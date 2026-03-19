/**
 * opcua_adapter.js — OPC UA implementation of PlcAdapter
 *
 * Connects to CODESYS Control OPC UA server using node-opcua.
 * Reads/writes GVL variables via the node IDs defined in opcua_nodes.js.
 *
 * Key differences from Modbus:
 * - Structured data: read/write individual struct fields (no register arithmetic)
 * - Data types preserved: DINT→Int32, LINT→Int64, BOOL→Boolean, REAL→Float
 * - No 125-register chunk limit
 * - Concurrent reads allowed via session
 */

const {
  OPCUAClient,
  MessageSecurityMode,
  SecurityPolicy,
  AttributeIds,
  DataType,
  StatusCodes,
  TimestampsToReturn,
  UserTokenType,
} = require('node-opcua');

const http = require('http');

const PlcAdapter = require('./plc_adapter');
const nodes = require('./opcua_nodes');

// ── Configuration ────────────────────────────────────────────
const OPCUA_ENDPOINT = process.env.OPCUA_ENDPOINT || 'opc.tcp://localhost:4840';
const RECONNECT_INTERVAL_MS = parseInt(process.env.OPCUA_RECONNECT_MS || '5000');
const ACK_POLL_INTERVAL_MS = 20;
const ACK_TIMEOUT_MS = 3000;

// Docker Engine API — for PLC container lifecycle control
const DOCKER_SOCKET = process.env.DOCKER_SOCKET || '/var/run/docker.sock';
const PLC_CONTAINER = process.env.PLC_CONTAINER || 'codesys_plc';

class OpcuaAdapter extends PlcAdapter {
  constructor() {
    super();
    this.client = null;
    this.session = null;
    this._reconnecting = false;
    this._readList = null;  // cached read list
  }

  // ── Connection lifecycle ──────────────────────────────────────

  async connect() {
    this.client = OPCUAClient.create({
      applicationName: 'NodeOPCUA-Client',
      connectionStrategy: {
        initialDelay: 1000,
        maxDelay: 10000,
        maxRetry: 100,
      },
      securityMode: MessageSecurityMode.SignAndEncrypt,
      securityPolicy: SecurityPolicy.Basic256Sha256,
      endpointMustExist: false,
    });

    this.client.on('backoff', (retry, delay) => {
      console.log(`[OPC-UA] Reconnect attempt ${retry}, next in ${delay}ms`);
    });

    try {
      await this.client.connect(OPCUA_ENDPOINT);
      this.session = await this.client.createSession({
        type: UserTokenType.UserName,
        userName: process.env.OPCUA_USER || 'PiiJar',
        password: process.env.OPCUA_PASSWORD || '!T0s1v41k33!',
      });
      this.connected = true;
      console.log(`[OPC-UA] Connected to ${OPCUA_ENDPOINT}`);
    } catch (err) {
      this.connected = false;
      console.error(`[OPC-UA] Connection failed: ${err.message}`);
      this._scheduleReconnect();
    }
  }

  async disconnect() {
    try {
      if (this.session) {
        await this.session.close();
        this.session = null;
      }
      if (this.client) {
        await this.client.disconnect();
        this.client = null;
      }
    } catch (err) {
      console.error(`[OPC-UA] Disconnect error: ${err.message}`);
    }
    this.connected = false;
  }

  _scheduleReconnect() {
    if (this._reconnecting) return;
    this._reconnecting = true;
    setTimeout(async () => {
      this._reconnecting = false;
      console.log('[OPC-UA] Attempting reconnect...');
      try {
        await this.connect();
      } catch (err) {
        console.error(`[OPC-UA] Reconnect failed: ${err.message}`);
      }
    }, RECONNECT_INTERVAL_MS);
  }

  // ── Low-level OPC UA helpers ──────────────────────────────────

  /**
   * Read multiple node values in a single OPC UA Read call.
   * @param {Array<{key: string, nodeId: string}>} readList
   * @returns {Object} key → value map
   */
  async _readNodes(readList) {
    if (!this.session) throw new Error('No OPC-UA session');
    const nodesToRead = readList.map(item => ({
      nodeId: item.nodeId,
      attributeId: AttributeIds.Value,
    }));
    const results = await this.session.read(nodesToRead, 0, TimestampsToReturn.Neither);
    const map = {};
    for (let i = 0; i < readList.length; i++) {
      const r = results[i];
      if (r.statusCode === StatusCodes.Good) {
        map[readList[i].key] = r.value.value;
      } else {
        map[readList[i].key] = null;
      }
    }
    return map;
  }

  /**
   * Write a single value to an OPC UA node.
   * @param {string} nid - Node ID string
   * @param {*} value - Value to write
   * @param {number} dataType - OPC UA DataType enum
   */
  async _writeNode(nid, value, dataType = DataType.Int16) {
    if (!this.session) throw new Error('No OPC-UA session');
    const statusCode = await this.session.write({
      nodeId: nid,
      attributeId: AttributeIds.Value,
      value: {
        value: { dataType, value },
      },
    });
    if (statusCode !== StatusCodes.Good) {
      throw new Error(`OPC-UA write failed: ${statusCode.toString()} for ${nid}`);
    }
  }

  /**
   * Write multiple values in a single call.
   * @param {Array<{nodeId: string, value: *, dataType: number}>} writes
   */
  async _writeNodes(writes) {
    if (!this.session) throw new Error('No OPC-UA session');
    const nodesToWrite = writes.map(w => ({
      nodeId: w.nodeId,
      attributeId: AttributeIds.Value,
      value: {
        value: { dataType: w.dataType || DataType.Int16, value: w.value },
      },
    }));
    const results = await this.session.write(nodesToWrite);
    for (let i = 0; i < results.length; i++) {
      if (results[i] !== StatusCodes.Good) {
        throw new Error(`OPC-UA write failed at index ${i}: ${results[i].toString()}`);
      }
    }
  }

  /**
   * Poll for ack value to match expected sequence.
   * @param {string} ackNodeId - Node to read
   * @param {number} expectedSeq - Expected value
   * @param {number} timeoutMs
   * @returns {boolean}
   */
  async _waitForAck(ackNodeId, expectedSeq, timeoutMs = ACK_TIMEOUT_MS) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const result = await this.session.read({
        nodeId: ackNodeId,
        attributeId: AttributeIds.Value,
      });
      if (result.statusCode === StatusCodes.Good && result.value.value === expectedSeq) {
        return true;
      }
      await new Promise(r => setTimeout(r, ACK_POLL_INTERVAL_MS));
    }
    return false;
  }

  // ── Sequence counters ─────────────────────────────────────────
  _cfgSeq = 0;
  _unitSeq = 0;
  _batchSeq = 0;
  _progSeq = 0;
  _avoidSeq = 0;

  _nextSeq(current) {
    return (current % 30000) + 1;
  }

  // ── Read operations ───────────────────────────────────────────

  async readState() {
    if (!this.connected || !this.session) return null;

    try {
      // Build read list (cache for performance)
      if (!this._readList) {
        this._readList = nodes.buildReadList();
      }

      const v = await this._readNodes(this._readList);
      const toNum = (val) => (val != null ? Number(val) : 0);

      // ── Parse transporters ────────────────────────────────
      const TARGET_INT_TO_STR = { 0: 'none', 1: 'to_loading', 2: 'to_buffer', 3: 'to_process', 4: 'to_unload', 5: 'to_avoid' };
      const BATCH_STATE_INT_TO_STR = { 0: 'not_processed', 1: 'in_process', 2: 'processed' };
      const PHASE_TO_OPERATION = { 0: 'idle', 1: 'moving', 2: 'lifting', 3: 'moving', 4: 'sinking' };
      const Z_STAGE_NAMES = { 0: 'idle', 2: 'slow_start', 3: 'fast_middle', 4: 'slow_end', 5: 'drip', 9: 'trip_close', 6: 'waiting_device', 7: 'fast_rise', 8: 'slow_top' };

      const transporters = [];
      for (let t = 1; t <= 3; t++) {
        const phase = toNum(v[`ts.${t}.phase`]);
        const isActive = !!v[`ts.${t}.is_active`];
        const status = !isActive ? 0 : (phase > 0 ? 4 : 3);
        const zStage = toNum(v[`sim.${t}.z_stage`]);

        transporters.push({
          id: t,
          model: '2D',
          state: {
            x_position: toNum(v[`ts.${t}.x_mm`]),
            y_position: toNum(v[`ts.${t}.y_mm`]),
            z_position: toNum(v[`ts.${t}.z_mm`]),
            operation: PHASE_TO_OPERATION[phase] || 'idle',
            current_station: toNum(v[`ts.${t}.current_station`]) || null,
            load: null,
            velocity_x: toNum(v[`sim.${t}.x_velocity`]) / 10.0,
            velocity_y: 0,
            status,
            phase,
            target_x: 0,
            target_y: 0,
            z_stage: Z_STAGE_NAMES[zStage] || 'idle',
            z_timer: toNum(v[`sim.${t}.z_timer`]),
            velocity_z: 0,
            pending_batch_id: null,
            current_task_batch_id: null,
            current_task_lift_station_id: toNum(v[`ts.${t}.lift_tgt`]) || null,
            current_task_sink_station_id: toNum(v[`ts.${t}.sink_tgt`]) || null,
            current_task_est_finish_s: null,
            initial_delay: 0,
            lift_station_target: toNum(v[`ts.${t}.lift_tgt`]) || null,
            sink_station_target: toNum(v[`ts.${t}.sink_tgt`]) || null,
            x_drive_target: toNum(v[`ts.${t}.x_drive_tgt`]),
            x_final_target: toNum(v[`ts.${t}.x_final_tgt`]),
            y_drive_target: toNum(v[`ts.${t}.y_drive_tgt`]),
            y_final_target: toNum(v[`ts.${t}.y_final_tgt`]),
            x_min_drive_limit: toNum(v[`ts.${t}.x_min_limit`]),
            x_max_drive_limit: toNum(v[`ts.${t}.x_max_limit`]),
            y_min_drive_limit: 0,
            y_max_drive_limit: 0,
            z_min_drive_limit: 0,
            z_max_drive_limit: 2500,
            phase_stats_idle_ms: 0,
            phase_stats_move_to_lift_ms: 0,
            phase_stats_lifting_ms: 0,
            phase_stats_move_to_sink_ms: 0,
            phase_stats_sinking_ms: 0,
            phase_stats_last_phase: phase,
            phase_stats_last_time_ms: Date.now(),
          },
        });
      }

      // ── Parse units ───────────────────────────────────────
      const units = [];
      for (let u = 1; u <= 10; u++) {
        const targetInt = toNum(v[`unit.${u}.target`]);
        const batchStateInt = toNum(v[`batch.${u}.state`]);
        units.push({
          unit_id: u,
          location: toNum(v[`unit.${u}.location`]),
          status: toNum(v[`unit.${u}.status`]),
          target: TARGET_INT_TO_STR[targetInt] || 'none',
          batch_code: toNum(v[`batch.${u}.code`]),
          batch_state: BATCH_STATE_INT_TO_STR[batchStateInt] || 'not_processed',
          batch_state_int: batchStateInt,
          batch_program: toNum(v[`batch.${u}.prog_id`]),
          batch_stage: toNum(v[`batch.${u}.cur_stage`]),
          batch_min_time: toNum(v[`batch.${u}.min_time`]),
          batch_max_time: toNum(v[`batch.${u}.max_time`]),
          batch_cal_time: toNum(v[`batch.${u}.cal_time`]),
          batch_start_time: toNum(v[`batch.${u}.start_time`]),
        });
      }

      // ── Parse meta ────────────────────────────────────────
      const meta = {
        station_count: toNum(v['meta.station_count']),
        init_done: toNum(v['meta.station_count']) > 0,  // inferred from station_count
        cycle_count: 0,  // Not needed with OPC UA (use subscription heartbeat)
        production_queue: toNum(v['meta.production_queue']),
      };

      // ── Parse TWA limits ──────────────────────────────────
      const twaLimits = {};
      for (let t = 1; t <= 3; t++) {
        twaLimits[t] = {
          x_min: toNum(v[`ts.${t}.x_min_limit`]),
          x_max: toNum(v[`ts.${t}.x_max_limit`]),
        };
      }

      // ── Parse task queues ─────────────────────────────────
      const taskQueues = {};
      for (let t = 1; t <= 3; t++) {
        const count = toNum(v[`tq.${t}.count`]);
        const tasks = [];
        for (let q = 1; q <= Math.min(count, 10); q++) {
          const unitId = toNum(v[`tq.${t}.${q}.unit_id`]);
          if (unitId === 0) continue;
          tasks.push({
            slot: q,
            unit_id: unitId,
            stage: toNum(v[`tq.${t}.${q}.stage`]),
            lift_station: toNum(v[`tq.${t}.${q}.lift_station`]),
            sink_station: toNum(v[`tq.${t}.${q}.sink_station`]),
            start_time: toNum(v[`tq.${t}.${q}.start_time`]),
            finish_time: toNum(v[`tq.${t}.${q}.finish_time`]),
            calc_time: toNum(v[`tq.${t}.${q}.calc_time`]) * 0.1,
            min_time: toNum(v[`tq.${t}.${q}.min_time`]) * 0.1,
            max_time: toNum(v[`tq.${t}.${q}.max_time`]) * 0.1,
          });
        }
        taskQueues[t] = { count, tasks };
      }

      // ── Parse DEP state ───────────────────────────────────
      const depState = {
        dep_activated: toNum(v['dep.activated']),
        dep_stable: toNum(v['dep.stable']),
        dep_waiting_count: toNum(v['dep.waiting_count']),
        dep_overlap_count: toNum(v['dep.overlap_count']),
        dep_pending_valid: toNum(v['dep.pending_valid']),
        dep_pending_unit: toNum(v['dep.pending_unit']),
        dep_pending_stage: toNum(v['dep.pending_stage']),
        dep_pending_time: toNum(v['dep.pending_time']),
        dep_wait_unit: toNum(v['dep.wait_unit']),
        waiting_units: [],
      };
      for (let w = 1; w <= 5; w++) {
        depState.waiting_units.push(toNum(v[`dep.waiting.${w}`]));
      }

      // ── Parse scheduler debug ─────────────────────────────
      const schedulerDebug = {};
      for (const k of Object.keys(nodes.SCHED_DEBUG)) {
        schedulerDebug[k] = toNum(v[`sched.${k}`]);
      }

      // ── Parse calibration ─────────────────────────────────
      const calibrationState = {
        step: 0,
        tid: 0,
        results: [],
      };
      for (let t = 1; t <= 3; t++) {
        calibrationState.results.push({
          id: t,
          lift_wet: toNum(v[`cal.${t}.lift_wet_time`]) / 10.0,
          sink_wet: toNum(v[`cal.${t}.sink_wet_time`]) / 10.0,
          lift_dry: toNum(v[`cal.${t}.lift_dry_time`]) / 10.0,
          sink_dry: toNum(v[`cal.${t}.sink_dry_time`]) / 10.0,
          x_acc: toNum(v[`cal.${t}.x_accel_time`]) / 10.0,
          x_dec: toNum(v[`cal.${t}.x_decel_time`]) / 10.0,
          x_max: toNum(v[`cal.${t}.x_max_speed`]),
        });
      }

      // ── Parse events (for event consumer) ─────────────────
      const eventHead = {
        count: toNum(v['event.count']),
        head_idx: toNum(v['event.head_idx']),
      };
      // Head message (if count > 0)
      if (eventHead.count > 0 && eventHead.head_idx >= 1 && eventHead.head_idx <= 10) {
        const hi = eventHead.head_idx;
        eventHead.seq = toNum(v[`event.buf.${hi}.seq`]);
        eventHead.msg_type = toNum(v[`event.buf.${hi}.msg_type`]);
        eventHead.ts_hi = toNum(v[`event.buf.${hi}.ts_hi`]);
        eventHead.ts_lo = toNum(v[`event.buf.${hi}.ts_lo`]);
        eventHead.fields = [];
        for (let f = 1; f <= 12; f++) {
          eventHead.fields.push(toNum(v[`event.buf.${hi}.f${f}`]));
        }
      }

      return {
        timestamp: new Date().toISOString(),
        transporters,
        units,
        meta,
        twaLimits,
        taskQueues,
        depState,
        schedulerDebug,
        calibration: calibrationState,
        eventHead,
      };
    } catch (err) {
      console.error(`[OPC-UA] readState error: ${err.message}`);
      this.connected = false;
      this._scheduleReconnect();
      return null;
    }
  }

  async readScheduleWindow(unitId) {
    if (!this.connected || !this.session) return null;

    try {
      // Write request
      await this._writeNode(nodes.CMD.schedule_req_unit, unitId, DataType.Int16);

      // Wait for PLC to fill the window
      await new Promise(r => setTimeout(r, 40));

      // Read schedule for the requested unit
      const sched = nodes.schedule(unitId);
      const readList = [{ key: 'stage_count', nodeId: sched.stage_count }];
      for (let s = 1; s <= 30; s++) {
        const st = sched[`stage_${s}`];
        for (const [k, nid] of Object.entries(st)) {
          readList.push({ key: `s${s}.${k}`, nodeId: nid });
        }
      }
      const v = await this._readNodes(readList);
      const stageCount = Number(v.stage_count) || 0;
      if (stageCount === 0) return null;

      const stages = [];
      for (let s = 1; s <= Math.min(stageCount, 30); s++) {
        stages.push({
          stage: s,
          station: Number(v[`s${s}.station`]) || 0,
          entry_time_s: Number(v[`s${s}.entry_time`]) || 0,
          exit_time_s: Number(v[`s${s}.exit_time`]) || 0,
          min_time_s: (Number(v[`s${s}.min_time`]) || 0) * 0.1,
          max_time_s: (Number(v[`s${s}.max_time`]) || 0) * 0.1,
        });
      }

      return { unit_id: unitId, stage_count: stageCount, stages };
    } catch (err) {
      console.error(`[OPC-UA] readScheduleWindow error: ${err.message}`);
      return null;
    }
  }

  async readEventHead() {
    // Event data is included in readState() result
    // This method is for standalone event reading if needed
    if (!this.connected || !this.session) return null;

    const readList = [
      { key: 'count', nodeId: nodes.EVENT.count },
      { key: 'head_idx', nodeId: nodes.EVENT.head_idx },
    ];
    const v = await this._readNodes(readList);
    const count = Number(v.count) || 0;
    if (count === 0) return null;

    const hi = Number(v.head_idx) || 1;
    const msgNodes = nodes.eventMsg(hi);
    const msgReadList = Object.entries(msgNodes).map(([k, nid]) => ({ key: k, nodeId: nid }));
    for (let f = 1; f <= 12; f++) {
      msgReadList.push({ key: `f${f}`, nodeId: nodes.eventPayload(hi, f) });
    }
    const mv = await this._readNodes(msgReadList);

    return {
      count,
      seq: Number(mv.seq) || 0,
      msgType: Number(mv.msg_type) || 0,
      timestamp: (Number(mv.ts_hi) || 0) * 65536 + (Number(mv.ts_lo) || 0),
      fields: Array.from({ length: 12 }, (_, i) => Number(mv[`f${i + 1}`]) || 0),
    };
  }

  // ── Write operations ──────────────────────────────────────────

  async uploadConfig(config) {
    const { stations, transporters, units, nttData, stationCount } = config;

    try {
      // Step 1: Clear all (cmd=3)
      this._cfgSeq = this._nextSeq(this._cfgSeq);
      await this._writeNodes([
        { nodeId: nodes.CMD.cfg_param, value: 0, dataType: DataType.Int16 },
        { nodeId: nodes.CMD.cfg_cmd, value: 3, dataType: DataType.Int16 },
        { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
      ]);
      if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
        return { success: false, error: 'PLC ack timeout for clear command' };
      }

      // Step 2: Upload stations (cmd=1)
      for (const st of stations) {
        const stNum = st.number;
        if (stNum < 101 || stNum > 125) continue;

        this._cfgSeq = this._nextSeq(this._cfgSeq);
        await this._writeNodes([
          { nodeId: nodes.CMD.cfg_d0, value: st.tank || 0, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d1, value: Math.round(st.x_position || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d2, value: Math.round(st.y_position || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d3, value: Math.round(st.z_position || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d4, value: st.operation || 0, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d5, value: Math.round((st.dropping_time || 0) * 10), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d6, value: Math.round((st.device_delay || 0) * 10), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d7, value: st.kind || 0, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_param, value: stNum, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_cmd, value: 1, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
        ]);
        if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
          return { success: false, error: `PLC ack timeout for station ${stNum}` };
        }
      }

      // Step 3: Upload transporter physics (cmd=4,5,6)
      const AREA_KEYS = ['line_100', 'line_200', 'line_300', 'line_400'];
      for (const tr of transporters) {
        const tid = tr.id;
        if (tid < 1 || tid > 3) continue;
        const p = tr.physics_2D || {};

        // cmd=4: physics page 1
        this._cfgSeq = this._nextSeq(this._cfgSeq);
        await this._writeNodes([
          { nodeId: nodes.CMD.cfg_d0, value: Math.round(tr.x_min_drive_limit || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d1, value: Math.round(tr.x_max_drive_limit || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d2, value: Math.round((p.x_acceleration_time_s || 0) * 10), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d3, value: Math.round((p.x_deceleration_time_s || 0) * 10), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d4, value: Math.round(p.x_max_speed_mm_s || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d5, value: Math.round(p.z_total_distance_mm || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d6, value: Math.round(p.avoid_distance_mm || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_param, value: tid, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_cmd, value: 4, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
        ]);
        if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
          return { success: false, error: `PLC ack timeout for T${tid} physics page 1` };
        }

        // cmd=5: physics page 2
        this._cfgSeq = this._nextSeq(this._cfgSeq);
        await this._writeNodes([
          { nodeId: nodes.CMD.cfg_d0, value: Math.round(p.z_slow_distance_dry_mm || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d1, value: Math.round(p.z_slow_distance_wet_mm || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d2, value: Math.round(p.z_slow_end_distance_mm || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d3, value: Math.round(p.z_slow_speed_mm_s || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d4, value: Math.round(p.z_fast_speed_mm_s || 0), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d5, value: Math.round((p.drip_tray_delay_s || 0) * 10), dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_d6, value: 0, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_param, value: tid, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_cmd, value: 5, dataType: DataType.Int16 },
          { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
        ]);
        if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
          return { success: false, error: `PLC ack timeout for T${tid} physics page 2` };
        }

        // cmd=6: task areas
        const areas = tr.task_areas || {};
        for (let ai = 0; ai < AREA_KEYS.length; ai++) {
          const area = areas[AREA_KEYS[ai]];
          if (!area || !area.min_lift_station) continue;
          const areaIdx = ai + 1;

          this._cfgSeq = this._nextSeq(this._cfgSeq);
          await this._writeNodes([
            { nodeId: nodes.CMD.cfg_d0, value: area.min_lift_station || 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_d1, value: area.max_lift_station || 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_d2, value: area.min_sink_station || 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_d3, value: area.max_sink_station || 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_d4, value: 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_d5, value: 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_d6, value: 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_param, value: tid * 10 + areaIdx, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_cmd, value: 6, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
          ]);
          if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
            return { success: false, error: `PLC ack timeout for T${tid} area ${areaIdx}` };
          }
        }
      }

      // Step 3b: NTT destinations (cmd=9,10)
      if (nttData) {
        const TARGET_MAP = {
          'to_loading': 1, 'to_buffer': 2, 'to_process': 3, 'to_unload': 4, 'to_unloading': 4, 'to_avoid': 5,
          'to_empty_buffer': 6, 'to_loaded_buffer': 7, 'to_processed_buffer': 8,
        };
        const targets = nttData.targets || {};
        for (const [targetName, targetDef] of Object.entries(targets)) {
          const tgtCode = TARGET_MAP[targetName];
          if (!tgtCode) continue;
          const trDefs = targetDef.transporters || {};
          for (const [trIdStr, dest] of Object.entries(trDefs)) {
            const trId = parseInt(trIdStr, 10);
            if (trId < 1 || trId > 3) continue;
            const stns = (dest.stations || []).slice(0, 5);
            const fb = (dest.fallback_stations || []).slice(0, 5);

            // cmd=9: primary
            this._cfgSeq = this._nextSeq(this._cfgSeq);
            const d9 = [0, 0, 0, 0, 0, 0, 0];
            for (let si = 0; si < stns.length; si++) d9[si] = stns[si];
            await this._writeNodes([
              ...d9.map((val, i) => ({ nodeId: nodes.CMD[`cfg_d${i}`], value: val, dataType: DataType.Int16 })),
              { nodeId: nodes.CMD.cfg_param, value: trId * 100 + tgtCode * 10 + stns.length, dataType: DataType.Int16 },
              { nodeId: nodes.CMD.cfg_cmd, value: 9, dataType: DataType.Int16 },
              { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
            ]);
            if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
              return { success: false, error: `PLC ack timeout for NTT cmd=9` };
            }

            // cmd=10: fallback
            if (fb.length > 0) {
              this._cfgSeq = this._nextSeq(this._cfgSeq);
              const d10 = [0, 0, 0, 0, 0, 0, 0];
              for (let si = 0; si < fb.length; si++) d10[si] = fb[si];
              await this._writeNodes([
                ...d10.map((val, i) => ({ nodeId: nodes.CMD[`cfg_d${i}`], value: val, dataType: DataType.Int16 })),
                { nodeId: nodes.CMD.cfg_param, value: trId * 100 + tgtCode * 10 + fb.length, dataType: DataType.Int16 },
                { nodeId: nodes.CMD.cfg_cmd, value: 10, dataType: DataType.Int16 },
                { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
              ]);
              if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
                return { success: false, error: `PLC ack timeout for NTT cmd=10` };
              }
            }
          }
        }
      }

      // Step 4: Upload units
      if (units && units.length > 0) {
        const STATUS_MAP = { 'not_used': 0, 'used': 1 };
        const TARGET_STR_TO_INT = { 'none': 0, 'to_loading': 1, 'to_buffer': 2, 'to_process': 3, 'to_unload': 4, 'to_avoid': 5 };
        for (const u of units) {
          const uid = u.unit_id;
          if (uid < 1 || uid > 10) continue;
          const statusInt = STATUS_MAP[u.status] ?? (typeof u.status === 'number' ? u.status : 0);
          const targetInt = TARGET_STR_TO_INT[u.target] ?? (typeof u.target === 'number' ? u.target : 0);

          this._unitSeq = this._nextSeq(this._unitSeq);
          await this._writeNodes([
            { nodeId: nodes.CMD.unit_id, value: uid, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.unit_loc, value: u.location || 0, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.unit_status, value: statusInt, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.unit_target, value: targetInt, dataType: DataType.Int16 },
            { nodeId: nodes.CMD.unit_seq, value: this._unitSeq, dataType: DataType.Int16 },
          ]);
          if (!await this._waitForAck(nodes.CMD.unit_ack, this._unitSeq)) {
            return { success: false, error: `PLC ack timeout for unit ${uid}` };
          }
        }
      }

      // Step 5: Init (cmd=2, param=station_count)
      this._cfgSeq = this._nextSeq(this._cfgSeq);
      await this._writeNodes([
        { nodeId: nodes.CMD.cfg_param, value: stationCount || stations.length, dataType: DataType.Int16 },
        { nodeId: nodes.CMD.cfg_cmd, value: 2, dataType: DataType.Int16 },
        { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
      ]);
      if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
        return { success: false, error: 'PLC ack timeout for init command' };
      }

      return { success: true };
    } catch (err) {
      console.error(`[OPC-UA] uploadConfig error: ${err.message}`);
      return { success: false, error: err.message };
    }
  }

  async writeCommand(transporterId, liftStation, sinkStation) {
    const cmd = nodes.cmdTransport(transporterId);
    await this._writeNodes([
      { nodeId: cmd.lift, value: liftStation, dataType: DataType.Int16 },
      { nodeId: cmd.sink, value: sinkStation, dataType: DataType.Int16 },
      { nodeId: cmd.start, value: 1, dataType: DataType.Int16 },
    ]);
    // Clear start after short delay
    setTimeout(async () => {
      try {
        await this._writeNode(cmd.start, 0, DataType.Int16);
      } catch (_) {}
    }, 200);
    console.log(`[OPC-UA] CMD T${transporterId}: lift=${liftStation} sink=${sinkStation}`);
  }

  async writeUnit(unitId, location, status, target) {
    this._unitSeq = this._nextSeq(this._unitSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.unit_id, value: unitId, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.unit_loc, value: location || 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.unit_status, value: status || 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.unit_target, value: target || 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.unit_seq, value: this._unitSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.unit_ack, this._unitSeq)) {
      throw new Error(`PLC unit ack timeout (unit=${unitId})`);
    }
    console.log(`[OPC-UA] Unit ${unitId}: loc=${location}, status=${status}, target=${target}`);
  }

  async writeBatch(unitIndex, batchCode, batchState, programId) {
    this._batchSeq = this._nextSeq(this._batchSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.batch_unit, value: unitIndex, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.batch_code, value: batchCode, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.batch_state, value: batchState, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.batch_prog, value: programId, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.batch_seq, value: this._batchSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.batch_ack, this._batchSeq)) {
      throw new Error(`PLC batch ack timeout (unit=${unitIndex})`);
    }
    console.log(`[OPC-UA] Batch unit=${unitIndex}: code=${batchCode}, state=${batchState}, prog=${programId}`);
  }

  async writeProgramStage(unitIndex, stageIndex, stations, minTime, maxTime, calTime) {
    const s = [0, 0, 0, 0, 0];
    for (let i = 0; i < Math.min(stations.length, 5); i++) {
      s[i] = stations[i] || 0;
    }

    this._progSeq = this._nextSeq(this._progSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.prog_unit, value: unitIndex, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_stage, value: stageIndex, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_s1, value: s[0], dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_s2, value: s[1], dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_s3, value: s[2], dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_s4, value: s[3], dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_s5, value: s[4], dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_min, value: minTime, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_max, value: maxTime, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_cal, value: calTime, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.prog_seq, value: this._progSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.prog_ack, this._progSeq)) {
      throw new Error(`PLC prog ack timeout (unit=${unitIndex}, stage=${stageIndex})`);
    }
  }

  async writeAvoidStatus(stationNumber, avoidStatus) {
    this._avoidSeq = this._nextSeq(this._avoidSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.avoid_stn, value: stationNumber, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.avoid_val, value: avoidStatus, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.avoid_seq, value: this._avoidSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.avoid_ack, this._avoidSeq)) {
      throw new Error(`PLC avoid ack timeout (station=${stationNumber})`);
    }
  }

  async ackEvent(seq) {
    await this._writeNode(nodes.CMD.event_ack_seq, seq & 0xFFFF, DataType.Int16);
  }

  async writeTime(unixSeconds) {
    const hi = (unixSeconds >>> 16) & 0xFFFF;
    const lo = unixSeconds & 0xFFFF;
    await this._writeNodes([
      { nodeId: nodes.CMD.time_hi, value: hi, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.time_lo, value: lo, dataType: DataType.Int16 },
    ]);
  }

  async writeProductionQueue(value) {
    await this._writeNode(nodes.CMD.production_queue, value, DataType.Int16);
  }

  async writeScheduleRequest(unitId) {
    await this._writeNode(nodes.CMD.schedule_req_unit, unitId, DataType.Int16);
  }

  async writeCalibrationPlan(tid, wetStation, dryStation) {
    this._cfgSeq = this._nextSeq(this._cfgSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.cfg_d0, value: wetStation || 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d1, value: dryStation || 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d2, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d3, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d4, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d5, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d6, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_param, value: tid, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_cmd, value: 7, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
      throw new Error(`PLC ack timeout for calibration plan T${tid}`);
    }
  }

  async writeCalibrationControl(action) {
    const paramMap = { 'start': 1, 'calculate': 2, 'abort': 3 };
    const param = paramMap[action];
    if (!param) throw new Error(`Unknown calibration action: ${action}`);

    this._cfgSeq = this._nextSeq(this._cfgSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.cfg_d0, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d1, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d2, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d3, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d4, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d5, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d6, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_param, value: param, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_cmd, value: 8, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
      throw new Error(`PLC ack timeout for calibration ${action}`);
    }
  }

  async writeCalibrationParams(tid, params) {
    this._cfgSeq = this._nextSeq(this._cfgSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.cfg_d0, value: Math.round((params.lift_wet_s || 0) * 100), dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d1, value: Math.round((params.sink_wet_s || 0) * 100), dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d2, value: Math.round((params.lift_dry_s || 0) * 100), dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d3, value: Math.round((params.sink_dry_s || 0) * 100), dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d4, value: Math.round((params.x_accel_s || 0) * 100), dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d5, value: Math.round((params.x_decel_s || 0) * 100), dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d6, value: Math.round(params.x_max_mm_s || 0), dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_param, value: tid, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_cmd, value: 11, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
      throw new Error(`PLC ack timeout for calibration params T${tid}`);
    }
  }

  async triggerMoveComputation() {
    this._cfgSeq = this._nextSeq(this._cfgSeq);
    await this._writeNodes([
      { nodeId: nodes.CMD.cfg_d0, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d1, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d2, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d3, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d4, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d5, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_d6, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_param, value: 0, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_cmd, value: 12, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cfg_seq, value: this._cfgSeq, dataType: DataType.Int16 },
    ]);
    if (!await this._waitForAck(nodes.CMD.cfg_ack, this._cfgSeq)) {
      throw new Error('PLC ack timeout for g_move computation');
    }
  }

  // ── PLC Runtime control via Docker Engine API ─────────────────

  /**
   * Docker Engine API helper — calls Unix socket.
   * @param {string} method - HTTP method
   * @param {string} apiPath - e.g. '/containers/codesys_plc/restart'
   * @param {number} timeoutMs
   * @returns {Promise<{status: number, data: string}>}
   */
  _dockerRequest(method, apiPath, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const options = {
        socketPath: DOCKER_SOCKET,
        path: apiPath,
        method,
        headers: { 'Content-Type': 'application/json' },
      };
      const req = http.request(options, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => resolve({ status: res.statusCode, data }));
      });
      req.on('error', (err) => {
        if (err.code === 'ENOENT') {
          reject(new Error('Docker socket not available — mount /var/run/docker.sock'));
        } else {
          reject(err);
        }
      });
      req.setTimeout(timeoutMs, () => { req.destroy(); reject(new Error('Docker API timeout')); });
      req.end();
    });
  }

  async startPlc() {
    try {
      // First try restart (works whether running or stopped)
      const res = await this._dockerRequest('POST', `/containers/${PLC_CONTAINER}/restart?t=5`);
      if (res.status === 204 || res.status === 200) {
        console.log(`[DOCKER] CODESYS container restarted`);
        // After restart, OPC UA connection will be lost — reconnect
        this.connected = false;
        setTimeout(() => this.connect(), 3000);
        return { success: true, message: 'CODESYS PLC restarted' };
      }
      // Container might not exist or might be in a weird state
      console.error(`[DOCKER] Restart failed: ${res.status} ${res.data}`);
      return { success: false, error: `Docker restart failed: HTTP ${res.status}` };
    } catch (err) {
      console.error(`[DOCKER] Start error: ${err.message}`);
      return { success: false, error: err.message };
    }
  }

  async stopPlc() {
    try {
      const res = await this._dockerRequest('POST', `/containers/${PLC_CONTAINER}/stop?t=10`);
      if (res.status === 204 || res.status === 200) {
        console.log(`[DOCKER] CODESYS container stopped`);
        this.connected = false;
        return { success: true, message: 'CODESYS PLC stopped' };
      }
      if (res.status === 304) {
        return { success: true, message: 'CODESYS PLC already stopped' };
      }
      return { success: false, error: `Docker stop failed: HTTP ${res.status}` };
    } catch (err) {
      console.error(`[DOCKER] Stop error: ${err.message}`);
      return { success: false, error: err.message };
    }
  }

  async getPlcStatus() {
    try {
      const res = await this._dockerRequest('GET', `/containers/${PLC_CONTAINER}/json`, 5000);
      if (res.status === 200) {
        const info = JSON.parse(res.data);
        const state = info.State || {};
        let status = 'unknown';
        if (state.Running) status = 'running';
        else if (state.Status === 'exited') status = 'stopped';
        else status = state.Status || 'unknown';
        return {
          status,
          detail: {
            container_state: state.Status,
            started_at: state.StartedAt,
            finished_at: state.FinishedAt,
            exit_code: state.ExitCode,
            pid: state.Pid,
          },
        };
      }
      if (res.status === 404) {
        return { status: 'not_found', detail: 'Container does not exist' };
      }
      return { status: 'unknown' };
    } catch (err) {
      return { status: 'unknown', detail: err.message };
    }
  }

  async getPlcLogs(lines = 200) {
    try {
      const res = await this._dockerRequest(
        'GET',
        `/containers/${PLC_CONTAINER}/logs?stdout=true&stderr=true&tail=${lines}&timestamps=true`,
        10000
      );
      if (res.status === 200) {
        // Docker log stream has 8-byte header per frame — strip it
        const logs = res.data.replace(/[\x00-\x08]/g, '').replace(/\r/g, '');
        return { success: true, logs };
      }
      return { success: false, logs: `Failed to fetch logs: HTTP ${res.status}` };
    } catch (err) {
      return { success: false, logs: err.message };
    }
  }
}

module.exports = OpcuaAdapter;

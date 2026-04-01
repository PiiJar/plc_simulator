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
  UserTokenType,
  VariantArrayType,
} = require('node-opcua');

const http = require('http');

const PlcAdapter = require('./plc_adapter');
const nodes = require('./opcua_nodes');

// ── Configuration ────────────────────────────────────────────
const OPCUA_ENDPOINT = process.env.OPCUA_ENDPOINT || 'opc.tcp://localhost:4840';
const RECONNECT_INTERVAL_MS = parseInt(process.env.OPCUA_RECONNECT_MS || '5000');


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
    // Prevent concurrent connection attempts
    if (this._connecting) return;
    this._connecting = true;

    try {
      // Clean up previous client if any
      if (this.client) {
        try { await this.client.disconnect(); } catch (_) {}
        this.client = null;
      }
      this.session = null;
      this.connected = false;

      this.client = OPCUAClient.create({
        applicationName: 'PLCGateway',
        connectionStrategy: {
          initialDelay: 1000,
          maxDelay: 10000,
          maxRetry: 100,
        },
        securityMode: MessageSecurityMode.None,
        securityPolicy: SecurityPolicy.None,
        endpointMustExist: false,
      });

      this.client.on('backoff', (retry, delay) => {
        console.log(`[OPC-UA] Reconnect attempt ${retry}, next in ${delay}ms`);
      });

      await this.client.connect(OPCUA_ENDPOINT);
      // Anonymous session — CODESYS Anonymous_OPCUAServer group grants access
      this.session = await this.client.createSession();
      this.connected = true;
      this._readList = null; // reset cached read list
      console.log(`[OPC-UA] Connected to ${OPCUA_ENDPOINT}`);
    } catch (err) {
      this.connected = false;
      console.error(`[OPC-UA] Connection failed: ${err.message}`);
      this._scheduleReconnect();
    } finally {
      this._connecting = false;
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
   * Read multiple node values, chunked to avoid BadTooManyOperations.
   * CODESYS MaxNodesPerRead = 100 (default, V3.5 SP17+, CODESYSControl.cfg).
   * Confirmed via OPC UA OperationLimits node i=11705.
   * @param {Array<{key: string, nodeId: string}>} readList
   * @returns {Object} key → value map
   */
  async _readNodes(readList) {
    if (!this.session) throw new Error('No OPC-UA session');
    const CHUNK = 100;  // CODESYS MaxNodesPerRead = 100
    const map = {};
    for (let offset = 0; offset < readList.length; offset += CHUNK) {
      const chunk = readList.slice(offset, offset + CHUNK);
      const nodesToRead = chunk.map(item => ({
        nodeId: item.nodeId,
        attributeId: AttributeIds.Value,
      }));
      const results = await this.session.read(nodesToRead, 0);
      for (let i = 0; i < chunk.length; i++) {
        const r = results[i];
        if (r.statusCode === StatusCodes.Good) {
          let val = r.value.value;
          // Coerce Int64/UInt64 (node-opcua returns [high, low] array) to JS number
          if (Array.isArray(val) && val.length === 2) {
            val = val[0] * 0x100000000 + (val[1] >>> 0);
          }
          map[chunk[i].key] = val;
        } else {
          map[chunk[i].key] = null;
        }
      }
    }
    return map;
  }

  /**
   * Read LINT/Int64 nodes individually (node-opcua v2 Variant issue workaround).
   * node-opcua batch read throws when encountering Int64 values because it
   * cannot auto-detect arrayType. Reading individually and catching errors.
   * @param {Array<{key: string, nodeId: string}>} readList
   * @returns {Object} key → number map
   */
  async _readLintNodes(readList) {
    if (!this.session) return {};
    const map = {};
    for (const item of readList) {
      try {
        const result = await this.session.read({
          nodeId: item.nodeId,
          attributeId: AttributeIds.Value,
        });
        if (result.statusCode === StatusCodes.Good) {
          const val = result.value.value;
          if (Array.isArray(val) && val.length === 2) {
            map[item.key] = val[0] * 0x100000000 + (val[1] >>> 0);
          } else {
            map[item.key] = Number(val) || 0;
          }
        } else {
          map[item.key] = 0;
        }
      } catch (_) {
        map[item.key] = 0;
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
        throw new Error(`OPC-UA write failed at index ${i} (nodeId: ${writes[i].nodeId}): ${results[i].toString()}`);
      }
    }
  }

  /**
   * Send a PLC command via OPC UA.
   * Writes g_cmd_code + g_cmd_param atomically.
   * PLC processes when g_cmd_code <> 0 and clears it.
   */
  async _sendCommand(code, param = 0) {
    await this._writeNodes([
      { nodeId: nodes.CMD.cmd_param, value: param, dataType: DataType.Int16 },
      { nodeId: nodes.CMD.cmd_code,  value: code,  dataType: DataType.Int16 },
    ]);
    // Small delay to let PLC process the command
    await new Promise(r => setTimeout(r, 50));
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

      // Read LINT batch.start_time fields separately (Int64 workaround)
      if (!this._batchLintList) {
        this._batchLintList = [];
        for (let u = 1; u <= 10; u++) {
          const bn = nodes.batch(u);
          this._batchLintList.push({ key: `batch.${u}.start_time`, nodeId: bn.start_time });
        }
      }
      const batchLint = await this._readLintNodes(this._batchLintList);
      Object.assign(v, batchLint);

      // Read g_time_s (LINT) separately
      if (!this._metaLintList) {
        this._metaLintList = [{ key: 'meta.time_seconds', nodeId: nodes.META.time_seconds }];
      }
      const metaLint = await this._readLintNodes(this._metaLintList);
      Object.assign(v, metaLint);

      // NOTE: transporter TaskId and RunningTaskId (LINT) are NOT read.
      // Reading LINT fields from struct members crashes CODESYS OPC UA provider.
      // These fields are not needed for UI display.

      const toNum = (val) => (val != null ? Number(val) : 0);

      // Read task queue LINT fields (StartTime, FinishTime) separately.
      // Only read active slots (up to count) to avoid 180 individual reads.
      {
        const tqLintList = [];
        for (let t = 1; t <= 3; t++) {
          const count = toNum(v[`tq.${t}.count`]);
          if (count > 0) {
            const tq = nodes.taskQueue(t);
            for (let q = 1; q <= Math.min(count, 30); q++) {
              const slot = tq[`task_${q}`];
              tqLintList.push({ key: `tq.${t}.${q}.start_time`, nodeId: slot.start_time });
              tqLintList.push({ key: `tq.${t}.${q}.finish_time`, nodeId: slot.finish_time });
            }
          }
        }
        if (tqLintList.length > 0) {
          const taskQueueLint = await this._readLintNodes(tqLintList);
          Object.assign(v, taskQueueLint);
        }
      }

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
        time_s: toNum(v['meta.time_seconds']),  // PLC system time (seconds)
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
        for (let q = 1; q <= Math.min(count, 30); q++) {
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
            calc_time: toNum(v[`tq.${t}.${q}.calc_time`]),
            min_time: toNum(v[`tq.${t}.${q}.min_time`]),
            max_time: toNum(v[`tq.${t}.${q}.max_time`]),
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
      // Program CalTime snapshot per unit (g_dbg_prog_cal[1..10])
      schedulerDebug.prog_cal = {};
      for (let u = 1; u <= 10; u++) {
        const val = toNum(v[`sched.prog_cal.${u}`]);
        if (val !== 0) schedulerDebug.prog_cal[u] = val;
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
        eventHead,
      };
    } catch (err) {
      const msg = err.message || String(err);
      console.error(`[OPC-UA] readState error: ${msg}`);
      if (err.stack) console.error(err.stack);
      // Only disconnect on actual connection/session errors
      if (msg.includes('session') || msg.includes('connect') || msg.includes('closed') || msg.includes('socket')) {
        this.connected = false;
        this._scheduleReconnect();
      }
      return null;
    }
  }


  async getActivePrograms(activeUids) {
    if (!this.connected || !this.session) return null;
    if (!activeUids || activeUids.length === 0) return [];

    try {
      const readList = [];
      for (const uid of activeUids) {
        const pw = nodes.programWrite(uid);
        readList.push({ key: `prog${uid}.prog_id`, nodeId: pw.program_id });
        readList.push({ key: `prog${uid}.step_count`, nodeId: pw.step_count });
        for (let s = 1; s <= 30; s++) { // up to max 30 stages
          readList.push({ key: `prog${uid}.s${s}.cal`, nodeId: pw[`step_${s}`].cal_time });
          readList.push({ key: `prog${uid}.s${s}.min`, nodeId: pw[`step_${s}`].min_time });
          readList.push({ key: `prog${uid}.s${s}.s0`, nodeId: pw[`step_${s}`].s0 });
        }
      }

      const results = await this._readNodes(readList);
      
      const programs = [];
      for (const uid of activeUids) {
        const stepCount = Number(results[`prog${uid}.step_count`]) || 0;
        if (stepCount === 0) continue;
        
        const steps = [];
        for (let s = 1; s <= stepCount; s++) {
          steps.push({
            stage: s,
            station_id: Number(results[`prog${uid}.s${s}.s0`]),
            min_time: Number(results[`prog${uid}.s${s}.min`]),
            cal_time: Number(results[`prog${uid}.s${s}.cal`])
          });
        }
        programs.push({
          unit_id: uid,
          program_id: Number(results[`prog${uid}.prog_id`]),
          steps: steps
        });
      }
      return programs;
    } catch (err) {
      console.error('[OPC-UA] getActivePrograms error:', err);
      return null;
    }
  }

  async readScheduleWindow(unitId) {
    if (!this.connected || !this.session) return null;

    try {
      // Schedule data is always available — PLC fills g_schedule[uid] continuously
      // No request write needed (no sliding window protocol in CODESYS version)

      // Read schedule for the requested unit
      // NOTE: entry_time and exit_time are LINT — skip them to avoid
      // node-opcua Int64 Variant error; read only non-LINT fields
      const sched = nodes.schedule(unitId);
      const readList = [{ key: 'stage_count', nodeId: sched.stage_count }];
      for (let s = 0; s <= 30; s++) {
        const st = sched[`stage_${s}`];
        for (const [k, nid] of Object.entries(st)) {
          if (k === 'entry_time' || k === 'exit_time') continue; // LINT fields
          readList.push({ key: `s${s}.${k}`, nodeId: nid });
        }
      }
      const v = await this._readNodes(readList);
      const stageCount = Number(v.stage_count) || 0;
      if (stageCount === 0) return null;

      // Read LINT fields (entry_time, exit_time) separately using
      // individual reads with proper Int64 handling
      const lintReadList = [];
      for (let s = 0; s <= Math.min(stageCount, 30); s++) {
        const st = sched[`stage_${s}`];
        lintReadList.push({ key: `s${s}.entry_time`, nodeId: st.entry_time });
        lintReadList.push({ key: `s${s}.exit_time`, nodeId: st.exit_time });
      }
      const lv = await this._readLintNodes(lintReadList);

      const stages = [];
      for (let s = 0; s <= Math.min(stageCount, 30); s++) {
        stages.push({
          stage: s,
          station: Number(v[`s${s}.station`]) || 0,
          entry_time_s: lv[`s${s}.entry_time`] || 0,
          exit_time_s: lv[`s${s}.exit_time`] || 0,
          min_time_s: Number(v[`s${s}.min_time`]) || 0,
          max_time_s: Number(v[`s${s}.max_time`]) || 0,
        });
      }

      return { unit_id: unitId, stage_count: stageCount, stages };
    } catch (err) {
      console.error(`[OPC-UA] readScheduleWindow error: ${err.message || String(err)}`);
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
  // Protocol: write struct data directly via OPC UA, then trigger
  // commands via g_cmd_code/g_cmd_param (PLC clears after processing).

  async uploadConfig(config) {
    const { stations, transporters, units, nttData, stationCount } = config;

    try {
      // Step 1: Clear all (cmd=3)
      await this._sendCommand(3, 0);
      console.log('[OPC-UA] Sent CLEAR command');

      // Step 2: Write station config directly to g_station[n]
      for (const st of stations) {
        const stNum = st.number;
        if (stNum < 100 || stNum > 130) continue;
        const sw = nodes.stationWrite(stNum);
        await this._writeNodes([
          { nodeId: sw.station_id,    value: stNum,                                    dataType: DataType.Int16 },
          { nodeId: sw.tank_id,       value: st.tank || 0,                             dataType: DataType.Int16 },
          { nodeId: sw.is_in_use,     value: true,                                     dataType: DataType.Boolean },
          { nodeId: sw.station_type,  value: st.operation || st.station_type || 0,     dataType: DataType.Int16 },
          { nodeId: sw.x_position,    value: Math.round(st.x_position || 0),           dataType: DataType.Int32 },
          { nodeId: sw.y_position,    value: Math.round(st.y_position || 0),           dataType: DataType.Int32 },
          { nodeId: sw.z_position,    value: Math.round(st.z_position || 0),           dataType: DataType.Int32 },
          { nodeId: sw.dripping_time, value: Math.round((st.dropping_time || 0) * 10), dataType: DataType.Int16 },
          { nodeId: sw.device_delay,  value: Math.round((st.device_delay || 0) * 10),  dataType: DataType.Int16 },
          { nodeId: sw.dry_wet,       value: st.kind || 0,                             dataType: DataType.Int16 },
          { nodeId: sw.move_away,     value: st.move_away || 0,                        dataType: DataType.Int16 },
        ]);
      }
      console.log(`[OPC-UA] Wrote ${stations.length} stations`);

      // Step 3: Write transporter config to g_cfg[tid]
      const AREA_KEYS = ['line_100', 'line_200', 'line_300'];
      for (const tr of transporters) {
        const tid = tr.id;
        if (tid < 1 || tid > 3) continue;
        const cw = nodes.cfgWrite(tid);
        const p = tr.physics_2D || {};
        const areas = tr.task_areas || {};

        const writes = [
          // Identity & limits
          { nodeId: cw.transporter_id,  value: tid,                                         dataType: DataType.Int16 },
          { nodeId: cw.is_in_use,       value: true,                                        dataType: DataType.Boolean },
          { nodeId: cw.drive_pos_min,   value: Math.round(tr.x_min_drive_limit || 0),       dataType: DataType.Int32 },
          { nodeId: cw.drive_pos_max,   value: Math.round(tr.x_max_drive_limit || 0),       dataType: DataType.Int32 },
          { nodeId: cw.y_min_drive_limit, value: Math.round(tr.y_min_drive_limit || 0),     dataType: DataType.Int32 },
          { nodeId: cw.y_max_drive_limit, value: Math.round(tr.y_max_drive_limit || 0),     dataType: DataType.Int32 },
          // X-axis physics
          { nodeId: cw.speed_max_x,     value: Math.round(p.x_max_speed_mm_s || 0),         dataType: DataType.Int32 },
          { nodeId: cw.acceleration_x,  value: Math.round((p.x_acceleration_time_s || 0) * 10), dataType: DataType.Int32 },
          { nodeId: cw.deceleration_x,  value: Math.round((p.x_deceleration_time_s || 0) * 10), dataType: DataType.Int32 },
          // Z-axis positions (from physics_2D z params)
          { nodeId: cw.z_pos_down,      value: Math.round(p.z_total_distance_mm || 0),      dataType: DataType.Int32 },
          { nodeId: cw.z_pos_slow_up,   value: Math.round(p.z_slow_distance_dry_mm || 0),   dataType: DataType.Int32 },
          { nodeId: cw.z_pos_slow_down, value: Math.round(p.z_slow_distance_wet_mm || 0),   dataType: DataType.Int32 },
          { nodeId: cw.z_pos_slow_end,  value: Math.round(p.z_slow_end_distance_mm || 0),   dataType: DataType.Int32 },
          // Z-axis speeds
          { nodeId: cw.speed_lift_slow_z, value: Math.round(p.z_slow_speed_mm_s || 0),      dataType: DataType.Int32 },
          { nodeId: cw.speed_lift_fast_z, value: Math.round(p.z_fast_speed_mm_s || 0),      dataType: DataType.Int32 },
          // Drip tray
          { nodeId: cw.drip_tray_in_use, value: (p.drip_tray_delay_s || 0) > 0,             dataType: DataType.Boolean },
          { nodeId: cw.drip_tray_delay,  value: Math.round((p.drip_tray_delay_s || 0) * 10), dataType: DataType.Int16 },
          // Collision avoidance
          { nodeId: cw.collision_width,  value: Math.round(p.avoid_distance_mm || 0),        dataType: DataType.Int32 },
          { nodeId: cw.avoidance_width,  value: Math.round(p.avoid_distance_mm || 0),        dataType: DataType.Int32 },
        ];

        // Task areas (up to 3 slots)
        for (let ai = 0; ai < AREA_KEYS.length; ai++) {
          const area = areas[AREA_KEYS[ai]];
          const aIdx = ai + 1;
          if (area && area.min_lift_station) {
            writes.push(
              { nodeId: cw[`ta${aIdx}_min_lift`], value: area.min_lift_station || 0, dataType: DataType.Int16 },
              { nodeId: cw[`ta${aIdx}_max_lift`], value: area.max_lift_station || 0, dataType: DataType.Int16 },
              { nodeId: cw[`ta${aIdx}_min_sink`], value: area.min_sink_station || 0, dataType: DataType.Int16 },
              { nodeId: cw[`ta${aIdx}_max_sink`], value: area.max_sink_station || 0, dataType: DataType.Int16 },
            );
          } else {
            writes.push(
              { nodeId: cw[`ta${aIdx}_min_lift`], value: 0, dataType: DataType.Int16 },
              { nodeId: cw[`ta${aIdx}_max_lift`], value: 0, dataType: DataType.Int16 },
              { nodeId: cw[`ta${aIdx}_min_sink`], value: 0, dataType: DataType.Int16 },
              { nodeId: cw[`ta${aIdx}_max_sink`], value: 0, dataType: DataType.Int16 },
            );
          }
        }

        await this._writeNodes(writes);
      }
      console.log(`[OPC-UA] Wrote ${transporters.length} transporter configs`);

      // Step 4: Write NTT destinations to g_ntt[tid]
      if (nttData) {
        const TARGET_MAP = {
          'to_loading': 1, 'to_buffer': 2, 'to_process': 3, 'to_unload': 4, 'to_unloading': 4,
          'to_avoid': 5, 'to_empty_buffer': 6, 'to_loaded_buffer': 7, 'to_processed_buffer': 8,
        };
        const targets = nttData.targets || {};
        for (const [targetName, targetDef] of Object.entries(targets)) {
          const tgtCode = TARGET_MAP[targetName];
          if (!tgtCode) continue;
          const trDefs = targetDef.transporters || {};
          for (const [trIdStr, dest] of Object.entries(trDefs)) {
            const trId = parseInt(trIdStr, 10);
            if (trId < 1 || trId > 3) continue;
            const nw = nodes.nttWrite(trId);
            const tgt = nw[`tgt_${tgtCode}`];
            if (!tgt) continue;

            const stns = (dest.stations || []).slice(0, 5);
            const fb = (dest.fallback_stations || []).slice(0, 5);
            const writes = [
              { nodeId: tgt.station_count, value: stns.length, dataType: DataType.Int16 },
              { nodeId: tgt.fallback_count, value: fb.length, dataType: DataType.Int16 },
            ];
            for (let si = 1; si <= 5; si++) {
              writes.push({ nodeId: tgt[`s${si}`], value: stns[si - 1] || 0, dataType: DataType.Int16 });
              writes.push({ nodeId: tgt[`fb${si}`], value: fb[si - 1] || 0, dataType: DataType.Int16 });
            }
            await this._writeNodes(writes);
          }
        }
        console.log('[OPC-UA] Wrote NTT destinations');
      }

      // Step 5: Write units to g_unit[uid]
      if (units && units.length > 0) {
        const STATUS_MAP = { 'not_used': 0, 'used': 1 };
        const TARGET_STR_TO_INT = { 'none': 0, 'to_loading': 1, 'to_buffer': 2, 'to_process': 3, 'to_unload': 4, 'to_avoid': 5 };
        for (const u of units) {
          const uid = u.unit_id;
          if (uid < 1 || uid > 10) continue;
          const uw = nodes.unitWrite(uid);
          const statusInt = STATUS_MAP[u.status] ?? (typeof u.status === 'number' ? u.status : 0);
          const targetInt = TARGET_STR_TO_INT[u.target] ?? (typeof u.target === 'number' ? u.target : 0);
          await this._writeNodes([
            { nodeId: uw.location, value: u.location || 0, dataType: DataType.Int16 },
            { nodeId: uw.status,   value: statusInt,       dataType: DataType.Int16 },
            { nodeId: uw.target,   value: targetInt,       dataType: DataType.Int16 },
          ]);
        }
        console.log(`[OPC-UA] Wrote ${units.length} units`);
      }

      // Step 6: Write real unix time for PLC time sync
      const unixSeconds = Math.floor(Date.now() / 1000);
      await this._writeNodes([
        { nodeId: nodes.CMD.time_sync, value: unixSeconds, dataType: DataType.Int64 },
      ]);
      console.log(`[OPC-UA] Wrote time_sync = ${unixSeconds} (${new Date(unixSeconds * 1000).toISOString()})`);

      // Step 7: Init command (cmd=2, param=station_count)
      await this._sendCommand(2, stationCount || stations.length);
      console.log(`[OPC-UA] Sent INIT command (station_count=${stationCount || stations.length})`);

      return { success: true };
    } catch (err) {
      console.error(`[OPC-UA] uploadConfig error: ${err.message}`);
      return { success: false, error: err.message };
    }
  }

  async writeCommand(transporterId, liftStation, sinkStation) {
    // Manual transport is not supported via g_cmd protocol.
    // The PLC scheduler handles all transport assignments automatically.
    // Log the request for debugging purposes.
    console.log(`[OPC-UA] writeCommand T${transporterId}: lift=${liftStation} sink=${sinkStation} (manual commands not supported in CODESYS version)`);
  }

  async writeUnit(unitId, location, status, target) {
    const uw = nodes.unitWrite(unitId);
    await this._writeNodes([
      { nodeId: uw.location, value: location || 0, dataType: DataType.Int16 },
      { nodeId: uw.status,   value: status || 0,   dataType: DataType.Int16 },
      { nodeId: uw.target,   value: target || 0,   dataType: DataType.Int16 },
    ]);
    console.log(`[OPC-UA] Unit ${unitId}: loc=${location}, status=${status}, target=${target}`);
  }

  async writeBatch(unitIndex, batchCode, batchState, programId) {
    const bw = nodes.batchWrite(unitIndex);
    const pw = nodes.programWrite(unitIndex);
    const nowS = Math.floor(Date.now() / 1000);
    const MAX_TIME_DEFAULT = 1800; // 30 min

    await this._writeNodes([
      { nodeId: bw.batch_code, value: batchCode || 0,  dataType: DataType.Int16 },
      { nodeId: bw.state,      value: batchState || 0, dataType: DataType.Int16 },
      { nodeId: bw.prog_id,    value: programId || 0,  dataType: DataType.Int16 },
      { nodeId: bw.cur_stage,  value: 0,               dataType: DataType.Int16 },
      { nodeId: bw.min_time,   value: 0,               dataType: DataType.Int32 },
      { nodeId: bw.max_time,   value: MAX_TIME_DEFAULT, dataType: DataType.Int32 },
      { nodeId: bw.cal_time,   value: 0,               dataType: DataType.Int32 },
    ]);

    // Write g_program[uid].ProgramId so PLC can match batch → program
    await this._writeNode(pw.program_id, programId || 0, DataType.Int16);

    // StartTime is LINT (Int64) — requires [high, low] format
    const high = Math.floor(nowS / 0x100000000) & 0xFFFFFFFF;
    const low  = nowS & 0xFFFFFFFF;
    const sc = await this.session.write({
      nodeId: bw.start_time,
      attributeId: AttributeIds.Value,
      value: {
        value: {
          dataType: DataType.Int64,
          arrayType: VariantArrayType.Scalar,
          value: [high, low],
        },
      },
    });
    if (sc !== StatusCodes.Good) {
      throw new Error(`OPC-UA write StartTime failed: ${sc.toString()}`);
    }

    console.log(`[OPC-UA] Batch unit=${unitIndex}: code=${batchCode}, state=${batchState}, prog=${programId}, startTime=${nowS}, maxTime=${MAX_TIME_DEFAULT}`);
  }

  /**
   * Write movement times for one transporter to g_move[tid].
   * @param {number} tid - transporter id (1..3)
   * @param {object} data - { lift_s: {stn: seconds}, sink_s: {stn: seconds}, travel: {from: {to: seconds}} }
   */
  async writeMovementTimes(tid, data) {
    const mw = nodes.moveTimesWrite(tid);

    // Write lift + sink times (×10 → tenths of second)
    const liftSink = [];
    for (const [stnStr, secs] of Object.entries(data.lift_s || {})) {
      const idx = parseInt(stnStr) - 100;
      if (idx >= 1 && idx <= 30 && mw[`lift_${idx}`]) {
        liftSink.push({ nodeId: mw[`lift_${idx}`], value: Math.round(secs * 10), dataType: DataType.Int16 });
      }
    }
    for (const [stnStr, secs] of Object.entries(data.sink_s || {})) {
      const idx = parseInt(stnStr) - 100;
      if (idx >= 1 && idx <= 30 && mw[`sink_${idx}`]) {
        liftSink.push({ nodeId: mw[`sink_${idx}`], value: Math.round(secs * 10), dataType: DataType.Int16 });
      }
    }
    if (liftSink.length > 0) {
      await this._writeNodes(liftSink);
    }

    // Write travel times (×10 → tenths of second), chunked to avoid huge single writes
    const travel = data.travel || {};
    for (const [fromStr, toMap] of Object.entries(travel)) {
      const fromIdx = parseInt(fromStr) - 100;
      if (fromIdx < 1 || fromIdx > 30) continue;
      const writes = [];
      for (const [toStr, secs] of Object.entries(toMap)) {
        const toIdx = parseInt(toStr) - 100;
        if (toIdx < 1 || toIdx > 30) continue;
        const key = `travel_${fromIdx}_${toIdx}`;
        if (mw[key]) {
          writes.push({ nodeId: mw[key], value: Math.round(secs * 10), dataType: DataType.Int16 });
        }
      }
      if (writes.length > 0) {
        await this._writeNodes(writes);
      }
    }

    console.log(`[OPC-UA] Movement times written for transporter ${tid}`);
  }

  async writeProgramStage(unitIndex, stageIndex, stations, minTime, maxTime, calTime) {
    const pw = nodes.programWrite(unitIndex);
    const step = pw[`step_${stageIndex}`];
    if (!step) throw new Error(`Invalid stage index ${stageIndex} for unit ${unitIndex}`);

    const stns = [0, 0, 0, 0, 0];
    for (let i = 0; i < Math.min(stations.length, 5); i++) {
      stns[i] = stations[i] || 0;
    }

    await this._writeNodes([
      { nodeId: step.min_time,      value: minTime || 0,          dataType: DataType.Int32 },
      { nodeId: step.max_time,      value: maxTime || 0,          dataType: DataType.Int32 },
      { nodeId: step.cal_time,      value: calTime || 0,          dataType: DataType.Int32 },
      { nodeId: step.station_count, value: stations.length,       dataType: DataType.Int16 },
      { nodeId: step.s0,            value: stns[0],               dataType: DataType.Int16 },
      { nodeId: step.s1,            value: stns[1],               dataType: DataType.Int16 },
      { nodeId: step.s2,            value: stns[2],               dataType: DataType.Int16 },
      { nodeId: step.s3,            value: stns[3],               dataType: DataType.Int16 },
      { nodeId: step.s4,            value: stns[4],               dataType: DataType.Int16 },
    ]);

    // Update step count if this stage extends it
    const scReadList = [{ key: 'sc', nodeId: pw.step_count }];
    const scv = await this._readNodes(scReadList);
    const currentCount = Number(scv.sc) || 0;
    if (stageIndex > currentCount) {
      await this._writeNode(pw.step_count, stageIndex, DataType.Int16);
    }
  }

  async writeAvoidStatus(stationNumber, avoidStatusVal) {
    const nid = nodes.avoidStatus(stationNumber);
    await this._writeNode(nid, avoidStatusVal, DataType.Int16);
  }

  async ackEvent(seq) {
    await this._writeNode(nodes.CMD.event_ack_seq, seq & 0xFFFF, DataType.Int16);
  }

  async writeTime(unixSeconds) {
    // g_time_s is LINT (64-bit signed integer)
    // node-opcua requires arrayType: Scalar when writing Int64 with [high, low]
    if (!this.session) throw new Error('No OPC-UA session');
    const high = Math.floor(unixSeconds / 0x100000000) & 0xFFFFFFFF;
    const low = unixSeconds & 0xFFFFFFFF;
    const statusCode = await this.session.write({
      nodeId: nodes.CMD.time_s,
      attributeId: AttributeIds.Value,
      value: {
        value: {
          dataType: DataType.Int64,
          arrayType: VariantArrayType.Scalar,
          value: [high, low],
        },
      },
    });
    if (statusCode !== StatusCodes.Good) {
      throw new Error(`OPC-UA write g_time_s failed: ${statusCode.toString()}`);
    }
  }

  async writeProductionQueue(value) {
    await this._writeNode(nodes.CMD.production_queue, value, DataType.Int16);
  }

  async writeScheduleRequest(unitId) {
    // No schedule request needed — PLC fills g_schedule[] continuously
    // This is a no-op in the CODESYS OPC UA version
  }

  // ── PLC Runtime control ─────────────────────────────────────
  //
  // Uses Docker exec to run /etc/init.d/codesyscontrol start|stop|status
  // inside the running container.  The Docker container itself stays alive —
  // only the CODESYS runtime process (codesyscontrol.bin) is started/stopped.
  // This is the equivalent of PLC RUN / STOP in the CODESYS IDE.

  /**
   * Docker Engine API helper — calls Unix socket.
   * @param {string} method - HTTP method
   * @param {string} apiPath - e.g. '/containers/codesys/json'
   * @param {object|null} body - JSON body to send (optional)
   * @param {number} timeoutMs
   * @returns {Promise<{status: number, data: string}>}
   */
  _dockerRequest(method, apiPath, body = null, timeoutMs = 30000) {
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
      if (body) req.write(JSON.stringify(body));
      req.end();
    });
  }

  /**
   * Execute a command inside the running container via Docker exec API.
   * @param {string[]} cmd - Command array, e.g. ['/etc/init.d/codesyscontrol', 'stop']
   * @returns {Promise<{output: string, exitCode: number}>}
   */
  async _dockerExec(cmd) {
    // 1. Create exec instance
    const createRes = await this._dockerRequest(
      'POST',
      `/containers/${PLC_CONTAINER}/exec`,
      { AttachStdout: true, AttachStderr: true, Tty: true, Cmd: cmd }
    );
    if (createRes.status !== 201) {
      throw new Error(`Docker exec create failed: HTTP ${createRes.status} ${createRes.data}`);
    }
    const execId = JSON.parse(createRes.data).Id;

    // 2. Start exec and capture output (Tty=true → plain text, no multiplex headers)
    const startRes = await this._dockerRequest(
      'POST',
      `/exec/${execId}/start`,
      { Detach: false, Tty: true }
    );

    // 3. Get exit code
    let exitCode = -1;
    try {
      const inspectRes = await this._dockerRequest('GET', `/exec/${execId}/json`);
      if (inspectRes.status === 200) {
        exitCode = JSON.parse(inspectRes.data).ExitCode ?? -1;
      }
    } catch (_) {}

    return { output: startRes.data || '', exitCode };
  }

  /**
   * PLC RUN — start the CODESYS runtime process inside the container.
   * Container stays running; only codesyscontrol.bin is started.
   */
  async startPlc() {
    try {
      const result = await this._dockerExec(['/etc/init.d/codesyscontrol', 'start']);
      const msg = result.output.trim() || 'codesyscontrol started';
      console.log(`[PLC] RUN: ${msg} (exit: ${result.exitCode})`);

      // OPC UA server comes up with the runtime — reconnect
      this.connected = false;
      setTimeout(() => this.connect(), 2000);
      return { success: true, message: msg };
    } catch (err) {
      console.error(`[PLC] RUN error: ${err.message}`);
      return { success: false, error: err.message };
    }
  }

  /**
   * PLC STOP — stop the CODESYS runtime process inside the container.
   * Container stays running; codesyscontrol.bin is terminated gracefully.
   */
  async stopPlc() {
    try {
      const result = await this._dockerExec(['/etc/init.d/codesyscontrol', 'stop']);
      const msg = result.output.trim() || 'codesyscontrol stopped';
      console.log(`[PLC] STOP: ${msg} (exit: ${result.exitCode})`);
      this.connected = false;
      return { success: true, message: msg };
    } catch (err) {
      console.error(`[PLC] STOP error: ${err.message}`);
      return { success: false, error: err.message };
    }
  }

  /**
   * Get PLC status — checks both container state and CODESYS runtime process.
   * Returns 'running' only when container is up AND codesyscontrol is active.
   */
  async getPlcStatus() {
    try {
      // 1. Check Docker container is running
      const containerRes = await this._dockerRequest('GET', `/containers/${PLC_CONTAINER}/json`, null, 5000);
      if (containerRes.status === 404) {
        return { status: 'not_found', detail: 'Container does not exist' };
      }
      if (containerRes.status !== 200) {
        return { status: 'unknown' };
      }
      const info = JSON.parse(containerRes.data);
      if (!info.State?.Running) {
        return {
          status: 'container_stopped',
          detail: { container_state: info.State?.Status || 'exited' },
        };
      }

      // 2. Container is running — check CODESYS runtime process
      const result = await this._dockerExec(['/etc/init.d/codesyscontrol', 'status']);
      const output = result.output.trim();
      const isRunning = output.includes('running');

      return {
        status: isRunning ? 'running' : 'stopped',
        detail: {
          container_state: 'running',
          runtime_output: output,
        },
      };
    } catch (err) {
      return { status: 'unknown', detail: err.message };
    }
  }

  async getPlcLogs(lines = 200) {
    try {
      const res = await this._dockerRequest(
        'GET',
        `/containers/${PLC_CONTAINER}/logs?stdout=true&stderr=true&tail=${lines}&timestamps=true`,
        null,
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

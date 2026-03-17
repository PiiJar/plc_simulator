/**
 * opcua_nodes.js — OPC UA NodeId map for CODESYS GVL variables
 *
 * Maps logical gateway data concepts to CODESYS OPC UA node paths.
 * CODESYS Control OPC UA server exposes GVL variables as:
 *   ns=<NS>;s=|var|<DEVICE>.Application.<GVL>.<Var>
 *
 * Arrays use 1-based indexing: GVL_Parameters.Units[1].Location
 * Nested structs use dot notation: TransporterStatus[1].XPosition
 *
 * Environment config:
 *   OPCUA_NS       — namespace index (default: 4)
 *   OPCUA_DEVICE   — device prefix (default: "CODESYS_Control_Win_V3", empty for Linux)
 */

const NS = parseInt(process.env.OPCUA_NS || '4');
const DEVICE = process.env.OPCUA_DEVICE || '';

// Build full OPC UA node ID string
function nodeId(gvl, varPath) {
  const prefix = DEVICE ? `${DEVICE}.Application` : 'Application';
  return `ns=${NS};s=|var|${prefix}.${gvl}.${varPath}`;
}

// Shorthand GVL references
const P = (v) => nodeId('GVL_Parameters', v);
const S = (v) => nodeId('GVL_JC_Scheduler', v);
const G = (v) => nodeId('GVL_Gateway', v);    // Gateway → PLC command inputs

// ═══════════════════════════════════════════════════════════════
// READ nodes — PLC state polled by gateway
// ═══════════════════════════════════════════════════════════════

/**
 * TransporterStatus fields for transporter tid (1..3)
 */
function transporterStatus(tid) {
  const b = `TransporterStatus[${tid}]`;
  return {
    x_mm:          P(`${b}.XPosition`),
    y_mm:          P(`${b}.YPosition`),
    z_mm:          P(`${b}.ZPosition`),
    phase:         P(`${b}.Phase`),
    status:        P(`${b}.Status`),
    current_station: P(`${b}.CurrentStation`),
    lift_tgt:      P(`${b}.LiftStationTarget`),
    sink_tgt:      P(`${b}.SinkStationTarget`),
    task_id:       P(`${b}.TaskId`),
    x_drive_tgt:   P(`${b}.XDriveTarget`),
    x_final_tgt:   P(`${b}.XFinalTarget`),
    y_drive_tgt:   P(`${b}.YDriveTarget`),
    y_final_tgt:   P(`${b}.YFinalTarget`),
    x_min_limit:   P(`${b}.XMinDriveLimit`),
    x_max_limit:   P(`${b}.XMaxDriveLimit`),
    is_active:     P(`${b}.IsActive`),
    busy:          P(`${b}.Busy`),
    dripping_time: P(`${b}.DrippingTime`),
    task_remaining_time: P(`${b}.TaskRemainingTime`),
    lift_remaining_time: P(`${b}.LiftStationRemainingTime`),
  };
}

/**
 * SimTransporter fields for transporter tid (1..3)
 */
function simTransporter(tid) {
  const b = `SimTransporter[${tid}]`;
  return {
    running_task_id:  S(`${b}.RunningTaskId`),
    treatment_time:   S(`${b}.TreatmentTime`),
    min_time:         S(`${b}.MinTime`),
    max_time:         S(`${b}.MaxTime`),
    lift_device_delay: S(`${b}.LiftDeviceDelay`),
    sink_device_delay: S(`${b}.SinkDeviceDelay`),
    x_velocity:       S(`${b}.XVelocity`),
    z_stage:          S(`${b}.ZStage`),
    z_timer:          S(`${b}.ZTimer`),
  };
}

/**
 * Unit fields for unit uid (1..10)
 */
function unit(uid) {
  const b = `Units[${uid}]`;
  return {
    location: P(`${b}.Location`),
    status:   P(`${b}.Status`),
    target:   P(`${b}.Target`),
  };
}

/**
 * Batch fields for unit uid (1..10)
 */
function batch(uid) {
  const b = `Batches[${uid}]`;
  return {
    code:       P(`${b}.BatchCode`),
    state:      P(`${b}.State`),
    prog_id:    P(`${b}.ProgId`),
    cur_stage:  P(`${b}.CurStage`),
    min_time:   P(`${b}.MinTime`),
    max_time:   P(`${b}.MaxTime`),
    cal_time:   P(`${b}.CalTime`),
    start_time: P(`${b}.StartTime`),
  };
}

/**
 * Task queue for transporter tid (1..3)
 */
function taskQueue(tid) {
  const b = `TaskQueue[${tid}]`;
  const nodes = { count: S(`${b}.Count`) };
  // 10 task slots
  for (let q = 1; q <= 10; q++) {
    const qb = `${b}.Queue[${q}]`;
    nodes[`task_${q}`] = {
      unit_id:      S(`${qb}.UnitId`),
      stage:        S(`${qb}.Stage`),
      lift_station: S(`${qb}.LiftStation`),
      sink_station: S(`${qb}.SinkStation`),
      start_time:   S(`${qb}.StartTime`),
      finish_time:  S(`${qb}.FinishTime`),
      calc_time:    S(`${qb}.CalcTime`),
      min_time:     S(`${qb}.MinTime`),
      max_time:     S(`${qb}.MaxTime`),
    };
  }
  return nodes;
}

/**
 * Schedule for unit uid (1..10)
 */
function schedule(uid) {
  const b = `Schedule[${uid}]`;
  const nodes = { stage_count: S(`${b}.StageCount`) };
  for (let s = 1; s <= 30; s++) {
    const sb = `${b}.Stages[${s}]`;
    nodes[`stage_${s}`] = {
      station:    S(`${sb}.Station`),
      entry_time: S(`${sb}.EntryTime`),
      exit_time:  S(`${sb}.ExitTime`),
      min_time:   S(`${sb}.MinTime`),
      max_time:   S(`${sb}.MaxTime`),
    };
  }
  return nodes;
}

/**
 * Calibration for transporter tid (1..3)
 */
function calibration(tid) {
  const b = `Calibration[${tid}]`;
  return {
    wet_station:   S(`${b}.WetStation`),
    dry_station:   S(`${b}.DryStation`),
    lift_wet_time: S(`${b}.LiftWetTime`),
    sink_wet_time: S(`${b}.SinkWetTime`),
    lift_dry_time: S(`${b}.LiftDryTime`),
    sink_dry_time: S(`${b}.SinkDryTime`),
    x_accel_time:  S(`${b}.XAccelTime`),
    x_decel_time:  S(`${b}.XDecelTime`),
    x_max_speed:   S(`${b}.XMaxSpeed`),
  };
}

// ── Scalar read nodes ────────────────────────────────────────

const META = {
  station_count:    P('StationCount'),
  cal_active:       S('CalibrationActive'),
  production_queue: S('ProductionQueue'),
  time_seconds:     S('TimeSeconds'),
};

const DEP = {
  activated:     S('DepActivated'),
  stable:        S('DepStable'),
  waiting_count: S('DepWaitingCount'),
  overlap_count: S('DepOverlap.Count'),
  pending_valid: S('DepPending.Valid'),
  pending_unit:  S('DepPending.BatchUnit'),
  pending_stage: S('DepPending.BatchStage'),
  pending_time:  S('DepPending.TimeStamp'),
  wait_unit:     S('DepWaitUnit'),
};

// DEP waiting array (1..5)
function depWaiting(idx) {
  return S(`DepWaiting[${idx}]`);
}

const SCHED_DEBUG = {
  tsk_phase:          S('SchedDbgTskPhase'),
  dep_phase:          S('SchedDbgDepPhase'),
  turn:               S('SchedDbgTurn'),
  skip_cnt:           S('SchedDbgSkipCnt'),
  conflict_resolved:  S('ConflictResolved'),
  dep_reject_cnt:     S('SchedDbgDepRejectCnt'),
  dep_fit_round:      S('SchedDbgDepFitRound'),
  dep_cur_wait_unit:  S('SchedDbgDepCurWaitUnit'),
  dep_wait_cnt:       S('SchedDbgDepWaitCnt'),
  batch_cnt:          S('SchedDbgBatchCnt'),
};

// Event queue head (read-only from PLC)
const EVENT = {
  count:    S('EventQueue.Count'),
  head_idx: S('EventQueue.Head'),
};

// Event message at buffer index (1..10)
function eventMsg(idx) {
  const b = `EventQueue.Buffer[${idx}]`;
  return {
    seq:     S(`${b}.Seq`),
    msg_type: S(`${b}.MsgType`),
    ts_hi:   S(`${b}.TsHi`),
    ts_lo:   S(`${b}.TsLo`),
  };
}

function eventPayload(bufIdx, fieldIdx) {
  return S(`EventQueue.Buffer[${bufIdx}].Payload[${fieldIdx}]`);
}

// Avoid status per station (100..130)
function avoidStatus(stationNum) {
  return P(`AvoidStatus[${stationNum}]`);
}

// ═══════════════════════════════════════════════════════════════
// WRITE nodes — Gateway → PLC command inputs
// These map to GVL_Gateway (new GVL for CODESYS input protocol)
// ═══════════════════════════════════════════════════════════════

const CMD = {
  // Config upload protocol (seq/cmd/ack handshake)
  cfg_seq:   G('CfgSeq'),
  cfg_cmd:   G('CfgCmd'),
  cfg_param: G('CfgParam'),
  cfg_d0:    G('CfgD[0]'),
  cfg_d1:    G('CfgD[1]'),
  cfg_d2:    G('CfgD[2]'),
  cfg_d3:    G('CfgD[3]'),
  cfg_d4:    G('CfgD[4]'),
  cfg_d5:    G('CfgD[5]'),
  cfg_d6:    G('CfgD[6]'),
  cfg_d7:    G('CfgD[7]'),

  // Config ack (read from PLC)
  cfg_ack:   G('CfgAck'),

  // Unit write protocol
  unit_seq:    G('UnitSeq'),
  unit_id:     G('UnitId'),
  unit_loc:    G('UnitLoc'),
  unit_status: G('UnitStatus'),
  unit_target: G('UnitTarget'),
  unit_ack:    G('UnitAck'),

  // Batch write protocol
  batch_seq:    G('BatchSeq'),
  batch_unit:   G('BatchUnit'),
  batch_code:   G('BatchCode'),
  batch_state:  G('BatchState'),
  batch_prog:   G('BatchProg'),
  batch_ack:    G('BatchAck'),

  // Program stage write protocol
  prog_seq:    G('ProgSeq'),
  prog_unit:   G('ProgUnit'),
  prog_stage:  G('ProgStage'),
  prog_s1:     G('ProgS[1]'),
  prog_s2:     G('ProgS[2]'),
  prog_s3:     G('ProgS[3]'),
  prog_s4:     G('ProgS[4]'),
  prog_s5:     G('ProgS[5]'),
  prog_min:    G('ProgMinTime'),
  prog_max:    G('ProgMaxTime'),
  prog_cal:    G('ProgCalTime'),
  prog_ack:    G('ProgAck'),

  // Avoid write protocol
  avoid_seq:    G('AvoidSeq'),
  avoid_stn:    G('AvoidStation'),
  avoid_val:    G('AvoidValue'),
  avoid_ack:    G('AvoidAck'),

  // Manual transport commands (per transporter)
  cmd_t1_start: G('CmdT1Start'),
  cmd_t1_lift:  G('CmdT1Lift'),
  cmd_t1_sink:  G('CmdT1Sink'),
  cmd_t2_start: G('CmdT2Start'),
  cmd_t2_lift:  G('CmdT2Lift'),
  cmd_t2_sink:  G('CmdT2Sink'),
  cmd_t3_start: G('CmdT3Start'),
  cmd_t3_lift:  G('CmdT3Lift'),
  cmd_t3_sink:  G('CmdT3Sink'),

  // Event acknowledgment
  event_ack_seq: G('EventAckSeq'),

  // Time sync
  time_hi: G('TimeHi'),
  time_lo: G('TimeLo'),

  // Production queue flag
  production_queue: G('ProductionQueue'),

  // Schedule window request
  schedule_req_unit: G('ScheduleReqUnit'),
};

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

/**
 * Get command transport nodes for a specific transporter
 */
function cmdTransport(tid) {
  return {
    start: G(`CmdT${tid}Start`),
    lift:  G(`CmdT${tid}Lift`),
    sink:  G(`CmdT${tid}Sink`),
  };
}

/**
 * Collect all read node IDs needed for a full state poll.
 * Returns flat array of { key, nodeId } for batch OPC UA read.
 */
function buildReadList() {
  const list = [];
  const add = (key, nid) => list.push({ key, nodeId: nid });

  // Meta
  for (const [k, nid] of Object.entries(META)) add(`meta.${k}`, nid);

  // Transporters (1..3)
  for (let t = 1; t <= 3; t++) {
    const ts = transporterStatus(t);
    for (const [k, nid] of Object.entries(ts)) add(`ts.${t}.${k}`, nid);
    const st = simTransporter(t);
    for (const [k, nid] of Object.entries(st)) add(`sim.${t}.${k}`, nid);
  }

  // Units + Batches (1..10)
  for (let u = 1; u <= 10; u++) {
    const un = unit(u);
    for (const [k, nid] of Object.entries(un)) add(`unit.${u}.${k}`, nid);
    const bn = batch(u);
    for (const [k, nid] of Object.entries(bn)) add(`batch.${u}.${k}`, nid);
  }

  // Task queues (1..3, count + 10 slots × 9 fields)
  for (let t = 1; t <= 3; t++) {
    add(`tq.${t}.count`, taskQueue(t).count);
    for (let q = 1; q <= 10; q++) {
      const tq = taskQueue(t)[`task_${q}`];
      for (const [k, nid] of Object.entries(tq)) add(`tq.${t}.${q}.${k}`, nid);
    }
  }

  // DEP state
  for (const [k, nid] of Object.entries(DEP)) add(`dep.${k}`, nid);
  for (let w = 1; w <= 5; w++) add(`dep.waiting.${w}`, depWaiting(w));

  // Scheduler debug
  for (const [k, nid] of Object.entries(SCHED_DEBUG)) add(`sched.${k}`, nid);

  // Calibration (1..3)
  for (let t = 1; t <= 3; t++) {
    const cal = calibration(t);
    for (const [k, nid] of Object.entries(cal)) add(`cal.${t}.${k}`, nid);
  }

  // Event queue (count + head index + buffer[1..10] headers)
  add('event.count', EVENT.count);
  add('event.head_idx', EVENT.head_idx);
  for (let i = 1; i <= 10; i++) {
    const em = eventMsg(i);
    for (const [k, nid] of Object.entries(em)) add(`event.buf.${i}.${k}`, nid);
    for (let f = 1; f <= 12; f++) {
      add(`event.buf.${i}.f${f}`, eventPayload(i, f));
    }
  }

  return list;
}

module.exports = {
  nodeId,
  NS,
  transporterStatus,
  simTransporter,
  unit,
  batch,
  taskQueue,
  schedule,
  calibration,
  META,
  DEP,
  depWaiting,
  SCHED_DEBUG,
  EVENT,
  eventMsg,
  eventPayload,
  avoidStatus,
  CMD,
  cmdTransport,
  buildReadList,
};

/**
 * opcua_nodes.js — OPC UA NodeId map for CODESYS GVL variables
 *
 * Maps logical gateway data concepts to CODESYS OPC UA node paths.
 * CODESYS Control OPC UA server exposes GVL variables as:
 *   ns=<NS>;s=|var|<DEVICE>.Application.<GVL>.<Var>
 *
 * Actual PLC variable naming (IEC ST style):
 *   GVL_JC_Parameters: TransporterStatus[1..3], Unit[1..10], Batch[1..10],
 *                   Stations[100..130], AvoidStatus[100..130], CountStations
 *   GVL_JC_Scheduler: SimTrans[1..3], Task[1..3], Schedule[1..10],
 *                     Move[1..3], Event, CmdCode, CmdParam, etc.
 *
 * Environment config:
 *   OPCUA_NS       — namespace index (default: 4)
 *   OPCUA_DEVICE   — device prefix (default: "CODESYS Control for Linux SL")
 */

const NS = parseInt(process.env.OPCUA_NS || '4');
const DEVICE = process.env.OPCUA_DEVICE || 'CODESYS Control for Linux SL';

// Build full OPC UA node ID string
function nodeId(gvl, varPath) {
  const prefix = DEVICE ? `${DEVICE}.Application` : 'Application';
  return `ns=${NS};s=|var|${prefix}.${gvl}.${varPath}`;
}

// Shorthand GVL references
const P = (v) => nodeId('GVL_JC_Parameters', v);
const S = (v) => nodeId('GVL_JC_Scheduler', v);

// ═══════════════════════════════════════════════════════════════
// READ nodes — PLC state polled by gateway
// ═══════════════════════════════════════════════════════════════

/**
 * Transporter status fields for transporter tid (1..3)
 * PLC variable: GVL_JC_Parameters.TransporterStatus[tid]
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
 * PLC variable: GVL_JC_Scheduler.SimTrans[tid]
 */
function simTransporter(tid) {
  const b = `SimTrans[${tid}]`;
  return {
    runninTask_id:  S(`${b}.RunningTaskId`),
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
 * PLC variable: GVL_JC_Parameters.Unit[uid]
 */
function unit(uid) {
  const b = `Unit[${uid}]`;
  return {
    location: P(`${b}.Location`),
    status:   P(`${b}.Status`),
    target:   P(`${b}.Target`),
  };
}

/**
 * Batch fields for unit uid (1..10)
 * PLC variable: GVL_JC_Parameters.Batch[uid]
 */
function batch(uid) {
  const b = `Batch[${uid}]`;
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
 * PLC variable: GVL_JC_Scheduler.Task[tid]
 */
function taskQueue(tid) {
  const b = `Task[${tid}]`;
  const nodes = { count: S(`${b}.Count`) };
  // 30 task slots
  for (let q = 1; q <= 30; q++) {
    const qb = `${b}.Queue[${q}]`;
    nodes[`task_${q}`] = {
      unit_id:      S(`${qb}.Unit`),
      stage:        S(`${qb}.Stage`),
      lift_station: S(`${qb}.LiftStationTarget`),
      sink_station: S(`${qb}.SinkStationTarget`),
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
 * PLC variable: GVL_JC_Scheduler.Schedule[uid]
 */
function schedule(uid) {
  const b = `Schedule[${uid}]`;
  const nodes = { stage_count: S(`${b}.StageCount`) };
  for (let s = 0; s <= 30; s++) {
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
 * UI snapshot schedule for unit uid (1..10)
 * PLC variable: GVL_JC_Scheduler.SimUiSchedule[uid]
 * Stable copy written only at TSK phase 10000 rising edge.
 */
function simSchedule(uid) {
  const b = `SimUiSchedule[${uid}]`;
  const nodes = { stage_count: S(`${b}.StageCount`) };
  for (let s = 0; s <= 30; s++) {
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
 * UI snapshot task queue for transporter tid (1..3)
 * PLC variable: GVL_JC_Scheduler.SimUiTask[tid]
 * Stable copy written only at TSK phase 10000 rising edge.
 */
function simTaskQueue(tid) {
  const b = `SimUiTask[${tid}]`;
  const nodes = { count: S(`${b}.Count`) };
  for (let q = 1; q <= 30; q++) {
    const qb = `${b}.Queue[${q}]`;
    nodes[`task_${q}`] = {
      unit_id:      S(`${qb}.Unit`),
      stage:        S(`${qb}.Stage`),
      lift_station: S(`${qb}.LiftStationTarget`),
      sink_station: S(`${qb}.SinkStationTarget`),
      start_time:   S(`${qb}.StartTime`),
      finish_time:  S(`${qb}.FinishTime`),
      calc_time:    S(`${qb}.CalcTime`),
      min_time:     S(`${qb}.MinTime`),
      max_time:     S(`${qb}.MaxTime`),
    };
  }
  return nodes;
}

// ── Scalar read nodes ────────────────────────────────────────

const META = {
  station_count:    P('CountStations'),
  production_queue: S('ProductionQueue'),
  time_seconds:     S('TimeS'),
};

const DEP = {
  activated:     S('DepActivated'),
  stable:        S('TskStable'),
  waiting_count: S('DepWaitingCount'),
  overlap_count: S('DepOverlap.Count'),
  pending_valid: S('DepPending.Valid'),
  pendinUnit:  S('DepPending.BatchUnit'),
  pending_stage: S('DepPending.BatchStage'),
  pending_time:  S('DepPending.TimeStamp'),
};

// DEP waiting array (1..5)
function depWaiting(idx) {
  return S(`DepWaiting[${idx}]`);
}

// UI snapshot scalar fields
const SIM_UI = {
  wait_unit:   S('SimUiWaitUnit'),
  wait_reason: S('SimUiWaitReason'),
};

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
  // TSK conflict debug
  conflict_type:      S('DbgTskConflictType'),
  conflict_iter:      S('DbgTskConflictIter'),
  conf_unit:          S('DbgTskConfUnit'),
  conf_stage:         S('DbgTskConfStage'),
  blocked_unit:       S('DbgTskBlockedUnit'),
  blocked_stage:      S('DbgTskBlockedStage'),
  deficit:            S('DbgTskDeficit'),
  stretch_cnt:        S('DbgTskStretchCnt'),
  total_adv:          S('DbgTskTotalAdv'),
  total_delay:        S('DbgTskTotalDelay'),  tsk_round_ticks:      S('SchedDbgTskRoundTicks'),
  dep_round_ticks:      S('SchedDbgDepRoundTicks'),};

// Program CalTime snapshot per unit (DINT, safe for OPC UA batch read)
function progCalDebug(uid) {
  return S(`DbgProgCal[${uid}]`);
}

// Event queue head (read-only from PLC)
const EVENT = {
  count:    S('Event.Count'),
  head_idx: S('Event.Head'),
};

// Event message at buffer index (1..10)
function eventMsg(idx) {
  const b = `Event.Buffer[${idx}]`;
  return {
    seq:     S(`${b}.Seq`),
    msg_type: S(`${b}.MsgType`),
    ts_hi:   S(`${b}.TsHi`),
    ts_lo:   S(`${b}.TsLo`),
  };
}

function eventPayload(bufIdx, fieldIdx) {
  return S(`Event.Buffer[${bufIdx}].Payload[${fieldIdx}]`);
}

// Avoid status per station (100..130)
function avoidStatus(stationNum) {
  return P(`AvoidStatus[${stationNum}]`);
}

// ═══════════════════════════════════════════════════════════════
// WRITE nodes — Gateway → PLC command inputs
// All write variables live in GVL_JC_Scheduler (CmdCode/CmdParam protocol)
// ═══════════════════════════════════════════════════════════════

const CMD = {
  // OPC UA command protocol — PLC processes when cmd_code <> 0, then clears
  cmd_code:  S('CmdCode'),
  cmd_param: S('CmdParam'),

  // Event acknowledgment
  event_ack_seq: S('EventAckSeq'),

  // Production queue flag
  production_queue: S('ProductionQueue'),

  // Time sync (LINT)
  time_s: S('TimeS'),
  time_sync: S('TimeSync'),
};

// ═══════════════════════════════════════════════════════════════
// WRITE helpers — direct struct writes (Gateway → PLC)
// ═══════════════════════════════════════════════════════════════

/**
 * Station config write targets  (Stations[stNum])
 * PLC variable: GVL_JC_Parameters.Stations[100..130]
 */
function stationWrite(stNum) {
  const b = `Stations[${stNum}]`;
  return {
    station_id:     P(`${b}.StationId`),
    tank_id:        P(`${b}.TankId`),
    is_in_use:      P(`${b}.IsInUse`),
    station_type:   P(`${b}.StationType`),
    x_position:     P(`${b}.XPosition`),
    y_position:     P(`${b}.YPosition`),
    z_position:     P(`${b}.ZPosition`),
    dripping_time:  P(`${b}.DrippingTime`),
    device_delay:   P(`${b}.DeviceDelay`),
    dry_wet:           P(`${b}.DryWet`),
    move_away:         P(`${b}.MoveAway`),
    avoid_distance:    P(`${b}.AvoidDistance`),
    take_out_delay:    P(`${b}.TakeOutDelay`),
    take_out_distance: P(`${b}.TakeOutDistance`),
  };
}

/**
 * Transporter config write targets (Transporters[tid])
 * PLC variable: GVL_JC_Parameters.Transporters[1..3]
 */
function cfgWrite(tid) {
  const b = `Transporters[${tid}]`;
  return {
    transporter_id: P(`${b}.TransporterId`),
    is_in_use:      P(`${b}.IsInUse`),
    drive_pos_min:  P(`${b}.DrivePosMin`),
    drive_pos_max:  P(`${b}.DrivePosMax`),
    // Y-axis limits
    y_min_drive_limit: P(`${b}.YMinDriveLimit`),
    y_max_drive_limit: P(`${b}.YMaxDriveLimit`),
    // Task areas
    ta1_min_lift:   P(`${b}.TaskArea[1].MinLift`),
    ta1_max_lift:   P(`${b}.TaskArea[1].MaxLift`),
    ta1_min_sink:   P(`${b}.TaskArea[1].MinSink`),
    ta1_max_sink:   P(`${b}.TaskArea[1].MaxSink`),
    ta2_min_lift:   P(`${b}.TaskArea[2].MinLift`),
    ta2_max_lift:   P(`${b}.TaskArea[2].MaxLift`),
    ta2_min_sink:   P(`${b}.TaskArea[2].MinSink`),
    ta2_max_sink:   P(`${b}.TaskArea[2].MaxSink`),
    ta3_min_lift:   P(`${b}.TaskArea[3].MinLift`),
    ta3_max_lift:   P(`${b}.TaskArea[3].MaxLift`),
    ta3_min_sink:   P(`${b}.TaskArea[3].MinSink`),
    ta3_max_sink:   P(`${b}.TaskArea[3].MaxSink`),
    // X-axis physics
    speed_max_x:       P(`${b}.SpeedMax_X`),
    acceleration_x:    P(`${b}.Acceleration_X`),
    deceleration_x:    P(`${b}.Deceleration_X`),
    // Z-axis positions
    z_pos_down:        P(`${b}.ZPosDown`),
    z_pos_slow_up:     P(`${b}.ZPosSlowUp`),
    z_pos_slow_down:   P(`${b}.ZPosSlowDown`),
    z_pos_slow_end:    P(`${b}.ZPosSlowEnd`),
    // Z-axis speeds
    speed_lift_slow_z: P(`${b}.SpeedLiftSlow_Z`),
    speed_lift_fast_z: P(`${b}.SpeedLiftFast_Z`),
    // Drip tray
    drip_tray_in_use:  P(`${b}.DripTrayInUse`),
    drip_tray_delay:   P(`${b}.DripTrayDelay`),
    // Collision avoidance
    collision_width:   P(`${b}.CollisionWidth`),
    avoidance_width:   P(`${b}.AvoidanceWidth`),
  };
}

/**
 * Unit write targets (Unit[uid])
 * PLC variable: GVL_JC_Parameters.Unit[1..10]
 */
function unitWrite(uid) {
  const b = `Unit[${uid}]`;
  return {
    location: P(`${b}.Location`),
    status:   P(`${b}.Status`),
    target:   P(`${b}.Target`),
  };
}

/**
 * Batch write targets (Batch[uid])
 * PLC variable: GVL_JC_Parameters.Batch[1..10]
 */
function batchWrite(uid) {
  const b = `Batch[${uid}]`;
  return {
    batch_code: P(`${b}.BatchCode`),
    state:      P(`${b}.State`),
    prog_id:    P(`${b}.ProgId`),
    cur_stage:  P(`${b}.CurStage`),
    start_time: P(`${b}.StartTime`),
    min_time:   P(`${b}.MinTime`),
    max_time:   P(`${b}.MaxTime`),
    cal_time:   P(`${b}.CalTime`),
  };
}

/**
 * Treatment program write targets (TreatmentPrograms[uid])
 * PLC variable: GVL_JC_Parameters.TreatmentPrograms[1..10]
 */
function programWrite(uid) {
  const b = `TreatmentPrograms[${uid}]`;
  const n = {
    program_id: P(`${b}.ProgramId`),
    step_count: P(`${b}.StepCount`),
  };
  for (let s = 0; s <= 30; s++) {
    const sb = `${b}.Steps[${s}]`;
    n[`step_${s}`] = {
      min_time:      P(`${sb}.MinTime`),
      max_time:      P(`${sb}.MaxTime`),
      cal_time:      P(`${sb}.CalTime`),
      station_count: P(`${sb}.StationCount`),
      s0:            P(`${sb}.Stations[0]`),
      s1:            P(`${sb}.Stations[1]`),
      s2:            P(`${sb}.Stations[2]`),
      s3:            P(`${sb}.Stations[3]`),
      s4:            P(`${sb}.Stations[4]`),
    };
  }
  return n;
}

/**
 * NTT (no-treatment-task) write targets (Ntt[tid])
 * PLC variable: GVL_JC_Scheduler.Ntt[1..3]
 */
function nttWrite(tid) {
  const b = `Ntt[${tid}]`;
  const n = {};
  for (let tgt = 1; tgt <= 8; tgt++) {
    const tb = `${b}.Target[${tgt}]`;
    n[`tgt_${tgt}`] = {
      station_count: S(`${tb}.StationCount`),
      fallback_count: S(`${tb}.FallbackCount`),
    };
    for (let si = 1; si <= 5; si++) {
      n[`tgt_${tgt}`][`s${si}`] = S(`${tb}.Stations[${si}]`);
      n[`tgt_${tgt}`][`fb${si}`] = S(`${tb}.FallbackStations[${si}]`);
    }
  }
  return n;
}

/**
 * Manual task write targets (ManualTask[tid])
 * PLC variable: GVL_JC_Scheduler.ManualTask[1..3]
 */
function manualTaskWrite(tid) {
  const b = `ManualTask[${tid}]`;
  return {
    liftStation: S(`${b}.LiftStation`),
    sinkStation: S(`${b}.SinkStation`),
    valid:       S(`${b}.Valid`),
  };
}

/**
 * Manual task read targets (ManualTask[tid])
 */
function manualTaskRead(tid) {
  const b = `ManualTask[${tid}]`;
  return {
    lift_station: S(`${b}.LiftStation`),
    sink_station: S(`${b}.SinkStation`),
    valid:        S(`${b}.Valid`),
  };
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

/**
 * Collect all read node IDs needed for a full state poll.
 * Returns flat array of { key, nodeId } for batch OPC UA read.
 *
 * IMPORTANT: LINT (Int64) fields are excluded from this list because
 * node-opcua v2.164 throws "Variant#constructor : arrayType must be specified"
 * when decoding Int64 values in a batch read.  These fields are collected
 * in buildLintReadList() and read separately.
 */
const LINT_KEYS = new Set([
  'meta.time_seconds',  // TimeS : LINT
]);

function buildReadList() {
  const list = [];
  const add = (key, nid) => {
    if (LINT_KEYS.has(key)) return; // skip LINT fields
    list.push({ key, nodeId: nid });
  };

  // Meta
  for (const [k, nid] of Object.entries(META)) add(`meta.${k}`, nid);

  // Transporters (1..3)
  // NOTE: task_id (TaskId) and runninTask_id (RunningTaskId) are LINT —
  // CODESYS OPC UA server crashes when batch-reading LINT struct fields.
  // They are read separately via _readLintNodes in opcua_adapter.js.
  for (let t = 1; t <= 3; t++) {
    const ts = transporterStatus(t);
    for (const [k, nid] of Object.entries(ts)) {
      if (k === 'task_id') continue; // LINT field — read separately
      add(`ts.${t}.${k}`, nid);
    }
    const st = simTransporter(t);
    for (const [k, nid] of Object.entries(st)) {
      if (k === 'runninTask_id') continue; // LINT field — read separately
      add(`sim.${t}.${k}`, nid);
    }
  }

  // Units + Batches (1..10)
  // NOTE: batch.start_time is LINT — skip it
  for (let u = 1; u <= 10; u++) {
    const un = unit(u);
    for (const [k, nid] of Object.entries(un)) add(`unit.${u}.${k}`, nid);
    const bn = batch(u);
    for (const [k, nid] of Object.entries(bn)) {
      if (k === 'start_time') continue; // LINT field
      add(`batch.${u}.${k}`, nid);
    }
  }

  // Task queues — read from sim_ui snapshot (stable copy)
  // NOTE: start_time, finish_time are LINT — skip them
  for (let t = 1; t <= 3; t++) {
    add(`tq.${t}.count`, simTaskQueue(t).count);
    for (let q = 1; q <= 30; q++) {
      const tq = simTaskQueue(t)[`task_${q}`];
      for (const [k, nid] of Object.entries(tq)) {
        if (k === 'start_time' || k === 'finish_time') continue; // LINT fields
        add(`tq.${t}.${q}.${k}`, nid);
      }
    }
  }

  // DEP state
  for (const [k, nid] of Object.entries(DEP)) add(`dep.${k}`, nid);
  for (let w = 1; w <= 5; w++) add(`dep.waiting.${w}`, depWaiting(w));

  // UI snapshot scalars (wait status)
  for (const [k, nid] of Object.entries(SIM_UI)) add(`sim_ui.${k}`, nid);

  // Scheduler debug
  for (const [k, nid] of Object.entries(SCHED_DEBUG)) add(`sched.${k}`, nid);

  // Program CalTime snapshot per unit (from DbgProgCal)
  for (let u = 1; u <= 10; u++) add(`sched.prog_cal.${u}`, progCalDebug(u));

  // Manual task state (ManualTask[1..3])
  for (let t = 1; t <= 3; t++) {
    const mt = manualTaskRead(t);
    for (const [k, nid] of Object.entries(mt)) add(`mt.${t}.${k}`, nid);
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

/**
 * Movement times write targets (Move[tid])
 * PLC variable: GVL_JC_Scheduler.Move[1..3]
 * Station index: station_number - 100 (station 101 → index 1, max 30)
 * Times are INT ×10 = tenths of second
 */
function moveTimesWrite(tid) {
  const b = `Move[${tid}]`;
  const result = {};
  for (let idx = 1; idx <= 30; idx++) {
    result[`lift_${idx}`] = S(`${b}.LiftTime[${idx}]`);
    result[`sink_${idx}`] = S(`${b}.SinkTime[${idx}]`);
  }
  for (let from = 1; from <= 30; from++) {
    for (let to = 1; to <= 30; to++) {
      result[`travel_${from}_${to}`] = S(`${b}.Travel[${from}].ToTime[${to}]`);
    }
  }
  return result;
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
  simSchedule,
  simTaskQueue,
  META,
  DEP,
  depWaiting,
  SIM_UI,
  SCHED_DEBUG,
  EVENT,
  eventMsg,
  eventPayload,
  avoidStatus,
  progCalDebug,
  CMD,
  buildReadList,
  // Write helpers
  stationWrite,
  cfgWrite,
  unitWrite,
  batchWrite,
  programWrite,
  nttWrite,
  manualTaskWrite,
  manualTaskRead,
  moveTimesWrite,
};

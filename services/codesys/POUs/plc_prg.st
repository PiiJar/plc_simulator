(* ============================================================
   plc_prg.st — Main program (CODESYS / OPC UA)
   ============================================================
   Gateway communicates via OPC UA — reads/writes GVL variables
   directly. All multi-field writes are atomic (single OPC UA call).

   Gateway writes:
     g_station[], g_cfg[], g_unit[], g_batch[], g_program[],
     g_ntt[], g_cal[], g_avoid_status[], g_time_s,
     g_production_queue, g_event_ack_seq

   Gateway reads:
     g_transporter[], g_schedule[], g_task[], g_sim_trans[],
     g_move[], g_event, g_dep_wait_sched, g_sched_dbg_*,
     g_cal_active, g_cal[]

   Command interface (g_cmd_code / g_cmd_param):
     Gateway writes g_cmd_code + g_cmd_param via OPC UA.
     PLC processes when g_cmd_code <> 0, then clears it.
     2 = init       (param = station_count)
     3 = clear      (clear all config)
     8 = cal_ctrl   (param: 1=start, 2=calculate, 3=abort)
    12 = calc_move  (compute g_move from g_cal kinematics)
   ============================================================ *)

PROGRAM PLC_PRG
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MAX_STATIONS_PER_STEP : INT;
    MIN_StationIndex    : INT;
    MAX_StationIndex    : INT;
    MAX_Units           : INT;
    DEP_MAX_WAITING     : INT;
END_VAR

VAR_EXTERNAL
  (* --- Shared data arrays — written by Gateway via OPC UA --- *)
  g_station_count    : INT;
  g_station          : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc      : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_cfg              : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_transporter      : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_sim_trans        : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
  g_unit             : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_ntt              : ARRAY[1..MAX_Transporters] OF UDT_JC_NttTransporterType;
  g_batch            : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_program          : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_avoid_status     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF INT;
  g_move             : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_schedule         : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_task             : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  (* --- Departure Scheduler state --- *)
  g_dep_activated    : BOOL;
  g_dep_stable       : BOOL;
  g_dep_waiting_count : INT;
  g_dep_overlap      : UDT_JC_DepOverlapType;
  g_dep_pending      : UDT_JC_DepPendingWriteType;
  g_dep_waiting      : ARRAY[1..DEP_MAX_WAITING] OF INT;
  g_dep_wait_sched   : UDT_JC_TskScheduleType;
  g_dep_wait_unit    : INT;
  (* --- Scheduler Debug --- *)
  g_sched_dbg_tsk_phase : INT;
  g_sched_dbg_dep_phase : INT;
  g_sched_dbg_turn      : INT;
  g_conflict_resolved   : BOOL;
  g_sched_dbg_batch_cnt : INT;
  (* --- Calibration --- *)
  g_cal              : ARRAY[1..MAX_Transporters] OF UDT_JC_CalibrationType;
  g_cal_active       : BOOL;
  (* --- Production --- *)
  g_production_queue : INT;
  (* --- Time --- *)
  g_time_s           : LINT;
  (* --- Event queue --- *)
  g_event            : UDT_JC_EventQueueType;
  g_event_pending    : UDT_JC_EventMsgType;
  g_event_pending_valid : BOOL;
  g_event_ack_seq    : INT;
  (* --- OPC UA Command Interface --- *)
  g_cmd_code         : INT;
  g_cmd_param        : INT;
END_VAR

VAR
  init_done      : BOOL := FALSE;
  i              : INT;
  twa_calc       : TWA_FB_CalcLimits;
  clear_cfg      : SIM_FB_ClearConfig;
  cycle_count    : INT;
  main_sched     : STC_FB_MainScheduler;
  run_tasks      : SIM_FB_RunTasks;
  calibrate      : STC_FB_Calibrate;
  calc_move      : STC_FB_CalcMoveTimes;
  evt_queue      : STC_FB_EventQueue;
  cal_cmd        : INT := 0;
  cal_load_run   : BOOL := FALSE;
  (* Time self-increment *)
  time_cycle_cnt : INT := 0;
  last_time_s    : LINT := 0;
  (* Waiting batch at station 114 *)
  fb_wait_calc       : TSK_FB_CalcSchedule;
  dep_wait_114_unit  : INT := 0;
  dep_wait_114_last  : INT := 0;
  wait_i             : INT;
END_VAR

(* ============================================================
   COMMAND HANDLER — OPC UA (direct, no sequence handshake)
   Gateway writes g_cmd_code + g_cmd_param in one atomic OPC UA
   call. PLC processes when g_cmd_code <> 0 and clears it.
   ============================================================ *)
IF g_cmd_code <> 0 THEN

  IF g_cmd_code = 3 THEN
    (* ── Clear all config data ── *)
    clear_cfg();
    init_done := FALSE;
    g_station_count := 0;

  ELSIF g_cmd_code = 8 THEN
    (* ── Calibration control ── *)
    cal_cmd := g_cmd_param;

  ELSIF g_cmd_code = 12 THEN
    (* ── Compute g_move from loaded g_cal kinematic params ── *)
    cal_load_run := TRUE;

  ELSIF g_cmd_code = 2 THEN
    (* ── Finish init: all config already uploaded via OPC UA ── *)
    g_station_count := g_cmd_param;

    FOR i := 1 TO MAX_Transporters DO
      IF g_cfg[i].TaskArea[1].MinLift > 0 THEN
        g_transporter[i].IsActive := TRUE;
        g_transporter[i].Status := 3;  (* auto_idle *)
      ELSE
        g_transporter[i].IsActive := FALSE;
        g_transporter[i].Status := 0;  (* not_used *)
      END_IF;
      g_transporter[i].Phase := 0;
      g_sim_trans[i].ZStage := 0;
      g_sim_trans[i].XVelocity := 0;
      g_sim_trans[i].ZTimer := 0.0;
      g_transporter[i].XMinDriveLimit := g_cfg[i].DrivePosMin;
      g_transporter[i].XMaxDriveLimit := g_cfg[i].DrivePosMax;

      (* Start position: at own area minimum, z=0 *)
      g_transporter[i].XPosition := g_cfg[i].DrivePosMin;
      g_transporter[i].ZPosition := 0;
      g_transporter[i].CurrentStation := 0;
    END_FOR;

    init_done := TRUE;

    (* Build g_station_loc from g_unit[].location so SIM_FB_RunTasks
       can find units on stations via g_station_loc[stn].UnitId.
       Gateway writes g_unit[] but not g_station_loc[]. *)
    FOR i := 1 TO MAX_Units DO
      IF g_unit[i].location >= MIN_StationIndex
         AND g_unit[i].location <= MAX_StationIndex THEN
        g_station_loc[g_unit[i].location].UnitId     := i;
        g_station_loc[g_unit[i].location].ChangeTime  := g_time_s;
      END_IF;
    END_FOR;

    (* Init event queue *)
    g_event.Head := 1;
    g_event.NextSeq := 1;
    g_event.Count := 0;
  END_IF;

  g_cmd_code := 0;  (* Command processed — clear trigger *)
END_IF;

(* ============================================================
   MAIN TRANSPORT CYCLE — only runs when init_done
   ============================================================ *)
IF init_done THEN

  (* ── Compute g_move from loaded kinematic params (one-shot) ── *)
  calc_move(i_run := cal_load_run);
  IF cal_load_run THEN
    cal_load_run := FALSE;
  END_IF;

  (* ── Calculate transporter working areas (X-limits) every cycle ── *)
  twa_calc();

  (* ── Unix time self-increment ──
     Gateway writes g_time_s directly via OPC UA for sync.
     PLC self-increments +1 second every 50 cycles (50 × 20 ms = 1 s)
     when gateway hasn't updated. *)
  IF g_time_s <> last_time_s THEN
    (* Gateway wrote new time — accept and reset counter *)
    last_time_s := g_time_s;
    time_cycle_cnt := 0;
  ELSE
    time_cycle_cnt := time_cycle_cnt + 1;
    IF time_cycle_cnt >= 50 THEN
      g_time_s := g_time_s + LINT#1;
      last_time_s := g_time_s;
      time_cycle_cnt := 0;
    END_IF;
  END_IF;

  (* ── Execute transporter tasks (physics simulation) ── *)
  run_tasks(i_run := init_done);

  (* ── Calibration FB — issues test tasks, measures parameters ── *)
  calibrate(i_run := init_done, i_cmd := cal_cmd);
  cal_cmd := 0;
  g_cal_active := calibrate.o_active;

END_IF;  (* init_done *)

(* ── Main Scheduler (TSK + DEP alternating cycles) ──
   MUST run outside init_done block so that when init_done=FALSE
   (during RESET), MainScheduler's i_run=FALSE path executes,
   properly resetting internal state of both TSK and DEP FBs. *)
main_sched(i_run := init_done, i_time_s := g_time_s);

(* ── Event queue — always runs, not gated by init_done ── *)
evt_queue();

(* ── Cycle counter ── *)
cycle_count := cycle_count + 1;
IF cycle_count > 30000 THEN cycle_count := 0; END_IF;

(* ── WAITING BATCH AT STATION 114 — shortcut for UI ──
   Scan for NOT_PROCESSED unit at station 114 with valid program.
   Calculate schedule once when a new unit appears there. *)
dep_wait_114_unit := 0;
FOR wait_i := 1 TO 10 DO
  IF g_unit[wait_i].location = 114
     AND g_batch[wait_i].State = 0
     AND g_program[wait_i].ProgramId > 0
     AND g_batch[wait_i].ProgId = g_program[wait_i].ProgramId THEN
    dep_wait_114_unit := wait_i;
  END_IF;
END_FOR;

IF dep_wait_114_unit <> dep_wait_114_last THEN
  dep_wait_114_last := dep_wait_114_unit;
  IF dep_wait_114_unit > 0 THEN
    fb_wait_calc(i_unit := dep_wait_114_unit, i_trans := 1, i_time_s := g_time_s);
    g_dep_wait_sched := g_schedule[dep_wait_114_unit];
    g_dep_wait_unit  := dep_wait_114_unit;
    g_schedule[dep_wait_114_unit].StageCount := 0;
  ELSE
    g_dep_wait_unit := 0;
  END_IF;
END_IF;

END_PROGRAM

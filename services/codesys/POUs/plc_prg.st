(* ===========================================================================================
 *  PLC_PRG — Main program (CODESYS / OPC UA)
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Gateway communicates via OPC UA — reads/writes GVL variables.
 *
 *  Command interface (g_cmd_code / g_cmd_param):
 *  2 = init       (param = station_count)
 *  3 = clear      (clear all config)
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


PROGRAM PLC_PRG


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_STATIONS_PER_STEP   : INT;
    MIN_StationIndex        : INT;
    MAX_StationIndex        : INT;
    MAX_Units               : INT;
    DEP_MAX_WAITING         : INT;
END_VAR

VAR_EXTERNAL
  (* --- Shared data arrays — written by Gateway via OPC UA --- *)
  CountStations              : INT;
  Stations                 : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc             : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_cfg                     : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_transporter             : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_sim_trans               : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
  g_unit                    : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_ntt                     : ARRAY[1..MAX_Transporters] OF UDT_JC_NttTransporterType;
  g_batch                   : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_program                 : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_avoid_status            : ARRAY[MIN_StationIndex..MAX_StationIndex] OF INT;
  g_move                    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_schedule                : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_task                    : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  (* --- Departure Scheduler state --- *)
  g_dep_activated           : BOOL;
  g_tsk_stable              : BOOL;
  g_dep_waiting_count       : INT;
  g_dep_overlap             : UDT_JC_DepOverlapType;
  g_dep_pending             : UDT_JC_DepPendingWriteType;
  g_dep_waiting             : ARRAY[1..DEP_MAX_WAITING] OF INT;

  (* --- Scheduler Debug --- *)
  g_sched_dbg_tsk_phase     : INT;
  g_sched_dbg_dep_phase     : INT;
  (* --- UI snapshot --- *)
  g_sim_ui_schedule         : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_sim_ui_task             : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_sim_ui_wait_unit        : INT;
  g_sim_ui_wait_reason      : INT;
  g_sched_dbg_turn          : INT;
  g_conflict_resolved       : BOOL;
  g_sched_dbg_batch_cnt     : INT;
  (* --- Production --- *)
  (* --- Time --- *)
  g_time_s                  : LINT;
  g_time_100ms              : LINT;
  (* --- Event queue --- *)
  g_event                   : UDT_JC_EventQueueType;
  g_event_pending           : UDT_JC_EventMsgType;
  g_event_pending_valid     : BOOL;
  g_event_ack_seq           : INT;
  (* --- OPC UA Command Interface --- *)
  g_cmd_code                : INT;
  g_cmd_param               : INT;
END_VAR

VAR
  init_done                 : BOOL := FALSE;
  i                         : INT;
  twa_calc                  : TWA_FB_CalcLimits;
  clear_cfg                 : SIM_FB_ClearConfig;
  cycle_count               : INT;
  main_sched                : STC_FB_MainScheduler;
  run_tasks                 : SIM_FB_RunTasks;
  evt_queue                 : SIM_FB_EventQueue;
  (* Time from SysTime library *)
  now_ms                    : LINT := 0;
  (* UI snapshot edge detection *)
  prev_tsk_phase            : INT := 0;
  prev_dep_phase            : INT := 0;
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
    CountStations := 0;

  ELSIF g_cmd_code = 2 THEN
    (* ── Finish init: all config already uploaded via OPC UA ── *)
    CountStations := g_cmd_param;

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
      g_sim_trans[i].IdleStartTime := g_time_s;  (* init move-away timer *)
      g_transporter[i].XMinDriveLimit := g_cfg[i].DrivePosMin;
      g_transporter[i].XMaxDriveLimit := g_cfg[i].DrivePosMax;

      (* Start position: at own area minimum, z=0 *)
      g_transporter[i].XPosition := g_cfg[i].DrivePosMin;
      g_transporter[i].ZPosition := 0;
      g_transporter[i].CurrentStation := 0;
    END_FOR;

    init_done := TRUE;

    (* Calculate time offset: real unix time - uptime *)
    g_time_offset := g_time_sync - UDINT_TO_LINT(SysTimeGetMs()) / 1000;

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

  (* ── Calculate transporter working areas (X-limits) every cycle ── *)
  twa_calc();

  (* ── System time: uptime + offset = real unix seconds ── *)
  now_ms := UDINT_TO_LINT(SysTimeGetMs());
  g_time_s := g_time_offset + now_ms / 1000;        (* seconds, unix epoch *)
  g_time_100ms := g_time_offset * 10 + now_ms / 100; (* 0.1s ticks, unix epoch *)

  (* ── Execute transporter tasks (physics simulation) ── *)
  run_tasks(i_run := init_done);

END_IF;  (* init_done *)

(* ── Main Scheduler (TSK + DEP alternating cycles) ──
   MUST run outside init_done block so that when init_done=FALSE
   (during RESET), MainScheduler's i_run=FALSE path executes,
   properly resetting internal state of both TSK and DEP FBs. *)
main_sched(i_run := init_done, i_time_s := g_time_s);

(* ── UI schedule snapshot — copy stable data for gateway reads ── *)
IF g_sched_dbg_tsk_phase = 10000 AND prev_tsk_phase <> 10000 THEN
  (* TSK reached READY — snapshot active batch schedules + tasks *)
  g_sim_ui_schedule := g_schedule;
  g_sim_ui_task     := g_task;
END_IF;
IF g_sched_dbg_dep_phase = 8000 AND prev_dep_phase <> 8000 THEN
  (* DEP activated a waiting batch — clear wait status *)
  g_sim_ui_wait_unit   := 0;
  g_sim_ui_wait_reason := 0;
END_IF;
IF g_sched_dbg_dep_phase = 9000 AND prev_dep_phase <> 9000 THEN
  (* DEP rejected a waiting batch — record which unit and why *)
  g_sim_ui_wait_unit   := g_sched_dbg_dep_cur_wait_unit;
  g_sim_ui_wait_reason := 1;  (* TODO: differentiate reject reasons when DEP exposes them *)
END_IF;
prev_tsk_phase := g_sched_dbg_tsk_phase;
prev_dep_phase := g_sched_dbg_dep_phase;

(* ── Event queue — always runs, not gated by init_done ── *)
evt_queue();

(* ── Cycle counter ── *)
cycle_count := cycle_count + 1;
  IF cycle_count > 30000 THEN cycle_count := 0; END_IF;

END_PROGRAM

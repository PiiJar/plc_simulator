(* ===========================================================================================
 *  FB_SIM_MainCycle — Simulator main cycle (all SIM-specific logic)
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 08.04.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Encapsulates everything that is simulation-only and NOT vNeeded in production:
 *    - OPC UA command handler (init / clear)
 *    - System time calculation (g_time_s via offset from gateway sync)
 *    - TWA calculation
 *    - Physics simulation (delta_t + FB_SIM_RunTasks)
 *    - UI schedule snapshot for gateway
 *    - Event queue processing
 *
 *  In production PLC_PRG, this FB is removed entirely.
 *  PLC_PRG only needs: time from real PLC clock, TWA, MainScheduler.
 * ========================================================================================= *)


FUNCTION_BLOCK FB_SIM_MainCycle


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_STATIONS_PER_STEP   : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    MAX_UNITS               : INT;
    DEP_MAX_WAITING         : INT;
END_VAR

VAR_EXTERNAL
  CountStations             : INT;
  Stations                  : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  g_station_occupancy       : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters              : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  g_sim_trans               : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  g_ntt                     : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms         : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_avoid_status            : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  g_schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_task                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  g_dep_activated           : BOOL;
  g_tsk_stable              : BOOL;
  g_dep_waiting_count       : INT;
  g_dep_overlap             : UDT_JC_DepOverlapType;
  g_dep_pending             : UDT_JC_DepPendingWriteType;
  g_dep_waiting             : ARRAY[1..DEP_MAX_WAITING] OF INT;
  g_sched_dbg_tsk_phase     : INT;
  g_sched_dbg_dep_phase     : INT;
  g_sim_ui_schedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_sim_ui_task             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  g_sim_ui_wait_unit        : INT;
  g_sim_ui_wait_reason      : INT;
  g_sched_dbg_turn          : INT;
  g_conflict_resolved       : BOOL;
  g_sched_dbg_batch_cnt     : INT;
  g_time_s                  : LINT;
  g_time_100ms              : LINT;
  g_time_offset             : LINT;
  g_time_sync               : LINT;
  g_event                   : UDT_JC_EventQueueType;
  g_event_pending           : UDT_JC_EventMsgType;
  g_event_pending_valid     : BOOL;
  g_event_ack_seq           : INT;
  g_cmd_code                : INT;
  g_cmd_param               : INT;
  g_sched_dbg_dep_cur_wait_unit : INT;
END_VAR

VAR_OUTPUT
  oInitDone               : BOOL;
END_VAR

VAR
  vInitDone                 : BOOL := FALSE;
  i                         : INT;
  vFB_ClearConfig                 : FB_SIM_ClearConfig;
  vFB_RunTasks                 : FB_SIM_RunTasks;
  vFB_EventQueue                 : FB_SIM_EventQueue;
  vNowMs                    : LINT := 0;
  vPrevMs                   : UDINT := 0;
  vSimDeltaT               : REAL := 0.02;
  vPrevTskPhase            : INT := 0;
  vPrevDepPhase            : INT := 0;
END_VAR


(* ============================================================
   COMMAND HANDLER — OPC UA (direct, no sequence handshake)
   Gateway writes g_cmd_code + g_cmd_param in one atomic OPC UA
   call. PLC processes when g_cmd_code <> 0 and clears it.
   ============================================================ *)
IF g_cmd_code <> 0 THEN

  IF g_cmd_code = 3 THEN
    (* ── Clear all config data ── *)
    vFB_ClearConfig();
    vInitDone := FALSE;
    CountStations := 0;

  ELSIF g_cmd_code = 2 THEN
    (* ── Finish init: all config vAlready uploaded via OPC UA ── *)
    CountStations := g_cmd_param;

    FOR i := 1 TO MAX_TRANSPORTERS DO
      IF Transporters[i].TaskArea[1].MinLift > 0 THEN
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
      g_transporter[i].IdleStartTime := g_time_s;
      g_transporter[i].XMinDriveLimit := Transporters[i].DrivePosMin;
      g_transporter[i].XMaxDriveLimit := Transporters[i].DrivePosMax;

      (* Start position: at own vArea minimum, z=0 *)
      g_transporter[i].XPosition := Transporters[i].DrivePosMin;
      g_transporter[i].ZPosition := 0;
      g_transporter[i].CurrentStation := 0;
    END_FOR;

    vInitDone := TRUE;

    (* Calculate time offset: real unix time - uptime *)
    g_time_offset := g_time_sync - UDINT_TO_LINT(SysTimeGetMs()) / 1000;

    (* Build g_station_occupancy from g_unit[].Location so FB_SIM_RunTasks
       can find units on stations via g_station_occupancy[stn].UnitId.
       Gateway writes g_unit[] but not g_station_occupancy[]. *)
    FOR i := 1 TO MAX_UNITS DO
      IF g_unit[i].Location >= MIN_STATION_INDEX
         AND g_unit[i].Location <= MAX_STATION_INDEX THEN
        g_station_occupancy[g_unit[i].Location].UnitId     := i;
        g_station_occupancy[g_unit[i].Location].ChangeTime  := g_time_s;
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
   MAIN TRANSPORT CYCLE — only runs when vInitDone
   ============================================================ *)
IF vInitDone THEN

  (* ── System time: uptime + offset = real unix seconds ── *)
  vNowMs := UDINT_TO_LINT(SysTimeGetMs());
  g_time_s := g_time_offset + vNowMs / 1000;        (* seconds, unix epoch *)
  g_time_100ms := g_time_offset * 10 + vNowMs / 100; (* 0.1s ticks, unix epoch *)

  (* ── Actual cycle time for physics simulation ── *)
  IF vPrevMs > 0 THEN
    vSimDeltaT := UDINT_TO_REAL(LINT_TO_UDINT(vNowMs) - vPrevMs) / 1000.0;
  END_IF;
  vPrevMs := LINT_TO_UDINT(vNowMs);

  (* ── Execute transporter tasks (physics simulation) ── *)
  vFB_RunTasks(iRun := vInitDone, iDeltaT := vSimDeltaT);

END_IF;  (* vInitDone *)

oInitDone := vInitDone;

(* ── UI schedule snapshot — copy stable data for gateway reads ── *)
IF g_sched_dbg_tsk_phase = 10000 AND vPrevTskPhase <> 10000 THEN
  g_sim_ui_schedule := g_schedule;
  g_sim_ui_task     := g_task;
END_IF;
IF g_sched_dbg_dep_phase = 8000 AND vPrevDepPhase <> 8000 THEN
  g_sim_ui_wait_unit   := 0;
  g_sim_ui_wait_reason := 0;
END_IF;
IF g_sched_dbg_dep_phase = 9000 AND vPrevDepPhase <> 9000 THEN
  g_sim_ui_wait_unit   := g_sched_dbg_dep_cur_wait_unit;
  g_sim_ui_wait_reason := 1;
END_IF;
vPrevTskPhase := g_sched_dbg_tsk_phase;
vPrevDepPhase := g_sched_dbg_dep_phase;

(* ── Event queue — always runs, not gated by vInitDone ── *)
vFB_EventQueue();

END_FUNCTION_BLOCK

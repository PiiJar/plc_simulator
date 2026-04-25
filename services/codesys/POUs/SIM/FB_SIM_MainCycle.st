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
 *    - System time calculation (gTimeS via offset from gateway sync)
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
    MAX_TRANSPORTERS      : INT;
    MAX_STATIONS_PER_STEP : INT;
    MIN_STATION_INDEX     : INT;
    MAX_STATION_INDEX     : INT;
    MAX_UNITS             : INT;
    DEP_MAX_WAITING       : INT;
END_VAR

VAR_EXTERNAL
  CountStations           : INT;
  Stations                : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  gStationOccupancy       : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters            : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  gTransporter            : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  gSimTrans               : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  gUnit                   : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  gNtt                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  gBatch                  : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms       : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gAvoidStatus            : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  gMove                   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  gSchedule               : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gTask                   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  gDepActivated           : BOOL;
  gTskStable              : BOOL;
  gDepWaitingCount        : INT;
  gDepOverlap             : UDT_JC_DepOverlapType;
  gDepPending             : UDT_JC_DepPendingWriteType;
  gDepWaiting             : ARRAY[1..DEP_MAX_WAITING] OF INT;
  gSchedDbgTskPhase       : INT;
  gSchedDbgDepPhase       : INT;
  gSimUiSchedule          : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gSimUiTask              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  gSimUiWaitUnit          : INT;
  gSimUiWaitReason        : INT;
  gSchedDbgTurn           : INT;
  gConflictResolved       : BOOL;
  gSchedDbgBatchCnt       : INT;
  gTimeS                  : LINT;
  gTime100ms              : LINT;
  gTimeOffset             : LINT;
  gTimeSync               : LINT;
  gEvent                  : UDT_JC_EventQueueType;
  gEventPending           : UDT_JC_EventMsgType;
  gEventPendingValid      : BOOL;
  gEventAckSeq            : INT;
  gCmdCode                : INT;
  gCmdParam               : INT;
  gSchedDbgDepCurWaitUnit : INT;
END_VAR

VAR_OUTPUT
  oInitDone : BOOL;
END_VAR

VAR
  vInitDone       : BOOL := FALSE;
  i               : INT;
  vFB_ClearConfig : FB_SIM_ClearConfig;
  vFB_RunTasks    : FB_SIM_RunTasks;
  vFB_EventQueue  : FB_SIM_EventQueue;
  vNowMs          : LINT := 0;
  vPrevMs         : UDINT := 0;
  vSimDeltaT      : REAL := 0.02;
  vPrevTskPhase   : INT := 0;
  vPrevDepPhase   : INT := 0;
END_VAR


(* ============================================================
   COMMAND HANDLER — OPC UA (direct, no sequence handshake)
   Gateway writes gCmdCode + gCmdParam in one atomic OPC UA
   call. PLC processes when gCmdCode <> 0 and clears it.
   ============================================================ *)
IF gCmdCode <> 0 THEN

  IF gCmdCode = 3 THEN
    (* ── Clear all config data ── *)
    vFB_ClearConfig();
    vInitDone := FALSE;
    CountStations := 0;

  ELSIF gCmdCode = 2 THEN
    (* ── Finish init: all config vAlready uploaded via OPC UA ── *)
    CountStations := gCmdParam;

    FOR i := 1 TO MAX_TRANSPORTERS DO
      IF Transporters[i].TaskArea[1].MinLift > 0 THEN
        gTransporter[i].IsActive := TRUE;
        gTransporter[i].Status := 3;  (* auto_idle *)
      ELSE
        gTransporter[i].IsActive := FALSE;
        gTransporter[i].Status := 0;  (* not_used *)
      END_IF;
      gTransporter[i].Phase := 0;
      gSimTrans[i].ZStage := 0;
      gSimTrans[i].XVelocity := 0;
      gSimTrans[i].ZTimer := 0.0;
      gTransporter[i].IdleStartTime := gTimeS;
      gTransporter[i].XMinDriveLimit := Transporters[i].DrivePosMin;
      gTransporter[i].XMaxDriveLimit := Transporters[i].DrivePosMax;

      (* Start position: at own vArea minimum, z=0 *)
      gTransporter[i].XPosition := Transporters[i].DrivePosMin;
      gTransporter[i].ZPosition := 0;
      gTransporter[i].CurrentStation := 0;
    END_FOR;

    vInitDone := TRUE;

    (* Calculate time offset: real unix time - uptime *)
    gTimeOffset := gTimeSync - UDINT_TO_LINT(SysTimeGetMs()) / 1000;

    (* Build gStationOccupancy from gUnit[].Location so FB_SIM_RunTasks
       can find units on stations via gStationOccupancy[stn].UnitId.
       Gateway writes gUnit[] but not gStationOccupancy[]. *)
    FOR i := 1 TO MAX_UNITS DO
      IF gUnit[i].Location >= MIN_STATION_INDEX
         AND gUnit[i].Location <= MAX_STATION_INDEX THEN
        gStationOccupancy[gUnit[i].Location].UnitId     := i;
        gStationOccupancy[gUnit[i].Location].ChangeTime  := gTimeS;
      END_IF;
    END_FOR;

    (* Init event queue *)
    gEvent.Head := 1;
    gEvent.NextSeq := 1;
    gEvent.Count := 0;
  END_IF;

  gCmdCode := 0;  (* Command processed — clear trigger *)
END_IF;

(* ============================================================
   MAIN TRANSPORT CYCLE — only runs when vInitDone
   ============================================================ *)
IF vInitDone THEN

  (* ── System time: uptime + offset = real unix seconds ── *)
  vNowMs := UDINT_TO_LINT(SysTimeGetMs());
  gTimeS := gTimeOffset + vNowMs / 1000;        (* seconds, unix epoch *)
  gTime100ms := gTimeOffset * 10 + vNowMs / 100; (* 0.1s ticks, unix epoch *)

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
IF gSchedDbgTskPhase = 10000 AND vPrevTskPhase <> 10000 THEN
  gSimUiSchedule := gSchedule;
  gSimUiTask     := gTask;
END_IF;
IF gSchedDbgDepPhase = 8000 AND vPrevDepPhase <> 8000 THEN
  gSimUiWaitUnit   := 0;
  gSimUiWaitReason := 0;
END_IF;
IF gSchedDbgDepPhase = 9000 AND vPrevDepPhase <> 9000 THEN
  gSimUiWaitUnit   := gSchedDbgDepCurWaitUnit;
  gSimUiWaitReason := 1;
END_IF;
vPrevTskPhase := gSchedDbgTskPhase;
vPrevDepPhase := gSchedDbgDepPhase;

(* ── Event queue — always runs, not gated by vInitDone ── *)
vFB_EventQueue();

END_FUNCTION_BLOCK

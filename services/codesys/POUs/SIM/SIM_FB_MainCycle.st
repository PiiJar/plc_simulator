(* ===========================================================================================
 *  SIM_FB_MainCycle — Simulator main cycle (all SIM-specific logic)
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 08.04.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Encapsulates everything that is simulation-only and NOT needed in production:
 *    - OPC UA command handler (init / clear)
 *    - System time calculation (TimeS via offset from gateway sync)
 *    - TWA calculation
 *    - Physics simulation (delta_t + SIM_FB_RunTasks)
 *    - UI schedule snapshot for gateway
 *    - Event queue processing
 *
 *  In production PLC_PRG, this FB is removed entirely.
 *  PLC_PRG only needs: time from real PLC clock, TWA, MainScheduler.
 * ========================================================================================= *)


FUNCTION_BLOCK SIM_FB_MainCycle


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
  StationOccupancy       : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters              : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  SimTrans               : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  Unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Ntt                     : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  Batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms         : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  AvoidStatus            : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  Schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  Task                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  DepActivated           : BOOL;
  TskStable              : BOOL;
  DepWaitingCount       : INT;
  DepOverlap             : UDT_JC_DepOverlapType;
  DepPending             : UDT_JC_DepPendingWriteType;
  DepWaiting             : ARRAY[1..DEP_MAX_WAITING] OF INT;
  SchedDbgTskPhase     : INT;
  SchedDbgDepPhase     : INT;
  SimUiSchedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  SimUiTask             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  SimUiWaitUnit        : INT;
  SimUiWaitReason      : INT;
  SchedDbgTurn          : INT;
  ConflictResolved       : BOOL;
  SchedDbgBatchCnt     : INT;
  TimeS                  : LINT;
  Time100ms              : LINT;
  TimeOffset             : LINT;
  TimeSync               : LINT;
  Event                   : UDT_JC_EventQueueType;
  EventPending           : UDT_JC_EventMsgType;
  EventPendingValid     : BOOL;
  EventAckSeq           : INT;
  CmdCode                : INT;
  CmdParam               : INT;
  SchedDbgDepCurWaitUnit : INT;
END_VAR

VAR_OUTPUT
  oInitDone               : BOOL;
END_VAR

VAR
  vInitDone                 : BOOL := FALSE;
  vI                         : INT;
  vFB_ClearCfg                 : SIM_FB_ClearConfig;
  vFB_RunTasks                 : SIM_FB_RunTasks;
  vFB_EvtQueue                 : SIM_FB_EventQueue;
  vNowMs                    : LINT := 0;
  vPrevMs                   : UDINT := 0;
  vSimDeltaT               : REAL := 0.02;
  vPrevTskPhase            : INT := 0;
  vPrevDepPhase            : INT := 0;
END_VAR


(* ============================================================
   COMMAND HANDLER — OPC UA (direct, no sequence handshake)
   Gateway writes CmdCode + CmdParam in one atomic OPC UA
   call. PLC processes when CmdCode <> 0 and clears it.
   ============================================================ *)
IF CmdCode <> 0 THEN

  IF CmdCode = 3 THEN
    (* ── Clear all config data ── *)
    vFB_ClearCfg();
    vInitDone := FALSE;
    CountStations := 0;

  ELSIF CmdCode = 2 THEN
    (* ── Finish init: all config already uploaded via OPC UA ── *)
    CountStations := CmdParam;

    FOR vI := 1 TO MAX_TRANSPORTERS DO
      IF Transporters[vI].TaskArea[1].MinLift > 0 THEN
        TransporterStatus[vI].IsActive := TRUE;
        TransporterStatus[vI].Status := 3;  (* auto_idle *)
      ELSE
        TransporterStatus[vI].IsActive := FALSE;
        TransporterStatus[vI].Status := 0;  (* not_used *)
      END_IF;
      TransporterStatus[vI].Phase := 0;
      SimTrans[vI].ZStage := 0;
      SimTrans[vI].XVelocity := 0;
      SimTrans[vI].ZTimer := 0.0;
      TransporterStatus[vI].IdleStartTime := TimeS;
      TransporterStatus[vI].XMinDriveLimit := Transporters[vI].DrivePosMin;
      TransporterStatus[vI].XMaxDriveLimit := Transporters[vI].DrivePosMax;

      (* Start position: at own area minimum, z=0 *)
      TransporterStatus[vI].XPosition := Transporters[vI].DrivePosMin;
      TransporterStatus[vI].ZPosition := 0;
      TransporterStatus[vI].CurrentStation := 0;
    END_FOR;

    vInitDone := TRUE;

    (* Calculate time offset: real unix time - uptime *)
    TimeOffset := TimeSync - UDINT_TO_LINT(SysTimeGetMs()) / 1000;

    (* Build StationOccupancy from Unit[].location so SIM_FB_RunTasks
       can find units on stations via StationOccupancy[stn].UnitId.
       Gateway writes Unit[] but not StationOccupancy[]. *)
    FOR vI := 1 TO MAX_UNITS DO
      IF Unit[vI].location >= MIN_STATION_INDEX
         AND Unit[vI].location <= MAX_STATION_INDEX THEN
        StationOccupancy[Unit[vI].location].UnitId     := vI;
        StationOccupancy[Unit[vI].location].ChangeTime  := TimeS;
      END_IF;
    END_FOR;

    (* Init event queue *)
    Event.Head := 1;
    Event.NextSeq := 1;
    Event.Count := 0;
  END_IF;

  CmdCode := 0;  (* Command processed — clear trigger *)
END_IF;

(* ============================================================
   MAIN TRANSPORT CYCLE — only runs when vInitDone
   ============================================================ *)
IF vInitDone THEN

  (* ── System time: uptime + offset = real unix seconds ── *)
  vNowMs := UDINT_TO_LINT(SysTimeGetMs());
  TimeS := TimeOffset + vNowMs / 1000;        (* seconds, unix epoch *)
  Time100ms := TimeOffset * 10 + vNowMs / 100; (* 0.1s ticks, unix epoch *)

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
IF SchedDbgTskPhase = 10000 AND vPrevTskPhase <> 10000 THEN
  SimUiSchedule := Schedule;
  SimUiTask     := Task;
END_IF;
IF SchedDbgDepPhase = 8000 AND vPrevDepPhase <> 8000 THEN
  SimUiWaitUnit   := 0;
  SimUiWaitReason := 0;
END_IF;
IF SchedDbgDepPhase = 9000 AND vPrevDepPhase <> 9000 THEN
  SimUiWaitUnit   := SchedDbgDepCurWaitUnit;
  SimUiWaitReason := 1;
END_IF;
vPrevTskPhase := SchedDbgTskPhase;
vPrevDepPhase := SchedDbgDepPhase;

(* ── Event queue — always runs, not gated by vInitDone ── *)
vFB_EvtQueue();

END_FUNCTION_BLOCK

(* ============================================================
   FB_SIM_ClearConfig — Clear all PLC configuration data

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Called by PLC_PRG when Gateway sends cmd=3 (clear_all).
   Zeroes out all stations, transporter configs, transporter
   states and units so the PLC is ready for fresh config upload.
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION_BLOCK FB_SIM_ClearConfig
VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS      : INT;
    MAX_STATIONS_PER_STEP : INT;
    MAX_STEPS_PER_PROGRAM : INT;
    MAX_TASK_QUEUE        : INT;
    MIN_STATION_INDEX     : INT;
    MAX_STATION_INDEX     : INT;
    MAX_UNITS             : INT;
    DEP_MAX_WAITING       : INT;
    NOT_PROCESSED         : INT;
END_VAR

VAR_EXTERNAL
  CountStations     : INT;
  Stations          : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  gStationOccupancy : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters      : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  gTransporter      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  gSimTrans         : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  gDispatchedTask   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
  gUnit             : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  gNtt              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  gBatch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gAvoidStatus      : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  gSchedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gTask             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  gSimUiSchedule    : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gSimUiTask        : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  gSimUiWaitUnit    : INT;
  gSimUiWaitReason  : INT;
  gDepPending       : UDT_JC_DepPendingWriteType;
  gDepActivated     : BOOL;
  gTskStable        : BOOL;
  gDepWaitingCount  : INT;
  gDepWaiting       : ARRAY[1..DEP_MAX_WAITING] OF INT;
END_VAR
VAR
  i : INT;
  j : INT;
  k : INT;
END_VAR

(* --- Clear all stations --- *)
FOR i := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
  Stations[i].TankId       := 0;
  Stations[i].IsInUse       := FALSE;
  Stations[i].XPosition    := 0;
  Stations[i].YPosition    := 0;
  Stations[i].ZPosition    := 0;
  Stations[i].DryWet          := 0;
  Stations[i].StationType     := 0;
  Stations[i].DrippingTime := 0;
  Stations[i].DeviceDelay  := 0;
END_FOR;

(* --- Clear all vLocation tracking (transporters 1..MAX_TRANSPORTERS + stations MIN..MAX) --- *)
FOR i := 1 TO MAX_STATION_INDEX DO
  gStationOccupancy[i].UnitId     := 0;
  gStationOccupancy[i].ChangeTime := 0;
END_FOR;
CountStations := 0;

(* --- Clear all transporter configs --- *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  Transporters[i].DrivePosMin   := 0;
  Transporters[i].DrivePosMax   := 0;
  Transporters[i].YMinDriveLimit   := 0;
  Transporters[i].YMaxDriveLimit   := 0;
  Transporters[i].CollisionWidth    := 0;
  Transporters[i].AvoidanceWidth    := 0;
  Transporters[i].Acceleration_X     := 0;
  Transporters[i].Deceleration_X     := 0;
  Transporters[i].SpeedMax_X    := 0;
  Transporters[i].ZPosDown    := 0;
  Transporters[i].ZPosSlowUp := 0;
  Transporters[i].ZPosSlowDown := 0;
  Transporters[i].ZPosSlowEnd := 0;
  Transporters[i].SpeedLiftSlow_Z   := 0;
  Transporters[i].SpeedLiftFast_Z   := 0;
  Transporters[i].DripTrayDelay  := 0;
  FOR j := 1 TO 4 DO
    Transporters[i].TaskArea[j].MinLift := 0;
    Transporters[i].TaskArea[j].MaxLift := 0;
    Transporters[i].TaskArea[j].MinSink := 0;
    Transporters[i].TaskArea[j].MaxSink := 0;
  END_FOR;
END_FOR;

(* --- Clear avoid status --- *)
FOR i := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
  gAvoidStatus[i] := 0;
END_FOR;

(* --- Clear all transporter states --- *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  gTransporter[i].IsActive          := FALSE;
  gTransporter[i].Status          := 0;
  gTransporter[i].Phase           := 0;
  gTransporter[i].TaskId         := 0;
  gTransporter[i].LiftStationTarget    := 0;
  gTransporter[i].SinkStationTarget    := 0;
  gTransporter[i].DrippingTime   := 0;
  gTransporter[i].TaskRemainingTime  := 0;
  gTransporter[i].CurrentStation := 0;
  gTransporter[i].XFinalTarget  := 0;
  gTransporter[i].XDriveTarget  := 0;
  gTransporter[i].YFinalTarget  := 0;
  gTransporter[i].YDriveTarget  := 0;
  gTransporter[i].XPosition            := 0;
  gTransporter[i].YPosition            := 0;
  gTransporter[i].ZPosition            := 0;
  gSimTrans[i].XVelocity           := 0;
  gSimTrans[i].ZStage         := 0;
  gSimTrans[i].ZTimer       := 0.0;
  gTransporter[i].IdleStartTime := gTimeS;  (* prevent spurious move-away after clear *)
  gDispatchedTask[i].Active := FALSE;
  gTransporter[i].XMinDriveLimit     := 0;
  gTransporter[i].XMaxDriveLimit     := 0;
END_FOR;

(* --- Clear all units --- *)
FOR i := 1 TO MAX_UNITS DO
  gUnit[i].Location := 0;
  gUnit[i].Status   := 0;
  gUnit[i].Target   := 0;
END_FOR;

(* --- Clear NTT destinations --- *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  FOR j := 1 TO 8 DO
    gNtt[i].Target[j].StationCount := 0;
    gNtt[i].Target[j].FallbackCount := 0;
    FOR k := 1 TO MAX_STATIONS_PER_STEP DO
      gNtt[i].Target[j].Stations[k] := 0;
      gNtt[i].Target[j].FallbackStations[k] := 0;
    END_FOR;
  END_FOR;
END_FOR;

(* --- Clear all batches --- *)
FOR i := 1 TO MAX_UNITS DO
  gBatch[i].BatchCode  := 0;
  gBatch[i].State       := 0;
  gBatch[i].ProgId     := 0;
  gBatch[i].CurStage   := 0;
  gBatch[i].MinTime    := 0;
  gBatch[i].MaxTime    := 0;
  gBatch[i].CalTime    := 0;
  gBatch[i].StartTime  := LINT#0;
END_FOR;

(* --- Clear all treatment programs --- *)
FOR i := 1 TO MAX_UNITS DO
  TreatmentPrograms[i].ProgramId := 0;
  TreatmentPrograms[i].ProgramName := '';
  TreatmentPrograms[i].StepCount := 0;
  FOR j := 0 TO MAX_STEPS_PER_PROGRAM DO
    FOR k := 0 TO 4 DO
      TreatmentPrograms[i].Steps[j].Stations[k] := 0;
    END_FOR;
    TreatmentPrograms[i].Steps[j].StationCount := 0;
    TreatmentPrograms[i].Steps[j].MinTime := 0;
    TreatmentPrograms[i].Steps[j].MaxTime := 0;
    TreatmentPrograms[i].Steps[j].CalTime := 0;
  END_FOR;
END_FOR;

(* --- Clear all schedules (gSchedule) --- *)
FOR i := 1 TO MAX_UNITS DO
  gSchedule[i].StageCount := 0;
  FOR j := 0 TO MAX_STEPS_PER_PROGRAM DO
    gSchedule[i].Stages[j].Station       := 0;
    gSchedule[i].Stages[j].EntryTime    := 0;
    gSchedule[i].Stages[j].ExitTime     := 0;
    gSchedule[i].Stages[j].MinTime      := 0;
    gSchedule[i].Stages[j].CalcTime     := 0;
    gSchedule[i].Stages[j].MaxTime      := 0;
    gSchedule[i].Stages[j].TransferTime := 0;
  END_FOR;
END_FOR;

(* --- Clear all task queues (gTask) --- *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  gTask[i].Count := 0;
  FOR j := 1 TO MAX_TASK_QUEUE DO
    gTask[i].Queue[j].Unit         := 0;
    gTask[i].Queue[j].Stage        := 0;
    gTask[i].Queue[j].LiftStationTarget := 0;
    gTask[i].Queue[j].SinkStationTarget := 0;
    gTask[i].Queue[j].StartTime   := 0;
    gTask[i].Queue[j].FinishTime  := 0;
    gTask[i].Queue[j].CalcTime    := 0;
    gTask[i].Queue[j].MinTime     := 0;
    gTask[i].Queue[j].MaxTime     := 0;
  END_FOR;
END_FOR;

(* --- Clear UI snapshot --- *)
FOR i := 1 TO MAX_UNITS DO
  gSimUiSchedule[i].StageCount := 0;
END_FOR;
FOR i := 1 TO MAX_TRANSPORTERS DO
  gSimUiTask[i].Count := 0;
END_FOR;
gSimUiWaitUnit := 0;
gSimUiWaitReason := 0;

(* --- Clear departure pending write --- *)
gDepPending.Valid := FALSE;
gDepPending.BatchUnit  := 0;
gDepPending.BatchStage := 0;
gDepPending.BatchState := NOT_PROCESSED;

(* --- Clear departure scheduler state (previously missing) --- *)
gDepActivated     := FALSE;
gTskStable        := TRUE;   (* JS: tasksStableFlag starts true on empty line *)
gDepWaitingCount := 0;
FOR i := 1 TO 5 DO
  gDepWaiting[i] := 0;
END_FOR;

END_FUNCTION_BLOCK

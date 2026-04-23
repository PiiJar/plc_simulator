(* ============================================================
   SIM_FB_ClearConfig — Clear all PLC configuration data

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

FUNCTION_BLOCK SIM_FB_ClearConfig
VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS    : INT;
    MAX_STATIONS_PER_STEP       : INT;
    MAX_STEPS_PER_PROGRAM       : INT;
    MAX_TASK_QUEUE      : INT;
    MIN_STATION_INDEX : INT;
    MAX_STATION_INDEX   : INT;
    MAX_UNITS           : INT;
    DEP_MAX_WAITING     : INT;
    NOT_PROCESSED       : INT;
END_VAR

VAR_EXTERNAL
  CountStations       : INT;
  Stations         : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  StationOccupancy     : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters              : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  TransporterStatus      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  SimTrans        : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  DispatchedTask  : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
  Unit            : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Ntt             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  Batch          : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms         : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  AvoidStatus     : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  Schedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  Task             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  SimUiSchedule  : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  SimUiTask      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  SimUiWaitUnit : INT;
  SimUiWaitReason : INT;
  DepPending      : UDT_JC_DepPendingWriteType;
  DepActivated    : BOOL;
  TskStable       : BOOL;
  DepWaitingCount : INT;
  DepWaiting       : ARRAY[1..DEP_MAX_WAITING] OF INT;
END_VAR
VAR
  vI : INT;
  vJ : INT;
  vK : INT;
END_VAR

(* --- Clear all stations --- *)
FOR vI := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
  Stations[vI].TankId       := 0;
  Stations[vI].IsInUse       := FALSE;
  Stations[vI].XPosition    := 0;
  Stations[vI].YPosition    := 0;
  Stations[vI].ZPosition    := 0;
  Stations[vI].DryWet          := 0;
  Stations[vI].StationType     := 0;
  Stations[vI].DrippingTime := 0;
  Stations[vI].DeviceDelay  := 0;
END_FOR;

(* --- Clear all location tracking (transporters 1..MAX_TRANSPORTERS + stations MIN..MAX) --- *)
FOR vI := 1 TO MAX_STATION_INDEX DO
  StationOccupancy[vI].UnitId     := 0;
  StationOccupancy[vI].ChangeTime := 0;
END_FOR;
CountStations := 0;

(* --- Clear all transporter configs --- *)
FOR vI := 1 TO MAX_TRANSPORTERS DO
  Transporters[vI].DrivePosMin   := 0;
  Transporters[vI].DrivePosMax   := 0;
  Transporters[vI].YMinDriveLimit   := 0;
  Transporters[vI].YMaxDriveLimit   := 0;
  Transporters[vI].CollisionWidth    := 0;
  Transporters[vI].AvoidanceWidth    := 0;
  Transporters[vI].Acceleration_X     := 0;
  Transporters[vI].Deceleration_X     := 0;
  Transporters[vI].SpeedMax_X    := 0;
  Transporters[vI].ZPosDown    := 0;
  Transporters[vI].ZPosSlowUp := 0;
  Transporters[vI].ZPosSlowDown := 0;
  Transporters[vI].ZPosSlowEnd := 0;
  Transporters[vI].SpeedLiftSlow_Z   := 0;
  Transporters[vI].SpeedLiftFast_Z   := 0;
  Transporters[vI].DripTrayDelay  := 0;
  FOR vJ := 1 TO 4 DO
    Transporters[vI].TaskArea[vJ].MinLift := 0;
    Transporters[vI].TaskArea[vJ].MaxLift := 0;
    Transporters[vI].TaskArea[vJ].MinSink := 0;
    Transporters[vI].TaskArea[vJ].MaxSink := 0;
  END_FOR;
END_FOR;

(* --- Clear avoid status --- *)
FOR vI := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
  AvoidStatus[vI] := 0;
END_FOR;

(* --- Clear all transporter states --- *)
FOR vI := 1 TO MAX_TRANSPORTERS DO
  TransporterStatus[vI].IsActive          := FALSE;
  TransporterStatus[vI].Status          := 0;
  TransporterStatus[vI].Phase           := 0;
  TransporterStatus[vI].TaskId         := 0;
  TransporterStatus[vI].LiftStationTarget    := 0;
  TransporterStatus[vI].SinkStationTarget    := 0;
  TransporterStatus[vI].DrippingTime   := 0;
  TransporterStatus[vI].TaskRemainingTime  := 0;
  TransporterStatus[vI].CurrentStation := 0;
  TransporterStatus[vI].XFinalTarget  := 0;
  TransporterStatus[vI].XDriveTarget  := 0;
  TransporterStatus[vI].YFinalTarget  := 0;
  TransporterStatus[vI].YDriveTarget  := 0;
  TransporterStatus[vI].XPosition            := 0;
  TransporterStatus[vI].YPosition            := 0;
  TransporterStatus[vI].ZPosition            := 0;
  SimTrans[vI].XVelocity           := 0;
  SimTrans[vI].ZStage         := 0;
  SimTrans[vI].ZTimer       := 0.0;
  TransporterStatus[vI].IdleStartTime := TimeS;  (* prevent spurious move-away after clear *)
  DispatchedTask[vI].Active := FALSE;
  TransporterStatus[vI].XMinDriveLimit     := 0;
  TransporterStatus[vI].XMaxDriveLimit     := 0;
END_FOR;

(* --- Clear all units --- *)
FOR vI := 1 TO MAX_UNITS DO
  Unit[vI].location := 0;
  Unit[vI].Status   := 0;
  Unit[vI].Target   := 0;
END_FOR;

(* --- Clear NTT destinations --- *)
FOR vI := 1 TO MAX_TRANSPORTERS DO
  FOR vJ := 1 TO 8 DO
    Ntt[vI].Target[vJ].StationCount := 0;
    Ntt[vI].Target[vJ].FallbackCount := 0;
    FOR vK := 1 TO MAX_STATIONS_PER_STEP DO
      Ntt[vI].Target[vJ].Stations[vK] := 0;
      Ntt[vI].Target[vJ].FallbackStations[vK] := 0;
    END_FOR;
  END_FOR;
END_FOR;

(* --- Clear all batches --- *)
FOR vI := 1 TO MAX_UNITS DO
  Batch[vI].BatchCode  := 0;
  Batch[vI].State       := 0;
  Batch[vI].ProgId     := 0;
  Batch[vI].CurStage   := 0;
  Batch[vI].MinTime    := 0;
  Batch[vI].MaxTime    := 0;
  Batch[vI].CalTime    := 0;
  Batch[vI].StartTime  := LINT#0;
END_FOR;

(* --- Clear all treatment programs --- *)
FOR vI := 1 TO MAX_UNITS DO
  TreatmentPrograms[vI].ProgramId := 0;
  TreatmentPrograms[vI].ProgramName := '';
  TreatmentPrograms[vI].StepCount := 0;
  FOR vJ := 0 TO MAX_STEPS_PER_PROGRAM DO
    FOR vK := 0 TO 4 DO
      TreatmentPrograms[vI].Steps[vJ].Stations[vK] := 0;
    END_FOR;
    TreatmentPrograms[vI].Steps[vJ].StationCount := 0;
    TreatmentPrograms[vI].Steps[vJ].MinTime := 0;
    TreatmentPrograms[vI].Steps[vJ].MaxTime := 0;
    TreatmentPrograms[vI].Steps[vJ].CalTime := 0;
  END_FOR;
END_FOR;

(* --- Clear all schedules (Schedule) --- *)
FOR vI := 1 TO MAX_UNITS DO
  Schedule[vI].StageCount := 0;
  FOR vJ := 0 TO MAX_STEPS_PER_PROGRAM DO
    Schedule[vI].Stages[vJ].station       := 0;
    Schedule[vI].Stages[vJ].EntryTime    := 0;
    Schedule[vI].Stages[vJ].ExitTime     := 0;
    Schedule[vI].Stages[vJ].MinTime      := 0;
    Schedule[vI].Stages[vJ].CalcTime     := 0;
    Schedule[vI].Stages[vJ].MaxTime      := 0;
    Schedule[vI].Stages[vJ].TransferTime := 0;
  END_FOR;
END_FOR;

(* --- Clear all task queues (Task) --- *)
FOR vI := 1 TO MAX_TRANSPORTERS DO
  Task[vI].Count := 0;
  FOR vJ := 1 TO MAX_TASK_QUEUE DO
    Task[vI].Queue[vJ].Unit         := 0;
    Task[vI].Queue[vJ].Stage        := 0;
    Task[vI].Queue[vJ].LiftStationTarget := 0;
    Task[vI].Queue[vJ].SinkStationTarget := 0;
    Task[vI].Queue[vJ].StartTime   := 0;
    Task[vI].Queue[vJ].FinishTime  := 0;
    Task[vI].Queue[vJ].CalcTime    := 0;
    Task[vI].Queue[vJ].MinTime     := 0;
    Task[vI].Queue[vJ].MaxTime     := 0;
  END_FOR;
END_FOR;

(* --- Clear UI snapshot --- *)
FOR vI := 1 TO MAX_UNITS DO
  SimUiSchedule[vI].StageCount := 0;
END_FOR;
FOR vI := 1 TO MAX_TRANSPORTERS DO
  SimUiTask[vI].Count := 0;
END_FOR;
SimUiWaitUnit := 0;
SimUiWaitReason := 0;

(* --- Clear departure pending write --- *)
DepPending.Valid := FALSE;
DepPending.BatchUnit  := 0;
DepPending.BatchStage := 0;
DepPending.BatchState := NOT_PROCESSED;

(* --- Clear departure scheduler state (previously missing) --- *)
DepActivated     := FALSE;
TskStable        := TRUE;   (* JS: tasksStableFlag starts true on empty line *)
DepWaitingCount := 0;
FOR vI := 1 TO 5 DO
  DepWaiting[vI] := 0;
END_FOR;

END_FUNCTION_BLOCK

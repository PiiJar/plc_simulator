(* ============================================================
   SIM_FB_ClearConfig.st — Clear all PLC configuration data
   
   Called by PLC_PRG when Gateway sends cmd=3 (clear_all).
   Zeroes out all stations, transporter configs, transporter
   states and units so the PLC is ready for fresh config upload.
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_ClearConfig
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MAX_STATIONS_PER_STEP       : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
    MAX_Units           : INT;
    DEP_MAX_WAITING     : INT;
END_VAR

VAR_EXTERNAL
  g_station_count    : INT;
  g_station         : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc     : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_cfg              : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_transporter      : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_sim_trans        : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
  g_unit            : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_ntt             : ARRAY[1..MAX_Transporters] OF UDT_JC_NttTransporterType;
  g_batch          : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_program         : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_avoid_status     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF INT;
  g_schedule         : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_task             : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_dep_sandbox      : UDT_JC_DepSandboxType;
  g_dep_pending      : UDT_JC_DepPendingWriteType;
  g_dep_activated    : BOOL;
  g_dep_stable       : BOOL;
  g_dep_waiting_count : INT;
  g_dep_waiting       : ARRAY[1..DEP_MAX_WAITING] OF INT;
  g_dep_wait_unit     : INT;
END_VAR
VAR
  i : INT;
  j : INT;
  k : INT;
END_VAR

(* --- Clear all stations --- *)
FOR i := MIN_StationIndex TO MAX_StationIndex DO
  g_station[i].TankId       := 0;
  g_station[i].IsInUse       := FALSE;
  g_station[i].XPosition    := 0;
  g_station[i].YPosition    := 0;
  g_station[i].ZPosition    := 0;
  g_station[i].DryWet          := 0;
  g_station[i].StationType     := 0;
  g_station[i].DrippingTime := 0;
  g_station[i].DeviceDelay  := 0;
END_FOR;

(* --- Clear all location tracking (transporters 1..MAX_Transporters + stations MIN..MAX) --- *)
FOR i := 1 TO MAX_StationIndex DO
  g_station_loc[i].UnitId     := 0;
  g_station_loc[i].ChangeTime := 0;
END_FOR;
g_station_count := 0;

(* --- Clear all transporter configs --- *)
FOR i := 1 TO MAX_Transporters DO
  g_cfg[i].DrivePosMin   := 0;
  g_cfg[i].DrivePosMax   := 0;
  g_cfg[i].YMinDriveLimit   := 0;
  g_cfg[i].YMaxDriveLimit   := 0;
  g_cfg[i].CollisionWidth    := 0;
  g_cfg[i].AvoidanceWidth    := 0;
  g_cfg[i].Acceleration_X     := 0;
  g_cfg[i].Deceleration_X     := 0;
  g_cfg[i].SpeedMax_X    := 0;
  g_cfg[i].ZPosDown    := 0;
  g_cfg[i].ZPosSlowUp := 0;
  g_cfg[i].ZPosSlowDown := 0;
  g_cfg[i].ZPosSlowEnd := 0;
  g_cfg[i].SpeedLiftSlow_Z   := 0;
  g_cfg[i].SpeedLiftFast_Z   := 0;
  g_cfg[i].DripTrayDelay  := 0;
  FOR j := 1 TO 4 DO
    g_cfg[i].TaskArea[j].MinLift := 0;
    g_cfg[i].TaskArea[j].MaxLift := 0;
    g_cfg[i].TaskArea[j].MinSink := 0;
    g_cfg[i].TaskArea[j].MaxSink := 0;
  END_FOR;
END_FOR;

(* --- Clear avoid status --- *)
FOR i := MIN_StationIndex TO MAX_StationIndex DO
  g_avoid_status[i] := 0;
END_FOR;

(* --- Clear all transporter states --- *)
FOR i := 1 TO MAX_Transporters DO
  g_transporter[i].IsActive          := FALSE;
  g_transporter[i].Status          := 0;
  g_transporter[i].Phase           := 0;
  g_transporter[i].TaskId         := 0;
  g_sim_trans[i].RunningTaskId := 0;
  g_transporter[i].LiftStationTarget    := 0;
  g_transporter[i].SinkStationTarget    := 0;
  g_sim_trans[i].TreatmentTime  := 0;
  g_sim_trans[i].LiftDeviceDelay := 0;
  g_sim_trans[i].SinkDeviceDelay := 0;
  g_transporter[i].DrippingTime   := 0;
  g_transporter[i].TaskRemainingTime  := 0;
  g_transporter[i].CurrentStation := 0;
  g_transporter[i].XFinalTarget  := 0;
  g_transporter[i].XDriveTarget  := 0;
  g_transporter[i].YFinalTarget  := 0;
  g_transporter[i].YDriveTarget  := 0;
  g_transporter[i].XPosition            := 0;
  g_transporter[i].YPosition            := 0;
  g_transporter[i].ZPosition            := 0;
  g_sim_trans[i].XVelocity           := 0;
  g_sim_trans[i].ZStage         := 0;
  g_sim_trans[i].ZTimer       := 0.0;
  g_transporter[i].XMinDriveLimit     := 0;
  g_transporter[i].XMaxDriveLimit     := 0;
END_FOR;

(* --- Clear all units --- *)
FOR i := 1 TO MAX_Units DO
  g_unit[i].location := 0;
  g_unit[i].Status   := 0;
  g_unit[i].Target   := 0;
END_FOR;

(* --- Clear NTT destinations --- *)
FOR i := 1 TO MAX_Transporters DO
  FOR j := 1 TO 8 DO
    g_ntt[i].Target[j].StationCount := 0;
    g_ntt[i].Target[j].FallbackCount := 0;
    FOR k := 1 TO MAX_STATIONS_PER_STEP DO
      g_ntt[i].Target[j].Stations[k] := 0;
      g_ntt[i].Target[j].FallbackStations[k] := 0;
    END_FOR;
  END_FOR;
END_FOR;

(* --- Clear all batches --- *)
FOR i := 1 TO MAX_Units DO
  g_batch[i].BatchCode  := 0;
  g_batch[i].State       := 0;
  g_batch[i].ProgId     := 0;
  g_batch[i].CurStage   := 0;
  g_batch[i].MinTime    := 0;
  g_batch[i].MaxTime    := 0;
  g_batch[i].CalTime    := 0;
  g_batch[i].StartTime  := LINT#0;
END_FOR;

(* --- Clear all treatment programs --- *)
FOR i := 1 TO MAX_Units DO
  g_program[i].ProgramId := 0;
  g_program[i].ProgramName := '';
  g_program[i].StepCount := 0;
  FOR j := 0 TO 30 DO
    FOR k := 0 TO 4 DO
      g_program[i].Steps[j].Stations[k] := 0;
    END_FOR;
    g_program[i].Steps[j].StationCount := 0;
    g_program[i].Steps[j].MinTime := 0;
    g_program[i].Steps[j].MaxTime := 0;
    g_program[i].Steps[j].CalTime := 0;
  END_FOR;
END_FOR;

(* --- Clear all schedules (g_schedule) --- *)
FOR i := 1 TO MAX_Units DO
  g_schedule[i].StageCount := 0;
  FOR j := 1 TO 30 DO
    g_schedule[i].Stages[j].station       := 0;
    g_schedule[i].Stages[j].EntryTime    := 0;
    g_schedule[i].Stages[j].ExitTime     := 0;
    g_schedule[i].Stages[j].MinTime      := 0;
    g_schedule[i].Stages[j].CalcTime     := 0;
    g_schedule[i].Stages[j].MaxTime      := 0;
    g_schedule[i].Stages[j].TransferTime := 0;
  END_FOR;
END_FOR;

(* --- Clear all task queues (g_task) --- *)
FOR i := 1 TO MAX_Transporters DO
  g_task[i].Count := 0;
  FOR j := 1 TO 60 DO
    g_task[i].Queue[j].Unit         := 0;
    g_task[i].Queue[j].Stage        := 0;
    g_task[i].Queue[j].LiftStationTarget := 0;
    g_task[i].Queue[j].SinkStationTarget := 0;
    g_task[i].Queue[j].StartTime   := 0;
    g_task[i].Queue[j].FinishTime  := 0;
    g_task[i].Queue[j].CalcTime    := 0;
    g_task[i].Queue[j].MinTime     := 0;
    g_task[i].Queue[j].MaxTime     := 0;
  END_FOR;
END_FOR;

(* --- Clear departure sandbox and pending write --- *)
g_dep_sandbox.Valid := FALSE;
g_dep_pending.Valid := FALSE;
g_dep_pending.BatchUnit  := 0;
g_dep_pending.BatchStage := 0;
g_dep_pending.BatchState := 0;

(* --- Clear departure scheduler state (previously missing) --- *)
g_dep_activated     := FALSE;
g_dep_stable        := FALSE;
g_dep_waiting_count := 0;
g_dep_wait_unit     := 0;
FOR i := 1 TO 5 DO
  g_dep_waiting[i] := 0;
END_FOR;

END_FUNCTION_BLOCK

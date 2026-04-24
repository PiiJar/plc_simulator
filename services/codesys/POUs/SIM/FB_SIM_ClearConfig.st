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
  g_station_occupancy     : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters              : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_transporter      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  g_sim_trans        : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  g_dispatched_task  : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
  g_unit            : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  g_ntt             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  g_batch          : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms         : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_avoid_status     : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  g_schedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_task             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  g_sim_ui_schedule  : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_sim_ui_task      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  g_sim_ui_wait_unit : INT;
  g_sim_ui_wait_reason : INT;
  g_dep_pending      : UDT_JC_DepPendingWriteType;
  g_dep_activated    : BOOL;
  g_tsk_stable       : BOOL;
  g_dep_waiting_count : INT;
  g_dep_waiting       : ARRAY[1..DEP_MAX_WAITING] OF INT;
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
  g_station_occupancy[i].UnitId     := 0;
  g_station_occupancy[i].ChangeTime := 0;
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
  g_avoid_status[i] := 0;
END_FOR;

(* --- Clear all transporter states --- *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  g_transporter[i].IsActive          := FALSE;
  g_transporter[i].Status          := 0;
  g_transporter[i].Phase           := 0;
  g_transporter[i].TaskId         := 0;
  g_transporter[i].LiftStationTarget    := 0;
  g_transporter[i].SinkStationTarget    := 0;
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
  g_transporter[i].IdleStartTime := g_time_s;  (* prevent spurious move-away after clear *)
  g_dispatched_task[i].Active := FALSE;
  g_transporter[i].XMinDriveLimit     := 0;
  g_transporter[i].XMaxDriveLimit     := 0;
END_FOR;

(* --- Clear all units --- *)
FOR i := 1 TO MAX_UNITS DO
  g_unit[i].vLocation := 0;
  g_unit[i].Status   := 0;
  g_unit[i].Target   := 0;
END_FOR;

(* --- Clear NTT destinations --- *)
FOR i := 1 TO MAX_TRANSPORTERS DO
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
FOR i := 1 TO MAX_UNITS DO
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

(* --- Clear all schedules (g_schedule) --- *)
FOR i := 1 TO MAX_UNITS DO
  g_schedule[i].StageCount := 0;
  FOR j := 0 TO MAX_STEPS_PER_PROGRAM DO
    g_schedule[i].Stages[j].Station       := 0;
    g_schedule[i].Stages[j].EntryTime    := 0;
    g_schedule[i].Stages[j].ExitTime     := 0;
    g_schedule[i].Stages[j].MinTime      := 0;
    g_schedule[i].Stages[j].CalcTime     := 0;
    g_schedule[i].Stages[j].MaxTime      := 0;
    g_schedule[i].Stages[j].TransferTime := 0;
  END_FOR;
END_FOR;

(* --- Clear all task queues (g_task) --- *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  g_task[i].Count := 0;
  FOR j := 1 TO MAX_TASK_QUEUE DO
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

(* --- Clear UI snapshot --- *)
FOR i := 1 TO MAX_UNITS DO
  g_sim_ui_schedule[i].StageCount := 0;
END_FOR;
FOR i := 1 TO MAX_TRANSPORTERS DO
  g_sim_ui_task[i].Count := 0;
END_FOR;
g_sim_ui_wait_unit := 0;
g_sim_ui_wait_reason := 0;

(* --- Clear departure pending write --- *)
g_dep_pending.Valid := FALSE;
g_dep_pending.BatchUnit  := 0;
g_dep_pending.BatchStage := 0;
g_dep_pending.BatchState := NOT_PROCESSED;

(* --- Clear departure scheduler state (previously missing) --- *)
g_dep_activated     := FALSE;
g_tsk_stable        := TRUE;   (* JS: tasksStableFlag starts true on empty line *)
g_dep_waiting_count := 0;
FOR i := 1 TO 5 DO
  g_dep_waiting[i] := 0;
END_FOR;

END_FUNCTION_BLOCK

(* ===========================================================================================
 *  STC_ManualTask — Execute manual transport tasks from gateway
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  For each transporter, checks g_manual_task[ti].Valid.
 *  If the transporter is idle (Phase=0), validates stations,
 *  calculates transfer time, and inserts a task into the queue
 *  (same pattern as TSK_NoTreatment).
 *  Clears Valid after task is created, or on invalid input.
 *
 *  Called from TSK_FB_Scheduler phase 2200 (before NTT).
 *
 * ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_ManualTask : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_time_s                  : LINT;
END_VAR

VAR_IN_OUT
  io_task                   : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL
  g_manual_task             : ARRAY[1..MAX_Transporters] OF UDT_JC_ManualTaskType;
  g_transporter             : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_move                    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_unit                    : ARRAY[1..MAX_Units] OF UDT_JC_UnitType;
  Stations                  : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  Transporters              : ARRAY[0..MAX_Transporters] OF UDT_TransporterType;
END_VAR

VAR_EXTERNAL CONSTANT
  MAX_TASK_QUEUE            : INT;
  MAX_Units                 : INT;
  USED                      : INT;
END_VAR

VAR
  ti                        : INT;
  ai                        : INT;
  sh                        : INT;
  lift                      : INT;
  sink                      : INT;
  covers                    : BOOL;
  trans_pos                 : INT;
  tmp_move                  : UDT_JC_MoveTimesType;
  xfer_s                    : REAL;
  travel_to_lift_s          : REAL;
  task_start                : LINT;
  task_end                  : LINT;
END_VAR

STC_ManualTask := TRUE;

FOR ti := 1 TO MAX_Transporters DO
  IF NOT g_manual_task[ti].Valid THEN
    CONTINUE;
  END_IF;

  lift := g_manual_task[ti].LiftStation;
  sink := g_manual_task[ti].SinkStation;

  (* Validate station range *)
  IF lift < MIN_StationIndex OR lift > MAX_StationIndex
     OR sink < MIN_StationIndex OR sink > MAX_StationIndex
     OR lift = sink THEN
    g_manual_task[ti].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Transporter must be active and idle *)
  (* Transporter must be active and idle or in move-away *)
  IF NOT g_transporter[ti].IsActive THEN
    CONTINUE;
  END_IF;
  IF g_transporter[ti].Phase <> 0
     AND NOT (g_transporter[ti].Phase = 1 AND g_transporter[ti].Status = 3) THEN
    CONTINUE;  (* keep Valid — retry next cycle *)
  END_IF;

  (* Check lift station is within transporter TaskArea *)
  covers := FALSE;
  FOR ai := 1 TO 4 DO
    IF Transporters[ti].TaskArea[ai].MinLift > 0
       OR Transporters[ti].TaskArea[ai].MaxLift > 0 THEN
      IF lift >= Transporters[ti].TaskArea[ai].MinLift
         AND lift <= Transporters[ti].TaskArea[ai].MaxLift THEN
        covers := TRUE;
      END_IF;
    END_IF;
  END_FOR;

  IF NOT covers THEN
    g_manual_task[ti].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Calculate transfer time *)
  tmp_move := g_move[ti];
  xfer_s := STC_CalcTransferTime(
    i_from_stn            := lift,
    i_to_stn              := sink,
    i_move                := tmp_move,
    i_from_dropping_x10   := Stations[lift].DrippingTime,
    i_to_device_delay_x10 := Stations[sink].DeviceDelay,
    i_drip_tray_delay_x10 := Transporters[ti].DripTrayDelay);

  (* Calculate travel-to-lift: time for transporter to reach lift station *)
  travel_to_lift_s := 0.0;
  trans_pos := g_transporter[ti].CurrentStation;
  IF trans_pos > 0 AND trans_pos <> lift THEN
    travel_to_lift_s := STC_CalcHorizontalTravel(
      i_from_stn := trans_pos,
      i_to_stn   := lift,
      i_move     := tmp_move);
  END_IF;

  task_start := i_time_s + REAL_TO_LINT(travel_to_lift_s);
  task_end   := task_start + REAL_TO_LINT(xfer_s);

  (* Check sink station is free — no unit occupying it *)
  covers := TRUE;  (* reuse variable as sink_free flag *)
  FOR sh := 1 TO MAX_Units DO
    IF g_unit[sh].location = sink AND g_unit[sh].Status = USED THEN
      covers := FALSE;
    END_IF;
  END_FOR;
  IF NOT covers THEN
    g_manual_task[ti].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Insert task at queue position 1 *)
  IF io_task[ti].Count < MAX_TASK_QUEUE THEN
    FOR sh := io_task[ti].Count TO 1 BY -1 DO
      io_task[ti].Queue[sh + 1] := io_task[ti].Queue[sh];
    END_FOR;
    io_task[ti].Queue[1].Unit              := 0;
    io_task[ti].Queue[1].Stage             := 0;
    io_task[ti].Queue[1].LiftStationTarget := lift;
    io_task[ti].Queue[1].SinkStationTarget := sink;
    io_task[ti].Queue[1].StartTime         := task_start;
    io_task[ti].Queue[1].FinishTime        := task_end;
    io_task[ti].Queue[1].CalcTime          := 0;
    io_task[ti].Queue[1].MinTime           := 0;
    io_task[ti].Queue[1].MaxTime           := 0;
    io_task[ti].Queue[1].NttPrimary        := 0;
    io_task[ti].Count := io_task[ti].Count + 1;
  END_IF;

  g_manual_task[ti].Valid := FALSE;
END_FOR;

END_FUNCTION

(* ===========================================================================================
 *  FC_STC_ManualTask — Execute manual transport tasks from gateway
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  For each transporter, checks g_manual_task[ti].Valid.
 *  If the transporter is idle (Phase=0), validates stations,
 *  calculates transfer time, and inserts a task into the queue
 *  (same pattern as FC_TSK_NoTreatment).
 *  Clears Valid after task is created, or on invalid input.
 *
 *  Called from FB_TSK_Scheduler vPhase 2200 (before NTT).
 *
 * ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_ManualTask : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTimeS                  : LINT;
END_VAR

VAR_IN_OUT
  ioTask                   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL
  g_manual_task             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ManualTaskType;
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Stations                  : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  Transporters              : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
END_VAR

VAR_EXTERNAL CONSTANT
  MAX_TASK_QUEUE            : INT;
  MAX_UNITS                 : INT;
  USED                      : INT;
END_VAR

VAR
  ti                        : INT;
  ai                        : INT;
  sh                        : INT;
  lift                      : INT;
  sink                      : INT;
  vCovers                    : BOOL;
  vTransPos                 : INT;
  vTmpMove                  : UDT_JC_MoveTimesType;
  vXferS                    : REAL;
  vTravelToLiftS          : REAL;
  vTaskStart                : LINT;
  vTaskEnd                  : LINT;
END_VAR

FC_STC_ManualTask := TRUE;

FOR ti := 1 TO MAX_TRANSPORTERS DO
  IF NOT g_manual_task[ti].Valid THEN
    CONTINUE;
  END_IF;

  lift := g_manual_task[ti].LiftStation;
  sink := g_manual_task[ti].SinkStation;

  (* Validate station range *)
  IF lift < MIN_STATION_INDEX OR lift > MAX_STATION_INDEX
     OR sink < MIN_STATION_INDEX OR sink > MAX_STATION_INDEX
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
  vCovers := FALSE;
  FOR ai := 1 TO 4 DO
    IF Transporters[ti].TaskArea[ai].MinLift > 0
       OR Transporters[ti].TaskArea[ai].MaxLift > 0 THEN
      IF lift >= Transporters[ti].TaskArea[ai].MinLift
         AND lift <= Transporters[ti].TaskArea[ai].MaxLift THEN
        vCovers := TRUE;
      END_IF;
    END_IF;
  END_FOR;

  IF NOT vCovers THEN
    g_manual_task[ti].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Calculate transfer time *)
  vTmpMove := g_move[ti];
  vXferS := FC_STC_CalcTransferTime(
    iFromStn            := lift,
    iToStn              := sink,
    iMove                := vTmpMove,
    i_from_dropping_x10   := Stations[lift].DrippingTime,
    i_to_device_delay_x10 := Stations[sink].DeviceDelay,
    iDripTrayDelayX10 := Transporters[ti].DripTrayDelay);

  (* Calculate vTravel-to-lift: time for transporter to reach lift station *)
  vTravelToLiftS := 0.0;
  vTransPos := g_transporter[ti].CurrentStation;
  IF vTransPos > 0 AND vTransPos <> lift THEN
    vTravelToLiftS := FC_STC_CalcHorizontalTravel(
      iFromStn := vTransPos,
      iToStn   := lift,
      iMove     := vTmpMove);
  END_IF;

  vTaskStart := iTimeS + REAL_TO_LINT(vTravelToLiftS);
  vTaskEnd   := vTaskStart + REAL_TO_LINT(vXferS);

  (* Check sink station is free — no unit occupying it *)
  vCovers := TRUE;  (* reuse variable as vSinkFree flag *)
  FOR sh := 1 TO MAX_UNITS DO
    IF g_unit[sh].Location = sink AND g_unit[sh].Status = USED THEN
      vCovers := FALSE;
    END_IF;
  END_FOR;
  IF NOT vCovers THEN
    g_manual_task[ti].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Insert task at queue position 1 *)
  IF ioTask[ti].Count < MAX_TASK_QUEUE THEN
    FOR sh := ioTask[ti].Count TO 1 BY -1 DO
      ioTask[ti].Queue[sh + 1] := ioTask[ti].Queue[sh];
    END_FOR;
    ioTask[ti].Queue[1].Unit              := 0;
    ioTask[ti].Queue[1].Stage             := 0;
    ioTask[ti].Queue[1].LiftStationTarget := lift;
    ioTask[ti].Queue[1].SinkStationTarget := sink;
    ioTask[ti].Queue[1].StartTime         := vTaskStart;
    ioTask[ti].Queue[1].FinishTime        := vTaskEnd;
    ioTask[ti].Queue[1].CalcTime          := 0;
    ioTask[ti].Queue[1].MinTime           := 0;
    ioTask[ti].Queue[1].MaxTime           := 0;
    ioTask[ti].Queue[1].NttPrimary        := 0;
    ioTask[ti].Count := ioTask[ti].Count + 1;
  END_IF;

  g_manual_task[ti].Valid := FALSE;
END_FOR;

END_FUNCTION

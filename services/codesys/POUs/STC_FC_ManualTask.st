(* ===========================================================================================
 *  STC_FC_ManualTask — Execute manual transport tasks from gateway
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  For each transporter, checks ManualTask[vTi].Valid.
 *  If the transporter is idle (Phase=0), validates stations,
 *  calculates transfer time, and inserts a task into the queue
 *  (same pattern as TSK_FC_NoTreatment).
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


FUNCTION STC_FC_ManualTask : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTimeS                  : LINT;
END_VAR

VAR_IN_OUT
  ioTask                   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL
  ManualTask             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ManualTaskType;
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  Unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Stations                  : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  Transporters              : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
END_VAR

VAR_EXTERNAL CONSTANT
  MAX_TASK_QUEUE            : INT;
  MAX_UNITS                 : INT;
  USED                      : INT;
END_VAR

VAR
  vTi                        : INT;
  vAi                        : INT;
  vSh                        : INT;
  vLift                      : INT;
  vSink                      : INT;
  vCovers                    : BOOL;
  vTransPos                 : INT;
  vTmpMove                  : UDT_JC_MoveTimesType;
  vXferS                    : REAL;
  vTravelToLiftS          : REAL;
  vTaskStart                : LINT;
  vTaskEnd                  : LINT;
END_VAR

STC_FC_ManualTask := TRUE;

FOR vTi := 1 TO MAX_TRANSPORTERS DO
  IF NOT ManualTask[vTi].Valid THEN
    CONTINUE;
  END_IF;

  vLift := ManualTask[vTi].LiftStation;
  vSink := ManualTask[vTi].SinkStation;

  (* Validate station range *)
  IF vLift < MIN_STATION_INDEX OR vLift > MAX_STATION_INDEX
     OR vSink < MIN_STATION_INDEX OR vSink > MAX_STATION_INDEX
     OR vLift = vSink THEN
    ManualTask[vTi].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Transporter must be active and idle *)
  (* Transporter must be active and idle or in move-away *)
  IF NOT TransporterStatus[vTi].IsActive THEN
    CONTINUE;
  END_IF;
  IF TransporterStatus[vTi].Phase <> 0
     AND NOT (TransporterStatus[vTi].Phase = 1 AND TransporterStatus[vTi].Status = 3) THEN
    CONTINUE;  (* keep Valid — retry next cycle *)
  END_IF;

  (* Check vLift station is within transporter TaskArea *)
  vCovers := FALSE;
  FOR vAi := 1 TO 4 DO
    IF Transporters[vTi].TaskArea[vAi].MinLift > 0
       OR Transporters[vTi].TaskArea[vAi].MaxLift > 0 THEN
      IF vLift >= Transporters[vTi].TaskArea[vAi].MinLift
         AND vLift <= Transporters[vTi].TaskArea[vAi].MaxLift THEN
        vCovers := TRUE;
      END_IF;
    END_IF;
  END_FOR;

  IF NOT vCovers THEN
    ManualTask[vTi].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Calculate transfer time *)
  vTmpMove := Move[vTi];
  vXferS := STC_FC_CalcTransferTime(
    iFromStn            := vLift,
    iToStn              := vSink,
    iMove                := vTmpMove,
    iFromDroppingX10   := Stations[vLift].DrippingTime,
    iToDeviceDelayX10 := Stations[vSink].DeviceDelay,
    iDripTrayDelayX10 := Transporters[vTi].DripTrayDelay);

  (* Calculate travel-to-vLift: time for transporter to reach vLift station *)
  vTravelToLiftS := 0.0;
  vTransPos := TransporterStatus[vTi].CurrentStation;
  IF vTransPos > 0 AND vTransPos <> vLift THEN
    vTravelToLiftS := STC_FC_CalcHorizontalTravel(
      iFromStn := vTransPos,
      iToStn   := vLift,
      iMove     := vTmpMove);
  END_IF;

  vTaskStart := iTimeS + REAL_TO_LINT(vTravelToLiftS);
  vTaskEnd   := vTaskStart + REAL_TO_LINT(vXferS);

  (* Check vSink station is free — no unit occupying it *)
  vCovers := TRUE;  (* reuse variable as sink_free flag *)
  FOR vSh := 1 TO MAX_UNITS DO
    IF Unit[vSh].location = vSink AND Unit[vSh].Status = USED THEN
      vCovers := FALSE;
    END_IF;
  END_FOR;
  IF NOT vCovers THEN
    ManualTask[vTi].Valid := FALSE;
    CONTINUE;
  END_IF;

  (* Insert task at queue position 1 *)
  IF ioTask[vTi].Count < MAX_TASK_QUEUE THEN
    FOR vSh := ioTask[vTi].Count TO 1 BY -1 DO
      ioTask[vTi].Queue[vSh + 1] := ioTask[vTi].Queue[vSh];
    END_FOR;
    ioTask[vTi].Queue[1].Unit              := 0;
    ioTask[vTi].Queue[1].Stage             := 0;
    ioTask[vTi].Queue[1].LiftStationTarget := vLift;
    ioTask[vTi].Queue[1].SinkStationTarget := vSink;
    ioTask[vTi].Queue[1].StartTime         := vTaskStart;
    ioTask[vTi].Queue[1].FinishTime        := vTaskEnd;
    ioTask[vTi].Queue[1].CalcTime          := 0;
    ioTask[vTi].Queue[1].MinTime           := 0;
    ioTask[vTi].Queue[1].MaxTime           := 0;
    ioTask[vTi].Queue[1].NttPrimary        := 0;
    ioTask[vTi].Count := ioTask[vTi].Count + 1;
  END_IF;

  ManualTask[vTi].Valid := FALSE;
END_FOR;

END_FUNCTION

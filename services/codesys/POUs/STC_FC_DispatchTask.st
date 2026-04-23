(* ===========================================================================================
 *  STC_FC_DispatchTask — Validate and dispatch tasks to transporters
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Called every PLC scan from MainScheduler.
 *  For each idle transporter with queued tasks:
 *  1. Skip if transporter not idle or queue empty
 *  2. Time check: start_time close enough?
 *  3. Sink station free check (with parallel alternatives)
 *  4. Conflict check against active transporters
 *  5. Dispatch: write to TransporterStatus → RunTasks picks it up
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_FC_DispatchTask : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    MAX_STATIONS_PER_STEP   : INT;
    MAX_STEPS_PER_PROGRAM   : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    SCH_DISPATCH_MARGIN_S   : REAL;
    USED                    : INT;
    PROCESSED               : INT;
END_VAR

VAR_EXTERNAL
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Task                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  StationOccupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  Ntt                     : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  Batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  Schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  TimeS                  : LINT;
  EventPending           : UDT_JC_EventMsgType;
  EventPendingValid     : BOOL;
  DispatchedTask         : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
END_VAR

VAR
  vTi                        : INT;     (* transporter loop *)
  (* Task fields — read from queue[1] to avoid struct copy *)
  vTUnit                    : INT;
  vTStage                   : INT;
  vTLift                    : INT;
  vTSink                    : INT;
  vTStart                   : LINT;
  vTFinish                  : LINT;
  vTCalcTime               : DINT;
  (* Time check *)
  vTravelS                  : REAL;
  vMarginS                  : LINT;
  vFromIdx                  : INT;
  vToIdx                    : INT;
  (* Sink search *)
  vSinkStn                  : INT;
  vSinkFree                 : BOOL;
  vBestStn                  : INT;
  vBestChange               : LINT;
  vSi                        : INT;
  vCandStn                  : INT;
  vCandFree                 : BOOL;
  vUj                        : INT;
  vTgt                       : INT;
  vNttIdx                   : INT;     (* resolved NTT index (buffer 6/7/8) *)
  vNttCnt                   : INT;
  vNttFbCnt                : INT;
  (* Conflict check *)
  vConflict                  : BOOL;
  vCj                        : INT;
  vTaskMin                  : INT;     (* min station of our proposed task *)
  vTaskMax                  : INT;     (* max station of our proposed task *)
  (* Queue position loop *)
  vQi                        : INT;
  (* Shift-down after dispatch *)
  vSh                        : INT;
  (* Transfer time for batch progress bar *)
  vXferTotal                : REAL;
  (* Program stage number for event *)
  vProgStage                : INT;
  (* Manual task dispatch flag *)
  vUnitOk                   : BOOL;
END_VAR

FOR vTi := 1 TO MAX_TRANSPORTERS DO

  (* ── 1. Skip if not idle or queue empty ── *)
  (* Accept idle (Phase=0) OR move-away in progress (Phase=1, Status=3) *)
  IF (TransporterStatus[vTi].Phase = 0 OR (TransporterStatus[vTi].Phase = 1 AND TransporterStatus[vTi].Status = 3))
     AND Task[vTi].Count >= 1 THEN

    (* Try each queue position — skip blocked tasks, dispatch first feasible *)
    FOR vQi := 1 TO Task[vTi].Count DO

    (* Read task fields from queue position vQi *)
    vTUnit      := Task[vTi].Queue[vQi].Unit;
    vTStage     := Task[vTi].Queue[vQi].Stage;  (* schedule index *)
    vTLift      := Task[vTi].Queue[vQi].LiftStationTarget;
    vTSink      := Task[vTi].Queue[vQi].SinkStationTarget;
    vTStart     := Task[vTi].Queue[vQi].StartTime;
    vTFinish    := Task[vTi].Queue[vQi].FinishTime;
    vTCalcTime := Task[vTi].Queue[vQi].CalcTime;

    (* Queue[].Stage already contains ProgramStage (set by STC_FC_CreateTasks) *)
    vProgStage := vTStage;

    (* ── 1b. Lift station unit check — unit must be AT the lift station ── *)
    (* Manual tasks have Unit=0 → skip unit-location check *)
    (* NOTE: CODESYS does NOT short-circuit OR — use nested IFs *)
    vUnitOk := FALSE;
    IF vTUnit = 0 THEN
      vUnitOk := TRUE;
    ELSIF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
      IF Unit[vTUnit].location = vTLift THEN
        vUnitOk := TRUE;
      END_IF;
    END_IF;

    IF vUnitOk THEN

    (* ── 2. Time check ── *)
    vTravelS := 0.0;
    IF TransporterStatus[vTi].CurrentStation > 0 AND vTLift > 0
       AND TransporterStatus[vTi].CurrentStation <> vTLift THEN
      vFromIdx := TransporterStatus[vTi].CurrentStation - MIN_STATION_INDEX;
      vToIdx   := vTLift - MIN_STATION_INDEX;
      IF vFromIdx >= 1 AND vFromIdx <= 30 AND vToIdx >= 1 AND vToIdx <= 30 THEN
        vTravelS := INT_TO_REAL(Move[vTi].Travel[vFromIdx].ToTime[vToIdx]) / 10.0;
      END_IF;
    END_IF;

    vMarginS := vTStart - TimeS;

    IF vMarginS <= REAL_TO_LINT(vTravelS + SCH_DISPATCH_MARGIN_S) THEN

      (* ── 3. Sink station free check ── *)
      vSinkStn := vTSink;
      vSinkFree := FALSE;

      IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
        vSinkFree := TRUE;
        FOR vUj := 1 TO MAX_UNITS DO
          IF Unit[vUj].location = vSinkStn AND Unit[vUj].Status = USED THEN
            vSinkFree := FALSE;
          END_IF;
        END_FOR;
      END_IF;

      IF NOT vSinkFree THEN
        (* Search alternative parallel stations *)
        vBestStn := 0;
        vBestChange := LINT#2000000000;

        IF vProgStage >= 1 AND vProgStage <= MAX_STEPS_PER_PROGRAM
           AND vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
          (* Treatment task — look in TreatmentPrograms for parallel stations *)
          FOR vSi := 0 TO MAX_STATIONS_PER_STEP - 1 DO
            vCandStn := TreatmentPrograms[vTUnit].Steps[vProgStage].Stations[vSi];
            IF vCandStn > 0 AND vCandStn <> vTSink THEN
              IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                vCandFree := TRUE;
                FOR vUj := 1 TO MAX_UNITS DO
                  IF Unit[vUj].location = vCandStn AND Unit[vUj].Status = USED THEN
                    vCandFree := FALSE;
                  END_IF;
                END_FOR;
                IF vCandFree THEN
                  IF StationOccupancy[vCandStn].ChangeTime < vBestChange THEN
                    vBestChange := StationOccupancy[vCandStn].ChangeTime;
                    vBestStn := vCandStn;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

        ELSIF vProgStage = 0 AND vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
          (* No-treatment task — look in Ntt for alternatives *)
          vTgt := Unit[vTUnit].Target;
          IF vTgt >= 1 AND vTgt <= 5 THEN
            (* Resolve buffer NTT index like NoTreatment does *)
            IF vTgt = 2 THEN
              IF Batch[vTUnit].BatchCode = 0 THEN
                vNttIdx := 6;
              ELSIF Batch[vTUnit].State = PROCESSED THEN
                vNttIdx := 8;
              ELSE
                vNttIdx := 7;
              END_IF;
            ELSE
              vNttIdx := vTgt;
            END_IF;
            (* Check primary stations *)
            vNttCnt := Ntt[vTi].Target[vNttIdx].StationCount;
            FOR vSi := 1 TO vNttCnt DO
              IF vSi <= MAX_STATIONS_PER_STEP THEN
                vCandStn := Ntt[vTi].Target[vNttIdx].Stations[vSi];
                IF vCandStn > 0 AND vCandStn <> vTSink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR vUj := 1 TO MAX_UNITS DO
                      IF Unit[vUj].location = vCandStn AND Unit[vUj].Status = USED THEN
                        vCandFree := FALSE;
                      END_IF;
                    END_FOR;
                    IF vCandFree THEN
                      IF StationOccupancy[vCandStn].ChangeTime < vBestChange THEN
                        vBestChange := StationOccupancy[vCandStn].ChangeTime;
                        vBestStn := vCandStn;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;
            (* Check fallback stations *)
            vNttFbCnt := Ntt[vTi].Target[vNttIdx].FallbackCount;
            FOR vSi := 1 TO vNttFbCnt DO
              IF vSi <= MAX_STATIONS_PER_STEP THEN
                vCandStn := Ntt[vTi].Target[vNttIdx].FallbackStations[vSi];
                IF vCandStn > 0 AND vCandStn <> vTSink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR vUj := 1 TO MAX_UNITS DO
                      IF Unit[vUj].location = vCandStn AND Unit[vUj].Status = USED THEN
                        vCandFree := FALSE;
                      END_IF;
                    END_FOR;
                    IF vCandFree THEN
                      IF StationOccupancy[vCandStn].ChangeTime < vBestChange THEN
                        vBestChange := StationOccupancy[vCandStn].ChangeTime;
                        vBestStn := vCandStn;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;
          END_IF;
        END_IF;

        IF vBestStn > 0 THEN
          vSinkStn := vBestStn;
          vSinkFree := TRUE;
        END_IF;
      END_IF;  (* NOT vSinkFree *)

      IF vSinkFree THEN

        (* ── 4. Conflict check ── *)
        vConflict := FALSE;

        IF vTLift <= vSinkStn THEN
          vTaskMin := vTLift;
          vTaskMax := vSinkStn;
        ELSE
          vTaskMin := vSinkStn;
          vTaskMax := vTLift;
        END_IF;

        FOR vCj := 1 TO MAX_TRANSPORTERS DO
          IF vCj <> vTi AND TransporterStatus[vCj].Phase > 0 THEN

            (* a) T2's entire active task inside our range → vConflict *)
            IF TransporterStatus[vCj].LiftStationTarget >= vTaskMin
               AND TransporterStatus[vCj].LiftStationTarget <= vTaskMax
               AND TransporterStatus[vCj].SinkStationTarget >= vTaskMin
               AND TransporterStatus[vCj].SinkStationTarget <= vTaskMax THEN
              vConflict := TRUE;
            END_IF;

            (* b) T2 delivers to one of our exact stations → vConflict *)
            IF TransporterStatus[vCj].SinkStationTarget = vTLift
               OR TransporterStatus[vCj].SinkStationTarget = vSinkStn THEN
              vConflict := TRUE;
            END_IF;

          END_IF;
        END_FOR;

        IF NOT vConflict THEN
          (* ── 5. Dispatch: assign task to transporter ── *)
          TransporterStatus[vTi].TaskId      := vTStart;
          TransporterStatus[vTi].LiftStationTarget := vTLift;
          TransporterStatus[vTi].SinkStationTarget := vSinkStn;
          TransporterStatus[vTi].CurrentTaskFinishTime := Task[vTi].Queue[vQi].FinishTime;
          StationOccupancy[vTi].UnitId      := vTUnit;
          TransporterStatus[vTi].TaskRemainingTime := vTCalcTime;

          (* ── 5b. Fill dispatched task package ── *)
          DispatchedTask[vTi].TaskId           := vTStart;
          DispatchedTask[vTi].UnitId           := vTUnit;
          DispatchedTask[vTi].LiftStation      := vTLift;
          DispatchedTask[vTi].SinkStation      := vSinkStn;
          IF vTLift >= MIN_STATION_INDEX AND vTLift <= MAX_STATION_INDEX THEN
            DispatchedTask[vTi].LiftX              := Stations[vTLift].XPosition;
            DispatchedTask[vTi].LiftKind           := Stations[vTLift].DryWet;
            DispatchedTask[vTi].DroppingTime_x10   := Stations[vTLift].DrippingTime;
            DispatchedTask[vTi].LiftDeviceDelay_x10 := Stations[vTLift].DeviceDelay;
          END_IF;
          IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
            DispatchedTask[vTi].SinkX              := Stations[vSinkStn].XPosition;
            DispatchedTask[vTi].SinkKind           := Stations[vSinkStn].DryWet;
            DispatchedTask[vTi].SinkDeviceDelay_x10 := Stations[vSinkStn].DeviceDelay;
          END_IF;
          DispatchedTask[vTi].DripTrayDelay_x10 := Transporters[vTi].DripTrayDelay;
          DispatchedTask[vTi].TreatmentTime    := vTCalcTime;
          DispatchedTask[vTi].MinTime          := Task[vTi].Queue[vQi].MinTime;
          DispatchedTask[vTi].MaxTime          := Task[vTi].Queue[vQi].MaxTime;
          DispatchedTask[vTi].NttPrimary       := Task[vTi].Queue[vQi].NttPrimary;
          IF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
            DispatchedTask[vTi].BatchCode      := Batch[vTUnit].BatchCode;
            DispatchedTask[vTi].ProgramStage   := Batch[vTUnit].CurStage;
          ELSE
            DispatchedTask[vTi].BatchCode      := 0;
            DispatchedTask[vTi].ProgramStage   := 0;
          END_IF;
          DispatchedTask[vTi].Active           := TRUE;

          (* ── Emit TASK_DISPATCHED event (msg_type=1) ── *)
          vXferTotal := STC_FC_CalcTransferTime(
            iFromStn            := vTLift,
            iToStn              := vSinkStn,
            iMove                := Move[vTi],
            iFromDroppingX10   := Stations[vTLift].DrippingTime,
            iToDeviceDelayX10 := Stations[vSinkStn].DeviceDelay,
            iDripTrayDelayX10 := Transporters[vTi].DripTrayDelay
          );
          IF vXferTotal < 1.0 THEN
            vXferTotal := INT_TO_REAL(ABS(vSinkStn - vTLift)) * 8.0;
          END_IF;
  IF vXferTotal < 5.0 THEN vXferTotal := 60.0; END_IF;
          DispatchedTask[vTi].TransferTime_x10 := REAL_TO_DINT(vXferTotal * 10.0);
          IF NOT EventPendingValid THEN
            EventPending.MsgType := 1;
            EventPending.TsHi := LINT_TO_UINT(TimeS / LINT#65536);
            EventPending.TsLo := LINT_TO_UINT(TimeS MOD LINT#65536);
            EventPending.Payload[1]  := LINT_TO_INT(vTStart / LINT#65536);   (* TaskId_Hi *)
            EventPending.Payload[2]  := LINT_TO_INT(vTStart MOD LINT#65536);  (* TaskId_Lo *)
            EventPending.Payload[3]  := vTi;
            EventPending.Payload[4]  := vTUnit;
            EventPending.Payload[5]  := vTLift;
            EventPending.Payload[6]  := vSinkStn;
            IF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
              vProgStage := Batch[vTUnit].CurStage;
              EventPending.Payload[7]  := vProgStage;
              EventPending.Payload[8]  := Batch[vTUnit].BatchCode;
            ELSE
              EventPending.Payload[7]  := 0;
              EventPending.Payload[8]  := 0;
            END_IF;
            EventPending.Payload[9]  := DINT_TO_INT(vTCalcTime);
            EventPending.Payload[10] := DINT_TO_INT(Task[vTi].Queue[vQi].MinTime);
            EventPending.Payload[11] := DINT_TO_INT(Task[vTi].Queue[vQi].MaxTime);
            EventPending.Payload[12] := REAL_TO_INT(vXferTotal);
            EventPendingValid := TRUE;
          END_IF;

          (* Copy station-specific timing from config *)
          IF vTLift >= MIN_STATION_INDEX AND vTLift <= MAX_STATION_INDEX THEN
            TransporterStatus[vTi].DrippingTime := Stations[vTLift].DrippingTime;
          END_IF;

          (* Shift queue: remove position vQi, move rest up *)
          FOR vSh := vQi + 1 TO Task[vTi].Count DO
            Task[vTi].Queue[vSh - 1] := Task[vTi].Queue[vSh];
          END_FOR;
          (* Clear last slot *)
          Task[vTi].Queue[Task[vTi].Count].Unit := 0;
          Task[vTi].Queue[Task[vTi].Count].Stage := 0;
          Task[vTi].Queue[Task[vTi].Count].SrcStage := 0;
          Task[vTi].Queue[Task[vTi].Count].LiftStationTarget := 0;
          Task[vTi].Queue[Task[vTi].Count].SinkStationTarget := 0;
          Task[vTi].Queue[Task[vTi].Count].StartTime := 0;
          Task[vTi].Queue[Task[vTi].Count].FinishTime := 0;
          Task[vTi].Queue[Task[vTi].Count].CalcTime := 0;
          Task[vTi].Queue[Task[vTi].Count].MinTime := 0;
          Task[vTi].Queue[Task[vTi].Count].MaxTime := 0;
          Task[vTi].Count := Task[vTi].Count - 1;
          EXIT;  (* dispatched — stop searching this queue *)

        END_IF;  (* NOT vConflict *)

      END_IF;  (* vSinkFree *)

    END_IF;  (* time check *)

    END_IF;  (* unit at lift station *)

    END_FOR;  (* vQi — try next queue position *)

  END_IF;  (* idle + queue *)

END_FOR;

STC_FC_DispatchTask := TRUE;

END_FUNCTION

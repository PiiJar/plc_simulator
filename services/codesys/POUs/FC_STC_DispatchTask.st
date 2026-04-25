(* ===========================================================================================
 *  FC_STC_DispatchTask — Validate and dispatch tasks to transporters
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
 *  5. Dispatch: write to gTransporter → RunTasks picks it up
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_DispatchTask : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS      : INT;
    MAX_UNITS             : INT;
    MAX_STATIONS_PER_STEP : INT;
    MAX_STEPS_PER_PROGRAM : INT;
    MIN_STATION_INDEX     : INT;
    MAX_STATION_INDEX     : INT;
    SCH_DISPATCH_MARGIN_S : REAL;
    USED                  : INT;
    PROCESSED             : INT;
END_VAR

VAR_EXTERNAL
  gTransporter       : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  gTask              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  Stations           : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  gStationOccupancy  : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  gUnit              : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms  : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gNtt               : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  gBatch             : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  gMove              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  Transporters       : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  gSchedule          : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gTimeS             : LINT;
  gEventPending      : UDT_JC_EventMsgType;
  gEventPendingValid : BOOL;
  gDispatchedTask    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
END_VAR

VAR
  vTi         : INT;     (* transporter loop *)
  (* Task fields — read from queue[1] to avoid struct copy *)
  vTUnit      : INT;
  vTStage     : INT;
  vTLift      : INT;
  vTSink      : INT;
  vTStart     : LINT;
  vTFinish    : LINT;
  vTCalcTime  : DINT;
  (* Time check *)
  vTravelS    : REAL;
  vMarginS    : LINT;
  vFromIdx    : INT;
  vToIdx      : INT;
  (* Sink search *)
  vSinkStn    : INT;
  vSinkFree   : BOOL;
  vBestStn    : INT;
  vBestChange : LINT;
  vSi         : INT;
  vCandStn    : INT;
  vCandFree   : BOOL;
  vUj         : INT;
  vTgt        : INT;
  vNttIdx     : INT;     (* resolved NTT index (buffer 6/7/8) *)
  vNttCnt     : INT;
  vNttFbCnt   : INT;
  (* Conflict check *)
  vConflict   : BOOL;
  vCj         : INT;
  vTaskMin    : INT;     (* min station of our proposed task *)
  vTaskMax    : INT;     (* max station of our proposed task *)
  (* Queue position loop *)
  vQi         : INT;
  (* Shift-down after dispatch *)
  vSh         : INT;
  (* Transfer time for batch progress bar *)
  vXferTotal  : REAL;
  (* Program stage number for event *)
  vProgStage  : INT;
  (* Manual task dispatch flag *)
  vUnitOk     : BOOL;
END_VAR

FOR vTi := 1 TO MAX_TRANSPORTERS DO

  (* ── 1. Skip if not idle or queue empty ── *)
  (* Accept idle (Phase=0) OR move-away in progress (Phase=1, Status=3) *)
  IF (gTransporter[vTi].Phase = 0 OR (gTransporter[vTi].Phase = 1 AND gTransporter[vTi].Status = 3))
     AND gTask[vTi].Count >= 1 THEN

    (* Try each queue position — skip blocked tasks, dispatch first feasible *)
    FOR vQi := 1 TO gTask[vTi].Count DO

    (* Read task fields from queue position vQi *)
    vTUnit      := gTask[vTi].Queue[vQi].Unit;
    vTStage     := gTask[vTi].Queue[vQi].Stage;  (* schedule index *)
    vTLift      := gTask[vTi].Queue[vQi].LiftStationTarget;
    vTSink      := gTask[vTi].Queue[vQi].SinkStationTarget;
    vTStart     := gTask[vTi].Queue[vQi].StartTime;
    vTFinish    := gTask[vTi].Queue[vQi].FinishTime;
    vTCalcTime := gTask[vTi].Queue[vQi].CalcTime;

    (* Queue[].Stage vAlready contains ProgramStage (set by FC_STC_CreateTasks) *)
    vProgStage := vTStage;

    (* ── 1b. Lift station unit check — unit must be AT the lift station ── *)
    (* Manual tasks have Unit=0 → skip unit-vLocation check *)
    (* NOTE: CODESYS does NOT short-circuit OR — use nested IFs *)
    vUnitOk := FALSE;
    IF vTUnit = 0 THEN
      vUnitOk := TRUE;
    ELSIF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
      IF gUnit[vTUnit].Location = vTLift THEN
        vUnitOk := TRUE;
      END_IF;
    END_IF;

    IF vUnitOk THEN

    (* ── 2. Time check ── *)
    vTravelS := 0.0;
    IF gTransporter[vTi].CurrentStation > 0 AND vTLift > 0
       AND gTransporter[vTi].CurrentStation <> vTLift THEN
      vFromIdx := gTransporter[vTi].CurrentStation - MIN_STATION_INDEX;
      vToIdx   := vTLift - MIN_STATION_INDEX;
      IF vFromIdx >= 1 AND vFromIdx <= 30 AND vToIdx >= 1 AND vToIdx <= 30 THEN
        vTravelS := INT_TO_REAL(gMove[vTi].Travel[vFromIdx].ToTime[vToIdx]) / 10.0;
      END_IF;
    END_IF;

    vMarginS := vTStart - gTimeS;

    IF vMarginS <= REAL_TO_LINT(vTravelS + SCH_DISPATCH_MARGIN_S) THEN

      (* ── 3. Sink station free check ── *)
      vSinkStn := vTSink;
      vSinkFree := FALSE;

      IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
        vSinkFree := TRUE;
        FOR vUj := 1 TO MAX_UNITS DO
          IF gUnit[vUj].Location = vSinkStn AND gUnit[vUj].Status = USED THEN
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
                  IF gUnit[vUj].Location = vCandStn AND gUnit[vUj].Status = USED THEN
                    vCandFree := FALSE;
                  END_IF;
                END_FOR;
                IF vCandFree THEN
                  IF gStationOccupancy[vCandStn].ChangeTime < vBestChange THEN
                    vBestChange := gStationOccupancy[vCandStn].ChangeTime;
                    vBestStn := vCandStn;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

        ELSIF vProgStage = 0 AND vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
          (* No-treatment task — look in gNtt for alternatives *)
          vTgt := gUnit[vTUnit].Target;
          IF vTgt >= 1 AND vTgt <= 5 THEN
            (* Resolve buffer NTT index like NoTreatment does *)
            IF vTgt = 2 THEN
              IF gBatch[vTUnit].BatchCode = 0 THEN
                vNttIdx := 6;
              ELSIF gBatch[vTUnit].State = PROCESSED THEN
                vNttIdx := 8;
              ELSE
                vNttIdx := 7;
              END_IF;
            ELSE
              vNttIdx := vTgt;
            END_IF;
            (* Check primary stations *)
            vNttCnt := gNtt[vTi].Target[vNttIdx].StationCount;
            FOR vSi := 1 TO vNttCnt DO
              IF vSi <= MAX_STATIONS_PER_STEP THEN
                vCandStn := gNtt[vTi].Target[vNttIdx].Stations[vSi];
                IF vCandStn > 0 AND vCandStn <> vTSink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR vUj := 1 TO MAX_UNITS DO
                      IF gUnit[vUj].Location = vCandStn AND gUnit[vUj].Status = USED THEN
                        vCandFree := FALSE;
                      END_IF;
                    END_FOR;
                    IF vCandFree THEN
                      IF gStationOccupancy[vCandStn].ChangeTime < vBestChange THEN
                        vBestChange := gStationOccupancy[vCandStn].ChangeTime;
                        vBestStn := vCandStn;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;
            (* Check fallback stations *)
            vNttFbCnt := gNtt[vTi].Target[vNttIdx].FallbackCount;
            FOR vSi := 1 TO vNttFbCnt DO
              IF vSi <= MAX_STATIONS_PER_STEP THEN
                vCandStn := gNtt[vTi].Target[vNttIdx].FallbackStations[vSi];
                IF vCandStn > 0 AND vCandStn <> vTSink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR vUj := 1 TO MAX_UNITS DO
                      IF gUnit[vUj].Location = vCandStn AND gUnit[vUj].Status = USED THEN
                        vCandFree := FALSE;
                      END_IF;
                    END_FOR;
                    IF vCandFree THEN
                      IF gStationOccupancy[vCandStn].ChangeTime < vBestChange THEN
                        vBestChange := gStationOccupancy[vCandStn].ChangeTime;
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
          IF vCj <> vTi AND gTransporter[vCj].Phase > 0 THEN

            (* a) T2's entire active task inside our range → vConflict *)
            IF gTransporter[vCj].LiftStationTarget >= vTaskMin
               AND gTransporter[vCj].LiftStationTarget <= vTaskMax
               AND gTransporter[vCj].SinkStationTarget >= vTaskMin
               AND gTransporter[vCj].SinkStationTarget <= vTaskMax THEN
              vConflict := TRUE;
            END_IF;

            (* b) T2 delivers to one of our exact stations → vConflict *)
            IF gTransporter[vCj].SinkStationTarget = vTLift
               OR gTransporter[vCj].SinkStationTarget = vSinkStn THEN
              vConflict := TRUE;
            END_IF;

          END_IF;
        END_FOR;

        IF NOT vConflict THEN
          (* ── 5. Dispatch: assign task to transporter ── *)
          gTransporter[vTi].TaskId      := vTStart;
          gTransporter[vTi].LiftStationTarget := vTLift;
          gTransporter[vTi].SinkStationTarget := vSinkStn;
          gTransporter[vTi].CurrentTaskFinishTime := gTask[vTi].Queue[vQi].FinishTime;
          gStationOccupancy[vTi].UnitId      := vTUnit;
          gTransporter[vTi].TaskRemainingTime := vTCalcTime;

          (* ── 5b. Fill dispatched task package ── *)
          gDispatchedTask[vTi].TaskId           := vTStart;
          gDispatchedTask[vTi].UnitId           := vTUnit;
          gDispatchedTask[vTi].LiftStation      := vTLift;
          gDispatchedTask[vTi].SinkStation      := vSinkStn;
          IF vTLift >= MIN_STATION_INDEX AND vTLift <= MAX_STATION_INDEX THEN
            gDispatchedTask[vTi].LiftX              := Stations[vTLift].XPosition;
            gDispatchedTask[vTi].LiftKind           := Stations[vTLift].DryWet;
            gDispatchedTask[vTi].DroppingTime_x10   := Stations[vTLift].DrippingTime;
            gDispatchedTask[vTi].LiftDeviceDelay_x10 := Stations[vTLift].DeviceDelay;
          END_IF;
          IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
            gDispatchedTask[vTi].SinkX              := Stations[vSinkStn].XPosition;
            gDispatchedTask[vTi].SinkKind           := Stations[vSinkStn].DryWet;
            gDispatchedTask[vTi].SinkDeviceDelay_x10 := Stations[vSinkStn].DeviceDelay;
          END_IF;
          gDispatchedTask[vTi].DripTrayDelay_x10 := Transporters[vTi].DripTrayDelay;
          gDispatchedTask[vTi].TreatmentTime    := vTCalcTime;
          gDispatchedTask[vTi].MinTime          := gTask[vTi].Queue[vQi].MinTime;
          gDispatchedTask[vTi].MaxTime          := gTask[vTi].Queue[vQi].MaxTime;
          gDispatchedTask[vTi].NttPrimary       := gTask[vTi].Queue[vQi].NttPrimary;
          IF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
            gDispatchedTask[vTi].BatchCode      := gBatch[vTUnit].BatchCode;
            gDispatchedTask[vTi].ProgramStage   := gBatch[vTUnit].CurStage;
          ELSE
            gDispatchedTask[vTi].BatchCode      := 0;
            gDispatchedTask[vTi].ProgramStage   := 0;
          END_IF;
          gDispatchedTask[vTi].Active           := TRUE;

          (* ── Emit TASK_DISPATCHED event (msg_type=1) ── *)
          vXferTotal := FC_STC_CalcTransferTime(
            iFromStn            := vTLift,
            iToStn              := vSinkStn,
            iMove                := gMove[vTi],
            iFromDroppingX10   := Stations[vTLift].DrippingTime,
            iToDeviceDelayX10 := Stations[vSinkStn].DeviceDelay,
            iDripTrayDelayX10 := Transporters[vTi].DripTrayDelay
          );
          IF vXferTotal < 1.0 THEN
            vXferTotal := INT_TO_REAL(ABS(vSinkStn - vTLift)) * 8.0;
          END_IF;
  IF vXferTotal < 5.0 THEN vXferTotal := 60.0; END_IF;
          gDispatchedTask[vTi].TransferTime_x10 := REAL_TO_DINT(vXferTotal * 10.0);
          IF NOT gEventPendingValid THEN
            gEventPending.MsgType := 1;
            gEventPending.TsHi := LINT_TO_UINT(gTimeS / LINT#65536);
            gEventPending.TsLo := LINT_TO_UINT(gTimeS MOD LINT#65536);
            gEventPending.Payload[1]  := LINT_TO_INT(vTStart / LINT#65536);   (* TaskId_Hi *)
            gEventPending.Payload[2]  := LINT_TO_INT(vTStart MOD LINT#65536);  (* TaskId_Lo *)
            gEventPending.Payload[3]  := vTi;
            gEventPending.Payload[4]  := vTUnit;
            gEventPending.Payload[5]  := vTLift;
            gEventPending.Payload[6]  := vSinkStn;
            IF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
              vProgStage := gBatch[vTUnit].CurStage;
              gEventPending.Payload[7]  := vProgStage;
              gEventPending.Payload[8]  := gBatch[vTUnit].BatchCode;
            ELSE
              gEventPending.Payload[7]  := 0;
              gEventPending.Payload[8]  := 0;
            END_IF;
            gEventPending.Payload[9]  := DINT_TO_INT(vTCalcTime);
            gEventPending.Payload[10] := DINT_TO_INT(gTask[vTi].Queue[vQi].MinTime);
            gEventPending.Payload[11] := DINT_TO_INT(gTask[vTi].Queue[vQi].MaxTime);
            gEventPending.Payload[12] := REAL_TO_INT(vXferTotal);
            gEventPendingValid := TRUE;
          END_IF;

          (* Copy station-specific timing from config *)
          IF vTLift >= MIN_STATION_INDEX AND vTLift <= MAX_STATION_INDEX THEN
            gTransporter[vTi].DrippingTime := Stations[vTLift].DrippingTime;
          END_IF;

          (* Shift queue: remove position vQi, move rest up *)
          FOR vSh := vQi + 1 TO gTask[vTi].Count DO
            gTask[vTi].Queue[vSh - 1] := gTask[vTi].Queue[vSh];
          END_FOR;
          (* Clear last slot *)
          gTask[vTi].Queue[gTask[vTi].Count].Unit := 0;
          gTask[vTi].Queue[gTask[vTi].Count].Stage := 0;
          gTask[vTi].Queue[gTask[vTi].Count].SrcStage := 0;
          gTask[vTi].Queue[gTask[vTi].Count].LiftStationTarget := 0;
          gTask[vTi].Queue[gTask[vTi].Count].SinkStationTarget := 0;
          gTask[vTi].Queue[gTask[vTi].Count].StartTime := 0;
          gTask[vTi].Queue[gTask[vTi].Count].FinishTime := 0;
          gTask[vTi].Queue[gTask[vTi].Count].CalcTime := 0;
          gTask[vTi].Queue[gTask[vTi].Count].MinTime := 0;
          gTask[vTi].Queue[gTask[vTi].Count].MaxTime := 0;
          gTask[vTi].Count := gTask[vTi].Count - 1;
          EXIT;  (* dispatched — stop searching this queue *)

        END_IF;  (* NOT vConflict *)

      END_IF;  (* vSinkFree *)

    END_IF;  (* time check *)

    END_IF;  (* unit at lift station *)

    END_FOR;  (* vQi — try next queue position *)

  END_IF;  (* idle + queue *)

END_FOR;

FC_STC_DispatchTask := TRUE;

END_FUNCTION

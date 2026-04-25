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
 *  5. Dispatch: write to g_transporter → RunTasks picks it up
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
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  g_task                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  g_station_occupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_ntt                     : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_time_s                  : LINT;
  g_event_pending           : UDT_JC_EventMsgType;
  g_event_pending_valid     : BOOL;
  g_dispatched_task         : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
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
  IF (g_transporter[vTi].Phase = 0 OR (g_transporter[vTi].Phase = 1 AND g_transporter[vTi].Status = 3))
     AND g_task[vTi].Count >= 1 THEN

    (* Try each queue position — skip blocked tasks, dispatch first feasible *)
    FOR vQi := 1 TO g_task[vTi].Count DO

    (* Read task fields from queue position vQi *)
    vTUnit      := g_task[vTi].Queue[vQi].Unit;
    vTStage     := g_task[vTi].Queue[vQi].Stage;  (* schedule index *)
    vTLift      := g_task[vTi].Queue[vQi].LiftStationTarget;
    vTSink      := g_task[vTi].Queue[vQi].SinkStationTarget;
    vTStart     := g_task[vTi].Queue[vQi].StartTime;
    vTFinish    := g_task[vTi].Queue[vQi].FinishTime;
    vTCalcTime := g_task[vTi].Queue[vQi].CalcTime;

    (* Queue[].Stage vAlready contains ProgramStage (set by FC_STC_CreateTasks) *)
    vProgStage := vTStage;

    (* ── 1b. Lift station unit check — unit must be AT the lift station ── *)
    (* Manual tasks have Unit=0 → skip unit-vLocation check *)
    (* NOTE: CODESYS does NOT short-circuit OR — use nested IFs *)
    vUnitOk := FALSE;
    IF vTUnit = 0 THEN
      vUnitOk := TRUE;
    ELSIF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
      IF g_unit[vTUnit].Location = vTLift THEN
        vUnitOk := TRUE;
      END_IF;
    END_IF;

    IF vUnitOk THEN

    (* ── 2. Time check ── *)
    vTravelS := 0.0;
    IF g_transporter[vTi].CurrentStation > 0 AND vTLift > 0
       AND g_transporter[vTi].CurrentStation <> vTLift THEN
      vFromIdx := g_transporter[vTi].CurrentStation - MIN_STATION_INDEX;
      vToIdx   := vTLift - MIN_STATION_INDEX;
      IF vFromIdx >= 1 AND vFromIdx <= 30 AND vToIdx >= 1 AND vToIdx <= 30 THEN
        vTravelS := INT_TO_REAL(g_move[vTi].Travel[vFromIdx].ToTime[vToIdx]) / 10.0;
      END_IF;
    END_IF;

    vMarginS := vTStart - g_time_s;

    IF vMarginS <= REAL_TO_LINT(vTravelS + SCH_DISPATCH_MARGIN_S) THEN

      (* ── 3. Sink station free check ── *)
      vSinkStn := vTSink;
      vSinkFree := FALSE;

      IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
        vSinkFree := TRUE;
        FOR vUj := 1 TO MAX_UNITS DO
          IF g_unit[vUj].Location = vSinkStn AND g_unit[vUj].Status = USED THEN
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
                  IF g_unit[vUj].Location = vCandStn AND g_unit[vUj].Status = USED THEN
                    vCandFree := FALSE;
                  END_IF;
                END_FOR;
                IF vCandFree THEN
                  IF g_station_occupancy[vCandStn].ChangeTime < vBestChange THEN
                    vBestChange := g_station_occupancy[vCandStn].ChangeTime;
                    vBestStn := vCandStn;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

        ELSIF vProgStage = 0 AND vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
          (* No-treatment task — look in g_ntt for alternatives *)
          vTgt := g_unit[vTUnit].Target;
          IF vTgt >= 1 AND vTgt <= 5 THEN
            (* Resolve buffer NTT index like NoTreatment does *)
            IF vTgt = 2 THEN
              IF g_batch[vTUnit].BatchCode = 0 THEN
                vNttIdx := 6;
              ELSIF g_batch[vTUnit].State = PROCESSED THEN
                vNttIdx := 8;
              ELSE
                vNttIdx := 7;
              END_IF;
            ELSE
              vNttIdx := vTgt;
            END_IF;
            (* Check primary stations *)
            vNttCnt := g_ntt[vTi].Target[vNttIdx].StationCount;
            FOR vSi := 1 TO vNttCnt DO
              IF vSi <= MAX_STATIONS_PER_STEP THEN
                vCandStn := g_ntt[vTi].Target[vNttIdx].Stations[vSi];
                IF vCandStn > 0 AND vCandStn <> vTSink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR vUj := 1 TO MAX_UNITS DO
                      IF g_unit[vUj].Location = vCandStn AND g_unit[vUj].Status = USED THEN
                        vCandFree := FALSE;
                      END_IF;
                    END_FOR;
                    IF vCandFree THEN
                      IF g_station_occupancy[vCandStn].ChangeTime < vBestChange THEN
                        vBestChange := g_station_occupancy[vCandStn].ChangeTime;
                        vBestStn := vCandStn;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;
            (* Check fallback stations *)
            vNttFbCnt := g_ntt[vTi].Target[vNttIdx].FallbackCount;
            FOR vSi := 1 TO vNttFbCnt DO
              IF vSi <= MAX_STATIONS_PER_STEP THEN
                vCandStn := g_ntt[vTi].Target[vNttIdx].FallbackStations[vSi];
                IF vCandStn > 0 AND vCandStn <> vTSink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR vUj := 1 TO MAX_UNITS DO
                      IF g_unit[vUj].Location = vCandStn AND g_unit[vUj].Status = USED THEN
                        vCandFree := FALSE;
                      END_IF;
                    END_FOR;
                    IF vCandFree THEN
                      IF g_station_occupancy[vCandStn].ChangeTime < vBestChange THEN
                        vBestChange := g_station_occupancy[vCandStn].ChangeTime;
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
          IF vCj <> vTi AND g_transporter[vCj].Phase > 0 THEN

            (* a) T2's entire active task inside our range → vConflict *)
            IF g_transporter[vCj].LiftStationTarget >= vTaskMin
               AND g_transporter[vCj].LiftStationTarget <= vTaskMax
               AND g_transporter[vCj].SinkStationTarget >= vTaskMin
               AND g_transporter[vCj].SinkStationTarget <= vTaskMax THEN
              vConflict := TRUE;
            END_IF;

            (* b) T2 delivers to one of our exact stations → vConflict *)
            IF g_transporter[vCj].SinkStationTarget = vTLift
               OR g_transporter[vCj].SinkStationTarget = vSinkStn THEN
              vConflict := TRUE;
            END_IF;

          END_IF;
        END_FOR;

        IF NOT vConflict THEN
          (* ── 5. Dispatch: assign task to transporter ── *)
          g_transporter[vTi].TaskId      := vTStart;
          g_transporter[vTi].LiftStationTarget := vTLift;
          g_transporter[vTi].SinkStationTarget := vSinkStn;
          g_transporter[vTi].CurrentTaskFinishTime := g_task[vTi].Queue[vQi].FinishTime;
          g_station_occupancy[vTi].UnitId      := vTUnit;
          g_transporter[vTi].TaskRemainingTime := vTCalcTime;

          (* ── 5b. Fill dispatched task package ── *)
          g_dispatched_task[vTi].TaskId           := vTStart;
          g_dispatched_task[vTi].UnitId           := vTUnit;
          g_dispatched_task[vTi].LiftStation      := vTLift;
          g_dispatched_task[vTi].SinkStation      := vSinkStn;
          IF vTLift >= MIN_STATION_INDEX AND vTLift <= MAX_STATION_INDEX THEN
            g_dispatched_task[vTi].LiftX              := Stations[vTLift].XPosition;
            g_dispatched_task[vTi].LiftKind           := Stations[vTLift].DryWet;
            g_dispatched_task[vTi].DroppingTime_x10   := Stations[vTLift].DrippingTime;
            g_dispatched_task[vTi].LiftDeviceDelay_x10 := Stations[vTLift].DeviceDelay;
          END_IF;
          IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
            g_dispatched_task[vTi].SinkX              := Stations[vSinkStn].XPosition;
            g_dispatched_task[vTi].SinkKind           := Stations[vSinkStn].DryWet;
            g_dispatched_task[vTi].SinkDeviceDelay_x10 := Stations[vSinkStn].DeviceDelay;
          END_IF;
          g_dispatched_task[vTi].DripTrayDelay_x10 := Transporters[vTi].DripTrayDelay;
          g_dispatched_task[vTi].TreatmentTime    := vTCalcTime;
          g_dispatched_task[vTi].MinTime          := g_task[vTi].Queue[vQi].MinTime;
          g_dispatched_task[vTi].MaxTime          := g_task[vTi].Queue[vQi].MaxTime;
          g_dispatched_task[vTi].NttPrimary       := g_task[vTi].Queue[vQi].NttPrimary;
          IF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
            g_dispatched_task[vTi].BatchCode      := g_batch[vTUnit].BatchCode;
            g_dispatched_task[vTi].ProgramStage   := g_batch[vTUnit].CurStage;
          ELSE
            g_dispatched_task[vTi].BatchCode      := 0;
            g_dispatched_task[vTi].ProgramStage   := 0;
          END_IF;
          g_dispatched_task[vTi].Active           := TRUE;

          (* ── Emit TASK_DISPATCHED event (msg_type=1) ── *)
          vXferTotal := FC_STC_CalcTransferTime(
            iFromStn            := vTLift,
            iToStn              := vSinkStn,
            iMove                := g_move[vTi],
            iFromDroppingX10   := Stations[vTLift].DrippingTime,
            iToDeviceDelayX10 := Stations[vSinkStn].DeviceDelay,
            iDripTrayDelayX10 := Transporters[vTi].DripTrayDelay
          );
          IF vXferTotal < 1.0 THEN
            vXferTotal := INT_TO_REAL(ABS(vSinkStn - vTLift)) * 8.0;
          END_IF;
  IF vXferTotal < 5.0 THEN vXferTotal := 60.0; END_IF;
          g_dispatched_task[vTi].TransferTime_x10 := REAL_TO_DINT(vXferTotal * 10.0);
          IF NOT g_event_pending_valid THEN
            g_event_pending.MsgType := 1;
            g_event_pending.TsHi := LINT_TO_UINT(g_time_s / LINT#65536);
            g_event_pending.TsLo := LINT_TO_UINT(g_time_s MOD LINT#65536);
            g_event_pending.Payload[1]  := LINT_TO_INT(vTStart / LINT#65536);   (* TaskId_Hi *)
            g_event_pending.Payload[2]  := LINT_TO_INT(vTStart MOD LINT#65536);  (* TaskId_Lo *)
            g_event_pending.Payload[3]  := vTi;
            g_event_pending.Payload[4]  := vTUnit;
            g_event_pending.Payload[5]  := vTLift;
            g_event_pending.Payload[6]  := vSinkStn;
            IF vTUnit >= 1 AND vTUnit <= MAX_UNITS THEN
              vProgStage := g_batch[vTUnit].CurStage;
              g_event_pending.Payload[7]  := vProgStage;
              g_event_pending.Payload[8]  := g_batch[vTUnit].BatchCode;
            ELSE
              g_event_pending.Payload[7]  := 0;
              g_event_pending.Payload[8]  := 0;
            END_IF;
            g_event_pending.Payload[9]  := DINT_TO_INT(vTCalcTime);
            g_event_pending.Payload[10] := DINT_TO_INT(g_task[vTi].Queue[vQi].MinTime);
            g_event_pending.Payload[11] := DINT_TO_INT(g_task[vTi].Queue[vQi].MaxTime);
            g_event_pending.Payload[12] := REAL_TO_INT(vXferTotal);
            g_event_pending_valid := TRUE;
          END_IF;

          (* Copy station-specific timing from config *)
          IF vTLift >= MIN_STATION_INDEX AND vTLift <= MAX_STATION_INDEX THEN
            g_transporter[vTi].DrippingTime := Stations[vTLift].DrippingTime;
          END_IF;

          (* Shift queue: remove position vQi, move rest up *)
          FOR vSh := vQi + 1 TO g_task[vTi].Count DO
            g_task[vTi].Queue[vSh - 1] := g_task[vTi].Queue[vSh];
          END_FOR;
          (* Clear last slot *)
          g_task[vTi].Queue[g_task[vTi].Count].Unit := 0;
          g_task[vTi].Queue[g_task[vTi].Count].Stage := 0;
          g_task[vTi].Queue[g_task[vTi].Count].SrcStage := 0;
          g_task[vTi].Queue[g_task[vTi].Count].LiftStationTarget := 0;
          g_task[vTi].Queue[g_task[vTi].Count].SinkStationTarget := 0;
          g_task[vTi].Queue[g_task[vTi].Count].StartTime := 0;
          g_task[vTi].Queue[g_task[vTi].Count].FinishTime := 0;
          g_task[vTi].Queue[g_task[vTi].Count].CalcTime := 0;
          g_task[vTi].Queue[g_task[vTi].Count].MinTime := 0;
          g_task[vTi].Queue[g_task[vTi].Count].MaxTime := 0;
          g_task[vTi].Count := g_task[vTi].Count - 1;
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

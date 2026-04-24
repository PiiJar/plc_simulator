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
  ti                        : INT;     (* transporter loop *)
  (* Task fields — read from queue[1] to avoid struct copy *)
  t_unit                    : INT;
  t_stage                   : INT;
  t_lift                    : INT;
  t_sink                    : INT;
  t_start                   : LINT;
  t_finish                  : LINT;
  t_calc_time               : DINT;
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
  si                        : INT;
  vCandStn                  : INT;
  vCandFree                 : BOOL;
  uj                        : INT;
  tgt                       : INT;
  vNttIdx                   : INT;     (* resolved NTT index (buffer 6/7/8) *)
  vNttCnt                   : INT;
  vNttFbCnt                : INT;
  (* Conflict check *)
  vConflict                  : BOOL;
  cj                        : INT;
  vTaskMin                  : INT;     (* min station of our proposed task *)
  vTaskMax                  : INT;     (* max station of our proposed task *)
  (* Queue position loop *)
  qi                        : INT;
  (* Shift-down after dispatch *)
  sh                        : INT;
  (* Transfer time for batch progress bar *)
  vXferTotal                : REAL;
  (* Program stage number for event *)
  vProgStage                : INT;
  (* Manual task dispatch flag *)
  vUnitOk                   : BOOL;
END_VAR

FOR ti := 1 TO MAX_TRANSPORTERS DO

  (* ── 1. Skip if not idle or queue empty ── *)
  (* Accept idle (Phase=0) OR move-away in progress (Phase=1, Status=3) *)
  IF (g_transporter[ti].Phase = 0 OR (g_transporter[ti].Phase = 1 AND g_transporter[ti].Status = 3))
     AND g_task[ti].Count >= 1 THEN

    (* Try each queue position — skip blocked tasks, dispatch first feasible *)
    FOR qi := 1 TO g_task[ti].Count DO

    (* Read task fields from queue position qi *)
    t_unit      := g_task[ti].Queue[qi].Unit;
    t_stage     := g_task[ti].Queue[qi].Stage;  (* schedule index *)
    t_lift      := g_task[ti].Queue[qi].LiftStationTarget;
    t_sink      := g_task[ti].Queue[qi].SinkStationTarget;
    t_start     := g_task[ti].Queue[qi].StartTime;
    t_finish    := g_task[ti].Queue[qi].FinishTime;
    t_calc_time := g_task[ti].Queue[qi].CalcTime;

    (* Queue[].Stage vAlready contains ProgramStage (set by FC_STC_CreateTasks) *)
    vProgStage := t_stage;

    (* ── 1b. Lift station unit check — unit must be AT the lift station ── *)
    (* Manual tasks have Unit=0 → skip unit-vLocation check *)
    (* NOTE: CODESYS does NOT short-circuit OR — use nested IFs *)
    vUnitOk := FALSE;
    IF t_unit = 0 THEN
      vUnitOk := TRUE;
    ELSIF t_unit >= 1 AND t_unit <= MAX_UNITS THEN
      IF g_unit[t_unit].Location = t_lift THEN
        vUnitOk := TRUE;
      END_IF;
    END_IF;

    IF vUnitOk THEN

    (* ── 2. Time check ── *)
    vTravelS := 0.0;
    IF g_transporter[ti].CurrentStation > 0 AND t_lift > 0
       AND g_transporter[ti].CurrentStation <> t_lift THEN
      vFromIdx := g_transporter[ti].CurrentStation - MIN_STATION_INDEX;
      vToIdx   := t_lift - MIN_STATION_INDEX;
      IF vFromIdx >= 1 AND vFromIdx <= 30 AND vToIdx >= 1 AND vToIdx <= 30 THEN
        vTravelS := INT_TO_REAL(g_move[ti].Travel[vFromIdx].ToTime[vToIdx]) / 10.0;
      END_IF;
    END_IF;

    vMarginS := t_start - g_time_s;

    IF vMarginS <= REAL_TO_LINT(vTravelS + SCH_DISPATCH_MARGIN_S) THEN

      (* ── 3. Sink station free check ── *)
      vSinkStn := t_sink;
      vSinkFree := FALSE;

      IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
        vSinkFree := TRUE;
        FOR uj := 1 TO MAX_UNITS DO
          IF g_unit[uj].Location = vSinkStn AND g_unit[uj].Status = USED THEN
            vSinkFree := FALSE;
          END_IF;
        END_FOR;
      END_IF;

      IF NOT vSinkFree THEN
        (* Search alternative parallel stations *)
        vBestStn := 0;
        vBestChange := LINT#2000000000;

        IF vProgStage >= 1 AND vProgStage <= MAX_STEPS_PER_PROGRAM
           AND t_unit >= 1 AND t_unit <= MAX_UNITS THEN
          (* Treatment task — look in TreatmentPrograms for parallel stations *)
          FOR si := 0 TO MAX_STATIONS_PER_STEP - 1 DO
            vCandStn := TreatmentPrograms[t_unit].Steps[vProgStage].Stations[si];
            IF vCandStn > 0 AND vCandStn <> t_sink THEN
              IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                vCandFree := TRUE;
                FOR uj := 1 TO MAX_UNITS DO
                  IF g_unit[uj].Location = vCandStn AND g_unit[uj].Status = USED THEN
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

        ELSIF vProgStage = 0 AND t_unit >= 1 AND t_unit <= MAX_UNITS THEN
          (* No-treatment task — look in g_ntt for alternatives *)
          tgt := g_unit[t_unit].Target;
          IF tgt >= 1 AND tgt <= 5 THEN
            (* Resolve buffer NTT index like NoTreatment does *)
            IF tgt = 2 THEN
              IF g_batch[t_unit].BatchCode = 0 THEN
                vNttIdx := 6;
              ELSIF g_batch[t_unit].State = PROCESSED THEN
                vNttIdx := 8;
              ELSE
                vNttIdx := 7;
              END_IF;
            ELSE
              vNttIdx := tgt;
            END_IF;
            (* Check primary stations *)
            vNttCnt := g_ntt[ti].Target[vNttIdx].StationCount;
            FOR si := 1 TO vNttCnt DO
              IF si <= MAX_STATIONS_PER_STEP THEN
                vCandStn := g_ntt[ti].Target[vNttIdx].Stations[si];
                IF vCandStn > 0 AND vCandStn <> t_sink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR uj := 1 TO MAX_UNITS DO
                      IF g_unit[uj].Location = vCandStn AND g_unit[uj].Status = USED THEN
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
            vNttFbCnt := g_ntt[ti].Target[vNttIdx].FallbackCount;
            FOR si := 1 TO vNttFbCnt DO
              IF si <= MAX_STATIONS_PER_STEP THEN
                vCandStn := g_ntt[ti].Target[vNttIdx].FallbackStations[si];
                IF vCandStn > 0 AND vCandStn <> t_sink THEN
                  IF vCandStn >= MIN_STATION_INDEX AND vCandStn <= MAX_STATION_INDEX THEN
                    vCandFree := TRUE;
                    FOR uj := 1 TO MAX_UNITS DO
                      IF g_unit[uj].Location = vCandStn AND g_unit[uj].Status = USED THEN
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

        IF t_lift <= vSinkStn THEN
          vTaskMin := t_lift;
          vTaskMax := vSinkStn;
        ELSE
          vTaskMin := vSinkStn;
          vTaskMax := t_lift;
        END_IF;

        FOR cj := 1 TO MAX_TRANSPORTERS DO
          IF cj <> ti AND g_transporter[cj].Phase > 0 THEN

            (* a) T2's entire active task inside our range → vConflict *)
            IF g_transporter[cj].LiftStationTarget >= vTaskMin
               AND g_transporter[cj].LiftStationTarget <= vTaskMax
               AND g_transporter[cj].SinkStationTarget >= vTaskMin
               AND g_transporter[cj].SinkStationTarget <= vTaskMax THEN
              vConflict := TRUE;
            END_IF;

            (* b) T2 delivers to one of our exact stations → vConflict *)
            IF g_transporter[cj].SinkStationTarget = t_lift
               OR g_transporter[cj].SinkStationTarget = vSinkStn THEN
              vConflict := TRUE;
            END_IF;

          END_IF;
        END_FOR;

        IF NOT vConflict THEN
          (* ── 5. Dispatch: assign task to transporter ── *)
          g_transporter[ti].TaskId      := t_start;
          g_transporter[ti].LiftStationTarget := t_lift;
          g_transporter[ti].SinkStationTarget := vSinkStn;
          g_transporter[ti].CurrentTaskFinishTime := g_task[ti].Queue[qi].FinishTime;
          g_station_occupancy[ti].UnitId      := t_unit;
          g_transporter[ti].TaskRemainingTime := t_calc_time;

          (* ── 5b. Fill dispatched task package ── *)
          g_dispatched_task[ti].TaskId           := t_start;
          g_dispatched_task[ti].UnitId           := t_unit;
          g_dispatched_task[ti].LiftStation      := t_lift;
          g_dispatched_task[ti].SinkStation      := vSinkStn;
          IF t_lift >= MIN_STATION_INDEX AND t_lift <= MAX_STATION_INDEX THEN
            g_dispatched_task[ti].LiftX              := Stations[t_lift].XPosition;
            g_dispatched_task[ti].LiftKind           := Stations[t_lift].DryWet;
            g_dispatched_task[ti].DroppingTime_x10   := Stations[t_lift].DrippingTime;
            g_dispatched_task[ti].LiftDeviceDelay_x10 := Stations[t_lift].DeviceDelay;
          END_IF;
          IF vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
            g_dispatched_task[ti].SinkX              := Stations[vSinkStn].XPosition;
            g_dispatched_task[ti].SinkKind           := Stations[vSinkStn].DryWet;
            g_dispatched_task[ti].SinkDeviceDelay_x10 := Stations[vSinkStn].DeviceDelay;
          END_IF;
          g_dispatched_task[ti].DripTrayDelay_x10 := Transporters[ti].DripTrayDelay;
          g_dispatched_task[ti].TreatmentTime    := t_calc_time;
          g_dispatched_task[ti].MinTime          := g_task[ti].Queue[qi].MinTime;
          g_dispatched_task[ti].MaxTime          := g_task[ti].Queue[qi].MaxTime;
          g_dispatched_task[ti].NttPrimary       := g_task[ti].Queue[qi].NttPrimary;
          IF t_unit >= 1 AND t_unit <= MAX_UNITS THEN
            g_dispatched_task[ti].BatchCode      := g_batch[t_unit].BatchCode;
            g_dispatched_task[ti].ProgramStage   := g_batch[t_unit].CurStage;
          ELSE
            g_dispatched_task[ti].BatchCode      := 0;
            g_dispatched_task[ti].ProgramStage   := 0;
          END_IF;
          g_dispatched_task[ti].Active           := TRUE;

          (* ── Emit TASK_DISPATCHED event (msg_type=1) ── *)
          vXferTotal := FC_STC_CalcTransferTime(
            iFromStn            := t_lift,
            iToStn              := vSinkStn,
            iMove                := g_move[ti],
            i_from_dropping_x10   := Stations[t_lift].DrippingTime,
            i_to_device_delay_x10 := Stations[vSinkStn].DeviceDelay,
            iDripTrayDelayX10 := Transporters[ti].DripTrayDelay
          );
          IF vXferTotal < 1.0 THEN
            vXferTotal := INT_TO_REAL(ABS(vSinkStn - t_lift)) * 8.0;
          END_IF;
  IF vXferTotal < 5.0 THEN vXferTotal := 60.0; END_IF;
          g_dispatched_task[ti].TransferTime_x10 := REAL_TO_DINT(vXferTotal * 10.0);
          IF NOT g_event_pending_valid THEN
            g_event_pending.MsgType := 1;
            g_event_pending.TsHi := LINT_TO_UINT(g_time_s / LINT#65536);
            g_event_pending.TsLo := LINT_TO_UINT(g_time_s MOD LINT#65536);
            g_event_pending.Payload[1]  := LINT_TO_INT(t_start / LINT#65536);   (* TaskId_Hi *)
            g_event_pending.Payload[2]  := LINT_TO_INT(t_start MOD LINT#65536);  (* TaskId_Lo *)
            g_event_pending.Payload[3]  := ti;
            g_event_pending.Payload[4]  := t_unit;
            g_event_pending.Payload[5]  := t_lift;
            g_event_pending.Payload[6]  := vSinkStn;
            IF t_unit >= 1 AND t_unit <= MAX_UNITS THEN
              vProgStage := g_batch[t_unit].CurStage;
              g_event_pending.Payload[7]  := vProgStage;
              g_event_pending.Payload[8]  := g_batch[t_unit].BatchCode;
            ELSE
              g_event_pending.Payload[7]  := 0;
              g_event_pending.Payload[8]  := 0;
            END_IF;
            g_event_pending.Payload[9]  := DINT_TO_INT(t_calc_time);
            g_event_pending.Payload[10] := DINT_TO_INT(g_task[ti].Queue[qi].MinTime);
            g_event_pending.Payload[11] := DINT_TO_INT(g_task[ti].Queue[qi].MaxTime);
            g_event_pending.Payload[12] := REAL_TO_INT(vXferTotal);
            g_event_pending_valid := TRUE;
          END_IF;

          (* Copy station-specific timing from config *)
          IF t_lift >= MIN_STATION_INDEX AND t_lift <= MAX_STATION_INDEX THEN
            g_transporter[ti].DrippingTime := Stations[t_lift].DrippingTime;
          END_IF;

          (* Shift queue: remove position qi, move rest up *)
          FOR sh := qi + 1 TO g_task[ti].Count DO
            g_task[ti].Queue[sh - 1] := g_task[ti].Queue[sh];
          END_FOR;
          (* Clear last slot *)
          g_task[ti].Queue[g_task[ti].Count].Unit := 0;
          g_task[ti].Queue[g_task[ti].Count].Stage := 0;
          g_task[ti].Queue[g_task[ti].Count].SrcStage := 0;
          g_task[ti].Queue[g_task[ti].Count].LiftStationTarget := 0;
          g_task[ti].Queue[g_task[ti].Count].SinkStationTarget := 0;
          g_task[ti].Queue[g_task[ti].Count].StartTime := 0;
          g_task[ti].Queue[g_task[ti].Count].FinishTime := 0;
          g_task[ti].Queue[g_task[ti].Count].CalcTime := 0;
          g_task[ti].Queue[g_task[ti].Count].MinTime := 0;
          g_task[ti].Queue[g_task[ti].Count].MaxTime := 0;
          g_task[ti].Count := g_task[ti].Count - 1;
          EXIT;  (* dispatched — stop searching this queue *)

        END_IF;  (* NOT vConflict *)

      END_IF;  (* vSinkFree *)

    END_IF;  (* time check *)

    END_IF;  (* unit at lift station *)

    END_FOR;  (* qi — try next queue position *)

  END_IF;  (* idle + queue *)

END_FOR;

FC_STC_DispatchTask := TRUE;

END_FUNCTION

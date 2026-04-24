(* ===========================================================================================
 *  FC_TSK_NoTreatment — Create no-treatment transfer tasks
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Scans units with a target and creates transfer tasks
 *  using the g_ntt destination table.
 *
 *  VAR_IN_OUT: ioTask — only mutable array (inserts NTT tasks).
 *  All other globals are read-only via VAR_EXTERNAL.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_TSK_NoTreatment : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTimeS                  : LINT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_STATIONS_PER_STEP   : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    MAX_UNITS               : INT;
    MAX_TASK_QUEUE          : INT;
    SCH_DISPATCH_MARGIN_S   : REAL;
    NOT_PROCESSED           : INT;
    PROCESSED               : INT;
    USED                    : INT;
END_VAR

VAR_EXTERNAL
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  g_ntt                     : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  g_station_occupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
END_VAR

VAR
  ui                        : INT;
  vLoc                       : INT;
  tgt                       : INT;
  cov_t                     : INT;
  ai                        : INT;
  vCovers                    : BOOL;
  vDone                      : BOOL;
  vDest                      : UDT_JC_NttDestType;
  vNttIdx                   : INT;
  vOnPrimary                : BOOL;
  vOnFallback               : BOOL;
  vPrimaryFree              : BOOL;
  vDestStn                  : INT;
  si                        : INT;
  vStationIdx               : INT;
  vStnFree                  : BOOL;
  uj                        : INT;
  ti                        : INT;
  vAlready                   : BOOL;
  qi2                       : INT;
  vXferS                    : REAL;
  vTaskStart                : LINT;
  vTaskEnd                  : LINT;
  vSlotStart                : LINT;
  vTmpMove                  : UDT_JC_MoveTimesType;
  vSlotEnd                  : LINT;
  latest_end                : LINT;
  vTravelFromSink          : REAL;
  vTravelToLiftS          : REAL;
  vTransPos                 : INT;
  vNttDuration              : LINT;
  vSlotOk                   : BOOL;
  sh                        : INT;

  (* Idle-stretch: extend blocking batch CalTime to make room for NTT -----------------------*)
  vStretchPending           : BOOL;
  vStretchUnitId           : INT;
  vStretchDeficit           : DINT;
  vStretchAvail             : DINT;

  (* Multi-transporter shared-vArea idle check -----------------------------------------------*)
  ot                        : INT;
  oq                        : INT;
  vOverlapConflict          : BOOL;
  vDestX                    : DINT;
  vAvoidDist                : DINT;
  cov_min_x                 : DINT;
  cov_max_x                 : DINT;
  ot_min_x                  : DINT;
  ot_max_x                  : DINT;
  zone_min_x                : DINT;
  zone_max_x                : DINT;
  danger_min                : DINT;
  danger_max                : DINT;
  (* Shared-vArea timing: NTT split into own-vArea + shared-vArea portions ---------------------*)
  vLocIdx                   : INT;
  vLocX                     : DINT;
  phase2_s                  : REAL;
  vSharedEntry              : LINT;
  vSharedTime               : REAL;
  ot_idle_ok                : BOOL;
  ot_idle_start             : LINT;
  ot_idle_end               : LINT;
  ot_next_lift              : INT;
  ot_dispatch_from          : INT;
  ot_travel_to_next         : REAL;

  (* Idle-stretch for other transporter: widen idle gap by extending blocker CalTime --------*)
  ot_stretch_pending        : BOOL;
  ot_stretch_unit_id        : INT;
  ot_stretch_deficit        : DINT;
  ot_stretch_avail          : DINT;
  ot_stretch_need           : LINT;
  ot_stretch_ok             : BOOL;
END_VAR

FC_TSK_NoTreatment := TRUE;

FOR ui := 1 TO MAX_UNITS DO
  tgt := g_unit[ui].Target;
  vLoc := g_unit[ui].vLocation;

  IF tgt >= 1 AND tgt <= 5 AND vLoc >= MIN_STATION_INDEX THEN

    IF tgt = 3 AND (g_batch[ui].BatchCode = 0 OR g_batch[ui].State <> NOT_PROCESSED) THEN
      CONTINUE;
    END_IF;

    vAlready := FALSE;
    FOR ti := 1 TO MAX_TRANSPORTERS DO
      IF NOT vAlready THEN
        IF g_transporter[ti].Phase > 0 AND g_station_occupancy[ti].UnitId = ui THEN
          vAlready := TRUE;
        END_IF;
        FOR qi2 := 1 TO ioTask[ti].Count DO
          IF NOT vAlready THEN
            IF ioTask[ti].Queue[qi2].Unit = ui THEN
              vAlready := TRUE;
            END_IF;
          END_IF;
        END_FOR;
      END_IF;
    END_FOR;

    IF NOT vAlready THEN

    vDone := FALSE;
    FOR cov_t := 1 TO MAX_TRANSPORTERS DO
      IF NOT vDone THEN

      vCovers := FALSE;
      FOR ai := 1 TO 4 DO
        IF NOT vCovers THEN
          IF Transporters[cov_t].TaskArea[ai].MinLift > 0 OR Transporters[cov_t].TaskArea[ai].MaxLift > 0 THEN
            IF vLoc >= Transporters[cov_t].TaskArea[ai].MinLift AND vLoc <= Transporters[cov_t].TaskArea[ai].MaxLift THEN
              vCovers := TRUE;
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      IF vCovers AND g_transporter[cov_t].IsActive
         AND (g_transporter[cov_t].Phase = 0 OR tgt = 5) THEN

        IF tgt = 2 THEN
          IF g_batch[ui].BatchCode = 0 THEN vNttIdx := 6;
          ELSIF g_batch[ui].State = PROCESSED THEN vNttIdx := 8;
  ELSE vNttIdx := 7; END_IF;
        ELSIF tgt = 3 THEN vNttIdx := 7;
  ELSE vNttIdx := tgt; END_IF;

        vDest := g_ntt[cov_t].Target[vNttIdx];

        vOnPrimary := FALSE;
        FOR si := 1 TO vDest.StationCount DO
  IF vDest.Stations[si] = vLoc THEN vOnPrimary := TRUE; END_IF;
        END_FOR;

        IF NOT vOnPrimary THEN

          vOnFallback := FALSE;
          FOR si := 1 TO vDest.FallbackCount DO
  IF vDest.FallbackStations[si] = vLoc THEN vOnFallback := TRUE; END_IF;
          END_FOR;

          vPrimaryFree := FALSE;
          FOR si := 1 TO vDest.StationCount DO
            vStationIdx := vDest.Stations[si];
            IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
              vStnFree := TRUE;
              FOR uj := 1 TO MAX_UNITS DO
  IF g_unit[uj].vLocation = vStationIdx AND g_unit[uj].Status = USED THEN vStnFree := FALSE; END_IF;
              END_FOR;
  IF vStnFree THEN vPrimaryFree := TRUE; END_IF;
            END_IF;
          END_FOR;

          vDestStn := 0;

          IF vOnFallback AND NOT vPrimaryFree THEN
            vDestStn := 0;
          ELSIF vOnFallback AND vPrimaryFree THEN
            FOR si := 1 TO vDest.StationCount DO
              IF vDestStn = 0 THEN
                vStationIdx := vDest.Stations[si];
                IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
                  vStnFree := TRUE;
                  FOR uj := 1 TO MAX_UNITS DO
  IF g_unit[uj].vLocation = vStationIdx AND g_unit[uj].Status = USED THEN vStnFree := FALSE; END_IF;
                  END_FOR;
  IF vStnFree THEN vDestStn := vStationIdx; END_IF;
                END_IF;
              END_IF;
            END_FOR;
          ELSE
            FOR si := 1 TO vDest.StationCount DO
              IF vDestStn = 0 THEN
                vStationIdx := vDest.Stations[si];
                IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
                  vStnFree := TRUE;
                  FOR uj := 1 TO MAX_UNITS DO
  IF g_unit[uj].vLocation = vStationIdx AND g_unit[uj].Status = USED THEN vStnFree := FALSE; END_IF;
                  END_FOR;
  IF vStnFree THEN vDestStn := vStationIdx; END_IF;
                END_IF;
              END_IF;
            END_FOR;

            IF vDestStn = 0 THEN
              FOR si := 1 TO vDest.FallbackCount DO
                IF vDestStn = 0 THEN
                  vStationIdx := vDest.FallbackStations[si];
                  IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
                    vStnFree := TRUE;
                    FOR uj := 1 TO MAX_UNITS DO
  IF g_unit[uj].vLocation = vStationIdx AND g_unit[uj].Status = USED THEN vStnFree := FALSE; END_IF;
                    END_FOR;
  IF vStnFree THEN vDestStn := vStationIdx; END_IF;
                  END_IF;
                END_IF;
              END_FOR;
            END_IF;
          END_IF;

          IF vDestStn > 0 THEN
            vTmpMove := g_move[cov_t];
            vXferS := FC_STC_CalcTransferTime(
              iFromStn            := vLoc,
              iToStn              := vDestStn,
              iMove                := vTmpMove,
              i_from_dropping_x10   := Stations[vLoc].DrippingTime,
              i_to_device_delay_x10 := Stations[vDestStn].DeviceDelay,
              iDripTrayDelayX10 := Transporters[cov_t].DripTrayDelay);

            (* ── Travel-to: time for transporter to reach lift station ── *)
            vTravelToLiftS := 0.0;
            IF g_transporter[cov_t].Phase = 0 THEN
              vTransPos := g_transporter[cov_t].CurrentStation;
            ELSE
              vTransPos := g_transporter[cov_t].SinkStationTarget;
            END_IF;
            IF vTransPos > 0 AND vTransPos <> vLoc THEN
              vTravelToLiftS := FC_STC_CalcHorizontalTravel(
                iFromStn := vTransPos,
                iToStn   := vLoc,
                iMove     := vTmpMove);
            END_IF;

            vTaskStart := iTimeS + REAL_TO_LINT(vTravelToLiftS);
            vTaskEnd   := vTaskStart + REAL_TO_LINT(vXferS);
            vNttDuration := vTaskEnd - vTaskStart;

            vSlotOk := FALSE;
            vStretchPending := FALSE;
            ot_stretch_pending := FALSE;

            IF ioTask[cov_t].Count = 0 THEN
              vSlotOk := TRUE;
            ELSE
              IF ioTask[cov_t].Queue[1].StartTime > vTaskStart THEN
                vSlotStart := vTaskStart;
                vSlotEnd   := ioTask[cov_t].Queue[1].StartTime;
                vTravelFromSink := FC_STC_CalcHorizontalTravel(
                  iFromStn := vDestStn,
                  iToStn   := ioTask[cov_t].Queue[1].LiftStationTarget,
                  iMove     := g_move[cov_t]);
                latest_end := vSlotEnd - REAL_TO_LINT(vTravelFromSink) - 1;
                IF vTaskStart >= vSlotStart AND vTaskEnd <= latest_end THEN
                  vSlotOk := TRUE;
                END_IF;

                (* ── Idle-stretch: NTT slightly too long for idle window ──
                   Check if the blocking batch's treatment CalTime can be
                   extended (up to MaxTime) to widen the idle gap.  Only flag
                   the intent here; the actual g_batch write happens after
                   the multi-transporter overlap check passes. *)
                IF NOT vSlotOk AND latest_end > 0 THEN
                  vStretchDeficit := LINT_TO_DINT(vTaskEnd - latest_end);
                  IF vStretchDeficit > 0 THEN
                    vStretchUnitId := ioTask[cov_t].Queue[1].Unit;
                    IF vStretchUnitId >= 1 AND vStretchUnitId <= MAX_UNITS THEN
                      vStretchAvail := g_batch[vStretchUnitId].MaxTime
                                     - g_batch[vStretchUnitId].CalTime;
                      IF vStretchAvail >= vStretchDeficit THEN
                        vStretchPending := TRUE;
                        vSlotOk := TRUE;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;

            IF NOT vSlotOk THEN
              IF ioTask[cov_t].Count > 0
                 AND ioTask[cov_t].Queue[1].SinkStationTarget = vLoc THEN
                vSlotOk := TRUE;
              ELSE
                vDestStn := 0;
              END_IF;
            END_IF;
          END_IF;

          (* ── Multi-transporter shared-vArea idle check ──
             If vDestStn is on the shared drive vArea between two transporters,
             the other transporter must have an idle window covering the time
             when THIS transporter is physically on the shared vArea.

             NTT transfer phases:
               Phase 2: lift + drip + tray  (nostin on vielä lift-asemalla)
               Phase 3: horizontal vTravel   (nostin liikkuu kohti vDest)
               Phase 4: lower + tray + dev  (nostin on vDest-asemalla)

             If lift station is NOT on shared vArea:
               vSharedEntry = vTaskStart + phase2_s  (vTravel starts)
               vSharedTime  = vXferS - phase2_s
             If lift station IS on shared vArea:
               vSharedEntry = vTaskStart  (vAlready there)
               vSharedTime  = vXferS
          *)
          IF vDestStn > 0 THEN
            vOverlapConflict := FALSE;
            vDestX := Stations[vDestStn].XPosition;
            vAvoidDist := Transporters[cov_t].AvoidanceWidth;
            cov_min_x := Transporters[cov_t].DrivePosMin;
            cov_max_x := Transporters[cov_t].DrivePosMax;

            FOR ot := 1 TO MAX_TRANSPORTERS DO
              IF ot <> cov_t AND NOT vOverlapConflict
                 AND g_transporter[ot].IsActive THEN
                ot_min_x := Transporters[ot].DrivePosMin;
                ot_max_x := Transporters[ot].DrivePosMax;

                IF cov_min_x > ot_min_x THEN zone_min_x := cov_min_x;
  ELSE zone_min_x := ot_min_x; END_IF;
                IF cov_max_x < ot_max_x THEN zone_max_x := cov_max_x;
  ELSE zone_max_x := ot_max_x; END_IF;

                IF zone_min_x >= zone_max_x THEN CONTINUE; END_IF;
                IF vDestX < zone_min_x OR vDestX > zone_max_x THEN CONTINUE; END_IF;

                danger_min := zone_min_x - vAvoidDist;
                danger_max := zone_max_x + vAvoidDist;

                (* ── Calculate shared-vArea entry time and vDuration ── *)
                vLocX := Stations[vLoc].XPosition;
                IF vLocX >= danger_min AND vLocX <= danger_max THEN
                  vSharedEntry := vTaskStart;
                  vSharedTime  := vXferS;
                ELSE
                  vLocIdx := vLoc - MIN_STATION_INDEX;
                  IF vLocIdx >= 1 AND vLocIdx <= 25 THEN
                    phase2_s := INT_TO_REAL(g_move[cov_t].LiftTime[vLocIdx]) / 10.0
                              + INT_TO_REAL(Stations[vLoc].DrippingTime) / 10.0
                              + INT_TO_REAL(Transporters[cov_t].DripTrayDelay) / 10.0;
                  ELSE
                    phase2_s := 0.0;
                  END_IF;
                  vSharedEntry := vTaskStart + REAL_TO_LINT(phase2_s);
                  vSharedTime  := vXferS - phase2_s;
  IF vSharedTime < 1.0 THEN vSharedTime := 1.0; END_IF;
                END_IF;

                (* ── Check: does other transporter have an idle window
                     that starts ≤ vSharedEntry and lasts ≥ vSharedTime? ── *)
                ot_idle_ok := FALSE;

                IF ioTask[ot].Count = 0 AND g_transporter[ot].Phase = 0 THEN
                  ot_idle_ok := TRUE;
                ELSIF ioTask[ot].Count = 0
                      AND g_transporter[ot].Phase >= 1
                      AND g_transporter[ot].Phase <= 4 THEN
                  (* Transporter executing task, nothing queued after.
                     Idle starts at current task finish. *)
                  ot_idle_start := g_transporter[ot].CurrentTaskFinishTime;
                  IF ot_idle_start <= vSharedEntry THEN
                    ot_idle_ok := TRUE;
                  END_IF;
                ELSE
                  IF ioTask[ot].Count > 0 THEN
                    IF g_transporter[ot].Phase >= 1 AND g_transporter[ot].Phase <= 4 THEN
                      (* Idle gap: current task finish → next queued start *)
                      ot_idle_start := g_transporter[ot].CurrentTaskFinishTime;
                      ot_dispatch_from := g_transporter[ot].SinkStationTarget;
                    ELSE
                      ot_idle_start := vTaskStart;
                      ot_dispatch_from := g_transporter[ot].CurrentStation;
                    END_IF;
                    ot_next_lift := ioTask[ot].Queue[1].LiftStationTarget;
                    ot_travel_to_next := 0.0;
                    IF ot_dispatch_from > 0
                       AND ot_next_lift > 0
                       AND ot_dispatch_from <> ot_next_lift THEN
                      ot_travel_to_next := FC_STC_CalcHorizontalTravel(
                        iFromStn := ot_dispatch_from,
                        iToStn   := ot_next_lift,
                        iMove     := g_move[ot]);
                    END_IF;
                    ot_idle_end := ioTask[ot].Queue[1].StartTime
                                 - REAL_TO_LINT(ot_travel_to_next)
                                 - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                    IF ot_idle_end < ot_idle_start THEN
                      ot_idle_end := ot_idle_start;
                    END_IF;
                    IF ot_idle_start <= vSharedEntry
                       AND ot_idle_end >= vSharedEntry + REAL_TO_LINT(vSharedTime) THEN
                      ot_idle_ok := TRUE;
                    END_IF;
                  END_IF;

                  IF NOT ot_idle_ok THEN
                    FOR oq := 1 TO ioTask[ot].Count - 1 DO
                      IF NOT ot_idle_ok THEN
                        ot_idle_start := ioTask[ot].Queue[oq].FinishTime;
                        ot_dispatch_from := ioTask[ot].Queue[oq].SinkStationTarget;
                        ot_next_lift := ioTask[ot].Queue[oq + 1].LiftStationTarget;
                        ot_travel_to_next := 0.0;
                        IF ot_dispatch_from > 0
                           AND ot_next_lift > 0
                           AND ot_dispatch_from <> ot_next_lift THEN
                          ot_travel_to_next := FC_STC_CalcHorizontalTravel(
                            iFromStn := ot_dispatch_from,
                            iToStn   := ot_next_lift,
                            iMove     := g_move[ot]);
                        END_IF;
                        ot_idle_end := ioTask[ot].Queue[oq + 1].StartTime
                                     - REAL_TO_LINT(ot_travel_to_next)
                                     - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                        IF ot_idle_end < ot_idle_start THEN
                          ot_idle_end := ot_idle_start;
                        END_IF;
                        IF ot_idle_start <= vSharedEntry
                           AND ot_idle_end >= vSharedEntry + REAL_TO_LINT(vSharedTime) THEN
                          ot_idle_ok := TRUE;
                        END_IF;
                      END_IF;
                    END_FOR;
                  END_IF;

                  IF NOT ot_idle_ok AND ioTask[ot].Count > 0 THEN
                    ot_idle_start := ioTask[ot].Queue[ioTask[ot].Count].FinishTime;
                    IF ot_idle_start <= vSharedEntry THEN
                      ot_idle_ok := TRUE;
                    END_IF;
                  END_IF;
                END_IF;

                IF NOT ot_idle_ok THEN
                  (* ── Idle-stretch for other transporter ──
                     Try to widen the nearest idle gap by extending the
                     blocking batch CalTime (up to MaxTime).  Only tasks
                     with Stage > 0 (regular, not NTT) are candidates. *)
                  ot_stretch_ok := FALSE;

                  (* Try gap before first task *)
                  IF ioTask[ot].Count > 0
                     AND ioTask[ot].Queue[1].Stage > 0 THEN
                    IF g_transporter[ot].Phase >= 1 AND g_transporter[ot].Phase <= 4 THEN
                      ot_idle_start := g_transporter[ot].CurrentTaskFinishTime;
                      ot_dispatch_from := g_transporter[ot].SinkStationTarget;
                    ELSE
                      ot_idle_start := vTaskStart;
                      ot_dispatch_from := g_transporter[ot].CurrentStation;
                    END_IF;
                    ot_next_lift := ioTask[ot].Queue[1].LiftStationTarget;
                    ot_travel_to_next := 0.0;
                    IF ot_dispatch_from > 0
                       AND ot_next_lift > 0
                       AND ot_dispatch_from <> ot_next_lift THEN
                      ot_travel_to_next := FC_STC_CalcHorizontalTravel(
                        iFromStn := ot_dispatch_from,
                        iToStn   := ot_next_lift,
                        iMove     := g_move[ot]);
                    END_IF;
                    ot_idle_end := ioTask[ot].Queue[1].StartTime
                                 - REAL_TO_LINT(ot_travel_to_next)
                                 - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                    IF ot_idle_end < ot_idle_start THEN
                      ot_idle_end := ot_idle_start;
                    END_IF;

                    IF ot_idle_start <= vSharedEntry
                       AND ot_idle_end > vSharedEntry THEN
                      ot_stretch_need := vSharedEntry
                                       + REAL_TO_LINT(vSharedTime)
                                       - ot_idle_end;
                      IF ot_stretch_need > LINT#0 THEN
                        ot_stretch_unit_id := ioTask[ot].Queue[1].Unit;
                        IF ot_stretch_unit_id >= 1
                           AND ot_stretch_unit_id <= MAX_UNITS THEN
                          ot_stretch_avail :=
                            g_batch[ot_stretch_unit_id].MaxTime
                          - g_batch[ot_stretch_unit_id].CalTime;
                          IF ot_stretch_avail >= LINT_TO_DINT(ot_stretch_need) THEN
                            ot_stretch_deficit := LINT_TO_DINT(ot_stretch_need);
                            ot_stretch_pending := TRUE;
                            ot_stretch_ok      := TRUE;
                          END_IF;
                        END_IF;
                      END_IF;
                    END_IF;
                  END_IF;

                  (* Try gaps between tasks *)
                  IF NOT ot_stretch_ok THEN
                    FOR oq := 1 TO ioTask[ot].Count - 1 DO
                      IF NOT ot_stretch_ok
                         AND ioTask[ot].Queue[oq + 1].Stage > 0 THEN
                        ot_idle_start := ioTask[ot].Queue[oq].FinishTime;
                        ot_dispatch_from := ioTask[ot].Queue[oq].SinkStationTarget;
                        ot_next_lift := ioTask[ot].Queue[oq + 1].LiftStationTarget;
                        ot_travel_to_next := 0.0;
                        IF ot_dispatch_from > 0
                           AND ot_next_lift > 0
                           AND ot_dispatch_from <> ot_next_lift THEN
                          ot_travel_to_next := FC_STC_CalcHorizontalTravel(
                            iFromStn := ot_dispatch_from,
                            iToStn   := ot_next_lift,
                            iMove     := g_move[ot]);
                        END_IF;
                        ot_idle_end := ioTask[ot].Queue[oq + 1].StartTime
                                     - REAL_TO_LINT(ot_travel_to_next)
                                     - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                        IF ot_idle_end < ot_idle_start THEN
                          ot_idle_end := ot_idle_start;
                        END_IF;

                        IF ot_idle_start <= vSharedEntry
                           AND ot_idle_end > vSharedEntry THEN
                          ot_stretch_need := vSharedEntry
                                           + REAL_TO_LINT(vSharedTime)
                                           - ot_idle_end;
                          IF ot_stretch_need > LINT#0 THEN
                            ot_stretch_unit_id := ioTask[ot].Queue[oq + 1].Unit;
                            IF ot_stretch_unit_id >= 1
                               AND ot_stretch_unit_id <= MAX_UNITS THEN
                              ot_stretch_avail :=
                                g_batch[ot_stretch_unit_id].MaxTime
                              - g_batch[ot_stretch_unit_id].CalTime;
                              IF ot_stretch_avail >= LINT_TO_DINT(ot_stretch_need) THEN
                                ot_stretch_deficit := LINT_TO_DINT(ot_stretch_need);
                                ot_stretch_pending := TRUE;
                                ot_stretch_ok      := TRUE;
                              END_IF;
                            END_IF;
                          END_IF;
                        END_IF;
                      END_IF;
                    END_FOR;
                  END_IF;

                  IF ot_stretch_ok THEN
                    ot_idle_ok := TRUE;
                  ELSE
                    vOverlapConflict := TRUE;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;

  IF vOverlapConflict THEN vDestStn := 0; END_IF;
          END_IF;

          IF vDestStn > 0 THEN
            (* ── Commit idle-stretch: extend blocking batch CalTime ── *)
            IF vStretchPending THEN
              g_batch[vStretchUnitId].CalTime :=
                g_batch[vStretchUnitId].CalTime + vStretchDeficit;
              vStretchPending := FALSE;
            END_IF;

            (* ── Commit other-transporter idle-stretch ── *)
            IF ot_stretch_pending THEN
              g_batch[ot_stretch_unit_id].CalTime :=
                g_batch[ot_stretch_unit_id].CalTime + ot_stretch_deficit;
              ot_stretch_pending := FALSE;
            END_IF;

            IF ioTask[cov_t].Count < MAX_TASK_QUEUE THEN
              FOR sh := ioTask[cov_t].Count TO 1 BY -1 DO
                ioTask[cov_t].Queue[sh + 1] := ioTask[cov_t].Queue[sh];
              END_FOR;
              ioTask[cov_t].Queue[1].Unit         := ui;
              ioTask[cov_t].Queue[1].Stage        := 0;
              ioTask[cov_t].Queue[1].LiftStationTarget := vLoc;
              ioTask[cov_t].Queue[1].SinkStationTarget := vDestStn;
              ioTask[cov_t].Queue[1].StartTime   := vTaskStart;
              ioTask[cov_t].Queue[1].FinishTime  := vTaskEnd;
              ioTask[cov_t].Queue[1].CalcTime    := 0;
              ioTask[cov_t].Queue[1].MinTime     := 0;
              ioTask[cov_t].Queue[1].MaxTime     := 0;
              ioTask[cov_t].Queue[1].NttPrimary := 0;
              FOR si := 1 TO vDest.StationCount DO
                IF vDest.Stations[si] = vDestStn THEN
                  ioTask[cov_t].Queue[1].NttPrimary := 1;
                END_IF;
              END_FOR;
              ioTask[cov_t].Count := ioTask[cov_t].Count + 1;
              vDone := TRUE;
            END_IF;
          END_IF;

        END_IF; (* NOT vOnPrimary *)
      END_IF; (* vCovers + idle *)
      END_IF; (* NOT vDone *)
    END_FOR; (* transporter loop *)
    END_IF; (* NOT vAlready *)
  END_IF; (* valid target *)
END_FOR;

END_FUNCTION

(* ===========================================================================================
 *  TSK_NoTreatment — Create no-treatment transfer tasks
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Scans units with a target and creates transfer tasks
 *  using the g_ntt destination table.
 *
 *  VAR_IN_OUT: io_task — only mutable array (inserts NTT tasks).
 *  All other globals are read-only via VAR_EXTERNAL.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION TSK_NoTreatment : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_time_s                  : LINT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_Transporters *)
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_STATIONS_PER_STEP   : INT;
    MIN_StationIndex        : INT;
    MAX_StationIndex        : INT;
    MAX_Units               : INT;
    MAX_TASK_QUEUE          : INT;
    SCH_DISPATCH_MARGIN_S   : REAL;
    NOT_PROCESSED           : INT;
    PROCESSED               : INT;
    USED                    : INT;
END_VAR

VAR_EXTERNAL
  g_unit                    : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_batch                   : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_ntt                     : ARRAY[1..MAX_Transporters] OF UDT_JC_NttTransporterType;
  g_transporter             : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_station                 : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc             : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_cfg                     : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_move                    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
END_VAR

VAR
  ui                        : INT;
  loc                       : INT;
  tgt                       : INT;
  cov_t                     : INT;
  ai                        : INT;
  covers                    : BOOL;
  done                      : BOOL;
  dest                      : UDT_JC_NttDestType;
  ntt_idx                   : INT;
  on_primary                : BOOL;
  on_fallback               : BOOL;
  primary_free              : BOOL;
  dest_stn                  : INT;
  si                        : INT;
  station_idx               : INT;
  stn_free                  : BOOL;
  uj                        : INT;
  ti                        : INT;
  already                   : BOOL;
  qi2                       : INT;
  xfer_s                    : REAL;
  task_start                : LINT;
  task_end                  : LINT;
  slot_start                : LINT;
  tmp_move                  : UDT_JC_MoveTimesType;
  slot_end                  : LINT;
  latest_end                : LINT;
  travel_from_sink          : REAL;
  ntt_duration              : LINT;
  slot_ok                   : BOOL;
  sh                        : INT;

  (* Idle-stretch: extend blocking batch CalTime to make room for NTT -----------------------*)
  stretch_pending           : BOOL;
  stretch_unit_id           : INT;
  stretch_deficit           : DINT;
  stretch_avail             : DINT;

  (* Multi-transporter shared-area idle check -----------------------------------------------*)
  ot                        : INT;
  oq                        : INT;
  overlap_conflict          : BOOL;
  dest_x                    : DINT;
  avoid_dist                : DINT;
  cov_min_x                 : DINT;
  cov_max_x                 : DINT;
  ot_min_x                  : DINT;
  ot_max_x                  : DINT;
  zone_min_x                : DINT;
  zone_max_x                : DINT;
  danger_min                : DINT;
  danger_max                : DINT;
  (* Shared-area timing: NTT split into own-area + shared-area portions ---------------------*)
  loc_idx                   : INT;
  loc_x                     : DINT;
  phase2_s                  : REAL;
  shared_entry              : LINT;
  shared_time               : REAL;
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

TSK_NoTreatment := TRUE;

FOR ui := 1 TO MAX_Units DO
  tgt := g_unit[ui].Target;
  loc := g_unit[ui].location;

  IF tgt >= 1 AND tgt <= 5 AND loc >= MIN_StationIndex THEN

    IF tgt = 3 AND (g_batch[ui].BatchCode = 0 OR g_batch[ui].State <> NOT_PROCESSED) THEN
      CONTINUE;
    END_IF;

    already := FALSE;
    FOR ti := 1 TO MAX_Transporters DO
      IF NOT already THEN
        IF g_transporter[ti].Phase > 0 AND g_station_loc[ti].UnitId = ui THEN
          already := TRUE;
        END_IF;
        FOR qi2 := 1 TO io_task[ti].Count DO
          IF NOT already THEN
            IF io_task[ti].Queue[qi2].Unit = ui THEN
              already := TRUE;
            END_IF;
          END_IF;
        END_FOR;
      END_IF;
    END_FOR;

    IF NOT already THEN

    done := FALSE;
    FOR cov_t := 1 TO MAX_Transporters DO
      IF NOT done THEN

      covers := FALSE;
      FOR ai := 1 TO 4 DO
        IF NOT covers THEN
          IF g_cfg[cov_t].TaskArea[ai].MinLift > 0 OR g_cfg[cov_t].TaskArea[ai].MaxLift > 0 THEN
            IF loc >= g_cfg[cov_t].TaskArea[ai].MinLift AND loc <= g_cfg[cov_t].TaskArea[ai].MaxLift THEN
              covers := TRUE;
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      IF covers AND g_transporter[cov_t].IsActive
         AND (g_transporter[cov_t].Phase = 0 OR tgt = 5) THEN

        IF tgt = 2 THEN
          IF g_batch[ui].BatchCode = 0 THEN ntt_idx := 6;
          ELSIF g_batch[ui].State = PROCESSED THEN ntt_idx := 8;
  ELSE ntt_idx := 7; END_IF;
        ELSIF tgt = 3 THEN ntt_idx := 7;
  ELSE ntt_idx := tgt; END_IF;

        dest := g_ntt[cov_t].Target[ntt_idx];

        on_primary := FALSE;
        FOR si := 1 TO dest.StationCount DO
  IF dest.Stations[si] = loc THEN on_primary := TRUE; END_IF;
        END_FOR;

        IF NOT on_primary THEN

          on_fallback := FALSE;
          FOR si := 1 TO dest.FallbackCount DO
  IF dest.FallbackStations[si] = loc THEN on_fallback := TRUE; END_IF;
          END_FOR;

          primary_free := FALSE;
          FOR si := 1 TO dest.StationCount DO
            station_idx := dest.Stations[si];
            IF station_idx <> loc AND station_idx >= MIN_StationIndex AND station_idx <= MAX_StationIndex THEN
              stn_free := TRUE;
              FOR uj := 1 TO MAX_Units DO
  IF g_unit[uj].location = station_idx AND g_unit[uj].Status = USED THEN stn_free := FALSE; END_IF;
              END_FOR;
  IF stn_free THEN primary_free := TRUE; END_IF;
            END_IF;
          END_FOR;

          dest_stn := 0;

          IF on_fallback AND NOT primary_free THEN
            dest_stn := 0;
          ELSIF on_fallback AND primary_free THEN
            FOR si := 1 TO dest.StationCount DO
              IF dest_stn = 0 THEN
                station_idx := dest.Stations[si];
                IF station_idx <> loc AND station_idx >= MIN_StationIndex AND station_idx <= MAX_StationIndex THEN
                  stn_free := TRUE;
                  FOR uj := 1 TO MAX_Units DO
  IF g_unit[uj].location = station_idx AND g_unit[uj].Status = USED THEN stn_free := FALSE; END_IF;
                  END_FOR;
  IF stn_free THEN dest_stn := station_idx; END_IF;
                END_IF;
              END_IF;
            END_FOR;
          ELSE
            FOR si := 1 TO dest.StationCount DO
              IF dest_stn = 0 THEN
                station_idx := dest.Stations[si];
                IF station_idx <> loc AND station_idx >= MIN_StationIndex AND station_idx <= MAX_StationIndex THEN
                  stn_free := TRUE;
                  FOR uj := 1 TO MAX_Units DO
  IF g_unit[uj].location = station_idx AND g_unit[uj].Status = USED THEN stn_free := FALSE; END_IF;
                  END_FOR;
  IF stn_free THEN dest_stn := station_idx; END_IF;
                END_IF;
              END_IF;
            END_FOR;

            IF dest_stn = 0 THEN
              FOR si := 1 TO dest.FallbackCount DO
                IF dest_stn = 0 THEN
                  station_idx := dest.FallbackStations[si];
                  IF station_idx <> loc AND station_idx >= MIN_StationIndex AND station_idx <= MAX_StationIndex THEN
                    stn_free := TRUE;
                    FOR uj := 1 TO MAX_Units DO
  IF g_unit[uj].location = station_idx AND g_unit[uj].Status = USED THEN stn_free := FALSE; END_IF;
                    END_FOR;
  IF stn_free THEN dest_stn := station_idx; END_IF;
                  END_IF;
                END_IF;
              END_FOR;
            END_IF;
          END_IF;

          IF dest_stn > 0 THEN
            tmp_move := g_move[cov_t];
            xfer_s := STC_CalcTransferTime(
              i_from_stn            := loc,
              i_to_stn              := dest_stn,
              i_move                := tmp_move,
              i_from_dropping_x10   := g_station[loc].DrippingTime,
              i_to_device_delay_x10 := g_station[dest_stn].DeviceDelay,
              i_drip_tray_delay_x10 := g_cfg[cov_t].DripTrayDelay);

            task_start := i_time_s;
            task_end   := task_start + REAL_TO_LINT(xfer_s);
            ntt_duration := task_end - task_start;

            slot_ok := FALSE;
            stretch_pending := FALSE;
            ot_stretch_pending := FALSE;

            IF io_task[cov_t].Count = 0 THEN
              slot_ok := TRUE;
            ELSE
              IF io_task[cov_t].Queue[1].StartTime > task_start THEN
                slot_start := task_start;
                slot_end   := io_task[cov_t].Queue[1].StartTime;
                travel_from_sink := STC_CalcHorizontalTravel(
                  i_from_stn := dest_stn,
                  i_to_stn   := io_task[cov_t].Queue[1].LiftStationTarget,
                  i_move     := g_move[cov_t]);
                latest_end := slot_end - REAL_TO_LINT(travel_from_sink) - 1;
                IF task_start >= slot_start AND task_end <= latest_end THEN
                  slot_ok := TRUE;
                END_IF;

                (* ── Idle-stretch: NTT slightly too long for idle window ──
                   Check if the blocking batch's treatment CalTime can be
                   extended (up to MaxTime) to widen the idle gap.  Only flag
                   the intent here; the actual g_batch write happens after
                   the multi-transporter overlap check passes. *)
                IF NOT slot_ok AND latest_end > 0 THEN
                  stretch_deficit := LINT_TO_DINT(task_end - latest_end);
                  IF stretch_deficit > 0 THEN
                    stretch_unit_id := io_task[cov_t].Queue[1].Unit;
                    IF stretch_unit_id >= 1 AND stretch_unit_id <= MAX_Units THEN
                      stretch_avail := g_batch[stretch_unit_id].MaxTime
                                     - g_batch[stretch_unit_id].CalTime;
                      IF stretch_avail >= stretch_deficit THEN
                        stretch_pending := TRUE;
                        slot_ok := TRUE;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;

            IF NOT slot_ok THEN
              IF io_task[cov_t].Count > 0
                 AND io_task[cov_t].Queue[1].SinkStationTarget = loc THEN
                slot_ok := TRUE;
              ELSE
                dest_stn := 0;
              END_IF;
            END_IF;
          END_IF;

          (* ── Multi-transporter shared-area idle check ──
             If dest_stn is on the shared drive area between two transporters,
             the other transporter must have an idle window covering the time
             when THIS transporter is physically on the shared area.

             NTT transfer phases:
               Phase 2: lift + drip + tray  (nostin on vielä lift-asemalla)
               Phase 3: horizontal travel   (nostin liikkuu kohti dest)
               Phase 4: lower + tray + dev  (nostin on dest-asemalla)

             If lift station is NOT on shared area:
               shared_entry = task_start + phase2_s  (travel starts)
               shared_time  = xfer_s - phase2_s
             If lift station IS on shared area:
               shared_entry = task_start  (already there)
               shared_time  = xfer_s
          *)
          IF dest_stn > 0 THEN
            overlap_conflict := FALSE;
            dest_x := g_station[dest_stn].XPosition;
            avoid_dist := g_cfg[cov_t].AvoidanceWidth;
            cov_min_x := g_cfg[cov_t].DrivePosMin;
            cov_max_x := g_cfg[cov_t].DrivePosMax;

            FOR ot := 1 TO MAX_Transporters DO
              IF ot <> cov_t AND NOT overlap_conflict
                 AND g_transporter[ot].IsActive THEN
                ot_min_x := g_cfg[ot].DrivePosMin;
                ot_max_x := g_cfg[ot].DrivePosMax;

                IF cov_min_x > ot_min_x THEN zone_min_x := cov_min_x;
  ELSE zone_min_x := ot_min_x; END_IF;
                IF cov_max_x < ot_max_x THEN zone_max_x := cov_max_x;
  ELSE zone_max_x := ot_max_x; END_IF;

                IF zone_min_x >= zone_max_x THEN CONTINUE; END_IF;
                IF dest_x < zone_min_x OR dest_x > zone_max_x THEN CONTINUE; END_IF;

                danger_min := zone_min_x - avoid_dist;
                danger_max := zone_max_x + avoid_dist;

                (* ── Calculate shared-area entry time and duration ── *)
                loc_x := g_station[loc].XPosition;
                IF loc_x >= danger_min AND loc_x <= danger_max THEN
                  shared_entry := task_start;
                  shared_time  := xfer_s;
                ELSE
                  loc_idx := loc - MIN_StationIndex;
                  IF loc_idx >= 1 AND loc_idx <= 25 THEN
                    phase2_s := INT_TO_REAL(g_move[cov_t].LiftTime[loc_idx]) / 10.0
                              + INT_TO_REAL(g_station[loc].DrippingTime) / 10.0
                              + INT_TO_REAL(g_cfg[cov_t].DripTrayDelay) / 10.0;
                  ELSE
                    phase2_s := 0.0;
                  END_IF;
                  shared_entry := task_start + REAL_TO_LINT(phase2_s);
                  shared_time  := xfer_s - phase2_s;
  IF shared_time < 1.0 THEN shared_time := 1.0; END_IF;
                END_IF;

                (* ── Check: does other transporter have an idle window
                     that starts ≤ shared_entry and lasts ≥ shared_time? ── *)
                ot_idle_ok := FALSE;

                IF io_task[ot].Count = 0 AND g_transporter[ot].Phase = 0 THEN
                  ot_idle_ok := TRUE;
                ELSIF io_task[ot].Count = 0
                      AND g_transporter[ot].Phase >= 1
                      AND g_transporter[ot].Phase <= 4 THEN
                  (* Transporter executing task, nothing queued after.
                     Idle starts at current task finish. *)
                  ot_idle_start := g_transporter[ot].CurrentTaskFinishTime;
                  IF ot_idle_start <= shared_entry THEN
                    ot_idle_ok := TRUE;
                  END_IF;
                ELSE
                  IF io_task[ot].Count > 0 THEN
                    IF g_transporter[ot].Phase >= 1 AND g_transporter[ot].Phase <= 4 THEN
                      (* Idle gap: current task finish → next queued start *)
                      ot_idle_start := g_transporter[ot].CurrentTaskFinishTime;
                      ot_dispatch_from := g_transporter[ot].SinkStationTarget;
                    ELSE
                      ot_idle_start := task_start;
                      ot_dispatch_from := g_transporter[ot].CurrentStation;
                    END_IF;
                    ot_next_lift := io_task[ot].Queue[1].LiftStationTarget;
                    ot_travel_to_next := 0.0;
                    IF ot_dispatch_from > 0
                       AND ot_next_lift > 0
                       AND ot_dispatch_from <> ot_next_lift THEN
                      ot_travel_to_next := STC_CalcHorizontalTravel(
                        i_from_stn := ot_dispatch_from,
                        i_to_stn   := ot_next_lift,
                        i_move     := g_move[ot]);
                    END_IF;
                    ot_idle_end := io_task[ot].Queue[1].StartTime
                                 - REAL_TO_LINT(ot_travel_to_next)
                                 - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                    IF ot_idle_end < ot_idle_start THEN
                      ot_idle_end := ot_idle_start;
                    END_IF;
                    IF ot_idle_start <= shared_entry
                       AND ot_idle_end >= shared_entry + REAL_TO_LINT(shared_time) THEN
                      ot_idle_ok := TRUE;
                    END_IF;
                  END_IF;

                  IF NOT ot_idle_ok THEN
                    FOR oq := 1 TO io_task[ot].Count - 1 DO
                      IF NOT ot_idle_ok THEN
                        ot_idle_start := io_task[ot].Queue[oq].FinishTime;
                        ot_dispatch_from := io_task[ot].Queue[oq].SinkStationTarget;
                        ot_next_lift := io_task[ot].Queue[oq + 1].LiftStationTarget;
                        ot_travel_to_next := 0.0;
                        IF ot_dispatch_from > 0
                           AND ot_next_lift > 0
                           AND ot_dispatch_from <> ot_next_lift THEN
                          ot_travel_to_next := STC_CalcHorizontalTravel(
                            i_from_stn := ot_dispatch_from,
                            i_to_stn   := ot_next_lift,
                            i_move     := g_move[ot]);
                        END_IF;
                        ot_idle_end := io_task[ot].Queue[oq + 1].StartTime
                                     - REAL_TO_LINT(ot_travel_to_next)
                                     - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                        IF ot_idle_end < ot_idle_start THEN
                          ot_idle_end := ot_idle_start;
                        END_IF;
                        IF ot_idle_start <= shared_entry
                           AND ot_idle_end >= shared_entry + REAL_TO_LINT(shared_time) THEN
                          ot_idle_ok := TRUE;
                        END_IF;
                      END_IF;
                    END_FOR;
                  END_IF;

                  IF NOT ot_idle_ok AND io_task[ot].Count > 0 THEN
                    ot_idle_start := io_task[ot].Queue[io_task[ot].Count].FinishTime;
                    IF ot_idle_start <= shared_entry THEN
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
                  IF io_task[ot].Count > 0
                     AND io_task[ot].Queue[1].Stage > 0 THEN
                    IF g_transporter[ot].Phase >= 1 AND g_transporter[ot].Phase <= 4 THEN
                      ot_idle_start := g_transporter[ot].CurrentTaskFinishTime;
                      ot_dispatch_from := g_transporter[ot].SinkStationTarget;
                    ELSE
                      ot_idle_start := task_start;
                      ot_dispatch_from := g_transporter[ot].CurrentStation;
                    END_IF;
                    ot_next_lift := io_task[ot].Queue[1].LiftStationTarget;
                    ot_travel_to_next := 0.0;
                    IF ot_dispatch_from > 0
                       AND ot_next_lift > 0
                       AND ot_dispatch_from <> ot_next_lift THEN
                      ot_travel_to_next := STC_CalcHorizontalTravel(
                        i_from_stn := ot_dispatch_from,
                        i_to_stn   := ot_next_lift,
                        i_move     := g_move[ot]);
                    END_IF;
                    ot_idle_end := io_task[ot].Queue[1].StartTime
                                 - REAL_TO_LINT(ot_travel_to_next)
                                 - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                    IF ot_idle_end < ot_idle_start THEN
                      ot_idle_end := ot_idle_start;
                    END_IF;

                    IF ot_idle_start <= shared_entry
                       AND ot_idle_end > shared_entry THEN
                      ot_stretch_need := shared_entry
                                       + REAL_TO_LINT(shared_time)
                                       - ot_idle_end;
                      IF ot_stretch_need > LINT#0 THEN
                        ot_stretch_unit_id := io_task[ot].Queue[1].Unit;
                        IF ot_stretch_unit_id >= 1
                           AND ot_stretch_unit_id <= MAX_Units THEN
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
                    FOR oq := 1 TO io_task[ot].Count - 1 DO
                      IF NOT ot_stretch_ok
                         AND io_task[ot].Queue[oq + 1].Stage > 0 THEN
                        ot_idle_start := io_task[ot].Queue[oq].FinishTime;
                        ot_dispatch_from := io_task[ot].Queue[oq].SinkStationTarget;
                        ot_next_lift := io_task[ot].Queue[oq + 1].LiftStationTarget;
                        ot_travel_to_next := 0.0;
                        IF ot_dispatch_from > 0
                           AND ot_next_lift > 0
                           AND ot_dispatch_from <> ot_next_lift THEN
                          ot_travel_to_next := STC_CalcHorizontalTravel(
                            i_from_stn := ot_dispatch_from,
                            i_to_stn   := ot_next_lift,
                            i_move     := g_move[ot]);
                        END_IF;
                        ot_idle_end := io_task[ot].Queue[oq + 1].StartTime
                                     - REAL_TO_LINT(ot_travel_to_next)
                                     - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                        IF ot_idle_end < ot_idle_start THEN
                          ot_idle_end := ot_idle_start;
                        END_IF;

                        IF ot_idle_start <= shared_entry
                           AND ot_idle_end > shared_entry THEN
                          ot_stretch_need := shared_entry
                                           + REAL_TO_LINT(shared_time)
                                           - ot_idle_end;
                          IF ot_stretch_need > LINT#0 THEN
                            ot_stretch_unit_id := io_task[ot].Queue[oq + 1].Unit;
                            IF ot_stretch_unit_id >= 1
                               AND ot_stretch_unit_id <= MAX_Units THEN
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
                    overlap_conflict := TRUE;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;

  IF overlap_conflict THEN dest_stn := 0; END_IF;
          END_IF;

          IF dest_stn > 0 THEN
            (* ── Commit idle-stretch: extend blocking batch CalTime ── *)
            IF stretch_pending THEN
              g_batch[stretch_unit_id].CalTime :=
                g_batch[stretch_unit_id].CalTime + stretch_deficit;
              stretch_pending := FALSE;
            END_IF;

            (* ── Commit other-transporter idle-stretch ── *)
            IF ot_stretch_pending THEN
              g_batch[ot_stretch_unit_id].CalTime :=
                g_batch[ot_stretch_unit_id].CalTime + ot_stretch_deficit;
              ot_stretch_pending := FALSE;
            END_IF;

            IF io_task[cov_t].Count < MAX_TASK_QUEUE THEN
              FOR sh := io_task[cov_t].Count TO 1 BY -1 DO
                io_task[cov_t].Queue[sh + 1] := io_task[cov_t].Queue[sh];
              END_FOR;
              io_task[cov_t].Queue[1].Unit         := ui;
              io_task[cov_t].Queue[1].Stage        := 0;
              io_task[cov_t].Queue[1].LiftStationTarget := loc;
              io_task[cov_t].Queue[1].SinkStationTarget := dest_stn;
              io_task[cov_t].Queue[1].StartTime   := task_start;
              io_task[cov_t].Queue[1].FinishTime  := task_end;
              io_task[cov_t].Queue[1].CalcTime    := 0;
              io_task[cov_t].Queue[1].MinTime     := 0;
              io_task[cov_t].Queue[1].MaxTime     := 0;
              io_task[cov_t].Queue[1].NttPrimary := 0;
              FOR si := 1 TO dest.StationCount DO
                IF dest.Stations[si] = dest_stn THEN
                  io_task[cov_t].Queue[1].NttPrimary := 1;
                END_IF;
              END_FOR;
              io_task[cov_t].Count := io_task[cov_t].Count + 1;
              done := TRUE;
            END_IF;
          END_IF;

        END_IF; (* NOT on_primary *)
      END_IF; (* covers + idle *)
      END_IF; (* NOT done *)
    END_FOR; (* transporter loop *)
    END_IF; (* NOT already *)
  END_IF; (* valid target *)
END_FOR;

END_FUNCTION

(* ============================================================
   TSK_NoTreatment -- Create no-treatment transfer tasks
   ============================================================
   FC version. Scans units with a target and creates transfer
   tasks using the g_ntt destination table.

   VAR_IN_OUT: io_task -- only mutable array (inserts NTT tasks).
   All other globals are read-only via VAR_EXTERNAL.
   ============================================================ *)

FUNCTION TSK_NoTreatment : BOOL
VAR_INPUT
  i_time_s : LINT;
END_VAR
VAR_IN_OUT
  io_task : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_STATIONS_PER_STEP   : INT;
    MIN_StationIndex        : INT;
    MAX_StationIndex        : INT;
    MAX_Units               : INT;
    MAX_TASK_QUEUE          : INT;
END_VAR
VAR_EXTERNAL
  g_unit        : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_batch       : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_ntt         : ARRAY[1..MAX_Transporters] OF UDT_JC_NttTransporterType;
  g_transporter : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_station     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_cfg         : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_move        : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
END_VAR
VAR
  ui       : INT;
  qi       : INT;
  loc      : INT;
  tgt      : INT;
  cov_t    : INT;
  ai       : INT;
  covers   : BOOL;
  done     : BOOL;
  dest     : UDT_JC_NttDestType;
  ntt_idx  : INT;
  on_primary  : BOOL;
  on_fallback : BOOL;
  primary_free : BOOL;
  dest_stn : INT;
  si       : INT;
  station_idx : INT;
  stn_free : BOOL;
  uj       : INT;
  ti       : INT;
  already  : BOOL;
  qi2      : INT;
  xfer_s   : REAL;
  task_start : LINT;
  task_end   : LINT;
  has_overlap    : BOOL;
  ntt_start      : LINT;
  ntt_end        : LINT;
  ov_s           : LINT;
  ov_e           : LINT;
  margin_travel  : REAL;
  slot_start     : LINT;
  tmp_move       : UDT_JC_MoveTimesType;
  slot_end       : LINT;
  earliest_start : LINT;
  latest_end     : LINT;
  travel_to_lift : REAL;
  travel_from_sink : REAL;
  ntt_duration   : LINT;
  qi3            : INT;
  slot_ok        : BOOL;
  sh             : INT;
  ot             : INT;
  oq             : INT;
  overlap_conflict : BOOL;
  dest_x         : DINT;
  avoid_dist     : DINT;
  cov_min_x      : DINT;
  cov_max_x      : DINT;
  ot_min_x       : DINT;
  ot_max_x       : DINT;
  zone_min_x     : DINT;
  zone_max_x     : DINT;
  danger_min     : DINT;
  danger_max     : DINT;
  ot_lift_x      : DINT;
  ot_sink_x      : DINT;
END_VAR

TSK_NoTreatment := TRUE;

FOR ui := 1 TO MAX_Units DO
  tgt := g_unit[ui].Target;
  loc := g_unit[ui].location;

  IF tgt >= 1 AND tgt <= 5 AND loc >= 100 THEN

    IF tgt = 3 AND (g_batch[ui].BatchCode = 0 OR g_batch[ui].State <> 0) THEN
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
          ELSIF g_batch[ui].State = 2 THEN ntt_idx := 8;
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
                IF g_unit[uj].location = station_idx AND g_unit[uj].Status = 1 THEN stn_free := FALSE; END_IF;
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
                    IF g_unit[uj].location = station_idx AND g_unit[uj].Status = 1 THEN stn_free := FALSE; END_IF;
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
                    IF g_unit[uj].location = station_idx AND g_unit[uj].Status = 1 THEN stn_free := FALSE; END_IF;
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
                      IF g_unit[uj].location = station_idx AND g_unit[uj].Status = 1 THEN stn_free := FALSE; END_IF;
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

                IF g_transporter[ot].Phase >= 1 AND g_transporter[ot].Phase <= 4
                   AND io_task[ot].Count > 0 THEN
                  ot_lift_x := g_station[io_task[ot].Queue[1].LiftStationTarget].XPosition;
                  ot_sink_x := g_station[io_task[ot].Queue[1].SinkStationTarget].XPosition;
                  IF (ot_lift_x >= danger_min AND ot_lift_x <= danger_max)
                     OR (ot_sink_x >= danger_min AND ot_sink_x <= danger_max) THEN
                    overlap_conflict := TRUE;
                  END_IF;
                END_IF;

                FOR oq := 1 TO io_task[ot].Count DO
                  IF NOT overlap_conflict THEN
                    IF io_task[ot].Queue[oq].FinishTime > task_start
                       AND io_task[ot].Queue[oq].StartTime < task_end THEN
                      ot_lift_x := g_station[io_task[ot].Queue[oq].LiftStationTarget].XPosition;
                      ot_sink_x := g_station[io_task[ot].Queue[oq].SinkStationTarget].XPosition;
                      IF (ot_lift_x >= danger_min AND ot_lift_x <= danger_max)
                         OR (ot_sink_x >= danger_min AND ot_sink_x <= danger_max) THEN
                        overlap_conflict := TRUE;
                      END_IF;
                    END_IF;
                  END_IF;
                END_FOR;
              END_IF;
            END_FOR;

            IF overlap_conflict THEN dest_stn := 0; END_IF;
          END_IF;

          IF dest_stn > 0 THEN
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

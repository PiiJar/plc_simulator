(* ============================================================
   STC_FB_DispatchTask — Validate and dispatch tasks to transporters
   ============================================================
   Called every PLC scan from MainScheduler (before TSK/DEP).
   For each idle transporter with queued tasks:

     1. Skip if transporter not idle (phase <> 0) or queue empty
     2. Time check: is start_time close enough?
        travel_time_to_lift + 3s >= time_until_start → proceed
     3. Sink station free check:
        a) Original sink free → use it
        b) Not free → search alternative parallel stations
           (from g_program[].Steps[] or g_ntt[] for stage=0)
        c) Pick the station with oldest change_time (longest empty)
        d) No free alternative → skip, don't dispatch
     4. Conflict check: no other active transporter targeting
        same lift or sink station
     5. Dispatch: write task_id, lift_station, sink_station
        to g_transporter → RunTasks picks it up

   Used by: STC_FB_MainScheduler
   ============================================================ *)

FUNCTION_BLOCK STC_FB_DispatchTask
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MAX_Units           : INT;
    MAX_STATIONS_PER_STEP       : INT;
    MAX_STEPS_PER_PROGRAM          : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
END_VAR
VAR_EXTERNAL
  g_transporter : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_sim_trans   : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
  g_task        : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_station     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_unit        : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_program     : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_ntt         : ARRAY[1..MAX_Transporters] OF UDT_JC_NttTransporterType;
  g_batch       : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_move        : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_cfg         : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_schedule    : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_time_s      : LINT;
  g_event_pending       : UDT_JC_EventMsgType;
  g_event_pending_valid : BOOL;
END_VAR
VAR
  ti           : INT;     (* transporter loop *)
  (* Task fields — read from queue[1] to avoid struct copy *)
  t_unit       : INT;
  t_stage      : INT;
  t_lift       : INT;
  t_sink       : INT;
  t_start      : LINT;
  t_finish     : LINT;
  t_calc_time  : DINT;
  (* Time check *)
  travel_s     : REAL;
  margin_s     : LINT;
  from_idx     : INT;
  to_idx       : INT;
  (* Sink search *)
  sink_stn     : INT;
  sink_free    : BOOL;
  best_stn     : INT;
  best_change  : LINT;
  si           : INT;
  cand_stn     : INT;
  cand_free    : BOOL;
  uj           : INT;
  tgt          : INT;
  ntt_idx      : INT;     (* resolved NTT index (buffer 6/7/8) *)
  ntt_cnt      : INT;
  ntt_fb_cnt   : INT;
  (* Conflict check *)
  conflict     : BOOL;
  cj           : INT;
  task_min     : INT;     (* min station of our proposed task *)
  task_max     : INT;     (* max station of our proposed task *)
  (* Queue position loop *)
  qi           : INT;
  (* Shift-down after dispatch *)
  sh           : INT;
  (* Transfer time for batch progress bar *)
  xfer_total   : REAL;
  (* Program stage number for event *)
  prog_stage   : INT;
END_VAR

FOR ti := 1 TO MAX_Transporters DO

  (* ── 1. Skip if not idle or queue empty ── *)
  IF g_transporter[ti].Phase = 0 AND g_task[ti].Count >= 1 THEN

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

    (* Convert schedule index → program stage number for g_program access *)
    prog_stage := 0;
    IF t_unit >= 1 AND t_unit <= MAX_Units
       AND t_stage >= 1 AND t_stage <= g_schedule[t_unit].StageCount THEN
      prog_stage := g_schedule[t_unit].Stages[t_stage].ProgramStage;
    END_IF;

    (* ── 2. Time check ── *)
    travel_s := 0.0;
    IF g_transporter[ti].CurrentStation > 0 AND t_lift > 0
       AND g_transporter[ti].CurrentStation <> t_lift THEN
      from_idx := g_transporter[ti].CurrentStation - 100;
      to_idx   := t_lift - 100;
      IF from_idx >= 1 AND from_idx <= 30 AND to_idx >= 1 AND to_idx <= 30 THEN
        travel_s := INT_TO_REAL(g_move[ti].Travel[from_idx].ToTime[to_idx]) / 10.0;
      END_IF;
    END_IF;

    margin_s := t_start - g_time_s;

    IF margin_s <= REAL_TO_LINT(travel_s) + 3 THEN

      (* ── 3. Sink station free check ── *)
      sink_stn := t_sink;
      sink_free := FALSE;

      IF sink_stn >= MIN_StationIndex AND sink_stn <= MAX_StationIndex THEN
        sink_free := TRUE;
        FOR uj := 1 TO MAX_Units DO
          IF g_unit[uj].location = sink_stn AND g_unit[uj].Status = 1 THEN
            sink_free := FALSE;
          END_IF;
        END_FOR;
      END_IF;

      IF NOT sink_free THEN
        (* Search alternative parallel stations *)
        best_stn := 0;
        best_change := LINT#2000000000;

        IF prog_stage >= 1 AND prog_stage <= MAX_STEPS_PER_PROGRAM
           AND t_unit >= 1 AND t_unit <= MAX_Units THEN
          (* Treatment task — look in g_program for parallel stations *)
          FOR si := 0 TO MAX_STATIONS_PER_STEP - 1 DO
            cand_stn := g_program[t_unit].Steps[prog_stage - 1].Stations[si];
            IF cand_stn > 0 AND cand_stn <> t_sink THEN
              IF cand_stn >= MIN_StationIndex AND cand_stn <= MAX_StationIndex THEN
                cand_free := TRUE;
                FOR uj := 1 TO MAX_Units DO
                  IF g_unit[uj].location = cand_stn AND g_unit[uj].Status = 1 THEN
                    cand_free := FALSE;
                  END_IF;
                END_FOR;
                IF cand_free THEN
                  IF g_station_loc[cand_stn].ChangeTime < best_change THEN
                    best_change := g_station_loc[cand_stn].ChangeTime;
                    best_stn := cand_stn;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

        ELSIF prog_stage = 0 AND t_unit >= 1 AND t_unit <= MAX_Units THEN
          (* No-treatment task — look in g_ntt for alternatives *)
          tgt := g_unit[t_unit].Target;
          IF tgt >= 1 AND tgt <= 5 THEN
            (* Resolve buffer NTT index like NoTreatment does *)
            IF tgt = 2 THEN
              IF g_batch[t_unit].BatchCode = 0 THEN
                ntt_idx := 6;
              ELSIF g_batch[t_unit].State = 2 THEN
                ntt_idx := 8;
              ELSE
                ntt_idx := 7;
              END_IF;
            ELSE
              ntt_idx := tgt;
            END_IF;
            (* Check primary stations *)
            ntt_cnt := g_ntt[ti].Target[ntt_idx].StationCount;
            FOR si := 1 TO ntt_cnt DO
              IF si <= MAX_STATIONS_PER_STEP THEN
                cand_stn := g_ntt[ti].Target[ntt_idx].Stations[si];
                IF cand_stn > 0 AND cand_stn <> t_sink THEN
                  IF cand_stn >= MIN_StationIndex AND cand_stn <= MAX_StationIndex THEN
                    cand_free := TRUE;
                    FOR uj := 1 TO MAX_Units DO
                      IF g_unit[uj].location = cand_stn AND g_unit[uj].Status = 1 THEN
                        cand_free := FALSE;
                      END_IF;
                    END_FOR;
                    IF cand_free THEN
                      IF g_station_loc[cand_stn].ChangeTime < best_change THEN
                        best_change := g_station_loc[cand_stn].ChangeTime;
                        best_stn := cand_stn;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;
            (* Check fallback stations *)
            ntt_fb_cnt := g_ntt[ti].Target[ntt_idx].FallbackCount;
            FOR si := 1 TO ntt_fb_cnt DO
              IF si <= MAX_STATIONS_PER_STEP THEN
                cand_stn := g_ntt[ti].Target[ntt_idx].FallbackStations[si];
                IF cand_stn > 0 AND cand_stn <> t_sink THEN
                  IF cand_stn >= MIN_StationIndex AND cand_stn <= MAX_StationIndex THEN
                    cand_free := TRUE;
                    FOR uj := 1 TO MAX_Units DO
                      IF g_unit[uj].location = cand_stn AND g_unit[uj].Status = 1 THEN
                        cand_free := FALSE;
                      END_IF;
                    END_FOR;
                    IF cand_free THEN
                      IF g_station_loc[cand_stn].ChangeTime < best_change THEN
                        best_change := g_station_loc[cand_stn].ChangeTime;
                        best_stn := cand_stn;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;
          END_IF;
        END_IF;

        IF best_stn > 0 THEN
          sink_stn := best_stn;
          sink_free := TRUE;
        END_IF;
      END_IF;  (* NOT sink_free *)

      IF sink_free THEN

        (* ── 4. Conflict check ── *)
        (* Check against other transporters' ACTIVE tasks (phase>0).
           Two rules:
           a) T2's entire task (lift AND sink) is inside our task
              range [task_min..task_max] → conflict.
              Example: our 114→101 range [101,114]
                T2 114→113: both in [101,114] → conflict
                T2 114→117: 117 outside     → no conflict (going away)
           b) T2 delivers (sink) to one of our exact stations
              from outside our range → conflict.
              Example: T2 120→114, 114 is our lift → conflict *)
        conflict := FALSE;

        IF t_lift <= sink_stn THEN
          task_min := t_lift;
          task_max := sink_stn;
        ELSE
          task_min := sink_stn;
          task_max := t_lift;
        END_IF;

        FOR cj := 1 TO MAX_Transporters DO
          IF cj <> ti AND g_transporter[cj].Phase > 0 THEN

            (* a) T2's entire active task inside our range → conflict *)
            IF g_transporter[cj].LiftStationTarget >= task_min
               AND g_transporter[cj].LiftStationTarget <= task_max
               AND g_transporter[cj].SinkStationTarget >= task_min
               AND g_transporter[cj].SinkStationTarget <= task_max THEN
              conflict := TRUE;
            END_IF;

            (* b) T2 delivers to one of our exact stations → conflict *)
            IF g_transporter[cj].SinkStationTarget = t_lift
               OR g_transporter[cj].SinkStationTarget = sink_stn THEN
              conflict := TRUE;
            END_IF;

          END_IF;
        END_FOR;

        IF NOT conflict THEN
          (* ── 5. Dispatch: assign task to transporter ── *)
          g_transporter[ti].TaskId      := t_start;
          g_transporter[ti].LiftStationTarget := t_lift;
          g_transporter[ti].SinkStationTarget := sink_stn;
          g_station_loc[ti].UnitId      := t_unit;
          g_sim_trans[ti].TreatmentTime := t_calc_time;
          g_sim_trans[ti].MinTime := g_task[ti].Queue[qi].MinTime;
          g_sim_trans[ti].MaxTime := g_task[ti].Queue[qi].MaxTime;
          g_sim_trans[ti].NttPrimary := g_task[ti].Queue[qi].NttPrimary;
          g_transporter[ti].TaskRemainingTime := t_calc_time;

          (* ── Emit TASK_DISPATCHED event (msg_type=1) ── *)
          (* Compute transfer time for xfer_total field *)
          xfer_total := STC_CalcTransferTime(
            i_from_stn            := t_lift,
            i_to_stn              := sink_stn,
            i_move                := g_move[ti],
            i_from_dropping_x10   := g_station[t_lift].DrippingTime,
            i_to_device_delay_x10 := g_station[sink_stn].DeviceDelay,
            i_drip_tray_delay_x10 := g_cfg[ti].DripTrayDelay
          );
          IF xfer_total < 1.0 THEN
            xfer_total := INT_TO_REAL(ABS(sink_stn - t_lift)) * 8.0;
          END_IF;
          IF xfer_total < 5.0 THEN xfer_total := 60.0; END_IF;
          IF NOT g_event_pending_valid THEN
            g_event_pending.MsgType := 1;
            g_event_pending.TsHi := LINT_TO_INT(g_time_s / LINT#65536);
            g_event_pending.TsLo := LINT_TO_INT(g_time_s MOD LINT#65536);
            g_event_pending.Payload[1]  := LINT_TO_INT(t_start / LINT#65536);   (* TaskId_Hi *)
            g_event_pending.Payload[2]  := LINT_TO_INT(t_start MOD LINT#65536);  (* TaskId_Lo *)
            g_event_pending.Payload[3]  := ti;
            g_event_pending.Payload[4]  := t_unit;
            g_event_pending.Payload[5]  := t_lift;
            g_event_pending.Payload[6]  := sink_stn;
            prog_stage := g_batch[t_unit].CurStage;
            g_event_pending.Payload[7]  := prog_stage;  (* treatment program stage number *)
            g_event_pending.Payload[8]  := g_batch[t_unit].BatchCode;
            g_event_pending.Payload[9]  := DINT_TO_INT(t_calc_time);
            g_event_pending.Payload[10] := DINT_TO_INT(g_task[ti].Queue[qi].MinTime);
            g_event_pending.Payload[11] := DINT_TO_INT(g_task[ti].Queue[qi].MaxTime);
            g_event_pending.Payload[12] := REAL_TO_INT(xfer_total);
            g_event_pending_valid := TRUE;
          END_IF;

          (* Copy station-specific timing from config *)
          IF t_lift >= MIN_StationIndex AND t_lift <= MAX_StationIndex THEN
            g_transporter[ti].DrippingTime := g_station[t_lift].DrippingTime;
            g_sim_trans[ti].LiftDeviceDelay := g_station[t_lift].DeviceDelay;
          END_IF;
          IF sink_stn >= MIN_StationIndex AND sink_stn <= MAX_StationIndex THEN
            g_sim_trans[ti].SinkDeviceDelay := g_station[sink_stn].DeviceDelay;
          END_IF;

          (* Shift queue: remove position qi, move rest up *)
          FOR sh := qi + 1 TO g_task[ti].Count DO
            g_task[ti].Queue[sh - 1] := g_task[ti].Queue[sh];
          END_FOR;
          (* Clear last slot *)
          g_task[ti].Queue[g_task[ti].Count].Unit := 0;
          g_task[ti].Queue[g_task[ti].Count].Stage := 0;
          g_task[ti].Queue[g_task[ti].Count].LiftStationTarget := 0;
          g_task[ti].Queue[g_task[ti].Count].SinkStationTarget := 0;
          g_task[ti].Queue[g_task[ti].Count].StartTime := 0;
          g_task[ti].Queue[g_task[ti].Count].FinishTime := 0;
          g_task[ti].Queue[g_task[ti].Count].CalcTime := 0;
          g_task[ti].Queue[g_task[ti].Count].MinTime := 0;
          g_task[ti].Queue[g_task[ti].Count].MaxTime := 0;
          g_task[ti].Count := g_task[ti].Count - 1;
          EXIT;  (* dispatched — stop searching this queue *)

        END_IF;  (* NOT conflict *)

      END_IF;  (* sink_free *)

    END_IF;  (* time check *)

    END_FOR;  (* qi — try next queue position *)

  END_IF;  (* idle + queue *)

END_FOR;

END_FUNCTION_BLOCK

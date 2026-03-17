(* ============================================================
   SIM_FB_RunTasks.st — Simulate transporter task execution

   For each active transporter [1..3], checks whether a new task
   has been assigned (task_id <> running_task_id) and executes
   the full transport cycle:

     Phase 0  idle        — waiting for new task
     Phase 1  to_lift     — X-drive towards lift station
     Phase 2  lifting     — Z-lift sequence (stages 1-5)
     Phase 3  to_sink     — X-drive towards sink station
     Phase 4  sinking     — Z-sink sequence (stages 6-8)

   Also maintains current_station (nearest station) every cycle.

   Called once per PLC scan from PLC_PRG.
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_RunTasks
VAR_INPUT
  i_run : BOOL;       (* enable — typically init_done *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MAX_Units           : INT;
    MAX_STEPS_PER_PROGRAM          : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
    IN_PROCESS          : INT;
END_VAR

VAR_EXTERNAL
  g_transporter  : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_sim_trans    : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
  g_station     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;    g_station_loc  : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;  g_cfg          : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_move         : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_unit         : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_batch        : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_program      : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_time_s       : LINT;
  g_event_pending       : UDT_JC_EventMsgType;
  g_event_pending_valid : BOOL;
END_VAR
VAR
  i            : INT;
  idx          : INT;
  (* Physics FB instances — one per transporter (MATIEC needs separate instances) *)
  fb_x1        : SIM_FB_XMotion;
  fb_x2        : SIM_FB_XMotion;
  fb_x3        : SIM_FB_XMotion;
  fb_z1        : SIM_FB_ZMotion;
  fb_z2        : SIM_FB_ZMotion;
  fb_z3        : SIM_FB_ZMotion;
  (* Station lookup *)
  lookup       : STC_FB_FindStation;
  (* Temp vars for VAR_IN_OUT passing *)
  tmp_x        : DINT;
  tmp_vx       : DINT;
  tmp_z        : DINT;
  tmp_zs       : INT;
  tmp_zt       : REAL;
  arrived_x    : BOOL;
  at_station   : BOOL;    (* TRUE only when actually at station, not just at drive limit *)
  arrived_z    : BOOL;
  station_kind : INT;
  device_delay : REAL;
  drop_time    : REAL;
  pick_unit_id : INT;     (* unit_id picked up from lift station *)
  xfer_total   : REAL;    (* transfer time for UI progress bar *)
  sink_unit_id : INT;     (* unit_id being placed at sink station *)
  (* Nearest-station calculation *)
  nearest_num  : INT;
  min_dist     : DINT;
  dx           : DINT;
  (* Time measurement instances *)
  tm1          : STC_FB_MeasureMoveTimes;
  tm2          : STC_FB_MeasureMoveTimes;
  tm3          : STC_FB_MeasureMoveTimes;
  (* Unit location update instances *)
  upd_loc1     : STC_FB_UpdateUnitLocation;
  upd_loc2     : STC_FB_UpdateUnitLocation;
  upd_loc3     : STC_FB_UpdateUnitLocation;
  (* Event helpers *)
  evt_unit     : INT;
  evt_diff     : LINT;
  (* Treatment time wait *)
  can_lift       : BOOL;
  lift_uid       : INT;      (* unit at lift station *)
  treat_cal      : DINT;      (* treatment cal_time for current stage *)
  treat_elapsed  : LINT;     (* seconds spent at lift station *)
  (* ── TASK_COMPLETE event: phase timestamps per transporter ── *)
  ts_task_start  : ARRAY[1..3] OF LINT;  (* Phase 0→1: task accepted *)
  ts_at_lift     : ARRAY[1..3] OF LINT;  (* Phase 1 at_station: arrived at lift *)
  ts_lift_begin  : ARRAY[1..3] OF LINT;  (* Phase 1→2: can_lift, begin lift *)
  ts_lift_done   : ARRAY[1..3] OF LINT;  (* Phase 2→3: lift complete *)
  ts_at_sink     : ARRAY[1..3] OF LINT;  (* Phase 3→4: arrived at sink *)
  (* TASK_COMPLETE temp vars *)
  dd_lift_s      : INT;   (* lift device_delay in seconds *)
  dropping_s     : INT;   (* dropping/valutus time in seconds *)
  trip_s         : INT;   (* drip tray delay in seconds, 0 if not used *)
  dur_nosto      : INT;   (* computed nosto duration *)
  dur_lasku      : INT;   (* computed lasku duration *)
END_VAR

IF NOT i_run THEN
  RETURN;
END_IF;

FOR i := 1 TO MAX_Transporters DO
  IF g_transporter[i].IsActive THEN

  (* ── Phase 0 → 1: Accept new task ───────────────────────── *)
  IF (g_transporter[i].Phase = 0)
     AND (g_transporter[i].TaskId <> g_sim_trans[i].RunningTaskId) THEN
    g_sim_trans[i].RunningTaskId := g_transporter[i].TaskId;
    lookup(station_number := g_transporter[i].LiftStationTarget);
    g_transporter[i].XFinalTarget := lookup.x_mm;
    g_transporter[i].Phase := 1;
    g_transporter[i].Status := 4;  (* auto_run *)
    g_sim_trans[i].ZStage := 0;
    g_sim_trans[i].ZTimer := 0.0;
    (* Record task start timestamp *)
    ts_task_start[i] := g_time_s;
    ts_at_lift[i]    := LINT#0;

  (* ── Phase 1: Drive X towards lift station ──────────────── *)
  ELSIF g_transporter[i].Phase = 1 THEN
    tmp_x  := g_transporter[i].XPosition;
    tmp_vx := g_sim_trans[i].XVelocity;
    IF i = 1 THEN
      fb_x1(
        delta_t  := 0.02,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
      arrived_x := fb_x1.arrived;
    ELSIF i = 2 THEN
      fb_x2(
        delta_t  := 0.02,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
      arrived_x := fb_x2.arrived;
    ELSIF i = 3 THEN
      fb_x3(
        delta_t  := 0.02,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
      arrived_x := fb_x3.arrived;
    END_IF;
    g_transporter[i].XPosition  := tmp_x;
    g_sim_trans[i].XVelocity := tmp_vx;

    (* Only transition when actually at station, not just at drive limit *)
    at_station := arrived_x
                  AND (ABS(g_transporter[i].XPosition - g_transporter[i].XFinalTarget) <= 6);
    IF at_station THEN
      g_transporter[i].CurrentStation := g_transporter[i].LiftStationTarget;
      (* Record arrival at lift station (first time only) *)
      IF ts_at_lift[i] = LINT#0 THEN
        ts_at_lift[i] := g_time_s;
      END_IF;

      (* ── Wait for treatment time AND device_delay before lifting ──
         Z-movement starts when the LONGER of two has elapsed:
         1. Remaining treatment time (unit must finish treatment)
         2. Station device_delay (covers must be open)
         Both timers run simultaneously from transporter arrival.
         This matches JS behavior: max(treatment, device_delay). *)
      can_lift := TRUE;
      lookup(station_number := g_transporter[i].LiftStationTarget);
      device_delay := lookup.device_delay_s;

      (* Check treatment time *)
      lift_uid := g_station_loc[g_transporter[i].LiftStationTarget].UnitId;
      IF lift_uid >= 1 AND lift_uid <= MAX_Units THEN
        IF g_batch[lift_uid].State = IN_PROCESS
           AND g_batch[lift_uid].CurStage >= 1
           AND g_batch[lift_uid].CurStage <= MAX_STEPS_PER_PROGRAM THEN
          treat_cal := g_program[lift_uid].Steps[g_batch[lift_uid].CurStage - 1].CalTime;
          IF treat_cal > 0 THEN
            treat_elapsed := g_time_s - g_station_loc[g_transporter[i].LiftStationTarget].ChangeTime;
            IF treat_elapsed < DINT_TO_LINT(treat_cal) THEN
              can_lift := FALSE;
            END_IF;
          END_IF;
        END_IF;
      END_IF;

      (* Check device_delay — covers must have had time to open since arrival *)
      IF can_lift AND device_delay > 0.0 THEN
        IF LINT_TO_REAL(g_time_s - ts_at_lift[i]) < device_delay THEN
          can_lift := FALSE;
        END_IF;
      END_IF;

      IF can_lift THEN
      (* Record lift begin timestamp *)
      ts_lift_begin[i] := g_time_s;
      drop_time    := lookup.dropping_time_s;
      (* Skip stage 1 — device_delay already overlapped above.
         Z-movement starts immediately (stage 2).
         dropping_time and drip_tray_delay happen at the TOP. *)
      g_transporter[i].ZPosition := 0;
      g_sim_trans[i].ZTimer := 0.0;
      g_sim_trans[i].ZStage := 2;
      g_transporter[i].Phase := 2;

      (* ── Calculate transfer time (used by event + batch times) ── *)
      xfer_total := STC_CalcTransferTime(
        i_from_stn            := g_transporter[i].LiftStationTarget,
        i_to_stn              := g_transporter[i].SinkStationTarget,
        i_move                := g_move[i],
        i_from_dropping_x10   := g_station[g_transporter[i].LiftStationTarget].DrippingTime,
        i_to_device_delay_x10 := g_station[g_transporter[i].SinkStationTarget].DeviceDelay,
        i_drip_tray_delay_x10 := g_cfg[i].DripTrayDelay
      );
      IF xfer_total < 1.0 THEN
        xfer_total := INT_TO_REAL(
          ABS(g_transporter[i].SinkStationTarget
              - g_transporter[i].LiftStationTarget)
        ) * 8.0;
      END_IF;
      IF xfer_total < 5.0 THEN xfer_total := 60.0; END_IF;

      (* ── Emit LIFT event (msg_type=2) ── *)
      evt_unit := g_station_loc[g_transporter[i].LiftStationTarget].UnitId;
      IF NOT g_event_pending_valid AND evt_unit >= 1 THEN
        g_event_pending.MsgType := 2;
        g_event_pending.TsHi := LINT_TO_INT(g_time_s / LINT#65536);
        g_event_pending.TsLo := LINT_TO_INT(g_time_s MOD LINT#65536);
        g_event_pending.Payload[1]  := LINT_TO_INT(g_transporter[i].TaskId / LINT#65536);   (* TaskId_Hi *)
        g_event_pending.Payload[2]  := LINT_TO_INT(g_transporter[i].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        g_event_pending.Payload[3]  := i;
        g_event_pending.Payload[4]  := evt_unit;
        g_event_pending.Payload[5]  := g_transporter[i].LiftStationTarget;
        g_event_pending.Payload[6]  := g_batch[evt_unit].BatchCode;
        g_event_pending.Payload[7]  := g_batch[evt_unit].CurStage;
        evt_diff := g_time_s - g_station_loc[g_transporter[i].LiftStationTarget].ChangeTime;
        IF evt_diff > LINT#32000 THEN
          g_event_pending.Payload[8] := 32000;
        ELSE
          g_event_pending.Payload[8] := LINT_TO_INT(evt_diff);
        END_IF;
        (* ── Original program calc/min/max for this stage ── *)
        (* g_sim_trans holds dispatch-time scheduler values which may differ
           from the treatment program originals. Read directly from g_program
           using the batch's current stage (CurStage=1-based program index). *)
        IF g_batch[evt_unit].CurStage >= 1 AND g_batch[evt_unit].CurStage <= 30 THEN
          g_event_pending.Payload[9]  := DINT_TO_INT(g_program[evt_unit].Steps[g_batch[evt_unit].CurStage - 1].CalTime);
          g_event_pending.Payload[10] := DINT_TO_INT(g_program[evt_unit].Steps[g_batch[evt_unit].CurStage - 1].MinTime);
          g_event_pending.Payload[11] := DINT_TO_INT(g_program[evt_unit].Steps[g_batch[evt_unit].CurStage - 1].MaxTime);
        ELSE
          (* Stage 0 (pickup) — no program step *)
          g_event_pending.Payload[9]  := 0;
          g_event_pending.Payload[10] := 0;
          g_event_pending.Payload[11] := 0;
        END_IF;
        g_event_pending.Payload[12] := REAL_TO_INT(xfer_total);
        g_event_pending_valid := TRUE;
      END_IF;

      (* Unit moves from lift station → transporter *)
      pick_unit_id := g_station_loc[g_transporter[i].LiftStationTarget].UnitId;
      IF pick_unit_id >= 1 THEN
        IF i = 1 THEN
          upd_loc1(i_unit := pick_unit_id, i_location := i);
        ELSIF i = 2 THEN
          upd_loc2(i_unit := pick_unit_id, i_location := i);
        ELSIF i = 3 THEN
          upd_loc3(i_unit := pick_unit_id, i_location := i);
        END_IF;

        (* Set batch transfer times for UI progress bar — matches JS behavior *)
        g_batch[pick_unit_id].StartTime := g_time_s;
        g_batch[pick_unit_id].CalTime   := REAL_TO_DINT(xfer_total);
        g_batch[pick_unit_id].MinTime   := g_batch[pick_unit_id].CalTime;
        g_batch[pick_unit_id].MaxTime   := 600;
      END_IF;
      END_IF;  (* can_lift *)
    END_IF;
    (* If arrived_x but not at_station → at drive limit, wait for clearance *)

  (* ── Phase 2: Lift Z at lift station ────────────────────── *)
  ELSIF g_transporter[i].Phase = 2 THEN
    lookup(station_number := g_transporter[i].LiftStationTarget);
    station_kind := lookup.skind;
    tmp_z  := g_transporter[i].ZPosition;
    tmp_zs := g_sim_trans[i].ZStage;
    tmp_zt := g_sim_trans[i].ZTimer;
    IF i = 1 THEN
      fb_z1(
        delta_t       := 0.02,
        station_kind  := station_kind,
        ZPosDown        := g_cfg[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := g_cfg[i].ZPosSlowUp,
        ZPosSlowDown    := g_cfg[i].ZPosSlowDown,
        ZPosSlowEnd     := g_cfg[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := g_cfg[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := g_cfg[i].SpeedLiftFast_Z,
        DripTrayDelay   := g_cfg[i].DripTrayDelay,
        DroppingTime    := g_station[g_transporter[i].LiftStationTarget].DrippingTime,
        z_mm          := tmp_z,
        z_stage       := tmp_zs,
        z_timer_s     := tmp_zt
      );
      arrived_z := fb_z1.done;
    ELSIF i = 2 THEN
      fb_z2(
        delta_t       := 0.02,
        station_kind  := station_kind,
        ZPosDown        := g_cfg[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := g_cfg[i].ZPosSlowUp,
        ZPosSlowDown    := g_cfg[i].ZPosSlowDown,
        ZPosSlowEnd     := g_cfg[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := g_cfg[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := g_cfg[i].SpeedLiftFast_Z,
        DripTrayDelay   := g_cfg[i].DripTrayDelay,
        DroppingTime    := g_station[g_transporter[i].LiftStationTarget].DrippingTime,
        z_mm          := tmp_z,
        z_stage       := tmp_zs,
        z_timer_s     := tmp_zt
      );
      arrived_z := fb_z2.done;
    ELSIF i = 3 THEN
      fb_z3(
        delta_t       := 0.02,
        station_kind  := station_kind,
        ZPosDown        := g_cfg[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := g_cfg[i].ZPosSlowUp,
        ZPosSlowDown    := g_cfg[i].ZPosSlowDown,
        ZPosSlowEnd     := g_cfg[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := g_cfg[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := g_cfg[i].SpeedLiftFast_Z,
        DripTrayDelay   := g_cfg[i].DripTrayDelay,
        DroppingTime    := g_station[g_transporter[i].LiftStationTarget].DrippingTime,
        z_mm          := tmp_z,
        z_stage       := tmp_zs,
        z_timer_s     := tmp_zt
      );
      arrived_z := fb_z3.done;
    END_IF;
    g_transporter[i].ZPosition      := tmp_z;
    g_sim_trans[i].ZStage   := tmp_zs;
    g_sim_trans[i].ZTimer := tmp_zt;
    IF arrived_z THEN
      (* Record lift done timestamp *)
      ts_lift_done[i] := g_time_s;
      lookup(station_number := g_transporter[i].SinkStationTarget);
      g_transporter[i].XFinalTarget := lookup.x_mm;
      g_transporter[i].Phase := 3;
    END_IF;

  (* ── Phase 3: Drive X towards sink station ─────────────── *)
  ELSIF g_transporter[i].Phase = 3 THEN
    tmp_x  := g_transporter[i].XPosition;
    tmp_vx := g_sim_trans[i].XVelocity;
    IF i = 1 THEN
      fb_x1(
        delta_t  := 0.02,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
      arrived_x := fb_x1.arrived;
    ELSIF i = 2 THEN
      fb_x2(
        delta_t  := 0.02,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
      arrived_x := fb_x2.arrived;
    ELSIF i = 3 THEN
      fb_x3(
        delta_t  := 0.02,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
      arrived_x := fb_x3.arrived;
    END_IF;
    g_transporter[i].XPosition  := tmp_x;
    g_sim_trans[i].XVelocity := tmp_vx;

    (* Only transition when actually at station, not just at drive limit *)
    at_station := arrived_x
                  AND (ABS(g_transporter[i].XPosition - g_transporter[i].XFinalTarget) <= 6);
    IF at_station THEN
      g_transporter[i].CurrentStation := g_transporter[i].SinkStationTarget;
      (* Record arrival at sink timestamp *)
      ts_at_sink[i] := g_time_s;
      lookup(station_number := g_transporter[i].SinkStationTarget);
      device_delay := lookup.device_delay_s;
      g_sim_trans[i].ZTimer := device_delay + INT_TO_REAL(g_cfg[i].DripTrayDelay) / 10.0;
      g_sim_trans[i].ZStage := 6;
      g_transporter[i].Phase := 4;
    END_IF;
    (* If arrived_x but not at_station → at drive limit, wait for clearance *)

  (* ── Phase 4: Sink Z at sink station ───────────────────── *)
  ELSIF g_transporter[i].Phase = 4 THEN
    lookup(station_number := g_transporter[i].SinkStationTarget);
    station_kind := lookup.skind;
    tmp_z  := g_transporter[i].ZPosition;
    tmp_zs := g_sim_trans[i].ZStage;
    tmp_zt := g_sim_trans[i].ZTimer;
    IF i = 1 THEN
      fb_z1(
        delta_t       := 0.02,
        station_kind  := station_kind,
        ZPosDown        := g_cfg[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := g_cfg[i].ZPosSlowUp,
        ZPosSlowDown    := g_cfg[i].ZPosSlowDown,
        ZPosSlowEnd     := g_cfg[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := g_cfg[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := g_cfg[i].SpeedLiftFast_Z,
        DripTrayDelay   := g_cfg[i].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := tmp_z,
        z_stage       := tmp_zs,
        z_timer_s     := tmp_zt
      );
      arrived_z := fb_z1.done;
    ELSIF i = 2 THEN
      fb_z2(
        delta_t       := 0.02,
        station_kind  := station_kind,
        ZPosDown        := g_cfg[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := g_cfg[i].ZPosSlowUp,
        ZPosSlowDown    := g_cfg[i].ZPosSlowDown,
        ZPosSlowEnd     := g_cfg[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := g_cfg[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := g_cfg[i].SpeedLiftFast_Z,
        DripTrayDelay   := g_cfg[i].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := tmp_z,
        z_stage       := tmp_zs,
        z_timer_s     := tmp_zt
      );
      arrived_z := fb_z2.done;
    ELSIF i = 3 THEN
      fb_z3(
        delta_t       := 0.02,
        station_kind  := station_kind,
        ZPosDown        := g_cfg[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := g_cfg[i].ZPosSlowUp,
        ZPosSlowDown    := g_cfg[i].ZPosSlowDown,
        ZPosSlowEnd     := g_cfg[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := g_cfg[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := g_cfg[i].SpeedLiftFast_Z,
        DripTrayDelay   := g_cfg[i].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := tmp_z,
        z_stage       := tmp_zs,
        z_timer_s     := tmp_zt
      );
      arrived_z := fb_z3.done;
    END_IF;
    g_transporter[i].ZPosition      := tmp_z;
    g_sim_trans[i].ZStage   := tmp_zs;
    g_sim_trans[i].ZTimer := tmp_zt;
    IF arrived_z THEN
      (* ── Emit TASK_COMPLETE event (msg_type=3) before Phase reset ── *)
      IF NOT g_event_pending_valid THEN
        (* Config-based sub-phase durations *)
        dropping_s := g_transporter[i].DrippingTime / 10;
        IF g_cfg[i].DripTrayInUse THEN
          trip_s := g_cfg[i].DripTrayDelay / 10;
        ELSE
          trip_s := 0;
        END_IF;
        (* Nosto = total lift phase - dropping - trip_close
           device_delay no longer in lift phase (overlapped in Phase 1) *)
        dur_nosto := LINT_TO_INT(ts_lift_done[i] - ts_lift_begin[i])
                     - dropping_s - trip_s;
        IF dur_nosto < 0 THEN dur_nosto := 0; END_IF;
        (* Lasku = total sink phase - device_delay - trip_open *)
        dd_lift_s := g_sim_trans[i].SinkDeviceDelay / 10;
        dur_lasku := LINT_TO_INT(g_time_s - ts_at_sink[i]) - dd_lift_s - trip_s;
        IF dur_lasku < 0 THEN dur_lasku := 0; END_IF;

        g_event_pending.MsgType := 3;
        g_event_pending.TsHi := LINT_TO_INT(g_time_s / LINT#65536);
        g_event_pending.TsLo := LINT_TO_INT(g_time_s MOD LINT#65536);
        g_event_pending.Payload[1]  := LINT_TO_INT(g_transporter[i].TaskId / LINT#65536);   (* TaskId_Hi *)
        g_event_pending.Payload[2]  := LINT_TO_INT(g_transporter[i].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        g_event_pending.Payload[3]  := i;                                                     (* transporter *)
        g_event_pending.Payload[4]  := LINT_TO_INT(ts_at_lift[i] - ts_task_start[i]);         (* siirto nostoasemalle *)
        g_event_pending.Payload[5]  := LINT_TO_INT(ts_lift_begin[i] - ts_at_lift[i]);         (* odotus ennen nostoa (max(treat,dev_delay)) *)
        g_event_pending.Payload[6]  := dur_nosto;                                             (* nosto *)
        g_event_pending.Payload[7]  := dropping_s;                                            (* valutus *)
        g_event_pending.Payload[8]  := trip_s;                                                (* trip close *)
        g_event_pending.Payload[9]  := LINT_TO_INT(ts_at_sink[i] - ts_lift_done[i]);          (* siirto laskuasemalle *)
        g_event_pending.Payload[10] := trip_s;                                                (* trip open *)
        g_event_pending.Payload[11] := dur_lasku;                                             (* lasku *)
        g_event_pending.Payload[12] := LINT_TO_INT(g_time_s - ts_task_start[i]);              (* total *)
        g_event_pending_valid := TRUE;
      END_IF;

      (* Unit moves from transporter → sink station *)
      sink_unit_id := g_station_loc[i].UnitId;
      IF sink_unit_id >= 1 THEN
        IF i = 1 THEN
          upd_loc1(i_unit := sink_unit_id, i_location := g_transporter[i].SinkStationTarget, i_ntt_primary := g_sim_trans[i].NttPrimary);
        ELSIF i = 2 THEN
          upd_loc2(i_unit := sink_unit_id, i_location := g_transporter[i].SinkStationTarget, i_ntt_primary := g_sim_trans[i].NttPrimary);
        ELSIF i = 3 THEN
          upd_loc3(i_unit := sink_unit_id, i_location := g_transporter[i].SinkStationTarget, i_ntt_primary := g_sim_trans[i].NttPrimary);
        END_IF;
      END_IF;

      g_transporter[i].Phase := 0;
      g_transporter[i].Status := 3;  (* auto_idle *)

    END_IF;
  END_IF;  (* ELSIF chain: phases 0→1→2→3→4 *)

  (* ── Phase 0 idle: drive back inside limits if outside ────── *)
  IF g_transporter[i].Phase = 0 THEN
    tmp_x  := g_transporter[i].XPosition;
    tmp_vx := g_sim_trans[i].XVelocity;
    (* Use current position as target — XMotion will clamp to nearest limit if outside *)
    IF i = 1 THEN
      fb_x1(
        delta_t  := 0.02,
        x_target := tmp_x,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
    ELSIF i = 2 THEN
      fb_x2(
        delta_t  := 0.02,
        x_target := tmp_x,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
    ELSIF i = 3 THEN
      fb_x3(
        delta_t  := 0.02,
        x_target := tmp_x,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := g_cfg[i].SpeedMax_X,
        t_acc    := g_cfg[i].Acceleration_X,
        t_dec    := g_cfg[i].Deceleration_X,
        x_pos    := tmp_x,
        v_x      := tmp_vx
      );
    END_IF;
    g_transporter[i].XPosition  := tmp_x;
    g_sim_trans[i].XVelocity := tmp_vx;
  END_IF;

  (* ── Nearest station tracking ──────────────────────────── *)
  min_dist := 999999999;
  nearest_num := g_transporter[i].CurrentStation;
  FOR idx := MIN_StationIndex TO MAX_StationIndex DO
    IF g_station[idx].TankId <> 0 THEN
      dx := g_station[idx].XPosition - g_transporter[i].XPosition;
      IF ABS(dx) < min_dist THEN
        min_dist := ABS(dx);
        nearest_num := idx;
      END_IF;
    END_IF;
  END_FOR;
  g_transporter[i].CurrentStation := nearest_num;

  (* ── Measure move times (one instance per transporter) ──── *)
  IF i = 1 THEN
    tm1(t_id := 1, phase := g_transporter[1].Phase, delta_t := 0.02,
        vel_x := g_sim_trans[1].XVelocity, z_stage := g_sim_trans[1].ZStage,
        lift_stn := g_transporter[1].LiftStationTarget,
        sink_stn := g_transporter[1].SinkStationTarget,
        from_stn := g_transporter[1].CurrentStation);
  ELSIF i = 2 THEN
    tm2(t_id := 2, phase := g_transporter[2].Phase, delta_t := 0.02,
        vel_x := g_sim_trans[2].XVelocity, z_stage := g_sim_trans[2].ZStage,
        lift_stn := g_transporter[2].LiftStationTarget,
        sink_stn := g_transporter[2].SinkStationTarget,
        from_stn := g_transporter[2].CurrentStation);
  ELSIF i = 3 THEN
    tm3(t_id := 3, phase := g_transporter[3].Phase, delta_t := 0.02,
        vel_x := g_sim_trans[3].XVelocity, z_stage := g_sim_trans[3].ZStage,
        lift_stn := g_transporter[3].LiftStationTarget,
        sink_stn := g_transporter[3].SinkStationTarget,
        from_stn := g_transporter[3].CurrentStation);
  END_IF;

  END_IF;  (* active *)
END_FOR;

END_FUNCTION_BLOCK

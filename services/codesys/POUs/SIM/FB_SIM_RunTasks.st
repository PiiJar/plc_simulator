(* ============================================================
   FB_SIM_RunTasks — Simulate transporter task execution

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
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
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION_BLOCK FB_SIM_RunTasks
VAR_INPUT
  iRun     : BOOL;   (* enable — typically vInitDone *)
  iDeltaT : REAL;   (* actual cycle time in seconds *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS    : INT;
    MAX_UNITS           : INT;
    MAX_STEPS_PER_PROGRAM          : INT;
    MIN_STATION_INDEX : INT;
    MAX_STATION_INDEX   : INT;
    IN_PROCESS          : INT;
END_VAR

VAR_EXTERNAL
  g_transporter  : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  g_sim_trans    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  Stations      : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  g_station_occupancy  : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters          : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_move         : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  g_actual_move  : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ActualMoveTimeType;
  g_unit         : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  g_batch        : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms      : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_time_s       : LINT;
  g_event_pending       : UDT_JC_EventMsgType;
  g_event_pending_valid : BOOL;
  g_dispatched_task     : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
END_VAR
VAR
  i            : INT;
  vIdx          : INT;
  (* Physics FB instances — one per transporter (MATIEC needs separate instances) *)
  fb_x1        : FB_SIM_XMotion;
  fb_x2        : FB_SIM_XMotion;
  fb_x3        : FB_SIM_XMotion;
  fb_z1        : FB_SIM_ZMotion;
  fb_z2        : FB_SIM_ZMotion;
  fb_z3        : FB_SIM_ZMotion;
  (* Temp vars for VAR_IN_OUT passing *)
  vTmpX        : DINT;
  vTmpVx       : DINT;
  vTmpZ        : DINT;
  vTmpZs       : INT;
  vTmpZt       : REAL;
  arrived_x    : BOOL;
  at_station   : BOOL;    (* TRUE only when actually at station, not just at drive limit *)
  arrived_z    : BOOL;
  vStationKind : INT;
  device_delay : REAL;
  vDropTime    : REAL;
  vPickUnitId : INT;     (* unit_id picked up from lift station *)
  vXferTotal   : REAL;    (* transfer time for UI progress bar *)
  vSinkUnitId : INT;     (* unit_id being placed at sink station *)
  (* Nearest-station calculation *)
  vNearestNum  : INT;
  vMinDist     : DINT;
  dx           : DINT;
  (* Actual move time tracker — now FC FC_STC_TrackMoveTimes, no instance vNeeded *)
  (* Unit vLocation update — now FC FC_STC_UpdateUnitLocation, no instance vNeeded *)
  (* Event helpers *)
  evt_unit     : INT;
  evt_diff     : LINT;
  (* Treatment time wait *)
  vCanLift       : BOOL;
  vLiftUid       : INT;      (* unit at lift station *)
  treat_cal      : DINT;      (* treatment cal_time for current stage *)
  treat_elapsed  : LINT;     (* seconds spent at lift station *)
  (* ── TASK_COMPLETE event: vPhase timestamps per transporter ── *)
  ts_task_start  : ARRAY[1..3] OF LINT;  (* Phase 0→1: task accepted *)
  ts_at_lift     : ARRAY[1..3] OF LINT;  (* Phase 1 at_station: arrived at lift *)
  ts_lift_begin  : ARRAY[1..3] OF LINT;  (* Phase 1→2: vCanLift, begin lift *)
  ts_lift_done   : ARRAY[1..3] OF LINT;  (* Phase 2→3: lift complete *)
  ts_at_sink     : ARRAY[1..3] OF LINT;  (* Phase 3→4: arrived at sink *)
  (* TASK_COMPLETE temp vars *)
  dd_lift_s      : INT;   (* lift device_delay in seconds *)
  dropping_s     : INT;   (* dropping/valutus time in seconds *)
  trip_s         : INT;   (* drip tray vDelay in seconds, 0 if not used *)
  vDurNosto      : INT;   (* computed nosto vDuration *)
  vDurLasku      : INT;   (* computed lasku vDuration *)
END_VAR

IF NOT iRun THEN
  RETURN;
END_IF;

FOR i := 1 TO MAX_TRANSPORTERS DO
  IF g_transporter[i].IsActive THEN

  (* ── Phase 0 → 1: Accept new task ───────────────────────── *)
  IF (g_transporter[i].Phase = 0)
     AND g_dispatched_task[i].Active THEN
    g_transporter[i].XFinalTarget := g_dispatched_task[i].LiftX;
    g_transporter[i].Status := 4;  (* auto_run — must be set before TrackMoveTimes *)
    g_transporter[i].Phase := 1;
    FC_STC_TrackMoveTimes(iTrans := i, iPrev := 0, iNew := 1);
    g_sim_trans[i].ZStage := 0;
    g_sim_trans[i].ZTimer := 0.0;
    (* Record task start timestamp *)
    ts_task_start[i] := g_time_s;
    ts_at_lift[i]    := LINT#0;

  (* ── Phase 1: Drive X towards lift station ──────────────── *)
  ELSIF g_transporter[i].Phase = 1 THEN
    vTmpX  := g_transporter[i].XPosition;
    vTmpVx := g_sim_trans[i].XVelocity;
    IF i = 1 THEN
      fb_x1(
        delta_t  := iDeltaT,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      arrived_x := fb_x1.arrived;
      g_transporter[i].XDriveTarget := fb_x1.x_drive;
    ELSIF i = 2 THEN
      fb_x2(
        delta_t  := iDeltaT,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      arrived_x := fb_x2.arrived;
      g_transporter[i].XDriveTarget := fb_x2.x_drive;
    ELSIF i = 3 THEN
      fb_x3(
        delta_t  := iDeltaT,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      arrived_x := fb_x3.arrived;
      g_transporter[i].XDriveTarget := fb_x3.x_drive;
    END_IF;
    g_transporter[i].XPosition  := vTmpX;
    g_sim_trans[i].XVelocity := vTmpVx;

    (* Only transition when actually at station, not just at drive limit *)
    at_station := arrived_x
                  AND (ABS(g_transporter[i].XPosition - g_transporter[i].XFinalTarget) <= 6);
    IF at_station THEN
      g_transporter[i].CurrentStation := g_transporter[i].LiftStationTarget;

      (* ── Move-away arrival: Status=3 means idle repositioning, not a real task ── *)
      IF g_transporter[i].Status = 3 THEN
        g_transporter[i].Phase := 0;
        g_transporter[i].IdleStartTime := g_time_s;
        FC_STC_TrackMoveTimes(iTrans := i, iPrev := 1, iNew := 0);
      ELSE
      (* Record arrival at lift station (first time only) *)
      IF ts_at_lift[i] = LINT#0 THEN
        ts_at_lift[i] := g_time_s;
      END_IF;

      (* ── Wait for treatment time AND device_delay before lifting ──
         Z-movement starts when the LONGER of two has elapsed:
         1. Remaining treatment time (unit must finish treatment)
         2. Station device_delay (vCovers must be open)
         Both timers run simultaneously from transporter arrival.
         This matches JS behavior: max(treatment, device_delay). *)
      vCanLift := TRUE;
      device_delay := INT_TO_REAL(g_dispatched_task[i].LiftDeviceDelay_x10) / 10.0;
      vDropTime := INT_TO_REAL(g_dispatched_task[i].DroppingTime_x10) / 10.0;

      (* Check treatment time *)
      vLiftUid := g_station_occupancy[g_transporter[i].LiftStationTarget].UnitId;
      IF vLiftUid >= 1 AND vLiftUid <= MAX_UNITS THEN
        IF g_batch[vLiftUid].State = IN_PROCESS
           AND g_batch[vLiftUid].CurStage >= 1
           AND g_batch[vLiftUid].CurStage <= MAX_STEPS_PER_PROGRAM THEN
          treat_cal := TreatmentPrograms[vLiftUid].Steps[g_batch[vLiftUid].CurStage].CalTime;
          IF treat_cal > 0 THEN
            treat_elapsed := g_time_s - g_station_occupancy[g_transporter[i].LiftStationTarget].ChangeTime;
            IF treat_elapsed < DINT_TO_LINT(treat_cal) THEN
              vCanLift := FALSE;
            END_IF;
          END_IF;
        END_IF;
      END_IF;

      (* Check device_delay — vCovers must have had time to open since arrival *)
      IF vCanLift AND device_delay > 0.0 THEN
        IF LINT_TO_REAL(g_time_s - ts_at_lift[i]) < device_delay THEN
          vCanLift := FALSE;
        END_IF;
      END_IF;

      IF vCanLift THEN
      (* Record lift begin timestamp *)
      ts_lift_begin[i] := g_time_s;
      (* vDropTime vAlready captured by STC_FindStation above *)
      (* Skip stage 1 — device_delay vAlready overlapped above.
         Z-movement starts immediately (stage 2).
         dropping_time and drip_tray_delay happen at the TOP. *)
      g_transporter[i].ZPosition := 0;
      g_sim_trans[i].ZTimer := 0.0;
      g_sim_trans[i].ZStage := 2;
      g_transporter[i].Phase := 2;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 1, iNew := 2);

      (* ── Calculate transfer time (used by event + batch times) ── *)
      vXferTotal := DINT_TO_REAL(g_dispatched_task[i].TransferTime_x10) / 10.0;
      IF vXferTotal < 5.0 THEN vXferTotal := 60.0; END_IF;

      (* ── Emit LIFT event (msg_type=2) ── *)
      evt_unit := g_station_occupancy[g_transporter[i].LiftStationTarget].UnitId;
      IF NOT g_event_pending_valid AND evt_unit >= 1 THEN
        g_event_pending.MsgType := 2;
        g_event_pending.TsHi := LINT_TO_UINT(g_time_s / LINT#65536);
        g_event_pending.TsLo := LINT_TO_UINT(g_time_s MOD LINT#65536);
        g_event_pending.Payload[1]  := LINT_TO_INT(g_transporter[i].TaskId / LINT#65536);   (* TaskId_Hi *)
        g_event_pending.Payload[2]  := LINT_TO_INT(g_transporter[i].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        g_event_pending.Payload[3]  := i;
        g_event_pending.Payload[4]  := evt_unit;
        g_event_pending.Payload[5]  := g_transporter[i].LiftStationTarget;
        g_event_pending.Payload[6]  := g_batch[evt_unit].BatchCode;
        g_event_pending.Payload[7]  := g_batch[evt_unit].CurStage;
        evt_diff := g_time_s - g_station_occupancy[g_transporter[i].LiftStationTarget].ChangeTime;
        IF evt_diff > LINT#32000 THEN
          g_event_pending.Payload[8] := 32000;
        ELSE
          g_event_pending.Payload[8] := LINT_TO_INT(evt_diff);
        END_IF;
        (* ── Original program calc/min/max for this stage ── *)
        (* g_sim_trans holds dispatch-time scheduler values which may differ
           from the treatment program originals. Read directly from TreatmentPrograms
           using the batch's current stage (CurStage=1-based program index). *)
        IF g_batch[evt_unit].CurStage >= 1 AND g_batch[evt_unit].CurStage <= 30 THEN
          g_event_pending.Payload[9]  := DINT_TO_INT(TreatmentPrograms[evt_unit].Steps[g_batch[evt_unit].CurStage].CalTime);
          g_event_pending.Payload[10] := DINT_TO_INT(TreatmentPrograms[evt_unit].Steps[g_batch[evt_unit].CurStage].MinTime);
          g_event_pending.Payload[11] := DINT_TO_INT(TreatmentPrograms[evt_unit].Steps[g_batch[evt_unit].CurStage].MaxTime);
        ELSE
          (* Stage 0 (pickup) — no program step *)
          g_event_pending.Payload[9]  := 0;
          g_event_pending.Payload[10] := 0;
          g_event_pending.Payload[11] := 0;
        END_IF;
        g_event_pending.Payload[12] := REAL_TO_INT(vXferTotal);
        g_event_pending_valid := TRUE;
      END_IF;

      (* Unit moves from lift station → transporter *)
      vPickUnitId := g_station_occupancy[g_transporter[i].LiftStationTarget].UnitId;
      IF vPickUnitId >= 1 THEN
        FC_STC_UpdateUnitLocation(iUnit := vPickUnitId, iLocation := i, iNttPrimary := 0);

        (* Set batch transfer times for UI progress bar — matches JS behavior *)
        g_batch[vPickUnitId].StartTime := g_time_s;
        g_batch[vPickUnitId].CalTime   := REAL_TO_DINT(vXferTotal);
        g_batch[vPickUnitId].MinTime   := g_batch[vPickUnitId].CalTime;
        g_batch[vPickUnitId].MaxTime   := 600;
      END_IF;
      END_IF;  (* vCanLift *)
      END_IF;  (* Status=3 ELSE branch *)
    END_IF;
    (* If arrived_x but not at_station → at drive limit, wait for clearance *)

  (* ── Phase 2: Lift Z at lift station ────────────────────── *)
  ELSIF g_transporter[i].Phase = 2 THEN
    vStationKind := g_dispatched_task[i].LiftKind;
    vTmpZ  := g_transporter[i].ZPosition;
    vTmpZs := g_sim_trans[i].ZStage;
    vTmpZt := g_sim_trans[i].ZTimer;
    IF i = 1 THEN
      fb_z1(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[i].ZPosSlowUp,
        ZPosSlowDown    := Transporters[i].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[i].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[i].DripTrayDelay,
        DroppingTime    := g_dispatched_task[i].DroppingTime_x10,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      arrived_z := fb_z1.vDone;
    ELSIF i = 2 THEN
      fb_z2(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[i].ZPosSlowUp,
        ZPosSlowDown    := Transporters[i].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[i].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[i].DripTrayDelay,
        DroppingTime    := g_dispatched_task[i].DroppingTime_x10,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      arrived_z := fb_z2.vDone;
    ELSIF i = 3 THEN
      fb_z3(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[i].ZPosSlowUp,
        ZPosSlowDown    := Transporters[i].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[i].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[i].DripTrayDelay,
        DroppingTime    := g_dispatched_task[i].DroppingTime_x10,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      arrived_z := fb_z3.vDone;
    END_IF;
    g_transporter[i].ZPosition      := vTmpZ;
    g_sim_trans[i].ZStage   := vTmpZs;
    g_sim_trans[i].ZTimer := vTmpZt;
    IF arrived_z THEN
      (* Record lift vDone timestamp *)
      ts_lift_done[i] := g_time_s;
      g_transporter[i].XFinalTarget := g_dispatched_task[i].SinkX;
      g_transporter[i].Phase := 3;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 2, iNew := 3);
    END_IF;

  (* ── Phase 3: Drive X towards sink station ─────────────── *)
  ELSIF g_transporter[i].Phase = 3 THEN
    vTmpX  := g_transporter[i].XPosition;
    vTmpVx := g_sim_trans[i].XVelocity;
    IF i = 1 THEN
      fb_x1(
        delta_t  := iDeltaT,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      arrived_x := fb_x1.arrived;
      g_transporter[i].XDriveTarget := fb_x1.x_drive;
    ELSIF i = 2 THEN
      fb_x2(
        delta_t  := iDeltaT,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      arrived_x := fb_x2.arrived;
      g_transporter[i].XDriveTarget := fb_x2.x_drive;
    ELSIF i = 3 THEN
      fb_x3(
        delta_t  := iDeltaT,
        x_target := g_transporter[i].XFinalTarget,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      arrived_x := fb_x3.arrived;
      g_transporter[i].XDriveTarget := fb_x3.x_drive;
    END_IF;
    g_transporter[i].XPosition  := vTmpX;
    g_sim_trans[i].XVelocity := vTmpVx;

    (* Only transition when actually at station, not just at drive limit *)
    at_station := arrived_x
                  AND (ABS(g_transporter[i].XPosition - g_transporter[i].XFinalTarget) <= 6);
    IF at_station THEN
      g_transporter[i].CurrentStation := g_transporter[i].SinkStationTarget;
      (* Record arrival at sink timestamp *)
      ts_at_sink[i] := g_time_s;
      device_delay := INT_TO_REAL(g_dispatched_task[i].SinkDeviceDelay_x10) / 10.0;
      g_sim_trans[i].ZTimer := device_delay + INT_TO_REAL(g_dispatched_task[i].DripTrayDelay_x10) / 10.0;
      g_sim_trans[i].ZStage := 6;
      g_transporter[i].Phase := 4;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 3, iNew := 4);
    END_IF;
    (* If arrived_x but not at_station → at drive limit, wait for clearance *)

  (* ── Phase 4: Sink Z at sink station ───────────────────── *)
  ELSIF g_transporter[i].Phase = 4 THEN
    vStationKind := g_dispatched_task[i].SinkKind;
    vTmpZ  := g_transporter[i].ZPosition;
    vTmpZs := g_sim_trans[i].ZStage;
    vTmpZt := g_sim_trans[i].ZTimer;
    IF i = 1 THEN
      fb_z1(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[i].ZPosSlowUp,
        ZPosSlowDown    := Transporters[i].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[i].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[i].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      arrived_z := fb_z1.vDone;
    ELSIF i = 2 THEN
      fb_z2(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[i].ZPosSlowUp,
        ZPosSlowDown    := Transporters[i].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[i].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[i].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      arrived_z := fb_z2.vDone;
    ELSIF i = 3 THEN
      fb_z3(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[i].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[i].ZPosSlowUp,
        ZPosSlowDown    := Transporters[i].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[i].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[i].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[i].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      arrived_z := fb_z3.vDone;
    END_IF;
    g_transporter[i].ZPosition      := vTmpZ;
    g_sim_trans[i].ZStage   := vTmpZs;
    g_sim_trans[i].ZTimer := vTmpZt;
    IF arrived_z THEN
      (* ── Emit TASK_COMPLETE event (msg_type=3) before Phase reset ── *)
      IF NOT g_event_pending_valid THEN
        (* Config-based sub-vPhase durations *)
        dropping_s := g_transporter[i].DrippingTime / 10;
        IF Transporters[i].DripTrayInUse THEN
          trip_s := Transporters[i].DripTrayDelay / 10;
        ELSE
          trip_s := 0;
        END_IF;
        (* Nosto = total lift vPhase - dropping - trip_close
           device_delay no longer in lift vPhase (overlapped in Phase 1) *)
        vDurNosto := LINT_TO_INT(ts_lift_done[i] - ts_lift_begin[i])
                     - dropping_s - trip_s;
        IF vDurNosto < 0 THEN vDurNosto := 0; END_IF;
        (* Lasku = total sink vPhase - device_delay - trip_open *)
        dd_lift_s := g_dispatched_task[i].SinkDeviceDelay_x10 / 10;
        vDurLasku := LINT_TO_INT(g_time_s - ts_at_sink[i]) - dd_lift_s - trip_s;
        IF vDurLasku < 0 THEN vDurLasku := 0; END_IF;

        g_event_pending.MsgType := 3;
        g_event_pending.TsHi := LINT_TO_UINT(g_time_s / LINT#65536);
        g_event_pending.TsLo := LINT_TO_UINT(g_time_s MOD LINT#65536);
        g_event_pending.Payload[1]  := LINT_TO_INT(g_transporter[i].TaskId / LINT#65536);   (* TaskId_Hi *)
        g_event_pending.Payload[2]  := LINT_TO_INT(g_transporter[i].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        g_event_pending.Payload[3]  := i;                                                     (* transporter *)
        g_event_pending.Payload[4]  := LINT_TO_INT(ts_at_lift[i] - ts_task_start[i]);         (* siirto nostoasemalle *)
        g_event_pending.Payload[5]  := LINT_TO_INT(ts_lift_begin[i] - ts_at_lift[i]);         (* odotus ennen nostoa (max(treat,dev_delay)) *)
        g_event_pending.Payload[6]  := vDurNosto;                                             (* nosto *)
        g_event_pending.Payload[7]  := dropping_s;                                            (* valutus *)
        g_event_pending.Payload[8]  := trip_s;                                                (* trip close *)
        g_event_pending.Payload[9]  := LINT_TO_INT(ts_at_sink[i] - ts_lift_done[i]);          (* siirto laskuasemalle *)
        g_event_pending.Payload[10] := trip_s;                                                (* trip open *)
        g_event_pending.Payload[11] := vDurLasku;                                             (* lasku *)
        g_event_pending.Payload[12] := LINT_TO_INT(g_time_s - ts_task_start[i]);              (* total *)
        g_event_pending_valid := TRUE;
      END_IF;

      (* Unit moves from transporter → sink station *)
      vSinkUnitId := g_station_occupancy[i].UnitId;
      IF vSinkUnitId >= 1 THEN
        FC_STC_UpdateUnitLocation(iUnit := vSinkUnitId, iLocation := g_transporter[i].SinkStationTarget, iNttPrimary := g_dispatched_task[i].NttPrimary);
      END_IF;

      g_transporter[i].Phase := 0;
      g_transporter[i].CurrentTaskFinishTime := 0;
      g_dispatched_task[i].Active := FALSE;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 4, iNew := 0);
      g_transporter[i].Status := 3;  (* auto_idle *)
      g_transporter[i].IdleStartTime := g_time_s;  (* move-away idle timer *)

    END_IF;
  END_IF;  (* ELSIF chain: phases 0→1→2→3→4 *)

  (* ── Phase 0 idle: drive back inside limits if outside ────── *)
  IF g_transporter[i].Phase = 0 THEN
    vTmpX  := g_transporter[i].XPosition;
    vTmpVx := g_sim_trans[i].XVelocity;
    (* Use current position as target — XMotion will clamp to nearest limit if outside *)
    IF i = 1 THEN
      fb_x1(
        delta_t  := iDeltaT,
        x_target := vTmpX,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
    ELSIF i = 2 THEN
      fb_x2(
        delta_t  := iDeltaT,
        x_target := vTmpX,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
    ELSIF i = 3 THEN
      fb_x3(
        delta_t  := iDeltaT,
        x_target := vTmpX,
        x_min    := g_transporter[i].XMinDriveLimit,
        x_max    := g_transporter[i].XMaxDriveLimit,
        v_max    := Transporters[i].SpeedMax_X,
        t_acc    := Transporters[i].Acceleration_X,
        t_dec    := Transporters[i].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
    END_IF;
    g_transporter[i].XPosition  := vTmpX;
    g_sim_trans[i].XVelocity := vTmpVx;
  END_IF;

  (* ── Nearest station tracking ──────────────────────────── *)
  vMinDist := 999999999;
  vNearestNum := g_transporter[i].CurrentStation;
  FOR vIdx := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
    IF Stations[vIdx].TankId <> 0 THEN
      dx := Stations[vIdx].XPosition - g_transporter[i].XPosition;
      IF ABS(dx) < vMinDist THEN
        vMinDist := ABS(dx);
        vNearestNum := vIdx;
      END_IF;
    END_IF;
  END_FOR;
  g_transporter[i].CurrentStation := vNearestNum;

  END_IF;  (* active *)
END_FOR;

END_FUNCTION_BLOCK

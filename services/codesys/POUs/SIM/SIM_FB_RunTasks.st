(* ============================================================
   SIM_FB_RunTasks — Simulate transporter task execution

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

FUNCTION_BLOCK SIM_FB_RunTasks
VAR_INPUT
  iRun     : BOOL;   (* enable — typically init_done *)
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
  TransporterStatus  : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  SimTrans    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  Stations      : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  StationOccupancy  : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters          : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  Move         : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  ActualMove  : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ActualMoveTimeType;
  Unit         : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Batch        : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms      : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  TimeS       : LINT;
  EventPending       : UDT_JC_EventMsgType;
  EventPendingValid : BOOL;
  DispatchedTask     : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
END_VAR
VAR
  vI            : INT;
  vIdx          : INT;
  (* Physics FB instances — one per transporter (MATIEC needs separate instances) *)
  vFB_X1        : SIM_FB_XMotion;
  vFB_X2        : SIM_FB_XMotion;
  vFB_X3        : SIM_FB_XMotion;
  vFB_Z1        : SIM_FB_ZMotion;
  vFB_Z2        : SIM_FB_ZMotion;
  vFB_Z3        : SIM_FB_ZMotion;
  (* Temp vars for VAR_IN_OUT passing *)
  vTmpX        : DINT;
  vTmpVx       : DINT;
  vTmpZ        : DINT;
  vTmpZs       : INT;
  vTmpZt       : REAL;
  vArrivedX    : BOOL;
  vAtStation   : BOOL;    (* TRUE only when actually at station, not just at drive limit *)
  vArrivedZ    : BOOL;
  vStationKind : INT;
  vDeviceDelay : REAL;
  vDropTime    : REAL;
  vPickUnitId : INT;     (* unit_id picked up from lift station *)
  vXferTotal   : REAL;    (* transfer time for UI progress bar *)
  vSinkUnitId : INT;     (* unit_id being placed at sink station *)
  (* Nearest-station calculation *)
  vNearestNum  : INT;
  vMinDist     : DINT;
  vDx           : DINT;
  (* Actual move time tracker — now FC STC_FC_TrackMoveTimes, no instance needed *)
  (* Unit location update — now FC STC_FC_UpdateUnitLocation, no instance needed *)
  (* Event helpers *)
  vEvtUnit     : INT;
  vEvtDiff     : LINT;
  (* Treatment time wait *)
  vCanLift       : BOOL;
  vLiftUid       : INT;      (* unit at lift station *)
  vTreatCal      : DINT;      (* treatment cal_time for current stage *)
  vTreatElapsed  : LINT;     (* seconds spent at lift station *)
  (* ── TASK_COMPLETE event: phase timestamps per transporter ── *)
  vTsTaskStart  : ARRAY[1..3] OF LINT;  (* Phase 0→1: task accepted *)
  vTsAtLift     : ARRAY[1..3] OF LINT;  (* Phase 1 vAtStation: arrived at lift *)
  vTsLiftBegin  : ARRAY[1..3] OF LINT;  (* Phase 1→2: vCanLift, begin lift *)
  vTsLiftDone   : ARRAY[1..3] OF LINT;  (* Phase 2→3: lift complete *)
  vTsAtSink     : ARRAY[1..3] OF LINT;  (* Phase 3→4: arrived at sink *)
  (* TASK_COMPLETE temp vars *)
  vDdLiftS      : INT;   (* lift vDeviceDelay in seconds *)
  vDroppingS     : INT;   (* dropping/valutus time in seconds *)
  vTripS         : INT;   (* drip tray delay in seconds, 0 if not used *)
  vDurNosto      : INT;   (* computed nosto duration *)
  vDurLasku      : INT;   (* computed lasku duration *)
END_VAR

IF NOT iRun THEN
  RETURN;
END_IF;

FOR vI := 1 TO MAX_TRANSPORTERS DO
  IF TransporterStatus[vI].IsActive THEN

  (* ── Phase 0 → 1: Accept new task ───────────────────────── *)
  IF (TransporterStatus[vI].Phase = 0)
     AND DispatchedTask[vI].Active THEN
    TransporterStatus[vI].XFinalTarget := DispatchedTask[vI].LiftX;
    TransporterStatus[vI].Status := 4;  (* auto_run — must be set before TrackMoveTimes *)
    TransporterStatus[vI].Phase := 1;
    STC_FC_TrackMoveTimes(iTrans := vI, iPrev := 0, iNew := 1);
    SimTrans[vI].ZStage := 0;
    SimTrans[vI].ZTimer := 0.0;
    (* Record task start timestamp *)
    vTsTaskStart[vI] := TimeS;
    vTsAtLift[vI]    := LINT#0;

  (* ── Phase 1: Drive X towards lift station ──────────────── *)
  ELSIF TransporterStatus[vI].Phase = 1 THEN
    vTmpX  := TransporterStatus[vI].XPosition;
    vTmpVx := SimTrans[vI].XVelocity;
    IF vI = 1 THEN
      vFB_X1(
        delta_t  := iDeltaT,
        x_target := TransporterStatus[vI].XFinalTarget,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      vArrivedX := vFB_X1.arrived;
      TransporterStatus[vI].XDriveTarget := vFB_X1.x_drive;
    ELSIF vI = 2 THEN
      vFB_X2(
        delta_t  := iDeltaT,
        x_target := TransporterStatus[vI].XFinalTarget,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      vArrivedX := vFB_X2.arrived;
      TransporterStatus[vI].XDriveTarget := vFB_X2.x_drive;
    ELSIF vI = 3 THEN
      vFB_X3(
        delta_t  := iDeltaT,
        x_target := TransporterStatus[vI].XFinalTarget,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      vArrivedX := vFB_X3.arrived;
      TransporterStatus[vI].XDriveTarget := vFB_X3.x_drive;
    END_IF;
    TransporterStatus[vI].XPosition  := vTmpX;
    SimTrans[vI].XVelocity := vTmpVx;

    (* Only transition when actually at station, not just at drive limit *)
    vAtStation := vArrivedX
                  AND (ABS(TransporterStatus[vI].XPosition - TransporterStatus[vI].XFinalTarget) <= 6);
    IF vAtStation THEN
      TransporterStatus[vI].CurrentStation := TransporterStatus[vI].LiftStationTarget;

      (* ── Move-away arrival: Status=3 means idle repositioning, not a real task ── *)
      IF TransporterStatus[vI].Status = 3 THEN
        TransporterStatus[vI].Phase := 0;
        TransporterStatus[vI].IdleStartTime := TimeS;
        STC_FC_TrackMoveTimes(iTrans := vI, iPrev := 1, iNew := 0);
      ELSE
      (* Record arrival at lift station (first time only) *)
      IF vTsAtLift[vI] = LINT#0 THEN
        vTsAtLift[vI] := TimeS;
      END_IF;

      (* ── Wait for treatment time AND vDeviceDelay before lifting ──
         Z-movement starts when the LONGER of two has elapsed:
         1. Remaining treatment time (unit must finish treatment)
         2. Station vDeviceDelay (covers must be open)
         Both timers run simultaneously from transporter arrival.
         This matches JS behavior: max(treatment, vDeviceDelay). *)
      vCanLift := TRUE;
      vDeviceDelay := INT_TO_REAL(DispatchedTask[vI].LiftDeviceDelay_x10) / 10.0;
      vDropTime := INT_TO_REAL(DispatchedTask[vI].DroppingTime_x10) / 10.0;

      (* Check treatment time *)
      vLiftUid := StationOccupancy[TransporterStatus[vI].LiftStationTarget].UnitId;
      IF vLiftUid >= 1 AND vLiftUid <= MAX_UNITS THEN
        IF Batch[vLiftUid].State = IN_PROCESS
           AND Batch[vLiftUid].CurStage >= 1
           AND Batch[vLiftUid].CurStage <= MAX_STEPS_PER_PROGRAM THEN
          vTreatCal := TreatmentPrograms[vLiftUid].Steps[Batch[vLiftUid].CurStage].CalTime;
          IF vTreatCal > 0 THEN
            vTreatElapsed := TimeS - StationOccupancy[TransporterStatus[vI].LiftStationTarget].ChangeTime;
            IF vTreatElapsed < DINT_TO_LINT(vTreatCal) THEN
              vCanLift := FALSE;
            END_IF;
          END_IF;
        END_IF;
      END_IF;

      (* Check vDeviceDelay — covers must have had time to open since arrival *)
      IF vCanLift AND vDeviceDelay > 0.0 THEN
        IF LINT_TO_REAL(TimeS - vTsAtLift[vI]) < vDeviceDelay THEN
          vCanLift := FALSE;
        END_IF;
      END_IF;

      IF vCanLift THEN
      (* Record lift begin timestamp *)
      vTsLiftBegin[vI] := TimeS;
      (* vDropTime already captured by STC_FindStation above *)
      (* Skip stage 1 — vDeviceDelay already overlapped above.
         Z-movement starts immediately (stage 2).
         dropping_time and drip_tray_delay happen at the TOP. *)
      TransporterStatus[vI].ZPosition := 0;
      SimTrans[vI].ZTimer := 0.0;
      SimTrans[vI].ZStage := 2;
      TransporterStatus[vI].Phase := 2;
      STC_FC_TrackMoveTimes(iTrans := vI, iPrev := 1, iNew := 2);

      (* ── Calculate transfer time (used by event + batch times) ── *)
      vXferTotal := DINT_TO_REAL(DispatchedTask[vI].TransferTime_x10) / 10.0;
      IF vXferTotal < 5.0 THEN vXferTotal := 60.0; END_IF;

      (* ── Emit LIFT event (msg_type=2) ── *)
      vEvtUnit := StationOccupancy[TransporterStatus[vI].LiftStationTarget].UnitId;
      IF NOT EventPendingValid AND vEvtUnit >= 1 THEN
        EventPending.MsgType := 2;
        EventPending.TsHi := LINT_TO_UINT(TimeS / LINT#65536);
        EventPending.TsLo := LINT_TO_UINT(TimeS MOD LINT#65536);
        EventPending.Payload[1]  := LINT_TO_INT(TransporterStatus[vI].TaskId / LINT#65536);   (* TaskId_Hi *)
        EventPending.Payload[2]  := LINT_TO_INT(TransporterStatus[vI].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        EventPending.Payload[3]  := vI;
        EventPending.Payload[4]  := vEvtUnit;
        EventPending.Payload[5]  := TransporterStatus[vI].LiftStationTarget;
        EventPending.Payload[6]  := Batch[vEvtUnit].BatchCode;
        EventPending.Payload[7]  := Batch[vEvtUnit].CurStage;
        vEvtDiff := TimeS - StationOccupancy[TransporterStatus[vI].LiftStationTarget].ChangeTime;
        IF vEvtDiff > LINT#32000 THEN
          EventPending.Payload[8] := 32000;
        ELSE
          EventPending.Payload[8] := LINT_TO_INT(vEvtDiff);
        END_IF;
        (* ── Original program calc/min/max for this stage ── *)
        (* SimTrans holds dispatch-time scheduler values which may differ
           from the treatment program originals. Read directly from TreatmentPrograms
           using the batch's current stage (CurStage=1-based program index). *)
        IF Batch[vEvtUnit].CurStage >= 1 AND Batch[vEvtUnit].CurStage <= 30 THEN
          EventPending.Payload[9]  := DINT_TO_INT(TreatmentPrograms[vEvtUnit].Steps[Batch[vEvtUnit].CurStage].CalTime);
          EventPending.Payload[10] := DINT_TO_INT(TreatmentPrograms[vEvtUnit].Steps[Batch[vEvtUnit].CurStage].MinTime);
          EventPending.Payload[11] := DINT_TO_INT(TreatmentPrograms[vEvtUnit].Steps[Batch[vEvtUnit].CurStage].MaxTime);
        ELSE
          (* Stage 0 (pickup) — no program step *)
          EventPending.Payload[9]  := 0;
          EventPending.Payload[10] := 0;
          EventPending.Payload[11] := 0;
        END_IF;
        EventPending.Payload[12] := REAL_TO_INT(vXferTotal);
        EventPendingValid := TRUE;
      END_IF;

      (* Unit moves from lift station → transporter *)
      vPickUnitId := StationOccupancy[TransporterStatus[vI].LiftStationTarget].UnitId;
      IF vPickUnitId >= 1 THEN
        STC_FC_UpdateUnitLocation(iUnit := vPickUnitId, iLocation := vI, iNttPrimary := 0);

        (* Set batch transfer times for UI progress bar — matches JS behavior *)
        Batch[vPickUnitId].StartTime := TimeS;
        Batch[vPickUnitId].CalTime   := REAL_TO_DINT(vXferTotal);
        Batch[vPickUnitId].MinTime   := Batch[vPickUnitId].CalTime;
        Batch[vPickUnitId].MaxTime   := 600;
      END_IF;
      END_IF;  (* vCanLift *)
      END_IF;  (* Status=3 ELSE branch *)
    END_IF;
    (* If vArrivedX but not vAtStation → at drive limit, wait for clearance *)

  (* ── Phase 2: Lift Z at lift station ────────────────────── *)
  ELSIF TransporterStatus[vI].Phase = 2 THEN
    vStationKind := DispatchedTask[vI].LiftKind;
    vTmpZ  := TransporterStatus[vI].ZPosition;
    vTmpZs := SimTrans[vI].ZStage;
    vTmpZt := SimTrans[vI].ZTimer;
    IF vI = 1 THEN
      vFB_Z1(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[vI].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[vI].ZPosSlowUp,
        ZPosSlowDown    := Transporters[vI].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[vI].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[vI].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[vI].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[vI].DripTrayDelay,
        DroppingTime    := DispatchedTask[vI].DroppingTime_x10,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      vArrivedZ := vFB_Z1.done;
    ELSIF vI = 2 THEN
      vFB_Z2(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[vI].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[vI].ZPosSlowUp,
        ZPosSlowDown    := Transporters[vI].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[vI].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[vI].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[vI].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[vI].DripTrayDelay,
        DroppingTime    := DispatchedTask[vI].DroppingTime_x10,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      vArrivedZ := vFB_Z2.done;
    ELSIF vI = 3 THEN
      vFB_Z3(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[vI].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[vI].ZPosSlowUp,
        ZPosSlowDown    := Transporters[vI].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[vI].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[vI].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[vI].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[vI].DripTrayDelay,
        DroppingTime    := DispatchedTask[vI].DroppingTime_x10,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      vArrivedZ := vFB_Z3.done;
    END_IF;
    TransporterStatus[vI].ZPosition      := vTmpZ;
    SimTrans[vI].ZStage   := vTmpZs;
    SimTrans[vI].ZTimer := vTmpZt;
    IF vArrivedZ THEN
      (* Record lift done timestamp *)
      vTsLiftDone[vI] := TimeS;
      TransporterStatus[vI].XFinalTarget := DispatchedTask[vI].SinkX;
      TransporterStatus[vI].Phase := 3;
      STC_FC_TrackMoveTimes(iTrans := vI, iPrev := 2, iNew := 3);
    END_IF;

  (* ── Phase 3: Drive X towards sink station ─────────────── *)
  ELSIF TransporterStatus[vI].Phase = 3 THEN
    vTmpX  := TransporterStatus[vI].XPosition;
    vTmpVx := SimTrans[vI].XVelocity;
    IF vI = 1 THEN
      vFB_X1(
        delta_t  := iDeltaT,
        x_target := TransporterStatus[vI].XFinalTarget,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      vArrivedX := vFB_X1.arrived;
      TransporterStatus[vI].XDriveTarget := vFB_X1.x_drive;
    ELSIF vI = 2 THEN
      vFB_X2(
        delta_t  := iDeltaT,
        x_target := TransporterStatus[vI].XFinalTarget,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      vArrivedX := vFB_X2.arrived;
      TransporterStatus[vI].XDriveTarget := vFB_X2.x_drive;
    ELSIF vI = 3 THEN
      vFB_X3(
        delta_t  := iDeltaT,
        x_target := TransporterStatus[vI].XFinalTarget,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
      vArrivedX := vFB_X3.arrived;
      TransporterStatus[vI].XDriveTarget := vFB_X3.x_drive;
    END_IF;
    TransporterStatus[vI].XPosition  := vTmpX;
    SimTrans[vI].XVelocity := vTmpVx;

    (* Only transition when actually at station, not just at drive limit *)
    vAtStation := vArrivedX
                  AND (ABS(TransporterStatus[vI].XPosition - TransporterStatus[vI].XFinalTarget) <= 6);
    IF vAtStation THEN
      TransporterStatus[vI].CurrentStation := TransporterStatus[vI].SinkStationTarget;
      (* Record arrival at sink timestamp *)
      vTsAtSink[vI] := TimeS;
      vDeviceDelay := INT_TO_REAL(DispatchedTask[vI].SinkDeviceDelay_x10) / 10.0;
      SimTrans[vI].ZTimer := vDeviceDelay + INT_TO_REAL(DispatchedTask[vI].DripTrayDelay_x10) / 10.0;
      SimTrans[vI].ZStage := 6;
      TransporterStatus[vI].Phase := 4;
      STC_FC_TrackMoveTimes(iTrans := vI, iPrev := 3, iNew := 4);
    END_IF;
    (* If vArrivedX but not vAtStation → at drive limit, wait for clearance *)

  (* ── Phase 4: Sink Z at sink station ───────────────────── *)
  ELSIF TransporterStatus[vI].Phase = 4 THEN
    vStationKind := DispatchedTask[vI].SinkKind;
    vTmpZ  := TransporterStatus[vI].ZPosition;
    vTmpZs := SimTrans[vI].ZStage;
    vTmpZt := SimTrans[vI].ZTimer;
    IF vI = 1 THEN
      vFB_Z1(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[vI].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[vI].ZPosSlowUp,
        ZPosSlowDown    := Transporters[vI].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[vI].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[vI].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[vI].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[vI].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      vArrivedZ := vFB_Z1.done;
    ELSIF vI = 2 THEN
      vFB_Z2(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[vI].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[vI].ZPosSlowUp,
        ZPosSlowDown    := Transporters[vI].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[vI].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[vI].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[vI].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[vI].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      vArrivedZ := vFB_Z2.done;
    ELSIF vI = 3 THEN
      vFB_Z3(
        delta_t       := iDeltaT,
        vStationKind  := vStationKind,
        ZPosDown        := Transporters[vI].ZPosDown,
        ZPosUp          := 0,
        ZPosSlowUp      := Transporters[vI].ZPosSlowUp,
        ZPosSlowDown    := Transporters[vI].ZPosSlowDown,
        ZPosSlowEnd     := Transporters[vI].ZPosSlowEnd,
        SpeedLiftSlow_Z := Transporters[vI].SpeedLiftSlow_Z,
        SpeedLiftFast_Z := Transporters[vI].SpeedLiftFast_Z,
        DripTrayDelay   := Transporters[vI].DripTrayDelay,
        DroppingTime    := 0,
        z_mm          := vTmpZ,
        z_stage       := vTmpZs,
        z_timer_s     := vTmpZt
      );
      vArrivedZ := vFB_Z3.done;
    END_IF;
    TransporterStatus[vI].ZPosition      := vTmpZ;
    SimTrans[vI].ZStage   := vTmpZs;
    SimTrans[vI].ZTimer := vTmpZt;
    IF vArrivedZ THEN
      (* ── Emit TASK_COMPLETE event (msg_type=3) before Phase reset ── *)
      IF NOT EventPendingValid THEN
        (* Config-based sub-phase durations *)
        vDroppingS := TransporterStatus[vI].DrippingTime / 10;
        IF Transporters[vI].DripTrayInUse THEN
          vTripS := Transporters[vI].DripTrayDelay / 10;
        ELSE
          vTripS := 0;
        END_IF;
        (* Nosto = total lift phase - dropping - trip_close
           vDeviceDelay no longer in lift phase (overlapped in Phase 1) *)
        vDurNosto := LINT_TO_INT(vTsLiftDone[vI] - vTsLiftBegin[vI])
                     - vDroppingS - vTripS;
        IF vDurNosto < 0 THEN vDurNosto := 0; END_IF;
        (* Lasku = total sink phase - vDeviceDelay - trip_open *)
        vDdLiftS := DispatchedTask[vI].SinkDeviceDelay_x10 / 10;
        vDurLasku := LINT_TO_INT(TimeS - vTsAtSink[vI]) - vDdLiftS - vTripS;
        IF vDurLasku < 0 THEN vDurLasku := 0; END_IF;

        EventPending.MsgType := 3;
        EventPending.TsHi := LINT_TO_UINT(TimeS / LINT#65536);
        EventPending.TsLo := LINT_TO_UINT(TimeS MOD LINT#65536);
        EventPending.Payload[1]  := LINT_TO_INT(TransporterStatus[vI].TaskId / LINT#65536);   (* TaskId_Hi *)
        EventPending.Payload[2]  := LINT_TO_INT(TransporterStatus[vI].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        EventPending.Payload[3]  := vI;                                                     (* transporter *)
        EventPending.Payload[4]  := LINT_TO_INT(vTsAtLift[vI] - vTsTaskStart[vI]);         (* siirto nostoasemalle *)
        EventPending.Payload[5]  := LINT_TO_INT(vTsLiftBegin[vI] - vTsAtLift[vI]);         (* odotus ennen nostoa (max(treat,dev_delay)) *)
        EventPending.Payload[6]  := vDurNosto;                                             (* nosto *)
        EventPending.Payload[7]  := vDroppingS;                                            (* valutus *)
        EventPending.Payload[8]  := vTripS;                                                (* trip close *)
        EventPending.Payload[9]  := LINT_TO_INT(vTsAtSink[vI] - vTsLiftDone[vI]);          (* siirto laskuasemalle *)
        EventPending.Payload[10] := vTripS;                                                (* trip open *)
        EventPending.Payload[11] := vDurLasku;                                             (* lasku *)
        EventPending.Payload[12] := LINT_TO_INT(TimeS - vTsTaskStart[vI]);              (* total *)
        EventPendingValid := TRUE;
      END_IF;

      (* Unit moves from transporter → sink station *)
      vSinkUnitId := StationOccupancy[vI].UnitId;
      IF vSinkUnitId >= 1 THEN
        STC_FC_UpdateUnitLocation(iUnit := vSinkUnitId, iLocation := TransporterStatus[vI].SinkStationTarget, iNttPrimary := DispatchedTask[vI].NttPrimary);
      END_IF;

      TransporterStatus[vI].Phase := 0;
      TransporterStatus[vI].CurrentTaskFinishTime := 0;
      DispatchedTask[vI].Active := FALSE;
      STC_FC_TrackMoveTimes(iTrans := vI, iPrev := 4, iNew := 0);
      TransporterStatus[vI].Status := 3;  (* auto_idle *)
      TransporterStatus[vI].IdleStartTime := TimeS;  (* move-away idle timer *)

    END_IF;
  END_IF;  (* ELSIF chain: phases 0→1→2→3→4 *)

  (* ── Phase 0 idle: drive back inside limits if outside ────── *)
  IF TransporterStatus[vI].Phase = 0 THEN
    vTmpX  := TransporterStatus[vI].XPosition;
    vTmpVx := SimTrans[vI].XVelocity;
    (* Use current position as target — XMotion will clamp to nearest limit if outside *)
    IF vI = 1 THEN
      vFB_X1(
        delta_t  := iDeltaT,
        x_target := vTmpX,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
    ELSIF vI = 2 THEN
      vFB_X2(
        delta_t  := iDeltaT,
        x_target := vTmpX,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
    ELSIF vI = 3 THEN
      vFB_X3(
        delta_t  := iDeltaT,
        x_target := vTmpX,
        x_min    := TransporterStatus[vI].XMinDriveLimit,
        x_max    := TransporterStatus[vI].XMaxDriveLimit,
        v_max    := Transporters[vI].SpeedMax_X,
        t_acc    := Transporters[vI].Acceleration_X,
        t_dec    := Transporters[vI].Deceleration_X,
        x_pos    := vTmpX,
        v_x      := vTmpVx
      );
    END_IF;
    TransporterStatus[vI].XPosition  := vTmpX;
    SimTrans[vI].XVelocity := vTmpVx;
  END_IF;

  (* ── Nearest station tracking ──────────────────────────── *)
  vMinDist := 999999999;
  vNearestNum := TransporterStatus[vI].CurrentStation;
  FOR vIdx := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
    IF Stations[vIdx].TankId <> 0 THEN
      vDx := Stations[vIdx].XPosition - TransporterStatus[vI].XPosition;
      IF ABS(vDx) < vMinDist THEN
        vMinDist := ABS(vDx);
        vNearestNum := vIdx;
      END_IF;
    END_IF;
  END_FOR;
  TransporterStatus[vI].CurrentStation := vNearestNum;

  END_IF;  (* active *)
END_FOR;

END_FUNCTION_BLOCK

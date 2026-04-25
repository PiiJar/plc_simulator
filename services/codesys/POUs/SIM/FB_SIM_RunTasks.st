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
  iRun    : BOOL;   (* enable — typically vInitDone *)
  iDeltaT : REAL;   (* actual cycle time in seconds *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS      : INT;
    MAX_UNITS             : INT;
    MAX_STEPS_PER_PROGRAM : INT;
    MIN_STATION_INDEX     : INT;
    MAX_STATION_INDEX     : INT;
    IN_PROCESS            : INT;
END_VAR

VAR_EXTERNAL
  gTransporter       : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  gSimTrans          : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;
  Stations           : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  gStationOccupancy  : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters       : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  gMove              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  gActualMove        : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ActualMoveTimeType;
  gUnit              : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  gBatch             : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms  : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gTimeS             : LINT;
  gEventPending      : UDT_JC_EventMsgType;
  gEventPendingValid : BOOL;
  gDispatchedTask    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;
END_VAR
VAR
  i             : INT;
  vIdx          : INT;
  (* Physics FB instances — one per transporter (MATIEC needs separate instances) *)
  vFB_X1        : FB_SIM_XMotion;
  vFB_X2        : FB_SIM_XMotion;
  vFB_X3        : FB_SIM_XMotion;
  vFB_Z1        : FB_SIM_ZMotion;
  vFB_Z2        : FB_SIM_ZMotion;
  vFB_Z3        : FB_SIM_ZMotion;
  (* Temp vars for VAR_IN_OUT passing *)
  vTmpX         : DINT;
  vTmpVx        : DINT;
  vTmpZ         : DINT;
  vTmpZs        : INT;
  vTmpZt        : REAL;
  vArrivedX     : BOOL;
  vAtStation    : BOOL;    (* TRUE only when actually at station, not just at drive limit *)
  vArrivedZ     : BOOL;
  vStationKind  : INT;
  vDeviceDelay  : REAL;
  vDropTime     : REAL;
  vPickUnitId   : INT;     (* unit_id picked up from lift station *)
  vXferTotal    : REAL;    (* transfer time for UI progress bar *)
  vSinkUnitId   : INT;     (* unit_id being placed at sink station *)
  (* Nearest-station calculation *)
  vNearestNum   : INT;
  vMinDist      : DINT;
  vDx           : DINT;
  (* Actual move time tracker — now FC FC_STC_TrackMoveTimes, no instance vNeeded *)
  (* Unit vLocation update — now FC FC_STC_UpdateUnitLocation, no instance vNeeded *)
  (* Event helpers *)
  vEvtUnit      : INT;
  vEvtDiff      : LINT;
  (* Treatment time wait *)
  vCanLift      : BOOL;
  vLiftUid      : INT;      (* unit at lift station *)
  vTreatCal     : DINT;      (* treatment cal_time for current stage *)
  vTreatElapsed : LINT;     (* seconds spent at lift station *)
  (* ── TASK_COMPLETE event: vPhase timestamps per transporter ── *)
  vTsTaskStart  : ARRAY[1..3] OF LINT;  (* Phase 0→1: task accepted *)
  vTsAtLift     : ARRAY[1..3] OF LINT;  (* Phase 1 vAtStation: arrived at lift *)
  vTsLiftBegin  : ARRAY[1..3] OF LINT;  (* Phase 1→2: vCanLift, begin lift *)
  vTsLiftDone   : ARRAY[1..3] OF LINT;  (* Phase 2→3: lift complete *)
  vTsAtSink     : ARRAY[1..3] OF LINT;  (* Phase 3→4: arrived at sink *)
  (* TASK_COMPLETE temp vars *)
  vDdLiftS      : INT;   (* lift vDeviceDelay in seconds *)
  vDroppingS    : INT;   (* dropping/valutus time in seconds *)
  vTripS        : INT;   (* drip tray vDelay in seconds, 0 if not used *)
  vDurNosto     : INT;   (* computed nosto vDuration *)
  vDurLasku     : INT;   (* computed lasku vDuration *)
END_VAR

IF NOT iRun THEN
  RETURN;
END_IF;

FOR i := 1 TO MAX_TRANSPORTERS DO
  IF gTransporter[i].IsActive THEN

  (* ── Phase 0 → 1: Accept new task ───────────────────────── *)
  IF (gTransporter[i].Phase = 0)
     AND gDispatchedTask[i].Active THEN
    gTransporter[i].XFinalTarget := gDispatchedTask[i].LiftX;
    gTransporter[i].Status := 4;  (* auto_run — must be set before TrackMoveTimes *)
    gTransporter[i].Phase := 1;
    FC_STC_TrackMoveTimes(iTrans := i, iPrev := 0, iNew := 1);
    gSimTrans[i].ZStage := 0;
    gSimTrans[i].ZTimer := 0.0;
    (* Record task start timestamp *)
    vTsTaskStart[i] := gTimeS;
    vTsAtLift[i]    := LINT#0;

  (* ── Phase 1: Drive X towards lift station ──────────────── *)
  ELSIF gTransporter[i].Phase = 1 THEN
    vTmpX  := gTransporter[i].XPosition;
    vTmpVx := gSimTrans[i].XVelocity;
    IF i = 1 THEN
      vFB_X1(
        iDeltaT  := iDeltaT,
        iXTarget := gTransporter[i].XFinalTarget,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
      vArrivedX := vFB_X1.arrived;
      gTransporter[i].XDriveTarget := vFB_X1.x_drive;
    ELSIF i = 2 THEN
      vFB_X2(
        iDeltaT  := iDeltaT,
        iXTarget := gTransporter[i].XFinalTarget,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
      vArrivedX := vFB_X2.arrived;
      gTransporter[i].XDriveTarget := vFB_X2.x_drive;
    ELSIF i = 3 THEN
      vFB_X3(
        iDeltaT  := iDeltaT,
        iXTarget := gTransporter[i].XFinalTarget,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
      vArrivedX := vFB_X3.arrived;
      gTransporter[i].XDriveTarget := vFB_X3.x_drive;
    END_IF;
    gTransporter[i].XPosition  := vTmpX;
    gSimTrans[i].XVelocity := vTmpVx;

    (* Only transition when actually at station, not just at drive limit *)
    vAtStation := vArrivedX
                  AND (ABS(gTransporter[i].XPosition - gTransporter[i].XFinalTarget) <= 6);
    IF vAtStation THEN
      gTransporter[i].CurrentStation := gTransporter[i].LiftStationTarget;

      (* ── Move-away arrival: Status=3 means idle repositioning, not a real task ── *)
      IF gTransporter[i].Status = 3 THEN
        gTransporter[i].Phase := 0;
        gTransporter[i].IdleStartTime := gTimeS;
        FC_STC_TrackMoveTimes(iTrans := i, iPrev := 1, iNew := 0);
      ELSE
      (* Record arrival at lift station (first time only) *)
      IF vTsAtLift[i] = LINT#0 THEN
        vTsAtLift[i] := gTimeS;
      END_IF;

      (* ── Wait for treatment time AND vDeviceDelay before lifting ──
         Z-movement starts when the LONGER of two has elapsed:
         1. Remaining treatment time (unit must finish treatment)
         2. Station vDeviceDelay (vCovers must be open)
         Both timers run simultaneously from transporter arrival.
         This matches JS behavior: max(treatment, vDeviceDelay). *)
      vCanLift := TRUE;
      vDeviceDelay := INT_TO_REAL(gDispatchedTask[i].LiftDeviceDelay_x10) / 10.0;
      vDropTime := INT_TO_REAL(gDispatchedTask[i].DroppingTime_x10) / 10.0;

      (* Check treatment time *)
      vLiftUid := gStationOccupancy[gTransporter[i].LiftStationTarget].UnitId;
      IF vLiftUid >= 1 AND vLiftUid <= MAX_UNITS THEN
        IF gBatch[vLiftUid].State = IN_PROCESS
           AND gBatch[vLiftUid].CurStage >= 1
           AND gBatch[vLiftUid].CurStage <= MAX_STEPS_PER_PROGRAM THEN
          vTreatCal := TreatmentPrograms[vLiftUid].Steps[gBatch[vLiftUid].CurStage].CalTime;
          IF vTreatCal > 0 THEN
            vTreatElapsed := gTimeS - gStationOccupancy[gTransporter[i].LiftStationTarget].ChangeTime;
            IF vTreatElapsed < DINT_TO_LINT(vTreatCal) THEN
              vCanLift := FALSE;
            END_IF;
          END_IF;
        END_IF;
      END_IF;

      (* Check vDeviceDelay — vCovers must have had time to open since arrival *)
      IF vCanLift AND vDeviceDelay > 0.0 THEN
        IF LINT_TO_REAL(gTimeS - vTsAtLift[i]) < vDeviceDelay THEN
          vCanLift := FALSE;
        END_IF;
      END_IF;

      IF vCanLift THEN
      (* Record lift begin timestamp *)
      vTsLiftBegin[i] := gTimeS;
      (* vDropTime vAlready captured by STC_FindStation above *)
      (* Skip stage 1 — vDeviceDelay vAlready overlapped above.
         Z-movement starts immediately (stage 2).
         dropping_time and drip_tray_delay happen at the TOP. *)
      gTransporter[i].ZPosition := 0;
      gSimTrans[i].ZTimer := 0.0;
      gSimTrans[i].ZStage := 2;
      gTransporter[i].Phase := 2;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 1, iNew := 2);

      (* ── Calculate transfer time (used by event + batch times) ── *)
      vXferTotal := DINT_TO_REAL(gDispatchedTask[i].TransferTime_x10) / 10.0;
      IF vXferTotal < 5.0 THEN vXferTotal := 60.0; END_IF;

      (* ── Emit LIFT event (msg_type=2) ── *)
      vEvtUnit := gStationOccupancy[gTransporter[i].LiftStationTarget].UnitId;
      IF NOT gEventPendingValid AND vEvtUnit >= 1 THEN
        gEventPending.MsgType := 2;
        gEventPending.TsHi := LINT_TO_UINT(gTimeS / LINT#65536);
        gEventPending.TsLo := LINT_TO_UINT(gTimeS MOD LINT#65536);
        gEventPending.Payload[1]  := LINT_TO_INT(gTransporter[i].TaskId / LINT#65536);   (* TaskId_Hi *)
        gEventPending.Payload[2]  := LINT_TO_INT(gTransporter[i].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        gEventPending.Payload[3]  := i;
        gEventPending.Payload[4]  := vEvtUnit;
        gEventPending.Payload[5]  := gTransporter[i].LiftStationTarget;
        gEventPending.Payload[6]  := gBatch[vEvtUnit].BatchCode;
        gEventPending.Payload[7]  := gBatch[vEvtUnit].CurStage;
        vEvtDiff := gTimeS - gStationOccupancy[gTransporter[i].LiftStationTarget].ChangeTime;
        IF vEvtDiff > LINT#32000 THEN
          gEventPending.Payload[8] := 32000;
        ELSE
          gEventPending.Payload[8] := LINT_TO_INT(vEvtDiff);
        END_IF;
        (* ── Original program calc/min/max for this stage ── *)
        (* gSimTrans holds dispatch-time scheduler values which may differ
           from the treatment program originals. Read directly from TreatmentPrograms
           using the batch's current stage (CurStage=1-based program index). *)
        IF gBatch[vEvtUnit].CurStage >= 1 AND gBatch[vEvtUnit].CurStage <= 30 THEN
          gEventPending.Payload[9]  := DINT_TO_INT(TreatmentPrograms[vEvtUnit].Steps[gBatch[vEvtUnit].CurStage].CalTime);
          gEventPending.Payload[10] := DINT_TO_INT(TreatmentPrograms[vEvtUnit].Steps[gBatch[vEvtUnit].CurStage].MinTime);
          gEventPending.Payload[11] := DINT_TO_INT(TreatmentPrograms[vEvtUnit].Steps[gBatch[vEvtUnit].CurStage].MaxTime);
        ELSE
          (* Stage 0 (pickup) — no program step *)
          gEventPending.Payload[9]  := 0;
          gEventPending.Payload[10] := 0;
          gEventPending.Payload[11] := 0;
        END_IF;
        gEventPending.Payload[12] := REAL_TO_INT(vXferTotal);
        gEventPendingValid := TRUE;
      END_IF;

      (* Unit moves from lift station → transporter *)
      vPickUnitId := gStationOccupancy[gTransporter[i].LiftStationTarget].UnitId;
      IF vPickUnitId >= 1 THEN
        FC_STC_UpdateUnitLocation(iUnit := vPickUnitId, iLocation := i, iNttPrimary := 0);

        (* Set batch transfer times for UI progress bar — matches JS behavior *)
        gBatch[vPickUnitId].StartTime := gTimeS;
        gBatch[vPickUnitId].CalTime   := REAL_TO_DINT(vXferTotal);
        gBatch[vPickUnitId].MinTime   := gBatch[vPickUnitId].CalTime;
        gBatch[vPickUnitId].MaxTime   := 600;
      END_IF;
      END_IF;  (* vCanLift *)
      END_IF;  (* Status=3 ELSE branch *)
    END_IF;
    (* If vArrivedX but not vAtStation → at drive limit, wait for clearance *)

  (* ── Phase 2: Lift Z at lift station ────────────────────── *)
  ELSIF gTransporter[i].Phase = 2 THEN
    iVStationKind := gDispatchedTask[i].LiftKind;
    vTmpZ  := gTransporter[i].ZPosition;
    vTmpZs := gSimTrans[i].ZStage;
    vTmpZt := gSimTrans[i].ZTimer;
    IF i = 1 THEN
      vFB_Z1(
        iDeltaT       := iDeltaT,
        iVStationKind  := vStationKind,
        iZPosDown        := Transporters[i].ZPosDown,
        iZPosUp          := 0,
        iZPosSlowUp      := Transporters[i].ZPosSlowUp,
        iZPosSlowDown    := Transporters[i].ZPosSlowDown,
        iZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        iSpeedLiftSlowZ := Transporters[i].SpeedLiftSlow_Z,
        iSpeedLiftFastZ := Transporters[i].SpeedLiftFast_Z,
        iDripTrayDelay   := Transporters[i].DripTrayDelay,
        iDroppingTime    := gDispatchedTask[i].DroppingTime_x10,
        ioZMm          := vTmpZ,
        ioZStage       := vTmpZs,
        ioZTimerS     := vTmpZt
      );
      vArrivedZ := vFB_Z1.oDone;
    ELSIF i = 2 THEN
      vFB_Z2(
        iDeltaT       := iDeltaT,
        iVStationKind  := vStationKind,
        iZPosDown        := Transporters[i].ZPosDown,
        iZPosUp          := 0,
        iZPosSlowUp      := Transporters[i].ZPosSlowUp,
        iZPosSlowDown    := Transporters[i].ZPosSlowDown,
        iZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        iSpeedLiftSlowZ := Transporters[i].SpeedLiftSlow_Z,
        iSpeedLiftFastZ := Transporters[i].SpeedLiftFast_Z,
        iDripTrayDelay   := Transporters[i].DripTrayDelay,
        iDroppingTime    := gDispatchedTask[i].DroppingTime_x10,
        ioZMm          := vTmpZ,
        ioZStage       := vTmpZs,
        ioZTimerS     := vTmpZt
      );
      vArrivedZ := vFB_Z2.oDone;
    ELSIF i = 3 THEN
      vFB_Z3(
        iDeltaT       := iDeltaT,
        iVStationKind  := vStationKind,
        iZPosDown        := Transporters[i].ZPosDown,
        iZPosUp          := 0,
        iZPosSlowUp      := Transporters[i].ZPosSlowUp,
        iZPosSlowDown    := Transporters[i].ZPosSlowDown,
        iZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        iSpeedLiftSlowZ := Transporters[i].SpeedLiftSlow_Z,
        iSpeedLiftFastZ := Transporters[i].SpeedLiftFast_Z,
        iDripTrayDelay   := Transporters[i].DripTrayDelay,
        iDroppingTime    := gDispatchedTask[i].DroppingTime_x10,
        ioZMm          := vTmpZ,
        ioZStage       := vTmpZs,
        ioZTimerS     := vTmpZt
      );
      vArrivedZ := vFB_Z3.oDone;
    END_IF;
    gTransporter[i].ZPosition      := vTmpZ;
    gSimTrans[i].ZStage   := vTmpZs;
    gSimTrans[i].ZTimer := vTmpZt;
    IF vArrivedZ THEN
      (* Record lift oDone timestamp *)
      vTsLiftDone[i] := gTimeS;
      gTransporter[i].XFinalTarget := gDispatchedTask[i].SinkX;
      gTransporter[i].Phase := 3;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 2, iNew := 3);
    END_IF;

  (* ── Phase 3: Drive X towards sink station ─────────────── *)
  ELSIF gTransporter[i].Phase = 3 THEN
    vTmpX  := gTransporter[i].XPosition;
    vTmpVx := gSimTrans[i].XVelocity;
    IF i = 1 THEN
      vFB_X1(
        iDeltaT  := iDeltaT,
        iXTarget := gTransporter[i].XFinalTarget,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
      vArrivedX := vFB_X1.arrived;
      gTransporter[i].XDriveTarget := vFB_X1.x_drive;
    ELSIF i = 2 THEN
      vFB_X2(
        iDeltaT  := iDeltaT,
        iXTarget := gTransporter[i].XFinalTarget,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
      vArrivedX := vFB_X2.arrived;
      gTransporter[i].XDriveTarget := vFB_X2.x_drive;
    ELSIF i = 3 THEN
      vFB_X3(
        iDeltaT  := iDeltaT,
        iXTarget := gTransporter[i].XFinalTarget,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
      vArrivedX := vFB_X3.arrived;
      gTransporter[i].XDriveTarget := vFB_X3.x_drive;
    END_IF;
    gTransporter[i].XPosition  := vTmpX;
    gSimTrans[i].XVelocity := vTmpVx;

    (* Only transition when actually at station, not just at drive limit *)
    vAtStation := vArrivedX
                  AND (ABS(gTransporter[i].XPosition - gTransporter[i].XFinalTarget) <= 6);
    IF vAtStation THEN
      gTransporter[i].CurrentStation := gTransporter[i].SinkStationTarget;
      (* Record arrival at sink timestamp *)
      vTsAtSink[i] := gTimeS;
      vDeviceDelay := INT_TO_REAL(gDispatchedTask[i].SinkDeviceDelay_x10) / 10.0;
      gSimTrans[i].ZTimer := vDeviceDelay + INT_TO_REAL(gDispatchedTask[i].DripTrayDelay_x10) / 10.0;
      gSimTrans[i].ZStage := 6;
      gTransporter[i].Phase := 4;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 3, iNew := 4);
    END_IF;
    (* If vArrivedX but not vAtStation → at drive limit, wait for clearance *)

  (* ── Phase 4: Sink Z at sink station ───────────────────── *)
  ELSIF gTransporter[i].Phase = 4 THEN
    iVStationKind := gDispatchedTask[i].SinkKind;
    vTmpZ  := gTransporter[i].ZPosition;
    vTmpZs := gSimTrans[i].ZStage;
    vTmpZt := gSimTrans[i].ZTimer;
    IF i = 1 THEN
      vFB_Z1(
        iDeltaT       := iDeltaT,
        iVStationKind  := vStationKind,
        iZPosDown        := Transporters[i].ZPosDown,
        iZPosUp          := 0,
        iZPosSlowUp      := Transporters[i].ZPosSlowUp,
        iZPosSlowDown    := Transporters[i].ZPosSlowDown,
        iZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        iSpeedLiftSlowZ := Transporters[i].SpeedLiftSlow_Z,
        iSpeedLiftFastZ := Transporters[i].SpeedLiftFast_Z,
        iDripTrayDelay   := Transporters[i].DripTrayDelay,
        iDroppingTime    := 0,
        ioZMm          := vTmpZ,
        ioZStage       := vTmpZs,
        ioZTimerS     := vTmpZt
      );
      vArrivedZ := vFB_Z1.oDone;
    ELSIF i = 2 THEN
      vFB_Z2(
        iDeltaT       := iDeltaT,
        iVStationKind  := vStationKind,
        iZPosDown        := Transporters[i].ZPosDown,
        iZPosUp          := 0,
        iZPosSlowUp      := Transporters[i].ZPosSlowUp,
        iZPosSlowDown    := Transporters[i].ZPosSlowDown,
        iZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        iSpeedLiftSlowZ := Transporters[i].SpeedLiftSlow_Z,
        iSpeedLiftFastZ := Transporters[i].SpeedLiftFast_Z,
        iDripTrayDelay   := Transporters[i].DripTrayDelay,
        iDroppingTime    := 0,
        ioZMm          := vTmpZ,
        ioZStage       := vTmpZs,
        ioZTimerS     := vTmpZt
      );
      vArrivedZ := vFB_Z2.oDone;
    ELSIF i = 3 THEN
      vFB_Z3(
        iDeltaT       := iDeltaT,
        iVStationKind  := vStationKind,
        iZPosDown        := Transporters[i].ZPosDown,
        iZPosUp          := 0,
        iZPosSlowUp      := Transporters[i].ZPosSlowUp,
        iZPosSlowDown    := Transporters[i].ZPosSlowDown,
        iZPosSlowEnd     := Transporters[i].ZPosSlowEnd,
        iSpeedLiftSlowZ := Transporters[i].SpeedLiftSlow_Z,
        iSpeedLiftFastZ := Transporters[i].SpeedLiftFast_Z,
        iDripTrayDelay   := Transporters[i].DripTrayDelay,
        iDroppingTime    := 0,
        ioZMm          := vTmpZ,
        ioZStage       := vTmpZs,
        ioZTimerS     := vTmpZt
      );
      vArrivedZ := vFB_Z3.oDone;
    END_IF;
    gTransporter[i].ZPosition      := vTmpZ;
    gSimTrans[i].ZStage   := vTmpZs;
    gSimTrans[i].ZTimer := vTmpZt;
    IF vArrivedZ THEN
      (* ── Emit TASK_COMPLETE event (msg_type=3) before Phase reset ── *)
      IF NOT gEventPendingValid THEN
        (* Config-based sub-vPhase durations *)
        vDroppingS := gTransporter[i].DrippingTime / 10;
        IF Transporters[i].DripTrayInUse THEN
          vTripS := Transporters[i].DripTrayDelay / 10;
        ELSE
          vTripS := 0;
        END_IF;
        (* Nosto = total lift vPhase - dropping - trip_close
           vDeviceDelay no longer in lift vPhase (overlapped in Phase 1) *)
        vDurNosto := LINT_TO_INT(vTsLiftDone[i] - vTsLiftBegin[i])
                     - vDroppingS - vTripS;
        IF vDurNosto < 0 THEN vDurNosto := 0; END_IF;
        (* Lasku = total sink vPhase - vDeviceDelay - trip_open *)
        vDdLiftS := gDispatchedTask[i].SinkDeviceDelay_x10 / 10;
        vDurLasku := LINT_TO_INT(gTimeS - vTsAtSink[i]) - vDdLiftS - vTripS;
        IF vDurLasku < 0 THEN vDurLasku := 0; END_IF;

        gEventPending.MsgType := 3;
        gEventPending.TsHi := LINT_TO_UINT(gTimeS / LINT#65536);
        gEventPending.TsLo := LINT_TO_UINT(gTimeS MOD LINT#65536);
        gEventPending.Payload[1]  := LINT_TO_INT(gTransporter[i].TaskId / LINT#65536);   (* TaskId_Hi *)
        gEventPending.Payload[2]  := LINT_TO_INT(gTransporter[i].TaskId MOD LINT#65536);  (* TaskId_Lo *)
        gEventPending.Payload[3]  := i;                                                     (* transporter *)
        gEventPending.Payload[4]  := LINT_TO_INT(vTsAtLift[i] - vTsTaskStart[i]);         (* siirto nostoasemalle *)
        gEventPending.Payload[5]  := LINT_TO_INT(vTsLiftBegin[i] - vTsAtLift[i]);         (* odotus ennen nostoa (max(treat,dev_delay)) *)
        gEventPending.Payload[6]  := vDurNosto;                                             (* nosto *)
        gEventPending.Payload[7]  := vDroppingS;                                            (* valutus *)
        gEventPending.Payload[8]  := vTripS;                                                (* trip close *)
        gEventPending.Payload[9]  := LINT_TO_INT(vTsAtSink[i] - vTsLiftDone[i]);          (* siirto laskuasemalle *)
        gEventPending.Payload[10] := vTripS;                                                (* trip open *)
        gEventPending.Payload[11] := vDurLasku;                                             (* lasku *)
        gEventPending.Payload[12] := LINT_TO_INT(gTimeS - vTsTaskStart[i]);              (* total *)
        gEventPendingValid := TRUE;
      END_IF;

      (* Unit moves from transporter → sink station *)
      vSinkUnitId := gStationOccupancy[i].UnitId;
      IF vSinkUnitId >= 1 THEN
        FC_STC_UpdateUnitLocation(iUnit := vSinkUnitId, iLocation := gTransporter[i].SinkStationTarget, iNttPrimary := gDispatchedTask[i].NttPrimary);
      END_IF;

      gTransporter[i].Phase := 0;
      gTransporter[i].CurrentTaskFinishTime := 0;
      gDispatchedTask[i].Active := FALSE;
      FC_STC_TrackMoveTimes(iTrans := i, iPrev := 4, iNew := 0);
      gTransporter[i].Status := 3;  (* auto_idle *)
      gTransporter[i].IdleStartTime := gTimeS;  (* move-away idle timer *)

    END_IF;
  END_IF;  (* ELSIF chain: phases 0→1→2→3→4 *)

  (* ── Phase 0 idle: drive back inside limits if outside ────── *)
  IF gTransporter[i].Phase = 0 THEN
    vTmpX  := gTransporter[i].XPosition;
    vTmpVx := gSimTrans[i].XVelocity;
    (* Use current position as target — XMotion will clamp to nearest limit if outside *)
    IF i = 1 THEN
      vFB_X1(
        iDeltaT  := iDeltaT,
        iXTarget := vTmpX,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
    ELSIF i = 2 THEN
      vFB_X2(
        iDeltaT  := iDeltaT,
        iXTarget := vTmpX,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
    ELSIF i = 3 THEN
      vFB_X3(
        iDeltaT  := iDeltaT,
        iXTarget := vTmpX,
        iXMin    := gTransporter[i].XMinDriveLimit,
        iXMax    := gTransporter[i].XMaxDriveLimit,
        iVMax    := Transporters[i].SpeedMax_X,
        iTAcc    := Transporters[i].Acceleration_X,
        iTDec    := Transporters[i].Deceleration_X,
        ioXPos    := vTmpX,
        ioVX      := vTmpVx
      );
    END_IF;
    gTransporter[i].XPosition  := vTmpX;
    gSimTrans[i].XVelocity := vTmpVx;
  END_IF;

  (* ── Nearest station tracking ──────────────────────────── *)
  vMinDist := 999999999;
  vNearestNum := gTransporter[i].CurrentStation;
  FOR vIdx := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
    IF Stations[vIdx].TankId <> 0 THEN
      vDx := Stations[vIdx].XPosition - gTransporter[i].XPosition;
      IF ABS(vDx) < vMinDist THEN
        vMinDist := ABS(vDx);
        vNearestNum := vIdx;
      END_IF;
    END_IF;
  END_FOR;
  gTransporter[i].CurrentStation := vNearestNum;

  END_IF;  (* active *)
END_FOR;

END_FUNCTION_BLOCK

(* ===========================================================================================
 *  FB_TSK_Scheduler — Main task scheduler state machine
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  One vPhase per PLC scan cycle.
 *
 *  Phase flow (structured by 100/1000 groups):
 *  0        STOPPED
 *  1        INIT             (collect active batches)
 *  2        NO_TREATMENT_STATES
 *  1000+i   CALC_SCHEDULE    (schedule for batch i, 0..vBatchCount-1)
 *  2000     CLEAR_TASKS      (clear task queues)
 *  2001+i   CREATE_TASKS     (tasks for batch i, 0..vBatchCount-1)
 *  2100     SORT_TASKS
 *  2101     SWAP_TASKS
 *  2102     ANALYZE          (→ 2103 if vConflict, → 2200 if clean)
 *  2103     RESOLVE          (→ 2100 loop, or → 2200 if max iter)
 *  2200     NO_TREATMENT     (create no-treatment tasks)
 *  2201     APPLY_STRETCHES  (persist resolve decisions)
 *  10000    READY            (cycle complete)
 *  10001    CHECK_DEP_PENDING
 *  10002    RESTART          (→ 1)
 *
 *  Phase advancement:
 *  Default = vPhase + 1 (at end of function body).
 *  vNextPhase is set ONLY when jumping to a different group.
 *
 *  Conflict resolution: one vConflict per cycle.
 *  If resolved → back to SORT (2100).
 *  If no vConflict → NO_TREATMENT → READY.
 *  Max iterations to prevent infinite loops.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *  25.03.2026 - Restructured: vPhase+1 default, vIdx from vPhase offset.
 *
 *
 *)


FUNCTION_BLOCK FB_TSK_Scheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iRun   : BOOL;    (* TRUE = run, FALSE = stop *)
  iTimeS : LINT;    (* current absolute time (s), unix seconds *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS : INT;
    MAX_UNITS        : INT;
    MAX_LOCKS        : INT;
END_VAR

VAR_EXTERNAL
  gBatch              : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  gUnit               : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms   : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gTask               : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  gSchedule           : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  Transporters        : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  (* DEP handshake *)
  gDepPending         : UDT_JC_DepPendingWriteType;
  gConflictResolved   : BOOL;
  gTskStable          : BOOL;
  (* Debug observability *)
  gDbgTskConflictType : INT;
  gDbgTskConflictIter : INT;
  gDbgTskConfUnit     : INT;
  gDbgTskConfStage    : INT;
  gDbgTskBlockedUnit  : INT;
  gDbgTskBlockedStage : INT;
  gDbgTskDeficit      : DINT;
  gDbgTskStretchCnt   : INT;
  gDbgTskTotalAdv     : DINT;
  gDbgTskTotalDelay   : DINT;
  gDbgProgCal         : ARRAY[1..MAX_UNITS] OF DINT;
END_VAR

VAR_OUTPUT
  oPhase      : INT;
  oBatchCnt   : INT;
  oTaskCnt    : INT;
  oCycleCnt   : INT;
  oConflict   : BOOL;
  oRoundTicks : INT;     (* ticks consumed by last completed vRound *)
END_VAR

VAR
  vPhase              : INT := 0;
  vNextPhase          : INT;
  vIdx                : INT;    (* derived from vPhase offset *)
  (* Batch list *)
  vBatchList          : ARRAY[1..MAX_UNITS] OF INT;
  vBatchCount         : INT;
  (* Conflict iteration *)
  vConflictIter       : INT;
  cMaxConflictIter    : INT := 40;
  (* Analyze result cache *)
  vAnConflict         : BOOL;
  vAnConfType         : INT;
  vAnConfUnit         : INT;
  vAnConfStage        : INT;
  vAnConfTrans        : INT;
  vAnBlockedUnit      : INT;
  vAnBlockedStage     : INT;
  vAnDeficit          : REAL;
  (* Resolve result cache *)
  vRsTotalAdv         : REAL;
  vRsTotalDelay       : REAL;
  (* Transporter assignment *)
  vSchedTrans         : INT;
  (* Locked stages — prevents oscillation in resolve loop *)
  vLocks              : ARRAY[1..MAX_LOCKS] OF UDT_JC_TskLockType;
  vLockCnt            : INT := 0;
  vLocksInitialized   : BOOL := FALSE;
  vFB_FindTransporter : FB_STC_FindTransporter;
  (* candidateStretches — JS: resolve decisions persisted to TreatmentPrograms *)
  vStretches          : ARRAY[1..20] OF UDT_JC_TskStretchType;
  vStretchCnt         : INT := 0;
  vSi                 : INT;
  vNewCal             : DINT;
  vFlexCap            : DINT;
  (* Temp *)
  vUi                 : INT;
  vUi2                : INT;
  vTi                 : INT;
  vBi                 : INT;
  vTotalTasks         : INT;
  vCycleCount         : INT := 0;
  vRoundTicks         : INT := 0;  (* ticks since last RESTART *)
END_VAR

IF NOT iRun THEN
  IF vPhase <> 0 THEN
    FOR vTi := 1 TO MAX_TRANSPORTERS DO
      gTask[vTi].Count := 0;
    END_FOR;
  END_IF;
  vPhase := 0;
  oPhase := 0;
  RETURN;
END_IF;

vNextPhase := 0;
vRoundTicks := vRoundTicks + 1;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 0: STOPPED                                             *)
(* ══════════════════════════════════════════════════════════════ *)
IF vPhase = 0 THEN
  vNextPhase := 1;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1: INIT — collect active batches                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 1 THEN
  (* Clear schedule for ALL units — start from clean slate *)
  FOR vUi := 1 TO MAX_UNITS DO
    gSchedule[vUi].StageCount := 0;
  END_FOR;
  vBatchCount := FC_STC_CollectActiveBatches(iMode := 0, oList => vBatchList);
  oBatchCnt := vBatchCount;
  vConflictIter := 0;
  vLocksInitialized := FALSE;
  vStretchCnt := 0;
  gDbgTskTotalAdv   := 0;
  gDbgTskTotalDelay := 0;

  IF vBatchCount = 0 THEN
    FOR vTi := 1 TO MAX_TRANSPORTERS DO
      gTask[vTi].Count := 0;
    END_FOR;
    gConflictResolved := TRUE;
    vNextPhase := 2200;   (* skip to NO_TREATMENT *)
  ELSE
    gConflictResolved := FALSE;
    (* vPhase + 1 → 2 *)
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2: NO_TREATMENT_STATES                                *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2 THEN
  FC_STC_NoTreatmentStates();
  vNextPhase := 1000;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1000+i: CALC_SCHEDULE — one batch per scan             *)
(*   i = 0..vBatchCount-1: calculate schedule                   *)
(*   i >= vBatchCount: oDone → 2000                              *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase >= 1000 AND vPhase <= 1999 THEN
  vIdx := vPhase - 1000;

  IF vIdx < vBatchCount THEN
    vUi := vBatchList[vIdx + 1];

    (* CalcSchedule handles elapsed-time normalisation — no pre-adjustment vNeeded here. *)

    IF gUnit[vUi].Location < MIN_STATION_INDEX THEN
      vSchedTrans := gUnit[vUi].Location;
    ELSE
      vFB_FindTransporter(iLiftStn := gUnit[vUi].Location, iSinkStn := 0);
      vSchedTrans := vFB_FindTransporter.oTrans;
      IF vSchedTrans = 0 THEN vSchedTrans := 1; END_IF;
    END_IF;

    FC_STC_CalcSchedule(iUnit := vUi, iTrans := vSchedTrans, iTimeS := iTimeS,
                     ioSchedule := gSchedule, ioBatch := gBatch, ioProgram := TreatmentPrograms);
    (* vPhase + 1 → next batch *)

  ELSE
    vNextPhase := 2000;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2000: CLEAR_TASKS — clear all task queues              *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2000 THEN
  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    gTask[vTi].Count := 0;
  END_FOR;
  (* vPhase + 1 → 2001 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2001+i: CREATE_TASKS — one batch per scan              *)
(*   i = 0..vBatchCount-1: create tasks                         *)
(*   i >= vBatchCount: oDone → 2100                              *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase >= 2001 AND vPhase <= 2099 THEN
  vIdx := vPhase - 2001;

  IF vIdx < vBatchCount THEN
    vUi := vBatchList[vIdx + 1];
    FC_STC_CreateTasks(iUnit := vUi, ioSchedule := gSchedule, ioTask := gTask);
    (* vPhase + 1 → next batch *)
  ELSE
    vNextPhase := 2100;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2100: SORT_TASKS                                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2100 THEN
  FC_STC_SortTasks(iTrans := 0, iTimeS := iTimeS, ioTask := gTask, ioBatch := gBatch);
  IF NOT vLocksInitialized THEN
    vLockCnt := 0;
    FOR vBi := 1 TO MAX_LOCKS DO
      vLocks[vBi].Unit := 0;
      vLocks[vBi].Stage := 0;
      vLocks[vBi].Direction := 0;
    END_FOR;
    vLocksInitialized := TRUE;
  END_IF;
  (* vPhase + 1 → 2101 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2101: SWAP_TASKS                                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2101 THEN
  FC_STC_SwapTasks(ioTask := gTask);
  (* vPhase + 1 → 2102 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2102: ANALYZE                                          *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2102 THEN
  FC_TSK_Analyze(ioTask := gTask,
    oHasConflict => vAnConflict, oConfType => vAnConfType,
    oConfUnit => vAnConfUnit, oConfStage => vAnConfStage,
    oConfTrans => vAnConfTrans, oBlockedUnit => vAnBlockedUnit,
    oBlockedStage => vAnBlockedStage, oDeficit => vAnDeficit);
  oConflict := vAnConflict;

  IF vAnConflict THEN
    gDbgTskConflictType  := vAnConfType;
    gDbgTskConfUnit      := vAnConfUnit;
    gDbgTskConfStage     := vAnConfStage;
    gDbgTskBlockedUnit   := vAnBlockedUnit;
    gDbgTskBlockedStage  := vAnBlockedStage;
    gDbgTskDeficit        := REAL_TO_DINT(vAnDeficit);
    gConflictResolved := FALSE;
    (* vPhase + 1 → 2103 RESOLVE *)
  ELSE
    gConflictResolved := TRUE;
    vNextPhase := 2200;   (* skip RESOLVE → NO_TREATMENT *)
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2103: RESOLVE — one vConflict, then re-analyze          *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2103 THEN
  FC_TSK_Resolve(
    iConfUnit     := vAnConfUnit,
    iConfStage    := vAnConfStage,
    iConfTrans    := vAnConfTrans,
    iBlockedUnit  := vAnBlockedUnit,
    iBlockedStage := vAnBlockedStage,
    iDeficit       := vAnDeficit,
    ioLocks        := vLocks,
    ioLockCnt     := vLockCnt,
    ioSchedule     := gSchedule,
    ioTask         := gTask,
    ioBatch        := gBatch,
    oTotalAdv     => vRsTotalAdv,
    oTotalDelay   => vRsTotalDelay
  );

  (* Collect vStretches *)
  IF vRsTotalAdv > 0.1 AND vStretchCnt < 20 THEN
    vStretchCnt := vStretchCnt + 1;
    vStretches[vStretchCnt].Unit   := vAnBlockedUnit;
    vStretches[vStretchCnt].Stage  := vAnBlockedStage;
    vStretches[vStretchCnt].DelayS := -REAL_TO_DINT(vRsTotalAdv);
    gDbgTskTotalAdv := gDbgTskTotalAdv + REAL_TO_DINT(vRsTotalAdv);
  END_IF;
  IF vRsTotalDelay > 0.1 AND vStretchCnt < 20 THEN
    vStretchCnt := vStretchCnt + 1;
    vStretches[vStretchCnt].Unit   := vAnConfUnit;
    vStretches[vStretchCnt].Stage  := vAnConfStage;
    vStretches[vStretchCnt].DelayS := REAL_TO_DINT(vRsTotalDelay);
    gDbgTskTotalDelay := gDbgTskTotalDelay + REAL_TO_DINT(vRsTotalDelay);
  END_IF;

  vConflictIter := vConflictIter + 1;

  IF vConflictIter >= cMaxConflictIter THEN
    gConflictResolved := TRUE;
    vNextPhase := 2200;   (* accept partial, move on *)
  ELSE
    vNextPhase := 2100;   (* re-SORT → SWAP → ANALYZE *)
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2200: NO_TREATMENT — create no-treatment tasks         *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2200 THEN
  FC_STC_ManualTask(iTimeS := iTimeS, ioTask := gTask);
  FC_TSK_NoTreatment(iTimeS := iTimeS, ioTask := gTask);
  oConflict := FALSE;
  (* vPhase + 1 → 2201 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2201: APPLY_STRETCHES — persist resolve decisions      *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2201 THEN
  FOR vSi := 1 TO vStretchCnt DO
    IF vStretches[vSi].Unit >= 1 AND vStretches[vSi].Unit <= MAX_UNITS THEN
     IF vStretches[vSi].Stage >= 1
        AND vStretches[vSi].Stage <= TreatmentPrograms[vStretches[vSi].Unit].StepCount THEN
      vNewCal := TreatmentPrograms[vStretches[vSi].Unit].Steps[vStretches[vSi].Stage].CalTime
               + vStretches[vSi].DelayS;
      IF vNewCal < TreatmentPrograms[vStretches[vSi].Unit].Steps[vStretches[vSi].Stage].MinTime THEN
        vNewCal := TreatmentPrograms[vStretches[vSi].Unit].Steps[vStretches[vSi].Stage].MinTime;
      END_IF;
      (* Flex cap: min + factor × (max - min) *)
      vFlexCap := TreatmentPrograms[vStretches[vSi].Unit].Steps[vStretches[vSi].Stage].MinTime
               + REAL_TO_DINT(SCH_TSK_FLEX_FACTOR * DINT_TO_REAL(
                   TreatmentPrograms[vStretches[vSi].Unit].Steps[vStretches[vSi].Stage].MaxTime
                 - TreatmentPrograms[vStretches[vSi].Unit].Steps[vStretches[vSi].Stage].MinTime));
      IF vNewCal > vFlexCap THEN
        vNewCal := vFlexCap;
      END_IF;
      TreatmentPrograms[vStretches[vSi].Unit].Steps[vStretches[vSi].Stage].CalTime := vNewCal;

      IF gBatch[vStretches[vSi].Unit].CurStage = vStretches[vSi].Stage THEN
        gBatch[vStretches[vSi].Unit].CalTime := vNewCal;
      END_IF;
     END_IF;
    END_IF;
  END_FOR;
  vStretchCnt := 0;
  (* vPhase + 1 → 2202 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2202: MOVE_AWAY — idle transporter move-away check     *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2202 THEN
  FC_STC_TakeOut(iTimeS := iTimeS);
  vNextPhase := 10000;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10000: READY — cycle complete                          *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 10000 THEN
  vTotalTasks := 0;
  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    vTotalTasks := vTotalTasks + gTask[vTi].Count;
  END_FOR;
  oTaskCnt := vTotalTasks;

  IF NOT oConflict THEN
    gDbgTskConflictType := 0;
    gDbgTskConfUnit     := 0;
    gDbgTskConfStage    := 0;
    gDbgTskBlockedUnit  := 0;
    gDbgTskBlockedStage := 0;
    gDbgTskDeficit       := 0;
  END_IF;
  gDbgTskConflictIter := vConflictIter;
  gDbgTskStretchCnt   := vStretchCnt;

  FOR vUi := 1 TO MAX_UNITS DO
    IF gBatch[vUi].CurStage >= 1
       AND gBatch[vUi].CurStage <= TreatmentPrograms[vUi].StepCount THEN
      gDbgProgCal[vUi] := TreatmentPrograms[vUi].Steps[gBatch[vUi].CurStage].CalTime;
    ELSE
      gDbgProgCal[vUi] := 0;
    END_IF;
  END_FOR;
  (* vPhase + 1 → 10001 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10001: CHECK_DEP_PENDING                               *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 10001 THEN
  IF gDepPending.Valid THEN
    FOR vUi := 1 TO MAX_UNITS DO
      IF gDepPending.Programs[vUi].ProgramId > 0 THEN
        TreatmentPrograms[vUi] := gDepPending.Programs[vUi];
      END_IF;
    END_FOR;
    IF gDepPending.BatchUnit >= 1 AND gDepPending.BatchUnit <= MAX_UNITS THEN
      gBatch[gDepPending.BatchUnit].CurStage   := gDepPending.BatchStage;
      gBatch[gDepPending.BatchUnit].State       := gDepPending.BatchState;
      gBatch[gDepPending.BatchUnit].StartTime   := gDepPending.TimeStamp;
      gBatch[gDepPending.BatchUnit].MinTime     := gDepPending.BatchMinTime;
      gBatch[gDepPending.BatchUnit].MaxTime     := gDepPending.BatchMaxTime;
      gBatch[gDepPending.BatchUnit].CalTime     := gDepPending.BatchCalTime;
    END_IF;
    (* Apply active batch CalTimes written by DEP *)
    FOR vUi := 1 TO MAX_UNITS DO
      IF gDepPending.ActiveBatchCalTime[vUi] > 0
         AND vUi <> gDepPending.BatchUnit THEN
        gBatch[vUi].CalTime := gDepPending.ActiveBatchCalTime[vUi];
      END_IF;
    END_FOR;
    gDepPending.Valid := FALSE;
    gConflictResolved := FALSE;
    gTskStable := FALSE;
    vNextPhase := 1;   (* full recalculation *)
  END_IF;
  (* else vPhase + 1 → 10002 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10002: RESTART — begin new cycle                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 10002 THEN
  vCycleCount := vCycleCount + 1;
  oCycleCnt := vCycleCount;
  oRoundTicks := vRoundTicks;
  vRoundTicks := 0;
  vNextPhase := 1;

(* ══════════════════════════════════════════════════════════════ *)
(* Unknown vPhase → reset                                        *)
(* ══════════════════════════════════════════════════════════════ *)
ELSE
  vNextPhase := 1;
END_IF;

(* ── Phase advancement: default = vPhase + 1 ── *)
IF vNextPhase > 0 THEN
  vPhase := vNextPhase;
ELSE
  vPhase := vPhase + 1;
END_IF;
oPhase := vPhase;

END_FUNCTION_BLOCK

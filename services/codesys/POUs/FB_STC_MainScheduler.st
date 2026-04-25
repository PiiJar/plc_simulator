(* ===========================================================================================
 *  FB_STC_MainScheduler — Master scheduler orchestrator
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Manages FB_TSK_Scheduler and FB_DEP_Scheduler calls on
 *  alternating PLC scan cycles. Ensures they never execute
 *  on the same cycle.
 *
 *  Synchronization rules:
 *  1. Normal: alternate TSK_TURN → DEP_TURN → TSK_TURN
 *  2. Skip DEP when TSK is still computing (vPhase < 10000)
 *  3. Skip DEP when gDepPending.Valid = TRUE
 *  4. gTskStable is computed after each TSK call
 *
 *  Turn values: 0=INIT, 1=TSK_TURN, 2=DEP_TURN
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION_BLOCK FB_STC_MainScheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iRun   : BOOL;     (* TRUE = run *)
  iTimeS : LINT;     (* current absolute time (s), unix seconds *)
END_VAR

VAR_EXTERNAL CONSTANT
  MAX_UNITS     : INT;
  NOT_PROCESSED : INT;
END_VAR

VAR_EXTERNAL
  gTskStable              : BOOL;
  gConflictResolved       : BOOL;
  gDepPending             : UDT_JC_DepPendingWriteType;
  gBatch                  : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  gSchedule               : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gDepWkSchedule          : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  (* Scheduler debug globals — written here, read by Gateway via OPC UA *)
  gSchedDbgTskPhase       : INT;
  gSchedDbgDepPhase       : INT;
  gSchedDbgTurn           : INT;
  gSchedDbgSkipCnt        : INT;
  gSchedDbgDepRejectCnt   : INT;
  gSchedDbgDepFitRound    : INT;
  gSchedDbgDepCurWaitUnit : INT;
  gSchedDbgDepWaitCnt     : INT;
  gSchedDbgBatchCnt       : INT;
  gSchedDbgTskRoundTicks  : INT;
  gSchedDbgDepRoundTicks  : INT;
END_VAR

VAR_OUTPUT
  oTskPhase : INT;     (* TSK scheduler vPhase *)
  oDepPhase : INT;     (* DEP scheduler vPhase *)
  oTurn     : INT;     (* 1=TSK ran, 2=DEP ran *)
  oSkipCnt  : INT;     (* DEP skipped count (debug) *)
END_VAR

VAR
  vFB_TskScheduler  : FB_TSK_Scheduler;
  vFB_DepScheduler  : FB_DEP_Scheduler;
  vFB_TwaCalcLimits : FB_TWA_CalcLimits;
  (* dispatch — now FC FC_STC_DispatchTask, no instance vNeeded *)
  vTurn             : INT := 0;   (* 0=init, 1=TSK, 2=DEP *)
  vSkipCnt          : INT := 0;
  vTskPhase         : INT := 0;
  vUi               : INT;
END_VAR

IF NOT iRun THEN
  (* Stop both schedulers *)
  vFB_TskScheduler(iRun := FALSE, iTimeS := 0);
  vFB_DepScheduler(iRun := FALSE, iTimeS := 0, iTskPhase := 0);
  vTurn := 0;
  vTskPhase := 0;
  oTskPhase := 0;
  oDepPhase := 0;
  oTurn := 0;
  RETURN;
END_IF;

(* ── Calculate transporter working areas (X-limits) every cycle ── *)
vFB_TwaCalcLimits();

(* ── Dispatch tasks to idle transporters (every scan) ── *)
FC_STC_DispatchTask();

(* ── Determine this cycle's vTurn ── *)
IF vTurn = 0 THEN
  (* First scan: always start with TSK *)
  vTurn := 1;

ELSIF vTurn = 1 THEN
  (* Last cycle was TSK → normally DEP's vTurn *)
  (* But skip DEP if: *)
  (*   a) TSK has not reached READY yet (vPhase < 10000) *)
  (*   b) pending data waiting for TSK to process *)
  IF vTskPhase < 10000 THEN
    (* TSK still computing — DEP would be blocked at WAIT_STABLE *)
    vTurn := 1;
    vSkipCnt := vSkipCnt + 1;
  ELSIF gDepPending.Valid THEN
    (* TSK must process pending before DEP continues *)
    vTurn := 1;
    vSkipCnt := vSkipCnt + 1;
  ELSE
    vTurn := 2;
  END_IF;

ELSIF vTurn = 2 THEN
  (* Last cycle was DEP → TSK's vTurn.
     DEP now works on sandbox arrays g_dep_wk_xxx, never live globals,
     so TSK can run freely on any cycle. *)
  vTurn := 1;
END_IF;

(* ── Execute the selected scheduler ── *)
IF vTurn = 1 THEN
  (* TSK vTurn *)
  vFB_TskScheduler(iRun := TRUE, iTimeS := iTimeS);
  vTskPhase := vFB_TskScheduler.oPhase;

  (* JS parity: set stable only when TSK reached READY and conflictResolved; do not clear here *)
    IF (vTskPhase >= 10000) AND gConflictResolved THEN
      gTskStable := TRUE;
  END_IF;

ELSIF vTurn = 2 THEN
  (* DEP vTurn *)
  vFB_DepScheduler(
    iRun       := TRUE,
    iTimeS    := iTimeS,
    iTskPhase := vTskPhase
  );
END_IF;

(* ── Publish waiting batch schedules from DEP workspace for UI display ── *)
FOR vUi := 1 TO MAX_UNITS DO
  IF gBatch[vUi].State = NOT_PROCESSED AND gDepWkSchedule[vUi].StageCount > 0 THEN
    gSchedule[vUi] := gDepWkSchedule[vUi];
  END_IF;
END_FOR;

(* ── Update outputs ── *)
oTskPhase := vFB_TskScheduler.oPhase;
oDepPhase := vFB_DepScheduler.oPhase;
oTurn      := vTurn;
oSkipCnt  := vSkipCnt;

(* ── Forward to scheduler debug globals (OPC UA readable) ── *)
gSchedDbgTskPhase        := vFB_TskScheduler.oPhase;
gSchedDbgDepPhase        := vFB_DepScheduler.oPhase;
gSchedDbgTurn             := vTurn;
gSchedDbgSkipCnt         := vSkipCnt;
gSchedDbgDepRejectCnt   := vFB_DepScheduler.oRejectCnt;
gSchedDbgDepFitRound    := vFB_DepScheduler.oFitRound;
gSchedDbgDepCurWaitUnit := vFB_DepScheduler.oCurWaitUnit;
gSchedDbgDepWaitCnt     := vFB_DepScheduler.oWaitCnt;
gSchedDbgBatchCnt        := vFB_TskScheduler.oBatchCnt;
gSchedDbgTskRoundTicks  := vFB_TskScheduler.oRoundTicks;
gSchedDbgDepRoundTicks  := vFB_DepScheduler.oRoundTicks;

END_FUNCTION_BLOCK

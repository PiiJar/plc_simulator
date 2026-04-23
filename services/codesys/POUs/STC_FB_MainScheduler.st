(* ===========================================================================================
 *  STC_FB_MainScheduler — Master scheduler orchestrator
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Manages TSK_FB_Scheduler and DEP_FB_Scheduler calls on
 *  alternating PLC scan cycles. Ensures they never execute
 *  on the same cycle.
 *
 *  Synchronization rules:
 *  1. Normal: alternate TSK_TURN → DEP_TURN → TSK_TURN
 *  2. Skip DEP when TSK is still computing (phase < 10000)
 *  3. Skip DEP when DepPending.Valid = TRUE
 *  4. TskStable is computed after each TSK call
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


FUNCTION_BLOCK STC_FB_MainScheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iRun                     : BOOL;     (* TRUE = run *)
  iTimeS                  : LINT;     (* current absolute time (s), unix seconds *)
END_VAR

VAR_EXTERNAL
  TskStable              : BOOL;
  ConflictResolved       : BOOL;
  DepPending             : UDT_JC_DepPendingWriteType;
  MAX_UNITS                 : INT;
  NOT_PROCESSED             : INT;
  Batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  Schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  DepWkSchedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  (* Scheduler debug globals — written here, read by Gateway via OPC UA *)
  SchedDbgTskPhase     : INT;
  SchedDbgDepPhase     : INT;
  SchedDbgTurn          : INT;
  SchedDbgSkipCnt      : INT;
  SchedDbgDepRejectCnt : INT;
  SchedDbgDepFitRound : INT;
  SchedDbgDepCurWaitUnit : INT;
  SchedDbgDepWaitCnt  : INT;
  SchedDbgBatchCnt     : INT;
  SchedDbgTskRoundTicks : INT;
  SchedDbgDepRoundTicks : INT;
END_VAR

VAR_OUTPUT
  oTskPhase               : INT;     (* TSK scheduler phase *)
  oDepPhase               : INT;     (* DEP scheduler phase *)
  oTurn                    : INT;     (* 1=TSK ran, 2=DEP ran *)
  oSkipCnt                : INT;     (* DEP skipped count (debug) *)
END_VAR

VAR
  vFB_TskSched                 : TSK_FB_Scheduler;
  vFB_DepSched                 : DEP_FB_Scheduler;
  vFB_TwaCalc                  : TWA_FB_CalcLimits;
  (* dispatch — now FC STC_FC_DispatchTask, no instance needed *)
  vTurn                      : INT := 0;   (* 0=init, 1=TSK, 2=DEP *)
  vSkipCnt                  : INT := 0;
  vTskPhase                 : INT := 0;
  vUi                        : INT;
END_VAR

IF NOT iRun THEN
  (* Stop both schedulers *)
  vFB_TskSched(iRun := FALSE, iTimeS := 0);
  vFB_DepSched(iRun := FALSE, iTimeS := 0, iTskPhase := 0);
  vTurn := 0;
  vTskPhase := 0;
  oTskPhase := 0;
  oDepPhase := 0;
  oTurn := 0;
  RETURN;
END_IF;

(* ── Calculate transporter working areas (X-limits) every cycle ── *)
vFB_TwaCalc();

(* ── Dispatch tasks to idle transporters (every scan) ── *)
STC_FC_DispatchTask();

(* ── Determine this cycle's vTurn ── *)
IF vTurn = 0 THEN
  (* First scan: always start with TSK *)
  vTurn := 1;

ELSIF vTurn = 1 THEN
  (* Last cycle was TSK → normally DEP's vTurn *)
  (* But skip DEP if: *)
  (*   a) TSK has not reached READY yet (phase < 10000) *)
  (*   b) pending data waiting for TSK to process *)
  IF vTskPhase < 10000 THEN
    (* TSK still computing — DEP would be blocked at WAIT_STABLE *)
    vTurn := 1;
    vSkipCnt := vSkipCnt + 1;
  ELSIF DepPending.Valid THEN
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
  vFB_TskSched(iRun := TRUE, iTimeS := iTimeS);
  vTskPhase := vFB_TskSched.oPhase;

  (* JS parity: set stable only when TSK reached READY and conflictResolved; do not clear here *)
    IF (vTskPhase >= 10000) AND ConflictResolved THEN
      TskStable := TRUE;
  END_IF;

ELSIF vTurn = 2 THEN
  (* DEP vTurn *)
  vFB_DepSched(
    iRun       := TRUE,
    iTimeS    := iTimeS,
    iTskPhase := vTskPhase
  );
END_IF;

(* ── Publish waiting batch schedules from DEP workspace for UI display ── *)
FOR vUi := 1 TO MAX_UNITS DO
  IF Batch[vUi].State = NOT_PROCESSED AND DepWkSchedule[vUi].StageCount > 0 THEN
    Schedule[vUi] := DepWkSchedule[vUi];
  END_IF;
END_FOR;

(* ── Update outputs ── *)
oTskPhase := vFB_TskSched.oPhase;
oDepPhase := vFB_DepSched.oPhase;
oTurn      := vTurn;
oSkipCnt  := vSkipCnt;

(* ── Forward to scheduler debug globals (OPC UA readable) ── *)
SchedDbgTskPhase        := vFB_TskSched.oPhase;
SchedDbgDepPhase        := vFB_DepSched.oPhase;
SchedDbgTurn             := vTurn;
SchedDbgSkipCnt         := vSkipCnt;
SchedDbgDepRejectCnt   := vFB_DepSched.oRejectCnt;
SchedDbgDepFitRound    := vFB_DepSched.oFitRound;
SchedDbgDepCurWaitUnit := vFB_DepSched.oCurWaitUnit;
SchedDbgDepWaitCnt     := vFB_DepSched.oWaitCnt;
SchedDbgBatchCnt        := vFB_TskSched.oBatchCnt;
SchedDbgTskRoundTicks  := vFB_TskSched.oRoundTicks;
SchedDbgDepRoundTicks  := vFB_DepSched.oRoundTicks;

END_FUNCTION_BLOCK

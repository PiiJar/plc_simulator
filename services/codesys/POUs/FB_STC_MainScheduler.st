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
 *  3. Skip DEP when g_dep_pending.Valid = TRUE
 *  4. g_tsk_stable is computed after each TSK call
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
  iRun                     : BOOL;     (* TRUE = run *)
  iTimeS                  : LINT;     (* current absolute time (s), unix seconds *)
END_VAR

VAR_EXTERNAL
  g_tsk_stable              : BOOL;
  g_conflict_resolved       : BOOL;
  g_dep_pending             : UDT_JC_DepPendingWriteType;
  MAX_UNITS                 : INT;
  NOT_PROCESSED             : INT;
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  g_schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_dep_wk_schedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  (* Scheduler debug globals — written here, read by Gateway via OPC UA *)
  g_sched_dbg_tsk_phase     : INT;
  g_sched_dbg_dep_phase     : INT;
  g_sched_dbg_turn          : INT;
  g_sched_dbg_skip_cnt      : INT;
  g_sched_dbg_dep_reject_cnt : INT;
  g_sched_dbg_dep_fit_round : INT;
  g_sched_dbg_dep_cur_wait_unit : INT;
  g_sched_dbg_dep_wait_cnt  : INT;
  g_sched_dbg_batch_cnt     : INT;
  g_sched_dbg_tsk_round_ticks : INT;
  g_sched_dbg_dep_round_ticks : INT;
END_VAR

VAR_OUTPUT
  oTskPhase               : INT;     (* TSK scheduler vPhase *)
  oDepPhase               : INT;     (* DEP scheduler vPhase *)
  oTurn                    : INT;     (* 1=TSK ran, 2=DEP ran *)
  oSkipCnt                : INT;     (* DEP skipped count (debug) *)
END_VAR

VAR
  vFB_TskScheduler                 : FB_TSK_Scheduler;
  vFB_DepScheduler                 : FB_DEP_Scheduler;
  vFB_TwaCalcLimits                  : FB_TWA_CalcLimits;
  (* dispatch — now FC FC_STC_DispatchTask, no instance vNeeded *)
  vTurn                      : INT := 0;   (* 0=init, 1=TSK, 2=DEP *)
  vSkipCnt                  : INT := 0;
  vTskPhase                 : INT := 0;
  vUi                        : INT;
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
  ELSIF g_dep_pending.Valid THEN
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
    IF (vTskPhase >= 10000) AND g_conflict_resolved THEN
      g_tsk_stable := TRUE;
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
  IF g_batch[vUi].State = NOT_PROCESSED AND g_dep_wk_schedule[vUi].StageCount > 0 THEN
    g_schedule[vUi] := g_dep_wk_schedule[vUi];
  END_IF;
END_FOR;

(* ── Update outputs ── *)
oTskPhase := vFB_TskScheduler.oPhase;
oDepPhase := vFB_DepScheduler.oPhase;
oTurn      := vTurn;
oSkipCnt  := vSkipCnt;

(* ── Forward to scheduler debug globals (OPC UA readable) ── *)
g_sched_dbg_tsk_phase        := vFB_TskScheduler.oPhase;
g_sched_dbg_dep_phase        := vFB_DepScheduler.oPhase;
g_sched_dbg_turn             := vTurn;
g_sched_dbg_skip_cnt         := vSkipCnt;
g_sched_dbg_dep_reject_cnt   := vFB_DepScheduler.oRejectCnt;
g_sched_dbg_dep_fit_round    := vFB_DepScheduler.oFitRound;
g_sched_dbg_dep_cur_wait_unit := vFB_DepScheduler.oCurWaitUnit;
g_sched_dbg_dep_wait_cnt     := vFB_DepScheduler.oWaitCnt;
g_sched_dbg_batch_cnt        := vFB_TskScheduler.oBatchCnt;
g_sched_dbg_tsk_round_ticks  := vFB_TskScheduler.oRoundTicks;
g_sched_dbg_dep_round_ticks  := vFB_DepScheduler.oRoundTicks;

END_FUNCTION_BLOCK

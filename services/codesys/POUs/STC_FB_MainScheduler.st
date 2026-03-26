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


FUNCTION_BLOCK STC_FB_MainScheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_run                     : BOOL;     (* TRUE = run *)
  i_time_s                  : LINT;     (* current absolute time (s), unix seconds *)
END_VAR

VAR_EXTERNAL
  g_tsk_stable              : BOOL;
  g_conflict_resolved       : BOOL;
  g_dep_pending             : UDT_JC_DepPendingWriteType;
  MAX_Units                 : INT;
  g_batch                   : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_schedule                : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_dep_wk_schedule         : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
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
END_VAR

VAR_OUTPUT
  o_tsk_phase               : INT;     (* TSK scheduler phase *)
  o_dep_phase               : INT;     (* DEP scheduler phase *)
  o_turn                    : INT;     (* 1=TSK ran, 2=DEP ran *)
  o_skip_cnt                : INT;     (* DEP skipped count (debug) *)
END_VAR

VAR
  tsk_sched                 : TSK_FB_Scheduler;
  dep_sched                 : DEP_FB_Scheduler;
  (* dispatch — now FC STC_DispatchTask, no instance needed *)
  turn                      : INT := 0;   (* 0=init, 1=TSK, 2=DEP *)
  skip_cnt                  : INT := 0;
  tsk_phase                 : INT := 0;
  ui                        : INT;
END_VAR

IF NOT i_run THEN
  (* Stop both schedulers *)
  tsk_sched(i_run := FALSE, i_time_s := 0);
  dep_sched(i_run := FALSE, i_time_s := 0, i_tsk_phase := 0);
  turn := 0;
  tsk_phase := 0;
  o_tsk_phase := 0;
  o_dep_phase := 0;
  o_turn := 0;
  RETURN;
END_IF;

(* ── Dispatch tasks to idle transporters (every scan) ── *)
STC_DispatchTask();

(* ── Determine this cycle's turn ── *)
IF turn = 0 THEN
  (* First scan: always start with TSK *)
  turn := 1;

ELSIF turn = 1 THEN
  (* Last cycle was TSK → normally DEP's turn *)
  (* But skip DEP if: *)
  (*   a) TSK has not reached READY yet (phase < 10000) *)
  (*   b) pending data waiting for TSK to process *)
  IF tsk_phase < 10000 THEN
    (* TSK still computing — DEP would be blocked at WAIT_STABLE *)
    turn := 1;
    skip_cnt := skip_cnt + 1;
  ELSIF g_dep_pending.Valid THEN
    (* TSK must process pending before DEP continues *)
    turn := 1;
    skip_cnt := skip_cnt + 1;
  ELSE
    turn := 2;
  END_IF;

ELSIF turn = 2 THEN
  (* Last cycle was DEP → TSK's turn.
     DEP now works on sandbox arrays g_dep_wk_xxx, never live globals,
     so TSK can run freely on any cycle. *)
  turn := 1;
END_IF;

(* ── Execute the selected scheduler ── *)
IF turn = 1 THEN
  (* TSK turn *)
  tsk_sched(i_run := TRUE, i_time_s := i_time_s);
  tsk_phase := tsk_sched.o_phase;

  (* JS parity: set stable only when TSK reached READY and conflictResolved; do not clear here *)
    IF (tsk_phase >= 10000) AND g_conflict_resolved THEN
      g_tsk_stable := TRUE;
  END_IF;

ELSIF turn = 2 THEN
  (* DEP turn *)
  dep_sched(
    i_run       := TRUE,
    i_time_s    := i_time_s,
    i_tsk_phase := tsk_phase
  );
END_IF;

(* ── Publish waiting batch schedules from DEP workspace for UI display ── *)
FOR ui := 1 TO MAX_Units DO
  IF g_batch[ui].State = 0 AND g_dep_wk_schedule[ui].StageCount > 0 THEN
    g_schedule[ui] := g_dep_wk_schedule[ui];
  END_IF;
END_FOR;

(* ── Update outputs ── *)
o_tsk_phase := tsk_sched.o_phase;
o_dep_phase := dep_sched.o_phase;
o_turn      := turn;
o_skip_cnt  := skip_cnt;

(* ── Forward to scheduler debug globals (OPC UA readable) ── *)
g_sched_dbg_tsk_phase        := tsk_sched.o_phase;
g_sched_dbg_dep_phase        := dep_sched.o_phase;
g_sched_dbg_turn             := turn;
g_sched_dbg_skip_cnt         := skip_cnt;
g_sched_dbg_dep_reject_cnt   := dep_sched.o_reject_cnt;
g_sched_dbg_dep_fit_round    := dep_sched.o_fit_round;
g_sched_dbg_dep_cur_wait_unit := dep_sched.o_cur_wait_unit;
g_sched_dbg_dep_wait_cnt     := dep_sched.o_wait_cnt;
g_sched_dbg_batch_cnt        := tsk_sched.o_batch_cnt;

END_FUNCTION_BLOCK

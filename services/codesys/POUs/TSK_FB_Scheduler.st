(* ===========================================================================================
 *  TSK_FB_Scheduler — Main task scheduler state machine
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  One phase per PLC scan cycle.
 *
 *  Phase flow (structured by 100/1000 groups):
 *  0        STOPPED
 *  1        INIT             (collect active batches)
 *  2        NO_TREATMENT_STATES
 *  1000+i   CALC_SCHEDULE    (schedule for batch i, 0..batch_count-1)
 *  2000     CLEAR_TASKS      (clear task queues)
 *  2001+i   CREATE_TASKS     (tasks for batch i, 0..batch_count-1)
 *  2100     SORT_TASKS
 *  2101     SWAP_TASKS
 *  2102     ANALYZE          (→ 2103 if conflict, → 2200 if clean)
 *  2103     RESOLVE          (→ 2100 loop, or → 2200 if max iter)
 *  2200     NO_TREATMENT     (create no-treatment tasks)
 *  2201     APPLY_STRETCHES  (persist resolve decisions)
 *  10000    READY            (cycle complete)
 *  10001    CHECK_DEP_PENDING
 *  10002    RESTART          (→ 1)
 *
 *  Phase advancement:
 *  Default = phase + 1 (at end of function body).
 *  next_phase is set ONLY when jumping to a different group.
 *
 *  Conflict resolution: one conflict per cycle.
 *  If resolved → back to SORT (2100).
 *  If no conflict → NO_TREATMENT → READY.
 *  Max iterations to prevent infinite loops.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *  25.03.2026 - Restructured: phase+1 default, idx from phase offset.
 *
 *
 *)


FUNCTION_BLOCK TSK_FB_Scheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_run                     : BOOL;    (* TRUE = run, FALSE = stop *)
  i_time_s                  : LINT;    (* current absolute time (s), unix seconds *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_Units               : INT;
    MAX_LOCKS               : INT;
END_VAR

VAR_EXTERNAL
  g_batch                   : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_unit                    : ARRAY[1..MAX_Units] OF UDT_JC_UnitType;
  TreatmentPrograms                 : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_task                    : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_schedule                : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  Transporters                     : ARRAY[0..MAX_Transporters] OF UDT_TransporterType;
  (* DEP handshake *)
  g_dep_pending             : UDT_JC_DepPendingWriteType;
  g_conflict_resolved       : BOOL;
  g_tsk_stable              : BOOL;
  (* Debug observability *)
  g_dbg_tsk_conflict_type   : INT;
  g_dbg_tsk_conflict_iter   : INT;
  g_dbg_tsk_conf_unit       : INT;
  g_dbg_tsk_conf_stage      : INT;
  g_dbg_tsk_blocked_unit    : INT;
  g_dbg_tsk_blocked_stage   : INT;
  g_dbg_tsk_deficit         : DINT;
  g_dbg_tsk_stretch_cnt     : INT;
  g_dbg_tsk_total_adv       : DINT;
  g_dbg_tsk_total_delay     : DINT;
  g_dbg_prog_cal            : ARRAY[1..MAX_Units] OF DINT;
END_VAR

VAR_OUTPUT
  o_phase                   : INT;
  o_batch_cnt               : INT;
  o_task_cnt                : INT;
  o_cycle_cnt               : INT;
  o_conflict                : BOOL;
  o_round_ticks             : INT;     (* ticks consumed by last completed round *)
END_VAR

VAR
  phase                     : INT := 0;
  next_phase                : INT;
  idx                       : INT;    (* derived from phase offset *)
  (* Batch list *)
  batch_list                : ARRAY[1..MAX_Units] OF INT;
  batch_count               : INT;
  (* Conflict iteration *)
  conflict_iter             : INT;
  MAX_CONFLICT_ITER         : INT := 40;
  (* Analyze result cache *)
  an_conflict               : BOOL;
  an_conf_type              : INT;
  an_conf_unit              : INT;
  an_conf_stage             : INT;
  an_conf_trans             : INT;
  an_blocked_unit           : INT;
  an_blocked_stage          : INT;
  an_deficit                : REAL;
  (* Resolve result cache *)
  rs_total_adv              : REAL;
  rs_total_delay            : REAL;
  (* Transporter assignment *)
  sched_trans               : INT;
  (* Locked stages — prevents oscillation in resolve loop *)
  locks                     : ARRAY[1..MAX_LOCKS] OF UDT_JC_TskLockType;
  lock_cnt                  : INT := 0;
  locks_initialized         : BOOL := FALSE;
  fb_find                   : STC_FindTransporter;
  (* candidateStretches — JS: resolve decisions persisted to TreatmentPrograms *)
  stretches                 : ARRAY[1..20] OF UDT_JC_TskStretchType;
  stretch_cnt               : INT := 0;
  si                        : INT;
  new_cal                   : DINT;
  (* Temp *)
  ui                        : INT;
  ui2                       : INT;
  ti                        : INT;
  bi                        : INT;
  total_tasks               : INT;
  cycle_count               : INT := 0;
  round_ticks               : INT := 0;  (* ticks since last RESTART *)
END_VAR

IF NOT i_run THEN
  IF phase <> 0 THEN
    FOR ti := 1 TO MAX_Transporters DO
      g_task[ti].Count := 0;
    END_FOR;
  END_IF;
  phase := 0;
  o_phase := 0;
  RETURN;
END_IF;

next_phase := 0;
round_ticks := round_ticks + 1;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 0: STOPPED                                             *)
(* ══════════════════════════════════════════════════════════════ *)
IF phase = 0 THEN
  next_phase := 1;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1: INIT — collect active batches                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 1 THEN
  (* Clear schedule for ALL units — start from clean slate *)
  FOR ui := 1 TO MAX_Units DO
    g_schedule[ui].StageCount := 0;
  END_FOR;
  batch_count := STC_CollectActiveBatches(i_mode := 0, o_list => batch_list);
  o_batch_cnt := batch_count;
  conflict_iter := 0;
  locks_initialized := FALSE;
  stretch_cnt := 0;
  g_dbg_tsk_total_adv   := 0;
  g_dbg_tsk_total_delay := 0;

  IF batch_count = 0 THEN
    FOR ti := 1 TO MAX_Transporters DO
      g_task[ti].Count := 0;
    END_FOR;
    g_conflict_resolved := TRUE;
    next_phase := 2200;   (* skip to NO_TREATMENT *)
  ELSE
    g_conflict_resolved := FALSE;
    (* phase + 1 → 2 *)
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2: NO_TREATMENT_STATES                                *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2 THEN
  STC_NoTreatmentStates();
  next_phase := 1000;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1000+i: CALC_SCHEDULE — one batch per scan             *)
(*   i = 0..batch_count-1: calculate schedule                   *)
(*   i >= batch_count: done → 2000                              *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase >= 1000 AND phase <= 1999 THEN
  idx := phase - 1000;

  IF idx < batch_count THEN
    ui := batch_list[idx + 1];

    (* CalcSchedule handles elapsed-time normalisation — no pre-adjustment needed here. *)

    IF g_unit[ui].location < MIN_StationIndex THEN
      sched_trans := g_unit[ui].location;
    ELSE
      fb_find(i_lift_stn := g_unit[ui].location, i_sink_stn := 0);
      sched_trans := fb_find.o_trans;
      IF sched_trans = 0 THEN sched_trans := 1; END_IF;
    END_IF;

    STC_CalcSchedule(i_unit := ui, i_trans := sched_trans, i_time_s := i_time_s,
                     io_schedule := g_schedule, io_batch := g_batch, io_program := TreatmentPrograms);
    (* phase + 1 → next batch *)

  ELSE
    next_phase := 2000;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2000: CLEAR_TASKS — clear all task queues              *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2000 THEN
  FOR ti := 1 TO MAX_Transporters DO
    g_task[ti].Count := 0;
  END_FOR;
  (* phase + 1 → 2001 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2001+i: CREATE_TASKS — one batch per scan              *)
(*   i = 0..batch_count-1: create tasks                         *)
(*   i >= batch_count: done → 2100                              *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase >= 2001 AND phase <= 2099 THEN
  idx := phase - 2001;

  IF idx < batch_count THEN
    ui := batch_list[idx + 1];
    STC_CreateTasks(i_unit := ui, io_schedule := g_schedule, io_task := g_task);
    (* phase + 1 → next batch *)
  ELSE
    next_phase := 2100;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2100: SORT_TASKS                                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2100 THEN
  STC_SortTasks(i_trans := 0, i_time_s := i_time_s, io_task := g_task, io_batch := g_batch);
  IF NOT locks_initialized THEN
    lock_cnt := 0;
    FOR bi := 1 TO MAX_LOCKS DO
      locks[bi].Unit := 0;
      locks[bi].Stage := 0;
      locks[bi].Direction := 0;
    END_FOR;
    locks_initialized := TRUE;
  END_IF;
  (* phase + 1 → 2101 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2101: SWAP_TASKS                                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2101 THEN
  STC_SwapTasks(io_task := g_task);
  (* phase + 1 → 2102 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2102: ANALYZE                                          *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2102 THEN
  TSK_Analyze(io_task := g_task,
    o_has_conflict => an_conflict, o_conf_type => an_conf_type,
    o_conf_unit => an_conf_unit, o_conf_stage => an_conf_stage,
    o_conf_trans => an_conf_trans, o_blocked_unit => an_blocked_unit,
    o_blocked_stage => an_blocked_stage, o_deficit => an_deficit);
  o_conflict := an_conflict;

  IF an_conflict THEN
    g_dbg_tsk_conflict_type  := an_conf_type;
    g_dbg_tsk_conf_unit      := an_conf_unit;
    g_dbg_tsk_conf_stage     := an_conf_stage;
    g_dbg_tsk_blocked_unit   := an_blocked_unit;
    g_dbg_tsk_blocked_stage  := an_blocked_stage;
    g_dbg_tsk_deficit        := REAL_TO_DINT(an_deficit);
    g_conflict_resolved := FALSE;
    (* phase + 1 → 2103 RESOLVE *)
  ELSE
    g_conflict_resolved := TRUE;
    next_phase := 2200;   (* skip RESOLVE → NO_TREATMENT *)
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2103: RESOLVE — one conflict, then re-analyze          *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2103 THEN
  TSK_Resolve(
    i_conf_unit     := an_conf_unit,
    i_conf_stage    := an_conf_stage,
    i_conf_trans    := an_conf_trans,
    i_blocked_unit  := an_blocked_unit,
    i_blocked_stage := an_blocked_stage,
    i_deficit       := an_deficit,
    io_locks        := locks,
    io_lock_cnt     := lock_cnt,
    io_schedule     := g_schedule,
    io_task         := g_task,
    io_batch        := g_batch,
    o_total_adv     => rs_total_adv,
    o_total_delay   => rs_total_delay
  );

  (* Collect stretches *)
  IF rs_total_adv > 0.1 AND stretch_cnt < 20 THEN
    stretch_cnt := stretch_cnt + 1;
    stretches[stretch_cnt].Unit   := an_blocked_unit;
    stretches[stretch_cnt].Stage  := an_blocked_stage;
    stretches[stretch_cnt].DelayS := -REAL_TO_DINT(rs_total_adv);
    g_dbg_tsk_total_adv := g_dbg_tsk_total_adv + REAL_TO_DINT(rs_total_adv);
  END_IF;
  IF rs_total_delay > 0.1 AND stretch_cnt < 20 THEN
    stretch_cnt := stretch_cnt + 1;
    stretches[stretch_cnt].Unit   := an_conf_unit;
    stretches[stretch_cnt].Stage  := an_conf_stage;
    stretches[stretch_cnt].DelayS := REAL_TO_DINT(rs_total_delay);
    g_dbg_tsk_total_delay := g_dbg_tsk_total_delay + REAL_TO_DINT(rs_total_delay);
  END_IF;

  conflict_iter := conflict_iter + 1;

  IF conflict_iter >= MAX_CONFLICT_ITER THEN
    g_conflict_resolved := TRUE;
    next_phase := 2200;   (* accept partial, move on *)
  ELSE
    next_phase := 2100;   (* re-SORT → SWAP → ANALYZE *)
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2200: NO_TREATMENT — create no-treatment tasks         *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2200 THEN
  STC_ManualTask(i_time_s := i_time_s, io_task := g_task);
  TSK_NoTreatment(i_time_s := i_time_s, io_task := g_task);
  o_conflict := FALSE;
  (* phase + 1 → 2201 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2201: APPLY_STRETCHES — persist resolve decisions      *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2201 THEN
  FOR si := 1 TO stretch_cnt DO
    IF stretches[si].Unit >= 1 AND stretches[si].Unit <= MAX_Units THEN
     IF stretches[si].Stage >= 1
        AND stretches[si].Stage <= TreatmentPrograms[stretches[si].Unit].StepCount THEN
      new_cal := TreatmentPrograms[stretches[si].Unit].Steps[stretches[si].Stage].CalTime
               + stretches[si].DelayS;
      IF new_cal < TreatmentPrograms[stretches[si].Unit].Steps[stretches[si].Stage].MinTime THEN
        new_cal := TreatmentPrograms[stretches[si].Unit].Steps[stretches[si].Stage].MinTime;
      END_IF;
      IF new_cal > TreatmentPrograms[stretches[si].Unit].Steps[stretches[si].Stage].MaxTime THEN
        new_cal := TreatmentPrograms[stretches[si].Unit].Steps[stretches[si].Stage].MaxTime;
      END_IF;
      TreatmentPrograms[stretches[si].Unit].Steps[stretches[si].Stage].CalTime := new_cal;

      IF g_batch[stretches[si].Unit].CurStage = stretches[si].Stage THEN
        g_batch[stretches[si].Unit].CalTime := new_cal;
      END_IF;
     END_IF;
    END_IF;
  END_FOR;
  stretch_cnt := 0;
  (* phase + 1 → 2202 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2202: MOVE_AWAY — idle transporter move-away check     *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2202 THEN
  STC_TakeOut(i_time_s := i_time_s);
  next_phase := 10000;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10000: READY — cycle complete                          *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 10000 THEN
  total_tasks := 0;
  FOR ti := 1 TO MAX_Transporters DO
    total_tasks := total_tasks + g_task[ti].Count;
  END_FOR;
  o_task_cnt := total_tasks;

  IF NOT o_conflict THEN
    g_dbg_tsk_conflict_type := 0;
    g_dbg_tsk_conf_unit     := 0;
    g_dbg_tsk_conf_stage    := 0;
    g_dbg_tsk_blocked_unit  := 0;
    g_dbg_tsk_blocked_stage := 0;
    g_dbg_tsk_deficit       := 0;
  END_IF;
  g_dbg_tsk_conflict_iter := conflict_iter;
  g_dbg_tsk_stretch_cnt   := stretch_cnt;

  FOR ui := 1 TO MAX_Units DO
    IF g_batch[ui].CurStage >= 1
       AND g_batch[ui].CurStage <= TreatmentPrograms[ui].StepCount THEN
      g_dbg_prog_cal[ui] := TreatmentPrograms[ui].Steps[g_batch[ui].CurStage].CalTime;
    ELSE
      g_dbg_prog_cal[ui] := 0;
    END_IF;
  END_FOR;
  (* phase + 1 → 10001 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10001: CHECK_DEP_PENDING                               *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 10001 THEN
  IF g_dep_pending.Valid THEN
    FOR ui := 1 TO MAX_Units DO
      IF g_dep_pending.Programs[ui].ProgramId > 0 THEN
        TreatmentPrograms[ui] := g_dep_pending.Programs[ui];
      END_IF;
    END_FOR;
    IF g_dep_pending.BatchUnit >= 1 AND g_dep_pending.BatchUnit <= MAX_Units THEN
      g_batch[g_dep_pending.BatchUnit].CurStage   := g_dep_pending.BatchStage;
      g_batch[g_dep_pending.BatchUnit].State       := g_dep_pending.BatchState;
      g_batch[g_dep_pending.BatchUnit].StartTime   := g_dep_pending.TimeStamp;
      g_batch[g_dep_pending.BatchUnit].MinTime     := g_dep_pending.BatchMinTime;
      g_batch[g_dep_pending.BatchUnit].MaxTime     := g_dep_pending.BatchMaxTime;
      g_batch[g_dep_pending.BatchUnit].CalTime     := g_dep_pending.BatchCalTime;
    END_IF;
    g_dep_pending.Valid := FALSE;
    g_conflict_resolved := FALSE;
    g_tsk_stable := FALSE;
    next_phase := 1;   (* full recalculation *)
  END_IF;
  (* else phase + 1 → 10002 *)

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10002: RESTART — begin new cycle                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 10002 THEN
  cycle_count := cycle_count + 1;
  o_cycle_cnt := cycle_count;
  o_round_ticks := round_ticks;
  round_ticks := 0;
  next_phase := 1;

(* ══════════════════════════════════════════════════════════════ *)
(* Unknown phase → reset                                        *)
(* ══════════════════════════════════════════════════════════════ *)
ELSE
  next_phase := 1;
END_IF;

(* ── Phase advancement: default = phase + 1 ── *)
IF next_phase > 0 THEN
  phase := next_phase;
ELSE
  phase := phase + 1;
END_IF;
o_phase := phase;

END_FUNCTION_BLOCK

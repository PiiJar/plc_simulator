(* ============================================================
   TSK_FB_Scheduler — Main task scheduler state machine
   ============================================================
   Ported from taskScheduler.js tick() function (V3.4)

   One phase per PLC scan cycle. Phase counter advances through:
     0    STOPPED
     1    INIT (count active batches)
     2    NO_TREATMENT_STATES (update unit/batch states)
     1000 SCHEDULE_START
     1001..1000+N  SCHEDULE per batch (one per tick, N=MAX_Units)
     1900 SCHEDULE_DONE
     2000 TASKS_START (clear task queues)
     2001..2000+N  CREATE_TASKS per batch (one per tick)
     2200 TASKS_SORT (insertion sort by start_time)
     2201 TASKS_SWAP
     2202 TASKS_ANALYZE
     2203 TASKS_RESOLVE (if conflict found)
     2204 TASKS_NO_TREATMENT (if no conflict)
     10000 READY
     10110 RESTART (begin new cycle)

   Conflict resolution: one conflict per cycle.
   If resolved → RESTART → new ANALYZE.
   If no conflict → NO_TREATMENT → READY.
   Max iterations to prevent infinite loops.
   ============================================================ *)

FUNCTION_BLOCK TSK_FB_Scheduler
VAR_INPUT
  i_run    : BOOL;    (* TRUE = run, FALSE = stop *)
  i_time_s : LINT;    (* current absolute time (s), unix seconds *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
END_VAR

VAR_EXTERNAL
  g_batch  : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_unit    : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_program : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_task    : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_schedule : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_cfg    : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  (* DEP handshake *)
  g_dep_pending : UDT_JC_DepPendingWriteType;
  g_conflict_resolved : BOOL;
  g_tsk_stable       : BOOL;  (* tasksStableFlag: FALSE on DEP activation, TRUE when READY+conflict_free *)
END_VAR
VAR_OUTPUT
  o_phase      : INT;     (* current phase *)
  o_batch_cnt  : INT;     (* active batch count *)
  o_task_cnt   : INT;     (* total task count *)
  o_cycle_cnt  : INT;     (* completed cycles *)
  o_conflict   : BOOL;    (* TRUE during conflict resolution *)
END_VAR
VAR
  phase        : INT := 0;
  next_phase   : INT;
  (* Batch iteration *)
  batch_idx    : INT;      (* current batch being processed 1..10 *)
  batch_list   : ARRAY[1..MAX_Units] OF INT;  (* active unit indices *)
  batch_count  : INT;
  (* Conflict iteration *)
  conflict_iter : INT;
  MAX_CONFLICT_ITER : INT := 40;
  (* Sub-FB instances *)
  fb_calc    : TSK_FB_CalcSchedule;
  fb_create  : TSK_FB_CreateTasks;
  fb_swap    : TSK_FB_SwapTasks;
  fb_analyze : TSK_FB_Analyze;
  fb_resolve : TSK_FB_Resolve;
  fb_notrt   : TSK_FB_NoTreatment;
  fb_clear   : STC_FB_ClearTaskQueues;  (* shared queue clear *)
  fb_sort    : STC_FB_SortTaskQueue;    (* shared queue sort *)
  fb_collect : STC_FB_CollectActiveBatches; (* shared batch collector *)
  fb_notrt_st : STC_FB_NoTreatmentStates;  (* non-treatment state updates *)
  (* Transporter assignment for schedule calculation *)
  sched_trans : INT;
  (* Locked stages — prevents oscillation in resolve loop *)
  locks           : ARRAY[1..50] OF UDT_JC_TskLockType;
  lock_cnt        : INT := 0;
  locks_initialized : BOOL := FALSE;
  fb_find    : STC_FindTransporter;
  (* candidateStretches — JS: resolve decisions persisted to g_program *)
  stretches     : ARRAY[1..20] OF UDT_JC_TskStretchType;
  stretch_cnt   : INT := 0;
  si            : INT;   (* stretch apply loop *)
  new_cal       : DINT;  (* clamped calc time *)
  (* Temp *)
  bi         : INT;
  ti         : INT;
  qi         : INT;
  ui         : INT;
  total_tasks : INT;
  cycle_count : INT := 0;
END_VAR

IF NOT i_run THEN
  IF phase <> 0 THEN
    (* Reset: clear task queues so stale tasks don't persist *)
    fb_clear();
  END_IF;
  phase := 0;
  o_phase := 0;
  RETURN;
END_IF;

next_phase := phase;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 0: STOPPED — wait for i_run                            *)
(* ══════════════════════════════════════════════════════════════ *)
IF phase = 0 THEN
  next_phase := 1;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1: INIT — collect active batches                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 1 THEN
  fb_collect(i_mode := 0);
  batch_count := fb_collect.o_count;
  FOR bi := 1 TO batch_count DO
    batch_list[bi] := fb_collect.o_list[bi];
  END_FOR;
  o_batch_cnt := batch_count;
  conflict_iter := 0;
  locks_initialized := FALSE;
  stretch_cnt := 0;  (* Reset stretch collection for new cycle *)

  IF batch_count = 0 THEN
    (* No active batches — clear stale tasks, then run no-treatment *)
    fb_clear();
    g_conflict_resolved := TRUE;  (* Empty line is stable — JS: conflictResolved = true on reset *)
    next_phase := 2204;
  ELSE
    (* Defensively reset — situation may have changed since last cycle.
         Safe because g_tsk_stable also requires tsk_phase >= 10000,
       which is FALSE during all computation phases (1..2205).
       g_conflict_resolved will be set TRUE/FALSE in Phase 2202 ANALYZE. *)
    g_conflict_resolved := FALSE;
    next_phase := 2;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2: NO_TREATMENT_STATES — update unit/batch states      *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2 THEN
  fb_notrt_st();
  next_phase := 1000;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1000: SCHEDULE_START                                   *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 1000 THEN
  batch_idx := 1;
  next_phase := 1001;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1001..1000+MAX_Units: SCHEDULE per batch (one per tick) *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase >= 1001 AND phase <= 1000 + MAX_Units THEN
  IF batch_idx <= batch_count THEN
    ui := batch_list[batch_idx];

    (* Find transporter for this unit — first one with matching task_area *)
    fb_find(i_lift_stn := g_unit[ui].location, i_sink_stn := 0);
    sched_trans := fb_find.o_trans;
    IF sched_trans = 0 THEN sched_trans := 1; END_IF;  (* fallback default *)

    fb_calc(i_unit := ui, i_trans := sched_trans, i_time_s := i_time_s);

    batch_idx := batch_idx + 1;
    IF batch_idx <= batch_count THEN
      next_phase := phase + 1;
    ELSE
      next_phase := 1900;
    END_IF;
  ELSE
    next_phase := 1900;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1900: SCHEDULE_DONE                                    *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 1900 THEN
  next_phase := 2000;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2000: TASKS_START — clear all task queues              *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2000 THEN
  fb_clear();
  batch_idx := 1;
  next_phase := 2001;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2001..2000+MAX_Units: CREATE_TASKS per batch (one per tick) *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase >= 2001 AND phase <= 2000 + MAX_Units THEN
  IF batch_idx <= batch_count THEN
    ui := batch_list[batch_idx];
    fb_create(i_unit := ui);
    batch_idx := batch_idx + 1;
    IF batch_idx <= batch_count THEN
      next_phase := phase + 1;
    ELSE
      next_phase := 2200;
    END_IF;
  ELSE
    next_phase := 2200;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2200: TASKS_SORT — insertion sort each queue by time   *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2200 THEN
  fb_sort(i_trans := 0);
  (* Initialize locks once per scheduler cycle *)
  IF NOT locks_initialized THEN
    lock_cnt := 0;
    FOR bi := 1 TO 50 DO
      locks[bi].Unit := 0;
      locks[bi].Stage := 0;
      locks[bi].Direction := 0;
    END_FOR;
    locks_initialized := TRUE;
  END_IF;
  next_phase := 2201;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2201: TASKS_SWAP                                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2201 THEN
  fb_swap();
  next_phase := 2202;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2202: TASKS_ANALYZE                                    *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2202 THEN
  fb_analyze();
  o_conflict := fb_analyze.o_has_conflict;
  IF fb_analyze.o_has_conflict THEN
    g_conflict_resolved := FALSE;  (* Conflicts found — DEP must not proceed *)
    next_phase := 2203;
  ELSE
    g_conflict_resolved := TRUE;  (* No conflicts — JS: state.conflictResolved = true *)
    next_phase := 2204;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2203: TASKS_RESOLVE                                    *)
(* One conflict per cycle → recalculate                         *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2203 THEN
  fb_resolve(
    i_conf_unit     := fb_analyze.o_conf_unit,
    i_conf_stage    := fb_analyze.o_conf_stage,
    i_conf_trans    := fb_analyze.o_conf_trans,
    i_blocked_unit  := fb_analyze.o_blocked_unit,
    i_blocked_stage := fb_analyze.o_blocked_stage,
    i_deficit       := fb_analyze.o_deficit,
    io_locks        := locks,
    io_lock_cnt     := lock_cnt
  );

  (* -- Collect stretches from resolve decisions -- *)
  (* JS: TASKS_SAVE collects candidateStretches from resolveHistory *)
  (* ADVANCE on blocked → negative DelayS *)
  IF fb_resolve.o_total_adv > 0.1 AND stretch_cnt < 20 THEN
    stretch_cnt := stretch_cnt + 1;
    stretches[stretch_cnt].Unit   := fb_analyze.o_blocked_unit;
    stretches[stretch_cnt].Stage  := fb_analyze.o_blocked_stage;
    stretches[stretch_cnt].DelayS := -REAL_TO_DINT(fb_resolve.o_total_adv);
  END_IF;
  (* DELAY on conf → positive DelayS *)
  IF fb_resolve.o_total_delay > 0.1 AND stretch_cnt < 20 THEN
    stretch_cnt := stretch_cnt + 1;
    stretches[stretch_cnt].Unit   := fb_analyze.o_conf_unit;
    stretches[stretch_cnt].Stage  := fb_analyze.o_conf_stage;
    stretches[stretch_cnt].DelayS := REAL_TO_DINT(fb_resolve.o_total_delay);
  END_IF;

  conflict_iter := conflict_iter + 1;

  IF conflict_iter >= MAX_CONFLICT_ITER THEN
    (* Max iterations reached — accept partial solution, let DEP proceed *)
    g_conflict_resolved := TRUE;
    next_phase := 2204;
  ELSE
    (* Re-analyze: SORT → SWAP → ANALYZE again *)
    next_phase := 2200;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2204: TASKS_NO_TREATMENT                               *)
(* Task list is stable (no conflicts). Create unit-target tasks *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2204 THEN
  fb_notrt(i_time_s := i_time_s);
  o_conflict := FALSE;
  next_phase := 2205;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2205: APPLY_STRETCHES — persist resolve decisions      *)
(* JS: TASKS_SAVE → candidateStretches → applyTreatmentProgramStretches *)
(* Write accumulated delay/advance to g_program CalTime so next *)
(* cycle builds schedule from adjusted baseline.                *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2205 THEN
  FOR si := 1 TO stretch_cnt DO
    IF stretches[si].Unit >= 1 AND stretches[si].Unit <= MAX_Units THEN
     IF stretches[si].Stage >= 1
        AND stretches[si].Stage <= g_program[stretches[si].Unit].StepCount THEN
      (* Clamp new CalTime between MinTime and MaxTime *)
      new_cal := g_program[stretches[si].Unit].Steps[stretches[si].Stage].CalTime
               + stretches[si].DelayS;
      IF new_cal < g_program[stretches[si].Unit].Steps[stretches[si].Stage].MinTime THEN
        new_cal := g_program[stretches[si].Unit].Steps[stretches[si].Stage].MinTime;
      END_IF;
      IF new_cal > g_program[stretches[si].Unit].Steps[stretches[si].Stage].MaxTime THEN
        new_cal := g_program[stretches[si].Unit].Steps[stretches[si].Stage].MaxTime;
      END_IF;
      g_program[stretches[si].Unit].Steps[stretches[si].Stage].CalTime := new_cal;

      (* If batch is currently on this stage, also update runtime batch.CalTime *)
      IF g_batch[stretches[si].Unit].CurStage = stretches[si].Stage THEN
        g_batch[stretches[si].Unit].CalTime := new_cal;
      END_IF;
     END_IF;
    END_IF;
  END_FOR;
  stretch_cnt := 0;
  next_phase := 10000;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10000: READY — cycle complete                          *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 10000 THEN
  (* Count total tasks *)
  total_tasks := 0;
  FOR ti := 1 TO MAX_Transporters DO
    total_tasks := total_tasks + g_task[ti].Count;
  END_FOR;
  o_task_cnt := total_tasks;
  next_phase := 10100;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10100: CHECK_DEP_PENDING — DEP activated a batch       *)
(* Copy pending data to globals and trigger full recalculation  *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 10100 THEN
  IF g_dep_pending.Valid THEN
    (* Apply DEP's pending data: programs + schedules + stage change.
       ONLY overwrite units where pending has a valid program (ProgramId > 0).
       Reason: DEP snapshots ALL g_program[] at INIT. If a NEW batch was
       loaded by the gateway AFTER the snapshot, the pending copy for that
       unit has ProgramId=0. Blindly overwriting would clobber the
       gateway-written program, breaking the collect filter permanently
       (g_batch[].ProgId <> g_program[].ProgramId). *)
    FOR ui := 1 TO MAX_Units DO
      IF g_dep_pending.Programs[ui].ProgramId > 0 THEN
        g_program[ui]  := g_dep_pending.Programs[ui];
      END_IF;
      IF g_dep_pending.Schedule[ui].StageCount > 0 THEN
        g_schedule[ui] := g_dep_pending.Schedule[ui];
      END_IF;
    END_FOR;
    IF g_dep_pending.BatchUnit >= 1 AND g_dep_pending.BatchUnit <= MAX_Units THEN
      g_batch[g_dep_pending.BatchUnit].CurStage   := g_dep_pending.BatchStage;
      g_batch[g_dep_pending.BatchUnit].State        := g_dep_pending.BatchState;
      g_batch[g_dep_pending.BatchUnit].StartTime   := g_dep_pending.TimeStamp;
      g_batch[g_dep_pending.BatchUnit].MinTime     := g_dep_pending.BatchMinTime;
      g_batch[g_dep_pending.BatchUnit].MaxTime     := g_dep_pending.BatchMaxTime;
      g_batch[g_dep_pending.BatchUnit].CalTime     := g_dep_pending.BatchCalTime;
    END_IF;
    g_dep_pending.Valid := FALSE;
    g_conflict_resolved := FALSE;  (* Force TSK to re-stabilize after DEP activation — JS: tasksConflictResolved = false *)
    g_tsk_stable := FALSE;         (* Mirror JS tasksStableFlag: DEPARTURE activation invalidates stability *)
    (* Full recalculation with new data *)
    next_phase := 1;
  ELSE
    next_phase := 10110;
  END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 10110: RESTART — begin new cycle                       *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 10110 THEN
  cycle_count := cycle_count + 1;
  o_cycle_cnt := cycle_count;
  next_phase := 1;  (* back to INIT *)

(* ══════════════════════════════════════════════════════════════ *)
(* Unknown phase → reset to INIT                                *)
(* ══════════════════════════════════════════════════════════════ *)
ELSE
  next_phase := 1;
END_IF;

(* ── Phase assignment at end of scan ── *)
phase := next_phase;
o_phase := phase;

END_FUNCTION_BLOCK

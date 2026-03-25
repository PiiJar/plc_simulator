(* ============================================================
   TSK_FB_Scheduler — Main task scheduler state machine

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   One phase per PLC scan cycle. Phase counter advances through:
     0    STOPPED
     1    INIT (count active batches)
     2    NO_TREATMENT_STATES (update unit/batch states)
     1000 SCHEDULE_START
     1001..1000+N  SCHEDULE per batch (one per tick)
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
   ------------------------------------------------------------
   Changes:
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
  (* Sub-FB instances removed — CollectActiveBatches and NoTreatmentStates are now FCs *)
  (* Analyze result cache (FC outputs stored per scan) *)
  an_conflict  : BOOL;
  an_conf_type : INT;
  an_conf_unit : INT;
  an_conf_stage : INT;
  an_conf_trans : INT;
  an_blocked_unit : INT;
  an_blocked_stage : INT;
  an_deficit   : REAL;
  (* Resolve result cache *)
  rs_total_adv   : REAL;
  rs_total_delay : REAL;
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
  (* justActivated normalization temps *)
  ja_elapsed : REAL;
  ja_remain  : REAL;
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
    FOR ti := 1 TO MAX_Transporters DO
      g_task[ti].Count := 0;
    END_FOR;
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
  batch_count := STC_CollectActiveBatches(i_mode := 0, o_list => batch_list);
  o_batch_cnt := batch_count;
  conflict_iter := 0;
  locks_initialized := FALSE;
  stretch_cnt := 0;  (* Reset stretch collection for new cycle *)
  g_dbg_tsk_total_adv   := 0;  (* Reset per-cycle accumulators *)
  g_dbg_tsk_total_delay := 0;

  IF batch_count = 0 THEN
    (* No active batches — clear stale tasks, then run no-treatment *)
    FOR ti := 1 TO MAX_Transporters DO
      g_task[ti].Count := 0;
    END_FOR;
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
  STC_NoTreatmentStates();
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

    (* ── justActivated normalization — JS: taskScheduler.js lines 1027-1037 ──
       When a batch is first activated (CurStage=0, State=IN_PROCESS, on station),
       normalize its times to remaining wait time before schedule calculation.
       JS: calc = max(1, oldCalc - elapsed), start = now, min = calc, max = 2*calc *)
    IF g_batch[ui].CurStage = 0
       AND g_batch[ui].State = 1
       AND g_unit[ui].location >= 100 THEN
      IF g_batch[ui].StartTime > 0 AND g_batch[ui].StartTime < i_time_s THEN
        ja_elapsed := LINT_TO_REAL(i_time_s - g_batch[ui].StartTime);
        ja_remain  := DINT_TO_REAL(g_batch[ui].CalTime) - ja_elapsed;
        IF ja_remain < 1.0 THEN ja_remain := 1.0; END_IF;
        g_batch[ui].CalTime   := REAL_TO_DINT(ja_remain);
        g_batch[ui].StartTime := i_time_s;
        g_batch[ui].MinTime   := g_batch[ui].CalTime;
        g_batch[ui].MaxTime   := 2 * g_batch[ui].CalTime;
      END_IF;
    END_IF;

    (* Find transporter for this unit *)
    IF g_unit[ui].location < 100 THEN
      (* Unit is on a transporter — location IS the transporter index *)
      sched_trans := g_unit[ui].location;
    ELSE
      (* Unit is on a station — find transporter by task_area *)
      fb_find(i_lift_stn := g_unit[ui].location, i_sink_stn := 0);
      sched_trans := fb_find.o_trans;
      IF sched_trans = 0 THEN sched_trans := 1; END_IF;  (* fallback default *)
    END_IF;

    STC_CalcSchedule(i_unit := ui, i_trans := sched_trans, i_time_s := i_time_s,
                     io_schedule := g_schedule, io_batch := g_batch, io_program := g_program);

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
  FOR ti := 1 TO MAX_Transporters DO
    g_task[ti].Count := 0;
  END_FOR;
  batch_idx := 1;
  next_phase := 2001;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2001..2000+MAX_Units: CREATE_TASKS per batch (one per tick) *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase >= 2001 AND phase <= 2000 + MAX_Units THEN
  IF batch_idx <= batch_count THEN
    ui := batch_list[batch_idx];
    STC_CreateTasks(i_unit := ui, io_schedule := g_schedule, io_task := g_task);
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
  STC_SortTasks(i_trans := 0, i_time_s := i_time_s, io_task := g_task, io_batch := g_batch);
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
  STC_SwapTasks(io_task := g_task);
  next_phase := 2202;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2202: TASKS_ANALYZE                                    *)
(* ══════════════════════════════════════════════════════════════ *)
ELSIF phase = 2202 THEN
  TSK_Analyze(io_task := g_task,
    o_has_conflict => an_conflict, o_conf_type => an_conf_type,
    o_conf_unit => an_conf_unit, o_conf_stage => an_conf_stage,
    o_conf_trans => an_conf_trans, o_blocked_unit => an_blocked_unit,
    o_blocked_stage => an_blocked_stage, o_deficit => an_deficit);
  o_conflict := an_conflict;
  (* Write analyze results to debug globals *)
  IF an_conflict THEN
    g_dbg_tsk_conflict_type  := an_conf_type;
    g_dbg_tsk_conf_unit      := an_conf_unit;
    g_dbg_tsk_conf_stage     := an_conf_stage;
    g_dbg_tsk_blocked_unit   := an_blocked_unit;
    g_dbg_tsk_blocked_stage  := an_blocked_stage;
    g_dbg_tsk_deficit        := REAL_TO_DINT(an_deficit);
  END_IF;
  IF an_conflict THEN
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

  (* -- Collect stretches from resolve decisions -- *)
  (* JS: TASKS_SAVE collects candidateStretches from resolveHistory *)
  (* ADVANCE on blocked -> negative DelayS *)
  IF rs_total_adv > 0.1 AND stretch_cnt < 20 THEN
    stretch_cnt := stretch_cnt + 1;
    stretches[stretch_cnt].Unit   := an_blocked_unit;
    stretches[stretch_cnt].Stage  := an_blocked_stage;
    stretches[stretch_cnt].DelayS := -REAL_TO_DINT(rs_total_adv);
    g_dbg_tsk_total_adv := g_dbg_tsk_total_adv + REAL_TO_DINT(rs_total_adv);
  END_IF;
  (* DELAY on conf -> positive DelayS *)
  IF rs_total_delay > 0.1 AND stretch_cnt < 20 THEN
    stretch_cnt := stretch_cnt + 1;
    stretches[stretch_cnt].Unit   := an_conf_unit;
    stretches[stretch_cnt].Stage  := an_conf_stage;
    stretches[stretch_cnt].DelayS := REAL_TO_DINT(rs_total_delay);
    g_dbg_tsk_total_delay := g_dbg_tsk_total_delay + REAL_TO_DINT(rs_total_delay);
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
  TSK_NoTreatment(i_time_s := i_time_s, io_task := g_task);
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

  (* Write conflict debug snapshot *)
  IF NOT o_conflict THEN
    g_dbg_tsk_conflict_type := 0;  (* no conflict *)
    g_dbg_tsk_conf_unit     := 0;
    g_dbg_tsk_conf_stage    := 0;
    g_dbg_tsk_blocked_unit  := 0;
    g_dbg_tsk_blocked_stage := 0;
    g_dbg_tsk_deficit       := 0;
  END_IF;
  g_dbg_tsk_conflict_iter := conflict_iter;
  g_dbg_tsk_stretch_cnt   := stretch_cnt;

  (* Snapshot current-stage CalTime from g_program for each active unit *)
  FOR ui := 1 TO MAX_Units DO
    IF g_batch[ui].CurStage >= 1
       AND g_batch[ui].CurStage <= g_program[ui].StepCount THEN
      g_dbg_prog_cal[ui] := g_program[ui].Steps[g_batch[ui].CurStage].CalTime;
    ELSE
      g_dbg_prog_cal[ui] := 0;
    END_IF;
  END_FOR;

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

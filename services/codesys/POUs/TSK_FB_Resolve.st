(* ============================================================
   TSK_FB_Resolve — Conflict resolution matching JS resolveConflict()
   ============================================================
   Ported from transporterTaskScheduler.js resolveConflict() (line 1638)

   Four sequential phases — each reduces remaining deficit,
   next phase uses the remainder (partial solutions accumulate):

     Phase 1: ADVANCE — advance blocked batch using
              CHAIN bottleneck + SUFFIX flex_down
              (walks backward through earlier stages)
     Phase 2: DELAY   — delay conflict batch using
              SINGLE-STAGE flex_up (conf_stage only)
     Phase 3: PRECEDING_DELAY — delay conf batch at stage-1
     Phase 4: DELAY_PREV_PAST_NEXT — delay blocked batch to
              force order swap (only if NOT swappable)

   lockedStages prevents oscillation: once a stage is advanced,
   it cannot be delayed, and vice versa.

   Cap factor: 90% if batch is on that stage, 50% otherwise.

   Each phase applies a FLAT SHIFT: modify the target stage's
   CalcTime + ExitTime, then fb_shift propagates to subsequent
   stages and task queue entries.

   The caller loop (TSK_FB_Scheduler 2200→2202→2203) re-runs
   SORT → SWAP → ANALYZE after each resolve, so partial
   solutions converge over iterations.
   ============================================================ *)

FUNCTION_BLOCK TSK_FB_Resolve
VAR_INPUT
  i_conf_unit     : INT;     (* conflict task: unit *)
  i_conf_stage    : INT;     (* conflict task: stage *)
  i_conf_trans    : INT;     (* conflict task: transporter *)
  i_blocked_unit  : INT;     (* blocking task: unit *)
  i_blocked_stage : INT;     (* blocking task: stage *)
  i_deficit       : REAL;    (* seconds short *)
END_VAR
VAR_IN_OUT
  io_locks    : ARRAY[1..50] OF UDT_JC_TskLockType;
  io_lock_cnt : INT;
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
END_VAR

VAR_EXTERNAL
  g_task    : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_schedule : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_batch   : ARRAY[1..MAX_Units] OF UDT_BatchType;
END_VAR
VAR_OUTPUT
  o_solved      : BOOL;
  o_total_delay : REAL;
  o_total_adv   : REAL;
END_VAR
VAR
  remain      : REAL;
  cap         : REAL;
  amount      : REAL;
  stage_flex  : REAL;
  (* Lock checking *)
  is_locked_adv   : BOOL;   (* blocked stage locked DELAY → cannot ADVANCE *)
  is_locked_del   : BOOL;   (* conf stage locked ADVANCE → cannot DELAY *)
  can_advance     : BOOL;
  can_delay       : BOOL;
  lock_i          : INT;
  (* Priority 3 — PRECEDING_DELAY *)
  prev_conf_stage   : INT;
  is_pcs_locked     : BOOL;
  (* Priority 4 — DELAY_PREV_PAST_NEXT *)
  prev_sink_stn     : INT;
  next_lift_stn     : INT;
  is_blk_adv_locked : BOOL;
  qi                : INT;
  (* Chain advance — JS: walk backward to find bottleneck *)
  chain_flex     : REAL;   (* bottleneck flex among earlier stages *)
  suffix_flex    : REAL;   (* conflictFlexDown - chainFlexDown *)
  earlier_stg    : INT;    (* loop variable for chain walk *)
  earlier_flex   : REAL;   (* individual earlier stage flex_down *)
  chain_amount   : REAL;   (* amount from CHAIN_ADVANCE *)
  suffix_amount  : REAL;   (* amount from SUFFIX_ADVANCE *)
  (* Shared shift FB *)
  fb_shift : STC_FB_ShiftSchedule;
END_VAR

o_solved      := FALSE;
o_total_delay := 0.0;
o_total_adv   := 0.0;
remain        := i_deficit;

IF remain <= 0.1 THEN
  o_solved := TRUE;
  RETURN;
END_IF;

(* ══════ Lock check: is blocked stage locked DELAY? (cannot ADVANCE) ══════ *)
is_locked_adv := FALSE;
FOR lock_i := 1 TO io_lock_cnt DO
  IF io_locks[lock_i].Unit = i_blocked_unit
     AND io_locks[lock_i].Stage = i_blocked_stage
     AND io_locks[lock_i].Direction = 2 THEN  (* 2=DELAY *)
    is_locked_adv := TRUE;
  END_IF;
END_FOR;

(* ══════ Lock check: is conf stage locked ADVANCE? (cannot DELAY) ══════ *)
is_locked_del := FALSE;
FOR lock_i := 1 TO io_lock_cnt DO
  IF io_locks[lock_i].Unit = i_conf_unit
     AND io_locks[lock_i].Stage = i_conf_stage
     AND io_locks[lock_i].Direction = 1 THEN  (* 1=ADVANCE *)
    is_locked_del := TRUE;
  END_IF;
END_FOR;

can_advance := NOT is_locked_adv;
can_delay   := NOT is_locked_del;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1: ADVANCE — advance blocked batch (JS Vaihe 1)       *)
(* Chain bottleneck: walk backward through earlier stages to    *)
(* find smallest flex_down < conflictFlexDown.                  *)
(* CHAIN_ADVANCE uses bottleneck, SUFFIX_ADVANCE uses remainder *)
(* JS: resolveConflict() lines 1738-1860                        *)
(* ══════════════════════════════════════════════════════════════ *)
IF can_advance
   AND i_blocked_unit >= 1 AND i_blocked_unit <= MAX_Units
   AND i_blocked_stage >= 1
   AND i_blocked_stage <= g_schedule[i_blocked_unit].StageCount THEN

  (* Conflict stage's own flex_down *)
  stage_flex := DINT_TO_REAL(
    g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime
    - g_schedule[i_blocked_unit].Stages[i_blocked_stage].MinTime);
  IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

  IF stage_flex > 0.1 THEN
    (* Cap: 90% if batch is on this stage, 50% otherwise *)
    IF g_batch[i_blocked_unit].CurStage = g_schedule[i_blocked_unit].Stages[i_blocked_stage].ProgramStage THEN
      cap := 0.9;
    ELSE
      cap := 0.5;
    END_IF;

    (* -- Chain bottleneck search -- *)
    (* JS: walk backward through prevBatchTasks (stages < conflictStage) *)
    (* Find smallest flex_down among earlier stages that is < conflictFlexDown *)
    chain_flex := stage_flex;  (* init to conflict stage flex = no bottleneck *)
    FOR earlier_stg := 1 TO i_blocked_stage - 1 DO
      earlier_flex := DINT_TO_REAL(
        g_schedule[i_blocked_unit].Stages[earlier_stg].CalcTime
        - g_schedule[i_blocked_unit].Stages[earlier_stg].MinTime);
      IF earlier_flex < 0.0 THEN earlier_flex := 0.0; END_IF;
      IF earlier_flex > 0.0 AND earlier_flex < chain_flex THEN
        chain_flex := earlier_flex;
      END_IF;
    END_FOR;
    (* If no earlier stage had positive flex < conflictFlex, chain_flex = stage_flex *)
    (* In that case suffix_flex = 0 and all advance comes from chain *)

    (* -- CHAIN_ADVANCE: apply bottleneck amount -- *)
    chain_amount := chain_flex * cap;
    IF chain_amount > remain THEN chain_amount := remain; END_IF;

    IF chain_amount > 0.1 THEN
      g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime :=
        g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime - REAL_TO_DINT(chain_amount);
      g_schedule[i_blocked_unit].Stages[i_blocked_stage].ExitTime :=
        g_schedule[i_blocked_unit].Stages[i_blocked_stage].ExitTime - REAL_TO_LINT(chain_amount);

      fb_shift(i_unit := i_blocked_unit, i_from_stage := i_blocked_stage + 1, i_amount := -chain_amount);

      g_batch[i_blocked_unit].CalTime :=
        g_batch[i_blocked_unit].CalTime - REAL_TO_DINT(chain_amount);
      IF g_batch[i_blocked_unit].CalTime < g_batch[i_blocked_unit].MinTime THEN
        g_batch[i_blocked_unit].CalTime := g_batch[i_blocked_unit].MinTime;
      END_IF;

      remain := remain - chain_amount;
      o_total_adv := o_total_adv + chain_amount;
    END_IF;

    (* -- SUFFIX_ADVANCE: use remaining flex beyond bottleneck -- *)
    (* JS: suffixFlexDown = conflictFlexDown - chainFlexDown *)
    suffix_flex := stage_flex - chain_flex;
    IF suffix_flex > 0.1 AND remain > 0.1 THEN
      suffix_amount := suffix_flex * cap;
      IF suffix_amount > remain THEN suffix_amount := remain; END_IF;

      IF suffix_amount > 0.1 THEN
        g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime :=
          g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime - REAL_TO_DINT(suffix_amount);
        g_schedule[i_blocked_unit].Stages[i_blocked_stage].ExitTime :=
          g_schedule[i_blocked_unit].Stages[i_blocked_stage].ExitTime - REAL_TO_LINT(suffix_amount);

        fb_shift(i_unit := i_blocked_unit, i_from_stage := i_blocked_stage + 1, i_amount := -suffix_amount);

        g_batch[i_blocked_unit].CalTime :=
          g_batch[i_blocked_unit].CalTime - REAL_TO_DINT(suffix_amount);
        IF g_batch[i_blocked_unit].CalTime < g_batch[i_blocked_unit].MinTime THEN
          g_batch[i_blocked_unit].CalTime := g_batch[i_blocked_unit].MinTime;
        END_IF;

        remain := remain - suffix_amount;
        o_total_adv := o_total_adv + suffix_amount;
      END_IF;
    END_IF;

    (* Record lock: ADVANCE on blocked stage *)
    IF io_lock_cnt < 50 THEN
      io_lock_cnt := io_lock_cnt + 1;
      io_locks[io_lock_cnt].Unit := i_blocked_unit;
      io_locks[io_lock_cnt].Stage := i_blocked_stage;
      io_locks[io_lock_cnt].Direction := 1;  (* 1=ADVANCE *)
    END_IF;

    IF remain <= 0.1 THEN
      o_solved := TRUE;
      RETURN;
    END_IF;
  END_IF;
END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 2: DELAY — delay conflict batch (JS Vaihe 2)          *)
(* Single-stage flex: conf_stage MaxTime - CalcTime             *)
(* Flat shift applied to conf_stage onward.                     *)
(* Partial delay is OK — remainder goes to Phase 3.             *)
(* ══════════════════════════════════════════════════════════════ *)
IF can_delay AND remain > 0.1
   AND i_conf_unit >= 1 AND i_conf_unit <= MAX_Units
   AND i_conf_stage >= 1
   AND i_conf_stage <= g_schedule[i_conf_unit].StageCount THEN

  stage_flex := DINT_TO_REAL(
    g_schedule[i_conf_unit].Stages[i_conf_stage].MaxTime
    - g_schedule[i_conf_unit].Stages[i_conf_stage].CalcTime);
  IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

  IF stage_flex > 0.1 THEN
    IF g_batch[i_conf_unit].CurStage = g_schedule[i_conf_unit].Stages[i_conf_stage].ProgramStage THEN
      cap := 0.9;
    ELSE
      cap := 0.5;
    END_IF;
    amount := stage_flex * cap;
    IF amount > remain THEN amount := remain; END_IF;

    (* Apply: increase CalcTime of conf_stage *)
    g_schedule[i_conf_unit].Stages[i_conf_stage].CalcTime :=
      g_schedule[i_conf_unit].Stages[i_conf_stage].CalcTime + REAL_TO_DINT(amount);
    g_schedule[i_conf_unit].Stages[i_conf_stage].ExitTime :=
      g_schedule[i_conf_unit].Stages[i_conf_stage].ExitTime + REAL_TO_LINT(amount);

    fb_shift(i_unit := i_conf_unit, i_from_stage := i_conf_stage + 1, i_amount := amount);

    (* JS: propagateDelayToBatch updates batch.calc_time_s ONLY if batch is on this stage *)
    IF g_batch[i_conf_unit].CurStage = g_schedule[i_conf_unit].Stages[i_conf_stage].ProgramStage THEN
      g_batch[i_conf_unit].CalTime :=
        g_batch[i_conf_unit].CalTime + REAL_TO_DINT(amount);
      IF g_batch[i_conf_unit].CalTime > g_batch[i_conf_unit].MaxTime THEN
        g_batch[i_conf_unit].CalTime := g_batch[i_conf_unit].MaxTime;
      END_IF;
    END_IF;

    remain := remain - amount;
    o_total_delay := o_total_delay + amount;

    (* Record lock: DELAY on conf stage *)
    IF io_lock_cnt < 50 THEN
      io_lock_cnt := io_lock_cnt + 1;
      io_locks[io_lock_cnt].Unit := i_conf_unit;
      io_locks[io_lock_cnt].Stage := i_conf_stage;
      io_locks[io_lock_cnt].Direction := 2;  (* 2=DELAY *)
    END_IF;

    IF remain <= 0.1 THEN
      o_solved := TRUE;
      RETURN;
    END_IF;
  END_IF;
END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 3: PRECEDING_DELAY — delay conf batch at stage-1       *)
(* (JS Vaihe 3)                                                 *)
(* Delay the conf batch's PREVIOUS stage to push everything     *)
(* ══════════════════════════════════════════════════════════════ *)
prev_conf_stage := i_conf_stage - 1;
IF remain > 0.1 AND prev_conf_stage >= 1 AND i_conf_unit >= 1 AND i_conf_unit <= MAX_Units THEN
  (* Check lock: is prev_conf_stage locked ADVANCE? → cannot DELAY *)
  is_pcs_locked := FALSE;
  FOR lock_i := 1 TO io_lock_cnt DO
    IF io_locks[lock_i].Unit = i_conf_unit
       AND io_locks[lock_i].Stage = prev_conf_stage
       AND io_locks[lock_i].Direction = 1 THEN
      is_pcs_locked := TRUE;
    END_IF;
  END_FOR;

  IF NOT is_pcs_locked THEN
    stage_flex := DINT_TO_REAL(g_schedule[i_conf_unit].Stages[prev_conf_stage].MaxTime
                - g_schedule[i_conf_unit].Stages[prev_conf_stage].CalcTime);
    IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

    IF stage_flex > 0.1 THEN
      IF g_batch[i_conf_unit].CurStage = g_schedule[i_conf_unit].Stages[prev_conf_stage].ProgramStage THEN
        cap := 0.9;
      ELSE
        cap := 0.5;
      END_IF;
      amount := stage_flex * cap;
      IF amount > remain THEN amount := remain; END_IF;

      g_schedule[i_conf_unit].Stages[prev_conf_stage].CalcTime :=
        g_schedule[i_conf_unit].Stages[prev_conf_stage].CalcTime + REAL_TO_DINT(amount);
      g_schedule[i_conf_unit].Stages[prev_conf_stage].ExitTime :=
        g_schedule[i_conf_unit].Stages[prev_conf_stage].ExitTime + REAL_TO_LINT(amount);
      fb_shift(i_unit := i_conf_unit, i_from_stage := prev_conf_stage + 1, i_amount := amount);

      (* JS: propagateDelayToBatch with propagateFromStage=conf_stage
         updates batch.calc_time_s ONLY if batch is on conf_stage *)
      IF g_batch[i_conf_unit].CurStage = g_schedule[i_conf_unit].Stages[i_conf_stage].ProgramStage THEN
        g_batch[i_conf_unit].CalTime :=
          g_batch[i_conf_unit].CalTime + REAL_TO_DINT(amount);
        IF g_batch[i_conf_unit].CalTime > g_batch[i_conf_unit].MaxTime THEN
          g_batch[i_conf_unit].CalTime := g_batch[i_conf_unit].MaxTime;
        END_IF;
      END_IF;

      remain := remain - amount;
      o_total_delay := o_total_delay + amount;

      (* Record lock *)
      IF io_lock_cnt < 50 THEN
        io_lock_cnt := io_lock_cnt + 1;
        io_locks[io_lock_cnt].Unit := i_conf_unit;
        io_locks[io_lock_cnt].Stage := prev_conf_stage;
        io_locks[io_lock_cnt].Direction := 2;
      END_IF;

      IF remain <= 0.1 THEN
        o_solved := TRUE;
        RETURN;
      END_IF;
    END_IF;
  END_IF;
END_IF;

(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 4: DELAY_PREV_PAST_NEXT — delay blocked batch to       *)
(* force order swap (JS Vaihe 4)                                *)
(* Only if NOT swappable: prev.sink ≠ next.lift                 *)
(* ══════════════════════════════════════════════════════════════ *)
IF remain > 0.1 AND i_blocked_unit >= 1 AND i_blocked_unit <= MAX_Units THEN
  (* Find blocked and conf tasks in queue to check swap condition *)
  prev_sink_stn := 0;
  next_lift_stn := 0;
  IF i_conf_trans >= 1 AND i_conf_trans <= MAX_Transporters THEN
    FOR qi := 1 TO g_task[i_conf_trans].Count DO
      IF g_task[i_conf_trans].Queue[qi].Unit = i_blocked_unit
         AND g_task[i_conf_trans].Queue[qi].Stage = i_blocked_stage THEN
        prev_sink_stn := g_task[i_conf_trans].Queue[qi].SinkStationTarget;
      END_IF;
      IF g_task[i_conf_trans].Queue[qi].Unit = i_conf_unit
         AND g_task[i_conf_trans].Queue[qi].Stage = i_conf_stage THEN
        next_lift_stn := g_task[i_conf_trans].Queue[qi].LiftStationTarget;
      END_IF;
    END_FOR;
  END_IF;

  (* Swap check: if prev.sink = next.lift → swappable, skip *)
  IF NOT (prev_sink_stn > 0 AND next_lift_stn > 0 AND prev_sink_stn = next_lift_stn) THEN
    (* Check lock: is blocked stage locked ADVANCE? → cannot DELAY *)
    is_blk_adv_locked := FALSE;
    FOR lock_i := 1 TO io_lock_cnt DO
      IF io_locks[lock_i].Unit = i_blocked_unit
         AND io_locks[lock_i].Stage = i_blocked_stage
         AND io_locks[lock_i].Direction = 1 THEN
        is_blk_adv_locked := TRUE;
      END_IF;
    END_FOR;

    IF NOT is_blk_adv_locked THEN
      stage_flex := DINT_TO_REAL(g_schedule[i_blocked_unit].Stages[i_blocked_stage].MaxTime
                  - g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime);
      IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

      IF stage_flex > 0.1 THEN
        IF g_batch[i_blocked_unit].CurStage = g_schedule[i_blocked_unit].Stages[i_blocked_stage].ProgramStage THEN
          cap := 0.9;
        ELSE
          cap := 0.5;
        END_IF;
        amount := stage_flex * cap;
        IF amount > remain THEN amount := remain; END_IF;

        g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime :=
          g_schedule[i_blocked_unit].Stages[i_blocked_stage].CalcTime + REAL_TO_DINT(amount);
        g_schedule[i_blocked_unit].Stages[i_blocked_stage].ExitTime :=
          g_schedule[i_blocked_unit].Stages[i_blocked_stage].ExitTime + REAL_TO_LINT(amount);
        fb_shift(i_unit := i_blocked_unit, i_from_stage := i_blocked_stage + 1, i_amount := amount);

        (* JS: propagateDelayToBatch updates batch.calc_time_s ONLY if batch is on this stage *)
        IF g_batch[i_blocked_unit].CurStage = g_schedule[i_blocked_unit].Stages[i_blocked_stage].ProgramStage THEN
          g_batch[i_blocked_unit].CalTime :=
            g_batch[i_blocked_unit].CalTime + REAL_TO_DINT(amount);
          IF g_batch[i_blocked_unit].CalTime > g_batch[i_blocked_unit].MaxTime THEN
            g_batch[i_blocked_unit].CalTime := g_batch[i_blocked_unit].MaxTime;
          END_IF;
        END_IF;

        remain := remain - amount;
        o_total_delay := o_total_delay + amount;

        (* Record lock: DELAY on blocked stage *)
        IF io_lock_cnt < 50 THEN
          io_lock_cnt := io_lock_cnt + 1;
          io_locks[io_lock_cnt].Unit := i_blocked_unit;
          io_locks[io_lock_cnt].Stage := i_blocked_stage;
          io_locks[io_lock_cnt].Direction := 2;
        END_IF;

        IF remain <= 0.1 THEN
          o_solved := TRUE;
          RETURN;
        END_IF;
      END_IF;
    END_IF;
  END_IF;
END_IF;

(* If not solved, partial resolution was applied *)

END_FUNCTION_BLOCK

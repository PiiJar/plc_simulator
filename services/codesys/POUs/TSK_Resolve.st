(* ===========================================================================================
 *  TSK_Resolve — Conflict resolution
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Four sequential resolution phases:
 *  1. ADVANCE (chain bottleneck + suffix flex_down)
 *  2. DELAY (single-stage flex_up)
 *  3. PRECEDING_DELAY (conf stage-1)
 *  4. DELAY_PREV_PAST_NEXT (force order swap)
 *
 *  VAR_IN_OUT: io_schedule, io_task, io_batch, io_locks,
 *  io_lock_cnt — caller passes live or workspace arrays.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION TSK_Resolve : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_conf_unit               : INT;
  i_conf_stage              : INT;
  i_conf_trans              : INT;
  i_blocked_unit            : INT;
  i_blocked_stage           : INT;
  i_deficit                 : REAL;
END_VAR

VAR_IN_OUT
  io_locks                  : ARRAY[1..50] OF UDT_JC_TskLockType;
  io_lock_cnt               : INT;
  io_schedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  io_batch                  : ARRAY[1..10] OF UDT_BatchType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_Units               : INT;
END_VAR

VAR_OUTPUT
  o_solved                  : BOOL;
  o_total_delay             : REAL;
  o_total_adv               : REAL;
END_VAR

VAR
  remain                    : REAL;
  cap                       : REAL;
  amount                    : REAL;
  stage_flex                : REAL;
  is_locked_adv             : BOOL;
  is_locked_del             : BOOL;
  can_advance               : BOOL;
  can_delay                 : BOOL;
  lock_i                    : INT;
  prev_conf_stage           : INT;
  is_pcs_locked             : BOOL;
  prev_sink_stn             : INT;
  next_lift_stn             : INT;
  is_blk_adv_locked         : BOOL;
  qi                        : INT;
  chain_flex                : REAL;
  suffix_flex               : REAL;
  earlier_stg               : INT;
  earlier_flex              : REAL;
  chain_amount              : REAL;
  suffix_amount             : REAL;
  sched_blocked             : INT;
  sched_conf                : INT;
  sched_prev_conf           : INT;
  tmp_si                    : INT;
END_VAR

TSK_Resolve := FALSE;
o_solved      := FALSE;
o_total_delay := 0.0;
o_total_adv   := 0.0;
remain        := i_deficit;

IF remain <= 0.1 THEN
  o_solved := TRUE;
  TSK_Resolve := TRUE;
  RETURN;
END_IF;

(* Lock check: blocked stage locked DELAY? cannot ADVANCE *)
is_locked_adv := FALSE;
FOR lock_i := 1 TO io_lock_cnt DO
  IF io_locks[lock_i].Unit = i_blocked_unit
     AND io_locks[lock_i].Stage = i_blocked_stage
     AND io_locks[lock_i].Direction = 2 THEN
    is_locked_adv := TRUE;
  END_IF;
END_FOR;

(* Lock check: conf stage locked ADVANCE? cannot DELAY *)
is_locked_del := FALSE;
FOR lock_i := 1 TO io_lock_cnt DO
  IF io_locks[lock_i].Unit = i_conf_unit
     AND io_locks[lock_i].Stage = i_conf_stage
     AND io_locks[lock_i].Direction = 1 THEN
    is_locked_del := TRUE;
  END_IF;
END_FOR;

can_advance := NOT is_locked_adv;
can_delay   := NOT is_locked_del;

(* Map ProgramStage to schedule array index *)
sched_blocked := 0;
IF i_blocked_unit >= 1 AND i_blocked_unit <= MAX_Units THEN
  FOR tmp_si := 1 TO io_schedule[i_blocked_unit].StageCount DO
    IF io_schedule[i_blocked_unit].Stages[tmp_si].ProgramStage = i_blocked_stage THEN
  sched_blocked := tmp_si; EXIT;
    END_IF;
  END_FOR;
END_IF;

sched_conf := 0;
IF i_conf_unit >= 1 AND i_conf_unit <= MAX_Units THEN
  FOR tmp_si := 1 TO io_schedule[i_conf_unit].StageCount DO
    IF io_schedule[i_conf_unit].Stages[tmp_si].ProgramStage = i_conf_stage THEN
  sched_conf := tmp_si; EXIT;
    END_IF;
  END_FOR;
END_IF;

(* ================================================================ *)
(* PHASE 1: ADVANCE -- advance blocked batch                       *)
(* ================================================================ *)
IF can_advance
   AND i_blocked_unit >= 1 AND i_blocked_unit <= MAX_Units
   AND i_blocked_stage >= 1 THEN
IF sched_blocked >= 1 AND sched_blocked <= io_schedule[i_blocked_unit].StageCount THEN

  stage_flex := DINT_TO_REAL(
    io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime
    - io_schedule[i_blocked_unit].Stages[sched_blocked].MinTime);
  IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

  IF stage_flex > 0.1 THEN
    IF io_batch[i_blocked_unit].CurStage = i_blocked_stage THEN cap := 0.9;
  ELSE cap := 0.5; END_IF;

    (* Chain bottleneck search *)
    chain_flex := stage_flex;
    FOR earlier_stg := 1 TO sched_blocked - 1 DO
      earlier_flex := DINT_TO_REAL(
        io_schedule[i_blocked_unit].Stages[earlier_stg].CalcTime
        - io_schedule[i_blocked_unit].Stages[earlier_stg].MinTime);
  IF earlier_flex < 0.0 THEN earlier_flex := 0.0; END_IF;
      IF earlier_flex > 0.0 AND earlier_flex < chain_flex THEN
        chain_flex := earlier_flex;
      END_IF;
    END_FOR;

    (* CHAIN_ADVANCE *)
    chain_amount := chain_flex * cap;
  IF chain_amount > remain THEN chain_amount := remain; END_IF;

    IF chain_amount > 0.1 THEN
      io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime :=
        io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime - REAL_TO_DINT(chain_amount);
      io_schedule[i_blocked_unit].Stages[sched_blocked].ExitTime :=
        io_schedule[i_blocked_unit].Stages[sched_blocked].ExitTime - REAL_TO_LINT(chain_amount);

      STC_ShiftSchedule(i_unit := i_blocked_unit, i_from_stage := i_blocked_stage + 1,
                         i_amount := -chain_amount, io_schedule := io_schedule, io_task := io_task);

      io_batch[i_blocked_unit].CalTime :=
        io_batch[i_blocked_unit].CalTime - REAL_TO_DINT(chain_amount);
      IF io_batch[i_blocked_unit].CalTime < io_batch[i_blocked_unit].MinTime THEN
        io_batch[i_blocked_unit].CalTime := io_batch[i_blocked_unit].MinTime;
      END_IF;

      remain := remain - chain_amount;
      o_total_adv := o_total_adv + chain_amount;
    END_IF;

    (* SUFFIX_ADVANCE *)
    suffix_flex := stage_flex - chain_flex;
    IF suffix_flex > 0.1 AND remain > 0.1 THEN
      suffix_amount := suffix_flex * cap;
  IF suffix_amount > remain THEN suffix_amount := remain; END_IF;

      IF suffix_amount > 0.1 THEN
        io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime :=
          io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime - REAL_TO_DINT(suffix_amount);
        io_schedule[i_blocked_unit].Stages[sched_blocked].ExitTime :=
          io_schedule[i_blocked_unit].Stages[sched_blocked].ExitTime - REAL_TO_LINT(suffix_amount);

        STC_ShiftSchedule(i_unit := i_blocked_unit, i_from_stage := i_blocked_stage + 1,
                           i_amount := -suffix_amount, io_schedule := io_schedule, io_task := io_task);

        io_batch[i_blocked_unit].CalTime :=
          io_batch[i_blocked_unit].CalTime - REAL_TO_DINT(suffix_amount);
        IF io_batch[i_blocked_unit].CalTime < io_batch[i_blocked_unit].MinTime THEN
          io_batch[i_blocked_unit].CalTime := io_batch[i_blocked_unit].MinTime;
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
      io_locks[io_lock_cnt].Direction := 1;
    END_IF;

    IF remain <= 0.1 THEN
  o_solved := TRUE;
  TSK_Resolve := TRUE; RETURN;
    END_IF;
  END_IF;
END_IF;
END_IF;

(* ================================================================ *)
(* PHASE 2: DELAY -- delay conflict batch                          *)
(* ================================================================ *)
IF can_delay AND remain > 0.1
   AND i_conf_unit >= 1 AND i_conf_unit <= MAX_Units
   AND i_conf_stage >= 1 THEN
IF sched_conf >= 1 AND sched_conf <= io_schedule[i_conf_unit].StageCount THEN

  stage_flex := DINT_TO_REAL(
    io_schedule[i_conf_unit].Stages[sched_conf].MaxTime
    - io_schedule[i_conf_unit].Stages[sched_conf].CalcTime);
  IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

  IF stage_flex > 0.1 THEN
    IF io_batch[i_conf_unit].CurStage = i_conf_stage THEN cap := 0.9;
  ELSE cap := 0.5; END_IF;
    amount := stage_flex * cap;
  IF amount > remain THEN amount := remain; END_IF;

    io_schedule[i_conf_unit].Stages[sched_conf].CalcTime :=
      io_schedule[i_conf_unit].Stages[sched_conf].CalcTime + REAL_TO_DINT(amount);
    io_schedule[i_conf_unit].Stages[sched_conf].ExitTime :=
      io_schedule[i_conf_unit].Stages[sched_conf].ExitTime + REAL_TO_LINT(amount);

    STC_ShiftSchedule(i_unit := i_conf_unit, i_from_stage := i_conf_stage + 1,
                       i_amount := amount, io_schedule := io_schedule, io_task := io_task);

    IF io_batch[i_conf_unit].CurStage = i_conf_stage THEN
      io_batch[i_conf_unit].CalTime :=
        io_batch[i_conf_unit].CalTime + REAL_TO_DINT(amount);
      IF io_batch[i_conf_unit].CalTime > io_batch[i_conf_unit].MaxTime THEN
        io_batch[i_conf_unit].CalTime := io_batch[i_conf_unit].MaxTime;
      END_IF;
    END_IF;

    remain := remain - amount;
    o_total_delay := o_total_delay + amount;

    IF io_lock_cnt < 50 THEN
      io_lock_cnt := io_lock_cnt + 1;
      io_locks[io_lock_cnt].Unit := i_conf_unit;
      io_locks[io_lock_cnt].Stage := i_conf_stage;
      io_locks[io_lock_cnt].Direction := 2;
    END_IF;

    IF remain <= 0.1 THEN
  o_solved := TRUE;
  TSK_Resolve := TRUE; RETURN;
    END_IF;
  END_IF;
END_IF;
END_IF;

(* ================================================================ *)
(* PHASE 3: PRECEDING_DELAY -- delay conf batch at stage-1         *)
(* ================================================================ *)
prev_conf_stage := i_conf_stage - 1;

sched_prev_conf := 0;
IF i_conf_unit >= 1 AND i_conf_unit <= MAX_Units AND prev_conf_stage >= 1 THEN
  FOR tmp_si := 1 TO io_schedule[i_conf_unit].StageCount DO
    IF io_schedule[i_conf_unit].Stages[tmp_si].ProgramStage = prev_conf_stage THEN
  sched_prev_conf := tmp_si; EXIT;
    END_IF;
  END_FOR;
END_IF;

IF remain > 0.1 AND prev_conf_stage >= 1 AND i_conf_unit >= 1 AND i_conf_unit <= MAX_Units
   AND sched_prev_conf >= 1 THEN
  is_pcs_locked := FALSE;
  FOR lock_i := 1 TO io_lock_cnt DO
    IF io_locks[lock_i].Unit = i_conf_unit
       AND io_locks[lock_i].Stage = prev_conf_stage
       AND io_locks[lock_i].Direction = 1 THEN
      is_pcs_locked := TRUE;
    END_IF;
  END_FOR;

  IF NOT is_pcs_locked THEN
    stage_flex := DINT_TO_REAL(io_schedule[i_conf_unit].Stages[sched_prev_conf].MaxTime
                - io_schedule[i_conf_unit].Stages[sched_prev_conf].CalcTime);
  IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

    IF stage_flex > 0.1 THEN
      IF io_batch[i_conf_unit].CurStage = prev_conf_stage THEN cap := 0.9;
  ELSE cap := 0.5; END_IF;
      amount := stage_flex * cap;
  IF amount > remain THEN amount := remain; END_IF;

      io_schedule[i_conf_unit].Stages[sched_prev_conf].CalcTime :=
        io_schedule[i_conf_unit].Stages[sched_prev_conf].CalcTime + REAL_TO_DINT(amount);
      io_schedule[i_conf_unit].Stages[sched_prev_conf].ExitTime :=
        io_schedule[i_conf_unit].Stages[sched_prev_conf].ExitTime + REAL_TO_LINT(amount);
      STC_ShiftSchedule(i_unit := i_conf_unit, i_from_stage := prev_conf_stage + 1,
                         i_amount := amount, io_schedule := io_schedule, io_task := io_task);

      IF io_batch[i_conf_unit].CurStage = i_conf_stage THEN
        io_batch[i_conf_unit].CalTime :=
          io_batch[i_conf_unit].CalTime + REAL_TO_DINT(amount);
        IF io_batch[i_conf_unit].CalTime > io_batch[i_conf_unit].MaxTime THEN
          io_batch[i_conf_unit].CalTime := io_batch[i_conf_unit].MaxTime;
        END_IF;
      END_IF;

      remain := remain - amount;
      o_total_delay := o_total_delay + amount;

      IF io_lock_cnt < 50 THEN
        io_lock_cnt := io_lock_cnt + 1;
        io_locks[io_lock_cnt].Unit := i_conf_unit;
        io_locks[io_lock_cnt].Stage := prev_conf_stage;
        io_locks[io_lock_cnt].Direction := 2;
      END_IF;

      IF remain <= 0.1 THEN
  o_solved := TRUE;
  TSK_Resolve := TRUE; RETURN;
      END_IF;
    END_IF;
  END_IF;
END_IF;

(* ================================================================ *)
(* PHASE 4: DELAY_PREV_PAST_NEXT -- force order swap               *)
(* ================================================================ *)
IF remain > 0.1 AND i_blocked_unit >= 1 AND i_blocked_unit <= MAX_Units THEN
  prev_sink_stn := 0;
  next_lift_stn := 0;
  IF i_conf_trans >= 1 AND i_conf_trans <= MAX_Transporters THEN
    FOR qi := 1 TO io_task[i_conf_trans].Count DO
      IF io_task[i_conf_trans].Queue[qi].Unit = i_blocked_unit
         AND io_task[i_conf_trans].Queue[qi].Stage = i_blocked_stage THEN
        prev_sink_stn := io_task[i_conf_trans].Queue[qi].SinkStationTarget;
      END_IF;
      IF io_task[i_conf_trans].Queue[qi].Unit = i_conf_unit
         AND io_task[i_conf_trans].Queue[qi].Stage = i_conf_stage THEN
        next_lift_stn := io_task[i_conf_trans].Queue[qi].LiftStationTarget;
      END_IF;
    END_FOR;
  END_IF;

  IF NOT (prev_sink_stn > 0 AND next_lift_stn > 0 AND prev_sink_stn = next_lift_stn) THEN
    is_blk_adv_locked := FALSE;
    FOR lock_i := 1 TO io_lock_cnt DO
      IF io_locks[lock_i].Unit = i_blocked_unit
         AND io_locks[lock_i].Stage = i_blocked_stage
         AND io_locks[lock_i].Direction = 1 THEN
        is_blk_adv_locked := TRUE;
      END_IF;
    END_FOR;

    IF NOT is_blk_adv_locked THEN
      stage_flex := DINT_TO_REAL(io_schedule[i_blocked_unit].Stages[sched_blocked].MaxTime
                  - io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime);
  IF stage_flex < 0.0 THEN stage_flex := 0.0; END_IF;

      IF stage_flex > 0.1 THEN
        IF io_batch[i_blocked_unit].CurStage = i_blocked_stage THEN cap := 0.9;
  ELSE cap := 0.5; END_IF;
        amount := stage_flex * cap;
  IF amount > remain THEN amount := remain; END_IF;

        io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime :=
          io_schedule[i_blocked_unit].Stages[sched_blocked].CalcTime + REAL_TO_DINT(amount);
        io_schedule[i_blocked_unit].Stages[sched_blocked].ExitTime :=
          io_schedule[i_blocked_unit].Stages[sched_blocked].ExitTime + REAL_TO_LINT(amount);
        STC_ShiftSchedule(i_unit := i_blocked_unit, i_from_stage := i_blocked_stage + 1,
                           i_amount := amount, io_schedule := io_schedule, io_task := io_task);

        IF io_batch[i_blocked_unit].CurStage = i_blocked_stage THEN
          io_batch[i_blocked_unit].CalTime :=
            io_batch[i_blocked_unit].CalTime + REAL_TO_DINT(amount);
          IF io_batch[i_blocked_unit].CalTime > io_batch[i_blocked_unit].MaxTime THEN
            io_batch[i_blocked_unit].CalTime := io_batch[i_blocked_unit].MaxTime;
          END_IF;
        END_IF;

        remain := remain - amount;
        o_total_delay := o_total_delay + amount;

        IF io_lock_cnt < 50 THEN
          io_lock_cnt := io_lock_cnt + 1;
          io_locks[io_lock_cnt].Unit := i_blocked_unit;
          io_locks[io_lock_cnt].Stage := i_blocked_stage;
          io_locks[io_lock_cnt].Direction := 2;
        END_IF;

        IF remain <= 0.1 THEN
  o_solved := TRUE;
  TSK_Resolve := TRUE; RETURN;
        END_IF;
      END_IF;
    END_IF;
  END_IF;
END_IF;

END_FUNCTION

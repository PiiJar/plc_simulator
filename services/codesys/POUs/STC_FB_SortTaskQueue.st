(* ============================================================
   STC_FB_SortTaskQueue — Insertion sort task queues by priority
   ============================================================
   Sorts one or all transporter task queues in-place using
   insertion sort (stable, O(n²) — fine for n ≤ 10).

   Priority order (matches JS _compareTasksPriority):
     1. EMERGENCY tasks first (overtime ratio > 1.0)
        — both emergency → higher ratio first
     2. Normal tasks: earliest StartTime first

   Overtime ratio = (g_time_s - batch.StartTime) / batch.MaxTime
   Only computed when batch is IN_PROCESS at the task's lift station
   and batch.CurStage matches task.Stage.

   Mode controlled by i_trans:
     0   = sort ALL queues (1..3)
     1-3 = sort only that transporter's queue

   Replaces 3× duplicated insertion sort code in:
     TSK_FB_Scheduler (phase 2200)
     DEP_FB_Scheduler (phase 1020)
     TSK_FB_Analyze   (merge-sort variant — still inline)
   ============================================================ *)

FUNCTION_BLOCK STC_FB_SortTaskQueue
VAR_INPUT
  i_trans : INT;    (* 0 = all, 1..3 = specific transporter *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
END_VAR

VAR_EXTERNAL
  g_task     : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_batch    : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_unit     : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_schedule : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_time_s   : LINT;
END_VAR
VAR
  ti         : INT;
  t_start    : INT;
  t_end      : INT;
  ins_i      : INT;
  ins_j      : INT;
  ins_cnt    : INT;
  tmp_task   : UDT_JC_TskTaskType;
  tmp_unit   : INT;
  cur_unit   : INT;
  tmp_ratio  : REAL;
  cur_ratio  : REAL;
  tmp_emerg  : BOOL;
  cur_emerg  : BOOL;
  do_shift   : BOOL;
END_VAR

IF i_trans >= 1 AND i_trans <= 3 THEN
  t_start := i_trans;
  t_end   := i_trans;
ELSE
  t_start := 1;
  t_end   := 3;
END_IF;

FOR ti := t_start TO t_end DO
  ins_cnt := g_task[ti].Count;
  IF ins_cnt >= 2 THEN
    FOR ins_i := 2 TO ins_cnt DO
      tmp_task := g_task[ti].Queue[ins_i];

      (* ── Compute overtime ratio for the task being inserted ── *)
      tmp_ratio := 0.0;
      tmp_unit  := tmp_task.Unit;
      IF tmp_unit >= 1 AND tmp_unit <= MAX_Units THEN
        IF g_batch[tmp_unit].State = 1                                   (* IN_PROCESS *)
           AND tmp_task.Stage >= 1
           AND tmp_task.Stage <= g_schedule[tmp_unit].StageCount
           AND g_batch[tmp_unit].CurStage = g_schedule[tmp_unit].Stages[tmp_task.Stage].ProgramStage
           AND g_unit[tmp_unit].location = tmp_task.LiftStationTarget
           AND g_batch[tmp_unit].StartTime > LINT#0
           AND g_batch[tmp_unit].MaxTime > 0 THEN
          tmp_ratio := LINT_TO_REAL(g_time_s - g_batch[tmp_unit].StartTime)
                       / DINT_TO_REAL(g_batch[tmp_unit].MaxTime);
        END_IF;
      END_IF;
      tmp_emerg := tmp_ratio > 1.0;

      (* ── Insertion sort with emergency-aware comparator ── *)
      ins_j := ins_i - 1;
      WHILE ins_j >= 1 DO
        (* Compute overtime ratio for the element at ins_j *)
        cur_ratio := 0.0;
        cur_unit  := g_task[ti].Queue[ins_j].Unit;
        IF cur_unit >= 1 AND cur_unit <= MAX_Units THEN
          IF g_batch[cur_unit].State = 1
             AND g_task[ti].Queue[ins_j].Stage >= 1
             AND g_task[ti].Queue[ins_j].Stage <= g_schedule[cur_unit].StageCount
             AND g_batch[cur_unit].CurStage = g_schedule[cur_unit].Stages[g_task[ti].Queue[ins_j].Stage].ProgramStage
             AND g_unit[cur_unit].location = g_task[ti].Queue[ins_j].LiftStationTarget
             AND g_batch[cur_unit].StartTime > LINT#0
             AND g_batch[cur_unit].MaxTime > 0 THEN
            cur_ratio := LINT_TO_REAL(g_time_s - g_batch[cur_unit].StartTime)
                         / DINT_TO_REAL(g_batch[cur_unit].MaxTime);
          END_IF;
        END_IF;
        cur_emerg := cur_ratio > 1.0;

        (* Decide: should Queue[ins_j] shift right to make room for tmp_task? *)
        do_shift := FALSE;
        IF tmp_emerg AND NOT cur_emerg THEN
          (* tmp is emergency, cur is not → tmp goes first *)
          do_shift := TRUE;
        ELSIF tmp_emerg AND cur_emerg THEN
          (* both emergency → higher ratio first *)
          IF tmp_ratio > cur_ratio THEN
            do_shift := TRUE;
          END_IF;
        ELSIF NOT tmp_emerg AND NOT cur_emerg THEN
          (* normal order: earlier StartTime first *)
          IF g_task[ti].Queue[ins_j].StartTime > tmp_task.StartTime THEN
            do_shift := TRUE;
          END_IF;
        (* ELSE: cur is emergency, tmp is not → cur stays, stop *)
        END_IF;

        IF NOT do_shift THEN EXIT; END_IF;

        g_task[ti].Queue[ins_j + 1] := g_task[ti].Queue[ins_j];
        ins_j := ins_j - 1;
      END_WHILE;

      g_task[ti].Queue[ins_j + 1] := tmp_task;
    END_FOR;
  END_IF;
END_FOR;

END_FUNCTION_BLOCK

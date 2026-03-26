(* ===========================================================================================
 *  STC_SortTasks — Insertion sort task queues by priority
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Shared FC: both TSK and DEP call this with different arrays.
 *  Priority: emergency (overtime ratio > 1.0) first, then
 *  earliest StartTime.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_SortTasks : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_trans                   : INT;    (* 0 = all, 1..3 = specific transporter *)
  i_time_s                  : LINT;
END_VAR

VAR_IN_OUT
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  io_batch                  : ARRAY[1..10] OF UDT_BatchType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_Units               : INT;
END_VAR

VAR_EXTERNAL
  g_unit                    : ARRAY[1..MAX_Units] OF UDT_UnitType;
END_VAR

VAR
  ti                        : INT;
  t_start                   : INT;
  t_end                     : INT;
  ins_i                     : INT;
  ins_j                     : INT;
  ins_cnt                   : INT;
  tmp_task                  : UDT_JC_TskTaskType;
  tmp_unit                  : INT;
  cur_unit                  : INT;
  tmp_ratio                 : REAL;
  cur_ratio                 : REAL;
  tmp_emerg                 : BOOL;
  cur_emerg                 : BOOL;
  do_shift                  : BOOL;
END_VAR

STC_SortTasks := TRUE;

IF i_trans >= 1 AND i_trans <= 3 THEN
  t_start := i_trans;
  t_end   := i_trans;
ELSE
  t_start := 1;
  t_end   := 3;
END_IF;

FOR ti := t_start TO t_end DO
  ins_cnt := io_task[ti].Count;
  IF ins_cnt >= 2 THEN
    FOR ins_i := 2 TO ins_cnt DO
      tmp_task := io_task[ti].Queue[ins_i];

      tmp_ratio := 0.0;
      tmp_unit  := tmp_task.Unit;
      IF tmp_unit >= 1 AND tmp_unit <= MAX_Units THEN
        IF io_batch[tmp_unit].State = 1
           AND tmp_task.Stage >= 1 THEN
          IF io_batch[tmp_unit].CurStage = tmp_task.Stage
             AND g_unit[tmp_unit].location = tmp_task.LiftStationTarget
             AND io_batch[tmp_unit].StartTime > LINT#0
             AND io_batch[tmp_unit].MaxTime > 0 THEN
            tmp_ratio := LINT_TO_REAL(i_time_s - io_batch[tmp_unit].StartTime)
                         / DINT_TO_REAL(io_batch[tmp_unit].MaxTime);
          END_IF;
        END_IF;
      END_IF;
      tmp_emerg := tmp_ratio > 1.0;

      ins_j := 0;
      FOR ins_j := ins_i - 1 TO 1 BY -1 DO
        cur_ratio := 0.0;
        cur_unit  := io_task[ti].Queue[ins_j].Unit;
        IF cur_unit >= 1 AND cur_unit <= MAX_Units THEN
          IF io_batch[cur_unit].State = 1
             AND io_task[ti].Queue[ins_j].Stage >= 1 THEN
            IF io_batch[cur_unit].CurStage = io_task[ti].Queue[ins_j].Stage
               AND g_unit[cur_unit].location = io_task[ti].Queue[ins_j].LiftStationTarget
               AND io_batch[cur_unit].StartTime > LINT#0
               AND io_batch[cur_unit].MaxTime > 0 THEN
              cur_ratio := LINT_TO_REAL(i_time_s - io_batch[cur_unit].StartTime)
                           / DINT_TO_REAL(io_batch[cur_unit].MaxTime);
            END_IF;
          END_IF;
        END_IF;
        cur_emerg := cur_ratio > 1.0;

        do_shift := FALSE;
        IF tmp_emerg AND NOT cur_emerg THEN
          do_shift := TRUE;
        ELSIF tmp_emerg AND cur_emerg THEN
          IF tmp_ratio > cur_ratio THEN
            do_shift := TRUE;
          END_IF;
        ELSIF NOT tmp_emerg AND NOT cur_emerg THEN
          IF io_task[ti].Queue[ins_j].StartTime > tmp_task.StartTime THEN
            do_shift := TRUE;
          END_IF;
        END_IF;

        IF NOT do_shift THEN EXIT; END_IF;

        io_task[ti].Queue[ins_j + 1] := io_task[ti].Queue[ins_j];
      END_FOR;

      io_task[ti].Queue[ins_j + 1] := tmp_task;
    END_FOR;
  END_IF;
END_FOR;

END_FUNCTION

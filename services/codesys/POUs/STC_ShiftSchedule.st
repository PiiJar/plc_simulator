(* ===========================================================================================
 *  STC_ShiftSchedule — Shift schedule + task times
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Propagates a time shift through one unit's schedule stages
 *  AND through all matching tasks.
 *
 *  Positive i_amount = DELAY (shift later),
 *  Negative i_amount = ADVANCE (shift earlier).
 *
 *  VAR_IN_OUT: io_schedule, io_task — caller passes live or
 *  workspace arrays.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_ShiftSchedule : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_unit                    : INT;     (* unit index 1..10 *)
  i_from_stage              : INT;     (* propagate from this stage onward *)
  i_amount                  : REAL;    (* seconds to shift (+ = later, - = earlier) *)
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 10=MAX_Units, 3=MAX_Transporters *)
  io_schedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_Units               : INT;
END_VAR

VAR_EXTERNAL
  g_time_s                  : LINT;
END_VAR

VAR
  sc                        : INT;
  si                        : INT;
  qi                        : INT;
  ti                        : INT;
  duration                  : LINT;
END_VAR

STC_ShiftSchedule := TRUE;
IF i_unit < 1 OR i_unit > MAX_Units THEN RETURN; END_IF;
IF ABS(i_amount) < 0.001 THEN RETURN; END_IF;

(* -- Shift schedule stages entry/exit times -- *)
sc := io_schedule[i_unit].StageCount;
FOR si := 1 TO sc DO
  IF si >= 1 AND si <= 30
     AND io_schedule[i_unit].Stages[si].ProgramStage >= i_from_stage THEN
    io_schedule[i_unit].Stages[si].EntryTime :=
      io_schedule[i_unit].Stages[si].EntryTime + REAL_TO_LINT(i_amount);
    io_schedule[i_unit].Stages[si].ExitTime :=
      io_schedule[i_unit].Stages[si].ExitTime + REAL_TO_LINT(i_amount);
    (* GAP-3: Past-clamp -- don't let EntryTime go before now+1 *)
    IF i_amount < 0.0 AND io_schedule[i_unit].Stages[si].EntryTime < g_time_s + LINT#1 THEN
      io_schedule[i_unit].Stages[si].ExitTime := g_time_s + LINT#1
        + (io_schedule[i_unit].Stages[si].ExitTime - io_schedule[i_unit].Stages[si].EntryTime);
      io_schedule[i_unit].Stages[si].EntryTime := g_time_s + LINT#1;
    END_IF;
  END_IF;
END_FOR;

(* -- Shift matching tasks in all transporter queues -- *)
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO io_task[ti].Count DO
    IF io_task[ti].Queue[qi].Unit = i_unit
       AND io_task[ti].Queue[qi].Stage >= i_from_stage THEN
      io_task[ti].Queue[qi].StartTime :=
        io_task[ti].Queue[qi].StartTime + REAL_TO_LINT(i_amount);
      io_task[ti].Queue[qi].FinishTime :=
        io_task[ti].Queue[qi].FinishTime + REAL_TO_LINT(i_amount);
      (* GAP-3: Past-clamp -- don't let StartTime go before now+1 *)
      IF i_amount < 0.0 AND io_task[ti].Queue[qi].StartTime < g_time_s + LINT#1 THEN
        duration := io_task[ti].Queue[qi].FinishTime - io_task[ti].Queue[qi].StartTime;
        io_task[ti].Queue[qi].StartTime := g_time_s + LINT#1;
        io_task[ti].Queue[qi].FinishTime := g_time_s + LINT#1 + duration;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

END_FUNCTION

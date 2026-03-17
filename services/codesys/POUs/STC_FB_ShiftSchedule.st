(* ============================================================
   STC_FB_ShiftSchedule — Shift schedule + task times
   ============================================================
   Propagates a time shift through one unit's schedule stages
   AND through all matching tasks in the 3 transporter queues.

   Positive i_amount = DELAY (shift later),
   Negative i_amount = ADVANCE (shift earlier).

   Replaces 4× duplicated propagation code in TSK_FB_Resolve.
   ============================================================ *)

FUNCTION_BLOCK STC_FB_ShiftSchedule
VAR_INPUT
  i_unit       : INT;     (* unit index 1..10 *)
  i_from_stage : INT;     (* propagate from this stage onward *)
  i_amount     : REAL;    (* seconds to shift (+ = later, - = earlier) *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
END_VAR

VAR_EXTERNAL
  g_schedule : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_task     : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_time_s   : LINT;
END_VAR
VAR
  sc       : INT;
  si       : INT;
  qi       : INT;
  ti       : INT;
  duration : LINT;
END_VAR

IF i_unit < 1 OR i_unit > MAX_Units THEN RETURN; END_IF;
IF ABS(i_amount) < 0.001 THEN RETURN; END_IF;

(* ── Shift schedule stages entry/exit times ── *)
sc := g_schedule[i_unit].StageCount;
FOR si := i_from_stage TO sc DO
  IF si >= 1 AND si <= 30 THEN
    g_schedule[i_unit].Stages[si].EntryTime :=
      g_schedule[i_unit].Stages[si].EntryTime + REAL_TO_LINT(i_amount);
    g_schedule[i_unit].Stages[si].ExitTime :=
      g_schedule[i_unit].Stages[si].ExitTime + REAL_TO_LINT(i_amount);
    (* GAP-3: Past-clamp — don't let EntryTime go before now+1 *)
    IF i_amount < 0.0 AND g_schedule[i_unit].Stages[si].EntryTime < g_time_s + LINT#1 THEN
      g_schedule[i_unit].Stages[si].ExitTime := g_time_s + LINT#1
        + (g_schedule[i_unit].Stages[si].ExitTime - g_schedule[i_unit].Stages[si].EntryTime);
      g_schedule[i_unit].Stages[si].EntryTime := g_time_s + LINT#1;
    END_IF;
  END_IF;
END_FOR;

(* ── Shift matching tasks in all transporter queues ── *)
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO g_task[ti].Count DO
    IF g_task[ti].Queue[qi].Unit = i_unit
       AND g_task[ti].Queue[qi].Stage >= i_from_stage THEN
      g_task[ti].Queue[qi].StartTime :=
        g_task[ti].Queue[qi].StartTime + REAL_TO_LINT(i_amount);
      g_task[ti].Queue[qi].FinishTime :=
        g_task[ti].Queue[qi].FinishTime + REAL_TO_LINT(i_amount);
      (* GAP-3: Past-clamp — don't let StartTime go before now+1 *)
      IF i_amount < 0.0 AND g_task[ti].Queue[qi].StartTime < g_time_s + LINT#1 THEN
        duration := g_task[ti].Queue[qi].FinishTime - g_task[ti].Queue[qi].StartTime;
        g_task[ti].Queue[qi].StartTime := g_time_s + LINT#1;
        g_task[ti].Queue[qi].FinishTime := g_time_s + LINT#1 + duration;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

END_FUNCTION_BLOCK

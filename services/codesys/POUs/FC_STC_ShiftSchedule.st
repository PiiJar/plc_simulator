(* ===========================================================================================
 *  FC_STC_ShiftSchedule — Shift schedule + task times
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Propagates a time shift through one unit's schedule stages
 *  AND through all matching tasks.
 *
 *  Positive iAmount = DELAY (shift later),
 *  Negative iAmount = ADVANCE (shift earlier).
 *
 *  VAR_IN_OUT: ioSchedule, ioTask — caller passes live or
 *  workspace arrays.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_ShiftSchedule : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iUnit                    : INT;     (* unit index 1..10 *)
  iFromStage              : INT;     (* propagate from this stage onward *)
  iAmount                  : REAL;    (* seconds to shift (+ = later, - = earlier) *)
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 10=MAX_UNITS, 3=MAX_TRANSPORTERS *)
  ioSchedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
END_VAR

VAR_EXTERNAL
  g_time_s                  : LINT;
END_VAR

VAR
  vSc                        : INT;
  vSi                        : INT;
  vQi                        : INT;
  vTi                        : INT;
  vDuration                  : LINT;
END_VAR

FC_STC_ShiftSchedule := TRUE;
IF iUnit < 1 OR iUnit > MAX_UNITS THEN RETURN; END_IF;
IF ABS(iAmount) < 0.001 THEN RETURN; END_IF;

(* -- Shift schedule stages entry/exit times -- *)
vSc := ioSchedule[iUnit].StageCount;
FOR vSi := 1 TO vSc DO
  IF vSi >= 1 AND vSi <= 30
     AND ioSchedule[iUnit].Stages[vSi].ProgramStage >= iFromStage THEN
    ioSchedule[iUnit].Stages[vSi].EntryTime :=
      ioSchedule[iUnit].Stages[vSi].EntryTime + REAL_TO_LINT(iAmount);
    ioSchedule[iUnit].Stages[vSi].ExitTime :=
      ioSchedule[iUnit].Stages[vSi].ExitTime + REAL_TO_LINT(iAmount);
    (* GAP-3: Past-clamp -- don't let EntryTime go before now+1 *)
    IF iAmount < 0.0 AND ioSchedule[iUnit].Stages[vSi].EntryTime < g_time_s + LINT#1 THEN
      ioSchedule[iUnit].Stages[vSi].ExitTime := g_time_s + LINT#1
        + (ioSchedule[iUnit].Stages[vSi].ExitTime - ioSchedule[iUnit].Stages[vSi].EntryTime);
      ioSchedule[iUnit].Stages[vSi].EntryTime := g_time_s + LINT#1;
    END_IF;
  END_IF;
END_FOR;

(* -- Shift matching tasks in all transporter queues -- *)
FOR vTi := 1 TO MAX_TRANSPORTERS DO
  FOR vQi := 1 TO ioTask[vTi].Count DO
    IF ioTask[vTi].Queue[vQi].Unit = iUnit
       AND ioTask[vTi].Queue[vQi].Stage >= iFromStage THEN
      ioTask[vTi].Queue[vQi].StartTime :=
        ioTask[vTi].Queue[vQi].StartTime + REAL_TO_LINT(iAmount);
      ioTask[vTi].Queue[vQi].FinishTime :=
        ioTask[vTi].Queue[vQi].FinishTime + REAL_TO_LINT(iAmount);
      (* GAP-3: Past-clamp -- don't let StartTime go before now+1 *)
      IF iAmount < 0.0 AND ioTask[vTi].Queue[vQi].StartTime < g_time_s + LINT#1 THEN
        vDuration := ioTask[vTi].Queue[vQi].FinishTime - ioTask[vTi].Queue[vQi].StartTime;
        ioTask[vTi].Queue[vQi].StartTime := g_time_s + LINT#1;
        ioTask[vTi].Queue[vQi].FinishTime := g_time_s + LINT#1 + vDuration;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

END_FUNCTION

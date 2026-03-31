(* ===========================================================================================
 *  DEP_FitTaskToSlot — Fit a departure task into idle slots
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Reads idle slots and move times.
 *  Returns fit result via VAR_OUTPUT.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION DEP_FitTaskToSlot : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_lift_stn                : INT;
  i_sink_stn                : INT;
  i_trans_id                : INT;
  i_task_start              : LINT;
  i_task_end                : LINT;
  i_shift_s                 : REAL;
  i_calc_time_s             : DINT;
  i_max_time_s              : DINT;
  i_flex_factor             : REAL;
  i_margin_s                : REAL;
  i_conflict_margin_s       : REAL;
END_VAR

VAR_IN_OUT
  io_idle_slot              : ARRAY[1..3] OF UDT_JC_DepIdleSlotSetType;
  o_result                  : UDT_JC_DepFitResultType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    DEP_MAX_IDLE_SLOTS      : INT;
    SCH_DISPATCH_MARGIN_S   : REAL;
END_VAR

VAR_EXTERNAL
  g_move                    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
END_VAR

VAR
  si                        : INT;
  slot_cnt                  : INT;
  slot_start                : LINT;
  slot_end                  : LINT;
  from_stn                  : INT;
  to_stn                    : INT;
  travel_to                 : REAL;
  travel_from               : REAL;
  earliest                  : LINT;
  latest                    : LINT;
  task_dur                  : LINT;
  delay                     : REAL;
  flex_up                   : REAL;
  capped_flex               : REAL;
  best_delay                : REAL;
  best_slot                 : INT;
  found                     : BOOL;
  overflow_best_delay       : REAL;
  overflow_best_slot        : INT;
  tmp_move                  : UDT_JC_MoveTimesType;
  total_delay               : REAL;
END_VAR

o_result.Fits         := FALSE;
o_result.DelayTime    := 0;
o_result.NeedExtraTime := 0;
o_result.TaskEndTime  := 0;
o_result.SlotIdx      := 0;
o_result.OverflowSlotIdx := 0;
o_result.TransporterId := i_trans_id;
DEP_FitTaskToSlot := FALSE;

IF i_trans_id < 1 OR i_trans_id > MAX_Transporters THEN RETURN; END_IF;

task_dur   := i_task_end - i_task_start;
flex_up    := DINT_TO_REAL(i_max_time_s - i_calc_time_s);
  IF flex_up < 0.0 THEN flex_up := 0.0; END_IF;
capped_flex := flex_up * i_flex_factor;

slot_cnt   := io_idle_slot[i_trans_id].Count;
best_delay := 1.0E9;
best_slot  := 0;
found      := FALSE;
overflow_best_delay := 1.0E9;
overflow_best_slot  := 0;

tmp_move := g_move[i_trans_id];
FOR si := 1 TO DEP_MAX_IDLE_SLOTS DO
  IF si > slot_cnt THEN EXIT; END_IF;

  slot_start := io_idle_slot[i_trans_id].Slots[si].StartTime;
  slot_end   := io_idle_slot[i_trans_id].Slots[si].EndTime;

  from_stn := io_idle_slot[i_trans_id].Slots[si].LiftStationTarget;
  travel_to := 0.0;
  IF from_stn > 0 AND from_stn <> i_lift_stn THEN
    travel_to := STC_CalcHorizontalTravel(i_from_stn := from_stn, i_to_stn := i_lift_stn, i_move := tmp_move);
  END_IF;

  to_stn := io_idle_slot[i_trans_id].Slots[si].SinkStationTarget;
  travel_from := 0.0;
  IF to_stn > 0 AND to_stn <> i_sink_stn THEN
    travel_from := STC_CalcHorizontalTravel(i_from_stn := i_sink_stn, i_to_stn := to_stn, i_move := tmp_move);
  END_IF;

  (* earliest = max(transporter arrival, task readiness) + conflict margin *)
  IF (slot_start + REAL_TO_LINT(travel_to)) > (i_task_start + REAL_TO_LINT(i_shift_s)) THEN
    earliest := slot_start + REAL_TO_LINT(travel_to + i_conflict_margin_s);
  ELSE
    earliest := i_task_start + REAL_TO_LINT(i_shift_s + i_conflict_margin_s);
  END_IF;

  IF slot_end > LINT#9000000000 THEN
    latest := LINT#9000000000;
  ELSE
    latest := slot_end - REAL_TO_LINT(travel_from + SCH_DISPATCH_MARGIN_S);
  END_IF;

  IF earliest + task_dur <= latest THEN
    delay := LINT_TO_REAL(earliest - i_task_start) - i_shift_s;
  IF delay < 0.0 THEN delay := 0.0; END_IF;
    total_delay := i_shift_s + delay;

    IF total_delay <= i_margin_s OR total_delay <= capped_flex + 1.0 THEN
      IF delay < best_delay THEN
        best_delay := delay;
        best_slot  := si;
        found      := TRUE;
      END_IF;
    ELSE
      IF delay < overflow_best_delay THEN
        overflow_best_delay := delay;
        overflow_best_slot  := si;
      END_IF;
    END_IF;
  END_IF;
END_FOR;

IF found THEN
  o_result.Fits      := TRUE;
  o_result.DelayTime := REAL_TO_DINT(best_delay);
  o_result.SlotIdx   := best_slot;
  o_result.TaskEndTime := i_task_start + REAL_TO_LINT(i_shift_s + best_delay) + task_dur;
  o_result.NeedExtraTime := 0;
ELSE
  o_result.Fits := FALSE;
  IF overflow_best_delay < 1.0E8 THEN
    o_result.DelayTime     := REAL_TO_DINT(overflow_best_delay);
    o_result.NeedExtraTime := REAL_TO_DINT(i_shift_s + overflow_best_delay - capped_flex);
  IF o_result.NeedExtraTime < 0 THEN o_result.NeedExtraTime := 0; END_IF;
    o_result.OverflowSlotIdx := overflow_best_slot;
  ELSE
    o_result.NeedExtraTime := 0;
  END_IF;
END_IF;

DEP_FitTaskToSlot := TRUE;

END_FUNCTION

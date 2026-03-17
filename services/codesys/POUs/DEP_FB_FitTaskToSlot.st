(* ============================================================
   DEP_FB_FitTaskToSlot — Fit a departure task into idle slots
   ============================================================
   Tries to fit a single waiting-batch task into the idle slots
   of its assigned transporter.  Calculates travel times from
   the previous task's sink to this task's lift, and from this
   task's sink to the next task's lift.

   Source: transporterTaskScheduler.js fitSingleTaskToIdleSlots()

   Flex constraint: delay cannot exceed flex_up × flexUpFactor.
   If no slot fits, o_need_extra_s reports the shortfall for
   backward chaining.

   Used by: DEP_FB_Scheduler (CHECK_ANALYZE phase)
   ============================================================ *)

FUNCTION_BLOCK DEP_FB_FitTaskToSlot
VAR_INPUT
  i_lift_stn     : INT;     (* task lift station *)
  i_sink_stn     : INT;     (* task sink station *)
  i_trans_id     : INT;     (* transporter for this task *)
  i_task_start   : LINT;    (* scheduled task start time (s), unix seconds *)
  i_task_end     : LINT;    (* scheduled task end time (s), unix seconds *)
  i_shift_s      : REAL;    (* pre-applied shift (overlap delay) *)
  i_calc_time_s  : DINT;    (* treatment calc_time (s) *)
  i_max_time_s   : DINT;    (* treatment max_time (s) *)
  i_flex_factor  : REAL;    (* flex_up usage factor, e.g. 0.5 *)
  i_margin_s     : REAL;    (* delay significance threshold (s) *)
  i_conflict_margin_s : REAL; (* slot boundary margin (s), typ. 1.0 *)
END_VAR
VAR_OUTPUT
  o_result : UDT_JC_DepFitResultType;
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters   : INT;
    DEP_MAX_IDLE_SLOTS : INT;
END_VAR

VAR_EXTERNAL
  g_dep_idle_slot : ARRAY[1..MAX_Transporters] OF UDT_JC_DepIdleSlotSetType;
  g_move          : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
END_VAR
VAR
  si          : INT;
  slot_cnt    : INT;
  slot_start  : LINT;
  slot_end    : LINT;
  from_stn    : INT;    (* previous task's sink or transporter home *)
  to_stn      : INT;    (* next task's lift *)
  travel_to   : REAL;   (* travel time: prev_sink → this lift *)
  travel_from : REAL;   (* travel time: this sink → next_lift *)
  earliest    : LINT;
  latest      : LINT;
  task_dur    : LINT;
  delay       : REAL;
  flex_up     : REAL;
  capped_flex : REAL;
  best_delay  : REAL;
  best_slot   : INT;
  found       : BOOL;
  overflow_best_delay : REAL;   (* best delay among flex-overflow slots *)
  overflow_best_slot  : INT;
  tmp_move    : UDT_JC_MoveTimesType;  (* MATIEC cannot index arrays in FUNCTION args *)
END_VAR

(* Initialize output *)
o_result.Fits         := FALSE;
o_result.DelayTime      := 0;
o_result.NeedExtraTime := 0;
o_result.TaskEndTime   := 0;
o_result.SlotIdx     := 0;
o_result.TransporterId     := i_trans_id;

IF i_trans_id < 1 OR i_trans_id > MAX_Transporters THEN
  RETURN;
END_IF;

task_dur   := i_task_end - i_task_start;
flex_up    := DINT_TO_REAL(i_max_time_s - i_calc_time_s);
IF flex_up < 0.0 THEN flex_up := 0.0; END_IF;
capped_flex := flex_up * i_flex_factor;

slot_cnt   := g_dep_idle_slot[i_trans_id].Count;
best_delay := 1.0E9;
best_slot  := 0;
found      := FALSE;
overflow_best_delay := 1.0E9;
overflow_best_slot  := 0;

tmp_move := g_move[i_trans_id];
FOR si := 1 TO DEP_MAX_IDLE_SLOTS DO
  IF si > slot_cnt THEN
    EXIT;
  END_IF;

  slot_start := g_dep_idle_slot[i_trans_id].Slots[si].StartTime;
  slot_end   := g_dep_idle_slot[i_trans_id].Slots[si].EndTime;

  (* ── Travel time: prev task sink → this lift ── *)
  from_stn := g_dep_idle_slot[i_trans_id].Slots[si].LiftStationTarget;
  travel_to := 0.0;
  IF from_stn > 0 AND from_stn <> i_lift_stn THEN
    travel_to := STC_CalcHorizontalTravel(i_from_stn := from_stn, i_to_stn := i_lift_stn, i_move := tmp_move);
  END_IF;

  (* ── Travel time: this sink → next task lift ── *)
  to_stn := g_dep_idle_slot[i_trans_id].Slots[si].SinkStationTarget;
  travel_from := 0.0;
  IF to_stn > 0 AND to_stn <> i_sink_stn THEN
    travel_from := STC_CalcHorizontalTravel(i_from_stn := i_sink_stn, i_to_stn := to_stn, i_move := tmp_move);
  END_IF;

  (* Earliest start = max(slot_start, task_start + shift) + travel_to + conflict_margin *)
  IF slot_start > (i_task_start + REAL_TO_LINT(i_shift_s)) THEN
    earliest := slot_start + REAL_TO_LINT(travel_to + i_conflict_margin_s);
  ELSE
    earliest := i_task_start + REAL_TO_LINT(i_shift_s + travel_to + i_conflict_margin_s);
  END_IF;

  (* Latest end = slot_end - travel_from - conflict_margin *)
  IF slot_end > LINT#9000000000 THEN
    (* Open-ended slot *)
    latest := LINT#9000000000;
  ELSE
    latest := slot_end - REAL_TO_LINT(travel_from + i_conflict_margin_s);
  END_IF;

  (* Check if task fits *)
  IF earliest + task_dur <= latest THEN
    delay := LINT_TO_REAL(earliest - i_task_start) - i_shift_s;
    IF delay < 0.0 THEN delay := 0.0; END_IF;

    (* Flex constraint: small delays always OK; larger must be within flex + 1s *)
    IF delay <= i_margin_s OR delay <= capped_flex + 1.0 THEN
      IF delay < best_delay THEN
        best_delay := delay;
        best_slot  := si;
        found      := TRUE;
      END_IF;
    ELSE
      (* Flex overflow — track separately for backward chaining *)
      IF delay < overflow_best_delay THEN
        overflow_best_delay := delay;
        overflow_best_slot  := si;
      END_IF;
    END_IF;
  END_IF;
END_FOR;

IF found THEN
  o_result.Fits      := TRUE;
  o_result.DelayTime   := REAL_TO_DINT(best_delay);
  o_result.SlotIdx  := best_slot;
  o_result.TaskEndTime := i_task_start + REAL_TO_LINT(i_shift_s + best_delay) + task_dur;
  o_result.NeedExtraTime := 0;
ELSE
  (* Report how much extra is needed for backward chaining *)
  o_result.Fits := FALSE;
  IF overflow_best_delay < 1.0E8 THEN
    (* Overflow slot found — report shortfall beyond capped flex *)
    o_result.DelayTime      := REAL_TO_DINT(overflow_best_delay);
    o_result.NeedExtraTime := REAL_TO_DINT(overflow_best_delay - capped_flex);
    IF o_result.NeedExtraTime < 0 THEN
      o_result.NeedExtraTime := 0;
    END_IF;
  ELSE
    (* No slot at all *)
    o_result.NeedExtraTime := 0;
  END_IF;
END_IF;

END_FUNCTION_BLOCK

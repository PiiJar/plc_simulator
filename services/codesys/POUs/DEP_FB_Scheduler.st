(* ============================================================
   DEP_FB_Scheduler — Departure scheduler state machine
   ============================================================
   Ported from departureScheduler.js tick()

   Controls batch activation: waiting batches (state=NOT_PROCESSED)
   are checked against idle slots to see if their tasks fit into
   the existing transporter schedule without conflicts.

   Uses the "wrapper approach": works directly on globals while
   TSK is paused at phase >= 10000. Sandbox is a backup for
   rollback on REJECT.

   Phase flow:
     0      STOPPED
     1      WAIT_STABLE       (wait for TSK phase >= 10000)
     100    INIT              (snapshot, find waiting batches)
     200    CALC_OVERLAP      (compute overlap stations)
     1000   BATCH_START       (prepare current waiting batch)
     1010   CALC_SCHED        (calculate waiting batch schedule)
     1020   CLEAR_TASKS       (clear all task queues)
     1021   CREATE_TASKS      (create tasks, one batch per scan)
     1022   SORT_TASKS        (sort all queues)
     1023   SWAP_TASKS        (swap same-station pairs)
     1030   EXTRACT_WAIT      (extract waiting batch tasks)
     1040   CALC_IDLE         (calculate idle slots)
     2000   FIT_STAGE0        (check pickup fits in idle slot)
     2001   FIT_TASK          (check stage 1+ tasks)
     3000   APPLY_DELAY       (record delay → recalc loop)
     8000   ACTIVATE          (commit, set pending)
     8010   WAIT_SAVE         (wait for TSK to process)
     8020   END_DELAY         (stabilization ticks)
     8100   RESTART           (→ WAIT_STABLE)
     9000   REJECT            (restore sandbox, try next batch)
   ============================================================ *)

FUNCTION_BLOCK DEP_FB_Scheduler
VAR_INPUT
  i_run       : BOOL;     (* TRUE = run *)
  i_time_s    : LINT;     (* current absolute time (s), unix seconds *)
  i_tsk_phase : INT;      (* TSK_FB_Scheduler.o_phase *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters   : INT;
    MAX_Units          : INT;
    DEP_MAX_WAITING    : INT;
    DEP_MAX_IDLE_SLOTS : INT;
    MIN_StationIndex   : INT;
    MAX_StationIndex   : INT;
END_VAR

VAR_EXTERNAL
  g_batch          : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_unit            : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_program         : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_schedule         : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_task            : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_station          : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_cfg              : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_transporter      : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_dep_sandbox      : UDT_JC_DepSandboxType;
  g_dep_idle_slot   : ARRAY[1..MAX_Transporters] OF UDT_JC_DepIdleSlotSetType;
  g_dep_overlap      : UDT_JC_DepOverlapType;
  g_dep_pending      : UDT_JC_DepPendingWriteType;
  g_dep_activated    : BOOL;
  g_dep_stable       : BOOL;
  g_move              : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_dep_waiting      : ARRAY[1..DEP_MAX_WAITING] OF INT;
  g_dep_waiting_count : INT;
  g_dep_wait_sched    : UDT_JC_TskScheduleType;
  g_dep_wait_unit     : INT;
END_VAR
VAR_OUTPUT
  o_phase     : INT;
  o_wait_cnt  : INT;      (* waiting batch count *)
  o_activated : BOOL;     (* batch activated this cycle *)
  o_reject_cnt    : INT;  (* how many batches rejected this cycle *)
  o_fit_round     : INT;  (* current fit round counter *)
  o_cur_wait_unit : INT;  (* which unit is being evaluated *)
END_VAR
VAR
  phase       : INT := 0;
  next_phase  : INT;

  (* ── Waiting batch management ── *)
  waiting_list  : ARRAY[1..MAX_Units] OF INT;  (* unit indices with state=NOT_PROCESSED *)
  waiting_cnt   : INT;
  cur_wait_idx  : INT;
  cur_wait_unit : INT;

  (* ── Active batch list for rebuild ── *)
  batch_list    : ARRAY[1..MAX_Units] OF INT;
  batch_count   : INT;
  create_idx    : INT;    (* index into batch_list for per-scan create *)

  (* ── Extracted waiting batch tasks ── *)
  w_tasks       : ARRAY[1..30] OF UDT_JC_TskTaskType;
  w_trans       : ARRAY[1..30] OF INT;    (* transporter id per task *)
  w_task_cnt    : INT;
  cur_task_idx  : INT;

  (* ── Fit state ── *)
  fit_round      : INT;
  MAX_FIT_ROUNDS : INT := 50;
  sched_base_time : LINT;        (* adjusted base time for waiting batch *)

  (* ── Delay recording ── *)
  delay_stage  : INT;
  delay_amount : REAL;
  delay_target : INT;            (* 0=batch/stage0, 1=program stage *)

  (* ── Constants ── *)
  FLEX_FACTOR       : REAL := 0.5;
  MARGIN_S          : REAL := 5.0;
  CONFLICT_MARGIN_S : REAL := 1.0;
  MAX_INIT_WAIT_S   : REAL := 120.0;
  END_DELAY_TICKS   : INT := 100;

  (* ── End delay counter ── *)
  end_delay_cnt : INT;

  (* ── Sub-FB instances ── *)
  fb_sandbox      : DEP_FB_Sandbox;
  fb_overlap      : DEP_FB_CalcOverlap;
  fb_idle_slots   : DEP_FB_CalcIdleSlots;
  fb_fit          : DEP_FB_FitTaskToSlot;
  fb_ovlp_delay   : DEP_FB_OverlapDelay;
  fb_calc_sched   : TSK_FB_CalcSchedule;
  fb_create_tasks : TSK_FB_CreateTasks;
  fb_swap_tasks   : TSK_FB_SwapTasks;
  fb_clear        : STC_FB_ClearTaskQueues;
  fb_sort         : STC_FB_SortTaskQueue;
  fb_collect_all  : STC_FB_CollectActiveBatches;
  fb_collect_wait : STC_FB_CollectActiveBatches;
  fb_find         : STC_FindTransporter;

  (* ── Temp variables ── *)
  ti : INT;
  qi : INT;
  bi : INT;
  ui : INT;
  si : INT;
  sched_trans   : INT;
  tmp_move       : UDT_JC_MoveTimesType;  (* temp for g_move[sched_trans] *)
  write_idx     : INT;
  loading_stn   : INT;
  first_stn     : INT;
  xfer_dur      : REAL;
  stage0_delay  : REAL;
  stage0_ovlp   : REAL;     (* G10: stage 0 overlap delay *)
  stage0_pending_delay : REAL;  (* G04: deferred stage 0 delay *)
  ovlp_delay_s  : REAL;
  total_delay_s : REAL;
  prog_idx      : INT;
  old_cal       : DINT;
  new_cal       : DINT;
  max_cal       : DINT;
  est_finish    : LINT;          (* G04: in-flight estimated finish time *)

  (* ── Stage 0 inline fit variables (matches JS inline code) ── *)
  s0_slot_si       : INT;
  s0_slot_cnt      : INT;
  s0_slot_start    : LINT;
  s0_slot_end      : LINT;
  s0_travel_to     : REAL;     (* travel time: prev sink → pickup *)
  s0_travel_from   : REAL;     (* travel time: sink → next lift *)
  s0_earliest      : LINT;     (* earliest pickup = max(slot.start, now) + travel *)
  s0_task_dur      : LINT;
  s0_slot_fitted   : BOOL;
  s0_from_stn      : INT;
  s0_to_stn        : INT;

  (* ── G02: Backward chaining variables ── *)
  remaining_need   : REAL;
  chain_delays     : ARRAY[1..10] OF UDT_JC_DepDelayActionType;
  chain_delay_cnt  : INT;
  chain_ok         : BOOL;
  prev_flex_up     : REAL;
  prev_capped      : REAL;
  use_delay        : REAL;
  bk               : INT;     (* backward loop index *)
  ci               : INT;     (* chain apply loop index *)

  (* ── Prepend offset: 1 if CalcSchedule prepended loading station ── *)
  prepend_offset : INT;

  (* ── G06: Waiting list sort variables ── *)
  tmp_unit : INT;
  tmp_key  : LINT;
  ji       : INT;
END_VAR

IF NOT i_run THEN
  phase := 0;
  o_phase := 0;
  o_activated := FALSE;
  RETURN;
END_IF;

next_phase := phase;
o_activated := FALSE;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 0: STOPPED                                           *)
(* ════════════════════════════════════════════════════════════ *)
IF phase = 0 THEN
  next_phase := 1;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1: WAIT_STABLE                                       *)
(* Wait for TSK to be ready (phase >= 10000)                   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1 THEN
  IF i_tsk_phase >= 10000 AND g_dep_stable THEN
    next_phase := 100;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 100: INIT — snapshot sandbox, find waiting batches    *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 100 THEN
  (* Snapshot globals → sandbox (backup for rollback) *)
  fb_sandbox(i_cmd := 1);

  (* Find waiting batches (state = NOT_PROCESSED) *)
  fb_collect_wait(i_mode := 1);
  waiting_cnt := fb_collect_wait.o_count;
  FOR ui := 1 TO waiting_cnt DO
    waiting_list[ui] := fb_collect_wait.o_list[ui];
  END_FOR;

  o_wait_cnt := waiting_cnt;
  o_reject_cnt := 0;
  o_fit_round := 0;
  o_cur_wait_unit := 0;
  g_dep_waiting_count := waiting_cnt;
  FOR ui := 1 TO waiting_cnt DO
    g_dep_waiting[ui] := waiting_list[ui];
  END_FOR;

  (* Build active batch list for rebuild phases *)
  fb_collect_all(i_mode := 0);
  batch_count := fb_collect_all.o_count;
  FOR ui := 1 TO batch_count DO
    batch_list[ui] := fb_collect_all.o_list[ui];
  END_FOR;

  IF waiting_cnt = 0 THEN
    (* No waiting batches → back to waiting *)
    fb_sandbox(i_cmd := 3);   (* clear sandbox *)
    next_phase := 1;
  ELSE
    cur_wait_idx := 1;
    next_phase := 150;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 150: SORT_WAITING — FIFO sort by start_time (G06)     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 150 THEN
  (* Insertion sort waiting list by g_batch[unit].StartTime ascending *)
  FOR si := 2 TO waiting_cnt DO
    tmp_unit := waiting_list[si];
    tmp_key  := g_batch[tmp_unit].StartTime;
    ji := si - 1;
    WHILE ji >= 1 DO
      IF g_batch[waiting_list[ji]].StartTime > tmp_key THEN
        waiting_list[ji + 1] := waiting_list[ji];
        ji := ji - 1;
      ELSE
        EXIT;
      END_IF;
    END_WHILE;
    waiting_list[ji + 1] := tmp_unit;
  END_FOR;
  next_phase := 200;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 200: CALC_OVERLAP — compute overlap stations          *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 200 THEN
  fb_overlap();
  next_phase := 1000;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1000: BATCH_START — prepare current waiting batch     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1000 THEN
  IF cur_wait_idx > waiting_cnt THEN
    (* All batches processed, none activated → back to waiting *)
    fb_sandbox(i_cmd := 2);   (* restore globals from snapshot *)
    fb_sandbox(i_cmd := 3);   (* clear sandbox *)
    next_phase := 1;
  ELSE
    cur_wait_unit := waiting_list[cur_wait_idx];
    o_cur_wait_unit := cur_wait_unit;
    fit_round := 0;
    o_fit_round := 0;
    sched_base_time := i_time_s;
    stage0_pending_delay := 0.0;
    next_phase := 1010;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1010: CALC_SCHED — calculate waiting batch schedule   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1010 THEN
  (* Find transporter for this batch based on its location *)
  fb_find(i_lift_stn := g_unit[cur_wait_unit].location, i_sink_stn := 0);
  sched_trans := fb_find.o_trans;
  IF sched_trans = 0 THEN sched_trans := 1; END_IF;

  (* Calculate schedule using (possibly shifted) base time *)
  fb_calc_sched(
    i_unit   := cur_wait_unit,
    i_trans  := sched_trans,
    i_time_s := sched_base_time
  );

  next_phase := 1020;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1020: CLEAR_TASKS — clear all task queues             *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1020 THEN
  fb_clear();
  create_idx := 1;
  next_phase := 1021;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1021: CREATE_TASKS — one batch per scan               *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1021 THEN
  IF create_idx <= batch_count THEN
    fb_create_tasks(i_unit := batch_list[create_idx]);
    create_idx := create_idx + 1;
    next_phase := 1021;   (* stay until all active batches done *)
  ELSIF create_idx = batch_count + 1 THEN
    (* ★ FIX: Also create tasks for the current waiting batch,
       so phase 1030 EXTRACT_WAIT can find and separate them.
       JS: CHECK_CREATE_TASKS creates tasks from ALL schedules,
       then splits into existingTasks and waitingBatchTasks. *)
    fb_create_tasks(i_unit := cur_wait_unit);
    create_idx := create_idx + 1;
    next_phase := 1022;   (* waiting batch done → sort *)
  ELSE
    next_phase := 1022;   (* all batches created → sort *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1022: SORT_TASKS — sort all queues by start_time      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1022 THEN
  fb_sort(i_trans := 0);
  next_phase := 1023;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1023: SWAP_TASKS — swap same-station pairs            *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1023 THEN
  fb_swap_tasks();
  next_phase := 1030;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1030: EXTRACT_WAIT — extract waiting batch tasks      *)
(* Copy waiting batch's tasks to w_tasks[], remove from queues *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1030 THEN
  w_task_cnt := 0;

  FOR ti := 1 TO MAX_Transporters DO
    write_idx := 0;
    FOR qi := 1 TO g_task[ti].Count DO
      IF g_task[ti].Queue[qi].Unit = cur_wait_unit THEN
        (* Copy to waiting task array *)
        w_task_cnt := w_task_cnt + 1;
        IF w_task_cnt <= 30 THEN
          w_tasks[w_task_cnt] := g_task[ti].Queue[qi];
          w_trans[w_task_cnt] := ti;
        END_IF;
      ELSE
        (* Keep in queue — shift down *)
        write_idx := write_idx + 1;
        IF write_idx <> qi THEN
          g_task[ti].Queue[write_idx] := g_task[ti].Queue[qi];
        END_IF;
      END_IF;
    END_FOR;
    (* Clear remaining slots *)
    FOR qi := write_idx + 1 TO g_task[ti].Count DO
      g_task[ti].Queue[qi].Unit := 0;
    END_FOR;
    g_task[ti].Count := write_idx;
  END_FOR;

  (* ── G04: Inject in-flight pseudo-tasks for active transporters ── *)
  (* Matches JS: build inFlightTasks from transporter states.         *)
  (* When a transporter is executing a transfer (Phase 1-4), the      *)
  (* dispatched task is no longer in g_task[].Queue. We inject a      *)
  (* pseudo-task [now → est_finish] so idle-slot calculation sees     *)
  (* the transporter as occupied until the transfer completes.        *)
  FOR ti := 1 TO MAX_Transporters DO
    IF g_transporter[ti].Phase >= 1 AND g_transporter[ti].Phase <= 4 THEN
      est_finish := i_time_s + DINT_TO_LINT(g_transporter[ti].TaskRemainingTime);
      IF est_finish > i_time_s AND g_task[ti].Count < 10 THEN
        (* ★ FIX: Remove schedule-derived task matching in-flight transfer
           to avoid duplicate (JS: inFlightTasks replace schedule tasks) *)
        FOR qi := 1 TO g_task[ti].Count DO
          IF g_task[ti].Queue[qi].LiftStationTarget = g_transporter[ti].LiftStationTarget
             AND g_task[ti].Queue[qi].SinkStationTarget = g_transporter[ti].SinkStationTarget THEN
            FOR bi := qi TO g_task[ti].Count - 1 DO
              g_task[ti].Queue[bi] := g_task[ti].Queue[bi + 1];
            END_FOR;
            g_task[ti].Queue[g_task[ti].Count].Unit := 0;
            g_task[ti].Count := g_task[ti].Count - 1;
            EXIT;
          END_IF;
        END_FOR;
        (* Shift existing tasks up by 1 to make room at position 1 *)
        FOR qi := g_task[ti].Count TO 1 BY -1 DO
          g_task[ti].Queue[qi + 1] := g_task[ti].Queue[qi];
        END_FOR;
        (* Insert in-flight pseudo-task at position 1 *)
        g_task[ti].Queue[1].Unit              := 0;    (* pseudo — no unit *)
        g_task[ti].Queue[1].Stage             := -1;   (* pseudo-stage marker *)
        g_task[ti].Queue[1].LiftStationTarget := g_transporter[ti].LiftStationTarget;
        g_task[ti].Queue[1].SinkStationTarget := g_transporter[ti].SinkStationTarget;
        g_task[ti].Queue[1].StartTime         := i_time_s;
        g_task[ti].Queue[1].FinishTime        := est_finish;
        g_task[ti].Queue[1].CalcTime          := 0;
        g_task[ti].Queue[1].MinTime           := 0;
        g_task[ti].Queue[1].MaxTime           := 0;
        g_task[ti].Count := g_task[ti].Count + 1;
      END_IF;
    END_IF;
  END_FOR;

  next_phase := 1040;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1040: CALC_IDLE — calc idle slots for all transporters*)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1040 THEN
  FOR ti := 1 TO MAX_Transporters DO
    fb_idle_slots(i_trans := ti, i_time_s := i_time_s);
  END_FOR;
  cur_task_idx := 1;
  next_phase := 2000;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2000: FIT_STAGE0 — inline idle-slot fit for pickup    *)
(* Matches JS departureScheduler.js stage 0 inline code:       *)
(*   earliestPickup = max(slot.start, currentTimeSec) + travel  *)
(*   NO margin in earliest (unlike fb_fit which adds margin).   *)
(*   Stage 0 delay NEVER triggers RECALC — only stage 1+ does. *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2000 THEN
  loading_stn := g_unit[cur_wait_unit].location;

  (* Find first treatment station from schedule.
     If CalcSchedule prepended the loading station (loading ≠ first treatment),
     Stages[1] = loading (CalcTime=0), Stages[2] = first treatment.
     Otherwise Stages[1] = first treatment directly. *)
  first_stn := 0;
  prepend_offset := 0;
  IF g_schedule[cur_wait_unit].StageCount >= 1 THEN
    first_stn := g_schedule[cur_wait_unit].Stages[1].station;
    (* Detect prepend: first schedule stage = loading station with zero calc_time *)
    IF first_stn = loading_stn
       AND g_schedule[cur_wait_unit].Stages[1].CalcTime = 0
       AND g_schedule[cur_wait_unit].StageCount >= 2 THEN
      first_stn := g_schedule[cur_wait_unit].Stages[2].station;
      prepend_offset := 1;
    END_IF;
  END_IF;

  IF first_stn = 0 THEN
    next_phase := 9000;
  ELSIF loading_stn < 100 THEN
    (* ★ G07: Batch is on transporter — use transporter's current_station *)
    IF loading_stn >= 1 AND loading_stn <= MAX_Transporters THEN
      sched_trans := loading_stn;
      loading_stn := g_transporter[loading_stn].CurrentStation;
      IF loading_stn < 100 THEN
        next_phase := 9000;
      END_IF;
    ELSE
      next_phase := 9000;
    END_IF;
    IF next_phase <> 9000 THEN
      fb_find(i_lift_stn := loading_stn, i_sink_stn := first_stn);
      IF fb_find.o_trans > 0 THEN
        sched_trans := fb_find.o_trans;
      END_IF;
    END_IF;
  ELSE
    fb_find(i_lift_stn := loading_stn, i_sink_stn := first_stn);
    sched_trans := fb_find.o_trans;
    IF sched_trans = 0 THEN sched_trans := 1; END_IF;
  END_IF;

  IF next_phase <> 9000 THEN
    (* Calculate transfer time for pickup *)
    tmp_move := g_move[sched_trans];
    xfer_dur := STC_CalcTransferTime(
      i_from_stn            := loading_stn,
      i_to_stn              := first_stn,
      i_move                := tmp_move,
      i_from_dropping_x10   := g_station[loading_stn].DrippingTime,
      i_to_device_delay_x10 := g_station[first_stn].DeviceDelay,
      i_drip_tray_delay_x10 := g_cfg[sched_trans].DripTrayDelay
    );
    IF xfer_dur < 1.0 THEN xfer_dur := 1.0; END_IF;

    s0_task_dur := REAL_TO_LINT(xfer_dur);
    s0_slot_fitted := FALSE;
    s0_slot_cnt := g_dep_idle_slot[sched_trans].Count;
    stage0_delay := 0.0;

    (* ── Inline idle-slot scan (matches JS stage 0 logic) ── *)
    FOR s0_slot_si := 1 TO DEP_MAX_IDLE_SLOTS DO
      IF s0_slot_si > s0_slot_cnt THEN EXIT; END_IF;

      s0_slot_start := g_dep_idle_slot[sched_trans].Slots[s0_slot_si].StartTime;
      s0_slot_end   := g_dep_idle_slot[sched_trans].Slots[s0_slot_si].EndTime;
      IF s0_slot_end > i_time_s THEN
        (* Travel: prev task sink → pickup station (JS: travelToPickup) *)
        s0_from_stn := g_dep_idle_slot[sched_trans].Slots[s0_slot_si].LiftStationTarget;
        s0_travel_to := 0.0;
        IF s0_from_stn > 0 AND s0_from_stn <> loading_stn THEN
          s0_travel_to := STC_CalcHorizontalTravel(i_from_stn := s0_from_stn, i_to_stn := loading_stn, i_move := tmp_move);
        END_IF;

        (* JS: earliestPickup = max(slot.start, currentTimeSec) + travelToPickup *)
        IF s0_slot_start > i_time_s THEN
          s0_earliest := s0_slot_start + REAL_TO_LINT(s0_travel_to);
        ELSE
          s0_earliest := i_time_s + REAL_TO_LINT(s0_travel_to);
        END_IF;

        (* Travel: sink → next task lift (JS: travelFromSink) *)
        s0_to_stn := g_dep_idle_slot[sched_trans].Slots[s0_slot_si].SinkStationTarget;
        s0_travel_from := 0.0;
        IF s0_to_stn > 0 AND s0_to_stn <> first_stn THEN
          s0_travel_from := STC_CalcHorizontalTravel(i_from_stn := first_stn, i_to_stn := s0_to_stn, i_move := tmp_move);
        END_IF;

        (* JS: slotEnd = slot.nextTask ? slot.end - travelFromSink - conflictMargin : slot.end *)
        IF s0_to_stn > 0 THEN
          s0_slot_end := s0_slot_end - REAL_TO_LINT(s0_travel_from + CONFLICT_MARGIN_S);
        END_IF;

        (* ★ G10: Overlap check for stage 0 *)
        fb_ovlp_delay(
          i_lift_stn   := loading_stn,
          i_sink_stn   := first_stn,
          i_trans_id   := sched_trans,
          i_task_start := s0_earliest,
          i_task_end   := s0_earliest + s0_task_dur,
          i_margin_s   := CONFLICT_MARGIN_S
        );
        IF fb_ovlp_delay.o_delay_s > 0.0 THEN
          s0_earliest := s0_earliest + REAL_TO_LINT(fb_ovlp_delay.o_delay_s);
        END_IF;

        (* Does the task fit? *)
        IF s0_earliest + s0_task_dur <= s0_slot_end THEN
          (* JS: stage0Delay = effectiveStart - task.task_start_time *)
          stage0_delay := LINT_TO_REAL(s0_earliest - sched_base_time);
          IF stage0_delay < 0.0 THEN stage0_delay := 0.0; END_IF;

          (* maxInitialWaitS check *)
          IF stage0_delay <= MAX_INIT_WAIT_S THEN
            s0_slot_fitted := TRUE;

            (* ★ G11: Trim idle slot *)
            g_dep_idle_slot[sched_trans].Slots[s0_slot_si].StartTime :=
              s0_earliest + s0_task_dur;

            (* Record stage 0 delay — shift sched_base_time for stage 1+ *)
            IF stage0_delay > MARGIN_S THEN
              stage0_pending_delay := stage0_pending_delay + stage0_delay;
              sched_base_time := sched_base_time + REAL_TO_LINT(stage0_delay);
            END_IF;

            EXIT;  (* Found a fitting slot *)
          END_IF;
        END_IF;
      END_IF;
    END_FOR;

    IF NOT s0_slot_fitted THEN
      (* Stage 0 doesn't fit any slot → REJECT *)
      next_phase := 9000;
    ELSE
      (* JS: stage 0 delay NEVER triggers RECALC alone.
         continue → proceed to stage 1+ tasks.
         Skip pickup task if CalcSchedule prepended the loading station:
         it was already fitted inline above. *)
      IF prepend_offset = 1 THEN
        cur_task_idx := 2;   (* skip prepended pickup task *)
      ELSE
        cur_task_idx := 1;
      END_IF;

      IF cur_task_idx > w_task_cnt THEN
        next_phase := 8000;    (* No stage 1+ → ACTIVATE *)
      ELSE
        next_phase := 2001;    (* Continue to stage 1+ fit *)
      END_IF;
    END_IF;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2001: FIT_TASK — fit stage 1+ tasks one per tick      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2001 THEN
  IF cur_task_idx > w_task_cnt THEN
    (* All stage 1+ tasks fit → ACTIVATE.
       Stage 0 delay (if any) was already applied to sched_base_time
       in phase 2000. TSK will recalculate after activation. *)
    next_phase := 8000;
  ELSE
    (* Get current task data *)
    si := w_tasks[cur_task_idx].Stage;
    ti := w_trans[cur_task_idx];

    (* Overlap delay check *)
    fb_ovlp_delay(
      i_lift_stn   := w_tasks[cur_task_idx].LiftStationTarget,
      i_sink_stn   := w_tasks[cur_task_idx].SinkStationTarget,
      i_trans_id   := ti,
      i_task_start := w_tasks[cur_task_idx].StartTime,
      i_task_end   := w_tasks[cur_task_idx].FinishTime,
      i_margin_s   := CONFLICT_MARGIN_S
    );
    ovlp_delay_s := fb_ovlp_delay.o_delay_s;

    (* Idle-slot fit check *)
    fb_fit(
      i_lift_stn     := w_tasks[cur_task_idx].LiftStationTarget,
      i_sink_stn     := w_tasks[cur_task_idx].SinkStationTarget,
      i_trans_id     := ti,
      i_task_start   := w_tasks[cur_task_idx].StartTime,
      i_task_end     := w_tasks[cur_task_idx].FinishTime,
      i_shift_s      := ovlp_delay_s,
      i_calc_time_s  := w_tasks[cur_task_idx].CalcTime,
      i_max_time_s   := w_tasks[cur_task_idx].MaxTime,
      i_flex_factor  := FLEX_FACTOR,
      i_margin_s     := MARGIN_S,
      i_conflict_margin_s := CONFLICT_MARGIN_S
    );

    total_delay_s := ovlp_delay_s + DINT_TO_REAL(fb_fit.o_result.DelayTime);

    IF fb_fit.o_result.Fits THEN
      (* ★ G11: Trim idle slot after successful stage 1+ fit *)
      IF fb_fit.o_result.SlotIdx >= 1 AND fb_fit.o_result.SlotIdx <= DEP_MAX_IDLE_SLOTS THEN
        g_dep_idle_slot[ti].Slots[fb_fit.o_result.SlotIdx].StartTime :=
          fb_fit.o_result.TaskEndTime;
      END_IF;

      IF total_delay_s <= MARGIN_S THEN
        (* Fits with negligible delay → next task *)
        cur_task_idx := cur_task_idx + 1;
        next_phase := 2001;
      ELSE
        (* Delay needed → record and recalculate *)
        delay_stage  := si;
        delay_amount := total_delay_s;
        delay_target := 1;   (* program stage *)
        next_phase   := 3000;
      END_IF;
    ELSE
      (* ★ G02: Does not fit → try backward chaining *)
      IF fb_fit.o_result.NeedExtraTime <= 0 THEN
        (* No slot at all → reject *)
        next_phase := 9000;
      ELSE
        (* Walk backward through w_tasks, accumulate flex *)
        remaining_need := DINT_TO_REAL(fb_fit.o_result.NeedExtraTime);
        chain_delay_cnt := 0;
        chain_ok := FALSE;

        bk := cur_task_idx - 1;
        WHILE bk >= 1 AND remaining_need > MARGIN_S DO
          prev_flex_up := DINT_TO_REAL(w_tasks[bk].MaxTime - w_tasks[bk].CalcTime);
          IF prev_flex_up < 0.0 THEN prev_flex_up := 0.0; END_IF;
          prev_capped := prev_flex_up * FLEX_FACTOR;
          use_delay := prev_capped;
          IF use_delay > remaining_need THEN use_delay := remaining_need; END_IF;

          IF use_delay > MARGIN_S THEN
            chain_delay_cnt := chain_delay_cnt + 1;
            IF chain_delay_cnt <= 10 THEN
              chain_delays[chain_delay_cnt].Stage   := w_tasks[bk].Stage;
              chain_delays[chain_delay_cnt].DelayTime := REAL_TO_DINT(use_delay);
              IF w_tasks[bk].Stage = 0 THEN
                chain_delays[chain_delay_cnt].Target := 0;  (* batch *)
              ELSE
                chain_delays[chain_delay_cnt].Target := 1;  (* program stage *)
              END_IF;
              chain_delays[chain_delay_cnt].Valid := TRUE;
            END_IF;
            remaining_need := remaining_need - use_delay;
          END_IF;
          bk := bk - 1;
        END_WHILE;

        IF remaining_need <= MARGIN_S THEN chain_ok := TRUE; END_IF;

        IF chain_ok THEN
          (* Apply chain delays *)
          FOR ci := 1 TO chain_delay_cnt DO
            IF chain_delays[ci].Valid THEN
              IF chain_delays[ci].Target = 0 THEN
                (* Stage 0 / batch delay: shift base time *)
                sched_base_time := sched_base_time + DINT_TO_LINT(chain_delays[ci].DelayTime);
              ELSIF chain_delays[ci].Target = 1 THEN
                prog_idx := chain_delays[ci].Stage - prepend_offset;
                IF prog_idx >= 1 AND prog_idx <= 30 THEN
                  old_cal := g_program[cur_wait_unit].Steps[prog_idx - 1].CalTime;
                  max_cal := g_program[cur_wait_unit].Steps[prog_idx - 1].MaxTime;
                  new_cal := old_cal + chain_delays[ci].DelayTime;
                  IF new_cal > max_cal AND max_cal > 0 THEN
                    new_cal := max_cal;
                  END_IF;
                  g_program[cur_wait_unit].Steps[prog_idx - 1].CalTime := new_cal;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

          (* ★ FIX: Also apply the current task's delay to the program
             (JS: pendingDelays includes both chain + current task delays) *)
          IF total_delay_s > MARGIN_S THEN
            prog_idx := si - prepend_offset;
            IF prog_idx >= 1 AND prog_idx <= 30 THEN
              old_cal := g_program[cur_wait_unit].Steps[prog_idx - 1].CalTime;
              max_cal := g_program[cur_wait_unit].Steps[prog_idx - 1].MaxTime;
              new_cal := old_cal + REAL_TO_DINT(total_delay_s);
              IF new_cal > max_cal AND max_cal > 0 THEN
                new_cal := max_cal;
              END_IF;
              g_program[cur_wait_unit].Steps[prog_idx - 1].CalTime := new_cal;
            END_IF;
          END_IF;

          fit_round := fit_round + 1;
          o_fit_round := fit_round;
          IF fit_round > MAX_FIT_ROUNDS THEN
            next_phase := 9000;
          ELSE
            next_phase := 1010;  (* RECALC *)
          END_IF;
        ELSE
          (* Backward chaining insufficient → REJECT *)
          next_phase := 9000;
        END_IF;
      END_IF;
    END_IF;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 3000: APPLY_DELAY — write delay to program, recalc   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 3000 THEN
  fit_round := fit_round + 1;
  o_fit_round := fit_round;
  IF fit_round > MAX_FIT_ROUNDS THEN
    next_phase := 9000;
  ELSE
    IF delay_target = 1 THEN
      (* Program stage delay: increase cal_time.
         Subtract prepend_offset: task.Stage is schedule index which
         includes the prepended loading station. *)
      prog_idx := delay_stage - prepend_offset;
      IF prog_idx >= 1 AND prog_idx <= 30 THEN
        old_cal := g_program[cur_wait_unit].Steps[prog_idx - 1].CalTime;
        max_cal := g_program[cur_wait_unit].Steps[prog_idx - 1].MaxTime;
        new_cal := old_cal + REAL_TO_DINT(delay_amount);
        IF new_cal > max_cal AND max_cal > 0 THEN
          new_cal := max_cal;
        END_IF;
        g_program[cur_wait_unit].Steps[prog_idx - 1].CalTime := new_cal;
      END_IF;
    END_IF;
    (* Recalculate: schedule → tasks → idle → fit *)
    next_phase := 1010;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8000: ACTIVATE — commit changes to pending write      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 8000 THEN
  (* Store pending write data *)
  FOR ui := 1 TO MAX_Units DO
    g_dep_pending.Programs[ui] := g_program[ui];
    g_dep_pending.Schedule[ui] := g_schedule[ui];
  END_FOR;
  g_dep_pending.BatchUnit  := cur_wait_unit;
  g_dep_pending.BatchStage := 0;    (* cur_stage = 0, JS: batch.Stage = 0 *)
  g_dep_pending.BatchState := 1;    (* NOT_PROCESSED → IN_PROCESS *)
  (* ── Stage 0 batch times — matches JS ACTIVATE logic ──────────
     JS: sandboxBatch.calc_time_s = stage0Sched.treatment_time_s
         sandboxBatch.calc_time_s += action.delay   (if idle-slot delay)
         sandboxBatch.min_time_s  = sandboxBatch.calc_time_s
         sandboxBatch.max_time_s  = max(calc, 2*calc)
     PLC: program Steps[0] = first treatment station (= JS stage0Sched)
          stage0_pending_delay = idle-slot delay (= JS action.delay)
     ──────────────────────────────────────────────────────────── *)
  IF stage0_pending_delay > MARGIN_S THEN
    (* Delay case: calc = treatment + delay, min = calc, max = 2*calc *)
    g_dep_pending.BatchCalTime := g_program[cur_wait_unit].Steps[0].CalTime
                                  + REAL_TO_DINT(stage0_pending_delay);
    g_dep_pending.BatchMinTime := g_dep_pending.BatchCalTime;
    g_dep_pending.BatchMaxTime := 2 * g_dep_pending.BatchCalTime;
  ELSE
    (* No delay: use first treatment step times directly *)
    g_dep_pending.BatchCalTime := g_program[cur_wait_unit].Steps[0].CalTime;
    g_dep_pending.BatchMinTime := g_program[cur_wait_unit].Steps[0].MinTime;
    g_dep_pending.BatchMaxTime := g_program[cur_wait_unit].Steps[0].MaxTime;
  END_IF;
  IF g_dep_pending.BatchMaxTime < g_dep_pending.BatchCalTime THEN
    g_dep_pending.BatchMaxTime := g_dep_pending.BatchCalTime;
  END_IF;
  g_dep_pending.TimeStamp      := i_time_s;
  g_dep_pending.Valid        := TRUE;

  (* Restore globals from sandbox (undo DEP's temp changes) *)
  fb_sandbox(i_cmd := 2);
  fb_sandbox(i_cmd := 3);   (* clear sandbox *)

  g_dep_activated := TRUE;
  o_activated := TRUE;

  next_phase := 8010;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8010: WAIT_SAVE — wait for TSK to process pending     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 8010 THEN
  IF NOT g_dep_pending.Valid THEN
    (* TSK has processed the pending write *)
    next_phase := 8020;
  END_IF;
  (* Otherwise keep waiting *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8020: END_DELAY — stabilization ticks                 *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 8020 THEN
  end_delay_cnt := 0;
  next_phase := 8021;

ELSIF phase >= 8021 AND phase <= 8099 THEN
  end_delay_cnt := end_delay_cnt + 1;
  IF end_delay_cnt >= END_DELAY_TICKS THEN
    next_phase := 8100;
  ELSE
    next_phase := phase + 1;
    IF next_phase > 8099 THEN
      next_phase := 8100;
    END_IF;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8100: RESTART — back to WAIT_STABLE                   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 8100 THEN
  g_dep_activated := FALSE;
  next_phase := 1;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 9000: REJECT — restore, try next batch                *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 9000 THEN
  (* Restore globals from sandbox (undo changes for this batch) *)
  fb_sandbox(i_cmd := 2);
  o_reject_cnt := o_reject_cnt + 1;

  (* Try next waiting batch *)
  cur_wait_idx := cur_wait_idx + 1;
  IF cur_wait_idx > waiting_cnt THEN
    (* No more batches → back to waiting *)
    fb_sandbox(i_cmd := 3);
    next_phase := 1;
  ELSE
    (* Try next batch — re-snapshot is still valid *)
    next_phase := 1000;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* Unknown phase → reset                                       *)
(* ════════════════════════════════════════════════════════════ *)
ELSE
  next_phase := 1;
END_IF;

(* ── Phase assignment ── *)
phase := next_phase;
o_phase := phase;

END_FUNCTION_BLOCK

(* ===========================================================================================
 *  FB_DEP_Scheduler — Departure scheduler state machine
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Controls batch activation: waiting batches (state=NOT_PROCESSED)
 *  are checked against idle slots to see if their tasks fit into
 *  the existing transporter schedule without conflicts.
 *
 *  Uses sandbox workspace arrays (g_dep_wk_xxx): DEP never touches
 *  live globals. Sandbox SNAPSHOT copies live -> workspace at INIT.
 *  All computation happens on workspace arrays. Only ACTIVATE
 *  writes results to g_dep_pending for TSK to apply.
 *
 *  Phase flow (structured by 100/1000 groups):
 *  0        STOPPED
 *  1        WAIT_STABLE          (wait for TSK phase >= 10000)
 *  100      INIT_SNAPSHOT        (snapshot batch+program to sandbox)
 *  101      INIT_COLLECT         (find waiting + active batches)
 *  102      INIT_SORT_WAITING    (FIFO sort by start_time)
 *  103      INIT_CALC_OVERLAP    (compute overlap stations)
 *  200      BATCH_START          (prepare next waiting batch)
 *  1000+i   CALC_SCHEDULE        (active batches only)
 *  2000     CLEAR_TASKS          (clear sandbox task queues)
 *  2001+i   CREATE_TASKS         (active batches only)
 *  2100     SORT_TASKS           (sort all queues)
 *  2101     SWAP_TASKS           (swap same-station pairs)
 *  2200     INJECT_IN_FLIGHT     (inject in-flight pseudo-tasks)
 *  2300     CALC_IDLE            (calculate idle slots)
 *  2400     CALC_WAIT_SCHEDULE   (calculate waiting batch schedule)
 *  2500     CREATE_WAIT_TASKS    (create + extract waiting tasks)
 *  2600     STATION_CONFLICT     (check station overlap, swap times)
 *  3000     FIT_START            (begin fitting tasks)
 *  3100+i   FIT_TASK             (fit all tasks to idle slots)
 *  4000     APPLY_DELAY          (record delay -> recalc loop)
 *  8000     ACTIVATE             (commit, set pending)
 *  8100     WAIT_SAVE            (wait for TSK to process)
 *  8200+i   END_DELAY            (stabilization ticks, i=0..N)
 *  8500     RESTART              (-> WAIT_STABLE)
 *  9000     REJECT               (restore sandbox, try next batch)
 *
 *  Phase advancement:
 *  Default = phase + 1 (at end of function body).
 *  next_phase is set ONLY when jumping to a different group.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *  25.03.2026 - Restructured state machine: 100/1000 groups,
 *  phase+1 default, index by phase offset.
 *  Removed create_idx, cur_task_idx, end_delay_cnt.
 *  Schedule computed for ALL batches (no sandbox copy needed).
 *
 *
 *)


FUNCTION_BLOCK FB_DEP_Scheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_run                     : BOOL;     (* TRUE = run *)
  i_time_s                  : LINT;     (* current absolute time (s), unix seconds *)
  i_tsk_phase               : INT;      (* FB_TSK_Scheduler.o_phase *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    DEP_MAX_WAITING         : INT;
    DEP_MAX_IDLE_SLOTS      : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    NOT_PROCESSED           : INT;
    IN_PROCESS              : INT;
    USED                    : INT;
    TO_NONE                 : INT;
    SCH_DEP_FLEX_FACTOR         : REAL;
    SCH_MARGIN_S            : REAL;
    SCH_CONFLICT_MARGIN_S   : REAL;
    SCH_MAX_INIT_WAIT_S     : REAL;
    SCH_MAX_FIT_ROUNDS      : INT;
    MAX_TASK_QUEUE          : INT;
END_VAR

VAR_EXTERNAL
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_task                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  g_dep_idle_slot           : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DepIdleSlotSetType;
  g_dep_overlap             : UDT_JC_DepOverlapType;
  g_dep_pending             : UDT_JC_DepPendingWriteType;
  g_dep_activated           : BOOL;
  g_tsk_stable              : BOOL;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  g_dep_waiting             : ARRAY[1..DEP_MAX_WAITING] OF INT;
  g_dep_waiting_count       : INT;
  g_dep_wk_schedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  g_dep_wk_task             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  g_dep_wk_program          : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_dep_wk_batch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  g_event_pending           : UDT_JC_EventMsgType;
  g_event_pending_valid     : BOOL;
END_VAR

VAR_OUTPUT
  o_phase                   : INT;
  o_wait_cnt                : INT;
  o_activated               : BOOL;
  o_reject_cnt              : INT;
  o_fit_round               : INT;
  o_cur_wait_unit           : INT;
  o_round_ticks             : INT;     (* ticks consumed by last completed round *)
END_VAR

VAR
  phase                     : INT := 0;
  next_phase                : INT;

  (* ── Waiting batch management ── *)
  waiting_list              : ARRAY[1..MAX_UNITS] OF INT;
  waiting_cnt               : INT;
  cur_wait_idx              : INT;
  cur_wait_unit             : INT;

  (* ── Active batch list for rebuild ── *)
  batch_list                : ARRAY[1..MAX_UNITS] OF INT;
  batch_count               : INT;

  (* ── Extracted waiting batch tasks ── *)
  w_tasks                   : ARRAY[1..30] OF UDT_JC_TskTaskType;
  w_trans                   : ARRAY[1..30] OF INT;
  w_task_cnt                : INT;

  (* ── Phase index: derived from phase number ── *)
  idx                       : INT;

  (* ── First fit task index (skip stage 0 if prepended) ── *)
  fit_task_start            : INT;

  (* ── Fit state ── *)
  fit_round                 : INT;
  sched_base_time           : LINT;

  (* ── Delay recording ── *)
  delay_stage               : INT;
  delay_amount              : REAL;
  delay_target              : INT;

  (* Sub-FB instances *)
  fb_find                   : FB_STC_FindTransporter;
  fit_result                : UDT_JC_DepFitResultType;

  (* ── Temp variables ── *)
  ti                        : INT;
  qi                        : INT;
  bi                        : INT;
  ui                        : INT;
  si                        : INT;
  sched_trans               : INT;
  write_idx                 : INT;
  ovlp_delay_s              : REAL;
  total_delay_s             : REAL;
  prog_idx                  : INT;
  old_cal                   : DINT;
  new_cal                   : DINT;
  max_cal                   : DINT;
  est_finish                : LINT;



  (* ── Backward chaining variables ── *)
  remaining_need            : REAL;
  chain_delays              : ARRAY[1..10] OF UDT_JC_DepDelayActionType;
  chain_delay_cnt           : INT;
  chain_ok                  : BOOL;
  prev_flex_up              : REAL;
  prev_capped               : REAL;
  use_delay                 : REAL;
  bk                        : INT;
  ci                        : INT;

  (* ── Idle-slot widening: stretch IN_PROCESS batches ── *)
  ov_slot_idx               : INT;
  widen_need                : REAL;
  widen_ok                  : BOOL;
  border_unit               : INT;
  border_src_stage          : INT;
  border_flex               : REAL;
  border_capped             : REAL;
  border_use                : REAL;
  min_cal                   : DINT;

  (* ── Sort variables ── *)
  tmp_unit                  : INT;
  tmp_key                   : LINT;
  ji                        : INT;

  (* ── Station conflict (Phase 2600) ── *)
  cap_ws                    : INT;
  cap_as                    : INT;
  cap_bi                    : INT;
  cap_stn                   : INT;
  cap_w_entry               : LINT;
  cap_w_exit                : LINT;
  cap_a_entry               : LINT;
  cap_a_exit                : LINT;
  cap_need                  : LINT;
  cap_prog_stg              : INT;
  cap_a_prog_stg            : INT;
  cap_a_unit                : INT;
  cap_conflict              : BOOL;
  cap_margin                : LINT := 2;
  flex_cap                  : DINT;

  round_ticks               : INT := 0;  (* ticks since last RESTART *)
END_VAR

IF NOT i_run THEN
  phase := 0;
  o_phase := 0;
  o_activated := FALSE;
  RETURN;
END_IF;

next_phase := 0;   (* 0 = use phase + 1 at end *)
o_activated := FALSE;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 0: STOPPED                                           *)
(* ════════════════════════════════════════════════════════════ *)
IF phase = 0 THEN
  next_phase := 1;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1: WAIT_STABLE                                       *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 1 THEN
  IF i_tsk_phase >= 10000 AND g_tsk_stable THEN
    next_phase := 100;
  ELSE
    next_phase := 1;  (* stay *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 100: INIT_SNAPSHOT — copy batch+program to sandbox    *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 100 THEN
  FC_DEP_Sandbox(i_cmd := 1,
    io_wk_schedule := g_dep_wk_schedule, io_wk_batch := g_dep_wk_batch,
    io_wk_program := g_dep_wk_program, io_wk_task := g_dep_wk_task);
  (* phase + 1 -> 101 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 101: INIT_COLLECT — find waiting + active batches     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 101 THEN
  waiting_cnt := FC_STC_CollectActiveBatches(i_mode := 1, o_list => waiting_list);
  o_wait_cnt := waiting_cnt;
  o_reject_cnt := 0;
  o_fit_round := 0;
  o_cur_wait_unit := 0;
  g_dep_waiting_count := waiting_cnt;
  FOR ui := 1 TO waiting_cnt DO
    g_dep_waiting[ui] := waiting_list[ui];
  END_FOR;

  batch_count := FC_STC_CollectActiveBatches(i_mode := 0, o_list => batch_list);

  IF waiting_cnt = 0 THEN
    next_phase := 1;
  END_IF;
  (* else phase + 1 -> 102 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 102: INIT_SORT_WAITING — FIFO sort by start_time     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 102 THEN
  FOR si := 2 TO waiting_cnt DO
    tmp_unit := waiting_list[si];
    tmp_key  := g_dep_wk_batch[tmp_unit].StartTime;
    ji := 0;
    FOR ji := si - 1 TO 1 BY -1 DO
      IF g_dep_wk_batch[waiting_list[ji]].StartTime > tmp_key THEN
        waiting_list[ji + 1] := waiting_list[ji];
      ELSE
        EXIT;
      END_IF;
    END_FOR;
    waiting_list[ji + 1] := tmp_unit;
  END_FOR;
  cur_wait_idx := 1;
  (* phase + 1 -> 103 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 103: INIT_CALC_OVERLAP — compute overlap stations     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 103 THEN
  FC_DEP_CalcOverlap(io_overlap := g_dep_overlap);
  next_phase := 200;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 200: BATCH_START — prepare current waiting batch      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 200 THEN
  IF cur_wait_idx > waiting_cnt THEN
    next_phase := 1;
  ELSE
    cur_wait_unit := waiting_list[cur_wait_idx];
    o_cur_wait_unit := cur_wait_unit;
    fit_round := 0;
    o_fit_round := 0;
    sched_base_time := i_time_s;
    next_phase := 1000;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1000+i: CALC_SCHEDULE — one schedule per scan         *)
(*   i=0..batch_count-1: active batches FIRST                  *)
(*   i=batch_count: waiting batch LAST (sees active schedules) *)
(*   i>batch_count: done -> 2000                               *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase >= 1000 AND phase <= 1999 THEN
  idx := phase - 1000;

  IF idx < batch_count THEN
    (* Calculate schedule for active batch FIRST *)
    fb_find(i_lift_stn := g_unit[batch_list[idx + 1]].location, i_sink_stn := 0);
    sched_trans := fb_find.o_trans;
  IF sched_trans = 0 THEN sched_trans := 1; END_IF;

    FC_STC_CalcSchedule(
      i_unit   := batch_list[idx + 1],
      i_trans  := sched_trans,
      i_time_s := i_time_s,
      io_schedule := g_dep_wk_schedule,
      io_batch    := g_dep_wk_batch,
      io_program  := g_dep_wk_program
    );
    (* phase + 1 -> next active batch *)

  ELSE
    (* All active schedules calculated -> clear tasks *)
    next_phase := 2000;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2000: CLEAR_TASKS — clear sandbox task queues         *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2000 THEN
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    g_dep_wk_task[ti].Count := 0;
    FOR qi := 1 TO MAX_TASK_QUEUE DO
      g_dep_wk_task[ti].Queue[qi].Unit := 0;
    END_FOR;
  END_FOR;
  (* phase + 1 -> 2001 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2001+i: CREATE_TASKS — active batches only            *)
(*   i=0..batch_count-1: active batches                        *)
(*   i>=batch_count: done -> 2100                              *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase >= 2001 AND phase <= 2099 THEN
  idx := phase - 2001;

  IF idx < batch_count THEN
    FC_STC_CreateTasks(i_unit := batch_list[idx + 1], io_schedule := g_dep_wk_schedule, io_task := g_dep_wk_task);
    (* phase + 1 -> next batch *)

  ELSE
    next_phase := 2100;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2100: SORT_TASKS — sort all queues by start_time      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2100 THEN
  FC_STC_SortTasks(i_trans := 0, i_time_s := i_time_s, io_task := g_dep_wk_task, io_batch := g_dep_wk_batch);
  (* phase + 1 -> 2101 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2101: SWAP_TASKS — swap same-station pairs            *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2101 THEN
  FC_STC_SwapTasks(io_task := g_dep_wk_task);
  next_phase := 2200;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2200: INJECT_IN_FLIGHT — inject active transporter    *)
(*   pseudo-tasks into task queues                             *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2200 THEN

  (* Inject in-flight pseudo-tasks for active transporters *)
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    IF g_transporter[ti].Phase >= 1 AND g_transporter[ti].Phase <= 4 THEN
      est_finish := i_time_s + DINT_TO_LINT(g_transporter[ti].TaskRemainingTime);
      IF est_finish > i_time_s AND g_dep_wk_task[ti].Count < 30 THEN
        (* Remove schedule-derived task matching in-flight transfer *)
        FOR qi := 1 TO g_dep_wk_task[ti].Count DO
          IF g_dep_wk_task[ti].Queue[qi].LiftStationTarget = g_transporter[ti].LiftStationTarget
             AND g_dep_wk_task[ti].Queue[qi].SinkStationTarget = g_transporter[ti].SinkStationTarget THEN
            FOR bi := qi TO g_dep_wk_task[ti].Count - 1 DO
              g_dep_wk_task[ti].Queue[bi] := g_dep_wk_task[ti].Queue[bi + 1];
            END_FOR;
            g_dep_wk_task[ti].Queue[g_dep_wk_task[ti].Count].Unit := 0;
            g_dep_wk_task[ti].Count := g_dep_wk_task[ti].Count - 1;
            EXIT;
          END_IF;
        END_FOR;
        (* Shift existing tasks up by 1 *)
        FOR qi := g_dep_wk_task[ti].Count TO 1 BY -1 DO
          g_dep_wk_task[ti].Queue[qi + 1] := g_dep_wk_task[ti].Queue[qi];
        END_FOR;
        (* Insert in-flight pseudo-task at position 1 *)
        g_dep_wk_task[ti].Queue[1].Unit              := 0;
        g_dep_wk_task[ti].Queue[1].Stage             := -1;
        g_dep_wk_task[ti].Queue[1].LiftStationTarget := g_transporter[ti].LiftStationTarget;
        g_dep_wk_task[ti].Queue[1].SinkStationTarget := g_transporter[ti].SinkStationTarget;
        g_dep_wk_task[ti].Queue[1].StartTime         := i_time_s;
        g_dep_wk_task[ti].Queue[1].FinishTime        := est_finish;
        g_dep_wk_task[ti].Queue[1].CalcTime          := 0;
        g_dep_wk_task[ti].Queue[1].MinTime           := 0;
        g_dep_wk_task[ti].Queue[1].MaxTime           := 0;
        g_dep_wk_task[ti].Count := g_dep_wk_task[ti].Count + 1;
      END_IF;
    END_IF;
  END_FOR;

  next_phase := 2300;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2300: CALC_IDLE — calc idle slots for all transporters*)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2300 THEN
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    FC_DEP_CalcIdleSlots(i_trans := ti, i_time_s := i_time_s,
                      io_task := g_dep_wk_task, io_idle_slot := g_dep_idle_slot);
  END_FOR;

  next_phase := 2400;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2400: CALC_WAIT_SCHEDULE — calculate waiting batch    *)
(*   schedule (after idle slots are ready)                     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2400 THEN
  fb_find(i_lift_stn := g_unit[cur_wait_unit].location, i_sink_stn := 0);
  sched_trans := fb_find.o_trans;
  IF sched_trans = 0 THEN sched_trans := 1; END_IF;

  FC_STC_CalcSchedule(
    i_unit   := cur_wait_unit,
    i_trans  := sched_trans,
    i_time_s := sched_base_time,
    io_schedule := g_dep_wk_schedule,
    io_batch    := g_dep_wk_batch,
    io_program  := g_dep_wk_program
  );
  next_phase := 2500;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2500: CREATE_WAIT_TASKS — create waiting batch tasks  *)
(*   and extract to w_tasks list                               *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2500 THEN
  (* Create tasks for waiting batch (appends to queues) *)
  FC_STC_CreateTasks(i_unit := cur_wait_unit, io_schedule := g_dep_wk_schedule, io_task := g_dep_wk_task);

  (* Extract waiting batch tasks from queues into w_tasks *)
  w_task_cnt := 0;
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    write_idx := 0;
    FOR qi := 1 TO g_dep_wk_task[ti].Count DO
      IF g_dep_wk_task[ti].Queue[qi].Unit = cur_wait_unit THEN
        w_task_cnt := w_task_cnt + 1;
        IF w_task_cnt <= 30 THEN
          w_tasks[w_task_cnt] := g_dep_wk_task[ti].Queue[qi];
          w_trans[w_task_cnt] := ti;
        END_IF;
      ELSE
        write_idx := write_idx + 1;
        IF write_idx <> qi THEN
          g_dep_wk_task[ti].Queue[write_idx] := g_dep_wk_task[ti].Queue[qi];
        END_IF;
      END_IF;
    END_FOR;
    FOR qi := write_idx + 1 TO g_dep_wk_task[ti].Count DO
      g_dep_wk_task[ti].Queue[qi].Unit := 0;
    END_FOR;
    g_dep_wk_task[ti].Count := write_idx;
  END_FOR;

  next_phase := 2600;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2600: STATION_CONFLICT — check waiting batch schedule *)
(*   against active batches for same-station overlap           *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 2600 THEN
  cap_conflict := FALSE;

  FOR cap_ws := 1 TO g_dep_wk_schedule[cur_wait_unit].StageCount DO
    IF cap_conflict THEN EXIT; END_IF;

    cap_stn   := g_dep_wk_schedule[cur_wait_unit].Stages[cap_ws].station;
    cap_w_entry := g_dep_wk_schedule[cur_wait_unit].Stages[cap_ws].EntryTime;
    cap_w_exit  := g_dep_wk_schedule[cur_wait_unit].Stages[cap_ws].ExitTime;
    IF cap_stn = 0 OR cap_w_entry >= cap_w_exit THEN
      (* skip invalid *)
    ELSE

    FOR cap_bi := 1 TO batch_count DO
      IF cap_conflict THEN EXIT; END_IF;
      ui := batch_list[cap_bi];

      FOR cap_as := 1 TO g_dep_wk_schedule[ui].StageCount DO
        IF cap_conflict THEN EXIT; END_IF;

        IF g_dep_wk_schedule[ui].Stages[cap_as].station = cap_stn THEN
          cap_a_entry := g_dep_wk_schedule[ui].Stages[cap_as].EntryTime;
          cap_a_exit  := g_dep_wk_schedule[ui].Stages[cap_as].ExitTime;

          (* Check overlap: max(w_entry, a_entry) < min(w_exit, a_exit) *)
          IF cap_w_entry < cap_a_exit AND cap_a_entry < cap_w_exit THEN

            IF cap_a_entry <= cap_w_entry THEN
              (* Case A: Active is on station when waiting arrives.
                 Option 1: extend waiting's previous stage CalTime.
                 Option 2: shorten active's current stage CalTime. *)
              cap_need := cap_a_exit - cap_w_entry + cap_margin;
              cap_a_unit := ui;

              (* Option 1: extend waiting's previous stage *)
              IF cap_ws >= 2 THEN
                cap_prog_stg := g_dep_wk_schedule[cur_wait_unit].Stages[cap_ws - 1].ProgramStage;
              ELSE
                cap_prog_stg := 0;
              END_IF;

              IF cap_prog_stg >= 0 AND cap_prog_stg <= 30 THEN
                old_cal := g_dep_wk_program[cur_wait_unit].Steps[cap_prog_stg].CalTime;
                max_cal := g_dep_wk_program[cur_wait_unit].Steps[cap_prog_stg].MaxTime;
                min_cal := g_dep_wk_program[cur_wait_unit].Steps[cap_prog_stg].MinTime;
                new_cal := old_cal + LINT_TO_DINT(cap_need);
                (* Flex cap: min + factor × (max - min) *)
                flex_cap := min_cal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(max_cal - min_cal));
                IF max_cal > 0 AND new_cal > flex_cap THEN new_cal := flex_cap; END_IF;
                IF max_cal <= 0 OR new_cal <= max_cal THEN
                  g_dep_wk_program[cur_wait_unit].Steps[cap_prog_stg].CalTime := new_cal;
                  cap_conflict := TRUE;
                END_IF;
              END_IF;

              (* Option 2: shorten active's current stage *)
              IF NOT cap_conflict THEN
                cap_a_prog_stg := g_dep_wk_schedule[cap_a_unit].Stages[cap_as].ProgramStage;
                IF cap_a_prog_stg >= 1 AND cap_a_prog_stg <= 30 THEN
                  old_cal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime;
                  min_cal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].MinTime;
                  new_cal := old_cal - LINT_TO_DINT(cap_need);
                  IF new_cal >= min_cal THEN
                    g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime := new_cal;
                    cap_conflict := TRUE;
                  ELSE
                    next_phase := 9000;  (* Neither option works — reject *)
                  END_IF;
                ELSE
                  next_phase := 9000;
                END_IF;
              END_IF;

            ELSE
              (* Case B: Waiting is on station first, active is coming.
                 Option 1: shorten waiting's current stage CalTime.
                 Option 2: extend active's previous stage CalTime. *)
              cap_need := cap_w_exit - cap_a_entry + cap_margin;
              cap_a_unit := ui;

              (* Option 1: shorten waiting's current stage *)
              cap_prog_stg := g_dep_wk_schedule[cur_wait_unit].Stages[cap_ws].ProgramStage;

              IF cap_prog_stg >= 0 AND cap_prog_stg <= 30 THEN
                old_cal := g_dep_wk_program[cur_wait_unit].Steps[cap_prog_stg].CalTime;
                min_cal := g_dep_wk_program[cur_wait_unit].Steps[cap_prog_stg].MinTime;
                new_cal := old_cal - LINT_TO_DINT(cap_need);
                IF new_cal >= min_cal THEN
                  g_dep_wk_program[cur_wait_unit].Steps[cap_prog_stg].CalTime := new_cal;
                  cap_conflict := TRUE;
                END_IF;
              END_IF;

              (* Option 2: extend active's previous stage *)
              IF NOT cap_conflict THEN
                IF cap_as >= 2 THEN
                  cap_a_prog_stg := g_dep_wk_schedule[cap_a_unit].Stages[cap_as - 1].ProgramStage;
                  IF cap_a_prog_stg >= 1 AND cap_a_prog_stg <= 30 THEN
                    old_cal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime;
                    max_cal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].MaxTime;
                    min_cal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].MinTime;
                    new_cal := old_cal + LINT_TO_DINT(cap_need);
                    (* Flex cap: min + factor × (max - min) *)
                    flex_cap := min_cal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(max_cal - min_cal));
                    IF max_cal > 0 AND new_cal > flex_cap THEN new_cal := flex_cap; END_IF;
                    IF max_cal <= 0 OR new_cal <= max_cal THEN
                      g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime := new_cal;
                      cap_conflict := TRUE;
                    ELSE
                      next_phase := 9000;  (* Neither option works — reject *)
                    END_IF;
                  ELSE
                    next_phase := 9000;
                  END_IF;
                ELSE
                  next_phase := 9000;
                END_IF;
              END_IF;
            END_IF;

          END_IF;  (* overlap *)
        END_IF;  (* same station *)
      END_FOR;  (* cap_as *)
    END_FOR;  (* cap_bi *)

    END_IF;  (* valid station *)
  END_FOR;  (* cap_ws *)

  IF next_phase = 0 THEN
    IF cap_conflict THEN
      (* Station conflict resolved by adjusting CalTime — recalc *)
      fit_round := fit_round + 1;
      o_fit_round := fit_round;
      IF fit_round > SCH_MAX_FIT_ROUNDS THEN
        next_phase := 9000;
      ELSE
        sched_base_time := i_time_s;
        next_phase := 1000;
      END_IF;
    ELSE
      next_phase := 3000;
    END_IF;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 3000: FIT_START — begin fitting waiting batch tasks   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 3000 THEN
  fit_task_start := 1;

  IF w_task_cnt < 1 THEN
    next_phase := 9000;   (* No tasks -> reject *)
  ELSE
    next_phase := 3100;   (* -> FIT_TASK *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 3100+i: FIT_TASK — fit all tasks one per tick         *)
(*   idx = phase - 3100, task index = fit_task_start + idx     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase >= 3100 AND phase <= 3199 THEN
  idx := phase - 3100;
  si := fit_task_start + idx;  (* actual task index *)

  IF si > w_task_cnt THEN
    (* All tasks fit -> ACTIVATE *)
    next_phase := 8000;
  ELSE
    ti := w_trans[si];

    (* Overlap delay check *)
    ovlp_delay_s := FC_DEP_OverlapDelay(
      i_lift_stn   := w_tasks[si].LiftStationTarget,
      i_sink_stn   := w_tasks[si].SinkStationTarget,
      i_trans_id   := ti,
      i_task_start := w_tasks[si].StartTime,
      i_task_end   := w_tasks[si].FinishTime,
      i_margin_s   := SCH_CONFLICT_MARGIN_S,
      io_task      := g_dep_wk_task,
      io_overlap   := g_dep_overlap
    );

    (* Idle-slot fit check *)
    FC_DEP_FitTaskToSlot(
      i_lift_stn     := w_tasks[si].LiftStationTarget,
      i_sink_stn     := w_tasks[si].SinkStationTarget,
      i_trans_id     := ti,
      i_task_start   := w_tasks[si].StartTime,
      i_task_end     := w_tasks[si].FinishTime,
      i_shift_s      := ovlp_delay_s,
      i_calc_time_s  := w_tasks[si].CalcTime,
      i_min_time_s   := w_tasks[si].MinTime,
      i_max_time_s   := w_tasks[si].MaxTime,
      i_flex_factor  := SCH_DEP_FLEX_FACTOR,
      i_margin_s     := SCH_MARGIN_S,
      i_conflict_margin_s := SCH_CONFLICT_MARGIN_S,
      io_idle_slot   := g_dep_idle_slot,
      o_result       := fit_result
    );

    total_delay_s := ovlp_delay_s + DINT_TO_REAL(fit_result.DelayTime);

    IF fit_result.Fits THEN
      (* Trim idle slot after successful fit *)
      IF fit_result.SlotIdx >= 1 AND fit_result.SlotIdx <= DEP_MAX_IDLE_SLOTS THEN
        g_dep_idle_slot[ti].Slots[fit_result.SlotIdx].StartTime :=
          fit_result.TaskEndTime;
        g_dep_idle_slot[ti].Slots[fit_result.SlotIdx].LiftStationTarget :=
          w_tasks[si].SinkStationTarget;
      END_IF;

      IF total_delay_s > SCH_MARGIN_S THEN
        prog_idx := w_tasks[si].SrcStage;
        IF prog_idx >= 0 AND prog_idx <= 30 THEN
          old_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime;
          max_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].MaxTime;
          min_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].MinTime;
          new_cal := old_cal + REAL_TO_DINT(total_delay_s);
          flex_cap := min_cal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(max_cal - min_cal));
          IF max_cal > 0 AND new_cal > flex_cap THEN new_cal := flex_cap; END_IF;
          g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime := new_cal;
          fit_round := fit_round + 1;
          o_fit_round := fit_round;
          IF fit_round > SCH_MAX_FIT_ROUNDS THEN
            next_phase := 9000;
          ELSE
            (* Recalc all from beginning *)
            sched_base_time := i_time_s;
            next_phase := 1000;
          END_IF;
        END_IF;
      END_IF;
      (* else: no significant delay, phase + 1 = next task *)
    ELSE
      (* Does not fit -> try backward chaining *)
      IF fit_result.NeedExtraTime <= 0 THEN
        next_phase := 9000;
      ELSE
        remaining_need := DINT_TO_REAL(fit_result.NeedExtraTime);
        chain_delay_cnt := 0;
        chain_ok := FALSE;

        FOR bk := si - 1 TO 1 BY -1 DO
          IF remaining_need <= SCH_MARGIN_S THEN EXIT; END_IF;
          prev_flex_up := DINT_TO_REAL(w_tasks[bk].MaxTime - w_tasks[bk].MinTime);
  IF prev_flex_up < 0.0 THEN prev_flex_up := 0.0; END_IF;
          prev_capped := prev_flex_up * SCH_DEP_FLEX_FACTOR;
          use_delay := prev_capped;
  IF use_delay > remaining_need THEN use_delay := remaining_need; END_IF;

          IF use_delay > SCH_MARGIN_S THEN
            chain_delay_cnt := chain_delay_cnt + 1;
            IF chain_delay_cnt <= 10 THEN
              chain_delays[chain_delay_cnt].Stage   := w_tasks[bk].SrcStage;
              chain_delays[chain_delay_cnt].DelayTime := REAL_TO_DINT(use_delay);
              IF w_tasks[bk].SrcStage = 0 THEN
                chain_delays[chain_delay_cnt].Target := 0;
              ELSE
                chain_delays[chain_delay_cnt].Target := 1;
              END_IF;
              chain_delays[chain_delay_cnt].Valid := TRUE;
            END_IF;
            remaining_need := remaining_need - use_delay;
          END_IF;
        END_FOR;

  IF remaining_need <= SCH_MARGIN_S THEN chain_ok := TRUE; END_IF;

        IF chain_ok THEN
          (* Apply chain delays *)
          FOR ci := 1 TO chain_delay_cnt DO
            IF chain_delays[ci].Valid THEN
              IF chain_delays[ci].Target = 0 THEN
                sched_base_time := sched_base_time + DINT_TO_LINT(chain_delays[ci].DelayTime);
              ELSIF chain_delays[ci].Target = 1 THEN
                prog_idx := chain_delays[ci].Stage;
                IF prog_idx >= 1 AND prog_idx <= 30 THEN
                  old_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime;
                  max_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].MaxTime;
                  min_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].MinTime;
                  new_cal := old_cal + chain_delays[ci].DelayTime;
                  flex_cap := min_cal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(max_cal - min_cal));
                  IF max_cal > 0 AND new_cal > flex_cap THEN
                    new_cal := flex_cap;
                  END_IF;
                  g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime := new_cal;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

          (* Also apply current task's delay *)
          IF total_delay_s > SCH_MARGIN_S THEN
            prog_idx := w_tasks[si].SrcStage;
            IF prog_idx >= 1 AND prog_idx <= 30 THEN
              old_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime;
              max_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].MaxTime;
              min_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].MinTime;
              new_cal := old_cal + REAL_TO_DINT(total_delay_s);
              flex_cap := min_cal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(max_cal - min_cal));
              IF max_cal > 0 AND new_cal > flex_cap THEN
                new_cal := flex_cap;
              END_IF;
              g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime := new_cal;
            END_IF;
          END_IF;

          fit_round := fit_round + 1;
          o_fit_round := fit_round;
          IF fit_round > SCH_MAX_FIT_ROUNDS THEN
            next_phase := 9000;
          ELSE
            next_phase := 1000;  (* RECALC *)
          END_IF;
        ELSE
          (* ── Backward chaining insufficient → try widening idle slot
             by stretching/advancing IN_PROCESS batch CalTimes ── *)
          widen_ok := FALSE;
          widen_need := remaining_need;
          ov_slot_idx := fit_result.OverflowSlotIdx;

          IF ov_slot_idx >= 1 AND ov_slot_idx <= g_dep_idle_slot[ti].Count THEN
            (* ── Stretch RIGHT border: find task whose StartTime = slot EndTime ── *)
            border_unit := 0;
            FOR qi := 1 TO g_dep_wk_task[ti].Count DO
              IF g_dep_wk_task[ti].Queue[qi].StartTime = g_dep_idle_slot[ti].Slots[ov_slot_idx].EndTime THEN
                border_unit := g_dep_wk_task[ti].Queue[qi].Unit;
                border_src_stage := g_dep_wk_task[ti].Queue[qi].SrcStage;
                EXIT;
              END_IF;
            END_FOR;

            IF border_unit >= 1 AND border_unit <= MAX_UNITS
               AND border_unit <> cur_wait_unit
               AND border_src_stage >= 1 AND border_src_stage <= 30 THEN
              (* Flex cap: min + factor × (max - min); available room = flex_cap - CalTime *)
              min_cal := g_dep_wk_program[border_unit].Steps[border_src_stage].MinTime;
              max_cal := g_dep_wk_program[border_unit].Steps[border_src_stage].MaxTime;
              old_cal := g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime;
              flex_cap := min_cal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(max_cal - min_cal));
              border_flex := DINT_TO_REAL(flex_cap - old_cal);
  IF border_flex < 0.0 THEN border_flex := 0.0; END_IF;
              border_use := border_flex;
  IF border_use > widen_need THEN border_use := widen_need; END_IF;

              IF border_use > SCH_MARGIN_S THEN
                new_cal := old_cal + REAL_TO_DINT(border_use);
  IF max_cal > 0 AND new_cal > flex_cap THEN new_cal := flex_cap; END_IF;
                g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime := new_cal;
                widen_need := widen_need - border_use;
              END_IF;
            END_IF;

            (* ── Advance LEFT border: find task whose FinishTime = slot StartTime ── *)
            IF widen_need > SCH_MARGIN_S THEN
              border_unit := 0;
              FOR qi := 1 TO g_dep_wk_task[ti].Count DO
                IF g_dep_wk_task[ti].Queue[qi].FinishTime = g_dep_idle_slot[ti].Slots[ov_slot_idx].StartTime THEN
                  border_unit := g_dep_wk_task[ti].Queue[qi].Unit;
                  border_src_stage := g_dep_wk_task[ti].Queue[qi].SrcStage;
                  EXIT;
                END_IF;
              END_FOR;

              IF border_unit >= 1 AND border_unit <= MAX_UNITS
                 AND border_unit <> cur_wait_unit
                 AND border_src_stage >= 1 AND border_src_stage <= 30 THEN
                border_flex := DINT_TO_REAL(
                  g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime
                - g_dep_wk_program[border_unit].Steps[border_src_stage].MinTime);
  IF border_flex < 0.0 THEN border_flex := 0.0; END_IF;
                border_capped := border_flex * SCH_DEP_FLEX_FACTOR;
                border_use := border_capped;
  IF border_use > widen_need THEN border_use := widen_need; END_IF;

                IF border_use > SCH_MARGIN_S THEN
                  old_cal := g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime;
                  min_cal := g_dep_wk_program[border_unit].Steps[border_src_stage].MinTime;
                  new_cal := old_cal - REAL_TO_DINT(border_use);
  IF new_cal < min_cal THEN new_cal := min_cal; END_IF;
                  g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime := new_cal;
                  widen_need := widen_need - border_use;
                END_IF;
              END_IF;
            END_IF;

  IF widen_need <= SCH_MARGIN_S THEN widen_ok := TRUE; END_IF;
          END_IF;

          IF widen_ok THEN
            (* Slot widened → RECALC with modified IN_PROCESS programs *)
            fit_round := fit_round + 1;
            o_fit_round := fit_round;
            IF fit_round > SCH_MAX_FIT_ROUNDS THEN
              next_phase := 9000;
            ELSE
              next_phase := 1000;  (* RECALC *)
            END_IF;
          ELSE
            next_phase := 9000;   (* REJECT *)
          END_IF;
        END_IF;
      END_IF;
    END_IF;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 4000: APPLY_DELAY — write delay to program, recalc   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 4000 THEN
  fit_round := fit_round + 1;
  o_fit_round := fit_round;
  IF fit_round > SCH_MAX_FIT_ROUNDS THEN
    next_phase := 9000;
  ELSE
    IF delay_target = 1 THEN
      prog_idx := delay_stage;
      IF prog_idx >= 1 AND prog_idx <= 30 THEN
        old_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime;
        max_cal := g_dep_wk_program[cur_wait_unit].Steps[prog_idx].MaxTime;
        new_cal := old_cal + REAL_TO_DINT(delay_amount);
        IF new_cal > max_cal AND max_cal > 0 THEN
          new_cal := max_cal;
        END_IF;
        g_dep_wk_program[cur_wait_unit].Steps[prog_idx].CalTime := new_cal;
      END_IF;
    END_IF;
    next_phase := 1000;  (* RECALC *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8000: ACTIVATE — commit changes to pending write      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 8000 THEN
  FOR ui := 1 TO MAX_UNITS DO
    g_dep_pending.Programs[ui] := g_dep_wk_program[ui];
  END_FOR;
  (* Write active batch CalTimes from sandbox programs *)
  FOR ui := 1 TO MAX_UNITS DO
    IF g_dep_wk_batch[ui].State = IN_PROCESS
       AND g_dep_wk_batch[ui].CurStage >= 1
       AND g_dep_wk_batch[ui].CurStage <= g_dep_wk_program[ui].StepCount THEN
      g_dep_pending.ActiveBatchCalTime[ui] := g_dep_wk_program[ui].Steps[g_dep_wk_batch[ui].CurStage].CalTime;
    ELSE
      g_dep_pending.ActiveBatchCalTime[ui] := 0;
    END_IF;
  END_FOR;
  g_dep_pending.BatchUnit  := cur_wait_unit;
  g_dep_pending.BatchStage := 0;
  g_dep_pending.BatchState := IN_PROCESS;
  (* Stage 0 = prepend, read CalcTime/Min/Max from calculated schedule *)
  g_dep_pending.BatchCalTime := g_dep_wk_schedule[cur_wait_unit].Stages[0].CalcTime;
  g_dep_pending.BatchMinTime := g_dep_wk_schedule[cur_wait_unit].Stages[0].MinTime;
  g_dep_pending.BatchMaxTime := g_dep_wk_schedule[cur_wait_unit].Stages[0].MaxTime;
  g_dep_pending.TimeStamp := i_time_s;
  g_dep_pending.Valid     := TRUE;

  g_dep_activated := TRUE;
  o_activated := TRUE;

  (* ── Emit BATCH_ACTIVATED event (msg_type=4) ── *)
  IF NOT g_event_pending_valid THEN
    g_event_pending.MsgType := 4;
    g_event_pending.TsHi := LINT_TO_UINT(i_time_s / LINT#65536);
    g_event_pending.TsLo := LINT_TO_UINT(i_time_s MOD LINT#65536);
    g_event_pending.Payload[1]  := cur_wait_unit;                        (* unit_id *)
    g_event_pending.Payload[2]  := g_batch[cur_wait_unit].BatchCode;     (* batch_code *)
    g_event_pending.Payload[3]  := g_batch[cur_wait_unit].ProgId;        (* program_id *)
    g_event_pending.Payload[4]  := TreatmentPrograms[cur_wait_unit].StepCount;   (* stages_count *)
    g_event_pending.Payload[5]  := g_dep_wk_schedule[cur_wait_unit].Stages[0].Station; (* start_station *)
    g_event_pending_valid := TRUE;
  END_IF;

  next_phase := 8100;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8100: WAIT_SAVE — wait for TSK to process pending     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 8100 THEN
  IF NOT g_dep_pending.Valid THEN
    next_phase := 8500;
  ELSE
    next_phase := 8100;  (* stay *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8500: RESTART — back to WAIT_STABLE                   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 8500 THEN
  g_dep_activated := FALSE;
  o_round_ticks := round_ticks;
  round_ticks := 0;
  next_phase := 1;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 9000: REJECT — restore sandbox, try next batch        *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF phase = 9000 THEN
  FC_DEP_Sandbox(i_cmd := 1,
    io_wk_schedule := g_dep_wk_schedule, io_wk_batch := g_dep_wk_batch,
    io_wk_program := g_dep_wk_program, io_wk_task := g_dep_wk_task);
  o_reject_cnt := o_reject_cnt + 1;

  cur_wait_idx := cur_wait_idx + 1;
  IF cur_wait_idx > waiting_cnt THEN
    next_phase := 1;
  ELSE
    next_phase := 200;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* Unknown phase -> reset                                       *)
(* ════════════════════════════════════════════════════════════ *)
ELSE
  next_phase := 1;
END_IF;

(* ── Phase advancement ── *)
IF next_phase > 0 THEN
  phase := next_phase;
ELSE
  phase := phase + 1;
END_IF;
o_phase := phase;

END_FUNCTION_BLOCK

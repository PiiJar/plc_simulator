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
 *  1        WAIT_STABLE          (wait for TSK vPhase >= 10000)
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
 *  4000     APPLY_DELAY          (record vDelay -> recalc loop)
 *  8000     ACTIVATE             (commit, set pending)
 *  8100     WAIT_SAVE            (wait for TSK to process)
 *  8200+i   END_DELAY            (stabilization ticks, i=0..N)
 *  8500     RESTART              (-> WAIT_STABLE)
 *  9000     REJECT               (restore sandbox, try next batch)
 *
 *  Phase advancement:
 *  Default = vPhase + 1 (at end of function body).
 *  vNextPhase is set ONLY when jumping to a different group.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *  25.03.2026 - Restructured state machine: 100/1000 groups,
 *  vPhase+1 default, index by vPhase offset.
 *  Removed create_idx, cur_task_idx, end_delay_cnt.
 *  Schedule computed for ALL batches (no sandbox copy vNeeded).
 *
 *
 *)


FUNCTION_BLOCK FB_DEP_Scheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iRun                     : BOOL;     (* TRUE = run *)
  iTimeS                  : LINT;     (* current absolute time (s), unix seconds *)
  iTskPhase               : INT;      (* FB_TSK_Scheduler.oPhase *)
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
  oPhase                   : INT;
  oWaitCnt                : INT;
  oActivated               : BOOL;
  oRejectCnt              : INT;
  oFitRound               : INT;
  oCurWaitUnit           : INT;
  oRoundTicks             : INT;     (* ticks consumed by last completed vRound *)
END_VAR

VAR
  vPhase                     : INT := 0;
  vNextPhase                : INT;

  (* ── Waiting batch management ── *)
  vWaitingList              : ARRAY[1..MAX_UNITS] OF INT;
  vWaitingCnt               : INT;
  vCurWaitIdx              : INT;
  vCurWaitUnit             : INT;

  (* ── Active batch list for rebuild ── *)
  vBatchList                : ARRAY[1..MAX_UNITS] OF INT;
  vBatchCount               : INT;

  (* ── Extracted waiting batch tasks ── *)
  vWTasks                   : ARRAY[1..30] OF UDT_JC_TskTaskType;
  vWTrans                   : ARRAY[1..30] OF INT;
  vWTaskCnt                : INT;

  (* ── Phase index: derived from vPhase number ── *)
  vIdx                       : INT;

  (* ── First fit task index (skip stage 0 if prepended) ── *)
  vFitTaskStart            : INT;

  (* ── Fit state ── *)
  vFitRound                 : INT;
  vSchedBaseTime           : LINT;

  (* ── Delay recording ── *)
  vDelayStage               : INT;
  vDelayAmount              : REAL;
  vDelayTarget              : INT;

  (* Sub-FB instances *)
  vFB_FindTransporter                   : FB_STC_FindTransporter;
  vFitResult                : UDT_JC_DepFitResultType;

  (* ── Temp variables ── *)
  ti                        : INT;
  qi                        : INT;
  bi                        : INT;
  ui                        : INT;
  si                        : INT;
  vSchedTrans               : INT;
  vWriteIdx                 : INT;
  ovlp_delay_s              : REAL;
  vTotalDelayS             : REAL;
  vProgIdx                  : INT;
  vOldCal                   : DINT;
  vNewCal                   : DINT;
  vMaxCal                   : DINT;
  est_finish                : LINT;



  (* ── Backward chaining variables ── *)
  vRemainingNeed            : REAL;
  vChainDelays              : ARRAY[1..10] OF UDT_JC_DepDelayActionType;
  vChainDelayCnt           : INT;
  vChainOk                  : BOOL;
  vPrevFlexUp              : REAL;
  vPrevCapped               : REAL;
  vUseDelay                 : REAL;
  bk                        : INT;
  ci                        : INT;

  (* ── Idle-slot widening: stretch IN_PROCESS batches ── *)
  ov_slot_idx               : INT;
  vWidenNeed                : REAL;
  vWidenOk                  : BOOL;
  border_unit               : INT;
  border_src_stage          : INT;
  border_flex               : REAL;
  border_capped             : REAL;
  border_use                : REAL;
  vMinCal                   : DINT;

  (* ── Sort variables ── *)
  vTmpUnit                  : INT;
  vTmpKey                   : LINT;
  ji                        : INT;

  (* ── Station vConflict (Phase 2600) ── *)
  cap_ws                    : INT;
  cap_as                    : INT;
  cap_bi                    : INT;
  vCapStn                   : INT;
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
  vFlexCap                  : DINT;

  round_ticks               : INT := 0;  (* ticks since last RESTART *)
END_VAR

IF NOT iRun THEN
  vPhase := 0;
  oPhase := 0;
  oActivated := FALSE;
  RETURN;
END_IF;

vNextPhase := 0;   (* 0 = use vPhase + 1 at end *)
oActivated := FALSE;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 0: STOPPED                                           *)
(* ════════════════════════════════════════════════════════════ *)
IF vPhase = 0 THEN
  vNextPhase := 1;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1: WAIT_STABLE                                       *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 1 THEN
  IF iTskPhase >= 10000 AND g_tsk_stable THEN
    vNextPhase := 100;
  ELSE
    vNextPhase := 1;  (* stay *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 100: INIT_SNAPSHOT — copy batch+program to sandbox    *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 100 THEN
  FC_DEP_Sandbox(iCmd := 1,
    ioWkSchedule := g_dep_wk_schedule, ioWkBatch := g_dep_wk_batch,
    ioWkProgram := g_dep_wk_program, ioWkTask := g_dep_wk_task);
  (* vPhase + 1 -> 101 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 101: INIT_COLLECT — find waiting + active batches     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 101 THEN
  vWaitingCnt := FC_STC_CollectActiveBatches(iMode := 1, oList => vWaitingList);
  oWaitCnt := vWaitingCnt;
  oRejectCnt := 0;
  oFitRound := 0;
  oCurWaitUnit := 0;
  g_dep_waiting_count := vWaitingCnt;
  FOR ui := 1 TO vWaitingCnt DO
    g_dep_waiting[ui] := vWaitingList[ui];
  END_FOR;

  vBatchCount := FC_STC_CollectActiveBatches(iMode := 0, oList => vBatchList);

  IF vWaitingCnt = 0 THEN
    vNextPhase := 1;
  END_IF;
  (* else vPhase + 1 -> 102 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 102: INIT_SORT_WAITING — FIFO sort by start_time     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 102 THEN
  FOR si := 2 TO vWaitingCnt DO
    vTmpUnit := vWaitingList[si];
    vTmpKey  := g_dep_wk_batch[vTmpUnit].StartTime;
    ji := 0;
    FOR ji := si - 1 TO 1 BY -1 DO
      IF g_dep_wk_batch[vWaitingList[ji]].StartTime > vTmpKey THEN
        vWaitingList[ji + 1] := vWaitingList[ji];
      ELSE
        EXIT;
      END_IF;
    END_FOR;
    vWaitingList[ji + 1] := vTmpUnit;
  END_FOR;
  vCurWaitIdx := 1;
  (* vPhase + 1 -> 103 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 103: INIT_CALC_OVERLAP — compute overlap stations     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 103 THEN
  FC_DEP_CalcOverlap(ioOverlap := g_dep_overlap);
  vNextPhase := 200;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 200: BATCH_START — prepare current waiting batch      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 200 THEN
  IF vCurWaitIdx > vWaitingCnt THEN
    vNextPhase := 1;
  ELSE
    vCurWaitUnit := vWaitingList[vCurWaitIdx];
    oCurWaitUnit := vCurWaitUnit;
    vFitRound := 0;
    oFitRound := 0;
    vSchedBaseTime := iTimeS;
    vNextPhase := 1000;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 1000+i: CALC_SCHEDULE — one schedule per scan         *)
(*   i=0..vBatchCount-1: active batches FIRST                  *)
(*   i=vBatchCount: waiting batch LAST (sees active schedules) *)
(*   i>vBatchCount: oDone -> 2000                               *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase >= 1000 AND vPhase <= 1999 THEN
  vIdx := vPhase - 1000;

  IF vIdx < vBatchCount THEN
    (* Calculate schedule for active batch FIRST *)
    vFB_FindTransporter(iLiftStn := g_unit[vBatchList[vIdx + 1]].Location, iSinkStn := 0);
    vSchedTrans := vFB_FindTransporter.oTrans;
  IF vSchedTrans = 0 THEN vSchedTrans := 1; END_IF;

    FC_STC_CalcSchedule(
      iUnit   := vBatchList[vIdx + 1],
      iTrans  := vSchedTrans,
      iTimeS := iTimeS,
      ioSchedule := g_dep_wk_schedule,
      ioBatch    := g_dep_wk_batch,
      ioProgram  := g_dep_wk_program
    );
    (* vPhase + 1 -> next active batch *)

  ELSE
    (* All active schedules calculated -> clear tasks *)
    vNextPhase := 2000;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2000: CLEAR_TASKS — clear sandbox task queues         *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2000 THEN
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    g_dep_wk_task[ti].Count := 0;
    FOR qi := 1 TO MAX_TASK_QUEUE DO
      g_dep_wk_task[ti].Queue[qi].Unit := 0;
    END_FOR;
  END_FOR;
  (* vPhase + 1 -> 2001 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2001+i: CREATE_TASKS — active batches only            *)
(*   i=0..vBatchCount-1: active batches                        *)
(*   i>=vBatchCount: oDone -> 2100                              *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase >= 2001 AND vPhase <= 2099 THEN
  vIdx := vPhase - 2001;

  IF vIdx < vBatchCount THEN
    FC_STC_CreateTasks(iUnit := vBatchList[vIdx + 1], ioSchedule := g_dep_wk_schedule, ioTask := g_dep_wk_task);
    (* vPhase + 1 -> next batch *)

  ELSE
    vNextPhase := 2100;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2100: SORT_TASKS — sort all queues by start_time      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2100 THEN
  FC_STC_SortTasks(iTrans := 0, iTimeS := iTimeS, ioTask := g_dep_wk_task, ioBatch := g_dep_wk_batch);
  (* vPhase + 1 -> 2101 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2101: SWAP_TASKS — swap same-station pairs            *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2101 THEN
  FC_STC_SwapTasks(ioTask := g_dep_wk_task);
  vNextPhase := 2200;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2200: INJECT_IN_FLIGHT — inject active transporter    *)
(*   pseudo-tasks into task queues                             *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2200 THEN

  (* Inject in-flight pseudo-tasks for active transporters *)
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    IF g_transporter[ti].Phase >= 1 AND g_transporter[ti].Phase <= 4 THEN
      est_finish := iTimeS + DINT_TO_LINT(g_transporter[ti].TaskRemainingTime);
      IF est_finish > iTimeS AND g_dep_wk_task[ti].Count < 30 THEN
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
        g_dep_wk_task[ti].Queue[1].StartTime         := iTimeS;
        g_dep_wk_task[ti].Queue[1].FinishTime        := est_finish;
        g_dep_wk_task[ti].Queue[1].CalcTime          := 0;
        g_dep_wk_task[ti].Queue[1].MinTime           := 0;
        g_dep_wk_task[ti].Queue[1].MaxTime           := 0;
        g_dep_wk_task[ti].Count := g_dep_wk_task[ti].Count + 1;
      END_IF;
    END_IF;
  END_FOR;

  vNextPhase := 2300;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2300: CALC_IDLE — calc idle slots for all transporters*)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2300 THEN
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    FC_DEP_CalcIdleSlots(iTrans := ti, iTimeS := iTimeS,
                      ioTask := g_dep_wk_task, ioIdleSlot := g_dep_idle_slot);
  END_FOR;

  vNextPhase := 2400;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2400: CALC_WAIT_SCHEDULE — calculate waiting batch    *)
(*   schedule (after idle slots are ready)                     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2400 THEN
  vFB_FindTransporter(iLiftStn := g_unit[vCurWaitUnit].Location, iSinkStn := 0);
  vSchedTrans := vFB_FindTransporter.oTrans;
  IF vSchedTrans = 0 THEN vSchedTrans := 1; END_IF;

  FC_STC_CalcSchedule(
    iUnit   := vCurWaitUnit,
    iTrans  := vSchedTrans,
    iTimeS := vSchedBaseTime,
    ioSchedule := g_dep_wk_schedule,
    ioBatch    := g_dep_wk_batch,
    ioProgram  := g_dep_wk_program
  );
  vNextPhase := 2500;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2500: CREATE_WAIT_TASKS — create waiting batch tasks  *)
(*   and extract to vWTasks list                               *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2500 THEN
  (* Create tasks for waiting batch (appends to queues) *)
  FC_STC_CreateTasks(iUnit := vCurWaitUnit, ioSchedule := g_dep_wk_schedule, ioTask := g_dep_wk_task);

  (* Extract waiting batch tasks from queues into vWTasks *)
  vWTaskCnt := 0;
  FOR ti := 1 TO MAX_TRANSPORTERS DO
    vWriteIdx := 0;
    FOR qi := 1 TO g_dep_wk_task[ti].Count DO
      IF g_dep_wk_task[ti].Queue[qi].Unit = vCurWaitUnit THEN
        vWTaskCnt := vWTaskCnt + 1;
        IF vWTaskCnt <= 30 THEN
          vWTasks[vWTaskCnt] := g_dep_wk_task[ti].Queue[qi];
          vWTrans[vWTaskCnt] := ti;
        END_IF;
      ELSE
        vWriteIdx := vWriteIdx + 1;
        IF vWriteIdx <> qi THEN
          g_dep_wk_task[ti].Queue[vWriteIdx] := g_dep_wk_task[ti].Queue[qi];
        END_IF;
      END_IF;
    END_FOR;
    FOR qi := vWriteIdx + 1 TO g_dep_wk_task[ti].Count DO
      g_dep_wk_task[ti].Queue[qi].Unit := 0;
    END_FOR;
    g_dep_wk_task[ti].Count := vWriteIdx;
  END_FOR;

  vNextPhase := 2600;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2600: STATION_CONFLICT — check waiting batch schedule *)
(*   against active batches for same-station overlap           *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2600 THEN
  cap_conflict := FALSE;

  FOR cap_ws := 1 TO g_dep_wk_schedule[vCurWaitUnit].StageCount DO
    IF cap_conflict THEN EXIT; END_IF;

    vCapStn   := g_dep_wk_schedule[vCurWaitUnit].Stages[cap_ws].Station;
    cap_w_entry := g_dep_wk_schedule[vCurWaitUnit].Stages[cap_ws].EntryTime;
    cap_w_exit  := g_dep_wk_schedule[vCurWaitUnit].Stages[cap_ws].ExitTime;
    IF vCapStn = 0 OR cap_w_entry >= cap_w_exit THEN
      (* skip invalid *)
    ELSE

    FOR cap_bi := 1 TO vBatchCount DO
      IF cap_conflict THEN EXIT; END_IF;
      ui := vBatchList[cap_bi];

      FOR cap_as := 1 TO g_dep_wk_schedule[ui].StageCount DO
        IF cap_conflict THEN EXIT; END_IF;

        IF g_dep_wk_schedule[ui].Stages[cap_as].Station = vCapStn THEN
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
                cap_prog_stg := g_dep_wk_schedule[vCurWaitUnit].Stages[cap_ws - 1].ProgramStage;
              ELSE
                cap_prog_stg := 0;
              END_IF;

              IF cap_prog_stg >= 0 AND cap_prog_stg <= 30 THEN
                vOldCal := g_dep_wk_program[vCurWaitUnit].Steps[cap_prog_stg].CalTime;
                vMaxCal := g_dep_wk_program[vCurWaitUnit].Steps[cap_prog_stg].MaxTime;
                vMinCal := g_dep_wk_program[vCurWaitUnit].Steps[cap_prog_stg].MinTime;
                vNewCal := vOldCal + LINT_TO_DINT(cap_need);
                (* Flex cap: min + factor × (max - min) *)
                vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
                IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
                IF vMaxCal <= 0 OR vNewCal <= vMaxCal THEN
                  g_dep_wk_program[vCurWaitUnit].Steps[cap_prog_stg].CalTime := vNewCal;
                  cap_conflict := TRUE;
                END_IF;
              END_IF;

              (* Option 2: shorten active's current stage *)
              IF NOT cap_conflict THEN
                cap_a_prog_stg := g_dep_wk_schedule[cap_a_unit].Stages[cap_as].ProgramStage;
                IF cap_a_prog_stg >= 1 AND cap_a_prog_stg <= 30 THEN
                  vOldCal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime;
                  vMinCal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].MinTime;
                  vNewCal := vOldCal - LINT_TO_DINT(cap_need);
                  IF vNewCal >= vMinCal THEN
                    g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime := vNewCal;
                    cap_conflict := TRUE;
                  ELSE
                    vNextPhase := 9000;  (* Neither option works — reject *)
                  END_IF;
                ELSE
                  vNextPhase := 9000;
                END_IF;
              END_IF;

            ELSE
              (* Case B: Waiting is on station first, active is coming.
                 Option 1: shorten waiting's current stage CalTime.
                 Option 2: extend active's previous stage CalTime. *)
              cap_need := cap_w_exit - cap_a_entry + cap_margin;
              cap_a_unit := ui;

              (* Option 1: shorten waiting's current stage *)
              cap_prog_stg := g_dep_wk_schedule[vCurWaitUnit].Stages[cap_ws].ProgramStage;

              IF cap_prog_stg >= 0 AND cap_prog_stg <= 30 THEN
                vOldCal := g_dep_wk_program[vCurWaitUnit].Steps[cap_prog_stg].CalTime;
                vMinCal := g_dep_wk_program[vCurWaitUnit].Steps[cap_prog_stg].MinTime;
                vNewCal := vOldCal - LINT_TO_DINT(cap_need);
                IF vNewCal >= vMinCal THEN
                  g_dep_wk_program[vCurWaitUnit].Steps[cap_prog_stg].CalTime := vNewCal;
                  cap_conflict := TRUE;
                END_IF;
              END_IF;

              (* Option 2: extend active's previous stage *)
              IF NOT cap_conflict THEN
                IF cap_as >= 2 THEN
                  cap_a_prog_stg := g_dep_wk_schedule[cap_a_unit].Stages[cap_as - 1].ProgramStage;
                  IF cap_a_prog_stg >= 1 AND cap_a_prog_stg <= 30 THEN
                    vOldCal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime;
                    vMaxCal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].MaxTime;
                    vMinCal := g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].MinTime;
                    vNewCal := vOldCal + LINT_TO_DINT(cap_need);
                    (* Flex cap: min + factor × (max - min) *)
                    vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
                    IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
                    IF vMaxCal <= 0 OR vNewCal <= vMaxCal THEN
                      g_dep_wk_program[cap_a_unit].Steps[cap_a_prog_stg].CalTime := vNewCal;
                      cap_conflict := TRUE;
                    ELSE
                      vNextPhase := 9000;  (* Neither option works — reject *)
                    END_IF;
                  ELSE
                    vNextPhase := 9000;
                  END_IF;
                ELSE
                  vNextPhase := 9000;
                END_IF;
              END_IF;
            END_IF;

          END_IF;  (* overlap *)
        END_IF;  (* same station *)
      END_FOR;  (* cap_as *)
    END_FOR;  (* cap_bi *)

    END_IF;  (* valid station *)
  END_FOR;  (* cap_ws *)

  IF vNextPhase = 0 THEN
    IF cap_conflict THEN
      (* Station vConflict resolved by adjusting CalTime — recalc *)
      vFitRound := vFitRound + 1;
      oFitRound := vFitRound;
      IF vFitRound > SCH_MAX_FIT_ROUNDS THEN
        vNextPhase := 9000;
      ELSE
        vSchedBaseTime := iTimeS;
        vNextPhase := 1000;
      END_IF;
    ELSE
      vNextPhase := 3000;
    END_IF;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 3000: FIT_START — begin fitting waiting batch tasks   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 3000 THEN
  vFitTaskStart := 1;

  IF vWTaskCnt < 1 THEN
    vNextPhase := 9000;   (* No tasks -> reject *)
  ELSE
    vNextPhase := 3100;   (* -> FIT_TASK *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 3100+i: FIT_TASK — fit all tasks one per tick         *)
(*   vIdx = vPhase - 3100, task index = vFitTaskStart + vIdx     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase >= 3100 AND vPhase <= 3199 THEN
  vIdx := vPhase - 3100;
  si := vFitTaskStart + vIdx;  (* actual task index *)

  IF si > vWTaskCnt THEN
    (* All tasks fit -> ACTIVATE *)
    vNextPhase := 8000;
  ELSE
    ti := vWTrans[si];

    (* Overlap vDelay check *)
    ovlp_delay_s := FC_DEP_OverlapDelay(
      iLiftStn   := vWTasks[si].LiftStationTarget,
      iSinkStn   := vWTasks[si].SinkStationTarget,
      iTransId   := ti,
      iTaskStart := vWTasks[si].StartTime,
      iTaskEnd   := vWTasks[si].FinishTime,
      iMarginS   := SCH_CONFLICT_MARGIN_S,
      ioTask      := g_dep_wk_task,
      ioOverlap   := g_dep_overlap
    );

    (* Idle-slot fit check *)
    FC_DEP_FitTaskToSlot(
      iLiftStn     := vWTasks[si].LiftStationTarget,
      iSinkStn     := vWTasks[si].SinkStationTarget,
      iTransId     := ti,
      iTaskStart   := vWTasks[si].StartTime,
      iTaskEnd     := vWTasks[si].FinishTime,
      iShiftS      := ovlp_delay_s,
      iCalcTimeS  := vWTasks[si].CalcTime,
      iMinTimeS   := vWTasks[si].MinTime,
      iMaxTimeS   := vWTasks[si].MaxTime,
      iFlexFactor  := SCH_DEP_FLEX_FACTOR,
      iMarginS     := SCH_MARGIN_S,
      iConflictMarginS := SCH_CONFLICT_MARGIN_S,
      ioIdleSlot   := g_dep_idle_slot,
      oResult       := vFitResult
    );

    vTotalDelayS := ovlp_delay_s + DINT_TO_REAL(vFitResult.DelayTime);

    IF vFitResult.Fits THEN
      (* Trim idle slot after successful fit *)
      IF vFitResult.SlotIdx >= 1 AND vFitResult.SlotIdx <= DEP_MAX_IDLE_SLOTS THEN
        g_dep_idle_slot[ti].Slots[vFitResult.SlotIdx].StartTime :=
          vFitResult.TaskEndTime;
        g_dep_idle_slot[ti].Slots[vFitResult.SlotIdx].LiftStationTarget :=
          vWTasks[si].SinkStationTarget;
      END_IF;

      IF vTotalDelayS > SCH_MARGIN_S THEN
        vProgIdx := vWTasks[si].SrcStage;
        IF vProgIdx >= 0 AND vProgIdx <= 30 THEN
          vOldCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime;
          vMaxCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].MaxTime;
          vMinCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].MinTime;
          vNewCal := vOldCal + REAL_TO_DINT(vTotalDelayS);
          vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
          IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
          g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
          vFitRound := vFitRound + 1;
          oFitRound := vFitRound;
          IF vFitRound > SCH_MAX_FIT_ROUNDS THEN
            vNextPhase := 9000;
          ELSE
            (* Recalc all from beginning *)
            vSchedBaseTime := iTimeS;
            vNextPhase := 1000;
          END_IF;
        END_IF;
      END_IF;
      (* else: no significant vDelay, vPhase + 1 = next task *)
    ELSE
      (* Does not fit -> try backward chaining *)
      IF vFitResult.NeedExtraTime <= 0 THEN
        vNextPhase := 9000;
      ELSE
        vRemainingNeed := DINT_TO_REAL(vFitResult.NeedExtraTime);
        vChainDelayCnt := 0;
        vChainOk := FALSE;

        FOR bk := si - 1 TO 1 BY -1 DO
          IF vRemainingNeed <= SCH_MARGIN_S THEN EXIT; END_IF;
          vPrevFlexUp := DINT_TO_REAL(vWTasks[bk].MaxTime - vWTasks[bk].MinTime);
  IF vPrevFlexUp < 0.0 THEN vPrevFlexUp := 0.0; END_IF;
          vPrevCapped := vPrevFlexUp * SCH_DEP_FLEX_FACTOR;
          vUseDelay := vPrevCapped;
  IF vUseDelay > vRemainingNeed THEN vUseDelay := vRemainingNeed; END_IF;

          IF vUseDelay > SCH_MARGIN_S THEN
            vChainDelayCnt := vChainDelayCnt + 1;
            IF vChainDelayCnt <= 10 THEN
              vChainDelays[vChainDelayCnt].Stage   := vWTasks[bk].SrcStage;
              vChainDelays[vChainDelayCnt].DelayTime := REAL_TO_DINT(vUseDelay);
              IF vWTasks[bk].SrcStage = 0 THEN
                vChainDelays[vChainDelayCnt].Target := 0;
              ELSE
                vChainDelays[vChainDelayCnt].Target := 1;
              END_IF;
              vChainDelays[vChainDelayCnt].Valid := TRUE;
            END_IF;
            vRemainingNeed := vRemainingNeed - vUseDelay;
          END_IF;
        END_FOR;

  IF vRemainingNeed <= SCH_MARGIN_S THEN vChainOk := TRUE; END_IF;

        IF vChainOk THEN
          (* Apply chain delays *)
          FOR ci := 1 TO vChainDelayCnt DO
            IF vChainDelays[ci].Valid THEN
              IF vChainDelays[ci].Target = 0 THEN
                vSchedBaseTime := vSchedBaseTime + DINT_TO_LINT(vChainDelays[ci].DelayTime);
              ELSIF vChainDelays[ci].Target = 1 THEN
                vProgIdx := vChainDelays[ci].Stage;
                IF vProgIdx >= 1 AND vProgIdx <= 30 THEN
                  vOldCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime;
                  vMaxCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].MaxTime;
                  vMinCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].MinTime;
                  vNewCal := vOldCal + vChainDelays[ci].DelayTime;
                  vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
                  IF vMaxCal > 0 AND vNewCal > vFlexCap THEN
                    vNewCal := vFlexCap;
                  END_IF;
                  g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

          (* Also apply current task's vDelay *)
          IF vTotalDelayS > SCH_MARGIN_S THEN
            vProgIdx := vWTasks[si].SrcStage;
            IF vProgIdx >= 1 AND vProgIdx <= 30 THEN
              vOldCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime;
              vMaxCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].MaxTime;
              vMinCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].MinTime;
              vNewCal := vOldCal + REAL_TO_DINT(vTotalDelayS);
              vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
              IF vMaxCal > 0 AND vNewCal > vFlexCap THEN
                vNewCal := vFlexCap;
              END_IF;
              g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
            END_IF;
          END_IF;

          vFitRound := vFitRound + 1;
          oFitRound := vFitRound;
          IF vFitRound > SCH_MAX_FIT_ROUNDS THEN
            vNextPhase := 9000;
          ELSE
            vNextPhase := 1000;  (* RECALC *)
          END_IF;
        ELSE
          (* ── Backward chaining insufficient → try widening idle slot
             by stretching/advancing IN_PROCESS batch CalTimes ── *)
          vWidenOk := FALSE;
          vWidenNeed := vRemainingNeed;
          ov_slot_idx := vFitResult.OverflowSlotIdx;

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
               AND border_unit <> vCurWaitUnit
               AND border_src_stage >= 1 AND border_src_stage <= 30 THEN
              (* Flex cap: min + factor × (max - min); available room = vFlexCap - CalTime *)
              vMinCal := g_dep_wk_program[border_unit].Steps[border_src_stage].MinTime;
              vMaxCal := g_dep_wk_program[border_unit].Steps[border_src_stage].MaxTime;
              vOldCal := g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime;
              vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
              border_flex := DINT_TO_REAL(vFlexCap - vOldCal);
  IF border_flex < 0.0 THEN border_flex := 0.0; END_IF;
              border_use := border_flex;
  IF border_use > vWidenNeed THEN border_use := vWidenNeed; END_IF;

              IF border_use > SCH_MARGIN_S THEN
                vNewCal := vOldCal + REAL_TO_DINT(border_use);
  IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
                g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime := vNewCal;
                vWidenNeed := vWidenNeed - border_use;
              END_IF;
            END_IF;

            (* ── Advance LEFT border: find task whose FinishTime = slot StartTime ── *)
            IF vWidenNeed > SCH_MARGIN_S THEN
              border_unit := 0;
              FOR qi := 1 TO g_dep_wk_task[ti].Count DO
                IF g_dep_wk_task[ti].Queue[qi].FinishTime = g_dep_idle_slot[ti].Slots[ov_slot_idx].StartTime THEN
                  border_unit := g_dep_wk_task[ti].Queue[qi].Unit;
                  border_src_stage := g_dep_wk_task[ti].Queue[qi].SrcStage;
                  EXIT;
                END_IF;
              END_FOR;

              IF border_unit >= 1 AND border_unit <= MAX_UNITS
                 AND border_unit <> vCurWaitUnit
                 AND border_src_stage >= 1 AND border_src_stage <= 30 THEN
                border_flex := DINT_TO_REAL(
                  g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime
                - g_dep_wk_program[border_unit].Steps[border_src_stage].MinTime);
  IF border_flex < 0.0 THEN border_flex := 0.0; END_IF;
                border_capped := border_flex * SCH_DEP_FLEX_FACTOR;
                border_use := border_capped;
  IF border_use > vWidenNeed THEN border_use := vWidenNeed; END_IF;

                IF border_use > SCH_MARGIN_S THEN
                  vOldCal := g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime;
                  vMinCal := g_dep_wk_program[border_unit].Steps[border_src_stage].MinTime;
                  vNewCal := vOldCal - REAL_TO_DINT(border_use);
  IF vNewCal < vMinCal THEN vNewCal := vMinCal; END_IF;
                  g_dep_wk_program[border_unit].Steps[border_src_stage].CalTime := vNewCal;
                  vWidenNeed := vWidenNeed - border_use;
                END_IF;
              END_IF;
            END_IF;

  IF vWidenNeed <= SCH_MARGIN_S THEN vWidenOk := TRUE; END_IF;
          END_IF;

          IF vWidenOk THEN
            (* Slot widened → RECALC with modified IN_PROCESS programs *)
            vFitRound := vFitRound + 1;
            oFitRound := vFitRound;
            IF vFitRound > SCH_MAX_FIT_ROUNDS THEN
              vNextPhase := 9000;
            ELSE
              vNextPhase := 1000;  (* RECALC *)
            END_IF;
          ELSE
            vNextPhase := 9000;   (* REJECT *)
          END_IF;
        END_IF;
      END_IF;
    END_IF;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 4000: APPLY_DELAY — write vDelay to program, recalc   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 4000 THEN
  vFitRound := vFitRound + 1;
  oFitRound := vFitRound;
  IF vFitRound > SCH_MAX_FIT_ROUNDS THEN
    vNextPhase := 9000;
  ELSE
    IF vDelayTarget = 1 THEN
      vProgIdx := vDelayStage;
      IF vProgIdx >= 1 AND vProgIdx <= 30 THEN
        vOldCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime;
        vMaxCal := g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].MaxTime;
        vNewCal := vOldCal + REAL_TO_DINT(vDelayAmount);
        IF vNewCal > vMaxCal AND vMaxCal > 0 THEN
          vNewCal := vMaxCal;
        END_IF;
        g_dep_wk_program[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
      END_IF;
    END_IF;
    vNextPhase := 1000;  (* RECALC *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8000: ACTIVATE — commit changes to pending write      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 8000 THEN
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
  g_dep_pending.BatchUnit  := vCurWaitUnit;
  g_dep_pending.BatchStage := 0;
  g_dep_pending.BatchState := IN_PROCESS;
  (* Stage 0 = prepend, read CalcTime/Min/Max from calculated schedule *)
  g_dep_pending.BatchCalTime := g_dep_wk_schedule[vCurWaitUnit].Stages[0].CalcTime;
  g_dep_pending.BatchMinTime := g_dep_wk_schedule[vCurWaitUnit].Stages[0].MinTime;
  g_dep_pending.BatchMaxTime := g_dep_wk_schedule[vCurWaitUnit].Stages[0].MaxTime;
  g_dep_pending.TimeStamp := iTimeS;
  g_dep_pending.Valid     := TRUE;

  g_dep_activated := TRUE;
  oActivated := TRUE;

  (* ── Emit BATCH_ACTIVATED event (msg_type=4) ── *)
  IF NOT g_event_pending_valid THEN
    g_event_pending.MsgType := 4;
    g_event_pending.TsHi := LINT_TO_UINT(iTimeS / LINT#65536);
    g_event_pending.TsLo := LINT_TO_UINT(iTimeS MOD LINT#65536);
    g_event_pending.Payload[1]  := vCurWaitUnit;                        (* unit_id *)
    g_event_pending.Payload[2]  := g_batch[vCurWaitUnit].BatchCode;     (* batch_code *)
    g_event_pending.Payload[3]  := g_batch[vCurWaitUnit].ProgId;        (* program_id *)
    g_event_pending.Payload[4]  := TreatmentPrograms[vCurWaitUnit].StepCount;   (* stages_count *)
    g_event_pending.Payload[5]  := g_dep_wk_schedule[vCurWaitUnit].Stages[0].Station; (* start_station *)
    g_event_pending_valid := TRUE;
  END_IF;

  vNextPhase := 8100;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8100: WAIT_SAVE — wait for TSK to process pending     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 8100 THEN
  IF NOT g_dep_pending.Valid THEN
    vNextPhase := 8500;
  ELSE
    vNextPhase := 8100;  (* stay *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8500: RESTART — back to WAIT_STABLE                   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 8500 THEN
  g_dep_activated := FALSE;
  oRoundTicks := round_ticks;
  round_ticks := 0;
  vNextPhase := 1;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 9000: REJECT — restore sandbox, try next batch        *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 9000 THEN
  FC_DEP_Sandbox(iCmd := 1,
    ioWkSchedule := g_dep_wk_schedule, ioWkBatch := g_dep_wk_batch,
    ioWkProgram := g_dep_wk_program, ioWkTask := g_dep_wk_task);
  oRejectCnt := oRejectCnt + 1;

  vCurWaitIdx := vCurWaitIdx + 1;
  IF vCurWaitIdx > vWaitingCnt THEN
    vNextPhase := 1;
  ELSE
    vNextPhase := 200;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* Unknown vPhase -> reset                                       *)
(* ════════════════════════════════════════════════════════════ *)
ELSE
  vNextPhase := 1;
END_IF;

(* ── Phase advancement ── *)
IF vNextPhase > 0 THEN
  vPhase := vNextPhase;
ELSE
  vPhase := vPhase + 1;
END_IF;
oPhase := vPhase;

END_FUNCTION_BLOCK

(* ===========================================================================================
 *  DEP_FB_Scheduler — Departure scheduler state machine
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
 *  writes results to DepPending for TSK to apply.
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
 *  4000     APPLY_DELAY          (record delay -> recalc loop)
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
 *  Schedule computed for ALL batches (no sandbox copy needed).
 *
 *
 *)


FUNCTION_BLOCK DEP_FB_Scheduler


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iRun                     : BOOL;     (* TRUE = run *)
  iTimeS                  : LINT;     (* current absolute time (s), unix seconds *)
  iTskPhase               : INT;      (* TSK_FB_Scheduler.oPhase *)
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
  Batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  Unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  Schedule                : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  Task                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  DepIdleSlot           : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DepIdleSlotSetType;
  DepOverlap             : UDT_JC_DepOverlapType;
  DepPending             : UDT_JC_DepPendingWriteType;
  DepActivated           : BOOL;
  TskStable              : BOOL;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  DepWaiting             : ARRAY[1..DEP_MAX_WAITING] OF INT;
  DepWaitingCount       : INT;
  DepWkSchedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  DepWkTask             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  DepWkProgram          : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  DepWkBatch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  EventPending           : UDT_JC_EventMsgType;
  EventPendingValid     : BOOL;
END_VAR

VAR_OUTPUT
  oPhase                   : INT;
  oWaitCnt                : INT;
  oActivated               : BOOL;
  oRejectCnt              : INT;
  oFitRound               : INT;
  oCurWaitUnit           : INT;
  oRoundTicks             : INT;     (* ticks consumed by last completed round *)
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
  vFB_Find                   : STC_FB_FindTransporter;
  vFitResult                : UDT_JC_DepFitResultType;

  (* ── Temp variables ── *)
  vTi                        : INT;
  vQi                        : INT;
  vBi                        : INT;
  vUi                        : INT;
  vSi                        : INT;
  vSchedTrans               : INT;
  vWriteIdx                 : INT;
  vOvlpDelayS              : REAL;
  vTotalDelayS             : REAL;
  vProgIdx                  : INT;
  vOldCal                   : DINT;
  vNewCal                   : DINT;
  vMaxCal                   : DINT;
  vEstFinish                : LINT;



  (* ── Backward chaining variables ── *)
  vRemainingNeed            : REAL;
  vChainDelays              : ARRAY[1..10] OF UDT_JC_DepDelayActionType;
  vChainDelayCnt           : INT;
  vChainOk                  : BOOL;
  vPrevFlexUp              : REAL;
  vPrevCapped               : REAL;
  vUseDelay                 : REAL;
  vBk                        : INT;
  vCi                        : INT;

  (* ── Idle-slot widening: stretch IN_PROCESS batches ── *)
  vOvSlotIdx               : INT;
  vWidenNeed                : REAL;
  vWidenOk                  : BOOL;
  vBorderUnit               : INT;
  vBorderSrcStage          : INT;
  vBorderFlex               : REAL;
  vBorderCapped             : REAL;
  vBorderUse                : REAL;
  vMinCal                   : DINT;

  (* ── Sort variables ── *)
  vTmpUnit                  : INT;
  vTmpKey                   : LINT;
  vJi                        : INT;

  (* ── Station conflict (Phase 2600) ── *)
  vCapWs                    : INT;
  vCapAs                    : INT;
  vCapBi                    : INT;
  vCapStn                   : INT;
  vCapWEntry               : LINT;
  vCapWExit                : LINT;
  vCapAEntry               : LINT;
  vCapAExit                : LINT;
  vCapNeed                  : LINT;
  vCapProgStg              : INT;
  vCapAProgStg            : INT;
  vCapAUnit                : INT;
  vCapConflict              : BOOL;
  vCapMargin                : LINT := 2;
  vFlexCap                  : DINT;

  vRoundTicks               : INT := 0;  (* ticks since last RESTART *)
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
  IF iTskPhase >= 10000 AND TskStable THEN
    vNextPhase := 100;
  ELSE
    vNextPhase := 1;  (* stay *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 100: INIT_SNAPSHOT — copy batch+program to sandbox    *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 100 THEN
  DEP_FC_Sandbox(iCmd := 1,
    ioWkSchedule := DepWkSchedule, ioWkBatch := DepWkBatch,
    ioWkProgram := DepWkProgram, ioWkTask := DepWkTask);
  (* vPhase + 1 -> 101 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 101: INIT_COLLECT — find waiting + active batches     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 101 THEN
  vWaitingCnt := STC_FC_CollectActiveBatches(iMode := 1, oList => vWaitingList);
  oWaitCnt := vWaitingCnt;
  oRejectCnt := 0;
  oFitRound := 0;
  oCurWaitUnit := 0;
  DepWaitingCount := vWaitingCnt;
  FOR vUi := 1 TO vWaitingCnt DO
    DepWaiting[vUi] := vWaitingList[vUi];
  END_FOR;

  vBatchCount := STC_FC_CollectActiveBatches(iMode := 0, oList => vBatchList);

  IF vWaitingCnt = 0 THEN
    vNextPhase := 1;
  END_IF;
  (* else vPhase + 1 -> 102 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 102: INIT_SORT_WAITING — FIFO sort by start_time     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 102 THEN
  FOR vSi := 2 TO vWaitingCnt DO
    vTmpUnit := vWaitingList[vSi];
    vTmpKey  := DepWkBatch[vTmpUnit].StartTime;
    vJi := 0;
    FOR vJi := vSi - 1 TO 1 BY -1 DO
      IF DepWkBatch[vWaitingList[vJi]].StartTime > vTmpKey THEN
        vWaitingList[vJi + 1] := vWaitingList[vJi];
      ELSE
        EXIT;
      END_IF;
    END_FOR;
    vWaitingList[vJi + 1] := vTmpUnit;
  END_FOR;
  vCurWaitIdx := 1;
  (* vPhase + 1 -> 103 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 103: INIT_CALC_OVERLAP — compute overlap stations     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 103 THEN
  DEP_FC_CalcOverlap(ioOverlap := DepOverlap);
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
(*   i>vBatchCount: done -> 2000                               *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase >= 1000 AND vPhase <= 1999 THEN
  vIdx := vPhase - 1000;

  IF vIdx < vBatchCount THEN
    (* Calculate schedule for active batch FIRST *)
    vFB_Find(iLiftStn := Unit[vBatchList[vIdx + 1]].location, iSinkStn := 0);
    vSchedTrans := vFB_Find.oTrans;
  IF vSchedTrans = 0 THEN vSchedTrans := 1; END_IF;

    STC_FC_CalcSchedule(
      iUnit   := vBatchList[vIdx + 1],
      iTrans  := vSchedTrans,
      iTimeS := iTimeS,
      ioSchedule := DepWkSchedule,
      ioBatch    := DepWkBatch,
      ioProgram  := DepWkProgram
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
  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    DepWkTask[vTi].Count := 0;
    FOR vQi := 1 TO MAX_TASK_QUEUE DO
      DepWkTask[vTi].Queue[vQi].Unit := 0;
    END_FOR;
  END_FOR;
  (* vPhase + 1 -> 2001 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2001+i: CREATE_TASKS — active batches only            *)
(*   i=0..vBatchCount-1: active batches                        *)
(*   i>=vBatchCount: done -> 2100                              *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase >= 2001 AND vPhase <= 2099 THEN
  vIdx := vPhase - 2001;

  IF vIdx < vBatchCount THEN
    STC_FC_CreateTasks(iUnit := vBatchList[vIdx + 1], ioSchedule := DepWkSchedule, ioTask := DepWkTask);
    (* vPhase + 1 -> next batch *)

  ELSE
    vNextPhase := 2100;
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2100: SORT_TASKS — sort all queues by start_time      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2100 THEN
  STC_FC_SortTasks(iTrans := 0, iTimeS := iTimeS, ioTask := DepWkTask, ioBatch := DepWkBatch);
  (* vPhase + 1 -> 2101 *)

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2101: SWAP_TASKS — swap same-station pairs            *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2101 THEN
  STC_FC_SwapTasks(ioTask := DepWkTask);
  vNextPhase := 2200;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2200: INJECT_IN_FLIGHT — inject active transporter    *)
(*   pseudo-tasks into task queues                             *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2200 THEN

  (* Inject in-flight pseudo-tasks for active transporters *)
  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    IF TransporterStatus[vTi].Phase >= 1 AND TransporterStatus[vTi].Phase <= 4 THEN
      vEstFinish := iTimeS + DINT_TO_LINT(TransporterStatus[vTi].TaskRemainingTime);
      IF vEstFinish > iTimeS AND DepWkTask[vTi].Count < 30 THEN
        (* Remove schedule-derived task matching in-flight transfer *)
        FOR vQi := 1 TO DepWkTask[vTi].Count DO
          IF DepWkTask[vTi].Queue[vQi].LiftStationTarget = TransporterStatus[vTi].LiftStationTarget
             AND DepWkTask[vTi].Queue[vQi].SinkStationTarget = TransporterStatus[vTi].SinkStationTarget THEN
            FOR vBi := vQi TO DepWkTask[vTi].Count - 1 DO
              DepWkTask[vTi].Queue[vBi] := DepWkTask[vTi].Queue[vBi + 1];
            END_FOR;
            DepWkTask[vTi].Queue[DepWkTask[vTi].Count].Unit := 0;
            DepWkTask[vTi].Count := DepWkTask[vTi].Count - 1;
            EXIT;
          END_IF;
        END_FOR;
        (* Shift existing tasks up by 1 *)
        FOR vQi := DepWkTask[vTi].Count TO 1 BY -1 DO
          DepWkTask[vTi].Queue[vQi + 1] := DepWkTask[vTi].Queue[vQi];
        END_FOR;
        (* Insert in-flight pseudo-task at position 1 *)
        DepWkTask[vTi].Queue[1].Unit              := 0;
        DepWkTask[vTi].Queue[1].Stage             := -1;
        DepWkTask[vTi].Queue[1].LiftStationTarget := TransporterStatus[vTi].LiftStationTarget;
        DepWkTask[vTi].Queue[1].SinkStationTarget := TransporterStatus[vTi].SinkStationTarget;
        DepWkTask[vTi].Queue[1].StartTime         := iTimeS;
        DepWkTask[vTi].Queue[1].FinishTime        := vEstFinish;
        DepWkTask[vTi].Queue[1].CalcTime          := 0;
        DepWkTask[vTi].Queue[1].MinTime           := 0;
        DepWkTask[vTi].Queue[1].MaxTime           := 0;
        DepWkTask[vTi].Count := DepWkTask[vTi].Count + 1;
      END_IF;
    END_IF;
  END_FOR;

  vNextPhase := 2300;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2300: CALC_IDLE — calc idle slots for all transporters*)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2300 THEN
  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    DEP_FC_CalcIdleSlots(iTrans := vTi, iTimeS := iTimeS,
                      ioTask := DepWkTask, ioIdleSlot := DepIdleSlot);
  END_FOR;

  vNextPhase := 2400;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2400: CALC_WAIT_SCHEDULE — calculate waiting batch    *)
(*   schedule (after idle slots are ready)                     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2400 THEN
  vFB_Find(iLiftStn := Unit[vCurWaitUnit].location, iSinkStn := 0);
  vSchedTrans := vFB_Find.oTrans;
  IF vSchedTrans = 0 THEN vSchedTrans := 1; END_IF;

  STC_FC_CalcSchedule(
    iUnit   := vCurWaitUnit,
    iTrans  := vSchedTrans,
    iTimeS := vSchedBaseTime,
    ioSchedule := DepWkSchedule,
    ioBatch    := DepWkBatch,
    ioProgram  := DepWkProgram
  );
  vNextPhase := 2500;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2500: CREATE_WAIT_TASKS — create waiting batch tasks  *)
(*   and extract to vWTasks list                               *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2500 THEN
  (* Create tasks for waiting batch (appends to queues) *)
  STC_FC_CreateTasks(iUnit := vCurWaitUnit, ioSchedule := DepWkSchedule, ioTask := DepWkTask);

  (* Extract waiting batch tasks from queues into vWTasks *)
  vWTaskCnt := 0;
  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    vWriteIdx := 0;
    FOR vQi := 1 TO DepWkTask[vTi].Count DO
      IF DepWkTask[vTi].Queue[vQi].Unit = vCurWaitUnit THEN
        vWTaskCnt := vWTaskCnt + 1;
        IF vWTaskCnt <= 30 THEN
          vWTasks[vWTaskCnt] := DepWkTask[vTi].Queue[vQi];
          vWTrans[vWTaskCnt] := vTi;
        END_IF;
      ELSE
        vWriteIdx := vWriteIdx + 1;
        IF vWriteIdx <> vQi THEN
          DepWkTask[vTi].Queue[vWriteIdx] := DepWkTask[vTi].Queue[vQi];
        END_IF;
      END_IF;
    END_FOR;
    FOR vQi := vWriteIdx + 1 TO DepWkTask[vTi].Count DO
      DepWkTask[vTi].Queue[vQi].Unit := 0;
    END_FOR;
    DepWkTask[vTi].Count := vWriteIdx;
  END_FOR;

  vNextPhase := 2600;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 2600: STATION_CONFLICT — check waiting batch schedule *)
(*   against active batches for same-station overlap           *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 2600 THEN
  vCapConflict := FALSE;

  FOR vCapWs := 1 TO DepWkSchedule[vCurWaitUnit].StageCount DO
    IF vCapConflict THEN EXIT; END_IF;

    vCapStn   := DepWkSchedule[vCurWaitUnit].Stages[vCapWs].station;
    vCapWEntry := DepWkSchedule[vCurWaitUnit].Stages[vCapWs].EntryTime;
    vCapWExit  := DepWkSchedule[vCurWaitUnit].Stages[vCapWs].ExitTime;
    IF vCapStn = 0 OR vCapWEntry >= vCapWExit THEN
      (* skip invalid *)
    ELSE

    FOR vCapBi := 1 TO vBatchCount DO
      IF vCapConflict THEN EXIT; END_IF;
      vUi := vBatchList[vCapBi];

      FOR vCapAs := 1 TO DepWkSchedule[vUi].StageCount DO
        IF vCapConflict THEN EXIT; END_IF;

        IF DepWkSchedule[vUi].Stages[vCapAs].station = vCapStn THEN
          vCapAEntry := DepWkSchedule[vUi].Stages[vCapAs].EntryTime;
          vCapAExit  := DepWkSchedule[vUi].Stages[vCapAs].ExitTime;

          (* Check overlap: max(w_entry, a_entry) < min(w_exit, a_exit) *)
          IF vCapWEntry < vCapAExit AND vCapAEntry < vCapWExit THEN

            IF vCapAEntry <= vCapWEntry THEN
              (* Case A: Active is on station when waiting arrives.
                 Option 1: extend waiting's previous stage CalTime.
                 Option 2: shorten active's current stage CalTime. *)
              vCapNeed := vCapAExit - vCapWEntry + vCapMargin;
              vCapAUnit := vUi;

              (* Option 1: extend waiting's previous stage *)
              IF vCapWs >= 2 THEN
                vCapProgStg := DepWkSchedule[vCurWaitUnit].Stages[vCapWs - 1].ProgramStage;
              ELSE
                vCapProgStg := 0;
              END_IF;

              IF vCapProgStg >= 0 AND vCapProgStg <= 30 THEN
                vOldCal := DepWkProgram[vCurWaitUnit].Steps[vCapProgStg].CalTime;
                vMaxCal := DepWkProgram[vCurWaitUnit].Steps[vCapProgStg].MaxTime;
                vMinCal := DepWkProgram[vCurWaitUnit].Steps[vCapProgStg].MinTime;
                vNewCal := vOldCal + LINT_TO_DINT(vCapNeed);
                (* Flex cap: min + factor × (max - min) *)
                vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
                IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
                IF vMaxCal <= 0 OR vNewCal <= vMaxCal THEN
                  DepWkProgram[vCurWaitUnit].Steps[vCapProgStg].CalTime := vNewCal;
                  vCapConflict := TRUE;
                END_IF;
              END_IF;

              (* Option 2: shorten active's current stage *)
              IF NOT vCapConflict THEN
                vCapAProgStg := DepWkSchedule[vCapAUnit].Stages[vCapAs].ProgramStage;
                IF vCapAProgStg >= 1 AND vCapAProgStg <= 30 THEN
                  vOldCal := DepWkProgram[vCapAUnit].Steps[vCapAProgStg].CalTime;
                  vMinCal := DepWkProgram[vCapAUnit].Steps[vCapAProgStg].MinTime;
                  vNewCal := vOldCal - LINT_TO_DINT(vCapNeed);
                  IF vNewCal >= vMinCal THEN
                    DepWkProgram[vCapAUnit].Steps[vCapAProgStg].CalTime := vNewCal;
                    vCapConflict := TRUE;
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
              vCapNeed := vCapWExit - vCapAEntry + vCapMargin;
              vCapAUnit := vUi;

              (* Option 1: shorten waiting's current stage *)
              vCapProgStg := DepWkSchedule[vCurWaitUnit].Stages[vCapWs].ProgramStage;

              IF vCapProgStg >= 0 AND vCapProgStg <= 30 THEN
                vOldCal := DepWkProgram[vCurWaitUnit].Steps[vCapProgStg].CalTime;
                vMinCal := DepWkProgram[vCurWaitUnit].Steps[vCapProgStg].MinTime;
                vNewCal := vOldCal - LINT_TO_DINT(vCapNeed);
                IF vNewCal >= vMinCal THEN
                  DepWkProgram[vCurWaitUnit].Steps[vCapProgStg].CalTime := vNewCal;
                  vCapConflict := TRUE;
                END_IF;
              END_IF;

              (* Option 2: extend active's previous stage *)
              IF NOT vCapConflict THEN
                IF vCapAs >= 2 THEN
                  vCapAProgStg := DepWkSchedule[vCapAUnit].Stages[vCapAs - 1].ProgramStage;
                  IF vCapAProgStg >= 1 AND vCapAProgStg <= 30 THEN
                    vOldCal := DepWkProgram[vCapAUnit].Steps[vCapAProgStg].CalTime;
                    vMaxCal := DepWkProgram[vCapAUnit].Steps[vCapAProgStg].MaxTime;
                    vMinCal := DepWkProgram[vCapAUnit].Steps[vCapAProgStg].MinTime;
                    vNewCal := vOldCal + LINT_TO_DINT(vCapNeed);
                    (* Flex cap: min + factor × (max - min) *)
                    vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
                    IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
                    IF vMaxCal <= 0 OR vNewCal <= vMaxCal THEN
                      DepWkProgram[vCapAUnit].Steps[vCapAProgStg].CalTime := vNewCal;
                      vCapConflict := TRUE;
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
      END_FOR;  (* vCapAs *)
    END_FOR;  (* vCapBi *)

    END_IF;  (* valid station *)
  END_FOR;  (* vCapWs *)

  IF vNextPhase = 0 THEN
    IF vCapConflict THEN
      (* Station conflict resolved by adjusting CalTime — recalc *)
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
  vSi := vFitTaskStart + vIdx;  (* actual task index *)

  IF vSi > vWTaskCnt THEN
    (* All tasks fit -> ACTIVATE *)
    vNextPhase := 8000;
  ELSE
    vTi := vWTrans[vSi];

    (* Overlap delay check *)
    vOvlpDelayS := DEP_FC_OverlapDelay(
      iLiftStn   := vWTasks[vSi].LiftStationTarget,
      iSinkStn   := vWTasks[vSi].SinkStationTarget,
      iTransId   := vTi,
      iTaskStart := vWTasks[vSi].StartTime,
      iTaskEnd   := vWTasks[vSi].FinishTime,
      iMarginS   := SCH_CONFLICT_MARGIN_S,
      ioTask      := DepWkTask,
      ioOverlap   := DepOverlap
    );

    (* Idle-slot fit check *)
    DEP_FC_FitTaskToSlot(
      iLiftStn     := vWTasks[vSi].LiftStationTarget,
      iSinkStn     := vWTasks[vSi].SinkStationTarget,
      iTransId     := vTi,
      iTaskStart   := vWTasks[vSi].StartTime,
      iTaskEnd     := vWTasks[vSi].FinishTime,
      iShiftS      := vOvlpDelayS,
      iCalcTimeS  := vWTasks[vSi].CalcTime,
      iMinTimeS   := vWTasks[vSi].MinTime,
      iMaxTimeS   := vWTasks[vSi].MaxTime,
      iFlexFactor  := SCH_DEP_FLEX_FACTOR,
      iMarginS     := SCH_MARGIN_S,
      iConflictMarginS := SCH_CONFLICT_MARGIN_S,
      ioIdleSlot   := DepIdleSlot,
      ioOResult       := vFitResult
    );

    vTotalDelayS := vOvlpDelayS + DINT_TO_REAL(vFitResult.DelayTime);

    IF vFitResult.Fits THEN
      (* Trim idle slot after successful fit *)
      IF vFitResult.SlotIdx >= 1 AND vFitResult.SlotIdx <= DEP_MAX_IDLE_SLOTS THEN
        DepIdleSlot[vTi].Slots[vFitResult.SlotIdx].StartTime :=
          vFitResult.TaskEndTime;
        DepIdleSlot[vTi].Slots[vFitResult.SlotIdx].LiftStationTarget :=
          vWTasks[vSi].SinkStationTarget;
      END_IF;

      IF vTotalDelayS > SCH_MARGIN_S THEN
        vProgIdx := vWTasks[vSi].SrcStage;
        IF vProgIdx >= 0 AND vProgIdx <= 30 THEN
          vOldCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime;
          vMaxCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].MaxTime;
          vMinCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].MinTime;
          vNewCal := vOldCal + REAL_TO_DINT(vTotalDelayS);
          vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
          IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
          DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
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
      (* else: no significant delay, vPhase + 1 = next task *)
    ELSE
      (* Does not fit -> try backward chaining *)
      IF vFitResult.NeedExtraTime <= 0 THEN
        vNextPhase := 9000;
      ELSE
        vRemainingNeed := DINT_TO_REAL(vFitResult.NeedExtraTime);
        vChainDelayCnt := 0;
        vChainOk := FALSE;

        FOR vBk := vSi - 1 TO 1 BY -1 DO
          IF vRemainingNeed <= SCH_MARGIN_S THEN EXIT; END_IF;
          vPrevFlexUp := DINT_TO_REAL(vWTasks[vBk].MaxTime - vWTasks[vBk].MinTime);
  IF vPrevFlexUp < 0.0 THEN vPrevFlexUp := 0.0; END_IF;
          vPrevCapped := vPrevFlexUp * SCH_DEP_FLEX_FACTOR;
          vUseDelay := vPrevCapped;
  IF vUseDelay > vRemainingNeed THEN vUseDelay := vRemainingNeed; END_IF;

          IF vUseDelay > SCH_MARGIN_S THEN
            vChainDelayCnt := vChainDelayCnt + 1;
            IF vChainDelayCnt <= 10 THEN
              vChainDelays[vChainDelayCnt].Stage   := vWTasks[vBk].SrcStage;
              vChainDelays[vChainDelayCnt].DelayTime := REAL_TO_DINT(vUseDelay);
              IF vWTasks[vBk].SrcStage = 0 THEN
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
          FOR vCi := 1 TO vChainDelayCnt DO
            IF vChainDelays[vCi].Valid THEN
              IF vChainDelays[vCi].Target = 0 THEN
                vSchedBaseTime := vSchedBaseTime + DINT_TO_LINT(vChainDelays[vCi].DelayTime);
              ELSIF vChainDelays[vCi].Target = 1 THEN
                vProgIdx := vChainDelays[vCi].Stage;
                IF vProgIdx >= 1 AND vProgIdx <= 30 THEN
                  vOldCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime;
                  vMaxCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].MaxTime;
                  vMinCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].MinTime;
                  vNewCal := vOldCal + vChainDelays[vCi].DelayTime;
                  vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
                  IF vMaxCal > 0 AND vNewCal > vFlexCap THEN
                    vNewCal := vFlexCap;
                  END_IF;
                  DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;

          (* Also apply current task's delay *)
          IF vTotalDelayS > SCH_MARGIN_S THEN
            vProgIdx := vWTasks[vSi].SrcStage;
            IF vProgIdx >= 1 AND vProgIdx <= 30 THEN
              vOldCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime;
              vMaxCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].MaxTime;
              vMinCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].MinTime;
              vNewCal := vOldCal + REAL_TO_DINT(vTotalDelayS);
              vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
              IF vMaxCal > 0 AND vNewCal > vFlexCap THEN
                vNewCal := vFlexCap;
              END_IF;
              DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
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
          vOvSlotIdx := vFitResult.OverflowSlotIdx;

          IF vOvSlotIdx >= 1 AND vOvSlotIdx <= DepIdleSlot[vTi].Count THEN
            (* ── Stretch RIGHT border: find task whose StartTime = slot EndTime ── *)
            vBorderUnit := 0;
            FOR vQi := 1 TO DepWkTask[vTi].Count DO
              IF DepWkTask[vTi].Queue[vQi].StartTime = DepIdleSlot[vTi].Slots[vOvSlotIdx].EndTime THEN
                vBorderUnit := DepWkTask[vTi].Queue[vQi].Unit;
                vBorderSrcStage := DepWkTask[vTi].Queue[vQi].SrcStage;
                EXIT;
              END_IF;
            END_FOR;

            IF vBorderUnit >= 1 AND vBorderUnit <= MAX_UNITS
               AND vBorderUnit <> vCurWaitUnit
               AND vBorderSrcStage >= 1 AND vBorderSrcStage <= 30 THEN
              (* Flex cap: min + factor × (max - min); available room = vFlexCap - CalTime *)
              vMinCal := DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].MinTime;
              vMaxCal := DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].MaxTime;
              vOldCal := DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].CalTime;
              vFlexCap := vMinCal + REAL_TO_DINT(SCH_DEP_FLEX_FACTOR * DINT_TO_REAL(vMaxCal - vMinCal));
              vBorderFlex := DINT_TO_REAL(vFlexCap - vOldCal);
  IF vBorderFlex < 0.0 THEN vBorderFlex := 0.0; END_IF;
              vBorderUse := vBorderFlex;
  IF vBorderUse > vWidenNeed THEN vBorderUse := vWidenNeed; END_IF;

              IF vBorderUse > SCH_MARGIN_S THEN
                vNewCal := vOldCal + REAL_TO_DINT(vBorderUse);
  IF vMaxCal > 0 AND vNewCal > vFlexCap THEN vNewCal := vFlexCap; END_IF;
                DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].CalTime := vNewCal;
                vWidenNeed := vWidenNeed - vBorderUse;
              END_IF;
            END_IF;

            (* ── Advance LEFT border: find task whose FinishTime = slot StartTime ── *)
            IF vWidenNeed > SCH_MARGIN_S THEN
              vBorderUnit := 0;
              FOR vQi := 1 TO DepWkTask[vTi].Count DO
                IF DepWkTask[vTi].Queue[vQi].FinishTime = DepIdleSlot[vTi].Slots[vOvSlotIdx].StartTime THEN
                  vBorderUnit := DepWkTask[vTi].Queue[vQi].Unit;
                  vBorderSrcStage := DepWkTask[vTi].Queue[vQi].SrcStage;
                  EXIT;
                END_IF;
              END_FOR;

              IF vBorderUnit >= 1 AND vBorderUnit <= MAX_UNITS
                 AND vBorderUnit <> vCurWaitUnit
                 AND vBorderSrcStage >= 1 AND vBorderSrcStage <= 30 THEN
                vBorderFlex := DINT_TO_REAL(
                  DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].CalTime
                - DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].MinTime);
  IF vBorderFlex < 0.0 THEN vBorderFlex := 0.0; END_IF;
                vBorderCapped := vBorderFlex * SCH_DEP_FLEX_FACTOR;
                vBorderUse := vBorderCapped;
  IF vBorderUse > vWidenNeed THEN vBorderUse := vWidenNeed; END_IF;

                IF vBorderUse > SCH_MARGIN_S THEN
                  vOldCal := DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].CalTime;
                  vMinCal := DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].MinTime;
                  vNewCal := vOldCal - REAL_TO_DINT(vBorderUse);
  IF vNewCal < vMinCal THEN vNewCal := vMinCal; END_IF;
                  DepWkProgram[vBorderUnit].Steps[vBorderSrcStage].CalTime := vNewCal;
                  vWidenNeed := vWidenNeed - vBorderUse;
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
(* PHASE 4000: APPLY_DELAY — write delay to program, recalc   *)
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
        vOldCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime;
        vMaxCal := DepWkProgram[vCurWaitUnit].Steps[vProgIdx].MaxTime;
        vNewCal := vOldCal + REAL_TO_DINT(vDelayAmount);
        IF vNewCal > vMaxCal AND vMaxCal > 0 THEN
          vNewCal := vMaxCal;
        END_IF;
        DepWkProgram[vCurWaitUnit].Steps[vProgIdx].CalTime := vNewCal;
      END_IF;
    END_IF;
    vNextPhase := 1000;  (* RECALC *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8000: ACTIVATE — commit changes to pending write      *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 8000 THEN
  FOR vUi := 1 TO MAX_UNITS DO
    DepPending.Programs[vUi] := DepWkProgram[vUi];
  END_FOR;
  (* Write active batch CalTimes from sandbox programs *)
  FOR vUi := 1 TO MAX_UNITS DO
    IF DepWkBatch[vUi].State = IN_PROCESS
       AND DepWkBatch[vUi].CurStage >= 1
       AND DepWkBatch[vUi].CurStage <= DepWkProgram[vUi].StepCount THEN
      DepPending.ActiveBatchCalTime[vUi] := DepWkProgram[vUi].Steps[DepWkBatch[vUi].CurStage].CalTime;
    ELSE
      DepPending.ActiveBatchCalTime[vUi] := 0;
    END_IF;
  END_FOR;
  DepPending.BatchUnit  := vCurWaitUnit;
  DepPending.BatchStage := 0;
  DepPending.BatchState := IN_PROCESS;
  (* Stage 0 = prepend, read CalcTime/Min/Max from calculated schedule *)
  DepPending.BatchCalTime := DepWkSchedule[vCurWaitUnit].Stages[0].CalcTime;
  DepPending.BatchMinTime := DepWkSchedule[vCurWaitUnit].Stages[0].MinTime;
  DepPending.BatchMaxTime := DepWkSchedule[vCurWaitUnit].Stages[0].MaxTime;
  DepPending.TimeStamp := iTimeS;
  DepPending.Valid     := TRUE;

  DepActivated := TRUE;
  oActivated := TRUE;

  (* ── Emit BATCH_ACTIVATED event (msg_type=4) ── *)
  IF NOT EventPendingValid THEN
    EventPending.MsgType := 4;
    EventPending.TsHi := LINT_TO_UINT(iTimeS / LINT#65536);
    EventPending.TsLo := LINT_TO_UINT(iTimeS MOD LINT#65536);
    EventPending.Payload[1]  := vCurWaitUnit;                        (* unit_id *)
    EventPending.Payload[2]  := Batch[vCurWaitUnit].BatchCode;     (* batch_code *)
    EventPending.Payload[3]  := Batch[vCurWaitUnit].ProgId;        (* program_id *)
    EventPending.Payload[4]  := TreatmentPrograms[vCurWaitUnit].StepCount;   (* stages_count *)
    EventPending.Payload[5]  := DepWkSchedule[vCurWaitUnit].Stages[0].Station; (* start_station *)
    EventPendingValid := TRUE;
  END_IF;

  vNextPhase := 8100;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8100: WAIT_SAVE — wait for TSK to process pending     *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 8100 THEN
  IF NOT DepPending.Valid THEN
    vNextPhase := 8500;
  ELSE
    vNextPhase := 8100;  (* stay *)
  END_IF;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 8500: RESTART — back to WAIT_STABLE                   *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 8500 THEN
  DepActivated := FALSE;
  oRoundTicks := vRoundTicks;
  vRoundTicks := 0;
  vNextPhase := 1;

(* ════════════════════════════════════════════════════════════ *)
(* PHASE 9000: REJECT — restore sandbox, try next batch        *)
(* ════════════════════════════════════════════════════════════ *)
ELSIF vPhase = 9000 THEN
  DEP_FC_Sandbox(iCmd := 1,
    ioWkSchedule := DepWkSchedule, ioWkBatch := DepWkBatch,
    ioWkProgram := DepWkProgram, ioWkTask := DepWkTask);
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

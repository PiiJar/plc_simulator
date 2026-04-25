(* GVL_JC_Scheduler — Simulator-internal global variables *)
(* Identical names to globals.st VAR_GLOBAL — no renaming needed *)
VAR_GLOBAL
  (* ===== Simulation Transporter State ===== *)
  gSimTrans               : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;  (* physics + scheduler command state *)

  (* ===== No-Treatment Task Destinations ===== *)
  gNtt                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;  (* no-treatment task destinations *)

  (* ===== Precomputed Movement Times ===== *)
  gMove                   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;  (* precomputed movement times per transporter *)

  (* ===== Actual (Measured) Move Times ===== *)
  gActualMove             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ActualMoveTimeType;  (* phase timestamps updated after each completed task *)

  (* ===== Unit Schedule ===== *)
  gSchedule               : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;  (* calculated schedule per unit *)

  (* ===== Task Queues ===== *)
  gTask                   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;  (* task queue per transporter *)

  (* ===== Departure Scheduler State ===== *)
  gDepWkSchedule          : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;  (* DEP workspace: schedules *)
  gDepWkTask              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;  (* DEP workspace: task queues *)
  gDepWkProgram           : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;  (* DEP workspace: programs *)
  gDepWkBatch             : ARRAY[1..MAX_UNITS] OF UDT_BatchType;  (* DEP workspace: batch state *)
  gDepIdleSlot            : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DepIdleSlotSetType;  (* idle slots per transporter *)
  gDepWaiting             : ARRAY[1..DEP_MAX_WAITING] OF INT;  (* waiting batch unit indices *)
  gDepWaitingCount        : INT;  (* number of waiting batches *)
  gDepOverlap             : UDT_JC_DepOverlapType;  (* overlap station flags *)
  gDepPending             : UDT_JC_DepPendingWriteType;  (* ACTIVATE write buffer *)
  gDepActivated           : BOOL;  (* handshake TSK ← DEP *)
  gTskStable              : BOOL;  (* tasksStableFlag: TRUE when last TSK cycle reached READY+conflict_free, cleared only on DEP activation/reset *)
  gConflictResolved       : BOOL;  (* TRUE when TSK Analyze found no conflicts — gate for DEP *)


  (* ===== Scheduler Debug Observability ===== *)
  gSchedDbgTskPhase       : INT;  (* TSK scheduler current phase *)
  gSchedDbgDepPhase       : INT;  (* DEP scheduler current phase *)
  gSchedDbgTurn           : INT;  (* 1=TSK ran, 2=DEP ran this cycle *)
  gSchedDbgSkipCnt        : INT;  (* DEP skip count *)
  gSchedDbgDepRejectCnt   : INT;  (* DEP reject count this cycle *)
  gSchedDbgDepFitRound    : INT;  (* DEP fit round counter *)
  gSchedDbgDepCurWaitUnit : INT;  (* DEP current waiting batch unit *)
  gSchedDbgDepWaitCnt     : INT;  (* DEP waiting batch count *)
  gSchedDbgBatchCnt       : INT;  (* TSK active batch count *)
  gSchedDbgTskRoundTicks  : INT;  (* TSK ticks consumed by last completed round *)
  gSchedDbgDepRoundTicks  : INT;  (* DEP ticks consumed by last completed round *)


  (* ===== TSK Conflict Debug (non-LINT for OPC UA) ===== *)
  gDbgTskConflictType     : INT;   (* last analyze: 0=none, 1=TASK_SEQ, 2=COLLISION, 3=HANDOFF *)
  gDbgTskConflictIter     : INT;   (* resolve iterations this cycle *)
  gDbgTskConfUnit         : INT;   (* conflict task unit *)
  gDbgTskConfStage        : INT;   (* conflict task stage *)
  gDbgTskBlockedUnit      : INT;   (* blocked task unit *)
  gDbgTskBlockedStage     : INT;   (* blocked task stage *)
  gDbgTskDeficit          : DINT;  (* last deficit in seconds *)
  gDbgTskStretchCnt       : INT;   (* stretches applied this cycle *)
  gDbgTskTotalAdv         : DINT;  (* total advance seconds this cycle *)
  gDbgTskTotalDelay       : DINT;  (* total delay seconds this cycle *)
  gDbgProgCal             : ARRAY[1..MAX_UNITS] OF DINT;  (* current stage CalTime snapshot per unit *)

  (* ===== Production Queue ===== *)
  gProductionQueue        : INT;  (* 1=batches in queue, 0=queue empty *)

  (* ===== Unix Time ===== *)
  gTimeS                  : LINT;  (* absolute time in unix seconds *)
  gTime100ms              : LINT;  (* absolute time in 0.1s ticks *)
  gTimeSync               : LINT;  (* gateway writes real unix seconds here at init *)
  gTimeOffset             : LINT;  (* gTimeSync - uptime_s at init *)

  (* ===== Event Queue ===== *)
  gEvent                  : UDT_JC_EventQueueType;  (* circular event buffer *)
  gEventPending           : UDT_JC_EventMsgType;  (* staging slot — written by other FBs *)
  gEventPendingValid      : BOOL;  (* TRUE = pending message ready to enqueue *)
  gEventAckSeq            : INT;   (* Gateway writes ack_seq via OPC UA to consume head message *)

  (* ===== UI Snapshot (SIM only — stable schedule for gateway reads) ===== *)
  gSimUiSchedule          : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gSimUiTask              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  gSimUiWaitUnit          : INT;   (* current waiting batch unit, 0 = none *)
  gSimUiWaitReason        : INT;   (* 0=pending, 1=NO_SLOT, 2=DELAY_TOO_LARGE, 3=STATION_CONFLICT, 4=MAX_ROUNDS *)

  (* ===== Dispatched Task (Executor Input) ===== *)
  gDispatchedTask         : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;  (* filled by Dispatcher, read by Executor *)

  (* ===== Manual Task Commands ===== *)
  gManualTask             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ManualTaskType;  (* gateway writes, PLC clears Valid after execution *)

  (* ===== OPC UA Gateway Command Interface ===== *)
  (* Gateway writes gCmdCode + gCmdParam via OPC UA.
     PLC processes when gCmdCode <> 0, then clears it.
     Commands:
       2 = init       (param = station_count)  — finalize config, start runtime
       3 = clear      — zero all config, stop runtime
  *)
  gCmdCode                : INT;   (* command code, non-zero = trigger *)
  gCmdParam               : INT;   (* command parameter *)
END_VAR

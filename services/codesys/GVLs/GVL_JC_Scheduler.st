{attribute 'qualified_only'}
(* GVL_JC_Scheduler — Simulator-internal global variables *)
VAR_GLOBAL
  (* ===== Simulation Transporter State ===== *)
  SimTrans                   : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_SimTransporterType;  (* physics + scheduler command state *)

  (* ===== No-Treatment Task Destinations ===== *)
  Ntt                         : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;  (* no-treatment task destinations *)

  (* ===== Precomputed Movement Times ===== *)
  Move                        : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;  (* precomputed movement times per transporter *)

  (* ===== Actual (Measured) Move Times ===== *)
  ActualMove                 : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ActualMoveTimeType;  (* phase timestamps updated after each completed task *)

  (* ===== Unit Schedule ===== *)
  Schedule                    : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;  (* calculated schedule per unit *)

  (* ===== Task Queues ===== *)
  Task                        : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;  (* task queue per transporter *)

  (* ===== Departure Scheduler State ===== *)
  DepWkSchedule             : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;  (* DEP workspace: schedules *)
  DepWkTask                 : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;  (* DEP workspace: task queues *)
  DepWkProgram              : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;  (* DEP workspace: programs *)
  DepWkBatch                : ARRAY[1..MAX_UNITS] OF UDT_BatchType;  (* DEP workspace: batch state *)
  DepIdleSlot               : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DepIdleSlotSetType;  (* idle slots per transporter *)
  DepWaiting                 : ARRAY[1..DEP_MAX_WAITING] OF INT;  (* waiting batch unit indices *)
  DepWaitingCount           : INT;  (* number of waiting batches *)
  DepOverlap                 : UDT_JC_DepOverlapType;  (* overlap station flags *)
  DepPending                 : UDT_JC_DepPendingWriteType;  (* ACTIVATE write buffer *)
  DepActivated               : BOOL;  (* handshake TSK ← DEP *)
  TskStable                  : BOOL;  (* tasksStableFlag: TRUE when last TSK cycle reached READY+conflict_free, cleared only on DEP activation/reset *)
  ConflictResolved           : BOOL;  (* TRUE when TSK Analyze found no conflicts — gate for DEP *)


  (* ===== Scheduler Debug Observability ===== *)
  SchedDbgTskPhase         : INT;  (* TSK scheduler current phase *)
  SchedDbgDepPhase         : INT;  (* DEP scheduler current phase *)
  SchedDbgTurn              : INT;  (* 1=TSK ran, 2=DEP ran this cycle *)
  SchedDbgSkipCnt          : INT;  (* DEP skip count *)
  SchedDbgDepRejectCnt    : INT;  (* DEP reject count this cycle *)
  SchedDbgDepFitRound     : INT;  (* DEP fit round counter *)
  SchedDbgDepCurWaitUnit : INT;  (* DEP current waiting batch unit *)
  SchedDbgDepWaitCnt      : INT;  (* DEP waiting batch count *)
  SchedDbgBatchCnt         : INT;  (* TSK active batch count *)
  SchedDbgTskRoundTicks    : INT;  (* TSK ticks consumed by last completed round *)
  SchedDbgDepRoundTicks    : INT;  (* DEP ticks consumed by last completed round *)


  (* ===== TSK Conflict Debug (non-LINT for OPC UA) ===== *)
  DbgTskConflictType       : INT;   (* last analyze: 0=none, 1=TASK_SEQ, 2=COLLISION, 3=HANDOFF *)
  DbgTskConflictIter       : INT;   (* resolve iterations this cycle *)
  DbgTskConfUnit           : INT;   (* conflict task unit *)
  DbgTskConfStage          : INT;   (* conflict task stage *)
  DbgTskBlockedUnit        : INT;   (* blocked task unit *)
  DbgTskBlockedStage       : INT;   (* blocked task stage *)
  DbgTskDeficit             : DINT;  (* last deficit in seconds *)
  DbgTskStretchCnt         : INT;   (* stretches applied this cycle *)
  DbgTskTotalAdv           : DINT;  (* total advance seconds this cycle *)
  DbgTskTotalDelay         : DINT;  (* total delay seconds this cycle *)
  DbgProgCal                : ARRAY[1..MAX_UNITS] OF DINT;  (* current stage CalTime snapshot per unit *)

  (* ===== Production Queue ===== *)
  ProductionQueue            : INT;  (* 1=batches in queue, 0=queue empty *)

  (* ===== Unix Time ===== *)
  TimeS                      : LINT;  (* absolute time in unix seconds *)
  Time100ms                  : LINT;  (* absolute time in 0.1s ticks *)
  TimeSync                   : LINT;  (* gateway writes real unix seconds here at init *)
  TimeOffset                 : LINT;  (* TimeSync - uptime_s at init *)

  (* ===== Event Queue ===== *)
  Event                       : UDT_JC_EventQueueType;  (* circular event buffer *)
  EventPending               : UDT_JC_EventMsgType;  (* staging slot — written by other FBs *)
  EventPendingValid         : BOOL;  (* TRUE = pending message ready to enqueue *)
  EventAckSeq               : INT;   (* Gateway writes ack_seq via OPC UA to consume head message *)

  (* ===== UI Snapshot (SIM only — stable schedule for gateway reads) ===== *)
  SimUiSchedule             : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  SimUiTask                 : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
  SimUiWaitUnit            : INT;   (* current waiting batch unit, 0 = none *)
  SimUiWaitReason          : INT;   (* 0=pending, 1=NO_SLOT, 2=DELAY_TOO_LARGE, 3=STATION_CONFLICT, 4=MAX_ROUNDS *)

  (* ===== Dispatched Task (Executor Input) ===== *)
  DispatchedTask             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_DispatchedTaskType;  (* filled by Dispatcher, read by Executor *)

  (* ===== Manual Task Commands ===== *)
  ManualTask                 : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ManualTaskType;  (* gateway writes, PLC clears Valid after execution *)

  (* ===== OPC UA Gateway Command Interface ===== *)
  (* Gateway writes CmdCode + CmdParam via OPC UA.
     PLC processes when CmdCode <> 0, then clears it.
     Commands:
       2 = init       (param = station_count)  — finalize config, start runtime
       3 = clear      — zero all config, stop runtime
  *)
  CmdCode                    : INT;   (* command code, non-zero = trigger *)
  CmdParam                   : INT;   (* command parameter *)
END_VAR

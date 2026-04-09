(* GVL_JC_Scheduler — Simulator-internal global variables *)
(* Identical names to globals.st VAR_GLOBAL — no renaming needed *)
VAR_GLOBAL
  (* ===== Simulation Transporter State ===== *)
  g_sim_trans                   : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;  (* physics + scheduler command state *)

  (* ===== No-Treatment Task Destinations ===== *)
  g_ntt                         : ARRAY[1..MAX_Transporters] OF UDT_JC_NttTransporterType;  (* no-treatment task destinations *)

  (* ===== Precomputed Movement Times ===== *)
  g_move                        : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;  (* precomputed movement times per transporter *)

  (* ===== Actual (Measured) Move Times ===== *)
  g_actual_move                 : ARRAY[1..MAX_Transporters] OF UDT_JC_ActualMoveTimeType;  (* phase timestamps updated after each completed task *)

  (* ===== Unit Schedule ===== *)
  g_schedule                    : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;  (* calculated schedule per unit *)

  (* ===== Task Queues ===== *)
  g_task                        : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;  (* task queue per transporter *)

  (* ===== Departure Scheduler State ===== *)
  g_dep_wk_schedule             : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;  (* DEP workspace: schedules *)
  g_dep_wk_task                 : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;  (* DEP workspace: task queues *)
  g_dep_wk_program              : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;  (* DEP workspace: programs *)
  g_dep_wk_batch                : ARRAY[1..MAX_Units] OF UDT_BatchType;  (* DEP workspace: batch state *)
  g_dep_idle_slot               : ARRAY[1..MAX_Transporters] OF UDT_JC_DepIdleSlotSetType;  (* idle slots per transporter *)
  g_dep_waiting                 : ARRAY[1..DEP_MAX_WAITING] OF INT;  (* waiting batch unit indices *)
  g_dep_waiting_count           : INT;  (* number of waiting batches *)
  g_dep_overlap                 : UDT_JC_DepOverlapType;  (* overlap station flags *)
  g_dep_pending                 : UDT_JC_DepPendingWriteType;  (* ACTIVATE write buffer *)
  g_dep_activated               : BOOL;  (* handshake TSK ← DEP *)
  g_tsk_stable                  : BOOL;  (* tasksStableFlag: TRUE when last TSK cycle reached READY+conflict_free, cleared only on DEP activation/reset *)
  g_conflict_resolved           : BOOL;  (* TRUE when TSK Analyze found no conflicts — gate for DEP *)


  (* ===== Scheduler Debug Observability ===== *)
  g_sched_dbg_tsk_phase         : INT;  (* TSK scheduler current phase *)
  g_sched_dbg_dep_phase         : INT;  (* DEP scheduler current phase *)
  g_sched_dbg_turn              : INT;  (* 1=TSK ran, 2=DEP ran this cycle *)
  g_sched_dbg_skip_cnt          : INT;  (* DEP skip count *)
  g_sched_dbg_dep_reject_cnt    : INT;  (* DEP reject count this cycle *)
  g_sched_dbg_dep_fit_round     : INT;  (* DEP fit round counter *)
  g_sched_dbg_dep_cur_wait_unit : INT;  (* DEP current waiting batch unit *)
  g_sched_dbg_dep_wait_cnt      : INT;  (* DEP waiting batch count *)
  g_sched_dbg_batch_cnt         : INT;  (* TSK active batch count *)
  g_sched_dbg_tsk_round_ticks    : INT;  (* TSK ticks consumed by last completed round *)
  g_sched_dbg_dep_round_ticks    : INT;  (* DEP ticks consumed by last completed round *)


  (* ===== TSK Conflict Debug (non-LINT for OPC UA) ===== *)
  g_dbg_tsk_conflict_type       : INT;   (* last analyze: 0=none, 1=TASK_SEQ, 2=COLLISION, 3=HANDOFF *)
  g_dbg_tsk_conflict_iter       : INT;   (* resolve iterations this cycle *)
  g_dbg_tsk_conf_unit           : INT;   (* conflict task unit *)
  g_dbg_tsk_conf_stage          : INT;   (* conflict task stage *)
  g_dbg_tsk_blocked_unit        : INT;   (* blocked task unit *)
  g_dbg_tsk_blocked_stage       : INT;   (* blocked task stage *)
  g_dbg_tsk_deficit             : DINT;  (* last deficit in seconds *)
  g_dbg_tsk_stretch_cnt         : INT;   (* stretches applied this cycle *)
  g_dbg_tsk_total_adv           : DINT;  (* total advance seconds this cycle *)
  g_dbg_tsk_total_delay         : DINT;  (* total delay seconds this cycle *)
  g_dbg_prog_cal                : ARRAY[1..MAX_Units] OF DINT;  (* current stage CalTime snapshot per unit *)

  (* ===== Production Queue ===== *)
  g_production_queue            : INT;  (* 1=batches in queue, 0=queue empty *)

  (* ===== Unix Time ===== *)
  g_time_s                      : LINT;  (* absolute time in unix seconds *)
  g_time_100ms                  : LINT;  (* absolute time in 0.1s ticks *)
  g_time_sync                   : LINT;  (* gateway writes real unix seconds here at init *)
  g_time_offset                 : LINT;  (* g_time_sync - uptime_s at init *)

  (* ===== Event Queue ===== *)
  g_event                       : UDT_JC_EventQueueType;  (* circular event buffer *)
  g_event_pending               : UDT_JC_EventMsgType;  (* staging slot — written by other FBs *)
  g_event_pending_valid         : BOOL;  (* TRUE = pending message ready to enqueue *)
  g_event_ack_seq               : INT;   (* Gateway writes ack_seq via OPC UA to consume head message *)

  (* ===== UI Snapshot (SIM only — stable schedule for gateway reads) ===== *)
  g_sim_ui_schedule             : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_sim_ui_task                 : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_sim_ui_wait_unit            : INT;   (* current waiting batch unit, 0 = none *)
  g_sim_ui_wait_reason          : INT;   (* 0=pending, 1=NO_SLOT, 2=DELAY_TOO_LARGE, 3=STATION_CONFLICT, 4=MAX_ROUNDS *)

  (* ===== Manual Task Commands ===== *)
  g_manual_task                 : ARRAY[1..MAX_Transporters] OF UDT_JC_ManualTaskType;  (* gateway writes, PLC clears Valid after execution *)

  (* ===== OPC UA Gateway Command Interface ===== *)
  (* Gateway writes g_cmd_code + g_cmd_param via OPC UA.
     PLC processes when g_cmd_code <> 0, then clears it.
     Commands:
       2 = init       (param = station_count)  — finalize config, start runtime
       3 = clear      — zero all config, stop runtime
  *)
  g_cmd_code                    : INT;   (* command code, non-zero = trigger *)
  g_cmd_param                   : INT;   (* command parameter *)
END_VAR

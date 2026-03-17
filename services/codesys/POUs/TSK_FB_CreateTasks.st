(* ============================================================
   TSK_FB_CreateTasks — Build task list from schedule
   ============================================================
   Ported from transporterTaskScheduler.js createTaskListFromSchedule()

   For each consecutive stage pair in g_schedule[unit]:
     - Lift station = current stage station
     - Sink station = next stage station
     - Assigns transporter from task_area match in g_cfg
     - Skips already completed stages (stage < batch.CurStage)
   Appends tasks to g_task[transporter].Queue.

   Called once per batch per scheduler cycle.
   ============================================================ *)

FUNCTION_BLOCK TSK_FB_CreateTasks
VAR_INPUT
  i_unit : INT;   (* unit index 1..10 *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
    MAX_TASK_QUEUE   : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex : INT;
END_VAR

VAR_EXTERNAL
  g_batch  : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_schedule : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_task    : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_cfg    : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_station : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
END_VAR
VAR
  si         : INT;     (* schedule stage index *)
  sc         : INT;     (* stage count *)
  lift_stn   : INT;     (* lift station *)
  sink_stn   : INT;     (* sink station *)
  tid        : INT;     (* transporter id found *)
  qi         : INT;     (* queue write index *)
  fb_find    : STC_FindTransporter;  (* transporter lookup *)
  (* Cross-transfer detection — JS: isCrossTransporterOp + findCrossTransporterEndStation *)
  eff_lift_stn : INT;   (* effective lift station after cross-transfer check *)
END_VAR

IF i_unit < 1 OR i_unit > MAX_Units THEN RETURN; END_IF;

sc := g_schedule[i_unit].StageCount;
IF sc < 2 THEN RETURN; END_IF;

(* CalcSchedule already builds a schedule starting from the batch's
   current stage (and prepends the unit's current location when needed).
   No skip logic needed here — every consecutive pair is a valid task. *)

(* Loop through consecutive stage pairs *)
FOR si := 1 TO sc - 1 DO
  lift_stn := g_schedule[i_unit].Stages[si].station;
  sink_stn := g_schedule[i_unit].Stages[si + 1].station;

  IF lift_stn > 0 AND sink_stn > 0 THEN
    (* -- Cross-transfer detection -- *)
    (* JS: if station.operation === 10 && lift.y_position !== sink.y_position
       → use ChangeStation as effective lift (belt other end, same line as sink) *)
    eff_lift_stn := lift_stn;
    IF lift_stn >= MIN_StationIndex AND lift_stn <= MAX_StationIndex
       AND sink_stn >= MIN_StationIndex AND sink_stn <= MAX_StationIndex THEN
      IF g_station[lift_stn].Crosstransport > 0
         AND g_station[lift_stn].ChangeStation > 0
         AND g_station[lift_stn].YPosition <> g_station[sink_stn].YPosition THEN
        eff_lift_stn := g_station[lift_stn].ChangeStation;
      END_IF;
    END_IF;

    (* -- Find transporter via task_area matching (with scoring) -- *)
    fb_find(i_lift_stn := eff_lift_stn, i_sink_stn := sink_stn);
    tid := fb_find.o_trans;

    (* -- Append task to transporter queue -- *)
    IF tid >= 1 AND tid <= 3 THEN
      qi := g_task[tid].Count + 1;
      IF qi <= MAX_TASK_QUEUE THEN
        g_task[tid].Queue[qi].Unit         := i_unit;
        g_task[tid].Queue[qi].Stage        := si;  (* schedule index — used by Resolve/ShiftSchedule as g_schedule array index *)
        g_task[tid].Queue[qi].LiftStationTarget := eff_lift_stn;
        g_task[tid].Queue[qi].SinkStationTarget := sink_stn;
        g_task[tid].Queue[qi].StartTime   := g_schedule[i_unit].Stages[si].ExitTime;
        g_task[tid].Queue[qi].FinishTime  := g_schedule[i_unit].Stages[si + 1].EntryTime;
        g_task[tid].Queue[qi].CalcTime    := g_schedule[i_unit].Stages[si].CalcTime;
        g_task[tid].Queue[qi].MinTime     := g_schedule[i_unit].Stages[si].MinTime;
        g_task[tid].Queue[qi].MaxTime     := g_schedule[i_unit].Stages[si].MaxTime;
        g_task[tid].Count := qi;
      END_IF;
    END_IF;
  END_IF;
END_FOR;

END_FUNCTION_BLOCK

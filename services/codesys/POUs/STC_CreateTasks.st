(* ===========================================================================================
 *  STC_CreateTasks — Build task list from schedule for one unit
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Shared FC: both TSK and DEP call this with different arrays.
 *  Creates transporter tasks from the calculated schedule stages
 *  and appends them to the task queues.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_CreateTasks : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_unit                    : INT;
END_VAR

VAR_IN_OUT
  io_schedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_Units               : INT;
    MAX_TASK_QUEUE          : INT;
    MIN_StationIndex        : INT;
    MAX_StationIndex        : INT;
END_VAR

VAR_EXTERNAL
  g_cfg                     : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_station                 : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
END_VAR

VAR
  si                        : INT;
  sc                        : INT;
  lift_stn                  : INT;
  sink_stn                  : INT;
  tid                       : INT;
  qi                        : INT;
  fb_find                   : STC_FindTransporter;
  eff_lift_stn              : INT;
END_VAR

STC_CreateTasks := FALSE;
IF i_unit < 1 OR i_unit > MAX_Units THEN RETURN; END_IF;

sc := io_schedule[i_unit].StageCount;
IF sc < 2 THEN RETURN; END_IF;

FOR si := 1 TO sc - 1 DO
  lift_stn := io_schedule[i_unit].Stages[si].station;
  sink_stn := io_schedule[i_unit].Stages[si + 1].station;

  IF lift_stn > 0 AND sink_stn > 0 THEN
    eff_lift_stn := lift_stn;
    IF lift_stn >= MIN_StationIndex AND lift_stn <= MAX_StationIndex
       AND sink_stn >= MIN_StationIndex AND sink_stn <= MAX_StationIndex THEN
      IF g_station[lift_stn].Crosstransport > 0
         AND g_station[lift_stn].ChangeStation > 0
         AND g_station[lift_stn].YPosition <> g_station[sink_stn].YPosition THEN
        eff_lift_stn := g_station[lift_stn].ChangeStation;
      END_IF;
    END_IF;

    fb_find(i_lift_stn := eff_lift_stn, i_sink_stn := sink_stn);
    tid := fb_find.o_trans;

    IF tid >= 1 AND tid <= 3 THEN
      qi := io_task[tid].Count + 1;
      IF qi <= MAX_TASK_QUEUE THEN
        io_task[tid].Queue[qi].Unit         := i_unit;
        io_task[tid].Queue[qi].Stage        := io_schedule[i_unit].Stages[si + 1].ProgramStage;
        io_task[tid].Queue[qi].SrcStage     := io_schedule[i_unit].Stages[si].ProgramStage;
        io_task[tid].Queue[qi].LiftStationTarget := eff_lift_stn;
        io_task[tid].Queue[qi].SinkStationTarget := sink_stn;
        io_task[tid].Queue[qi].StartTime   := io_schedule[i_unit].Stages[si].ExitTime;
        io_task[tid].Queue[qi].FinishTime  := io_schedule[i_unit].Stages[si + 1].EntryTime;
        io_task[tid].Queue[qi].CalcTime    := io_schedule[i_unit].Stages[si].CalcTime;
        io_task[tid].Queue[qi].MinTime     := io_schedule[i_unit].Stages[si].MinTime;
        io_task[tid].Queue[qi].MaxTime     := io_schedule[i_unit].Stages[si].MaxTime;
        io_task[tid].Count := qi;
      END_IF;
    END_IF;
  END_IF;
END_FOR;

STC_CreateTasks := TRUE;

END_FUNCTION

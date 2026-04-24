(* ===========================================================================================
 *  FC_STC_CreateTasks — Build task list from schedule for one unit
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


FUNCTION FC_STC_CreateTasks : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iUnit                    : INT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 10=MAX_UNITS, 3=MAX_TRANSPORTERS *)
  ioSchedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    MAX_TASK_QUEUE          : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
END_VAR

VAR_EXTERNAL
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
END_VAR

VAR
  si                        : INT;
  sc                        : INT;
  vLiftStn                  : INT;
  vSinkStn                  : INT;
  tid                       : INT;
  qi                        : INT;
  vFB_FindTransporter                   : FB_STC_FindTransporter;
  vEffLiftStn              : INT;
END_VAR

FC_STC_CreateTasks := FALSE;
IF iUnit < 1 OR iUnit > MAX_UNITS THEN RETURN; END_IF;

sc := ioSchedule[iUnit].StageCount;
IF sc < 1 THEN RETURN; END_IF;

(* Start from 0 if Stages[0] exists (prepend), else from 1 *)
FOR si := 0 TO sc - 1 DO
  IF ioSchedule[iUnit].Stages[si].Station = 0 THEN
    (* Skip unused stage slot *)
  ELSE
    vLiftStn := ioSchedule[iUnit].Stages[si].Station;
    vSinkStn := ioSchedule[iUnit].Stages[si + 1].Station;

    IF vLiftStn > 0 AND vSinkStn > 0 THEN
      vEffLiftStn := vLiftStn;
      IF vLiftStn >= MIN_STATION_INDEX AND vLiftStn <= MAX_STATION_INDEX
         AND vSinkStn >= MIN_STATION_INDEX AND vSinkStn <= MAX_STATION_INDEX THEN
        IF Stations[vLiftStn].Crosstransport > 0
           AND Stations[vLiftStn].ChangeStation > 0
           AND Stations[vLiftStn].YPosition <> Stations[vSinkStn].YPosition THEN
          vEffLiftStn := Stations[vLiftStn].ChangeStation;
        END_IF;
      END_IF;

      vFB_FindTransporter(iLiftStn := vEffLiftStn, iSinkStn := vSinkStn);
      tid := vFB_FindTransporter.oTrans;

      IF tid >= 1 AND tid <= 3 THEN
        qi := ioTask[tid].Count + 1;
        IF qi <= MAX_TASK_QUEUE THEN
          ioTask[tid].Queue[qi].Unit         := iUnit;
          ioTask[tid].Queue[qi].Stage        := ioSchedule[iUnit].Stages[si + 1].ProgramStage;
          ioTask[tid].Queue[qi].SrcStage     := ioSchedule[iUnit].Stages[si].ProgramStage;
          ioTask[tid].Queue[qi].LiftStationTarget := vEffLiftStn;
          ioTask[tid].Queue[qi].SinkStationTarget := vSinkStn;
          ioTask[tid].Queue[qi].StartTime   := ioSchedule[iUnit].Stages[si].ExitTime;
          ioTask[tid].Queue[qi].FinishTime  := ioSchedule[iUnit].Stages[si + 1].EntryTime;
          ioTask[tid].Queue[qi].CalcTime    := ioSchedule[iUnit].Stages[si].CalcTime;
          ioTask[tid].Queue[qi].MinTime     := ioSchedule[iUnit].Stages[si].MinTime;
          ioTask[tid].Queue[qi].MaxTime     := ioSchedule[iUnit].Stages[si].MaxTime;
          ioTask[tid].Count := qi;
        END_IF;
      END_IF;
    END_IF;
  END_IF; (* skip unused stage slot *)
END_FOR;

FC_STC_CreateTasks := TRUE;

END_FUNCTION

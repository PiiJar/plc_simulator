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
  vSi                        : INT;
  vSc                        : INT;
  vLiftStn                  : INT;
  vSinkStn                  : INT;
  vTid                       : INT;
  vQi                        : INT;
  vFB_FindTransporter                   : FB_STC_FindTransporter;
  vEffLiftStn              : INT;
END_VAR

FC_STC_CreateTasks := FALSE;
IF iUnit < 1 OR iUnit > MAX_UNITS THEN RETURN; END_IF;

vSc := ioSchedule[iUnit].StageCount;
IF vSc < 1 THEN RETURN; END_IF;

(* Start from 0 if Stages[0] exists (prepend), else from 1 *)
FOR vSi := 0 TO vSc - 1 DO
  IF ioSchedule[iUnit].Stages[vSi].Station = 0 THEN
    (* Skip unused stage slot *)
  ELSE
    vLiftStn := ioSchedule[iUnit].Stages[vSi].Station;
    vSinkStn := ioSchedule[iUnit].Stages[vSi + 1].Station;

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
      vTid := vFB_FindTransporter.oTrans;

      IF vTid >= 1 AND vTid <= 3 THEN
        vQi := ioTask[vTid].Count + 1;
        IF vQi <= MAX_TASK_QUEUE THEN
          ioTask[vTid].Queue[vQi].Unit         := iUnit;
          ioTask[vTid].Queue[vQi].Stage        := ioSchedule[iUnit].Stages[vSi + 1].ProgramStage;
          ioTask[vTid].Queue[vQi].SrcStage     := ioSchedule[iUnit].Stages[vSi].ProgramStage;
          ioTask[vTid].Queue[vQi].LiftStationTarget := vEffLiftStn;
          ioTask[vTid].Queue[vQi].SinkStationTarget := vSinkStn;
          ioTask[vTid].Queue[vQi].StartTime   := ioSchedule[iUnit].Stages[vSi].ExitTime;
          ioTask[vTid].Queue[vQi].FinishTime  := ioSchedule[iUnit].Stages[vSi + 1].EntryTime;
          ioTask[vTid].Queue[vQi].CalcTime    := ioSchedule[iUnit].Stages[vSi].CalcTime;
          ioTask[vTid].Queue[vQi].MinTime     := ioSchedule[iUnit].Stages[vSi].MinTime;
          ioTask[vTid].Queue[vQi].MaxTime     := ioSchedule[iUnit].Stages[vSi].MaxTime;
          ioTask[vTid].Count := vQi;
        END_IF;
      END_IF;
    END_IF;
  END_IF; (* skip unused stage slot *)
END_FOR;

FC_STC_CreateTasks := TRUE;

END_FUNCTION

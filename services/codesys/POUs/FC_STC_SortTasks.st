(* ===========================================================================================
 *  FC_STC_SortTasks — Insertion sort task queues by vPriority
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Shared FC: both TSK and DEP call this with different arrays.
 *  Priority: emergency (overtime ratio > 1.0) first, then
 *  vEarliest StartTime.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_SortTasks : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTrans                   : INT;    (* 0 = all, 1..3 = specific transporter *)
  iTimeS                  : LINT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS, 10=MAX_UNITS *)
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  ioBatch                  : ARRAY[1..10] OF UDT_BatchType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    IN_PROCESS              : INT;
END_VAR

VAR_EXTERNAL
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
END_VAR

VAR
  ti                        : INT;
  t_start                   : INT;
  t_end                     : INT;
  vInsI                     : INT;
  vInsJ                     : INT;
  vInsCnt                   : INT;
  vTmpTask                  : UDT_JC_TskTaskType;
  vTmpUnit                  : INT;
  vCurUnit                  : INT;
  vTmpRatio                 : REAL;
  vCurRatio                 : REAL;
  vTmpEmerg                 : BOOL;
  vCurEmerg                 : BOOL;
  vDoShift                  : BOOL;
END_VAR

FC_STC_SortTasks := TRUE;

IF iTrans >= 1 AND iTrans <= 3 THEN
  t_start := iTrans;
  t_end   := iTrans;
ELSE
  t_start := 1;
  t_end   := 3;
END_IF;

FOR ti := t_start TO t_end DO
  vInsCnt := ioTask[ti].Count;
  IF vInsCnt >= 2 THEN
    FOR vInsI := 2 TO vInsCnt DO
      vTmpTask := ioTask[ti].Queue[vInsI];

      vTmpRatio := 0.0;
      vTmpUnit  := vTmpTask.Unit;
      IF vTmpUnit >= 1 AND vTmpUnit <= MAX_UNITS THEN
        IF ioBatch[vTmpUnit].State = IN_PROCESS
           AND vTmpTask.Stage >= 1 THEN
          IF ioBatch[vTmpUnit].CurStage = vTmpTask.Stage
             AND g_unit[vTmpUnit].vLocation = vTmpTask.LiftStationTarget
             AND ioBatch[vTmpUnit].StartTime > LINT#0
             AND ioBatch[vTmpUnit].MaxTime > 0 THEN
            vTmpRatio := LINT_TO_REAL(iTimeS - ioBatch[vTmpUnit].StartTime)
                         / DINT_TO_REAL(ioBatch[vTmpUnit].MaxTime);
          END_IF;
        END_IF;
      END_IF;
      vTmpEmerg := vTmpRatio > 1.0;

      vInsJ := 0;
      FOR vInsJ := vInsI - 1 TO 1 BY -1 DO
        vCurRatio := 0.0;
        vCurUnit  := ioTask[ti].Queue[vInsJ].Unit;
        IF vCurUnit >= 1 AND vCurUnit <= MAX_UNITS THEN
          IF ioBatch[vCurUnit].State = IN_PROCESS
             AND ioTask[ti].Queue[vInsJ].Stage >= 1 THEN
            IF ioBatch[vCurUnit].CurStage = ioTask[ti].Queue[vInsJ].Stage
               AND g_unit[vCurUnit].vLocation = ioTask[ti].Queue[vInsJ].LiftStationTarget
               AND ioBatch[vCurUnit].StartTime > LINT#0
               AND ioBatch[vCurUnit].MaxTime > 0 THEN
              vCurRatio := LINT_TO_REAL(iTimeS - ioBatch[vCurUnit].StartTime)
                           / DINT_TO_REAL(ioBatch[vCurUnit].MaxTime);
            END_IF;
          END_IF;
        END_IF;
        vCurEmerg := vCurRatio > 1.0;

        vDoShift := FALSE;
        IF vTmpEmerg AND NOT vCurEmerg THEN
          vDoShift := TRUE;
        ELSIF vTmpEmerg AND vCurEmerg THEN
          IF vTmpRatio > vCurRatio THEN
            vDoShift := TRUE;
          END_IF;
        ELSIF NOT vTmpEmerg AND NOT vCurEmerg THEN
          IF ioTask[ti].Queue[vInsJ].StartTime > vTmpTask.StartTime THEN
            vDoShift := TRUE;
          END_IF;
        END_IF;

        IF NOT vDoShift THEN EXIT; END_IF;

        ioTask[ti].Queue[vInsJ + 1] := ioTask[ti].Queue[vInsJ];
      END_FOR;

      ioTask[ti].Queue[vInsJ + 1] := vTmpTask;
    END_FOR;
  END_IF;
END_FOR;

END_FUNCTION

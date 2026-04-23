(* ===========================================================================================
 *  TSK_FC_Analyze — Conflict analysis for task list
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Read-only analysis: never writes globals.
 *
 *  Three conflict checks, each stops at first hit:
 *  1. TASK_SEQUENCE
 *  2. CROSS_TRANSPORTER_HANDOFF
 *  3. TRANSPORTER_COLLISION
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION TSK_FC_Analyze : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
END_VAR

VAR_EXTERNAL
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
END_VAR

VAR_OUTPUT
  oHasConflict            : BOOL;
  oConfType               : INT;     (* 1=TASK_SEQUENCE, 2=COLLISION, 3=HANDOFF *)
  oConfUnit               : INT;
  oConfStage              : INT;
  oConfTrans              : INT;
  oBlockedUnit            : INT;
  oBlockedStage           : INT;
  oDeficit                 : REAL;
  oCheckedCount             : INT;
END_VAR

VAR
  vTi                        : INT;
  vTj                        : INT;
  vQi                        : INT;
  vQj                        : INT;
  vPrevSink                 : INT;
  vNextLift                 : INT;
  vTravelS                  : REAL;
  vGapS                     : REAL;
  vDeficitS                 : REAL;
  vLiftX                    : REAL;
  vSinkX                    : REAL;
  vX1Min                    : REAL;
  vX1Max                    : REAL;
  vX2Min                    : REAL;
  vX2Max                    : REAL;
  vXoStart                  : REAL;
  vXoEnd                    : REAL;
  vToStart                  : LINT;
  vToEnd                    : LINT;
  vLIdx                     : INT;
  vSIdx                     : INT;
  vLiftX2                   : REAL;
  vSinkX2                   : REAL;
  vLIdx2                    : INT;
  vSIdx2                    : INT;
  vCurUnit                  : INT;
  vCurStage                 : INT;
  vFoundNext                : BOOL;
  vRecvPrevEnd             : LINT;
  vRecvPrevSink            : INT;
  vHasRecvPrev             : BOOL;
  vRk                        : INT;
  vRecvPrevUnit            : INT;
  vRecvPrevStg             : INT;
  vRecvTravel               : REAL;
  vRecvEarliest             : LINT;
  vHandoffDeficit           : REAL;
  vTotalTasks               : INT;
  vDeficitTol               : REAL := 1.0;
  vTmpMove                  : UDT_JC_MoveTimesType;
END_VAR

TSK_FC_Analyze := FALSE;
oHasConflict := FALSE;
oConfType    := 0;
oDeficit      := 0.0;
oCheckedCount  := 0;

vTotalTasks := 0;
FOR vTi := 1 TO MAX_TRANSPORTERS DO
  vTotalTasks := vTotalTasks + ioTask[vTi].Count;
END_FOR;
IF vTotalTasks = 0 THEN RETURN; END_IF;

(* CHECK 1: TASK_SEQUENCE *)
FOR vTi := 1 TO MAX_TRANSPORTERS DO
  FOR vQi := 1 TO ioTask[vTi].Count - 1 DO
    IF ioTask[vTi].Queue[vQi].Unit > 0 AND ioTask[vTi].Queue[vQi + 1].Unit > 0 THEN
      vPrevSink := ioTask[vTi].Queue[vQi].SinkStationTarget;
      vNextLift := ioTask[vTi].Queue[vQi + 1].LiftStationTarget;
      vTmpMove := Move[vTi];
      vTravelS := STC_FC_CalcHorizontalTravel(iFromStn := vPrevSink, iToStn := vNextLift, iMove := vTmpMove);
      vGapS := LINT_TO_REAL(ioTask[vTi].Queue[vQi + 1].StartTime - ioTask[vTi].Queue[vQi].FinishTime);
      vDeficitS := vTravelS - vGapS;
      IF vDeficitS > vDeficitTol THEN
  oHasConflict := TRUE;
  oConfType := 1;
        oConfUnit := ioTask[vTi].Queue[vQi + 1].Unit;
        oConfStage := ioTask[vTi].Queue[vQi + 1].Stage;
        oConfTrans := vTi;
        oBlockedUnit := ioTask[vTi].Queue[vQi].Unit;
        oBlockedStage := ioTask[vTi].Queue[vQi].Stage;
  oDeficit := vDeficitS;
  oCheckedCount := vTotalTasks;
  TSK_FC_Analyze := TRUE; RETURN;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* CHECK 2: CROSS_TRANSPORTER_HANDOFF *)
FOR vTi := 1 TO MAX_TRANSPORTERS DO
  FOR vQi := 1 TO ioTask[vTi].Count DO
    vCurUnit  := ioTask[vTi].Queue[vQi].Unit;
    vCurStage := ioTask[vTi].Queue[vQi].Stage;
    IF vCurUnit > 0 THEN
      vFoundNext := FALSE;
      FOR vTj := 1 TO MAX_TRANSPORTERS DO
        IF vTj <> vTi AND NOT vFoundNext THEN
          FOR vQj := 1 TO ioTask[vTj].Count DO
            IF NOT vFoundNext THEN
              IF ioTask[vTj].Queue[vQj].Unit = vCurUnit
                 AND ioTask[vTj].Queue[vQj].Stage = vCurStage + 1 THEN
                vFoundNext := TRUE;
                vHasRecvPrev := FALSE;
  vRecvPrevEnd := 0;
  vRecvPrevSink := 0;
  vRecvPrevUnit := 0;
  vRecvPrevStg := 0;
                FOR vRk := 1 TO ioTask[vTj].Count DO
                  IF vRk <> vQj THEN
                    IF ioTask[vTj].Queue[vRk].FinishTime <= ioTask[vTj].Queue[vQj].StartTime THEN
                      IF NOT vHasRecvPrev OR ioTask[vTj].Queue[vRk].FinishTime > vRecvPrevEnd THEN
                        vHasRecvPrev := TRUE;
                        vRecvPrevEnd  := ioTask[vTj].Queue[vRk].FinishTime;
                        vRecvPrevSink := ioTask[vTj].Queue[vRk].SinkStationTarget;
                        vRecvPrevUnit := ioTask[vTj].Queue[vRk].Unit;
                        vRecvPrevStg  := ioTask[vTj].Queue[vRk].Stage;
                      END_IF;
                    END_IF;
                  END_IF;
                END_FOR;
                IF vHasRecvPrev THEN
                  vRecvTravel := STC_FC_CalcHorizontalTravel(
                    iFromStn := vRecvPrevSink,
                    iToStn   := ioTask[vTi].Queue[vQi].SinkStationTarget,
                    iMove     := Move[vTj]);
                  vRecvEarliest := vRecvPrevEnd + REAL_TO_LINT(vRecvTravel);
                  vHandoffDeficit := LINT_TO_REAL(vRecvEarliest - ioTask[vTi].Queue[vQi].FinishTime);
                  IF vHandoffDeficit > vDeficitTol THEN
  oHasConflict := TRUE;
  oConfType := 3;
                    oConfUnit := ioTask[vTi].Queue[vQi].Unit;
                    oConfStage := ioTask[vTi].Queue[vQi].Stage;
                    oConfTrans := vTi;
                    oBlockedUnit := vRecvPrevUnit;
                    oBlockedStage := vRecvPrevStg;
  oDeficit := vHandoffDeficit;
  oCheckedCount := vTotalTasks;
  TSK_FC_Analyze := TRUE; RETURN;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;
        END_IF;
      END_FOR;
    END_IF;
  END_FOR;
END_FOR;

(* CHECK 3: TRANSPORTER_COLLISION *)
FOR vTi := 1 TO MAX_TRANSPORTERS DO
  FOR vQi := 1 TO ioTask[vTi].Count DO
    IF ioTask[vTi].Queue[vQi].Unit > 0 THEN
      vLIdx := ioTask[vTi].Queue[vQi].LiftStationTarget - MIN_STATION_INDEX;
      vSIdx := ioTask[vTi].Queue[vQi].SinkStationTarget - MIN_STATION_INDEX;
      IF vLIdx >= 1 AND vLIdx <= 30 THEN
        vLiftX := DINT_TO_REAL(Stations[ioTask[vTi].Queue[vQi].LiftStationTarget].XPosition);
  ELSE vLiftX := 0.0; END_IF;
      IF vSIdx >= 1 AND vSIdx <= 30 THEN
        vSinkX := DINT_TO_REAL(Stations[ioTask[vTi].Queue[vQi].SinkStationTarget].XPosition);
  ELSE vSinkX := 0.0; END_IF;
  IF vLiftX < vSinkX THEN vX1Min := vLiftX;
  vX1Max := vSinkX;
  ELSE vX1Min := vSinkX;
  vX1Max := vLiftX; END_IF;

      FOR vTj := vTi + 1 TO MAX_TRANSPORTERS DO
        FOR vQj := 1 TO ioTask[vTj].Count DO
          IF ioTask[vTj].Queue[vQj].Unit > 0 THEN
            vLIdx2 := ioTask[vTj].Queue[vQj].LiftStationTarget - MIN_STATION_INDEX;
            vSIdx2 := ioTask[vTj].Queue[vQj].SinkStationTarget - MIN_STATION_INDEX;
            IF vLIdx2 >= 1 AND vLIdx2 <= 30 THEN
              vLiftX2 := DINT_TO_REAL(Stations[ioTask[vTj].Queue[vQj].LiftStationTarget].XPosition);
  ELSE vLiftX2 := 0.0; END_IF;
            IF vSIdx2 >= 1 AND vSIdx2 <= 30 THEN
              vSinkX2 := DINT_TO_REAL(Stations[ioTask[vTj].Queue[vQj].SinkStationTarget].XPosition);
  ELSE vSinkX2 := 0.0; END_IF;
  IF vLiftX2 < vSinkX2 THEN vX2Min := vLiftX2;
  vX2Max := vSinkX2;
  ELSE vX2Min := vSinkX2;
  vX2Max := vLiftX2; END_IF;

  vXoStart := vX1Min; IF vX2Min > vXoStart THEN vXoStart := vX2Min; END_IF;
  vXoEnd := vX1Max; IF vX2Max < vXoEnd THEN vXoEnd := vX2Max; END_IF;

            IF vXoStart < vXoEnd THEN
              vToStart := ioTask[vTi].Queue[vQi].StartTime;
  IF ioTask[vTj].Queue[vQj].StartTime > vToStart THEN vToStart := ioTask[vTj].Queue[vQj].StartTime; END_IF;
              vToEnd := ioTask[vTi].Queue[vQi].FinishTime;
  IF ioTask[vTj].Queue[vQj].FinishTime < vToEnd THEN vToEnd := ioTask[vTj].Queue[vQj].FinishTime; END_IF;

              IF vToStart < vToEnd THEN
                vDeficitS := LINT_TO_REAL(vToEnd - vToStart) + 2.0;
  oHasConflict := TRUE;
  oConfType := 2;
                IF ioTask[vTi].Queue[vQi].StartTime <= ioTask[vTj].Queue[vQj].StartTime THEN
                  oConfUnit := ioTask[vTj].Queue[vQj].Unit;
                  oConfStage := ioTask[vTj].Queue[vQj].Stage;
                  oConfTrans := vTj;
                  oBlockedUnit := ioTask[vTi].Queue[vQi].Unit;
                  oBlockedStage := ioTask[vTi].Queue[vQi].Stage;
                ELSE
                  oConfUnit := ioTask[vTi].Queue[vQi].Unit;
                  oConfStage := ioTask[vTi].Queue[vQi].Stage;
                  oConfTrans := vTi;
                  oBlockedUnit := ioTask[vTj].Queue[vQj].Unit;
                  oBlockedStage := ioTask[vTj].Queue[vQj].Stage;
                END_IF;
  oDeficit := vDeficitS;
  oCheckedCount := vTotalTasks;
  TSK_FC_Analyze := TRUE; RETURN;
              END_IF;
            END_IF;
          END_IF;
        END_FOR;
      END_FOR;
    END_IF;
  END_FOR;
END_FOR;

oCheckedCount := vTotalTasks;

END_FUNCTION

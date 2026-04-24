(* ===========================================================================================
 *  FC_TSK_Analyze — Conflict analysis for task list
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Read-only analysis: never writes globals.
 *
 *  Three vConflict checks, each stops at first hit:
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


FUNCTION FC_TSK_Analyze : BOOL


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
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
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
  checked_count             : INT;
END_VAR

VAR
  ti                        : INT;
  tj                        : INT;
  qi                        : INT;
  qj                        : INT;
  vPrevSink                 : INT;
  vNextLift                 : INT;
  vTravelS                  : REAL;
  vGapS                     : REAL;
  deficit_s                 : REAL;
  vLiftX                    : REAL;
  vSinkX                    : REAL;
  x1_min                    : REAL;
  x1_max                    : REAL;
  x2_min                    : REAL;
  x2_max                    : REAL;
  xo_start                  : REAL;
  xo_end                    : REAL;
  vToStart                  : LINT;
  vToEnd                    : LINT;
  l_idx                     : INT;
  s_idx                     : INT;
  vLiftX2                   : REAL;
  vSinkX2                   : REAL;
  l_idx2                    : INT;
  s_idx2                    : INT;
  vCurUnit                  : INT;
  vCurStage                 : INT;
  vFoundNext                : BOOL;
  recv_prev_end             : LINT;
  recv_prev_sink            : INT;
  has_recv_prev             : BOOL;
  rk                        : INT;
  recv_prev_unit            : INT;
  recv_prev_stg             : INT;
  recv_travel               : REAL;
  recv_earliest             : LINT;
  handoff_deficit           : REAL;
  vTotalTasks               : INT;
  DEFICIT_TOL               : REAL := 1.0;
  vTmpMove                  : UDT_JC_MoveTimesType;
END_VAR

FC_TSK_Analyze := FALSE;
oHasConflict := FALSE;
oConfType    := 0;
oDeficit      := 0.0;
checked_count  := 0;

vTotalTasks := 0;
FOR ti := 1 TO MAX_TRANSPORTERS DO
  vTotalTasks := vTotalTasks + ioTask[ti].Count;
END_FOR;
IF vTotalTasks = 0 THEN RETURN; END_IF;

(* CHECK 1: TASK_SEQUENCE *)
FOR ti := 1 TO MAX_TRANSPORTERS DO
  FOR qi := 1 TO ioTask[ti].Count - 1 DO
    IF ioTask[ti].Queue[qi].Unit > 0 AND ioTask[ti].Queue[qi + 1].Unit > 0 THEN
      vPrevSink := ioTask[ti].Queue[qi].SinkStationTarget;
      vNextLift := ioTask[ti].Queue[qi + 1].LiftStationTarget;
      vTmpMove := g_move[ti];
      vTravelS := FC_STC_CalcHorizontalTravel(iFromStn := vPrevSink, iToStn := vNextLift, iMove := vTmpMove);
      vGapS := LINT_TO_REAL(ioTask[ti].Queue[qi + 1].StartTime - ioTask[ti].Queue[qi].FinishTime);
      deficit_s := vTravelS - vGapS;
      IF deficit_s > DEFICIT_TOL THEN
  oHasConflict := TRUE;
  oConfType := 1;
        oConfUnit := ioTask[ti].Queue[qi + 1].Unit;
        oConfStage := ioTask[ti].Queue[qi + 1].Stage;
        oConfTrans := ti;
        oBlockedUnit := ioTask[ti].Queue[qi].Unit;
        oBlockedStage := ioTask[ti].Queue[qi].Stage;
  oDeficit := deficit_s;
  checked_count := vTotalTasks;
  FC_TSK_Analyze := TRUE; RETURN;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* CHECK 2: CROSS_TRANSPORTER_HANDOFF *)
FOR ti := 1 TO MAX_TRANSPORTERS DO
  FOR qi := 1 TO ioTask[ti].Count DO
    vCurUnit  := ioTask[ti].Queue[qi].Unit;
    vCurStage := ioTask[ti].Queue[qi].Stage;
    IF vCurUnit > 0 THEN
      vFoundNext := FALSE;
      FOR tj := 1 TO MAX_TRANSPORTERS DO
        IF tj <> ti AND NOT vFoundNext THEN
          FOR qj := 1 TO ioTask[tj].Count DO
            IF NOT vFoundNext THEN
              IF ioTask[tj].Queue[qj].Unit = vCurUnit
                 AND ioTask[tj].Queue[qj].Stage = vCurStage + 1 THEN
                vFoundNext := TRUE;
                has_recv_prev := FALSE;
  recv_prev_end := 0;
  recv_prev_sink := 0;
  recv_prev_unit := 0;
  recv_prev_stg := 0;
                FOR rk := 1 TO ioTask[tj].Count DO
                  IF rk <> qj THEN
                    IF ioTask[tj].Queue[rk].FinishTime <= ioTask[tj].Queue[qj].StartTime THEN
                      IF NOT has_recv_prev OR ioTask[tj].Queue[rk].FinishTime > recv_prev_end THEN
                        has_recv_prev := TRUE;
                        recv_prev_end  := ioTask[tj].Queue[rk].FinishTime;
                        recv_prev_sink := ioTask[tj].Queue[rk].SinkStationTarget;
                        recv_prev_unit := ioTask[tj].Queue[rk].Unit;
                        recv_prev_stg  := ioTask[tj].Queue[rk].Stage;
                      END_IF;
                    END_IF;
                  END_IF;
                END_FOR;
                IF has_recv_prev THEN
                  recv_travel := FC_STC_CalcHorizontalTravel(
                    iFromStn := recv_prev_sink,
                    iToStn   := ioTask[ti].Queue[qi].SinkStationTarget,
                    iMove     := g_move[tj]);
                  recv_earliest := recv_prev_end + REAL_TO_LINT(recv_travel);
                  handoff_deficit := LINT_TO_REAL(recv_earliest - ioTask[ti].Queue[qi].FinishTime);
                  IF handoff_deficit > DEFICIT_TOL THEN
  oHasConflict := TRUE;
  oConfType := 3;
                    oConfUnit := ioTask[ti].Queue[qi].Unit;
                    oConfStage := ioTask[ti].Queue[qi].Stage;
                    oConfTrans := ti;
                    oBlockedUnit := recv_prev_unit;
                    oBlockedStage := recv_prev_stg;
  oDeficit := handoff_deficit;
  checked_count := vTotalTasks;
  FC_TSK_Analyze := TRUE; RETURN;
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
FOR ti := 1 TO MAX_TRANSPORTERS DO
  FOR qi := 1 TO ioTask[ti].Count DO
    IF ioTask[ti].Queue[qi].Unit > 0 THEN
      l_idx := ioTask[ti].Queue[qi].LiftStationTarget - MIN_STATION_INDEX;
      s_idx := ioTask[ti].Queue[qi].SinkStationTarget - MIN_STATION_INDEX;
      IF l_idx >= 1 AND l_idx <= 30 THEN
        vLiftX := DINT_TO_REAL(Stations[ioTask[ti].Queue[qi].LiftStationTarget].XPosition);
  ELSE vLiftX := 0.0; END_IF;
      IF s_idx >= 1 AND s_idx <= 30 THEN
        vSinkX := DINT_TO_REAL(Stations[ioTask[ti].Queue[qi].SinkStationTarget].XPosition);
  ELSE vSinkX := 0.0; END_IF;
  IF vLiftX < vSinkX THEN x1_min := vLiftX;
  x1_max := vSinkX;
  ELSE x1_min := vSinkX;
  x1_max := vLiftX; END_IF;

      FOR tj := ti + 1 TO MAX_TRANSPORTERS DO
        FOR qj := 1 TO ioTask[tj].Count DO
          IF ioTask[tj].Queue[qj].Unit > 0 THEN
            l_idx2 := ioTask[tj].Queue[qj].LiftStationTarget - MIN_STATION_INDEX;
            s_idx2 := ioTask[tj].Queue[qj].SinkStationTarget - MIN_STATION_INDEX;
            IF l_idx2 >= 1 AND l_idx2 <= 30 THEN
              vLiftX2 := DINT_TO_REAL(Stations[ioTask[tj].Queue[qj].LiftStationTarget].XPosition);
  ELSE vLiftX2 := 0.0; END_IF;
            IF s_idx2 >= 1 AND s_idx2 <= 30 THEN
              vSinkX2 := DINT_TO_REAL(Stations[ioTask[tj].Queue[qj].SinkStationTarget].XPosition);
  ELSE vSinkX2 := 0.0; END_IF;
  IF vLiftX2 < vSinkX2 THEN x2_min := vLiftX2;
  x2_max := vSinkX2;
  ELSE x2_min := vSinkX2;
  x2_max := vLiftX2; END_IF;

  xo_start := x1_min; IF x2_min > xo_start THEN xo_start := x2_min; END_IF;
  xo_end := x1_max; IF x2_max < xo_end THEN xo_end := x2_max; END_IF;

            IF xo_start < xo_end THEN
              vToStart := ioTask[ti].Queue[qi].StartTime;
  IF ioTask[tj].Queue[qj].StartTime > vToStart THEN vToStart := ioTask[tj].Queue[qj].StartTime; END_IF;
              vToEnd := ioTask[ti].Queue[qi].FinishTime;
  IF ioTask[tj].Queue[qj].FinishTime < vToEnd THEN vToEnd := ioTask[tj].Queue[qj].FinishTime; END_IF;

              IF vToStart < vToEnd THEN
                deficit_s := LINT_TO_REAL(vToEnd - vToStart) + 2.0;
  oHasConflict := TRUE;
  oConfType := 2;
                IF ioTask[ti].Queue[qi].StartTime <= ioTask[tj].Queue[qj].StartTime THEN
                  oConfUnit := ioTask[tj].Queue[qj].Unit;
                  oConfStage := ioTask[tj].Queue[qj].Stage;
                  oConfTrans := tj;
                  oBlockedUnit := ioTask[ti].Queue[qi].Unit;
                  oBlockedStage := ioTask[ti].Queue[qi].Stage;
                ELSE
                  oConfUnit := ioTask[ti].Queue[qi].Unit;
                  oConfStage := ioTask[ti].Queue[qi].Stage;
                  oConfTrans := ti;
                  oBlockedUnit := ioTask[tj].Queue[qj].Unit;
                  oBlockedStage := ioTask[tj].Queue[qj].Stage;
                END_IF;
  oDeficit := deficit_s;
  checked_count := vTotalTasks;
  FC_TSK_Analyze := TRUE; RETURN;
              END_IF;
            END_IF;
          END_IF;
        END_FOR;
      END_FOR;
    END_IF;
  END_FOR;
END_FOR;

checked_count := vTotalTasks;

END_FUNCTION

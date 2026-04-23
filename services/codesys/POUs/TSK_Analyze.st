(* ===========================================================================================
 *  TSK_Analyze — Conflict analysis for task list
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


FUNCTION TSK_Analyze : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_Transporters *)
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MAX_Units               : INT;
    MIN_StationIndex        : INT;
    MAX_StationIndex        : INT;
END_VAR

VAR_EXTERNAL
  Stations                 : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_move                    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
END_VAR

VAR_OUTPUT
  o_has_conflict            : BOOL;
  o_conf_type               : INT;     (* 1=TASK_SEQUENCE, 2=COLLISION, 3=HANDOFF *)
  o_conf_unit               : INT;
  o_conf_stage              : INT;
  o_conf_trans              : INT;
  o_blocked_unit            : INT;
  o_blocked_stage           : INT;
  o_deficit                 : REAL;
  checked_count             : INT;
END_VAR

VAR
  ti                        : INT;
  tj                        : INT;
  qi                        : INT;
  qj                        : INT;
  prev_sink                 : INT;
  next_lift                 : INT;
  travel_s                  : REAL;
  gap_s                     : REAL;
  deficit_s                 : REAL;
  lift_x                    : REAL;
  sink_x                    : REAL;
  x1_min                    : REAL;
  x1_max                    : REAL;
  x2_min                    : REAL;
  x2_max                    : REAL;
  xo_start                  : REAL;
  xo_end                    : REAL;
  to_start                  : LINT;
  to_end                    : LINT;
  l_idx                     : INT;
  s_idx                     : INT;
  lift_x2                   : REAL;
  sink_x2                   : REAL;
  l_idx2                    : INT;
  s_idx2                    : INT;
  cur_unit                  : INT;
  cur_stage                 : INT;
  found_next                : BOOL;
  recv_prev_end             : LINT;
  recv_prev_sink            : INT;
  has_recv_prev             : BOOL;
  rk                        : INT;
  recv_prev_unit            : INT;
  recv_prev_stg             : INT;
  recv_travel               : REAL;
  recv_earliest             : LINT;
  handoff_deficit           : REAL;
  total_tasks               : INT;
  DEFICIT_TOL               : REAL := 1.0;
  tmp_move                  : UDT_JC_MoveTimesType;
END_VAR

TSK_Analyze := FALSE;
o_has_conflict := FALSE;
o_conf_type    := 0;
o_deficit      := 0.0;
checked_count  := 0;

total_tasks := 0;
FOR ti := 1 TO MAX_Transporters DO
  total_tasks := total_tasks + io_task[ti].Count;
END_FOR;
IF total_tasks = 0 THEN RETURN; END_IF;

(* CHECK 1: TASK_SEQUENCE *)
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO io_task[ti].Count - 1 DO
    IF io_task[ti].Queue[qi].Unit > 0 AND io_task[ti].Queue[qi + 1].Unit > 0 THEN
      prev_sink := io_task[ti].Queue[qi].SinkStationTarget;
      next_lift := io_task[ti].Queue[qi + 1].LiftStationTarget;
      tmp_move := g_move[ti];
      travel_s := STC_CalcHorizontalTravel(i_from_stn := prev_sink, i_to_stn := next_lift, i_move := tmp_move);
      gap_s := LINT_TO_REAL(io_task[ti].Queue[qi + 1].StartTime - io_task[ti].Queue[qi].FinishTime);
      deficit_s := travel_s - gap_s;
      IF deficit_s > DEFICIT_TOL THEN
  o_has_conflict := TRUE;
  o_conf_type := 1;
        o_conf_unit := io_task[ti].Queue[qi + 1].Unit;
        o_conf_stage := io_task[ti].Queue[qi + 1].Stage;
        o_conf_trans := ti;
        o_blocked_unit := io_task[ti].Queue[qi].Unit;
        o_blocked_stage := io_task[ti].Queue[qi].Stage;
  o_deficit := deficit_s;
  checked_count := total_tasks;
  TSK_Analyze := TRUE; RETURN;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* CHECK 2: CROSS_TRANSPORTER_HANDOFF *)
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO io_task[ti].Count DO
    cur_unit  := io_task[ti].Queue[qi].Unit;
    cur_stage := io_task[ti].Queue[qi].Stage;
    IF cur_unit > 0 THEN
      found_next := FALSE;
      FOR tj := 1 TO MAX_Transporters DO
        IF tj <> ti AND NOT found_next THEN
          FOR qj := 1 TO io_task[tj].Count DO
            IF NOT found_next THEN
              IF io_task[tj].Queue[qj].Unit = cur_unit
                 AND io_task[tj].Queue[qj].Stage = cur_stage + 1 THEN
                found_next := TRUE;
                has_recv_prev := FALSE;
  recv_prev_end := 0;
  recv_prev_sink := 0;
  recv_prev_unit := 0;
  recv_prev_stg := 0;
                FOR rk := 1 TO io_task[tj].Count DO
                  IF rk <> qj THEN
                    IF io_task[tj].Queue[rk].FinishTime <= io_task[tj].Queue[qj].StartTime THEN
                      IF NOT has_recv_prev OR io_task[tj].Queue[rk].FinishTime > recv_prev_end THEN
                        has_recv_prev := TRUE;
                        recv_prev_end  := io_task[tj].Queue[rk].FinishTime;
                        recv_prev_sink := io_task[tj].Queue[rk].SinkStationTarget;
                        recv_prev_unit := io_task[tj].Queue[rk].Unit;
                        recv_prev_stg  := io_task[tj].Queue[rk].Stage;
                      END_IF;
                    END_IF;
                  END_IF;
                END_FOR;
                IF has_recv_prev THEN
                  recv_travel := STC_CalcHorizontalTravel(
                    i_from_stn := recv_prev_sink,
                    i_to_stn   := io_task[ti].Queue[qi].SinkStationTarget,
                    i_move     := g_move[tj]);
                  recv_earliest := recv_prev_end + REAL_TO_LINT(recv_travel);
                  handoff_deficit := LINT_TO_REAL(recv_earliest - io_task[ti].Queue[qi].FinishTime);
                  IF handoff_deficit > DEFICIT_TOL THEN
  o_has_conflict := TRUE;
  o_conf_type := 3;
                    o_conf_unit := io_task[ti].Queue[qi].Unit;
                    o_conf_stage := io_task[ti].Queue[qi].Stage;
                    o_conf_trans := ti;
                    o_blocked_unit := recv_prev_unit;
                    o_blocked_stage := recv_prev_stg;
  o_deficit := handoff_deficit;
  checked_count := total_tasks;
  TSK_Analyze := TRUE; RETURN;
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
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO io_task[ti].Count DO
    IF io_task[ti].Queue[qi].Unit > 0 THEN
      l_idx := io_task[ti].Queue[qi].LiftStationTarget - MIN_StationIndex;
      s_idx := io_task[ti].Queue[qi].SinkStationTarget - MIN_StationIndex;
      IF l_idx >= 1 AND l_idx <= 30 THEN
        lift_x := DINT_TO_REAL(Stations[io_task[ti].Queue[qi].LiftStationTarget].XPosition);
  ELSE lift_x := 0.0; END_IF;
      IF s_idx >= 1 AND s_idx <= 30 THEN
        sink_x := DINT_TO_REAL(Stations[io_task[ti].Queue[qi].SinkStationTarget].XPosition);
  ELSE sink_x := 0.0; END_IF;
  IF lift_x < sink_x THEN x1_min := lift_x;
  x1_max := sink_x;
  ELSE x1_min := sink_x;
  x1_max := lift_x; END_IF;

      FOR tj := ti + 1 TO MAX_Transporters DO
        FOR qj := 1 TO io_task[tj].Count DO
          IF io_task[tj].Queue[qj].Unit > 0 THEN
            l_idx2 := io_task[tj].Queue[qj].LiftStationTarget - MIN_StationIndex;
            s_idx2 := io_task[tj].Queue[qj].SinkStationTarget - MIN_StationIndex;
            IF l_idx2 >= 1 AND l_idx2 <= 30 THEN
              lift_x2 := DINT_TO_REAL(Stations[io_task[tj].Queue[qj].LiftStationTarget].XPosition);
  ELSE lift_x2 := 0.0; END_IF;
            IF s_idx2 >= 1 AND s_idx2 <= 30 THEN
              sink_x2 := DINT_TO_REAL(Stations[io_task[tj].Queue[qj].SinkStationTarget].XPosition);
  ELSE sink_x2 := 0.0; END_IF;
  IF lift_x2 < sink_x2 THEN x2_min := lift_x2;
  x2_max := sink_x2;
  ELSE x2_min := sink_x2;
  x2_max := lift_x2; END_IF;

  xo_start := x1_min; IF x2_min > xo_start THEN xo_start := x2_min; END_IF;
  xo_end := x1_max; IF x2_max < xo_end THEN xo_end := x2_max; END_IF;

            IF xo_start < xo_end THEN
              to_start := io_task[ti].Queue[qi].StartTime;
  IF io_task[tj].Queue[qj].StartTime > to_start THEN to_start := io_task[tj].Queue[qj].StartTime; END_IF;
              to_end := io_task[ti].Queue[qi].FinishTime;
  IF io_task[tj].Queue[qj].FinishTime < to_end THEN to_end := io_task[tj].Queue[qj].FinishTime; END_IF;

              IF to_start < to_end THEN
                deficit_s := LINT_TO_REAL(to_end - to_start) + 2.0;
  o_has_conflict := TRUE;
  o_conf_type := 2;
                IF io_task[ti].Queue[qi].StartTime <= io_task[tj].Queue[qj].StartTime THEN
                  o_conf_unit := io_task[tj].Queue[qj].Unit;
                  o_conf_stage := io_task[tj].Queue[qj].Stage;
                  o_conf_trans := tj;
                  o_blocked_unit := io_task[ti].Queue[qi].Unit;
                  o_blocked_stage := io_task[ti].Queue[qi].Stage;
                ELSE
                  o_conf_unit := io_task[ti].Queue[qi].Unit;
                  o_conf_stage := io_task[ti].Queue[qi].Stage;
                  o_conf_trans := ti;
                  o_blocked_unit := io_task[tj].Queue[qj].Unit;
                  o_blocked_stage := io_task[tj].Queue[qj].Stage;
                END_IF;
  o_deficit := deficit_s;
  checked_count := total_tasks;
  TSK_Analyze := TRUE; RETURN;
              END_IF;
            END_IF;
          END_IF;
        END_FOR;
      END_FOR;
    END_IF;
  END_FOR;
END_FOR;

checked_count := total_tasks;

END_FUNCTION

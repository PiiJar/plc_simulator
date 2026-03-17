(* ============================================================
   TSK_FB_Analyze — Conflict analysis for task list
   ============================================================
   Ported from transporterTaskScheduler.js analyzeTaskConflicts()

   Three conflict checks, each stops at first hit:

   1. TASK_SEQUENCE: per-transporter queue order (preserves SWAP).
      Does the transporter have time to travel from prev.sink
      to next.lift?

   2. TRANSPORTER_COLLISION: different transporters — do their
      X-ranges and time-ranges overlap?

   3. CROSS_TRANSPORTER_HANDOFF: same batch, consecutive stages
      on different transporters — does the receiving transporter
      have time to reach the handoff station?

   NOTE: TASK_SEQUENCE iterates g_task[ti].Queue[] directly
   (not a merged sorted list) so SWAP ordering is preserved.

   Outputs:
     o_has_conflict — TRUE if conflict found
     o_conf_unit, o_conf_stage — which task is blocked
     o_blocked_unit, o_blocked_stage — which task blocks it
     o_deficit — how many seconds short
     o_conf_type — 1=TASK_SEQUENCE, 2=COLLISION, 3=HANDOFF
     checked_count — total tasks inspected
   ============================================================ *)

FUNCTION_BLOCK TSK_FB_Analyze
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MAX_Units           : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
END_VAR

VAR_EXTERNAL
  g_task    : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_station : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_move    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
END_VAR
VAR_OUTPUT
  o_has_conflict  : BOOL;
  o_conf_type     : INT;     (* 1=TASK_SEQUENCE, 2=COLLISION, 3=HANDOFF *)
  o_conf_unit     : INT;     (* conflict task: unit *)
  o_conf_stage    : INT;     (* conflict task: stage *)
  o_conf_trans    : INT;     (* conflict task: transporter *)
  o_blocked_unit  : INT;     (* blocking task: unit *)
  o_blocked_stage : INT;     (* blocking task: stage *)
  o_deficit       : REAL;    (* seconds short *)
  checked_count   : INT;     (* tasks checked before conflict *)
END_VAR
VAR
  (* Loop variables *)
  ti       : INT;    (* transporter outer *)
  tj       : INT;    (* transporter inner *)
  qi       : INT;    (* queue index outer *)
  qj       : INT;    (* queue index inner *)
  (* TASK_SEQUENCE *)
  prev_sink : INT;
  next_lift : INT;
  travel_s  : REAL;
  gap_s     : REAL;
  deficit_s : REAL;
  (* TRANSPORTER_COLLISION: X range per task *)
  lift_x   : REAL;
  sink_x   : REAL;
  x1_min   : REAL;
  x1_max   : REAL;
  x2_min   : REAL;
  x2_max   : REAL;
  xo_start : REAL;
  xo_end   : REAL;
  to_start : LINT;
  to_end   : LINT;
  l_idx    : INT;
  s_idx    : INT;
  lift_x2  : REAL;
  sink_x2  : REAL;
  l_idx2   : INT;
  s_idx2   : INT;
  (* CROSS_TRANSPORTER_HANDOFF *)
  cur_unit    : INT;
  cur_stage   : INT;
  found_next  : BOOL;
  recv_prev_end  : LINT;
  recv_prev_sink : INT;
  has_recv_prev  : BOOL;
  rk       : INT;     (* receiver prev search *)
  recv_prev_unit : INT;    (* saved receiver prev task unit *)
  recv_prev_stg  : INT;    (* saved receiver prev task stage *)
  recv_travel    : REAL;
  recv_earliest  : LINT;
  handoff_deficit : REAL;
  (* Counter *)
  total_tasks : INT;
  DEFICIT_TOL : REAL := 1.0;
  tmp_move    : UDT_JC_MoveTimesType;  (* MATIEC cannot index arrays in FUNCTION args *)
END_VAR

o_has_conflict := FALSE;
o_conf_type    := 0;
o_deficit      := 0.0;
checked_count  := 0;

(* Count total tasks *)
total_tasks := 0;
FOR ti := 1 TO MAX_Transporters DO
  total_tasks := total_tasks + g_task[ti].Count;
END_FOR;
IF total_tasks = 0 THEN RETURN; END_IF;

(* ══════════════════════════════════════════════════════════════════════ *)
(* CHECK 1: TASK_SEQUENCE — per-transporter queue order (SWAP-safe)    *)
(* Iterates g_task[ti].Queue[] in queue order, NOT sorted by time.     *)
(* ══════════════════════════════════════════════════════════════════════ *)
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO g_task[ti].Count - 1 DO
    IF g_task[ti].Queue[qi].Unit > 0 AND g_task[ti].Queue[qi + 1].Unit > 0 THEN

      prev_sink := g_task[ti].Queue[qi].SinkStationTarget;
      next_lift := g_task[ti].Queue[qi + 1].LiftStationTarget;

      tmp_move := g_move[ti];
      travel_s := STC_CalcHorizontalTravel(i_from_stn := prev_sink, i_to_stn := next_lift, i_move := tmp_move);

      gap_s := LINT_TO_REAL(
        g_task[ti].Queue[qi + 1].StartTime - g_task[ti].Queue[qi].FinishTime
      );
      deficit_s := travel_s - gap_s;

      IF deficit_s > DEFICIT_TOL THEN
        o_has_conflict  := TRUE;
        o_conf_type     := 1;  (* TASK_SEQUENCE *)
        o_conf_unit     := g_task[ti].Queue[qi + 1].Unit;
        o_conf_stage    := g_task[ti].Queue[qi + 1].Stage;
        o_conf_trans    := ti;
        o_blocked_unit  := g_task[ti].Queue[qi].Unit;
        o_blocked_stage := g_task[ti].Queue[qi].Stage;
        o_deficit       := deficit_s;
        checked_count   := total_tasks;
        RETURN;
      END_IF;

    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════════════ *)
(* CHECK 2: CROSS_TRANSPORTER_HANDOFF                                  *)
(* Same batch, consecutive stages on different transporters.           *)
(* Does the receiving transporter have time to reach handoff station?  *)
(*                                                                      *)
(* JS checks HANDOFF before COLLISION (per-task loop order).           *)
(* Conflict targets the DELIVERING task (current transporter);         *)
(* resolver will delay the preceding stage so the batch waits longer   *)
(* on the delivering transporter's side.                               *)
(* ══════════════════════════════════════════════════════════════════════ *)
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO g_task[ti].Count DO
    cur_unit  := g_task[ti].Queue[qi].Unit;
    cur_stage := g_task[ti].Queue[qi].Stage;
    IF cur_unit > 0 THEN

      (* Find next stage of same batch in a different transporter *)
      found_next := FALSE;
      FOR tj := 1 TO MAX_Transporters DO
        IF tj <> ti AND NOT found_next THEN
          FOR qj := 1 TO g_task[tj].Count DO
            IF NOT found_next THEN
              IF g_task[tj].Queue[qj].Unit = cur_unit
                 AND g_task[tj].Queue[qj].Stage = cur_stage + 1 THEN
                found_next := TRUE;

                (* Found handoff pair: ti delivers to sink, tj picks up *)
                (* Find receiver's (tj) previous task — latest finish before next task start *)
                has_recv_prev := FALSE;
                recv_prev_end  := 0;
                recv_prev_sink := 0;
                recv_prev_unit := 0;
                recv_prev_stg  := 0;
                FOR rk := 1 TO g_task[tj].Count DO
                  IF rk <> qj THEN
                    IF g_task[tj].Queue[rk].FinishTime <= g_task[tj].Queue[qj].StartTime THEN
                      IF NOT has_recv_prev OR g_task[tj].Queue[rk].FinishTime > recv_prev_end THEN
                        has_recv_prev := TRUE;
                        recv_prev_end  := g_task[tj].Queue[rk].FinishTime;
                        recv_prev_sink := g_task[tj].Queue[rk].SinkStationTarget;
                        recv_prev_unit := g_task[tj].Queue[rk].Unit;
                        recv_prev_stg  := g_task[tj].Queue[rk].Stage;
                      END_IF;
                    END_IF;
                  END_IF;
                END_FOR;

                IF has_recv_prev THEN
                  (* Travel from receiver's prev sink to handoff station (= ti's current sink) *)
                  recv_travel := STC_CalcHorizontalTravel(
                    i_from_stn := recv_prev_sink,
                    i_to_stn   := g_task[ti].Queue[qi].SinkStationTarget,
                    i_move     := g_move[tj]
                  );
                  recv_earliest := recv_prev_end + REAL_TO_LINT(recv_travel);
                  handoff_deficit := LINT_TO_REAL(
                    recv_earliest - g_task[ti].Queue[qi].FinishTime
                  );

                  IF handoff_deficit > DEFICIT_TOL THEN
                    o_has_conflict  := TRUE;
                    o_conf_type     := 3;  (* CROSS_TRANSPORTER_HANDOFF *)
                    (* Conflict on delivering task *)
                    o_conf_unit     := g_task[ti].Queue[qi].Unit;
                    o_conf_stage    := g_task[ti].Queue[qi].Stage;
                    o_conf_trans    := ti;
                    (* Blocked by receiver's previous task *)
                    o_blocked_unit  := recv_prev_unit;
                    o_blocked_stage := recv_prev_stg;
                    o_deficit       := handoff_deficit;
                    checked_count   := total_tasks;
                    RETURN;
                  END_IF;
                END_IF;
                (* If no recv prev task, receiver is idle → no handoff conflict *)

              END_IF;
            END_IF;
          END_FOR;
        END_IF;
      END_FOR;

    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════════════ *)
(* CHECK 3: TRANSPORTER_COLLISION — X+time overlap, different trans.   *)
(* Compares every task pair across different transporters.              *)
(* JS: conf = later task (timeline), blocked = earlier task.           *)
(* ══════════════════════════════════════════════════════════════════════ *)
FOR ti := 1 TO MAX_Transporters DO
  FOR qi := 1 TO g_task[ti].Count DO
    IF g_task[ti].Queue[qi].Unit > 0 THEN

      (* X range for task A *)
      l_idx := g_task[ti].Queue[qi].LiftStationTarget - 100;
      s_idx := g_task[ti].Queue[qi].SinkStationTarget - 100;
      IF l_idx >= 1 AND l_idx <= 30 THEN
        lift_x := DINT_TO_REAL(g_station[g_task[ti].Queue[qi].LiftStationTarget].XPosition);
      ELSE
        lift_x := 0.0;
      END_IF;
      IF s_idx >= 1 AND s_idx <= 30 THEN
        sink_x := DINT_TO_REAL(g_station[g_task[ti].Queue[qi].SinkStationTarget].XPosition);
      ELSE
        sink_x := 0.0;
      END_IF;
      IF lift_x < sink_x THEN
        x1_min := lift_x;
        x1_max := sink_x;
      ELSE
        x1_min := sink_x;
        x1_max := lift_x;
      END_IF;

      FOR tj := ti + 1 TO MAX_Transporters DO
        FOR qj := 1 TO g_task[tj].Count DO
          IF g_task[tj].Queue[qj].Unit > 0 THEN

            (* X range for task B *)
            l_idx2 := g_task[tj].Queue[qj].LiftStationTarget - 100;
            s_idx2 := g_task[tj].Queue[qj].SinkStationTarget - 100;
            IF l_idx2 >= 1 AND l_idx2 <= 30 THEN
              lift_x2 := DINT_TO_REAL(g_station[g_task[tj].Queue[qj].LiftStationTarget].XPosition);
            ELSE
              lift_x2 := 0.0;
            END_IF;
            IF s_idx2 >= 1 AND s_idx2 <= 30 THEN
              sink_x2 := DINT_TO_REAL(g_station[g_task[tj].Queue[qj].SinkStationTarget].XPosition);
            ELSE
              sink_x2 := 0.0;
            END_IF;
            IF lift_x2 < sink_x2 THEN
              x2_min := lift_x2;
              x2_max := sink_x2;
            ELSE
              x2_min := sink_x2;
              x2_max := lift_x2;
            END_IF;

            (* X overlap *)
            xo_start := x1_min;
            IF x2_min > xo_start THEN xo_start := x2_min; END_IF;
            xo_end := x1_max;
            IF x2_max < xo_end THEN xo_end := x2_max; END_IF;

            IF xo_start < xo_end THEN
              (* Time overlap *)
              to_start := g_task[ti].Queue[qi].StartTime;
              IF g_task[tj].Queue[qj].StartTime > to_start THEN
                to_start := g_task[tj].Queue[qj].StartTime;
              END_IF;
              to_end := g_task[ti].Queue[qi].FinishTime;
              IF g_task[tj].Queue[qj].FinishTime < to_end THEN
                to_end := g_task[tj].Queue[qj].FinishTime;
              END_IF;

              IF to_start < to_end THEN
                deficit_s := LINT_TO_REAL(to_end - to_start) + 2.0;
                o_has_conflict  := TRUE;
                o_conf_type     := 2;  (* TRANSPORTER_COLLISION *)
                (* Assign conf = later task (timeline), blocked = earlier task — matches JS *)
                IF g_task[ti].Queue[qi].StartTime <= g_task[tj].Queue[qj].StartTime THEN
                  o_conf_unit     := g_task[tj].Queue[qj].Unit;
                  o_conf_stage    := g_task[tj].Queue[qj].Stage;
                  o_conf_trans    := tj;
                  o_blocked_unit  := g_task[ti].Queue[qi].Unit;
                  o_blocked_stage := g_task[ti].Queue[qi].Stage;
                ELSE
                  o_conf_unit     := g_task[ti].Queue[qi].Unit;
                  o_conf_stage    := g_task[ti].Queue[qi].Stage;
                  o_conf_trans    := ti;
                  o_blocked_unit  := g_task[tj].Queue[qj].Unit;
                  o_blocked_stage := g_task[tj].Queue[qj].Stage;
                END_IF;
                o_deficit       := deficit_s;
                checked_count   := total_tasks;
                RETURN;
              END_IF;
            END_IF;

          END_IF;
        END_FOR;
      END_FOR;

    END_IF;
  END_FOR;
END_FOR;

(* No conflict found *)
checked_count := total_tasks;

END_FUNCTION_BLOCK

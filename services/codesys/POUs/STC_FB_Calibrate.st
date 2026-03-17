(* ============================================================
   STC_FB_Calibrate — Teaching / calibration mode
   ============================================================
   Runs 2 normal tasks per transporter to measure real lift,
   sink, and travel kinematic parameters.

   Task 1: lift=dry_station, sink=wet_station
     → MeasureMoveTimes records: lift_s[dry], sink_s[wet],
       travel[dry→wet]
     → X velocity profile measured during phase 3.

   Task 2: lift=wet_station, sink=dry_station
     → MeasureMoveTimes records: lift_s[wet], sink_s[dry],
       travel[wet→dry]

   Two tasks give ALL measurements: lift_wet, sink_wet,
   lift_dry, sink_dry, and X kinematics from vel profile.

   Calibration sequence per transporter:
     Step 10-12: Task 1 (dry→wet) + X velocity measurement
     Step 20-22: Task 2 (wet→dry)
     Step 30:    Read results from g_move → g_cal
     Step 40:    Next transporter or cal_step 100

   Global control:
     Step   0: Idle (waiting for cmd=1)
     Step 100: All measurement done (waiting for cmd=2 = Calculate)
     Step 200: Calculating g_move from measured parameters
     Step 999: Complete (waiting for cmd=3 = abort/reset)

   Inputs:
     i_run  — enable (typically init_done)
     i_cmd  — one-shot command: 1=start, 2=calculate, 3=abort

   Outputs:
     o_step   — current cal_step number
     o_tid    — transporter being calibrated
     o_active — TRUE while calibration is running
   ============================================================ *)

FUNCTION_BLOCK STC_FB_Calibrate
VAR_INPUT
  i_run : BOOL;       (* enable — typically init_done *)
  i_cmd : INT;        (* one-shot: 1=start, 2=calculate, 3=abort *)
END_VAR
VAR_OUTPUT
  o_step   : INT;     (* current calibration cal_step *)
  o_tid    : INT;     (* transporter being calibrated *)
  o_active : BOOL;    (* calibration in progress *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
END_VAR

VAR_EXTERNAL
  g_transporter : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_sim_trans   : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
  g_station    : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_cfg         : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_cal         : ARRAY[1..MAX_Transporters] OF UDT_JC_CalibrationType;
  g_move        : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_time_s      : LINT;
END_VAR
VAR
  cal_step       : INT := 0;
  tid        : INT := 0;      (* current transporter 1..3 *)
  task_key   : LINT := 0;   (* task_id for issued task *)
  (* X velocity measurement during phase 3 of task 1 *)
  x_meas_ph  : INT := 0;      (* 0=wait 1=accel 2=cruise 3=decel *)
  x_timer    : REAL := 0.0;
  x_prev_v   : REAL := 0.0;
  x_max_v    : REAL := 0.0;
  x_acc_t    : REAL := 0.0;
  x_dec_t    : REAL := 0.0;
  cur_v      : REAL;
  (* Calculation loop variables *)
  ci         : INT;
  cj         : INT;
  dist       : REAL;
  d_acc      : REAL;
  d_dec      : REAL;
  v_peak     : REAL;
  travel_t   : REAL;
  vm         : REAL;
  ta         : REAL;
  td         : REAL;
  (* Helper *)
  next_tid   : INT;
  wet_idx    : INT;
  dry_idx    : INT;
END_VAR

IF NOT i_run THEN
  RETURN;
END_IF;

(* ── Command handling ── *)
IF i_cmd = 1 AND cal_step = 0 THEN
  (* Start calibration — find first active transporter with plan *)
  tid := 0;
  FOR ci := 1 TO MAX_Transporters DO
    IF g_transporter[ci].IsActive AND tid = 0 THEN
      IF g_cal[ci].WetStation > 0 AND g_cal[ci].DryStation > 0 THEN
        tid := ci;
      END_IF;
    END_IF;
  END_FOR;
  IF tid > 0 THEN
    cal_step := 10;
    o_active := TRUE;
  END_IF;
END_IF;

IF i_cmd = 2 AND cal_step = 100 THEN
  (* Calculate g_move from measured parameters *)
  cal_step := 200;
END_IF;

IF i_cmd = 3 THEN
  (* Abort — reset to idle *)
  cal_step := 0;
  tid := 0;
  o_active := FALSE;
END_IF;

(* ================================================================
   STEP 10-12: TASK 1 — lift=dry_station, sink=wet_station
   MeasureMoveTimes records lift_s[dry], sink_s[wet], travel[dry→wet].
   X velocity profile measured during phase 3 (travel dry→wet).
   ================================================================ *)
IF cal_step = 10 THEN
  (* Issue task 1: lift from dry, sink to wet *)
  task_key := g_time_s;
  g_transporter[tid].TaskId := task_key;
  g_transporter[tid].LiftStationTarget := g_cal[tid].DryStation;
  g_transporter[tid].SinkStationTarget := g_cal[tid].WetStation;
  (* Reset X velocity measurement *)
  x_meas_ph := 0;
  x_timer   := 0.0;
  x_prev_v  := 0.0;
  x_max_v   := 0.0;
  x_acc_t   := 0.0;
  x_dec_t   := 0.0;
  cal_step := 11;
END_IF;

IF cal_step = 11 THEN
  (* Wait for task acceptance *)
  IF g_sim_trans[tid].RunningTaskId = task_key THEN
    cal_step := 12;
  END_IF;
END_IF;

IF cal_step = 12 THEN
  cur_v := ABS(DINT_TO_REAL(g_sim_trans[tid].XVelocity));

  (* ── Track X velocity during phase 3 (travel dry→wet) ── *)
  IF g_transporter[tid].Phase = 3 THEN
    IF x_meas_ph = 0 AND cur_v > 0.5 THEN
      (* Acceleration started *)
      x_meas_ph := 1;
      x_timer := 0.02;
      x_prev_v := cur_v;
      x_max_v := cur_v;

    ELSIF x_meas_ph = 1 THEN
      x_timer := x_timer + 0.02;
      IF cur_v > x_max_v THEN
        x_max_v := cur_v;
      END_IF;
      IF cur_v <= x_prev_v THEN
        (* Velocity stopped increasing → reached v_max *)
        x_acc_t := x_timer - 0.02;
        x_meas_ph := 2;
        x_timer := 0.0;
      END_IF;
      x_prev_v := cur_v;

    ELSIF x_meas_ph = 2 THEN
      (* Cruising — wait for deceleration *)
      IF cur_v < x_max_v - 1.0 THEN
        x_meas_ph := 3;
        x_timer := 0.02;
      END_IF;

    ELSIF x_meas_ph = 3 THEN
      x_timer := x_timer + 0.02;
    END_IF;
  END_IF;

  (* ── Phase 3 ended or phase 4 reached: store X results ── *)
  IF g_transporter[tid].Phase >= 4 AND x_meas_ph >= 1 THEN
    IF x_meas_ph = 3 THEN
      x_dec_t := x_timer;
    END_IF;
    g_cal[tid].XAccelTime  := REAL_TO_INT(x_acc_t * 10.0);
    g_cal[tid].XDecelTime  := REAL_TO_INT(x_dec_t * 10.0);
    g_cal[tid].XMaxSpeed := REAL_TO_DINT(x_max_v);
    (* Don't re-enter — set meas_ph to done *)
    x_meas_ph := 99;
  END_IF;

  (* ── Wait for full task completion (phase returns to 0) ── *)
  IF g_transporter[tid].Phase = 0 AND x_meas_ph >= 99 THEN
    cal_step := 20;
  END_IF;
END_IF;

(* ================================================================
   STEP 20-22: TASK 2 — lift=wet_station, sink=dry_station
   MeasureMoveTimes records lift_s[wet], sink_s[dry], travel[wet→dry].
   ================================================================ *)
IF cal_step = 20 THEN
  (* Issue task 2: lift from wet, sink to dry *)
  task_key := g_time_s + LINT#1;
  g_transporter[tid].TaskId := task_key;
  g_transporter[tid].LiftStationTarget := g_cal[tid].WetStation;
  g_transporter[tid].SinkStationTarget := g_cal[tid].DryStation;
  cal_step := 21;
END_IF;

IF cal_step = 21 THEN
  IF g_sim_trans[tid].RunningTaskId = task_key THEN
    cal_step := 22;
  END_IF;
END_IF;

IF cal_step = 22 THEN
  (* Wait for task completion *)
  IF g_transporter[tid].Phase = 0 THEN
    cal_step := 30;
  END_IF;
END_IF;

(* ================================================================
   STEP 30: READ RESULTS FROM g_move → g_cal
   MeasureMoveTimes has recorded all 4 lift/sink times into g_move.
   ================================================================ *)
IF cal_step = 30 THEN
  wet_idx := g_cal[tid].WetStation - 100;
  dry_idx := g_cal[tid].DryStation - 100;

  IF wet_idx >= 1 AND wet_idx <= 25 THEN
    g_cal[tid].LiftWetTime := g_move[tid].LiftTime[wet_idx];
    g_cal[tid].SinkWetTime := g_move[tid].SinkTime[wet_idx];
  END_IF;

  IF dry_idx >= 1 AND dry_idx <= 25 THEN
    g_cal[tid].LiftDryTime := g_move[tid].LiftTime[dry_idx];
    g_cal[tid].SinkDryTime := g_move[tid].SinkTime[dry_idx];
  END_IF;

  cal_step := 40;
END_IF;

(* ================================================================
   STEP 40: TRANSPORTER DONE — advance to next or finish
   ================================================================ *)
IF cal_step = 40 THEN
  (* Find next active transporter after current tid with plan *)
  next_tid := 0;
  FOR ci := tid + 1 TO MAX_Transporters DO
    IF g_transporter[ci].IsActive AND next_tid = 0 THEN
      IF g_cal[ci].WetStation > 0 AND g_cal[ci].DryStation > 0 THEN
        next_tid := ci;
      END_IF;
    END_IF;
  END_FOR;

  IF next_tid > 0 THEN
    (* Calibrate next transporter *)
    tid := next_tid;
    cal_step := 10;
  ELSE
    (* All transporters done — measurement complete *)
    cal_step := 100;
  END_IF;
END_IF;

(* ================================================================
   STEP 200: CALCULATE g_move FROM MEASURED PARAMETERS
   For each active transporter with calibration data:
     - Copy lift/sink wet times to all wet stations
     - Copy lift/sink dry times to all dry stations
     - Calculate all station-to-station travel times using
       measured v_max, t_acc, t_dec and station distances
   ================================================================ *)
IF cal_step = 200 THEN
  FOR ci := 1 TO MAX_Transporters DO
    IF g_transporter[ci].IsActive AND g_cal[ci].XMaxSpeed > 0 THEN

      vm := DINT_TO_REAL(g_cal[ci].XMaxSpeed);
      ta := INT_TO_REAL(g_cal[ci].XAccelTime) / 10.0;
      td := INT_TO_REAL(g_cal[ci].XDecelTime) / 10.0;

      (* --- Fill lift_s and sink_s per station type --- *)
      FOR cj := 1 TO 25 DO
        IF g_station[100 + cj].TankId <> 0 THEN
          IF g_station[100 + cj].DryWet = 1 THEN
            (* Wet station *)
            g_move[ci].LiftTime[cj] := g_cal[ci].LiftWetTime;
            g_move[ci].SinkTime[cj] := g_cal[ci].SinkWetTime;
          ELSE
            (* Dry station *)
            g_move[ci].LiftTime[cj] := g_cal[ci].LiftDryTime;
            g_move[ci].SinkTime[cj] := g_cal[ci].SinkDryTime;
          END_IF;
        END_IF;
      END_FOR;

      (* --- Calculate all travel times from kinematics --- *)
      (* d_acc = 0.5 * v_max * t_acc (distance during acceleration)
         d_dec = 0.5 * v_max * t_dec (distance during deceleration)
         If dist >= d_acc + d_dec:
           travel = t_acc + (dist - d_acc - d_dec) / v_max + t_dec
         Else (triangle profile):
           v_peak = SQRT(2 * dist * v_max / (t_acc + t_dec))
           travel = v_peak * (t_acc + t_dec) / v_max *)
      d_acc := 0.5 * vm * ta;
      d_dec := 0.5 * vm * td;

      FOR cj := 1 TO 25 DO
        IF g_station[100 + cj].TankId <> 0 THEN
          FOR wet_idx := 1 TO 25 DO
            IF g_station[100 + wet_idx].TankId <> 0 THEN
              IF cj = wet_idx THEN
                g_move[ci].Travel[cj].ToTime[wet_idx] := 0;
              ELSE
                dist := ABS(DINT_TO_REAL(g_station[100 + cj].XPosition - g_station[100 + wet_idx].XPosition));
                IF dist < 1.0 THEN
                  g_move[ci].Travel[cj].ToTime[wet_idx] := 0;
                ELSIF dist >= (d_acc + d_dec) THEN
                  (* Full trapezoidal profile *)
                  travel_t := ta + (dist - d_acc - d_dec) / vm + td;
                  g_move[ci].Travel[cj].ToTime[wet_idx] := REAL_TO_INT(travel_t * 10.0);
                ELSE
                  (* Triangle profile — cannot reach full speed *)
                  IF (ta + td) > 0.0 THEN
                    v_peak := SQRT(2.0 * dist * vm / (ta + td));
                    travel_t := v_peak * (ta + td) / vm;
                    g_move[ci].Travel[cj].ToTime[wet_idx] := REAL_TO_INT(travel_t * 10.0);
                  ELSE
                    g_move[ci].Travel[cj].ToTime[wet_idx] := 0;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;
          END_FOR;
        END_IF;
      END_FOR;

    END_IF;
  END_FOR;

  cal_step := 999;
END_IF;

(* ── Update outputs ── *)
o_step := cal_step;
o_tid  := tid;
IF cal_step > 0 AND cal_step < 999 THEN
  o_active := TRUE;
ELSIF cal_step = 999 THEN
  o_active := FALSE;
ELSE
  o_active := FALSE;
END_IF;

END_FUNCTION_BLOCK

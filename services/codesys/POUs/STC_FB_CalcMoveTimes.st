(* ============================================================
   STC_FB_CalcMoveTimes — Compute g_move from kinematic params
   ============================================================
   Calculates precomputed movement times for all active
   transporters using calibration kinematic parameters (g_cal)
   and station positions (g_station).

   For each transporter with valid g_cal data (x_max_mm_s > 0):
     - lift_s/sink_s: based on station kind (0=dry, 1=wet)
     - travel: trapezoidal velocity profile from X distances

   Call with i_run = TRUE to trigger computation (rising edge).

   Replaces need to re-run full calibration sequence when
   kinematic parameters are already known (e.g. loaded from
   a previously saved movement_times.json).
   ============================================================ *)

FUNCTION_BLOCK STC_FB_CalcMoveTimes
VAR_INPUT
  i_run : BOOL;    (* rising edge triggers computation *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
END_VAR
VAR_EXTERNAL
  g_cal           : ARRAY[1..MAX_Transporters] OF UDT_JC_CalibrationType;
  g_station       : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_move          : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_station_count : INT;
END_VAR
VAR
  prev_run  : BOOL := FALSE;
  tid       : INT;
  si        : INT;
  sj        : INT;
  idx_i     : INT;
  idx_j     : INT;
  last_stn  : INT;    (* last active station number *)
  vm        : REAL;   (* max velocity mm/s *)
  ta        : REAL;   (* accel time s *)
  td        : REAL;   (* decel time s *)
  d_acc     : REAL;   (* accel distance mm *)
  d_dec     : REAL;   (* decel distance mm *)
  dist      : REAL;   (* distance between stations mm *)
  t_time    : REAL;   (* computed travel time *)
  v_peak    : REAL;   (* peak velocity in triangle profile *)
END_VAR

(* Rising edge detection *)
IF i_run AND NOT prev_run THEN

  (* Determine last active station *)
  last_stn := MIN_StationIndex + g_station_count - 1;
  IF last_stn > MAX_StationIndex THEN
    last_stn := MAX_StationIndex;
  END_IF;

  FOR tid := 1 TO MAX_Transporters DO
    (* Skip transporters without valid calibration data *)
    IF g_cal[tid].XMaxSpeed >= 1 THEN

      vm := DINT_TO_REAL(g_cal[tid].XMaxSpeed);
      ta := INT_TO_REAL(g_cal[tid].XAccelTime) / 10.0;
      td := INT_TO_REAL(g_cal[tid].XDecelTime) / 10.0;
      d_acc := 0.5 * vm * ta;
      d_dec := 0.5 * vm * td;

      (* --- Lift and sink times per station --- *)
      FOR si := MIN_StationIndex TO last_stn DO
        idx_i := si - MIN_StationIndex + 1;
        IF idx_i >= 1 AND idx_i <= 30 THEN
          IF g_station[si].DryWet = 1 THEN
            (* Wet station *)
            g_move[tid].LiftTime[idx_i] := g_cal[tid].LiftWetTime;
            g_move[tid].SinkTime[idx_i] := g_cal[tid].SinkWetTime;
          ELSE
            (* Dry station *)
            g_move[tid].LiftTime[idx_i] := g_cal[tid].LiftDryTime;
            g_move[tid].SinkTime[idx_i] := g_cal[tid].SinkDryTime;
          END_IF;
        END_IF;
      END_FOR;

      (* --- Travel times between stations --- *)
      FOR si := MIN_StationIndex TO last_stn DO
        idx_i := si - MIN_StationIndex + 1;
        IF idx_i >= 1 AND idx_i <= 30 THEN
          FOR sj := MIN_StationIndex TO last_stn DO
            idx_j := sj - MIN_StationIndex + 1;
            IF idx_j >= 1 AND idx_j <= 30 THEN
              IF si = sj THEN
                g_move[tid].Travel[idx_i].ToTime[idx_j] := 0;
              ELSE
                dist := ABS(DINT_TO_REAL(g_station[si].XPosition - g_station[sj].XPosition));
                IF dist < 1.0 THEN
                  t_time := 0.0;
                ELSIF dist >= d_acc + d_dec THEN
                  (* Trapezoidal profile: full accel + cruise + full decel *)
                  t_time := ta + (dist - d_acc - d_dec) / vm + td;
                ELSE
                  (* Triangle profile: cannot reach full speed *)
                  IF ta + td > 0.0 THEN
                    v_peak := SQRT(2.0 * dist * vm / (ta + td));
                    t_time := v_peak * (ta + td) / vm;
                  ELSE
                    t_time := 0.0;
                  END_IF;
                END_IF;
                g_move[tid].Travel[idx_i].ToTime[idx_j] := REAL_TO_INT(t_time * 10.0);
              END_IF;
            END_IF;
          END_FOR;
        END_IF;
      END_FOR;

    END_IF;  (* valid calibration check *)
  END_FOR;

END_IF;

prev_run := i_run;

END_FUNCTION_BLOCK

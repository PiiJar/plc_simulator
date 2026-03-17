(* ============================================================
   SIM_FB_XMotion.st — Horizontal motion with accel / decel
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_XMotion
VAR_INPUT
  delta_t  : REAL;     (* cycle time s — simulation internal *)
  x_target : DINT;     (* target X mm *)
  x_min    : DINT;     (* TWA lower limit mm *)
  x_max    : DINT;     (* TWA upper limit mm *)
  v_max    : DINT;     (* max velocity mm/s *)
  t_acc    : DINT;     (* acceleration time ×10 = tenths of second *)
  t_dec    : DINT;     (* deceleration time ×10 = tenths of second *)
END_VAR
VAR_IN_OUT
  x_pos : DINT;        (* current X position mm *)
  v_x   : DINT;        (* current X velocity mm/s *)
END_VAR
VAR_OUTPUT
  arrived : BOOL;
END_VAR
VAR
  (* Internal REAL copies for physics integration *)
  r_target     : REAL;
  r_min        : REAL;
  r_max        : REAL;
  r_vmax       : REAL;
  r_tacc       : REAL;
  r_tdec       : REAL;
  r_pos        : REAL;
  r_vel        : REAL;
  drive_target : REAL;
  distance     : REAL;
  dir          : REAL;
  a_acc        : REAL;
  a_dec        : REAL;
  brake_dist   : REAL;
  new_vel      : REAL;
  travel       : REAL;
END_VAR
  (* Convert DINT/INT inputs to REAL for physics *)
  r_target := DINT_TO_REAL(x_target);
  r_min    := DINT_TO_REAL(x_min);
  r_max    := DINT_TO_REAL(x_max);
  r_vmax   := DINT_TO_REAL(v_max);
  r_tacc   := DINT_TO_REAL(t_acc) / 10.0;
  r_tdec   := DINT_TO_REAL(t_dec) / 10.0;
  r_pos    := DINT_TO_REAL(x_pos);
  r_vel    := DINT_TO_REAL(v_x);

  IF (r_max > r_min) THEN
    IF r_pos < r_min THEN
      drive_target := r_min;
    ELSIF r_pos > r_max THEN
      drive_target := r_max;
    ELSE
      IF r_target < r_min THEN
        drive_target := r_min;
      ELSIF r_target > r_max THEN
        drive_target := r_max;
      ELSE
        drive_target := r_target;
      END_IF;
    END_IF;
  ELSE
    drive_target := r_target;
  END_IF;

  arrived := ABS(r_pos - drive_target) <= 3.0;
  IF arrived THEN
    x_pos := REAL_TO_DINT(drive_target);
    v_x := 0;
    RETURN;
  END_IF;

  IF r_tacc <= 0.0 THEN r_tacc := 0.001; END_IF;
  IF r_tdec <= 0.0 THEN r_tdec := 0.001; END_IF;
  IF r_vmax < 0.0 THEN r_vmax := 0.0; END_IF;

  a_acc := r_vmax / r_tacc;
  a_dec := r_vmax / r_tdec;

  dir := 1.0;
  IF drive_target < r_pos THEN
    dir := -1.0;
  END_IF;

  distance := ABS(drive_target - r_pos);

  IF a_dec > 0.0 THEN
    brake_dist := (r_vel * r_vel) / (2.0 * a_dec);
  ELSE
    brake_dist := 0.0;
  END_IF;

  IF brake_dist >= distance THEN
    new_vel := r_vel - a_dec * delta_t;
    IF new_vel < 0.0 THEN new_vel := 0.0; END_IF;
  ELSE
    new_vel := r_vel + a_acc * delta_t;
    IF new_vel > r_vmax THEN new_vel := r_vmax; END_IF;
  END_IF;

  travel := new_vel * delta_t;
  IF travel >= distance THEN
    x_pos := REAL_TO_DINT(drive_target);
    v_x := 0;
    arrived := TRUE;
  ELSE
    x_pos := REAL_TO_DINT(r_pos + dir * travel);
    v_x := REAL_TO_DINT(new_vel);
    arrived := FALSE;
  END_IF;
END_FUNCTION_BLOCK


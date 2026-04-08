(* STC_TakeOut - Evaluate and trigger idle take-out for transporters
   Uses station-specific TakeOutDelay (seconds) and TakeOutDistance (mm) *)
(* IMPORT_MARKER_2026_04_01_B *)

FUNCTION STC_TakeOut : BOOL

VAR_INPUT
  i_time_s                  : LINT;
END_VAR

VAR
  ti                        : INT;
  current_station           : INT;
  take_out_delay            : INT;
  take_out_dist             : DINT;
  idle_time                 : LINT;
  current_x                 : DINT;
  target_x                  : DINT;
  next_lift_x               : DINT;
  area_center               : DINT;
  dir                       : INT;
  queued_lift_station       : INT;
  time_to_start             : LINT;
END_VAR

STC_TakeOut := TRUE;

FOR ti := 1 TO MAX_Transporters DO

  IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[ti].Status <> 3 THEN CONTINUE; END_IF;
  IF NOT g_transporter[ti].IsActive THEN CONTINUE; END_IF;

  current_station := g_transporter[ti].CurrentStation;
  IF current_station < MIN_StationIndex OR current_station > MAX_StationIndex THEN CONTINUE; END_IF;

  take_out_delay := g_station[current_station].TakeOutDelay;
  IF take_out_delay = 0 THEN CONTINUE; END_IF;

  take_out_dist := INT_TO_DINT(g_station[current_station].TakeOutDistance);
  IF take_out_dist <= 0 THEN CONTINUE; END_IF;

  idle_time := i_time_s - g_sim_trans[ti].IdleStartTime;
  IF idle_time < DINT_TO_LINT(INT_TO_DINT(take_out_delay)) THEN CONTINUE; END_IF;

  (* Defer if next task on same station starts soon *)
  IF g_task[ti].Count > 0 THEN
    queued_lift_station := g_task[ti].Queue[1].LiftStationTarget;
    IF queued_lift_station = current_station THEN
      time_to_start := g_task[ti].Queue[1].StartTime - i_time_s;
      IF time_to_start >= 0 AND time_to_start < DINT_TO_LINT(INT_TO_DINT(MOVE_AWAY_MIN_WAIT_S)) THEN
        CONTINUE;
      END_IF;
    END_IF;
  END_IF;

  current_x := g_transporter[ti].XPosition;

  (* Determine direction: toward next task or toward area center *)
  IF g_task[ti].Count > 0 THEN
    next_lift_x := g_station[g_task[ti].Queue[1].LiftStationTarget].XPosition;
    IF next_lift_x > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  ELSE
    area_center := (g_cfg[ti].DrivePosMin + g_cfg[ti].DrivePosMax) / 2;
    IF area_center > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  END_IF;

  (* Compute target position from TakeOutDistance *)
  target_x := current_x + (INT_TO_DINT(dir) * take_out_dist);

  (* Clamp to transporter drive limits *)
  IF target_x < g_cfg[ti].DrivePosMin THEN
    target_x := g_cfg[ti].DrivePosMin;
  END_IF;
  IF target_x > g_cfg[ti].DrivePosMax THEN
    target_x := g_cfg[ti].DrivePosMax;
  END_IF;

  (* Skip if we can't actually move *)
  IF ABS(target_x - current_x) < 100 THEN CONTINUE; END_IF;

  g_transporter[ti].Phase := 1;
  g_transporter[ti].LiftStationTarget := 0;
  g_transporter[ti].SinkStationTarget := 0;
  g_transporter[ti].XDriveTarget := target_x;
  g_transporter[ti].XFinalTarget := target_x;

END_FOR;

STC_TakeOut := TRUE;

END_FUNCTION

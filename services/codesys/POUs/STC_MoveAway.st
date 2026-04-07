(* STC_MoveAway - Evaluate and trigger idle move-away for transporters *)
(* IMPORT_MARKER_2026_04_01_B *)

FUNCTION STC_MoveAway : BOOL

VAR_INPUT
  i_time_s                  : LINT;
END_VAR

VAR
  ti                        : INT;
  current_station           : INT;
  move_away_s               : INT;
  idle_time                 : LINT;
  current_x                 : DINT;
  next_lift_x               : DINT;
  area_center               : DINT;
  dir                       : INT;
  target_station            : INT;
  candidate_station         : INT;
  queued_lift_station       : INT;
  time_to_start             : LINT;
END_VAR

STC_MoveAway := TRUE;

FOR ti := 1 TO MAX_Transporters DO

  IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[ti].Status <> 3 THEN CONTINUE; END_IF;
  IF NOT g_transporter[ti].IsActive THEN CONTINUE; END_IF;

  current_station := g_transporter[ti].CurrentStation;
  IF current_station < MIN_StationIndex OR current_station > MAX_StationIndex THEN CONTINUE; END_IF;

  move_away_s := g_station[current_station].MoveAway;
  IF move_away_s = 0 THEN CONTINUE; END_IF;

  idle_time := i_time_s - g_sim_trans[ti].IdleStartTime;
  IF idle_time < DINT_TO_LINT(INT_TO_DINT(move_away_s)) THEN CONTINUE; END_IF;

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

  target_station := STC_FindStationOffset(
    i_trans     := ti,
    i_from_stn  := current_station,
    i_dir       := dir,
    i_min_steps := 2
  );

  IF target_station = 0 THEN
    dir := -dir;
    target_station := STC_FindStationOffset(
      i_trans     := ti,
      i_from_stn  := current_station,
      i_dir       := dir,
      i_min_steps := 2
    );
    IF target_station = 0 THEN CONTINUE; END_IF;
  END_IF;

  WHILE (target_station >= MIN_StationIndex) AND (target_station <= MAX_StationIndex)
        AND (g_station[target_station].MoveAway > 0) DO
    candidate_station := STC_FindStationOffset(
      i_trans     := ti,
      i_from_stn  := target_station,
      i_dir       := dir,
      i_min_steps := 1
    );
    IF (candidate_station = 0) OR (candidate_station = target_station) THEN
      target_station := 0;
      EXIT;
    END_IF;
    target_station := candidate_station;
  END_WHILE;

  IF target_station = 0 THEN CONTINUE; END_IF;

  g_transporter[ti].Phase := 1;
  g_transporter[ti].LiftStationTarget := target_station;
  g_transporter[ti].SinkStationTarget := 0;
  g_transporter[ti].XDriveTarget := g_station[target_station].XPosition;
  g_transporter[ti].XFinalTarget := g_station[target_station].XPosition;

END_FOR;

STC_MoveAway := TRUE;

END_FUNCTION

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
  si                        : INT;
  stn_x                     : DINT;
  best_stn                  : INT;
  best_dist                 : DINT;
  dx                        : DINT;
END_VAR

STC_TakeOut := TRUE;

FOR ti := 1 TO MAX_Transporters DO

  IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[ti].Status <> 3 THEN CONTINUE; END_IF;
  IF NOT g_transporter[ti].IsActive THEN CONTINUE; END_IF;

  current_station := g_transporter[ti].CurrentStation;
  IF current_station < MIN_StationIndex OR current_station > MAX_StationIndex THEN CONTINUE; END_IF;

  take_out_delay := Stations[current_station].TakeOutDelay;
  IF take_out_delay = 0 THEN CONTINUE; END_IF;

  take_out_dist := INT_TO_DINT(Stations[current_station].TakeOutDistance);
  IF take_out_dist <= 0 THEN CONTINUE; END_IF;

  idle_time := i_time_s - g_transporter[ti].IdleStartTime;
  IF idle_time < DINT_TO_LINT(INT_TO_DINT(take_out_delay)) THEN CONTINUE; END_IF;

  (* Defer if next task on SAME station starts soon *)
  IF g_task[ti].Count > 0 THEN
    queued_lift_station := g_task[ti].Queue[1].LiftStationTarget;
    IF queued_lift_station = current_station THEN
      time_to_start := g_task[ti].Queue[1].StartTime - i_time_s;
      IF time_to_start >= 0 AND time_to_start < DINT_TO_LINT(INT_TO_DINT(TAKE_OUT_MIN_WAIT_S)) THEN
        CONTINUE;
      END_IF;
    END_IF;
  END_IF;

  current_x := g_transporter[ti].XPosition;

  (* Determine direction: toward next task or toward area center *)
  IF g_task[ti].Count > 0 THEN
    next_lift_x := Stations[g_task[ti].Queue[1].LiftStationTarget].XPosition;
    IF next_lift_x > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  ELSE
    area_center := (Transporters[ti].DrivePosMin + Transporters[ti].DrivePosMax) / 2;
    IF area_center > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  END_IF;

  (* Compute minimum target position from TakeOutDistance *)
  target_x := current_x + (INT_TO_DINT(dir) * take_out_dist);

  (* Find nearest station in move direction that is at least take_out_dist away *)
  best_stn := 0;
  best_dist := DINT#2147483647;
  FOR si := MIN_StationIndex TO MIN_StationIndex + CountStations - 1 DO
    stn_x := Stations[si].XPosition;
    IF stn_x = 0 THEN CONTINUE; END_IF;
    (* Station must be in the correct direction and at least take_out_dist from current *)
    IF dir > 0 THEN
      dx := stn_x - current_x;
    ELSE
      dx := current_x - stn_x;
    END_IF;
    IF dx >= take_out_dist AND dx < best_dist THEN
      (* Must be within transporter drive limits *)
      IF stn_x >= Transporters[ti].DrivePosMin AND stn_x <= Transporters[ti].DrivePosMax THEN
        best_dist := dx;
        best_stn := si;
      END_IF;
    END_IF;
  END_FOR;

  IF best_stn > 0 THEN
    target_x := Stations[best_stn].XPosition;
  ELSE
    CONTINUE;  (* no station found in direction — skip take-out *)
  END_IF;

  (* Skip if we can't actually move *)
  IF ABS(target_x - current_x) < 100 THEN CONTINUE; END_IF;

  (* If next task starts soon and take-out would pass over its lift station,
     stop at the lift station instead *)
  IF g_task[ti].Count > 0 THEN
    time_to_start := g_task[ti].Queue[1].StartTime - i_time_s;
    IF time_to_start >= 0 AND time_to_start < DINT_TO_LINT(INT_TO_DINT(TAKE_OUT_MIN_WAIT_S)) THEN
      queued_lift_station := g_task[ti].Queue[1].LiftStationTarget;
      IF queued_lift_station >= MIN_StationIndex AND queued_lift_station <= MAX_StationIndex THEN
        next_lift_x := Stations[queued_lift_station].XPosition;
        (* Check if take-out target is on the other side of lift station *)
        IF dir > 0 AND target_x > next_lift_x AND next_lift_x > current_x THEN
          target_x := next_lift_x;
        ELSIF dir < 0 AND target_x < next_lift_x AND next_lift_x < current_x THEN
          target_x := next_lift_x;
        END_IF;
      END_IF;
    END_IF;
  END_IF;

  (* Re-check: still worth moving? *)
  IF ABS(target_x - current_x) < 100 THEN CONTINUE; END_IF;

  g_transporter[ti].Phase := 1;
  g_transporter[ti].LiftStationTarget := 0;
  g_transporter[ti].SinkStationTarget := 0;
  g_transporter[ti].XDriveTarget := target_x;
  g_transporter[ti].XFinalTarget := target_x;

END_FOR;

STC_TakeOut := TRUE;

END_FUNCTION

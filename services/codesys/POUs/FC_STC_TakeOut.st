(* FC_STC_TakeOut - Evaluate and trigger idle take-out for transporters
   Uses station-specific TakeOutDelay (seconds) and TakeOutDistance (mm) *)
(* IMPORT_MARKER_2026_04_01_B *)

FUNCTION FC_STC_TakeOut : BOOL

VAR_INPUT
  iTimeS                  : LINT;
END_VAR

VAR
  ti                        : INT;
  current_station           : INT;
  take_out_delay            : INT;
  take_out_dist             : DINT;
  vIdleTime                 : LINT;
  current_x                 : DINT;
  target_x                  : DINT;
  vNextLiftX               : DINT;
  vAreaCenter               : DINT;
  dir                       : INT;
  queued_lift_station       : INT;
  vTimeToStart             : LINT;
  si                        : INT;
  vStnX                     : DINT;
  vBestStn                  : INT;
  vBestDist                 : DINT;
  dx                        : DINT;
END_VAR

FC_STC_TakeOut := TRUE;

FOR ti := 1 TO MAX_TRANSPORTERS DO

  IF g_transporter[ti].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[ti].Status <> 3 THEN CONTINUE; END_IF;
  IF NOT g_transporter[ti].IsActive THEN CONTINUE; END_IF;

  current_station := g_transporter[ti].CurrentStation;
  IF current_station < MIN_STATION_INDEX OR current_station > MAX_STATION_INDEX THEN CONTINUE; END_IF;

  take_out_delay := Stations[current_station].TakeOutDelay;
  IF take_out_delay = 0 THEN CONTINUE; END_IF;

  take_out_dist := INT_TO_DINT(Stations[current_station].TakeOutDistance);
  IF take_out_dist <= 0 THEN CONTINUE; END_IF;

  vIdleTime := iTimeS - g_transporter[ti].IdleStartTime;
  IF vIdleTime < DINT_TO_LINT(INT_TO_DINT(take_out_delay)) THEN CONTINUE; END_IF;

  (* Defer if next task on SAME station starts soon *)
  IF g_task[ti].Count > 0 THEN
    queued_lift_station := g_task[ti].Queue[1].LiftStationTarget;
    IF queued_lift_station = current_station THEN
      vTimeToStart := g_task[ti].Queue[1].StartTime - iTimeS;
      IF vTimeToStart >= 0 AND vTimeToStart < DINT_TO_LINT(INT_TO_DINT(TAKE_OUT_MIN_WAIT_S)) THEN
        CONTINUE;
      END_IF;
    END_IF;
  END_IF;

  current_x := g_transporter[ti].XPosition;

  (* Determine direction: toward next task or toward vArea center *)
  IF g_task[ti].Count > 0 THEN
    vNextLiftX := Stations[g_task[ti].Queue[1].LiftStationTarget].XPosition;
    IF vNextLiftX > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  ELSE
    vAreaCenter := (Transporters[ti].DrivePosMin + Transporters[ti].DrivePosMax) / 2;
    IF vAreaCenter > current_x THEN
      dir := 1;
    ELSE
      dir := -1;
    END_IF;
  END_IF;

  (* Compute minimum target position from TakeOutDistance *)
  target_x := current_x + (INT_TO_DINT(dir) * take_out_dist);

  (* Find nearest station in move direction that is at least take_out_dist away *)
  vBestStn := 0;
  vBestDist := DINT#2147483647;
  FOR si := MIN_STATION_INDEX TO MIN_STATION_INDEX + CountStations - 1 DO
    vStnX := Stations[si].XPosition;
    IF vStnX = 0 THEN CONTINUE; END_IF;
    (* Station must be in the correct direction and at least take_out_dist from current *)
    IF dir > 0 THEN
      dx := vStnX - current_x;
    ELSE
      dx := current_x - vStnX;
    END_IF;
    IF dx >= take_out_dist AND dx < vBestDist THEN
      (* Must be within transporter drive limits *)
      IF vStnX >= Transporters[ti].DrivePosMin AND vStnX <= Transporters[ti].DrivePosMax THEN
        vBestDist := dx;
        vBestStn := si;
      END_IF;
    END_IF;
  END_FOR;

  IF vBestStn > 0 THEN
    target_x := Stations[vBestStn].XPosition;
  ELSE
    CONTINUE;  (* no station vFound in direction — skip take-out *)
  END_IF;

  (* Skip if we can't actually move *)
  IF ABS(target_x - current_x) < 100 THEN CONTINUE; END_IF;

  (* If next task starts soon and take-out would pass over its lift station,
     stop at the lift station instead *)
  IF g_task[ti].Count > 0 THEN
    vTimeToStart := g_task[ti].Queue[1].StartTime - iTimeS;
    IF vTimeToStart >= 0 AND vTimeToStart < DINT_TO_LINT(INT_TO_DINT(TAKE_OUT_MIN_WAIT_S)) THEN
      queued_lift_station := g_task[ti].Queue[1].LiftStationTarget;
      IF queued_lift_station >= MIN_STATION_INDEX AND queued_lift_station <= MAX_STATION_INDEX THEN
        vNextLiftX := Stations[queued_lift_station].XPosition;
        (* Check if take-out target is on the other side of lift station *)
        IF dir > 0 AND target_x > vNextLiftX AND vNextLiftX > current_x THEN
          target_x := vNextLiftX;
        ELSIF dir < 0 AND target_x < vNextLiftX AND vNextLiftX < current_x THEN
          target_x := vNextLiftX;
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

FC_STC_TakeOut := TRUE;

END_FUNCTION

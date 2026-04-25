(* FC_STC_TakeOut - Evaluate and trigger idle take-out for transporters
   Uses station-specific TakeOutDelay (seconds) and TakeOutDistance (mm) *)
(* IMPORT_MARKER_2026_04_01_B *)

FUNCTION FC_STC_TakeOut : BOOL

VAR_INPUT
  iTimeS                  : LINT;
END_VAR

VAR
  vTi                        : INT;
  vCurrentStation           : INT;
  vTakeOutDelay            : INT;
  vTakeOutDist             : DINT;
  vIdleTime                 : LINT;
  vCurrentX                 : DINT;
  vTargetX                  : DINT;
  vNextLiftX               : DINT;
  vAreaCenter               : DINT;
  vDir                       : INT;
  vQueuedLiftStation       : INT;
  vTimeToStart             : LINT;
  vSi                        : INT;
  vStnX                     : DINT;
  vBestStn                  : INT;
  vBestDist                 : DINT;
  vDx                        : DINT;
END_VAR

FC_STC_TakeOut := TRUE;

FOR vTi := 1 TO MAX_TRANSPORTERS DO

  IF g_transporter[vTi].Phase <> 0 THEN CONTINUE; END_IF;
  IF g_transporter[vTi].Status <> 3 THEN CONTINUE; END_IF;
  IF NOT g_transporter[vTi].IsActive THEN CONTINUE; END_IF;

  vCurrentStation := g_transporter[vTi].CurrentStation;
  IF vCurrentStation < MIN_STATION_INDEX OR vCurrentStation > MAX_STATION_INDEX THEN CONTINUE; END_IF;

  vTakeOutDelay := Stations[vCurrentStation].TakeOutDelay;
  IF vTakeOutDelay = 0 THEN CONTINUE; END_IF;

  vTakeOutDist := INT_TO_DINT(Stations[vCurrentStation].TakeOutDistance);
  IF vTakeOutDist <= 0 THEN CONTINUE; END_IF;

  vIdleTime := iTimeS - g_transporter[vTi].IdleStartTime;
  IF vIdleTime < DINT_TO_LINT(INT_TO_DINT(vTakeOutDelay)) THEN CONTINUE; END_IF;

  (* Defer if next task on SAME station starts soon *)
  IF g_task[vTi].Count > 0 THEN
    vQueuedLiftStation := g_task[vTi].Queue[1].LiftStationTarget;
    IF vQueuedLiftStation = vCurrentStation THEN
      vTimeToStart := g_task[vTi].Queue[1].StartTime - iTimeS;
      IF vTimeToStart >= 0 AND vTimeToStart < DINT_TO_LINT(INT_TO_DINT(TAKE_OUT_MIN_WAIT_S)) THEN
        CONTINUE;
      END_IF;
    END_IF;
  END_IF;

  vCurrentX := g_transporter[vTi].XPosition;

  (* Determine direction: toward next task or toward vArea center *)
  IF g_task[vTi].Count > 0 THEN
    vNextLiftX := Stations[g_task[vTi].Queue[1].LiftStationTarget].XPosition;
    IF vNextLiftX > vCurrentX THEN
      vDir := 1;
    ELSE
      vDir := -1;
    END_IF;
  ELSE
    vAreaCenter := (Transporters[vTi].DrivePosMin + Transporters[vTi].DrivePosMax) / 2;
    IF vAreaCenter > vCurrentX THEN
      vDir := 1;
    ELSE
      vDir := -1;
    END_IF;
  END_IF;

  (* Compute minimum target position from TakeOutDistance *)
  vTargetX := vCurrentX + (INT_TO_DINT(vDir) * vTakeOutDist);

  (* Find nearest station in move direction that is at least vTakeOutDist away *)
  vBestStn := 0;
  vBestDist := DINT#2147483647;
  FOR vSi := MIN_STATION_INDEX TO MIN_STATION_INDEX + CountStations - 1 DO
    vStnX := Stations[vSi].XPosition;
    IF vStnX = 0 THEN CONTINUE; END_IF;
    (* Station must be in the correct direction and at least vTakeOutDist from current *)
    IF vDir > 0 THEN
      vDx := vStnX - vCurrentX;
    ELSE
      vDx := vCurrentX - vStnX;
    END_IF;
    IF vDx >= vTakeOutDist AND vDx < vBestDist THEN
      (* Must be within transporter drive limits *)
      IF vStnX >= Transporters[vTi].DrivePosMin AND vStnX <= Transporters[vTi].DrivePosMax THEN
        vBestDist := vDx;
        vBestStn := vSi;
      END_IF;
    END_IF;
  END_FOR;

  IF vBestStn > 0 THEN
    vTargetX := Stations[vBestStn].XPosition;
  ELSE
    CONTINUE;  (* no station vFound in direction — skip take-out *)
  END_IF;

  (* Skip if we can't actually move *)
  IF ABS(vTargetX - vCurrentX) < 100 THEN CONTINUE; END_IF;

  (* If next task starts soon and take-out would pass over its lift station,
     stop at the lift station instead *)
  IF g_task[vTi].Count > 0 THEN
    vTimeToStart := g_task[vTi].Queue[1].StartTime - iTimeS;
    IF vTimeToStart >= 0 AND vTimeToStart < DINT_TO_LINT(INT_TO_DINT(TAKE_OUT_MIN_WAIT_S)) THEN
      vQueuedLiftStation := g_task[vTi].Queue[1].LiftStationTarget;
      IF vQueuedLiftStation >= MIN_STATION_INDEX AND vQueuedLiftStation <= MAX_STATION_INDEX THEN
        vNextLiftX := Stations[vQueuedLiftStation].XPosition;
        (* Check if take-out target is on the other side of lift station *)
        IF vDir > 0 AND vTargetX > vNextLiftX AND vNextLiftX > vCurrentX THEN
          vTargetX := vNextLiftX;
        ELSIF vDir < 0 AND vTargetX < vNextLiftX AND vNextLiftX < vCurrentX THEN
          vTargetX := vNextLiftX;
        END_IF;
      END_IF;
    END_IF;
  END_IF;

  (* Re-check: still worth moving? *)
  IF ABS(vTargetX - vCurrentX) < 100 THEN CONTINUE; END_IF;

  g_transporter[vTi].Phase := 1;
  g_transporter[vTi].LiftStationTarget := 0;
  g_transporter[vTi].SinkStationTarget := 0;
  g_transporter[vTi].XDriveTarget := vTargetX;
  g_transporter[vTi].XFinalTarget := vTargetX;

END_FOR;

FC_STC_TakeOut := TRUE;

END_FUNCTION

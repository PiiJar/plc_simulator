(* ============================================================
   fb_station_lookup.stn_data → STC_FB_FindStation — Find a station by its number
   ============================================================ *)

FUNCTION_BLOCK STC_FB_FindStation
VAR_INPUT
  station_number : INT;
END_VAR
VAR_OUTPUT
  found           : BOOL;
  idx             : INT;
  x_mm            : DINT;
  skind           : INT;
  device_delay_s  : REAL;
  dropping_time_s : REAL;
END_VAR
VAR_EXTERNAL CONSTANT
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
END_VAR
VAR_EXTERNAL
  g_station : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
END_VAR
VAR
  stn_data : UDT_StationType;
END_VAR
  (* Direct lookup by station number — no loop needed *)
  IF (station_number >= MIN_StationIndex) AND (station_number <= MAX_StationIndex) THEN
    stn_data := g_station[station_number];
    IF stn_data.TankId <> 0 THEN
      found := TRUE;
      idx := station_number;
      x_mm := stn_data.XPosition;
      skind := stn_data.DryWet;
      device_delay_s := INT_TO_REAL(stn_data.DeviceDelay) / 10.0;
      dropping_time_s := INT_TO_REAL(stn_data.DrippingTime) / 10.0;
      RETURN;
    END_IF;
  END_IF;

  found := FALSE;
  idx := 0;
  x_mm := 0;
  skind := 0;
  device_delay_s := 0.0;
  dropping_time_s := 0.0;
END_FUNCTION_BLOCK

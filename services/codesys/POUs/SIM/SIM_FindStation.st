(* ============================================================
 *  SIM_FindStation — Find a station by its number

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Direct lookup in g_station[] by station number.
   Returns x_mm (DINT); other fields via VAR_OUTPUT.
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION SIM_FindStation : DINT   (* returns x_mm *)
VAR_INPUT
  station_number : INT;
END_VAR
VAR_OUTPUT
  found           : BOOL;
  skind           : INT;
  device_delay_s  : REAL;
  dropping_time_s : REAL;
END_VAR
VAR_EXTERNAL CONSTANT
    MIN_StationIndex : INT;
    MAX_StationIndex : INT;
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
      SIM_FindStation := stn_data.XPosition;
      skind := stn_data.DryWet;
      device_delay_s := INT_TO_REAL(stn_data.DeviceDelay) / 10.0;
      dropping_time_s := INT_TO_REAL(stn_data.DrippingTime) / 10.0;
      RETURN;
    END_IF;
  END_IF;

  found := FALSE;
  SIM_FindStation := 0;
  skind := 0;
  device_delay_s := 0.0;
  dropping_time_s := 0.0;

END_FUNCTION

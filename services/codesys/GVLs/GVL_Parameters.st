(* GVL_Parameters — Production process data arrays *)
(* Identical names to globals.st VAR_GLOBAL — no renaming needed *)
VAR_GLOBAL
  CountStations                  : INT;  (* configured station count *)
  Stations                     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;  (* station configuration *)
  g_station_loc                 : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;  (* unit location per station *)
  g_cfg                         : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;  (* transporter configuration *)
  g_transporter                 : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;  (* transporter runtime status *)
  g_unit                        : ARRAY[1..MAX_Units] OF UDT_UnitType;  (* unit (lifting frame) state *)
  g_batch                       : ARRAY[1..MAX_Units] OF UDT_BatchType;  (* batch state per unit *)
  g_program                     : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;  (* treatment program per unit *)
  g_avoid_status                : ARRAY[MIN_StationIndex..MAX_StationIndex] OF INT;  (* AVOID_None/Passable/Block per station *)
END_VAR

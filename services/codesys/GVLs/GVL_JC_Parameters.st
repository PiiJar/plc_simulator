(* Scheduler GVL_Parameters — Production process data arrays *)
VAR_GLOBAL
  g_station_occupancy : ARRAY[1..MAX_StationIndex] OF UDT_JC_UnitAtStationType;  (* unit location per station *)
  g_transporter       : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType; (* transporter runtime status *)
  g_unit              : ARRAY[1..MAX_Units] OF UDT_JC_UnitType;                  (* unit (lifting frame) state *)
  g_batch             : ARRAY[1..MAX_Units] OF UDT_BatchType;                    (* batch state per unit *)
  g_avoid_status      : ARRAY[MIN_StationIndex..MAX_StationIndex] OF INT;        (* AVOID_None/Passable/Block per station *)
END_VAR

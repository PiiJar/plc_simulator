(* Scheduler GVL_Parameters — Production process data arrays *)
VAR_GLOBAL
  CountStations     : INT;                                                      (* configured station count *)
  Stations          : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;  (* station configuration *)
  gStationOccupancy : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;  (* unit location per station *)
  Transporters      : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;       (* transporter configuration, index 0 unused *)
  gTransporter      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType; (* transporter runtime status *)
  gUnit             : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;                  (* unit (lifting frame) state *)
  gBatch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;                    (* batch state per unit *)
  TreatmentPrograms : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;         (* treatment program per unit *)
  gAvoidStatus      : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;        (* AVOID_NONE/Passable/Block per station *)
END_VAR

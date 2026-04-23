{attribute 'qualified_only'}
(* Scheduler GVL_Parameters — Production process data arrays *)
VAR_GLOBAL
  CountStations       : INT;                                                      (* configured station count *)
  Stations            : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;  (* station configuration *)
  StationOccupancy : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;  (* unit location per station *)
  Transporters        : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;       (* transporter configuration, index 0 unused *)
  TransporterStatus       : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType; (* transporter runtime status *)
  Unit              : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;                  (* unit (lifting frame) state *)
  Batch             : ARRAY[1..MAX_UNITS] OF UDT_BatchType;                    (* batch state per unit *)
  TreatmentPrograms   : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;         (* treatment program per unit *)
  AvoidStatus      : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;        (* AVOID_NONE/Passable/Block per station *)
END_VAR

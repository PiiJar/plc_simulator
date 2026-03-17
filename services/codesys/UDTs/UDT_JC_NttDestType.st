(* NttDestType - No-treatment task destination: primary + fallback stations *)
TYPE UDT_JC_NttDestType :
STRUCT
    Stations         : ARRAY[1..5] OF INT; (* primary stations, up to MAX_STATIONS_PER_STEP *)
    StationCount     : INT;                (* how many primary stations are valid *)
    FallbackStations : ARRAY[1..5] OF INT; (* fallback stations, up to MAX_STATIONS_PER_STEP *)
    FallbackCount    : INT;                (* how many fallback stations are valid *)
END_STRUCT;
END_TYPE

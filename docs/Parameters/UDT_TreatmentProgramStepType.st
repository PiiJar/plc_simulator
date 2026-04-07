(* TreatmentProgramStepType - Step within a treatment program, optimized for OPC UA transfer *)
(* Stations: Parallel groups fill multiple entries, serial/single groups fill only index 0 *)
(* StationCount indicates number of valid entries in Stations array *)
TYPE UDT_TreatmentProgramStepType :
STRUCT
    MinTime      : DINT;               (* Minimum treatment time in seconds *)
    MaxTime      : DINT;               (* Maximum treatment time in seconds *)
    CalTime      : DINT;               (* Calculated treatment time in seconds *)
    StationCount : INT;                (* Number of valid stations in Stations array *)
    Stations     : ARRAY[0..4] OF INT; (* Station indexes for this step *)
END_STRUCT;
END_TYPE

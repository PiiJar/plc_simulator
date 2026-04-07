(* TreatmentProgramType - Complete treatment program with embedded steps for OPC UA transfer *)
(* StepCount indicates number of valid steps in the Steps array *)
TYPE UDT_TreatmentProgramType :
STRUCT
    ProgramId   : INT;                                          (* Treatment program number *)
    ProgramName : STRING;                                       (* Treatment program name *)
    StepCount   : INT;                                          (* Number of valid steps in Steps array *)
    Steps       : ARRAY[0..30] OF UDT_TreatmentProgramStepType; (* Embedded step array *)
END_STRUCT;
END_TYPE

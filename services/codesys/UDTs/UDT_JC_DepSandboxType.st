(* DepSandboxType - Isolated copy of scheduler state for departure planning *)
TYPE UDT_JC_DepSandboxType :
STRUCT
    Schedule : ARRAY[1..10] OF UDT_JC_TskScheduleType;           (* MAX_Units *)
    Batches  : ARRAY[1..10] OF UDT_BatchType;            (* MAX_Units *)
    Programs : ARRAY[1..10] OF UDT_TreatmentProgramType; (* MAX_Units *)
    Tasks    : ARRAY[1..3] OF UDT_JC_TskQueueType;               (* MAX_Transporters *)
    Valid    : BOOL;
END_STRUCT;
END_TYPE

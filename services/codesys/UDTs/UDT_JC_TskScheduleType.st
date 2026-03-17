(* TskScheduleType - Calculated batch schedule, one per unit *)
TYPE UDT_JC_TskScheduleType :
STRUCT
    StageCount : INT;                         (* number of active stages *)
    Stages     : ARRAY[1..30] OF UDT_JC_TskStageType; (* MAX_STEPS_PER_PROGRAM *)
END_STRUCT;
END_TYPE

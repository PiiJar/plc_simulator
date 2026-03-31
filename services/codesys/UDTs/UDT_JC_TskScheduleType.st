(* TskScheduleType - Calculated batch schedule, one per unit *)
TYPE UDT_JC_TskScheduleType :
STRUCT
    StageCount : INT;                         (* number of active stages *)
    Stages     : ARRAY[0..30] OF UDT_JC_TskStageType; (* index = ProgramStage, 0 = prepend *)
END_STRUCT;
END_TYPE

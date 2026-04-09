(* ManualTaskType - Manual transport task command from gateway *)
TYPE UDT_JC_ManualTaskType :
STRUCT
    LiftStation : INT; (* source station *)
    SinkStation : INT; (* destination station *)
    Valid       : BOOL; (* TRUE = pending command, PLC clears after execution *)
END_STRUCT;
END_TYPE

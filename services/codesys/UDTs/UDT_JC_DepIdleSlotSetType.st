(* DepIdleSlotSetType - Collection of idle slots for a transporter *)
TYPE UDT_JC_DepIdleSlotSetType :
STRUCT
    Slots : ARRAY[1..20] OF UDT_JC_DepIdleSlotType; (* DEP_MAX_IDLE_SLOTS *)
    Count : INT;
END_STRUCT;
END_TYPE

(* UDT_UnitType - Tracks a single bar/basket unit on the treatment line *)
TYPE UDT_UnitType :
STRUCT
    Location : INT; (* station number where unit currently is *)
    Status   : INT; (* NOT_USED=0, USED=1 *)
    Target   : INT; (* TO_NONE=0, TO_LOADING=1, TO_BUFFER=2, TO_PROCESS=3, TO_UNLOAD=4, TO_AVOID=5 *)
END_STRUCT;
END_TYPE

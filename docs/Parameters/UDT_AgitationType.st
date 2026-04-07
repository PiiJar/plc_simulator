(* AgitationType - Data structure derived from param.agitation SQL tables *)
TYPE UDT_AgitationType :
STRUCT
    AgitationId : INT; (* Primary key *)
    TankId : INT; (* Reference to tanks.TankId *)
    AgitationDevice : INT; (* Reference to devices.Id *)
    IsInUse : BOOL; (* Agitation enabled *)
END_STRUCT
END_TYPE

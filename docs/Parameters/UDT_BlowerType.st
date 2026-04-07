(* BlowerType - Data structure derived from param.blower SQL tables *)
TYPE UDT_BlowerType :
STRUCT
    BlowerId : INT; (* Primary key *)
    TankId : INT; (* Reference to tanks.TankId *)
    BlowerDevice : INT; (* Reference to devices.Id *)
    IsInUse : BOOL; (* Blower enabled *)
END_STRUCT
END_TYPE

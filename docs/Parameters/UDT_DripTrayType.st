(* DripTrayType - Data structure derived from param.driptray SQL tables *)
TYPE UDT_DripTrayType :
STRUCT
    RecordId : INT; (* Primary key *)
    TransporterId : INT; (* Reference to transporter *)
    DeviceId : INT; (* Reference to devices.Id *)
    IsInUse : BOOL; (* Drip tray enabled *)
END_STRUCT
END_TYPE

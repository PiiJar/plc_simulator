(* RectifierType - Data structure derived from param.rectifiers SQL tables *)
TYPE UDT_RectifierType :
STRUCT
    RecordId : INT; (* Primary key *)
    EquipmentCode : STRING(30); (* Equipment code *)
    StationId : INT; (* Reference to station *)
    MinVoltage : REAL; (* Minimum voltage *)
    MaxVoltage : REAL; (* Maximum voltage *)
    MinCurrent : REAL; (* Minimum current *)
    MaxCurrent : REAL; (* Maximum current *)
END_STRUCT
END_TYPE

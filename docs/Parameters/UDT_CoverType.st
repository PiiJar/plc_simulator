(* CoverType - Data structure derived from param.covers SQL tables *)
TYPE UDT_CoverType :
STRUCT
    CoverId : INT; (* Primary key *)
    StationId : INT; (* Reference to station.StationId *)
    CoverDevice : INT; (* Reference to devices.Id *)
    IsInUse : BOOL; (* Cover enabled *)
END_STRUCT
END_TYPE

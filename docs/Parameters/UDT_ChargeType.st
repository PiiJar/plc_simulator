(* ChargeType - Data structure derived from param.charges SQL tables - Production tracking *)
TYPE UDT_ChargeType :
STRUCT
    ChargeId : STRING(30); (* Primary key VARCHAR *)
    LoadTime : DATE_AND_TIME; (* Load timestamp *)
    UnloadTime : DATE_AND_TIME; (* Unload timestamp *)
    ToLineTime : DATE_AND_TIME; (* To line timestamp *)
    ShiftNumber : INT; (* Shift number *)
    UnitNumber : INT; (* Bar/basket number *)
    UnitType : INT; (* 0=Bar, 1=Basket *)
    HangerType : INT; (* Hanger type *)
    TreatmentProgramId : INT; (* Treatment program reference *)
    LoadStationId : INT; (* Load station reference *)
    UnloadStationId : INT; (* Unload station reference *)
    CurrentWanted : ARRAY[1..9] OF INT; (* Current wanted for groups 1-9 *)
    RectifierProgramId : ARRAY[1..9] OF INT; (* Rectifier programs 1-9 *)
    VoltageWanted : ARRAY[1..9] OF REAL; (* Voltage wanted for groups 1-9 *)
    TotalSurfaceArea : REAL; (* Total surface area of charge products m2, pre-computed by SCADA at charge creation *)
    Ultrawash : BOOL; (* Ultrawash enabled *)
    RotationProgram : INT; (* Rotation program *)
    RotationMode : INT; (* Rotation mode *)
    RetreatmentDone : BOOL; (* Retreatment completed *)
END_STRUCT
END_TYPE

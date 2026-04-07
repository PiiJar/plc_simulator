(* ProductionStatsType - Production statistics structure *)
TYPE UDT_ProductionStatsType :
STRUCT
    TotalChargesProcessed : DINT; (* Total charges processed *)
    TotalChargesOk : DINT; (* Total good charges *)
    TotalChargesNotOk : DINT; (* Total rejected charges *)
    TotalChargesReworked : DINT; (* Total reworked charges *)
    ShiftChargesProcessed : INT; (* Charges processed this shift *)
    ShiftChargesOk : INT; (* Good charges this shift *)
    ShiftChargesNotOk : INT; (* Rejected charges this shift *)
    CurrentShift : INT; (* Current shift number *)
END_STRUCT
END_TYPE

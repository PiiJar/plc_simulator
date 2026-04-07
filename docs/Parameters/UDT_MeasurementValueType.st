(* MeasurementValueType - Runtime measurement value data structure *)
TYPE UDT_MeasurementValueType :
STRUCT
    MeasurementId : INT; (* Reference to measurement config *)
    RawValue : REAL; (* Raw input value *)
    ScaledValue : REAL; (* Engineering scaled value *)
    Valid : BOOL; (* Value validity *)
    LowAlarm : BOOL; (* Low alarm active *)
    HighAlarm : BOOL; (* High alarm active *)
    Timestamp : DATE_AND_TIME; (* Last update timestamp *)
END_STRUCT
END_TYPE

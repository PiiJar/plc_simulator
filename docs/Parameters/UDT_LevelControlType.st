(* LevelControlType - Data structure derived from param.level_control SQL tables *)
(* Level control is fill-only. *)
(* MeasType: 0=Analog, 1=Digital *)
TYPE UDT_LevelControlType :
STRUCT
    FillId : INT; (* Primary key *)
    TankId : INT; (* Reference to tanks.TankId *)
    IsInUse : BOOL; (* Control enabled *)
    SourceTankId : INT; (* Source tank for filling *)
    HHLevel : REAL; (* High-High level setpoint *)
    HLevel : REAL; (* High level setpoint *)
    LLevel : REAL; (* Low level setpoint *)
    LLLevel : REAL; (* Low-Low level setpoint *)
    MeasType : INT; (* 0=Analog, 1=Digital *)
    MeasurementId : INT; (* Reference to measurements *)
    FillDeviceId : INT; (* Reference to devices.Id for fill valve/pump *)
    
    (* === Alternative Fill Device === *)
    AltFillDeviceId : INT; (* Alternative fill device ID (0 = not configured) *)
    AltFillOutputInverted : BOOL; (* TRUE = invert output for normally-open valve *)
    
    MaxFillTime : INT; (* Maximum fill time s *)
    SensorTimeFilter : REAL; (* Sensor time filter *)
    DiscrepencyTimeFilter : REAL; (* Discrepancy time filter *)
END_STRUCT
END_TYPE

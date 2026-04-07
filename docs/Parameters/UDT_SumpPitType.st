(* SumpPitType - Data structure derived from param.sump_pit SQL tables *)
(* Sump pit controller configuration: level measurement + transfer pump *)
(* Collects overflow/leaking media and allows manual pump-out *)
TYPE UDT_SumpPitType :
STRUCT
    Id : INT; (* Primary key *)
    IsInUse : BOOL; (* Control enabled *)
    MeasType : INT; (* 0=Analog (4-20mA transmitter), 1=Digital (float switches) *)
    MeasurementId : INT; (* Reference to measurements.id for analog mode *)
    HHLevel : REAL; (* High-High alarm threshold - stops water inlet, latched *)
    HLevel : REAL; (* High warning threshold - operator notification *)
    LLevel : REAL; (* Low threshold - informational *)
    LLLevel : REAL; (* Low-Low threshold - optionally stops pump *)
    LLStopsPump : BOOL; (* TRUE=LL level automatically stops pump *)
    PumpDeviceId : INT; (* Reference to devices.id for the transfer pump *)
    MaxPumpTime : INT; (* Max pump run time in seconds (0=no limit) *)
    SensorTimeFilter : REAL; (* Debounce filter time for digital switches (seconds) *)
    DiscrepencyTimeFilter : REAL; (* Sensor fault detection timeout (seconds) *)
END_STRUCT
END_TYPE

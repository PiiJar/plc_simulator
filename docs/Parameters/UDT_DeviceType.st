(* DeviceType - Data structure derived from param.devices SQL tables *)
(* DeviceType: 1=Pump, 2=Valve, 3=Motor, 4=Heater, 5=Cooler, 6=Agitator, 7=Cover, 8=Rectifier, 9=Filter, 10=Other *)
TYPE UDT_DeviceType :
STRUCT
    Id : INT; (* Primary key *)
    EquipmentCode : STRING(30); (* Equipment code *)
    DeviceName : STRING(30); (* Device name *)
    DeviceType : INT; (* Device type/category *)
    HasMCB : BOOL; (* Has Motor Circuit Breaker feedback *)
    HasFeedbackOn : BOOL; (* Has ON feedback signal *)
    HasFeedbackOff : BOOL; (* Has OFF feedback signal *)
    HasSafetySwitch : BOOL; (* Has safety switch *)
    ControlOnDelay : INT; (* ON control delay ms *)
    ControlOffDelay : INT; (* OFF control delay ms *)
    AlarmDelay : INT; (* Alarm delay ms *)
    MaxForceTime : INT; (* Maximum force time s *)
    AllowForceOn : BOOL; (* Allow manual force ON *)
END_STRUCT
END_TYPE

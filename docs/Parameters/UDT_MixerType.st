(* MixerType - Data structure derived from param.mixer SQL tables *)
TYPE UDT_MixerType :
STRUCT
    MixerId : INT; (* Primary key *)
    TankId : INT; (* Reference to tanks.TankId *)
    MixerDevice : INT; (* Reference to devices.Id *)
    IsInUse : BOOL; (* Mixer enabled *)
END_STRUCT
END_TYPE

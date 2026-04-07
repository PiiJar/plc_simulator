(* PumpType - Data structure derived from param.pump SQL table *)
(* Generic pump configuration covering circulation, filter, and transfer pumps *)
TYPE UDT_PumpType :
STRUCT
    PumpId : INT;                    (* Primary key *)
    TankId : INT;                    (* Reference to tanks.TankId *)
    PumpDeviceId : INT;              (* Reference to devices.Id *)
    IsInUse : BOOL;                  (* Pump enabled *)
    PumpFunction : INT;              (* 1=Circulation, 2=Filter, 3=Transfer *)
    HasModeSwitch : BOOL;            (* Has physical 3-position mode switch (Auto/Manual/Test) *)
END_STRUCT
END_TYPE

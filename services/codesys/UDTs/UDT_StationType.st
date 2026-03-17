TYPE UDT_StationType :
STRUCT
    StationId            : INT;  (* Primary key *)
    TankId               : INT;  (* Reference to tanks.TankId *)
    IsInUse              : BOOL; (* Station enabled *)
    StationType          : INT;  (* 0=Reserve, 1=Buffer, 2=Process, etc. *)

    (* Position in mm - used for collision avoidance and drive targets *)
    XPosition            : DINT; (* X position mm *)
    YPosition            : DINT; (* Y position mm *)
    ZPosition            : DINT; (* Z position mm *)
    LiftSinkZone         : INT;  (* Lift/sink zone *)
    AvoidDistance        : INT;  (* Avoid distance *)
    TakeOutDistance      : INT;  (* Take out distance *)
    DrippingTime         : INT;  (* Dripping time ×10 = tenths of second *)
    DeviceDelay          : INT;  (* Device delay ×10 = tenths of second *)
    DryWet               : INT;  (* 0=dry, 1=wet *)

    (* Cross transport parameters *)
    Crosstransport       : INT;  (* Cross transport index *)
    CrossTransportTime   : INT;  (* Cross transport time s *)
    ChangeStation        : INT;  (* Change station index *)
    DeviceConfig         : INT;  (* Device configuration *)

    (* Control indices - references to control arrays *)
    Temp_Index           : INT;  (* Temperature control index *)
    Level_Index          : INT;  (* Level control index *)
    Cond_Index           : INT;  (* Conductivity control index *)

    (* Rotation parameters *)
    HasAutomaticRotation : BOOL; (* TRUE = chemical tank (sink at 45°), FALSE = loading/buffer (sink at 0° vertical) *)
END_STRUCT;
END_TYPE

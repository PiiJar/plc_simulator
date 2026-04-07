(* RotationDeviceType - Basket rotation configuration *)
(* Controls basket angle: 0° (vertical/home), 45° (sink for chemical), 135° (lift from chemical) *)
(* Time-based positioning from single home sensor at 0° position *)
(* Location (station/transporter) is runtime data in GVL_Tracking, not stored here *)
TYPE UDT_RotationDeviceType :
STRUCT
    RotationDeviceId : INT;         (* Primary key *)
    RotationDevice : INT;           (* Reference to devices.Id for motor *)
    IsInUse : BOOL;                 (* Rotation enabled *)
    (* Time-based positioning parameters in milliseconds *)
    TimeHomeToSink45 : INT;         (* Time from home (0°) to sink position (45°) ms *)
    TimeHomeToLift135 : INT;        (* Time from home (0°) to lift position (135°) ms *)
    TimeFullRotation : INT;         (* Time for one complete rotation (360°) ms *)
    (* Fault detection *)
    AlarmTimeout : INT;             (* Max time to reach position before fault ms *)
END_STRUCT
END_TYPE

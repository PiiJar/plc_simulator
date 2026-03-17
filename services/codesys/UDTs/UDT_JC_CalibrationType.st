(* CalibrationType - Calibration teaching data, one per transporter *)
(* Gateway writes plan, PLC fills results *)
TYPE UDT_JC_CalibrationType :
STRUCT
    (* Plan — set by gateway via cfg_cmd=7 *)
    WetStation  : INT;  (* wet station number *)
    DryStation  : INT;  (* dry station number *)

    (* Results — read from g_move after MeasureMoveTimes records them *)
    LiftWetTime : INT;  (* lift time at wet station ×10 = tenths of second *)
    SinkWetTime : INT;  (* sink time at wet station ×10 = tenths of second *)
    LiftDryTime : INT;  (* lift time at dry station ×10 = tenths of second *)
    SinkDryTime : INT;  (* sink time at dry station ×10 = tenths of second *)
    XAccelTime  : INT;  (* measured acceleration time ×10 = tenths of second *)
    XDecelTime  : INT;  (* measured deceleration time ×10 = tenths of second *)
    XMaxSpeed   : DINT; (* measured max X speed mm/s *)
END_STRUCT;
END_TYPE

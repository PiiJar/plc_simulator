(* TaskArea - Lift/sink station ranges per transporter task area slot *)
TYPE UDT_TaskArea :
STRUCT
    MinLift : INT; (* minimum lift station number *)
    MaxLift : INT; (* maximum lift station number *)
    MinSink : INT; (* minimum sink station number *)
    MaxSink : INT; (* maximum sink station number *)
END_STRUCT;
END_TYPE

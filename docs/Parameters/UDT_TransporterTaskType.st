(* UDT_TransporterTaskType - Task definition for transporter lift/sink sequences *)
(* Converted from Siemens DT_TransporterTask *)
TYPE UDT_TransporterTaskType :
STRUCT
    LiftStation : INT;          (* Station number of the lift station *)
    LiftType : INT;             (* Lift type: 0=Slow/Wet, 1=Fast/Dry *)
    LiftDrippingTime : INT;     (* Dripping time when lifting (seconds) *)
    SinkStation : INT;          (* Station number of the sink station *)
    SinkType : INT;             (* Sink type: 0=Slow/Wet, 1=Fast/Dry *)
    TimeLeft : INT;             (* Time left on the lift station (seconds) *)
    Start : INT;                (* Start trigger *)
END_STRUCT
END_TYPE

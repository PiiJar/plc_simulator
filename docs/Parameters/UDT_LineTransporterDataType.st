(* UDT_LineTransporterDataType - Working data for transporter collision avoidance *)
(* Used internally by FB_TransporterWorkingArea sub-blocks *)
TYPE UDT_LineTransporterDataType :
STRUCT
    StateIndex : INT;       (* Index into ioTransporterStates array *)
    ID : INT;               (* Transporter ID for tie-breaking *)
    XPos : DINT;            (* Current X position mm *)
    Phase : INT;            (* 0=idle, 1=to_source, 2=lift, 3=to_sink, 4=sink *)
    Status : INT;           (* 0=off, 1=fault, 2=manual, 3=semi, 4=auto *)
    FinalTarget : DINT;     (* Final X target position mm *)
    AvoidDist : DINT;       (* Avoid distance from config mm *)
    ConfigMinX : DINT;      (* Configured minimum X limit mm *)
    ConfigMaxX : DINT;      (* Configured maximum X limit mm *)
    CanEvade : BOOL;        (* Can perform evasion maneuver *)
    Priority : DINT;        (* Collision avoidance priority (higher = more important) *)
END_STRUCT
END_TYPE

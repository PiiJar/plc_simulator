(* TransporterStatusType - Runtime transporter status data structure *)
TYPE UDT_TransporterStatusType :
STRUCT
    TransporterId            : INT;  (* Reference to transporter config *)

    (* Current positions in mm *)
    XPosition                : DINT; (* Current X position mm *)
    YPosition                : DINT; (* Current Y position mm *)
    ZPosition                : DINT; (* Current Z position mm *)

    (* Station tracking *)
    CurrentStation           : INT;  (* Current station *)
    LiftStationTarget        : INT;  (* Lift target station *)
    SinkStationTarget        : INT;  (* Sink target station *)

    (* Phase and Status for collision avoidance *)
    Status                   : INT;  (* 0=off, 1=fault, 2=manual, 3=semi, 4=auto *)
    Phase                    : INT;  (* 0=idle, 1=to_source, 2=lift, 3=to_sink, 4=sink *)
    TaskId                   : LINT; (* Current task ID *)
    TaskRemainingTime        : DINT; (* Remaining time for current task s *)
    LiftStationRemainingTime : DINT; (* Remaining time at lift station s *)
    DrippingTime             : INT;  (* Dripping time ×10 = tenths of second *)

    (* Target positions *)
    XDriveTarget             : DINT; (* X drive target position mm *)
    XFinalTarget             : DINT; (* Final X target position mm *)
    YDriveTarget             : DINT; (* Y drive target position mm *)
    YFinalTarget             : DINT; (* Final Y target position mm *)

    (* Working area limits - calculated by FB_TransporterWorkingArea *)
    XMinDriveLimit           : DINT; (* Minimum X drive limit mm *)
    XMaxDriveLimit           : DINT; (* Maximum X drive limit mm *)

    (* Runtime status *)
    Busy                     : BOOL; (* Transporter busy *)
    Fault                    : BOOL; (* Transporter fault *)
    AtPosition               : BOOL; (* At target position *)
    CanEvade                 : BOOL; (* Can perform evasion maneuver *)
    Priority                 : DINT; (* Collision avoidance priority *)

    (* Additional status fields for FB_TransporterController *)
    IsActive                 : BOOL; (* Transporter is actively executing a task *)
    IsCarrying               : BOOL; (* Transporter is carrying product *)
END_STRUCT;
END_TYPE

(* UDT_UnitType - Tracks a single bar/basket unit on the treatment line *)
TYPE UDT_UnitType :
STRUCT
    Location         : INT;  (* station number where unit currently is *)
    Status           : INT;  (* NOT_USED=0, USED=1 *)
    Target           : INT;  (* TO_NONE=0, TO_LOADING=1, TO_BUFFER=2, TO_PROCESS=3, TO_UNLOAD=4, TO_AVOID=5 *)
    
    (* Runtime tracking fields - updated by FB_UnitTracker and FB_UnitTimeCalc *)
    StationIndex     : INT;  (* Current station index, or transporter ID when in transit *)
    Stage            : INT;  (* Current treatment program step index *)
    ElapsedTime      : DINT; (* Elapsed time at current station in seconds *)
    RemainingTime    : INT;  (* Remaining time at current station in seconds *)
    NextStationIndex : INT;  (* Resolved next destination station index *)
    IsReady          : BOOL; (* TRUE when ElapsedTime >= MinTime for current step *)
    IsOverdue        : BOOL; (* TRUE when ElapsedTime > MaxTime for current step *)
    
    (* Charge data - copied at load time *)
    Charge           : UDT_ChargeType; (* Production charge associated with this unit *)
END_STRUCT;
END_TYPE

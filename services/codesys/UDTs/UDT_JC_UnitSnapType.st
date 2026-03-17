(* UnitSnapType - Snapshot of unit state, pre-computed once per cycle by NoTreatmentStates *)
TYPE UDT_JC_UnitSnapType :
STRUCT
    IsActive   : BOOL; (* status <> NOT_USED *)
    Location   : INT;  (* location *)
    LocationOp : INT;  (* station operation at location *)
    Target     : INT;  (* target *)
    HasBatch   : BOOL; (* batch_code <> 0 *)
    BatchState : INT;  (* batch state *)
    CurStage   : INT;  (* current stage from g_batch *)
    InBuffer   : BOOL; (* loc operation 44..47 *)
    OnStation  : BOOL; (* loc in STATION_ARRAY range *)
    Elapsed    : LINT; (* time at station, 0 if not on station *)
    CalTime    : DINT; (* cal_time for current stage (seconds) *)
END_STRUCT;
END_TYPE

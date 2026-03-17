(* BatchType - Runtime state of a production batch/charge on a unit *)
TYPE UDT_BatchType :
STRUCT
    BatchCode : INT;  (* batch code - numeric ID *)
    CurStage  : INT;  (* current stage number, 0 = not started *)
    State     : INT;  (* NOT_PROCESSED=0, IN_PROCESS=1, PROCESSED=2 *)
    ProgId    : INT;  (* treatment program number *)
    StartTime : LINT; (* batch start time (unix seconds) *)
    MinTime   : DINT; (* stage minimum time (seconds) *)
    MaxTime   : DINT; (* stage maximum time (seconds) *)
    CalTime   : DINT; (* stage calculated / target time (seconds) *)
END_STRUCT;
END_TYPE

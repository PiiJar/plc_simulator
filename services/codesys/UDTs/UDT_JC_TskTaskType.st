(* TskTaskType - Transporter task: pickup/putdown assignment *)
TYPE UDT_JC_TskTaskType :
STRUCT
    Unit              : INT;  (* unit index 1..10, 0 = no task *)
    Stage             : INT;  (* program stage that created this task *)
    LiftStationTarget : INT;  (* station to pick up from *)
    SinkStationTarget : INT;  (* station to put down to *)
    StartTime         : LINT; (* absolute time task begins (s), unix seconds *)
    FinishTime        : LINT; (* absolute time task completes (s), unix seconds *)
    CalcTime          : DINT; (* treatment calc_time for flex (seconds) *)
    MinTime           : DINT; (* treatment min_time for flex_down (seconds) *)
    MaxTime           : DINT; (* treatment max_time for flex_up (seconds) *)
    NttPrimary        : INT;  (* 1 = sink is NTT primary destination, 0 = all other cases *)
END_STRUCT;
END_TYPE

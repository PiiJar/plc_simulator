(* DepDelayActionType - Schedule adjustment to accommodate departure *)
TYPE UDT_JC_DepDelayActionType :
STRUCT
    Stage     : INT;  (* program stage to delay *)
    DelayTime : DINT; (* delay amount (seconds) *)
    Target    : INT;  (* 0=batch cur_stage delay, 1=program stage delay *)
    Valid     : BOOL;
END_STRUCT;
END_TYPE

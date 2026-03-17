(* DepFitResultType - Outcome of fitting a departure task into idle slots *)
TYPE UDT_JC_DepFitResultType :
STRUCT
    Fits          : BOOL; (* TRUE = task fits in a slot *)
    DelayTime     : DINT; (* delay needed to make it fit (seconds) *)
    NeedExtraTime : DINT; (* extra time that does not fit (seconds) *)
    TaskEndTime   : LINT; (* calculated task end time (s), unix seconds *)
    SlotIdx       : INT;  (* index of the used idle slot *)
    TransporterId : INT;  (* transporter id that can handle it *)
END_STRUCT;
END_TYPE

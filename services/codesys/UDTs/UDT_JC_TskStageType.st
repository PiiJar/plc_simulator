(* TskStageType - Calculated batch schedule stage *)
(* Times are absolute epoch-offset seconds (g_time_s reference frame) *)
TYPE UDT_JC_TskStageType :
STRUCT
    Station      : INT;  (* station number, 0 = unused stage *)
    ProgramStage : INT;  (* batch program stage number (1..N), 0 = pre-position entry *)
    EntryTime    : LINT; (* absolute arrival time (s), unix seconds *)
    ExitTime     : LINT; (* absolute departure time (s), unix seconds *)
    MinTime      : DINT; (* minimum treatment time (seconds) *)
    CalcTime     : DINT; (* calculated target treatment time (seconds) *)
    MaxTime      : DINT; (* maximum treatment time (seconds) *)
    TransferTime : DINT; (* transfer time from previous station (seconds) *)
END_STRUCT;
END_TYPE

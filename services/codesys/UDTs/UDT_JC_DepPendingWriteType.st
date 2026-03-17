(* DepPendingWriteType - Data to commit from sandbox to globals after ACTIVATE *)
TYPE UDT_JC_DepPendingWriteType :
STRUCT
    Valid        : BOOL;
    Programs     : ARRAY[1..10] OF UDT_TreatmentProgramType; (* MAX_Units *)
    Schedule     : ARRAY[1..10] OF UDT_JC_TskScheduleType;           (* MAX_Units *)
    BatchUnit    : INT;                                      (* activated batch: unit index *)
    BatchStage   : INT;                                      (* activated batch: new cur_stage *)
    BatchState   : INT;                                      (* activated batch: new state (IN_PROCESS=1) *)
    BatchMinTime : DINT;                                     (* stage 0 min_time for activated batch (seconds) *)
    BatchMaxTime : DINT;                                     (* stage 0 max_time for activated batch (seconds) *)
    BatchCalTime : DINT;                                     (* stage 0 cal_time for activated batch (seconds) *)
    TimeStamp    : LINT;                                     (* activation time (s), unix seconds *)
END_STRUCT;
END_TYPE

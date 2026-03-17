(* TskQueueType - Transporter task queue *)
TYPE UDT_JC_TskQueueType :
STRUCT
    Count : INT;                        (* number of active tasks *)
    Queue : ARRAY[1..10] OF UDT_JC_TskTaskType; (* task slots, MAX_TASK_QUEUE *)
END_STRUCT;
END_TYPE

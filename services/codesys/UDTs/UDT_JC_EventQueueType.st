(* EventQueueType - Event message queue PLC → Gateway *)
(* Handshake: PLC outputs head message via Modbus.
   Gateway reads it, processes it, writes ack_seq = head.seq.
   PLC sees ack match → advances head, count--. *)
TYPE UDT_JC_EventQueueType :
STRUCT
    Count   : INT;                         (* messages currently in queue (0..10) *)
    Head    : INT;                         (* index of oldest message, 1-based *)
    NextSeq : INT;                         (* next sequence number to assign *)
    Buffer  : ARRAY[1..10] OF UDT_JC_EventMsgType; (* circular buffer *)
END_STRUCT;
END_TYPE

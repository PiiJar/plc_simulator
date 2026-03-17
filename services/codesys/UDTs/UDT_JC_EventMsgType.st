(* EventMsgType - Generic event message with type-dependent payload *)
(*
   All events share TaskId in f[1..2] for cross-referencing:
     TaskId = f[1] * 65536 + f[2]  (= g_transporter.TaskId)

   msg_type=1 (TASK_DISPATCHED):
     f[1]=TaskId_Hi  f[2]=TaskId_Lo
     f[3]=transporter  f[4]=UnitId  f[5]=lift_stn  f[6]=sink_stn
     f[7]=stage  f[8]=batch_code
     f[9]=calc_time(s)  f[10]=min_time(s)  f[11]=max_time(s)
     f[12]=xfer_total(s)

   msg_type=2 (LIFT):
     f[1]=TaskId_Hi  f[2]=TaskId_Lo
     f[3]=transporter  f[4]=UnitId  f[5]=lift_stn  f[6]=batch_code
     f[7]=stage  f[8]=actual_time(s)  f[9]=calc_time(s)
     f[10]=min_time(s)  f[11]=max_time(s)  f[12]=xfer_total(s)

   msg_type=3 (TASK_COMPLETE):
     f[1]=TaskId_Hi  f[2]=TaskId_Lo  f[3]=transporter
     f[4]=siirto_nostoasemalle(s)   f[5]=odotus_ennen_nostoa(s)
     f[6]=nosto(s)  f[7]=valutus(s)  f[8]=trip_close(s)
     f[9]=siirto_laskuasemalle(s)  f[10]=trip_open(s)
     f[11]=lasku(s)  f[12]=total(s)
*)
TYPE UDT_JC_EventMsgType :
STRUCT
    Seq     : INT;                 (* unique incrementing sequence number *)
    MsgType : INT;                 (* 1=task_dispatched, 2=lift, ... *)
    TsHi    : INT;                 (* timestamp upper 16 bits (unix s) *)
    TsLo    : INT;                 (* timestamp lower 16 bits *)
    Payload : ARRAY[1..12] OF INT; (* payload — meaning depends on msg_type *)
END_STRUCT;
END_TYPE

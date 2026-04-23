(* ============================================================
   SIM_FB_EventQueue — Event message queue handler (OPC UA)

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Manages a circular 10-slot event queue (Event).

   Enqueue: caller writes msg to EventPending, sets
   EventPendingValid := TRUE. This FB picks it up.

   Dequeue: Gateway reads Event.Buffer[Head] via OPC UA,
   then writes EventAckSeq to acknowledge.

   Called every PLC scan from PLC_PRG.
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_EventQueue
VAR_EXTERNAL
  Event               : UDT_JC_EventQueueType;
  EventPending       : UDT_JC_EventMsgType;
  EventPendingValid : BOOL;
  EventAckSeq       : INT;
END_VAR
VAR
  vTail : INT;
END_VAR

(* ── 1. Enqueue: pick up pending message if queue not full ── *)
IF EventPendingValid AND Event.Count < 10 THEN
  vTail := ((Event.Head - 1 + Event.Count) MOD 10) + 1;

  EventPending.Seq := Event.NextSeq;
  Event.NextSeq := Event.NextSeq + 1;
  IF Event.NextSeq > 32000 THEN
    Event.NextSeq := 1;
  END_IF;

  Event.Buffer[vTail] := EventPending;
  Event.Count := Event.Count + 1;

  EventPendingValid := FALSE;
END_IF;

(* ── 2. Dequeue: check gateway ack for head message ── *)
IF Event.Count > 0 THEN
  IF EventAckSeq = Event.Buffer[Event.Head].Seq THEN
    Event.Head := (Event.Head MOD 10) + 1;
    Event.Count := Event.Count - 1;
  END_IF;
END_IF;

END_FUNCTION_BLOCK

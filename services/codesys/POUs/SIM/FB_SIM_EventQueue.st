(* ============================================================
   FB_SIM_EventQueue — Event message queue handler (OPC UA)

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Manages a circular 10-slot event queue (gEvent).

   Enqueue: caller writes msg to gEventPending, sets
   gEventPendingValid := TRUE. This FB picks it up.

   Dequeue: Gateway reads gEvent.Buffer[Head] via OPC UA,
   then writes gEventAckSeq to acknowledge.

   Called every PLC scan from PLC_PRG.
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION_BLOCK FB_SIM_EventQueue
VAR_EXTERNAL
  gEvent             : UDT_JC_EventQueueType;
  gEventPending      : UDT_JC_EventMsgType;
  gEventPendingValid : BOOL;
  gEventAckSeq       : INT;
END_VAR
VAR
  vTail : INT;
END_VAR

(* ── 1. Enqueue: pick up pending message if queue not full ── *)
IF gEventPendingValid AND gEvent.Count < 10 THEN
  vTail := ((gEvent.Head - 1 + gEvent.Count) MOD 10) + 1;

  gEventPending.Seq := gEvent.NextSeq;
  gEvent.NextSeq := gEvent.NextSeq + 1;
  IF gEvent.NextSeq > 32000 THEN
    gEvent.NextSeq := 1;
  END_IF;

  gEvent.Buffer[vTail] := gEventPending;
  gEvent.Count := gEvent.Count + 1;

  gEventPendingValid := FALSE;
END_IF;

(* ── 2. Dequeue: check gateway ack for head message ── *)
IF gEvent.Count > 0 THEN
  IF gEventAckSeq = gEvent.Buffer[gEvent.Head].Seq THEN
    gEvent.Head := (gEvent.Head MOD 10) + 1;
    gEvent.Count := gEvent.Count - 1;
  END_IF;
END_IF;

END_FUNCTION_BLOCK

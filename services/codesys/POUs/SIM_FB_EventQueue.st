(* ============================================================
   SIM_FB_EventQueue — Event message queue handler (OPC UA)
   ============================================================
   Manages a circular 10-slot event queue (g_event).

   - enqueue: caller writes msg fields to g_event_pending,
     then sets g_event_pending_valid := TRUE.
     This FB picks it up and adds to queue.
   - dequeue: Gateway reads g_event.Buffer[Head] directly
     via OPC UA, then writes g_event_ack_seq to acknowledge.
     PLC sees ack match → advance head, count--.

   Called every PLC scan from plc_prg (always, not gated by
   scheduler turn).

   OPC UA handshake:
     PLC:    g_event.Count, g_event.Head, g_event.Buffer[] → readable via OPC UA
     Gateway: g_event_ack_seq → writable via OPC UA
     When g_event_ack_seq = g_event.Buffer[Head].Seq: message consumed → next.
   ============================================================ *)

FUNCTION_BLOCK SIM_FB_EventQueue
VAR_EXTERNAL
  g_event               : UDT_JC_EventQueueType;
  g_event_pending       : UDT_JC_EventMsgType;
  g_event_pending_valid : BOOL;
  g_event_ack_seq       : INT;
END_VAR
VAR
  tail : INT;
END_VAR

(* ── 1. Enqueue: pick up pending message if queue not full ── *)
IF g_event_pending_valid AND g_event.Count < 10 THEN
  tail := ((g_event.Head - 1 + g_event.Count) MOD 10) + 1;

  g_event_pending.Seq := g_event.NextSeq;
  g_event.NextSeq := g_event.NextSeq + 1;
  IF g_event.NextSeq > 32000 THEN
    g_event.NextSeq := 1;
  END_IF;

  g_event.Buffer[tail] := g_event_pending;
  g_event.Count := g_event.Count + 1;

  g_event_pending_valid := FALSE;
END_IF;

(* ── 2. Dequeue: check gateway ack for head message ── *)
IF g_event.Count > 0 THEN
  IF g_event_ack_seq = g_event.Buffer[g_event.Head].Seq THEN
    g_event.Head := (g_event.Head MOD 10) + 1;
    g_event.Count := g_event.Count - 1;
  END_IF;
END_IF;

END_FUNCTION_BLOCK

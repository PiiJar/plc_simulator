(* ============================================================
   SIM_FB_EventQueue — Event message queue handler (OPC UA)

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Manages a circular 10-slot event queue (g_event).

   Enqueue: caller writes msg to g_event_pending, sets
   g_event_pending_valid := TRUE. This FB picks it up.

   Dequeue: Gateway reads g_event.Buffer[Head] via OPC UA,
   then writes g_event_ack_seq to acknowledge.

   Called every PLC scan from PLC_PRG.
   ------------------------------------------------------------
   Changes:
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

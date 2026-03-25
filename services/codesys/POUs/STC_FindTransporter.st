(* ============================================================
   STC_FindTransporter — Find best covering transporter

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Finds which transporter (1..3) can handle a lift→sink pair
   by checking cfg[].TaskArea[] coverage.

   When multiple transporters match, scores by:
     1. Fewest queued tasks (load balance)
     2. Closest last-sink to new lift (travel efficiency)

   If i_sink_stn = 0, only lift coverage is checked.

   NOTE: Kept as FUNCTION_BLOCK because MATIEC cannot handle
   ARRAY OF STRUCT as FUNCTION VAR_INPUT parameter.
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION_BLOCK STC_FindTransporter
VAR_INPUT
  i_lift_stn : INT;     (* lift station number *)
  i_sink_stn : INT;     (* sink station number, 0 = lift-only search *)
END_VAR
VAR_OUTPUT
  o_trans : INT;         (* transporter ID 1..3, 0 = not found *)
END_VAR
VAR_EXTERNAL CONSTANT
  MAX_Transporters : INT;
END_VAR
VAR_EXTERNAL
  g_cfg : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_task : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
END_VAR
VAR
  ti       : INT;
  ai       : INT;
  area     : UDT_TaskArea;
  can_lift : BOOL;
  can_sink : BOOL;
  (* Multi-transporter scoring *)
  capable      : ARRAY[1..3] OF INT;   (* capable transporter IDs *)
  cap_count    : INT;
  best_idx     : INT;
  best_count   : INT;
  best_dist    : INT;
  cur_count    : INT;
  cur_dist     : INT;
  last_sink    : INT;
  ci           : INT;
  qi           : INT;
END_VAR

o_trans := 0;
cap_count := 0;

(* Phase 1: Collect all capable transporters *)
FOR ti := 1 TO MAX_Transporters DO
  FOR ai := 1 TO 4 DO
    IF cap_count < 3 THEN
      area := g_cfg[ti].TaskArea[ai];
      IF area.MinLift > 0 OR area.MaxLift > 0 THEN
        can_lift := (i_lift_stn >= area.MinLift) AND (i_lift_stn <= area.MaxLift);
        IF i_sink_stn = 0 THEN
          IF can_lift THEN
            (* Check not already added — nested IF to avoid array bounds on capable[0] *)
            IF cap_count = 0 THEN
              cap_count := cap_count + 1;
              capable[cap_count] := ti;
            ELSIF capable[cap_count] <> ti THEN
              cap_count := cap_count + 1;
              capable[cap_count] := ti;
            END_IF;
          END_IF;
        ELSE
          can_sink := (i_sink_stn >= area.MinSink) AND (i_sink_stn <= area.MaxSink);
          IF can_lift AND can_sink THEN
            IF cap_count = 0 THEN
              cap_count := cap_count + 1;
              capable[cap_count] := ti;
            ELSIF capable[cap_count] <> ti THEN
              cap_count := cap_count + 1;
              capable[cap_count] := ti;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* Phase 2: Select best — score by task count then distance *)
IF cap_count = 0 THEN
  o_trans := 0;
ELSIF cap_count = 1 THEN
  o_trans := capable[1];
ELSE
  (* JS: scored.sort((a,b) => a.count - b.count || a.distFromLastTask - b.distFromLastTask) *)
  best_idx := 1;
  best_count := g_task[capable[1]].Count;
  (* Find last sink station for first candidate *)
  last_sink := 0;
  IF best_count > 0 THEN
    last_sink := g_task[capable[1]].Queue[best_count].SinkStationTarget;
  END_IF;
  IF last_sink > 0 THEN
    best_dist := ABS(last_sink - i_lift_stn);
  ELSE
    best_dist := 0;
  END_IF;

  FOR ci := 2 TO cap_count DO
    cur_count := g_task[capable[ci]].Count;
    last_sink := 0;
    IF cur_count > 0 THEN
      last_sink := g_task[capable[ci]].Queue[cur_count].SinkStationTarget;
    END_IF;
    IF last_sink > 0 THEN
      cur_dist := ABS(last_sink - i_lift_stn);
    ELSE
      cur_dist := 0;
    END_IF;

    IF cur_count < best_count THEN
      best_idx := ci;
      best_count := cur_count;
      best_dist := cur_dist;
    ELSIF cur_count = best_count AND cur_dist < best_dist THEN
      best_idx := ci;
      best_count := cur_count;
      best_dist := cur_dist;
    END_IF;
  END_FOR;

  o_trans := capable[best_idx];
END_IF;

END_FUNCTION_BLOCK

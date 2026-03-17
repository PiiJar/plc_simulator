(* ============================================================
   TWA_CalcPriority.st — Priority calculation for collision avoidance

   Priority rules (from transporterWorkingArea.js):
     canEvade = FALSE  → 100000 (cannot move, others must avoid)
     phase 3 (to_sink) → 200000 + (99999 - distance_to_target)
     phase 1 (to_lift) → 100000 + (99999 - distance_to_target)
     phase 0 (idle)    → 1

   Returns REAL to avoid DINT compatibility issues.
   Values fit within REAL precision (max ~300000).
   ============================================================ *)

FUNCTION TWA_CalcPriority : DINT
VAR_INPUT
  i_phase     : INT;
  i_can_evade : BOOL;
  i_x_pos     : DINT;
  i_x_target  : DINT;
END_VAR
VAR
  dist : DINT;
END_VAR

IF NOT i_can_evade THEN
  TWA_CalcPriority := DINT#100000;
  RETURN;
END_IF;

IF i_phase = 3 THEN
  dist := ABS(i_x_pos - i_x_target);
  IF dist > 99999 THEN dist := 99999; END_IF;
  TWA_CalcPriority := DINT#200000 + (DINT#99999 - dist);
ELSIF i_phase = 1 THEN
  dist := ABS(i_x_pos - i_x_target);
  IF dist > 99999 THEN dist := 99999; END_IF;
  TWA_CalcPriority := DINT#100000 + (DINT#99999 - dist);
ELSE
  TWA_CalcPriority := 1;
END_IF;

END_FUNCTION

(* ============================================================
   STC_FB_CollectActiveBatches — Filter active batches to list
   ============================================================
   Scans g_batch[1..10] and collects unit indices matching
   mode-specific conditions into an output list.

   Common conditions for both modes:
     unit.Status  = USED (1)
     unit.Target  = TO_NONE (0)
     batch.prog_id = g_program[ui].ProgramId  (valid program)

   Mode:
     i_mode = 0 — active (in-production) batches:
                   batch.state = IN_PROCESS (1)
                   batch.CurStage >= 0 AND <= 99
     i_mode = 1 — waiting batches:
                   Direct lookup: g_station_loc[114].UnitId
                   Only station 114 can hold a waiting batch.

   Replaces 3× duplicated collection loops in:
     TSK_FB_Scheduler (phase 1, active batches)
     DEP_FB_Scheduler (phase 100, active + waiting batches)
   ============================================================ *)

FUNCTION_BLOCK STC_FB_CollectActiveBatches
VAR_INPUT
  i_mode : INT;    (* 0 = all active, 1 = waiting only *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Units : INT;
    MAX_StationIndex : INT;
END_VAR
VAR_EXTERNAL
  g_batch       : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_unit        : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_program     : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_station_loc : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
END_VAR
VAR_OUTPUT
  o_list  : ARRAY[1..MAX_Units] OF INT;  (* unit indices *)
  o_count : INT;
END_VAR
VAR
  ui : INT;
END_VAR

o_count := 0;
FOR ui := 1 TO MAX_Units DO
  o_list[ui] := 0;
END_FOR;

IF i_mode = 1 THEN
  (* ── Waiting batch: direct lookup at station 114 ── *)
  ui := g_station_loc[114].UnitId;
  IF ui >= 1 AND ui <= MAX_Units THEN
    IF g_unit[ui].Status = 1
       AND g_unit[ui].Target = 0
       AND g_batch[ui].State = 0
       AND g_batch[ui].ProgId = g_program[ui].ProgramId
       AND g_program[ui].ProgramId > 0 THEN
      o_count := 1;
      o_list[1] := ui;
    END_IF;
  END_IF;
  RETURN;
END_IF;

(* ── Mode 0: active batches — loop ── *)
FOR ui := 1 TO MAX_Units DO
  IF g_unit[ui].Status = 1
     AND g_unit[ui].Target = 0
     AND g_batch[ui].ProgId = g_program[ui].ProgramId
     AND g_program[ui].ProgramId > 0 THEN

    IF g_batch[ui].State = 1
       AND g_batch[ui].CurStage >= 0
       AND g_batch[ui].CurStage <= 99 THEN
      o_count := o_count + 1;
      o_list[o_count] := ui;
    END_IF;
  END_IF;
END_FOR;

END_FUNCTION_BLOCK

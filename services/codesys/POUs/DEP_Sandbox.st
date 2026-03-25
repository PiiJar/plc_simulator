(* ============================================================
   DEP_Sandbox — Sandbox snapshot / restore / clear

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Copies between live globals and DEP workspace arrays
   via VAR_IN_OUT.

   Commands:
     1 = SNAPSHOT  — live → workspace
     2 = RESTORE   — workspace → live
     3 = CLEAR     — noop for array-based workspace
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION DEP_Sandbox : BOOL
VAR_INPUT
  i_cmd : INT;
END_VAR
VAR_IN_OUT
  io_wk_schedule : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  io_wk_batch    : ARRAY[1..10] OF UDT_BatchType;
  io_wk_program  : ARRAY[1..10] OF UDT_TreatmentProgramType;
  io_wk_task     : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
END_VAR
VAR_EXTERNAL
  g_schedule : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_batch    : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_program  : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_task     : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
END_VAR
VAR
  ui : INT;
  ti : INT;
END_VAR

DEP_Sandbox := TRUE;

IF i_cmd = 1 THEN
  (* SNAPSHOT: live → workspace *)
  FOR ui := 1 TO MAX_Units DO
    io_wk_schedule[ui] := g_schedule[ui];
    io_wk_batch[ui]    := g_batch[ui];
    io_wk_program[ui]  := g_program[ui];
  END_FOR;
  FOR ti := 1 TO MAX_Transporters DO
    io_wk_task[ti] := g_task[ti];
  END_FOR;

ELSIF i_cmd = 2 THEN
  (* RESTORE: workspace → live (for REJECT rollback) *)
  FOR ui := 1 TO MAX_Units DO
    g_schedule[ui] := io_wk_schedule[ui];
    IF io_wk_batch[ui].BatchCode > 0 THEN
      g_batch[ui] := io_wk_batch[ui];
    END_IF;
    IF io_wk_program[ui].ProgramId > 0 THEN
      g_program[ui] := io_wk_program[ui];
    END_IF;
  END_FOR;
  FOR ti := 1 TO MAX_Transporters DO
    g_task[ti] := io_wk_task[ti];
  END_FOR;

ELSIF i_cmd = 3 THEN
  ;  (* CLEAR: nothing needed *)

END_IF;

END_FUNCTION

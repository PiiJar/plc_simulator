(* ============================================================
   DEP_FB_Sandbox — Sandbox snapshot / restore / clear
   ============================================================
   Copies global scheduler state to/from the departure sandbox.
   Struct assignment `a := b` in ST copies all fields automatically.

   Source: departureScheduler.js _copyDepartureSandbox()

   Commands:
     1 = SNAPSHOT  — copy globals → g_dep_sandbox
     2 = RESTORE   — copy g_dep_sandbox → globals
     3 = CLEAR     — invalidate sandbox

   Used by: DEP_FB_Scheduler (INIT, REJECT, ACTIVATE)
   ============================================================ *)

FUNCTION_BLOCK DEP_FB_Sandbox
VAR_INPUT
  i_cmd : INT;     (* 1=SNAPSHOT, 2=RESTORE, 3=CLEAR *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
END_VAR

VAR_EXTERNAL
  g_schedule    : ARRAY[1..MAX_Units] OF UDT_JC_TskScheduleType;
  g_batch     : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_program    : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_task       : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
  g_dep_sandbox : UDT_JC_DepSandboxType;
END_VAR
VAR
  ui : INT;
  ti : INT;
END_VAR

IF i_cmd = 1 THEN
  (* ── SNAPSHOT: globals → sandbox ── *)
  FOR ui := 1 TO MAX_Units DO
    g_dep_sandbox.Schedule[ui] := g_schedule[ui];
    g_dep_sandbox.Batches[ui]  := g_batch[ui];
    g_dep_sandbox.Programs[ui] := g_program[ui];
  END_FOR;
  FOR ti := 1 TO MAX_Transporters DO
    g_dep_sandbox.Tasks[ti] := g_task[ti];
  END_FOR;
  g_dep_sandbox.Valid := TRUE;

ELSIF i_cmd = 2 THEN
  (* ── RESTORE: sandbox → globals ── *)
  (* Only restore entries that existed at snapshot time.
     Gateway may have loaded new programs/batches between
     snapshot and restore — protect those writes. *)
  IF g_dep_sandbox.Valid THEN
    FOR ui := 1 TO MAX_Units DO
      g_schedule[ui] := g_dep_sandbox.Schedule[ui];
      IF g_dep_sandbox.Batches[ui].BatchCode > 0 THEN
        g_batch[ui]  := g_dep_sandbox.Batches[ui];
      END_IF;
      IF g_dep_sandbox.Programs[ui].ProgramId > 0 THEN
        g_program[ui] := g_dep_sandbox.Programs[ui];
      END_IF;
    END_FOR;
    FOR ti := 1 TO MAX_Transporters DO
      g_task[ti] := g_dep_sandbox.Tasks[ti];
    END_FOR;
  END_IF;

ELSIF i_cmd = 3 THEN
  (* ── CLEAR: invalidate sandbox ── *)
  g_dep_sandbox.Valid := FALSE;

END_IF;

END_FUNCTION_BLOCK

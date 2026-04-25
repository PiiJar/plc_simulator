(* ===========================================================================================
 *  FC_DEP_Sandbox — Sandbox snapshot / restore / clear
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Copies batch and program data between live globals and
 *  DEP workspace arrays via VAR_IN_OUT.
 *  Schedule is NOT copied — DEP calculates it fresh (phases 1000+i).
 *  Task queues are NOT copied — DEP rebuilds them (phases 2000+).
 *
 *  Commands:
 *  1 = SNAPSHOT  — live batch+program → workspace
 *  2 = RESTORE   — workspace batch+program → live
 *  3 = CLEAR     — noop for array-based workspace
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_DEP_Sandbox : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iCmd : INT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 10=MAX_UNITS, 3=MAX_TRANSPORTERS *)
  ioWkSchedule : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  ioWkBatch    : ARRAY[1..10] OF UDT_BatchType;
  ioWkProgram  : ARRAY[1..10] OF UDT_TreatmentProgramType;
  ioWkTask     : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS : INT;
    MAX_UNITS        : INT;
END_VAR

VAR_EXTERNAL
  gSchedule         : ARRAY[1..MAX_UNITS] OF UDT_JC_TskScheduleType;
  gBatch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gTask             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
END_VAR

VAR
  vUi : INT;
END_VAR

FC_DEP_Sandbox := TRUE;

IF iCmd = 1 THEN
  (* SNAPSHOT: clear workspace, then copy live batch+program *)
  FOR vUi := 1 TO MAX_UNITS DO
    ioWkSchedule[vUi].StageCount := 0;
    ioWkBatch[vUi]    := gBatch[vUi];
    ioWkProgram[vUi]  := TreatmentPrograms[vUi];
  END_FOR;
  FOR vUi := 1 TO MAX_TRANSPORTERS DO
    ioWkTask[vUi].Count := 0;
  END_FOR;
ELSIF iCmd = 2 THEN
  (* RESTORE: workspace batch+program → live (for REJECT rollback) *)
  FOR vUi := 1 TO MAX_UNITS DO
    IF ioWkBatch[vUi].BatchCode > 0 THEN
      gBatch[vUi] := ioWkBatch[vUi];
    END_IF;
    IF ioWkProgram[vUi].ProgramId > 0 THEN
      TreatmentPrograms[vUi] := ioWkProgram[vUi];
    END_IF;
  END_FOR;
ELSIF iCmd = 3 THEN
  ;  (* CLEAR: nothing vNeeded *)

END_IF;

END_FUNCTION

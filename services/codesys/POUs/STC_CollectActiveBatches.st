(* ===========================================================================================
 *  STC_CollectActiveBatches — Filter active/waiting batches
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Returns count of matching batches; fills o_list via VAR_OUTPUT.
 *
 *  Mode:
 *  i_mode = 0 — active (in-production) batches
 *  i_mode = 1 — waiting batches (station 114 lookup)
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_CollectActiveBatches : INT   (* returns count *)


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_mode                    : INT;    (* 0 = all active, 1 = waiting only *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Units               : INT;
    MAX_StationIndex        : INT;
    USED                    : INT;
    TO_NONE                 : INT;
    NOT_PROCESSED           : INT;
    IN_PROCESS              : INT;
END_VAR

VAR_EXTERNAL
  g_batch                   : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_unit                    : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_program                 : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_station_loc             : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
END_VAR

VAR_OUTPUT
  o_list                    : ARRAY[1..MAX_Units] OF INT;  (* unit indices *)
END_VAR

VAR
  ui                        : INT;
  cnt                       : INT;
END_VAR

cnt := 0;
FOR ui := 1 TO MAX_Units DO
  o_list[ui] := 0;
END_FOR;

IF i_mode = 1 THEN
  (* ── Waiting batch: direct lookup at station 114 ── *)
  ui := g_station_loc[114].UnitId;
  IF ui >= 1 AND ui <= MAX_Units THEN
    IF g_unit[ui].Status = USED
       AND g_unit[ui].Target = TO_NONE
       AND g_batch[ui].State = NOT_PROCESSED
       AND g_batch[ui].ProgId = g_program[ui].ProgramId
       AND g_program[ui].ProgramId > 0 THEN
      cnt := 1;
      o_list[1] := ui;
    END_IF;
  END_IF;
  STC_CollectActiveBatches := cnt;
  RETURN;
END_IF;

(* ── Mode 0: active batches — loop ── *)
FOR ui := 1 TO MAX_Units DO
  IF g_unit[ui].Status = USED
     AND g_unit[ui].Target = TO_NONE
     AND g_batch[ui].ProgId = g_program[ui].ProgramId
     AND g_program[ui].ProgramId > 0 THEN

    IF g_batch[ui].State = IN_PROCESS
       AND g_batch[ui].CurStage >= 0
       AND g_batch[ui].CurStage <= 99 THEN
      cnt := cnt + 1;
      o_list[cnt] := ui;
    END_IF;
  END_IF;
END_FOR;

STC_CollectActiveBatches := cnt;

END_FUNCTION

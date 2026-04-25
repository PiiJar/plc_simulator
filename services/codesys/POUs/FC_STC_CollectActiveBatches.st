(* ===========================================================================================
 *  FC_STC_CollectActiveBatches — Filter active/waiting batches
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Returns count of matching batches; fills oList via VAR_OUTPUT.
 *
 *  Mode:
 *  iMode = 0 — active (in-production) batches
 *  iMode = 1 — waiting batches (station 114 lookup)
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_CollectActiveBatches : INT   (* returns count *)


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iMode                    : INT;    (* 0 = all active, 1 = waiting only *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_UNITS               : INT;
    MAX_STATION_INDEX        : INT;
    USED                    : INT;
    TO_NONE                 : INT;
    NOT_PROCESSED           : INT;
    IN_PROCESS              : INT;
END_VAR

VAR_EXTERNAL
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_station_occupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
END_VAR

VAR_OUTPUT
  oList                    : ARRAY[1..MAX_UNITS] OF INT;  (* unit indices *)
END_VAR

VAR
  vUi                        : INT;
  vCnt                       : INT;
END_VAR

vCnt := 0;
FOR vUi := 1 TO MAX_UNITS DO
  oList[vUi] := 0;
END_FOR;

IF iMode = 1 THEN
  (* ── Waiting batch: direct lookup at station 114 ── *)
  vUi := g_station_occupancy[114].UnitId;
  IF vUi >= 1 AND vUi <= MAX_UNITS THEN
    IF g_unit[vUi].Status = USED
       AND g_unit[vUi].Target = TO_NONE
       AND g_batch[vUi].State = NOT_PROCESSED
       AND g_batch[vUi].ProgId = TreatmentPrograms[vUi].ProgramId
       AND TreatmentPrograms[vUi].ProgramId > 0 THEN
      vCnt := 1;
      oList[1] := vUi;
    END_IF;
  END_IF;
  FC_STC_CollectActiveBatches := vCnt;
  RETURN;
END_IF;

(* ── Mode 0: active batches — loop ── *)
FOR vUi := 1 TO MAX_UNITS DO
  IF g_unit[vUi].Status = USED
     AND g_unit[vUi].Target = TO_NONE
     AND g_batch[vUi].ProgId = TreatmentPrograms[vUi].ProgramId
     AND TreatmentPrograms[vUi].ProgramId > 0 THEN

    IF g_batch[vUi].State = IN_PROCESS
       AND g_batch[vUi].CurStage >= 0
       AND g_batch[vUi].CurStage <= 99 THEN
      vCnt := vCnt + 1;
      oList[vCnt] := vUi;
    END_IF;
  END_IF;
END_FOR;

FC_STC_CollectActiveBatches := vCnt;

END_FUNCTION

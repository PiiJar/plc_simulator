(* ===========================================================================================
 *  STC_FC_CollectActiveBatches — Filter active/waiting batches
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


FUNCTION STC_FC_CollectActiveBatches : INT   (* returns count *)


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
  Batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  Unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  StationOccupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
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
  vUi := StationOccupancy[114].UnitId;
  IF vUi >= 1 AND vUi <= MAX_UNITS THEN
    IF Unit[vUi].Status = USED
       AND Unit[vUi].Target = TO_NONE
       AND Batch[vUi].State = NOT_PROCESSED
       AND Batch[vUi].ProgId = TreatmentPrograms[vUi].ProgramId
       AND TreatmentPrograms[vUi].ProgramId > 0 THEN
      vCnt := 1;
      oList[1] := vUi;
    END_IF;
  END_IF;
  STC_FC_CollectActiveBatches := vCnt;
  RETURN;
END_IF;

(* ── Mode 0: active batches — loop ── *)
FOR vUi := 1 TO MAX_UNITS DO
  IF Unit[vUi].Status = USED
     AND Unit[vUi].Target = TO_NONE
     AND Batch[vUi].ProgId = TreatmentPrograms[vUi].ProgramId
     AND TreatmentPrograms[vUi].ProgramId > 0 THEN

    IF Batch[vUi].State = IN_PROCESS
       AND Batch[vUi].CurStage >= 0
       AND Batch[vUi].CurStage <= 99 THEN
      vCnt := vCnt + 1;
      oList[vCnt] := vUi;
    END_IF;
  END_IF;
END_FOR;

STC_FC_CollectActiveBatches := vCnt;

END_FUNCTION

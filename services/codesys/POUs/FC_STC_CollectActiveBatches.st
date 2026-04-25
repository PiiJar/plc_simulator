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
  iMode : INT;    (* 0 = all active, 1 = waiting only *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_UNITS         : INT;
    MAX_STATION_INDEX : INT;
    USED              : INT;
    TO_NONE           : INT;
    NOT_PROCESSED     : INT;
    IN_PROCESS        : INT;
END_VAR

VAR_EXTERNAL
  gBatch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  gUnit             : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  TreatmentPrograms : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gStationOccupancy : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
END_VAR

VAR_OUTPUT
  oList : ARRAY[1..MAX_UNITS] OF INT;  (* unit indices *)
END_VAR

VAR
  vUi  : INT;
  vCnt : INT;
END_VAR

vCnt := 0;
FOR vUi := 1 TO MAX_UNITS DO
  oList[vUi] := 0;
END_FOR;

IF iMode = 1 THEN
  (* ── Waiting batch: direct lookup at station 114 ── *)
  vUi := gStationOccupancy[114].UnitId;
  IF vUi >= 1 AND vUi <= MAX_UNITS THEN
    IF gUnit[vUi].Status = USED
       AND gUnit[vUi].Target = TO_NONE
       AND gBatch[vUi].State = NOT_PROCESSED
       AND gBatch[vUi].ProgId = TreatmentPrograms[vUi].ProgramId
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
  IF gUnit[vUi].Status = USED
     AND gUnit[vUi].Target = TO_NONE
     AND gBatch[vUi].ProgId = TreatmentPrograms[vUi].ProgramId
     AND TreatmentPrograms[vUi].ProgramId > 0 THEN

    IF gBatch[vUi].State = IN_PROCESS
       AND gBatch[vUi].CurStage >= 0
       AND gBatch[vUi].CurStage <= 99 THEN
      vCnt := vCnt + 1;
      oList[vCnt] := vUi;
    END_IF;
  END_IF;
END_FOR;

FC_STC_CollectActiveBatches := vCnt;

END_FUNCTION

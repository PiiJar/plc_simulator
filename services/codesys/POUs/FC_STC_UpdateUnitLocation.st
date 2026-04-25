(* ===========================================================================================
 *  FC_STC_UpdateUnitLocation — Update a unit's vLocation
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Sets gUnit[iUnit].Location to the given new vLocation.
 *  Updates gStationOccupancy[].UnitId + ChangeTime for both old
 *  and new vLocations.
 *
 *  When moving to a station:
 *  - Advances batch CurStage if batch is IN_PROCESS
 *  - Updates batch min/max/cal times from treatment program
 *  - Clears unit target if iNttPrimary = 1
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_UpdateUnitLocation : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iUnit       : INT;   (* unit number to update *)
  iLocation   : INT;   (* new vLocation: <100 = transporter id, >=100 = station number *)
  iNttPrimary : INT;   (* 1 = sink is NTT primary → clear target, 0 = don't clear *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_UNITS             : INT;
    MAX_TRANSPORTERS      : INT;
    MAX_STEPS_PER_PROGRAM : INT;
    MIN_STATION_INDEX     : INT;
    MAX_STATION_INDEX     : INT;
    IN_PROCESS            : INT;
    USED                  : INT;
    TO_NONE               : INT;
END_VAR

VAR_EXTERNAL
  gUnit             : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Stations          : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  gStationOccupancy : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  gBatch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  gTransporter      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  gMove             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  gTimeS            : LINT;
END_VAR

VAR
  vOldLoc : INT;
  vNewStg : INT;
END_VAR

IF (iUnit >= 1) AND (iUnit <= MAX_UNITS) THEN
  vOldLoc := gUnit[iUnit].Location;

  (* --- Clear unit_id from old vLocation (unified: transporter or station) --- *)
  IF (vOldLoc >= 1) AND (vOldLoc <= MAX_STATION_INDEX) THEN
    gStationOccupancy[vOldLoc].UnitId     := 0;
    gStationOccupancy[vOldLoc].ChangeTime := gTimeS;
  END_IF;

  (* --- Update unit vLocation --- *)
  gUnit[iUnit].Location := iLocation;

  (* --- Set unit_id on new vLocation (unified: transporter or station) --- *)
  IF (iLocation >= 1) AND (iLocation <= MAX_STATION_INDEX) THEN
    gStationOccupancy[iLocation].UnitId     := iUnit;
    gStationOccupancy[iLocation].ChangeTime := gTimeS;

    (* Station-specific: batch stage advance only when landing on a station *)
    IF (iLocation >= MIN_STATION_INDEX) THEN

    (* Advance batch stage if unit is USED with an active batch *)
    IF (gUnit[iUnit].Status = USED)  (* USED *)
       AND (gBatch[iUnit].BatchCode <> 0)
       AND (gBatch[iUnit].State = IN_PROCESS)
       AND (gBatch[iUnit].CurStage < MAX_STEPS_PER_PROGRAM) THEN
      gBatch[iUnit].CurStage := gBatch[iUnit].CurStage + 1;

      (* Stamp arrival time on new station — used by CalcSchedule for elapsed calculation *)
      gBatch[iUnit].StartTime := gTimeS;

      (* Update batch treatment times from program for the new stage *)
      IF (TreatmentPrograms[iUnit].ProgramId = gBatch[iUnit].ProgId)
         AND (TreatmentPrograms[iUnit].ProgramId > 0) THEN
        vNewStg := gBatch[iUnit].CurStage;
        IF (vNewStg >= 1) AND (vNewStg <= MAX_STEPS_PER_PROGRAM) THEN
          gBatch[iUnit].MinTime := TreatmentPrograms[iUnit].Steps[vNewStg].MinTime;
          gBatch[iUnit].MaxTime := TreatmentPrograms[iUnit].Steps[vNewStg].MaxTime;
          gBatch[iUnit].CalTime := TreatmentPrograms[iUnit].Steps[vNewStg].CalTime;
        END_IF;
      END_IF;
    END_IF;

    (* NOT_PROCESSED batch on station: clear times so UI shows no progress bar *)
    IF (gBatch[iUnit].BatchCode <> 0)
       AND (gBatch[iUnit].State <> IN_PROCESS) THEN
      gBatch[iUnit].MinTime   := 0;
      gBatch[iUnit].CalTime   := 0;
      gBatch[iUnit].MaxTime   := 32000;  (* ~8.9 h cap, INT max safe *)
      gBatch[iUnit].StartTime := gTimeS;
    END_IF;

    (* Clear unit target ONLY when iNttPrimary = 1 (primary NTT destination).
       All other cases: keep target so NTT retries primary later. *)
    IF gUnit[iUnit].Target <> TO_NONE AND iNttPrimary > 0 THEN
      gUnit[iUnit].Target := TO_NONE;  (* primary reached → clear *)
    END_IF;

    END_IF; (* iLocation >= MIN_STATION_INDEX — station-specific block *)
  END_IF; (* iLocation valid *)
END_IF;

FC_STC_UpdateUnitLocation := TRUE;

END_FUNCTION

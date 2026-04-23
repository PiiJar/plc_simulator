(* ===========================================================================================
 *  STC_FC_UpdateUnitLocation — Update a unit's location
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Sets Unit[iUnit].location to the given new location.
 *  Updates StationOccupancy[].UnitId + ChangeTime for both old
 *  and new locations.
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


FUNCTION STC_FC_UpdateUnitLocation : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iUnit                    : INT;   (* unit number to update *)
  iLocation                : INT;   (* new location: <100 = transporter id, >=100 = station number *)
  iNttPrimary             : INT;   (* 1 = sink is NTT primary → clear target, 0 = don't clear *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_UNITS               : INT;
    MAX_TRANSPORTERS        : INT;
    MAX_STEPS_PER_PROGRAM   : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    IN_PROCESS              : INT;
    USED                    : INT;
    TO_NONE                 : INT;
END_VAR

VAR_EXTERNAL
  Unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  StationOccupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  TimeS                  : LINT;
END_VAR

VAR
  vOldLoc                   : INT;
  vNewStg                   : INT;
END_VAR

IF (iUnit >= 1) AND (iUnit <= MAX_UNITS) THEN
  vOldLoc := Unit[iUnit].location;

  (* --- Clear unit_id from old location (unified: transporter or station) --- *)
  IF (vOldLoc >= 1) AND (vOldLoc <= MAX_STATION_INDEX) THEN
    StationOccupancy[vOldLoc].UnitId     := 0;
    StationOccupancy[vOldLoc].ChangeTime := TimeS;
  END_IF;

  (* --- Update unit location --- *)
  Unit[iUnit].location := iLocation;

  (* --- Set unit_id on new location (unified: transporter or station) --- *)
  IF (iLocation >= 1) AND (iLocation <= MAX_STATION_INDEX) THEN
    StationOccupancy[iLocation].UnitId     := iUnit;
    StationOccupancy[iLocation].ChangeTime := TimeS;

    (* Station-specific: batch stage advance only when landing on a station *)
    IF (iLocation >= MIN_STATION_INDEX) THEN

    (* Advance batch stage if unit is USED with an active batch *)
    IF (Unit[iUnit].Status = USED)  (* USED *)
       AND (Batch[iUnit].BatchCode <> 0)
       AND (Batch[iUnit].State = IN_PROCESS)
       AND (Batch[iUnit].CurStage < MAX_STEPS_PER_PROGRAM) THEN
      Batch[iUnit].CurStage := Batch[iUnit].CurStage + 1;

      (* Stamp arrival time on new station — used by CalcSchedule for elapsed calculation *)
      Batch[iUnit].StartTime := TimeS;

      (* Update batch treatment times from program for the new stage *)
      IF (TreatmentPrograms[iUnit].ProgramId = Batch[iUnit].ProgId)
         AND (TreatmentPrograms[iUnit].ProgramId > 0) THEN
        vNewStg := Batch[iUnit].CurStage;
        IF (vNewStg >= 1) AND (vNewStg <= MAX_STEPS_PER_PROGRAM) THEN
          Batch[iUnit].MinTime := TreatmentPrograms[iUnit].Steps[vNewStg].MinTime;
          Batch[iUnit].MaxTime := TreatmentPrograms[iUnit].Steps[vNewStg].MaxTime;
          Batch[iUnit].CalTime := TreatmentPrograms[iUnit].Steps[vNewStg].CalTime;
        END_IF;
      END_IF;
    END_IF;

    (* NOT_PROCESSED batch on station: clear times so UI shows no progress bar *)
    IF (Batch[iUnit].BatchCode <> 0)
       AND (Batch[iUnit].State <> IN_PROCESS) THEN
      Batch[iUnit].MinTime   := 0;
      Batch[iUnit].CalTime   := 0;
      Batch[iUnit].MaxTime   := 32000;  (* ~8.9 h cap, INT max safe *)
      Batch[iUnit].StartTime := TimeS;
    END_IF;

    (* Clear unit target ONLY when iNttPrimary = 1 (primary NTT destination).
       All other cases: keep target so NTT retries primary later. *)
    IF Unit[iUnit].Target <> TO_NONE AND iNttPrimary > 0 THEN
      Unit[iUnit].Target := TO_NONE;  (* primary reached → clear *)
    END_IF;

    END_IF; (* iLocation >= MIN_STATION_INDEX — station-specific block *)
  END_IF; (* iLocation valid *)
END_IF;

STC_FC_UpdateUnitLocation := TRUE;

END_FUNCTION

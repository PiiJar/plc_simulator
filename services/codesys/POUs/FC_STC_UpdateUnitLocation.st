(* ===========================================================================================
 *  FC_STC_UpdateUnitLocation — Update a unit's vLocation
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Sets g_unit[iUnit].vLocation to the given new vLocation.
 *  Updates g_station_occupancy[].UnitId + ChangeTime for both old
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
  iUnit                    : INT;   (* unit number to update *)
  iLocation                : INT;   (* new vLocation: <100 = transporter id, >=100 = station number *)
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
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  g_station_occupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  g_time_s                  : LINT;
END_VAR

VAR
  vOldLoc                   : INT;
  vNewStg                   : INT;
END_VAR

IF (iUnit >= 1) AND (iUnit <= MAX_UNITS) THEN
  vOldLoc := g_unit[iUnit].vLocation;

  (* --- Clear unit_id from old vLocation (unified: transporter or station) --- *)
  IF (vOldLoc >= 1) AND (vOldLoc <= MAX_STATION_INDEX) THEN
    g_station_occupancy[vOldLoc].UnitId     := 0;
    g_station_occupancy[vOldLoc].ChangeTime := g_time_s;
  END_IF;

  (* --- Update unit vLocation --- *)
  g_unit[iUnit].vLocation := iLocation;

  (* --- Set unit_id on new vLocation (unified: transporter or station) --- *)
  IF (iLocation >= 1) AND (iLocation <= MAX_STATION_INDEX) THEN
    g_station_occupancy[iLocation].UnitId     := iUnit;
    g_station_occupancy[iLocation].ChangeTime := g_time_s;

    (* Station-specific: batch stage advance only when landing on a station *)
    IF (iLocation >= MIN_STATION_INDEX) THEN

    (* Advance batch stage if unit is USED with an active batch *)
    IF (g_unit[iUnit].Status = USED)  (* USED *)
       AND (g_batch[iUnit].BatchCode <> 0)
       AND (g_batch[iUnit].State = IN_PROCESS)
       AND (g_batch[iUnit].CurStage < MAX_STEPS_PER_PROGRAM) THEN
      g_batch[iUnit].CurStage := g_batch[iUnit].CurStage + 1;

      (* Stamp arrival time on new station — used by CalcSchedule for elapsed calculation *)
      g_batch[iUnit].StartTime := g_time_s;

      (* Update batch treatment times from program for the new stage *)
      IF (TreatmentPrograms[iUnit].ProgramId = g_batch[iUnit].ProgId)
         AND (TreatmentPrograms[iUnit].ProgramId > 0) THEN
        vNewStg := g_batch[iUnit].CurStage;
        IF (vNewStg >= 1) AND (vNewStg <= MAX_STEPS_PER_PROGRAM) THEN
          g_batch[iUnit].MinTime := TreatmentPrograms[iUnit].Steps[vNewStg].MinTime;
          g_batch[iUnit].MaxTime := TreatmentPrograms[iUnit].Steps[vNewStg].MaxTime;
          g_batch[iUnit].CalTime := TreatmentPrograms[iUnit].Steps[vNewStg].CalTime;
        END_IF;
      END_IF;
    END_IF;

    (* NOT_PROCESSED batch on station: clear times so UI shows no progress bar *)
    IF (g_batch[iUnit].BatchCode <> 0)
       AND (g_batch[iUnit].State <> IN_PROCESS) THEN
      g_batch[iUnit].MinTime   := 0;
      g_batch[iUnit].CalTime   := 0;
      g_batch[iUnit].MaxTime   := 32000;  (* ~8.9 h cap, INT max safe *)
      g_batch[iUnit].StartTime := g_time_s;
    END_IF;

    (* Clear unit target ONLY when iNttPrimary = 1 (primary NTT destination).
       All other cases: keep target so NTT retries primary later. *)
    IF g_unit[iUnit].Target <> TO_NONE AND iNttPrimary > 0 THEN
      g_unit[iUnit].Target := TO_NONE;  (* primary reached → clear *)
    END_IF;

    END_IF; (* iLocation >= MIN_STATION_INDEX — station-specific block *)
  END_IF; (* iLocation valid *)
END_IF;

FC_STC_UpdateUnitLocation := TRUE;

END_FUNCTION

(* ===========================================================================================
 *  STC_UpdateUnitLocation — Update a unit's location
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Sets g_unit[i_unit].location to the given new location.
 *  Updates g_station_occupancy[].UnitId + ChangeTime for both old
 *  and new locations.
 *
 *  When moving to a station:
 *  - Advances batch CurStage if batch is IN_PROCESS
 *  - Updates batch min/max/cal times from treatment program
 *  - Clears unit target if i_ntt_primary = 1
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_UpdateUnitLocation : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_unit                    : INT;   (* unit number to update *)
  i_location                : INT;   (* new location: <100 = transporter id, >=100 = station number *)
  i_ntt_primary             : INT;   (* 1 = sink is NTT primary → clear target, 0 = don't clear *)
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
  old_loc                   : INT;
  new_stg                   : INT;
END_VAR

IF (i_unit >= 1) AND (i_unit <= MAX_UNITS) THEN
  old_loc := g_unit[i_unit].location;

  (* --- Clear unit_id from old location (unified: transporter or station) --- *)
  IF (old_loc >= 1) AND (old_loc <= MAX_STATION_INDEX) THEN
    g_station_occupancy[old_loc].UnitId     := 0;
    g_station_occupancy[old_loc].ChangeTime := g_time_s;
  END_IF;

  (* --- Update unit location --- *)
  g_unit[i_unit].location := i_location;

  (* --- Set unit_id on new location (unified: transporter or station) --- *)
  IF (i_location >= 1) AND (i_location <= MAX_STATION_INDEX) THEN
    g_station_occupancy[i_location].UnitId     := i_unit;
    g_station_occupancy[i_location].ChangeTime := g_time_s;

    (* Station-specific: batch stage advance only when landing on a station *)
    IF (i_location >= MIN_STATION_INDEX) THEN

    (* Advance batch stage if unit is USED with an active batch *)
    IF (g_unit[i_unit].Status = USED)  (* USED *)
       AND (g_batch[i_unit].BatchCode <> 0)
       AND (g_batch[i_unit].State = IN_PROCESS)
       AND (g_batch[i_unit].CurStage < MAX_STEPS_PER_PROGRAM) THEN
      g_batch[i_unit].CurStage := g_batch[i_unit].CurStage + 1;

      (* Stamp arrival time on new station — used by CalcSchedule for elapsed calculation *)
      g_batch[i_unit].StartTime := g_time_s;

      (* Update batch treatment times from program for the new stage *)
      IF (TreatmentPrograms[i_unit].ProgramId = g_batch[i_unit].ProgId)
         AND (TreatmentPrograms[i_unit].ProgramId > 0) THEN
        new_stg := g_batch[i_unit].CurStage;
        IF (new_stg >= 1) AND (new_stg <= MAX_STEPS_PER_PROGRAM) THEN
          g_batch[i_unit].MinTime := TreatmentPrograms[i_unit].Steps[new_stg].MinTime;
          g_batch[i_unit].MaxTime := TreatmentPrograms[i_unit].Steps[new_stg].MaxTime;
          g_batch[i_unit].CalTime := TreatmentPrograms[i_unit].Steps[new_stg].CalTime;
        END_IF;
      END_IF;
    END_IF;

    (* NOT_PROCESSED batch on station: clear times so UI shows no progress bar *)
    IF (g_batch[i_unit].BatchCode <> 0)
       AND (g_batch[i_unit].State <> IN_PROCESS) THEN
      g_batch[i_unit].MinTime   := 0;
      g_batch[i_unit].CalTime   := 0;
      g_batch[i_unit].MaxTime   := 32000;  (* ~8.9 h cap, INT max safe *)
      g_batch[i_unit].StartTime := g_time_s;
    END_IF;

    (* Clear unit target ONLY when i_ntt_primary = 1 (primary NTT destination).
       All other cases: keep target so NTT retries primary later. *)
    IF g_unit[i_unit].Target <> TO_NONE AND i_ntt_primary > 0 THEN
      g_unit[i_unit].Target := TO_NONE;  (* primary reached → clear *)
    END_IF;

    END_IF; (* i_location >= MIN_STATION_INDEX — station-specific block *)
  END_IF; (* i_location valid *)
END_IF;

STC_UpdateUnitLocation := TRUE;

END_FUNCTION

(* ============================================================
   STC_FB_UpdateUnitLocation — Update a unit's location
   ============================================================
   Sets g_unit[i_unit].location to the given new location.
   Location 1..MAX_Transporters = transporter, MIN_StationIndex..MAX_StationIndex = station.
   Updates g_station_loc[location].UnitId + ChangeTime for both.

   When moving to a station (sink / task completion):
     - Advances batch cur_stage if batch is IN_PROCESS
     - Updates batch min_time/max_time/cal_time from treatment program
     - Clears unit target to TO_NONE if target was set (NTT done)
   ============================================================ *)

FUNCTION_BLOCK STC_FB_UpdateUnitLocation
VAR_INPUT
  i_unit        : INT;   (* unit number to update *)
  i_location    : INT;   (* new location: <100 = transporter id, >=100 = station number *)
  i_ntt_primary : INT;   (* 1 = sink is NTT primary → clear target, 0 = don't clear *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Units           : INT;
    MAX_Transporters    : INT;
    MAX_STEPS_PER_PROGRAM          : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
    IN_PROCESS          : INT;
END_VAR
VAR_EXTERNAL
  g_unit        : ARRAY[1..MAX_Units] OF UDT_UnitType;
  g_station     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_station_loc : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
  g_batch       : ARRAY[1..MAX_Units] OF UDT_BatchType;
  g_program     : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
  g_transporter : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_move        : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_time_s      : LINT;
END_VAR
VAR
  old_loc     : INT;
  new_stg     : INT;
  xfer_total  : REAL;
END_VAR

IF (i_unit >= 1) AND (i_unit <= MAX_Units) THEN
  old_loc := g_unit[i_unit].location;

  (* --- Clear unit_id from old location (unified: transporter or station) --- *)
  IF (old_loc >= 1) AND (old_loc <= MAX_StationIndex) THEN
    g_station_loc[old_loc].UnitId     := 0;
    g_station_loc[old_loc].ChangeTime := g_time_s;
  END_IF;

  (* --- Update unit location --- *)
  g_unit[i_unit].location := i_location;

  (* NOTE: transporter batch times are set directly in SIM_FB_RunTasks
     at LIFT moment, not here — UpdateUnitLocation's transporter block
     was unreliably executing. *)

  (* --- Set unit_id on new location (unified: transporter or station) --- *)
  IF (i_location >= 1) AND (i_location <= MAX_StationIndex) THEN
    g_station_loc[i_location].UnitId     := i_unit;
    g_station_loc[i_location].ChangeTime := g_time_s;

    (* Station-specific: batch stage advance only when landing on a station *)
    IF (i_location >= MIN_StationIndex) THEN

    (* Advance batch stage if unit is USED with an active batch *)
    IF (g_unit[i_unit].Status = 1)  (* USED *)
       AND (g_batch[i_unit].BatchCode <> 0)
       AND (g_batch[i_unit].State = IN_PROCESS)
       AND (g_batch[i_unit].CurStage < MAX_STEPS_PER_PROGRAM) THEN
      g_batch[i_unit].CurStage := g_batch[i_unit].CurStage + 1;

      (* Stamp arrival time on new station — used by CalcSchedule for elapsed calculation *)
      g_batch[i_unit].StartTime := g_time_s;

      (* Update batch treatment times from program for the new stage *)
      IF (g_program[i_unit].ProgramId = g_batch[i_unit].ProgId)
         AND (g_program[i_unit].ProgramId > 0) THEN
        new_stg := g_batch[i_unit].CurStage;
        IF (new_stg >= 1) AND (new_stg <= MAX_STEPS_PER_PROGRAM) THEN
          g_batch[i_unit].MinTime := g_program[i_unit].Steps[new_stg - 1].MinTime;
          g_batch[i_unit].MaxTime := g_program[i_unit].Steps[new_stg - 1].MaxTime;
          g_batch[i_unit].CalTime := g_program[i_unit].Steps[new_stg - 1].CalTime;
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
    IF g_unit[i_unit].Target <> 0 AND i_ntt_primary > 0 THEN
      g_unit[i_unit].Target := 0;  (* primary reached → clear *)
    END_IF;

    END_IF; (* i_location >= MIN_StationIndex — station-specific block *)
  END_IF; (* i_location valid *)
END_IF;

END_FUNCTION_BLOCK

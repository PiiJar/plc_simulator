(* ============================================================
   STC_NoTreatmentStates — Non-treatment target state management

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Manages non-treatment target states for all units.

   Structure:
     Pass 0 — SNAPSHOT: read unit/batch/station state into snap[]
     Section 1 — PROCESSED: mark last-stage units as PROCESSED
     Section 2 — TO_AVOID: clear occupied next-stage stations
     Section 3 — TO_LOADING: route one empty unit to loading
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION STC_NoTreatmentStates : BOOL
  VAR_EXTERNAL CONSTANT
    MAX_Units          : INT;
    MAX_STEPS_PER_PROGRAM         : INT;
    MAX_STATIONS_PER_STEP      : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex  : INT;
    IN_PROCESS         : INT;
    PROCESSED          : INT;
    NOT_USED           : INT;
    TO_NONE            : INT;
    TO_AVOID           : INT;
    TO_LOADING         : INT;
    USED               : INT;
    OP_LOADING           : INT;
    OP_LOADING_UNLOADING : INT;
  END_VAR

  VAR_EXTERNAL
    g_unit             : ARRAY[1..MAX_Units] OF UDT_UnitType;
    g_batch            : ARRAY[1..MAX_Units] OF UDT_BatchType;
    g_program          : ARRAY[1..MAX_Units] OF UDT_TreatmentProgramType;
    g_station          : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
    g_station_loc      : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;
    g_time_s           : LINT;
    g_production_queue : INT;
  END_VAR

  VAR
    (* Snapshot *)
    snap        : ARRAY[1..MAX_Units] OF UDT_JC_UnitSnapType;
    u           : INT;        (* unit loop index *)
    has_loading : BOOL;       (* any unit already has TO_LOADING *)
    (* Section 1+2 *)
    p           : INT;        (* parallel station loop *)
    next_stn    : INT;        (* next stage station *)
    occ_uid     : INT;        (* unit_id at an occupied station *)
    free_found  : BOOL;       (* any next-stage station is free *)
    avoid_uid   : INT;        (* unit to mark TO_AVOID *)
    (* Section 3 *)
    load_free   : BOOL;       (* a loading station is free *)
    load_uid    : INT;        (* best candidate for TO_LOADING *)
    load_in_buf : BOOL;       (* current candidate is in buffer *)
    stk         : INT;        (* station loop *)
    op          : INT;        (* station operation code *)
  END_VAR

  (* ════════════════════════════════════════════════════════════
     Pass 0 — SNAPSHOT: collect per-unit state in one pass
     ════════════════════════════════════════════════════════════ *)
  has_loading := FALSE;

  FOR u := 1 TO MAX_Units DO
    snap[u].IsActive := g_unit[u].Status <> NOT_USED;
    IF NOT snap[u].IsActive THEN
      CONTINUE;
    END_IF;

    snap[u].Location       := g_unit[u].location;
    snap[u].Target       := g_unit[u].Target;
    snap[u].HasBatch := g_batch[u].BatchCode <> 0;
    snap[u].BatchState    := g_batch[u].State;
    snap[u].CurStage := g_batch[u].CurStage;

    snap[u].OnStation := snap[u].Location >= MIN_StationIndex
                          AND snap[u].Location <= MAX_StationIndex;
    IF snap[u].OnStation THEN
      snap[u].LocationOp    := g_station[snap[u].Location].StationType;
      snap[u].InBuffer := snap[u].LocationOp >= 44 AND snap[u].LocationOp <= 47;
      IF g_station_loc[snap[u].Location].ChangeTime > 0 THEN
        snap[u].Elapsed := g_time_s - g_station_loc[snap[u].Location].ChangeTime;
      ELSE
        snap[u].Elapsed := 0;
      END_IF;
      IF snap[u].CurStage >= 1 THEN
        snap[u].CalTime := g_program[u].Steps[snap[u].CurStage].CalTime;
      ELSE
        snap[u].CalTime := 0;
      END_IF;
    ELSE
      snap[u].LocationOp    := 0;
      snap[u].InBuffer := FALSE;
      snap[u].Elapsed   := 0;
      snap[u].CalTime       := 0;
    END_IF;

    IF snap[u].Target = TO_LOADING THEN
      has_loading := TRUE;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 1 — PROCESSED: mark batch done at last treatment stage
     ════════════════════════════════════════════════════════════ *)
  FOR u := 1 TO MAX_Units DO
    IF NOT snap[u].IsActive OR NOT snap[u].HasBatch THEN
      CONTINUE;
    END_IF;
    IF snap[u].BatchState <> IN_PROCESS OR NOT snap[u].OnStation THEN
      CONTINUE;
    END_IF;
    IF snap[u].CurStage >= 1 AND snap[u].CurStage < MAX_STEPS_PER_PROGRAM THEN
      IF snap[u].CurStage >= g_program[u].StepCount THEN
        IF snap[u].Elapsed > 0 AND snap[u].Elapsed >= DINT_TO_LINT(snap[u].CalTime) THEN
          g_batch[u].State := PROCESSED;
          snap[u].BatchState   := PROCESSED;  (* update snapshot *)
        END_IF;
      END_IF;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 2 — TO_AVOID: clear the way to next treatment station
     ════════════════════════════════════════════════════════════ *)
  FOR u := 1 TO MAX_Units DO
    IF NOT snap[u].IsActive OR NOT snap[u].HasBatch THEN
      CONTINUE;
    END_IF;
    IF snap[u].BatchState <> IN_PROCESS THEN
      CONTINUE;
    END_IF;
    IF snap[u].CurStage < 1 OR snap[u].CurStage >= MAX_STEPS_PER_PROGRAM THEN
      CONTINUE;
    END_IF;
    IF snap[u].CurStage >= g_program[u].StepCount THEN
      CONTINUE;  (* no next stage *)
    END_IF;

    (* — Pass 1: any next-stage station free or being cleared? — *)
    free_found := FALSE;
    avoid_uid  := 0;
    FOR p := 0 TO MAX_STATIONS_PER_STEP - 1 DO
      next_stn := g_program[u].Steps[snap[u].CurStage + 1].Stations[p];
      IF next_stn = 0 THEN
        EXIT;
      END_IF;
      IF next_stn >= MIN_StationIndex AND next_stn <= MAX_StationIndex THEN
        IF g_station_loc[next_stn].UnitId = 0 THEN
          free_found := TRUE;
          EXIT;
        END_IF;
        occ_uid := g_station_loc[next_stn].UnitId;
        IF occ_uid >= 1 AND occ_uid <= MAX_Units THEN
          IF snap[occ_uid].Target = TO_AVOID THEN
            free_found := TRUE;
            EXIT;
          END_IF;
        END_IF;
      END_IF;
    END_FOR;

    (* — Pass 2: all occupied → mark ONE movable unit TO_AVOID — *)
    IF NOT free_found THEN
      FOR p := 0 TO MAX_STATIONS_PER_STEP - 1 DO
        next_stn := g_program[u].Steps[snap[u].CurStage + 1].Stations[p];
        IF next_stn = 0 THEN
          EXIT;
        END_IF;
        IF next_stn >= MIN_StationIndex AND next_stn <= MAX_StationIndex THEN
          occ_uid := g_station_loc[next_stn].UnitId;
          IF occ_uid >= 1 AND occ_uid <= MAX_Units THEN
            IF NOT snap[occ_uid].HasBatch AND snap[occ_uid].Target = TO_NONE THEN
              avoid_uid := occ_uid;
              EXIT;
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      IF avoid_uid >= 1 THEN
        g_unit[avoid_uid].Target := TO_AVOID;
        snap[avoid_uid].Target     := TO_AVOID;  (* update snapshot *)
      END_IF;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 3 — TO_LOADING: route one empty unit to loading station
     ════════════════════════════════════════════════════════════ *)
  IF g_production_queue = 1 AND NOT has_loading THEN

    (* Check if any loading station is free *)
    load_free := FALSE;
    FOR stk := MIN_StationIndex TO MAX_StationIndex DO
      op := g_station[stk].StationType;
      IF (op = OP_LOADING OR op = OP_LOADING_UNLOADING)
         AND g_station_loc[stk].UnitId = 0 THEN
        load_free := TRUE;
        EXIT;
      END_IF;
    END_FOR;

    IF load_free THEN
      load_uid    := 0;
      load_in_buf := FALSE;
      FOR u := 1 TO MAX_Units DO
        IF snap[u].IsActive AND NOT snap[u].HasBatch
           AND snap[u].Target = TO_NONE AND snap[u].OnStation THEN
          IF snap[u].InBuffer THEN
            IF load_uid = 0 THEN
              load_uid    := u;
              load_in_buf := TRUE;
            END_IF;
          ELSE
            IF load_uid = 0 OR load_in_buf THEN
              load_uid    := u;
              load_in_buf := FALSE;
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      IF load_uid >= 1 THEN
        g_unit[load_uid].Target := TO_LOADING;
      END_IF;
    END_IF; (* load_free *)

  END_IF; (* production_queue AND NOT has_loading *)

  STC_NoTreatmentStates := TRUE;

END_FUNCTION

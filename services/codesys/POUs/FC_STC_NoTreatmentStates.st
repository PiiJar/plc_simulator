(* ===========================================================================================
 *  FC_STC_NoTreatmentStates — Non-treatment target state management
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Manages non-treatment target states for all units.
 *
 *  Structure:
 *  Pass 0 — SNAPSHOT: read unit/batch/station state into vSnap[]
 *  Section 1 — PROCESSED: mark last-stage units as PROCESSED
 *  Section 2 — TO_AVOID: clear occupied next-stage stations
 *  Section 3 — TO_LOADING: route one empty unit to loading
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_NoTreatmentStates : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_EXTERNAL CONSTANT
    MAX_UNITS               : INT;
    MAX_STEPS_PER_PROGRAM   : INT;
    MAX_STATIONS_PER_STEP   : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    IN_PROCESS              : INT;
    PROCESSED               : INT;
    NOT_USED                : INT;
    TO_NONE                 : INT;
    TO_UNLOAD               : INT;
    TO_AVOID                : INT;
    TO_LOADING              : INT;
    USED                    : INT;
    OP_BUFFER               : INT;
    OP_BUFFER_PROCESSED     : INT;
    OP_LOADING              : INT;
    OP_LOADING_UNLOADING    : INT;
END_VAR

VAR_EXTERNAL
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  TreatmentPrograms                 : ARRAY[1..MAX_UNITS] OF UDT_TreatmentProgramType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  g_station_occupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  g_time_s                  : LINT;
  g_production_queue        : INT;
  g_event_pending           : UDT_JC_EventMsgType;
  g_event_pending_valid     : BOOL;
END_VAR

VAR
  (* Snapshot *)
  vSnap                      : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitSnapType;
  u                         : INT;        (* unit loop index *)
  vHasLoading               : BOOL;       (* any unit vAlready has TO_LOADING *)
  (* Section 1+2 *)
  p                         : INT;        (* parallel station loop *)
  vNextStn                  : INT;        (* next stage station *)
  vOccUid                   : INT;        (* unit_id at an occupied station *)
  vFreeFound                : BOOL;       (* any next-stage station is free *)
  vAvoidUid                 : INT;        (* unit to mark TO_AVOID *)
  (* Section 3 *)
  vLoadFree                 : BOOL;       (* a loading station is free *)
  vLoadUid                  : INT;        (* best candidate for TO_LOADING *)
  vLoadInBuf               : BOOL;       (* current candidate is in buffer *)
  vStk                       : INT;        (* station loop *)
  op                        : INT;        (* station operation code *)
END_VAR

  (* ════════════════════════════════════════════════════════════
     Pass 0 — SNAPSHOT: collect per-unit state in one pass
     ════════════════════════════════════════════════════════════ *)
  vHasLoading := FALSE;

  FOR u := 1 TO MAX_UNITS DO
    vSnap[u].IsActive := g_unit[u].Status <> NOT_USED;
    IF NOT vSnap[u].IsActive THEN
      CONTINUE;
    END_IF;

    vSnap[u].Location       := g_unit[u].Location;
    vSnap[u].Target       := g_unit[u].Target;
    vSnap[u].HasBatch := g_batch[u].BatchCode <> 0;
    vSnap[u].BatchState    := g_batch[u].State;
    vSnap[u].CurStage := g_batch[u].CurStage;

    vSnap[u].OnStation := vSnap[u].Location >= MIN_STATION_INDEX
                          AND vSnap[u].Location <= MAX_STATION_INDEX;
    IF vSnap[u].OnStation THEN
      vSnap[u].LocationOp    := Stations[vSnap[u].Location].StationType;
      vSnap[u].InBuffer := vSnap[u].LocationOp >= OP_BUFFER AND vSnap[u].LocationOp <= OP_BUFFER_PROCESSED;
      IF g_station_occupancy[vSnap[u].Location].ChangeTime > 0 THEN
        vSnap[u].Elapsed := g_time_s - g_station_occupancy[vSnap[u].Location].ChangeTime;
      ELSE
        vSnap[u].Elapsed := 0;
      END_IF;
      IF vSnap[u].CurStage >= 1 THEN
        vSnap[u].CalTime := TreatmentPrograms[u].Steps[vSnap[u].CurStage].CalTime;
      ELSE
        vSnap[u].CalTime := 0;
      END_IF;
    ELSE
      vSnap[u].LocationOp    := 0;
      vSnap[u].InBuffer := FALSE;
      vSnap[u].Elapsed   := 0;
      vSnap[u].CalTime       := 0;
    END_IF;

    IF vSnap[u].Target = TO_LOADING THEN
      vHasLoading := TRUE;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 1 — PROCESSED: mark batch oDone at last treatment stage
     ════════════════════════════════════════════════════════════ *)
  FOR u := 1 TO MAX_UNITS DO
    IF NOT vSnap[u].IsActive OR NOT vSnap[u].HasBatch THEN
      CONTINUE;
    END_IF;
    IF vSnap[u].BatchState <> IN_PROCESS OR NOT vSnap[u].OnStation THEN
      CONTINUE;
    END_IF;
    IF vSnap[u].CurStage >= 1 AND vSnap[u].CurStage < MAX_STEPS_PER_PROGRAM THEN
      IF vSnap[u].CurStage >= TreatmentPrograms[u].StepCount THEN
        IF vSnap[u].Elapsed > 0 AND vSnap[u].Elapsed >= DINT_TO_LINT(vSnap[u].CalTime) THEN
          g_batch[u].State := PROCESSED;
          vSnap[u].BatchState   := PROCESSED;  (* update snapshot *)

          (* ── Emit BATCH_COMPLETED event (msg_type=5) ── *)
          IF NOT g_event_pending_valid THEN
            g_event_pending.MsgType := 5;
            g_event_pending.TsHi := LINT_TO_UINT(g_time_s / LINT#65536);
            g_event_pending.TsLo := LINT_TO_UINT(g_time_s MOD LINT#65536);
            g_event_pending.Payload[1]  := u;                                  (* unit_id *)
            g_event_pending.Payload[2]  := g_batch[u].BatchCode;               (* batch_code *)
            g_event_pending.Payload[3]  := TreatmentPrograms[u].StepCount;             (* stage_count *)
            g_event_pending.Payload[4]  := vSnap[u].Location;                   (* final_station *)
            g_event_pending.Payload[5]  := 0;
            g_event_pending.Payload[6]  := 0;
            g_event_pending.Payload[7]  := 0;
            g_event_pending.Payload[8]  := 0;
            g_event_pending.Payload[9]  := 0;
            g_event_pending.Payload[10] := 0;
            g_event_pending.Payload[11] := 0;
            g_event_pending.Payload[12] := 0;
            g_event_pending_valid := TRUE;
          END_IF;

          (* Route to unloading station *)
          IF vSnap[u].Target = TO_NONE THEN
            g_unit[u].Target := TO_UNLOAD;
            vSnap[u].Target   := TO_UNLOAD;
          END_IF;
        END_IF;
      END_IF;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 2 — TO_AVOID: clear the way to next treatment station
     ════════════════════════════════════════════════════════════ *)
  FOR u := 1 TO MAX_UNITS DO
    IF NOT vSnap[u].IsActive OR NOT vSnap[u].HasBatch THEN
      CONTINUE;
    END_IF;
    IF vSnap[u].BatchState <> IN_PROCESS THEN
      CONTINUE;
    END_IF;
    IF vSnap[u].CurStage < 1 OR vSnap[u].CurStage >= MAX_STEPS_PER_PROGRAM THEN
      CONTINUE;
    END_IF;
    IF vSnap[u].CurStage >= TreatmentPrograms[u].StepCount THEN
      CONTINUE;  (* no next stage *)
    END_IF;

    (* — Pass 1: any next-stage station free or being cleared? — *)
    vFreeFound := FALSE;
    vAvoidUid  := 0;
    FOR p := 0 TO MAX_STATIONS_PER_STEP - 1 DO
      vNextStn := TreatmentPrograms[u].Steps[vSnap[u].CurStage + 1].Stations[p];
      IF vNextStn = 0 THEN
        EXIT;
      END_IF;
      IF vNextStn >= MIN_STATION_INDEX AND vNextStn <= MAX_STATION_INDEX THEN
        IF g_station_occupancy[vNextStn].UnitId = 0 THEN
          vFreeFound := TRUE;
          EXIT;
        END_IF;
        vOccUid := g_station_occupancy[vNextStn].UnitId;
        IF vOccUid >= 1 AND vOccUid <= MAX_UNITS THEN
          IF vSnap[vOccUid].Target = TO_AVOID THEN
            vFreeFound := TRUE;
            EXIT;
          END_IF;
        END_IF;
      END_IF;
    END_FOR;

    (* — Pass 2: all occupied → mark ONE movable unit TO_AVOID — *)
    IF NOT vFreeFound THEN
      FOR p := 0 TO MAX_STATIONS_PER_STEP - 1 DO
        vNextStn := TreatmentPrograms[u].Steps[vSnap[u].CurStage + 1].Stations[p];
        IF vNextStn = 0 THEN
          EXIT;
        END_IF;
        IF vNextStn >= MIN_STATION_INDEX AND vNextStn <= MAX_STATION_INDEX THEN
          vOccUid := g_station_occupancy[vNextStn].UnitId;
          IF vOccUid >= 1 AND vOccUid <= MAX_UNITS THEN
            IF NOT vSnap[vOccUid].HasBatch AND vSnap[vOccUid].Target = TO_NONE THEN
              vAvoidUid := vOccUid;
              EXIT;
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      IF vAvoidUid >= 1 THEN
        g_unit[vAvoidUid].Target := TO_AVOID;
        vSnap[vAvoidUid].Target     := TO_AVOID;  (* update snapshot *)
      END_IF;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 3 — TO_LOADING: route one empty unit to loading station
     ════════════════════════════════════════════════════════════ *)
  IF g_production_queue = 1 AND NOT vHasLoading THEN

    (* Check if any loading station is free *)
    vLoadFree := FALSE;
    FOR vStk := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
      op := Stations[vStk].StationType;
      IF (op = OP_LOADING OR op = OP_LOADING_UNLOADING)
         AND g_station_occupancy[vStk].UnitId = 0 THEN
        vLoadFree := TRUE;
        EXIT;
      END_IF;
    END_FOR;

    IF vLoadFree THEN
      vLoadUid    := 0;
      vLoadInBuf := FALSE;
      FOR u := 1 TO MAX_UNITS DO
        IF vSnap[u].IsActive AND NOT vSnap[u].HasBatch
           AND vSnap[u].Target = TO_NONE AND vSnap[u].OnStation THEN
          IF vSnap[u].InBuffer THEN
            IF vLoadUid = 0 THEN
              vLoadUid    := u;
              vLoadInBuf := TRUE;
            END_IF;
          ELSE
            IF vLoadUid = 0 OR vLoadInBuf THEN
              vLoadUid    := u;
              vLoadInBuf := FALSE;
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      IF vLoadUid >= 1 THEN
        g_unit[vLoadUid].Target := TO_LOADING;
      END_IF;
    END_IF; (* vLoadFree *)

  END_IF; (* production_queue AND NOT vHasLoading *)

  FC_STC_NoTreatmentStates := TRUE;

END_FUNCTION

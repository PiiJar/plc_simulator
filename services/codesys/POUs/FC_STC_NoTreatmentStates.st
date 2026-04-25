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
  vU                         : INT;        (* unit loop index *)
  vHasLoading               : BOOL;       (* any unit vAlready has TO_LOADING *)
  (* Section 1+2 *)
  vP                         : INT;        (* parallel station loop *)
  vNextStn                  : INT;        (* next stage station *)
  vOccUid                   : INT;        (* unit_id at an occupied station *)
  vFreeFound                : BOOL;       (* any next-stage station is free *)
  vAvoidUid                 : INT;        (* unit to mark TO_AVOID *)
  (* Section 3 *)
  vLoadFree                 : BOOL;       (* a loading station is free *)
  vLoadUid                  : INT;        (* best candidate for TO_LOADING *)
  vLoadInBuf               : BOOL;       (* current candidate is in buffer *)
  vStk                       : INT;        (* station loop *)
  vOp                        : INT;        (* station operation code *)
END_VAR

  (* ════════════════════════════════════════════════════════════
     Pass 0 — SNAPSHOT: collect per-unit state in one pass
     ════════════════════════════════════════════════════════════ *)
  vHasLoading := FALSE;

  FOR vU := 1 TO MAX_UNITS DO
    vSnap[vU].IsActive := g_unit[vU].Status <> NOT_USED;
    IF NOT vSnap[vU].IsActive THEN
      CONTINUE;
    END_IF;

    vSnap[vU].Location       := g_unit[vU].Location;
    vSnap[vU].Target       := g_unit[vU].Target;
    vSnap[vU].HasBatch := g_batch[vU].BatchCode <> 0;
    vSnap[vU].BatchState    := g_batch[vU].State;
    vSnap[vU].CurStage := g_batch[vU].CurStage;

    vSnap[vU].OnStation := vSnap[vU].Location >= MIN_STATION_INDEX
                          AND vSnap[vU].Location <= MAX_STATION_INDEX;
    IF vSnap[vU].OnStation THEN
      vSnap[vU].LocationOp    := Stations[vSnap[vU].Location].StationType;
      vSnap[vU].InBuffer := vSnap[vU].LocationOp >= OP_BUFFER AND vSnap[vU].LocationOp <= OP_BUFFER_PROCESSED;
      IF g_station_occupancy[vSnap[vU].Location].ChangeTime > 0 THEN
        vSnap[vU].Elapsed := g_time_s - g_station_occupancy[vSnap[vU].Location].ChangeTime;
      ELSE
        vSnap[vU].Elapsed := 0;
      END_IF;
      IF vSnap[vU].CurStage >= 1 THEN
        vSnap[vU].CalTime := TreatmentPrograms[vU].Steps[vSnap[vU].CurStage].CalTime;
      ELSE
        vSnap[vU].CalTime := 0;
      END_IF;
    ELSE
      vSnap[vU].LocationOp    := 0;
      vSnap[vU].InBuffer := FALSE;
      vSnap[vU].Elapsed   := 0;
      vSnap[vU].CalTime       := 0;
    END_IF;

    IF vSnap[vU].Target = TO_LOADING THEN
      vHasLoading := TRUE;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 1 — PROCESSED: mark batch oDone at last treatment stage
     ════════════════════════════════════════════════════════════ *)
  FOR vU := 1 TO MAX_UNITS DO
    IF NOT vSnap[vU].IsActive OR NOT vSnap[vU].HasBatch THEN
      CONTINUE;
    END_IF;
    IF vSnap[vU].BatchState <> IN_PROCESS OR NOT vSnap[vU].OnStation THEN
      CONTINUE;
    END_IF;
    IF vSnap[vU].CurStage >= 1 AND vSnap[vU].CurStage < MAX_STEPS_PER_PROGRAM THEN
      IF vSnap[vU].CurStage >= TreatmentPrograms[vU].StepCount THEN
        IF vSnap[vU].Elapsed > 0 AND vSnap[vU].Elapsed >= DINT_TO_LINT(vSnap[vU].CalTime) THEN
          g_batch[vU].State := PROCESSED;
          vSnap[vU].BatchState   := PROCESSED;  (* update snapshot *)

          (* ── Emit BATCH_COMPLETED event (msg_type=5) ── *)
          IF NOT g_event_pending_valid THEN
            g_event_pending.MsgType := 5;
            g_event_pending.TsHi := LINT_TO_UINT(g_time_s / LINT#65536);
            g_event_pending.TsLo := LINT_TO_UINT(g_time_s MOD LINT#65536);
            g_event_pending.Payload[1]  := vU;                                  (* unit_id *)
            g_event_pending.Payload[2]  := g_batch[vU].BatchCode;               (* batch_code *)
            g_event_pending.Payload[3]  := TreatmentPrograms[vU].StepCount;             (* stage_count *)
            g_event_pending.Payload[4]  := vSnap[vU].Location;                   (* final_station *)
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
          IF vSnap[vU].Target = TO_NONE THEN
            g_unit[vU].Target := TO_UNLOAD;
            vSnap[vU].Target   := TO_UNLOAD;
          END_IF;
        END_IF;
      END_IF;
    END_IF;
  END_FOR;

  (* ════════════════════════════════════════════════════════════
     Section 2 — TO_AVOID: clear the way to next treatment station
     ════════════════════════════════════════════════════════════ *)
  FOR vU := 1 TO MAX_UNITS DO
    IF NOT vSnap[vU].IsActive OR NOT vSnap[vU].HasBatch THEN
      CONTINUE;
    END_IF;
    IF vSnap[vU].BatchState <> IN_PROCESS THEN
      CONTINUE;
    END_IF;
    IF vSnap[vU].CurStage < 1 OR vSnap[vU].CurStage >= MAX_STEPS_PER_PROGRAM THEN
      CONTINUE;
    END_IF;
    IF vSnap[vU].CurStage >= TreatmentPrograms[vU].StepCount THEN
      CONTINUE;  (* no next stage *)
    END_IF;

    (* — Pass 1: any next-stage station free or being cleared? — *)
    vFreeFound := FALSE;
    vAvoidUid  := 0;
    FOR vP := 0 TO MAX_STATIONS_PER_STEP - 1 DO
      vNextStn := TreatmentPrograms[vU].Steps[vSnap[vU].CurStage + 1].Stations[vP];
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
      FOR vP := 0 TO MAX_STATIONS_PER_STEP - 1 DO
        vNextStn := TreatmentPrograms[vU].Steps[vSnap[vU].CurStage + 1].Stations[vP];
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
      vOp := Stations[vStk].StationType;
      IF (vOp = OP_LOADING OR vOp = OP_LOADING_UNLOADING)
         AND g_station_occupancy[vStk].UnitId = 0 THEN
        vLoadFree := TRUE;
        EXIT;
      END_IF;
    END_FOR;

    IF vLoadFree THEN
      vLoadUid    := 0;
      vLoadInBuf := FALSE;
      FOR vU := 1 TO MAX_UNITS DO
        IF vSnap[vU].IsActive AND NOT vSnap[vU].HasBatch
           AND vSnap[vU].Target = TO_NONE AND vSnap[vU].OnStation THEN
          IF vSnap[vU].InBuffer THEN
            IF vLoadUid = 0 THEN
              vLoadUid    := vU;
              vLoadInBuf := TRUE;
            END_IF;
          ELSE
            IF vLoadUid = 0 OR vLoadInBuf THEN
              vLoadUid    := vU;
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

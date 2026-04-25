(* ===========================================================================================
 *  FB_TWA_CalcLimits — Transporter Working Area: X-limit calculation
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Calculates x_min_limit and x_max_limit for all active
 *  transporters. Collision avoidance layers:
 *
 *  Pass 1 (per transporter):
 *  - Station restrictions from g_avoid_status
 *  - Safety vDistance from same-line neighbors
 *  - canEvade, vPriority, x-vRank computation
 *
 *  Pass 2 (pair comparisons):
 *  - Priority-based restrictions (higher → lower)
 *  - Bidirectional safety (same direction chase)
 *
 *  Final: Trap validation
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION_BLOCK FB_TWA_CalcLimits


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    AVOID_PASSABLE          : INT;
    AVOID_BLOCK             : INT;
    MIN_WORKING_AREA         : DINT;
    IN_PROCESS              : INT;
END_VAR

VAR_EXTERNAL
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  CountStations              : INT;
  g_avoid_status            : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  g_station_occupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  g_batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
END_VAR

VAR
  i                         : INT;
  j                         : INT;
  vStnNum                   : INT;
  vStnX                     : DINT;
  vAvoidSt                  : INT;
  vMinX                     : DINT;
  vMaxX                     : DINT;
  vCurrentX                 : DINT;
  vCurrentY                 : DINT;
  vAvoidDist                : DINT;
  vIsTarget                 : BOOL;
  vNewVal                   : DINT;

  (* Station scan: nearest restricting station per side *)
  vNearLeftX               : DINT;
  vNearLeftStn             : INT;
  vNearRightX              : DINT;
  vNearRightStn            : INT;
  vHasLeft                  : BOOL;
  vHasRight                 : BOOL;
  vMidpoint                  : DINT;

  (* Per-transporter computed values *)
  vPriority                  : ARRAY[1..MAX_TRANSPORTERS] OF DINT;
  vCanEvade                 : ARRAY[1..MAX_TRANSPORTERS] OF BOOL;
  vRank                      : ARRAY[1..MAX_TRANSPORTERS] OF INT;

  (* Pair comparison *)
  vOtherX                   : DINT;
  vOtherY                   : DINT;
  vIPhase                   : INT;
  vJPhase                   : INT;
  vDist                      : DINT;
  vWorkArea                 : DINT;
  vAWins                    : BOOL;
  vRestrictX                : DINT;
  vBetween                   : INT;
  vChainOfs                 : DINT;
  vAdjusted                  : DINT;

  (* Bidirectional *)
  vIMovingRight            : BOOL;
  vIMovingLeft             : BOOL;
  vJMovingRight            : BOOL;
  vJMovingLeft             : BOOL;

  (* IN_PROCESS batch vPriority boost *)
  vLiftStn                  : INT;
  vLiftUid                  : INT;
  vBatchBoost               : DINT;

  (* Full task extent for vRestrictX *)
  vLiftX                    : DINT;
  vSinkX                    : DINT;
  vILiftStn                : INT;
  vISinkStn                : INT;
END_VAR

(* ══════════════════════════════════════════════════════════════
   PASS 1: Station restrictions + safety vDistance + properties
   Each transporter computes its OWN limits in one iteration.
   ══════════════════════════════════════════════════════════════ *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  IF NOT g_transporter[i].IsActive THEN
    vPriority[i] := 0;
    vCanEvade[i] := FALSE;
    vRank[i] := 0;
    CONTINUE;
  END_IF;

  vMinX := Transporters[i].DrivePosMin;
  vMaxX := Transporters[i].DrivePosMax;
  vCurrentX := g_transporter[i].XPosition;
  vCurrentY := g_transporter[i].YPosition;
  vAvoidDist := Transporters[i].AvoidanceWidth;

  (* Lock transporters with no drive range configured *)
  IF (vMinX < 1) OR (vMaxX < 1) THEN
    g_transporter[i].XMinDriveLimit := vCurrentX;
    g_transporter[i].XMaxDriveLimit := vCurrentX;
    vPriority[i] := 0;
    vCanEvade[i] := FALSE;
    vRank[i] := 0;
    CONTINUE;
  END_IF;

  (* ── Station scan: find nearest restrict LEFT and RIGHT ──────
     Single pass through all stations. Only Block and
     Passable-target stations cause restrictions. *)
  vHasLeft := FALSE;
  vHasRight := FALSE;
  vNearLeftX := 0;
  vNearLeftStn := 0;
  vNearRightX := 0;
  vNearRightStn := 0;

  FOR vStnNum := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
    IF Stations[vStnNum].TankId = 0 THEN CONTINUE; END_IF;

    vAvoidSt := g_avoid_status[vStnNum];
    IF vAvoidSt = 0 THEN CONTINUE; END_IF;  (* AVOID_NONE *)

    (* Passable: only restricts if this transporter's target *)
    IF vAvoidSt = AVOID_PASSABLE THEN
      vIsTarget := (vStnNum = g_transporter[i].LiftStationTarget)
               OR  (vStnNum = g_transporter[i].SinkStationTarget);
      IF NOT vIsTarget THEN CONTINUE; END_IF;
    END_IF;

    (* Station is Block or Passable+target → track nearest per side *)
    vStnX := Stations[vStnNum].XPosition;

    IF vStnX < vCurrentX THEN
      IF NOT vHasLeft OR vStnX > vNearLeftX THEN
        vNearLeftX := vStnX;
        vNearLeftStn := vStnNum;
        vHasLeft := TRUE;
      END_IF;
    ELSIF vStnX > vCurrentX THEN
      IF NOT vHasRight OR vStnX < vNearRightX THEN
        vNearRightX := vStnX;
        vNearRightStn := vStnNum;
        vHasRight := TRUE;
      END_IF;
    END_IF;
  END_FOR;

  (* Apply station restrictions using station-specific AvoidDistance *)
  IF vHasLeft THEN
    vNewVal := vNearLeftX + Stations[vNearLeftStn].AvoidDistance;
    IF vNewVal > vMinX THEN vMinX := vNewVal; END_IF;
  END_IF;
  IF vHasRight THEN
    vNewVal := vNearRightX - Stations[vNearRightStn].AvoidDistance;
    IF vNewVal < vMaxX THEN vMaxX := vNewVal; END_IF;
  END_IF;

  (* Conflict: trapped vBetween two restricting stations *)
  IF (vMinX >= vMaxX) AND vHasLeft AND vHasRight THEN
    vMidpoint := (vNearLeftX + vNearRightX) / 2;
    vMinX := vMidpoint - 5;
    vMaxX := vMidpoint + 5;
  END_IF;

  (* ── Safety vDistance: each same-line neighbor pushes i away ── *)
  FOR j := 1 TO MAX_TRANSPORTERS DO
    IF j = i THEN CONTINUE; END_IF;
    IF NOT g_transporter[j].IsActive THEN CONTINUE; END_IF;

    vOtherY := g_transporter[j].YPosition;
    IF ABS(vOtherY - vCurrentY) >= 1 THEN CONTINUE; END_IF;

    vOtherX := g_transporter[j].XPosition;

    IF vOtherX < vCurrentX THEN
      (* j is LEFT → j's safety zone pushes i's min up *)
      vNewVal := vOtherX + Transporters[j].AvoidanceWidth;
  IF vNewVal > vMinX THEN vMinX := vNewVal; END_IF;
    ELSIF vOtherX > vCurrentX THEN
      (* j is RIGHT → j's safety zone pushes i's max down *)
      vNewVal := vOtherX - Transporters[j].AvoidanceWidth;
  IF vNewVal < vMaxX THEN vMaxX := vNewVal; END_IF;
    END_IF;
  END_FOR;

  (* ── Write limits ── *)
  g_transporter[i].XMinDriveLimit := vMinX;
  g_transporter[i].XMaxDriveLimit := vMaxX;

  (* ── canEvade (inline) ── *)
  vCanEvade[i] := TRUE;
  IF g_transporter[i].Status < 3 THEN
    vCanEvade[i] := FALSE;
  END_IF;
  IF (g_transporter[i].Status = 4)
     AND ((g_transporter[i].Phase = 2) OR (g_transporter[i].Phase = 4)) THEN
    vCanEvade[i] := FALSE;
  END_IF;
  vWorkArea := vMaxX - vMinX;
  IF vWorkArea < MIN_WORKING_AREA THEN
    vCanEvade[i] := FALSE;
  END_IF;

  (* ── Priority (inline, replaces TWA_CalcPriority call) ──────
     IN_PROCESS batch boost: +100000 if the task serves an
     IN_PROCESS batch. Phases 1-4 all check via LiftStation
     unit lookup (unit stays associated throughout transfer).
     This ensures treatment tasks trump NTT/empty moves. ── *)
  vIPhase := g_transporter[i].Phase;
  vBatchBoost := 0;
  IF vIPhase >= 1 AND vIPhase <= 4 THEN
    vLiftStn := g_transporter[i].LiftStationTarget;
    IF vLiftStn >= 1 AND vLiftStn <= MAX_STATION_INDEX THEN
      vLiftUid := g_station_occupancy[vLiftStn].UnitId;
      IF vLiftUid >= 1 AND vLiftUid <= MAX_UNITS THEN
        IF g_batch[vLiftUid].State = IN_PROCESS THEN
          vBatchBoost := DINT#100000;
        END_IF;
      END_IF;
    END_IF;
  END_IF;

  IF NOT vCanEvade[i] THEN
    vPriority[i] := DINT#100000;
  ELSIF vIPhase = 3 OR vIPhase = 4 THEN
    vDist := ABS(vCurrentX - g_transporter[i].XFinalTarget);
  IF vDist > 99999 THEN vDist := 99999; END_IF;
    vPriority[i] := DINT#200000 + vBatchBoost + (DINT#99999 - vDist);
  ELSIF vIPhase = 1 OR vIPhase = 2 THEN
    (* Move-away (Status=3, Phase=1) gets idle-class vPriority, not active-task vPriority *)
    IF g_transporter[i].Status = 3 THEN
      vPriority[i] := 2;  (* above stationary idle (1), below active tasks (100000+) *)
    ELSE
      vDist := ABS(vCurrentX - g_transporter[i].XFinalTarget);
      IF vDist > 99999 THEN vDist := 99999; END_IF;
      vPriority[i] := DINT#100000 + vBatchBoost + (DINT#99999 - vDist);
    END_IF;
  ELSE
    vPriority[i] := 1;
  END_IF;

  (* ── X-vRank among same-line active transporters ──
     vRank = 1 + count of same-line transporters with smaller x *)
  vRank[i] := 1;
  FOR j := 1 TO MAX_TRANSPORTERS DO
    IF j = i THEN CONTINUE; END_IF;
    IF NOT g_transporter[j].IsActive THEN CONTINUE; END_IF;
    IF ABS(g_transporter[j].YPosition - vCurrentY) >= 1 THEN CONTINUE; END_IF;
    IF g_transporter[j].XPosition < vCurrentX THEN
      vRank[i] := vRank[i] + 1;
    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════
   PASS 2: Priority restrictions + bidirectional safety
   Each pair (i,j): i restricts j if i has higher vPriority.
   ══════════════════════════════════════════════════════════════ *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  IF NOT g_transporter[i].IsActive THEN CONTINUE; END_IF;
  IF vPriority[i] = 0 THEN CONTINUE; END_IF;

  vCurrentX := g_transporter[i].XPosition;
  vCurrentY := g_transporter[i].YPosition;
  vIPhase := g_transporter[i].Phase;

  FOR j := 1 TO MAX_TRANSPORTERS DO
    IF j = i THEN CONTINUE; END_IF;
    IF NOT g_transporter[j].IsActive THEN CONTINUE; END_IF;
    IF vPriority[j] = 0 THEN CONTINUE; END_IF;

    vOtherY := g_transporter[j].YPosition;
    IF ABS(vOtherY - vCurrentY) >= 1 THEN CONTINUE; END_IF;

    vOtherX := g_transporter[j].XPosition;
    vJPhase := g_transporter[j].Phase;

    (* ── Priority restrictions: i restricts j if i wins ── *)
    (* Move-away (Status=3, Phase=1) participates in restrictions
       so it can push stationary idle transporters out of its way *)
    IF (vIPhase <> 0) OR (g_transporter[i].Status = 3 AND vIPhase = 1) THEN
      vAWins := FALSE;
      IF vPriority[i] > vPriority[j] THEN
        vAWins := TRUE;
      ELSIF (vPriority[i] = vPriority[j]) AND (i < j) THEN
        vAWins := TRUE;
      END_IF;

      IF vAWins THEN
        (* Full task extent: use the extreme position
           of both lift and sink stations on the side
           facing j. This prevents j from first driving
           closer and then having to reverse when i
           moves to the other end of its task. *)
        vILiftStn := g_transporter[i].LiftStationTarget;
        vISinkStn := g_transporter[i].SinkStationTarget;
        IF vIPhase >= 1 AND vIPhase <= 4 THEN
          vLiftX := vCurrentX;
          vSinkX := vCurrentX;
          IF vILiftStn >= MIN_STATION_INDEX
             AND vILiftStn <= MAX_STATION_INDEX THEN
            vLiftX := Stations[vILiftStn].XPosition;
          END_IF;
          IF vISinkStn >= MIN_STATION_INDEX
             AND vISinkStn <= MAX_STATION_INDEX THEN
            vSinkX := Stations[vISinkStn].XPosition;
          END_IF;
          IF vCurrentX < vOtherX THEN
            (* i LEFT of j → use rightmost extent *)
            vRestrictX := vLiftX;
            IF vSinkX > vRestrictX THEN
              vRestrictX := vSinkX;
            END_IF;
            IF vCurrentX > vRestrictX THEN
              vRestrictX := vCurrentX;
            END_IF;
          ELSE
            (* i RIGHT of j → use leftmost extent *)
            vRestrictX := vLiftX;
            IF vSinkX < vRestrictX THEN
              vRestrictX := vSinkX;
            END_IF;
            IF vCurrentX < vRestrictX THEN
              vRestrictX := vCurrentX;
            END_IF;
          END_IF;
        ELSE
          vRestrictX := vCurrentX;
        END_IF;

        (* "vBetween" from pre-computed vRank *)
        vBetween := ABS(vRank[i] - vRank[j]) - 1;
  IF vBetween < 0 THEN vBetween := 0; END_IF;

        vChainOfs := Transporters[i].AvoidanceWidth
                   + INT_TO_DINT(vBetween) * (MIN_WORKING_AREA + Transporters[i].AvoidanceWidth);

        IF vCurrentX < vOtherX THEN
          (* i LEFT, j RIGHT → restrict j's XMin *)
          vNewVal := vRestrictX + vChainOfs;
          IF vNewVal > g_transporter[j].XMinDriveLimit THEN
            IF vNewVal <= (g_transporter[j].XMaxDriveLimit - MIN_WORKING_AREA) THEN
              g_transporter[j].XMinDriveLimit := vNewVal;
            ELSE
              vAdjusted := g_transporter[j].XMaxDriveLimit - MIN_WORKING_AREA;
              IF vAdjusted > g_transporter[j].XMinDriveLimit THEN
                g_transporter[j].XMinDriveLimit := vAdjusted;
              END_IF;
            END_IF;
          END_IF;

        ELSIF vCurrentX > vOtherX THEN
          (* i RIGHT, j LEFT → restrict j's XMax *)
          vNewVal := vRestrictX - vChainOfs;
          IF vNewVal < g_transporter[j].XMaxDriveLimit THEN
            IF vNewVal >= (g_transporter[j].XMinDriveLimit + MIN_WORKING_AREA) THEN
              g_transporter[j].XMaxDriveLimit := vNewVal;
            ELSE
              vAdjusted := g_transporter[j].XMinDriveLimit + MIN_WORKING_AREA;
              IF vAdjusted < g_transporter[j].XMaxDriveLimit THEN
                g_transporter[j].XMaxDriveLimit := vAdjusted;
              END_IF;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
    END_IF;

    (* ── Bidirectional safety: only adjacent (vRank diff = 1) ── *)
    IF ABS(vRank[i] - vRank[j]) = 1 THEN
      vIMovingRight := ((vIPhase = 1) OR (vIPhase = 3))
                        AND (g_transporter[i].XFinalTarget > vCurrentX);
      vJMovingRight := ((vJPhase = 1) OR (vJPhase = 3))
                        AND (g_transporter[j].XFinalTarget > vOtherX);
      vIMovingLeft := ((vIPhase = 1) OR (vIPhase = 3))
                       AND (g_transporter[i].XFinalTarget < vCurrentX);
      vJMovingLeft := ((vJPhase = 1) OR (vJPhase = 3))
                       AND (g_transporter[j].XFinalTarget < vOtherX);

      IF vCurrentX < vOtherX AND vIMovingRight AND vJMovingRight THEN
        (* i LEFT chasing j RIGHT → restrict j's XMin *)
        vNewVal := vCurrentX + Transporters[i].AvoidanceWidth;
        IF vNewVal > g_transporter[j].XMinDriveLimit THEN
          g_transporter[j].XMinDriveLimit := vNewVal;
        END_IF;
      END_IF;

      IF vCurrentX > vOtherX AND vIMovingLeft AND vJMovingLeft THEN
        (* i RIGHT chasing j LEFT → restrict j's XMax *)
        vNewVal := vCurrentX - Transporters[i].AvoidanceWidth;
        IF vNewVal < g_transporter[j].XMaxDriveLimit THEN
          g_transporter[j].XMaxDriveLimit := vNewVal;
        END_IF;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════
   TRAP VALIDATION: if restrictions vConflict, lock in place
   ══════════════════════════════════════════════════════════════ *)
FOR i := 1 TO MAX_TRANSPORTERS DO
  IF NOT g_transporter[i].IsActive THEN CONTINUE; END_IF;
  IF g_transporter[i].XMinDriveLimit > g_transporter[i].XMaxDriveLimit THEN
    g_transporter[i].XMinDriveLimit := g_transporter[i].XPosition;
    g_transporter[i].XMaxDriveLimit := g_transporter[i].XPosition;
  END_IF;
END_FOR;

END_FUNCTION_BLOCK

(* ===========================================================================================
 *  TWA_FB_CalcLimits — Transporter Working Area: X-limit calculation
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
 *  - Station restrictions from AvoidStatus
 *  - Safety distance from same-line neighbors
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


FUNCTION_BLOCK TWA_FB_CalcLimits


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
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  CountStations              : INT;
  AvoidStatus            : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF INT;
  StationOccupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Batch                   : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
END_VAR

VAR
  vI                         : INT;
  vJ                         : INT;
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
   PASS 1: Station restrictions + safety distance + properties
   Each transporter computes its OWN limits in one iteration.
   ══════════════════════════════════════════════════════════════ *)
FOR vI := 1 TO MAX_TRANSPORTERS DO
  IF NOT TransporterStatus[vI].IsActive THEN
    vPriority[vI] := 0;
    vCanEvade[vI] := FALSE;
    vRank[vI] := 0;
    CONTINUE;
  END_IF;

  vMinX := Transporters[vI].DrivePosMin;
  vMaxX := Transporters[vI].DrivePosMax;
  vCurrentX := TransporterStatus[vI].XPosition;
  vCurrentY := TransporterStatus[vI].YPosition;
  vAvoidDist := Transporters[vI].AvoidanceWidth;

  (* Lock transporters with no drive range configured *)
  IF (vMinX < 1) OR (vMaxX < 1) THEN
    TransporterStatus[vI].XMinDriveLimit := vCurrentX;
    TransporterStatus[vI].XMaxDriveLimit := vCurrentX;
    vPriority[vI] := 0;
    vCanEvade[vI] := FALSE;
    vRank[vI] := 0;
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

    vAvoidSt := AvoidStatus[vStnNum];
    IF vAvoidSt = 0 THEN CONTINUE; END_IF;  (* AVOID_NONE *)

    (* Passable: only restricts if this transporter's target *)
    IF vAvoidSt = AVOID_PASSABLE THEN
      vIsTarget := (vStnNum = TransporterStatus[vI].LiftStationTarget)
               OR  (vStnNum = TransporterStatus[vI].SinkStationTarget);
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

  (* ── Safety distance: each same-line neighbor pushes vI away ── *)
  FOR vJ := 1 TO MAX_TRANSPORTERS DO
    IF vJ = vI THEN CONTINUE; END_IF;
    IF NOT TransporterStatus[vJ].IsActive THEN CONTINUE; END_IF;

    vOtherY := TransporterStatus[vJ].YPosition;
    IF ABS(vOtherY - vCurrentY) >= 1 THEN CONTINUE; END_IF;

    vOtherX := TransporterStatus[vJ].XPosition;

    IF vOtherX < vCurrentX THEN
      (* vJ is LEFT → vJ's safety zone pushes vI's min up *)
      vNewVal := vOtherX + Transporters[vJ].AvoidanceWidth;
  IF vNewVal > vMinX THEN vMinX := vNewVal; END_IF;
    ELSIF vOtherX > vCurrentX THEN
      (* vJ is RIGHT → vJ's safety zone pushes vI's max down *)
      vNewVal := vOtherX - Transporters[vJ].AvoidanceWidth;
  IF vNewVal < vMaxX THEN vMaxX := vNewVal; END_IF;
    END_IF;
  END_FOR;

  (* ── Write limits ── *)
  TransporterStatus[vI].XMinDriveLimit := vMinX;
  TransporterStatus[vI].XMaxDriveLimit := vMaxX;

  (* ── canEvade (inline) ── *)
  vCanEvade[vI] := TRUE;
  IF TransporterStatus[vI].Status < 3 THEN
    vCanEvade[vI] := FALSE;
  END_IF;
  IF (TransporterStatus[vI].Status = 4)
     AND ((TransporterStatus[vI].Phase = 2) OR (TransporterStatus[vI].Phase = 4)) THEN
    vCanEvade[vI] := FALSE;
  END_IF;
  vWorkArea := vMaxX - vMinX;
  IF vWorkArea < MIN_WORKING_AREA THEN
    vCanEvade[vI] := FALSE;
  END_IF;

  (* ── Priority (inline, replaces TWA_CalcPriority call) ──────
     IN_PROCESS batch boost: +100000 if the task serves an
     IN_PROCESS batch. Phases 1-4 all check via LiftStation
     unit lookup (unit stays associated throughout transfer).
     This ensures treatment tasks trump NTT/empty moves. ── *)
  vIPhase := TransporterStatus[vI].Phase;
  vBatchBoost := 0;
  IF vIPhase >= 1 AND vIPhase <= 4 THEN
    vLiftStn := TransporterStatus[vI].LiftStationTarget;
    IF vLiftStn >= 1 AND vLiftStn <= MAX_STATION_INDEX THEN
      vLiftUid := StationOccupancy[vLiftStn].UnitId;
      IF vLiftUid >= 1 AND vLiftUid <= MAX_UNITS THEN
        IF Batch[vLiftUid].State = IN_PROCESS THEN
          vBatchBoost := DINT#100000;
        END_IF;
      END_IF;
    END_IF;
  END_IF;

  IF NOT vCanEvade[vI] THEN
    vPriority[vI] := DINT#100000;
  ELSIF vIPhase = 3 OR vIPhase = 4 THEN
    vDist := ABS(vCurrentX - TransporterStatus[vI].XFinalTarget);
  IF vDist > 99999 THEN vDist := 99999; END_IF;
    vPriority[vI] := DINT#200000 + vBatchBoost + (DINT#99999 - vDist);
  ELSIF vIPhase = 1 OR vIPhase = 2 THEN
    (* Move-away (Status=3, Phase=1) gets idle-class vPriority, not active-task vPriority *)
    IF TransporterStatus[vI].Status = 3 THEN
      vPriority[vI] := 2;  (* above stationary idle (1), below active tasks (100000+) *)
    ELSE
      vDist := ABS(vCurrentX - TransporterStatus[vI].XFinalTarget);
      IF vDist > 99999 THEN vDist := 99999; END_IF;
      vPriority[vI] := DINT#100000 + vBatchBoost + (DINT#99999 - vDist);
    END_IF;
  ELSE
    vPriority[vI] := 1;
  END_IF;

  (* ── X-vRank among same-line active transporters ──
     vRank = 1 + count of same-line transporters with smaller x *)
  vRank[vI] := 1;
  FOR vJ := 1 TO MAX_TRANSPORTERS DO
    IF vJ = vI THEN CONTINUE; END_IF;
    IF NOT TransporterStatus[vJ].IsActive THEN CONTINUE; END_IF;
    IF ABS(TransporterStatus[vJ].YPosition - vCurrentY) >= 1 THEN CONTINUE; END_IF;
    IF TransporterStatus[vJ].XPosition < vCurrentX THEN
      vRank[vI] := vRank[vI] + 1;
    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════
   PASS 2: Priority restrictions + bidirectional safety
   Each pair (vI,vJ): vI restricts vJ if vI has higher vPriority.
   ══════════════════════════════════════════════════════════════ *)
FOR vI := 1 TO MAX_TRANSPORTERS DO
  IF NOT TransporterStatus[vI].IsActive THEN CONTINUE; END_IF;
  IF vPriority[vI] = 0 THEN CONTINUE; END_IF;

  vCurrentX := TransporterStatus[vI].XPosition;
  vCurrentY := TransporterStatus[vI].YPosition;
  vIPhase := TransporterStatus[vI].Phase;

  FOR vJ := 1 TO MAX_TRANSPORTERS DO
    IF vJ = vI THEN CONTINUE; END_IF;
    IF NOT TransporterStatus[vJ].IsActive THEN CONTINUE; END_IF;
    IF vPriority[vJ] = 0 THEN CONTINUE; END_IF;

    vOtherY := TransporterStatus[vJ].YPosition;
    IF ABS(vOtherY - vCurrentY) >= 1 THEN CONTINUE; END_IF;

    vOtherX := TransporterStatus[vJ].XPosition;
    vJPhase := TransporterStatus[vJ].Phase;

    (* ── Priority restrictions: vI restricts vJ if vI wins ── *)
    (* Move-away (Status=3, Phase=1) participates in restrictions
       so it can push stationary idle transporters out of its way *)
    IF (vIPhase <> 0) OR (TransporterStatus[vI].Status = 3 AND vIPhase = 1) THEN
      vAWins := FALSE;
      IF vPriority[vI] > vPriority[vJ] THEN
        vAWins := TRUE;
      ELSIF (vPriority[vI] = vPriority[vJ]) AND (vI < vJ) THEN
        vAWins := TRUE;
      END_IF;

      IF vAWins THEN
        (* Full task extent: use the extreme position
           of both lift and sink stations on the side
           facing vJ. This prevents vJ from first driving
           closer and then having to reverse when vI
           moves to the other end of its task. *)
        vILiftStn := TransporterStatus[vI].LiftStationTarget;
        vISinkStn := TransporterStatus[vI].SinkStationTarget;
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
            (* vI LEFT of vJ → use rightmost extent *)
            vRestrictX := vLiftX;
            IF vSinkX > vRestrictX THEN
              vRestrictX := vSinkX;
            END_IF;
            IF vCurrentX > vRestrictX THEN
              vRestrictX := vCurrentX;
            END_IF;
          ELSE
            (* vI RIGHT of vJ → use leftmost extent *)
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
        vBetween := ABS(vRank[vI] - vRank[vJ]) - 1;
  IF vBetween < 0 THEN vBetween := 0; END_IF;

        vChainOfs := Transporters[vI].AvoidanceWidth
                   + INT_TO_DINT(vBetween) * (MIN_WORKING_AREA + Transporters[vI].AvoidanceWidth);

        IF vCurrentX < vOtherX THEN
          (* vI LEFT, vJ RIGHT → restrict vJ's XMin *)
          vNewVal := vRestrictX + vChainOfs;
          IF vNewVal > TransporterStatus[vJ].XMinDriveLimit THEN
            IF vNewVal <= (TransporterStatus[vJ].XMaxDriveLimit - MIN_WORKING_AREA) THEN
              TransporterStatus[vJ].XMinDriveLimit := vNewVal;
            ELSE
              vAdjusted := TransporterStatus[vJ].XMaxDriveLimit - MIN_WORKING_AREA;
              IF vAdjusted > TransporterStatus[vJ].XMinDriveLimit THEN
                TransporterStatus[vJ].XMinDriveLimit := vAdjusted;
              END_IF;
            END_IF;
          END_IF;

        ELSIF vCurrentX > vOtherX THEN
          (* vI RIGHT, vJ LEFT → restrict vJ's XMax *)
          vNewVal := vRestrictX - vChainOfs;
          IF vNewVal < TransporterStatus[vJ].XMaxDriveLimit THEN
            IF vNewVal >= (TransporterStatus[vJ].XMinDriveLimit + MIN_WORKING_AREA) THEN
              TransporterStatus[vJ].XMaxDriveLimit := vNewVal;
            ELSE
              vAdjusted := TransporterStatus[vJ].XMinDriveLimit + MIN_WORKING_AREA;
              IF vAdjusted < TransporterStatus[vJ].XMaxDriveLimit THEN
                TransporterStatus[vJ].XMaxDriveLimit := vAdjusted;
              END_IF;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
    END_IF;

    (* ── Bidirectional safety: only adjacent (vRank diff = 1) ── *)
    IF ABS(vRank[vI] - vRank[vJ]) = 1 THEN
      vIMovingRight := ((vIPhase = 1) OR (vIPhase = 3))
                        AND (TransporterStatus[vI].XFinalTarget > vCurrentX);
      vJMovingRight := ((vJPhase = 1) OR (vJPhase = 3))
                        AND (TransporterStatus[vJ].XFinalTarget > vOtherX);
      vIMovingLeft := ((vIPhase = 1) OR (vIPhase = 3))
                       AND (TransporterStatus[vI].XFinalTarget < vCurrentX);
      vJMovingLeft := ((vJPhase = 1) OR (vJPhase = 3))
                       AND (TransporterStatus[vJ].XFinalTarget < vOtherX);

      IF vCurrentX < vOtherX AND vIMovingRight AND vJMovingRight THEN
        (* vI LEFT chasing vJ RIGHT → restrict vJ's XMin *)
        vNewVal := vCurrentX + Transporters[vI].AvoidanceWidth;
        IF vNewVal > TransporterStatus[vJ].XMinDriveLimit THEN
          TransporterStatus[vJ].XMinDriveLimit := vNewVal;
        END_IF;
      END_IF;

      IF vCurrentX > vOtherX AND vIMovingLeft AND vJMovingLeft THEN
        (* vI RIGHT chasing vJ LEFT → restrict vJ's XMax *)
        vNewVal := vCurrentX - Transporters[vI].AvoidanceWidth;
        IF vNewVal < TransporterStatus[vJ].XMaxDriveLimit THEN
          TransporterStatus[vJ].XMaxDriveLimit := vNewVal;
        END_IF;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* ══════════════════════════════════════════════════════════════
   TRAP VALIDATION: if restrictions conflict, lock in place
   ══════════════════════════════════════════════════════════════ *)
FOR vI := 1 TO MAX_TRANSPORTERS DO
  IF NOT TransporterStatus[vI].IsActive THEN CONTINUE; END_IF;
  IF TransporterStatus[vI].XMinDriveLimit > TransporterStatus[vI].XMaxDriveLimit THEN
    TransporterStatus[vI].XMinDriveLimit := TransporterStatus[vI].XPosition;
    TransporterStatus[vI].XMaxDriveLimit := TransporterStatus[vI].XPosition;
  END_IF;
END_FOR;

END_FUNCTION_BLOCK

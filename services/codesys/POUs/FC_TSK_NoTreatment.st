(* ===========================================================================================
 *  FC_TSK_NoTreatment — Create no-treatment transfer tasks
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Scans units with a target and creates transfer tasks
 *  using the gNtt destination table.
 *
 *  VAR_IN_OUT: ioTask — only mutable array (inserts NTT tasks).
 *  All other globals are read-only via VAR_EXTERNAL.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_TSK_NoTreatment : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTimeS : LINT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioTask : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS      : INT;
    MAX_STATIONS_PER_STEP : INT;
    MIN_STATION_INDEX     : INT;
    MAX_STATION_INDEX     : INT;
    MAX_UNITS             : INT;
    MAX_TASK_QUEUE        : INT;
    SCH_DISPATCH_MARGIN_S : REAL;
    NOT_PROCESSED         : INT;
    PROCESSED             : INT;
    USED                  : INT;
END_VAR

VAR_EXTERNAL
  gUnit             : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  gBatch            : ARRAY[1..MAX_UNITS] OF UDT_BatchType;
  gNtt              : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_NttTransporterType;
  gTransporter      : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Stations          : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  gStationOccupancy : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  Transporters      : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  gMove             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
END_VAR

VAR
  vUi               : INT;
  vLoc              : INT;
  vTgt              : INT;
  vCovT             : INT;
  vAi               : INT;
  vCovers           : BOOL;
  vODone            : BOOL;
  vDest             : UDT_JC_NttDestType;
  vNttIdx           : INT;
  vOnPrimary        : BOOL;
  vOnFallback       : BOOL;
  vPrimaryFree      : BOOL;
  vDestStn          : INT;
  vSi               : INT;
  vStationIdx       : INT;
  vStnFree          : BOOL;
  vUj               : INT;
  vTi               : INT;
  vAlready          : BOOL;
  vQi2              : INT;
  vXferS            : REAL;
  vTaskStart        : LINT;
  vTaskEnd          : LINT;
  vSlotStart        : LINT;
  vTmpMove          : UDT_JC_MoveTimesType;
  vSlotEnd          : LINT;
  vLatestEnd        : LINT;
  vTravelFromSink   : REAL;
  vTravelToLiftS    : REAL;
  vTransPos         : INT;
  vNttDuration      : LINT;
  vSlotOk           : BOOL;
  vSh               : INT;

  (* Idle-stretch: extend blocking batch CalTime to make room for NTT -----------------------*)
  vStretchPending   : BOOL;
  vStretchUnitId    : INT;
  vStretchDeficit   : DINT;
  vStretchAvail     : DINT;

  (* Multi-transporter shared-vArea idle check -----------------------------------------------*)
  vOt               : INT;
  vOq               : INT;
  vOverlapConflict  : BOOL;
  vDestX            : DINT;
  vAvoidDist        : DINT;
  vCovMinX          : DINT;
  vCovMaxX          : DINT;
  vOtMinX           : DINT;
  vOtMaxX           : DINT;
  vZoneMinX         : DINT;
  vZoneMaxX         : DINT;
  vDangerMin        : DINT;
  vDangerMax        : DINT;
  (* Shared-vArea timing: NTT split into own-vArea + shared-vArea portions ---------------------*)
  vLocIdx           : INT;
  vLocX             : DINT;
  vPhase2S          : REAL;
  vSharedEntry      : LINT;
  vSharedTime       : REAL;
  vOtIdleOk         : BOOL;
  vOtIdleStart      : LINT;
  vOtIdleEnd        : LINT;
  vOtNextLift       : INT;
  vOtDispatchFrom   : INT;
  vOtTravelToNext   : REAL;

  (* Idle-stretch for other transporter: widen idle gap by extending blocker CalTime --------*)
  vOtStretchPending : BOOL;
  vOtStretchUnitId  : INT;
  vOtStretchDeficit : DINT;
  vOtStretchAvail   : DINT;
  vOtStretchNeed    : LINT;
  vOtStretchOk      : BOOL;
END_VAR

FC_TSK_NoTreatment := TRUE;

FOR vUi := 1 TO MAX_UNITS DO
  vTgt := gUnit[vUi].Target;
  vLoc := gUnit[vUi].Location;

  IF vTgt >= 1 AND vTgt <= 5 AND vLoc >= MIN_STATION_INDEX THEN

    IF vTgt = 3 AND (gBatch[vUi].BatchCode = 0 OR gBatch[vUi].State <> NOT_PROCESSED) THEN
      CONTINUE;
    END_IF;

    vAlready := FALSE;
    FOR vTi := 1 TO MAX_TRANSPORTERS DO
      IF NOT vAlready THEN
        IF gTransporter[vTi].Phase > 0 AND gStationOccupancy[vTi].UnitId = vUi THEN
          vAlready := TRUE;
        END_IF;
        FOR vQi2 := 1 TO ioTask[vTi].Count DO
          IF NOT vAlready THEN
            IF ioTask[vTi].Queue[vQi2].Unit = vUi THEN
              vAlready := TRUE;
            END_IF;
          END_IF;
        END_FOR;
      END_IF;
    END_FOR;

    IF NOT vAlready THEN

    vODone := FALSE;
    FOR vCovT := 1 TO MAX_TRANSPORTERS DO
      IF NOT vODone THEN

      vCovers := FALSE;
      FOR vAi := 1 TO 4 DO
        IF NOT vCovers THEN
          IF Transporters[vCovT].TaskArea[vAi].MinLift > 0 OR Transporters[vCovT].TaskArea[vAi].MaxLift > 0 THEN
            IF vLoc >= Transporters[vCovT].TaskArea[vAi].MinLift AND vLoc <= Transporters[vCovT].TaskArea[vAi].MaxLift THEN
              vCovers := TRUE;
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      IF vCovers AND gTransporter[vCovT].IsActive
         AND (gTransporter[vCovT].Phase = 0 OR vTgt = 5) THEN

        IF vTgt = 2 THEN
          IF gBatch[vUi].BatchCode = 0 THEN vNttIdx := 6;
          ELSIF gBatch[vUi].State = PROCESSED THEN vNttIdx := 8;
  ELSE vNttIdx := 7; END_IF;
        ELSIF vTgt = 3 THEN vNttIdx := 7;
  ELSE vNttIdx := vTgt; END_IF;

        vDest := gNtt[vCovT].Target[vNttIdx];

        vOnPrimary := FALSE;
        FOR vSi := 1 TO vDest.StationCount DO
  IF vDest.Stations[vSi] = vLoc THEN vOnPrimary := TRUE; END_IF;
        END_FOR;

        IF NOT vOnPrimary THEN

          vOnFallback := FALSE;
          FOR vSi := 1 TO vDest.FallbackCount DO
  IF vDest.FallbackStations[vSi] = vLoc THEN vOnFallback := TRUE; END_IF;
          END_FOR;

          vPrimaryFree := FALSE;
          FOR vSi := 1 TO vDest.StationCount DO
            vStationIdx := vDest.Stations[vSi];
            IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
              vStnFree := TRUE;
              FOR vUj := 1 TO MAX_UNITS DO
  IF gUnit[vUj].Location = vStationIdx AND gUnit[vUj].Status = USED THEN vStnFree := FALSE; END_IF;
              END_FOR;
  IF vStnFree THEN vPrimaryFree := TRUE; END_IF;
            END_IF;
          END_FOR;

          vDestStn := 0;

          IF vOnFallback AND NOT vPrimaryFree THEN
            vDestStn := 0;
          ELSIF vOnFallback AND vPrimaryFree THEN
            FOR vSi := 1 TO vDest.StationCount DO
              IF vDestStn = 0 THEN
                vStationIdx := vDest.Stations[vSi];
                IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
                  vStnFree := TRUE;
                  FOR vUj := 1 TO MAX_UNITS DO
  IF gUnit[vUj].Location = vStationIdx AND gUnit[vUj].Status = USED THEN vStnFree := FALSE; END_IF;
                  END_FOR;
  IF vStnFree THEN vDestStn := vStationIdx; END_IF;
                END_IF;
              END_IF;
            END_FOR;
          ELSE
            FOR vSi := 1 TO vDest.StationCount DO
              IF vDestStn = 0 THEN
                vStationIdx := vDest.Stations[vSi];
                IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
                  vStnFree := TRUE;
                  FOR vUj := 1 TO MAX_UNITS DO
  IF gUnit[vUj].Location = vStationIdx AND gUnit[vUj].Status = USED THEN vStnFree := FALSE; END_IF;
                  END_FOR;
  IF vStnFree THEN vDestStn := vStationIdx; END_IF;
                END_IF;
              END_IF;
            END_FOR;

            IF vDestStn = 0 THEN
              FOR vSi := 1 TO vDest.FallbackCount DO
                IF vDestStn = 0 THEN
                  vStationIdx := vDest.FallbackStations[vSi];
                  IF vStationIdx <> vLoc AND vStationIdx >= MIN_STATION_INDEX AND vStationIdx <= MAX_STATION_INDEX THEN
                    vStnFree := TRUE;
                    FOR vUj := 1 TO MAX_UNITS DO
  IF gUnit[vUj].Location = vStationIdx AND gUnit[vUj].Status = USED THEN vStnFree := FALSE; END_IF;
                    END_FOR;
  IF vStnFree THEN vDestStn := vStationIdx; END_IF;
                  END_IF;
                END_IF;
              END_FOR;
            END_IF;
          END_IF;

          IF vDestStn > 0 THEN
            vTmpMove := gMove[vCovT];
            vXferS := FC_STC_CalcTransferTime(
              iFromStn            := vLoc,
              iToStn              := vDestStn,
              iMove                := vTmpMove,
              iFromDroppingX10   := Stations[vLoc].DrippingTime,
              iToDeviceDelayX10 := Stations[vDestStn].DeviceDelay,
              iDripTrayDelayX10 := Transporters[vCovT].DripTrayDelay);

            (* ── Travel-to: time for transporter to reach lift station ── *)
            vTravelToLiftS := 0.0;
            IF gTransporter[vCovT].Phase = 0 THEN
              vTransPos := gTransporter[vCovT].CurrentStation;
            ELSE
              vTransPos := gTransporter[vCovT].SinkStationTarget;
            END_IF;
            IF vTransPos > 0 AND vTransPos <> vLoc THEN
              vTravelToLiftS := FC_STC_CalcHorizontalTravel(
                iFromStn := vTransPos,
                iToStn   := vLoc,
                iMove     := vTmpMove);
            END_IF;

            vTaskStart := iTimeS + REAL_TO_LINT(vTravelToLiftS);
            vTaskEnd   := vTaskStart + REAL_TO_LINT(vXferS);
            vNttDuration := vTaskEnd - vTaskStart;

            vSlotOk := FALSE;
            vStretchPending := FALSE;
            vOtStretchPending := FALSE;

            IF ioTask[vCovT].Count = 0 THEN
              vSlotOk := TRUE;
            ELSE
              IF ioTask[vCovT].Queue[1].StartTime > vTaskStart THEN
                vSlotStart := vTaskStart;
                vSlotEnd   := ioTask[vCovT].Queue[1].StartTime;
                vTravelFromSink := FC_STC_CalcHorizontalTravel(
                  iFromStn := vDestStn,
                  iToStn   := ioTask[vCovT].Queue[1].LiftStationTarget,
                  iMove     := gMove[vCovT]);
                vLatestEnd := vSlotEnd - REAL_TO_LINT(vTravelFromSink) - 1;
                IF vTaskStart >= vSlotStart AND vTaskEnd <= vLatestEnd THEN
                  vSlotOk := TRUE;
                END_IF;

                (* ── Idle-stretch: NTT slightly too long for idle window ──
                   Check if the blocking batch's treatment CalTime can be
                   extended (up to MaxTime) to widen the idle gap.  Only flag
                   the intent here; the actual gBatch write happens after
                   the multi-transporter overlap check passes. *)
                IF NOT vSlotOk AND vLatestEnd > 0 THEN
                  vStretchDeficit := LINT_TO_DINT(vTaskEnd - vLatestEnd);
                  IF vStretchDeficit > 0 THEN
                    vStretchUnitId := ioTask[vCovT].Queue[1].Unit;
                    IF vStretchUnitId >= 1 AND vStretchUnitId <= MAX_UNITS THEN
                      vStretchAvail := gBatch[vStretchUnitId].MaxTime
                                     - gBatch[vStretchUnitId].CalTime;
                      IF vStretchAvail >= vStretchDeficit THEN
                        vStretchPending := TRUE;
                        vSlotOk := TRUE;
                      END_IF;
                    END_IF;
                  END_IF;
                END_IF;
              END_IF;
            END_IF;

            IF NOT vSlotOk THEN
              IF ioTask[vCovT].Count > 0
                 AND ioTask[vCovT].Queue[1].SinkStationTarget = vLoc THEN
                vSlotOk := TRUE;
              ELSE
                vDestStn := 0;
              END_IF;
            END_IF;
          END_IF;

          (* ── Multi-transporter shared-vArea idle check ──
             If vDestStn is on the shared drive vArea between two transporters,
             the other transporter must have an idle window covering the time
             when THIS transporter is physically on the shared vArea.

             NTT transfer phases:
               Phase 2: lift + drip + tray  (nostin on vielä lift-asemalla)
               Phase 3: horizontal vTravel   (nostin liikkuu kohti vDest)
               Phase 4: lower + tray + dev  (nostin on vDest-asemalla)

             If lift station is NOT on shared vArea:
               vSharedEntry = vTaskStart + vPhase2S  (vTravel starts)
               vSharedTime  = vXferS - vPhase2S
             If lift station IS on shared vArea:
               vSharedEntry = vTaskStart  (vAlready there)
               vSharedTime  = vXferS
          *)
          IF vDestStn > 0 THEN
            vOverlapConflict := FALSE;
            vDestX := Stations[vDestStn].XPosition;
            vAvoidDist := Transporters[vCovT].AvoidanceWidth;
            vCovMinX := Transporters[vCovT].DrivePosMin;
            vCovMaxX := Transporters[vCovT].DrivePosMax;

            FOR vOt := 1 TO MAX_TRANSPORTERS DO
              IF vOt <> vCovT AND NOT vOverlapConflict
                 AND gTransporter[vOt].IsActive THEN
                vOtMinX := Transporters[vOt].DrivePosMin;
                vOtMaxX := Transporters[vOt].DrivePosMax;

                IF vCovMinX > vOtMinX THEN vZoneMinX := vCovMinX;
  ELSE vZoneMinX := vOtMinX; END_IF;
                IF vCovMaxX < vOtMaxX THEN vZoneMaxX := vCovMaxX;
  ELSE vZoneMaxX := vOtMaxX; END_IF;

                IF vZoneMinX >= vZoneMaxX THEN CONTINUE; END_IF;
                IF vDestX < vZoneMinX OR vDestX > vZoneMaxX THEN CONTINUE; END_IF;

                vDangerMin := vZoneMinX - vAvoidDist;
                vDangerMax := vZoneMaxX + vAvoidDist;

                (* ── Calculate shared-vArea entry time and vDuration ── *)
                vLocX := Stations[vLoc].XPosition;
                IF vLocX >= vDangerMin AND vLocX <= vDangerMax THEN
                  vSharedEntry := vTaskStart;
                  vSharedTime  := vXferS;
                ELSE
                  vLocIdx := vLoc - MIN_STATION_INDEX;
                  IF vLocIdx >= 1 AND vLocIdx <= 25 THEN
                    vPhase2S := INT_TO_REAL(gMove[vCovT].LiftTime[vLocIdx]) / 10.0
                              + INT_TO_REAL(Stations[vLoc].DrippingTime) / 10.0
                              + INT_TO_REAL(Transporters[vCovT].DripTrayDelay) / 10.0;
                  ELSE
                    vPhase2S := 0.0;
                  END_IF;
                  vSharedEntry := vTaskStart + REAL_TO_LINT(vPhase2S);
                  vSharedTime  := vXferS - vPhase2S;
  IF vSharedTime < 1.0 THEN vSharedTime := 1.0; END_IF;
                END_IF;

                (* ── Check: does other transporter have an idle window
                     that starts ≤ vSharedEntry and lasts ≥ vSharedTime? ── *)
                vOtIdleOk := FALSE;

                IF ioTask[vOt].Count = 0 AND gTransporter[vOt].Phase = 0 THEN
                  vOtIdleOk := TRUE;
                ELSIF ioTask[vOt].Count = 0
                      AND gTransporter[vOt].Phase >= 1
                      AND gTransporter[vOt].Phase <= 4 THEN
                  (* Transporter executing task, nothing queued after.
                     Idle starts at current task finish. *)
                  vOtIdleStart := gTransporter[vOt].CurrentTaskFinishTime;
                  IF vOtIdleStart <= vSharedEntry THEN
                    vOtIdleOk := TRUE;
                  END_IF;
                ELSE
                  IF ioTask[vOt].Count > 0 THEN
                    IF gTransporter[vOt].Phase >= 1 AND gTransporter[vOt].Phase <= 4 THEN
                      (* Idle gap: current task finish → next queued start *)
                      vOtIdleStart := gTransporter[vOt].CurrentTaskFinishTime;
                      vOtDispatchFrom := gTransporter[vOt].SinkStationTarget;
                    ELSE
                      vOtIdleStart := vTaskStart;
                      vOtDispatchFrom := gTransporter[vOt].CurrentStation;
                    END_IF;
                    vOtNextLift := ioTask[vOt].Queue[1].LiftStationTarget;
                    vOtTravelToNext := 0.0;
                    IF vOtDispatchFrom > 0
                       AND vOtNextLift > 0
                       AND vOtDispatchFrom <> vOtNextLift THEN
                      vOtTravelToNext := FC_STC_CalcHorizontalTravel(
                        iFromStn := vOtDispatchFrom,
                        iToStn   := vOtNextLift,
                        iMove     := gMove[vOt]);
                    END_IF;
                    vOtIdleEnd := ioTask[vOt].Queue[1].StartTime
                                 - REAL_TO_LINT(vOtTravelToNext)
                                 - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                    IF vOtIdleEnd < vOtIdleStart THEN
                      vOtIdleEnd := vOtIdleStart;
                    END_IF;
                    IF vOtIdleStart <= vSharedEntry
                       AND vOtIdleEnd >= vSharedEntry + REAL_TO_LINT(vSharedTime) THEN
                      vOtIdleOk := TRUE;
                    END_IF;
                  END_IF;

                  IF NOT vOtIdleOk THEN
                    FOR vOq := 1 TO ioTask[vOt].Count - 1 DO
                      IF NOT vOtIdleOk THEN
                        vOtIdleStart := ioTask[vOt].Queue[vOq].FinishTime;
                        vOtDispatchFrom := ioTask[vOt].Queue[vOq].SinkStationTarget;
                        vOtNextLift := ioTask[vOt].Queue[vOq + 1].LiftStationTarget;
                        vOtTravelToNext := 0.0;
                        IF vOtDispatchFrom > 0
                           AND vOtNextLift > 0
                           AND vOtDispatchFrom <> vOtNextLift THEN
                          vOtTravelToNext := FC_STC_CalcHorizontalTravel(
                            iFromStn := vOtDispatchFrom,
                            iToStn   := vOtNextLift,
                            iMove     := gMove[vOt]);
                        END_IF;
                        vOtIdleEnd := ioTask[vOt].Queue[vOq + 1].StartTime
                                     - REAL_TO_LINT(vOtTravelToNext)
                                     - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                        IF vOtIdleEnd < vOtIdleStart THEN
                          vOtIdleEnd := vOtIdleStart;
                        END_IF;
                        IF vOtIdleStart <= vSharedEntry
                           AND vOtIdleEnd >= vSharedEntry + REAL_TO_LINT(vSharedTime) THEN
                          vOtIdleOk := TRUE;
                        END_IF;
                      END_IF;
                    END_FOR;
                  END_IF;

                  IF NOT vOtIdleOk AND ioTask[vOt].Count > 0 THEN
                    vOtIdleStart := ioTask[vOt].Queue[ioTask[vOt].Count].FinishTime;
                    IF vOtIdleStart <= vSharedEntry THEN
                      vOtIdleOk := TRUE;
                    END_IF;
                  END_IF;
                END_IF;

                IF NOT vOtIdleOk THEN
                  (* ── Idle-stretch for other transporter ──
                     Try to widen the nearest idle gap by extending the
                     blocking batch CalTime (up to MaxTime).  Only tasks
                     with Stage > 0 (regular, not NTT) are candidates. *)
                  vOtStretchOk := FALSE;

                  (* Try gap before first task *)
                  IF ioTask[vOt].Count > 0
                     AND ioTask[vOt].Queue[1].Stage > 0 THEN
                    IF gTransporter[vOt].Phase >= 1 AND gTransporter[vOt].Phase <= 4 THEN
                      vOtIdleStart := gTransporter[vOt].CurrentTaskFinishTime;
                      vOtDispatchFrom := gTransporter[vOt].SinkStationTarget;
                    ELSE
                      vOtIdleStart := vTaskStart;
                      vOtDispatchFrom := gTransporter[vOt].CurrentStation;
                    END_IF;
                    vOtNextLift := ioTask[vOt].Queue[1].LiftStationTarget;
                    vOtTravelToNext := 0.0;
                    IF vOtDispatchFrom > 0
                       AND vOtNextLift > 0
                       AND vOtDispatchFrom <> vOtNextLift THEN
                      vOtTravelToNext := FC_STC_CalcHorizontalTravel(
                        iFromStn := vOtDispatchFrom,
                        iToStn   := vOtNextLift,
                        iMove     := gMove[vOt]);
                    END_IF;
                    vOtIdleEnd := ioTask[vOt].Queue[1].StartTime
                                 - REAL_TO_LINT(vOtTravelToNext)
                                 - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                    IF vOtIdleEnd < vOtIdleStart THEN
                      vOtIdleEnd := vOtIdleStart;
                    END_IF;

                    IF vOtIdleStart <= vSharedEntry
                       AND vOtIdleEnd > vSharedEntry THEN
                      vOtStretchNeed := vSharedEntry
                                       + REAL_TO_LINT(vSharedTime)
                                       - vOtIdleEnd;
                      IF vOtStretchNeed > LINT#0 THEN
                        vOtStretchUnitId := ioTask[vOt].Queue[1].Unit;
                        IF vOtStretchUnitId >= 1
                           AND vOtStretchUnitId <= MAX_UNITS THEN
                          vOtStretchAvail :=
                            gBatch[vOtStretchUnitId].MaxTime
                          - gBatch[vOtStretchUnitId].CalTime;
                          IF vOtStretchAvail >= LINT_TO_DINT(vOtStretchNeed) THEN
                            vOtStretchDeficit := LINT_TO_DINT(vOtStretchNeed);
                            vOtStretchPending := TRUE;
                            vOtStretchOk      := TRUE;
                          END_IF;
                        END_IF;
                      END_IF;
                    END_IF;
                  END_IF;

                  (* Try gaps between tasks *)
                  IF NOT vOtStretchOk THEN
                    FOR vOq := 1 TO ioTask[vOt].Count - 1 DO
                      IF NOT vOtStretchOk
                         AND ioTask[vOt].Queue[vOq + 1].Stage > 0 THEN
                        vOtIdleStart := ioTask[vOt].Queue[vOq].FinishTime;
                        vOtDispatchFrom := ioTask[vOt].Queue[vOq].SinkStationTarget;
                        vOtNextLift := ioTask[vOt].Queue[vOq + 1].LiftStationTarget;
                        vOtTravelToNext := 0.0;
                        IF vOtDispatchFrom > 0
                           AND vOtNextLift > 0
                           AND vOtDispatchFrom <> vOtNextLift THEN
                          vOtTravelToNext := FC_STC_CalcHorizontalTravel(
                            iFromStn := vOtDispatchFrom,
                            iToStn   := vOtNextLift,
                            iMove     := gMove[vOt]);
                        END_IF;
                        vOtIdleEnd := ioTask[vOt].Queue[vOq + 1].StartTime
                                     - REAL_TO_LINT(vOtTravelToNext)
                                     - REAL_TO_LINT(SCH_DISPATCH_MARGIN_S);
                        IF vOtIdleEnd < vOtIdleStart THEN
                          vOtIdleEnd := vOtIdleStart;
                        END_IF;

                        IF vOtIdleStart <= vSharedEntry
                           AND vOtIdleEnd > vSharedEntry THEN
                          vOtStretchNeed := vSharedEntry
                                           + REAL_TO_LINT(vSharedTime)
                                           - vOtIdleEnd;
                          IF vOtStretchNeed > LINT#0 THEN
                            vOtStretchUnitId := ioTask[vOt].Queue[vOq + 1].Unit;
                            IF vOtStretchUnitId >= 1
                               AND vOtStretchUnitId <= MAX_UNITS THEN
                              vOtStretchAvail :=
                                gBatch[vOtStretchUnitId].MaxTime
                              - gBatch[vOtStretchUnitId].CalTime;
                              IF vOtStretchAvail >= LINT_TO_DINT(vOtStretchNeed) THEN
                                vOtStretchDeficit := LINT_TO_DINT(vOtStretchNeed);
                                vOtStretchPending := TRUE;
                                vOtStretchOk      := TRUE;
                              END_IF;
                            END_IF;
                          END_IF;
                        END_IF;
                      END_IF;
                    END_FOR;
                  END_IF;

                  IF vOtStretchOk THEN
                    vOtIdleOk := TRUE;
                  ELSE
                    vOverlapConflict := TRUE;
                  END_IF;
                END_IF;
              END_IF;
            END_FOR;

  IF vOverlapConflict THEN vDestStn := 0; END_IF;
          END_IF;

          IF vDestStn > 0 THEN
            (* ── Commit idle-stretch: extend blocking batch CalTime ── *)
            IF vStretchPending THEN
              gBatch[vStretchUnitId].CalTime :=
                gBatch[vStretchUnitId].CalTime + vStretchDeficit;
              vStretchPending := FALSE;
            END_IF;

            (* ── Commit other-transporter idle-stretch ── *)
            IF vOtStretchPending THEN
              gBatch[vOtStretchUnitId].CalTime :=
                gBatch[vOtStretchUnitId].CalTime + vOtStretchDeficit;
              vOtStretchPending := FALSE;
            END_IF;

            IF ioTask[vCovT].Count < MAX_TASK_QUEUE THEN
              FOR vSh := ioTask[vCovT].Count TO 1 BY -1 DO
                ioTask[vCovT].Queue[vSh + 1] := ioTask[vCovT].Queue[vSh];
              END_FOR;
              ioTask[vCovT].Queue[1].Unit         := vUi;
              ioTask[vCovT].Queue[1].Stage        := 0;
              ioTask[vCovT].Queue[1].LiftStationTarget := vLoc;
              ioTask[vCovT].Queue[1].SinkStationTarget := vDestStn;
              ioTask[vCovT].Queue[1].StartTime   := vTaskStart;
              ioTask[vCovT].Queue[1].FinishTime  := vTaskEnd;
              ioTask[vCovT].Queue[1].CalcTime    := 0;
              ioTask[vCovT].Queue[1].MinTime     := 0;
              ioTask[vCovT].Queue[1].MaxTime     := 0;
              ioTask[vCovT].Queue[1].NttPrimary := 0;
              FOR vSi := 1 TO vDest.StationCount DO
                IF vDest.Stations[vSi] = vDestStn THEN
                  ioTask[vCovT].Queue[1].NttPrimary := 1;
                END_IF;
              END_FOR;
              ioTask[vCovT].Count := ioTask[vCovT].Count + 1;
              vODone := TRUE;
            END_IF;
          END_IF;

        END_IF; (* NOT vOnPrimary *)
      END_IF; (* vCovers + idle *)
      END_IF; (* NOT vODone *)
    END_FOR; (* transporter loop *)
    END_IF; (* NOT vAlready *)
  END_IF; (* valid target *)
END_FOR;

END_FUNCTION

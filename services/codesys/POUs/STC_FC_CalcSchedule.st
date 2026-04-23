(* ===========================================================================================
 *  STC_FC_CalcSchedule — Calculate batch schedule for one unit
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Shared FC: both TSK and DEP call this with different arrays.
 *  Calculates start/finish times for each treatment stage based
 *  on elapsed time, cal_time and transfer durations.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_FC_CalcSchedule : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iUnit                    : INT;
  iTrans                   : INT;
  iTimeS                  : LINT;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 10=MAX_UNITS *)
  ioSchedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  ioBatch                  : ARRAY[1..10] OF UDT_BatchType;
  ioProgram                : ARRAY[1..10] OF UDT_TreatmentProgramType;
END_VAR

VAR_EXTERNAL CONSTANT
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
    MAX_UNITS               : INT;
    MAX_TRANSPORTERS        : INT;
    MAX_STEPS_PER_PROGRAM   : INT;
    NOT_PROCESSED           : INT;
    USED                    : INT;
END_VAR

VAR_EXTERNAL
  Unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  StationOccupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  CountStations              : INT;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
END_VAR

VAR
  vStg                       : INT;
  vStnNum                   : INT;
  vPrevStn                  : INT;
  vCurStage                 : INT;
  vLocation                  : INT;
  vStartSt                  : INT;
  vEntryT                   : LINT;
  vExitT                    : LINT;
  vXferT                    : REAL;
  vCalcS                    : REAL;
  vMinS                     : REAL;
  vMaxS                     : REAL;
  vIsOnStn                 : BOOL;
  vIsFirst                  : BOOL;
  vRemainS                  : REAL;
  vElapsedS                 : REAL;
  vP                         : INT;
  vChosenStn                : INT;
  vTmpMove                  : UDT_JC_MoveTimesType;
  vCandArr                  : ARRAY[1..5] OF INT;
  vCandCnt                  : INT;
  vSchedOccupied            : ARRAY[1..5] OF BOOL;
  vBestChangeTime          : LINT;
  vMyEntry                  : LINT;
  vMyExit                   : LINT;
  vOvStart                  : LINT;
  vOvEnd                    : LINT;
  vUj                        : INT;
  vSj                        : INT;
END_VAR

STC_FC_CalcSchedule := FALSE;
IF iUnit < 1 OR iUnit > MAX_UNITS THEN RETURN; END_IF;
IF iTrans < 1 OR iTrans > MAX_TRANSPORTERS THEN RETURN; END_IF;

vCurStage := ioBatch[iUnit].CurStage;
vLocation  := Unit[iUnit].vLocation;
vIsOnStn := vLocation >= MIN_STATION_INDEX;

(* Clear old schedule *)
FOR vStg := 0 TO MAX_STEPS_PER_PROGRAM DO
  ioSchedule[iUnit].Stages[vStg].station := 0;
  ioSchedule[iUnit].Stages[vStg].ProgramStage := 0;
  ioSchedule[iUnit].Stages[vStg].EntryTime := 0;
  ioSchedule[iUnit].Stages[vStg].ExitTime := 0;
  ioSchedule[iUnit].Stages[vStg].MinTime := 0;
  ioSchedule[iUnit].Stages[vStg].CalcTime := 0;
  ioSchedule[iUnit].Stages[vStg].MaxTime := 0;
  ioSchedule[iUnit].Stages[vStg].TransferTime := 0;
END_FOR;
ioSchedule[iUnit].StageCount := 0;

(* Waiting batch (state = NOT_PROCESSED): treat as stage 0 *)
IF ioBatch[iUnit].State = NOT_PROCESSED THEN
  vCurStage := 0;
END_IF;

IF vIsOnStn THEN
  vStartSt := vCurStage;
ELSE
  vStartSt := vCurStage + 1;
END_IF;
IF vStartSt < 1 THEN
  vStartSt := 1;
END_IF;

IF vIsOnStn THEN
  vPrevStn := vLocation;
ELSIF vCurStage >= 1 AND vCurStage <= 30 THEN
  vPrevStn := ioProgram[iUnit].Steps[vCurStage].Stations[0];
ELSE
  vPrevStn := 0;
END_IF;

vExitT := iTimeS;
vIsFirst := TRUE;

(* Prepend current vLocation to Stages[0] when unit needs pre-positioning *)
IF vIsOnStn AND vStartSt >= 1 THEN
  vStnNum := 0;
  FOR vP := 0 TO 4 DO
    IF ioProgram[iUnit].Steps[vStartSt].Stations[vP] = vLocation THEN
      vStnNum := vLocation;
    END_IF;
  END_FOR;
  IF vStnNum = 0 THEN
    ioSchedule[iUnit].Stages[0].station       := vLocation;
    ioSchedule[iUnit].Stages[0].ProgramStage := 0;
    ioSchedule[iUnit].Stages[0].EntryTime    := vExitT;
    ioSchedule[iUnit].Stages[0].TransferTime := 0;

    IF ioBatch[iUnit].CurStage = 0 AND ioBatch[iUnit].CalTime > 0 THEN
      IF ioBatch[iUnit].StartTime > 0 AND ioBatch[iUnit].StartTime < iTimeS THEN
        vElapsedS := LINT_TO_REAL(iTimeS - ioBatch[iUnit].StartTime);
      ELSE
        vElapsedS := 0.0;
      END_IF;
      vRemainS := DINT_TO_REAL(ioBatch[iUnit].CalTime) - vElapsedS;
  IF vRemainS < 1.0 THEN vRemainS := 1.0; END_IF;
      vExitT := iTimeS + REAL_TO_LINT(vRemainS);
      ioSchedule[iUnit].Stages[0].ExitTime  := vExitT;
      ioSchedule[iUnit].Stages[0].CalcTime  := REAL_TO_DINT(vRemainS);
      ioSchedule[iUnit].Stages[0].MinTime   := ioBatch[iUnit].MinTime;
      ioSchedule[iUnit].Stages[0].MaxTime   := ioBatch[iUnit].MaxTime;
    ELSE
      (* Pickup wait: transporter horizontal travel time to this station, min 5s *)
      vCalcS := STC_FC_CalcHorizontalTravel(
        iFromStn := TransporterStatus[iTrans].CurrentStation,
        iToStn   := vLocation,
        iMove     := Move[iTrans]);
      IF vCalcS < 5.0 THEN vCalcS := 5.0; END_IF;
      vExitT := iTimeS + REAL_TO_LINT(vCalcS);
      ioSchedule[iUnit].Stages[0].ExitTime  := vExitT;
      ioSchedule[iUnit].Stages[0].CalcTime  := REAL_TO_DINT(vCalcS);
      ioSchedule[iUnit].Stages[0].MinTime   := REAL_TO_DINT(vCalcS);
      ioSchedule[iUnit].Stages[0].MaxTime   := REAL_TO_DINT(2.0 * vCalcS);
    END_IF;

    vIsFirst := FALSE;
  END_IF;
END_IF;

(* ============================================================
   MAIN LOOP: Calculate schedule for each program stage
   ============================================================ *)
FOR vStg := vStartSt TO ioProgram[iUnit].StepCount DO

  vCandCnt := 0;
  FOR vP := 0 TO 4 DO
    IF ioProgram[iUnit].Steps[vStg].Stations[vP] > 0 THEN
      vCandCnt := vCandCnt + 1;
      vCandArr[vCandCnt] := ioProgram[iUnit].Steps[vStg].Stations[vP];
      vSchedOccupied[vCandCnt] := FALSE;
    END_IF;
  END_FOR;

  IF vCandCnt = 0 THEN
    EXIT;
  END_IF;

  vChosenStn := 0;
  IF vIsFirst AND vIsOnStn AND vStg = vCurStage THEN
    FOR vP := 1 TO vCandCnt DO
      IF vCandArr[vP] = vLocation THEN
        vChosenStn := vLocation;
      END_IF;
    END_FOR;
  END_IF;

  IF vChosenStn = 0 THEN
    IF vCandCnt = 1 THEN
      vChosenStn := vCandArr[1];
    ELSE
      (* Estimate this batch's time window per candidate for overlap check *)
      vCalcS := DINT_TO_REAL(ioProgram[iUnit].Steps[vStg].CalTime);
      vTmpMove := Move[iTrans];

      FOR vP := 1 TO vCandCnt DO
        (* Calculate entry/exit per candidate station individually *)
        vXferT := STC_FC_CalcTransferTime(
          iFromStn            := vPrevStn,
          iToStn              := vCandArr[vP],
          iMove                := vTmpMove,
          iFromDroppingX10   := Stations[vPrevStn].DrippingTime,
          iToDeviceDelayX10 := Stations[vCandArr[vP]].DeviceDelay,
          iDripTrayDelayX10 := Transporters[iTrans].DripTrayDelay
        );
        vMyEntry := vExitT + REAL_TO_LINT(vXferT);
        vMyExit  := vMyEntry + REAL_TO_LINT(vCalcS);

        FOR vUj := 1 TO MAX_UNITS DO
          IF vUj <> iUnit AND ioSchedule[vUj].StageCount > 0 THEN
            FOR vSj := 0 TO ioSchedule[vUj].StageCount DO
              IF ioSchedule[vUj].Stages[vSj].station = vCandArr[vP] THEN
                vOvStart := vMyEntry;
                IF ioSchedule[vUj].Stages[vSj].EntryTime > vOvStart THEN
                  vOvStart := ioSchedule[vUj].Stages[vSj].EntryTime;
                END_IF;
                vOvEnd := vMyExit;
                IF ioSchedule[vUj].Stages[vSj].ExitTime < vOvEnd THEN
                  vOvEnd := ioSchedule[vUj].Stages[vSj].ExitTime;
                END_IF;
                IF vOvEnd > vOvStart THEN
                  vSchedOccupied[vP] := TRUE;
                END_IF;
              END_IF;
            END_FOR;
          END_IF;
        END_FOR;

      END_FOR;

      (* Pass 1: prefer schedule-free station, pick earliest ChangeTime *)
      vBestChangeTime := LINT#9999999999;
      FOR vP := 1 TO vCandCnt DO
        IF NOT vSchedOccupied[vP] THEN
          IF vCandArr[vP] >= MIN_STATION_INDEX AND vCandArr[vP] <= MAX_STATION_INDEX THEN
            IF StationOccupancy[vCandArr[vP]].ChangeTime < vBestChangeTime THEN
              vBestChangeTime := StationOccupancy[vCandArr[vP]].ChangeTime;
              vChosenStn := vCandArr[vP];
            END_IF;
          END_IF;
        END_IF;
      END_FOR;

      (* Pass 2: all sched-occupied — pick first candidate *)
      IF vChosenStn = 0 THEN
        vChosenStn := vCandArr[1];
      END_IF;
    END_IF;
  END_IF;

  vStnNum := vChosenStn;

  vCalcS := DINT_TO_REAL(ioProgram[iUnit].Steps[vStg].CalTime);
  vMinS  := DINT_TO_REAL(ioProgram[iUnit].Steps[vStg].MinTime);
  vMaxS  := DINT_TO_REAL(ioProgram[iUnit].Steps[vStg].MaxTime);

  vTmpMove := Move[iTrans];
  IF vPrevStn >= MIN_STATION_INDEX AND vPrevStn <= MAX_STATION_INDEX
     AND vStnNum >= MIN_STATION_INDEX AND vStnNum <= MAX_STATION_INDEX THEN
    IF Stations[vPrevStn].Crosstransport > 0
       AND Stations[vPrevStn].ChangeStation > 0
       AND Stations[vPrevStn].YPosition <> Stations[vStnNum].YPosition THEN
      vXferT := INT_TO_REAL(Stations[vPrevStn].CrossTransportTime)
              + STC_FC_CalcTransferTime(
                  iFromStn            := Stations[vPrevStn].ChangeStation,
                  iToStn              := vStnNum,
                  iMove                := vTmpMove,
                  iFromDroppingX10   := Stations[Stations[vPrevStn].ChangeStation].DrippingTime,
                  iToDeviceDelayX10 := Stations[vStnNum].DeviceDelay,
                  iDripTrayDelayX10 := Transporters[iTrans].DripTrayDelay
                );
    ELSE
      vXferT := STC_FC_CalcTransferTime(
        iFromStn            := vPrevStn,
        iToStn              := vStnNum,
        iMove                := vTmpMove,
        iFromDroppingX10   := Stations[vPrevStn].DrippingTime,
        iToDeviceDelayX10 := Stations[vStnNum].DeviceDelay,
        iDripTrayDelayX10 := Transporters[iTrans].DripTrayDelay
      );
    END_IF;
  ELSE
    vXferT := 60.0;
  END_IF;

  IF vIsFirst AND vIsOnStn AND vStg = vCurStage THEN
    vEntryT := iTimeS;
    IF ioBatch[iUnit].StartTime > 0 THEN
      vElapsedS := LINT_TO_REAL(iTimeS - ioBatch[iUnit].StartTime);
    ELSE
      vElapsedS := 0.0;
    END_IF;
    vRemainS := DINT_TO_REAL(ioBatch[iUnit].CalTime) - vElapsedS;
  IF vRemainS < 1.0 THEN vRemainS := 1.0; END_IF;
    vExitT := iTimeS + REAL_TO_LINT(vRemainS);
  ELSIF vIsFirst AND NOT vIsOnStn THEN
    IF ioBatch[iUnit].StartTime > 0 AND ioBatch[iUnit].CalTime > 0 THEN
      vEntryT := ioBatch[iUnit].StartTime + DINT_TO_LINT(ioBatch[iUnit].CalTime);
    ELSE
      vEntryT := iTimeS + REAL_TO_LINT(vXferT);
    END_IF;
    vExitT  := vEntryT + REAL_TO_LINT(vCalcS);
  ELSE
    vEntryT := vExitT + REAL_TO_LINT(vXferT);
    vExitT  := vEntryT + REAL_TO_LINT(vCalcS);
  END_IF;

  IF vStg <= 30 THEN
    ioSchedule[iUnit].Stages[vStg].station       := vStnNum;
    ioSchedule[iUnit].Stages[vStg].ProgramStage := vStg;
    ioSchedule[iUnit].Stages[vStg].EntryTime    := vEntryT;
    ioSchedule[iUnit].Stages[vStg].ExitTime     := vExitT;
    ioSchedule[iUnit].Stages[vStg].MinTime      := REAL_TO_DINT(vMinS);
    ioSchedule[iUnit].Stages[vStg].CalcTime     := REAL_TO_DINT(vCalcS);
    ioSchedule[iUnit].Stages[vStg].MaxTime      := REAL_TO_DINT(vMaxS);
    ioSchedule[iUnit].Stages[vStg].TransferTime := REAL_TO_DINT(vXferT);
    ioSchedule[iUnit].StageCount := vStg;
  END_IF;

  vPrevStn := vStnNum;
  vIsFirst := FALSE;

END_FOR;

STC_FC_CalcSchedule := TRUE;

END_FUNCTION

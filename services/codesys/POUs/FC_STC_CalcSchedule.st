(* ===========================================================================================
 *  FC_STC_CalcSchedule — Calculate batch schedule for one unit
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


FUNCTION FC_STC_CalcSchedule : BOOL


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
  g_unit                    : ARRAY[1..MAX_UNITS] OF UDT_JC_UnitType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  g_station_occupancy             : ARRAY[1..MAX_STATION_INDEX] OF UDT_JC_UnitAtStationType;
  CountStations              : INT;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
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
  is_on_stn                 : BOOL;
  is_first                  : BOOL;
  vRemainS                  : REAL;
  vElapsedS                 : REAL;
  p                         : INT;
  vChosenStn                : INT;
  vTmpMove                  : UDT_JC_MoveTimesType;
  vCandArr                  : ARRAY[1..5] OF INT;
  vCandCnt                  : INT;
  vSchedOccupied            : ARRAY[1..5] OF BOOL;
  vBestChangeTime          : LINT;
  my_entry                  : LINT;
  my_exit                   : LINT;
  ov_start                  : LINT;
  ov_end                    : LINT;
  uj                        : INT;
  sj                        : INT;
END_VAR

FC_STC_CalcSchedule := FALSE;
IF iUnit < 1 OR iUnit > MAX_UNITS THEN RETURN; END_IF;
IF iTrans < 1 OR iTrans > MAX_TRANSPORTERS THEN RETURN; END_IF;

vCurStage := ioBatch[iUnit].CurStage;
vLocation  := g_unit[iUnit].vLocation;
is_on_stn := vLocation >= MIN_STATION_INDEX;

(* Clear old schedule *)
FOR vStg := 0 TO MAX_STEPS_PER_PROGRAM DO
  ioSchedule[iUnit].Stages[vStg].Station := 0;
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

IF is_on_stn THEN
  vStartSt := vCurStage;
ELSE
  vStartSt := vCurStage + 1;
END_IF;
IF vStartSt < 1 THEN
  vStartSt := 1;
END_IF;

IF is_on_stn THEN
  vPrevStn := vLocation;
ELSIF vCurStage >= 1 AND vCurStage <= 30 THEN
  vPrevStn := ioProgram[iUnit].Steps[vCurStage].Stations[0];
ELSE
  vPrevStn := 0;
END_IF;

vExitT := iTimeS;
is_first := TRUE;

(* Prepend current vLocation to Stages[0] when unit needs pre-positioning *)
IF is_on_stn AND vStartSt >= 1 THEN
  vStnNum := 0;
  FOR p := 0 TO 4 DO
    IF ioProgram[iUnit].Steps[vStartSt].Stations[p] = vLocation THEN
      vStnNum := vLocation;
    END_IF;
  END_FOR;
  IF vStnNum = 0 THEN
    ioSchedule[iUnit].Stages[0].Station       := vLocation;
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
      (* Pickup wait: transporter horizontal vTravel time to this station, min 5s *)
      vCalcS := FC_STC_CalcHorizontalTravel(
        iFromStn := g_transporter[iTrans].CurrentStation,
        iToStn   := vLocation,
        iMove     := g_move[iTrans]);
      IF vCalcS < 5.0 THEN vCalcS := 5.0; END_IF;
      vExitT := iTimeS + REAL_TO_LINT(vCalcS);
      ioSchedule[iUnit].Stages[0].ExitTime  := vExitT;
      ioSchedule[iUnit].Stages[0].CalcTime  := REAL_TO_DINT(vCalcS);
      ioSchedule[iUnit].Stages[0].MinTime   := REAL_TO_DINT(vCalcS);
      ioSchedule[iUnit].Stages[0].MaxTime   := REAL_TO_DINT(2.0 * vCalcS);
    END_IF;

    is_first := FALSE;
  END_IF;
END_IF;

(* ============================================================
   MAIN LOOP: Calculate schedule for each program stage
   ============================================================ *)
FOR vStg := vStartSt TO ioProgram[iUnit].StepCount DO

  vCandCnt := 0;
  FOR p := 0 TO 4 DO
    IF ioProgram[iUnit].Steps[vStg].Stations[p] > 0 THEN
      vCandCnt := vCandCnt + 1;
      vCandArr[vCandCnt] := ioProgram[iUnit].Steps[vStg].Stations[p];
      vSchedOccupied[vCandCnt] := FALSE;
    END_IF;
  END_FOR;

  IF vCandCnt = 0 THEN
    EXIT;
  END_IF;

  vChosenStn := 0;
  IF is_first AND is_on_stn AND vStg = vCurStage THEN
    FOR p := 1 TO vCandCnt DO
      IF vCandArr[p] = vLocation THEN
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
      vTmpMove := g_move[iTrans];

      FOR p := 1 TO vCandCnt DO
        (* Calculate entry/exit per candidate station individually *)
        vXferT := FC_STC_CalcTransferTime(
          iFromStn            := vPrevStn,
          iToStn              := vCandArr[p],
          iMove                := vTmpMove,
          i_from_dropping_x10   := Stations[vPrevStn].DrippingTime,
          i_to_device_delay_x10 := Stations[vCandArr[p]].DeviceDelay,
          iDripTrayDelayX10 := Transporters[iTrans].DripTrayDelay
        );
        my_entry := vExitT + REAL_TO_LINT(vXferT);
        my_exit  := my_entry + REAL_TO_LINT(vCalcS);

        FOR uj := 1 TO MAX_UNITS DO
          IF uj <> iUnit AND ioSchedule[uj].StageCount > 0 THEN
            FOR sj := 0 TO ioSchedule[uj].StageCount DO
              IF ioSchedule[uj].Stages[sj].Station = vCandArr[p] THEN
                ov_start := my_entry;
                IF ioSchedule[uj].Stages[sj].EntryTime > ov_start THEN
                  ov_start := ioSchedule[uj].Stages[sj].EntryTime;
                END_IF;
                ov_end := my_exit;
                IF ioSchedule[uj].Stages[sj].ExitTime < ov_end THEN
                  ov_end := ioSchedule[uj].Stages[sj].ExitTime;
                END_IF;
                IF ov_end > ov_start THEN
                  vSchedOccupied[p] := TRUE;
                END_IF;
              END_IF;
            END_FOR;
          END_IF;
        END_FOR;

      END_FOR;

      (* Pass 1: prefer schedule-free station, pick vEarliest ChangeTime *)
      vBestChangeTime := LINT#9999999999;
      FOR p := 1 TO vCandCnt DO
        IF NOT vSchedOccupied[p] THEN
          IF vCandArr[p] >= MIN_STATION_INDEX AND vCandArr[p] <= MAX_STATION_INDEX THEN
            IF g_station_occupancy[vCandArr[p]].ChangeTime < vBestChangeTime THEN
              vBestChangeTime := g_station_occupancy[vCandArr[p]].ChangeTime;
              vChosenStn := vCandArr[p];
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

  vTmpMove := g_move[iTrans];
  IF vPrevStn >= MIN_STATION_INDEX AND vPrevStn <= MAX_STATION_INDEX
     AND vStnNum >= MIN_STATION_INDEX AND vStnNum <= MAX_STATION_INDEX THEN
    IF Stations[vPrevStn].Crosstransport > 0
       AND Stations[vPrevStn].ChangeStation > 0
       AND Stations[vPrevStn].YPosition <> Stations[vStnNum].YPosition THEN
      vXferT := INT_TO_REAL(Stations[vPrevStn].CrossTransportTime)
              + FC_STC_CalcTransferTime(
                  iFromStn            := Stations[vPrevStn].ChangeStation,
                  iToStn              := vStnNum,
                  iMove                := vTmpMove,
                  i_from_dropping_x10   := Stations[Stations[vPrevStn].ChangeStation].DrippingTime,
                  i_to_device_delay_x10 := Stations[vStnNum].DeviceDelay,
                  iDripTrayDelayX10 := Transporters[iTrans].DripTrayDelay
                );
    ELSE
      vXferT := FC_STC_CalcTransferTime(
        iFromStn            := vPrevStn,
        iToStn              := vStnNum,
        iMove                := vTmpMove,
        i_from_dropping_x10   := Stations[vPrevStn].DrippingTime,
        i_to_device_delay_x10 := Stations[vStnNum].DeviceDelay,
        iDripTrayDelayX10 := Transporters[iTrans].DripTrayDelay
      );
    END_IF;
  ELSE
    vXferT := 60.0;
  END_IF;

  IF is_first AND is_on_stn AND vStg = vCurStage THEN
    vEntryT := iTimeS;
    IF ioBatch[iUnit].StartTime > 0 THEN
      vElapsedS := LINT_TO_REAL(iTimeS - ioBatch[iUnit].StartTime);
    ELSE
      vElapsedS := 0.0;
    END_IF;
    vRemainS := DINT_TO_REAL(ioBatch[iUnit].CalTime) - vElapsedS;
  IF vRemainS < 1.0 THEN vRemainS := 1.0; END_IF;
    vExitT := iTimeS + REAL_TO_LINT(vRemainS);
  ELSIF is_first AND NOT is_on_stn THEN
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
    ioSchedule[iUnit].Stages[vStg].Station       := vStnNum;
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
  is_first := FALSE;

END_FOR;

FC_STC_CalcSchedule := TRUE;

END_FUNCTION

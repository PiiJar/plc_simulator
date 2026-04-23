(* ===========================================================================================
 *  TSK_FC_Resolve — Conflict resolution
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Four sequential resolution phases:
 *  1. ADVANCE (chain bottleneck + suffix flex_down)
 *  2. DELAY (single-stage flex_up)
 *  3. PRECEDING_DELAY (conf stage-1)
 *  4. DELAY_PREV_PAST_NEXT (force order swap)
 *
 *  VAR_IN_OUT: ioSchedule, ioTask, ioBatch, ioLocks,
 *  ioLockCnt — caller passes live or workspace arrays.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION TSK_FC_Resolve : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iConfUnit               : INT;
  iConfStage              : INT;
  iConfTrans              : INT;
  iBlockedUnit            : INT;
  iBlockedStage           : INT;
  iDeficit                 : REAL;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 50=MAX_LOCKS, 10=MAX_UNITS, 3=MAX_TRANSPORTERS *)
  ioLocks                  : ARRAY[1..50] OF UDT_JC_TskLockType;
  ioLockCnt               : INT;
  ioSchedule               : ARRAY[1..10] OF UDT_JC_TskScheduleType;
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  ioBatch                  : ARRAY[1..10] OF UDT_BatchType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    SCH_TSK_FLEX_FACTOR     : REAL;
END_VAR

VAR_OUTPUT
  oSolved                  : BOOL;
  oTotalDelay             : REAL;
  oTotalAdv               : REAL;
END_VAR

VAR
  vRemain                    : REAL;
  vCap                       : REAL;
  vAmount                    : REAL;
  vStageFlex                : REAL;
  vIsLockedAdv             : BOOL;
  vIsLockedDel             : BOOL;
  vCanAdvance               : BOOL;
  vCanDelay                 : BOOL;
  vLockI                    : INT;
  vPrevConfStage           : INT;
  vIsPcsLocked             : BOOL;
  vPrevSinkStn             : INT;
  vNextLiftStn             : INT;
  vIsBlkAdvLocked         : BOOL;
  vQi                        : INT;
  vChainFlex                : REAL;
  vSuffixFlex               : REAL;
  vEarlierStg               : INT;
  vEarlierFlex              : REAL;
  vChainAmount              : REAL;
  vSuffixAmount             : REAL;
  vSchedBlocked             : INT;
  vSchedConf                : INT;
  vSchedPrevConf           : INT;
  vTmpSi                    : INT;
  vCapRemain                : REAL;
END_VAR

TSK_FC_Resolve := FALSE;
oSolved      := FALSE;
oTotalDelay := 0.0;
oTotalAdv   := 0.0;
vRemain        := iDeficit;

IF vRemain <= 0.1 THEN
  oSolved := TRUE;
  TSK_FC_Resolve := TRUE;
  RETURN;
END_IF;

(* Lock check: blocked stage locked DELAY? cannot ADVANCE *)
vIsLockedAdv := FALSE;
FOR vLockI := 1 TO ioLockCnt DO
  IF ioLocks[vLockI].Unit = iBlockedUnit
     AND ioLocks[vLockI].Stage = iBlockedStage
     AND ioLocks[vLockI].Direction = 2 THEN
    vIsLockedAdv := TRUE;
  END_IF;
END_FOR;

(* Lock check: conf stage locked ADVANCE? cannot DELAY *)
vIsLockedDel := FALSE;
FOR vLockI := 1 TO ioLockCnt DO
  IF ioLocks[vLockI].Unit = iConfUnit
     AND ioLocks[vLockI].Stage = iConfStage
     AND ioLocks[vLockI].Direction = 1 THEN
    vIsLockedDel := TRUE;
  END_IF;
END_FOR;

vCanAdvance := NOT vIsLockedAdv;
vCanDelay   := NOT vIsLockedDel;

(* Map ProgramStage to schedule array index *)
vSchedBlocked := 0;
IF iBlockedUnit >= 1 AND iBlockedUnit <= MAX_UNITS THEN
  FOR vTmpSi := 1 TO ioSchedule[iBlockedUnit].StageCount DO
    IF ioSchedule[iBlockedUnit].Stages[vTmpSi].ProgramStage = iBlockedStage THEN
      vSchedBlocked := vTmpSi; EXIT;
    END_IF;
  END_FOR;
END_IF;

vSchedConf := 0;
IF iConfUnit >= 1 AND iConfUnit <= MAX_UNITS THEN
  FOR vTmpSi := 1 TO ioSchedule[iConfUnit].StageCount DO
    IF ioSchedule[iConfUnit].Stages[vTmpSi].ProgramStage = iConfStage THEN
      vSchedConf := vTmpSi; EXIT;
    END_IF;
  END_FOR;
END_IF;

(* ================================================================ *)
(* PHASE 1: ADVANCE -- advance blocked batch                       *)
(* ================================================================ *)
IF vCanAdvance
   AND iBlockedUnit >= 1 AND iBlockedUnit <= MAX_UNITS
   AND iBlockedStage >= 1 THEN
IF vSchedBlocked >= 1 AND vSchedBlocked <= ioSchedule[iBlockedUnit].StageCount THEN

  (* Absolute flex vCap: use (MaxTime - MinTime) range, not (CalcTime - MinTime).
     This prevents cumulative drift when CalcTime is adjusted across rounds. *)
  vStageFlex := DINT_TO_REAL(
    ioSchedule[iBlockedUnit].Stages[vSchedBlocked].MaxTime
    - ioSchedule[iBlockedUnit].Stages[vSchedBlocked].MinTime);
  IF vStageFlex < 0.0 THEN vStageFlex := 0.0; END_IF;
  vStageFlex := vStageFlex * SCH_TSK_FLEX_FACTOR;
  (* Cap to actual remaining advance room *)
  vCapRemain := DINT_TO_REAL(
    ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime
    - ioSchedule[iBlockedUnit].Stages[vSchedBlocked].MinTime);
  IF vCapRemain < 0.0 THEN vCapRemain := 0.0; END_IF;
  IF vStageFlex > vCapRemain THEN vStageFlex := vCapRemain; END_IF;

  IF vStageFlex > 0.1 THEN
    IF ioBatch[iBlockedUnit].CurStage = iBlockedStage THEN vCap := 0.9;
  ELSE vCap := 0.5; END_IF;

    (* Chain bottleneck search *)
    vChainFlex := vStageFlex;
    FOR vEarlierStg := 1 TO vSchedBlocked - 1 DO
      vEarlierFlex := DINT_TO_REAL(
        ioSchedule[iBlockedUnit].Stages[vEarlierStg].CalcTime
        - ioSchedule[iBlockedUnit].Stages[vEarlierStg].MinTime);
  IF vEarlierFlex < 0.0 THEN vEarlierFlex := 0.0; END_IF;
      IF vEarlierFlex > 0.0 AND vEarlierFlex < vChainFlex THEN
        vChainFlex := vEarlierFlex;
      END_IF;
    END_FOR;

    (* CHAIN_ADVANCE *)
    vChainAmount := vChainFlex * vCap;
  IF vChainAmount > vRemain THEN vChainAmount := vRemain; END_IF;

    IF vChainAmount > 0.1 THEN
      ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime :=
        ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime - REAL_TO_DINT(vChainAmount);
      ioSchedule[iBlockedUnit].Stages[vSchedBlocked].ExitTime :=
        ioSchedule[iBlockedUnit].Stages[vSchedBlocked].ExitTime - REAL_TO_LINT(vChainAmount);

      STC_FC_ShiftSchedule(iUnit := iBlockedUnit, iFromStage := iBlockedStage + 1,
                         iAmount := -vChainAmount, ioSchedule := ioSchedule, ioTask := ioTask);

      ioBatch[iBlockedUnit].CalTime :=
        ioBatch[iBlockedUnit].CalTime - REAL_TO_DINT(vChainAmount);
      IF ioBatch[iBlockedUnit].CalTime < ioBatch[iBlockedUnit].MinTime THEN
        ioBatch[iBlockedUnit].CalTime := ioBatch[iBlockedUnit].MinTime;
      END_IF;

      vRemain := vRemain - vChainAmount;
      oTotalAdv := oTotalAdv + vChainAmount;
    END_IF;

    (* SUFFIX_ADVANCE *)
    vSuffixFlex := vStageFlex - vChainFlex;
    IF vSuffixFlex > 0.1 AND vRemain > 0.1 THEN
      vSuffixAmount := vSuffixFlex * vCap;
  IF vSuffixAmount > vRemain THEN vSuffixAmount := vRemain; END_IF;

      IF vSuffixAmount > 0.1 THEN
        ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime :=
          ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime - REAL_TO_DINT(vSuffixAmount);
        ioSchedule[iBlockedUnit].Stages[vSchedBlocked].ExitTime :=
          ioSchedule[iBlockedUnit].Stages[vSchedBlocked].ExitTime - REAL_TO_LINT(vSuffixAmount);

        STC_FC_ShiftSchedule(iUnit := iBlockedUnit, iFromStage := iBlockedStage + 1,
                           iAmount := -vSuffixAmount, ioSchedule := ioSchedule, ioTask := ioTask);

        ioBatch[iBlockedUnit].CalTime :=
          ioBatch[iBlockedUnit].CalTime - REAL_TO_DINT(vSuffixAmount);
        IF ioBatch[iBlockedUnit].CalTime < ioBatch[iBlockedUnit].MinTime THEN
          ioBatch[iBlockedUnit].CalTime := ioBatch[iBlockedUnit].MinTime;
        END_IF;

        vRemain := vRemain - vSuffixAmount;
        oTotalAdv := oTotalAdv + vSuffixAmount;
      END_IF;
    END_IF;

    (* Record lock: ADVANCE on blocked stage *)
    IF ioLockCnt < 50 THEN
      ioLockCnt := ioLockCnt + 1;
      ioLocks[ioLockCnt].Unit := iBlockedUnit;
      ioLocks[ioLockCnt].Stage := iBlockedStage;
      ioLocks[ioLockCnt].Direction := 1;
    END_IF;

    IF vRemain <= 0.1 THEN
  oSolved := TRUE;
  TSK_FC_Resolve := TRUE; RETURN;
    END_IF;
  END_IF;
END_IF;
END_IF;

(* ================================================================ *)
(* PHASE 2: DELAY -- delay conflict batch                          *)
(* ================================================================ *)
IF vCanDelay AND vRemain > 0.1
   AND iConfUnit >= 1 AND iConfUnit <= MAX_UNITS
   AND iConfStage >= 1 THEN
IF vSchedConf >= 1 AND vSchedConf <= ioSchedule[iConfUnit].StageCount THEN

  (* Absolute flex vCap: use (MaxTime - MinTime) range, not (MaxTime - CalcTime).
     This prevents cumulative drift when CalcTime is adjusted across rounds. *)
  vStageFlex := DINT_TO_REAL(
    ioSchedule[iConfUnit].Stages[vSchedConf].MaxTime
    - ioSchedule[iConfUnit].Stages[vSchedConf].MinTime);
  IF vStageFlex < 0.0 THEN vStageFlex := 0.0; END_IF;
  vStageFlex := vStageFlex * SCH_TSK_FLEX_FACTOR;
  (* Cap to actual remaining delay room *)
  vCapRemain := DINT_TO_REAL(
    ioSchedule[iConfUnit].Stages[vSchedConf].MaxTime
    - ioSchedule[iConfUnit].Stages[vSchedConf].CalcTime);
  IF vCapRemain < 0.0 THEN vCapRemain := 0.0; END_IF;
  IF vStageFlex > vCapRemain THEN vStageFlex := vCapRemain; END_IF;

  IF vStageFlex > 0.1 THEN
    IF ioBatch[iConfUnit].CurStage = iConfStage THEN vCap := 0.9;
  ELSE vCap := 0.5; END_IF;
    vAmount := vStageFlex * vCap;
  IF vAmount > vRemain THEN vAmount := vRemain; END_IF;

    ioSchedule[iConfUnit].Stages[vSchedConf].CalcTime :=
      ioSchedule[iConfUnit].Stages[vSchedConf].CalcTime + REAL_TO_DINT(vAmount);
    ioSchedule[iConfUnit].Stages[vSchedConf].ExitTime :=
      ioSchedule[iConfUnit].Stages[vSchedConf].ExitTime + REAL_TO_LINT(vAmount);

    STC_FC_ShiftSchedule(iUnit := iConfUnit, iFromStage := iConfStage + 1,
                       iAmount := vAmount, ioSchedule := ioSchedule, ioTask := ioTask);

    IF ioBatch[iConfUnit].CurStage = iConfStage THEN
      ioBatch[iConfUnit].CalTime :=
        ioBatch[iConfUnit].CalTime + REAL_TO_DINT(vAmount);
      IF ioBatch[iConfUnit].CalTime > ioBatch[iConfUnit].MaxTime THEN
        ioBatch[iConfUnit].CalTime := ioBatch[iConfUnit].MaxTime;
      END_IF;
    END_IF;

    vRemain := vRemain - vAmount;
    oTotalDelay := oTotalDelay + vAmount;

    IF ioLockCnt < 50 THEN
      ioLockCnt := ioLockCnt + 1;
      ioLocks[ioLockCnt].Unit := iConfUnit;
      ioLocks[ioLockCnt].Stage := iConfStage;
      ioLocks[ioLockCnt].Direction := 2;
    END_IF;

    IF vRemain <= 0.1 THEN
  oSolved := TRUE;
  TSK_FC_Resolve := TRUE; RETURN;
    END_IF;
  END_IF;
END_IF;
END_IF;

(* ================================================================ *)
(* PHASE 3: PRECEDING_DELAY -- delay conf batch at stage-1         *)
(* ================================================================ *)
vPrevConfStage := iConfStage - 1;

vSchedPrevConf := 0;
IF iConfUnit >= 1 AND iConfUnit <= MAX_UNITS AND vPrevConfStage >= 1 THEN
  FOR vTmpSi := 1 TO ioSchedule[iConfUnit].StageCount DO
    IF ioSchedule[iConfUnit].Stages[vTmpSi].ProgramStage = vPrevConfStage THEN
  vSchedPrevConf := vTmpSi; EXIT;
    END_IF;
  END_FOR;
END_IF;

IF vRemain > 0.1 AND vPrevConfStage >= 1 AND iConfUnit >= 1 AND iConfUnit <= MAX_UNITS
   AND vSchedPrevConf >= 1 THEN
  vIsPcsLocked := FALSE;
  FOR vLockI := 1 TO ioLockCnt DO
    IF ioLocks[vLockI].Unit = iConfUnit
       AND ioLocks[vLockI].Stage = vPrevConfStage
       AND ioLocks[vLockI].Direction = 1 THEN
      vIsPcsLocked := TRUE;
    END_IF;
  END_FOR;

  IF NOT vIsPcsLocked THEN
    (* Flex vCap: min + factor × (max - min); available room = flex_cap - CalcTime *)
    vStageFlex := DINT_TO_REAL(
      ioSchedule[iConfUnit].Stages[vSchedPrevConf].MinTime
      + REAL_TO_DINT(SCH_TSK_FLEX_FACTOR * DINT_TO_REAL(
          ioSchedule[iConfUnit].Stages[vSchedPrevConf].MaxTime
        - ioSchedule[iConfUnit].Stages[vSchedPrevConf].MinTime))
      - ioSchedule[iConfUnit].Stages[vSchedPrevConf].CalcTime);
  IF vStageFlex < 0.0 THEN vStageFlex := 0.0; END_IF;

    IF vStageFlex > 0.1 THEN
      IF ioBatch[iConfUnit].CurStage = vPrevConfStage THEN vCap := 0.9;
  ELSE vCap := 0.5; END_IF;
      vAmount := vStageFlex * vCap;
  IF vAmount > vRemain THEN vAmount := vRemain; END_IF;

      ioSchedule[iConfUnit].Stages[vSchedPrevConf].CalcTime :=
        ioSchedule[iConfUnit].Stages[vSchedPrevConf].CalcTime + REAL_TO_DINT(vAmount);
      ioSchedule[iConfUnit].Stages[vSchedPrevConf].ExitTime :=
        ioSchedule[iConfUnit].Stages[vSchedPrevConf].ExitTime + REAL_TO_LINT(vAmount);
      STC_FC_ShiftSchedule(iUnit := iConfUnit, iFromStage := vPrevConfStage + 1,
                         iAmount := vAmount, ioSchedule := ioSchedule, ioTask := ioTask);

      IF ioBatch[iConfUnit].CurStage = iConfStage THEN
        ioBatch[iConfUnit].CalTime :=
          ioBatch[iConfUnit].CalTime + REAL_TO_DINT(vAmount);
        IF ioBatch[iConfUnit].CalTime > ioBatch[iConfUnit].MaxTime THEN
          ioBatch[iConfUnit].CalTime := ioBatch[iConfUnit].MaxTime;
        END_IF;
      END_IF;

      vRemain := vRemain - vAmount;
      oTotalDelay := oTotalDelay + vAmount;

      IF ioLockCnt < 50 THEN
        ioLockCnt := ioLockCnt + 1;
        ioLocks[ioLockCnt].Unit := iConfUnit;
        ioLocks[ioLockCnt].Stage := vPrevConfStage;
        ioLocks[ioLockCnt].Direction := 2;
      END_IF;

      IF vRemain <= 0.1 THEN
  oSolved := TRUE;
  TSK_FC_Resolve := TRUE; RETURN;
      END_IF;
    END_IF;
  END_IF;
END_IF;

(* ================================================================ *)
(* PHASE 4: DELAY_PREV_PAST_NEXT -- force order swap               *)
(* ================================================================ *)
IF vRemain > 0.1 AND iBlockedUnit >= 1 AND iBlockedUnit <= MAX_UNITS THEN
  vPrevSinkStn := 0;
  vNextLiftStn := 0;
  IF iConfTrans >= 1 AND iConfTrans <= MAX_TRANSPORTERS THEN
    FOR vQi := 1 TO ioTask[iConfTrans].Count DO
      IF ioTask[iConfTrans].Queue[vQi].Unit = iBlockedUnit
         AND ioTask[iConfTrans].Queue[vQi].Stage = iBlockedStage THEN
        vPrevSinkStn := ioTask[iConfTrans].Queue[vQi].SinkStationTarget;
      END_IF;
      IF ioTask[iConfTrans].Queue[vQi].Unit = iConfUnit
         AND ioTask[iConfTrans].Queue[vQi].Stage = iConfStage THEN
        vNextLiftStn := ioTask[iConfTrans].Queue[vQi].LiftStationTarget;
      END_IF;
    END_FOR;
  END_IF;

  IF NOT (vPrevSinkStn > 0 AND vNextLiftStn > 0 AND vPrevSinkStn = vNextLiftStn) THEN
    vIsBlkAdvLocked := FALSE;
    FOR vLockI := 1 TO ioLockCnt DO
      IF ioLocks[vLockI].Unit = iBlockedUnit
         AND ioLocks[vLockI].Stage = iBlockedStage
         AND ioLocks[vLockI].Direction = 1 THEN
        vIsBlkAdvLocked := TRUE;
      END_IF;
    END_FOR;

    IF NOT vIsBlkAdvLocked THEN
      (* Flex vCap: min + factor × (max - min); available room = flex_cap - CalcTime *)
      vStageFlex := DINT_TO_REAL(
        ioSchedule[iBlockedUnit].Stages[vSchedBlocked].MinTime
        + REAL_TO_DINT(SCH_TSK_FLEX_FACTOR * DINT_TO_REAL(
            ioSchedule[iBlockedUnit].Stages[vSchedBlocked].MaxTime
          - ioSchedule[iBlockedUnit].Stages[vSchedBlocked].MinTime))
        - ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime);
  IF vStageFlex < 0.0 THEN vStageFlex := 0.0; END_IF;

      IF vStageFlex > 0.1 THEN
        IF ioBatch[iBlockedUnit].CurStage = iBlockedStage THEN vCap := 0.9;
  ELSE vCap := 0.5; END_IF;
        vAmount := vStageFlex * vCap;
  IF vAmount > vRemain THEN vAmount := vRemain; END_IF;

        ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime :=
          ioSchedule[iBlockedUnit].Stages[vSchedBlocked].CalcTime + REAL_TO_DINT(vAmount);
        ioSchedule[iBlockedUnit].Stages[vSchedBlocked].ExitTime :=
          ioSchedule[iBlockedUnit].Stages[vSchedBlocked].ExitTime + REAL_TO_LINT(vAmount);
        STC_FC_ShiftSchedule(iUnit := iBlockedUnit, iFromStage := iBlockedStage + 1,
                           iAmount := vAmount, ioSchedule := ioSchedule, ioTask := ioTask);

        IF ioBatch[iBlockedUnit].CurStage = iBlockedStage THEN
          ioBatch[iBlockedUnit].CalTime :=
            ioBatch[iBlockedUnit].CalTime + REAL_TO_DINT(vAmount);
          IF ioBatch[iBlockedUnit].CalTime > ioBatch[iBlockedUnit].MaxTime THEN
            ioBatch[iBlockedUnit].CalTime := ioBatch[iBlockedUnit].MaxTime;
          END_IF;
        END_IF;

        vRemain := vRemain - vAmount;
        oTotalDelay := oTotalDelay + vAmount;

        IF ioLockCnt < 50 THEN
          ioLockCnt := ioLockCnt + 1;
          ioLocks[ioLockCnt].Unit := iBlockedUnit;
          ioLocks[ioLockCnt].Stage := iBlockedStage;
          ioLocks[ioLockCnt].Direction := 2;
        END_IF;

        IF vRemain <= 0.1 THEN
  oSolved := TRUE;
  TSK_FC_Resolve := TRUE; RETURN;
        END_IF;
      END_IF;
    END_IF;
  END_IF;
END_IF;

END_FUNCTION

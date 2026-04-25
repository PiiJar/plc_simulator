(* ===========================================================================================
 *  FC_DEP_FitTaskToSlot — Fit a departure task into idle slots
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Reads idle slots and move times.
 *  Returns fit result via VAR_OUTPUT.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_DEP_FitTaskToSlot : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iLiftStn         : INT;
  iSinkStn         : INT;
  iTransId         : INT;
  iTaskStart       : LINT;
  iTaskEnd         : LINT;
  iShiftS          : REAL;
  iCalcTimeS       : DINT;
  iMinTimeS        : DINT;
  iMaxTimeS        : DINT;
  iFlexFactor      : REAL;
  iMarginS         : REAL;
  iConflictMarginS : REAL;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioIdleSlot : ARRAY[1..3] OF UDT_JC_DepIdleSlotSetType;
  ioResult   : UDT_JC_DepFitResultType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS      : INT;
    DEP_MAX_IDLE_SLOTS    : INT;
    SCH_DISPATCH_MARGIN_S : REAL;
END_VAR

VAR_EXTERNAL
  gMove : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
END_VAR

VAR
  vSi                : INT;
  vSlotCnt           : INT;
  vSlotStart         : LINT;
  vSlotEnd           : LINT;
  vFromStn           : INT;
  vToStn             : INT;
  vTravelTo          : REAL;
  vTravelFrom        : REAL;
  vEarliest          : LINT;
  vLatest            : LINT;
  vTaskDur           : LINT;
  vDelay             : REAL;
  vFlexUp            : REAL;
  vCappedFlex        : REAL;
  vBestDelay         : REAL;
  vBestSlot          : INT;
  vFound             : BOOL;
  vOverflowBestDelay : REAL;
  vOverflowBestSlot  : INT;
  vTmpMove           : UDT_JC_MoveTimesType;
  vTotalDelay        : REAL;
END_VAR

ioResult.Fits         := FALSE;
ioResult.DelayTime    := 0;
ioResult.NeedExtraTime := 0;
ioResult.TaskEndTime  := 0;
ioResult.SlotIdx      := 0;
ioResult.OverflowSlotIdx := 0;
ioResult.TransporterId := iTransId;
FC_DEP_FitTaskToSlot := FALSE;

IF iTransId < 1 OR iTransId > MAX_TRANSPORTERS THEN RETURN; END_IF;

vTaskDur   := iTaskEnd - iTaskStart;
(* Absolute cap: flex based on full (max - min) range, not (max - calc).
   This prevents cumulative drift when CalcTime is vAdjusted across rounds. *)
vFlexUp    := DINT_TO_REAL(iMaxTimeS - iMinTimeS);
  IF vFlexUp < 0.0 THEN vFlexUp := 0.0; END_IF;
vCappedFlex := vFlexUp * iFlexFactor;

vSlotCnt   := ioIdleSlot[iTransId].Count;
vBestDelay := 1.0E9;
vBestSlot  := 0;
vFound      := FALSE;
vOverflowBestDelay := 1.0E9;
vOverflowBestSlot  := 0;

vTmpMove := gMove[iTransId];
FOR vSi := 1 TO DEP_MAX_IDLE_SLOTS DO
  IF vSi > vSlotCnt THEN EXIT; END_IF;

  vSlotStart := ioIdleSlot[iTransId].Slots[vSi].StartTime;
  vSlotEnd   := ioIdleSlot[iTransId].Slots[vSi].EndTime;

  vFromStn := ioIdleSlot[iTransId].Slots[vSi].LiftStationTarget;
  vTravelTo := 0.0;
  IF vFromStn > 0 AND vFromStn <> iLiftStn THEN
    vTravelTo := FC_STC_CalcHorizontalTravel(iFromStn := vFromStn, iToStn := iLiftStn, iMove := vTmpMove);
  END_IF;

  vToStn := ioIdleSlot[iTransId].Slots[vSi].SinkStationTarget;
  vTravelFrom := 0.0;
  IF vToStn > 0 AND vToStn <> iSinkStn THEN
    vTravelFrom := FC_STC_CalcHorizontalTravel(iFromStn := iSinkStn, iToStn := vToStn, iMove := vTmpMove);
  END_IF;

  (* vEarliest = max(transporter arrival, task readiness) + vConflict margin *)
  IF (vSlotStart + REAL_TO_LINT(vTravelTo)) > (iTaskStart + REAL_TO_LINT(iShiftS)) THEN
    vEarliest := vSlotStart + REAL_TO_LINT(vTravelTo + iConflictMarginS);
  ELSE
    vEarliest := iTaskStart + REAL_TO_LINT(iShiftS + iConflictMarginS);
  END_IF;

  IF vSlotEnd > LINT#9000000000 THEN
    vLatest := LINT#9000000000;
  ELSE
    vLatest := vSlotEnd - REAL_TO_LINT(vTravelFrom + SCH_DISPATCH_MARGIN_S);
  END_IF;

  IF vEarliest + vTaskDur <= vLatest THEN
    vDelay := LINT_TO_REAL(vEarliest - iTaskStart) - iShiftS;
  IF vDelay < 0.0 THEN vDelay := 0.0; END_IF;
    vTotalDelay := iShiftS + vDelay;

    IF vTotalDelay <= iMarginS OR vTotalDelay <= vCappedFlex + 1.0 THEN
      IF vDelay < vBestDelay THEN
        vBestDelay := vDelay;
        vBestSlot  := vSi;
        vFound      := TRUE;
      END_IF;
    ELSE
      IF vDelay < vOverflowBestDelay THEN
        vOverflowBestDelay := vDelay;
        vOverflowBestSlot  := vSi;
      END_IF;
    END_IF;
  END_IF;
END_FOR;

IF vFound THEN
  ioResult.Fits      := TRUE;
  ioResult.DelayTime := REAL_TO_DINT(vBestDelay);
  ioResult.SlotIdx   := vBestSlot;
  ioResult.TaskEndTime := iTaskStart + REAL_TO_LINT(iShiftS + vBestDelay) + vTaskDur;
  ioResult.NeedExtraTime := 0;
ELSE
  ioResult.Fits := FALSE;
  IF vOverflowBestDelay < 1.0E8 THEN
    ioResult.DelayTime     := REAL_TO_DINT(vOverflowBestDelay);
    ioResult.NeedExtraTime := REAL_TO_DINT(iShiftS + vOverflowBestDelay - vCappedFlex);
  IF ioResult.NeedExtraTime < 0 THEN ioResult.NeedExtraTime := 0; END_IF;
    ioResult.OverflowSlotIdx := vOverflowBestSlot;
  ELSE
    ioResult.NeedExtraTime := 0;
  END_IF;
END_IF;

FC_DEP_FitTaskToSlot := TRUE;

END_FUNCTION

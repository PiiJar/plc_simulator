(* ===========================================================================================
 *  DEP_FC_FitTaskToSlot — Fit a departure task into idle slots
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


FUNCTION DEP_FC_FitTaskToSlot : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iLiftStn                : INT;
  iSinkStn                : INT;
  iTransId                : INT;
  iTaskStart              : LINT;
  iTaskEnd                : LINT;
  iShiftS                 : REAL;
  iCalcTimeS             : DINT;
  iMinTimeS              : DINT;
  iMaxTimeS              : DINT;
  iFlexFactor             : REAL;
  iMarginS                : REAL;
  iConflictMarginS       : REAL;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioIdleSlot              : ARRAY[1..3] OF UDT_JC_DepIdleSlotSetType;
  ioOResult                  : UDT_JC_DepFitResultType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    DEP_MAX_IDLE_SLOTS      : INT;
    SCH_DISPATCH_MARGIN_S   : REAL;
END_VAR

VAR_EXTERNAL
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
END_VAR

VAR
  vSi                        : INT;
  vSlotCnt                  : INT;
  vSlotStart                : LINT;
  vSlotEnd                  : LINT;
  vFromStn                  : INT;
  vToStn                    : INT;
  vTravelTo                 : REAL;
  vTravelFrom               : REAL;
  vEarliest                  : LINT;
  vLatest                    : LINT;
  vTaskDur                  : LINT;
  vDelay                     : REAL;
  vFlexUp                   : REAL;
  vCappedFlex               : REAL;
  vBestDelay                : REAL;
  vBestSlot                 : INT;
  vFound                     : BOOL;
  vOverflowBestDelay       : REAL;
  vOverflowBestSlot        : INT;
  vTmpMove                  : UDT_JC_MoveTimesType;
  vTotalDelay               : REAL;
END_VAR

ioOResult.Fits         := FALSE;
ioOResult.DelayTime    := 0;
ioOResult.NeedExtraTime := 0;
ioOResult.TaskEndTime  := 0;
ioOResult.SlotIdx      := 0;
ioOResult.OverflowSlotIdx := 0;
ioOResult.TransporterId := iTransId;
DEP_FC_FitTaskToSlot := FALSE;

IF iTransId < 1 OR iTransId > MAX_TRANSPORTERS THEN RETURN; END_IF;

vTaskDur   := iTaskEnd - iTaskStart;
(* Absolute cap: flex based on full (max - min) range, not (max - calc).
   This prevents cumulative drift when CalcTime is adjusted across rounds. *)
vFlexUp    := DINT_TO_REAL(iMaxTimeS - iMinTimeS);
  IF vFlexUp < 0.0 THEN vFlexUp := 0.0; END_IF;
vCappedFlex := vFlexUp * iFlexFactor;

vSlotCnt   := ioIdleSlot[iTransId].Count;
vBestDelay := 1.0E9;
vBestSlot  := 0;
vFound      := FALSE;
vOverflowBestDelay := 1.0E9;
vOverflowBestSlot  := 0;

vTmpMove := Move[iTransId];
FOR vSi := 1 TO DEP_MAX_IDLE_SLOTS DO
  IF vSi > vSlotCnt THEN EXIT; END_IF;

  vSlotStart := ioIdleSlot[iTransId].Slots[vSi].StartTime;
  vSlotEnd   := ioIdleSlot[iTransId].Slots[vSi].EndTime;

  vFromStn := ioIdleSlot[iTransId].Slots[vSi].LiftStationTarget;
  vTravelTo := 0.0;
  IF vFromStn > 0 AND vFromStn <> iLiftStn THEN
    vTravelTo := STC_FC_CalcHorizontalTravel(iFromStn := vFromStn, iToStn := iLiftStn, iMove := vTmpMove);
  END_IF;

  vToStn := ioIdleSlot[iTransId].Slots[vSi].SinkStationTarget;
  vTravelFrom := 0.0;
  IF vToStn > 0 AND vToStn <> iSinkStn THEN
    vTravelFrom := STC_FC_CalcHorizontalTravel(iFromStn := iSinkStn, iToStn := vToStn, iMove := vTmpMove);
  END_IF;

  (* vEarliest = max(transporter arrival, task readiness) + conflict margin *)
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
  ioOResult.Fits      := TRUE;
  ioOResult.DelayTime := REAL_TO_DINT(vBestDelay);
  ioOResult.SlotIdx   := vBestSlot;
  ioOResult.TaskEndTime := iTaskStart + REAL_TO_LINT(iShiftS + vBestDelay) + vTaskDur;
  ioOResult.NeedExtraTime := 0;
ELSE
  ioOResult.Fits := FALSE;
  IF vOverflowBestDelay < 1.0E8 THEN
    ioOResult.DelayTime     := REAL_TO_DINT(vOverflowBestDelay);
    ioOResult.NeedExtraTime := REAL_TO_DINT(iShiftS + vOverflowBestDelay - vCappedFlex);
  IF ioOResult.NeedExtraTime < 0 THEN ioOResult.NeedExtraTime := 0; END_IF;
    ioOResult.OverflowSlotIdx := vOverflowBestSlot;
  ELSE
    ioOResult.NeedExtraTime := 0;
  END_IF;
END_IF;

DEP_FC_FitTaskToSlot := TRUE;

END_FUNCTION

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
  oResult                  : UDT_JC_DepFitResultType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    DEP_MAX_IDLE_SLOTS      : INT;
    SCH_DISPATCH_MARGIN_S   : REAL;
END_VAR

VAR_EXTERNAL
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
END_VAR

VAR
  si                        : INT;
  vSlotCnt                  : INT;
  vSlotStart                : LINT;
  vSlotEnd                  : LINT;
  vFromStn                  : INT;
  vToStn                    : INT;
  vTravelTo                 : REAL;
  vTravelFrom               : REAL;
  vEarliest                  : LINT;
  latest                    : LINT;
  vTaskDur                  : LINT;
  vDelay                     : REAL;
  vFlexUp                   : REAL;
  capped_flex               : REAL;
  vBestDelay                : REAL;
  vBestSlot                 : INT;
  vFound                     : BOOL;
  overflow_best_delay       : REAL;
  overflow_best_slot        : INT;
  vTmpMove                  : UDT_JC_MoveTimesType;
  vTotalDelay               : REAL;
END_VAR

oResult.Fits         := FALSE;
oResult.DelayTime    := 0;
oResult.NeedExtraTime := 0;
oResult.TaskEndTime  := 0;
oResult.SlotIdx      := 0;
oResult.OverflowSlotIdx := 0;
oResult.TransporterId := iTransId;
FC_DEP_FitTaskToSlot := FALSE;

IF iTransId < 1 OR iTransId > MAX_TRANSPORTERS THEN RETURN; END_IF;

vTaskDur   := iTaskEnd - iTaskStart;
(* Absolute cap: flex based on full (max - min) range, not (max - calc).
   This prevents cumulative drift when CalcTime is vAdjusted across rounds. *)
vFlexUp    := DINT_TO_REAL(iMaxTimeS - iMinTimeS);
  IF vFlexUp < 0.0 THEN vFlexUp := 0.0; END_IF;
capped_flex := vFlexUp * iFlexFactor;

vSlotCnt   := ioIdleSlot[iTransId].Count;
vBestDelay := 1.0E9;
vBestSlot  := 0;
vFound      := FALSE;
overflow_best_delay := 1.0E9;
overflow_best_slot  := 0;

vTmpMove := g_move[iTransId];
FOR si := 1 TO DEP_MAX_IDLE_SLOTS DO
  IF si > vSlotCnt THEN EXIT; END_IF;

  vSlotStart := ioIdleSlot[iTransId].Slots[si].StartTime;
  vSlotEnd   := ioIdleSlot[iTransId].Slots[si].EndTime;

  vFromStn := ioIdleSlot[iTransId].Slots[si].LiftStationTarget;
  vTravelTo := 0.0;
  IF vFromStn > 0 AND vFromStn <> iLiftStn THEN
    vTravelTo := FC_STC_CalcHorizontalTravel(iFromStn := vFromStn, iToStn := iLiftStn, iMove := vTmpMove);
  END_IF;

  vToStn := ioIdleSlot[iTransId].Slots[si].SinkStationTarget;
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
    latest := LINT#9000000000;
  ELSE
    latest := vSlotEnd - REAL_TO_LINT(vTravelFrom + SCH_DISPATCH_MARGIN_S);
  END_IF;

  IF vEarliest + vTaskDur <= latest THEN
    vDelay := LINT_TO_REAL(vEarliest - iTaskStart) - iShiftS;
  IF vDelay < 0.0 THEN vDelay := 0.0; END_IF;
    vTotalDelay := iShiftS + vDelay;

    IF vTotalDelay <= iMarginS OR vTotalDelay <= capped_flex + 1.0 THEN
      IF vDelay < vBestDelay THEN
        vBestDelay := vDelay;
        vBestSlot  := si;
        vFound      := TRUE;
      END_IF;
    ELSE
      IF vDelay < overflow_best_delay THEN
        overflow_best_delay := vDelay;
        overflow_best_slot  := si;
      END_IF;
    END_IF;
  END_IF;
END_FOR;

IF vFound THEN
  oResult.Fits      := TRUE;
  oResult.DelayTime := REAL_TO_DINT(vBestDelay);
  oResult.SlotIdx   := vBestSlot;
  oResult.TaskEndTime := iTaskStart + REAL_TO_LINT(iShiftS + vBestDelay) + vTaskDur;
  oResult.NeedExtraTime := 0;
ELSE
  oResult.Fits := FALSE;
  IF overflow_best_delay < 1.0E8 THEN
    oResult.DelayTime     := REAL_TO_DINT(overflow_best_delay);
    oResult.NeedExtraTime := REAL_TO_DINT(iShiftS + overflow_best_delay - capped_flex);
  IF oResult.NeedExtraTime < 0 THEN oResult.NeedExtraTime := 0; END_IF;
    oResult.OverflowSlotIdx := overflow_best_slot;
  ELSE
    oResult.NeedExtraTime := 0;
  END_IF;
END_IF;

FC_DEP_FitTaskToSlot := TRUE;

END_FUNCTION

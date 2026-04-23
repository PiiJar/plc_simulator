(* ===========================================================================================
 *  DEP_FC_OverlapDelay — Overlap conflict vDelay calculation
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Returns vDelay vNeeded to avoid overlap conflicts.
 *  Reads task queues via ioTask (sandbox or live).
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION DEP_FC_OverlapDelay : REAL   (* returns delay_s, 0 = no conflict *)


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iLiftStn                : INT;
  iSinkStn                : INT;
  iTransId                : INT;
  iTaskStart              : LINT;
  iTaskEnd                : LINT;
  iMarginS                : REAL;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  ioOverlap                : UDT_JC_DepOverlapType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    DEP_MAX_DELAY_ACTS      : INT;
END_VAR

VAR
  vLiftIsOverlap           : BOOL;
  vSinkIsOverlap           : BOOL;
  vRound                     : INT;
  vTi                        : INT;
  vQi                        : INT;
  vMaxConf                  : REAL;
  vTStart                   : LINT;
  vTEnd                     : LINT;
  vEStart                   : LINT;
  vEEnd                     : LINT;
  vELift                    : INT;
  vESink                    : INT;
  vHasOvlp                  : BOOL;
  vNeeded                    : REAL;
  vDelay                     : REAL;
END_VAR

vDelay := 0.0;

IF iLiftStn >= 0 AND iLiftStn <= 200 THEN
  vLiftIsOverlap := ioOverlap.Flags[iLiftStn];
ELSE
  vLiftIsOverlap := FALSE;
END_IF;
IF iSinkStn >= 0 AND iSinkStn <= 200 THEN
  vSinkIsOverlap := ioOverlap.Flags[iSinkStn];
ELSE
  vSinkIsOverlap := FALSE;
END_IF;

IF NOT vLiftIsOverlap AND NOT vSinkIsOverlap THEN
  DEP_FC_OverlapDelay := 0.0;
  RETURN;
END_IF;

FOR vRound := 1 TO DEP_MAX_DELAY_ACTS DO
  vMaxConf := 0.0;
  vTStart  := iTaskStart + REAL_TO_LINT(vDelay);
  vTEnd    := iTaskEnd + REAL_TO_LINT(vDelay);

  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    IF vTi <> iTransId THEN
      FOR vQi := 1 TO MAX_UNITS DO
        IF vQi > ioTask[vTi].Count THEN EXIT; END_IF;

        vELift  := ioTask[vTi].Queue[vQi].LiftStationTarget;
        vESink  := ioTask[vTi].Queue[vQi].SinkStationTarget;
        vEStart := ioTask[vTi].Queue[vQi].StartTime;
        vEEnd   := ioTask[vTi].Queue[vQi].FinishTime;

        vHasOvlp := FALSE;
        IF vELift >= 0 AND vELift <= 200 THEN
  IF ioOverlap.Flags[vELift] THEN vHasOvlp := TRUE; END_IF;
        END_IF;
        IF NOT vHasOvlp AND vESink >= 0 AND vESink <= 200 THEN
  IF ioOverlap.Flags[vESink] THEN vHasOvlp := TRUE; END_IF;
        END_IF;

        IF vHasOvlp THEN
          IF vTStart < (vEEnd + REAL_TO_LINT(iMarginS)) AND vTEnd > (vEStart - REAL_TO_LINT(iMarginS)) THEN
            vNeeded := LINT_TO_REAL(vEEnd - vTStart) + iMarginS;
  IF vNeeded > vMaxConf THEN vMaxConf := vNeeded; END_IF;
          END_IF;
        END_IF;

      END_FOR;
    END_IF;
  END_FOR;

  IF vMaxConf <= 0.0 THEN EXIT; END_IF;
  vDelay := vDelay + vMaxConf;
END_FOR;

DEP_FC_OverlapDelay := vDelay;

END_FUNCTION

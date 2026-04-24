(* ===========================================================================================
 *  FC_DEP_OverlapDelay — Overlap vConflict vDelay calculation
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


FUNCTION FC_DEP_OverlapDelay : REAL   (* returns delay_s, 0 = no vConflict *)


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
  ti                        : INT;
  qi                        : INT;
  vMaxConf                  : REAL;
  t_start                   : LINT;
  t_end                     : LINT;
  e_start                   : LINT;
  e_end                     : LINT;
  e_lift                    : INT;
  e_sink                    : INT;
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
  FC_DEP_OverlapDelay := 0.0;
  RETURN;
END_IF;

FOR vRound := 1 TO DEP_MAX_DELAY_ACTS DO
  vMaxConf := 0.0;
  t_start  := iTaskStart + REAL_TO_LINT(vDelay);
  t_end    := iTaskEnd + REAL_TO_LINT(vDelay);

  FOR ti := 1 TO MAX_TRANSPORTERS DO
    IF ti <> iTransId THEN
      FOR qi := 1 TO MAX_UNITS DO
        IF qi > ioTask[ti].Count THEN EXIT; END_IF;

        e_lift  := ioTask[ti].Queue[qi].LiftStationTarget;
        e_sink  := ioTask[ti].Queue[qi].SinkStationTarget;
        e_start := ioTask[ti].Queue[qi].StartTime;
        e_end   := ioTask[ti].Queue[qi].FinishTime;

        vHasOvlp := FALSE;
        IF e_lift >= 0 AND e_lift <= 200 THEN
  IF ioOverlap.Flags[e_lift] THEN vHasOvlp := TRUE; END_IF;
        END_IF;
        IF NOT vHasOvlp AND e_sink >= 0 AND e_sink <= 200 THEN
  IF ioOverlap.Flags[e_sink] THEN vHasOvlp := TRUE; END_IF;
        END_IF;

        IF vHasOvlp THEN
          IF t_start < (e_end + REAL_TO_LINT(iMarginS)) AND t_end > (e_start - REAL_TO_LINT(iMarginS)) THEN
            vNeeded := LINT_TO_REAL(e_end - t_start) + iMarginS;
  IF vNeeded > vMaxConf THEN vMaxConf := vNeeded; END_IF;
          END_IF;
        END_IF;

      END_FOR;
    END_IF;
  END_FOR;

  IF vMaxConf <= 0.0 THEN EXIT; END_IF;
  vDelay := vDelay + vMaxConf;
END_FOR;

FC_DEP_OverlapDelay := vDelay;

END_FUNCTION

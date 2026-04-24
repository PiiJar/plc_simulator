(* ===========================================================================================
 *  DEP_OverlapDelay — Overlap conflict delay calculation
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Returns delay needed to avoid overlap conflicts.
 *  Reads task queues via io_task (sandbox or live).
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION DEP_OverlapDelay : REAL   (* returns delay_s, 0 = no conflict *)


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_lift_stn                : INT;
  i_sink_stn                : INT;
  i_trans_id                : INT;
  i_task_start              : LINT;
  i_task_end                : LINT;
  i_margin_s                : REAL;
END_VAR

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  io_task                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
  io_overlap                : UDT_JC_DepOverlapType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MAX_UNITS               : INT;
    DEP_MAX_DELAY_ACTS      : INT;
END_VAR

VAR
  lift_is_overlap           : BOOL;
  sink_is_overlap           : BOOL;
  round                     : INT;
  ti                        : INT;
  qi                        : INT;
  max_conf                  : REAL;
  t_start                   : LINT;
  t_end                     : LINT;
  e_start                   : LINT;
  e_end                     : LINT;
  e_lift                    : INT;
  e_sink                    : INT;
  has_ovlp                  : BOOL;
  needed                    : REAL;
  delay                     : REAL;
END_VAR

delay := 0.0;

IF i_lift_stn >= 0 AND i_lift_stn <= 200 THEN
  lift_is_overlap := io_overlap.Flags[i_lift_stn];
ELSE
  lift_is_overlap := FALSE;
END_IF;
IF i_sink_stn >= 0 AND i_sink_stn <= 200 THEN
  sink_is_overlap := io_overlap.Flags[i_sink_stn];
ELSE
  sink_is_overlap := FALSE;
END_IF;

IF NOT lift_is_overlap AND NOT sink_is_overlap THEN
  DEP_OverlapDelay := 0.0;
  RETURN;
END_IF;

FOR round := 1 TO DEP_MAX_DELAY_ACTS DO
  max_conf := 0.0;
  t_start  := i_task_start + REAL_TO_LINT(delay);
  t_end    := i_task_end + REAL_TO_LINT(delay);

  FOR ti := 1 TO MAX_TRANSPORTERS DO
    IF ti <> i_trans_id THEN
      FOR qi := 1 TO MAX_UNITS DO
        IF qi > io_task[ti].Count THEN EXIT; END_IF;

        e_lift  := io_task[ti].Queue[qi].LiftStationTarget;
        e_sink  := io_task[ti].Queue[qi].SinkStationTarget;
        e_start := io_task[ti].Queue[qi].StartTime;
        e_end   := io_task[ti].Queue[qi].FinishTime;

        has_ovlp := FALSE;
        IF e_lift >= 0 AND e_lift <= 200 THEN
  IF io_overlap.Flags[e_lift] THEN has_ovlp := TRUE; END_IF;
        END_IF;
        IF NOT has_ovlp AND e_sink >= 0 AND e_sink <= 200 THEN
  IF io_overlap.Flags[e_sink] THEN has_ovlp := TRUE; END_IF;
        END_IF;

        IF has_ovlp THEN
          IF t_start < (e_end + REAL_TO_LINT(i_margin_s)) AND t_end > (e_start - REAL_TO_LINT(i_margin_s)) THEN
            needed := LINT_TO_REAL(e_end - t_start) + i_margin_s;
  IF needed > max_conf THEN max_conf := needed; END_IF;
          END_IF;
        END_IF;

      END_FOR;
    END_IF;
  END_FOR;

  IF max_conf <= 0.0 THEN EXIT; END_IF;
  delay := delay + max_conf;
END_FOR;

DEP_OverlapDelay := delay;

END_FUNCTION

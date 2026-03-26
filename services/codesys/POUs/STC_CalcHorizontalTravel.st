(* ===========================================================================================
 *  STC_CalcHorizontalTravel — Horizontal travel time
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Calculates horizontal travel time between two stations
 *  (no lift/sink) using precomputed move time table.
 *  Caller passes i_move (UDT_JC_MoveTimesType) for the
 *  specific transporter.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_CalcHorizontalTravel : REAL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_from_stn                : INT;     (* source station number *)
  i_to_stn                  : INT;     (* destination station number *)
  i_move                    : UDT_JC_MoveTimesType;   (* transporter's precomputed move times *)
END_VAR

VAR
  from_idx                  : INT;
  to_idx                    : INT;
END_VAR

STC_CalcHorizontalTravel := 0.0;
IF i_from_stn > 0 AND i_to_stn > 0 AND i_from_stn <> i_to_stn THEN
  from_idx := i_from_stn - 100;
  to_idx   := i_to_stn - 100;
  IF from_idx >= 1 AND from_idx <= 25 AND to_idx >= 1 AND to_idx <= 25 THEN
    STC_CalcHorizontalTravel := INT_TO_REAL(i_move.Travel[from_idx].ToTime[to_idx]) / 10.0;
  END_IF;
END_IF;

END_FUNCTION

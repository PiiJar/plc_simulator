(* ===========================================================================================
 *  FC_STC_CalcHorizontalTravel — Horizontal vTravel time
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Calculates horizontal vTravel time between two stations
 *  (no lift/sink) using precomputed move time table.
 *  Caller passes iMove (UDT_JC_MoveTimesType) for the
 *  specific transporter.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_CalcHorizontalTravel : REAL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iFromStn : INT;     (* source station number *)
  iToStn   : INT;     (* destination station number *)
  iMove    : UDT_JC_MoveTimesType;   (* transporter's precomputed move times *)
END_VAR

VAR
  vFromIdx : INT;
  vToIdx   : INT;
END_VAR

FC_STC_CalcHorizontalTravel := 0.0;
IF iFromStn > 0 AND iToStn > 0 AND iFromStn <> iToStn THEN
  vFromIdx := iFromStn - MIN_STATION_INDEX;
  vToIdx   := iToStn - MIN_STATION_INDEX;
  IF vFromIdx >= 1 AND vFromIdx <= 25 AND vToIdx >= 1 AND vToIdx <= 25 THEN
    FC_STC_CalcHorizontalTravel := INT_TO_REAL(iMove.Travel[vFromIdx].ToTime[vToIdx]) / 10.0;
  END_IF;
END_IF;

END_FUNCTION

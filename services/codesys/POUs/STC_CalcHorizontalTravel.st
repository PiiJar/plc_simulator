(* ============================================================
   STC_CalcHorizontalTravel — Horizontal travel time (FUNCTION)
   ============================================================
   Calculates only the horizontal travel time between two stations
   (no lift/sink) using precomputed move time table.

   Converted from FUNCTION_BLOCK (STC_FB_CalcHorizontalTravel) to
   FUNCTION: the caller passes the specific transporter's
   UDT_JC_MoveTimesType instead of using VAR_EXTERNAL g_move.

   Used by: TSK_FB_Analyze, DEP_FB_FitTaskToSlot, DEP_FB_Scheduler,
            TSK_FB_NoTreatment
   ============================================================ *)

FUNCTION STC_CalcHorizontalTravel : REAL
VAR_INPUT
  i_from_stn : INT;     (* source station number *)
  i_to_stn   : INT;     (* destination station number *)
  i_move     : UDT_JC_MoveTimesType;   (* transporter's precomputed move times *)
END_VAR
VAR
  from_idx : INT;
  to_idx   : INT;
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

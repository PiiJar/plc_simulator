(* ===========================================================================================
 *  FC_STC_SwapTasks — Swap same-station task pairs
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Shared FC: both TSK and DEP call this with different arrays.
 *  Swaps adjacent tasks on the same transporter when the first
 *  task's sink equals the second task's lift (chain optimization).
 *  Returns swap count.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_SwapTasks : INT   (* returns swap count *)


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_IN_OUT  (* array sizes must match GVL_JC_Constants: 3=MAX_TRANSPORTERS *)
  ioTask                   : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
END_VAR

VAR
  vTi                        : INT;
  vQi                        : INT;
  vCnt                       : INT;
  vTmp                       : UDT_JC_TskTaskType;
  vSwaps                     : INT;
END_VAR

vSwaps := 0;

FOR vTi := 1 TO MAX_TRANSPORTERS DO
  vCnt := ioTask[vTi].Count;
  IF vCnt >= 2 THEN
    FOR vQi := 1 TO vCnt - 1 DO
      IF ioTask[vTi].Queue[vQi].Unit <> ioTask[vTi].Queue[vQi + 1].Unit
         AND ioTask[vTi].Queue[vQi].SinkStationTarget = ioTask[vTi].Queue[vQi + 1].LiftStationTarget THEN
        vTmp := ioTask[vTi].Queue[vQi];
        ioTask[vTi].Queue[vQi] := ioTask[vTi].Queue[vQi + 1];
        ioTask[vTi].Queue[vQi + 1] := vTmp;
        vSwaps := vSwaps + 1;
      END_IF;
    END_FOR;
  END_IF;
END_FOR;

FC_STC_SwapTasks := vSwaps;

END_FUNCTION

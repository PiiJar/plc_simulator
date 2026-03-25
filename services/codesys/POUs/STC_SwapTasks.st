(* ============================================================
   STC_SwapTasks — Swap same-station task pairs
   ============================================================
   Shared FC: both TSK and DEP call this with different arrays.
   Logic ported from transporterTaskScheduler.js swapSameStationTasks()
   ============================================================ *)

FUNCTION STC_SwapTasks : INT   (* returns swap count *)
VAR_IN_OUT
  io_task : ARRAY[1..3] OF UDT_JC_TskQueueType;
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
END_VAR
VAR
  ti     : INT;
  qi     : INT;
  cnt    : INT;
  tmp    : UDT_JC_TskTaskType;
  swaps  : INT;
END_VAR

swaps := 0;

FOR ti := 1 TO MAX_Transporters DO
  cnt := io_task[ti].Count;
  IF cnt >= 2 THEN
    FOR qi := 1 TO cnt - 1 DO
      IF io_task[ti].Queue[qi].Unit <> io_task[ti].Queue[qi + 1].Unit
         AND io_task[ti].Queue[qi].SinkStationTarget = io_task[ti].Queue[qi + 1].LiftStationTarget THEN
        tmp := io_task[ti].Queue[qi];
        io_task[ti].Queue[qi] := io_task[ti].Queue[qi + 1];
        io_task[ti].Queue[qi + 1] := tmp;
        swaps := swaps + 1;
      END_IF;
    END_FOR;
  END_IF;
END_FOR;

STC_SwapTasks := swaps;

END_FUNCTION

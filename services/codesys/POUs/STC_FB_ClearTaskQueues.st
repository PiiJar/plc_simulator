(* ============================================================
   STC_FB_ClearTaskQueues — Zero-out all transporter task queues
   ============================================================
   Clears count and all 9 fields of each slot in g_task[1..3].

   Replaces 2× identical clear loops in:
     TSK_FB_Scheduler (phase 2000)
     DEP_FB_Scheduler (phase 1020)
   ============================================================ *)

FUNCTION_BLOCK STC_FB_ClearTaskQueues
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MAX_Units        : INT;
    MAX_TASK_QUEUE   : INT;
END_VAR

VAR_EXTERNAL
  g_task : ARRAY[1..MAX_Transporters] OF UDT_JC_TskQueueType;
END_VAR
VAR
  ti : INT;
  qi : INT;
END_VAR

FOR ti := 1 TO MAX_Transporters DO
  g_task[ti].Count := 0;
  FOR qi := 1 TO MAX_TASK_QUEUE DO
    g_task[ti].Queue[qi].Unit         := 0;
    g_task[ti].Queue[qi].Stage        := 0;
    g_task[ti].Queue[qi].LiftStationTarget := 0;
    g_task[ti].Queue[qi].SinkStationTarget := 0;
    g_task[ti].Queue[qi].StartTime   := 0;
    g_task[ti].Queue[qi].FinishTime  := 0;
    g_task[ti].Queue[qi].CalcTime    := 0;
    g_task[ti].Queue[qi].MinTime     := 0;
    g_task[ti].Queue[qi].MaxTime     := 0;
  END_FOR;
END_FOR;

END_FUNCTION_BLOCK

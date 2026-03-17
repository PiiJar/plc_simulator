(* ============================================================
   DEP_FB_CalcOverlap — Overlap station detection
   ============================================================
   Identifies stations where multiple transporters can operate
   (task_area ranges overlap).  A station is marked as overlap
   if two or more different transporters have task_area ranges
   that cover it (either lift or sink range).

   Source: departureScheduler.js computeOverlapStations()

   Used by: DEP_FB_Scheduler (CALC phase)
   ============================================================ *)

FUNCTION_BLOCK DEP_FB_CalcOverlap
VAR_EXTERNAL CONSTANT
    MAX_Transporters    : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex   : INT;
END_VAR

VAR_EXTERNAL
  g_cfg         : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_dep_overlap : UDT_JC_DepOverlapType;
END_VAR
VAR
  station_idx         : INT;
  ti          : INT;
  ai          : INT;
  cover_count : INT;
  covered     : BOOL;
  area        : UDT_TaskArea;
END_VAR

g_dep_overlap.Count := 0;

(* G09: Clear full 0..200 domain first *)
FOR station_idx := 0 TO 200 DO
  g_dep_overlap.Flags[station_idx] := FALSE;
END_FOR;

FOR station_idx := MIN_StationIndex TO MAX_StationIndex DO
  cover_count := 0;

  FOR ti := 1 TO MAX_Transporters DO
    covered := FALSE;
    FOR ai := 1 TO 4 DO
      IF NOT covered THEN
        area := g_cfg[ti].TaskArea[ai];
        (* Station is covered if within lift OR sink range *)
        IF (area.MinLift > 0 AND station_idx >= area.MinLift AND station_idx <= area.MaxLift)
           OR (area.MinSink > 0 AND station_idx >= area.MinSink AND station_idx <= area.MaxSink) THEN
          covered := TRUE;
        END_IF;
      END_IF;
    END_FOR;
    IF covered THEN
      cover_count := cover_count + 1;
    END_IF;
  END_FOR;

  IF cover_count >= 2 THEN
    g_dep_overlap.Flags[station_idx] := TRUE;
    g_dep_overlap.Count := g_dep_overlap.Count + 1;
  ELSE
    g_dep_overlap.Flags[station_idx] := FALSE;
  END_IF;
END_FOR;

END_FUNCTION_BLOCK

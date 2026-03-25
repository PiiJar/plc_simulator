(* ============================================================
   DEP_CalcOverlap — Overlap station detection

   Company : Galvatek part of the John Cockerill Group
   Author  : Jarmo Piipponen
   Created : 25.03.2026
   ============================================================
   Identifies stations covered by 2+ transporters.
   Reads g_cfg (read-only config). Writes io_overlap.
   ------------------------------------------------------------
   Changes:
   ============================================================ *)

FUNCTION DEP_CalcOverlap : BOOL
VAR_IN_OUT
  io_overlap : UDT_JC_DepOverlapType;
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
    MIN_StationIndex : INT;
    MAX_StationIndex : INT;
END_VAR
VAR_EXTERNAL
  g_cfg : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
END_VAR
VAR
  station_idx : INT;
  ti          : INT;
  ai          : INT;
  cover_count : INT;
  covered     : BOOL;
  area        : UDT_TaskArea;
END_VAR

io_overlap.Count := 0;

FOR station_idx := 0 TO 200 DO
  io_overlap.Flags[station_idx] := FALSE;
END_FOR;

FOR station_idx := MIN_StationIndex TO MAX_StationIndex DO
  cover_count := 0;

  FOR ti := 1 TO MAX_Transporters DO
    covered := FALSE;
    FOR ai := 1 TO 4 DO
      IF NOT covered THEN
        area := g_cfg[ti].TaskArea[ai];
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
    io_overlap.Flags[station_idx] := TRUE;
    io_overlap.Count := io_overlap.Count + 1;
  END_IF;
END_FOR;

DEP_CalcOverlap := TRUE;

END_FUNCTION

(* ===========================================================================================
 *  FC_DEP_CalcOverlap — Overlap station detection
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Identifies stations vCovered by 2+ transporters.
 *  Reads Transporters (read-only config). Writes ioOverlap.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_DEP_CalcOverlap : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_IN_OUT
  ioOverlap : UDT_JC_DepOverlapType;
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS  : INT;
    MIN_STATION_INDEX : INT;
    MAX_STATION_INDEX : INT;
END_VAR

VAR_EXTERNAL
  Transporters : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
END_VAR

VAR
  vStationIdx : INT;
  vTi         : INT;
  vAi         : INT;
  vCoverCount : INT;
  vCovered    : BOOL;
  vArea       : UDT_TaskAreaType;
END_VAR

ioOverlap.Count := 0;

FOR vStationIdx := 0 TO 200 DO
  ioOverlap.Flags[vStationIdx] := FALSE;
END_FOR;

FOR vStationIdx := MIN_STATION_INDEX TO MAX_STATION_INDEX DO
  vCoverCount := 0;

  FOR vTi := 1 TO MAX_TRANSPORTERS DO
    vCovered := FALSE;
    FOR vAi := 1 TO 4 DO
      IF NOT vCovered THEN
        vArea := Transporters[vTi].TaskArea[vAi];
        IF (vArea.MinLift > 0 AND vStationIdx >= vArea.MinLift AND vStationIdx <= vArea.MaxLift)
           OR (vArea.MinSink > 0 AND vStationIdx >= vArea.MinSink AND vStationIdx <= vArea.MaxSink) THEN
          vCovered := TRUE;
        END_IF;
      END_IF;
    END_FOR;
    IF vCovered THEN
      vCoverCount := vCoverCount + 1;
    END_IF;
  END_FOR;

  IF vCoverCount >= 2 THEN
    ioOverlap.Flags[vStationIdx] := TRUE;
    ioOverlap.Count := ioOverlap.Count + 1;
  END_IF;
END_FOR;

FC_DEP_CalcOverlap := TRUE;

END_FUNCTION

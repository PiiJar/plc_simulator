(* ===========================================================================================
 *  STC_FB_FindTransporter — Find best covering transporter
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Finds which transporter (1..3) can handle a lift→sink pair
 *  by checking cfg[].TaskArea[] coverage.
 *
 *  When multiple transporters match, scores by:
 *  1. Fewest queued tasks (load balance)
 *  2. Closest last-sink to new lift (travel efficiency)
 *
 *  If iSinkStn = 0, only lift coverage is checked.
 *
 *  NOTE: Kept as FUNCTION_BLOCK because MATIEC cannot handle
 *  ARRAY OF STRUCT as FUNCTION VAR_INPUT parameter.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION_BLOCK STC_FB_FindTransporter


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iLiftStn                : INT;     (* lift station number *)
  iSinkStn                : INT;     (* sink station number, 0 = lift-only search *)
END_VAR

VAR_OUTPUT
  oTrans                   : INT;         (* transporter ID 1..3, 0 = not found *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
END_VAR

VAR_EXTERNAL
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  Task                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_TskQueueType;
END_VAR

VAR
  vTi                        : INT;
  vAi                        : INT;
  vArea                      : UDT_TaskAreaType;
  vCanLift                  : BOOL;
  vCanSink                  : BOOL;
  (* Multi-transporter scoring *)
  vCapable                   : ARRAY[1..3] OF INT;   (* vCapable transporter IDs *)
  vCapCount                 : INT;
  vBestIdx                  : INT;
  vBestCount                : INT;
  vBestDist                 : INT;
  vCurCount                 : INT;
  vCurDist                  : INT;
  vLastSink                 : INT;
  vCi                        : INT;
END_VAR

oTrans := 0;
vCapCount := 0;

(* Phase 1: Collect all vCapable transporters *)
FOR vTi := 1 TO MAX_TRANSPORTERS DO
  FOR vAi := 1 TO 4 DO
    IF vCapCount < 3 THEN
      vArea := Transporters[vTi].TaskArea[vAi];
      IF vArea.MinLift > 0 OR vArea.MaxLift > 0 THEN
        vCanLift := (iLiftStn >= vArea.MinLift) AND (iLiftStn <= vArea.MaxLift);
        IF iSinkStn = 0 THEN
          IF vCanLift THEN
            (* Check not already added — nested IF to avoid array bounds on vCapable[0] *)
            IF vCapCount = 0 THEN
              vCapCount := vCapCount + 1;
              vCapable[vCapCount] := vTi;
            ELSIF vCapable[vCapCount] <> vTi THEN
              vCapCount := vCapCount + 1;
              vCapable[vCapCount] := vTi;
            END_IF;
          END_IF;
        ELSE
          vCanSink := (iSinkStn >= vArea.MinSink) AND (iSinkStn <= vArea.MaxSink);
          IF vCanLift AND vCanSink THEN
            IF vCapCount = 0 THEN
              vCapCount := vCapCount + 1;
              vCapable[vCapCount] := vTi;
            ELSIF vCapable[vCapCount] <> vTi THEN
              vCapCount := vCapCount + 1;
              vCapable[vCapCount] := vTi;
            END_IF;
          END_IF;
        END_IF;
      END_IF;
    END_IF;
  END_FOR;
END_FOR;

(* Phase 2: Select best — score by task count then distance *)
IF vCapCount = 0 THEN
  oTrans := 0;
ELSIF vCapCount = 1 THEN
  oTrans := vCapable[1];
ELSE
  (* JS: scored.sort((a,b) => a.count - b.count || a.distFromLastTask - b.distFromLastTask) *)
  vBestIdx := 1;
  vBestCount := Task[vCapable[1]].Count;
  (* Find last sink station for first candidate *)
  vLastSink := 0;
  IF vBestCount > 0 THEN
    vLastSink := Task[vCapable[1]].Queue[vBestCount].SinkStationTarget;
  END_IF;
  IF vLastSink > 0 THEN
    vBestDist := ABS(vLastSink - iLiftStn);
  ELSE
    vBestDist := 0;
  END_IF;

  FOR vCi := 2 TO vCapCount DO
    vCurCount := Task[vCapable[vCi]].Count;
    vLastSink := 0;
    IF vCurCount > 0 THEN
      vLastSink := Task[vCapable[vCi]].Queue[vCurCount].SinkStationTarget;
    END_IF;
    IF vLastSink > 0 THEN
      vCurDist := ABS(vLastSink - iLiftStn);
    ELSE
      vCurDist := 0;
    END_IF;

    IF vCurCount < vBestCount THEN
      vBestIdx := vCi;
      vBestCount := vCurCount;
      vBestDist := vCurDist;
    ELSIF vCurCount = vBestCount AND vCurDist < vBestDist THEN
      vBestIdx := vCi;
      vBestCount := vCurCount;
      vBestDist := vCurDist;
    END_IF;
  END_FOR;

  oTrans := vCapable[vBestIdx];
END_IF;

END_FUNCTION_BLOCK

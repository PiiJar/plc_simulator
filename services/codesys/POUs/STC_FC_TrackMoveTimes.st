(* ===========================================================================================
 *  STC_FC_TrackMoveTimes — Record phase transition timestamps
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Called from SIM code at each transporter phase change.
 *  Uses Time100ms (0.1s ticks). On 4→0 completion,
 *  calculates net durations and updates Move[] with
 *  weighted average: new = (old * 4 + measured) / 5.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION STC_FC_TrackMoveTimes : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTrans                   : INT;   (* transporter index 1..MAX_TRANSPORTERS *)
  iPrev                    : INT;   (* previous phase *)
  iNew                     : INT;   (* new phase *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
END_VAR

VAR_EXTERNAL
  TransporterStatus             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  Move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  ActualMove             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ActualMoveTimeType;
  TimeS                  : LINT;
  Time100ms              : LINT;
END_VAR

VAR
  vT                         : INT;
  vLiftStn                  : INT;
  vSinkStn                  : INT;
  vStartStn                 : INT;
  vLi                        : INT;   (* lift station index = stn - 100 *)
  vSi                        : INT;   (* sink station index = stn - 100 *)
  vStI                      : INT;   (* start station index = stn - 100 *)
  vRawLift                  : INT;   (* measured lift duration in 0.1s ticks *)
  vRawSink                  : INT;   (* measured sink duration in 0.1s ticks *)
  vRawTrav1                 : INT;   (* measured travel start→lift in 0.1s ticks *)
  vRawTrav2                 : INT;   (* measured travel lift→sink in 0.1s ticks *)
  vDripX10                  : INT;   (* DrippingTime in 0.1s ticks from lift station *)
  vTrayX10                  : INT;   (* DripTrayDelay in 0.1s ticks from transporter config *)
  vDevX10                   : INT;   (* DeviceDelay in 0.1s ticks from sink station *)
END_VAR

vT := iTrans;

(* Bounds check *)
IF vT < 1 OR vT > MAX_TRANSPORTERS THEN
    RETURN;
END_IF;

CASE iPrev OF
    0: (* 0→1 : siirto nostoasemalle alkaa *)
        IF iNew = 1 THEN
            ActualMove[vT].StartStation := TransporterStatus[vT].CurrentStation;
            ActualMove[vT].LiftStation  := TransporterStatus[vT].LiftStationTarget;
            ActualMove[vT].SinkStation  := TransporterStatus[vT].SinkStationTarget;
            ActualMove[vT].ts0 := Time100ms;
            ActualMove[vT].Invalidated := FALSE;
        END_IF;
    1: (* 1→2 : nosto alkaa *)
        IF iNew = 2 THEN
            ActualMove[vT].ts1 := Time100ms;
        END_IF;
    2: (* 2→3 : siirto laskuasemalle alkaa *)
        IF iNew = 3 THEN
            ActualMove[vT].ts2 := Time100ms;
        END_IF;
    3: (* 3→4 : lasku alkaa *)
        IF iNew = 4 THEN
            ActualMove[vT].ts3 := Time100ms;
        END_IF;
    4: (* 4→0 : handled after CASE — see below *)
END_CASE;

(* ── Invalidate on anomaly (checked at every phase transition) ── *)
IF iNew > 0 THEN
    (* Not in automatic mode: task interrupted *)
    IF TransporterStatus[vT].Status < 4 THEN
        ActualMove[vT].Invalidated := TRUE;
    END_IF;
    (* Transporter fault active *)
    IF TransporterStatus[vT].Fault THEN
        ActualMove[vT].Invalidated := TRUE;
    END_IF;
END_IF;

(* ── 4→0 completion: calculate and update Move ── *)
IF iPrev = 4 AND iNew = 0 THEN
    ActualMove[vT].ts4 := Time100ms;

    (* Only update if all timestamps are valid and transfer was normal *)
    IF ActualMove[vT].ts0 > 0
       AND ActualMove[vT].ts1 > 0
       AND ActualMove[vT].ts2 > 0
       AND ActualMove[vT].ts3 > 0
       AND NOT ActualMove[vT].Invalidated
    THEN
                vLiftStn  := ActualMove[vT].LiftStation;
                vSinkStn  := ActualMove[vT].SinkStation;
                vStartStn := ActualMove[vT].StartStation;
                vLi   := vLiftStn  - MIN_STATION_INDEX;
                vSi   := vSinkStn  - MIN_STATION_INDEX;
                vStI := vStartStn - MIN_STATION_INDEX;

                (* Mechanical delays in 0.1s ticks *)
                vDripX10 := Stations[vLiftStn].DrippingTime;
                vTrayX10 := Transporters[vT].DripTrayDelay;
                vDevX10  := Stations[vSinkStn].DeviceDelay;

                (* Raw durations are already in 0.1s ticks *)
                vRawTrav1 := LINT_TO_INT(ActualMove[vT].ts1 - ActualMove[vT].ts0);
                vRawTrav2 := LINT_TO_INT(ActualMove[vT].ts3 - ActualMove[vT].ts2);

                (* Net lift = (ts2-ts1) - DrippingTime - DripTrayDelay *)
                vRawLift := LINT_TO_INT(ActualMove[vT].ts2 - ActualMove[vT].ts1)
                            - vDripX10 - vTrayX10;

                (* Net sink = (ts4-ts3) - DripTrayDelay - DeviceDelay *)
                vRawSink := LINT_TO_INT(ActualMove[vT].ts4 - ActualMove[vT].ts3)
                            - vTrayX10 - vDevX10;

                (* Clamp to minimum 0 *)
  IF vRawLift < 0 THEN vRawLift := 0; END_IF;
  IF vRawSink < 0 THEN vRawSink := 0; END_IF;
  IF vRawTrav1 < 0 THEN vRawTrav1 := 0; END_IF;
  IF vRawTrav2 < 0 THEN vRawTrav2 := 0; END_IF;

                (* Bounds check indices *)
                IF vLi >= 1 AND vLi <= 30
                   AND vSi >= 1 AND vSi <= 30
                   AND vStI >= 1 AND vStI <= 30
                THEN
                    (* Weighted average: new = (old * 4 + measured) / 5 *)

                    (* Lift time at lift station *)
                    Move[vT].LiftTime[vLi] :=
                        (Move[vT].LiftTime[vLi] * 4 + vRawLift) / 5;

                    (* Sink time at sink station *)
                    Move[vT].SinkTime[vSi] :=
                        (Move[vT].SinkTime[vSi] * 4 + vRawSink) / 5;

                    (* Travel: lift → sink (both directions) — phase 3 is always exact station-to-station *)
                    Move[vT].Travel[vLi].ToTime[vSi] :=
                        (Move[vT].Travel[vLi].ToTime[vSi] * 4 + vRawTrav2) / 5;
                    Move[vT].Travel[vSi].ToTime[vLi] :=
                        (Move[vT].Travel[vSi].ToTime[vLi] * 4 + vRawTrav2) / 5;
                END_IF;
            END_IF;
END_IF;

STC_FC_TrackMoveTimes := TRUE;

END_FUNCTION

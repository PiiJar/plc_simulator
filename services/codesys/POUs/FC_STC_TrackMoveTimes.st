(* ===========================================================================================
 *  FC_STC_TrackMoveTimes — Record vPhase transition timestamps
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Called from SIM code at each transporter vPhase change.
 *  Uses g_time_100ms (0.1s ticks). On 4→0 completion,
 *  calculates net durations and updates g_move[] with
 *  weighted average: new = (old * 4 + measured) / 5.
 *
 *  ------------------------------------------------------------------------------------------
 *
 *  Changes:
 *
 *
 *
 *)


FUNCTION FC_STC_TrackMoveTimes : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  iTrans                   : INT;   (* transporter index 1..MAX_TRANSPORTERS *)
  iPrev                    : INT;   (* previous vPhase *)
  iNew                     : INT;   (* new vPhase *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_TRANSPORTERS        : INT;
    MIN_STATION_INDEX        : INT;
    MAX_STATION_INDEX        : INT;
END_VAR

VAR_EXTERNAL
  g_transporter             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_TransporterStatusType;
  Stations                 : ARRAY[MIN_STATION_INDEX..MAX_STATION_INDEX] OF UDT_StationType;
  Transporters                     : ARRAY[0..MAX_TRANSPORTERS] OF UDT_TransporterType;
  g_move                    : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_MoveTimesType;
  g_actual_move             : ARRAY[1..MAX_TRANSPORTERS] OF UDT_JC_ActualMoveTimeType;
  g_time_s                  : LINT;
  g_time_100ms              : LINT;
END_VAR

VAR
  vT                         : INT;
  vLiftStn                  : INT;
  vSinkStn                  : INT;
  vStartStn                 : INT;
  vLi                        : INT;   (* lift station index = stn - 100 *)
  vSi                        : INT;   (* sink station index = stn - 100 *)
  vStI                      : INT;   (* start station index = stn - 100 *)
  vRawLift                  : INT;   (* measured lift vDuration in 0.1s ticks *)
  vRawSink                  : INT;   (* measured sink vDuration in 0.1s ticks *)
  vRawTrav1                 : INT;   (* measured vTravel start→lift in 0.1s ticks *)
  vRawTrav2                 : INT;   (* measured vTravel lift→sink in 0.1s ticks *)
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
            g_actual_move[vT].StartStation := g_transporter[vT].CurrentStation;
            g_actual_move[vT].LiftStation  := g_transporter[vT].LiftStationTarget;
            g_actual_move[vT].SinkStation  := g_transporter[vT].SinkStationTarget;
            g_actual_move[vT].Ts0 := g_time_100ms;
            g_actual_move[vT].Invalidated := FALSE;
        END_IF;
    1: (* 1→2 : nosto alkaa *)
        IF iNew = 2 THEN
            g_actual_move[vT].Ts1 := g_time_100ms;
        END_IF;
    2: (* 2→3 : siirto laskuasemalle alkaa *)
        IF iNew = 3 THEN
            g_actual_move[vT].Ts2 := g_time_100ms;
        END_IF;
    3: (* 3→4 : lasku alkaa *)
        IF iNew = 4 THEN
            g_actual_move[vT].Ts3 := g_time_100ms;
        END_IF;
    4: (* 4→0 : handled after CASE — see below *)
END_CASE;

(* ── Invalidate on anomaly (checked at every vPhase transition) ── *)
IF iNew > 0 THEN
    (* Not in automatic mode: task interrupted *)
    IF g_transporter[vT].Status < 4 THEN
        g_actual_move[vT].Invalidated := TRUE;
    END_IF;
    (* Transporter fault active *)
    IF g_transporter[vT].Fault THEN
        g_actual_move[vT].Invalidated := TRUE;
    END_IF;
END_IF;

(* ── 4→0 completion: calculate and update g_move ── *)
IF iPrev = 4 AND iNew = 0 THEN
    g_actual_move[vT].Ts4 := g_time_100ms;

    (* Only update if all timestamps are valid and transfer was normal *)
    IF g_actual_move[vT].Ts0 > 0
       AND g_actual_move[vT].Ts1 > 0
       AND g_actual_move[vT].Ts2 > 0
       AND g_actual_move[vT].Ts3 > 0
       AND NOT g_actual_move[vT].Invalidated
    THEN
                vLiftStn  := g_actual_move[vT].LiftStation;
                vSinkStn  := g_actual_move[vT].SinkStation;
                vStartStn := g_actual_move[vT].StartStation;
                vLi   := vLiftStn  - MIN_STATION_INDEX;
                vSi   := vSinkStn  - MIN_STATION_INDEX;
                vStI := vStartStn - MIN_STATION_INDEX;

                (* Mechanical delays in 0.1s ticks *)
                vDripX10 := Stations[vLiftStn].DrippingTime;
                vTrayX10 := Transporters[vT].DripTrayDelay;
                vDevX10  := Stations[vSinkStn].DeviceDelay;

                (* Raw durations are vAlready in 0.1s ticks *)
                vRawTrav1 := LINT_TO_INT(g_actual_move[vT].Ts1 - g_actual_move[vT].Ts0);
                vRawTrav2 := LINT_TO_INT(g_actual_move[vT].Ts3 - g_actual_move[vT].Ts2);

                (* Net lift = (Ts2-Ts1) - DrippingTime - DripTrayDelay *)
                vRawLift := LINT_TO_INT(g_actual_move[vT].Ts2 - g_actual_move[vT].Ts1)
                            - vDripX10 - vTrayX10;

                (* Net sink = (Ts4-Ts3) - DripTrayDelay - DeviceDelay *)
                vRawSink := LINT_TO_INT(g_actual_move[vT].Ts4 - g_actual_move[vT].Ts3)
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
                    g_move[vT].LiftTime[vLi] :=
                        (g_move[vT].LiftTime[vLi] * 4 + vRawLift) / 5;

                    (* Sink time at sink station *)
                    g_move[vT].SinkTime[vSi] :=
                        (g_move[vT].SinkTime[vSi] * 4 + vRawSink) / 5;

                    (* Travel: lift → sink (both directions) — vPhase 3 is always exact station-to-station *)
                    g_move[vT].Travel[vLi].ToTime[vSi] :=
                        (g_move[vT].Travel[vLi].ToTime[vSi] * 4 + vRawTrav2) / 5;
                    g_move[vT].Travel[vSi].ToTime[vLi] :=
                        (g_move[vT].Travel[vSi].ToTime[vLi] * 4 + vRawTrav2) / 5;
                END_IF;
            END_IF;
END_IF;

FC_STC_TrackMoveTimes := TRUE;

END_FUNCTION

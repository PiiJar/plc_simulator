(* ===========================================================================================
 *  STC_TrackMoveTimes — Record phase transition timestamps
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Called from SIM code at each transporter phase change.
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


FUNCTION STC_TrackMoveTimes : BOOL


(* Introduction of Variables ----------------------------------------------------------------*)

VAR_INPUT
  i_trans                   : INT;   (* transporter index 1..MAX_Transporters *)
  i_prev                    : INT;   (* previous phase *)
  i_new                     : INT;   (* new phase *)
END_VAR

VAR_EXTERNAL CONSTANT
    MAX_Transporters        : INT;
    MIN_StationIndex        : INT;
    MAX_StationIndex        : INT;
END_VAR

VAR_EXTERNAL
  g_transporter             : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
  g_station                 : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;
  g_cfg                     : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
  g_move                    : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
  g_actual_move             : ARRAY[1..MAX_Transporters] OF UDT_JC_ActualMoveTimeType;
  g_time_s                  : LINT;
  g_time_100ms              : LINT;
END_VAR

VAR
  t                         : INT;
  lift_stn                  : INT;
  sink_stn                  : INT;
  start_stn                 : INT;
  li                        : INT;   (* lift station index = stn - 100 *)
  si                        : INT;   (* sink station index = stn - 100 *)
  st_i                      : INT;   (* start station index = stn - 100 *)
  raw_lift                  : INT;   (* measured lift duration in 0.1s ticks *)
  raw_sink                  : INT;   (* measured sink duration in 0.1s ticks *)
  raw_trav1                 : INT;   (* measured travel start→lift in 0.1s ticks *)
  raw_trav2                 : INT;   (* measured travel lift→sink in 0.1s ticks *)
  drip_x10                  : INT;   (* DrippingTime in 0.1s ticks from lift station *)
  tray_x10                  : INT;   (* DripTrayDelay in 0.1s ticks from transporter config *)
  dev_x10                   : INT;   (* DeviceDelay in 0.1s ticks from sink station *)
END_VAR

t := i_trans;

(* Bounds check *)
IF t < 1 OR t > MAX_Transporters THEN
    RETURN;
END_IF;

CASE i_prev OF
    0: (* 0→1 : siirto nostoasemalle alkaa *)
        IF i_new = 1 THEN
            g_actual_move[t].StartStation := g_transporter[t].CurrentStation;
            g_actual_move[t].LiftStation  := g_transporter[t].LiftStationTarget;
            g_actual_move[t].SinkStation  := g_transporter[t].SinkStationTarget;
            g_actual_move[t].ts0 := g_time_100ms;
            g_actual_move[t].Invalidated := FALSE;
        END_IF;
    1: (* 1→2 : nosto alkaa *)
        IF i_new = 2 THEN
            g_actual_move[t].ts1 := g_time_100ms;
        END_IF;
    2: (* 2→3 : siirto laskuasemalle alkaa *)
        IF i_new = 3 THEN
            g_actual_move[t].ts2 := g_time_100ms;
        END_IF;
    3: (* 3→4 : lasku alkaa *)
        IF i_new = 4 THEN
            g_actual_move[t].ts3 := g_time_100ms;
        END_IF;
    4: (* 4→0 : handled after CASE — see below *)
END_CASE;

(* ── Invalidate on anomaly (checked at every phase transition) ── *)
IF i_new > 0 THEN
    (* Collision avoidance active: drive target limited *)
    IF g_transporter[t].XDriveTarget <> g_transporter[t].XFinalTarget THEN
        g_actual_move[t].Invalidated := TRUE;
    END_IF;
    (* Not in automatic mode: task interrupted *)
    IF g_transporter[t].Status < 4 THEN
        g_actual_move[t].Invalidated := TRUE;
    END_IF;
    (* Transporter fault active *)
    IF g_transporter[t].Fault THEN
        g_actual_move[t].Invalidated := TRUE;
    END_IF;
END_IF;

(* ── 4→0 completion: calculate and update g_move ── *)
IF i_prev = 4 AND i_new = 0 THEN
    g_actual_move[t].ts4 := g_time_100ms;

    (* Only update if all timestamps are valid and transfer was normal *)
    IF g_actual_move[t].ts0 > 0
       AND g_actual_move[t].ts1 > 0
       AND g_actual_move[t].ts2 > 0
       AND g_actual_move[t].ts3 > 0
       AND NOT g_actual_move[t].Invalidated
    THEN
                lift_stn  := g_actual_move[t].LiftStation;
                sink_stn  := g_actual_move[t].SinkStation;
                start_stn := g_actual_move[t].StartStation;
                li   := lift_stn  - MIN_StationIndex;
                si   := sink_stn  - MIN_StationIndex;
                st_i := start_stn - MIN_StationIndex;

                (* Mechanical delays in 0.1s ticks *)
                drip_x10 := g_station[lift_stn].DrippingTime;
                tray_x10 := g_cfg[t].DripTrayDelay;
                dev_x10  := g_station[sink_stn].DeviceDelay;

                (* Raw durations are already in 0.1s ticks *)
                raw_trav1 := LINT_TO_INT(g_actual_move[t].ts1 - g_actual_move[t].ts0);
                raw_trav2 := LINT_TO_INT(g_actual_move[t].ts3 - g_actual_move[t].ts2);

                (* Net lift = (ts2-ts1) - DrippingTime - DripTrayDelay *)
                raw_lift := LINT_TO_INT(g_actual_move[t].ts2 - g_actual_move[t].ts1)
                            - drip_x10 - tray_x10;

                (* Net sink = (ts4-ts3) - DripTrayDelay - DeviceDelay *)
                raw_sink := LINT_TO_INT(g_actual_move[t].ts4 - g_actual_move[t].ts3)
                            - tray_x10 - dev_x10;

                (* Clamp to minimum 0 *)
  IF raw_lift < 0 THEN raw_lift := 0; END_IF;
  IF raw_sink < 0 THEN raw_sink := 0; END_IF;
  IF raw_trav1 < 0 THEN raw_trav1 := 0; END_IF;
  IF raw_trav2 < 0 THEN raw_trav2 := 0; END_IF;

                (* Bounds check indices *)
                IF li >= 1 AND li <= 30
                   AND si >= 1 AND si <= 30
                   AND st_i >= 1 AND st_i <= 30
                THEN
                    (* Weighted average: new = (old * 4 + measured) / 5 *)

                    (* Lift time at lift station *)
                    g_move[t].LiftTime[li] :=
                        (g_move[t].LiftTime[li] * 4 + raw_lift) / 5;

                    (* Sink time at sink station *)
                    g_move[t].SinkTime[si] :=
                        (g_move[t].SinkTime[si] * 4 + raw_sink) / 5;

                    (* Travel: start → lift (both directions) *)
                    g_move[t].Travel[st_i].ToTime[li] :=
                        (g_move[t].Travel[st_i].ToTime[li] * 4 + raw_trav1) / 5;
                    g_move[t].Travel[li].ToTime[st_i] :=
                        (g_move[t].Travel[li].ToTime[st_i] * 4 + raw_trav1) / 5;

                    (* Travel: lift → sink (both directions) *)
                    g_move[t].Travel[li].ToTime[si] :=
                        (g_move[t].Travel[li].ToTime[si] * 4 + raw_trav2) / 5;
                    g_move[t].Travel[si].ToTime[li] :=
                        (g_move[t].Travel[si].ToTime[li] * 4 + raw_trav2) / 5;
                END_IF;
            END_IF;
END_IF;

STC_TrackMoveTimes := TRUE;

END_FUNCTION

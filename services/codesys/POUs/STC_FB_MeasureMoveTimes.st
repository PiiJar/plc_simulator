(* ============================================================
   FB_TimeMoves → STC_FB_MeasureMoveTimes — Times actual transporter movements
   ============================================================
   Records real lift, sink, and travel times into g_move table
   by observing phase transitions in the transport cycle.
   Used by task scheduling and departure scheduling.

   Phase state machine (from plc_prg.st):
     0 → 1 : X-travel to lift station
     1 → 2 : Lift at station
     2 → 3 : X-travel to sink station
     3 → 4 : Sink at station
     4 → 0 : Cycle complete

   Filtering — only pure mechanical motion is timed:
     Travel (phase 1, 3): timer runs only when ABS(vel_x) > 0.1
       → filters out TWA collision avoidance stops.
     Lift (phase 2): timer runs only during z_stage 2, 3, 4
       → excludes device_delay + dropping_time (stage 1)
         and drip_delay (stage 5).
     Sink (phase 4): timer runs only during z_stage 7, 8
       → excludes device_delay + drip_delay (stage 6).

   Usage in plc_prg.st (one instance per transporter):
     tm1(t_id := 1, phase := g_transporter[1].Phase,
         delta_t := 0.02, vel_x := g_sim_trans[1].XVelocity,
         z_stage := g_sim_trans[1].ZStage,
         lift_stn := g_transporter[1].LiftStationTarget,
         sink_stn := g_transporter[1].SinkStationTarget,
         from_stn := g_transporter[1].CurrentStation);

   Access recorded times:
     travel := g_move[1].Travel[3].ToTime[11];   stn 103 to 111
     lift   := g_move[1].LiftTime[5];             lift at stn 105
     sink   := g_move[2].SinkTime[12];            sink at stn 112
   ============================================================ *)

FUNCTION_BLOCK STC_FB_MeasureMoveTimes
VAR_INPUT
  t_id     : INT;     (* transporter index 1..3 *)
  phase    : INT;     (* current phase 0..4 *)
  delta_t  : REAL;    (* cycle time in seconds *)
  vel_x    : DINT;    (* current X velocity mm/s *)
  z_stage  : INT;     (* current Z motion stage 0..8 *)
  lift_stn : INT;     (* lift station number, e.g. 105 *)
  sink_stn : INT;     (* sink station number, e.g. 112 *)
  from_stn : INT;     (* station before command was given *)
END_VAR
VAR
  prev_phase   : INT := -1;   (* previous phase for edge detection *)
  timer        : REAL := 0.0; (* running timer *)
  travel_from  : INT;         (* index 1..25 for travel source *)
  travel_to    : INT;         (* index 1..25 for travel destination *)
  lift_idx     : INT;         (* index 1..25 for lift station *)
  sink_idx     : INT;         (* index 1..25 for sink station *)
END_VAR
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
END_VAR

VAR_EXTERNAL
  g_sim_trans : ARRAY[1..MAX_Transporters] OF UDT_JC_SimTransporterType;
  g_move : ARRAY[1..MAX_Transporters] OF UDT_JC_MoveTimesType;
END_VAR

(* ---- Phase transition detection ---- *)
IF phase <> prev_phase THEN

  (* -- Save completed measurement and set up next -- *)

  IF prev_phase = 1 AND phase = 2 THEN
    (* Travel to lift complete → save travel time *)
    IF travel_from >= 1 AND travel_from <= 25
       AND travel_to >= 1 AND travel_to <= 25 THEN
      g_move[t_id].Travel[travel_from].ToTime[travel_to] := REAL_TO_INT(timer * 10.0);
    END_IF;
    (* Start timing lift — timer starts at 0, accumulates only in z_stage 2-4 *)
    lift_idx := lift_stn - 100;
    timer := 0.0;

  ELSIF prev_phase = 2 AND phase = 3 THEN
    (* Lift complete → save lift time (pure mechanical Z-motion only) *)
    IF lift_idx >= 1 AND lift_idx <= 25 THEN
      g_move[t_id].LiftTime[lift_idx] := REAL_TO_INT(timer * 10.0);
    END_IF;
    (* Start timing travel to sink *)
    travel_from := lift_stn - 100;
    travel_to := sink_stn - 100;
    timer := 0.0;

  ELSIF prev_phase = 3 AND phase = 4 THEN
    (* Travel to sink complete → save travel time *)
    IF travel_from >= 1 AND travel_from <= 25
       AND travel_to >= 1 AND travel_to <= 25 THEN
      g_move[t_id].Travel[travel_from].ToTime[travel_to] := REAL_TO_INT(timer * 10.0);
    END_IF;
    (* Start timing sink — timer starts at 0, accumulates only in z_stage 7-8 *)
    sink_idx := sink_stn - 100;
    timer := 0.0;

  ELSIF prev_phase = 4 AND phase = 0 THEN
    (* Sink complete → save sink time (pure mechanical Z-motion only) *)
    IF sink_idx >= 1 AND sink_idx <= 25 THEN
      g_move[t_id].SinkTime[sink_idx] := REAL_TO_INT(timer * 10.0);
    END_IF;
    timer := 0.0;

  ELSIF prev_phase = 0 AND phase = 1 THEN
    (* New cycle starting → set up travel-to-lift *)
    travel_from := from_stn - 100;
    travel_to := lift_stn - 100;
    timer := 0.0;

  ELSE
    (* Unexpected transition → just reset *)
    timer := 0.0;
  END_IF;

  prev_phase := phase;

ELSE
  (* ---- No transition: accumulate timer ---- *)

  IF phase = 1 OR phase = 3 THEN
    (* Travel: only count time when actually moving *)
    (* Filters out TWA collision avoidance stops    *)
    IF vel_x <> 0 THEN
      timer := timer + delta_t;
    END_IF;

  ELSIF phase = 2 THEN
    (* Lift: only mechanical Z-motion stages 2-4 *)
    (* Excludes: stage 1 (device_delay + dropping_time), stage 5 (drip_delay) *)
    IF z_stage >= 2 AND z_stage <= 4 THEN
      timer := timer + delta_t;
    END_IF;

  ELSIF phase = 4 THEN
    (* Sink: only mechanical Z-motion stages 7-8 *)
    (* Excludes: stage 6 (device_delay + drip_delay) *)
    IF z_stage >= 7 AND z_stage <= 8 THEN
      timer := timer + delta_t;
    END_IF;
  END_IF;

END_IF;

END_FUNCTION_BLOCK

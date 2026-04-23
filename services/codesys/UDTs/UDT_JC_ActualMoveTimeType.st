(* ActualMoveTimeType - Phase transition timestamps for a single transfer *)
(* Each field stores the LINT timestamp in 0.1s ticks when the phase transition occurs *)
(* Durations: ts1-ts0 = travel to lift, ts2-ts1 = lift, ts3-ts2 = travel, ts4-ts3 = sink, ts0' = done *)
TYPE UDT_JC_ActualMoveTimeType :
STRUCT
    StartStation : INT;  (* Nostimen alkuasema / Transporter start station *)
    LiftStation  : INT;  (* Nostoasema / Lift station *)
    SinkStation  : INT;  (* Laskuasema / Sink station *)
    ts0 : LINT;  (* 0→1 : Siirto nostoasemalle alkaa / Travel to lift station begins *)
    ts1 : LINT;  (* 1→2 : Nosto alkaa / Lift begins *)
    ts2 : LINT;  (* 2→3 : Siirto laskuasemalle alkaa / Travel to sink begins *)
    ts3 : LINT;  (* 3→4 : Lasku alkaa / Sink begins *)
    ts4 : LINT;  (* 4→0 : Lasku päättyy / Sink complete *)
    Invalidated : BOOL;  (* TRUE = poikkeuksellinen siirto (väistö/häiriö), ei päivitä g_move[] *)
END_STRUCT;
END_TYPE

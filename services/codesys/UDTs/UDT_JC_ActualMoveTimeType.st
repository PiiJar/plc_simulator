(* ActualMoveTimeType - Phase transition timestamps for a single transfer *)
(* Each field stores the LINT timestamp in 0.1s ticks when the phase transition occurs *)
(* Durations: Ts1-Ts0 = travel to lift, Ts2-Ts1 = lift, Ts3-Ts2 = travel, Ts4-Ts3 = sink, Ts0' = done *)
TYPE UDT_JC_ActualMoveTimeType :
STRUCT
    StartStation : INT;  (* Nostimen alkuasema / Transporter start station *)
    LiftStation  : INT;  (* Nostoasema / Lift station *)
    SinkStation  : INT;  (* Laskuasema / Sink station *)
    Ts0 : LINT;  (* 0→1 : Siirto nostoasemalle alkaa / Travel to lift station begins *)
    Ts1 : LINT;  (* 1→2 : Nosto alkaa / Lift begins *)
    Ts2 : LINT;  (* 2→3 : Siirto laskuasemalle alkaa / Travel to sink begins *)
    Ts3 : LINT;  (* 3→4 : Lasku alkaa / Sink begins *)
    Ts4 : LINT;  (* 4→0 : Lasku päättyy / Sink complete *)
    Invalidated : BOOL;  (* TRUE = poikkeuksellinen siirto (väistö/häiriö), ei päivitä gMove[] *)
END_STRUCT;
END_TYPE

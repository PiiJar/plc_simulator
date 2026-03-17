(* MoveTimesType - Precomputed movement times per transporter *)
(* Timed from real motions, not calculated *)
TYPE UDT_JC_MoveTimesType :
STRUCT
    LiftTime : ARRAY[1..30] OF INT;           (* lift time ×10 = tenths of second, MAX_STATIONS_PER_LINE *)
    SinkTime : ARRAY[1..30] OF INT;           (* sink time ×10 = tenths of second, MAX_STATIONS_PER_LINE *)
    Travel   : ARRAY[1..30] OF UDT_JC_TravelFromType; (* travel[from].to_s[to] ×10, MAX_STATIONS_PER_LINE *)
END_STRUCT;
END_TYPE

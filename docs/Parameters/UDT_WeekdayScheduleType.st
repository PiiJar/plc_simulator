(* UDT_WeekdayScheduleType - Weekday production schedule entry *)
(* Used as ARRAY[1..7] in GVL_Parameters (1=Sunday..7=Saturday, Siemens DTL convention) *)
(* Data structure derived from param.weekday_schedule SQL table *)
(* Loaded at startup from database via HMI/SCADA *)
TYPE UDT_WeekdayScheduleType :
STRUCT
    ProductionStartTime : TIME_OF_DAY;  (* Time of day production starts (e.g., TOD#06:00:00) *)
    ProductionStopTime : TIME_OF_DAY;   (* Time of day production stops (e.g., TOD#22:00:00) *)
    FullDayProduction : BOOL;           (* TRUE = production runs 24h this day (ignores start/stop) *)
    IsActive : BOOL;                    (* TRUE = this day has scheduled production *)
END_STRUCT
END_TYPE

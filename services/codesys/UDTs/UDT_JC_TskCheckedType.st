(* TskCheckedType - Conflict analysis working data for FB_AnalyzeConflicts *)
TYPE UDT_JC_TskCheckedType :
STRUCT
    Unit        : INT;  (* batch unit index *)
    Stage       : INT;  (* program stage *)
    Transporter : INT;  (* assigned transporter *)
    StartTime   : LINT; (* task start (s), unix seconds *)
    EndTime     : LINT; (* task end (s), unix seconds *)
    FlexDown    : DINT; (* available advance margin (seconds) *)
    FlexUp      : DINT; (* available delay margin (seconds) *)
    XMin        : DINT; (* X-area minimum (mm) *)
    XMax        : DINT; (* X-area maximum (mm) *)
    IsConflict  : BOOL; (* TRUE if this task is in conflict *)
END_STRUCT;
END_TYPE

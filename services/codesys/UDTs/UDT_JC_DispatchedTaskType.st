(* DispatchedTaskType - Complete task package from Dispatcher to Executor *)
(* Contains all station/batch data the executor needs — no Stations[] lookup required *)
TYPE UDT_JC_DispatchedTaskType :
STRUCT
    (* Identification *)
    TaskId              : LINT;  (* unique ID = StartTime at creation *)
    UnitId              : INT;   (* unit index, 0 = manual/empty move *)

    (* Station targets *)
    LiftStation         : INT;   (* lift station number *)
    SinkStation         : INT;   (* sink station number *)
    LiftX               : DINT;  (* lift station X position, mm *)
    SinkX               : DINT;  (* sink station X position, mm *)
    LiftKind            : INT;   (* lift station 0=dry, 1=wet *)
    SinkKind            : INT;   (* sink station 0=dry, 1=wet *)

    (* Station timing parameters — ×0.1s *)
    DroppingTime_x10    : INT;   (* valutusaika at lift station *)
    LiftDeviceDelay_x10 : INT;   (* device delay at lift station *)
    SinkDeviceDelay_x10 : INT;   (* device delay at sink station *)
    DripTrayDelay_x10   : INT;   (* drip tray delay (from transporter config) *)

    (* Treatment timing — seconds *)
    TreatmentTime       : DINT;  (* CalcTime: expected treatment duration *)
    MinTime             : DINT;  (* minimum treatment time *)
    MaxTime             : DINT;  (* maximum treatment time *)
    TransferTime_x10    : DINT;  (* total transfer time, ×0.1s *)

    (* Task metadata *)
    NttPrimary          : INT;   (* 1 = sink is NTT primary destination *)
    BatchCode           : INT;   (* batch code for event reporting *)
    ProgramStage        : INT;   (* current program stage at dispatch *)

    (* State *)
    Active              : BOOL;  (* TRUE = task dispatched, FALSE = idle *)
END_STRUCT;
END_TYPE

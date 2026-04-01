(* SimTransporterType - Simulation-internal transporter data *)
(* Scheduler command params + physics state — NOT in production UDT *)
TYPE UDT_JC_SimTransporterType :
STRUCT
    RunningTaskId   : LINT; (* copied from TaskId when accepted *)
    TreatmentTime   : DINT; (* treatment duration (seconds) *)
    MinTime         : DINT; (* minimum treatment time (seconds) *)
    MaxTime         : DINT; (* maximum treatment time (seconds) *)
    LiftDeviceDelay : INT;  (* lift station device delay ×10 = tenths of second *)
    SinkDeviceDelay : INT;  (* sink station device delay ×10 = tenths of second *)
    XVelocity       : DINT; (* X velocity mm/s *)
    ZStage          : INT;  (* Z motion sub-phase *)
    ZTimer          : REAL; (* Z motion timer *)
    NttPrimary      : INT;  (* 1 = current task sink is NTT primary, 0 = otherwise *)
    IdleStartTime   : LINT; (* unix seconds when transporter became idle (Phase 4→0) *)
END_STRUCT;
END_TYPE

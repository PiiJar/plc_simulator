(* SimTransporterType — Simulation physics state only *)
(* No task/scheduler data — those live in g_dispatched_task *)
TYPE UDT_JC_SimTransporterType :
STRUCT
    XVelocity       : DINT; (* X velocity mm/s *)
    ZStage          : INT;  (* Z motion sub-phase *)
    ZTimer          : REAL; (* Z motion timer *)
END_STRUCT;
END_TYPE

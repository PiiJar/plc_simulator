(* RectifierProgramStepType - Data structure derived from param.rectifier_program_steps SQL tables *)
TYPE UDT_RectifierProgramStepType :
STRUCT
    RecordId : INT; (* Primary key *)
    RectifierProgramId : INT; (* Reference to rectifier_program *)
    StepNumber : INT; (* Step number *)
    StartPercentage : INT; (* Start percentage *)
    StopPercentage : INT; (* Stop percentage *)
    StepDuration : INT; (* Duration s *)
END_STRUCT
END_TYPE

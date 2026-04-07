(* RectifierProgramType - Data structure derived from param.rectifier_programs SQL tables *)
TYPE UDT_RectifierProgramType :
STRUCT
    RecordId : INT; (* Primary key *)
    ProgramName : STRING(30); (* Program name *)
    Description : STRING(30); (* Program description *)
END_STRUCT
END_TYPE

(* UDT_TransporterLiftSinkLimitsType - Position limits for lift/sink monitoring *)
(* Extracted from Siemens FB_TRP_SEQ position monitoring logic *)
TYPE UDT_TransporterLiftSinkLimitsType :
STRUCT
    AllowedPos_Minus : DINT;    (* Lower allowed position boundary mm *)
    AllowedPos_Plus : DINT;     (* Upper allowed position boundary mm *)
    MaxDownTime : REAL;         (* Maximum time for down movement s *)
    MaxUpTime : REAL;           (* Maximum time for up movement s *)
END_STRUCT
END_TYPE

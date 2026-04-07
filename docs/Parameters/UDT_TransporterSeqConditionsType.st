(* UDT_TransporterSeqConditionsType - Start conditions for sequence control *)
(* Extracted from Siemens FB_TRP_SEQ_SINK/LIFT/MAIN Conditions struct *)
TYPE UDT_TransporterSeqConditionsType :
STRUCT
    Ready : BOOL;               (* Sequence can be started - all conditions met *)
    TaskOK : BOOL;              (* Given task is valid *)
    ModeOK : BOOL;              (* Mode is semi-auto or auto *)
    Allowed : BOOL;             (* No interlocking alarms *)
END_STRUCT
END_TYPE

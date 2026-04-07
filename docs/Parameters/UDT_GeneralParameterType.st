(* GeneralParameterType - Data structure derived from param.general_parameters SQL tables *)
(* Type: 0=System, 1=PLC, 2=User, 3=HMI, 4=Reserved *)
TYPE UDT_GeneralParameterType :
STRUCT
    RecordId : INT; (* Primary key *)
    ParameterType : INT; (* Parameter type *)
    ParameterName : STRING(30); (* Parameter name *)
    ParameterValue : REAL; (* Parameter value *)
    Description : STRING(30); (* Description *)
    Platform : INT := 0; (* PLC platform: 0=Siemens, 1=TwinCAT, 2=Codesys *)
END_STRUCT
END_TYPE

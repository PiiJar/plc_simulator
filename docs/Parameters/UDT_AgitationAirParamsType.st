(* UDT_AgitationAirParamsType - Configuration for agitation air system *)
(* References devices and measurements via ID fields *)
TYPE UDT_AgitationAirParamsType :
STRUCT
    IsInUse : BOOL;                         (* Agitation air system enabled *)
    CompressorDeviceId : INT;               (* Reference to Devices[] - compressor *)
    CoolingFanDeviceId : INT;               (* Reference to Devices[] - cooling fan *)
    PressureMeasurementId : INT;            (* Reference to Measurements[] - discharge pressure *)
END_STRUCT
END_TYPE

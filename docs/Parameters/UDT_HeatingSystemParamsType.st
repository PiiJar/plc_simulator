(* UDT_HeatingSystemParamsType - Configuration for central heating system *)
(* References devices and measurements via ID fields *)
TYPE UDT_HeatingSystemParamsType :
STRUCT
    IsInUse : BOOL;                                 (* Heating system enabled *)
    GoingTemperatureMeasurementId : INT;            (* Reference to Measurements[] - outgoing water temperature *)
    ReturningTemperatureMeasurementId : INT;        (* Reference to Measurements[] - return water temperature *)
    ValveDeviceId : INT;                            (* Reference to Devices[] - 3-way valve *)
    CirculationPumpDeviceId : INT;                  (* Reference to Devices[] - circulation pump *)
END_STRUCT
END_TYPE

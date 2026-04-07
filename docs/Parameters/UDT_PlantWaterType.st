(* UDT_PlantWaterType - Configuration for plant water supply (demi water or tap water) *)
(* References devices and measurements via ID fields *)
TYPE UDT_PlantWaterType :
STRUCT
    IsInUse : BOOL;                         (* Water supply enabled *)
    PressureMeasurementId : INT;            (* Reference to Measurements[] - pressure sensor *)
    TemperatureMeasurementId : INT;         (* Reference to Measurements[] - temperature sensor *)
    FlowMeasurementId : INT;               (* Reference to Measurements[] - flow sensor *)
    MainValveDeviceId : INT;               (* Reference to Devices[] - main water valve *)
END_STRUCT
END_TYPE

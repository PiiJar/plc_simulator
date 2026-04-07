(* PHControlType - Data structure derived from param.ph_control SQL tables *)
(* ControlType: 0=Acid, 1=Alkali, 2=Acid/Alkali, 3=Dilution (shared water valve toward neutral) *)
TYPE UDT_PHControlType :
STRUCT
    PHId : INT; (* Primary key *)
    TankId : INT; (* Reference to tanks.TankId *)
    IsInUse : BOOL; (* Control enabled *)
    ControlType : INT; (* 0=Acid, 1=Alkali, 2=Both, 3=Dilution *)
    SetValueProd : REAL; (* Setpoint - production mode *)
    SetValueIdle : REAL; (* Setpoint - idle mode *)
    Tolerance : REAL; (* Control tolerance *)
    MeasurementId : INT; (* Reference to measurements *)
    AcidPumpDeviceId : INT; (* Reference to devices.Id *)
    AlkalinePumpDeviceId : INT; (* Reference to devices.Id *)
    AcidDosingId : INT; (* Reference to chemical_dosing.ChemicalId for acid pump dosing config, 0=no dosing control *)
    AlkaliDosingId : INT; (* Reference to chemical_dosing.ChemicalId for alkali pump dosing config, 0=no dosing control *)
END_STRUCT
END_TYPE

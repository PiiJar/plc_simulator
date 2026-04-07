(* ConductivityControlType - Data structure derived from param.conductivity_control SQL tables *)
TYPE UDT_ConductivityControlType :
STRUCT
    ConductivityId : INT; (* Primary key *)
    TankId : INT; (* Reference to tanks.TankId *)
    IsInUse : BOOL; (* Control enabled *)
    SetValueProd : REAL; (* Setpoint - production mode (target conductivity) *)
    SetValueIdle : REAL; (* Setpoint - idle mode *)
    Tolerance : REAL; (* Control tolerance *)
    MinAlarmProd : REAL; (* Min alarm limit - production *)
    MaxAlarmProd : REAL; (* Max alarm limit - production *)
    MinAlarmIdle : REAL; (* Min alarm limit - idle *)
    MaxAlarmIdle : REAL; (* Max alarm limit - idle *)
    AlarmDeadband : REAL; (* Alarm deadband value *)
    MeasurementId : INT; (* Reference to measurements *)
    ChemicalPumpDeviceId : INT; (* Reference to devices.Id - chemical dosing pump *)
    DilutionValveDeviceId : INT; (* Reference to devices.Id - water valve for dilution *)
    ChemicalDosingId : INT; (* Reference to chemical_dosing.ChemicalId for pump dosing config, 0=no dosing control *)
END_STRUCT
END_TYPE
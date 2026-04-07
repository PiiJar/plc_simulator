(* MeasurementType - Data structure derived from param.measurements SQL tables *)
TYPE UDT_MeasurementType :
STRUCT
    MeasurementId : INT; (* measurement_id SERIAL PRIMARY KEY !*)
    EquipmentCode : STRING(16); (* equipment_code VARCHAR NOT NULL *)
    IsInUse : BOOL; (* measurement_is_in_use BOOLEAN - Measurement enabled *)
    MinAlarmLimitProduction : REAL; (* min_alarm_limit_production REAL *)
    MaxAlarmLimitProduction : REAL; (* max_alarm_limit_production REAL *)
    MinAlarmLimitIdle : REAL; (* min_alarm_limit_idle REAL *)
    MaxAlarmLimitIdle : REAL; (* max_alarm_limit_idle REAL *)
    EngineeringScaleMin : REAL; (* engineering_scale_min DECIMAL *)
    EngineeringScaleMax : REAL; (* engineering_scale_max DECIMAL *)
    RawScaleMin : REAL; (* raw_scale_min DECIMAL *)
    RawScaleMax : REAL; (* raw_scale_max DECIMAL *)
    Unit : STRING(6); (* unit VARCHAR *)
    Decimals : DINT; (* decimals INT *)
    MeasurementTypeId : INT; (*  0 = temperature, 1 = pH, 2 = conductivity, 3 = level, 4 = current, 5 = voltage, 6 = frequency, 7 = concentration, 8 = flow rate, 9 = pressure, 10 = position, 11 = other *)
    SignalType : INT := 0; (* Analog signal type: 0=4-20mA, 1=0-20mA, 2=0-10V, 3=±10V, 4=±20mA *)
END_STRUCT
END_TYPE

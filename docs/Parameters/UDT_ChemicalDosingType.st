(* ChemicalDosingType - Data structure derived from param.chemical_dosing SQL tables *)
(* TriggerMode: 0=Manual, 1=Command, 2=Time-based, 3=Event-based (level/conductivity), 4=Surface-area-based *)
TYPE UDT_ChemicalDosingType :
STRUCT
    ChemicalId : INT; (* Primary key *)
    TankId : INT; (* Target tank reference *)
    DosingDeviceId : INT; (* Dosing device reference - pump or valve *)
    DosingDeviceType : INT; (* 0=Pump, 1=Valve *)
    ChemicalName : STRING(30); (* Chemical name *)
    IsInUse : BOOL; (* Dosing enabled *)
    
    (* Source tank monitoring *)
    SourceTankId : INT; (* Source chemical tank reference *)
    
    (* Dosing parameters *)
    PumpCapacity : REAL; (* Pump flow rate mL/s - primary dosing rate *)
    PumpVolume : REAL; (* Pump volume per stroke/cycle mL *)
    DosingVolumeUnit : INT; (* Volume unit: 0=mL, 1=L *)
    DosingCycleLength : INT; (* Duration of one dosing cycle s *)
    DosingAmountPerCycle : REAL; (* Amount dosed per cycle mL or L *)
    
    (* Trigger configuration *)
    TriggerMode : INT; (* 0=Manual, 1=Command, 2=Time-based, 3=Event-based, 4=Surface-area-based *)
    TriggerInterval : INT; (* Time-based trigger interval s, for TriggerMode=2 *)
    TriggerMeasurementId : INT; (* Measurement that triggers dosing, for TriggerMode=3 *)
    TriggerHighThreshold : REAL; (* Trigger when measurement exceeds this value *)
    TriggerLowThreshold : REAL; (* Stop when measurement drops below this value *)
    
    (* Surface area dosing - TriggerMode=4 *)
    SurfaceAreaThreshold : REAL; (* Accumulated m2 that triggers one dosing cycle *)
    
    (* Recipe/batch dosing *)
    WantedTotalAmount : REAL; (* Total amount to dose for recipe/batch mL or L *)
    
    (* Safety limits *)
    MaxDosingTime : INT; (* Maximum continuous dosing time s *)
    MinPauseTime : INT; (* Minimum pause between doses s *)
    MaxDailyAmount : REAL; (* Maximum daily dosing amount mL or L *)
    
    (* Alarms *)
    AlarmOnPumpFault : BOOL; (* Generate alarm on pump/valve fault *)
    AlarmOnOverdose : BOOL; (* Generate alarm on overdose detection *)
    AlarmOnLowChemical : BOOL; (* Generate alarm on low chemical level *)
END_STRUCT
END_TYPE

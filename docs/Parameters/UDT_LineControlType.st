(* LineControlType - Data structure for process line control *)
(* Controls the main water valve for an entire line *)
(* Aggregates HiHi alarms from all tanks to close main valve *)
TYPE UDT_LineControlType :
STRUCT
    LineId : INT; (* Primary key - matches UDT_TankType.LineId *)
    LineName : STRING(30); (* Descriptive name for the line *)
    IsInUse : BOOL; (* Line control enabled *)
    
    (* Main Water Valve *)
    MainWaterValveDeviceId : INT; (* Reference to devices.Id for main water valve *)
    
    (* Tank References - up to 20 tanks per line *)
    TankCount : INT; (* Number of tanks in this line (1-20) *)
    TankIds : ARRAY[1..20] OF INT; (* TankIds in this line *)
    
    (* Level Control References - for HiHi aggregation *)
    LevelControlCount : INT; (* Number of level controls to monitor *)
    LevelControlIds : ARRAY[1..20] OF INT; (* LevelControl FillIds to monitor for HiHi *)
    
    (* Safety Settings *)
    HiHiCloseDelay : INT := 0; (* Delay before closing main valve on HiHi (ms) *)
    HiHiReopenDelay : INT := 5000; (* Delay before reopening after HiHi clears (ms) *)
    
    (* Manual Override *)
    AllowManualOverride : BOOL := FALSE; (* Allow HMI override of HiHi interlock *)
END_STRUCT
END_TYPE

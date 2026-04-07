(* MultiValvePumpRecipeType - Recipe definition for multi-valve pump control *)
(* Each recipe defines a valve pattern (which valves open/closed) and max pump time *)
(* Stored in GVL_MultiValvePumpRecipes, loaded from param.multi_valve_pump_recipe *)
TYPE UDT_MultiValvePumpRecipeType :
STRUCT
    RecipeName : STRING[10]; (* Display name for HMI *)
    MaxPumpTime : INT; (* Max pump run time in seconds (0=no limit) *)
    Valve1Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 1 *)
    Valve2Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 2 *)
    Valve3Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 3 *)
    Valve4Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 4 *)
    Valve5Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 5 *)
    Valve6Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 6 *)
    Valve7Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 7 *)
    Valve8Pattern : BOOL; (* TRUE=open, FALSE=closed for valve 8 *)
    RequiresDestReady : BOOL; (* TRUE=destination must be ready before pump start, FALSE=skip check (e.g. IBC container) *)
END_STRUCT
END_TYPE

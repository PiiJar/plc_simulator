(* Signal tower parameters for indicator tower with 4 lights and horn *)
TYPE UDT_SignalTowerType :
STRUCT
    Id : INT; (* Tower ID, 0 = not configured *)
    TowerName : STRING(30); (* Display name *)
    FlashIntervalMs : INT; (* Flash interval ms *)
    HornDurationS : INT; (* Horn sound duration s *)
    HornRepeatIntervalS : INT; (* Horn repeat interval s *)
    HighPriorityThreshold : INT; (* High priority threshold *)
    LowPriorityThreshold : INT; (* Low priority threshold *)
END_STRUCT
END_TYPE

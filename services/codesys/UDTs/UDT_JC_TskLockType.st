(* TskLockType - Oscillation lock: prevents resolve from advancing & delaying same stage *)
TYPE UDT_JC_TskLockType :
STRUCT
    Unit      : INT; (* batch unit index, 0 = empty slot *)
    Stage     : INT; (* program stage *)
    Direction : INT; (* 1=ADVANCE, 2=DELAY *)
END_STRUCT;
END_TYPE

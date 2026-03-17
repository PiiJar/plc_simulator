(* TskStretchType - Resolve decision to persist: delay/advance amount for a program stage *)
TYPE UDT_JC_TskStretchType :
STRUCT
    Unit   : INT;  (* unit index 1..10, 0 = empty slot *)
    Stage  : INT;  (* program stage 1..N *)
    DelayS : DINT; (* seconds: positive = delay, negative = advance *)
END_STRUCT;
END_TYPE

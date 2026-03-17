TYPE UDT_UnitLocation :
STRUCT
    UnitId     : INT;  (* unit currently at this station, 0 = none *)
    ChangeTime : LINT; (* timestamp of last unit arrival/departure (unix seconds) *)
END_STRUCT;
END_TYPE

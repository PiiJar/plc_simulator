(* DepOverlapType - Stations covered by multiple transporters *)
TYPE UDT_JC_DepOverlapType :
STRUCT
    Flags : ARRAY[0..200] OF BOOL; (* TRUE = station is in overlap zone — G09: full domain matching JS *)
    Count : INT;
END_STRUCT;
END_TYPE

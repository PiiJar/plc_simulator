(* NttTransporterType - No-treatment per-transporter destination map *)
TYPE UDT_JC_NttTransporterType :
STRUCT
    (* Index = target code: 1=TO_LOADING, 2=(reserved), 3=TO_PROCESS, 4=TO_UNLOAD, 5=TO_AVOID,
    6=TO_EMPTY_BUFFER, 7=TO_LOADED_BUFFER, 8=TO_PROCESSED_BUFFER *)
    Target : ARRAY[1..8] OF UDT_JC_NttDestType;
END_STRUCT;
END_TYPE

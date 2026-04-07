(* ChargeProductType - Data structure derived from param.charge_products SQL tables *)
TYPE UDT_ChargeProductType :
STRUCT
    RecordId : INT; (* Primary key *)
    ChargeId : STRING(30); (* Reference to charge *)
    ProductId : INT; (* Reference to product *)
    Quantity : INT; (* Quantity *)
    TotalSurfaceArea : REAL; (* Total surface area *)
    TotalWeight : REAL; (* Total weight *)
    OrderCode : STRING(30); (* Order code *)
    ClientName : STRING(30); (* Client name *)
    AmountOk : INT; (* Good parts count *)
    AmountNotOk : INT; (* Rejected parts count *)
    AmountReworked : INT; (* Reworked parts count *)
END_STRUCT
END_TYPE

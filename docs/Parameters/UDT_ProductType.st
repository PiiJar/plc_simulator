(* ProductType - Data structure derived from param.products SQL tables *)
TYPE UDT_ProductType :
STRUCT
    ProductId : INT; (* Primary key *)
    ProductCode : STRING(30); (* Product code *)
    ProductName : STRING(30); (* Product name *)
    Description : STRING(30); (* Description *)
    SurfaceArea : REAL; (* Surface area *)
    CurrentDensity1 : REAL; (* Current density 1 *)
    CurrentDensity2 : REAL; (* Current density 2 *)
    CurrentDensity3 : REAL; (* Current density 3 *)
    CurrentDensity4 : REAL; (* Current density 4 *)
    CurrentDensity5 : REAL; (* Current density 5 *)
    CurrentDensity6 : REAL; (* Current density 6 *)
    Weight : REAL; (* Weight *)
    ProductGroup : STRING(20); (* Product group *)
    TreatmentProgramId : INT; (* Treatment program reference *)
    Amount : INT; (* Amount *)
END_STRUCT
END_TYPE

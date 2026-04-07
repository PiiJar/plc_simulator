(* RouteType - Data structure derived from param.route SQL tables *)
TYPE UDT_RouteType :
STRUCT
    RouteId : INT; (* Primary key *)
    RouteName : STRING(30); (* Route name *)
    SourceTankId : INT; (* Source tank reference *)
    ChemicalId : INT; (* Chemical reference *)
    RouteControlType : INT; (* Route control type *)
    IsSelected : BOOL; (* Route selected *)
END_STRUCT
END_TYPE

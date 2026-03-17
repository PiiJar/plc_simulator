(*******************************************************************************
 * DUT Name: UDT_TankType
 * Description: Tank configuration - identity and sub-equipment mapping
 *              References control loop IDs and equipment IDs for FB_Tank
 *              ID > 0 means equipment is present (replaces Has* booleans)
 *              All IDs reference their respective GVL_Parameters arrays
 *
 * Usage:
 *   - TankId is primary key
 *   - Set unused equipment IDs to 0 to disable
 *   - Composite FBs resolve their own device IDs from control params
 *
 * Version History:
 * Version  | Date       | Author      | Description
 * ----------------------------------------------------------------------
 * 2.0      | 2026-02-26 |             | Merged UDT_TankControlType sub-equipment IDs into UDT_TankType.
 *                                     | Added: TemperatureControl x2, Measurement x3, Pump x3,
 *                                     | ChemicalDosing x3, Mixer, Blower, Rectifier.
 *                                     | Removed Has* booleans (ID > 0 = present).
 *                                     | Removed drain control (no longer in codebase).
 * 1.0      | 2026-01-13 |             | Initial version - identity only
 *****************************************************************************)
TYPE UDT_TankType :
STRUCT
    (* === Tank Identification === *)
    TankId                : INT;    (* Primary key *)
    EquipmentCode         : STRING; (* Equipment code matching PID *)
    TankName              : STRING; (* Optional descriptive name *)
    TypeId                : INT;    (* Tank type identifier *)
    IsInUse               : BOOL;   (* TRUE = in use *)
    LineId                : INT;    (* Process line identifier *)
    GroupId               : INT;    (* Reference to tank_group.GroupId *)
    RinseId               : INT;    (* Rinse tank reference *)
    FilterUnitId          : INT;    (* Filter unit reference *)
    Color                 : STRING; (* Display color RGB hex *)

    (* === Position in mm === *)
    XPosition             : DINT;   (* X position mm *)
    YPosition             : DINT;   (* Y position mm *)
    ZPosition             : DINT;   (* Z position mm *)

    (* === Temperature Control (x2) === *)
    TemperatureControl1Id : INT;    (* Reference to GVL_Parameters.TemperatureControls[id], 0 = none *)
    TemperatureControl2Id : INT;    (* Reference to GVL_Parameters.TemperatureControls[id], 0 = none *)

    (* === Level Control === *)
    LevelControlId        : INT;    (* Reference to GVL_Parameters.LevelControls[id], 0 = none *)

    (* === pH Control === *)
    PHControlId           : INT;    (* Reference to GVL_Parameters.PHControls[id], 0 = none *)

    (* === Conductivity Control === *)
    ConductivityControlId : INT;    (* Reference to GVL_Parameters.ConductivityControls[id], 0 = none *)

    (* === Measurements (x3) === *)
    Measurement1Id        : INT;    (* Reference to GVL_Parameters.Measurements[id], 0 = none *)
    Measurement2Id        : INT;    (* Reference to GVL_Parameters.Measurements[id], 0 = none *)
    Measurement3Id        : INT;    (* Reference to GVL_Parameters.Measurements[id], 0 = none *)

    (* === Pumps (x3) === *)
    Pump1Idx              : INT;    (* Reference to GVL_Parameters.Pumps[idx], 0 = none (e.g. filter pump) *)
    Pump2Idx              : INT;    (* Reference to GVL_Parameters.Pumps[idx], 0 = none *)
    Pump3Idx              : INT;    (* Reference to GVL_Parameters.Pumps[idx], 0 = none *)

    (* === Chemical Dosing (x3) === *)
    ChemicalDosing1Id     : INT;    (* Reference to GVL_Parameters.ChemicalDosings[id], 0 = none *)
    ChemicalDosing2Id     : INT;    (* Reference to GVL_Parameters.ChemicalDosings[id], 0 = none *)
    ChemicalDosing3Id     : INT;    (* Reference to GVL_Parameters.ChemicalDosings[id], 0 = none *)

    (* === Agitation === *)
    AgitationId           : INT;    (* Reference to GVL_Parameters.Agitations[id], 0 = none *)

    (* === Mixer === *)
    MixerId               : INT;    (* Reference to GVL_Parameters.Mixers[id], 0 = none *)

    (* === Blower === *)
    BlowerId              : INT;    (* Reference to GVL_Parameters.Blowers[id], 0 = none *)

    (* === Cover === *)
    CoverId               : INT;    (* Reference to GVL_Parameters.Covers[id], 0 = none *)

    (* === Rectifier === *)
    RectifierId           : INT;    (* Reference to GVL_Parameters.Rectifiers[id], 0 = none *)
END_STRUCT;
END_TYPE

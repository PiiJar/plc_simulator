# PLC Programming Style Guide

> **Advisory Guidelines** — This document formalizes the coding conventions used across the ST codebase. Following these patterns ensures consistency, readability, and compatibility with both TwinCAT 3 and TIA Portal platforms.

*For developers and AI assistants generating or modifying PLC code.*

---

## Table of Contents

1. [Naming Conventions](#naming-conventions)
2. [File Organization](#file-organization)
3. [Block Headers](#block-headers)
4. [Variable Declarations](#variable-declarations)
5. [Comments](#comments)
6. [Code Structure Patterns](#code-structure-patterns)
7. [Data Types](#data-types)
8. [Arithmetic Safety](#arithmetic-safety)
9. [Platform Compatibility](#platform-compatibility)
10. [Composite vs. Control Block Architecture](#composite-vs-control-block-architecture)

---

## Naming Conventions

### Block Type Prefixes

| Element | Prefix | Example |
|---------|--------|---------|
| User Data Type (Struct) | `UDT_` | `UDT_TankType`, `UDT_AlarmTypeConfigType` |
| Function Block | `FB_` | `FB_Device`, `FB_PHControl` |
| Function | `FC_` | `FC_ScaleValue`, `FC_Clamp` |
| Global Variable List | `GVL_` | `GVL_Parameters`, `GVL_RuntimeData` |
| Program | *(none)* | `Main`, `LiftSinkSimulation` |

### Variable Prefixes

| Scope | Prefix | Example |
|-------|--------|---------|
| Input (`VAR_INPUT`) | `i` | `iEnable`, `iMeasurementParams` |
| Output (`VAR_OUTPUT`) | `o` | `oRunning`, `oHMI` |
| In-Out (`VAR_IN_OUT`) | `io` | `ioData`, `ioBuffer` |
| Local (`VAR`) | `v` | `vInitialized`, `vScaledValue` |
| Local FB Instance | `vFB_` | `vFB_Control`, `vFB_Timer` |
| Local Constant | `c` | `cMaxRetries`, `cDefaultTimeout` |
| Global Constant | ALL_CAPS | `MAX_ALARMS`, `STEP_IDLE` |
| Temporary | `t` | `tIndex`, `tResult` |

### Case Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Type names | PascalCase with `Type` suffix | `UDT_MeasurementType` |
| Block names | PascalCase | `FB_ConductivityControl` |
| Variables | PascalCase after prefix | `iAnalogInput`, `vLastScanTime` |
| Constants | ALL_CAPS with underscores | `MAX_LIFT_SINK_STEP_COUNT` |
| Struct fields | PascalCase | `SetValue`, `ControlType`, `AlarmHigh` |

---

## File Organization

### Folder Structure

```
ST_codes/
├── DUTs/                         # Data type definitions
│   ├── CommandStructures/        # Command-related UDTs
│   ├── GeneralDUTs/              # General-purpose UDTs
│   ├── Interfaces/               # Interface UDTs (*ToDeviceType, etc.)
│   ├── Parameters/               # Parameter UDTs (from database)
│   └── Status/                   # Status and feedback UDTs
├── GVLs/                         # Global variable lists
└── POUs/                         # Program organization units
    ├── CoreFunctions/            # Reusable function blocks
    │   ├── CompositeBlocks/      # Higher-level composite FBs
    │   ├── Control/              # Control loop FBs
    │   ├── Device/               # Device driver FBs
    │   └── Measurement/          # Measurement processing FBs
    ├── HelpFunctions/            # Utility functions
    └── Transporter/              # Application-specific FBs
```

### File Naming

- One block per file
- Filename matches block name exactly: `FB_PHControl.st`, `UDT_TankType.st`
- Use `.st` extension for all Structured Text files

---

## Block Headers

### Standard Header Template

```iecst
(*******************************************************************************
 * Block Name: FB_ExampleBlock
 * Description: Brief description of the block's purpose.
 *              Additional details on second line if needed.
 *
 * Version History:
 * Version  | Date       | Author      | Description
 * ----------------------------------------------------------------------
 * 1.0      | 2026-01-12 |             | Initial version
 ******************************************************************************)
```

### Type Definition Header

```iecst
(* UDT_ExampleType - Brief description of the data structure purpose *)
(* Source: param.table_name if derived from database schema *)
TYPE UDT_ExampleType :
STRUCT
    ...
END_STRUCT
END_TYPE
```

---

## Variable Declarations

### Section Grouping

Group related variables with section comments:

```iecst
FUNCTION_BLOCK FB_Example
VAR_INPUT
    (* === Configuration Parameters === *)
    iParams : UDT_ExampleParamType;
    
    (* === Physical Inputs === *)
    iAnalogInput : UDT_AnalogInput;
    iDigitalInput : BOOL;
    
    (* === Control Inputs === *)
    iEnable : BOOL;
    iReset : BOOL;
END_VAR

VAR_OUTPUT
    (* === Physical Outputs === *)
    oOutput : BOOL;
    oAnalogOutput : REAL;
    
    (* === HMI Interface === *)
    oHMI : UDT_ExampleHMIType;
    
    (* === Status === *)
    oActive : BOOL;
    oFault : BOOL;
END_VAR

VAR
    (* === Internal FB Instances === *)
    vFB_Control : FB_Control;
    vTonDelay : TON;
    
    (* === State Variables === *)
    vInitialized : BOOL;
    vState : INT;
    
    (* === Working Variables === *)
    vScaledValue : REAL;
END_VAR
```

### Default Values

Provide defaults for safety-critical inputs:

```iecst
VAR_INPUT
    iEnable : BOOL := FALSE;
    iTimeout : TIME := T#5S;
END_VAR
```

> **Rule: BOOL inputs must never default to TRUE.**
> TIA Portal does not support default values on `VAR_INPUT`. When a FB is instantiated without explicitly wiring a BOOL input, TIA will use `FALSE` regardless of the default declared in the source. Defaulting to `TRUE` creates a behavioral difference between TwinCAT (honours the default) and TIA (ignores it), leading to hard-to-find bugs. Always design FB logic so that `FALSE` is the safe initial state for every BOOL input.

---

## Comments

### Section Dividers

Use for major logical sections within implementation:

```iecst
(* ============================================================ *)
(* SECTION: Input Processing *)
(* ============================================================ *)
```

### Inline Comments

```iecst
// Single-line comment for brief explanations
vScaledValue := iRawValue * iParams.ScaleFactor;  // Scale to engineering units

(* Multi-line comment for longer explanations
   spanning multiple lines *)
```

### Struct Field Comments

```iecst
TYPE UDT_ExampleType :
STRUCT
    Id : INT;                   // Unique identifier
    Name : STRING[50];          // Display name
    SetValue : REAL;            // Target setpoint value
    ControlType : INT;          // 0=Off, 1=Auto, 2=Manual
END_STRUCT
END_TYPE
```

---

## Code Structure Patterns

### Initialization Block

Place at start of cyclic execution:

```iecst
IF NOT vInitialized THEN
    vLastScanTime := GVL_RuntimeData.CurrentTime;
    vState := 0;
    vInitialized := TRUE;
END_IF
```

### CASE Statement

```iecst
CASE vState OF
    0: // Idle
        IF iStart THEN
            vState := 10;
        END_IF
        
    10: // Running
        vFB_Process();
        IF vFB_Process.oDone THEN
            vState := 20;
        END_IF
        
    20: // Complete
        oComplete := TRUE;
        IF iReset THEN
            vState := 0;
        END_IF
        
ELSE
    vState := 0;  // Default to safe state
END_CASE
```

### Maximum Block Nesting Depth

⚠️ **Maximum depth for function blocks inside function blocks is four layers.**

The call hierarchy from the top-level program down to the deepest leaf FB/FC must not exceed 4 levels. Deeper nesting makes the system harder to debug, trace through, and understand the data flow.

```
CORRECT — 4 layers maximum:

  Main (Program)
   └─ FB_Tank                          (* Layer 1 *)
       └─ FB_TemperatureControl         (* Layer 2 *)
           └─ FB_Device                 (* Layer 3 *)
               └─ FC_ScaleValue         (* Layer 4 — maximum *)

WRONG — 5+ layers, flatten the hierarchy:

  Main (Program)
   └─ FB_Line                          (* Layer 1 *)
       └─ FB_Tank                      (* Layer 2 *)
           └─ FB_TemperatureControl    (* Layer 3 *)
               └─ FB_Device            (* Layer 4 *)
                   └─ FC_ScaleValue    (* Layer 5 — too deep *)
```

**Guidelines:**
- Count layers from the first FB/FC called by the program, not from Main itself
- Both FB and FC instances count as a layer
- Exceeding 4 layers is **not recommended** and must be **separately approved** before implementation
- If the hierarchy exceeds 4, consider calling the deepest blocks from a higher level or merging thin wrapper blocks
- Utility functions (`FC_*`) that perform pure calculations (no internal state) are acceptable at any depth but still count toward the limit

### Function Block Calls

Multi-line format for clarity:

```iecst
vFB_Control(
    iControlId := iParams.ControlId,
    iEnable := iEnable AND NOT iFault,
    iSetpoint := iParams.SetValue,
    iProcessValue := vScaledInput,
    oOutput => vControlOutput,
    oActive => oControlActive);
```

### One Call Per FB Instance Per Scan

⚠️ **Every function block instance must be called exactly ONCE per scan cycle.**

IEC 61131-3 function blocks maintain internal state (timers, edge detection, counters). Calling the same instance multiple times in different `IF/ELSE` branches causes erratic behavior because the FB processes its logic each time it is called.

```iecst
(* WRONG — TON called in 3 branches → timer resets/advances multiple times per scan *)
IF iManualMode THEN
    vFB_Timer(IN := FALSE, PT := T#0S);
ELSIF vIsDigitalMode THEN
    vFB_Timer(IN := vDigitalRequest, PT := T#60S);
ELSE
    vFB_Timer(IN := vAnalogRequest, PT := T#60S);
END_IF

(* CORRECT — single call with computed inputs *)
vFB_Timer(
    IN := NOT iManualMode AND SEL(G := vIsDigitalMode, IN0 := vAnalogRequest, IN1 := vDigitalRequest),
    PT := T#60S);
vTimeout := vFB_Timer.Q AND NOT iManualMode;
```

**Rule:** Compute `IN`, `PT`, and other parameters into intermediate variables **before** the single FB call. Use `SEL()`, `AND`/`OR` gating, or intermediate BOOLs to merge mode-dependent logic into one set of inputs.

This applies to all FB types: `TON`, `TOF`, `CTU`, `R_TRIG`, `F_TRIG`, and custom FBs.

### Interface Pattern

Standard interface UDT naming for block interconnection:

```iecst
// Control block outputs to device
oControlToDevice : UDT_ControlToDeviceType;

// Device reports back to control
iDeviceToControl : UDT_DeviceToControlType;

// Measurement reports to control
iMeasurementToControl : UDT_MeasurementToControlType;
```

### Edge Detection

```iecst
VAR
    vLastEnable : BOOL;
    vEnableRising : BOOL;
END_VAR

vEnableRising := iEnable AND NOT vLastEnable;
vLastEnable := iEnable;

IF vEnableRising THEN
    // Execute on rising edge
END_IF
```

---

## Data Types

### Type Selection

| Use Case | Type |
|----------|------|
| On/Off states | `BOOL` |
| Small counters, enum values | `INT` (-32768..32767) |
| Indexes, IDs, larger integers | `DINT` |
| Measurements, setpoints | `REAL` |
| High-precision calculations | `LREAL` |
| Text, names | `STRING[n]` with explicit length |
| Timestamps | `DATE_AND_TIME` |
| Bit fields | `WORD`, `DWORD` |
| Time durations | `TIME` |

### Array Declarations

Use named constants for bounds:

```iecst
VAR_GLOBAL CONSTANT
    MAX_TANKS : INT := 50;
    MAX_STEPS : INT := 100;
END_VAR

VAR
    Tanks : ARRAY[1..GVL_Constants.MAX_TANKS] OF UDT_TankType;
    Steps : ARRAY[0..GVL_Constants.MAX_STEPS-1] OF UDT_StepType;
END_VAR
```

### String Lengths

Always specify explicit length:

```iecst
Name : STRING[50];          // Names, descriptions
ShortCode : STRING[10];     // Identifiers, codes
Message : STRING[255];      // Long text, messages
```

---

## Arithmetic Safety

### INT Overflow in Time Calculations

⚠️ **Never multiply an `INT` parameter by 1000 (or any large factor) in `INT` arithmetic.**

`INT` is a signed 16-bit integer with range −32768 to 32767. Multiplying by 1000 overflows silently for any value > 32:

| `MaxFillTime` | `MaxFillTime * 1000` | Actual INT result | `INT_TO_TIME` produces |
|---------------|----------------------|-------------------|------------------------|
| 30 | 30,000 | 30,000 ✅ | `T#30S` ✅ |
| 33 | 33,000 | −32,536 ❌ | `T#0MS` (clamped) ❌ |
| 3600 | 3,600,000 | ~−4,480 ❌ | `T#0MS` (instant timeout) ❌ |

**Symptom:** Timer fires instantly every scan → output blinks on/off each cycle.

**Rule:** Always widen to `DINT` **before** multiplying:

```iecst
(* WRONG — overflows when iParams.MaxFillTime > 32 *)
vFB_Timer(PT := INT_TO_TIME(iParams.MaxFillTime * 1000));

(* CORRECT — DINT handles up to 2,147,483 seconds *)
vFB_Timer(PT := DINT_TO_TIME(INT_TO_DINT(iParams.MaxFillTime) * 1000));
```

**General rule:** When any multiplication, addition, or subtraction on `INT` values could exceed ±32,767, convert operands to `DINT` first. Common cases:
- Seconds → milliseconds (`* 1000`)
- Minutes → milliseconds (`* 60000`)
- Array index calculations with offsets

---

## Platform Compatibility

### Syntax Differences

| Feature | TwinCAT 3 | TIA Portal |
|---------|-----------|------------|
| Property syntax | `PROPERTY Name : Type` | Not supported (use methods) |
| Reference operator | `REF=` | Not supported |
| Interface inheritance | `IMPLEMENTS` | Limited support |
| Pointer syntax | `POINTER TO` | Limited support |
| LREAL literals | `1.0` | `1.0` (same) |
| Time literals | `T#1S`, `T#500MS` | `T#1S`, `T#500MS` (same) |

### GVL Qualified Access

Use `{attribute 'qualified_only'}` for constant GVLs to prevent naming conflicts:

```iecst
{attribute 'qualified_only'}
VAR_GLOBAL CONSTANT
    MAX_ALARMS : INT := 100;
END_VAR
```

Access as: `GVL_Constants.MAX_ALARMS`

### Reserved Words

Avoid using these as identifiers (platform-specific reserved):
- `AT`, `BY`, `DO`, `IF`, `OF`, `ON`, `OR`, `TO`
- `AND`, `FOR`, `MOD`, `NOT`, `VAR`, `XOR`
- `BOOL`, `BYTE`, `CASE`, `DATE`, `DINT`, `ELSE`, `EXIT`
- `FROM`, `GOTO`, `LINT`, `REAL`, `SINT`, `STEP`, `TASK`
- `THEN`, `TIME`, `TRUE`, `TYPE`, `UINT`, `WINT`, `WITH`
- `WORD`, `ARRAY`, `CLASS`, `DWORD`, `FALSE`, `FINAL`

#### TIA Portal SCL Reserved Field Names

⚠️ The following identifiers are **reserved in TIA Portal SCL** and must NOT be used as struct field names, even though they work in TwinCAT:

- `Name` — Use `TowerName`, `DeviceName`, etc. instead
- `Version`, `Author`, `Family`, `Title`
- `DB_SPECIFIC`, `S7_Optimized_Access`

If a struct field triggers `"The specified value is invalid"` during TIA import, it is likely a reserved identifier.

### Type Conversion Functions — Platform Availability

Not all type conversion functions exist on both platforms:

| Function | TwinCAT 3 | TIA Portal | Alternative |
|----------|-----------|------------|-------------|
| `DT_TO_DINT` | ✅ | ❌ | Pass `iDayOfWeek : INT` + `iTimeOfDay : TOD` as inputs instead |
| `DINT_TO_DT` | ✅ | ❌ | Construct from components |
| `TOD_TO_DINT` | ✅ | ✅ | |
| `DINT_TO_TOD` | ✅ | ✅ | |
| `DINT_TO_TIME` | ✅ | ✅ | |
| `TIME_TO_DINT` | ✅ | ✅ | |
| `REAL_TO_INT` | ✅ | ✅ | |
| `INT_TO_REAL` | ✅ | ✅ | |

**Rule:** When you need day-of-week or time-of-day from a timestamp, have the caller provide them as separate inputs rather than computing from `DATE_AND_TIME` inside the FB. This avoids platform-specific conversion functions.

### Best Practices for Cross-Platform Code

1. **Stick to IEC 61131-3 base features** — avoid vendor extensions
2. **Use explicit type conversions** — `REAL_TO_INT()`, `INT_TO_REAL()`
3. **Avoid pointer arithmetic** — use arrays and indexes instead
4. **Test on both platforms** — run converter and verify compilation
5. **BOOL inputs must never default to TRUE** — TIA Portal ignores `VAR_INPUT` defaults, so a `BOOL := TRUE` default works in TwinCAT but silently becomes `FALSE` in TIA. Design logic so `FALSE` is the safe/inactive state.
6. **Do not use `DT_TO_DINT` or `DINT_TO_DT`** — These do not exist in TIA Portal. Pass day-of-week and time-of-day as separate inputs instead of computing from `DATE_AND_TIME`.
7. **Avoid reserved identifiers as struct field names** — `Name`, `Version`, `Author`, `Family`, `Title` are reserved in TIA Portal SCL. Use domain-prefixed alternatives.
8. **Use named parameters for IEC standard functions** — TIA Portal requires named parameters for `SEL`, `LIMIT`, `MUX`, `MAX`, `MIN`. Positional parameters will not compile.
9. **Never use `VAR_EXTERNAL`** — Not supported in TIA Portal SCL. Use bare global references; the converter handles GVL qualification automatically.
10. **RETAIN variables require manual TIA configuration** — The converter replaces `RETAIN` with `NON_RETAIN` for TIA compatibility. Set retentivity manually in TIA Portal after project build.

### VAR_EXTERNAL — Not Supported in TIA Portal

⚠️ **Never use `VAR_EXTERNAL` or `VAR_EXTERNAL CONSTANT` in source ST files.**

TIA Portal's `GenerateBlocksFromSource` API rejects `VAR_EXTERNAL` in external source SCL files. This keyword is CODESYS/TwinCAT-specific and has no Siemens equivalent.

**How globals are accessed instead:**
- The converter automatically qualifies bare global references with their GVL name
- No forward declaration is needed — just use the bare variable name in the body

```iecst
(* WRONG — VAR_EXTERNAL not supported in TIA Portal *)
FUNCTION STC_Example : BOOL
VAR_EXTERNAL CONSTANT
    MAX_Transporters : INT;
END_VAR
VAR_EXTERNAL
    g_transporter : ARRAY[1..MAX_Transporters] OF UDT_TransporterStatusType;
END_VAR
VAR
    ti : INT;
END_VAR
FOR ti := 1 TO MAX_Transporters DO ...

(* CORRECT — bare references, converter handles GVL qualification *)
FUNCTION STC_Example : BOOL
VAR
    ti : INT;
END_VAR
FOR ti := 1 TO MAX_Transporters DO ...
```

### RETAIN/PERSISTENT Variables — TIA Portal Limitation

⚠️ **TIA Openness API does NOT support the `RETAIN` keyword in external source SCL files.**

When `VAR_GLOBAL RETAIN` is used in source GVLs:
- **TwinCAT**: Works correctly — `VAR_GLOBAL RETAIN` passes through unchanged
- **TIA Portal**: The converter outputs `NON_RETAIN` with a comment marker `// RETAIN_REQUESTED`

**Manual step required after TIA project build:**
1. Open the generated TIA Portal project
2. For each DATA_BLOCK listed in the build output:
   - Right-click → Properties
   - Under "Retentivity", set to "Set in IDB" or configure per-variable RETAIN as needed

### Named Parameters for IEC Standard Functions

⚠️ **TIA Portal requires named parameters for IEC standard functions.** Positional parameters will not compile.

```iecst
(* CORRECT — Named parameters for TIA Portal *)
result := SEL(G := bCondition, IN0 := valueIfFalse, IN1 := valueIfTrue);
limited := LIMIT(MN := minVal, IN := inputVal, MX := maxVal);
selected := MUX(K := index, IN0 := val0, IN1 := val1, IN2 := val2);

(* WRONG — Positional parameters will NOT compile in TIA Portal *)
result := SEL(bCondition, valueIfFalse, valueIfTrue);  // DO NOT USE
```

Common functions requiring named parameters:

| Function | Parameters |
|----------|------------|
| `SEL` | `G`, `IN0`, `IN1` |
| `LIMIT` | `MN`, `IN`, `MX` |
| `MUX` | `K`, `IN0`, `IN1`, ... |
| `MAX` | `IN1`, `IN2` |
| `MIN` | `IN1`, `IN2` |

---

## System-Wide Global Variables

### Accessing System Time

Function blocks that need timestamps should access `GVL_RuntimeData.CurrentTime` directly rather than receiving it as an input parameter. This simplifies call sites and ensures consistent time across all blocks.

**Pattern:**

```iecst
(* In leaf function blocks - access GVL directly *)
FUNCTION_BLOCK FB_Device
VAR_INPUT
    iDeviceParams : UDT_DeviceType;
    iCommandOn : BOOL;
    (* Note: System time comes from GVL_RuntimeData.CurrentTime *)
END_VAR
VAR
    vLastStartTime : DATE_AND_TIME;
END_VAR

(* Usage inside the FB *)
IF oRunning AND NOT vPrevRunning THEN
    vLastStartTime := GVL_RuntimeData.CurrentTime;
END_IF
```

**Benefits:**
- Eliminates `iCurrentTime := GVL_RuntimeData.CurrentTime` at every call site
- Reduces parameter count on function block interfaces
- Ensures all blocks see the same timestamp within a scan cycle

**GVL_RuntimeData provides:**
- `CurrentTime : DATE_AND_TIME` — System clock updated each scan by HMI/SCADA
- `SimulationMode : BOOL` — Global simulation flag
- `SystemRunning : BOOL` — System operational status

### When to Use GVL Direct Access vs Inputs

| Use Case | Approach |
|----------|----------|
| System time | `GVL_RuntimeData.CurrentTime` (global) |
| Simulation mode | `GVL_RuntimeData.SimulationMode` (global) |
| Device parameters | Input parameter (config varies per instance) |
| Process values | Input parameter (varies per call) |
| Control setpoints | Input parameter (varies per instance) |

---

## Composite vs. Control Block Architecture

### Block Roles: Control vs. Composite

The codebase uses a two-tier pattern for control loops:

| Role | Naming | Responsibility | Example |
|------|--------|----------------|---------||
| **Control block** | `FB_*Control` | All control decisions — hysteresis, latching, mode switching, timeouts | `FB_LevelControl`, `FB_TemperatureControl` |
| **Composite block** | `FB_*` (suffix varies: `LCA`, `TICA2x`, etc.) | Wiring — chains Measurement → Control → Device, handles I/O mapping, device arbitration, status/HMI population | `FB_LCA`, `FB_TICA2x` |

**Rule: Control logic belongs in the control block, never in the composite.**

A composite must not contain `IF/ELSE` branches that make control decisions (e.g., "should we fill?"). It may only:
- Wire inputs/outputs between sub-blocks
- Arbitrate between devices (main vs. alternative) based on interlock signals
- Map sub-block outputs to status structures and GVL_ToHMI
- Gate commands with safety interlocks (HH, sensor fault) as a defense-in-depth layer

### Single Output Per Functionality

Each control decision must produce **one output variable** that downstream blocks consume. Do not split the same decision across multiple variables or merge two independent sources into one.

**Rule: One variable per interface per functionality.**

```
WRONG (two sources for "fill"):
  FB_LevelControl.oFillRequest  ← analog mode only
  FB_LCA.vDigitalFillLatch      ← digital mode only
  FB_LCA.vFillRequest           ← merges the two (band-aid)

CORRECT (single source):
  FB_LevelControl.oFillRequest  ← covers BOTH modes
  FB_LCA uses vFB_Control.oFillRequest directly everywhere
```

When you find a composite unifying two sources with mode-branching like:
```iecst
(* BAD — control decision leaked into composite *)
IF vIsDigitalMode THEN
    vFillRequest := vDigitalFillLatch;
ELSE
    vFillRequest := vFB_Control.oFillRequest;
END_IF
```
Move the mode-specific logic into the control block so it produces a single output for both modes.

### Variable Chain Rules

Signals flowing from control decision to physical output should follow a minimal chain:

```
Control block output → Composite arbitration → Device input
oFillRequest        → vFillDeviceCmd          → FB_Device.iCommandOn
(1 variable)          (1 variable)              (FB call pin)
```

- **No intermediate "request" variables** between control and arbitration unless required for external export (e.g., `oFillRequest` output pin for shared valve logic)
- **No duplicate variables** carrying the same signal with different names
- **LAD compatibility exception:** Intermediate variables are permitted when needed for FB call pins in LAD-compatible code, but each must carry a distinct signal, not duplicate one

### Sensor Fault Handling Pattern

Sensor faults should flow through the measurement validity path, not as separate control inputs:

```
Composite detects sensor fault → sets vMeasurementValid := FALSE
  → Control block receives iProcessValueValid := FALSE
    → FB_Control sets oFault := TRUE, stops oOutputIncrease
    → Digital fill latch stops (NOT iProcessValueValid is a stop condition)
```

**Rule:** Do not add `iSensorFault` inputs to control blocks. Use `iProcessValueValid := FALSE` to communicate measurement problems. The control block reacts to invalid PV uniformly — no special-casing per fault type.

### Latched Control Patterns

For latched behaviors (e.g., digital fill latch, alarm latching):

1. **Start and stop conditions must be in the same block** — never split start in one FB and stop in another
2. **Edge detection for HMI triggers** — use `vPrev*` pattern for rising-edge commands (e.g., `iStartInitialFill AND NOT vPrevStartInitialFill`)
3. **Timeout belongs with the latch** — the block that owns the latch owns its timeout timer
4. **Safety stop conditions are always checked** — `NOT iEnable`, `NOT iProcessValueValid`, HH latched, timeout must all clear the latch regardless of how it was started

```iecst
(* Pattern: Latched fill with safety stops *)
(* Start conditions *)
IF <start_condition> AND iEnable AND NOT vHighHighLatched AND iProcessValueValid THEN
    vLatch := TRUE;
END_IF

(* Stop conditions — always checked *)
IF <target_reached> OR vHighHighLatched OR vTimeout OR NOT iEnable OR NOT iProcessValueValid THEN
    vLatch := FALSE;
END_IF
```

### Initial Fill Pattern

Initial fill (filling an empty tank from below LoLo to Hi) follows:

1. **HMI arms with `iInitialFillEnable`**, operator triggers with `iStartInitialFill` (edge-detected)
2. **LoLo not required** for initial fill start (tank is empty by definition)
3. **Same stop conditions** as normal fill (Hi reached, HH, timeout, disable, invalid PV)
4. **LL alarm suppressed** during initial fill (tank is intentionally empty)
5. **Implemented in control block**, not composite — initial fill is a control decision

---

## Quick Reference Card

```
Naming:
  UDT_*Type     - Data types          FB_*         - Function blocks
  GVL_*         - Global var lists    FC_*         - Functions
  i*            - Inputs              o*           - Outputs
  v*            - Local variables     c*/CAPS      - Constants

Header:
  (*************** Block Name: ... ***************)

Sections:
  (* === Section Name === *)
  (* ============================================================ *)

Patterns:
  IF NOT vInitialized THEN ... vInitialized := TRUE; END_IF
  CASE vState OF ... ELSE vState := 0; END_CASE
  vFB_Call(iInput := value, oOutput => result);
```

---

*Last updated: 2026-04-22*

# UDT Vertailu: Tuotanto-PLC vs Simulaattori

Vertailu 10 samannimisestä UDT-tyypistä tuotanto-PLC:n (docs/Parameters/) ja simulaattorin (services/codesys/UDTs/) välillä.

**Merkinnät:**
- ✅ = identtinen kenttä molemmissa
- 🟡 = vain tuotannossa
- 🔵 = vain simulaattorissa

---

## 1. UDT_BatchType

| #   | Kenttä    | Tyyppi | Tuotanto | Simulaattori | Tila |
|-----|-----------|--------|----------|--------------|------|
| 1   | BatchCode | INT    | ✓        | ✓            | ✅   |
| 2   | CurStage  | INT    | ✓        | ✓            | ✅   |
| 3   | State     | INT    | ✓        | ✓            | ✅   |
| 4   | ProgId    | INT    | ✓        | ✓            | ✅   |
| 5   | StartTime | LINT   | ✓        | ✓            | ✅   |
| 6   | MinTime   | DINT   | ✓        | ✓            | ✅   |
| 7   | MaxTime   | DINT   | ✓        | ✓            | ✅   |
| 8   | CalTime   | DINT   | ✓        | ✓            | ✅   |

**Yhteenveto:** Identtinen (8/8 kenttää).

---

## 2. UDT_StationType

| #   | Kenttä               | Tyyppi | Tuotanto | Simulaattori | Tila |
|-----|----------------------|--------|----------|--------------|------|
| 1   | StationId            | INT    | ✓        | ✓            | ✅   |
| 2   | TankId               | INT    | ✓        | ✓            | ✅   |
| 3   | IsInUse              | BOOL   | ✓        | ✓            | ✅   |
| 4   | StationType          | INT    | ✓        | ✓            | ✅   |
| 5   | XPosition            | DINT   | ✓        | ✓            | ✅   |
| 6   | YPosition            | DINT   | ✓        | ✓            | ✅   |
| 7   | ZPosition            | DINT   | ✓        | ✓            | ✅   |
| 8   | LiftSinkZone         | INT    | ✓        | ✓            | ✅   |
| 9   | AvoidDistance         | INT    | ✓        | ✓            | ✅   |
| 10  | TakeOutDistance       | INT    | ✓        | ✓            | ✅   |
| 11  | DrippingTime         | INT    | ✓        | ✓            | ✅   |
| 12  | DeviceDelay          | INT    | ✓        | ✓            | ✅   |
| 13  | DryWet               | INT    | ✓        | ✓            | ✅   |
| 14  | Crosstransport       | INT    | ✓        | ✓            | ✅   |
| 15  | CrossTransportTime   | INT    | ✓        | ✓            | ✅   |
| 16  | ChangeStation        | INT    | ✓        | ✓            | ✅   |
| 17  | DeviceConfig         | INT    | ✓        | ✓            | ✅   |
| 18  | Temp_Index           | INT    | ✓        | ✓            | ✅   |
| 19  | Level_Index          | INT    | ✓        | ✓            | ✅   |
| 20  | Cond_Index           | INT    | ✓        | ✓            | ✅   |
| 21  | HasAutomaticRotation | BOOL   | ✓        | ✓            | ✅   |
| 22  | MoveAway             | INT    | ✓        | ✓            | ✅   |

**Yhteenveto:** 22 identtistä. `MoveAway` säilytetty yhteensopivuuden vuoksi. Simulaattori käyttää `TakeOutDelay`/`TakeOutDistance`-kenttiä poissiirtologiikassa.

---

## 3. UDT_TankType

| #   | Kenttä                | Tyyppi | Tuotanto | Simulaattori | Tila |
|-----|-----------------------|--------|----------|--------------|------|
| 1   | TankId                | INT    | ✓        | ✓            | ✅   |
| 2   | EquipmentCode         | STRING | ✓        | ✓            | ✅   |
| 3   | TankName              | STRING | ✓        | ✓            | ✅   |
| 4   | TypeId                | INT    | ✓        | ✓            | ✅   |
| 5   | IsInUse               | BOOL   | ✓        | ✓            | ✅   |
| 6   | LineId                | INT    | ✓        | ✓            | ✅   |
| 7   | GroupId               | INT    | ✓        | ✓            | ✅   |
| 8   | RinseId               | INT    | ✓        | ✓            | ✅   |
| 9   | FilterUnitId          | INT    | ✓        | ✓            | ✅   |
| 10  | Color                 | STRING | ✓        | ✓            | ✅   |
| 11  | XPosition             | DINT   | ✓        | ✓            | ✅   |
| 12  | YPosition             | DINT   | ✓        | ✓            | ✅   |
| 13  | ZPosition             | DINT   | ✓        | ✓            | ✅   |
| 14  | TemperatureControl1Id | INT    | ✓        | ✓            | ✅   |
| 15  | TemperatureControl2Id | INT    | ✓        | ✓            | ✅   |
| 16  | LevelControlId        | INT    | ✓        | ✓            | ✅   |
| 17  | PHControlId           | INT    | ✓        | ✓            | ✅   |
| 18  | ConductivityControlId | INT    | ✓        | ✓            | ✅   |
| 19  | Measurement1Id        | INT    | ✓        | ✓            | ✅   |
| 20  | Measurement2Id        | INT    | ✓        | ✓            | ✅   |
| 21  | Measurement3Id        | INT    | ✓        | ✓            | ✅   |
| 22  | Pump1Idx              | INT    | ✓        | ✓            | ✅   |
| 23  | Pump2Idx              | INT    | ✓        | ✓            | ✅   |
| 24  | Pump3Idx              | INT    | ✓        | ✓            | ✅   |
| 25  | ChemicalDosing1Id     | INT    | ✓        | ✓            | ✅   |
| 26  | ChemicalDosing2Id     | INT    | ✓        | ✓            | ✅   |
| 27  | ChemicalDosing3Id     | INT    | ✓        | ✓            | ✅   |
| 28  | AgitationId           | INT    | ✓        | ✓            | ✅   |
| 29  | MixerId               | INT    | ✓        | ✓            | ✅   |
| 30  | BlowerId              | INT    | ✓        | ✓            | ✅   |
| 31  | CoverId               | INT    | ✓        | ✓            | ✅   |
| 32  | RectifierId           | INT    | ✓        | ✓            | ✅   |

**Yhteenveto:** Identtinen (32/32 kenttää).

---

## 4. UDT_TaskArea

| #   | Kenttä  | Tyyppi | Tuotanto | Simulaattori | Tila |
|-----|---------|--------|----------|--------------|------|
| 1   | MinLift | INT    | ✓        | ✓            | ✅   |
| 2   | MaxLift | INT    | ✓        | ✓            | ✅   |
| 3   | MinSink | INT    | ✓        | ✓            | ✅   |
| 4   | MaxSink | INT    | ✓        | ✓            | ✅   |

**Yhteenveto:** Identtinen (4/4 kenttää).

---

## 5. UDT_TransporterStatusType

| #   | Kenttä                  | Tyyppi | Tuotanto | Simulaattori | Tila |
|-----|-------------------------|--------|----------|--------------|------|
| 1   | TransporterId           | INT    | ✓        | ✓            | ✅   |
| 2   | XPosition               | DINT   | ✓        | ✓            | ✅   |
| 3   | YPosition               | DINT   | ✓        | ✓            | ✅   |
| 4   | ZPosition               | DINT   | ✓        | ✓            | ✅   |
| 5   | CurrentStation          | INT    | ✓        | ✓            | ✅   |
| 6   | LiftStationTarget       | INT    | ✓        | ✓            | ✅   |
| 7   | SinkStationTarget       | INT    | ✓        | ✓            | ✅   |
| 8   | Status                  | INT    | ✓        | ✓            | ✅   |
| 9   | Phase                   | INT    | ✓        | ✓            | ✅   |
| 10  | TaskId                  | LINT   | ✓        | ✓            | ✅   |
| 11  | TaskRemainingTime       | DINT   | ✓        | ✓            | ✅   |
| 12  | LiftStationRemainingTime| DINT   | ✓        | ✓            | ✅   |
| 13  | DrippingTime            | INT    | ✓        | ✓            | ✅   |
| 14  | XDriveTarget            | DINT   | ✓        | ✓            | ✅   |
| 15  | XFinalTarget            | DINT   | ✓        | ✓            | ✅   |
| 16  | YDriveTarget            | DINT   | ✓        | ✓            | ✅   |
| 17  | YFinalTarget            | DINT   | ✓        | ✓            | ✅   |
| 18  | XMinDriveLimit          | DINT   | ✓        | ✓            | ✅   |
| 19  | XMaxDriveLimit          | DINT   | ✓        | ✓            | ✅   |
| 20  | Busy                    | BOOL   | ✓        | ✓            | ✅   |
| 21  | Fault                   | BOOL   | ✓        | ✓            | ✅   |
| 22  | AtPosition              | BOOL   | ✓        | ✓            | ✅   |
| 23  | CanEvade                | BOOL   | ✓        | ✓            | ✅   |
| 24  | Priority                | DINT   | ✓        | ✓            | ✅   |
| 25  | IsActive                | BOOL   | ✓        | ✓            | ✅   |
| 26  | IsCarrying              | BOOL   | ✓        | ✓            | ✅   |
| 27  | CurrentTaskFinishTime   | LINT   | —        | ✓            | 🔵   |

**Yhteenveto:** 26 identtistä, 1 vain simulaattorissa. Simulaattori lisää `CurrentTaskFinishTime` (arvioitu tehtävän valmistumisaika).

---

## 6. UDT_TransporterType

| #   | Kenttä                    | Tyyppi       | Tuotanto | Simulaattori | Tila |
|-----|---------------------------|--------------|----------|--------------|------|
| 1   | TransporterId             | INT          | ✓        | ✓            | ✅   |
| 2   | EquipmentCode             | STRING       | ✓        | ✓            | ✅   |
| 3   | AliasNumber               | INT          | ✓        | ✓            | ✅   |
| 4   | IsInUse                   | BOOL         | ✓        | ✓            | ✅   |
| 5   | Model                     | INT          | ✓        | ✓            | ✅   |
| 6   | LineNumber                | INT          | ✓        | ✓            | ✅   |
| 7   | MinStation                | INT          | ✓        | ✓            | ✅   |
| 8   | MaxStation                | INT          | ✓        | ✓            | ✅   |
| 9   | TaskArea[1..3]            | UDT_TaskArea | ✓        | ✓            | ✅   |
| 10  | ZSensorLowLimit           | INT          | ✓        | ✓            | ✅   |
| 11  | ZSensorHighLimit          | INT          | ✓        | ✓            | ✅   |
| 12  | XSensorLineLimitBackward  | INT          | ✓        | ✓            | ✅   |
| 13  | XSensorLineLimitForward   | INT          | ✓        | ✓            | ✅   |
| 14  | DrivePosMin               | DINT         | ✓        | ✓            | ✅   |
| 15  | DrivePosMax               | DINT         | ✓        | ✓            | ✅   |
| 16  | CrashPosMin               | DINT         | ✓        | ✓            | ✅   |
| 17  | CrashPosMax               | DINT         | ✓        | ✓            | ✅   |
| 18  | YMinDriveLimit            | DINT         | ✓        | ✓            | ✅   |
| 19  | YMaxDriveLimit            | DINT         | ✓        | ✓            | ✅   |
| 20  | PosTolerance_X            | DINT         | ✓        | ✓            | ✅   |
| 21  | PosTolerance_Y            | DINT         | ✓        | ✓            | ✅   |
| 22  | PosLiftSinkTolerance_X    | DINT         | ✓        | ✓            | ✅   |
| 23  | PosValidationEnable_X     | BOOL         | ✓        | ✓            | ✅   |
| 24  | PosMaxChangeRate_X        | DINT         | ✓        | ✓            | ✅   |
| 25  | PosJumpThreshold_X        | DINT         | ✓        | ✓            | ✅   |
| 26  | PosValidationEnable_Z     | BOOL         | ✓        | ✓            | ✅   |
| 27  | PosMaxChangeRate_Z        | DINT         | ✓        | ✓            | ✅   |
| 28  | PosJumpThreshold_Z        | DINT         | ✓        | ✓            | ✅   |
| 29  | CollisionWidth            | DINT         | ✓        | ✓            | ✅   |
| 30  | AvoidanceWidth            | DINT         | ✓        | ✓            | ✅   |
| 31  | AbsToPosDirection_X       | DINT         | ✓        | ✓            | ✅   |
| 32  | AbsToPosOffset_X          | DINT         | ✓        | ✓            | ✅   |
| 33  | AbsToPosDirection_Y       | DINT         | ✓        | ✓            | ✅   |
| 34  | AbsToPosOffset_Y          | DINT         | ✓        | ✓            | ✅   |
| 35  | PosMaxSensor_X            | DINT         | ✓        | ✓            | ✅   |
| 36  | PosMaxSensor_Y            | DINT         | ✓        | ✓            | ✅   |
| 37  | SpeedMax_X                | DINT         | ✓        | ✓            | ✅   |
| 38  | SpeedMax_Y                | DINT         | ✓        | ✓            | ✅   |
| 39  | SpeedMax_Z                | DINT         | ✓        | ✓            | ✅   |
| 40  | MaximumSpeed              | INT          | ✓        | ✓            | ✅   |
| 41  | SpeedSemiAuto_X           | DINT         | ✓        | ✓            | ✅   |
| 42  | SpeedSemiAuto_Y           | DINT         | ✓        | ✓            | ✅   |
| 43  | SpeedSemiAuto_Z           | DINT         | ✓        | ✓            | ✅   |
| 44  | SpeedManual_X             | DINT         | ✓        | ✓            | ✅   |
| 45  | SpeedManualFast_X         | DINT         | ✓        | ✓            | ✅   |
| 46  | SpeedManual_Y             | DINT         | ✓        | ✓            | ✅   |
| 47  | SpeedManualFast_Y         | DINT         | ✓        | ✓            | ✅   |
| 48  | SpeedManual_Z             | DINT         | ✓        | ✓            | ✅   |
| 49  | SpeedManualFast_Z         | DINT         | ✓        | ✓            | ✅   |
| 50  | DecelerationDistance_X    | DINT         | ✓        | ✓            | ✅   |
| 51  | CrawlDistance_X           | DINT         | ✓        | ✓            | ✅   |
| 52  | SpeedCrawl_X              | DINT         | ✓        | ✓            | ✅   |
| 53  | Acceleration_X            | DINT         | ✓        | ✓            | ✅   |
| 54  | Acceleration_Y            | DINT         | ✓        | ✓            | ✅   |
| 55  | Acceleration_Z            | DINT         | ✓        | ✓            | ✅   |
| 56  | Deceleration_X            | DINT         | ✓        | ✓            | ✅   |
| 57  | Deceleration_Y            | DINT         | ✓        | ✓            | ✅   |
| 58  | Deceleration_Z            | DINT         | ✓        | ✓            | ✅   |
| 59  | SpeedLiftSlow_Z           | DINT         | ✓        | ✓            | ✅   |
| 60  | SpeedLiftMid_Z            | DINT         | ✓        | ✓            | ✅   |
| 61  | SpeedLiftFast_Z           | DINT         | ✓        | ✓            | ✅   |
| 62  | SpeedSinkSlow_Z           | DINT         | ✓        | ✓            | ✅   |
| 63  | SpeedSinkMid_Z            | DINT         | ✓        | ✓            | ✅   |
| 64  | SpeedSinkFast_Z           | DINT         | ✓        | ✓            | ✅   |
| 65  | LiftWetSlowTime           | DINT         | ✓        | ✓            | ✅   |
| 66  | LiftWetMidTime            | DINT         | ✓        | ✓            | ✅   |
| 67  | LiftWetFastTime           | DINT         | ✓        | ✓            | ✅   |
| 68  | LiftDrySlowTime           | DINT         | ✓        | ✓            | ✅   |
| 69  | LiftDryFastTime           | DINT         | ✓        | ✓            | ✅   |
| 70  | SinkWetMidTime            | DINT         | ✓        | ✓            | ✅   |
| 71  | SinkWetFastTime           | DINT         | ✓        | ✓            | ✅   |
| 72  | SinkDryFastTime           | DINT         | ✓        | ✓            | ✅   |
| 73  | HookingInUse              | BOOL         | ✓        | ✓            | ✅   |
| 74  | HookingOffset             | DINT         | ✓        | ✓            | ✅   |
| 75  | BarrelRotationInUse       | BOOL         | ✓        | ✓            | ✅   |
| 76  | DripTrayInUse             | BOOL         | ✓        | ✓            | ✅   |
| 77  | MovesEmptyAtDown          | BOOL         | ✓        | ✓            | ✅   |
| 78  | ZAxisHasEncoder           | BOOL         | ✓        | ✓            | ✅   |
| 79  | ZPosUp                    | DINT         | ✓        | ✓            | ✅   |
| 80  | ZPosDown                  | DINT         | ✓        | ✓            | ✅   |
| 81  | ZPosSlowUp                | DINT         | ✓        | ✓            | ✅   |
| 82  | ZPosSlowDown              | DINT         | ✓        | ✓            | ✅   |
| 83  | ZPosSlowEnd               | DINT         | ✓        | ✓            | ✅   |
| 84  | ZPosProduct               | DINT         | ✓        | ✓            | ✅   |
| 85  | ZPosDrip                  | DINT         | ✓        | ✓            | ✅   |
| 86  | ZPosTolerance             | DINT         | ✓        | ✓            | ✅   |
| 87  | StallFilterTime_X         | DINT         | ✓        | ✓            | ✅   |
| 88  | StallMinDistance_X        | DINT         | ✓        | ✓            | ✅   |
| 89  | StallFilterTime_Z         | DINT         | ✓        | ✓            | ✅   |
| 90  | StallMinDistance_Z        | DINT         | ✓        | ✓            | ✅   |
| 91  | SpeedLiftMax              | DINT         | ✓        | ✓            | ✅   |
| 92  | SpeedDriveMax             | DINT         | ✓        | ✓            | ✅   |
| 93  | DriveAcceleration         | DINT         | ✓        | ✓            | ✅   |
| 94  | DriveDeceleration         | DINT         | ✓        | ✓            | ✅   |
| 95  | DripTrayDelay             | INT          | ✓        | ✓            | ✅   |

**Yhteenveto:** Identtinen (95/95 kenttää).

---

## 7. UDT_TreatmentProgramStepType

| #   | Kenttä         | Tyyppi | Tuotanto | Simulaattori | Tila |
|-----|----------------|--------|----------|--------------|------|
| 1   | MinTime        | DINT   | ✓        | ✓            | ✅   |
| 2   | MaxTime        | DINT   | ✓        | ✓            | ✅   |
| 3   | CalTime        | DINT   | ✓        | ✓            | ✅   |
| 4   | StationCount   | INT    | ✓        | ✓            | ✅   |
| 5   | Stations[0..4] | INT    | ✓        | ✓            | ✅   |

**Yhteenveto:** Identtinen (5/5 kenttää).

---

## 8. UDT_TreatmentProgramType

| #   | Kenttä      | Tyyppi                       | Tuotanto | Simulaattori | Tila |
|-----|-------------|------------------------------|----------|--------------|------|
| 1   | ProgramId   | INT                          | ✓        | ✓            | ✅   |
| 2   | ProgramName | STRING                       | ✓        | ✓            | ✅   |
| 3   | StepCount   | INT                          | ✓        | ✓            | ✅   |
| 4   | Steps[0..30]| UDT_TreatmentProgramStepType | ✓        | ✓            | ✅   |

**Yhteenveto:** Identtinen (4/4 kenttää).

---

## 9. UDT_JC_UnitAtStationType

| #   | Kenttä     | Tyyppi | Tuotanto | Simulaattori | Tila |
|-----|------------|--------|----------|--------------|------|
| 1   | UnitId     | INT    | ✓        | ✓            | ✅   |
| 2   | ChangeTime | LINT   | ✓        | ✓            | ✅   |

**Yhteenveto:** Identtinen (2/2 kenttää).

---

## 10. UDT_JC_UnitType

| #   | Kenttä           | Tyyppi         | Tuotanto | Simulaattori | Tila |
|-----|------------------|----------------|----------|--------------|------|
| 1   | Location         | INT            | ✓        | ✓            | ✅   |
| 2   | Status           | INT            | ✓        | ✓            | ✅   |
| 3   | Target           | INT            | ✓        | ✓            | ✅   |
| 4   | StationIndex     | INT            | ✓        | —            | 🟡   |
| 5   | Stage            | INT            | ✓        | —            | 🟡   |
| 6   | ElapsedTime      | DINT           | ✓        | —            | 🟡   |
| 7   | RemainingTime    | INT            | ✓        | —            | 🟡   |
| 8   | NextStationIndex | INT            | ✓        | —            | 🟡   |
| 9   | IsReady          | BOOL           | ✓        | —            | 🟡   |
| 10  | IsOverdue        | BOOL           | ✓        | —            | 🟡   |
| 11  | Charge           | UDT_ChargeType | ✓        | —            | 🟡   |

**Yhteenveto:** 3 yhteistä, 8 vain tuotannossa. Simulaattori käyttää minimaali-versiota koska scheduler hallitsee runtime-tilaa erillisillä tietorakenteilla (g_batch, g_schedule).

---

## Kokonaiskuva

| UDT                          | Tuotanto | Simulaattori | Yhteisiä | Vain tuotanto 🟡 | Vain simulaattori 🔵       |
|------------------------------|----------|--------------|----------|-------------------|-----------------------------|
| UDT_BatchType                | 8        | 8            | 8        | 0                 | 0                           |
| UDT_StationType              | 22       | 22           | 22       | 0                 | 0                           |
| UDT_TankType                 | 32       | 32           | 32       | 0                 | 0                           |
| UDT_TaskArea                 | 4        | 4            | 4        | 0                 | 0                           |
| UDT_TransporterStatusType    | 26       | 27           | 26       | 0                 | 1 (CurrentTaskFinishTime)   |
| UDT_TransporterType          | 95       | 95           | 95       | 0                 | 0                           |
| UDT_TreatmentProgramStepType | 5        | 5            | 5        | 0                 | 0                           |
| UDT_TreatmentProgramType     | 4        | 4            | 4        | 0                 | 0                           |
| UDT_JC_UnitAtStationType             | 2        | 2            | 2        | 0                 | 0                           |
| UDT_JC_UnitType                 | 11       | 3            | 3        | 8                 | 0                           |
| **YHTEENSÄ**                 | **208**  | **202**      | **200**  | **8**             | **2**                       |

### Erot tiivistettynä

**Simulaattorissa lisäkenttiä (🔵):**

- `UDT_TransporterStatusType.CurrentTaskFinishTime` — arvioitu tehtävän valmistumisaika (LINT, unix s)

**Tuotannossa lisäkenttiä (🟡):**
- `UDT_JC_UnitType` — 8 runtime-kenttää (StationIndex, Stage, ElapsedTime, RemainingTime, NextStationIndex, IsReady, IsOverdue, Charge). Simulaattori ei tarvitse näitä koska scheduler käyttää omia rakenteita (g_batch, g_schedule, g_task).

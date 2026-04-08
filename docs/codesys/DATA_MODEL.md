# Tietomalli

## Yleiskuva

Kaikki PLC-data koostuu kolmesta tasosta:

1. **GVL (Global Variable Lists)** — ajoaikaiset muuttujat ja vakiot
2. **UDT (User Data Types)** — rakenteelliset tietotyypit
3. **VAR_IN_OUT** — funktiokutsuissa välitettävät taulukkoviittaukset

## GVL-rakenteet

### GVL_JC_Constants — Vakiot 🔒

Kirjaston sisäinen. Kaikki taulukkorajat ja algoritmien kynnysarvot. Tämä on ainoa paikka, josta rajat muutetaan.

| Vakio | Arvo | Käyttötarkoitus |
|-------|------|-----------------|
| `MAX_Transporters` | 3 | Nostinten maksimimäärä |
| `MAX_Units` | 10 | Nostolaitteiden (hook/frame) maksimimäärä |
| `MAX_STATIONS_PER_LINE` | 30 | Asemien maksimimäärä per linja |
| `MIN_StationIndex` | 100 | Ensimmäinen asemaindeksi |
| `MAX_StationIndex` | 130 | Viimeinen asemaindeksi |
| `MAX_STEPS_PER_PROGRAM` | 30 | Käsittelyohjelman vaiheiden maksimi |
| `MAX_TASK_QUEUE` | 30 | Tehtäväjonon koko per nostin |
| `MAX_LOCKS` | 50 | Lukkotilojen maksimi konfliktisilmukassa |
| `DEP_MAX_IDLE_SLOTS` | 20 | Tyhjien aikaikkunoiden maksimi per nostin |
| `DEP_MAX_WAITING` | 5 | Odottavien erien maksimi |
| `SCH_DISPATCH_MARGIN_S` | 3.0 | Dispatchin aikaisuusmarginaali (s) |
| `SCH_CONFLICT_MARGIN_S` | 1.0 | Konfliktin tunnistusmarginaali (s) |
| `SCH_FLEX_FACTOR` | 0.5 | DEP:n käyttämä osuus käsittelyajan liukumasta |

**Tärkeää:** `build_codesys_xml.py` sisältää näiden vakioiden numeeriset arvot (`CONST_VALUES`-dict), jotta PLCopenXML:n taulukkorajat voidaan generoida numeerisina literaaleina. Jos GVL-vakion arvo muuttuu, se pitää päivittää myös build-skriptiin.

### GVL_JC_Scheduler — Ajoaikaiset muuttujat 🔒

Kirjaston sisäinen. Schedulerin sisäiset taulukot, jotka jaetaan POU:ien välillä:

| Muuttuja | Tyyppi | Kirjoittaja | Lukija |
|----------|--------|-------------|--------|
| `g_schedule[1..10]` | UDT_JC_TskScheduleType | TSK/DEP | UI, SIM |
| `g_task[1..3]` | UDT_JC_TskQueueType | TSK | DispatchTask, SIM |
| `g_ntt[1..3]` | UDT_JC_NttTransporterType | NoTreatmentStates | TSK_NoTreatment |
| `g_move[1..3]` | UDT_JC_MoveTimesType | Gateway/SIM | CalcTransferTime |
| `g_actual_move[1..3]` | UDT_JC_ActualMoveTimeType | SIM | TrackMoveTimes |
| `g_sim_trans[1..3]` | UDT_JC_SimTransporterType | SIM | SIM |
| `g_dep_wk_schedule[1..10]` | UDT_JC_TskScheduleType | DEP | DEP |
| `g_dep_wk_task[1..3]` | UDT_JC_TskQueueType | DEP | DEP |
| `g_dep_wk_batch[1..10]` | UDT_BatchType | DEP | DEP |
| `g_dep_wk_program[1..10]` | UDT_TreatmentProgramType | DEP | DEP |
| `g_dep_idle_slot[1..3]` | UDT_JC_DepIdleSlotSetType | DEP | DEP |
| `g_dep_overlap` | UDT_JC_DepOverlapType | DEP | DEP |
| `g_dep_pending` | UDT_JC_DepPendingWriteType | DEP | TSK |
| `g_tsk_stable` | BOOL | TSK | DEP |
| `g_conflict_resolved` | BOOL | TSK | MainScheduler |

### GVL_Parameters — Konfiguraatiodata 🔌

Kirjaston rajapinta. Asiakas (tai kehitysympäristön Gateway) kirjoittaa nämä muuttujat.
Kirjasto lukee ne ja kirjoittaa laskentatulokset takaisin.

| Muuttuja | Tyyppi | Suunta |
|----------|--------|--------|
| `Stations[100..130]` | UDT_StationType | Asiakas → kirjasto |
| `g_cfg[1..3]` | UDT_TransporterType | Asiakas → kirjasto |
| `g_transporter[1..3]` | UDT_TransporterStatusType | Kirjasto → asiakas |
| `g_unit[1..10]` | UDT_UnitType | Asiakas ↔ kirjasto |
| `g_batch[1..10]` | UDT_BatchType | Asiakas ↔ kirjasto |
| `g_program[1..10]` | UDT_TreatmentProgramType | Asiakas ↔ kirjasto |
| `g_station_loc[1..130]` | UDT_UnitLocation | Kirjasto → asiakas |

---

## UDT-tyypit ryhmittäin

### Tuotantoprosessin ydin

#### UDT_UnitType — Nostolaite
```
Location    : INT     asema jossa unit sijaitsee
Status      : INT     NOT_USED=0, USED=1
Target      : INT     TO_NONE=0, TO_LOADING=1, TO_BUFFER=2, TO_PROCESS=3,
                      TO_UNLOAD=4, TO_AVOID=5
```

#### UDT_BatchType — Tuotantoerä
```
BatchCode   : INT     erän tunniste
CurStage    : INT     nykyinen käsittelyvaihe, 0 = ei aloitettu
State       : INT     NOT_PROCESSED=0, IN_PROCESS=1, PROCESSED=2
ProgId      : INT     käsittelyohjelman numero
StartTime   : LINT    aloitusaika (unix seconds)
MinTime     : DINT    nykyisen vaiheen min-aika (s)
MaxTime     : DINT    nykyisen vaiheen max-aika (s)
CalTime     : DINT    nykyisen vaiheen tavoiteaika (s)
```

#### UDT_TreatmentProgramType — Käsittelyohjelma
```
ProgramId   : INT
ProgramName : STRING
StepCount   : INT     vaiheiden lukumäärä
Steps       : ARRAY[0..30] OF UDT_TreatmentProgramStepType
```

#### UDT_TreatmentProgramStepType — Ohjelmavaihe
```
MinTime      : DINT    min käsittelyaika (s)
MaxTime      : DINT    max käsittelyaika (s)
CalTime      : DINT    laskennallinen käsittelyaika (s)
StationCount : INT     vaihtoehtoisten asemien lukumäärä
Stations     : ARRAY[0..4] OF INT    asemaindeksit
```

#### UDT_StationType — Käsittelyasema
```
StationId      : INT     pääavain
XPosition      : DINT    X-sijainti (mm)
YPosition      : DINT    Y-sijainti (mm)
ZPosition      : DINT    Z-sijainti (mm)
DrippingTime   : INT     tippumisaika (×10 = 0.1 s)
DeviceDelay    : INT     laiteviive (×10 = 0.1 s)
Crosstransport : INT     poikkisiirtoindeksi
ChangeStation  : INT     vaihtoasemaindeksi
TakeOutDelay   : INT     poissiirtoviive (s), 0 = ei poissiirtoa
TakeOutDistance : INT     poissiirtoetäisyys (mm)
AvoidDistance  : INT     asemakohtainen väistöetäisyys (mm)
...                      (lisää kenttiä: DryWet, LiftSinkZone)
```

### Schedulerin tietorakenteet

#### UDT_JC_TskScheduleType — Laskettu aikataulu
```
StageCount  : INT
Stages      : ARRAY[0..30] OF UDT_JC_TskStageType
```

#### UDT_JC_TskStageType — Aikatauluvaiheen tiedot
```
Station      : INT     asema, 0 = tyhjä
ProgramStage : INT     ohjelmavaiheen numero
EntryTime    : LINT    saapumisaika (unix s)
ExitTime     : LINT    lähtöaika (unix s)
MinTime      : DINT    min-aika (s)
CalcTime     : DINT    tavoiteaika (s)
MaxTime      : DINT    max-aika (s)
TransferTime : DINT    siirtoaika edelliseltä asemalta (s)
```

#### UDT_JC_TskQueueType — Tehtäväjono
```
Count : INT
Queue : ARRAY[1..30] OF UDT_JC_TskTaskType
```

#### UDT_JC_TskTaskType — Siirtotehtävä
```
Unit              : INT     yksikön indeksi
Stage             : INT     kohdevaihe
SrcStage          : INT     lähtövaihe
LiftStationTarget : INT     nostoasema
SinkStationTarget : INT     laskuasema
StartTime         : LINT    alkuaika (unix s)
FinishTime        : LINT    valmistumisaika (unix s)
CalcTime          : DINT    käsittelyn tavoiteaika (flex laskentaan)
MinTime           : DINT    min (flex_down)
MaxTime           : DINT    max (flex_up)
NttPrimary        : INT     1 = NTT-pääkohde
```

#### UDT_JC_TskLockType — Konfliktisilmukan lukko
```
Unit      : INT     yksikkö, 0 = tyhjä
Stage     : INT     vaihe
Direction : INT     1=ADVANCE, 2=DELAY
```

#### UDT_JC_TskStretchType — Resolve-päätös
```
Unit    : INT     yksikkö
Stage   : INT     vaihe
DelayS  : DINT    viive sekunneissa (positiivinen = viive, negatiivinen = ennakko)
```

### Nostinrakenteet

#### UDT_TransporterStatusType — Ajoaikaiset tiedot
```
TransporterId        : INT
XPosition            : DINT    nykyinen X (mm)
Phase                : INT     0=idle, 1=to_lift, 2=lift, 3=to_sink, 4=sink
TaskId               : LINT    aktiivinen tehtävä-ID
LiftStationTarget    : INT
SinkStationTarget    : INT
XMinDriveLimit       : DINT    TWA:n laskema X-alaraja (mm)
XMaxDriveLimit       : DINT    TWA:n laskema X-yläraja (mm)
IsActive             : BOOL
IsCarrying           : BOOL
CurrentTaskFinishTime : LINT
```

#### UDT_TransporterType — Konfiguraatio (laaja, 100+ kenttää)
Tärkeimmät ryhmät:
- **Identiteetti:** TransporterId, LineNumber, MinStation, MaxStation
- **Tehtäväalueet:** TaskAreas[1..3] OF UDT_TaskArea (lift/sink-asemarajat)
- **Nopeudet:** SpeedMax_X/Y/Z, kiihtyvyydet, hidastuvuudet
- **Z-nosto/lasku:** LiftWetSlowTime, SinkWetFastTime, ...
- **Tippumalusikka:** DripTrayInUse, DripTrayDelay

#### UDT_TaskArea — Tehtäväalueen rajat
```
MinLift : INT     alin nostoasema
MaxLift : INT     ylin nostoasema
MinSink : INT     alin laskuasema
MaxSink : INT     ylin laskuasema
```

### DEP-rakenteet

#### UDT_JC_DepPendingWriteType — Aktivointipyyntö (DEP → TSK)
```
Valid        : BOOL
Programs     : ARRAY[1..10] OF UDT_TreatmentProgramType
BatchUnit    : INT      aktivoitava yksikkö
BatchStage   : INT      nykyinen vaihe
BatchState   : INT      uusi tila (IN_PROCESS)
BatchMinTime : DINT     vaiheen 0 min-aika
BatchMaxTime : DINT     vaiheen 0 max-aika
BatchCalTime : DINT     vaiheen 0 tavoiteaika
TimeStamp    : LINT     aktivointiaika
```

#### UDT_JC_DepIdleSlotType — Vapaa aikaikkuna
```
StartTime          : LINT    ikkunan alku (unix s)
EndTime            : LINT    ikkunan loppu (unix s), 0 = avoin
LiftStationTarget  : INT     nostin tässä asemassa ikkunan alussa
SinkStationTarget  : INT     nostin tässä asemassa ikkunan lopussa
```

#### UDT_JC_DepIdleSlotSetType — Nostimen vapaat ikkunat
```
Slots : ARRAY[1..20] OF UDT_JC_DepIdleSlotType    (DEP_MAX_IDLE_SLOTS)
Count : INT
```

#### UDT_JC_DepOverlapType — Jaettujen asemien kartta
```
Flags : ARRAY[0..200] OF BOOL    TRUE = asema useamman nostimen alueella
Count : INT
```

### Simulaatiorakenteet

#### UDT_JC_SimTransporterType — Nostimen fysiikkatila
```
RunningTaskId   : LINT    aktiivinen tehtävä-ID
TreatmentTime   : DINT    käsittelyaika (s)
XVelocity       : DINT    X-nopeus (mm/s)
ZStage          : INT     Z-liikkeen alivaihe
ZTimer          : REAL    Z-ajastin
IdleStartTime   : LINT    tyhjäkäynnin alkuaika
```

#### UDT_JC_MoveTimesType — Esioletetut siirtoajat
```
LiftTime : ARRAY[1..30] OF INT     nostoaika per asema (×10 s)
SinkTime : ARRAY[1..30] OF INT     laskuaika per asema (×10 s)
Travel   : ARRAY[1..30] OF UDT_JC_TravelFromType
             Travel[from].ToTime[to] = vaakasiirtoaika (×10 s)
```

#### UDT_JC_ActualMoveTimeType — Mitatut vaiheen aikaleimat
```
ts0 : LINT    0→1 siirto nostoasemalle alkaa
ts1 : LINT    1→2 nosto alkaa
ts2 : LINT    2→3 siirto laskuasemalle alkaa
ts3 : LINT    3→4 lasku alkaa
ts4 : LINT    4→0 lasku päättyy
```

#### UDT_JC_EventMsgType — Tapahtumasanoma
```
Seq     : INT             juokseva numero
MsgType : INT             sanomatyyppi (1=dispatch, 2=lift, ...)
TsHi    : INT             aikaleima yläosat (unix s)
TsLo    : INT             aikaleima alaosat
Payload : ARRAY[1..12] OF INT    sanomatyyppikohtainen sisältö
```

---

## Taulukkokokojen riippuvuudet

Seuraavat koot ovat sidottuja GVL_JC_Constants-vakioihin:

| Taulukkokoko | Vakio | Esiintyy |
|--------------|-------|----------|
| `ARRAY[1..10]` | MAX_Units | schedule, batch, program, unit |
| `ARRAY[1..3]` | MAX_Transporters | task, cfg, transporter, move |
| `ARRAY[1..30]` | MAX_TASK_QUEUE | Queue (UDT_JC_TskQueueType) |
| `ARRAY[0..30]` | MAX_STEPS_PER_PROGRAM | Stages (UDT_JC_TskScheduleType), Steps (Program) |
| `ARRAY[1..50]` | MAX_LOCKS | locks (TSK_FB_Scheduler) |
| `ARRAY[1..20]` | DEP_MAX_IDLE_SLOTS | Slots (UDT_JC_DepIdleSlotSetType) |
| `ARRAY[100..130]` | MIN..MAX_StationIndex | Stations |

**Huom:** `VAR_IN_OUT`-parametreissa taulukkokoot on kirjoitettu numeerisina literaaleina (IEC 61131-3 rajoitus). Nämä on dokumentoitu kommenteilla kunkin POU:n VAR_IN_OUT-lohkossa.

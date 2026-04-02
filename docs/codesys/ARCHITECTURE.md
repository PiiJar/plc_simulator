# Arkkitehtuuri

## Toimitusraja

```
ASIAKKAAN PLC-PROJEKTI (avoin)       LUKITTU KIRJASTO (salattu)
┌────────────────────────────┐   ┌──────────────────────────────────┐
│  PLC_PRG                   │   │  STC_FB_MainScheduler ← entry pt │
│  (asiakas integroi)        │──▶│  TSK_*, DEP_*, STC_*, TWA_*      │
│  HW-ajurit, liitännät     │   │  GVL_JC_Constants                │
│  GVL_Parameters (konfig.)  │   │  GVL_JC_Scheduler                │
│                            │   │  UDT_* (32 kpl)                  │
└────────────────────────────┘   └──────────────────────────────────┘

KEHITYSYMPÄRISTÖ (ei toimiteta)
┌────────────────────────────────────────────────────┐
│  PLC_PRG (testi-integraatio)                       │
│  SIM_FB_RunTasks, SIM_FB_XMotion, SIM_FB_ZMotion   │
│  SIM_FB_EventQueue, SIM_FB_ClearConfig              │
│  SIM_FindStation                                    │
│  Docker-infra, Gateway, UI                          │
└────────────────────────────────────────────────────┘
```

Kirjaston **entry point** on `STC_FB_MainScheduler`. Asiakas luo siitä instanssin
omassa PLC_PRG:ssaan ja kutsuu sitä joka jaksolla. Kaikki MainScheduler:sta
"alaspäin" olevat funktiot kuuluvat lukittuun kirjastoon.

SIM-kerros on kehitysympäristön testikerros, joka simuloi nostimien fyysistä liikettä.
Tuotantokäytössä asiakas korvaa sen omilla HW-ajureillaan.

## Kerrosmalli (kirjaston sisäinen)

```
┌───────────────────────────────────────────────────────┐
│  STC_FB_MainScheduler  (FUNCTION_BLOCK)               │
│  Kirjaston entry point: vuorottelu, dispatch, debug    │
├──────────────────────┬────────────────────────────────┤
│  TSK_FB_Scheduler    │  DEP_FB_Scheduler              │
│  Aktiiviset erät     │  Odottavat erät (sandbox)      │
│  Konfliktiratkaisu   │  Idle-slot-sovitus             │
├──────────────────────┴────────────────────────────────┤
│  STC_*  — Jaetut laskentafunktiot                     │
│  CalcSchedule, CreateTasks, SortTasks, ShiftSchedule  │
│  FindTransporter, CalcTransferTime, DispatchTask ...  │
├───────────────────────────────────────────────────────┤
│  TWA_FB_CalcLimits — Törmäyksenesto (X-rajat)         │
├───────────────────────────────────────────────────────┤
│  GVL_JC_Constants  │  GVL_JC_Scheduler                │
│  UDT-tyypit (32 kpl)                                 │
└───────────────────────────────────────────────────────┘

Erikseen (kehitysympäristö, ei osa kirjastoa):
┌───────────────────────────────────────────────────────┐
│  SIM_*  — Simulaatiokerros (testaus)                  │
│  RunTasks (fysiikka), EventQueue, XMotion, ZMotion    │
└───────────────────────────────────────────────────────┘
```

## Suoritusvirta per PLC-jakso

### Tuotantokäytössä (asiakkaan PLC_PRG)

Asiakas kutsuu kirjastoa omasta pääohjelmastaan:

```
Asiakkaan PLC_PRG (yksi scan cycle)
│
├─ ... asiakkaan oma alustuslogiikka ...
├─ ... HW-ajurit: nostimien ohjaus ja tilapalaute ...
│
├─ STC_FB_MainScheduler(i_run := TRUE, i_time_s := unix_aika)
│     ├─ STC_DispatchTask()       ← joka jakso
│     │    Validoi ja lähettää seuraava tehtävä odottavalle nostimelle.
│     │
│     ├─ IF vuoro = TSK:
│     │    TSK_FB_Scheduler()     ← yksi vaihe per jakso
│     │
│     └─ ELIF vuoro = DEP:
│          DEP_FB_Scheduler()     ← yksi vaihe per jakso
│
└─ ... asiakkaan oma logiikka ...
```

### Kehitysympäristössä (testi-PLC_PRG)

Kehitysympäristön PLC_PRG lisää simulaatiokerroksen:

```
Testi-PLC_PRG (yksi scan cycle)
│
├─ 1. TWA_FB_CalcLimits()
│     Laskee jokaiselle nostimelle X-ajo-rajat
│     törmäyksen ehkäisemiseksi.
│
├─ 2. Aikasynkronointi
│     g_time_s := uptime + g_time_offset
│     g_time_100ms := g_time_s × 10  (0.1 s tikki)
│
├─ 3. SIM_FB_RunTasks()                ← EI OLE OSA KIRJASTOA
│     Simuloi nostimien X/Z-liikettä.
│     Generoi tapahtumia (lift_begin, task_complete, ...).
│     Päivittää g_station_loc[], g_transporter[].
│
├─ 4. STC_FB_MainScheduler()          ← KIRJASTON ENTRY POINT
│     ├─ STC_DispatchTask()       ← joka jakso
│     │
│     ├─ IF vuoro = TSK:
│     │    TSK_FB_Scheduler()     ← yksi vaihe per jakso
│     │
│     └─ ELIF vuoro = DEP:
│          DEP_FB_Scheduler()     ← yksi vaihe per jakso
│
└─ 5. SIM_FB_EventQueue()             ← EI OLE OSA KIRJASTOA
       Kierrättää tapahtumasanomia OPC UA → Gateway.
```

## Vuorottelumalli: TSK ja DEP

TSK ja DEP eivät koskaan suorita samalla PLC-jaksolla. MainScheduler hallitsee vuoroa:

```
Jakso N:    TSK suorittaa vaiheen (esim. 2100 SORT_TASKS)
Jakso N+1:  DEP suorittaa vaiheen (esim. 2300 CALC_IDLE)
Jakso N+2:  TSK suorittaa vaiheen (esim. 2101 SWAP_TASKS)
...
```

**Poikkeukset:**

- DEP skipataan, jos TSK ei ole valmis (phase < 10000)
- DEP skipataan, jos `g_dep_pending.Valid = TRUE` (edellinen aktivointi odottaa TSK:n käsittelyä)

## Tietovirran jako

```
Asiakkaan integraatio (tai kehitysympäristön Gateway)
    │
    ▼ kirjoittaa globaaleihin
g_station[], g_cfg[], g_unit[], g_batch[], g_program[]
g_cmd_code, g_time_sync
    │
    ▼ kirjaston sisäinen laskenta
STC_FB_MainScheduler
    ├─ TSK_FB_Scheduler
    │    käyttää suoraan g_schedule[], g_task[], g_batch[]
    │
    └─ DEP_FB_Scheduler
         kopioi: g_batch[], g_program[] → g_dep_wk_*  (sandbox)
         kirjoittaa: g_dep_pending (aktivointipyyntö)
    │
    ▼ asiakas lukee tulokset
g_transporter[], g_schedule[], g_task[]
```

**Rajapintaperiaate:** Asiakas (tai HW-kerros) kirjoittaa konfiguraation ja tilapäivitykset
globaaleihin taulukoihin. Kirjasto lukee ne ja kirjoittaa laskentatulokset takaisin.
Kirjaston sisäiset taulukot (`g_dep_wk_*`, `g_dep_pending` ym.) eivät kuulu rajapintaan.

**Keskeinen periaate:** DEP ei koskaan kirjoita suoraan globaaleihin taulukoihin. Se operoi sandbox-kopioilla (`g_dep_wk_*`) ja välittää tuloksen `g_dep_pending`-rakenteen kautta, jonka TSK käsittelee seuraavalla kierroksellaan.

## Tiedostorakenne

```
services/codesys/
├── GVLs/
│   ├── GVL_JC_Constants.st    Globaalit vakiot (rajat, kynnysarvot)     [KIRJASTO]
│   ├── GVL_JC_Scheduler.st    Schedulerin ajoaikamuuttujat              [KIRJASTO]
│   └── GVL_Parameters.st      Asiakkaan kirjoittama konfiguraatio       [RAJAPINTA]
│
├── UDTs/                      32 tietotyyppiä (ks. DATA_MODEL.md)       [KIRJASTO]
│
├── POUs/
│   ├── plc_prg.st             Testi-integraatio                         [KEHITYS]
│   ├── STC_FB_MainScheduler.st  Kirjaston entry point                   [KIRJASTO]
│   ├── TSK_FB_Scheduler.st    Task Scheduler -tilakone                  [KIRJASTO]
│   ├── TSK_Analyze.st         Konfliktianalyysi                         [KIRJASTO]
│   ├── TSK_Resolve.st         Konfliktiratkaisu                         [KIRJASTO]
│   ├── TSK_NoTreatment.st     Ei-käsittely-siirrot                     [KIRJASTO]
│   ├── DEP_FB_Scheduler.st    Departure Scheduler -tilakone             [KIRJASTO]
│   ├── DEP_*.st               DEP-apufunktiot (6 kpl)                  [KIRJASTO]
│   ├── STC_*.st               Jaetut laskentafunktiot (15 kpl)         [KIRJASTO]
│   ├── TWA_FB_CalcLimits.st   Törmäyksenestolaskenta                   [KIRJASTO]
│   └── SIM/                   Simulaatiokerros (6 tiedostoa)            [KEHITYS]
│
├── build_codesys_xml.py       PLCopenXML-generaattori                   [KEHITYS]
└── build/                     Generoitu XML-tiedosto                    [KEHITYS]
```

## Nimikäytännöt

| Prefiksi | Merkitys | Tyyppi |
|----------|----------|--------|
| `TSK_` | Task Scheduler | FB / FC |
| `DEP_` | Departure Scheduler | FB / FC |
| `STC_` | Scheduler Tool Collection | FC (yleensä) |
| `SIM_` | Simulation | FB / FC |
| `TWA_` | Transporter Working Area | FB |
| `UDT_` | User Data Type | TYPE |
| `GVL_` | Global Variable List | VAR_GLOBAL |
| `g_` | Globaali muuttuja | — |
| `i_` | Sisääntulo (VAR_INPUT) | — |
| `o_` | Ulostulo (VAR_OUTPUT) | — |
| `io_` | Sisään/ulos (VAR_IN_OUT) | — |
| `fb_` | FB-instanssi lokaalissa | — |
| `_FB_` | Function Block (tila-avaruus) | — |

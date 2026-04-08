# Scheduler-tilakoneet

> Tilakoneet ovat kirjaston sisäistä logiikkaa (🔒). Asiakas näkee vain
> `STC_FB_MainScheduler`-instanssin VAR_OUTPUT-muuttujat:
> `o_tsk_phase`, `o_dep_phase`, `o_turn`.

Molemmat schedulerit (TSK ja DEP) ovat vaihekohtaisia tilakoneita: yksi vaihe per PLC-jakso.
Oletussiirtymä on `phase + 1`. Poikkeussiirtymät asetetaan muuttujalla `next_phase`.

## TSK_FB_Scheduler — Task Scheduler

### Kokonaiskuva

```
  0  STOPPED
  │
  1  INIT ─────────── Kerää aktiiviset erät (batch_list)
  │
  2  NO_TREATMENT_STATES ── Päivitä unit-targetit (purku, puskuri, väistö)
  │
  1000+i  CALC_SCHEDULE ── Laske aikataulu erälle batch_list[i+1]
  │        (i = 0..batch_count-1, yksi erä per jakso)
  │        Aseta transporter STC_FindTransporter:lla
  │        └─ Kun i >= batch_count → next_phase := 2000
  │
  2000  CLEAR_TASKS ─── Tyhjennä tehtäväjonot g_task[1..3]
  │
  2001+i  CREATE_TASKS ── Muunna aikataulu tehtäviksi erälle i
  │        └─ Kun i >= batch_count → next_phase := 2100
  │
  ┌──── KONFLIKTISILMUKKA ─────────────────────────┐
  │                                                 │
  │  2100  SORT_TASKS ── Priorisoi tehtävät         │
  │    │                 Alusta lukot (1. kerta)     │
  │    ▼                                            │
  │  2101  SWAP_TASKS ── Optimoi ketjutukset        │
  │    │                                            │
  │    ▼                                            │
  │  2102  ANALYZE ─── Etsi ensimmäinen konflikti   │
  │    │                                            │
  │    ├─ Ei konfliktia → next_phase := 2200        │
  │    │                                            │
  │    └─ Konflikti löytyi → phase + 1              │
  │       │                                         │
  │       ▼                                         │
  │  2103  RESOLVE ─── Ratkaise yksi konflikti      │
  │    │                                            │
  │    ├─ Ratkaistu → next_phase := 2200            │
  │    │                                            │
  │    ├─ Osittain → next_phase := 2100 (uudelleen) │
  │    │    (iter < MAX_CONFLICT_ITER = 40)         │
  │    │                                            │
  │    └─ iter >= MAX → next_phase := 2200          │
  └─────────────────────────────────────────────────┘
  │
  2200  NO_TREATMENT ── Luo ei-käsittely-siirrot (NTT)
  │
  2201  APPLY_STRETCHES ── Kirjaa resolve-päätökset TreatmentPrograms:iin
  │
  2202  TAKE_OUT ── Tarkista tyhjäkäyntipoissiirrot
  │
  10000  READY ─── Aseta g_tsk_stable, g_conflict_resolved
  │
  10001  CHECK_DEP_PENDING ── Käsittele DEP:n aktivointipyyntö
  │
  10002  RESTART → next_phase := 1
```

### Vaihekohtaiset yksityiskohdat

#### Phase 0: STOPPED
Ei suoritusta. `i_run = FALSE` pitää schedulerin pysähdyksissä.

#### Phase 1: INIT
- `STC_CollectActiveBatches(mode=0)` → kerää IN_PROCESS-erät
- Nollaa `conflict_iter`, `stretch_cnt`, `locks_initialized`

#### Phase 2: NO_TREATMENT_STATES
- `STC_NoTreatmentStates()` → päivittää unit-targetit käsitellyille erille

#### Phase 1000+i: CALC_SCHEDULE
Yksi erä per PLC-jakso:
- Selvitä nostin: `STC_FindTransporter(lift_stn, sink_stn=0)`
- `STC_CalcSchedule(unit, trans, time_s)` → täytä `g_schedule[unit]`
- Sisältää asemavalinta, entry/exit-aikalaskenta, siirtoajat

#### Phase 2000: CLEAR_TASKS
- Nollaa `g_task[ti].Count := 0` ja Queue-rivit kaikille nostimille

#### Phase 2001+i: CREATE_TASKS
- `STC_CreateTasks(unit)` → muunna schedule-vaiheet tehtäviksi
- Käsittelee crosstransport-asemat (Y-siirto linjojen välillä)

#### Phase 2100: SORT_TASKS
- `STC_SortTasks(trans=0)` → prioriteettijärjestys kaikille nostimille
- Ensimmäisellä kierroksella alustaa `locks[1..MAX_LOCKS]`

#### Phase 2101: SWAP_TASKS
- `STC_SwapTasks()` → optimoi ketjutetut tehtävät (sink[i] = lift[i+1])

#### Phase 2102: ANALYZE
- `TSK_Analyze()` → tarkista 3 konfliktityyppiä (ks. [CONFLICT_RESOLUTION.md](CONFLICT_RESOLUTION.md))
- Tallentaa tuloksen `an_*`-muuttujiin

#### Phase 2103: RESOLVE
- `TSK_Resolve()` → 4-vaiheinen ratkaisustrategia
- Tallentaa stretch-päätökset ja lock-merkinnät
- Lukitusjärjestelmä estää oskilloinnin

#### Phase 2200: NO_TREATMENT
- `TSK_NoTreatment()` → luo siirtotehtävät puskuri/purku/väistö-targeteille
- Levittää idle-slotteja tarvittaessa

#### Phase 2201: APPLY_STRETCHES
- Kirjaa konfliktisilmukan `stretches[]` → `TreatmentPrograms[unit].Steps[stage].CalTime`
- Tekee ratkaisut pysyviksi

#### Phase 2202: TAKE_OUT
- `STC_TakeOut()` → tarkista pitääkö tyhjäkäynnillä oleva nostin siirtää pois (TakeOutDelay/TakeOutDistance)

#### Phase 10000: READY
- `g_tsk_stable := TRUE` (kun `conflict_resolved`)
- DEP saa aloittaa

#### Phase 10001: CHECK_DEP_PENDING
- Jos `g_dep_pending.Valid = TRUE` → käsittele aktivointi
- Kopioi DEP:n sandbox-tulokset live-dataan

#### Phase 10002: RESTART
- `next_phase := 1` → uusi laskentakierros alkaa

---

## DEP_FB_Scheduler — Departure Scheduler

Yksityiskohtainen kuvaus: [DEP_SCHEDULER.md](DEP_SCHEDULER.md)

### Kokonaiskuva

```
  0  STOPPED
  │
  1  WAIT_STABLE ─── Odota g_tsk_stable = TRUE
  │
  100  INIT_SNAPSHOT ── Kopioi g_batch[], TreatmentPrograms[] → workspace
  101  INIT_COLLECT ── Kerää odottavat + aktiiviset erät
  102  INIT_SORT_WAITING ── FIFO-järjestys odottaville
  103  INIT_CALC_OVERLAP ── Tunnista jaetut asemat
  │
  200  BATCH_START ── Valmistele nykyinen odottava erä
  │
  1000+i  CALC_SCHEDULE ── Laske aikataulut aktiivisille erille
  │
  2000  CLEAR_TASKS
  2001+i  CREATE_TASKS
  2100  SORT_TASKS
  2101  SWAP_TASKS
  │
  2200  INJECT_IN_FLIGHT ── Meneillään olevan kuljetuksen pseudotehtävä
  2300  CALC_IDLE ── Laske tyhjät aikaikkunat per nostin
  2400  CALC_WAIT_SCHEDULE ── Laske odottavan erän aikataulu erikseen
  2500  CREATE_WAIT_TASKS ── Muunna tehtäviksi
  2600  STATION_CONFLICT ── Asemavarausristiriidat
  │
  3000  FIT_START
  3100+i  FIT_TASK ── Sovita jokainen odottava tehtävä idle-slotiin
  │
  4000  APPLY_DELAY ── Kirjaa viiveet, käynnistä uudelleenlaskenta
  │
  8000  ACTIVATE ── Kirjoita tulos g_dep_pending:iin
  8100  WAIT_SAVE ── Odota TSK:n kuittaus
  8200+i  END_DELAY ── Stabilointitikki
  8500  RESTART → phase 1
  │
  9000  REJECT ── Palauta sandbox, yritä seuraavaa erää
```

### Avainvaiheet

| Vaihe | Toiminto |
|-------|----------|
| 1 | Portinvartija: ei aloita ennen kuin TSK on vakaa |
| 100 | `DEP_Sandbox(cmd=1)` — kopioi live → workspace |
| 2300 | `DEP_CalcIdleSlots()` — tunnista nostinten vapaat ajat |
| 3100+i | `DEP_FitTaskToSlot()` — sovita tehtävä aikaikkunaan |
| 4000 | Backward-chaining: levitä idle-slotteja viivyttämällä aktiivisia eriä |
| 8000 | Kirjoita `g_dep_pending` ja aseta `Valid := TRUE` |
| 9000 | `DEP_Sandbox(cmd=2)` — RESTORE, kokeile seuraavaa odottavaa erää |

---

## Vaiheiden ajoitus

Molemmat schedulerit etenevät **yhden vaiheen per PLC-jakso**. Tyypillinen kokonaislaskenta:

| Scheduler | Vaiheita per kierros | PLC-jaksoja (tyypillinen) |
|-----------|---------------------|--------------------------|
| TSK | ~15 + batch_count × 2 + conflict_iter × 4 | 30–80 |
| DEP | ~25 + batch_count × 2 + wait_task_count | 40–100 |

Vaiheiden tarkempi jakso riippuu aktiivisten erien ja odottavien tehtävien määrästä.

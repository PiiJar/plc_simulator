# DEP Scheduler — Departure Scheduler

## Tarkoitus

DEP-scheduler optimoi **odottavien erien** (NOT_PROCESSED) sisääntulon tuotantoon.
Se etsii nostimien tehtäväjonoista vapaita aikaikkunoita ja sovittaa odottavan erän
ensimmäiset tehtävät niihin ilman aktiivisten erien häirintää.

## Perusperiaate: Sandbox-malli

DEP ei koskaan kirjoita suoraan globaaleihin taulukoihin:

```
LIVE-DATA                           SANDBOX (g_dep_wk_*)
g_batch[1..10]  ──SNAPSHOT──→  g_dep_wk_batch[1..10]
TreatmentPrograms[1..10] ──SNAPSHOT──→ g_dep_wk_program[1..10]

                  (laskenta tapahtuu sandboxissa)

g_dep_pending   ←──ACTIVATE──  DEP:n laskentatulos
     │
     ▼
TSK käsittelee seuraavalla kierroksellaan
```

Tämä mahdollistaa:
- TSK voi toimia normaalisti DEP:n laskennan aikana
- DEP:n epäonnistunut sovitus voidaan perua (RESTORE)
- Ei race condition -tilanteita

## Vaiheketju

### 1. Portinvartija (Phase 1)

```
WAIT_STABLE:
  Jos g_tsk_stable = FALSE TAI i_tsk_phase < 10000:
    → odota (pysyy vaiheessa 1)
  Muuten:
    → next_phase := 100
```

### 2. Alustus (Phases 100–103)

| Vaihe | Toiminto |
|-------|----------|
| 100 | `DEP_Sandbox(cmd=1)`: kopioi live batch+program → workspace |
| 101 | Kerää aktiiviset (IN_PROCESS) ja odottavat (NOT_PROCESSED) erät |
| 102 | Lajittele odottavat FIFO-järjestykseen (StartTime) |
| 103 | `DEP_CalcOverlap()`: tunnista asemat, jotka ovat 2+ nostimen alueella |

### 3. Peruslaskenta (Phases 200–2101)

DEP käyttää **samoja STC-funktioita** kuin TSK, mutta sandbox-taulukoilla:

| Vaihe | Funktio | Kohdetaulukot |
|-------|---------|---------------|
| 1000+i | STC_CalcSchedule | g_dep_wk_schedule, g_dep_wk_batch, g_dep_wk_program |
| 2000 | Clear tasks | g_dep_wk_task |
| 2001+i | STC_CreateTasks | g_dep_wk_schedule, g_dep_wk_task |
| 2100 | STC_SortTasks | g_dep_wk_task, g_dep_wk_batch |
| 2101 | STC_SwapTasks | g_dep_wk_task |

### 4. Idle-slot-analyysi (Phases 2200–2600)

#### Phase 2200: INJECT_IN_FLIGHT
Lisää pseudotehtävä meneillään olevalle kuljetukselle. Ilman tätä idle-slot-laskenta
ei huomioisi jo käynnissä olevaa siirtoa.

#### Phase 2300: CALC_IDLE
```
DEP_CalcIdleSlots():
  Jokaiselle nostimelle:
    Skannaa tehtäväjono aikajärjestyksessä
    Tunnista aukkot: edellisen tehtävän loppu → seuraavan alku
    Tallenna: {StartTime, EndTime, from_station, to_station}
    Viimeinen aukko: EndTime = 9999999999 (avoin)
```

**Tulos:** `g_dep_idle_slot[1..3]` — enintään 20 aukkoa per nostin

#### Phase 2400: CALC_WAIT_SCHEDULE
Laske odottavan erän aikataulu sandboxissa.

#### Phase 2500: CREATE_WAIT_TASKS
Muunna aikataulu yksittäisiksi tehtäviksi → `w_tasks[1..30]`

#### Phase 2600: STATION_CONFLICT
Tarkista asemavarausristiriidat odottavan erän ja aktiivisten erien välillä.

### 5. Sovitus (Phases 3000–3100+i)

Tämä on DEP:n ydinalgoritmi:

#### Phase 3100+i: FIT_TASK

Jokaiselle odottavan erän tehtävälle:

```
ovlp_delay_s := DEP_OverlapDelay(
  i_lift_stn   = w_tasks[i].LiftStationTarget,
  i_sink_stn   = w_tasks[i].SinkStationTarget,
  i_trans_id   = trans,
  i_task_start = w_tasks[i].StartTime,
  i_task_end   = w_tasks[i].FinishTime,
  i_margin_s   = SCH_CONFLICT_MARGIN_S,
  io_task      = g_dep_wk_task,
  io_overlap   = g_dep_overlap
)

DEP_FitTaskToSlot(
  i_lift_stn          = w_tasks[i].LiftStationTarget,
  i_sink_stn          = w_tasks[i].SinkStationTarget,
  i_trans_id          = trans,
  i_task_start        = w_tasks[i].StartTime,
  i_task_end          = w_tasks[i].FinishTime,
  i_shift_s           = ovlp_delay_s,
  i_calc_time_s       = w_tasks[i].CalcTime,
  i_max_time_s        = w_tasks[i].MaxTime,
  i_flex_factor       = SCH_DEP_FLEX_FACTOR,
  i_margin_s          = SCH_MARGIN_S,
  i_conflict_margin_s = SCH_CONFLICT_MARGIN_S,
  io_idle_slot        = g_dep_idle_slot,
  o_result            = fit_result
):

1. Etsi paras idle-slot:
   └─ Jokaiselle slotille:
      ├─ travel_to   = CalcHorizontalTravel(slot.from_station, task.lift)
      ├─ travel_from = CalcHorizontalTravel(task.sink, slot.to_station)
    ├─ earliest    = MAX(slot.start + travel_to, task.start + ovlp_delay_s)
      ├─ latest      = MIN(slot.end - travel_from, horizon)
      │
      ├─ Jos earliest + task_duration ≤ latest:
      │     delay = earliest - task.start
      │     flex  = SCH_DEP_FLEX_FACTOR × (MaxTime - CalTime)
      │     margin = SCH_MARGIN_S
      │     Jos delay ≤ margin + flex → FITS ✓
      │     Muuten → OVERFLOW (tallenna paras)
      │
      └─ Muuten → EI MAHDU

2. Tuloste:
   o_result.Fits          = TRUE/FALSE
   o_result.DelayTime     = tarvittava viive
  o_result.NeedExtraTime = lisäaika joka ei mahtunut slotiin
  o_result.TaskEndTime   = toteutuva loppuaika
   o_result.SlotIdx       = käytetty slot
   o_result.TransporterId = nostin
```

Huomioita toteutuksesta:

- `DEP_FitTaskToSlot` ei ota `i_move`-parametria, vaan lukee `g_move[i_trans_id]` globaalisti.
- `DEP_OverlapDelay` ja `DEP_FitTaskToSlot` muodostavat yhdessä kokonaisviiveen:
  `total_delay_s = ovlp_delay_s + fit_result.DelayTime`.

### 6. Idle-slotin levitys (backward-chaining)

Jos tehtävä ei mahdu suoraan mutta on lähellä (OVERFLOW):

```
Phase 4000 APPLY_DELAY:
│
├─ Tunnista slot:n rajaerä (border batch)
│  = aktiivinen erä, jonka tehtävä päättää slotin
│
├─ Levitä borderilla: CalcTime += tarvittava aika
│  (rajoitettu: max SCH_DEP_FLEX_FACTOR × flex)
│
├─ STC_ShiftSchedule → propagoi viive
│
├─ fit_round++
│
└─ Jos fit_round < SCH_MAX_FIT_ROUNDS:
     next_phase := 2000  (laske uudelleen laajennetulla aikataululla)
   Muuten:
     next_phase := 9000  (REJECT)
```

### 7. Aktivointi (Phases 8000–8500)

#### Phase 8000: ACTIVATE
```
g_dep_pending.Valid     := TRUE
g_dep_pending.BatchUnit := cur_wait_unit
g_dep_pending.BatchState := IN_PROCESS
g_dep_pending.Programs  := g_dep_wk_program  (koko taulukko)
g_dep_pending.TimeStamp := i_time_s
```

#### Phase 8100: WAIT_SAVE
Odota kunnes TSK on käsitellyt pyynnön: `g_dep_pending.Valid = FALSE`

#### Phase 8500: RESTART
```
next_phase := 1  (takaisin WAIT_STABLE)
```

### 8. Hylkäys (Phase 9000): REJECT
```
DEP_Sandbox(cmd=2)  ← RESTORE: palauta workspace alkuperäiseksi
cur_wait_idx++      ← kokeile seuraavaa odottavaa erää
fit_round := 0

Jos cur_wait_idx > waiting_count:
  → next_phase := 8500  (kaikki kokeiltu, restart)
Muuten:
  → next_phase := 200   (seuraava erä)
```

## DEP:n apufunktiot

| Funktio | Tarkoitus |
|---------|-----------|
| `DEP_Sandbox` | Kopioi live ↔ workspace (SNAPSHOT, RESTORE) |
| `DEP_CalcIdleSlots` | Tunnista vapaat aikaikkunat tehtäväjonosta |
| `DEP_FitTaskToSlot` | Sovita tehtävä yhteen idle-slotiin |
| `DEP_CalcOverlap` | Tunnista useamman nostimen kattamat asemat |
| `DEP_OverlapDelay` | Ajoitussäädöt jaettujen alueiden konflikteissa |

## TSK:n rooli aktivoinnissa

Kun `g_dep_pending.Valid = TRUE`:

1. `STC_FB_MainScheduler` ei päästä DEP:tä ajoon (skippaa DEP-vuoron)
2. TSK:n Phase 10001 (CHECK_DEP_PENDING) käsittelee:
   - Kopioi `g_dep_pending.Programs` → `TreatmentPrograms`
   - Päivitä `g_batch[unit]` → State, CurStage, aika-arvot
   - Aseta `g_dep_pending.Valid := FALSE`
3. TSK aloittaa uuden kierroksen (Phase 10002 → 1), laskee kaikki erät mukaan lukien uusi

## Suunnittelun rajoitteet

- DEP käsittelee **yhden odottavan erän kerrallaan** (FIFO)
- Jos erä ei mahdu mihinkään idle-slottiin, se hylätään ja kokeillaan seuraavaa
- `SCH_DEP_FLEX_FACTOR = 0.5` tarkoittaa, että DEP käyttää korkeintaan puolet aktiivisen erän käytettävissä olevasta flexistä
- `SCH_MAX_FIT_ROUNDS = 50` rajoittaa backward-chaining-iteraatioiden määrää

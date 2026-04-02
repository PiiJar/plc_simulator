# Konfliktiratkaisu

## Yleiskuva

TSK-scheduler tunnistaa ja ratkaisee aikatauluristiriitoja iteratiivisella silmukalla:

```
SORT → SWAP → ANALYZE → RESOLVE → (takaisin SORT tai ulos)
```

Silmukka pyörii enintään `MAX_CONFLICT_ITER = 40` kierrosta. Jokainen kierros käsittelee yhden konfliktin. Lukitusjärjestelmä estää oskilloinnin.

## TSK_Analyze — Konfliktianalyysi

`TSK_Analyze` on puhdas lukufunktio (ei muuta dataa). Se tarkistaa kolme konfliktityyppiä
järjestyksessä ja pysähtyy ensimmäiseen löydettyyn:

### Tyyppi 1: TASK_SEQUENCE — Peräkkäiset tehtävät liian lähellä

Sama nostin suorittaa kaksi tehtävää peräkkäin, mutta ajoaika ei riitä.

```
Tehtävä A: sink = asema 108, valmistuu T₁
Tehtävä B: lift = asema 115, alkaa T₂

travel_s = STC_CalcHorizontalTravel(108, 115)
gap_s    = T₂ - T₁

Jos travel_s > gap_s + toleranssi → KONFLIKTI
deficit  = travel_s - gap_s
```

**Tuloste:**
- `o_conf_unit / o_conf_stage` = tehtävä B (myöhempi, viivytettävissä)
- `o_blocked_unit / o_blocked_stage` = tehtävä A (aiempi, nopeuttettavissa)
- `o_deficit` = puuttuva aika sekunneissa

### Tyyppi 2: COLLISION — Fyysinen törmäys

Kaksi tehtävää käyttävät päällekkäistä X-aluetta samanaikaisesti.

```
Tehtävä A: X-alue [4200..6100], aika [T₁..T₂]
Tehtävä B: X-alue [5800..7500], aika [T₃..T₄]

Jos [T₁..T₂] ∩ [T₃..T₄] ≠ ∅  JA  [4200..6100] ∩ [5800..7500] ≠ ∅
→ KONFLIKTI
```

Tunnistus: vertaa jokaista tehtäväparia eri nostimilla.
Aiemmin alkanut tehtävä on `blocked` (ei voi siirtää), myöhemmin alkanut on `conf` (viivytettävissä).

### Tyyppi 3: CROSS_TRANSPORTER_HANDOFF — Poikkisiirtoristiriita

Yksikkö siirtyy nostimelta T1 nostimelle T2. T2 ei ehdi paikalle ajoissa.

```
Vaihe S:   nostin T1, laskee asemalle X
Vaihe S+1: nostin T2, nostaa asemalta X

Tarkista: T2:n edellisen tehtävän loppuaika + siirtoaika > Vaihe S+1 alkuaika
```

## TSK_Resolve — Konfliktiratkaisu

`TSK_Resolve` yrittää neljää strategiaa eskalointiperiaatteella:

### Strategia 1: ADVANCE (ennakoi estettyä erää)

```
┌─ Etsi minimifleksi estetyn erän vaiheketjussa ─┐
│  flex_down = CalcTime - MinTime                  │
│  cap = 0.9 × flex  (nykyinen vaihe)             │
│  cap = 0.5 × flex  (muut vaiheet)               │
└─────────────────────────────────────────────────┘
│
├─ STC_ShiftSchedule(unit=blocked, from_stage, amount= -cap)
│  Siirtää vaiheketjua taaksepäin ajassa
│
└─ Kirjaa stretch: {unit, stage, delay= -amount}
```

**Miksi cap?** 0.9/0.5-kertoimet jättävät turvamarginaalia — ei käytetä kaikkea flexiä kerralla.

### Strategia 2: DELAY (viivytä konfliktin aiheuttajaa)

```
Jos ADVANCE ei ratkaise kokonaan:
│
├─ flex_up = MaxTime - CalcTime
├─ Lisää konfliktin aiheuttajan CalcTime
├─ STC_ShiftSchedule(unit=conf, from_stage, amount= +delay)
│
└─ Kirjaa stretch: {unit, stage, delay= +amount}
```

### Strategia 3: PRECEDING_DELAY (viivytä edellistä vaihetta)

```
Jos DELAY ei riitä:
│
├─ Kohdista viive vaiheeseen (conf_stage - 1)
├─ Sama flex_up-laskenta edelliselle vaiheelle
│
└─ STC_ShiftSchedule(unit=conf, from_stage= stage-1, amount)
```

### Strategia 4: DELAY_PREV_PAST_NEXT (pakota uudelleenjärjestys)

```
Viimeinen keino:
│
├─ Viivytä estävä erä niin, että se vaihtaa järjestystä
│  konfliktierän kanssa
│
└─ Tämä tuottaa uudelleenlajittelun seuraavalla SORT-kierroksella
```

## Lukitusjärjestelmä

Lukot estävät resolve-silmukan oskilloinnin (esim. ennakoi A → viivytä B → ennakoi A → ...).

```
locks[1..MAX_LOCKS] : ARRAY OF UDT_JC_TskLockType
  .Unit      = yksikkö
  .Stage     = vaihe
  .Direction = 1 (ADVANCE) tai 2 (DELAY)
```

**Toiminta:**
1. Ennen ADVANCE-yritystä: tarkista onko `(unit, stage, ADVANCE)` lukittu → ohita
2. Ennen DELAY-yritystä: tarkista onko `(unit, stage, DELAY)` lukittu → ohita
3. Strategian jälkeen: kirjaa lukko, estää saman suunnan käytön uudelleen

Lukot alustetaan jokaisen TSK-kierroksen alussa (Phase 2100 ensimmäisellä kerralla).

## STC_ShiftSchedule — Ajansiirron propagointi

Resolve-strategiat käyttävät `STC_ShiftSchedule` ajansiirron levittämiseen:

```
STC_ShiftSchedule(
    i_unit       = siirrettävä yksikkö
    i_from_stage = vaiheen indeksi (tästä eteenpäin)
    i_amount     = siirto sekunneissa (+viive, -ennakko)
)
```

**Propagointi:**
1. `io_schedule[unit].Stages[from_stage..StageCount]` → entry/exit-ajat + amount
2. `io_task[trans].Queue[qi]` → start/finish-ajat (matchataan unit + stage)
3. **Gap-3 Past-Clamp:** ennakoidessa EntryTime ei voi mennä nykyhetken alle (now + 1)

## Stretch-päätösten persistointi

Konfliktisilmukan stretches kirjataan Phase 2201 (APPLY_STRETCHES):

```
stretches[1..20] : ARRAY OF UDT_JC_TskStretchType
  .Unit   = yksikkö
  .Stage  = vaihe
  .DelayS = muutos sekunneissa

Phase 2201:
  FOR si := 1 TO stretch_cnt DO
    g_program[stretches[si].Unit].Steps[stretches[si].Stage].CalTime
      += stretches[si].DelayS;
  END_FOR;
```

Tämä tekee resolve-päätöksistä pysyviä — seuraava TSK-kierros laskee aikataulun jo päivitetyillä CalTime-arvoilla.

## Esimerkki: Konfliktisilmukan kulku

```
Kierros 1:
  2100  SORT → priorisoi: [tehtävä A (emergency), B, C]
  2101  SWAP → ei ketjutuksia
  2102  ANALYZE → löytää: A ja B törmäävät (COLLISION)
        deficit = 4.2 s
  2103  RESOLVE →
        ADVANCE B:  flex=6s, cap=3s → shift -3s → deficit jäljellä 1.2s
        DELAY A:    flex=2s → shift +1.2s → deficit = 0
        Lukitaan: (B, stage, ADVANCE), (A, stage, DELAY)
        Kirjataan: stretch(B, -3), stretch(A, +1.2)
        → next_phase := 2100 (tarkista uudelleen)

Kierros 2:
  2100  SORT → priorisoi uudelleen päivitetyillä ajoilla
  2101  SWAP
  2102  ANALYZE → ei konflikteja
        → next_phase := 2200 (ulos silmukasta)

Phase 2201:
  g_program[B].Steps[stage].CalTime -= 3
  g_program[A].Steps[stage].CalTime += 1.2
```

## Debug-muuttujat

Konfliktin diagnostiikka on näkyvissä OPC UA:n kautta:

| Muuttuja | Sisältö |
|----------|---------|
| `g_dbg_tsk_conflict_type` | 1=TASK_SEQ, 2=COLLISION, 3=HANDOFF |
| `g_dbg_tsk_conflict_iter` | Kierrosten lukumäärä |
| `g_dbg_tsk_conf_unit` | Konflikti-yksikkö |
| `g_dbg_tsk_conf_stage` | Konflikti-vaihe |
| `g_dbg_tsk_blocked_unit` | Estetty yksikkö |
| `g_dbg_tsk_blocked_stage` | Estetty vaihe |
| `g_dbg_tsk_deficit` | Alijäämä (s × 10) |
| `g_dbg_tsk_stretch_cnt` | Stretch-päätösten lukumäärä |
| `g_dbg_tsk_total_adv` | Ennakointien summa (s × 10) |
| `g_dbg_tsk_total_delay` | Viiveiden summa (s × 10) |

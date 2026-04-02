# Simulaatiokerros

> **Huom:** SIM-kerros on kehitysympäristön testikerros. Sitä **ei toimiteta** asiakkaalle.
> Tuotantokäytössä asiakas korvaa simulaation omilla HW-ajureillaan (servot, anturit, I/O).
> Scheduler-kirjaston ydinkoodi (TSK, DEP, STC, TWA) on identtinen molemmissa ympäristöissä.

## Tarkoitus

SIM-kerros simuloi nostimien fyysistä liikettä ja generoi tapahtumia kehitysympäristöä varten.
Se mahdollistaa scheduler-algoritmin testauksen ilman fyysistä laitteistoa.

## Simulaation vs. tuotannon erot

| Osa-alue | Tuotanto | Simulaatio |
|----------|----------|------------|
| X-liike | Servomoottorit | SIM_FB_XMotion (trapetsiprofiili) |
| Z-liike (nosto/lasku) | Hydrauliikka/pneumatiikka | SIM_FB_ZMotion (vaihetilakone) |
| Siirtoajat | Mitattu antureilla | Laskettu fysiikkamalleilla |
| Asemapaikannus | Fyysiset anturit | SIM_FindStation (X-positio → asema) |
| Tapahtumat | PLC-ulostulot / Modbus | SIM_FB_EventQueue → OPC UA |
| Liikkeen kalibrointi | Ei tarvita | g_move[] päivittyy automaattisesti |

## SIM_FB_RunTasks — Pääsimulaatio-FB

Suoritetaan joka PLC-jaksolla. Käy läpi kaikki nostimet ja simuloi yhden
aikajakson verran X- ja Z-liikettä.

### 5-vaiheinen kuljetussykli

```
Phase 0  IDLE
    │  dispatch asettaa TaskId → Phase 1
    ▼
Phase 1  TO_LIFT
    │  X-ajo nostoasemalle (SIM_FB_XMotion)
    │  AtPosition=TRUE → tapahtuma ARRIVED_AT_LIFT
    ▼
Phase 2  LIFTING
    │  Z-nostosarja (SIM_FB_ZMotion, 8 alivaihetta)
    │  Tapahtuma: LIFTING_BEGIN, LIFTING_DONE
    ▼
Phase 3  TO_SINK
    │  X-ajo laskuasemalle
    │  AtPosition=TRUE → tapahtuma ARRIVED_AT_SINK
    ▼
Phase 4  SINKING
    │  Z-laskusarja (SIM_FB_ZMotion, 8 alivaihetta)
    │  Tapahtuma: TASK_COMPLETE
    │  Siirtoajan mittaus: STC_TrackMoveTimes
    ▼
Phase 0  IDLE
```

### Phase 0 → 1: Tehtävän vastaanotto

```
Jos g_transporter[ti].TaskId <> 0 ja g_transporter[ti].TaskId <> RunningTaskId:
  RunningTaskId := TaskId
  XDriveTarget  := g_station[LiftStationTarget].XPosition
  Phase := 1
  Tapahtuma: TASK_STARTED
```

### Phase 1: X-ajo nostoasemalle

```
SIM_FB_XMotion(
    target     := XDriveTarget,
    speed_max  := g_cfg[ti].SpeedMax_X,
    accel      := g_cfg[ti].Acceleration_X,
    decel      := g_cfg[ti].Deceleration_X,
    x_min      := XMinDriveLimit,    ← TWA-rajoitus
    x_max      := XMaxDriveLimit     ← TWA-rajoitus
)

Tulos: XPosition päivittyy, AtPosition kun kohteessa.
```

**TWA-rajat:** `TWA_FB_CalcLimits` laskee joka jaksolla X-rajat törmäyksen estämiseksi.
SIM_FB_XMotion ei ylitä rajoja vaan hidastaa/pysähtyy.

### Phase 2: Z-nosto (8 alivaihetta)

```
ZStage-sekvenssi:
  0 → Lukitus auki (kansi avautuu)
  1 → Hidas nosto (ZPosDrip)
  2 → Tippumisaika (DrippingTime)
  3 → Tippumalusikan sulku (DripTrayDelay)
  4 → Nopea nosto (ZPosUp)
  5 → Stabilointi
  6 → Lukitus kiinni
  7 → Valmis → Phase 3
```

Jokainen alivaihe käyttää `ZTimer`-laskuria ja konfiguroituja aikoja
(`LiftWetSlowTime`, `LiftWetMidTime`, `LiftWetFastTime` jne.).

### Phase 3: X-ajo laskuasemalle

Sama kuin Phase 1, mutta `XDriveTarget := g_station[SinkStationTarget].XPosition`.

### Phase 4: Z-lasku

Vastaava 8-vaiheinen sekvenssi käänteisessä järjestyksessä.
Phase 4:n valmistuessa:
- Päivitä `g_unit[unit].Location := SinkStationTarget`
- Päivitä `g_station_loc[stn].UnitId`
- Kutsu `STC_TrackMoveTimes` → tallenna mitatut ajat
- `g_transporter[ti].Phase := 0`

## SIM_FB_XMotion — Vaakasuuntainen liike

Trapetsiprofiilinen nopeussäätö:

```
        v_max ─────────────
       /                   \
      /  kiihdytys   hidastuvuus  \
     /                       \
────                           ────
```

**Parametrit:**
- `i_target` — kohdepositio (mm)
- `i_speed_max` — maksiminopeus (mm/s)
- `i_acceleration` — kiihtyvyys (mm/s²)
- `i_deceleration` — hidastuvuus (mm/s²)
- `i_x_min`, `i_x_max` — TWA-rajat

**Hidastuvuusetäisyys:**
```
d_decel = v² / (2 × decel)
Jos |target - position| ≤ d_decel → aloita hidastus
```

**Ryömintänopeus (crawl):**
Konfiguraatio: `CrawlDistance_X`, `SpeedCrawl_X`. Loppumetreillä nopeus lasketaan
ryömintätasolle tarkkuuden varmistamiseksi.

## SIM_FB_ZMotion — Pystysuuntainen liike

Ei trapetsiprofiilia, vaan diskreetti vaihesarja:
- Nopeus valitaan ZStage-vaiheen mukaan (slow/mid/fast)
- Jokainen vaihe kestää konfiguidun ajan
- `ZTimer` laskee aikaa alaspäin → siirtyy seuraavaan vaiheeseen

## SIM_FindStation — Positio → asema

```
FUNCTION SIM_FindStation : INT
  VAR_INPUT
    i_x_pos  : DINT    (* X-positio mm *)
  END_VAR

  Lineaari-/binäärihaku g_station[]-taulukosta:
  Palauttaa lähimmän aseman StationId:n
  (toleranssi: g_cfg[trans].PosTolerance_X)
```

Käytetään Phase 1:ssä ja Phase 3:ssa `ARRIVED_AT`-tapahtuman laukaisuun.

## STC_TrackMoveTimes — Siirtoaikojen mittaus ja oppiminen

Kutsu tapahtuu jokaisen vaihesiirtymän yhteydessä SIM_FB_RunTasks:ssa:

```
Phase 0→1:  Tallenna StartStation, ts0
Phase 1→2:  Tallenna ts1 (nostoasemalle saapuminen)
Phase 2→3:  Tallenna ts2 (nosto valmis)
Phase 3→4:  Tallenna ts3 (laskuasemalle saapuminen)
Phase 4→0:  Tallenna ts4 (lasku valmis)
            Laske mitatut kestot, päivitä g_move[]
```

**Painotettu keskiarvo:**
```
g_move[trans].Travel[from].ToTime[to] :=
    (vanha × 4 + mitattu) / 5
```

Tämä adaptiivinen oppiminen parantaa aikataulun tarkkuutta ajan myötä.

## SIM_FB_EventQueue — Tapahtumajonon hallinta

Kiertojono Gateway-kommunikaatioon:

```
Koko: 10 slottia (Buffer[1..10])
Osoittimet: Head (vanhin), NextSeq (juokseva numero)

Enqueue:
  g_event_pending.MsgType := tyyppi
  g_event_pending.Payload := data
  g_event_pending_valid := TRUE

  → EventQueue sijoittaa seuraavaan vapaaan slotiin
  → NextSeq++ (wrappaa 32000:ssa)

Dequeue:
  Gateway lukee Buffer[Head] OPC UA:n kautta
  Gateway kirjoittaa AckSeq
  → Head++ (wrappaa 10:ssä)
```

**Tapahtumatyypit:**

| MsgType | Tapahtuma | Payload |
|---------|-----------|---------|
| 1 | TASK_DISPATCHED | trans, unit, lift_stn, sink_stn |
| 2 | ARRIVED_AT_LIFT | trans, station |
| 3 | LIFTING_BEGIN | trans, unit, station |
| 4 | LIFTING_DONE | trans, unit |
| 5 | ARRIVED_AT_SINK | trans, station |
| 6 | SINKING_BEGIN | trans, unit, station |
| 7 | TASK_COMPLETE | trans, unit, cycle_metrics |

## SIM_FB_ClearConfig — Konfiguraation nollaus

Nollaa kaikki konfiguraatiotaulukot (kutsutaan `cmd_code = 3`):
- `g_station[]`, `g_cfg[]`, `g_transporter[]`
- `g_unit[]`, `g_batch[]`, `g_program[]`
- `g_schedule[]`, `g_task[]`
- Simulaatiotaulukot

## Törmäyksenesto: TWA_FB_CalcLimits

Vaikka tämä ei ole puhtaasti SIM-kerroksen osa, se on kiinteästi integroitu simulaatioon.

**2-kierroksinen algoritmi:**

```
Kierros 1 (per nostin):
  ├─ Lask aserajoitukset (g_avoid_status[])
  ├─ Turvaetäisyydet viereisistä nostimista
  └─ Prioriteetti ja can_evade -lippu

Kierros 2 (nostimiparit):
  ├─ Korkeamman prioriteetin nostin rajoittaa matalampaa
  └─ Kaksisuuntainen tarkistus (takaa-ajo)
```

**Tuloste:** `g_transporter[ti].XMinDriveLimit`, `g_transporter[ti].XMaxDriveLimit`

Nämä rajat syötetään SIM_FB_XMotion:ille, joka ei ylitä niitä.

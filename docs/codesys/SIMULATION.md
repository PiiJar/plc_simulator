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
| Asemapaikannus | Fyysiset anturit | SIM_FindStation (asema → XPosition / DryWet / viiveet) |
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
  │  Z-nostosarja (SIM_FB_ZMotion, z_stage 2..5,9)
    │  Tapahtuma: LIFTING_BEGIN, LIFTING_DONE
    ▼
Phase 3  TO_SINK
    │  X-ajo laskuasemalle
    │  AtPosition=TRUE → tapahtuma ARRIVED_AT_SINK
    ▼
Phase 4  SINKING
  │  Z-laskusarja (SIM_FB_ZMotion, z_stage 6..8)
    │  Tapahtuma: TASK_COMPLETE
    │  Siirtoajan mittaus: STC_TrackMoveTimes
    ▼
Phase 0  IDLE
```

### Phase 0 → 1: Tehtävän vastaanotto

```
Jos g_transporter[ti].TaskId <> 0 ja g_transporter[ti].TaskId <> RunningTaskId:
  RunningTaskId := TaskId
  XDriveTarget  := Stations[LiftStationTarget].XPosition
  Phase := 1
  Tapahtuma: TASK_STARTED
```

### Phase 1: X-ajo nostoasemalle

```
SIM_FB_XMotion(
    target     := XDriveTarget,
    speed_max  := Transporters[ti].SpeedMax_X,
    accel      := Transporters[ti].Acceleration_X,
    decel      := Transporters[ti].Deceleration_X,
    x_min      := XMinDriveLimit,    ← TWA-rajoitus
    x_max      := XMaxDriveLimit     ← TWA-rajoitus
)

Tulos: XPosition päivittyy, AtPosition kun kohteessa.
```

**TWA-rajat:** `TWA_FB_CalcLimits` laskee joka jaksolla X-rajat törmäyksen estämiseksi.
SIM_FB_XMotion ei ylitä rajoja vaan hidastaa/pysähtyy.

### Phase 2: Z-nosto

```
ZStage-sekvenssi:
  2 → Hidas alkunosto nesteestä
  3 → Nopea nosto keskialueella
  4 → Hidas loppunosto yläasentoon
  5 → Valutusaika yläasemassa (DroppingTime)
  9 → Tippakourun sulkuviive (DripTrayDelay)
      → valmis, Phase 3
```

Jokainen vaihe käyttää `z_timer_s`-ajastinta tai suoraa nopeusintegraatiota.
Lift käyttää hitaita/nopeita Z-nopeuksia ja erottaa märkä- ja kuiva-asemien slow-zone-alueet.

### Phase 3: X-ajo laskuasemalle

Sama kuin Phase 1, mutta `XDriveTarget := Stations[SinkStationTarget].XPosition`.

### Phase 4: Z-lasku

Lasku ei ole noston peilikuva, vaan erillinen 3-vaiheinen sekvenssi:

```
  6 → Alkuviive (device_delay + drip_delay)
  7 → Nopea lasku
  8 → Hidas loppulasku altaaseen
      → valmis, Phase 0
```

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

Liike on toteutettu suorana accel/cruise/decel-profiilina. Erillistä crawl-vaihetta
ei ole SIM_FB_XMotion-rajapinnassa.

## SIM_FB_ZMotion — Pystysuuntainen liike

Ei trapetsiprofiilia, vaan diskreetti vaihesarja:
- Nopeus valitaan ZStage-vaiheen mukaan (slow/mid/fast)
- Jokainen vaihe kestää konfiguidun ajan
- `ZTimer` laskee aikaa alaspäin → siirtyy seuraavaan vaiheeseen

## SIM_FindStation — Asemahaku

```
FUNCTION SIM_FindStation : DINT
  VAR_INPUT
    station_number : INT
  END_VAR

  Suora haku Stations[]-taulukosta asemanumerolla.
  Palauttaa aseman `XPosition`-arvon.
  VAR_OUTPUT:n kautta saadaan lisäksi `skind`, `device_delay_s`
  ja `dropping_time_s`.
```

Käytetään SIM_FB_RunTasks:ssa kohdeaseman X-position ja asemaparametrien hakuun.

## STC_TrackMoveTimes — Siirtoaikojen mittaus ja oppiminen

Kutsu tapahtuu jokaisen vaihesiirtymän yhteydessä SIM_FB_RunTasks:ssa:

```
Phase 0→1:  Tallenna StartStation, ts0
Phase 1→2:  Tallenna ts1 (nosto alkaa)
Phase 2→3:  Tallenna ts2 (nosto valmis)
Phase 3→4:  Tallenna ts3 (laskuasemalle saapuminen)
Phase 4→0:  Tallenna ts4 (lasku valmis)
            Laske mitatut kestot, päivitä g_move[]
```

Varsinainen saapuminen nostoasemalle seurataan erillisellä `ts_at_lift`-muuttujalla
SIM_FB_RunTasks:ssa, mutta sitä ei kirjata `g_actual_move.ts1`-kenttään.

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
- `Stations[]`, `Transporters[]`, `g_transporter[]`
- `g_unit[]`, `g_batch[]`, `TreatmentPrograms[]`
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

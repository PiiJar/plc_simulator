# Käyttöönottajan diagnostiikka — toteutussuunnitelma

> Tavoite: salatun kirjaston käyttöönottaja saa riittävän informaation siitä,
> miksi scheduleri ei toimi, mitä parametreja puuttuu ja mitkä asetukset ovat ristiriitaisia.

---

## Nykytila

### Vahvuudet

| Ominaisuus | Sijainti |
|------------|----------|
| Faasitieto TSK / DEP | `g_sched_dbg_tsk_phase`, `g_sched_dbg_dep_phase` |
| Konfliktitieto (tyyppi, yksikkö, vaje) | `g_dbg_tsk_conflict_type` ym. |
| Tapahtumaviestit (dispatch / lift / complete) | `g_event` -jono |
| Debug-laskurit OPC UA:n kautta | `g_dbg_tsk_stretch_cnt`, `g_sched_dbg_dep_reject_cnt` ym. |

### Kriittinen puute

Kaikki validointivirheet ovat hiljaisia `RETURN`-käskyjä.
Käyttöönottaja ei tiedä, miksi scheduleri ei tee mitään — hän näkee vain,
että faasinumero ei etene.

---

## P1 — Virhekoodit hiljaisiin RETURN-kohtiin

**Työmäärä:** pieni  
**Hyöty:** käyttöönottaja näkee heti MIKSI scheduleri ei toimi

### Toteutus

Lisätään `GVL_JC_Scheduler`-muuttujiin:

```iec-st
g_error_last_code     : INT;                    (* viimeisin virhekoodi *)
g_error_last_context  : ARRAY[1..4] OF INT;     (* konteksti: unit, stage, trans, station *)
g_error_count         : DINT;                   (* virheiden kokonaismäärä käynnistyksestä *)
```

Jokaiseen nykyiseen hiljaiseen `RETURN`-kohtaan lisätään ennen paluuta:

```iec-st
(* esimerkki: STC_CalcSchedule.st *)
IF i_unit < 1 OR i_unit > MAX_Units THEN
    g_error_last_code := 201;
    g_error_last_context[1] := i_unit;
    g_error_count := g_error_count + 1;
    RETURN;
END_IF;
```

### Virhekooditaulukko

| Koodi | Kategoria | Kuvaus | Konteksti [1..4] |
|-------|-----------|--------|-------------------|
| **100–199** | **Konfiguraatio (startup)** | | |
| 101 | Konfiguraatio | Asemaa ei löydy layoutista | station_id, —, —, — |
| 102 | Konfiguraatio | Transportterin working area tyhjä | trans_id, —, —, — |
| 103 | Konfiguraatio | Treatment program viittaa tuntemattomaan asemaan | program_id, step, station_id, — |
| 104 | Konfiguraatio | `g_station_count` = 0 tai > MAX | station_count, —, —, — |
| 105 | Konfiguraatio | Transportterin nopeus = 0 | trans_id, axis (1=X, 2=Z), —, — |
| 106 | Konfiguraatio | Move time = 0 käytetyllä asemaparilla | lift_stn, sink_stn, —, — |
| 107 | Konfiguraatio | Working area alku > loppu | trans_id, start, end, — |
| 108 | Konfiguraatio | Duplikaatti XPosition asemilla | station_id_1, station_id_2, x_pos, — |
| **200–299** | **Parametrivirhe (runtime)** | | |
| 201 | Parametri | Unit index out of range | unit, —, —, — |
| 202 | Parametri | Transporter index out of range | trans, —, —, — |
| 203 | Parametri | Batch code = 0 | unit, stage, —, — |
| 204 | Parametri | Program step count > MAX | unit, step_count, —, — |
| 205 | Parametri | Program stage count = 0 | unit, batch_code, —, — |
| 206 | Parametri | Shift amount ≈ 0 (ei vaikutusta) | unit, —, —, — |
| **300–399** | **Ajoitusvirhe** | | |
| 301 | Ajoitus | `max_time < cal_time` (negatiivinen flex) | unit, stage, max_time, cal_time |
| 302 | Ajoitus | `min_time > max_time` (ristiriitaiset rajat) | unit, stage, min_time, max_time |
| 303 | Ajoitus | Travel time = 0 asemavälillä | lift_stn, sink_stn, —, — |
| 304 | Ajoitus | Time overflow (LINT ylivuoto) | unit, stage, —, — |
| **400–499** | **Dispatch-ongelma** | | |
| 401 | Dispatch | Yhtään transportteria ei löydy tehtävälle | unit, lift_stn, sink_stn, — |
| 402 | Dispatch | Sink station varattu, ei vaihtoehtoa | unit, sink_stn, occupant_unit, — |
| 403 | Dispatch | Unit ei ole nostoasemalla | unit, expected_stn, actual_stn, — |
| 404 | Dispatch | Tehtäväjono täynnä (MAX_TASK_QUEUE) | trans_id, queue_count, —, — |
| **500–599** | **DEP-scheduleri** | | |
| 501 | DEP | Kaikki odottavat batchit hylätty | wait_cnt, reject_cnt, —, — |
| 502 | DEP | Fit round raja saavutettu | fit_round, —, —, — |
| 503 | DEP | ACTIVATE-data ei kulutettu TSK:n toimesta | pending_seq, —, —, — |
| **600–699** | **Konflikti / lukkiuma** | | |
| 601 | Konflikti | Max conflict iterations saavutettu (40) | conflict_type, unit, stage, — |
| 602 | Konflikti | Oskillaatiolukko lauennut (50 lukkoa) | lock_cnt, —, —, — |
| 603 | Timeout | Faasi ei etene (> timeout sekuntia) | phase, elapsed_s, —, — |

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Lisää `g_error_last_code`, `g_error_last_context`, `g_error_count` |
| `POUs/STC_CalcSchedule.st` | Virhekoodit 201, 202 ennen RETURN-käskyjä |
| `POUs/STC_CreateTasks.st` | Virhekoodit 201, 205 ennen RETURN-käskyjä |
| `POUs/STC_ShiftSchedule.st` | Virhekoodit 201, 206 ennen RETURN-käskyjä |
| `POUs/DEP_CalcIdleSlots.st` | Virhekoodi 202 ennen RETURN-käskyä |
| `POUs/DEP_FitTaskToSlot.st` | Virhekoodit 202, 303 |
| `POUs/STC_DispatchTask.st` | Virhekoodit 401, 402, 403, 404 |
| `POUs/STC_FindTransporter.st` | Virhekoodi 401 |

---

## P2 — Startup-validointi (`STC_ValidateConfig`)

**Työmäärä:** keskisuuri (~200 riviä)  
**Hyöty:** käyttöönottaja voi tarkistaa konfiguraation ENNEN ajoa

### Toteutus

Uusi FUNCTION_BLOCK `STC_ValidateConfig`, joka kutsutaan kerran `g_cmd_code = 2` (INIT) yhteydessä `STC_FB_MainScheduler`:sta.

#### Rajapinta

```iec-st
FUNCTION_BLOCK STC_ValidateConfig
VAR_OUTPUT
    o_valid       : BOOL;     (* TRUE = konfiguraatio OK *)
    o_error_count : INT;      (* virheiden lukumäärä *)
    o_warn_count  : INT;      (* varoitusten lukumäärä *)
    o_first_error : INT;      (* ensimmäinen virhekoodi *)
END_VAR
```

#### Tarkistukset

| # | Tarkistus | Virhekoodi | Vakavuus |
|---|-----------|------------|----------|
| 1 | `g_station_count > 0` ja `≤ MAX_Stations` | 104 | ERROR |
| 2 | Jokaisella transportterilla `Speed_X > 0` ja `Speed_Z > 0` | 105 | ERROR |
| 3 | Jokaisella asemalla `XPosition` on uniikki | 108 | ERROR |
| 4 | Treatment program: jokainen asemavaihe viittaa olemassa olevaan asemaan | 103 | ERROR |
| 5 | Treatment program: `MinTime ≤ CalTime ≤ MaxTime` joka vaiheessa | 301, 302 | ERROR |
| 6 | Transportterin `WorkingArea_Start ≤ WorkingArea_End` | 107 | ERROR |
| 7 | Transportterin working area kattaa vähintään yhden aseman | 102 | ERROR |
| 8 | Move times: `TravelTime > 0` kaikilla käytetyillä asemapareilla | 106 | WARNING |
| 9 | Vähintään yksi aktiivinen batch olemassa | — | WARNING |
| 10 | Ei päällekkäisiä batch-koodeja samalla unit-indeksillä | — | WARNING |

#### Integraatio MainScheduleriin

```iec-st
(* STC_FB_MainScheduler — INIT-vaiheessa *)
CASE phase OF
    1: (* INIT *)
        validator(
            (* ei inputteja, lukee globaalit suoraan *)
        );
        IF NOT validator.o_valid THEN
            g_error_last_code := validator.o_first_error;
            phase := 0; (* STOPPED — ei käynnistä scheduleria *)
            RETURN;
        END_IF;
        phase := 2; (* jatka normaalisti *)
```

#### Uudet tiedostot

| Tiedosto | Kuvaus |
|----------|--------|
| `POUs/STC_ValidateConfig.st` | Uusi FUNCTION_BLOCK |

#### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `POUs/STC_FB_MainScheduler.st` | Kutsu `STC_ValidateConfig` INIT-vaiheessa |
| `build_codesys_xml.py` | Lisää `STC_ValidateConfig.st` POU-listaan |

---

## P3 — Phase timeout + jumitunnistus

**Työmäärä:** pieni  
**Hyöty:** käyttöönottaja huomaa heti jos scheduleri jää jumiin

### Toteutus

Lisätään `GVL_JC_Scheduler`-muuttujiin:

```iec-st
g_phase_start_time  : LINT;    (* faasin alkuhetki, unix seconds *)
g_phase_timeout_s   : INT := 30;  (* konfiguroitava timeout *)
g_warn_stuck_phase  : BOOL;    (* TRUE kun faasi ylittänyt timeoutin *)
```

Lisätään `STC_FB_MainScheduler`:iin faasinvaihdon yhteydessä:

```iec-st
(* faasinvaihdon jälkeen *)
IF new_phase <> old_phase THEN
    g_phase_start_time := g_now;
    g_warn_stuck_phase := FALSE;
END_IF;

(* joka kierroksella *)
IF g_now - g_phase_start_time > g_phase_timeout_s THEN
    g_warn_stuck_phase := TRUE;
    g_error_last_code := 603;
    g_error_last_context[1] := current_phase;
    g_error_last_context[2] := INT_TO_DINT(g_now - g_phase_start_time);
END_IF;
```

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Lisää `g_phase_start_time`, `g_phase_timeout_s`, `g_warn_stuck_phase` |
| `POUs/STC_FB_MainScheduler.st` | Timeout-tarkistus + faasinvaihdon aikaleima |

---

## P4 — Virhejono (Error Queue)

**Työmäärä:** keskisuuri  
**Hyöty:** täysi virhehistoria gateway-UI:hin

### Toteutus

Samalla periaatteella kuin `g_event` -tapahtumajono.

#### Uudet UDT:t

```iec-st
TYPE UDT_JC_ErrorMsgType :
STRUCT
    Seq       : INT;                   (* juokseva numero *)
    Code      : INT;                   (* virhekoodi 100-699 *)
    Severity  : INT;                   (* 1=WARNING, 2=ERROR, 3=FATAL *)
    TsHi      : INT;                   (* aikaleima ylempi 16 bittia *)
    TsLo      : INT;                   (* aikaleima alempi 16 bittia *)
    Context   : ARRAY[1..4] OF INT;    (* unit, stage, trans, station *)
END_STRUCT
END_TYPE

TYPE UDT_JC_ErrorQueueType :
STRUCT
    Buffer    : ARRAY[1..32] OF UDT_JC_ErrorMsgType;
    Head      : INT;
    Tail      : INT;
    Count     : INT;
    Overflow  : BOOL;   (* TRUE jos vanhoja viestejä ylikirjoitettu *)
END_STRUCT
END_TYPE
```

#### GVL-muuttujat

```iec-st
g_error_queue       : UDT_JC_ErrorQueueType;
g_error_ack_seq     : INT;    (* Gateway kirjoittaa: "olen käsitellyt tähän asti" *)
```

#### Apuohjelma

Uusi FUNCTION `STC_PushError`:

```iec-st
FUNCTION STC_PushError : BOOL
VAR_INPUT
    i_code     : INT;
    i_severity : INT;
    i_ctx1     : INT;
    i_ctx2     : INT;
    i_ctx3     : INT;
    i_ctx4     : INT;
END_VAR
```

Kutsutaan samoista kohdista kuin P1:n `g_error_last_code`-asetus, mutta
kirjoittaa virheen jonoon. P1:n muuttujat säilytetään pikakatsaukseen.

#### Gateway-integraatio

Gateway lukee `g_error_queue.Buffer` OPC UA:n kautta ja kirjoittaa
`g_error_ack_seq`:n kuittaukseksi. Vastaava logiikka kuin nykyinen
`g_event` / `g_event_ack_seq`.

### Uudet tiedostot

| Tiedosto | Kuvaus |
|----------|--------|
| `UDTs/UDT_JC_ErrorMsgType.st` | Virheviestin rakenne |
| `UDTs/UDT_JC_ErrorQueueType.st` | Virhejonon rakenne |
| `POUs/STC_PushError.st` | Jonoon kirjoitus -funktio |

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Lisää `g_error_queue`, `g_error_ack_seq` |
| `build_codesys_xml.py` | Lisää uudet UDT:t ja POU |
| Kaikki P1-tiedostot | Vaihda / lisää `STC_PushError(...)` -kutsut |

---

## P5 — Health status + suorituskykymittarit

**Työmäärä:** pieni–keskisuuri  
**Hyöty:** dashboard-näkymä kokonaistilanteesta

### Toteutus

Lisätään `GVL_JC_Scheduler`-muuttujiin:

```iec-st
(* === HEALTH STATUS === *)
g_health_status      : INT;     (* 0=OK, 1=WARNING, 2=ERROR, 3=STOPPED *)
g_health_code        : INT;     (* viimeisin ei-OK syy — virhekoodi *)

(* === SUORITUSKYKY === *)
g_perf_tsk_cycle_ms  : DINT;   (* TSK-kierroksen kesto millisekunteina *)
g_perf_dep_cycle_ms  : DINT;   (* DEP-kierroksen kesto millisekunteina *)
g_perf_dispatch_cnt  : INT;    (* lähetetyt tehtävät viimeisessä kierroksessa *)
g_perf_idle_pct      : INT;    (* transportterien joutilas-%, 0-100 *)

(* === VAROITUSTILAT === *)
g_warn_queue_near_full   : BOOL;   (* tehtäväjono > 80% kapasiteetista *)
g_warn_no_transporter    : BOOL;   (* tehtävä odottaa, kaikki transportterit varattu *)
g_warn_dep_all_rejected  : BOOL;   (* DEP hylkäsi kaikki odottavat batchit *)
g_warn_conflict_loop     : BOOL;   (* konfliktiresoluutio oskillaatio havaittu *)
```

#### Health status -logiikka MainSchedulerissa

```iec-st
(* joka kierroksella *)
IF g_warn_stuck_phase OR g_error_last_code >= 600 THEN
    g_health_status := 2;  (* ERROR *)
    g_health_code := g_error_last_code;
ELSIF g_warn_queue_near_full OR g_warn_no_transporter
      OR g_warn_dep_all_rejected OR g_warn_conflict_loop THEN
    g_health_status := 1;  (* WARNING *)
    g_health_code := g_error_last_code;
ELSIF phase = 0 THEN
    g_health_status := 3;  (* STOPPED *)
    g_health_code := 0;
ELSE
    g_health_status := 0;  (* OK *)
    g_health_code := 0;
END_IF;
```

#### Suorituskykymittaus

```iec-st
(* TSK-kierroksen alussa *)
tsk_start := TIME();

(* TSK-kierroksen lopussa *)
g_perf_tsk_cycle_ms := TIME_TO_DINT(TIME() - tsk_start);
```

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Kaikki uudet health/perf/warn -muuttujat |
| `POUs/STC_FB_MainScheduler.st` | Health-logiikka + suorituskykymittaus |
| `POUs/TSK_FB_Scheduler.st` | `g_warn_conflict_loop` asetus resolve-vaiheessa |
| `POUs/DEP_FB_Scheduler.st` | `g_warn_dep_all_rejected` asetus reject-vaiheessa |
| `POUs/STC_DispatchTask.st` | `g_warn_no_transporter`, `g_warn_queue_near_full` |

---

## Gateway / UI -integraatio (ei osa kirjastoa)

Gateway ja UI eivät ole osa salattua kirjastoa, mutta tarvitsevat päivitykset
hyödyntääkseen uusia diagnostiikkamuuttujia.

### OPC UA -nodet (opcua_nodes.js)

Lisätään luettavat nodet:

```
g_error_last_code, g_error_last_context[1..4], g_error_count
g_health_status, g_health_code
g_warn_stuck_phase, g_warn_queue_near_full, g_warn_no_transporter,
g_warn_dep_all_rejected, g_warn_conflict_loop
g_perf_tsk_cycle_ms, g_perf_dep_cycle_ms
g_error_queue.Buffer, g_error_ack_seq (write)
```

### Dashboard API (dashboard_api.js)

Uusi endpoint:

```
GET /api/scheduler/health
→ { status: "OK"|"WARNING"|"ERROR"|"STOPPED",
    code: 0,
    errors: [...],
    warnings: [...],
    performance: { tsk_ms, dep_ms, dispatch_cnt, idle_pct } }
```

### UI-komponentti

Uusi näkymä tai olemassa olevan dashboard-näkymän laajennus:

- **Liikennevalo** (vihreä/keltainen/punainen) health_status -mukaan
- **Virhelista** virhekoodilla, aikaleimalla ja kontekstilla
- **Config-validoinnin tulos** startup-vaiheen jälkeen
- **Suorituskykymittarit** reaaliaika-palkkeina

---

## Toteutusjärjestys ja riippuvuudet

```
P1 (virhekoodit)
 │
 ├──→ P2 (startup-validointi)  ← käyttää samoja virhekoodeja
 │
 ├──→ P3 (phase timeout)       ← kirjoittaa g_error_last_code
 │
 └──→ P4 (virhejono)           ← korvaa / täydentää P1:n yksittäismuuttujat
       │
       └──→ P5 (health + perf) ← lukee virheitä ja varoituksia
```

P1 on kaiken perusta. P2 ja P3 ovat itsenäisiä toisistaan mutta riippuvat P1:n
virhekoodirakenteesta. P4 laajentaa P1:n tallennuskerrosta. P5 kokoaa kaiken
yhteen.

---

## Käyttöönottajan kokemus: ennen ja jälkeen

### Ennen

> TSK phase = 10000, DEP phase = 9000. Ei tapahdu mitään. Miksi?

### Jälkeen

> **HEALTH: ERROR**
>
> `ERROR 501` — DEP rejected all 3 waiting batches.
> Last reject: Unit 4, Stage 2 — travel time = 0 between stations 5 → 8.
> → Check `g_move[5][8].TravelTime` in GVL_Parameters.
>
> **Config validation at startup:**
> - ❌ `103` — Program 2, step 4 references station 15 which does not exist
> - ⚠️ Move time = 0 for station pair 5 → 8 (used by Program 2)
>
> **Performance:** TSK 12 ms | DEP 8 ms | Dispatched 0 | Idle 100%

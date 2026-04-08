# Käyttöönottajan diagnostiikka — toteutussuunnitelma

> Tavoite: salatun kirjaston käyttöönottaja saa riittävän informaation siitä,
> miksi scheduleri ei toimi, mitä parametreja puuttuu ja mitkä asetukset ovat ristiriitaisia.

## Rajaus

Tämän suunnitelman lähtökohta on seuraava:

1. **PLC-puolen diagnostiikka toteutetaan osana tuotantoversiota.**
2. **Gateway / DB / UI -kulutus mukautetaan ensimmäisessä vaiheessa vain simulaattoriin.**
3. PLC-diagnostiikka ei saa riippua simulaattorista, vaan sen pitää toimia myös ilman
    gatewayta, jolloin eventit jäävät luettaviksi PLC:n event-puskuriin.
4. Tuotantotoimituksessa mukana on sekä salattu kirjastologiikka että tarvittava avoin
    PLC-host-integraatio event-puskurin välitykseen.

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

## P1 — Virhekoodit olemassa olevan tapahtumapuskurin kautta

**Työmäärä:** pieni  
**Hyöty:** käyttöönottaja näkee heti MIKSI scheduleri ei toimi

### Suunnitteluperiaate

PLC-ympäristössä kaiken ylimääräisen pitää olla kevyttä. Siksi:

1. **Käytetään olemassa olevaa `g_event` -puskuria** — ei uusia jonoja eikä UDT:tä
2. **Uusi msg_type = 6** (SCHEDULER_DIAG) — vältetään törmäys nykyiseen msg_type 4 = BATCH_ACTIVATED
3. **Mode + Code** koodaavat kaiken kahteen INT-kenttään
4. **Tuotantoympäristö:** PLC tuottaa eventit ja säilyttää ne puskuriin luettaviksi OPC UA:n kautta
5. **Simulaattori:** Gateway lukee samat eventit, tallentaa ne DB:hen ja näyttää UI:ssa
6. **Eventtivirtaa rajoitetaan**: vain korkean arvon ja koosteistetut tapahtumat pusketaan event-puskuriin

### Eventtien tuotantopolitiikka

Jaettua event-puskuria ei voi käyttää jokaisen sisäisen iteraation telemetriaan.
Siksi eventtituotanto rajataan seuraavasti:

| Luokka | Politiikka |
|--------|------------|
| **CONFIG / PARAM** | aina ulos |
| **FIT** | vain lopputulos ja merkittävin epäonnistumissyy |
| **CONFLICT** | vain konfliktin löytyminen + lopullinen ratkaisuyhteenveto |
| **DISPATCH** | vain toteutunut dispatch tai selkeä estävä syy |
| **CYCLE** | vain kierroksen loppuyhteenveto tai timeout |
| **BALANCE** | vain balanssitilan muutos tai kierroksen yhteenveto |

Tavoite on, että yksi scheduler-kierros tuottaa tyypillisesti **0–3 diagnostiikkaeventiä**,
ei kymmeniä eventtejä per sisäinen looppi.

### Puskurin suojaus

Nykyinen 10 eventin puskuri on diagnostiikan kanssa liian pieni. Ensimmäisessä toteutusvaiheessa:

1. kasvatetaan `g_event.Buffer` **10 -> 30**
2. lisätään kevyt pudotuslaskuri, jotta mahdollinen ylivuoto näkyy

```iec-st
g_diag_drop_cnt   : DINT;  (* kuinka monta diagnostiikkaeventiä jäi puskematta *)
g_diag_last_mode  : INT;   (* viimeisin diagnostiikkaeventin mode *)
g_diag_last_code  : INT;   (* viimeisin diagnostiikkaeventin code *)
```

### Tapahtumien luonne

Diagnostiikkaeventi ei ole pelkkä "virheilmoitus". Se on **käyttöönoton tietokanava**
jossa on erityyppistä informaatiota:

| Tyyppi | Luonne | Esimerkki |
|--------|--------|-----------|
| **Fataali** | Setup on rikki, scheduleri ei voi toimia | Asemaa ei löydy, nopeus = 0 |
| **Virhe** | Koodi törmäsi odottamattomaan tilaan | Indeksi yli rajojen, ylivuoto |
| **Operatiivinen** | Normaali mutta käyttöönottajalle hyödyllinen | Sovittelu onnistui/epäonnistui, miksi ei mahdu |
| **Tilatieto** | Schedulerin sisäinen eteneminen | Tehtävälista balanssissa, iteraatiokierrokset |

Kaikki kulkevat samaa kanavaa — **mode** kertoo mitä aluetta event koskee,
**code** kertoo mitä tapahtui, ja **Payload[3..6]** antaa numeerisen kontekstin.

### Tapahtumaviestin rakenne (olemassa oleva UDT_JC_EventMsgType)

```
msg_type = 6     (SCHEDULER_DIAG)
Payload[1]  = mode    (INT, tapahtuman aihealue)
Payload[2]  = code    (INT, tarkka tapahtuma)
Payload[3]  = val1    (kontekstiarvo 1)
Payload[4]  = val2    (kontekstiarvo 2)
Payload[5]  = val3    (kontekstiarvo 3)
Payload[6]  = val4    (kontekstiarvo 4)
Payload[7..12] = 0    (varattu)
```

### Mode-taulukko (Payload[1])

| Mode | Nimi | Kuvaus | Vakavuus |
|------|------|--------|----------|
| **1** | `CONFIG` | Konfiguraatiovirhe — schedulerilla ei toimintaedellytyksiä | FATAL |
| **2** | `PARAM` | Parametrivirhe ajon aikana — koodi sai arvon jota ei osaa käsitellä | ERROR |
| **3** | `FIT` | DEP-sovittelu — onnistui, epäonnistui, miksi | INFO / WARN |
| **4** | `CONFLICT` | Konfliktiresoluutio — mitä löydettiin, miten ratkaistiin | INFO / WARN |
| **5** | `DISPATCH` | Tehtävän lähetys — onnistui, epäonnistui, miksi | INFO / WARN |
| **6** | `CYCLE` | Tilakoneen kierrostieto — TSK/DEP valmistui, kestot, iteraatiot | INFO |
| **7** | `BALANCE` | Tehtävälistan tasapaino — balanssissa / ei, vaje, yksikkö | INFO / WARN |

### Code-taulukot per mode

#### Mode 1: CONFIG (fataali konfiguraatiovirhe)

| Code | Kuvaus | val1 | val2 | val3 | val4 |
|------|--------|------|------|------|------|
| 1 | `CountStations` = 0 tai > MAX | station_count | — | — | — |
| 2 | Transportterin nopeus = 0 | trans_id | axis¹ | — | — |
| 3 | Working area alku > loppu | trans_id | start | end | — |
| 4 | Working area ei kata yhtään asemaa | trans_id | — | — | — |
| 5 | Treatment program viittaa tuntemattomaan asemaan | program_id | step | station_id | — |
| 6 | Duplikaatti XPosition | station_id_1 | station_id_2 | x_pos | — |
| 7 | `MinTime > MaxTime` ohjelmavaiheessa | program_id | step | min_time | max_time |
| 8 | `MaxTime < CalTime` ohjelmavaiheessa | program_id | step | max_time | cal_time |
| 9 | Move time = 0 käytetyllä asemaparilla | lift_stn | sink_stn | — | — |

¹ axis: 1=X, 2=Z

#### Mode 2: PARAM (parametrivirhe ajon aikana)

| Code | Kuvaus | val1 | val2 | val3 | val4 |
|------|--------|------|------|------|------|
| 1 | Unit index out of range | unit | — | — | — |
| 2 | Transporter index out of range | trans | — | — | — |
| 3 | Batch code = 0 | unit | stage | — | — |
| 4 | Program step count > MAX | unit | step_count | — | — |
| 5 | Program stage count = 0 | unit | batch_code | — | — |
| 6 | Time overflow (LINT) | unit | stage | — | — |

#### Mode 3: FIT (DEP-sovittelu)

| Code | Kuvaus | val1 | val2 | val3 | val4 |
|------|--------|------|------|------|------|
| 1 | Sovittelu onnistui | wait_unit | slot_idx | delay_s | trans_id |
| 2 | Ei mahdu — kaikki slotit liian pieniä | wait_unit | best_slot | overflow_s | — |
| 3 | Ei mahdu — matka-aika liian pitkä | wait_unit | lift_stn | sink_stn | travel_s |
| 4 | Ei mahdu — flex ei riitä | wait_unit | stage | flex_s | need_s |
| 5 | Kaikki odottavat batchit hylätty | wait_cnt | reject_cnt | — | — |
| 6 | Fit round raja saavutettu | fit_round | — | — | — |
| 7 | Batch aktivoitu onnistuneesti | wait_unit | batch_code | delay_s | — |
| 8 | ACTIVATE-data ei kulutettu TSK:n toimesta | pending_seq | — | — | — |

#### Mode 4: CONFLICT (konfliktiresoluutio)

| Code | Kuvaus | val1 | val2 | val3 | val4 |
|------|--------|------|------|------|------|
| 1 | Konflikti löydetty: TASK_SEQUENCE | conf_unit | conf_stage | blocked_unit | deficit_s |
| 2 | Konflikti löydetty: COLLISION | conf_unit | conf_stage | conf_trans | deficit_s |
| 3 | Konflikti löydetty: HANDOFF | conf_unit | conf_stage | blocked_unit | deficit_s |
| 4 | Ratkaistu: ADVANCE | unit | stage | advance_s | — |
| 5 | Ratkaistu: DELAY | unit | stage | delay_s | — |
| 6 | Ratkaistu: PRECEDING_DELAY | unit | stage | delay_s | — |
| 7 | Ratkaistu: DELAY_PREV_PAST_NEXT | unit | stage | delay_s | — |
| 8 | Oskillaatiolukko asetettu | unit | stage | direction¹ | lock_cnt |
| 9 | Max iterations saavutettu (40) | conf_type | unit | stage | iter_cnt |
| 10 | Kaikki konfliktit ratkaistu | total_stretches | total_adv_s | total_delay_s | iter_cnt |

¹ direction: 1=ADVANCE, 2=DELAY

#### Mode 5: DISPATCH (tehtävän lähetys)

| Code | Kuvaus | val1 | val2 | val3 | val4 |
|------|--------|------|------|------|------|
| 1 | Tehtävä lähetetty | unit | trans_id | lift_stn | sink_stn |
| 2 | Ei transportteria saatavilla | unit | lift_stn | sink_stn | — |
| 3 | Sink station varattu, ei vaihtoehtoa | unit | sink_stn | occupant | — |
| 4 | Unit ei nostoasemalla | unit | expected_stn | actual_stn | — |
| 5 | Tehtäväjono täynnä | trans_id | queue_count | — | — |
| 6 | Move-away käynnistetty | trans_id | from_stn | to_stn | — |

#### Mode 6: CYCLE (tilakoneen kierrostieto)

| Code | Kuvaus | val1 | val2 | val3 | val4 |
|------|--------|------|------|------|------|
| 1 | TSK-kierros valmis | cycle_ms | batch_cnt | task_cnt | conflict² |
| 2 | DEP-kierros valmis | cycle_ms | wait_cnt | activated² | reject_cnt |
| 3 | DEP ohitettu (TSK ei stable) | skip_cnt | — | — | — |
| 4 | Faasi ei etene (timeout) | phase | elapsed_s | — | — |

² BOOL koodattuna: 0/1

#### Mode 7: BALANCE (tehtävälistan tasapaino)

| Code | Kuvaus | val1 | val2 | val3 | val4 |
|------|--------|------|------|------|------|
| 1 | Balanssissa — ei konflikteja | batch_cnt | task_cnt | — | — |
| 2 | Epäbalanssissa — aikavaje | unit | stage | deficit_s | — |
| 3 | Epäbalanssissa — transportteri ylikuormitettu | trans_id | task_cnt | idle_pct | — |
| 4 | Stretch-yhteenveto | stretch_cnt | total_adv_s | total_delay_s | — |

### Toteutus PLC:ssä

`STC_PushDiag` on kevyt FUNCTION (~15 riviä) joka kirjoittaa `g_event_pending`:

```iec-st
FUNCTION STC_PushDiag : BOOL
VAR_INPUT
    i_mode : INT;   (* tapahtuman aihealue, 1-7 *)
    i_code : INT;   (* tarkka tapahtuma moden sisällä *)
    i_v1   : INT;   (* kontekstiarvo 1 *)
    i_v2   : INT;   (* kontekstiarvo 2 *)
    i_v3   : INT;   (* kontekstiarvo 3 *)
    i_v4   : INT;   (* kontekstiarvo 4 *)
END_VAR

IF NOT g_event_pending_valid THEN
    g_event_pending.MsgType := 6;  (* SCHEDULER_DIAG *)
    g_event_pending.Payload[1] := i_mode;
    g_event_pending.Payload[2] := i_code;
    g_event_pending.Payload[3] := i_v1;
    g_event_pending.Payload[4] := i_v2;
    g_event_pending.Payload[5] := i_v3;
    g_event_pending.Payload[6] := i_v4;
    g_event_pending_valid := TRUE;
    g_diag_last_mode := i_mode;
    g_diag_last_code := i_code;
    STC_PushDiag := TRUE;
ELSE
    g_diag_drop_cnt := g_diag_drop_cnt + 1;
END_IF;
```

Kutsuesimerkki — fataali konfiguraatiovirhe:

```iec-st
(* STC_ValidateConfig: transportterin nopeus = 0 *)
IF g_cfg[t].Speed_X <= 0.0 THEN
    STC_PushDiag(i_mode := 1, i_code := 2, i_v1 := t, i_v2 := 1, i_v3 := 0, i_v4 := 0);
    error_count := error_count + 1;
END_IF;
```

Kutsuesimerkki — operatiivinen tieto (sovittelu epäonnistui):

```iec-st
(* DEP_FitTaskToSlot: ei mahdu, flex ei riitä *)
STC_PushDiag(i_mode := 3, i_code := 4,
    i_v1 := wait_unit, i_v2 := stage, i_v3 := flex_s, i_v4 := need_s);
```

Kutsuesimerkki — tilakoneen kierrostieto:

```iec-st
(* STC_FB_MainScheduler: TSK-kierros valmis *)
STC_PushDiag(i_mode := 6, i_code := 1,
    i_v1 := tsk_cycle_ms, i_v2 := batch_cnt, i_v3 := task_cnt, i_v4 := conflict_int);
```

Pikakatsausmuuttuja GVL:ssä:

```iec-st
(* GVL_JC_Scheduler *)
g_diag_last_mode : INT;   (* viimeisimmän diagnostiikkaevetin mode *)
g_diag_last_code : INT;   (* viimeisimmän diagnostiikkaevetin code *)
```

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Lisää `g_diag_last_mode`, `g_diag_last_code`, `g_diag_drop_cnt` |
| `UDTs/UDT_JC_EventQueueType.st` | Kasvata event-puskuri 10 -> 30 |
| `POUs/STC_PushDiag.st` | **Uusi** — kevyt event-funktio (~15 riviä) |
| `POUs/STC_CalcSchedule.st` | `STC_PushDiag(2, 1, ...)` / `(2, 2, ...)` ennen RETURN |
| `POUs/STC_CreateTasks.st` | `STC_PushDiag(2, 1, ...)` / `(2, 5, ...)` |
| `POUs/STC_ShiftSchedule.st` | `STC_PushDiag(2, 1, ...)` |
| `POUs/DEP_CalcIdleSlots.st` | `STC_PushDiag(2, 2, ...)` |
| `POUs/DEP_FitTaskToSlot.st` | `STC_PushDiag(3, 2..4, ...)` sovittelutulokset |
| `POUs/DEP_FB_Scheduler.st` | `STC_PushDiag(3, 5..8, ...)` kierrostulokset |
| `POUs/TSK_Analyze.st` | `STC_PushDiag(4, 1..3, ...)` konfliktit |
| `POUs/TSK_Resolve.st` | `STC_PushDiag(4, 4..10, ...)` ratkaisut |
| `POUs/STC_DispatchTask.st` | `STC_PushDiag(5, 1..6, ...)` dispatch-tulokset |
| `POUs/STC_FB_MainScheduler.st` | `STC_PushDiag(6, 1..4, ...)` kierrostiedot |
| `POUs/plc_prg.st` tai tuotannon host-PLC-pääohjelma | Sisällytä event queue -välitys myös tuotantoversioon |
| `build_codesys_xml.py` | Lisää `STC_PushDiag.st` POU-listaan |

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

| # | Tarkistus | Mode:Code | Vakavuus |
|---|-----------|-----------|----------|
| 1 | `CountStations > 0` ja `≤ MAX_Stations` | 1:1 | FATAL |
| 2 | Jokaisella transportterilla `Speed_X > 0` ja `Speed_Z > 0` | 1:2 | FATAL |
| 3 | Jokaisella asemalla `XPosition` on uniikki | 1:6 | FATAL |
| 4 | Treatment program: jokainen asemavaihe viittaa olemassa olevaan asemaan | 1:5 | FATAL |
| 5 | Treatment program: `MinTime ≤ CalTime ≤ MaxTime` joka vaiheessa | 1:7, 1:8 | FATAL |
| 6 | Transportterin `WorkingArea_Start ≤ WorkingArea_End` | 1:3 | FATAL |
| 7 | Transportterin working area kattaa vähintään yhden aseman | 1:4 | FATAL |
| 8 | Move times: `TravelTime > 0` kaikilla käytetyillä asemapareilla | 1:9 | WARNING* |
| 9 | Vähintään yksi aktiivinen batch olemassa | — | WARNING |
| 10 | Ei päällekkäisiä batch-koodeja samalla unit-indeksillä | — | WARNING |

\* Tarkistus ajetaan vain jos liikekestoja odotetaan esiladattavan gatewayn kautta.
Muussa tapauksessa se siirretään käyttöönoton jälkeiseksi varoitukseksi, ei init-vaiheen estoksi.

#### Integraatio MainScheduleriin

```iec-st
(* STC_FB_MainScheduler — INIT-vaiheessa *)
CASE phase OF
    1: (* INIT *)
        validator(
            (* ei inputteja, lukee globaalit suoraan *)
            (* kutsuu STC_PushDiag(1, x, ...) jokaisesta löydetystä ongelmasta *)
        );
        IF NOT validator.o_valid THEN
            g_diag_last_mode := 1;
            g_diag_last_code := validator.o_first_code;
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
    STC_PushDiag(i_mode := 6, i_code := 4,
                 i_v1 := current_phase,
                 i_v2 := INT_TO_DINT(g_now - g_phase_start_time),
                 i_v3 := 0, i_v4 := 0);
END_IF;
```

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Lisää `g_phase_start_time`, `g_phase_timeout_s`, `g_warn_stuck_phase` |
| `POUs/STC_FB_MainScheduler.st` | Timeout-tarkistus + faasinvaihdon aikaleima |

---

## P4 — Health status + suorituskykymittarit

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

(* === NOSTIMEN KUORMITUSASTE === *)
g_trans_busy_s   : ARRAY[1..MAX_Transporters] OF DINT;  (* kumulatiivinen busy-aika sekunneissa *)
g_trans_total_s  : ARRAY[1..MAX_Transporters] OF DINT;  (* kokonaisaika resetistä sekunneissa *)
g_trans_util_pct : ARRAY[1..MAX_Transporters] OF INT;   (* kuormitusaste 0-100 % *)

(* === VAROITUSTILAT === *)
g_warn_queue_near_full   : BOOL;   (* tehtäväjono > 80% kapasiteetista *)
g_warn_no_transporter    : BOOL;   (* tehtävä odottaa, kaikki transportterit varattu *)
g_warn_dep_all_rejected  : BOOL;   (* DEP hylkäsi kaikki odottavat batchit *)
g_warn_conflict_loop     : BOOL;   (* konfliktiresoluutio oskillaatio havaittu *)
```

#### Health status -logiikka MainSchedulerissa

```iec-st
(* joka kierroksella *)
IF g_warn_stuck_phase OR g_diag_last_mode = 1 THEN
    g_health_status := 2;  (* ERROR *)
    g_health_code := g_diag_last_code;
ELSIF g_warn_queue_near_full OR g_warn_no_transporter
      OR g_warn_dep_all_rejected OR g_warn_conflict_loop THEN
    g_health_status := 1;  (* WARNING *)
    g_health_code := g_diag_last_code;
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

#### Nostimen kuormitusaste

PLC-koodi ei nykyisellään laske nostimen kuormitusastetta. Lisätään
joka syklillä tuotantoversion PLC-ajossa. Simulaattorissa laskenta voidaan tehdä
`SIM_FB_RunTasks`:ssa, mutta tuotantotoimituksessa integraatiopiste on asiakkaan
PLC-host-ohjelma / pääsykli, joka kutsuu kirjastoa.

```iec-st
(* tarvittavat lisämuuttujat *)
g_reset_time_s : LINT;   (* resetin / initin aikaleima *)
cycle_dt_s     : DINT;   (* edellisen syklin kesto sekunteina tai 100 ms resoluutiossa *)
```

Laskenta:

```iec-st
(* joka syklillä, per transporter *)
g_trans_total_s[t] := LINT_TO_DINT(g_time_s - g_reset_time_s);

IF g_transporter[t].Phase > 0 THEN
    (* Phase > 0 = nostin suorittaa tehtävää *)
    g_trans_busy_s[t] := g_trans_busy_s[t] + cycle_dt_s;
END_IF;

(* kuormitusaste prosentteina *)
IF g_trans_total_s[t] > 0 THEN
    g_trans_util_pct[t] := DINT_TO_INT(g_trans_busy_s[t] * 100 / g_trans_total_s[t]);
END_IF;
```

Nollataan resetin (g_cmd_code = 2) yhteydessä:

```iec-st
FOR t := 1 TO MAX_Transporters DO
    g_trans_busy_s[t] := 0;
    g_trans_total_s[t] := 0;
    g_trans_util_pct[t] := 0;
END_FOR;
```

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Kaikki uudet health/perf/warn/utilization -muuttujat |
| `POUs/STC_FB_MainScheduler.st` | Health-logiikka + suorituskykymittaus |
| tuotannon host-PLC-pääohjelma | Kuormitusastelaskenta joka syklillä (production) |
| `POUs/SIM/SIM_FB_RunTasks.st` | Sama laskenta dev-/simulaattoriympäristössä |
| `POUs/TSK_FB_Scheduler.st` | `g_warn_conflict_loop` asetus resolve-vaiheessa |
| `POUs/DEP_FB_Scheduler.st` | `g_warn_dep_all_rejected` asetus reject-vaiheessa |
| `POUs/STC_DispatchTask.st` | `g_warn_no_transporter`, `g_warn_queue_near_full` |

#### UI-integraatio: MiniPieChart (vaihtoehto A — Gateway mäppää PLC-datat)

UI:ssa on valmis `MiniPieChart`-komponentti (`src/components/StationLayout/helpers/MiniPieChart.jsx`)
joka piirtää donut-kaavion idle- (harmaa) ja active-ajan (vihreä) perusteella.
Komponentti lukee `phase_stats_idle_ms` ja `phase_stats_*_ms` -kenttiä.

**Nykytila:** kentät ovat aina 0, koska gateway ei kumuloi aikaa.
Pie-chart näyttää tyhjän harmaan ympyrän.

**Ratkaisu:** Gateway lukee PLC:ltä `g_trans_busy_s` ja `g_trans_total_s`,
muuntaa ne nykyisiin ms-kenttiin. UI ei tarvitse muutoksia.

**opcua_adapter.js — readState()-funktion muutokset:**

```javascript
// Lue PLC:ltä (OPC UA)
const busy_s  = toNum(v[`sched.trans_busy_s_${t}`]);
const total_s = toNum(v[`sched.trans_total_s_${t}`]);
const idle_s  = Math.max(0, total_s - busy_s);

// Mäppää olemassa oleviin UI-kenttiin (millisekunteina)
state.phase_stats_idle_ms = idle_s * 1000;
state.phase_stats_move_to_lift_ms = busy_s * 1000;  // koko busy yhteen kenttään
state.phase_stats_lifting_ms = 0;
state.phase_stats_move_to_sink_ms = 0;
state.phase_stats_sinking_ms = 0;
```

**opcua_nodes.js — lisättävät nodet:**

```javascript
// per transporter (t = 1..MAX_Transporters)
`sched.trans_busy_s_${t}`  → GVL_JC_Scheduler.g_trans_busy_s[t]   (DINT, read)
`sched.trans_total_s_${t}` → GVL_JC_Scheduler.g_trans_total_s[t]  (DINT, read)
```

**Muutettavat tiedostot (Gateway/UI):**

| Tiedosto | Muutos |
|----------|--------|
| `services/gateway/opcua_nodes.js` | Lisää `trans_busy_s`, `trans_total_s` nodet per transporter |
| `services/gateway/opcua_adapter.js` | `readState()`: lue PLC-arvot, mäppää `phase_stats_*_ms` -kenttiin |

UI:ssa ei muutoksia — `MiniPieChart.jsx` ja `Transporter2D.jsx` toimivat sellaisenaan.

---

## P5 — Move time -konvergenssi (liikkeiden aikojen vakiintuminen)

**Työmäärä:** pieni  
**Hyöty:** käyttöönottaja näkee, ovatko schedulerin ajoitukset jo luotettavia

### Tausta

Scheduleri käyttää `g_move[transporter]` -taulukon matka-aikoja kaikissa
ajoituspäätöksissä (dispatch, DEP fit, konfliktianalyysi). Ajat päivittyvät
jokaisen valmistuneen tehtävän jälkeen eksponentiaalisella liukuvalla
keskiarvolla (EMA):

$$V_{n+1} = \frac{4 \cdot V_n + m}{5}$$

missä $m$ on uusi mittaus ja $V_n$ nykyinen tallennettu arvo.

Käyttöönoton alussa ajat eivät ole luotettavia (perustuvat alkuarvoihin tai
muutamaan mittaukseen). Käyttöönottajalla ei ole nykyisellään mitään keinoa
tietää, milloin ajat ovat vakiintuneet.

### Toteutus

Lisätään `GVL_JC_Scheduler`-muuttujiin:

```iec-st
(* === MOVE TIME KONVERGENSSI === *)
g_move_sample_cnt : ARRAY[1..MAX_Transporters] OF INT;  (* tehtävälaskuri per transporter *)
g_move_conv_pct   : ARRAY[1..MAX_Transporters] OF INT;  (* viimeisin suhteellinen muutos, promillea *)
g_move_converged  : BOOL;                               (* TRUE kun kaikki transportterit vakaat *)
```

#### Mittauslogiikka `STC_TrackMoveTimes`:ssa

Lisätään ennen nykyistä EMA-päivitystä (faasi 4→0):

```iec-st
(* kokonaisaika ENNEN EMA-päivitystä *)
old_total := g_move[tid].LiftTime[li]
           + g_move[tid].Travel[fi].ToTime[si]
           + g_move[tid].SinkTime[si];

(* kokonaisaika mittauksesta *)
meas_total := raw_lift + raw_trav2 + raw_sink;  (* 0.1s yksiköissä *)

(* suhteellinen muutos promilleina *)
IF old_total > 0 THEN
    g_move_conv_pct[tid] := ABS(meas_total - old_total) * 1000 / old_total;
ELSE
    g_move_conv_pct[tid] := 9999;  (* ei vertailupohjaa *)
END_IF;

g_move_sample_cnt[tid] := MIN(g_move_sample_cnt[tid] + 1, 32767);

(* --- tästä eteenpäin nykyinen EMA-päivitys --- *)
```

#### Kokonaiskonvergenssi `STC_FB_MainScheduler`:ssa

```iec-st
g_move_converged := TRUE;
FOR t := 1 TO active_transporter_count DO
    IF g_move_sample_cnt[t] < 5 OR g_move_conv_pct[t] > 20 THEN  (* > 2.0% *)
        g_move_converged := FALSE;
    END_IF;
END_FOR;
```

Kynnysarvot:
- Vähimmäisnäytteet: **5 tehtävää** (EMA tarvitsee muutaman kierroksen)
- Muutoskynnys: **20 promillea = 2,0 %** (alle tämän ≈ vakaa)

#### Konvergenssin eteneminen

EMA:n luonteen vuoksi suhteellinen muutos pienenee eksponentiaalisesti:

| Tehtävä # | Tyypillinen `g_move_conv_pct` | Tulkinta |
|-----------|-------------------------------|----------|
| 1 | 9999 | Ei vertailupohjaa |
| 2 | 200–500 | 20–50 % — voimakas hakeutuminen |
| 5 | 50–100 | 5–10 % — lähestyy |
| 10 | 10–30 | 1–3 % — vakiintumassa |
| 20+ | < 10 | < 1 % — vakaa |

### Muutettavat tiedostot

| Tiedosto | Muutos |
|----------|--------|
| `GVLs/GVL_JC_Scheduler.st` | Lisää `g_move_sample_cnt`, `g_move_conv_pct`, `g_move_converged` |
| `POUs/STC_TrackMoveTimes.st` | Konvergenssimittaus ennen EMA-päivitystä |
| `POUs/STC_FB_MainScheduler.st` | `g_move_converged` -arviointi joka kierroksella |

---

## Gateway / UI -integraatio simulaattoriin (1. vaihe)

Gateway ja UI eivät ole osa salattua kirjastoa. Ensimmäisessä vaiheessa ne
mukautetaan vain simulaattoriin kuluttamaan PLC:n tuottamaa diagnostiikkaa.
Tuotantoversio toimii myös ilman gatewayta: diagnostiikka jää PLC:n event-puskuriin
ja pikakatsausmuuttujiin luettavaksi.

### OPC UA -nodet (opcua_nodes.js)

Ei lisänodeja — diagnostiikkaviestit kulkevat olemassa olevan `g_event` -puskurin kautta
samalla mekanismilla kuin msg_type 1–5. Gateway tunnistaa `msg_type = 6` ja
käsittelee diagnostiikkana.

Lisäksi luetaan suoraan:

```
g_diag_last_mode, g_diag_last_code   (* pikakatsaus viimeisimpään eventiin *)
g_health_status, g_health_code
g_warn_stuck_phase, g_warn_queue_near_full, g_warn_no_transporter,
g_warn_dep_all_rejected, g_warn_conflict_loop
g_perf_tsk_cycle_ms, g_perf_dep_cycle_ms
g_trans_busy_s[1..MAX_Transporters], g_trans_total_s[1..MAX_Transporters]
g_trans_util_pct[1..MAX_Transporters]
g_move_sample_cnt[1..MAX_Transporters], g_move_conv_pct[1..MAX_Transporters]
g_move_converged
```

### Gateway: diagnostiikkaviestien käsittely (event_consumer.js)

Gateway lukee `g_event` -puskuria jo nyt. Lisätään `msg_type = 6` haara:

Diagnostiikka tallennetaan aluksi samaan olemassa olevaan `events`-tauluun kuin
muutkin PLC-eventit. Erillistä `scheduler_events`-taulua ei tarvita ensimmäisessä vaiheessa.

```javascript
case 6: // SCHEDULER_DIAG
    const mode = f[0];
    const code = f[1];
    const context = { v1: f[2], v2: f[3],
                                        v3: f[4], v4: f[5] };
  await db.query(
        `INSERT INTO events (seq, msg_type, plc_ts, f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,0,0,0,0,0,0,0)`,
                [event.seq, 6, plcTs, mode, code, f[2], f[3], f[4], f[5]]
  );
  break;
```

### Tietokanta: diagnostiikkakoodien selkokieliset kuvaukset (init.sql)

Uusi lookup-taulu — avaimena (mode, code) -pari:

```sql
CREATE TABLE IF NOT EXISTS diag_codes (
  mode        INT NOT NULL,       -- 1-7, vastaa Payload[1]
  code        INT NOT NULL,       -- moden sisäinen koodi, vastaa Payload[2]
  mode_name   TEXT NOT NULL,      -- 'CONFIG', 'PARAM', 'FIT', 'CONFLICT', 'DISPATCH', 'CYCLE', 'BALANCE'
  severity    TEXT NOT NULL,      -- 'FATAL', 'ERROR', 'WARNING', 'INFO'
  description TEXT NOT NULL,      -- selkokielinen kuvaus
  hint        TEXT,               -- käyttöönottovinkki
  val_labels  TEXT,               -- val1..4 selitykset, esim. 'trans_id, axis, -, -'
  PRIMARY KEY (mode, code)
);

INSERT INTO diag_codes (mode, code, mode_name, severity, description, hint, val_labels) VALUES
  -- Mode 1: CONFIG (fataali)
  (1, 1, 'CONFIG', 'FATAL', 'CountStations = 0 or > MAX',                     'Set via gateway before INIT',                        'station_count, -, -, -'),
  (1, 2, 'CONFIG', 'FATAL', 'Transporter speed = 0',                          'Set Speed_X/Z > 0 in g_cfg',                         'trans_id, axis(1=X 2=Z), -, -'),
  (1, 3, 'CONFIG', 'FATAL', 'Working area start > end',                       'Swap WorkingArea_Start and _End',                     'trans_id, start, end, -'),
  (1, 4, 'CONFIG', 'FATAL', 'Working area covers no stations',                'Extend working area or add stations',                 'trans_id, -, -, -'),
  (1, 5, 'CONFIG', 'FATAL', 'Treatment program references unknown station',   'Check station exists in Stations',                   'program_id, step, station_id, -'),
  (1, 6, 'CONFIG', 'FATAL', 'Duplicate XPosition on stations',                'Each station needs unique X coordinate',               'stn_id_1, stn_id_2, x_pos, -'),
  (1, 7, 'CONFIG', 'FATAL', 'MinTime > MaxTime in program step',              'Fix treatment program timing',                        'program_id, step, min_time, max_time'),
  (1, 8, 'CONFIG', 'FATAL', 'MaxTime < CalTime in program step',              'Increase MaxTime or decrease CalTime',                'program_id, step, max_time, cal_time'),
  (1, 9, 'CONFIG', 'WARNING', 'Move time = 0 for used station pair',          'Run a cycle or set movement_times.json',              'lift_stn, sink_stn, -, -'),

  -- Mode 2: PARAM (runtime virhe)
  (2, 1, 'PARAM',  'ERROR', 'Unit index out of range',                        'i_unit must be 1..MAX_Units',                         'unit, -, -, -'),
  (2, 2, 'PARAM',  'ERROR', 'Transporter index out of range',                 'i_trans must be 1..MAX_Transporters',                 'trans, -, -, -'),
  (2, 3, 'PARAM',  'ERROR', 'Batch code = 0',                                'Batch must have non-zero code',                       'unit, stage, -, -'),
  (2, 4, 'PARAM',  'ERROR', 'Program step count > MAX',                       'Treatment program has too many steps',                'unit, step_count, -, -'),
  (2, 5, 'PARAM',  'ERROR', 'Program stage count = 0',                        'Batch has no treatment stages',                       'unit, batch_code, -, -'),
  (2, 6, 'PARAM',  'ERROR', 'Time overflow (LINT)',                            'Check time_sync value',                               'unit, stage, -, -'),

  -- Mode 3: FIT (DEP-sovittelu)
  (3, 1, 'FIT',    'INFO',    'Fitting succeeded',                            NULL,                                                   'wait_unit, slot_idx, delay_s, trans_id'),
  (3, 2, 'FIT',    'WARNING', 'No fit: all slots too small',                  'Idle gaps too short for this batch',                   'wait_unit, best_slot, overflow_s, -'),
  (3, 3, 'FIT',    'WARNING', 'No fit: travel time too long',                 'Stations too far apart for idle gap',                  'wait_unit, lift_stn, sink_stn, travel_s'),
  (3, 4, 'FIT',    'WARNING', 'No fit: insufficient flex',                    'Increase MaxTime or decrease CalTime',                 'wait_unit, stage, flex_s, need_s'),
  (3, 5, 'FIT',    'WARNING', 'All waiting batches rejected',                 'No waiting batch fits in any idle slot',               'wait_cnt, reject_cnt, -, -'),
  (3, 6, 'FIT',    'WARNING', 'Fit round limit reached',                      'DEP recalculation loop hit maximum',                   'fit_round, -, -, -'),
  (3, 7, 'FIT',    'INFO',    'Batch activated successfully',                 NULL,                                                   'wait_unit, batch_code, delay_s, -'),
  (3, 8, 'FIT',    'WARNING', 'ACTIVATE data not consumed by TSK',            'TSK did not process previous activation',              'pending_seq, -, -, -'),

  -- Mode 4: CONFLICT (konfliktiresoluutio)
  (4, 1,  'CONFLICT', 'INFO',    'Conflict found: TASK_SEQUENCE',             NULL,                                                   'conf_unit, conf_stage, blocked_unit, deficit_s'),
  (4, 2,  'CONFLICT', 'INFO',    'Conflict found: COLLISION',                 NULL,                                                   'conf_unit, conf_stage, conf_trans, deficit_s'),
  (4, 3,  'CONFLICT', 'INFO',    'Conflict found: HANDOFF',                   NULL,                                                   'conf_unit, conf_stage, blocked_unit, deficit_s'),
  (4, 4,  'CONFLICT', 'INFO',    'Resolved: ADVANCE',                         NULL,                                                   'unit, stage, advance_s, -'),
  (4, 5,  'CONFLICT', 'INFO',    'Resolved: DELAY',                           NULL,                                                   'unit, stage, delay_s, -'),
  (4, 6,  'CONFLICT', 'INFO',    'Resolved: PRECEDING_DELAY',                 NULL,                                                   'unit, stage, delay_s, -'),
  (4, 7,  'CONFLICT', 'INFO',    'Resolved: DELAY_PREV_PAST_NEXT',            NULL,                                                   'unit, stage, delay_s, -'),
  (4, 8,  'CONFLICT', 'WARNING', 'Oscillation lock set',                      'Same stage being advanced and delayed',                'unit, stage, direction(1=ADV 2=DEL), lock_cnt'),
  (4, 9,  'CONFLICT', 'ERROR',   'Max iterations reached (40)',               'Conflict could not be resolved',                      'conf_type, unit, stage, iter_cnt'),
  (4, 10, 'CONFLICT', 'INFO',    'All conflicts resolved',                    NULL,                                                   'total_stretches, total_adv_s, total_delay_s, iter_cnt'),

  -- Mode 5: DISPATCH (tehtävän lähetys)
  (5, 1, 'DISPATCH', 'INFO',    'Task dispatched',                            NULL,                                                   'unit, trans_id, lift_stn, sink_stn'),
  (5, 2, 'DISPATCH', 'WARNING', 'No transporter available',                   'All transporters busy or out of area',                 'unit, lift_stn, sink_stn, -'),
  (5, 3, 'DISPATCH', 'WARNING', 'Sink station occupied, no alternative',      'Wait or free the occupied station',                    'unit, sink_stn, occupant, -'),
  (5, 4, 'DISPATCH', 'WARNING', 'Unit not at lift station',                   'Unit must be at expected station',                     'unit, expected_stn, actual_stn, -'),
  (5, 5, 'DISPATCH', 'WARNING', 'Task queue full',                            'MAX_TASK_QUEUE reached for transporter',               'trans_id, queue_count, -, -'),
  (5, 6, 'DISPATCH', 'INFO',    'Move-away started',                          NULL,                                                   'trans_id, from_stn, to_stn, -'),

  -- Mode 6: CYCLE (tilakoneen kierrostieto)
  (6, 1, 'CYCLE', 'INFO',    'TSK cycle complete',                            NULL,                                                   'cycle_ms, batch_cnt, task_cnt, has_conflict'),
  (6, 2, 'CYCLE', 'INFO',    'DEP cycle complete',                            NULL,                                                   'cycle_ms, wait_cnt, activated, reject_cnt'),
  (6, 3, 'CYCLE', 'INFO',    'DEP skipped (TSK not stable)',                  NULL,                                                   'skip_cnt, -, -, -'),
  (6, 4, 'CYCLE', 'ERROR',   'Phase stuck (timeout)',                         'Scheduler phase not advancing — check inputs',         'phase, elapsed_s, -, -'),

  -- Mode 7: BALANCE (tehtävälistan tasapaino)
  (7, 1, 'BALANCE', 'INFO',    'Balanced — no conflicts',                     NULL,                                                   'batch_cnt, task_cnt, -, -'),
  (7, 2, 'BALANCE', 'WARNING', 'Unbalanced — time deficit',                   'Stage needs more time than available',                 'unit, stage, deficit_s, -'),
  (7, 3, 'BALANCE', 'WARNING', 'Unbalanced — transporter overloaded',         'Consider adding transporters or reducing batches',     'trans_id, task_cnt, idle_pct, -'),
  (7, 4, 'BALANCE', 'INFO',    'Stretch summary',                             NULL,                                                   'stretch_cnt, total_adv_s, total_delay_s, -')
ON CONFLICT (mode, code) DO NOTHING;
```

Suositus: lisää lisäksi näkymä `diag_events`, joka yhdistää `events` + `diag_codes`
ja piilottaa `f1..f6`-kenttien teknisen mallin gatewaylta ja UI:lta.

### Dashboard API (dashboard_api.js)

Uusi endpoint:

```
GET /api/scheduler/health
→ { status: "OK"|"WARNING"|"ERROR"|"STOPPED",
    code: 0,
    errors: [...],
    warnings: [...],
    performance: { tsk_ms, dep_ms, dispatch_cnt,
                   utilization: [
                     { id: 1, busy_s: 3420, total_s: 7200, pct: 47 },
                     { id: 2, busy_s: 2880, total_s: 7200, pct: 40 } ] },
    convergence: { converged: true,
                   transporters: [
                     { id: 1, samples: 23, changePct: 0.3 },
                     { id: 2, samples: 18, changePct: 0.8 } ] } }

GET /api/scheduler/diag?limit=50&mode=3
→ [ { ts, mode, mode_name, code, severity, description, hint, values, val_labels } ]
    -- yhdistää events(msg_type=6) + diag_codes (mode, code)
  -- mode-filtteri vapaaehtoinen: näytä vain FIT / CONFLICT / jne.
```

### UI-komponentti

Uusi näkymä tai olemassa olevan dashboard-näkymän laajennus:

- **Liikennevalo** (vihreä/keltainen/punainen) health_status -mukaan
- **Diagnostiikkaloki** — mode + koodi + selkokielinen kuvaus + vinkki + arvot + aikaleima
- **Mode-filtteri** — näytä vain CONFIG / FIT / CONFLICT / DISPATCH / jne.
- **Config-validoinnin tulos** startup-vaiheen jälkeen
- **Suorituskykymittarit** reaaliaika-palkkeina
- **Konvergenssinäkymä** per transporter: näytemäärä, muutos-%, vakiintunut-lippu

---

## Toteutusjärjestys ja riippuvuudet

```
P1 (STC_PushDiag + mode/code -rakenne via g_event)
 │
 ├──→ P2 (startup-validointi)  ← pushaa mode=1 (CONFIG) eventit
 │
 ├──→ P3 (phase timeout)       ← pushaa mode=6, code=4
 │
 └──→ P4 (health + perf)       ← lukee g_diag_last_mode + warn-lippuja

P5 (konvergenssi)              ← itsenäinen, ei riipu P1–P4:stä

PLC rollout (production)       ← toteutetaan ensin kokonaan
Simulator rollout              ← gateway + DB + UI kuluttavat msg_type=6 eventtejä
DB: diag_codes -taulu          ← selkokieliset kuvaukset, voidaan lisätä milloin tahansa
UI: diagnostiikkanäkymä        ← parsii koodit + kuvaukset DB:stä
```

P1 on kaiken perusta — kevyt `STC_PushDiag(mode, code, v1..v4)` -funktio
ja `msg_type = 6` tapahtumapuskurissa. P2 ja P3 käyttävät samaa funktiota.
P4 kokoaa terveystilan. P5 on itsenäinen.

Gateway/DB/UI -kerros ei ole PLC-diagnostiikan edellytys: PLC toimii ilman niitä,
eventit jäävät puskuriin ja `g_diag_last_code` on luettavissa suoraan. Ensimmäinen
kuluttajaintegraatio tehdään simulaattoriin.

---

## Käyttöönottajan kokemus: ennen ja jälkeen

### Ennen

> TSK phase = 10000, DEP phase = 9000. Ei tapahdu mitään. Miksi?

### Jälkeen

> **HEALTH: ERROR**
>
> **[CONFIG 1:5]** FATAL — Treatment program references unknown station
> → program_id=2, step=4, station_id=15
> → *Hint: Check station exists in Stations*
>
> **[CONFIG 1:9]** WARNING — Move time = 0 for used station pair
> → lift_stn=105, sink_stn=108
> → *Hint: Run a cycle or set movement_times.json*

**Filter: FIT (mode=3)**

> **[FIT 3:4]** WARNING — No fit: insufficient flex
> → wait_unit=4, stage=2, flex_s=12, need_s=25
> → *Hint: Increase MaxTime or decrease CalTime*
>
> **[FIT 3:5]** WARNING — All waiting batches rejected
> → wait_cnt=3, reject_cnt=3

**Filter: CONFLICT (mode=4)**

> **[CONFLICT 4:1]** INFO — Conflict found: TASK_SEQUENCE
> → conf_unit=2, conf_stage=3, blocked_unit=5, deficit_s=8
>
> **[CONFLICT 4:5]** INFO — Resolved: DELAY
> → unit=5, stage=3, delay_s=8
>
> **[CONFLICT 4:10]** INFO — All conflicts resolved
> → total_stretches=3, total_adv_s=12, total_delay_s=8, iter_cnt=4

**Filter: CYCLE (mode=6)**

> **[CYCLE 6:1]** INFO — TSK cycle complete
> → cycle_ms=14, batch_cnt=5, task_cnt=12, has_conflict=0

> **Performance:** TSK 14 ms | DEP 8 ms | Dispatched 2 | Idle 33%
>
> **Move time convergence:**
> - Transporter 1: 23 samples, Δ 0.3 % ✅ converged
> - Transporter 2: 4 samples, Δ 12.5 % ⏳ settling
> - Transporter 3: 0 samples ⚠️ no data

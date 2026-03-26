# Pintakäsittelylinjan suorituskyvyn mittaus ja parantaminen

## 1. Teoriapohja — sovellettuna nostinlaitokseen

Linja on **job-shop-tyyppinen batch-prosessi**, jossa:
- Erät liikkuvat käsittelyasemien välillä **nostureiden** avulla (jaettu resurssi)
- Jokaisella asemalla on **min/max** -upotusaika (kemiallinen prosessi)
- Nosturit ovat **kapasiteetin rajoite** (bottleneck) — kaikki liike kulkee niiden kautta
- Laatua ei simuloida (Quality = 100%), joten keskitytään **Availability** × **Performance**

### Kolme avain-KPI:tä

| KPI | Määritelmä linjalle | Datalähde |
|---|---|---|
| **Takt Time** (tahtiikka) | Keskimääräinen aika peräkkäisten erien aktivointien (DEP) välillä | DEP-sykleistä: `activation_time[n+1] − activation_time[n]` |
| **Throughput** (suoritusteho) | Valmiit erät / aikajakso | `lift_events` viimeisestä asemasta (stage = max) |
| **Transporter Utilization** (nostimen käyttöaste) | % ajasta jolloin nostin suorittaa tehtävää vs. idle | `task_complete` + kokonaisaika |

### Pullonkaula-analyysi (Theory of Constraints)

Schedulerin perustehtävä on taata, että **yliaikoja ei synny** — jokainen erä nostetaan pois asemalta ennen max-ajan umpeutumista. Jos yliaikoja kuitenkin esiintyy, kyseessä on **schedulerin toimintahäiriö**, ei pullonkaulaindikaattori.

Pullonkaulan tunnistus oikein toimivalla linjalla:

- **Marginaali (max − actual)**: Asema jolla marginaali on pienin → nosturi ehtii juuri ja juuri → pullonkaulariski
- **Nostimen odotusaika**: Kuinka kauan erä odottaa nosturia min-ajan jälkeen → pitkä odotus = nosturikapasiteetti rajoittaa
- **Nostimen käyttöaste**: Korkea käyttöaste (>85%) → nosturi on kapasiteetin rajoite
- **Takt-ajan varianssi**: Epävakaa takt → jokin resurssi (asema tai nostin) aiheuttaa pullonkaulan ajoittain

---

## 2. Nykyinen datakeräys

| Data | Lähde | Tila |
|---|---|---|
| Käsittelyaika per asema (actual vs min/max) | `lift_events` (DB, msg_type=2) | ✅ Kerätään |
| Tehtävän dispatch (nostin, lähtö, kohde, stage, erä) | `task_dispatched` (DB, msg_type=1) | ✅ Kerätään |
| Tehtävän vaihejakauma (matka, odotus, nosto, valutus, lasku) | `task_complete` (DB, msg_type=3) | ✅ Kerätään |
| Nostimen X-positio (reaaliaikainen) | OPC UA → `hoistXHistory` (in-memory ring buffer) | ✅ Kerätään |
| Scheduler-sykliajat (TSK/DEP) | OPC UA → `dashboard_api` cycle tracking | ✅ Kerätään |
| Erän aikataulu (laskettu) | `g_schedule` → `/api/schedules` | ✅ Kerätään |
| Erän aktivointiaika | — | ❌ Puuttuu |
| Erän kokonaisläpimenoaika (cycle time) | — | ❌ Puuttuu |
| Nostimen idle vs busy -aika | Laskettavissa `task_complete`:sta | ⚠️ Laskettavissa |

---

## 3. Tarvittava uusi datakeräys

### A. Uusi event: `BATCH_ACTIVATED` (msg_type = 4)

- **Tarkoitus**: Milloin DEP aktivoi erän (State: 0→1)
- **Payload**: `unit_id`, `batch_code`, `activation_time_s`
- **Käyttö**: Tahtiajan (takt time) laskenta — peräkkäisten aktivointien välinen aika
- **Toteutus**: PLC:n DEP_FB_Scheduler lähettää eventin kun erä aktivoidaan

### B. Uusi event: `BATCH_COMPLETED` (msg_type = 5)

- **Tarkoitus**: Milloin erä valmistuu (Stage = StepCount, timer loppuu → State: 1→2)
- **Payload**: `unit_id`, `batch_code`, `total_duration_s`, `stage_count`
- **Käyttö**: Erän kokonaisläpimenoaika (cycle time from load to unload)
- **Toteutus**: PLC:n STC_NoTreatmentStates lähettää eventin kun State → PROCESSED

### C. Nostimen käyttöastelaskenta (ei uutta eventtiä)

- Lasketaan `task_complete`-datasta: `SUM(total_s)` / kokonaisaika = käyttöaste per nostin
- Toteutetaan gateway-puolella SQL-kyselynä

---

## 4. Visualisointisuunnitelma — Dashboard-paneelit

### Paneeli: Line Throughput & Takt (uusi)

- **Kuvaaja**: Aikajana jossa:
  - Pylväät: erien aktivointivälit (takt time per erä)
  - Viiva: liukuva keskiarvo (esim. 5 erän ikkuna)
  - Vaakaviiva: tavoitetahti (jos tunnettu)
- **KPI-laatikot**: Valmiit erät (kpl), keskimääräinen takt (s), min/max takt
- **Datalähde**: `BATCH_ACTIVATED` events (msg_type=4)

### Paneeli: Station Margin Heatmap (nykyinen timing-chart parannettu)

Nykyinen bar-chart kertoo osavatko käsittelyajat min/max -ikkunaan. Parannukset:

- **Värikoodaus marginaalin mukaan** (margin = max − actual):
  - 🟢 Vihreä: margin > 20% max-ajasta (runsaasti pelivaraa)
  - 🟡 Keltainen: margin 5–20% (tiukka — nosturi ehtii juuri)
  - 🔴 Punainen: margin < 5% (kriittinen — pullonkaulariski)
  - ⚫ Musta: actual > max (schedulerin toimintavirhe — linja ei toimi oikein)
- **Pullonkaulan tunnistus**: Asema jolla marginaali on pienin = bottleneck-kandidaatti
- **Nostimen odotusaika**: Kuinka kauan erä oli asemalla min-ajan jälkeen ennen nostoa (= odotti nosturia)
- **Datalähde**: `lift_events` (jo olemassa)

### Paneeli: Transporter Utilization (uusi)

- **Donitsikaavio** per nostin: busy% vs idle%
- **Aikajakauma**: Pino-pylväskaavio `task_complete`-datasta:
  - Matka lift-asemalle | Odotus | Nosto | Valutus | Matka sink-asemalle | Lasku
  - Näyttää **missä nostimen aika kuluu**
- **Datalähde**: `task_complete` (jo olemassa)

### Paneeli: Batch Cycle Time Distribution (uusi)

- **Hajontakaavio**: Erän kokonaisaika (first station → last station) vs eränumero
- Näyttää trendin: paraneeko vai heikkeneekö suorituskyky ajon aikana
- Tavoiteaika viivana
- **Datalähde**: `BATCH_COMPLETED` events (msg_type=5)

---

## 5. Analysointi ja optimointisykli

```
 ┌──────────────────────────┐
 │ 1. Aja simulaatio        │
 │    (production queue)     │
 └─────────┬────────────────┘
           ▼
 ┌──────────────────────────┐
 │ 2. Tarkista Dashboard    │
 │    - Takt vakaa?          │
 │    - Marginaalit riittävät?│
 │    - Nosturi idle/busy?   │
 └─────────┬────────────────┘
           ▼
 ┌──────────────────────────┐
 │ 3. Tunnista pullonkaula  │
 │    a) Asema: pieni margin │
 │       → nosturi ehtii     │
 │         juuri → riski      │
 │    b) Nosturi: korkea     │
 │       käyttöaste, pitkät  │
 │       odotukset min:n     │
 │       jälkeen             │
 │       → kapasiteettiraja  │
 │    c) Takt epävakaa       │
 │       → DEP-aktivointi-   │
 │         logiikka          │
 └─────────┬────────────────┘
           ▼
 ┌──────────────────────────┐
 │ 4. Viritä parametreja    │
 │    - Käsittelyajat       │
 │    - Movement times      │
 │    - DEP margin/delay     │
 │    - Asemien järjestys    │
 └─────────┬────────────────┘
           ▼
 ┌──────────────────────────┐
 │ 5. Aja uudelleen →       │
 │    vertaa KPI-trendejä   │
 └──────────────────────────┘
```

---

## 6. Toteutusjärjestys

| Vaihe | Työ | Prioriteetti |
|---|---|---|
| **A** | Lisää `BATCH_ACTIVATED` event PLC:hen (DEP_FB_Scheduler) + DB view | ⬆️ Korkea |
| **B** | Lisää `BATCH_COMPLETED` event PLC:hen (STC_NoTreatmentStates) + DB view | ⬆️ Korkea |
| **C** | Dashboard: Takt time -kuvaaja + KPI-laatikot (`/api/dashboard/takt`) | ⬆️ Korkea |
| **D** | Dashboard: Nostimen käyttöaste (`/api/dashboard/transporter-utilization`) | ➡️ Keskitaso |
| **E** | Dashboard: Erän läpimenoaikajakauma (`/api/dashboard/batch-cycle-time`) | ➡️ Keskitaso |
| **F** | Timing-charten pullonkaulavärikoodaus (dashboard.html muutos) | ⬇️ Matala |

---

## 7. Viitteet

- **OEE (Overall Equipment Effectiveness)**: Availability × Performance × Quality — standardikehys tuotantolinjan tehokkuuden mittaamiseen (ISO 22400-2:2014)
- **Theory of Constraints (TOC)**: Pullonkaulan tunnistaminen ja optimointi kokonaissuorituskyvyn parantamiseksi
- **Takt Time**: Lean-tuotannon käsite — asiakaskysynnän määräämä tuotantotahti
- **Factory Physics**: Hopp & Spearman — matemaattinen kehys tuotantojärjestelmien analysointiin

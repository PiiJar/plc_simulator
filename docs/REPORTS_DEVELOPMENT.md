# Raporttikehitys — Reports Development Plan

## Yleiskatsaus

Simulaattorin tietokanta kerää kolmea PLC-eventtiä jatkuvasti:

| msg_type | View | Sisältö |
|----------|------|---------|
| 1 | `task_dispatched` | Tehtävän anto nostimelle: nostin, yksikkö, lähtö→kohde, vaihe, erä, calc/min/max aika |
| 2 | `lift_events` | Nosto asemalta: nostin, asema, erä, vaihe, toteutunut aika vs calc/min/max |
| 3 | `task_complete` | Nostoliikkeen vaihejakauma: siirtomatkat, odotus, nosto, valutus, lasku, kokonaisaika |

Lisäksi `sim_log`-taulu tallentaa tuotannon elinkaaritapahtumat (RESET, START, STOP).

Tapahtumat linkittyvät `task_id`:llä (dispatch → lift → complete) ja `batch_code`:lla (erän yksilöinti).

---

## Raportti 1: Batch Report (eräkatsaus)

### Tarkoitus

Esittää yhden erän koko elinkaari linjassa: mihin asemiin erä meni, kuinka kauan kussakin oli, miten toteutunut aika suhteutui sallittuun aikaikkunaan, ja mikä nostin suoritti kunkin siirron.

### Datalähde

Kaikki tarvittava data on jo tietokannassa — ei vaadi PLC-muutoksia.

**Päätaulu**: `lift_events` (msg_type=2) — yksi rivi per nosto, sisältää:
- `plc_ts` — nostoaika
- `batch_code` — erätunniste
- `transporter_id` — nostin
- `station` — asema josta nostettiin
- `stage` — käsittelyvaihe (ohjelmaviite)
- `actual_time_s` — todellinen upotusaika (s)
- `calc_time_s` — laskettu tavoiteaika (s)
- `min_time_s` — minimiupotusaika (s)
- `max_time_s` — maksimiupotusaika (s)

**Liitostiedot**: `task_complete` (msg_type=3) — nostoliikkeen yksityiskohdat:
- `travel_to_lift_s` — siirto nostoasemalle
- `wait_before_lift_s` — odotus nostolla (nostimen saapuminen)
- `lift_s` — nostoaika
- `dripping_s` — valutus
- `travel_to_sink_s` — siirto laskuasemalle
- `sink_s` — lasku
- `total_s` — liikkeen kokonaisaika

**Erättietojen haku**: `task_dispatched` (msg_type=1) — reitti-info:
- `lift_station` → `sink_station` — mistä mihin
- `xfer_total_s` — laskettu kokonaissiirtoaika

### SQL-kyselyt

**1. Erän vaiheet**
```sql
SELECT
  le.plc_ts,
  le.transporter_id,
  le.station,
  le.stage,
  le.actual_time_s,
  le.min_time_s,
  le.max_time_s,
  le.calc_time_s,
  tc.travel_to_lift_s,
  tc.wait_before_lift_s,
  tc.lift_s,
  tc.dripping_s,
  tc.travel_to_sink_s,
  tc.sink_s,
  tc.total_s
FROM lift_events le
LEFT JOIN task_complete tc ON le.task_id = tc.task_id
WHERE le.batch_code = $1
  AND le.stage > 0
ORDER BY le.plc_ts;
```

**2. Erälista (dropdown-valikko)**
```sql
SELECT DISTINCT batch_code,
  MIN(plc_ts) AS started_at,
  MAX(plc_ts) AS ended_at,
  COUNT(*)    AS stage_count
FROM lift_events
WHERE stage > 0
GROUP BY batch_code
ORDER BY started_at DESC;
```

**3. Yhteenveto**
```sql
SELECT
  COUNT(*)                          AS total_stages,
  MIN(plc_ts)                       AS first_lift,
  MAX(plc_ts)                       AS last_lift,
  EXTRACT(EPOCH FROM MAX(plc_ts) - MIN(plc_ts))::INT AS total_duration_s,
  SUM(actual_time_s)                AS total_treatment_s,
  COUNT(DISTINCT transporter_id)    AS transporters_used
FROM lift_events
WHERE batch_code = $1 AND stage > 0;
```

### API-endpointit (Gateway)

```
GET /api/batch-report/batches
  → [{ batch_code, started_at, ended_at, stage_count }]

GET /api/batch-report/:batchCode
  → {
      summary: { total_stages, first_lift, last_lift, total_duration_s, ... },
      stages: [{ plc_ts, transporter_id, station, stage,
                 actual_time_s, min_time_s, max_time_s, calc_time_s,
                 travel_to_lift_s, wait_before_lift_s, lift_s,
                 dripping_s, travel_to_sink_s, sink_s, total_s }]
    }
```

### UI-komponentti

**Sijainti**: `services/ui/src/components/panels/BatchReportPanel.jsx`

**Rakenne**:
1. **Erävalitsin** — dropdown viimeisimmät erät (batch_code + aloitusaika)
2. **Yhteenvetorivi** — erän kokonaiskesto, vaihelkm, käytetyt nostimet
3. **Vaihejärjestelmä** — taulukko:

| Aika | Nostin | Asema | Vaihe | Toteutunut (s) | Minimi (s) | Maksimi (s) | Marginaali | Siirtoaika (s) | Odotus (s) |
|------|--------|-------|-------|---------------|-----------|-----------|-----------|---------------|-----------|
| 12:01:30 | T1 | 102 | 1 | 180 | 120 | 300 | 120s (40%) | 8 | 2 |
| 12:05:15 | T1 | 103 | 2 | 250 | 200 | 360 | 110s (31%) | 6 | 0 |

4. **Marginaalivärit** — sama logiikka kuin LINE_PERFORMANCE_PLAN:
   - Vihreä: margin > 20% max-ajasta
   - Keltainen: margin 5–20%
   - Punainen: margin < 5%
   - Musta: actual > max (yliaikavirhe)

5. **Toolbar-integraatio** — "Batch Report" -nappi

### Toteutustyöt

| # | Työ | Tiedosto | Riippuvuus |
|---|------|---------|------------|
| 1 | API: erälista + eräraportti | `dashboard_api.js` | — |
| 2 | UI: BatchReportPanel | `panels/BatchReportPanel.jsx` | #1 |
| 3 | UI: Toolbar-nappi + App-integraatio | `Toolbar.jsx`, `App.jsx` | #2 |
| 4 | Build: gateway + ui | `docker compose build gateway ui` | #3 |

---

## Tuleva raportti 2: Production Run Report (tuotantoajon yhteenveto)

Yhden tuotantoajon (START→STOP) kokonaiskatsaus:
- Kaikki erät listana batch_code + aloitus/lopetus + kesto
- Throughput: erät/tunti
- Takt time -trendi
- Nostimen käyttöaste

**Datalähde**: `sim_log` (tuotantoajon rajat) + `lift_events` + `task_complete`
**Vaatii**: `BATCH_ACTIVATED` ja `BATCH_COMPLETED` eventit (ks. LINE_PERFORMANCE_PLAN.md vaiheet A-B)

---

## Tuleva raportti 3: Station Performance Report (asemakohtainen)

Yhden aseman suorituskykyraportti yli kaikkien erien:
- Actual vs min/max -jakauma (histogrammi)
- Marginaalitrendi ajan funktiona
- Odotusaika-analyysi (kuinka kauan erä odotti nosturia min-ajan jälkeen)
- Pullonkaulaindeksi

**Datalähde**: `lift_events` filtteröitynä station-arvolla

---

## Tuleva raportti 4: Transporter Performance Report (nostinkohtainen)

Yhden nostimen tehokkuusraportti:
- Käyttöaste (busy vs idle %)
- Aikavaihejakauma (matka, odotus, nosto, valutus, lasku)
- Tehtävämäärä aikayksikössä
- Tehokkuustrendi

**Datalähde**: `task_complete` filtteröitynä transporter_id:llä

---

## Toteutusjärjestys

| Prioriteetti | Raportti | PLC-muutos | DB-muutos | Uusi API | Uusi UI |
|---|---|---|---|---|---|
| **1 — NYT** | Batch Report | Ei | Ei | 2 endpointtiä | BatchReportPanel |
| **2** | Production Run Report | Kyllä (2 eventtiä) | 2 viewiä | 3 endpointtiä | ProductionRunPanel |
| **3** | Station Performance | Ei | Ei | 1 endpoint | StationReportPanel |
| **4** | Transporter Performance | Ei | Ei | 1 endpoint | TransporterReportPanel |

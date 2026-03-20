# UI Muutossuunnitelma v2 — Korjattu vaiheistus

**Päivämäärä:** 19.3.2026 (päivitetty 20.3.2026)  
**Edellinen versio:** UI_MUUTOSSUUNNITELMA.md (18.3.2026)  
**Tavoite:** Sama kuin v1 — säilyttää kaikki nykyiset ominaisuudet, parantaa ylläpidettävyyttä ja suorituskykyä  
**Miksi v2:** Edellinen suunnitelma toteutettiin kaikki 9 vaihetta kerralla ilman välitestejä. Lopputulos: rikkinäinen UI. Tämä versio korjaa prosessin.

**Tilanne 20.3.2026:** Vaiheet Esityö–V3 toteutettu ja testattu. V3.5: Calibration poistettu kokonaan (UI, gateway, PLC). Seuraava: V4 (CSS-erottelu).

---

## 0. Nykytilan kuvaus

### Legacy (toimiva, lähde — käytetty V0:ssa)
```
OpenPLC_Simulator/PLC Simulator/visualization/src/
├── App.jsx                           3 126 riviä (monoliitti, TOIMII)
├── main.jsx                              10 riviä (suora <App />)
├── colorPalette.js                      605 riviä
├── hooks/useColorPalette.js             164 riviä
├── components/CalibrationPanel.jsx      399 riviä  (POISTETTU V3.5:ssä)
├── components/index.js                   19 riviä
└── components/StationLayout/            (7 tiedostoa, ~1 600 riviä, TOIMIVAT)
```
**Yhteensä:** ~6 100 riviä, 15 tiedostoa

### Uusi repo — nykytila V3.5 jälkeen (20.3.2026, TOIMII ✅)
```
plc_simulator/services/ui/src/
├── App.jsx                         1 450 riviä (refaktoroitu, TOIMII)
├── main.jsx                            10 riviä (suora <App />)
├── api/client.js                       24 riviä (V1: fetch-wrapper)
├── colorPalette.js                    605 riviä
├── hooks/useColorPalette.js           164 riviä
├── components/Toolbar.jsx             222 riviä (V2: yhtenäinen toolbar)
├── components/index.js                 19 riviä
├── components/panels/
│   ├── ConfigPanel.jsx                301 riviä (V3e)
│   ├── CustomerPanel.jsx              347 riviä (V3a)
│   ├── ProductionPanel.jsx            167 riviä (V3b)
│   ├── TasksPanel.jsx                 277 riviä (V3d)
│   └── UnitsPanel.jsx                 136 riviä (V3c)
└── components/StationLayout/          (7 tiedostoa, ~1 600 riviä)
```
**Yhteensä V3.5 jälkeen:** ~5 300 riviä, 20 tiedostoa  
**App.jsx:** 3 126 → 1 450 riviä (−54 %)  
**V3.5:** CalibrationPanel.jsx poistettu (−399 riviä), Calibrate-nappi poistettu Toolbarista

### Uusi repo — backend (TOIMII, ei kosketa)
- `services/gateway/` — OPC UA adapter, REST API ✅
- `services/codesys/` — Dockerfile + entrypoint.sh + PLC RUN/STOP ✅
- `services/db/` — PostgreSQL events ✅

---

## 1. Perusperiaatteet (eivät muutu v1:stä)

1. **Yksi vaihe kerrallaan** — ei seuraavaan ennen kuin edellinen on hyväksytty
2. **Jokaisen vaiheen jälkeen toimiva UI** — ei "korjataan myöhemmin"
3. **Toiminnallisuus aina identtinen** legacy-version kanssa
4. **Git commit jokaisen vaiheen jälkeen** — palautuspiste

---

## 2. Esityö: Git-seuranta kuntoon ✅ VALMIS

**Commit:** `64d8425` — checkpoint: broken UI state + PLC RUN/STOP backend + entrypoint.sh

**Tehtävät:**
1. ✅ Lisätty kaikki `services/` gitin seurantaan
2. ✅ `.gitignore` luotu (node_modules, dist, __pycache__)
3. ✅ Checkpoint-commit tehty
4. ✅ Jokainen vaihe = yksi commit

---

## 3. Vaihe 0 — Palautetaan toimiva UI ✅ VALMIS

**Commit:** `92903af` — V0: restore working legacy UI to new repo

**Tehtävät:**
1. ✅ Kopioitu legacy `src/` → `services/ui/src/` (15 tiedostoa, App.jsx 3126 riviä)
2. ✅ `main.jsx` palautettu yksinkertaiseksi (ei context-wrappejä)
3. ✅ `package.json`, `vite.config.mjs` tarkistettu (identtiset)
4. ✅ Build & deploy onnistui

**Hyväksymistesti:**
- [x] Sivu aukeaa selaimessa
- [x] Customer-paneeli aukeaa ja valinta toimii
- [x] Config latautuu
- [x] Asemat näkyvät layoutissa
- [x] PLC status näkyy
- [x] Start/Reset toimii
- [x] Transporterit liikkuvat
- [x] Batch/Unit ja Tasks-paneelit näyttävät dataa

---

## 4. Vaihe 1 — API-kerros (api/client.js) ✅ VALMIS

**Commit:** `976f048` — V1: centralized API layer (fetch→api.get/post/put/delete)

**Tehtävät:**
1. ✅ Luotu `src/api/client.js` (24 riviä: request-wrapper, JSON-serialisointi)
2. ✅ Korvattu 53 fetch()-kutsua → `api.get/post/put/delete`
3. ✅ Ei rakennemuutoksia — vain fetch→api

**Huomiot:**
- Automaattinen Node.js-skripti korvasi 51/53 kutsua, 2 korjattiin käsin
- Löydettiin ja korjattiin swap-bugi (manual-tasks GET oli vahingossa api.post, sim/start POST oli api.get)

**Hyväksymistesti:**
- [x] Kaikki V0:n testit läpi
- [x] Network-välilehti: samat kutsut
- [x] Ei console-erroreita

---

## 5. Vaihe 2 — Toolbar omaksi komponentiksi ✅ VALMIS

**Commit:** `b280dd7` — V2: extract Toolbar component (App.jsx 3068→2573 lines)

**Tehtävät:**
1. ✅ Luotu `src/components/Toolbar.jsx` (222 riviä)
2. ✅ Siirretty toolbar-JSX ja handler-kutsut
3. ✅ Prop drilling App.jsx:stä
4. ✅ Poistettu duplikaatti guard-render → yksi `<Toolbar isConfigLoaded={...}>` (disabled-tila)
5. ✅ CODESYS-logo suurennettu 36px → 56px (toolbar-nappien korkuinen)

**Hyväksymistesti:**
- [x] Kaikki V0:n testit läpi
- [x] Toolbar identtinen, napit toimivat
- [x] PLC status, Start/Reset, kello ja nopeus toimivat

---

## 6. Vaihe 3 — Paneelit omiksi komponenteiksi ✅ VALMIS

**Commit:** `a6ac83b` — V3: extract panel components (Config, Customer, Production, Units, Tasks) — App.jsx 3068→1450 lines

**Tehtävät (kaikki toteutettu):**

### 3a: CustomerPanel ✅
- 347 riviä, customer/plant CRUD, guard + main käyttävät samaa komponenttia
- Guard: yksinkertaistettu 22 riviä → sama komponentti kuin main

### 3b: ProductionPanel ✅
- 167 riviä, tuotannon setup, batch-rivit, ohjelman valinta

### 3c: UnitsPanel ✅
- 136 riviä, unit-taulukko PLC:ltä, yksittäisen unitin muokkaus

### 3d: TasksPanel ✅ 
- 277 riviä, manuaaliset tehtävät, suorituksessa olevat, tehtävälistat nostimittain, jakamattomat

### 3e: ConfigPanel ✅
- 301 riviä, layout-konfiguraatio (grid, stations, transporters, margins)
- Huom: käyttää `import { api }` (named export), ei default

**Hyväksymistesti:**
- [x] Kaikki V0:n testit läpi
- [x] App.jsx = 1 450 riviä (< 1500 tavoite ✅)
- [x] Jokainen paneeli avautuu ja sulkeutuu
- [x] Build onnistuu ilman erroreita

---

## 7. Vaihe 3.5 — Calibroinnin poisto ✅ VALMIS

**Syy:** Siirtoajat luetaan nyt suoraan `movement_times.json`-tiedostosta RESET-vaiheessa. Erillistä calibrointisekvenssiä ei tarvita — kaikki siirtoaikadata on valmiiksi laskettu tiedostossa.

**Poistettu (UI):**
- `CalibrationPanel.jsx` — koko tiedosto (399 riviä)
- `App.jsx` — import, `showCalibration` state, CalibrationPanel-renderointi
- `Toolbar.jsx` — Calibrate-nappi, `showCalibration`/`setShowCalibration` props

**Poistettu (Gateway):**
- 7 `/api/calibrate/*` endpointia (status, plan, start, calculate, abort, save, load)
- `loadCalibrationToPLC()` funktio
- `calibrationState` muuttuja ja poll-loop päivitys
- `opcua_adapter.js`: `writeCalibrationPlan`, `writeCalibrationControl`, `writeCalibrationParams`, `triggerMoveComputation`, calibration-parsinta `readState`:stä
- `opcua_nodes.js`: `calibration()` read-funktio, `calWrite()` write-funktio, `cal_active` META:sta, calibration `buildReadList`-silmukka
- `plc_adapter.js`: 4 abstraktia calibration-metodia

**Poistettu (PLC/CODESYS):**
- `STC_FB_Calibrate.st` — koko tiedosto (teaching-sekvenssi)
- `STC_FB_CalcMoveTimes.st` — koko tiedosto (g_cal → g_move lasku)
- `UDT_JC_CalibrationType.st` — koko tiedosto (calibration UDT)
- `GVL_JC_Scheduler.st`: `g_cal[]`, `g_cal_active`, cmd 8/12 dokumentaatio
- `plc_prg.st`: g_cal VAR_EXTERNAL, calibrate/calc_move FB-instanssit, cmd 8/12 handlerit, calibrate() kutsu
- `STC_FB_MainScheduler.st`: `g_cal_active` guard (esti scheduleria calibroinnin aikana)

**Korvaava mekanismi:**
- RESET kirjoittaa `movement_times.json` → `g_move[]` suoraan (`writeMovementTimes`)
- Ei välivaihetta g_cal:in kautta — siirtoajat menevät suoraan LiftTime/SinkTime/Travel-taulukoihin

---

## 8. Vaihe 4 — CSS erottelu ⬅️ SEURAAVA

**Tavoite:** Inline-tyylit → CSS-luokat toolbarissa ja paneeleissa.

**Tehtävät:**
1. Luo `styles/variables.css`, `styles/layout.css`, `styles/components.css`
2. Korvaa toolbar-tyylien inline `style={{}}` → className
3. Korvaa paneelien toistuvat tyylit → className
4. Dynaamiset tyylit (ehdolliset värit ym.) saa jäädä inlineksi

**Hyväksymistesti:**
- [ ] UI näyttää visuaalisesti identtiseltä
- [ ] Hover, disabled, active tilat toimivat
- [ ] Ei console-erroreita

**Commit:** `"V4: CSS extraction for toolbar and panels"`

---

## 9. Vaihe 5 — StationLayout lookup-optimointi

**Tavoite:** Korvaa renderin sisäiset `find()`-haut `useMemo`-lookupeilla.

**Tehtävät:**
1. Lisää `useMemo`-lookup-mapit StationLayout/index.jsx:ään
2. Käytä suoria hakuja renderissä
3. **Ei pilkota StationLayoutia** — vain sisäinen optimointi

**Hyväksymistesti:**
- [ ] Asemat näkyvät oikein
- [ ] Batchit oikeilla asemilla
- [ ] Transporterit näyttävät oikean datan
- [ ] Debug-paneeli näyttää oikeat arvot

**Commit:** `"V5: StationLayout lookup optimization"`

---

## 10. Vaihe 6 — Polling-siivous

**Tavoite:** Yhdistä hajautettu pollauslogiikka ilman muutoksia päivitysrytmiin.

**Tehtävät:**
1. Yhdistä core-pollaus (PLC status, batches, tasks) yhteen 2s intervalliin
2. Säilytä nopea transporter-states erillisenä
3. Käytä `Promise.allSettled` — osittainen virhe ei kaada koko pollausta
4. Ehdolliset paneeli-pollaukset säilyvät

**Hyväksymistesti:**
- [ ] PLC status päivittyy
- [ ] Transporterit liikkuvat sulavasti
- [ ] Batch/unit data päivittyy
- [ ] Paneelin avaus päivittää datansa
- [ ] Ei stale-data tilanteita

**Commit:** `"V6: polling consolidation"`

---

## 11. Vaihe 7 — Context-kerros (valinnainen)

**HUOM:** Tämä vaihe tehdään **VASTA** kun V0–V6 toimivat moitteettomasti. Jos prop drilling toimii hyvin, tätä ei tarvitse tehdä lainkaan.

**Tavoite:** Siirtää harvoin muuttuva tila (customer, plant, config) kontekstiin.

**Tehtävät:**
1. Luo `PlantContext` — vain harvoin muuttuva data
2. Luo `UiPanelsContext` — vain panel-näkyvyys booleanit
3. **EI** laita nopeaa runtime-dataa kontekstiin
4. Päivitä main.jsx wrappaamaan providerit
5. Päivitä App.jsx ja paneelit käyttämään konteksteja

**Hyväksymistesti:**
- [ ] Kaikki V0:n testit edelleen läpi
- [ ] React DevTools: context-päivitykset eivät aiheuta laajoja re-rendereitä
- [ ] Ei console-erroreita

**Commit:** `"V7: optional context layer"`

---

## 12. Vaihe 8 — React.memo + useMemo (valinnainen)

**Tehtävät:**
1. `React.memo` StationLayout-subkomponenteille
2. `useCallback` handlereille jotka välitetään propsina
3. Profiloi ennen/jälkeen React DevToolsilla

**Hyväksymistesti:**
- [ ] Profilerissa renderit vähenevät
- [ ] Ei stale-props bugeja
- [ ] Kaikki toimii

**Commit:** `"V8: memoization"`

---

## 13. Vaihe 9 — rAF-polun yksinkertaistus (valinnainen)

**Tehtävät:**
1. Kapseloi rAF-loop omaan hookiin
2. Selkeytä runtime-datan omistajuus

**Hyväksymistesti:**
- [ ] Transporter-liike sujuva
- [ ] Ei turhia re-rendereitä

**Commit:** `"V9: rAF simplification"`

---

## 14. Ehdoton sääntö

```
JOKAISEN VAIHEEN JÄLKEEN:
1. Build: docker compose build ui
2. Deploy: docker compose up -d --force-recreate ui
3. Testaa KAIKKI hyväksymistestit selaimessa
4. Vasta kun kaikki OK → git add + commit
5. Jos jokin testi failaa → korjaa TAI revert ja yritä uudelleen
6. EI EDETÄ SEURAAVAAN VAIHEESEEN ENNEN HYVÄKSYNTÄÄ
```

---

## 15. Yhteenveto vaiheista

| Vaihe | Sisältö | Tila | Commit | App.jsx |
|-------|---------|------|--------|--------|
| Esityö | Git-seuranta kuntoon | ✅ VALMIS | `64d8425` | — |
| V0 | Palauta toimiva legacy UI | ✅ VALMIS | `92903af` | 3 126 |
| V1 | API-kerros (fetch→api.get) | ✅ VALMIS | `976f048` | 3 126 |
| V2 | Toolbar-erottelu | ✅ VALMIS | `b280dd7` | 2 573 |
| V3 | Paneelit omiksi (prop drilling) | ✅ VALMIS | `a6ac83b` | 1 450 |
| V3.5 | Calibroinnin poisto (UI+GW+PLC) | ✅ VALMIS | — | 1 450 |
| V4 | CSS-erottelu | ⬅️ SEURAAVA | — | — |
| V5 | StationLayout lookup-optimointi | ⬜ | — | — |
| V6 | Polling-siivous | ⬜ | — | — |
| V7 | Context-kerros | Valinnainen | — | — |
| V8 | Memoointi | Valinnainen | — | — |
| V9 | rAF-yksinkertaistus | Valinnainen | — | — |

**V0–V3 toteutettu:** App.jsx 3 126 → 1 450 riviä (−54 %).  
**V3.5:** Calibrointi poistettu kokonaan — UI −399 riviä, gateway ~250 riviä, PLC 3 tiedostoa.  
**V4–V6 jälkeen App.jsx tavoite ~800–1000 riviä.**  
**V7–V9 tehdään vain jos hyöty on mitattavissa.**

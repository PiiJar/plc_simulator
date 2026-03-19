# UI Muutossuunnitelma v2 — Korjattu vaiheistus

**Päivämäärä:** 19.3.2026  
**Edellinen versio:** UI_MUUTOSSUUNNITELMA.md (18.3.2026)  
**Tavoite:** Sama kuin v1 — säilyttää kaikki nykyiset ominaisuudet, parantaa ylläpidettävyyttä ja suorituskykyä  
**Miksi v2:** Edellinen suunnitelma toteutettiin kaikki 9 vaihetta kerralla ilman välitestejä. Lopputulos: rikkinäinen UI. Tämä versio korjaa prosessin.

---

## 0. Nykytilan kuvaus (19.3.2026)

### Legacy (toimiva, lähde)
```
OpenPLC_Simulator/PLC Simulator/visualization/src/
├── App.jsx                           3 126 riviä (monoliitti, TOIMII)
├── main.jsx                              10 riviä (suora <App />)
├── colorPalette.js                      605 riviä
├── hooks/useColorPalette.js             164 riviä
├── components/CalibrationPanel.jsx      399 riviä
├── components/index.js                   19 riviä
└── components/StationLayout/            (7 tiedostoa, ~1 600 riviä, TOIMIVAT)
```
**Yhteensä:** ~6 100 riviä, 15 tiedostoa

### Uusi repo (rikki, refaktoroitu puolitiehen)
```
plc_simulator/services/ui/src/
├── App.jsx                         1 243 riviä (puuttuvia viittauksia)
├── main.jsx                            17 riviä (PlantProvider + UiPanelsProvider wrap)
├── api/client.js                       40 riviä (uusi)
├── context/PlantContext.jsx             38 riviä (uusi)
├── context/UiPanelsContext.jsx          27 riviä (uusi)
├── utils/formatTime.js                   8 riviä (uusi)
├── styles/*.css                        112 riviä (uusi)
├── components/Toolbar/              6 tiedostoa, ~332 riviä (uusi)
├── components/panels/               5 tiedostoa, ~1 580 riviä (uusi)
└── components/StationLayout/        (7 tiedostoa, ~1 600 riviä, pieniä muutoksia)
```
**Ongelmat:**
- `App.jsx` viittaa `usePlant()`, `useUiPanels()` — kontekstit luotu mutta kaikki tilat eivät siirtyneet
- Paneeleihin irrotettu logiikkaa mutta propsit eivät täsmää
- Ei yhtään välitestausta tehty
- Git seuraa vain 2 tiedostoa (`infra/`), palautuspistettä ei ole

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

## 2. Esityö: Git-seuranta kuntoon (ENNEN MITÄÄN MUUTA)

**Miksi:** Ilman gitiä ei ole palautuspistettä. Edellinen epäonnistuminen johtui osittain tästä.

**Tehtävät:**
1. Lisää kaikki `services/` gitin seurantaan
2. Tee `.gitignore` joka jättää pois `node_modules/`, `dist/`, `__pycache__/`
3. Commit: `"checkpoint: current state before UI restoration"`
4. Tämän jälkeen jokainen vaihe = yksi commit

---

## 3. Vaihe 0 — Palautetaan toimiva UI

**Tavoite:** Uudessa repossa pyörii täsmälleen sama UI kuin legacyssä. Kaikki refaktoroidut tiedostot poistetaan.

**Tehtävät:**
1. Kopioi legacy `src/` → new repo `services/ui/src/` (korvaa koko kansio)
2. Palauta `main.jsx` yksinkertaiseksi (ei context-wrappejä)
3. Varmista `package.json`, `vite.config.mjs`, `public/` ovat kunnossa
4. Build & deploy: `docker compose build ui && docker compose up -d --force-recreate ui`

**Hyväksymistesti:**
- [ ] Sivu aukeaa selaimessa (`http://172.19.31.7:5173`)
- [ ] Customer-paneeli aukeaa ja customer/plant valinta toimii
- [ ] Config latautuu valinnan jälkeen
- [ ] Asemat näkyvät layoutissa
- [ ] PLC status näkyy (vihreä/punainen pallo)
- [ ] Start-nappi käynnistää tuotannon
- [ ] Reset toimii
- [ ] Transporterit liikkuvat
- [ ] Batch/Unit paneeli näyttää dataa
- [ ] Tasks-paneeli näyttää dataa
- [ ] Calibration-paneeli toimii
- [ ] Debug-paneeli aukeaa klikkaamalla transporteria

**Commit:** `"V0: restore working legacy UI to new repo"`

---

## 4. Vaihe 1 — API-kerros (api/client.js)

**Tavoite:** Keskitetty fetch-wrapper, App.jsx edelleen monoliitti.

**Tehtävät:**
1. Luo `src/api/client.js` (request-wrapper, error handling)
2. Korvaa App.jsx:n `fetch()`-kutsut `api.get()` / `api.post()` -kutsuilla
3. **Ei muuta mitään rakennetta** — vain fetch→api.get/post

**Hyväksymistesti:**
- [ ] Kaikki V0:n testit edelleen läpi
- [ ] Selaimen Network-välilehti: samat kutsut, samat vastaukset
- [ ] Ei console-erroreita

**Commit:** `"V1: centralized API layer, no structural changes"`

---

## 5. Vaihe 2 — Toolbar omaksi komponentiksi

**Tavoite:** Erota toolbar App.jsx:stä omaksi tiedostoksi. App.jsx pienenee ~300 riviä.

**Tehtävät:**
1. Luo `src/components/Toolbar.jsx` (yksi tiedosto, ei pilkota vielä)
2. Siirrä toolbar-JSX ja sen suorat handler-kutsut
3. Välitä kaikki propsina App.jsx:stä (prop drilling OK tässä vaiheessa)
4. Poista duplikaatti guard-render (configia odottava näkymä vs päänäkymä → yksi toolbar disabled-tilalla)

**Hyväksymistesti:**
- [ ] Kaikki V0:n testit edelleen läpi
- [ ] Toolbar näyttää identtiseltä
- [ ] Napit toimivat: Customer, Config, Production, Batches, Tasks
- [ ] PLC status toimii
- [ ] Start/Reset toimii
- [ ] Kello ja nopeus toimivat

**Commit:** `"V2: extract Toolbar component"`

---

## 6. Vaihe 3 — Paneelit omiksi komponenteiksi

**Tavoite:** Erota 5 paneelia App.jsx:stä. App.jsx pienenee ~1500 riviä.

**Tehtävät (yksi kerrallaan, testi välissä):**

### 3a: CustomerPanel
1. Erota customer-hallinta JSX + handlerit
2. Props App.jsx:stä
3. **Testi:** customer-paneeli aukeaa, customer/plant luonti toimii

### 3b: ProductionPanel  
1. Erota tuotannon luonti JSX + handlerit
2. **Testi:** production create toimii, batch-rivien lisäys/poisto

### 3c: UnitsPanel
1. Erota batch/unit-taulukko
2. **Testi:** unit edit/save, batch location näkyy

### 3d: TasksPanel
1. Erota tehtäväjono + manual tasks
2. **Testi:** tasks näkyvät, manual task add/cancel

### 3e: ConfigPanel
1. Erota config-lomake
2. **Testi:** config-paneeli aukeaa, tallennus toimii

**Hyväksymistesti (kaikki 3a–3e jälkeen):**
- [ ] Kaikki V0:n testit edelleen läpi
- [ ] App.jsx < 1500 riviä
- [ ] Jokainen paneeli avautuu ja sulkeutuu
- [ ] Ei console-erroreita

**Commit:** `"V3: extract panel components (prop drilling)"`

---

## 7. Vaihe 4 — CSS erottelu

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

## 8. Vaihe 5 — StationLayout lookup-optimointi

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

## 9. Vaihe 6 — Polling-siivous

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

## 10. Vaihe 7 — Context-kerros (valinnainen)

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

## 11. Vaihe 8 — React.memo + useMemo (valinnainen)

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

## 12. Vaihe 9 — rAF-polun yksinkertaistus (valinnainen)

**Tehtävät:**
1. Kapseloi rAF-loop omaan hookiin
2. Selkeytä runtime-datan omistajuus

**Hyväksymistesti:**
- [ ] Transporter-liike sujuva
- [ ] Ei turhia re-rendereitä

**Commit:** `"V9: rAF simplification"`

---

## 13. Ehdoton sääntö

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

## 14. Yhteenveto vaiheista

| Vaihe | Sisältö | Pakollinen | Riski |
|-------|---------|------------|-------|
| Esityö | Git-seuranta kuntoon | ✅ | Ei riskiä |
| V0 | Palauta toimiva legacy UI | ✅ | Ei riskiä |
| V1 | API-kerros (fetch→api.get) | ✅ | Matala |
| V2 | Toolbar-erottelu | ✅ | Matala |
| V3 | Paneelit omiksi (prop drilling) | ✅ | Keskitaso |
| V4 | CSS-erottelu | ✅ | Matala |
| V5 | StationLayout lookup-optimointi | ✅ | Matala |
| V6 | Polling-siivous | ✅ | Keskitaso |
| V7 | Context-kerros | Valinnainen | Keskitaso |
| V8 | Memoointi | Valinnainen | Matala |
| V9 | rAF-yksinkertaistus | Valinnainen | Keskitaso |

**V0–V6 jälkeen App.jsx on ~800–1000 riviä, rakenne selkeä, kaikki toimii.**  
**V7–V9 tehdään vain jos hyöty on mitattavissa.**

# UI Muutossuunnitelma — Suorituskyky & Ylläpidettävyys

**Päivämäärä:** 18.3.2026  
**Tavoite:** Säilyttää kaikki nykyiset ominaisuudet, parantaa suorituskykyä ja ylläpidettävyyttä  
**Lähtötilanne:** Monoliittinen App.jsx (3 127 riviä), 69 useState, 19 useEffect, 294 inline-tyyliä, 7 samanaikaista polling-intervallia

---

## 1. Nykytilan yhteenveto

| Mittari | Arvo |
|---------|------|
| App.jsx rivimäärä | 3 127 |
| useState-hookit | 69 |
| useEffect-hookit | 19 |
| fetch()-kutsut | 53 |
| Inline-tyylit (`style={{`) | 294 |
| Samanaikaiset setInterval | 7 |
| requestAnimationFrame | 2 |
| CSS-tiedostot | 0 |
| Testit | 0 |
| TypeScript | 0 |
| Komponenttitiedostoja (StationLayout ym.) | 9 kpl, 2 300 riviä |
| Yhteensä | ~5 430 koodiriviä |

### Kriittisimmät ongelmat

1. **Ylläpidettävyys:** Kaikki liiketoimintalogiikka, tila, API-kutsut ja suuri osa UI:sta ovat yhdessä komponentissa. Muutos yhteen ominaisuuteen vaatii käytännössä koko [services/ui/src/App.jsx](services/ui/src/App.jsx#L21-L3127) -tiedoston kontekstin ymmärtämistä.
2. **Suorituskyky:** Pollaus, tiheästi päivittyvä runtime-data ja iso render-puu ovat samassa omistajassa. Tämä lisää turhia uudelleenrenderöintejä, vaikka tarkka vaikutus pitää mitata ennen optimointia.
3. **Rakennevelka:** `fetch()`-kutsut, toolbar-UI, paneelit ja guard-render ovat osin duplikoituja ja hajallaan. Esimerkiksi configia odottava render-haara alkaa kohdasta [services/ui/src/App.jsx](services/ui/src/App.jsx#L1217-L1462), ja varsinainen päätoolbar alkaa vasta kohdasta [services/ui/src/App.jsx](services/ui/src/App.jsx#L1464-L1831).
4. **Layout-lookupit:** `StationLayout` tekee useita `find()`-hakuja renderin sisällä [services/ui/src/components/StationLayout/index.jsx](services/ui/src/components/StationLayout/index.jsx#L160-L167), [services/ui/src/components/StationLayout/index.jsx](services/ui/src/components/StationLayout/index.jsx#L192-L201) ja [services/ui/src/components/StationLayout/index.jsx](services/ui/src/components/StationLayout/index.jsx#L229-L238). Tämä ei yksinään ole kriittinen ongelma, mutta on selkeä optimointikohde.

---

## 2. Arkkitehtuurin tavoitetila

```
src/
├── App.jsx                    # Vain layout-runko + routing (< 100 riviä)
├── main.jsx                   # React root (nykyinen, ei muutoksia)
├── styles/
│   ├── variables.css           # Design tokens: värit, fontit, tilat
│   ├── layout.css              # Toolbar, paneelilayout
│   └── components.css          # Komponenttikohtaiset luokat
├── context/
│   ├── PlantContext.jsx        # customer, plant, config, stations, tanks, transporters
│   ├── UiPanelsContext.jsx     # panelien näkyvyys ja debug-tila
│   └── SimulationContext.jsx   # rajattu runtime/sim-state, vain jos tarpeellinen
├── hooks/
│   ├── useColorPalette.js      # Nykyinen (ei muutoksia)
│   ├── usePolling.js           # Geneerinen polling-hook (intervalli + cleanup)
│   ├── useApi.js               # fetch-wrapperi: loading/error/data
│   ├── usePlcStatus.js         # PLC-tilan polling
│   └── useTransporterRuntime.js # nopean runtime-datan kapselointi
├── api/
│   └── client.js               # Keskitetty API-kerros: kaikki endpointit
├── components/
│   ├── Toolbar/
│   │   ├── Toolbar.jsx         # Yläpalkki-layout
│   │   ├── PlcStatusButton.jsx # PLC start/stop + status dot
│   │   ├── PlantBadge.jsx      # Customer/Plant näyttö
│   │   ├── ToolbarButtons.jsx  # Paneelinapit
│   │   └── SimControls.jsx     # START/RESET + kello
│   ├── panels/
│   │   ├── CustomerPanel.jsx   # Asiakashallinta (DraggablePanel)
│   │   ├── ProductionPanel.jsx # Tuotannon luonti
│   │   ├── UnitsPanel.jsx      # Batch/Unit-taulukko + muokkaus
│   │   ├── TasksPanel.jsx      # Tehtäväjono ja manuaaliset tehtävät
│   │   └── ConfigPanel.jsx     # Layout-konfiguraatio
│   ├── CalibrationPanel.jsx    # Nykyinen (jo erillinen)
│   └── StationLayout/          # Nykyinen (jo purettu osiin)
│       ├── index.jsx
│       ├── hooks/
│       ├── helpers/
│       └── subcomponents/
└── utils/
    └── formatTime.js           # Yleiskäyttöiset apufunktiot
```

---

## 3. Muutosvaiheet

### Vaihe 1: API-kerros ja mittausbaseline

**Prioriteetti:** Korkea  
**Vaikutus:** Ylläpidettävyys + turvallinen refaktorointi  
**Riski:** Matala  

**Ongelma:** 53 `fetch()`-kutsua ovat hajallaan App.jsx:ssä. Lisäksi nykyisestä toteutuksesta ei ole mitattua baselinea, jolloin optimointien hyöty jää oletusten varaan.

**Ratkaisu:**
1. Luo `src/api/client.js` ja siirrä sinne API-kutsujen peruslogiikka.
2. Yhtenäistä virheenkäsittely, headerit ja JSON-parsinta.
3. Lisää kevyt mittausbaseline ennen suuria rakenteellisia muutoksia:
   - React DevTools Profiler -otanta idle-tilassa
   - render-laskenta tärkeimmille komponenteille (`App`, `StationLayout`, toolbar, aktiiviset paneelit)
   - verkkoaktiivisuuden kirjaus 2 sekunnin sykleissä

**Käytännössä:**
```js
// api/client.js
const BASE = '/api';

async function request(path, options = {}) {
  const res = await fetch(`${BASE}${path}`, {
    headers: { 'Content-Type': 'application/json', ...options.headers },
    ...options
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error || `HTTP ${res.status}`);
  }

  return res.json();
}
```

**Voitot:**
- Refaktoroinnin turvallisuus paranee
- Yksi paikka API-sopimuksille
- Helpompi arvioida missä optimoinnit oikeasti vaikuttavat

---

### Vaihe 2: Guard-renderin poisto ja toolbarin yhtenäistäminen

**Prioriteetti:** Korkea  
**Vaikutus:** Ylläpidettävyys  
**Riski:** Matala  

**Ongelma:** Configia odottava näkymä ja varsinainen päätoolbar ovat rakenteeltaan lähes samat [services/ui/src/App.jsx](services/ui/src/App.jsx#L1217-L1462) ja [services/ui/src/App.jsx](services/ui/src/App.jsx#L1464-L1831). Tämä kasvattaa regressioriskiä.

**Ratkaisu:**
1. Erota yhteinen `Toolbar`-komponentti.
2. Tee nappeihin `disabled`/`isConfigured`-tila sen sijaan, että ylläpidetään kahta erillistä JSX-haaraa.
3. Pidä layout-runko samana riippumatta siitä, onko config ladattu.

**Voitot:**
- Poistaa noin 500+ rivin duplikaattilogiikan
- Tekee seuraavista vaiheista merkittävästi turvallisempia

---

### Vaihe 3: Komponenttien erottelu (App.jsx → moduulit)

**Prioriteetti:** Korkea  
**Vaikutus:** Ylläpidettävyys (kriittinen)  
**Riski:** Keskitaso  

**Ongelma:** App.jsx sisältää:
- Rivit 1–119: 69 useState-deklaraatiota
- Rivit 120–503: 19 useEffect-hookia + data loading
- Rivit 504–910: handler-funktioita (CRUD, navigation, formatting)
- Rivit 1217–1831: toolbar ja näkymärunko
- Rivit 1900–3127: useita isoja paneeleita

**Erottelukartta:**

| Uusi komponentti | Alkuperä (App.jsx rivit) | Arvio (rivit) |
|-----------------|--------------------------|---------------|
| `Toolbar.jsx` | 1464–1831 | ~150 |
| `PlcStatusButton.jsx` | 1480–1540 | ~80 |
| `SimControls.jsx` | 1778–1831 | ~80 |
| `ConfigPanel.jsx` | 1900–2195 | ~300 |
| `CustomerPanel.jsx` | 2198–2588 | ~400 |
| `ProductionPanel.jsx` | 2590–2810 | ~250 |
| `UnitsPanel.jsx` | 2812–2960 | ~180 |
| `TasksPanel.jsx` | 2962–3120 | ~200 |
| `DebugPanel.jsx` | 1838–1897 | ~60 |

**Jälkeen App.jsx:**
```jsx
export default function App() {
  return (
    <div className="app">
      <Toolbar />
      <main className="app__content">
        <StationLayout />
      </main>
      <PanelManager />
    </div>
  );
}
```

**Tärkeä tarkennus:** tämä vaihe on nykytilaan nähden merkittävin ylläpidettävyysparannus. Se kannattaa tehdä ennen laajaa context-uudistusta, koska paneelirajat ovat jo nähtävissä nykyisessä JSX-rakenteessa.

---

### Vaihe 4: CSS-erottelu (inline → luokat)

**Prioriteetti:** Korkea  
**Vaikutus:** Ylläpidettävyys + pieni/kohtalainen suorituskykyhyöty  
**Riski:** Matala  

**Ongelma:** 294 inline `style={{...}}` -objektia vaikeuttavat muutoksia ja aiheuttavat ylimääräistä objektien luontia renderöinnissä. Suurin hyöty on kuitenkin tyylien keskittäminen, ei yksin suorituskyky.

**Ratkaisu:**
1. Luo `src/styles/variables.css` — design tokens (värit, fontit, sätenat)
2. Luo `src/styles/layout.css` — toolbar, paneelien layout-rakenne
3. Luo `src/styles/components.css` — button-variantit, taulukot, lomake-elementit
4. Korvaa inline-tyylit CSS-luokilla vaiheittain (toolbar ensin, sitten paneelit)
5. Toistuva nappirakenne (8 toolbar-nappia, identtiset tyylit) → yksi `.toolbar-btn` -luokka

**Käytännössä:**
```css
/* variables.css */
:root {
  --color-primary: #1976d2;
  --color-success: #4caf50;
  --color-danger: #f44336;
  --radius-sm: 4px;
  --radius-md: 6px;
}

/* components.css */
.toolbar-btn {
  padding: 8px 12px;
  font-size: 12px;
  font-weight: 600;
  border-radius: var(--radius-sm);
  border: 1px solid #ccc;
  background: #fff;
  color: #333;
  cursor: pointer;
  width: 80px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 2px;
}
.toolbar-btn--active {
  background: var(--color-primary);
  color: #fff;
}
```

**Voitot:**
- Tyylimuutokset keskitetysti, ilman laajaa JSX-muokkausta
- Toistuvat button-, form- ja panel-tyylit yhdenmukaistuvat
- Inline-objektien määrä pienenee selvästi, mikä vähentää myös renderin sivukuluja

**Arvioitu koko:** ~200 riviä CSS:ää, ~250 JSX-riviä yksinkertaistuu

---

### Vaihe 5: StationLayoutin lookup-optimointi

**Prioriteetti:** Keskitaso  
**Vaikutus:** Suorituskyky + selkeämpi renderlogiikka  
**Riski:** Matala  

**Ongelma:** `StationLayout` tekee renderissä toistuvia hakuja `find()`-operaatioilla batches-, units- ja transporterStates-taulukoista [services/ui/src/components/StationLayout/index.jsx](services/ui/src/components/StationLayout/index.jsx#L160-L167), [services/ui/src/components/StationLayout/index.jsx](services/ui/src/components/StationLayout/index.jsx#L192-L201) ja [services/ui/src/components/StationLayout/index.jsx](services/ui/src/components/StationLayout/index.jsx#L229-L238).

**Ratkaisu:**
1. Rakenna `useMemo()`lla lookup-mapit:
  - `batchByLocation`
  - `unitByBatchId`
  - `unitByLocation`
  - `transporterStateById`
2. Käytä renderissä suoria lookuppeja `map.get(...)` / objektihakua.
3. Vasta tämän jälkeen arvioi, tarvitaanko lisää memoointia alikomponenteille.

**Voitot:**
- Vähemmän toistuvia lineaarisia hakuja renderissä
- Selkeämpi renderlogiikka
- Hyvä pohja myöhemmälle `React.memo`-käytölle

---

### Vaihe 6: Polling-optimointi

**Prioriteetti:** Korkea  
**Vaikutus:** Suorituskyky (kriittinen)  
**Riski:** Matala–keskitaso  

**Ongelma:** 7 erillistä `setInterval`-pollausta pyörii samanaikaisesti [services/ui/src/App.jsx](services/ui/src/App.jsx#L129-L129), [services/ui/src/App.jsx](services/ui/src/App.jsx#L236-L236), [services/ui/src/App.jsx](services/ui/src/App.jsx#L278-L278), [services/ui/src/App.jsx](services/ui/src/App.jsx#L304-L304), [services/ui/src/App.jsx](services/ui/src/App.jsx#L444-L444), [services/ui/src/App.jsx](services/ui/src/App.jsx#L489-L489) ja [services/ui/src/App.jsx](services/ui/src/App.jsx#L499-L499).

**Tarkennus nykyiseen suunnitelmaan:** kaikkia pollauksia ei yhdistetä sokeasti yhteen. Paneelikohtaiset lataukset säilytetään erillisinä, jos ne liittyvät vain avattuun UI-paneeliin.

**Ratkaisu:**
1. Tee yksi yhteinen 2s core-pollaus aina näkyvälle datalle:
  - PLC status
  - batches/units
  - transporter tasks/manual tasks
  - scheduler state
2. Säilytä nopea `transporter-states`-pollaus erillisenä.
3. Säilytä `showCustomer` / `showProduction` / `showBatches` -sidotut lataukset ehdollisina, koska ne vähentävät turhaa liikennettä.
4. Vältä setState-kutsuja, jos data ei oikeasti muuttunut.

**Voitot:**
- Vähemmän päällekkäistä pollauslogiikkaa
- Vähemmän turhia renderöintejä
- Silti säilytetään nykyiset eri päivitysrytmit siellä missä niille on tarve

---

### Vaihe 7: Context-kerros (tila pois App.jsx:stä)

**Prioriteetti:** Korkea  
**Vaikutus:** Ylläpidettävyys + rajattu suorituskykyhyöty  
**Riski:** Keskitaso  

**Ongelma:** Kaikki 69 useState-hookia asuvat App-komponentissa. Tämä tekee tilan omistajuudesta epäselvää. Pelkkä Context ei kuitenkaan automaattisesti ratkaise renderöintejä, jos nopeasti muuttuva data viedään yhteen isoon provideriin.

**Ratkaisu:** Käytetään pieniä ja tarkoituksenmukaisia contexteja tai provider-kokonaisuuksia:

| Context | Sisältö | Päivitystiheys |
|---------|---------|----------------|
| `PlantContext` | customer, plant, config, stations, tanks, transporters, batches, units | Harvoin (vaihto/reset) |
| `UiPanelsContext` | showCustomer, showConfig, showProduction, showBatches, showTasks, debugTransporterId | Käyttöliittymäohjaus |
| `SimulationContext` | isRunning, elapsedMs, speed, plcStatus, productionQueue, avgCycleSec | 500ms–2s |

**Tärkeä rajaus:** `transporterStates` kannattaa pitää erillisen hookin tai kapean providerin takana. Sitä ei pidä automaattisesti upottaa laajaan `SimulationContext`iin.

**Käytännössä (PlantContext):**
```jsx
// context/PlantContext.jsx
const PlantContext = createContext(null);

export function PlantProvider({ children }) {
  const [config, setConfig] = useState(null);
  const [stations, setStations] = useState([]);
  const [tanks, setTanks] = useState([]);
  const [transporters, setTransporters] = useState([]);
  const [selectedCustomer, setSelectedCustomer] = useState('');
  const [selectedPlant, setSelectedPlant] = useState('');
  // ... muu plant-tila

  // Data loading + reset logiikka tänne

  const value = useMemo(() => ({
    config, stations, tanks, transporters,
    selectedCustomer, selectedPlant,
    setSelectedCustomer, setSelectedPlant,
    // ...
  }), [config, stations, tanks, transporters, selectedCustomer, selectedPlant]);

  return <PlantContext.Provider value={value}>{children}</PlantContext.Provider>;
}

export const usePlant = () => useContext(PlantContext);
```

**Voitot:**
- Selkeä tilaomistajuus
- Vähemmän prop-drillingiä paneelikomponenttien välillä
- Helpottaa App.jsx:n pienentämistä ja testattavuutta

**Migraatiostrategia:**
1. Luo `PlantContext` ja `UiPanelsContext`
2. Siirrä vain hitaammin muuttuvat ja laajasti käytetyt tilat niihin
3. Lisää `SimulationContext` vasta kun komponenttirajat ovat selvemmät
4. Varmista jokaisen vaiheen jälkeen että käyttöliittymä toimii identtisesti

---

### Vaihe 8: React.memo + useMemo/useCallback strategia

**Prioriteetti:** Keskitaso  
**Vaikutus:** Suorituskyky  
**Riski:** Matala  

**Ongelma:** Jokainen komponentti renderöityy uudelleen vanhemman tillamuutoksesta, vaikka omat propsit eivät muutu.

**Ratkaisu:**

| Komponentti | Tekniikka | Perustelu |
|-------------|-----------|-----------|
| `StationLayout` | `React.memo` | Raskas SVG, propsit muuttuvat vain transporterStates-päivityksellä |
| `Station` | `React.memo` | Ei muutu ellei batches/avoidStatus muutu kyseiselle asemalle |
| `Transporter2D/3D` | `React.memo` | Vain oman transporterin tila kiinnostavaa |
| `ProductionBar` | `React.memo` | Muuttuu harvoin |
| Toolbar-napit | `useCallback` handlereille | Estä turhia renderöintejä |
| `plcBatches` | `useMemo` (✓ jo olemassa) | Hyvä, säilytä |

**Tärkeä rajaus:** memoointi tehdään vasta kun komponenttirajat, propsit ja lookupit ovat vakaat. Muuten riski on, että lisätään monimutkaisuutta ilman mitattavaa hyötyä.

**Esimerkki:**
```jsx
// StationLayout/subcomponents/Station.jsx  
export default React.memo(function Station({ station, batch, avoidStatus, ... }) {
  // ...
}, (prev, next) => {
  return prev.station === next.station 
    && prev.batch === next.batch 
    && prev.avoidStatus === next.avoidStatus;
});
```

---

### Vaihe 9: requestAnimationFrame- ja runtime-päivitysten yksinkertaistaminen

**Prioriteetti:** Keskitaso  
**Vaikutus:** Suorituskyky  
**Riski:** Keskitaso  

**Ongelma:** Nykyinen rAF-loop [services/ui/src/App.jsx](services/ui/src/App.jsx#L452-L465) ei välttämättä aiheuta renderiä joka framella, mutta se tekee runtime-päivityspolusta vaikeaselkoisen, koska samaa dataa päivitetään sekä pollauksessa että rAF-loopin kautta.

**Nykyinen koodi:**
```jsx
const tick = () => {
  const snapshot = latestSnapshotRef.current;
  if (snapshot.transporters !== lastRef) {
    lastRef = snapshot.transporters;
    setDisplayTransporterStates(snapshot.transporters);  // setState triggeröi renderin
  }
  rafId = requestAnimationFrame(tick);
};
```

**Ratkaisu:**
1. Yksinkertaista runtime-datan kulkureitti niin, että omistaja on yksiselitteinen.
2. Vältä kahden eri mekanismin (`setInterval` + rAF) käyttöä saman näkyvän tilan ylläpidossa ilman selkeää syytä.
3. Jos interpolaatio tarvitaan, pidä se kapeasti kapseloituna eikä globaalina App-tason logiikkana.

**Mahdollinen suunta:**
```jsx
// StationLayout tai erillinen useTransporterAnimation-hook
const displayStatesRef = useRef([]);

useEffect(() => {
  let rafId;
  let lastRef = null;
  const tick = () => {
    const snapshot = latestSnapshotRef.current;
    if (snapshot.transporters !== lastRef) {
      lastRef = snapshot.transporters;
      displayStatesRef.current = snapshot.transporters;
      // Trigger StationLayout redraw via callback/subscription, not setState
    }
    rafId = requestAnimationFrame(tick);
  };
  rafId = requestAnimationFrame(tick);
  return () => cancelAnimationFrame(rafId);
}, []);
```

**Voitot:**
- Runtime-päivityspolku yksinkertaistuu
- Helpompi ymmärtää ja profiloida
- Mahdollinen render-kuorma pienenee, jos nykyinen rakenne osoittautuu profilerissa raskaaksi

---

## 4. Toteutusjärjestys, portit ja hyväksymiskriteerit

```
Portti  Sisältö                                 Vaikutus                 Est. koko
──────  ───────────────────────────────────────  ───────────────────────  ──────────
P0      Baseline + API-kerros                    Turvallisuus + rakenne   Pieni
P1      Guard-render poisto + Toolbar           Ylläpidettävyys          Pieni
P2      Paneelit omiksi komponenteiksi          Ylläpidettävyys          Suuri
P3      CSS-erottelu                            Ylläpidettävyys          Keskisuuri
P4      StationLayout lookup-optimointi         Suorituskyky             Pieni
P5      Polling-siivous                         Suorituskyky             Keskisuuri
P6      Contextit harkitusti                    Rakenne                  Keskisuuri
P7      Memoointi ja callback-vakautus          Suorituskyky             Pieni
P8      rAF/runtime-polun yksinkertaistus       Suorituskyky             Pieni
```

### Portti P0 — Baseline + API-kerros

**Tavoite:** luoda turvallinen perusta myöhemmille muutoksille.

**Sisältö:**
- mittausbaseline
- `api/client.js`
- ensimmäiset API-kutsujen siirrot pois App.jsx:stä

**Hyväksymiskriteerit:**
- UI toimii ilman näkyviä regressioita
- vähintään PLC-, config- ja customer-endpointit kulkevat keskitetyn API-kerroksen kautta
- baseline-muistiinpanot kirjattu tähän dokumenttiin tai commit-viestiin

**Testattavat asiat:**
- sivu aukeaa
- customer/plant-valinta toimii
- config latautuu
- PLC status näkyy toolbarissa

### Portti P1 — Guard-render poisto + Toolbar

**Tavoite:** poistaa duplikaatti-JSX ja yhtenäistää päälayout.

**Sisältö:**
- yhteinen `Toolbar`
- disabled-tila configin puuttuessa
- yksi layout-runko molemmille tiloille

**Hyväksymiskriteerit:**
- toolbar näyttää samalta ennen ja jälkeen configin latauksen
- configin puuttuessa vain toiminnallisuus on rajoitettu, ei layout-rakenne
- vanha guard-haara poistettu App.jsx:stä

**Testattavat asiat:**
- käynnistys ilman valittua customer/plantia
- customer-paneelin avaus
- configin latautuminen valinnan jälkeen

### Portti P2 — Paneelit omiksi komponenteiksi

**Tavoite:** siirtää isot UI-alueet omiin tiedostoihinsa.

**Sisältö:**
- `ConfigPanel`
- `CustomerPanel`
- `ProductionPanel`
- `UnitsPanel`
- `TasksPanel`
- `DebugPanel`

**Hyväksymiskriteerit:**
- App.jsx ei enää sisällä suuria panel-JSX-lohkoja
- paneelien avaaminen/sulkeminen toimii ennallaan
- jokainen paneeli toimii samoilla API-polkuilla kuin ennen

**Testattavat asiat:**
- jokainen paneeli avautuu ja sulkeutuu
- customer luonti
- plant luonti
- production create
- unit edit/save
- manual task add/cancel

### Portti P3 — CSS-erottelu

**Tavoite:** yhtenäistää styling ja vähentää inline-tyyliä.

**Sisältö:**
- `styles/variables.css`
- `styles/layout.css`
- `styles/components.css`
- toolbar- ja panel-tyylien siirto luokkiin

**Hyväksymiskriteerit:**
- toolbar- ja paneelikomponenteissa ei ole enää merkittäviä staattisia inline-tyylejä
- UI näyttää visuaalisesti samalta

**Testattavat asiat:**
- toolbar, napit, paneelit, lomakkeet ja taulukot näyttävät ennallaan
- hover/disabled/active-tilat toimivat

### Portti P4 — StationLayout lookup-optimointi

**Tavoite:** vähentää renderin sisäisiä hakuja.

**Sisältö:**
- memoisoidut lookup-mapit
- suorien `find()`-hakujen korvaus renderin kriittisissä kohdissa

**Hyväksymiskriteerit:**
- StationLayout renderöi identtisesti ennen/jälkeen
- `find()`-hakujen määrä renderpolussa vähenee oleellisesti

**Testattavat asiat:**
- asemat näkyvät oikein
- batchit näkyvät oikeilla asemilla
- transporterit näyttävät oikean unit/batch-tiedon

### Portti P5 — Polling-siistiminen

**Tavoite:** vähentää hajautettua pollauslogiikkaa ilman toiminnallista regressiota.

**Sisältö:**
- core 2s pollaus
- ehdolliset paneelikohtaiset lataukset säilytetään
- nopea transporter-pollaus säilytetään erillisenä

**Hyväksymiskriteerit:**
- data päivittyy samalla käytännön rytmillä kuin ennen
- ei havaittavia stale-data-tilanteita
- pollauslogiikka on luettavissa yhdestä paikasta per dataluokka

**Testattavat asiat:**
- PLC status päivittyy
- transporter tasks päivittyvät
- batches/units päivittyvät
- scheduler/production stats päivittyvät

### Portti P6 — Contextit harkitusti

**Tavoite:** siirtää hitaammin muuttuva ja laajasti käytetty tila pois App.jsx:stä.

**Sisältö:**
- `PlantContext`
- `UiPanelsContext`
- mahdollisesti rajattu `SimulationContext`

**Hyväksymiskriteerit:**
- App.jsx pienenee merkittävästi
- contextit eivät pakota laajoja turhia renderöintejä profilerissa
- nopeasti muuttuva runtime-data ei ole yhdessä ylipainoisessa providerissa

**Testattavat asiat:**
- customer/plant/config-tila säilyy oikein
- panel state säilyy oikein
- simulation state toimii ennallaan

### Portti P7 — Memoointi ja callback-vakautus

**Tavoite:** vähentää turhia renderöintejä vakaassa rakenteessa.

**Sisältö:**
- `React.memo` valittuihin komponentteihin
- `useMemo` lookup- ja johdettuun dataan
- `useCallback` usein välitettäville handlereille

**Hyväksymiskriteerit:**
- profilerissa renderit vähenevät valituissa komponenteissa
- ei stale-props- tai callback-bugeja

**Testattavat asiat:**
- StationLayout päivittyy edelleen oikein
- napit toimivat
- paneelien callbackit toimivat

### Portti P8 — rAF/runtime-polun yksinkertaistus

**Tavoite:** selkeyttää nopean runtime-datan päivityspolkua.

**Sisältö:**
- rAF-logiikan kapselointi tai poisto
- yhden selkeän omistajan määrittely display/runtime-stateille

**Hyväksymiskriteerit:**
- transporter-liike näkyy edelleen oikein
- runtime-päivityspolku on yksiselitteinen
- profilerissa ei havaita uutta regressiota

**Testattavat asiat:**
- transporter-liike näkyy sulavasti
- debug-näkymän data vastaa liikettä
- nopea runtime-päivitys ei riko muuta UI:ta

---

## 5. Suorituskykyarvio

| Mittari | Nyt | Jälkeen | Muutos |
|---------|-----|---------|--------|
| App.jsx rivimäärä | 3 127 | < 300 (välitavoite), lopuksi < 100 | selvä vähennys |
| Isojen paneelien määrä App.jsx:ssä | 5+ | 0 | −100 % |
| API-kutsujen omistaja | hajallaan | keskitetty kerros + domain-hookit | rakenteellinen parannus |
| Pollauspisteet | 7 | vähemmän, mutta ei keinotekoisesti 1 | hallittavuus paranee |
| StationLayout renderpolun lookupit | useita `find()`-hakuja | memoisoitu lookup-rakenne | kevenee |

**Huomio:** suorituskykyluvut tarkennetaan vasta baseline-mittauksen jälkeen. Tässä vaiheessa tavoite on ennen kaikkea poistaa tunnetut rakenneongelmat ilman ominaisuushävikkiä.

---

## 6. Riskianalyysi ja hallintakeinot

Toteutuksen auditoinnissa on tunnistettu kolme merkittävää arkkitehtuuritason riskiä, jotka on otettava huomioon refaktoroinnin aikana.

### 1. Tilojen menetys (State Loss) komponenttien irrotuksessa
**Riski:** Kun massiivinen `App.jsx` pilkotaan pienempiin paneeleihin (Portti P2), tilojen hallinnan siirto voi aiheuttaa tilan tarpeetonta nollautumista (state loss) renderöintien yhteydessä.
**Mitigaatio:** 
- Suosi alkuvaiheessa prop-drillingiä (propsien välittämistä suoraan App.jsx:stä alikomponenteille) komponenttien eriyttämisessä.
- Vasta kun komponenttirajat ovat vakaat ja testatut, paikalliset tilat siirretään omaan jäsennellympään React Contextiinsa (Portti P6).

### 2. Vanhentunut data (Stale Data) pollausoptimoinnissa 
**Riski:** Jos 7 erillistä `setInterval`-pollausta yhdistetään yksinkertaisella `Promise.all`-kutsulla, yhden endpointin hidastuminen tai virhe kaataa koko päivityssyklin. Tämä jättää UI:hin vanhentunutta dataa ja voi jäädyttää sovellusta.
**Mitigaatio:** 
- Keskitetyssä pollauslogiikassa (Portti P5) on käytettävä **`Promise.allSettled`**-metodia. Tällöin osittainen datan päivitys onnistuu aina (esim. transporterit päivittyvät vaikka scheduler-raportointi viivästyisi).
- Säilytä paneelikohtaiset pollaukset visuaalisten ehtojen (`showCustomer`, `showProduction`) takana.

### 3. Kilpailutilanteet (Race Conditions) nopean ja hitaan datan välillä
**Riski:** Sovelluksessa on nopeaa dataa (`requestAnimationFrame`, transporter-liikkeet) ja hidasta dataa (React Context, asiakas/tehdas-tiedot). Näiden yhdistäminen samaan renderöintipuuhun väärin perustein aiheuttaa kilpailutilanteita ja massiivisia suorituskykyongelmia vieden pohjan koko UI-optimoinnilta.
**Mitigaatio:** 
- Erottele nopea ja hidas data ehdottomasti toisistaan. `PlantContext`iin sijoitetaan vain harvoin muuttuva data. 
- Nopea `transporterStates`-data pidetään kapeana joko omana paikallisena tilanaan (tai omana ref-pohjaisena toteutuksenaan rAF-loopissa), jota optimoidaan O(1) `useMemo`-lookupeilla (Portti P4) `StationLayout`-komponentin sisällä.

### Yhteenveto riskeistä

| Riski | Todennäköisyys | Vaikutus | Mitigation (kokoava) |
|-------|---------------|----------|------------|
| Regressio ominaisuuksissa | Keskitaso | Korkea | Manuaalitestaus jokaisen portin jälkeen, tiukka step-by-step eteneminen. |
| Context-käytön aiheuttama over-engineering | Keskitaso | Keskitaso | Contextit tuodaan vasta paneeli- ja domain-rajojen vakiinnuttua (P2 -> P6). |
| CSS-luokkien nimeämisongelmat | Matala | Matala | BEM-konventio tai CSS Modules myöhemmin. |
| Polling-yhdistämisen virheet | Korkea | Korkea | `Promise.allSettled` käyttö ja erillisten aikataulujen kunnioitus. |
| rAF ja React-tilan konfliktit | Korkea | Korkea | Nopean datan eristys; `useMemo`-lookupit `StationLayout`issa. |

---

## 7. Mitä EI muuteta tässä vaiheessa

- **TypeScript-migraatio** — suuri työ, ei suorituskykyetua. Tehdään myöhemmin.
- **State management -kirjasto (Zustand/Redux)** — React Context riittää tässä laajuudessa.
- **Testien lisääminen** — tärkeä, mutta erillinen työ. Komponenttien erottelu tekee sen helpommaksi.
- **Dashboard/Schedule HTML-integrointi** — erilliset tiedostot, ei vaikuta App.jsx:n suorituskykyyn.
- **Routing (React Router)** — sovellus on single-view, ei tarvetta vielä.
- **D3.js-riippuvuuden korvaaminen** — D3 on käytössä vain StationLayout:ssa, joka on jo modulaarinen.
- **Kirjastoversioiden päivitykset** — Vite 4→5, React 18→19 jne. — erillinen työ.

---

## 8. Onnistumiskriteerit

1. ✅ Kaikki nykyiset toiminnot toimivat identtisesti
2. ✅ App.jsx < 100 riviä
3. ✅ Yksikään komponenttitiedosto ei ylitä 400 riviä
4. ✅ 0 inline-tyyliä toolbar- ja paneelikomponenteissa (dynaamiset OK)
5. ✅ Baseline ja jälkimittaus tehty vähintään porteissa P0, P5 ja P8
6. ✅ Jokainen portti on oma commit- tai PR-kokonaisuutensa
7. ✅ StationLayout näyttää identtiseltä ennen/jälkeen lookup- ja memoointivaiheiden
8. ✅ Polling-siivous ei muuta käyttäjän kokemaa päivitysrytmiä kriittisissä näkymissä

---

## 9. Suositeltu toteutusjärjestys käytännössä

1. **P0** — baseline + API-kerros  
2. **P1** — guard-render pois + toolbar yhteen paikkaan  
3. **P2** — panelit omiksi komponenteiksi  
4. **P3** — CSS-erottelu  
5. **P4** — StationLayout lookup-optimointi  
6. **P5** — polling-siivous  
7. **P6** — contextit harkitusti  
8. **P7** — memoointi ja callback-vakautus  
9. **P8** — rAF/runtime-polun yksinkertaistus

Tämä järjestys minimoi riskin, koska ensin erotetaan vastuut ja poistetaan duplikaatiota, vasta sen jälkeen optimoidaan nopeasti muuttuvaa runtime-dataa.

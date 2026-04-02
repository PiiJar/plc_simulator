# Build ja Deploy

## Kaksi toimitusmuotoa

| Muoto | Kohde | Sisältö |
|-------|-------|---------|
| **PLCopenXML** | Kehitysympäristö | Kaikki POU:t mukaan lukien PLC_PRG ja SIM_* |
| **CODESYS Library** | Asiakastoimitus | Vain kirjasto-POU:t (salattu), ilman PLC_PRG ja SIM_* |

## PLCopenXML-generointi (kehitysympäristö)

Lähdekoodista generoidaan CODESYS-importtavissa oleva XML-tiedosto Python-skriptillä.

### Tiedostorakenne

```
services/codesys/
├── UDTs/*.st           ← 32 tietotyyppiä
├── GVLs/*.st           ← 3 globaalilistaa
├── POUs/**/*.st        ← POU:t (rekursiivinen haku)
├── build_codesys_xml.py  ← generointiskripti
└── build/
    └── project.xml     ← generoitu PLCopenXML
```

### Generointi

```bash
cd services/codesys/
python3 build_codesys_xml.py
# → build/project.xml
```

### Mitä build_codesys_xml.py tekee

1. **Lukee** kaikki `.st`-tiedostot UDTs/, GVLs/ ja POUs/ -kansioista (rekursiivinen)
2. **Parsii** IEC 61131-3 ST-lähdekoodin:
   - Tunnistaa POU-tyypin: `FUNCTION`, `FUNCTION_BLOCK`, `PROGRAM`
   - Parsii muuttujalohkot: `VAR_INPUT`, `VAR_OUTPUT`, `VAR_IN_OUT`, `VAR_EXTERNAL`, `VAR`
   - Käsittelee UDT-struktuurit ja GVL-vakiot
3. **Korvaa symboliset vakiot** taulukkorajoissa numeerisilla literaaleilla
4. **Generoi** PLCopenXML-rakenteen (CODESYS 3.5 -yhteensopiva)

### Kriittinen yksityiskohta: CONST_VALUES

CODESYS:n PLCopenXML-importti ei tue symbolisia vakioita `<dimension>`-elementeissä.
Siksi `build_codesys_xml.py` sisältää dict:n, joka kuvaa symboliset nimet numeerisiksi:

```python
CONST_VALUES = {
    "MAX_LINES":                 "1",
    "MAX_STATIONS_PER_LINE":     "30",
    "MAX_Transporters_PER_LINE": "3",
    "MIN_StationIndex":          "100",
    "MAX_StationIndex":          "130",
    "MAX_Transporters":          "3",
    "MAX_Units":                 "10",
    "MAX_STATIONS_PER_STEP":     "5",
    "MAX_STEPS_PER_PROGRAM":     "30",
    "MAX_TASK_QUEUE":            "30",
    "MAX_LOCKS":                 "50",
    "DEP_MAX_IDLE_SLOTS":        "20",
    "DEP_MAX_DELAY_ACTS":        "20",
    "DEP_MAX_WAITING":           "5",
}
```

**Jos GVL_JC_Constants.st:n vakion arvo muuttuu, se on päivitettävä myös tänne.**
Muuten generoitu XML sisältää vanhan arvon ja CODESYS-importti luo vääränkokoisia taulukoita.

### PLCopenXML-rakenne

Generoitu XML noudattaa PLCopen TC6 -skeemaa:

```xml
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <types>
    <dataTypes>
      <!-- UDT:t: UDT_BatchType, UDT_StationType, ... -->
    </dataTypes>
    <pous>
      <!-- FUNCTION_BLOCK, FUNCTION, PROGRAM -->
      <!-- PLC_PRG viimeisenä -->
    </pous>
  </types>
  <instances>
    <configurations>
      <configuration name="Config">
        <resource name="Res">
          <task name="MainTask" interval="T#20ms" priority="1"/>
          <globalVars>
            <!-- GVL_JC_Constants, GVL_JC_Scheduler, GVL_Parameters -->
          </globalVars>
        </resource>
      </configuration>
    </configurations>
  </instances>
</project>
```

## CODESYS-import

1. Avaa CODESYS IDE
2. **File → Project → Import PLCopenXML...**
3. Valitse `build/project.xml`
4. CODESYS luo kaikki POU:t, UDT:t ja GVL:t automaattisesti
5. Käännä projekti (**Build → Build**)
6. Lataa PLC:lle tai käynnistä simulaatio

## Docker-ympäristö (kehitys ja testaus)

Testausympäristö käyttää Docker Composea:

```
infra/docker-compose.yml
├── codesys     — CODESYS runtime + PLC-ohjelma (kaikki POU:t mukana)
├── gateway     — Node.js: OPC UA adapter, REST API
├── db          — PostgreSQL
└── ui          — Vite/React dashboard
```

Tämä ympäristö on rakennettu schedulerin testausta ja validointia varten.
Asiakkaalle ei toimiteta Docker-ympäristöä.

## Kirjastotoimitus (asiakas)

### Toimitettavat komponentit

Kirjasto paketoidaan CODESYS Library -muotoon, jossa lähdekoodi on lukittu:

| Komponentti | Sisältö | Salattu |
|-------------|---------|---------|
| `STC_FB_MainScheduler` | Kirjaston entry point | Kyllä |
| `TSK_*`, `DEP_*`, `STC_*`, `TWA_*` | Kaikki kirjasto-POU:t | Kyllä |
| `GVL_JC_Constants`, `GVL_JC_Scheduler` | Kirjaston globaalit | Kyllä |
| `UDT_*` | Tietotyypit | Kyllä |
| `GVL_Parameters` | Rajapinta (asiakkaan kirjoittamat muuttujat) | Ei (näkyvissä) |

### Mitä EI toimiteta

- `PLC_PRG` — asiakas kirjoittaa oman
- `SIM_*` — kehitysympäristön testikerros
- `build_codesys_xml.py` — generointityökalu
- Docker-infra, Gateway, UI

### CODESYS Library -paketointi

1. Avaa kehitysprojekti CODESYS IDE:ssä
2. Poista SIM_*-POU:t ja testi-PLC_PRG projektista
3. **Project → Project Information** — täytä versio, yritys, kuvaus
4. **Project → Properties → Encryption** — aseta salasana (lukitsee lähdekoodin)
5. **File → Save As Library** → `.library`-tiedosto
6. Asiakas asentaa: **Library Manager → Add Library → Install**

## Tehtävälistan tarkistus muutoksen jälkeen

Kun muutat scheduler-koodia:

1. ✅ Muokkaa `.st`-tiedostoa
2. ✅ Jos vakion arvo muuttui → päivitä `CONST_VALUES` in `build_codesys_xml.py`
3. ✅ Generoi XML: `python3 build_codesys_xml.py`
4. ✅ Importtaa CODESYS:iin
5. ✅ Käännä ja testaa

## Nimikäytännöt tiedostoissa

| Hakemisto | Sisältö | Nimeäminen |
|-----------|---------|------------|
| `UDTs/` | Tietotyypit | `UDT_<Nimi>Type.st` |
| `GVLs/` | Globaalit | `GVL_<Nimi>.st` |
| `POUs/` | Ohjelmalohkot | `<Prefiksi>_<Nimi>.st` |
| `POUs/SIM/` | Simulaatio | `SIM_<Nimi>.st` |
| `build/` | Generoitu | `project.xml` (ei versionhallinnassa) |

# Codesys Naming Alignment Plan

## Tavoite

Yhdenmukaistaa koko `services/codesys`-kansion ST-lähdetiedostojen nimet
`docs/PLC_Programming_Style_Guide.md` -ohjeen mukaisiksi siten, että nykyinen
CODESYS-käyttö säilyy toimivana.

Tämä tarkoittaa, että kaikki naming-scopeen kuuluvat nimet korjataan:
- lohkojen nimet (`FUNCTION`, `FUNCTION_BLOCK`, `PROGRAM`)
- tyyppien nimet (`UDT_*`, `GVL_*`)
- UDT-rakenteiden kentät
- kaikki muuttujaluokat (`VAR`, `VAR_INPUT`, `VAR_OUTPUT`, `VAR_IN_OUT`, `VAR_EXTERNAL`, `VAR_EXTERNAL CONSTANT`, `VAR_GLOBAL`, `VAR_GLOBAL CONSTANT`)
- kaikki kutsukohdat ja muut viittaukset, joissa nimet esiintyvät

## Tarkoitus

Tämän vaiheen tarkoitus on tehdä koko CODESYS-lähdepaketista nimikäytäntöjen osalta
yhtenäinen ja valmistella se myöhempää TIA-toteutukseen sovittamista varten.

Tässä vaiheessa **ei** muuteta `VAR_EXTERNAL`-lohkojen rakennetta — ne säilyvät CODESYS-käyttöä varten.
Sen sijaan varmistetaan, että kaikki nimet **kaikkialla** noudattavat PLC Guide -käytäntöjä.
`VAR_EXTERNAL` → DB -rakennemuunnos kuuluu erilliseen myöhempään TIA-migraatiovaiheeseen.

> **Tietoinen poikkeama guidesta:** PLC Guide kieltää `VAR_EXTERNAL`-käytön TIA-yhteensopivuuden takia. CODESYS-vaiheessa lohkot tarvitaan ja ne säilyvät. Tämä on dokumentoitu väliaikainen poikkeama, ei virhe.

## Rajaus

- Tämä suunnitelma koskee kaikkia ST-lähdetiedostoja hakemistoissa `services/codesys/GVLs/`, `services/codesys/UDTs/` ja `services/codesys/POUs/`.
- Tämä suunnitelma koskee myös `services/codesys/POUs/SIM/`-kansion simulaatiolohkoja.
- `plc_prg.st` on vain CODESYS-käyttöön: sen oman ohjelmanimen ei tarvitse noudattaa guidea, mutta sen sisältämien kutsuviittausten on vastattava päivitettyjä lohko- ja muuttujanimiä.
- Tämä suunnitelma ei koske Python-, Docker-, XML-, cfg- tai shell-tiedostoja, paitsi siltä osin kuin ne rakennetaan päivitettyjen ST-lähteiden pohjalta.

---

## Nykytila

- ST-lähteitä yhteensä 71 kpl:
    - 3 GVL-tiedostoa
    - 34 UDT-tiedostoa
    - 34 POU-tiedostoa (sisältäen `plc_prg.st` ja `POUs/SIM/`)
- Kvantifioitu naming-baseline on tällä hetkellä vain POU-alijoukolle:
    - 27 aiemmin auditoitua POU-lohkoa
    - **229 nimeämisrikkomusta** 25 tiedostossa
    - 2 tiedostoa jo oikein: `FC_STC_CalcHorizontalTravel.st`, `FC_STC_UpdateUnitLocation.st`
- Koko `services/codesys`-puun naming-baseline tarkennetaan Vaiheessa 1.

### Rikkomusten jakauma

| Tiedosto | Rikkomuksia |
|---|---|
| FC_TSK_NoTreatment.st | 34 |
| FC_TSK_Analyze.st | 26 |
| FB_TWA_CalcLimits.st | 20 |
| FB_TSK_Scheduler.st | 18 |
| FC_STC_DispatchTask.st | 14 |
| FC_STC_TrackMoveTimes.st | 11 |
| FC_STC_TakeOut.st | 10 |
| FC_STC_CalcSchedule.st | 9 |
| FC_TSK_Resolve.st | 9 |
| FC_DEP_OverlapDelay.st | 8 |
| FC_DEP_FitTaskToSlot.st | 6 |
| FC_STC_ManualTask.st | 5 |
| FC_STC_CreateTasks.st | 4 |
| FC_STC_ShiftSchedule.st | 4 |
| FC_STC_NoTreatmentStates.st | 3 |
| FC_STC_SortTasks.st | 3 |
| FB_STC_FindTransporter.st | 3 |
| FC_STC_SwapTasks.st | 2 |
| FC_STC_CalcTransferTime.st | 2 |
| FC_DEP_CalcOverlap.st | 2 |
| FC_DEP_CalcIdleSlots.st | 3 |
| FC_DEP_Sandbox.st | 1 |
| FC_STC_CollectActiveBatches.st | 1 |
| FB_STC_MainScheduler.st | 1 |
| FC_STC_UpdateUnitLocation.st | 0 ✅ |
| FC_STC_CalcHorizontalTravel.st | 0 ✅ |

---

## Nimeämissäännöt (PLC Guide)

| Lohko | Etuliite | Esimerkki |
|---|---|---|
| UDT | `UDT_` | `UDT_JC_TskQueueType` |
| GVL | `GVL_` | `GVL_JC_Scheduler` |
| Blokin nimi (Function) | `FC_` | `FC_STC_SwapTasks` |
| Blokin nimi (Function Block) | `FB_` | `FB_TWA_CalcLimits` |
| Blokin nimi (Program) | ei etuliitettä | `plc_prg` *(vain CODESYS — nimi ei naming-fixin kohde, sisäiset kutsut kyllä)* |
| UDT-kenttä | PascalCase | `TaskEndTime`, `TransporterId` |
| VAR_INPUT | `i` + iso | `iRun`, `iTimeS` |
| VAR_OUTPUT | `o` + iso | `oPhase`, `oCheckedCount` |
| VAR_IN_OUT | `io` + iso | `ioTask`, `ioIdleSlot` |
| VAR (lokaali) | `v` + iso | `vCurrentX`, `vTi` |
| VAR (FB-instanssi) | `vFB_` | `vFB_TskScheduler` |
| VAR (lokaali vakio) | `c` + iso | `cHorizon`, `cMaxConflictIter` |
| VAR_GLOBAL CONSTANT | ALL_CAPS | `MAX_TRANSPORTERS`, `SCH_MARGIN_S` |
| VAR_GLOBAL | projektikonventio: `g_` tai PascalCase | `g_task`, `Stations` |
| VAR (silmukkalaskuri, 1 kirjain) | sellaisenaan | `i`, `j`, `k`, `l` |
| VAR_EXTERNAL (globaali vakio) | ALL_CAPS | `MAX_TRANSPORTERS`, `SCH_MARGIN_S` |
| VAR_EXTERNAL (globaali muuttuja) | `g_` tai PascalCase | `g_task`, `Stations` |

> **Huom `t`-etuliite:** PLC Guide määrittelee `Temporary`-kategorian etuliitteellä `t` (esim. `tIndex`). Tässä projektissa lyhyet hakemistomuuttujat (`ti`, `qi`, `si`) käsitellään `v`-lokaaleina → `vTi`, `vQi`, `vSi`. Yksikirjaimiset silmukkalaskurit (`i`, `j`, `k`) säilytetään sellaisenaan — poikkeus, joka ei riko guiden henkeä.

### Muunnoslogiikka

```
snake_case   →  v + WordByWordCapitalize    (current_x       → vCurrentX)
lyhyt indeksi (2-3 kirj) →  v + Capitalize  (ti, qi, si      → vTi, vQi, vSi)
ALL_CAPS lokaalina       →  c + CamelCase   (HORIZON         → cHorizon)
iXxx tai oXxx VAR:ssa    →  v + sama        (iPhase          → vIPhase)
Numerosegmentti snake:ssa →  numero säilyy  (x1_min          → vX1Min)
                                            (x2_max          → vX2Max)
                                            (overflow_best_delay → vOverflowBestDelay)
snake_case UDT-kenttä     →  PascalCase      (task_end_time   → TaskEndTime)
snake_case FUNCTION/FB    →  prefix + PascalCase (`calc_overlap` → `FC_CalcOverlap`)
```

**Reunatapaus — numerosegmentit:** Numero kirjoitetaan suoraan seuraavan sanan alkuun ilman erillistä isoa kirjainta: `x1_min` → `vX1Min` (ei `vX1min` eikä `vX1_Min`).

---

## Toteutusvaiheet

### Vaihe 1 — Koko ST-puun naming-audit

Kirjoitetaan Python-skripti `services/codesys/check_naming.py`, joka auditoi koko
ST-puun (`GVLs/`, `UDTs/`, `POUs/`) ja tuottaa baseline-raportin.

Audit kattaa kaikki naming-kohteet:

| Kohde | Tarkistus |
|---|---|
| `TYPE UDT_*` | tyyppinimi |
| UDT-kentät | PascalCase |
| `VAR_GLOBAL` / `VAR_GLOBAL CONSTANT` | prefix-/ALL_CAPS-säännöt |
| `FUNCTION` / `FUNCTION_BLOCK` / `PROGRAM` | lohkonimi |
| `VAR`, `VAR_INPUT`, `VAR_OUTPUT`, `VAR_IN_OUT` | prefix-säännöt |
| `VAR_EXTERNAL`, `VAR_EXTERNAL CONSTANT` | vastaa GVL-puolen nimeä |
| kutsukohdat ja kenttäviittaukset | vastaavat päivitettyjä nimiä |

Tavoite: koko `services/codesys`-puulle saadaan mitattu naming-baseline ennen korjausta.

### Vaihe 2 — Automaattinen uudelleennimeäminen (fix_naming.py)

Kirjoitetaan Python-skripti `services/codesys/fix_naming.py`.

**Scope: KAIKKI nimeämiskohteet KAIKISSA ST-lähdetiedostoissa**:

| Lohko | Käsittely |
|---|---|
| UDT-tyypit ja kentät | automaattisesti |
| GVL-nimet, `VAR_GLOBAL`, `VAR_GLOBAL CONSTANT` | automaattisesti |
| `FUNCTION`, `FUNCTION_BLOCK`, `PROGRAM` | automaattisesti |
| `VAR`, `VAR_INPUT`, `VAR_OUTPUT`, `VAR_IN_OUT` | automaattisesti |
| `VAR_EXTERNAL CONSTANT` | päivitetään vastaamaan GVL-nimiä |
| `VAR_EXTERNAL` | päivitetään vastaamaan GVL-nimiä |
| kutsukohdat, kenttäviittaukset, tyyppiviittaukset | automaattisesti samassa ajossa |

Toimintaperiaate:
1. Lukee kaikki ST-lähdetiedostot hakemistoista `GVLs/`, `UDTs/`, `POUs/`
2. Kerää kaikki naming-rikkomukset koko puusta
3. Laskee uudet nimet PLC Guiden mukaisesti
4. Rakentaa keskitetyn rename-mapin, jotta GVL-, UDT-, POU- ja kutsukohdaviittaukset pysyvät synkassa
5. Korvaa kaikki esiintymät **kaikissa ST-tiedostoissa** käyttäen `\b`-sanarajaregexiä tai kontekstipohjaista korvausta tarvittaessa
6. Kirjoittaa muokatut tiedostot takaisin

**Tärkeää:** Skripti käsittelee kutsukohtien parametrinimet, UDT-kenttäviittaukset ja GVL/VAR_EXTERNAL-peilaukset mukaan samaan ajoon.

**GVL-nimien tämänhetkinen tila (auditin lähtötieto):**
- `GVL_JC_Constants`: kaikki ALL_CAPS ✅
- `GVL_JC_Scheduler`: `g_`-etuliite ✅
- `GVL_JC_Parameters`: `Stations`, `Transporters`, `TreatmentPrograms` PascalCase ✅

### Vaihe 3 — Manuaaliset pistekorjaukset

Automaattivaiheen jälkeen tarkistetaan vähintään seuraavat rakenteelliset erikoistapaukset:

| Tiedosto | Vanha nimi | Uusi nimi | Huomio |
|---|---|---|---|
| `FC_DEP_FitTaskToSlot.st` | `oResult` | `ioResult` | **Lohkon tyyppi muuttuu** VAR_OUTPUT → VAR_IN_OUT — vaatii manuaalisen tarkistuksen |

Muut rakenteelliset poikkeukset lisätään tähän vaiheeseen, jos Vaihe 1 löytää niitä GVL-, UDT- tai POU-puolelta.

### Vaihe 4 — Verifiointi

Ajetaan naming-audit uudelleen koko `services/codesys`-puulle:

```bash
cd /home/jarmo-piipponen/plc_simulator
python3 services/codesys/check_naming.py
```

Tavoite: **0 violations**.

### Vaihe 5 — XML-projektin uudelleenrakennus

Ajetaan `services/codesys/build_codesys_xml.py`, joka lukee `services/codesys/POUs/`-kansion ja tuottaa `services/codesys/build/project.xml`:n.

```bash
cd /home/jarmo-piipponen/plc_simulator
python3 services/codesys/build_codesys_xml.py
```

Vaiheen jälkeen `services/codesys/build/project.xml` vastaa päivitettyjä POU-tiedostoja.

### Vaihe 6 — Jatkotoimet TIA-migraatiossa (ei tämän suunnitelman osa)

Myöhemmässä erillisessä migraatiovaiheessa CODESYS:n `VAR_EXTERNAL`-viittaukset
muunnetaan TIA-toteutuksen tarvitsemiin DB-viittauksiin.

Tämä vaihe ei kuulu naming-fix-suunnitelman toteutukseen eikä sitä tehdä tässä projektissa
osana CODESYS-paketin yhdenmukaistamista.

---

## Tiedostojen vastaavuustaulukko (codesys → JC, viite toiseen projektiin)

*Huom: JC-kansio (`ST_codes/POUs/OneControl/JC/`) sijaitsee erillisessä StBaseCodes-projektissa eikä kuulu tähän workspaceen. Taulukko on viitteenä, jos tiedostot halutaan myöhemmin kopioida sinne.*

| codesys (`services/codesys/POUs/`) | JC-projekti (korvattava) |
|---|---|
| FB_DEP_Scheduler.st | DEP_FB_Scheduler.st |
| FB_STC_FindTransporter.st | STC_FindTransporter.st |
| FB_STC_MainScheduler.st | STC_FB_MainScheduler.st |
| FB_TSK_Scheduler.st | TSK_FB_Scheduler.st |
| FB_TWA_CalcLimits.st | TWA_FB_CalcLimits.st |
| FC_DEP_CalcIdleSlots.st | DEP_CalcIdleSlots.st |
| FC_DEP_CalcOverlap.st | DEP_CalcOverlap.st |
| FC_DEP_FitTaskToSlot.st | DEP_FitTaskToSlot.st |
| FC_DEP_OverlapDelay.st | DEP_OverlapDelay.st |
| FC_DEP_Sandbox.st | DEP_Sandbox.st |
| FC_STC_CalcHorizontalTravel.st | STC_CalcHorizontalTravel.st |
| FC_STC_CalcSchedule.st | STC_CalcSchedule.st |
| FC_STC_CalcTransferTime.st | STC_CalcTransferTime.st |
| FC_STC_CollectActiveBatches.st | STC_CollectActiveBatches.st |
| FC_STC_CreateTasks.st | STC_CreateTasks.st |
| FC_STC_DispatchTask.st | STC_DispatchTask.st |
| FC_STC_ManualTask.st | STC_ManualTask.st |
| FC_STC_NoTreatmentStates.st | STC_NoTreatmentStates.st |
| FC_STC_ShiftSchedule.st | STC_ShiftSchedule.st |
| FC_STC_SortTasks.st | STC_SortTasks.st |
| FC_STC_SwapTasks.st | STC_SwapTasks.st |
| FC_STC_TakeOut.st | STC_TakeOut.st |
| FC_STC_TrackMoveTimes.st | STC_TrackMoveTimes.st |
| FC_STC_UpdateUnitLocation.st | STC_UpdateUnitLocation.st |
| FC_TSK_Analyze.st | TSK_Analyze.st |
| FC_TSK_NoTreatment.st | TSK_NoTreatment.st |
| FC_TSK_Resolve.st | TSK_Resolve.st |

---

## Riskit ja hallinta

| Riski | Hallinta |
|---|---|
| Substring-konflikti (esim. `ot` osuu `ot_idle_ok`:iin) | `\b`-sanarajat kaikissa regex-korvauksissa |
| Ristiinviittaukset hajoavat GVL/UDT/POU-tiedostojen välillä | Yksi keskitetty rename-map koko ST-puulle, ei tiedostokohtaisia irrallisia korvauksia |
| CODESYS-käyttö rikkoutuu rajapintamuutoksissa | Vaihe 2 päivittää nimetyt parametrit, kenttäviittaukset ja kutsukohdat samassa muutoksessa |
| Kommenteissa olevat vanhat nimet | Hyväksyttävä – ei vaikuta toimintaan |
| TIA-migraatiovaiheen muunnoksia sekoitetaan naming-fixiin | `VAR_EXTERNAL` → DB rajataan erilliseen myöhempään vaiheeseen |

---

## Suoritusjärjestys yhteenveto

```
1. Aja check_naming.py       → muodosta baseline koko services/codesys-ST-puulle
2. Aja fix_naming.py         → nimeä kaikki lohkot, tyypit, kentät ja muuttujat kaikkialla
                               päivitä samalla kaikki viittaukset, kutsukohdat ja VAR_EXTERNAL-peilaukset
3. Tarkista manuaalisesti    → korjaa rakenteelliset erikoistapaukset (esim. oResult→ioResult)
4. Aja check_naming.py       → varmista 0 violations koko services/codesys-puulle
5. Aja build_codesys_xml.py  → uudelleenrakenna build/project.xml
6. VAR_EXTERNAL säilyvät     → DB-muunnos tehdään myöhemmin TIA-vaiheessa
```

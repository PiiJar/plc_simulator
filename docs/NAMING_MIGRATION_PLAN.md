# Nimeämiskonventioiden migraatiosuunnitelma

> Codesys ST -koodipohjan muuttaminen PLC_Programming_Style_Guide -dokumentin mukaiseksi.

## Lähtötilanne

| Sääntö | Nykytila | Tavoite | Muutoksia |
|--------|----------|---------|-----------|
| Lokaalit: `v`-prefiksi + PascalCase | `snake_case` ilman prefiksiä | `vPascalCase` | ~484 muuttujaa / 34 POUa |
| FB-instanssit: `vFB_` | `fb_find`, `tsk_sched` jne. | `vFB_Find`, `vFB_TskSched` | 16 instanssia |
| Funktiot: `FC_`-prefiksi | `STC_CalcSchedule` jne. | `STC_FC_CalcSchedule` | 22 funktiota |
| Globaalit: PascalCase (ei `g_`) | `g_snake_case` | PascalCase | ~62 muuttujaa |
| Vakiot: ALL_CAPS | Osittain PascalCase | ALL_CAPS | ~8 vakiota |
| `qualified_only` GVL:issä | Puuttuu | Lisätään | 3 GVL:ää |
| Otsikkotemplate | Kevyt formaatti | Style Guide -muoto | 34 tiedostoa |
| VAR_INPUT/OUTPUT casing | `i_snake_case` | `iPascalCase` | Kaikki I/O-muuttujat |

## Arkkitehtuurihuomiot

### Kytkentäpiste: opcua_nodes.js

Järjestelmän arkkitehtuuri on puhdas — **yksi tiedosto** toimii PLC-nimien ja ulkomaailman välisenä karttana:

```
ST-koodi (Codesys) ←→ opcua_nodes.js ←→ Gateway API ←→ UI
```

- `services/gateway/opcua_nodes.js` — kaikki ~200 PLC-muuttujaviittausta
- `services/gateway/export_movement_times.js` — 6 suoraa nodeId-viittausta
- `services/codesys/build_codesys_xml.py` — 13 vakionimeä `CONST_VALUES`-dictissä
- UI ja data-JSON eivät viittaa PLC-nimiin suoraan

### Riskien hallinta

- **Jokainen vaihe** on itsenäisesti testattava ja deployattava
- Vaiheet eivät ole riippuvaisia toisistaan (paitsi vaiheiden 3 ja 4 järjestys)
- `opcua_nodes.js` päivitetään **aina samassa commitissa** kuin vastaava ST-muutos

---

## Vaihe 0 — Valmistelu

**Tavoite:** Turvaverkko ennen muutoksia.

| # | Tehtävä | Tiedostot |
|---|---------|-----------|
| 0.1 | Varmista git-haara (`feature/naming-migration`) | — |
| 0.2 | Aja `build_codesys_xml.py` ja varmista clean build | `services/codesys/build/` |
| 0.3 | Aja Docker-ympäristö ylös, testaa gateway-yhteys | `docker-compose.yml` |
| 0.4 | Tallenna "ennen"-snapshot: OPC UA -nodelista | Manuaalinen tarkistus |

**Valmis kun:** Clean build + toimiva OPC UA -yhteys.

---

## Vaihe 1 — Vakiot ja GVL-attribuutit (pieni riski)

**Tavoite:** Korjataan vakioiden casing ja lisätään `qualified_only`. Vähiten kytkentöjä ulospäin.

| # | Tehtävä | Muutos |
|---|---------|--------|
| 1.1 | Lisää `{attribute 'qualified_only'}` GVL-tiedostoihin | 3 GVL-tiedostoa |
| 1.2 | Päivitä kaikki ST-viittaukset käyttämään GVL-kvalifioitua muotoa | Kaikki POUt jotka viittaavat GVL-muuttujiin |
| 1.3 | Korjaa 8 vakiota ALL_CAPS-muotoon | `GVL_JC_Constants.st` |

Vakioiden nimimuutokset:

| Nykyinen | Uusi |
|----------|------|
| `MAX_Transporters` | `MAX_TRANSPORTERS` |
| `MAX_Units` | `MAX_UNITS` |
| `MIN_StationIndex` | `MIN_STATION_INDEX` |
| `MAX_StationIndex` | `MAX_STATION_INDEX` |
| `MIN_WorkingArea` | `MIN_WORKING_AREA` |
| `AVOID_None` | `AVOID_NONE` |
| `AVOID_Passable` | `AVOID_PASSABLE` |
| `AVOID_Block` | `AVOID_BLOCK` |

| # | Ulkoiset päivitykset |
|---|---------------------|
| 1.4 | `build_codesys_xml.py` → `CONST_VALUES`-dictin avaimet | 
| 1.5 | `opcua_nodes.js` → ei vaikutusta (vakiot eivät ole OPC UA -nodeja) |

**Testaus:** Clean build + yksikkötestaus (vakioarvot eivät muutu).

---

## Vaihe 2 — UDT-korjaukset (minimaalinen)

**Tavoite:** Korjataan kaksi yksittäistä poikkeamaa UDT-tiedostoissa.

| # | Tehtävä | Muutos |
|---|---------|--------|
| 2.1 | `UDT_TaskArea` → `UDT_TaskAreaType` | Tiedostonimi + tyyppinimi + kaikki viittaukset |
| 2.2 | `UDT_JC_TskStageType.station` → `.Station` | Kenttänimi + kaikki viittaukset |

| # | Ulkoiset päivitykset |
|---|---------------------|
| 2.3 | `opcua_nodes.js` — tarkista viittaako `station`-kenttään (jos kyllä, päivitä) |

**Testaus:** Clean build + OPC UA -luku.

---

## Vaihe 3 — Globaalien muuttujien uudelleennimeäminen (suurin riski)

**Tavoite:** `g_snake_case` → PascalCase ilman `g_`-prefiksiä. Tämä on laajin ja riskialtein vaihe.

### Strategia: yksi GVL kerrallaan

**Vaihe 3A — GVL_JC_Scheduler (sisäiset muuttujat)**

Nämä ovat schedulerin sisäisiä, harvemmin luettuja gateway'stä:

| Nykyinen | Uusi | Viittauksia OPC UA:ssa |
|----------|------|----------------------|
| `g_schedule` | `Schedule` | Kyllä |
| `g_task` | `Task` | Kyllä |
| `g_sched_dbg_*` | `SchedDbg*` | Kyllä (debug) |
| `g_dbg_tsk_*` | `DbgTsk*` | Kyllä (debug) |
| `g_conflict_resolved` | `ConflictResolved` | Kyllä |
| `g_tsk_stable` | `TskStable` | Kyllä |
| ... | ... | ... |

**Vaihe 3B — GVL_JC_Parameters (rajapintamuuttujat)**

Nämä ovat kriittisimmät — gateway kirjoittaa ja lukee näitä:

| Nykyinen | Uusi | Viittauksia OPC UA:ssa |
|----------|------|----------------------|
| `g_batch` | `Batch` | Kyllä (luku + kirjoitus) |
| `g_unit` | `Unit` | Kyllä (luku + kirjoitus) |
| `g_transporter` | `Transporter` | Kyllä (luku) |
| `g_production_queue` | `ProductionQueue` | Kyllä (kirjoitus) |
| `g_time_s` | `TimeS` | Kyllä (luku) |
| `g_cmd_code` | `CmdCode` | Kyllä (kirjoitus) |
| `g_event` | `Event` | Kyllä (luku) |
| `g_manual_task` | `ManualTask` | Kyllä (kirjoitus) |
| `g_ntt` | `Ntt` | Kyllä (luku) |
| `g_move` | `Move` | Kyllä (luku) |
| ... | ... | ... |

**Jokainen muuttujan uudelleennimeäminen vaatii samanaikaisen päivityksen:**
1. GVL-tiedosto (deklaraatio)
2. Kaikki ST-tiedostot (viittaukset)
3. `opcua_nodes.js` (OPC UA -nodepolut)
4. `export_movement_times.js` (jos viittaa)

**Testaus per muuttuja:** Build + OPC UA -luku + gateway-yhteys.

---

## Vaihe 4 — Funktioiden ja FB:n nimeäminen (keskisuuri riski)

**Tavoite:** Lisätään `FC_`-prefiksi funktioihin ja korjataan `STC_FindTransporter`.

| # | Tehtävä |
|---|---------|
| 4.1 | Funktiot: lisää `FC_` domain-prefiksin jälkeen |
| 4.2 | `STC_FindTransporter` → `STC_FB_FindTransporter` |

Esimerkkejä:

| Nykyinen | Uusi |
|----------|------|
| `STC_CalcSchedule` | `STC_FC_CalcSchedule` |
| `STC_CalcHorizontalTravel` | `STC_FC_CalcHorizontalTravel` |
| `STC_SortTasks` | `STC_FC_SortTasks` |
| `DEP_CalcIdleSlots` | `DEP_FC_CalcIdleSlots` |
| `DEP_CalcOverlap` | `DEP_FC_CalcOverlap` |
| `TSK_Analyze` | `TSK_FC_Analyze` |
| `TSK_Resolve` | `TSK_FC_Resolve` |
| `STC_FindTransporter` | `STC_FB_FindTransporter` |

**Päivitykset per funktio:**
1. Tiedostonimi
2. `FUNCTION`/`FUNCTION_BLOCK`-deklaraatio
3. Kaikki kutsupaikat ST-koodissa
4. `build_codesys_xml.py` — ei vaikutusta (parsii dynaamisesti)

**Testaus:** Clean build (funktioiden nimet eivät näy OPC UA:ssa).

---

## Vaihe 5 — Muuttujaprefiksit ja PascalCase (laajin työ, pieni ulkoinen riski)

**Tavoite:** Kaikki POU-sisäiset muuttujat Style Guide -muotoon. Tämä on puhtaasti ST-sisäinen muutos — ei vaikutusta OPC UA:han tai gateway'hin.

### Vaihe 5A — VAR_INPUT / VAR_OUTPUT / VAR_IN_OUT casing

| Nykyinen | Uusi |
|----------|------|
| `i_time_s` | `iTimeS` |
| `i_unit` | `iUnit` |
| `o_phase` | `oPhase` |
| `o_batch_cnt` | `oBatchCnt` |
| `io_task` | `ioTask` |
| `io_schedule` | `ioSchedule` |

Myös SIM_FB_XMotion/ZMotion: lisätään `io`-prefiksi puuttuviin VAR_IN_OUT-muuttujiin.

### Vaihe 5B — VAR (lokaalit): `v`-prefiksi + PascalCase

| Nykyinen | Uusi |
|----------|------|
| `phase` | `vPhase` |
| `idx` | `vIdx` |
| `cnt` | `vCnt` |
| `found` | `vFound` |
| `prev_end` | `vPrevEnd` |
| `batch_list` | `vBatchList` |

### Vaihe 5C — FB-instanssit: `vFB_`-prefiksi

| Nykyinen | Uusi |
|----------|------|
| `fb_find` | `vFB_Find` |
| `tsk_sched` | `vFB_TskSched` |
| `dep_sched` | `vFB_DepSched` |
| `twa_calc` | `vFB_TwaCalc` |
| `main_scheduler` | `vFB_MainScheduler` |
| `sim_main` | `vFB_SimMain` |

### Vaihe 5D — Lokaalivakiot: `c`-prefiksi

| Nykyinen | Uusi |
|----------|------|
| `MAX_CONFLICT_ITER` | `cMaxConflictIter` |
| `HORIZON` | `cHorizon` |
| `DEFICIT_TOL` | `cDeficitTol` |

**Strategia:** Yksi POU-tiedosto kerrallaan. Ei ulkoisia riippuvuuksia.

**Testaus:** Clean build per tiedosto.

---

## Vaihe 6 — Otsikkotemplateiden päivitys (kosmeettinen)

**Tavoite:** Yhtenäistetään block header -formaatti Style Guiden mukaiseksi.

| # | Tehtävä |
|---|---------|
| 6.1 | Lisää `Block Name`, `Description`, `Version History` -taulukko kaikkiin POUihin |
| 6.2 | Lisää UDT-headeri kaikkiin UDT-tiedostoihin |

**Testaus:** Clean build (kommentit eivät vaikuta toimintaan).

---

## Vaihejärjestys ja riippuvuudet

```
Vaihe 0  Valmistelu
  │
  ├─► Vaihe 1  Vakiot + qualified_only     (pieni riski)
  │
  ├─► Vaihe 2  UDT-korjaukset              (minimaalinen)
  │
  ▼
Vaihe 3  Globaalit g_ → PascalCase         (suurin riski)
  │       ├─ 3A: GVL_JC_Scheduler
  │       └─ 3B: GVL_JC_Parameters
  ▼
Vaihe 4  Funktioiden FC_ + FB-korjaus      (keskisuuri)
  │
  ▼
Vaihe 5  POU-sisäiset muuttujat            (laajin, pienin riski)
  │       ├─ 5A: I/O casing
  │       ├─ 5B: Lokaalit v-prefiksi
  │       ├─ 5C: FB-instanssit vFB_
  │       └─ 5D: Lokaalivakiot c-prefiksi
  ▼
Vaihe 6  Otsikkotemplateet                  (kosmeettinen)
```

Vaiheet 1 ja 2 voidaan tehdä rinnakkain. Vaihe 5 voidaan aloittaa heti vaiheen 4 jälkeen. Vaihe 6 voidaan tehdä milloin tahansa.

---

## Työmääräarvio

| Vaihe | Tiedostoja | Muutoksia | Ulkoisia kytkentöjä |
|-------|-----------|-----------|---------------------|
| 1 | 3 GVL + ~34 POU + build script | ~50 | build_codesys_xml.py |
| 2 | 2 UDT + viittaavat POUt | ~10 | opcua_nodes.js (ehkä) |
| 3 | 3 GVL + 34 POU + 2 gateway-tiedostoa | ~300 | opcua_nodes.js, export_movement_times.js |
| 4 | 22 funktiota + kutsupaikat | ~80 | — |
| 5 | 34 POUa | ~500 | — |
| 6 | 34 POUa + 34 UDTa | Kommentteja | — |

## Avoimet kysymykset

1. **Domain-prefiksit (STC_/DEP_/TSK_/SIM_/TWA_):** Style Guide ei tunne näitä. Pidetäänkö ne vai korvataan puhtaalla `FB_`/`FC_`? Suositus: pidetään, koska ne tuovat selkeän moduulijaon.
2. **`g_`-globaalien uudet nimet:** Osa nimistä (esim. `g_batch` → `Batch`) voi törmätä UDT-nimiin. Nimeämiskäytäntö sovittava etukäteen.
3. **Testausautomaatio:** Onko käytettävissä automaattista OPC UA -regressiotestiä vai tehdäänkö manuaalinen validointi?

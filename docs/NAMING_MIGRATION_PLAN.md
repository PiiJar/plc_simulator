# Nimeämiskonventioiden migraatiosuunnitelma

> Hallittu, vaiheistettu siirtymä nykyisestä CODESYS-nimistöstä PLC_Programming_Style_Guide -dokumentin mukaiseen tuotantoversioon.

## Tarkoitus

Tämä dokumentti perustuu nykyisen `services/codesys/`-hakemiston auditointiin. Tavoite ei ole tehdä yhtä suurta nimeämisrefaktorointia, vaan siirtää koodipohja vaiheittain PLC-guiden suuntaan niin, että:

- PLC:n toimiva tuotantokäytös ei rikkoudu kesken siirtymän
- gatewayn OPC UA -kytkennät pysyvät hallinnassa
- PLCopenXML-build pysyy ehjänä jokaisen vaiheen jälkeen
- jokainen vaihe voidaan testata ja tarvittaessa peruuttaa itsenäisesti

## Auditointiin perustuva lähtötilanne

Nykyisestä CODESYS-kansiosta auditoitiin GVL:t, POU:t ja UDT:t suhteessa [docs/PLC_Programming_Style_Guide.md](docs/PLC_Programming_Style_Guide.md).

### Yhteenveto

| Kohde | Nykytila | Auditointitulos |
|-------|----------|-----------------|
| GVL-tiedostot | `GVL_JC_*` | Käytännössä linjassa guiden kanssa |
| UDT-tyypit | `UDT_*`, lähes kaikki `Type`-suffiksilla | Pääosin linjassa |
| UDT-kentät | PascalCase | Linjassa |
| Functionit | 22 kpl ilman `FC_`-prefiksiä | Selvä poikkeama guideen |
| Function blockit | 11 kpl, nimet kuten `STC_FB_*` ja `SIM_FB_*` | Poikkeama guiden `FB_*`-malliin |
| Program | `PLC_PRG` | Osittainen poikkeama |
| POU-muuttujat | `snake_case`, vaihtelevat lyhenteet | Selvä poikkeama guiden prefix + PascalCase -malliin |
| Julkiset globaalit | Sekoitus `g_*` ja PascalCase-nimiä | Ei suora guide-rike, mutta kriittinen rajapintakysymys |

### Auditoinnin tärkeimmät havainnot

1. Suurin varsinainen guide-poikkeama on funktioiden nimeämisessä.
Nykyiset functionit ovat muotoa `STC_CalcSchedule`, `DEP_CalcIdleSlots`, `TSK_Resolve`, vaikka guide haluaa `FC_`-prefiksin.

2. Function blockit eivät noudata guiden suosittelemaa blokkityyppiprefiksiä nimen alussa.
Nykyiset nimet ovat muotoa `STC_FB_MainScheduler` ja `SIM_FB_MainCycle`, kun guide haluaisi `FB_*`-alkuisen nimen.

3. UDT-puoli on jo lähellä tavoitetta.
Suurin näkyvä poikkeama on `UDT_TaskArea`, josta puuttuu `Type`-suffiksi.

4. POU-muuttujat ovat laajasti eri tyyliä kuin guide.
Nykyinen tyyli käyttää nimiä kuten `i_time_s`, `tsk_sched`, `turn`, `skip_cnt`, kun guide haluaa nimiä kuten `iTimeS`, `vFB_TskScheduler`, `vTurn`, `vSkipCount`.

5. Gateway on kovasti sidottu nykyisiin PLC-nimiin.
`services/gateway/opcua_nodes.js` muodostaa NodeId-polut suoraan IEC-symbolinimistä. Tämä tekee GVL- ja kenttätason nimeämismuutoksista ulkoisesti riskialttiita.

6. Guide ei yksin määrää globaalien OPC UA -muuttujien lopullista nimeämistä.
Siksi julkisten globaalien renamea ei saa tehdä automaattisesti osana muuta siivousta.

## Migraation ohjaavat periaatteet

Tätä suunnitelmaa noudatettaessa jokaisen muutossarjan pitää täyttää seuraavat ehdot:

1. Yksi rajattu muutostyyppi per vaihe.
Esimerkiksi blokkinimet erikseen, paikalliset muuttujat erikseen ja julkiset globaalit erikseen.

2. Ei samassa vaiheessa sekä sisäistä että ulkoista rajapintamuutosta, ellei siihen ole erikseen rakennettu yhteensopivuuskerrosta.

3. Gatewayn OPC UA -nodekartta päivitetään aina samassa muutossarjassa kuin vastaava PLC:n julkinen symboli.

4. PLCopenXML-buildin on pysyttävä ehjänä jokaisessa vaiheessa.

5. Jokaiselle vaiheelle on oma hyväksymiskriteeri.
Vaihetta ei jatketa ennen kuin sen oma validointi on läpäisty.

6. SIM-kerroksen nimeämistä ei käytetä tuotantomigraation ohjaavana referenssinä.
Tuotantotason nimiä johdetaan guideen ja tuotanto-PLC:n tarpeisiin, ei simulaation sisäisestä välivaiheesta.

## Päätettävät naming-linjaukset ennen toteutusta

Ennen ensimmäistäkään rename-commitia pitää lukita nämä päätökset:

### 1. Säilytetäänkö domain-etuliitteet

Nykyiset domain-etuliitteet ovat:

- `STC_`
- `TSK_`
- `DEP_`
- `SIM_`
- `TWA_`

Suositus:

- säilytä domain-etuliite modulaarisuuden vuoksi
- siirrä blokkityyppiprefiksi guiden mukaiseen paikkaan nimen alkuun

Esimerkkisuunta:

| Nykyinen | Suositeltu tavoite |
|----------|--------------------|
| `STC_CalcSchedule` | `FC_STC_CalcSchedule` |
| `DEP_CalcIdleSlots` | `FC_DEP_CalcIdleSlots` |
| `STC_FB_MainScheduler` | `FB_STC_MainScheduler` |
| `SIM_FB_MainCycle` | `FB_SIM_MainCycle` |

Tätä mallia suositellaan, koska se täyttää guiden blokkityyppisäännön ja säilyttää moduulijaon.

### 2. Mikä on julkisten globaalien lopullinen naming policy

Guide ei pakota yksiselitteisesti esimerkiksi muotoon `gCmdCode`, `g_cmd_code` tai `CmdCode`. Siksi tästä pitää tehdä projektikohtainen päätös.

Suositus:

- älä nimeä julkisia OPC UA -muuttujia uudelleen ensimmäisissä vaiheissa
- päätä niiden lopullinen malli erillisessä suunnittelupäätöksessä
- käytä siirtymävaiheessa yhteensopivuuskerrosta gatewayssa, jos julkinen nimi halutaan myöhemmin muuttaa

## Vaiheistus

## Vaihe 0 — Baseline ja turvaverkko

### Tavoite

Lukitaan nykyinen toimiva lähtötilanne ennen nimeämismuutoksia.

### Tehtävät

1. Varmista, että nykyinen `services/codesys/build/project.xml` syntyy clean buildillä.
2. Varmista, että gateway pystyy lukemaan nykyiset OPC UA -nodepolut ilman `BadNodeIdInvalid`-virheitä.
3. Tallenna lista gatewayn käyttämistä PLC-symboleista `services/gateway/opcua_nodes.js`-tiedoston perusteella.
4. Tee symbolikartta vanha nimi → tavoitenimi kaikille muutettaville POU-, UDT- ja mahdollisille GVL-symboleille.
5. Rajaa tuotantoa koskevat symbolit erilleen SIM-symboleista.

### Tuotos

- hyväksytty rename-matriisi
- vahvistettu nykyinen toimiva baseline

### Hyväksymiskriteerit

- PLCopenXML-build onnistuu
- gatewayn reset/init-ketju toimii nykyisillä nimillä
- rename-matriisi on hyväksytty ennen ensimmäistä refaktorointia

## Vaihe 0.5 — Vakiot ja GVL-attribuutti

### Tavoite

Korjataan GVL_JC_Constants-tiedoston ALL_CAPS-rikkeet ja lisätään `{attribute 'qualified_only'}`, ennen kuin varsinainen POU-rename aloitetaan. Tämä on pieni mutta laaja-vaikutteinen vaihe, koska nämä nimet esiintyvät lähes jokaisessa POUssa.

### Ongelma

Guide vaatii konstansseille muodon `ALL_CAPS_WITH_UNDERSCORES`. Seuraavat nimet rikkovat tätä sääntöä:

| Nykyinen | Tavoite | Esiintymissä |
|----------|---------|----------|
| `MIN_StationIndex` | `MIN_STATION_INDEX` | ~30 POUa |
| `MAX_StationIndex` | `MAX_STATION_INDEX` | ~30 POUa |
| `MAX_Transporters` | `MAX_TRANSPORTERS` | ~30 POUa |
| `MAX_Units` | `MAX_UNITS` | ~30 POUa |
| `MIN_WorkingArea` | `MIN_WORKING_AREA` | TWA_FB_CalcLimits |
| `AVOID_None` | `AVOID_NONE` | ~5 POUa |
| `AVOID_Passable` | `AVOID_PASSABLE` | ~5 POUa |
| `AVOID_Block` | `AVOID_BLOCK` | ~5 POUa |

### Tehtävät

1. Lisää `{attribute 'qualified_only'}` GVL_JC_Constants-tiedoston `VAR_GLOBAL CONSTANT` -lohkon ylle.
2. Nimeä yllä luetellut 8 vakiota uudelleen GVL_JC_Constants.st-tiedostossa.
3. Päivitä kaikki viittaukset näihin vakioihin kaikissa POUissa (VAR_EXTERNAL CONSTANT -lohkot ja käyttökohdat).
4. Päivitä `build_codesys_xml.py` tiedoston `CONST_VALUES`-dict vastaamaan uusia nimiä.

### Erikoisriski: VAR_EXTERNAL CONSTANT

Koska jokainen POU deklaroi käyttämänsä vakiot `VAR_EXTERNAL CONSTANT` -lohkossa, jokainen vakion uudelleennimeäminen vaatii päivityksen sekä deklaraatiossa että käyttöpaikoissa jokaisessa kyseistä vakiota käyttävässä POUssa. Tee tämä yksi vakio kerrallaan tai pienen loogisen ryhmän kerrallaan.

### Rajaus

- ei muutoksia GVL-runtime-muuttujiin
- ei muutoksia OPC UA -nodepolkuihin
- ei muutoksia UDT-kenttiin tai POU-blokkien nimiin

### Hyväksymiskriteerit

- PLCopenXML-build onnistuu
- vakioarvot eivät muutu, ainoastaan nimet
- kaikki POUt kääntyvät uusilla vakionimillä

## Vaihe 1 — POU-blokkien nimeäminen guideen

### Tavoite

Korjataan blokkityyppisäännöt ilman että kosketaan vielä julkisiin GVL-muuttujiin.

### Miksi tämä tehdään ensin

Tämä on suurin selkeä guide-poikkeama, mutta samalla ulkoisesti suhteellisen turvallinen muutos, koska function- ja function block -nimet eivät muodosta nykyisen gatewayn OPC UA -nodepolkuja.

### Tehtävät

1. Nimeä kaikki 22 functionia `FC_`-prefiksillisiksi.
2. Nimeä function blockit `FB_`-prefiksillisiksi.
3. Nimeä POU-tiedostot vastaamaan symboleita täsmälleen.
4. Päivitä kaikki sisäiset kutsupaikat ST-koodissa.
5. Päivitä mahdolliset dokumenttiviittaukset, joissa vanha blokkisymboli mainitaan toteutuksen nimenä.

### Täydellinen rename-matriisi — kaikki 22 funktiota

| Nykyinen | Uusi | Tiedostonimi |
|----------|------|--------------|
| `STC_CalcHorizontalTravel` | `FC_STC_CalcHorizontalTravel` | STC_CalcHorizontalTravel.st → FC_STC_CalcHorizontalTravel.st |
| `STC_CalcSchedule` | `FC_STC_CalcSchedule` | STC_CalcSchedule.st → FC_STC_CalcSchedule.st |
| `STC_CalcTransferTime` | `FC_STC_CalcTransferTime` | STC_CalcTransferTime.st → FC_STC_CalcTransferTime.st |
| `STC_CollectActiveBatches` | `FC_STC_CollectActiveBatches` | STC_CollectActiveBatches.st → FC_STC_CollectActiveBatches.st |
| `STC_CreateTasks` | `FC_STC_CreateTasks` | STC_CreateTasks.st → FC_STC_CreateTasks.st |
| `STC_DispatchTask` | `FC_STC_DispatchTask` | STC_DispatchTask.st → FC_STC_DispatchTask.st |
| `STC_ManualTask` | `FC_STC_ManualTask` | STC_ManualTask.st → FC_STC_ManualTask.st |
| `STC_NoTreatmentStates` | `FC_STC_NoTreatmentStates` | STC_NoTreatmentStates.st → FC_STC_NoTreatmentStates.st |
| `STC_ShiftSchedule` | `FC_STC_ShiftSchedule` | STC_ShiftSchedule.st → FC_STC_ShiftSchedule.st |
| `STC_SortTasks` | `FC_STC_SortTasks` | STC_SortTasks.st → FC_STC_SortTasks.st |
| `STC_SwapTasks` | `FC_STC_SwapTasks` | STC_SwapTasks.st → FC_STC_SwapTasks.st |
| `STC_TakeOut` | `FC_STC_TakeOut` | STC_TakeOut.st → FC_STC_TakeOut.st |
| `STC_TrackMoveTimes` | `FC_STC_TrackMoveTimes` | STC_TrackMoveTimes.st → FC_STC_TrackMoveTimes.st |
| `STC_UpdateUnitLocation` | `FC_STC_UpdateUnitLocation` | STC_UpdateUnitLocation.st → FC_STC_UpdateUnitLocation.st |
| `DEP_CalcIdleSlots` | `FC_DEP_CalcIdleSlots` | DEP_CalcIdleSlots.st → FC_DEP_CalcIdleSlots.st |
| `DEP_CalcOverlap` | `FC_DEP_CalcOverlap` | DEP_CalcOverlap.st → FC_DEP_CalcOverlap.st |
| `DEP_FitTaskToSlot` | `FC_DEP_FitTaskToSlot` | DEP_FitTaskToSlot.st → FC_DEP_FitTaskToSlot.st |
| `DEP_OverlapDelay` | `FC_DEP_OverlapDelay` | DEP_OverlapDelay.st → FC_DEP_OverlapDelay.st |
| `DEP_Sandbox` | `FC_DEP_Sandbox` | DEP_Sandbox.st → FC_DEP_Sandbox.st |
| `TSK_Analyze` | `FC_TSK_Analyze` | TSK_Analyze.st → FC_TSK_Analyze.st |
| `TSK_NoTreatment` | `FC_TSK_NoTreatment` | TSK_NoTreatment.st → FC_TSK_NoTreatment.st |
| `TSK_Resolve` | `FC_TSK_Resolve` | TSK_Resolve.st → FC_TSK_Resolve.st |

### Täydellinen rename-matriisi — kaikki 11 function blockia

| Nykyinen | Uusi | Huomio |
|----------|------|--------|
| `STC_FB_MainScheduler` | `FB_STC_MainScheduler` | — |
| `STC_FindTransporter` | `FB_STC_FindTransporter` | Ei FB_-prefiksiä nimessä, on silti FUNCTION_BLOCK |
| `DEP_FB_Scheduler` | `FB_DEP_Scheduler` | — |
| `TSK_FB_Scheduler` | `FB_TSK_Scheduler` | — |
| `TWA_FB_CalcLimits` | `FB_TWA_CalcLimits` | — |
| `SIM_FB_ClearConfig` | `FB_SIM_ClearConfig` | SIM-kerros |
| `SIM_FB_EventQueue` | `FB_SIM_EventQueue` | SIM-kerros |
| `SIM_FB_MainCycle` | `FB_SIM_MainCycle` | SIM-kerros |
| `SIM_FB_RunTasks` | `FB_SIM_RunTasks` | SIM-kerros |
| `SIM_FB_XMotion` | `FB_SIM_XMotion` | SIM-kerros |
| `SIM_FB_ZMotion` | `FB_SIM_ZMotion` | SIM-kerros |

### Rajaus

- ei muutoksia GVL-muuttujiin
- ei muutoksia OPC UA -nodepolkuihin
- ei muutoksia UDT-kenttiin

### Hyväksymiskriteerit

- kaikki ST-viittaukset kääntyvät uusilla blokkien nimillä
- PLCopenXML-build onnistuu
- gateway toimii kuten ennen, koska julkiset nodepolut eivät muutu

## Vaihe 2 — UDT-tasoinen viimeistely

### Tavoite

Korjataan auditissa havaitut yksittäiset UDT-poikkeamat ilman laajaa data-mallin uudelleennimeämistä.

### Tehtävät

1. Nimeä `UDT_TaskArea` → `UDT_TaskAreaType`.
   - Päivitä tiedostonimi `UDT_TaskArea.st` → `UDT_TaskAreaType.st`.
   - Päivitä kaikki viittaukset tähän tyyppiin ST-koodissa (`UDT_TransporterType.st` ja kaikki POUt).
2. Yhtenäistä `UDT_JC_TskStageType.station`-kentän kirjoitusasu.
   - UDT-tiedostossa kenttä on `Station` (PascalCase, oikein), mutta ST-koodissa käytetään kirjoitusasua `.station` (lowercase).
   - IEC 61131-3 -tunnisteet ovat case-insensitive, joten tämä ei ole toiminnallinen virhe, mutta se rikkoo guiden tyylivaatimusta.
   - Päivitä kaikki esiintymät muodossa `.station` → `.Station` niissä tiedostoissa joissa se esiintyy (STC_CalcSchedule.st, STC_CreateTasks.st, SIM_FB_ClearConfig.st, DEP_FB_Scheduler.st).
3. Tarkista samalla, että kaikki UDT-tiedostonimet vastaavat tarkasti tyyppinimiä.

### Rajaus

- ei muutoksia struct-kenttien nimiin laajemmin, ellei auditissa ole selkeää guide-poikkeamaa
- ei muutoksia julkisiin GVL-muuttujiin

### Hyväksymiskriteerit

- kaikki tyyppiviittaukset kääntyvät
- PLCopenXML-build onnistuu
- gatewayn lukemat eivät muutu tämän vaiheen vuoksi

## Vaihe 3 — Program-tason nimen yhtenäistäminen

### Tavoite

Korjataan ohjelman nimi ja tiedostonimi guideen sopivaksi vasta sen jälkeen kun blokkinimet on vakautettu.

### Tehtävät

1. Päätä lopullinen ohjelmanimi, esimerkiksi `Main`.
2. Nimeä `PLC_PRG` ja vastaava tiedosto tähän muotoon.
3. Päivitä build-polkujen ja importin kannalta tarvittavat viittaukset.

### Miksi tämä on oma vaiheensa

Program on koko projektin juurisymboli. Vaikka muutos on teknisesti pieni, se vaikuttaa koko importoitavaan kokonaisuuteen, joten sitä ei pidä sekoittaa muiden renamejen joukkoon.

### Hyväksymiskriteerit

- build ja import onnistuvat uudella ohjelmanimellä
- ohjelman juurikäytös ei muutu

## Vaihe 4 — POU-muuttujien nimeäminen guideen

### Tavoite

Muutetaan kaikki POU-sisäiset muuttujat guiden prefiksi + PascalCase -malliin.

### Miksi tämä tehdään vasta blokkien jälkeen

Tämä vaihe koskee suurinta määrää rivejä, mutta pienintä ulkoista rajapintaa. Kun blokkien nimet ovat jo vakioitu, muuttujien rename voidaan tehdä tiedosto kerrallaan ilman että symbolitason päätökset elävät enää samalla.

### Ali-vaiheet

#### 4A — VAR_INPUT / VAR_OUTPUT / VAR_IN_OUT

Esimerkit:

| Nykyinen | Uusi |
|----------|------|
| `i_time_s` | `iTimeS` |
| `i_unit` | `iUnit` |
| `io_schedule` | `ioSchedule` |
| `o_tsk_phase` | `oTskPhase` |

#### 4B — VAR-lokaalit

Esimerkit:

| Nykyinen | Uusi |
|----------|------|
| `turn` | `vTurn` |
| `skip_cnt` | `vSkipCount` |
| `cur_stage` | `vCurStage` |
| `chosen_stn` | `vChosenStation` |

#### 4C — FB-instanssit

Esimerkit:

| Nykyinen | Uusi |
|----------|------|
| `tsk_sched` | `vFB_TskScheduler` |
| `dep_sched` | `vFB_DepScheduler` |
| `twa_calc` | `vFB_TwaCalcLimits` |
| `sim_main` | `vFB_SimMainCycle` |
| `main_scheduler` | `vFB_MainScheduler` |

#### 4D — Tilapäiset ja apumuuttujat

Esimerkit:

| Nykyinen | Uusi |
|----------|------|
| `i` | `tIndex` tai `vIndex` käyttötarkoituksen mukaan |
| `p` | `tCandidateIndex` |
| `tmp_move` | `vTmpMove` |

### Toteutustapa

- yksi POU-tiedosto per commit tai pieni looginen blokkiryhmä per commit
- aloita tuotantokriittisistä POUista: STC, TSK, DEP
- siirrä SIM-POUt tämän jälkeen

### Hyväksymiskriteerit

- tiedosto kääntyy renamejen jälkeen
- funktionaalinen käytös ei muutu
- PLCopenXML-build onnistuu jokaisen alavaiheen jälkeen

## Vaihe 5 — GVL-muuttujien nimeäminen guideen (CODESYS)

### Arkkitehtuuri ja tavoite

CODESYS käyttää `VAR_GLOBAL`-muuttujia GVL-tiedostoissa. TIA Portal ei tue GVL-rakennetta — siellä samat tiedot tallennetaan Data Block (DB) -muotoon. **Nimeämiskäytännön pitää noudattaa guidea molemmissa ympäristöissä.**

Guide ei määrittele `g_`-prefiksiä globaaleille muuttujille. Guide määrittelee:
- Struct-kentät: PascalCase
- Lokaalit: `v`-prefix + PascalCase
- Vakiot: ALL_CAPS

GVL-muuttujat ovat rakenteellisesti lähimpänä struct-kenttiä (ne ovat DB-kenttiä TIA-maailmassa). **Tavoitenimi on PascalCase ilman prefiksiä.**

### Rename-matriisi — GVL_JC_Scheduler

| Nykyinen | Tavoite | OPC UA -muutos |
|----------|---------|----------------|
| `g_batch` | `Batch` | kyllä |
| `g_unit` | `Unit` | kyllä |
| `g_schedule` | `Schedule` | kyllä |
| `g_task` | `Task` | kyllä |
| `g_transporter` | `Transporter` | kyllä |
| `g_move` | `Move` | kyllä |
| `g_ntt` | `Ntt` | kyllä |
| `g_manual_task` | `ManualTask` | kyllä |
| `g_dispatched_task` | `DispatchedTask` | kyllä |
| `g_event` | `Event` | kyllä |
| `g_event_ack_seq` | `EventAckSeq` | kyllä |
| `g_event_pending` | `EventPending` | sisäinen |
| `g_event_pending_valid` | `EventPendingValid` | sisäinen |
| `g_cmd_code` | `CmdCode` | kyllä |
| `g_cmd_param` | `CmdParam` | kyllä |
| `g_production_queue` | `ProductionQueue` | kyllä |
| `g_time_s` | `TimeS` | kyllä |
| `g_time_sync` | `TimeSync` | kyllä |
| `g_time_100ms` | `Time100ms` | sisäinen |
| `g_time_offset` | `TimeOffset` | sisäinen |
| `g_tsk_stable` | `TskStable` | kyllä |
| `g_conflict_resolved` | `ConflictResolved` | sisäinen |
| `g_dep_activated` | `DepActivated` | kyllä |
| `g_dep_overlap` | `DepOverlap` | kyllä |
| `g_dep_pending` | `DepPending` | sisäinen |
| `g_dep_idle_slot` | `DepIdleSlot` | sisäinen |
| `g_dep_waiting` | `DepWaiting` | sisäinen |
| `g_dep_waiting_count` | `DepWaitingCount` | kyllä |
| `g_dep_wk_schedule` | `DepWkSchedule` | sisäinen |
| `g_dep_wk_task` | `DepWkTask` | sisäinen |
| `g_dep_wk_program` | `DepWkProgram` | sisäinen |
| `g_dep_wk_batch` | `DepWkBatch` | sisäinen |
| `g_sim_trans` | `SimTrans` | kyllä |
| `g_sim_ui_schedule` | `SimUiSchedule` | kyllä |
| `g_sim_ui_task` | `SimUiTask` | kyllä |
| `g_sim_ui_wait_reason` | `SimUiWaitReason` | kyllä |
| `g_sim_ui_wait_unit` | `SimUiWaitUnit` | kyllä |
| `g_station_occupancy` | `StationOccupancy` | sisäinen |
| `g_actual_move` | `ActualMove` | sisäinen |
| `g_sched_dbg_*` | `SchedDbg*` (PascalCase) | kyllä |
| `g_dbg_tsk_*` | `DbgTsk*` (PascalCase) | kyllä |

### Rename-matriisi — GVL_JC_Parameters

| Nykyinen | Tavoite | OPC UA -muutos |
|----------|---------|----------------|
| `g_transporter` | `Transporter` | kyllä |
| `g_unit` | `Unit` | kyllä |
| `g_batch` | `Batch` | kyllä |
| `Stations` | `Stations` | ei muutosta |
| `g_avoid_status` | `AvoidStatus` | kyllä |
| `CountStations` | `CountStations` | ei muutosta |
| `Transporters` | `Transporters` | ei muutosta |
| `TreatmentPrograms` | `TreatmentPrograms` | ei muutosta |

### Vaiheen rakenne

Tämä vaihe tehdään kahdessa osassa:

**5A — PLC-puoli (CODESYS):**
1. Nimeä GVL_JC_Scheduler.st ja GVL_JC_Parameters.st muuttujat
2. Päivitä kaikki VAR_EXTERNAL-viittaukset kaikissa POUissa
3. Päivitä `opcua_nodes.js` samanaikaisesti — ei erillistä vaihetta
4. Build + deploy + gateway-testi

**5B — TIA Portal -muunto (erillinen projekti):**
- GVL-rakenne muutetaan DB-rakenteeksi
- Tätä **ei voida testata CODESYS-ympäristössä**
- Nimeäminen on kuitenkin jo guidessa kun 5A on tehty

### Hyväksymiskriteerit (5A)

- PLCopenXML-build onnistuu
- `opcua_nodes.js` päivitetty vastaamaan uusia nimiä
- gateway reset/init/luku/kirjoitus toimivat uusilla nimillä
- OPC UA -yhteys ei katkea

## Vaihe 6 — Headerit, kommentit ja dokumentaation viimeistely

### Tavoite

Yhtenäistetään tiedostojen headerit ja kommentointityyli guiden mukaiseksi vasta kun symbolit ovat vakioituneet.

### Miksi tämä jätetään loppuun

Header- ja kommenttimuutokset tuottavat paljon diffiä mutta eivät pienennä teknistä riskiä. Siksi ne kannattaa tehdä vasta lopuksi, kun varsinainen naming-migraatio on valmis.

### Tehtävät

1. päivitä POU-headerit guiden standardimuotoon
2. päivitä UDT-headerit guiden standardimuotoon
3. tarkista section divider -käytäntö ja kommenttien yhdenmukaisuus

### Hyväksymiskriteerit

- ei toiminnallisia muutoksia
- build pysyy puhtaana

## Toiminnallisuuden säilyttäminen

Nimeämismigraatio ei saa rikkoa nykyistä toiminnallisuutta. Seuraavat guide-säännöt koskevat koodirakennetta pelkän nimistön sijaan, ja niiden toteutuminen pitää tarkistaa jokaisessa muutetussa POUssa.

### BOOL-syötteillä ei oletusarvo TRUE

Guide: "BOOL inputs must never default to TRUE."

Tia Portal ei tue `VAR_INPUT`-oletusarvoja ja käyttää aina `FALSE`. Jos CODESYS-koodissa on `iEnable : BOOL := TRUE`, TIA-versiossa se on `FALSE`, mikä muuttaa lohkon käyttäytymistä. Kaikki muutetut VAR_INPUT BOOL -muuttujat pitää tarkistaa: oletusarvo `FALSE` tai ei oletusarvoa.

### Yksi kutsu per FB-instanssi per sykli

Guide: "Every function block instance must be called exactly ONCE per scan cycle."

Jos FB:tä kutsutaan useissa `IF/ELSE`-haaroissa, se prosessoi sisäisen tilansa useaan kertaan ja käyttäytyy virheellisesti. Vaiheessa 4 (FB-instanssien uudelleennimeäminen) tarkista samalla, ettei yksikään instanssi saa kutsuja useammasta paikasta.

Yleisimmät riskikohdat: `SIM_FB_RunTasks`, `SIM_FB_XMotion`, `SIM_FB_ZMotion`.

### Maksimihaarukoinnin syvyys: 4 tasoa

Guide: "Maximum depth for function blocks inside function blocks is four layers."

Nykyinen kutsuhierarkia arviolta:
```
PLC_PRG (Program)
  └─ FB_SIM_MainCycle / FB_STC_MainScheduler   (taso 1)
      └─ FB_TSK_Scheduler / FB_DEP_Scheduler   (taso 2)
          └─ FC_STC_CalcSchedule (+ muita)      (taso 3)
              └─ FC_STC_CalcHorizontalTravel    (taso 4 — maksimi)
```

Jos jossain POUssa on syvempi haarukointi, se pitää tasapäistää ennen kuin se dokumentoidaan guide-yhteensopivana.

### INT-ylivuoto aikakertolaaskuissa

Guide: "Never multiply an INT parameter by 1000 (or any large factor) in INT arithmetic."

Koodissa käytetään paljon aikamuunnoksia (`* 1000`, `/ 1000`, `REAL_TO_LINT` jne.). Tarkista erityisesti ajanlaskenta-POUt (STC_CalcSchedule, STC_CalcTransferTime), ettei `INT`-tyypin kertolasku ylivuoda ennen tyyppimuunnosta. Oikea muoto on ensin `INT_TO_DINT` ja vasta sitten kertolasku.

### Named parameters IEC-standardifunktioille

Guide: "TIA Portal requires named parameters for IEC standard functions."

Koodin `SEL(...)`, `LIMIT(...)`, `MUX(...)`, `MAX(...)` ja `MIN(...)` -kutsut pitää käyttää nimettyjä parametreja. Tarkista tämä erityisesti vaiheessa 1 muutetuista POUista, koska koodigenerointitavat voivat vaihdella.

### VAR_EXTERNAL ja TIA Portal -yhteensopivuus

Guide: "Never use VAR_EXTERNAL or VAR_EXTERNAL CONSTANT in source ST files."

Nykyinen koodi käyttää `VAR_EXTERNAL CONSTANT` ja `VAR_EXTERNAL` kaikissa POUissa. Tämä toimii CODESYS-ympäristössä mutta ei TIA Portal -tuonnissa. VAR_EXTERNAL-poisto on massiivinen arkkitehtuurimuutos, jota ei tehdä tässä migraatiossa. Kirjataan kuitenkin avoimeksi kohdaksi tulevaa TIA-migraatiota varten.

## Toteutusjärjestys

Suositeltu järjestys on tämä:

1. Vaihe 0: baseline + rename-matriisi
2. Vaihe 0.5: vakiot ALL_CAPS + qualified_only
3. Vaihe 1: functionit ja function blockit (täydellinen matriisi)
4. Vaihe 2: UDT-poikkeamat + station-kenttä
5. Vaihe 3: program-nimi
6. Vaihe 4: POU-muuttujat tiedosto kerrallaan
7. Vaihe 5: julkiset globaalit vain erillisellä yhteensopivuusratkaisulla
8. Vaihe 6: headerit ja kommentit

Toiminnallisuuden säilyttäminen -tarkistukset tehdään vaiheissa 1–4 jokaisen tiedoston kohdalla.

Tämä järjestys minimoi todennäköisyyden sille, että uusi naming-muutos rikkoo gatewayn, OPC UA -rajapinnan tai CODESYS-importin yhtä aikaa.

## Validointistrategia

Jokaisen vaiheen jälkeen tehdään vähintään nämä tarkistukset:

1. `python3 services/codesys/build_codesys_xml.py`
2. PLCopenXML-tiedoston syntyminen ilman parse- tai nimeämisvirheitä
3. gatewayn perus-OPC-UA-luku onnistuu
4. reset/init-ketju toimii, jos vaihe koskee julkisia nodepolkuja
5. tarvittaessa manuaalinen CODESYS-importti ja login/download

Jos vaihe koskee vain POU-blokkeja tai sisäisiä muuttujia, minimivalidointi on build + import. Jos vaihe koskee julkisia globaaleja, tarvitaan lisäksi gatewayn oikea luku- ja kirjoituskäytös.

## Riskiluokitus

| Vaihe | Riskitaso | Pääsyy |
|-------|-----------|--------|
| 0 | Matala | Ei vielä tuotantorenamea |
| 0.5 | Korkea | 8 vakiota viitattuna lähes jokaisessa POUssa + build_codesys_xml.py |
| 1 | Keskitaso | 33 symbolia, laaja sisäinen kutsuverkko, ei OPC UA -vaikutusta |
| 2 | Matala | Pieni ja rajattu tyyppimuutos |
| 3 | Keskitaso | Ohjelman juurisymboli muuttuu |
| 4 | Keskitaso | Suuri määrä rivejä, mutta vähän ulkoisia kytkentöjä |
| 5 | Korkea | Suora kytkentä gatewayn OPC UA -nodepolkuihin |
| 6 | Matala | Kosmeettinen viimeistely |

## Ei tehdä tässä migraatiossa

Näitä ei pidä sotkea samaan projektiin ilman erillistä päätöstä:

1. toiminnalliset algoritmimuutokset scheduleriin
2. SIM-arkkitehtuurin uudelleensuunnittelu
3. gatewayn API-muutokset, jotka eivät liity nimeämiseen
4. tuotanto- ja simulaatiologiikan yhdistäminen tai uudelleenjako
5. massiivinen yhden commitin rename koko `services/codesys/`-hakemistoon

## Lopullinen suositus

Siirtymä kannattaa tehdä kahdessa pääaallossa:

- ensin sisäinen naming-migraatio, joka ei muuta julkisia OPC UA -nimiä
- vasta sen jälkeen mahdollinen julkisten globaalien naming-migraatio yhteensopivuuskerroksen kautta

Tämä on auditoinnin perusteella ainoa hallittu tapa päästä PLC-guiden mukaiseen tuotantoversioon ilman että järjestelmä rikkoutuu samasta syystä kuin aiemmassa epäonnistuneessa nimeämismuutoksessa.

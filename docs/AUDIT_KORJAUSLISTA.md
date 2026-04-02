# Audit-korjauslista

Tama dokumentti kokoaa yhteen [AUDIT_REPORT.md](./AUDIT_REPORT.md)-raportin jalkeisen teknisen tarkistuksen tulokset.

Tavoite ei ole toistaa audit-raporttia sellaisenaan, vaan erottaa:

- oikeat korjaustarpeet
- matalan prioriteetin yllapidettavyysasiat
- auditin virheelliset tai vanhentuneet havainnot

## 1. Korjaa heti

### 1.1 Task queue -kokojen ristiriita

**Mita korjataan**

Yhtenaiset jonokoot koko scheduler-ketjuun.

**Miksi**

Tassa on selkein rakenteellinen bugiriski.

- [services/codesys/GVLs/GVL_JC_Constants.st](../services/codesys/GVLs/GVL_JC_Constants.st) maarittaa `MAX_TASK_QUEUE := 60`
- [services/codesys/UDTs/UDT_JC_TskQueueType.st](../services/codesys/UDTs/UDT_JC_TskQueueType.st) maarittaa `Queue : ARRAY[1..30]`
- [services/codesys/POUs/STC_CreateTasks.st](../services/codesys/POUs/STC_CreateTasks.st) kirjoittaa jonoon ehdolla `qi <= MAX_TASK_QUEUE`

Jos toteutus olettaa 60 paikkaa mutta rakenne tarjoaa 30, tuloksena on **varma out-of-bounds -kirjoitus** jos tehtavia kertyy yli 30. CODESYS ei tee automaattista rajatarkistusta, joten muistin ylikirjoitus on mahdollinen.

**Toimenpide**

Paata yksi totuuslahde:

1. joko queue-koko on oikeasti 60 ja UDT korjataan siihen
2. tai queue-koko on oikeasti 30 ja vakio palautetaan siihen

**Suositus**

Korjaa tama ennen muita scheduler-refaktorointeja.

---

### 1.2 Station-offset `100` -> `MIN_StationIndex`

**Mita korjataan**

Korvataan semanttiset kovakoodatut `100`-arvot vakiolla `MIN_StationIndex`.

**Miksi**

Tama on todellinen yllapidettavyysongelma. Nykyinen toteutus toimii, mutta lukitsee logiikan tiettyyn asemointi-indeksiin.

Esimerkkeja:

- [services/codesys/POUs/STC_DispatchTask.st](../services/codesys/POUs/STC_DispatchTask.st)
- [services/codesys/POUs/STC_CalcSchedule.st](../services/codesys/POUs/STC_CalcSchedule.st)
- [services/codesys/POUs/TSK_FB_Scheduler.st](../services/codesys/POUs/TSK_FB_Scheduler.st)
- [services/codesys/POUs/TSK_Analyze.st](../services/codesys/POUs/TSK_Analyze.st)
- [services/codesys/POUs/STC_TrackMoveTimes.st](../services/codesys/POUs/STC_TrackMoveTimes.st)
- [services/codesys/POUs/STC_CalcHorizontalTravel.st](../services/codesys/POUs/STC_CalcHorizontalTravel.st)
- [services/codesys/POUs/STC_CalcTransferTime.st](../services/codesys/POUs/STC_CalcTransferTime.st)
- [services/codesys/POUs/TSK_NoTreatment.st](../services/codesys/POUs/TSK_NoTreatment.st)

**Toimenpide**

Korvaa ainakin seuraavat muodot:

- `x - 100` -> `x - MIN_StationIndex`
- `x >= 100` -> `x >= MIN_StationIndex`
- `x < 100` -> `x < MIN_StationIndex`

**Huomio**

Kaikkia numeroarvoja ei pidä korvata mekaanisesti. Jos luku liittyy kiinteasti UDT-dimension kokoon eika asemadomainiin, korvaus voi olla vaarin.

---

## 2. Korjaa seuraavaksi

### 2.1 Kovakoodatut loop-rajat, jotka oikeasti riippuvat vakioista

**Mita korjataan**

Poistetaan aidot magic number -rajat niista kohdista, joissa ne kuvaavat domain-rajoja.

**Miksi**

Auditin havainto oli tassa osittain oikea. Osa luvuista on aidosti kovakoodattuja, osa taas heijastaa tarkoituksella kiinteaa taulukkorakennetta.

**Aidot korjauskohteet**

- [services/codesys/POUs/TSK_FB_Scheduler.st](../services/codesys/POUs/TSK_FB_Scheduler.st) `FOR bi := 1 TO 50`
- [services/codesys/POUs/STC_CalcSchedule.st](../services/codesys/POUs/STC_CalcSchedule.st) `FOR stg := 0 TO 30`
- [services/codesys/POUs/DEP_FB_Scheduler.st](../services/codesys/POUs/DEP_FB_Scheduler.st) `FOR qi := 1 TO 30`
- [services/codesys/POUs/SIM/SIM_FB_ClearConfig.st](../services/codesys/POUs/SIM/SIM_FB_ClearConfig.st) `FOR j := 0 TO 30`

**Ei korjata sokkona**

- [services/codesys/POUs/DEP_CalcOverlap.st](../services/codesys/POUs/DEP_CalcOverlap.st) `FOR station_idx := 0 TO 200`

Tama ei ole pelkka magic number, koska kohderakenne [services/codesys/UDTs/UDT_JC_DepOverlapType.st](../services/codesys/UDTs/UDT_JC_DepOverlapType.st) on maaritelty alueelle `0..200`. Auditin suositus korvata tama vakiolla `MAX_StationIndex` (130) **rikkoisi koodin**, koska Overlap-taulukko on tarkoituksella laajempi kuin aktiivinen asema-alue.

- [services/codesys/POUs/DEP_FB_Scheduler.st](../services/codesys/POUs/DEP_FB_Scheduler.st) `FOR qi := 1 TO 30`

Tama heijastaa `Queue`-taulukon todellista kokoa (`ARRAY[1..30]`), ei `MAX_TASK_QUEUE / 2`:ta. Auditin ehdotus kayttaa `MAX_TASK_QUEUE / 2` piilottaisi oikean semantiikan ja on harhaan johtava niin kauan kuin queue-kokoristiriita (kohta 1.1) on avoin.

**Toimenpide**

Tee ensin erottelu:

1. domain-vakioihin kuuluvat rajat
2. kiintean rakenteen rajat

Korjaa vain ensimmainen ryhma yleiskayttoisiksi vakioiksi.

---

### 2.2 VAR_IN_OUT-taulukkokokojen riippuvuuksien dokumentointi tai keskittaminen

**Mita korjataan**

Selvennetaan tai keskitetaan ne kohdat, joissa `VAR_IN_OUT` kayttaa kiinteita kokoja `10` ja `3`.

**Miksi**

Auditin havainto on oikeansuuntainen, mutta ongelma ei rajoitu vain muutamaan tiedostoon. Samat riippuvuudet toistuvat useissa FC:issa.

Esimerkkeja:

- [services/codesys/POUs/STC_CalcSchedule.st](../services/codesys/POUs/STC_CalcSchedule.st)
- [services/codesys/POUs/STC_CreateTasks.st](../services/codesys/POUs/STC_CreateTasks.st)
- [services/codesys/POUs/STC_ShiftSchedule.st](../services/codesys/POUs/STC_ShiftSchedule.st)
- [services/codesys/POUs/TSK_Resolve.st](../services/codesys/POUs/TSK_Resolve.st)
- [services/codesys/POUs/DEP_CalcIdleSlots.st](../services/codesys/POUs/DEP_CalcIdleSlots.st)
- [services/codesys/POUs/DEP_FitTaskToSlot.st](../services/codesys/POUs/DEP_FitTaskToSlot.st)
- [services/codesys/POUs/DEP_Sandbox.st](../services/codesys/POUs/DEP_Sandbox.st)
- [services/codesys/POUs/DEP_OverlapDelay.st](../services/codesys/POUs/DEP_OverlapDelay.st)
- [services/codesys/POUs/STC_SortTasks.st](../services/codesys/POUs/STC_SortTasks.st)
- [services/codesys/POUs/STC_SwapTasks.st](../services/codesys/POUs/STC_SwapTasks.st)
- [services/codesys/POUs/TSK_NoTreatment.st](../services/codesys/POUs/TSK_NoTreatment.st)
- [services/codesys/POUs/TSK_Analyze.st](../services/codesys/POUs/TSK_Analyze.st)
- [services/codesys/POUs/STC_FindTransporter.st](../services/codesys/POUs/STC_FindTransporter.st)
- [services/codesys/POUs/SIM/SIM_FB_RunTasks.st](../services/codesys/POUs/SIM/SIM_FB_RunTasks.st)

Lisaa taustaa antaa myos [services/codesys/build_codesys_xml.py](../services/codesys/build_codesys_xml.py), joka korvaa symbolisia rajoja numeerisiksi XML-generoinnissa.

**Toimenpide**

Lyhyella tahtaimella:

- lisaa kommentti, etta kokojen on vastattava globaaleja vakioita

Pidemmalla tahtaimella:

- keskita taulukkokoot yhteen generoituun lahteeseen tai rakenteeseen

---

## 3. Nopeat siivouskorjaukset

### 3.1 Oikeat sisennys- ja muotoiluvirheet

**Mita korjataan**

Korjataan ne muotoiluvirheet, jotka audit raportoi oikein.

**Miksi**

Nama eivat muuta logiikkaa, mutta heikentavat luettavuutta ja vaikeuttavat jatkokehitysta.

Esimerkkeja:

- [services/codesys/POUs/TSK_FB_Scheduler.st](../services/codesys/POUs/TSK_FB_Scheduler.st)
- [services/codesys/POUs/TSK_Resolve.st](../services/codesys/POUs/TSK_Resolve.st)
- [services/codesys/POUs/STC_CreateTasks.st](../services/codesys/POUs/STC_CreateTasks.st)
- [services/codesys/POUs/SIM/SIM_FB_RunTasks.st](../services/codesys/POUs/SIM/SIM_FB_RunTasks.st)

**Toimenpide**

Tee nama samassa siivousmuutoksessa, mutta pidä erillaan toiminnallisista korjauksista.

---

### 3.2 Vanhentuneiden kommenttien siivous

**Mita korjataan**

Poistetaan tai neutraalisoidaan kommentit, jotka viittaavat poistettuun toteutukseen.

**Miksi**

Ne eivat riko logiikkaa, mutta voivat johtaa harhaan seuraavaa lukijaa.

Esimerkit:

- [services/codesys/POUs/TSK_FB_Scheduler.st](../services/codesys/POUs/TSK_FB_Scheduler.st) muutosloki
- [services/codesys/POUs/TSK_FB_Scheduler.st](../services/codesys/POUs/TSK_FB_Scheduler.st) `justActivated normalization removed` -kommentti

**Toimenpide**

Sailyta olennainen toteutuksen intentio, mutta poista viittaukset vanhoihin sisaisiin vaiheisiin ja muuttujiin.

---

## 4. Backlog-kohteet

### 4.1 Waiting batch -haku station 114:sta

**Mita korjataan**

Nykyinen yhden lastausaseman kovakoodaus vaihdetaan dynaamiseen waiting batch -hakuun.

**Miksi**

Tama ei nayta olevan bugi nykyisessa setupissa. Se on tietoinen rajaus, joka muuttuu ongelmaksi vasta kun lastausasemia on useita.

Viite:

- [services/codesys/POUs/STC_CollectActiveBatches.st](../services/codesys/POUs/STC_CollectActiveBatches.st)

**Toimenpide**

Toteuta vasta, kun usean lastausaseman logiikka otetaan oikeasti kayttoon.

---

## 5. Asiat, joita ei kannata korjata auditin perusteella

### 5.1 UDT-kommentointi ei ole auditin kuvaamalla tavalla puutteellinen

**Miksi tama on tarkea todeta**

Audit-vaitteen mukaan UDT-tiedostoissa olisi vain headerit ilman kenttakohtaisia selityksia. Nykyinen koodi ei tue tata johtopaatosta.

Vastanaytteita:

- [services/codesys/UDTs/UDT_UnitType.st](../services/codesys/UDTs/UDT_UnitType.st)
- [services/codesys/UDTs/UDT_JC_TskScheduleType.st](../services/codesys/UDTs/UDT_JC_TskScheduleType.st)
- [services/codesys/UDTs/UDT_JC_TskTaskType.st](../services/codesys/UDTs/UDT_JC_TskTaskType.st)

**Johtopaatos**

UDT-kommentointia ei tarvitse nostaa erilliseksi korjausprojektiksi auditin perusteella.

---

### 5.2 SIM_FB_RunTasks-headerista ei puutu yritys- tai tekijatietoja

**Miksi tama on tarkea todeta**

Audit raportoi taman virheellisesti. Header-tyyli poikkeaa muista tiedostoista, mutta sisalto ei puutu.

Viite:

- [services/codesys/POUs/SIM/SIM_FB_RunTasks.st](../services/codesys/POUs/SIM/SIM_FB_RunTasks.st)

**Johtopaatos**

Jos tiedostoa siivotaan, syy on tyylin yhdenmukaistus tai tiivistetty `VAR_EXTERNAL`-rivi, ei puuttuvat metatiedot.

---

### 5.3 an_/rs_-prefiksit eivat ole vakava ongelma

**Miksi tama on tarkea todeta**

Audit nosti taman nimeamishavaintona. Se on korkeintaan pieni luettavuusasia, ei tekninen ongelma.

Tiedostossa on jo ryhmittelyt:

- `Analyze result cache`
- `Resolve result cache`

Viite:

- [services/codesys/POUs/TSK_FB_Scheduler.st](../services/codesys/POUs/TSK_FB_Scheduler.st)

**Johtopaatos**

Ei priorisoida ennen toiminnallisia korjauksia.

---

## 6. Suositeltu toteutusjarjestys

1. Korjaa task queue -kokojen ristiriita.
2. Korvaa semanttiset `100`-offsetit vakiolla `MIN_StationIndex`.
3. Siivoa aidot kovakoodatut loop-rajat.
4. Dokumentoi tai keskita `VAR_IN_OUT`-kokojen riippuvuudet.
5. Tee lopuksi kommentti- ja muotoilusiivous.

## 7. Yhteenveto

Audit-raportti on hyodyllinen yllapidettavyyslistana, mutta sita ei pidä käyttää sellaisenaan toteutusjonona.

Tarkeimmat oikeat korjaukset ovat:

- task queue -kokojen ristiriita
- station-offsetin kovakoodaus
- aidot domain-vakioihin liittyvat magic numberit

Matalamman prioriteetin asiat ovat:

- sisennys- ja tyylisiivous
- vanhentuneet kommentit

Auditin virheelliset tai vanhentuneet kohdat liittyvat ainakin:

- UDT-kommentoinnin puutteisiin
- SIM-headerin puuttuviin metatietoihin
- joihinkin liian suoraviivaisesti tulkittuihin magic number -havaintoihin
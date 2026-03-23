# CalcSchedule JS → ST Validointi

**Päivämäärä**: 23.3.2026  
**Päivitetty**: 23.3.2026  
**Vertailu**: `transporterTaskScheduler.js :: calculateBatchSchedule()` vs `TSK_FB_CalcSchedule.st`  
**Kutsukonteksti**: `taskScheduler.js :: tick() phase 1001..1899` vs `TSK_FB_Scheduler.st :: phase 1001..1000+N`

---

## 1. Yleiskuvaus

JS-versio (5053 riviä `transporterTaskScheduler.js` + 2107 riviä `taskScheduler.js`) on konvertoitu ST-versioon (373 riviä `TSK_FB_CalcSchedule.st`). Konversio on pääosin rakenteellisesti onnistunut. Validoinnissa löytyi **7 havaintoa**, joista **5 korjattu** ja **2 todettiin ei-vioiksi**. Kaikki havainnot käsitelty.

---

## 2. Yhteenveto vioista

| # | Vika | Vakavuus | Tila | Tiedostot |
|---|---|---|---|---|
| ~~1~~ | ~~Stage 0 käsittelyaika = 0~~ | ~~KRIITTINEN~~ | ✅ **KORJATTU** | TSK_FB_CalcSchedule.st prepend-lohko |
| ~~2~~ | ~~Ensimmäisen stagen ehto ei toimi stage 0:lle~~ | ~~KRIITTINEN~~ | ✅ **KORJATTU** | (sidottu vikaan 1) |
| ~~3~~ | ~~forceEntryTime puuttuu kokonaan~~ | ~~KRIITTINEN~~ | ✅ **EI VIKA** | Kuollut koodi JS:ssä — `_forceEntryTime` ei koskaan asetettu |
| ~~4~~ | ~~justActivated-normalisointi puuttuu~~ | ~~KRIITTINEN~~ | ✅ **KORJATTU** | TSK_FB_Scheduler.st phase 1001 |
| ~~5~~ | ~~Nostimen valinta eri logiikalla (task_area vs batch location)~~ | ~~KORKEA~~ | ✅ **KORJATTU** | TSK_FB_Scheduler.st phase 1001 |
| ~~6~~ | ~~Stage 90 ohittaminen puuttuu schedulerista~~ | ~~EI VIKA~~ | ✅ **EI VIKA** | Käsitelty State-mekanismilla |
| ~~7~~ | ~~calc_s := INT_TO_REAL(CurStage) — roskamuuttuja~~ | ~~MATALA~~ | ✅ **KORJATTU** | TSK_FB_CalcSchedule.st |

> **Huom VIKA 4**: Aluksi arvioitiin "EI VIKA" (DEP pending hoitaa), mutta tarkemmin tutkittuna JS:n `justActivated`-normalisointi (elapsed-ajan vähennys) puuttui ST:stä. Korjattu TSK_FB_Scheduler.st phase 1001:een.

> **Huom VIKA 6**: ST ei käytä stage 90:tä. Sen sijaan `g_batch[].State` (NOT_PROCESSED=0, IN_PROCESS=1, PROCESSED=2) hallitsee erän tilaa. `STC_FB_CollectActiveBatches(i_mode:=0)` kerää vain `State=1` -erät, joten NOT_PROCESSED-erät eivät pääse TSK_FB_CalcSchedule:en. Tämä on **oikein** — ei vikaa.

---

## 3. Yksityiskohtaiset havainnot

### ~~VIKA 1: Stage 0 käsittelyaika puuttuu~~ → ✅ KORJATTU

**Ongelma**: ST:n prepend-lohkossa stage 0:n CalcTime/MinTime/MaxTime olivat aina 0. JS:ssä ne tulivat batch.calc_time_s/min_time_s/max_time_s.

**Korjaus** (`TSK_FB_CalcSchedule.st` prepend-lohko):
```st
IF g_batch[i_unit].CurStage = 0 AND g_batch[i_unit].CalTime > 0 THEN
  (* JS: remainingSec = max(1, calcTimeS - elapsed) *)
  IF g_batch[i_unit].StartTime > 0 AND g_batch[i_unit].StartTime < i_time_s THEN
    elapsed_s := LINT_TO_REAL(i_time_s - g_batch[i_unit].StartTime);
  ELSE
    elapsed_s := 0.0;
  END_IF;
  remain_s := DINT_TO_REAL(g_batch[i_unit].CalTime) - elapsed_s;
  IF remain_s < 1.0 THEN remain_s := 1.0; END_IF;
  exit_t := i_time_s + REAL_TO_LINT(remain_s);
  g_schedule[i_unit].Stages[out_count].ExitTime  := exit_t;
  g_schedule[i_unit].Stages[out_count].CalcTime  := REAL_TO_DINT(remain_s);
  g_schedule[i_unit].Stages[out_count].MinTime   := g_batch[i_unit].MinTime;
  g_schedule[i_unit].Stages[out_count].MaxTime   := g_batch[i_unit].MaxTime;
ELSE
  (* Mid-process repositioning: zero duration *)
  g_schedule[i_unit].Stages[out_count].ExitTime  := exit_t;
  g_schedule[i_unit].Stages[out_count].CalcTime  := 0;
  g_schedule[i_unit].Stages[out_count].MinTime   := 0;
  g_schedule[i_unit].Stages[out_count].MaxTime   := 0;
END_IF;
```

Nyt stage 0 käyttää g_batch-tietoja (departure-schedulerin laskemat), ja elapsed-aika vähennetään oikein.

---

### ~~VIKA 2: Ensimmäisen stagen remaining-time ehto ei toimi stage 0:lle~~ → ✅ KORJATTU (sidottu vikaan 1)

**Ongelma**: Kun erä oli stagella 0, prepend-lohkon CalcTime=0 → exit_t ei siirtynyt → kaikki seuraavat vaiheet alkoivat liian aikaisin.

**Korjaus**: Sidottu vikaan 1. Nyt prepend-lohko asettaa `exit_t := i_time_s + remain_s` kun CurStage=0 ja CalTime > 0. Seuraavat vaiheet alkavat oikeaan aikaan, koska:
1. Prepend asettaa `is_first := FALSE`
2. Prepend asettaa `exit_t` oikein (nykyaika + jäljellä oleva aika)
3. Ensimmäinen silmukkastage käyttää `exit_t + xfer_t` → oikea aloitusaika

---

### ~~VIKA 3: forceEntryTime puuttuu kokonaan~~ → ✅ EI VIKA (kuollut koodi)

**JS** (`transporterTaskScheduler.js` rivi 2865):
```javascript
const forceEntryTime = batch._forceEntryTime;
```

JS lukee `batch._forceEntryTime`, mutta **`_forceEntryTime` ei ole koskaan asetettu** missään JS-koodissa (grep koko koodikannasta vahvistaa). Arvo on aina `undefined`.

Tämä tarkoittaa, että ehto `isWaitingBatch && forceEntryTime !== undefined` on **aina FALSE**, ja koodi putoaa aina else-haaraan:
```javascript
prevExitTime = currentTimeSec;  // ← tämä suoritetaan aina
```

**ST**: `exit_t := i_time_s` — **identtinen toiminta JS:n kanssa.**

**Tulos: Kuollutta koodia JS:ssä. ST:n toteutus on oikein. EI vikaa.**

---

### ~~VIKA 4: justActivated-normalisointi puuttuu~~ → ✅ KORJATTU

**Alkuperäinen arvio**: "EI VIKA" — DEP_FB_Scheduler asettaa ajat aktivoinnissa.

**Tarkennettu ongelma**: DEP asettaa ajat KERRAN aktivoinnissa, mutta JS:n `justActivated`-logiikka normalisoi erän ajat **joka scheduler-syklissä** niin kauan kuin erä on CurStage=0 asemalla. Tämä on kriittistä, koska:
- Aika kuluu aktivoinnin jälkeen ennen kuin scheduler ehditä laskea aikataulua
- Ilman normalisointia CalcSchedule käyttää alkuperäistä CalTime-arvoa, joka ei huomioi kulunutta aikaa

**JS** (`taskScheduler.js` rivit 1027-1037):
```javascript
batch.calc_time_s = max(1, oldCalc - elapsed);
batch.start_time = now * 1000;
batch.min_time_s = batch.calc_time_s;
batch.max_time_s = 2 * batch.min_time_s;
```

**Korjaus** (`TSK_FB_Scheduler.st` phase 1001, ennen fb_calc-kutsua):
```st
IF g_batch[ui].CurStage = 0
   AND g_batch[ui].State = 1
   AND g_unit[ui].location >= 100 THEN
  IF g_batch[ui].StartTime > 0 AND g_batch[ui].StartTime < i_time_s THEN
    ja_elapsed := LINT_TO_REAL(i_time_s - g_batch[ui].StartTime);
    ja_remain  := DINT_TO_REAL(g_batch[ui].CalTime) - ja_elapsed;
    IF ja_remain < 1.0 THEN ja_remain := 1.0; END_IF;
    g_batch[ui].CalTime   := REAL_TO_DINT(ja_remain);
    g_batch[ui].StartTime := i_time_s;
    g_batch[ui].MinTime   := g_batch[ui].CalTime;
    g_batch[ui].MaxTime   := 2 * g_batch[ui].CalTime;
  END_IF;
END_IF;
```

Lisätty VAR-osaan: `ja_elapsed : REAL` ja `ja_remain : REAL`.

---

### ~~VIKA 5: Nostimen valinta eri logiikalla~~ → ✅ KORJATTU

**Ongelma**: Kun erä on nostimessa (`location < 100`), ST käytti `STC_FindTransporter(i_lift_stn := location)` joka on task_area-haku. Nostin-indeksi (1, 2) ei ole asema → väärä nostin tai fallback.

**JS**: Käyttää `transporter.id === batch.location` → suora vertailu.

**Korjaus** (`TSK_FB_Scheduler.st` phase 1001):
```st
IF g_unit[ui].location < 100 THEN
  (* Unit is on a transporter — location IS the transporter index *)
  sched_trans := g_unit[ui].location;
ELSE
  (* Unit is on a station — find transporter by task_area *)
  fb_find(i_lift_stn := g_unit[ui].location, i_sink_stn := 0);
  sched_trans := fb_find.o_trans;
  IF sched_trans = 0 THEN sched_trans := 1; END_IF;
END_IF;
```

---

### ~~VIKA 6: Stage 90 ohittaminen puuttuu~~ → EI VIKA

ST ei käytä stage 90:tä. Sen sijaan `g_batch[].State` hallitsee tilaa:
- `NOT_PROCESSED = 0` (vastaa JS:n stage 90)
- `IN_PROCESS = 1` (aktiivinen erä)
- `PROCESSED = 2` (valmis)

**Aktivointiketju**:
1. `DEP_FB_Scheduler` phase 8000: `g_dep_pending.BatchState := 1` (IN_PROCESS)
2. `TSK_FB_Scheduler` phase 10100: `g_batch[unit].State := g_dep_pending.BatchState`
3. `STC_FB_CollectActiveBatches(i_mode:=0)`: kerää vain `State = 1` → **NOT_PROCESSED-erät eivät pääse CalcSchedule:en**

**Tulos: Oikein toteutettu. EI vikaa.**

---

### ~~VIKA 7: calc_s := INT_TO_REAL(CurStage) — roskamuuttuja~~ → ✅ KORJATTU

**Ongelma**: `calc_s := INT_TO_REAL(g_batch[i_unit].CurStage)` asetti muuttujaan vaiheen numeron (esim. 5), ei käsittelyaikaa.

**Korjaus**: Rivi poistettu. prevExitTime-lohko yksinkertaistettu muotoon:
```st
exit_t := i_time_s;
```

---

## 4. Oikein konvertoidut osat

Seuraavat osat ovat JS:n kanssa identtisiä tai toiminnallisesti vastaavia:

| Ominaisuus | Tila |
|---|---|
| Aloitusvaiheen laskenta (start_st) | ✅ OK |
| Edellisen aseman tunnistus (prev_stn) | ✅ OK |
| Rinnakkaisasemien valinta (schedule overlap + physical occupation) | ✅ OK |
| Siirtoajan laskenta (STC_CalcTransferTime = JS calculateTransferTime) | ✅ OK |
| Poikittaissiirtokuljetin / cross-transfer detection | ✅ OK |
| Erä nostimessa → ensimmäinen stage käyttää TaskRemainingTime | ✅ OK |
| Normaalit staget: entry = prev_exit + transfer, exit = entry + calc | ✅ OK |
| Silmukkarakenne ja out_count | ✅ OK |
| StageCount tallennus | ✅ OK |

---

## 5. Korjausprioriteetti

### Korjatut (23.3.2026):
1. ~~**Vika 1 + 2**~~: Stage 0 CalcTime/MinTime/MaxTime g_batch-tiedoista → prepend-lohko korjattu
2. ~~**Vika 4**~~: justActivated-normalisointi → TSK_FB_Scheduler.st phase 1001 lisätty
3. ~~**Vika 5**~~: Nostimen valinta → location < 100 käytetään suoraan transporter-indeksinä
4. ~~**Vika 7**~~: Roskarivi → poistettu

### Ei vikoja:
- ~~**Vika 3**~~: forceEntryTime — kuollutta koodia JS:ssä
- ~~**Vika 6**~~: Stage 90 — State-mekanismi hoitaa

**Kaikki havainnot käsitelty.**

---

## 6. Tiedostot

| Tiedosto | Rooli | Muokattu |
|---|---|---|
| `OpenPLC_Simulator/PLC Simulator/sim-core/transporterTaskScheduler.js` | JS alkuperäinen (5053 riviä) | — |
| `OpenPLC_Simulator/PLC Simulator/sim-core/taskScheduler.js` | JS scheduler state machine (2107 riviä) | — |
| `plc_simulator/services/codesys/POUs/TSK_FB_CalcSchedule.st` | ST konversio (373 riviä) | ✅ Vikat 1, 2, 7 |
| `plc_simulator/services/codesys/POUs/TSK_FB_Scheduler.st` | ST scheduler state machine (432 riviä) | ✅ Vikat 4, 5 |

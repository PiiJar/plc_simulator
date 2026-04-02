# PLC-koodin auditointiraportti — Scheduler-moduuli

**Projekti:** Pintakäsittelylinjan ajoitusjärjestelmä (Scheduler)  
**Yritys:** Galvatek / John Cockerill Group  
**Auditoija:** GitHub Copilot  
**Päivämäärä:** 1.4.2026  
**Versio:** 1.3 (nimeämiskäytäntöjen auditointi lisätty)

---

## 1. Yhteenveto

| Kategoria | Tila | Huomioita |
|-----------|------|-----------|
| **Muuttujien alustus** | ✅ Hyvä | FB-muuttujat alustettu, FC:t alustaa VAR:it koodin alussa |
| **FOR-luuppien rajat** | ⚠️ Parannettavaa | Kovakoodattuja arvoja vakioiden sijaan |
| **Vakioiden käyttö** | ⚠️ Parannettavaa | MAX_* käytetty, mutta magic numbereja löytyy |
| **Nollalla jako** | ✅ Hyvä | Suojattu (MaxTime > 0 tarkistukset) |
| **Array-rajatarkistukset** | ⚠️ Ristiriita | Indeksit validoidaan, mutta queue-koko 30 vs vakio 60 |
| **PLC-yhteensopivuus** | ✅ Hyvä | IEC 61131-3 ST -syntaksi oikein |
| **Kommentointi** | ⚠️ Parannettavaa | Hyvä pohja, mutta vanhentuneita viittauksia ja epätasapainoa |
| **Visuaalinen yhtenäisyys** | ⚠️ Parannettavaa | Pää-FB:t hyvät, FC:t ja SIM vaihtelevat |
| **Muuttujien nimeäminen** | ⚠️ Parannettavaa | Prefiksit hyvät, lyhenteet epäyhtenäisiä |

**Kokonaisarvio:** Koodi on hyvälaatuista PLC-koodia. Yksi rakenteellinen ristiriita löytyi (queue-koko, ks. 3.3). Muut korjaussuositukset liittyvät ylläpidettävyyteen ja konfiguroitavuuteen.

---

## 2. Auditoidut tiedostot

### 2.1 POUs (Program Organization Units)

| Tiedosto | Tyyppi | Rivejä | Tila |
|----------|--------|--------|------|
| STC_FB_MainScheduler.st | FUNCTION_BLOCK | ~170 | ✅ |
| TSK_FB_Scheduler.st | FUNCTION_BLOCK | ~450 | ✅ |
| DEP_FB_Scheduler.st | FUNCTION_BLOCK | ~800 | ✅ |
| STC_DispatchTask.st | FUNCTION | ~370 | ✅ |
| STC_CalcSchedule.st | FUNCTION | ~200 | ⚠️ |
| STC_CreateTasks.st | FUNCTION | ~110 | ✅ |
| STC_SortTasks.st | FUNCTION | ~140 | ✅ |
| STC_CollectActiveBatches.st | FUNCTION | ~90 | ⚠️ |
| DEP_CalcIdleSlots.st | FUNCTION | ~100 | ✅ |
| DEP_FitTaskToSlot.st | FUNCTION | ~170 | ✅ |
| TSK_Analyze.st | FUNCTION | ~200 | ✅ |

### 2.2 GVLs (Global Variable Lists)

| Tiedosto | Tila |
|----------|------|
| GVL_JC_Constants.st | ✅ |
| GVL_JC_Scheduler.st | ✅ |
| GVL_Parameters.st | ✅ |

### 2.3 UDTs (User-Defined Types)

31 tietotyyppiä auditoitu — kaikki yhteensopivia IEC 61131-3 -standardin kanssa.

---

## 3. Kriittiset havainnot

### 3.1 � Tunnettu kehitysrajoitus: Station 114 (ei korjaustarvetta nyt)

**Tiedosto:** `POUs/STC_CollectActiveBatches.st`  
**Rivi:** 65

```st
(* ── Waiting batch: direct lookup at station 114 ── *)
ui := g_station_loc[114].UnitId;
```

**Tilanne:**  
Nykyisessä kehitysvaiheessa on vain yksi asema (114), josta odottava erä lähtee linjaan. Tämä on tarkoituksellinen yksinkertaistus.

**Lopullinen tavoite (TODO):**  
1. Hakea kaikki odottavat erät useammalta asemalta
2. Sortata ne haluttuun järjestykseen (prioriteetti, aika, jne.)
3. Valita seuraava aktivoitava erä sortatusta listasta

**Kehityssuunnitelma:**  
Kun odottavien sorttaus toteutetaan, tämä kohta korvataan dynaamisella logiikalla:
```st
(* Tulevaisuudessa: hae ja sorttaa kaikki odottavat *)
FOR station := FIRST_LOADING_STATION TO LAST_LOADING_STATION DO
  IF g_station_loc[station].UnitId > 0 THEN
    (* Lisää waiting_list:iin *)
  END_IF;
END_FOR;
(* Sorttaa prioriteetin mukaan *)
(* Valitse paras *)
```

**Vaikutus:** Ei — toimii oikein nykyisellä setupilla. Ei vaadi toimenpiteitä ennen usean lastausaseman käyttöönottoa.

---

### 3.2 🔴 Array-koot kovakoodattu VAR_IN_OUT:ssa

**Tiedostot:**  
- `POUs/STC_CalcSchedule.st`
- `POUs/STC_CreateTasks.st`
- `POUs/DEP_Sandbox.st`
- `POUs/STC_ShiftSchedule.st`
- `POUs/TSK_Resolve.st`
- `POUs/DEP_CalcIdleSlots.st`
- `POUs/DEP_FitTaskToSlot.st`
- `POUs/DEP_OverlapDelay.st`
- `POUs/STC_SortTasks.st`
- `POUs/STC_SwapTasks.st`
- `POUs/TSK_NoTreatment.st`
- `POUs/TSK_Analyze.st`
- `POUs/STC_FindTransporter.st`
- `POUs/SIM/SIM_FB_RunTasks.st`

```st
VAR_IN_OUT
  io_schedule : ARRAY[1..10] OF UDT_JC_TskScheduleType;  (* pitäisi olla MAX_Units *)
  io_task     : ARRAY[1..3] OF UDT_JC_TskQueueType;      (* pitäisi olla MAX_Transporters *)
END_VAR
```

**Ongelma:**  
VAR_IN_OUT-arrayjen koko on kovakoodattu (10, 3), vaikka GVL:ssä on vastaavat vakiot `MAX_Units := 10` ja `MAX_Transporters := 3`.

**Vaikutus:** Keskitaso — jos vakiot muuttuvat, nämä funktiot eivät toimi oikein.

**Suositus:**  
IEC 61131-3:ssa VAR_IN_OUT ei tue VAR_EXTERNAL CONSTANT -viittauksia arrayn koossa. Tämä on kielen rajoitus. Suositukset:

1. **Dokumentoi riippuvuus** selkeästi kommenttiin:
   ```st
   (* HUOM: Array-koko TÄYTYY vastata GVL_JC_Constants.MAX_Units/MAX_Transporters *)
   io_schedule : ARRAY[1..10] OF UDT_JC_TskScheduleType;
   ```

2. **Käytä koodigeneraattoria** — generoi .st-tiedostot vakioiden perusteella.

3. **Tarkista compile-time** — lisää ajonaikainen assert jos ympäristö tukee.

---

### 3.3 🔴 Queue-koko ristiriita: MAX_TASK_QUEUE (60) vs Queue ARRAY[1..30]

**Tiedostot:**
- `GVLs/GVL_JC_Constants.st` — `MAX_TASK_QUEUE := 60`
- `UDTs/UDT_JC_TskQueueType.st` — `Queue : ARRAY[1..30] OF UDT_JC_TskTaskType`
- `POUs/STC_CreateTasks.st` — rivi 90: `IF qi <= MAX_TASK_QUEUE THEN`

```st
(* GVL_JC_Constants.st *)
MAX_TASK_QUEUE            : INT  := 60;  (* max tasks per transporter queue *)

(* UDT_JC_TskQueueType.st *)
Queue : ARRAY[1..30] OF UDT_JC_TskTaskType; (* task slots, MAX_TASK_QUEUE *)
```

**Ongelma:**
Vakio `MAX_TASK_QUEUE = 60`, mutta todellinen taulukko on `ARRAY[1..30]`. `STC_CreateTasks` sallii kirjoituksen arvoon `qi = 60` asti, mikä ylittää taulukon rajan. CODESYS ei tee automaattista rajatarkistusta — tämä on **varma out-of-bounds -kirjoitus** jos tehtäviä kertyy yli 30.

**Vaikutus:** Kriittinen — muistin ylikirjoitus riskinä.

**Suositus:**
Päätä yksi totuuslähde:
1. Jos queue-koko on 60, korjaa UDT: `Queue : ARRAY[1..60]`
2. Jos queue-koko on 30, korjaa vakio: `MAX_TASK_QUEUE := 30`

Tämä on korjattava **ennen muita scheduler-muutoksia**.

---

## 4. Keskitason havainnot

### 4.1 🟡 FOR-luupit kovakoodatuilla ylärajoilla

| Tiedosto | Rivi | Nykyinen | Pitäisi olla |
|----------|------|----------|--------------|
| TSK_FB_Scheduler.st | 256 | `FOR bi := 1 TO 50` | `TO MAX_LOCKS` (uusi vakio) |
| DEP_CalcOverlap.st | 51 | `FOR station_idx := 0 TO 200` | Ei korjata — vastaa UDT_JC_DepOverlapType.Flags[0..200] |
| DEP_FB_Scheduler.st | 359 | `FOR qi := 1 TO 30` | `TO MAX_TASK_QUEUE / 2` |

**Huom:** `DEP_CalcOverlap.st` käyttää lukua 200 koska kohderakenne `UDT_JC_DepOverlapType.Flags` on `ARRAY[0..200]`. Korvaaminen vakiolla `MAX_StationIndex` (130) **rikkoisi koodin**, koska Overlap-taulukko on tarkoituksella laajempi kuin aktiivinen asema-alue.
| STC_CalcSchedule.st | 100 | `FOR stg := 0 TO 30` | `TO MAX_STEPS_PER_PROGRAM` |
| SIM_FB_ClearConfig.st | 169 | `FOR j := 0 TO 30` | `TO MAX_STEPS_PER_PROGRAM` |
| SIM_FB_ClearConfig.st | 183 | `FOR j := 0 TO 30` | `TO MAX_STEPS_PER_PROGRAM` |

**Suositus:**  
Korvaa kaikki kovakoodatut rajat GVL-vakioilla ylläpidettävyyden parantamiseksi. Lisää tarvittavat uudet vakiot:

```st
(* GVL_JC_Constants.st — lisättävät vakiot *)
MAX_LOCKS               : INT := 50;   (* TSK conflict resolution locks *)
MAX_CHAIN_DELAYS        : INT := 10;   (* DEP backward chaining delays *)
MAX_WAITING_TASKS       : INT := 30;   (* DEP waiting batch task buffer *)
```

---

### 4.2 🟡 Station index offset 100 kovakoodattu

**Tiedostot ja rivit:**

| Tiedosto | Rivi | Kovakoodattu |
|----------|------|--------------|
| STC_DispatchTask.st | 134-135 | `- 100` |
| STC_TrackMoveTimes.st | 107-109 | `- 100` |
| STC_CalcSchedule.st | 97 | `>= 100` |
| TSK_FB_Scheduler.st | 208 | `< 100` |
| STC_CalcHorizontalTravel.st | 41-42 | `- 100` |
| STC_CalcTransferTime.st | 50-51 | `- 100` |
| TSK_Analyze.st | 204-205, 220-221 | `- 100` |
| TSK_NoTreatment.st | 142 | `>= 100` |
| TSK_NoTreatment.st | 376 | `- 100` |

**Esimerkki:**
```st
from_idx := g_transporter[ti].CurrentStation - 100;
to_idx   := t_lift - 100;
```

**Ongelma:**  
`100` on `MIN_StationIndex`-vakion arvo, mutta kovakoodattu suoraan.

**Suositus:**  
Korvaa vakiolla:
```st
from_idx := g_transporter[ti].CurrentStation - MIN_StationIndex;
to_idx   := t_lift - MIN_StationIndex;
```

---

## 5. Hyvät käytännöt (jo toteutettu)

Seuraavat hyvät ohjelmointikäytännöt on jo implementoitu:

### 5.1 ✅ Muuttujien alustus FB:ssä

```st
VAR
  phase    : INT := 0;     (* Alustettu *)
  turn     : INT := 0;     (* Alustettu *)
  lock_cnt : INT := 0;     (* Alustettu *)
  locks_initialized : BOOL := FALSE;
END_VAR
```

### 5.2 ✅ Nollalla jako suojattu

```st
(* STC_SortTasks.st:88-90 *)
AND io_batch[tmp_unit].MaxTime > 0 THEN    (* ← Tarkistus ennen jakoa *)
  tmp_ratio := LINT_TO_REAL(...) / DINT_TO_REAL(io_batch[tmp_unit].MaxTime);
```

### 5.3 ✅ Array-indeksit validoidaan

```st
IF i_unit < 1 OR i_unit > MAX_Units THEN RETURN; END_IF;
IF i_trans < 1 OR i_trans > MAX_Transporters THEN RETURN; END_IF;
```

### 5.4 ✅ Vakioiden systemaattinen käyttö pääsilmukoissa

```st
FOR ti := 1 TO MAX_Transporters DO   (* ← Oikein *)
FOR ui := 1 TO MAX_Units DO          (* ← Oikein *)
```

### 5.5 ✅ Tyyppiliteraalit käytössä

```st
LINT#0
LINT#2000000000
REAL_TO_LINT()
DINT_TO_REAL()
LINT_TO_INT()
```

### 5.6 ✅ Phase-pohjainen tilakone

State machine -toteutus on selkeä ja seurattava:
```st
(* Phase-ryhmät: 100=INIT, 1000=CALC, 2000=TASKS, 10000=READY *)
IF phase >= 1000 AND phase <= 1999 THEN
  idx := phase - 1000;
  (* ... *)
END_IF;
```

### 5.7 ✅ Kommentointi ja dokumentaatio

Jokainen tiedosto sisältää:
- Otsikkokommentti (nimi, yritys, tekijä, päivämäärä)
- Toiminnallinen kuvaus
- Muutosloki
- Inline-kommentit kriittisissä kohdissa

---

## 6. Kommenttien auditointi

### 6.1 Kommenttien tasapaino — yhteenveto

| Tiedostotyyppi | Tasapaino | Kommentti |
|----------------|-----------|-----------|
| **FB-tiedostot** (TSK_FB_*, DEP_FB_*, STC_FB_*) | ✅ Hyvä | Runsaat phase-kommentit, box-headerit |
| **FC-tiedostot** (STC_*, DEP_*, TSK_*) | ⚠️ Vaihteleva | Header hyvä, inline niukempi |
| **GVL-tiedostot** | ✅ Erinomainen | Jokainen muuttuja kommentoitu |
| **UDT-tiedostot** | ⚠️ Niukka | Vain tiedostoheader, kentät ilman selityksiä |

---

### 6.2 ✅ Hyvät kommentointikäytännöt

**Tiedostoheaderit** — Johdonmukainen formaatti kaikissa tiedostoissa:
```st
(* ===========================================================================================
 *  STC_DispatchTask — Validate and dispatch tasks to transporters
 *
 *  Company : Galvatek part of the John Cockerill Group
 *  Author  : Jarmo Piipponen
 *  Created : 25.03.2026
 *
 * -------------------------------------------------------------------------------------------
 *  Called every PLC scan from MainScheduler.
 *  For each idle transporter with queued tasks:
 *  1. Skip if transporter not idle or queue empty
 *  2. Time check: start_time close enough?
 *  ...
 *)
```

**Phase-kommentit FB:ssä** — Selkeät box-kommentit jokaiselle tilalle:
```st
(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1000+i: CALC_SCHEDULE — one batch per scan             *)
(*   i = 0..batch_count-1: calculate schedule                   *)
(*   i >= batch_count: done → 2000                              *)
(* ══════════════════════════════════════════════════════════════ *)
```

**GVL-kommentit** — Jokainen muuttuja selitetty:
```st
g_dep_pending : UDT_JC_DepPendingWriteType;  (* ACTIVATE write buffer *)
g_tsk_stable  : BOOL;  (* tasksStableFlag: TRUE when TSK reached READY+conflict_free *)
```

---

### 6.3 🔴 Vanhentuneet viittaukset kommenteissa

Seuraavat kommentit viittaavat poistettuun tai muutettuun koodiin ja tulisi päivittää:

#### 6.3.1 TSK_FB_Scheduler.st — Changes-osio

**Rivi:** 40-42

```st
 *  Changes:
 *  25.03.2026 - Restructured: phase+1 default, idx from phase
 *  offset, removed batch_idx, removed 1000/1900
 *  staging phases.
```

**Ongelma:** Viittaa poistettuihin muuttujiin (`batch_idx`) ja vaiheisiin (`1000/1900`). Uusi lukija ei tiedä mitä nämä olivat.

**Suositus:** Muokkaa neutraalimmaksi:
```st
 *  Changes:
 *  25.03.2026 - Initial version: phase+1 default progression,
 *  idx derived from phase offset.
```

---

#### 6.3.2 TSK_FB_Scheduler.st — justActivated-kommentti

**Rivi:** 203-206

```st
    (* justActivated normalization removed — STC_CalcSchedule already
       computes remaining = CalTime - elapsed from the original StartTime.
       Running it here every TSK cycle caused CalTime to shrink and
       StartTime to reset, producing a sawtooth jump in the UI bar. *)
```

**Ongelma:** Selittää miksi poistettu koodi poistettiin. Hyödyllinen kehityksen aikana, mutta tulevaisuudessa hämmentävä.

**Suositus:** Lyhennä tai siirrä muutoslokiin:
```st
    (* Schedule calculated in STC_CalcSchedule — see Changes 25.03.2026 *)
```

---

### 6.4 🟡 Niukasti kommentoidut tiedostot

Seuraavissa tiedostoissa inline-kommentointi on niukempaa kuin pää-FB:issä:

| Tiedosto | Rivejä | Inline-kommentteja | Suositus |
|----------|--------|-------------------|----------|
| DEP_CalcOverlap.st | ~70 | 0 | Lisää algoritmin selitys |
| DEP_CalcIdleSlots.st | ~80 | 1 | Selitä idle slot -konsepti |
| STC_SortTasks.st | ~140 | 2 | Selitä priority-logiikka |
| TSK_Analyze.st | ~200 | 3 | Selitä konfliktityypit |

**Esimerkki puutteesta — DEP_CalcIdleSlots.st:**
```st
FOR qi := 1 TO MAX_Units DO
  IF qi > cnt THEN EXIT; END_IF;

  gap_start := prev_end;
  gap_end   := io_task[i_trans].Queue[qi].StartTime;

  IF gap_end > gap_start + LINT#1 THEN
    si := si + 1;
    (* ... *)
```

**Suositus:** Lisää selitys:
```st
(* Find gaps between consecutive tasks — these are idle slots
   where a new task could potentially fit *)
FOR qi := 1 TO MAX_Units DO
```

---

### 6.5 ~~🟡 UDT-tiedostojen kommentointi~~ ✅ Korjaus: UDT-kentät ovat jo kommentoituja

**Alkuperäinen väite:** UDT-tiedostoissa on vain header-kommentti, kentät ilman selityksiä.

**Todellisuus:** Tarkistus osoittaa, että lähes kaikki UDT-tiedostot sisältävät kenttäkohtaiset kommentit. Esimerkkejä:

```st
(* UDT_UnitType.st *)
    Location : INT; (* station number where unit currently is *)
    Status   : INT; (* NOT_USED=0, USED=1 *)
    Target   : INT; (* TO_NONE=0, TO_LOADING=1, ... *)

(* UDT_JC_TskTaskType.st *)
    Unit              : INT;  (* unit index 1..10, 0 = no task *)
    Stage             : INT;  (* destination program stage *)
    LiftStationTarget : INT;  (* station to pick up from *)
    SinkStationTarget : INT;  (* station to put down to *)
```

**Johtopäätös:** Tämä havainto oli virheellinen. UDT-kommentointi ei vaadi erillistä korjausprojektia.

---

## 7. Visuaalinen auditointi

Tarkastettu sisennysten, rivivälien, ryhmittelyn ja muotoilun yhtenäisyyttä koko koodikannassa.

---

### 7.1 Visuaalisen tyylin yhteenveto

| Tiedostotyyppi | Yhtenäisyys | Kommentti |
|----------------|-------------|-----------|
| **Pää-FB:t** (TSK_FB_*, DEP_FB_*, STC_FB_*) | ✅ Hyvä | Yhtenäinen tyyli keskenään |
| **STC_* FC:t** | ⚠️ Vaihteleva | Sisennyspoikkeamia, ei ryhmäkommentteja |
| **DEP_* FC:t** | ✅ Hyvä | Noudattavat pää-FB tyyliä |
| **TSK_* FC:t** | ⚠️ Vaihteleva | Sisennyspoikkeamia sisäkkäisissä IF:eissä |
| **SIM_* FB:t** | 🔴 Poikkeava | Eri header-tyyli, tiivistetyt VAR-osiot |
| **UDT:t** | ✅ Yhtenäinen | Minimalistinen mutta johdonmukainen |

---

### 7.2 ✅ Hyvät visuaaliset käytännöt

**1. VAR-osion tasaus pää-FB:issä** — Kaksoispistetasaus sarakkeeseen 26:
```st
VAR_INPUT
  i_run                     : BOOL;    (* TRUE = run, FALSE = stop *)
  i_time_s                  : LINT;    (* current absolute time (s), unix seconds *)
END_VAR
```

**2. Phase-blokkien box-kommentit** — Selkeä visuaalinen erotus:
```st
(* ══════════════════════════════════════════════════════════════ *)
(* PHASE 1000+i: CALC_SCHEDULE — one batch per scan             *)
(* ══════════════════════════════════════════════════════════════ *)
```

**3. VAR-osion ryhmäkommentit** (TSK_FB_Scheduler.st):
```st
VAR
  phase                     : INT := 0;
  next_phase                : INT;
  idx                       : INT;    (* derived from phase offset *)
  (* Batch list *)
  batch_list                : ARRAY[1..MAX_Units] OF INT;
  batch_count               : INT;
  (* Conflict iteration *)
  conflict_iter             : INT;
```

**4. Funktioargumenttien tasaus** — Monirivinen kutsu:
```st
TSK_Resolve(
  i_conf_unit     := an_conf_unit,
  i_conf_stage    := an_conf_stage,
  i_conf_trans    := an_conf_trans,
  i_blocked_unit  := an_blocked_unit,
  i_blocked_stage := an_blocked_stage,
  i_deficit       := an_deficit,
  io_locks        := locks
);
```

**5. Tyhjä rivi phase-blokkien välissä** — Parantaa luettavuutta.

---

### 7.3 🔴 Sisennyspoikkeamat

#### 7.3.1 TSK_FB_Scheduler.st — Väärin sisennetty IF

**Rivi:** 213

```st
      fb_find(i_lift_stn := g_unit[ui].location, i_sink_stn := 0);
      sched_trans := fb_find.o_trans;
  IF sched_trans = 0 THEN sched_trans := 1; END_IF;    (* ← väärin sisennetty *)
    END_IF;
```

**Ongelma:** `IF sched_trans = 0` rivillä 213 on sisennetty 2 välilyöntiä kun pitäisi olla 6.

---

#### 7.3.2 TSK_Resolve.st — Epätasainen sisennys

**Rivit:** 128-131

```st
IF i_blocked_unit >= 1 AND i_blocked_unit <= MAX_Units THEN
  FOR tmp_si := 1 TO io_schedule[i_blocked_unit].StageCount DO
    IF io_schedule[i_blocked_unit].Stages[tmp_si].ProgramStage = i_blocked_stage THEN
  sched_blocked := tmp_si; EXIT;                       (* ← väärin sisennetty *)
    END_IF;
  END_FOR;
END_IF;
```

**Ongelma:** `sched_blocked := tmp_si;` pitäisi olla sisennetty 6 välilyönnillä, nyt 2.

---

#### 7.3.3 STC_CreateTasks.st — ELSE-haaran sisennys

**Rivit:** 71-76

```st
FOR si := 0 TO sc - 1 DO
  IF io_schedule[i_unit].Stages[si].station = 0 THEN
    (* Skip unused stage slot *)
  ELSE
  lift_stn := io_schedule[i_unit].Stages[si].station;  (* ← pitäisi olla 4 välilyöntiä *)
  sink_stn := io_schedule[i_unit].Stages[si + 1].station;
```

**Ongelma:** ELSE-haaran koodi on sisennetty vain 2 välilyönnillä, pitäisi olla 4.

---

### 7.4 � Box-kommenttien merkkimääräero

**TSK_FB_Scheduler.st** (68 merkkiä):
```st
(* ══════════════════════════════════════════════════════════════ *)
```

**DEP_FB_Scheduler.st** (66 merkkiä):
```st
(* ════════════════════════════════════════════════════════════ *)
```

**Ero:** 2 merkkiä. Matalan prioriteetin tyylikysymys.

**Suositus:** Yhtenäistä 68 merkkiin kaikissa FB:issä.

---

### 7.5 🔴 SIM_FB_RunTasks.st — Eri tyyli

#### Header-tyyli poikkeaa:
```st
(* ============================================================
   SIM_FB_RunTasks — Simulate transporter task execution
   ...
   ============================================================ *)
```

Muissa tiedostoissa:
```st
(* ===========================================================================================
 *  STC_DispatchTask — Validate and dispatch tasks to transporters
 *
 *  Company : Galvatek part of the John Cockerill Group
 ...
```

**Poikkeamat:**
1. Ei tähtejä (`*`) rivien alussa
2. Lyhyempi viiva (60 vs 91 merkkiä)

~~3. Yritys/tekijä-kentät puuttuvat headerista~~ **Korjaus:** Company/Author/Created ovat riveillä 3-6. Tämä väite oli virheellinen.

---

#### VAR-osion tiivistys:

```st
VAR_EXTERNAL
  g_station     : ARRAY[MIN_StationIndex..MAX_StationIndex] OF UDT_StationType;    g_station_loc  : ARRAY[1..MAX_StationIndex] OF UDT_UnitLocation;  g_cfg          : ARRAY[1..MAX_Transporters] OF UDT_TransporterType;
```

**Ongelma:** Useita deklaraatioita samalla rivillä — pitäisi olla yksi per rivi.

---

### 7.6 🟡 FC-tiedostojen VAR-osiot ilman ryhmäkommentteja

Pää-FB:issä käytetään ryhmäkommentteja:
```st
  (* Batch list *)
  batch_list                : ARRAY[1..MAX_Units] OF INT;
  batch_count               : INT;
```

FC-tiedostoissa (esim. STC_DispatchTask.st):
```st
VAR
  ti                        : INT;     (* transporter loop *)
  t_unit                    : INT;
  t_stage                   : INT;
  t_lift                    : INT;
  t_sink                    : INT;
```

**Suositus:** Lisää ryhmäkommentit pitkiin VAR-osioihin:
```st
VAR
  (* Loop counters *)
  ti                        : INT;     (* transporter loop *)
  
  (* Task fields — read from queue[1] to avoid struct copy *)
  t_unit                    : INT;
  t_stage                   : INT;
```

---

### 7.7 Visuaalinen tyyliopas (ehdotus)

| Elementti | Standardi |
|-----------|-----------|
| **Sisennys** | 2 välilyöntiä per taso |
| **VAR-tasaus** | Kaksoispisteeseen sarakkeella 26 |
| **Header-pituus** | 91 merkkiä (`=`-viiva) |
| **Box-kommentit** | 68 merkkiä (`═`-viiva), 2 riviä |
| **Tyhjät rivit** | 1 rivi phase-blokkien välissä |
| **Deklaraatiot** | 1 muuttuja per rivi |
| **Ryhmäkommentit** | Yli 10 muuttujan VAR-osioissa |

---

## 8. Muuttujien nimeäminen

Tarkastettu nimeämiskäytäntöjen yhtenäisyys, luettavuus ja merkityksellisyys.

---

### 8.1 Nimeämiskäytäntöjen yhteenveto

| Kategoria | Yhtenäisyys | Kommentti |
|-----------|-------------|-----------|
| **Prefiksit (i_, o_, io_, g_)** | ✅ Erinomainen | Johdonmukainen koko koodikannassa |
| **Vakioiden nimeäminen** | ✅ Hyvä | UPPERCASE_WITH_UNDERSCORES |
| **FB-instanssit** | ✅ Hyvä | fb_* prefiksi |
| **Loop-indeksit** | ⚠️ Vaihteleva | ui/ti/qi vs ins_i/lock_i |
| **Lyhenteet** | ⚠️ Epäyhtenäinen | cnt/count, stn/station, trans/transporter |
| **Temp-muuttujat** | ⚠️ Vaihteleva | tmp_* vs tmp vs pelkkä nimi |

---

### 8.2 ✅ Hyvät nimeämiskäytännöt

#### 8.2.1 Parametrien prefiksit

Johdonmukainen ja selkeä prefiksijärjestelmä:

| Prefiksi | Merkitys | Esimerkki |
|----------|----------|-----------|
| `i_` | Input-parametri | `i_run`, `i_time_s`, `i_unit` |
| `o_` | Output-parametri | `o_phase`, `o_batch_cnt`, `o_conflict` |
| `io_` | In/Out-parametri | `io_task`, `io_schedule`, `io_batch` |
| `g_` | Global-muuttuja | `g_batch`, `g_unit`, `g_task` |
| `g_dbg_` | Debug-global | `g_dbg_tsk_conflict_type` |
| `g_dep_wk_` | DEP workspace | `g_dep_wk_schedule`, `g_dep_wk_task` |

#### 8.2.2 Vakioiden nimeäminen

```st
MAX_Units               : INT  := 10;
MAX_Transporters        : INT  := 3;
NOT_PROCESSED           : INT  := 0;
SCH_DISPATCH_MARGIN_S   : REAL := 3.0;
```

**Hyvää:** UPPERCASE, alaviivat sanojen välissä, selkeä merkitys.

#### 8.2.3 FB-instanssit

```st
fb_find                   : STC_FindTransporter;
fb_x1                     : SIM_FB_XMotion;
fb_z1                     : SIM_FB_ZMotion;
```

**Hyvää:** `fb_` prefiksi erottaa instanssit muista muuttujista.

#### 8.2.4 Ajan yksiköt suffiksissa

```st
i_time_s                  : LINT;     (* unix seconds *)
travel_s                  : REAL;     (* seconds *)
SCH_DISPATCH_MARGIN_S     : REAL;     (* seconds *)
```

**Hyvää:** `_s` ilmaisee sekunteja, parantaa luettavuutta.

---

### 8.3 🔴 Epäyhtenäiset loop-indeksit

Kaksi eri tyyliä käytössä:

**Tyyli 1: Kaksikirjaimiset (yleisin)**
```st
ui    (* unit index *)
ti    (* transporter index *)
qi    (* queue index *)
si    (* stage/slot index *)
bi    (* batch index *)
```

**Tyyli 2: Kuvaavammat**
```st
ins_i   (* insertion index *)
ins_j   (* insertion inner index *)
lock_i  (* lock search index *)
tmp_si  (* temporary stage index *)
```

**Ongelma:** Epäselvää miksi joissain paikoissa käytetään `ins_i` ja toisissa `qi`.

**Suositus:** Yhtenäistä yhdeksi tyyliksi:
- **Vaihtoehto A:** Kaikki kaksikirjaimisiksi (ui, ti, qi, ii, ji, li)
- **Vaihtoehto B:** Kaikki kuvaaviksi (unit_idx, trans_idx, queue_idx)

---

### 8.4 🔴 Selittämättömät prefiksit

TSK_FB_Scheduler.st:ssä käytetään prefiksejä ilman kommentointia:

```st
(* Analyze result cache *)
an_conflict               : BOOL;
an_conf_type              : INT;
an_conf_unit              : INT;
an_conf_stage             : INT;

(* Resolve result cache *)
rs_total_adv              : REAL;
rs_total_delay            : REAL;
```

**Ongelma:** `an_` ja `rs_` eivät ole itsestään selviä. Lukijan pitää arvata että:
- `an_` = analyze (TSK_Analyze tulokset)
- `rs_` = resolve (TSK_Resolve tulokset)

**Suositus:** Selkeämmät nimet tai kommentoi prefiksien merkitys:
```st
(* Analyze result cache — an_ = Analyze function output *)
analyze_conflict          : BOOL;
analyze_conf_type         : INT;
```

TAI lisää ryhmäkommenttiin selitys:
```st
(* ── Analyze result cache (an_ = TSK_Analyze outputs) ── *)
```

---

### 8.5 🟡 Epäyhtenäiset lyhenteet

| Täysi muoto | Lyhenne 1 | Lyhenne 2 | Tiedostot |
|-------------|-----------|-----------|-----------|
| station | `stn` | `station` | STC_DispatchTask, STC_CalcSchedule |
| transporter | `trans` | `transporter` | DEP_FB_Scheduler, STC_Calc |
| count | `cnt` | `count` | TSK_FB_Scheduler, DEP_FB |
| index | `idx` | `_i` | STC_CalcSchedule, TSK_Analyze |

**Esimerkkejä:**

```st
sink_stn        (* lyhenne stn *)
station_idx     (* täysi station *)

waiting_cnt     (* lyhenne cnt *)
batch_count     (* täysi count *)

from_idx        (* sufiksina idx *)
ins_i           (* sufiksina i *)
```

**Suositus:** Valitse yksi standardi ja noudata sitä:

| Käsite | Suositeltu lyhenne |
|--------|-------------------|
| station | `stn` |
| transporter | `trans` |
| count | `cnt` |
| index | `idx` |

---

### 8.6 🟡 UDT-kenttien nimeäminen vs lokaalit

UDT:ssä käytetään PascalCase:

```st
TYPE UDT_UnitType :
STRUCT
    Location : INT;  (* PascalCase *)
    Status   : INT;
    Target   : INT;
END_STRUCT;
```

Lokaaleissa käytetään snake_case ja lyhenteitä:

```st
VAR
  loc       : INT;   (* lyhenne UDT:n Location:sta *)
  tgt       : INT;   (* lyhenne UDT:n Target:sta *)
  cur_stage : INT;   (* snake_case *)
END_VAR
```

**Huomio:** Tämä on sinänsä OK-käytäntö (UDT = julkinen API, VAR = sisäinen), mutta lyhenteet kuten `tgt` voivat aiheuttaa hämmennystä.

**Suositus:** Käytä samoja nimiä kuin UDT:ssä kun mahdollista:
```st
location  : INT;   (* ei loc *)
target    : INT;   (* ei tgt *)
```

---

### 8.7 🟡 Sekamuotoinen location

`location` esiintyy eri muodoissa:

| Muoto | Käyttöpaikka |
|-------|--------------|
| `Location` | UDT_UnitType kenttä, UDT_JC_UnitSnap kenttä |
| `location` | STC_CalcSchedule lokaali muuttuja |
| `loc` | TSK_NoTreatment lokaali muuttuja |
| `g_unit[ui].location` | Viittaus UDT:n kenttään (pienellä l:llä!) |

**Ongelma:** UDT:ssä kenttä on `Location` (PascalCase), mutta viitaukset käyttävät `location` (camelCase). Tämä on CODESYS/IEC-syntaksin ominaisuus (case-insensitive), mutta hämmentävää.

**Suositus:** Viittaa UDT-kenttiin samalla kirjainkoolla kuin ne on määritelty:
```st
g_unit[ui].Location   (* sama kuin UDT:ssä *)
```

---

### 8.8 Nimeämisopas (ehdotus)

| Kategoria | Standardi | Esimerkki |
|-----------|-----------|-----------|
| **Input** | `i_` + snake_case | `i_time_s`, `i_unit_id` |
| **Output** | `o_` + snake_case | `o_phase`, `o_batch_cnt` |
| **In/Out** | `io_` + snake_case | `io_task`, `io_schedule` |
| **Global** | `g_` + snake_case | `g_batch`, `g_unit` |
| **Debug global** | `g_dbg_` + snake_case | `g_dbg_tsk_conflict` |
| **Workspace** | `g_xxx_wk_` | `g_dep_wk_task` |
| **Vakiot** | UPPER_SNAKE_CASE | `MAX_UNITS`, `NOT_PROCESSED` |
| **FB-instanssi** | `fb_` + nimi | `fb_find`, `fb_motion` |
| **Temp-struct** | `tmp_` + nimi | `tmp_task`, `tmp_move` |
| **Loop-indeksi** | kaksikirjaiminen | `ui`, `ti`, `qi`, `si` |
| **Lyhenteet** | yhtenäinen | `stn`, `trans`, `cnt`, `idx` |

---

## 9. Korjaussuositukset

### Prioriteetti 0 — Kriittinen (korjaa välittömästi)

| # | Korjaus | Tiedostot | Työmäärä |
|---|---------|-----------|----------|
| 0.1 | Yhtenäistä queue-koko: MAX_TASK_QUEUE vs ARRAY[1..30] | GVL_JC_Constants.st, UDT_JC_TskQueueType.st | 15 min |

### Prioriteetti 1 — Visuaaliset korjaukset (tehtävä heti)

| # | Korjaus | Tiedosto | Rivi | Työmäärä |
|---|---------|----------|------|----------|
| 1.1 | Korjaa sisennys: `IF sched_trans = 0` | TSK_FB_Scheduler.st | 213 | 2 min |
| 1.2 | Korjaa sisennys: `sched_blocked := tmp_si` | TSK_Resolve.st | 130 | 2 min |
| 1.3 | Korjaa ELSE-haaran sisennys | STC_CreateTasks.st | 71-76 | 5 min |
| 1.4 | Yhtenäistä box-kommenttien pituus (68 merkkiin) | DEP_FB_Scheduler.st | kaikki | 10 min |

### Prioriteetti 2 — Kommenttien siivous (tehtävä heti)

| # | Korjaus | Tiedosto | Työmäärä |
|---|---------|----------|----------|
| 2.1 | Päivitä Changes-osio — poista "removed" viittaukset | TSK_FB_Scheduler.st | 5 min |
| 2.2 | Lyhennä/poista "justActivated normalization removed" | TSK_FB_Scheduler.st | 5 min |

### Prioriteetti 3 — Tärkeät (tehtävä viikon sisällä)

| # | Korjaus | Tiedostot | Työmäärä |
|---|---------|-----------|----------|
| 3.1 | Korvaa `- 100` → `- MIN_StationIndex` | 8 tiedostoa | 30 min |
| 3.2 | Korvaa `>= 100` / `< 100` → `>= MIN_StationIndex` / `< MIN_StationIndex` | 3 tiedostoa | 10 min |
| 3.3 | Lisää puuttuvat vakiot GVL:ään | GVL_JC_Constants.st | 10 min |

### Prioriteetti 4 — Ylläpidettävyys (tehtävä sprintin aikana)

| # | Korjaus | Tiedostot | Työmäärä |
|---|---------|-----------|----------|
| 4.1 | Korvaa `TO 30` → `TO MAX_STEPS_PER_PROGRAM` | 3 tiedostoa | 20 min |
| 4.2 | Korvaa `TO 50` → `TO MAX_LOCKS` | 1 tiedosto | 10 min |
| 4.3 | Dokumentoi VAR_IN_OUT array-koot | 14 tiedostoa | 30 min |

### Prioriteetti 5 — Kommenttien parannukset (tehtävä kun aikaa)

| # | Korjaus | Tiedostot | Työmäärä |
|---|---------|-----------|----------|
| 5.1 | Lisää inline-kommentit FC-tiedostoihin | DEP_CalcOverlap.st, DEP_CalcIdleSlots.st | 30 min |
| ~~5.2~~ | ~~Lisää kenttäkommentit UDT-tiedostoihin~~ (tarpeetonta — kentät jo kommentoitu) | — | — |
| 5.3 | Dokumentoi konfliktityypit TSK_Analyze.st:ssä | TSK_Analyze.st | 15 min |

### Prioriteetti 6 — SIM-tiedostojen yhtenäistäminen (valinnainen)

| # | Korjaus | Tiedostot | Työmäärä |
|---|---------|-----------|----------|
| 6.1 | Päivitä header pää-FB:n tyyliin | SIM_FB_RunTasks.st | 10 min |
| 6.2 | Erota tiivistetyt VAR-deklaraatiot eri riveille | SIM_FB_RunTasks.st | 15 min |
| 6.3 | Lisää ryhmittelykommentit VAR-osioon | SIM_FB_RunTasks.st | 10 min |

### Prioriteetti 7 — Nimeämiskäytäntöjen parannukset (valinnainen)

| # | Korjaus | Tiedostot | Työmäärä |
|---|---------|-----------|----------|
| 7.1 | Lisää `an_`/`rs_` prefiksien selitys kommenttiin | TSK_FB_Scheduler.st | 5 min |
| 7.2 | Yhtenäistä lyhenteet: `cnt` vs `count` → `cnt` | Kaikki POU:t | 30 min |
| 7.3 | Yhtenäistä lyhenteet: `stn` vs `station` → `stn` | Kaikki POU:t | 30 min |
| 7.4 | Dokumentoi nimeämisopas projektin docs-kansioon | docs/NAMING_GUIDE.md | 20 min |

---

## 10. Testaussuositukset

Korjausten jälkeen suositellaan seuraavat testit:

1. **Yksikkötestit** — Varmista, että funktiot palauttavat samat tulokset
2. **Integraatiotestit** — Aja simulaattori läpi täydellä tuotantoskenaariolla
3. **Regressiotestit** — Vertaa ajoituksia ennen/jälkeen korjausten

---

## 11. Liitteet

### 11.1 Tarkistetut vakiot (GVL_JC_Constants.st)

| Vakio | Arvo | Käyttö |
|-------|------|--------|
| MAX_Units | 10 | Yksiköiden maksimimäärä |
| MAX_Transporters | 3 | Nosturien maksimimäärä |
| MAX_STEPS_PER_PROGRAM | 30 | Ohjelmavaiheiden maksimi |
| MAX_TASK_QUEUE | 60 | Tehtäväjonon koko |
| MIN_StationIndex | 100 | Ensimmäinen asemaindeksi |
| MAX_StationIndex | 130 | Viimeinen asemaindeksi |
| DEP_MAX_IDLE_SLOTS | 20 | DEP idle slot -puskuri |

### 11.2 Ehdotetut uudet vakiot

```st
(* Lisättävät vakiot GVL_JC_Constants.st:hen *)
MAX_LOCKS               : INT := 50;   (* TSK conflict resolution locks *)
MAX_CHAIN_DELAYS        : INT := 10;   (* DEP backward chaining delays *)
MAX_WAITING_TASKS       : INT := 30;   (* DEP waiting batch task buffer *)
```

### 11.3 Tulevaisuuden kehitys: Odottavien erien sorttaus

Kun linjalle lisätään useampi lastausasema, toteutetaan:
1. `STC_CollectWaitingBatches` — kerää kaikki odottavat erät kaikilta lastausasemilta
2. `STC_SortWaitingBatches` — sorttaa prioriteetin/ajan/muun logiikan mukaan
3. Parametrisointi: `FIRST_LOADING_STATION`, `LAST_LOADING_STATION` tai dynaaminen asemamaski

---

**Raportin loppu**

*Auditointi suoritettu GitHub Copilotin avulla 1.4.2026*

# Moduulireferenssi

Tiedostokohtainen hakuteos. Jokaisesta POU:sta: tyyppi, tarkoitus, rajapinta ja toimituslaajuus.

**Toimituslaajuus-merkinnät:**
- 🔒 **KIRJASTO** — salataan projektitoimituksissa
- 🔌 **RAJAPINTA** — näkyvissä asiakkaalle
- 🧪 **KEHITYS** — vain kehitysympäristö, ei toimiteta

---

## PLC_PRG — Testi-integraatio 🧪

| | |
|---|---|
| **Tiedosto** | `POUs/plc_prg.st` |
| **Tyyppi** | PROGRAM |
| **Toimitus** | 🧪 KEHITYS — ei toimiteta asiakkaalle |
| **Tarkoitus** | Kehitysympäristön integraatio-ohjelma: SIM-kutsu, aikasynkronointi, komentokehys |

**Sisäiset instanssit:**
- `main_sched : STC_FB_MainScheduler`
- `twa_calc : TWA_FB_CalcLimits`
- `run_tasks : SIM_FB_RunTasks`
- `evt_queue : SIM_FB_EventQueue`
- `clear_cfg : SIM_FB_ClearConfig`

**Komentokehys** (`g_cmd_code`):
- 2 = INIT (alusta nostimet, unit-sijainnit, tapahtumajonot)
- 3 = CLEAR (nollaa konfiguraatio)

---

## STC_FB_MainScheduler — Kirjaston entry point 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_FB_MainScheduler.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🔒 KIRJASTO — entry point, asiakas kutsuu tätä |
| **Tarkoitus** | Vuorottelee TSK ja DEP, ajaa DispatchTask joka jaksolla |

**VAR_INPUT:** `i_run : BOOL`, `i_time_s : LINT`
**VAR_OUTPUT:** `o_tsk_phase`, `o_dep_phase`, `o_turn`, `o_skip_cnt`

**Kutsuu:** TSK_FB_Scheduler, DEP_FB_Scheduler, STC_DispatchTask

---

## TSK_FB_Scheduler — Task Scheduler 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/TSK_FB_Scheduler.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Tilakone: aktiivisten erien aikataulutus ja konfliktiratkaisu |

**VAR_INPUT:** `i_run : BOOL`, `i_time_s : LINT`
**VAR_OUTPUT:** `o_phase`, `o_batch_cnt`, `o_task_cnt`, `o_cycle_cnt`, `o_conflict`

**Kutsuu:** STC_CollectActiveBatches, STC_NoTreatmentStates, STC_CalcSchedule, STC_CreateTasks, STC_SortTasks, STC_SwapTasks, TSK_Analyze, TSK_Resolve, TSK_NoTreatment, STC_MoveAway

**Tilakone:** ks. [SCHEDULER_PHASES.md](SCHEDULER_PHASES.md)

---

## TSK_Analyze — Konfliktianalyysi 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/TSK_Analyze.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Read-only analyysi: tunnista ensimmäinen konflikti tehtäväjonoista |

**VAR_INPUT:** `i_time_s : LINT`
**VAR_IN_OUT:** `io_task : ARRAY[1..3] OF UDT_JC_TskQueueType`
**VAR_OUTPUT:** `o_has_conflict`, `o_conf_type`, `o_conf_unit`, `o_conf_stage`, `o_blocked_unit`, `o_blocked_stage`, `o_deficit`

**Konfliktityypit:** 1=TASK_SEQUENCE, 2=COLLISION, 3=CROSS_HANDOFF

---

## TSK_Resolve — Konfliktiratkaisu 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/TSK_Resolve.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | 4-strateginen konfliktiratkaisu: ADVANCE → DELAY → PRECEDING → REORDER |

**VAR_INPUT:** `i_conf_unit`, `i_conf_stage`, `i_blocked_unit`, `i_blocked_stage`, `i_deficit`, `i_time_s`
**VAR_IN_OUT:** `io_locks[]`, `io_lock_cnt`, `io_schedule[]`, `io_task[]`, `io_batch[]`
**VAR_OUTPUT:** `o_total_adv`, `o_total_delay`

**Yksityiskohdat:** ks. [CONFLICT_RESOLUTION.md](CONFLICT_RESOLUTION.md)

---

## TSK_NoTreatment — Ei-käsittely-tehtävät 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/TSK_NoTreatment.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Luo siirtotehtävät puskuri/purku/väistö-kohteille |

**VAR_INPUT:** `i_time_s : LINT`
**VAR_IN_OUT:** `io_task : ARRAY[1..3] OF UDT_JC_TskQueueType`

**Käyttää:** `g_ntt[]` NTT-kohdetaulukkoja, `g_unit[].Target`

---

## DEP_FB_Scheduler — Departure Scheduler 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/DEP_FB_Scheduler.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Odottavien erien optimaalinen sisääntulo sandbox-mallilla |

**VAR_INPUT:** `i_run`, `i_time_s`, `i_tsk_phase`
**VAR_OUTPUT:** `o_phase`, `o_wait_cnt`, `o_activated`, `o_reject_cnt`, `o_fit_round`, `o_cur_wait_unit`

**Kutsuu:** DEP_Sandbox, DEP_CalcIdleSlots, DEP_FitTaskToSlot, DEP_CalcOverlap, DEP_OverlapDelay + kaikki STC-funktiot

**Yksityiskohdat:** ks. [DEP_SCHEDULER.md](DEP_SCHEDULER.md)

---

## DEP_CalcIdleSlots 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/DEP_CalcIdleSlots.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Tunnista vapaat aikaikkunat nostinten tehtäväjonoista |

**VAR_IN_OUT:** `io_task[1..3]`, `io_idle_slot[1..3]`

---

## DEP_FitTaskToSlot 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/DEP_FitTaskToSlot.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Tarkista mahtuuko odottava tehtävä idle-slotiin |

**VAR_INPUT:** `i_lift_stn`, `i_sink_stn`, `i_trans_id`, `i_task_start`, `i_task_end`, `i_shift_s`, `i_calc_time_s`, `i_max_time_s`, `i_flex_factor`, `i_margin_s`, `i_conflict_margin_s`
**VAR_IN_OUT:** `io_idle_slot[1..3]`, `o_result : UDT_JC_DepFitResultType`

---

## DEP_CalcOverlap 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/DEP_CalcOverlap.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Tunnista asemat jotka ovat 2+ nostimen tehtäväalueella |

**Kirjoittaa:** `g_dep_overlap.Flags[0..200]`

---

## DEP_OverlapDelay 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/DEP_OverlapDelay.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Ajoitussäädöt jaettujen alueiden konflikteissa |

**VAR_IN_OUT:** `io_task[1..3]`, `io_overlap`

---

## DEP_Sandbox 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/DEP_Sandbox.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Kopioi live ↔ workspace (SNAPSHOT/RESTORE) |

**VAR_INPUT:** `i_cmd : INT` (1=SNAPSHOT, 2=RESTORE)
**VAR_IN_OUT:** `io_wk_schedule[]`, `io_wk_batch[]`, `io_wk_program[]`, `io_wk_task[]`

---

## STC_CalcSchedule 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_CalcSchedule.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Laske entry/exit-aikataulut yhden unitin kaikille vaiheille |

**VAR_INPUT:** `i_unit`, `i_trans`, `i_time_s`
**VAR_IN_OUT:** `io_schedule[1..10]`, `io_batch[1..10]`, `io_program[1..10]`

---

## STC_CreateTasks 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_CreateTasks.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Muunna aikatauluvaiheiden parit tehtäviksi (lift→sink) |

**VAR_INPUT:** `i_unit`
**VAR_IN_OUT:** `io_schedule[1..10]`, `io_task[1..3]`

---

## STC_SortTasks 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_SortTasks.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Lajittele tehtävät: emergency (overtime) ensin, sitten StartTime |

**VAR_INPUT:** `i_trans`, `i_time_s`
**VAR_IN_OUT:** `io_task[1..3]`, `io_batch[1..10]`

---

## STC_SwapTasks 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_SwapTasks.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Optimoi ketjutetut tehtäväparit (sink[i] = lift[i+1]) |

**VAR_IN_OUT:** `io_task[1..3]`

---

## STC_ShiftSchedule 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_ShiftSchedule.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Propagoi ajanmuutos vaiheketjussa ja tehtäväjonossa |

**VAR_INPUT:** `i_unit`, `i_from_stage`, `i_amount : REAL`
**VAR_IN_OUT:** `io_schedule[1..10]`, `io_task[1..3]`

---

## STC_DispatchTask 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_DispatchTask.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Validoi ja lähetä seuraava tehtävä odottavalle nostimelle |

**Tarkistukset:** aikaehto, unit nostoasemalla, kohde-asema vapaa, ei törmäystä
**Kirjoittaa:** `g_transporter[ti].TaskId`, `.LiftStationTarget`, `.SinkStationTarget`

---

## STC_CollectActiveBatches 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_CollectActiveBatches.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Kerää erä-indeksit suodatinmoodin mukaan |

**VAR_INPUT:** `i_mode` — 0=IN_PROCESS, 1=NOT_PROCESSED (odottavat)

---

## STC_FindTransporter 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_FindTransporter.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Valitse paras nostin lift→sink-parille |

**VAR_INPUT:** `i_lift_stn`, `i_sink_stn`
**VAR_OUTPUT:** `o_trans : INT`

**Algoritmi:** kyvykkyyssuodatus (TaskArea-rajat) → pisteytys (vähiten jonossa, lähimpänä)

---

## STC_CalcHorizontalTravel 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_CalcHorizontalTravel.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Vaakasiirtoaika kahdessa aseman välillä |

**VAR_INPUT:** `i_from_stn`, `i_to_stn`, `i_move : UDT_JC_MoveTimesType`
**Palauttaa:** `REAL` (sekunteja)

---

## STC_CalcTransferTime 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_CalcTransferTime.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Kokonaissiirtoaika: nosto + tippumis + matka + lasku + viiveet |

**VAR_INPUT:** `i_from_stn`, `i_to_stn`, `i_move`, `i_from_dropping_x10`, `i_to_device_delay_x10`, `i_drip_tray_delay_x10`
**Palauttaa:** `REAL` (sekunteja)

---

## STC_TrackMoveTimes 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_TrackMoveTimes.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Mittaa ja tallenna todelliset siirtoajat, päivitä g_move[] |

**Painotettu keskiarvo:** `uusi = (vanha × 4 + mitattu) / 5`

---

## STC_UpdateUnitLocation 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_UpdateUnitLocation.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Päivitä g_station_loc[] kun unit siirtyy asemalle |

---

## STC_NoTreatmentStates 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_NoTreatmentStates.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Hallitse unit-targetit käsittelyn jälkeen (TO_UNLOAD, TO_AVOID, ...) |

---

## STC_MoveAway 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_MoveAway.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Siirrä tyhjäkäynnillä oleva nostin pois tieltä |

---

## STC_FindStationOffset 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/STC_FindStationOffset.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | Etsi N:s asema annetusta suunnasta |

---

## TWA_FB_CalcLimits 🔒

| | |
|---|---|
| **Tiedosto** | `POUs/TWA_FB_CalcLimits.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🔒 KIRJASTO |
| **Tarkoitus** | X-alueiden törmäyksenestolaskennat (2-kierroksinen algoritmi) |

**Kirjoittaa:** `g_transporter[ti].XMinDriveLimit`, `g_transporter[ti].XMaxDriveLimit`

---

## SIM_FB_RunTasks 🧪

| | |
|---|---|
| **Tiedosto** | `POUs/SIM/SIM_FB_RunTasks.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🧪 KEHITYS — ei toimiteta asiakkaalle |
| **Tarkoitus** | 5-vaiheinen kuljetussyklin fysiikkasimulaatio |

**Instanssit:** `fb_x1..x3 : SIM_FB_XMotion`, `fb_z1..z3 : SIM_FB_ZMotion`

**Yksityiskohdat:** ks. [SIMULATION.md](SIMULATION.md)

---

## SIM_FB_XMotion 🧪

| | |
|---|---|
| **Tiedosto** | `POUs/SIM/SIM_FB_XMotion.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🧪 KEHITYS |
| **Tarkoitus** | Trapetsiprofiilinen X-liikkeen simulaatio |

---

## SIM_FB_ZMotion 🧪

| | |
|---|---|
| **Tiedosto** | `POUs/SIM/SIM_FB_ZMotion.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🧪 KEHITYS |
| **Tarkoitus** | Z-liikesimulaatio: lift z_stage 2..5,9 ja sink z_stage 6..8 |

---

## SIM_FindStation 🧪

| | |
|---|---|
| **Tiedosto** | `POUs/SIM/SIM_FindStation.st` |
| **Tyyppi** | FUNCTION |
| **Toimitus** | 🧪 KEHITYS |
| **Tarkoitus** | Asemanumerosta suora asemahaku: palauttaa XPosition ja asemaparametreja |

---

## SIM_FB_EventQueue 🧪

| | |
|---|---|
| **Tiedosto** | `POUs/SIM/SIM_FB_EventQueue.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🧪 KEHITYS |
| **Tarkoitus** | 10-slottinen kiertojono tapahtumille (PLC → Gateway) |

---

## SIM_FB_ClearConfig 🧪

| | |
|---|---|
| **Tiedosto** | `POUs/SIM/SIM_FB_ClearConfig.st` |
| **Tyyppi** | FUNCTION_BLOCK |
| **Toimitus** | 🧪 KEHITYS |
| **Tarkoitus** | Nollaa kaikki konfiguraatiotaulukot (cmd_code=3) |

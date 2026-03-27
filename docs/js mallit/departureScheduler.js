/**
 * DepartureScheduler - Lähtölupalaskennan tilakone
 * 
 * ERILLINEN TILAKONE joka synkronoidaan TASKS-tilakoneen (taskScheduler.js) kanssa.
 * 
 * SYNKRONOINTI:
 * - Odottaa TASKS-tilakoneen valmistumista (phase = READY tai SAVE)
 * - Ei aloita uutta laskentaa ennen kuin TASKS on stabiloitunut
 * - END_DELAY (100 tickiä) VAIN onnistuneen aktivoinnin jälkeen
 * - Epäonnistuneen/hylätyn laskennan jälkeen palataan suoraan WAITING_FOR_TASKS
 * 
 * IDLE-SLOT SOVITUS (departure_target_description.md):
 * - Sovittelee odottavan erän nostimien tyhjäkäynti-ikkunoihin
 * - Linjalla jo olevien erien aikatauluja EI muuteta
 * - Ensimmäisen tehtävän ajoitus: idle_start + travel → min/max (ei program min/max)
 * - max_initial_wait_s rajaa 1. tehtävän odotuksen
 * - flex_up_factor kertoo kuinka paljon joustosta käytetään (oletus 50%)
 * - Jos tehtävä ei mahdu omalla flex_up:lla → backward chaining aiempiin tehtäviin
 * - Yksi viive per kierros: kirjaa, palauta WAITING_FOR_TASKS, seuraava kierros laskee uudestaan
 * - Kaikki mahtuvat → ACTIVATE
 * 
 * Vaiherakenne:
 *   0:         WAITING_FOR_TASKS (odottaa TASKS-koneen valmistumista)
 *   100:       INIT (alusta departure-laskenta, lue context)
 *   1000:      DEPARTURE_CALC_START (kerää stage 90 erät)
 *   1001-1099: DEPARTURE_CALC (laske aikataulut per erä)
 *   1900:      DEPARTURE_CALC_DONE
 *   2000:      WAITING_SORT_START
 *   2001:      WAITING_SORT_LOADED (järjestä loaded_s mukaan)
 *   2900:      WAITING_SORT_DONE
 *   3000:      CHECK_START (aloita lähtöluparkistus)
 *   3001:      CHECK_CREATE_TASKS
 *   3002:      CHECK_SORT
 *   3003:      CHECK_SWAP
 *   3004:      CHECK_ANALYZE
 *   3005:      CHECK_RESOLVE
 *   3006:      CHECK_UPDATE_PROGRAM
 *   3007:      CHECK_RECALC_SCHEDULE
 *   3008:      CHECK_RECALC_TASKS
 *   3090:      ACTIVATE (aktivoi erä, store pending data)
 *   3091:      WAIT_FOR_SAVE (wait for TASKS SAVE to write pending data)
 *   4000:      END_DELAY_START (100 tyhjää tickiä)
 *   4100:      END_DELAY_END
 *   4101:      RESTART (palaa odottamaan)
 * 
 * @module departureScheduler
 */

const scheduler = require('./transporterTaskScheduler');
const fs = require('fs');
const path = require('path');

// ═══════════════════════════════════════════════════════════════════════════════
// VAKIOT
// ═══════════════════════════════════════════════════════════════════════════════

const PHASE = {
    WAITING_FOR_TASKS: 0,
    INIT: 100,
    DEPARTURE_CALC_START: 1000,
    DEPARTURE_CALC_END: 1099,
    DEPARTURE_CALC_DONE: 1900,
    WAITING_SORT_START: 2000,
    WAITING_SORT_LOADED: 2001,
    WAITING_SORT_DONE: 2900,
    CHECK_START: 3000,
    CHECK_CREATE_TASKS: 3001,
    CHECK_SORT: 3002,
    CHECK_SWAP: 3003,
    CHECK_ANALYZE: 3004,
    CHECK_RESOLVE: 3005,
    CHECK_UPDATE_PROGRAM: 3006,
    CHECK_RECALC_SCHEDULE: 3007,
    CHECK_RECALC_TASKS: 3008,
    ACTIVATE: 3090,
    WAIT_FOR_SAVE: 3091,
    END_DELAY_START: 4000,
    END_DELAY_END: 4100,
    RESTART: 4101
};

const END_DELAY_TICKS = 100;  // 100 tyhjää tickiä stabilointia varten

// ── PLC fixed-array bounds (ST: VAR_GLOBAL CONSTANT) ──
const MAX_WAITING_BATCHES = 20;
const MAX_BATCHES = 50;
const MAX_TASKS = 200;
const MAX_STATIONS = 200;
const MAX_TRANSPORTERS = 10;
const MAX_STRETCHES = 50;
const MAX_CALC_BATCHES = 50;
const MAX_IN_FLIGHT_TASKS = 10;
const MAX_DELAY_ACTIONS = 20;
const MAX_CYCLE_HISTORY = 1000;
const MAX_PHASE_LOG = 100;
const REAL_MAX = 1.0e+38;
const REAL_MIN = -1.0e+38;

// ═══════════════════════════════════════════════════════════════════════════════
// TILAKONE - TILA (säilyy tikien välillä)
// ═══════════════════════════════════════════════════════════════════════════════

const state = {
    phase: 0,
    
    // Synkronointi TASKS-tilakoneen kanssa
    tasksPhase: 0,           // TASKS-tilakoneen nykyinen vaihe
    lastTasksReadyTick: 0,   // Viimeisin tick jolloin TASKS oli READY
    
    // Cycle timing statistics (sama rakenne kuin taskScheduler)
    cycleStartTime: 0,       // Date.now() kun sykli alkaa
    cycleStartTick: 0,       // simTick kun sykli alkaa
    cycleTickCount: 0,       // tickit tässä syklissä
    cycleTickPeriodMs: 0,    // tick-jakso (2× BASE_DT_MS koska vuorottelu)
    totalCycles: 0,
    lastCycleTimeMs: 0,
    lastCycleTicks: 0,
    lastCycleSimTimeMs: 0,
    longestCycleTimeMs: 0,
    longestCycleTicks: 0,
    cycleHistory: [],        // wall-clock ms per cycle (max 1000)
    cycleHistoryCount: 0,
    cycleTickHistory: [],    // ticks per cycle (max 1000)
    cycleTickHistoryCount: 0,
    cycleSimTimeHistory: [], // sim-time ms per cycle (max 1000)
    cycleSimTimeHistoryCount: 0,
    
    // Kierroksen data (kopioidaan INIT:ssä) — PLC: counter-based arrays
    batches: [],
    batchCount: 0,
    stations: [],
    stationCount: 0,
    transporters: [],
    transporterCount: 0,
    transporterStates: [],
    transporterStateCount: 0,
    
    // Tulokset — PLC: indexed arrays with counters
    schedules: [],
    scheduleCount: 0,
    programs: [],
    programCount: 0,
    waitingScheds: [],
    waitingSchedCount: 0,
    waitingAnalyses: [],
    waitingAnalysisCount: 0,
    waitingTaskSets: [],
    waitingTaskSetCount: 0,
    
    // Lähtölupalaskenta — PLC: counter-based arrays
    waitingBatches: [],
    waitingBatchCount: 0,
    currentWaitingIndex: 0,
    allCalcBatches: [],
    allCalcCount: 0,
    currentCalcIndex: 0,
    departureSandbox: null,
    sandboxSnapshot: null,
    combinedTasks: [],
    combinedTaskCount: 0,
    departureAnalysis: null,
    departureCandidateStretches: [],
    candidateStretches: [],
    candidateStretchCount: 0,
    pendingDelay: null,
    pendingDelays: [],
    pendingDelayCount: 0,
    departureLockedStages: [],
    depLockedStageCount: 0,
    inFlightTasks: [],
    inFlightTaskCount: 0,
    
    // Handshake TASKS-tilakoneen kanssa
    // PLC-vastine: DB-bitti jonka FB_DEPARTURE asettaa ja FB_TASKS lukee
    activatedThisCycle: false,
    pendingWriteData: { valid: false },  // Data waiting for TASKS SAVE to write (PLC: fixed struct + valid flag)
    
    // Konfiguraatio
    waitingBatchMaxCount: 20,
    departureMaxIterations: 50,
    departureConflictMarginSec: 1,
    departureIteration: 0,
    
    // Tavoitetilan parametrit (departure_target_description.md)
    maxInitialWaitS: 120,    // max_initial_wait_s: suurin sallittu odotus 1. tehtävän alkuun
    flexUpFactor: 0.5,       // flex_up_factor: kerroin jolla MaxTime-CalcTime jousto käytössä
    
    // Kierroksittainen eteneminen (target): DEPARTURE-kierrosten välinen tila
    departureRound: 0,       // Monesko sovittelukierros tälle erälle (0 = ensimmäinen)
    
    // Statistiikka — PLC: counter-based
    departureTimes: [],
    departureTimeCount: 0,
    avgDepartureIntervalSec: 0,
    lastDepartureConflict: null,
    finalDepartureConflict: null,
    departureCheckResultsSummary: null,
    
    // END_DELAY laskuri
    endDelayCounter: 0,
    
    // Debug — PLC: ring buffer with counter
    phaseLog: [],
    phaseLogCount: 0
};

// ═══════════════════════════════════════════════════════════════════════════════
// KONTEKSTI
// ═══════════════════════════════════════════════════════════════════════════════

let ctx = {};

// ═══════════════════════════════════════════════════════════════════════════════
// PLC-YHTEENSOPIVAT APUFUNKTIOT (ST: FUNCTION-blocks)
// ═══════════════════════════════════════════════════════════════════════════════

// G2: PLC → GET_SYSTEM_TIME (RTC milliseconds)
function _getSystemTimeMs() { return Date.now(); }

// G4: PLC → (x > REAL_MIN) AND (x < REAL_MAX) — ST:ssä REAL on aina numero, ei NaN:ia
function _isFinite(x) {
    return (typeof x === 'number') && (x === x) && (x > REAL_MIN) && (x < REAL_MAX);
}

// G5: PLC-compatible ring buffer write (linear shift when full)
// ST: IF count >= maxSize THEN FOR i:=0 TO maxSize-2 DO arr[i]:=arr[i+1]; arr[maxSize-1]:=value; ELSE arr[count]:=value; count:=count+1; END_IF
function _ringBufferWrite(arr, count, maxSize, value) {
    if (count >= maxSize) {
        for (let i = 0; i < maxSize - 1; i++) arr[i] = arr[i + 1];
        arr[maxSize - 1] = value;
        return count;
    }
    arr[count] = value;
    return count + 1;
}

/** Insertion sort — PLC-yhteensopiva, ei rekursiota, stabiili.
 *  C3: context-parametri välittää lisätiedot compareFn:lle (korvaa sulkeuman). */
function _insertionSort(arr, count, compareFn, context) {
    for (let i = 1; i < count; i++) {
        const key = arr[i];
        let j = i - 1;
        while (j >= 0 && compareFn(arr[j], key, context) > 0) {
            arr[j + 1] = arr[j];
            j--;
        }
        arr[j + 1] = key;
    }
}

/** PLC-compatible array search (replaces .includes()) */
function _arrayIncludes(arr, count, value) {
    for (let i = 0; i < count; i++) {
        if (arr[i] === value) return true;
    }
    return false;
}

// ── A1: Schedule indexed-array helpers (replaces schedulesByBatchId hash map) ──

function _findScheduleIndex(batchId) {
    for (let i = 0; i < state.scheduleCount; i++) {
        if (state.schedules[i].batchId === batchId) return i;
    }
    return -1;
}

function _getSchedule(batchId) {
    const idx = _findScheduleIndex(batchId);
    return idx >= 0 ? state.schedules[idx].data : null;
}

function _setSchedule(batchId, scheduleData) {
    const idx = _findScheduleIndex(batchId);
    if (idx >= 0) {
        state.schedules[idx].data = scheduleData;
    } else if (state.scheduleCount < MAX_BATCHES) {
        state.schedules[state.scheduleCount++] = { batchId: batchId, data: scheduleData };
    }
}

function _removeSchedule(batchId) {
    const idx = _findScheduleIndex(batchId);
    if (idx < 0) return;
    for (let i = idx; i < state.scheduleCount - 1; i++) {
        state.schedules[i] = state.schedules[i + 1];
    }
    state.scheduleCount--;
}

/** Convert schedules array → hash map for external API */
function _schedulesToHashMap() {
    const map = {};
    for (let i = 0; i < state.scheduleCount; i++) {
        map[String(state.schedules[i].batchId)] = state.schedules[i].data;
    }
    return map;
}

/** Load hash map → schedules indexed array */
function _schedulesFromHashMap(hashMap) {
    state.schedules = [];
    state.scheduleCount = 0;
    if (!hashMap) return;
    for (const batchIdStr of Object.keys(hashMap)) {
        if (state.scheduleCount < MAX_BATCHES) {
            state.schedules[state.scheduleCount++] = { batchId: Number(batchIdStr), data: hashMap[batchIdStr] };
        }
    }
}

// ── A2: Program indexed-array helpers (replaces programsByBatchId hash map) ──

function _findProgramIndex(batchId) {
    for (let i = 0; i < state.programCount; i++) {
        if (state.programs[i].batchId === batchId) return i;
    }
    return -1;
}

function _getProgram(batchId) {
    const idx = _findProgramIndex(batchId);
    return idx >= 0 ? state.programs[idx].data : null;
}

function _setProgram(batchId, programData) {
    const idx = _findProgramIndex(batchId);
    if (idx >= 0) {
        state.programs[idx].data = programData;
    } else if (state.programCount < MAX_BATCHES) {
        state.programs[state.programCount++] = { batchId: batchId, data: programData };
    }
}

/** Convert programs array → hash map for external API */
function _programsToHashMap() {
    const map = {};
    for (let i = 0; i < state.programCount; i++) {
        map[String(state.programs[i].batchId)] = state.programs[i].data;
    }
    return map;
}

/** Load hash map → programs indexed array */
function _programsFromHashMap(hashMap) {
    state.programs = [];
    state.programCount = 0;
    if (!hashMap) return;
    for (const batchIdStr of Object.keys(hashMap)) {
        if (state.programCount < MAX_BATCHES) {
            state.programs[state.programCount++] = { batchId: Number(batchIdStr), data: hashMap[batchIdStr] };
        }
    }
}

// ── A3: _calcScheds indexed-array helpers (replaces _calcSchedules temp hash map) ──

function _findCalcSchedIndex(batchId) {
    for (let i = 0; i < state._calcSchedCount; i++) {
        if (state._calcScheds[i].batchId === batchId) return i;
    }
    return -1;
}

function _getCalcSched(batchId) {
    const idx = _findCalcSchedIndex(batchId);
    return idx >= 0 ? state._calcScheds[idx].data : null;
}

function _setCalcSched(batchId, scheduleData) {
    const idx = _findCalcSchedIndex(batchId);
    if (idx >= 0) {
        state._calcScheds[idx].data = scheduleData;
    } else if (state._calcSchedCount < MAX_BATCHES) {
        state._calcScheds[state._calcSchedCount++] = { batchId: batchId, data: scheduleData };
    }
}

// ── A4: WaitingSched indexed-array helpers (replaces waitingSchedules hash map) ──

function _findWaitingSchedIndex(batchId) {
    for (let i = 0; i < state.waitingSchedCount; i++) {
        if (state.waitingScheds[i].batchId === batchId) return i;
    }
    return -1;
}

function _getWaitingSched(batchId) {
    const idx = _findWaitingSchedIndex(batchId);
    return idx >= 0 ? state.waitingScheds[idx].data : null;
}

function _setWaitingSched(batchId, scheduleData) {
    const idx = _findWaitingSchedIndex(batchId);
    if (idx >= 0) {
        state.waitingScheds[idx].data = scheduleData;
    } else if (state.waitingSchedCount < MAX_WAITING_BATCHES) {
        state.waitingScheds[state.waitingSchedCount++] = { batchId: batchId, data: scheduleData };
    }
}

function _removeWaitingSched(batchId) {
    const idx = _findWaitingSchedIndex(batchId);
    if (idx < 0) return;
    for (let i = idx; i < state.waitingSchedCount - 1; i++) {
        state.waitingScheds[i] = state.waitingScheds[i + 1];
    }
    state.waitingSchedCount--;
}

// ── A5: WaitingAnalysis indexed-array helpers (replaces waitingBatchAnalysis hash map) ──

function _findWaitingAnalysisIndex(batchId) {
    for (let i = 0; i < state.waitingAnalysisCount; i++) {
        if (state.waitingAnalyses[i].batchId === batchId) return i;
    }
    return -1;
}

function _getWaitingAnalysis(batchId) {
    const idx = _findWaitingAnalysisIndex(batchId);
    return idx >= 0 ? state.waitingAnalyses[idx].data : null;
}

function _setWaitingAnalysis(batchId, analysisData) {
    const idx = _findWaitingAnalysisIndex(batchId);
    if (idx >= 0) {
        state.waitingAnalyses[idx].data = analysisData;
    } else if (state.waitingAnalysisCount < MAX_WAITING_BATCHES) {
        state.waitingAnalyses[state.waitingAnalysisCount++] = { batchId: batchId, data: analysisData };
    }
}

// ── A6: WaitingTaskSet indexed-array helpers (replaces waitingBatchTasks hash map) ──

function _findWaitingTaskSetIndex(batchId) {
    for (let i = 0; i < state.waitingTaskSetCount; i++) {
        if (state.waitingTaskSets[i].batchId === batchId) return i;
    }
    return -1;
}

function _getWaitingTaskSet(batchId) {
    const idx = _findWaitingTaskSetIndex(batchId);
    return idx >= 0 ? state.waitingTaskSets[idx].tasks : null;
}

function _setWaitingTaskSet(batchId, tasks) {
    const idx = _findWaitingTaskSetIndex(batchId);
    if (idx >= 0) {
        state.waitingTaskSets[idx].tasks = tasks;
    } else if (state.waitingTaskSetCount < MAX_WAITING_BATCHES) {
        state.waitingTaskSets[state.waitingTaskSetCount++] = { batchId: batchId, tasks: tasks };
    }
}

function _removeWaitingTaskSet(batchId) {
    const idx = _findWaitingTaskSetIndex(batchId);
    if (idx < 0) return;
    for (let i = idx; i < state.waitingTaskSetCount - 1; i++) {
        state.waitingTaskSets[i] = state.waitingTaskSets[i + 1];
    }
    state.waitingTaskSetCount--;
}

function log(msg) {
    // PLC: vain ring buffer, ei konsoli-I/O:ta (sama kuin taskScheduler)
    var entry = { phase: state.phase, msg: msg, time: _getSystemTimeMs() };
    state.phaseLogCount = _ringBufferWrite(state.phaseLog, state.phaseLogCount, MAX_PHASE_LOG, entry);
}

// ═══════════════════════════════════════════════════════════════════════════════
// PLC-YHTEENSOPIVAT KOPIOFUNKTIOT (ST: field-by-field struct copy)
// Korvaa JSON.parse(JSON.stringify(...)) -patternin
// ═══════════════════════════════════════════════════════════════════════════════

/** Copy single batch struct field-by-field.
 *  PLC: ST_Batch := src; (struct assignment) */
function _copyBatch(src) {
    return {
        batch_id: src.batch_id,
        stage: src.stage,
        treatment_program: src.treatment_program,
        start_time: src.start_time,
        calc_time_s: src.calc_time_s,
        min_time_s: src.min_time_s,
        max_time_s: src.max_time_s,
        isDelayed: src.isDelayed,
        justActivated: src.justActivated,
        loaded_s: src.loaded_s,
        start_time_s: src.start_time_s
    };
}

/** Copy batches array field-by-field.
 *  PLC: FOR i:=0 TO count-1 DO arr[i] := src[i]; */
function _copyBatchesArray(srcArr) {
    const result = [];
    if (!srcArr) return result;
    const len = srcArr.length;
    for (let i = 0; i < len; i++) {
        result[i] = _copyBatch(srcArr[i]);
    }
    return result;
}

/** Copy single transporter state struct (nested .state — two-level copy).
 *  PLC: ST_TransporterState := src; */
function _copyTransporterState(src) {
    const copy = {
        id: src.id,
        name: src.name
    };
    if (src.state) {
        copy.state = {
            status: src.state.status,
            phase: src.state.phase,
            x_position: src.state.x_position,
            sink_station_target: src.state.sink_station_target,
            lift_station_target: src.state.lift_station_target,
            est_finish_s: src.state.est_finish_s,
            pending_batch_id: src.state.pending_batch_id,
            current_task_lift_station_id: src.state.current_task_lift_station_id
        };
    } else {
        copy.state = null;
    }
    return copy;
}

/** Copy transporter states array field-by-field. */
function _copyTransporterStatesArray(srcArr) {
    const result = [];
    if (!srcArr) return result;
    const len = srcArr.length;
    for (let i = 0; i < len; i++) {
        result[i] = _copyTransporterState(srcArr[i]);
    }
    return result;
}

/** Copy single schedule stage struct field-by-field.
 *  PLC: ST_ScheduleStage := src; */
function _copyScheduleStage(src) {
    const copy = {
        stage: src.stage,
        station: src.station,
        entry_time_s: src.entry_time_s,
        exit_time_s: src.exit_time_s,
        treatment_time_s: src.treatment_time_s,
        transfer_time_s: src.transfer_time_s,
        min_time_s: src.min_time_s,
        max_time_s: src.max_time_s
    };
    if (src.station_name !== undefined) copy.station_name = src.station_name;
    if (src.station_id !== undefined) copy.station_id = src.station_id;
    if (src.entry_time !== undefined) copy.entry_time = src.entry_time;
    if (src.exit_time !== undefined) copy.exit_time = src.exit_time;
    if (src.min_exit_time_s !== undefined) copy.min_exit_time_s = src.min_exit_time_s;
    if (src.max_exit_time_s !== undefined) copy.max_exit_time_s = src.max_exit_time_s;
    if (src.transfer_details !== undefined) copy.transfer_details = src.transfer_details;
    if (src.parallel_stations !== undefined) copy.parallel_stations = src.parallel_stations;
    if (src.selected_from_parallel !== undefined) copy.selected_from_parallel = src.selected_from_parallel;
    return copy;
}

/** Copy single schedule object (with stages array).
 *  PLC: Deep copy schedule struct + stages array */
function _copySchedule(srcData) {
    if (!srcData) return null;
    const copy = {};
    if (srcData.batchStage !== undefined) copy.batchStage = srcData.batchStage;
    if (srcData.totalTime !== undefined) copy.totalTime = srcData.totalTime;
    if (srcData.totalTransferTime !== undefined) copy.totalTransferTime = srcData.totalTransferTime;
    if (srcData.dynamicOffsetSec !== undefined) copy.dynamicOffsetSec = srcData.dynamicOffsetSec;
    if (srcData.calculated_at !== undefined) copy.calculated_at = srcData.calculated_at;
    if (srcData.stages) {
        copy.stages = [];
        const len = srcData.stages.length;
        for (let si = 0; si < len; si++) {
            copy.stages[si] = _copyScheduleStage(srcData.stages[si]);
        }
    }
    return copy;
}

/** Copy single program stage struct field-by-field.
 *  PLC: ST_ProgramStage := src; */
function _copyProgramStage(src) {
    return {
        stage: src.stage,
        min_station: src.min_station,
        max_station: src.max_station,
        min_time: src.min_time,
        max_time: src.max_time,
        calc_time: src.calc_time
    };
}

/** Copy program (array of stage objects) field-by-field.
 *  PLC: FOR i:=0 TO count-1 DO program[i] := src[i]; */
function _copyProgram(srcProg) {
    if (!srcProg) return [];
    const result = [];
    const len = srcProg.length;
    for (let pi = 0; pi < len; pi++) {
        result[pi] = _copyProgramStage(srcProg[pi]);
    }
    return result;
}

/** Copy programs hash map field-by-field (each value is a program array). */
function _copyProgramsHashMap(srcMap) {
    const copy = {};
    if (!srcMap) return copy;
    for (const batchIdStr of Object.keys(srcMap)) {
        copy[batchIdStr] = _copyProgram(srcMap[batchIdStr]);
    }
    return copy;
}

/** Copy single task struct field-by-field.
 *  PLC: ST_Task := src; */
function _copyTask(src) {
    return {
        batch_id: src.batch_id,
        stage: src.stage,
        transporter_id: src.transporter_id,
        lift_station_id: src.lift_station_id,
        sink_station_id: src.sink_station_id,
        task_start_time: src.task_start_time,
        task_finished_time: src.task_finished_time,
        is_no_treatment: src.is_no_treatment,
        is_primary_destination: src.is_primary_destination,
        unit_id: src.unit_id,
        unit_target: src.unit_target,
        min_time_s: src.min_time_s,
        max_time_s: src.max_time_s,
        calc_time_s: src.calc_time_s,
        isInFlight: src.isInFlight
    };
}

/** Deep copy departureSandbox field-by-field.
 *  Sandbox uses hash maps internally (temporary calculation structure).
 *  PLC: Copies all sub-structures entry-by-entry. */
function _copyDepartureSandbox(src) {
    if (!src) return null;
    const sb = {};

    // Copy batches
    sb.batches = [];
    if (src.batches) {
        const len = src.batches.length;
        for (let i = 0; i < len; i++) {
            sb.batches[i] = _copyBatch(src.batches[i]);
        }
    }

    // Copy schedulesByBatchId (hash map of schedules)
    sb.schedulesByBatchId = {};
    if (src.schedulesByBatchId) {
        for (const batchIdStr of Object.keys(src.schedulesByBatchId)) {
            sb.schedulesByBatchId[batchIdStr] = _copySchedule(src.schedulesByBatchId[batchIdStr]);
        }
    }

    // Copy programsByBatchId (hash map of programs)
    sb.programsByBatchId = _copyProgramsHashMap(src.programsByBatchId);

    // Copy tasks
    sb.tasks = [];
    if (src.tasks) {
        const len = src.tasks.length;
        for (let i = 0; i < len; i++) {
            sb.tasks[i] = _copyTask(src.tasks[i]);
        }
    }

    return sb;
}

// ═══════════════════════════════════════════════════════════════════════════════
// APUFUNKTIOT
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Laske overlap-asemat: asemat joissa USEAMPI nostin voi toimia.
 * Vertaa jokaisen nostimen task_areas-alueita (lift + sink) ja etsii
 * asemanumerot jotka kuuluvat vähintään kahden eri nostimen alueisiin.
 * 
 * PLC: Palauttaa { flags: BOOL[MAX_STATIONS+1], count: INT } (Set-korvaaja).
 * 
 * @param {Array} transporters - Nostimet task_areas-tiedoilla
 * @returns {{ flags: boolean[], count: number }} Overlap-asemanumerot boolean-arrayna
 */
function computeOverlapStations(transporters) {
    // PLC: coverageCount[station] = kuinka monta nostinta kattaa aseman
    const coverageCount = [];
    for (let i = 0; i <= MAX_STATIONS; i++) coverageCount[i] = 0;

    for (let ti = 0; ti < (transporters ? transporters.length : 0); ti++) {
        const t = transporters[ti];
        if (!t.task_areas) continue;
        // PLC: BOOL-taulukko — estää saman aseman laskemisen kahdesti per nostin
        const covered = [];
        for (let i = 0; i <= MAX_STATIONS; i++) covered[i] = false;
        const areaKeys = Object.keys(t.task_areas);
        for (let ak = 0; ak < areaKeys.length; ak++) {
            const area = t.task_areas[areaKeys[ak]];
            const minLift = area.min_lift_station || 0;
            const maxLift = area.max_lift_station || 0;
            const minSink = area.min_sink_station || 0;
            const maxSink = area.max_sink_station || 0;
            if (minLift > 0 && maxLift > 0) {
                for (let n = minLift; n <= maxLift && n <= MAX_STATIONS; n++) {
                    if (!covered[n]) { covered[n] = true; coverageCount[n]++; }
                }
            }
            if (minSink > 0 && maxSink > 0) {
                for (let n = minSink; n <= maxSink && n <= MAX_STATIONS; n++) {
                    if (!covered[n]) { covered[n] = true; coverageCount[n]++; }
                }
            }
        }
    }

    const flags = [];
    let count = 0;
    for (let i = 0; i <= MAX_STATIONS; i++) {
        flags[i] = (coverageCount[i] > 1);
        if (flags[i]) count++;
    }
    return { flags: flags, count: count };
}

/**
 * Laske overlap-alueen viive yksittäiselle tehtävälle.
 * 
 * Jos tehtävä käyttää overlap-asemaa (nosto- tai laskuasema), tarkistaa
 * ettei mikään TOISEN nostimen tehtävä overlap-alueella ole samaan aikaan.
 * Jos konflikti löytyy, palauttaa tarvittavan viiveen (sekuntia) jotta
 * tehtävä voidaan aloittaa konfliktin jälkeen.
 * 
 * @param {Object} task - Tehtävä (lift_station_id, sink_station_id, transporter_id, task_start_time, task_finished_time)
 * @param {number} cumulativeShift - Kumulatiivinen viive aiemmista stageista
 * @param {Array} existingTasks - Olemassa olevat tehtävät (linja-erien)
 * @param {{ flags: boolean[], count: number }} overlapStations - Overlap-asemat boolean-arrayna
 * @param {number} [marginSec=2] - Turvamarginaali (sekuntia)
 * @returns {number} Tarvittava lisäviive (0 = ei konfliktia)
 */
function calculateOverlapDelay(task, cumulativeShift, existingTasks, overlapStations, marginSec) {
    if (!overlapStations || overlapStations.count === 0) return 0;
    
    const liftId = task.lift_station_id;
    const sinkId = task.sink_station_id;
    const isOverlap = (liftId >= 0 && liftId <= MAX_STATIONS && overlapStations.flags[liftId]) ||
                      (sinkId >= 0 && sinkId <= MAX_STATIONS && overlapStations.flags[sinkId]);
    if (!isOverlap) return 0;
    
    const taskDuration = task.task_finished_time - task.task_start_time;
    const tId = task.transporter_id;
    const margin = marginSec || 2;
    let adjustedStart = task.task_start_time + cumulativeShift;
    
    // Iteratiivinen haku: etsi ensimmäinen konfliktiton aikaikkuna (max 20 kierrosta)
    for (let iter = 0; iter < 20; iter++) {
        const adjustedEnd = adjustedStart + taskDuration;
        let foundConflict = false;
        let latestConflictEnd = adjustedStart;
        
        for (const existing of existingTasks) {
            if (existing.transporter_id === tId) continue;
            
            // Tarkista käyttääkö olemassa oleva tehtävä overlap-asemaa
            const eLift = existing.lift_station_id;
            const eSink = existing.sink_station_id;
            if (!(eLift >= 0 && eLift <= MAX_STATIONS && overlapStations.flags[eLift]) &&
                !(eSink >= 0 && eSink <= MAX_STATIONS && overlapStations.flags[eSink])) {
                continue;
            }
            
            // Aikakonflikti: tehtävät limittyvät ajallisesti (marginaalilla)
            if (adjustedStart < existing.task_finished_time + margin &&
                adjustedEnd > existing.task_start_time - margin) {
                foundConflict = true;
                latestConflictEnd = Math.max(latestConflictEnd, existing.task_finished_time + margin);
            }
        }
        
        if (!foundConflict) break;
        adjustedStart = latestConflictEnd;
    }
    
    return Math.max(0, adjustedStart - (task.task_start_time + cumulativeShift));
}

function summarizeTasks(label, tasks) {
    // PLC: Korvaa Map/Set yksinkertaisilla taulukoilla
    const batchIds = [];
    const batchCounts = [];
    const batchStages = [];  // taulukko taulukoita
    let batchGroupCount = 0;
    const taskArr = tasks || [];
    for (let ti = 0; ti < taskArr.length; ti++) {
        const t = taskArr[ti];
        const key = t.batch_id;
        let found = -1;
        for (let bi = 0; bi < batchGroupCount; bi++) {
            if (batchIds[bi] === key) { found = bi; break; }
        }
        if (found < 0) {
            found = batchGroupCount++;
            batchIds[found] = key;
            batchCounts[found] = 0;
            batchStages[found] = [];
        }
        batchCounts[found]++;
        // Add stage if not already present
        let stageExists = false;
        for (let si = 0; si < batchStages[found].length; si++) {
            if (batchStages[found][si] === t.stage) { stageExists = true; break; }
        }
        if (!stageExists) batchStages[found].push(t.stage);
    }
    let summary = '';
    for (let bi = 0; bi < batchGroupCount; bi++) {
        batchStages[bi].sort(function(a, b) { return a - b; });
        if (bi > 0) summary += '; ';
        summary += 'B' + batchIds[bi] + ':' + batchCounts[bi] + ' s[' + batchStages[bi].join(',') + ']';
    }
    log(label + ': ' + taskArr.length + ' tasks' + (summary ? ' (' + summary + ')' : ''));
}

/**
 * Calculate schedule for a waiting batch (stage 0 pre-calc + full schedule).
 * Called from CHECK_CREATE_TASKS — each waiting batch gets its own schedule.
 * Uses sandbox line tasks for idle-slot calculation.
 */
function calculateWaitingBatchSchedule(batch, batchId) {
    const program = _getProgram(batchId);
    if (!program) return null;
    
    const transporter = state.transporters[0];
    const now = ctx.currentTimeSec || 0;
    const baseTime = now;
    
    // 1. Line tasks from sandbox + in-flight
    // PLC: FOR-loop copy (korvaa spread-operaattori)
    const lineTasks = [];
    const _sbTasks = (state.departureSandbox ? state.departureSandbox.tasks : null) || [];
    for (let _li = 0; _li < _sbTasks.length; _li++) lineTasks[_li] = _sbTasks[_li];
    if (state._inFlightTasks && state._inFlightTasks.length > 0) {
        for (let _ifi = 0; _ifi < state._inFlightTasks.length; _ifi++) lineTasks.push(state._inFlightTasks[_ifi]);
    }
    
    // 2. Find stage 0 transporter
    // PLC: explicit null check (korvaa ?.)
    const firstStageStation = parseInt(program[0] ? program[0].min_station : 0, 10);
    const batchLoc = ctx.getBatchLocation(batch.batch_id);
    const pickupStation = scheduler.findStation(batchLoc, state.stations);
    let stage0Transporter = null;
    for (const t of state.transporters) {
        if (scheduler.canTransporterHandleTask(t, batchLoc, firstStageStation)) {
            stage0Transporter = t;
            break;
        }
    }
    if (!stage0Transporter) stage0Transporter = transporter;
    
    // 3. Idle slots for stage 0 transporter
    const tId = stage0Transporter.id;
    const idleSlots = scheduler.calculateTransporterIdleSlots(tId, lineTasks, now);
    
    // 4. Stage 0 calc time from idle slot + travel
    const maxInitWait = state.maxInitialWaitS || 120;
    let stage0CalcTime = 0;
    for (const slot of idleSlots) {
        if (slot.end <= now) continue;
        let travelToPickup = 0;
        if (pickupStation) {
            let fromStation = null;
            if (slot.prevTask) {
                fromStation = scheduler.findStation(slot.prevTask.sink_station_id, state.stations);
            } else {
                // PLC: FOR-loop (korvaa .find())
                let tCurrentState = null;
                const _tsArr1 = ctx.transporterStates || [];
                for (let _tsi = 0; _tsi < _tsArr1.length; _tsi++) { if (_tsArr1[_tsi].id === tId) { tCurrentState = _tsArr1[_tsi]; break; } }
                const currentX = (tCurrentState && tCurrentState.state) ? tCurrentState.state.x_position : undefined;
                if (currentX != null && Number.isFinite(currentX)) {
                    fromStation = { number: -1, x_position: currentX };
                } else if (stage0Transporter.start_station) {
                    fromStation = scheduler.findStation(stage0Transporter.start_station, state.stations);
                }
            }
            if (fromStation && fromStation.number !== pickupStation.number) {
                if (fromStation.number === -1) {
                    travelToPickup = scheduler.calculateHorizontalTravelTime(
                        fromStation, pickupStation, stage0Transporter
                    );
                } else {
                    const transfer = scheduler.calculateTransferTime(
                        fromStation, pickupStation, stage0Transporter,
                        ctx.movementTimes || null
                    );
                    // PLC: explicit null check (korvaa ?. ??)
                    travelToPickup = (transfer && transfer.phase3_travel_s != null) ? transfer.phase3_travel_s : 0;
                }
            }
        }
        const pickupTime = Math.max(slot.start, now) + travelToPickup;
        const waitTime = pickupTime - now;
        if (waitTime > maxInitWait) continue;
        stage0CalcTime = waitTime;
        break;
    }
    
    // 5. Write stage 0 times to batch
    const s0min = stage0CalcTime;
    const s0max = Math.max(s0min, 2 * s0min);
    batch.calc_time_s = stage0CalcTime;
    batch.min_time_s = s0min;
    batch.max_time_s = s0max;
    log('CHECK B' + batchId + ': stage 0 pre-calc → calc=' + stage0CalcTime.toFixed(1) + 's, min=' + s0min.toFixed(1) + 's, max=' + s0max.toFixed(1) + 's (T' + tId + ', ' + idleSlots.length + ' idle-slots)');
    
    // 6. Calculate full schedule
    const existingSchedules = [];
    for (let si = 0; si < state.scheduleCount; si++) {
        if (state.schedules[si].batchId !== batchId) {
            existingSchedules.push(state.schedules[si].data);
        }
    }
    // PLC: FOR-loop (korvaa .filter().map() → Set)
    const occupiedStations = new Set();
    const _cwUnits1 = ctx.units || [];
    for (let _ui = 0; _ui < _cwUnits1.length; _ui++) {
        const _u = _cwUnits1[_ui];
        if (_u.batch_id != null && _u.batch_id !== batch.batch_id && _u.location > 0) occupiedStations.add(_u.location);
    }
    const batchLocForCalc = ctx.getBatchLocation(batch.batch_id);
    const isOnTransporter = batchLocForCalc != null && batchLocForCalc < 100;
    let calcTransporterState = null;
    if (isOnTransporter) {
        // PLC: FOR-loop (korvaa .find())
        const _tsArr2 = ctx.transporterStates || [];
        for (let _tsi = 0; _tsi < _tsArr2.length; _tsi++) { if (_tsArr2[_tsi].id === batchLocForCalc) { calcTransporterState = _tsArr2[_tsi]; break; } }
    }
    
    try {
        const scheduleResult = scheduler.calculateBatchSchedule(
            batch, program, state.stations,
            isOnTransporter ? (function() { for (var _fi = 0; _fi < state.transporters.length; _fi++) { if (state.transporters[_fi].id === batchLocForCalc) return state.transporters[_fi]; } return transporter; })() : transporter,
            baseTime, batch.isDelayed, calcTransporterState,
            {
                movementTimes: ctx.movementTimes || null,
                lineSchedules: existingSchedules,
                occupiedStations: occupiedStations,
                stationIdleSince: ctx.stationIdleSince || new Map(),
                units: ctx.units || []
            }
        );
        
        if (scheduleResult) {
            scheduleResult.batchStage = batch.stage;
            scheduleResult.dynamicOffsetSec = baseTime - now;
            
            // PLC: FOR-loop (korvaa .find())
            let stage0Sched = null;
            if (scheduleResult.stages) { for (let _si = 0; _si < scheduleResult.stages.length; _si++) { if (scheduleResult.stages[_si].stage === 0) { stage0Sched = scheduleResult.stages[_si]; break; } } }
            if (stage0Sched) {
                // PLC: FOR-loop (korvaa .find())
                let sandboxBatch = null;
                if (state.departureSandbox && state.departureSandbox.batches) { for (let _sbi = 0; _sbi < state.departureSandbox.batches.length; _sbi++) { if (state.departureSandbox.batches[_sbi].batch_id === batchId) { sandboxBatch = state.departureSandbox.batches[_sbi]; break; } } }
                if (sandboxBatch) {
                    sandboxBatch.calc_time_s = stage0Sched.treatment_time_s;
                    sandboxBatch.min_time_s = stage0Sched.min_time_s;
                    sandboxBatch.max_time_s = stage0Sched.max_time_s;
                }
                batch.calc_time_s = stage0Sched.treatment_time_s;
                batch.min_time_s = stage0Sched.min_time_s;
                batch.max_time_s = stage0Sched.max_time_s;
                log('CHECK B' + batchId + ': stage 0 → calc=' + stage0Sched.treatment_time_s.toFixed(1) + 's, min=' + stage0Sched.min_time_s.toFixed(1) + 's, max=' + stage0Sched.max_time_s.toFixed(1) + 's');
            }
            
            _setSchedule(batchId, scheduleResult);
            state.departureSandbox.schedulesByBatchId[String(batchId)] = scheduleResult;
            _setWaitingSched(batchId, scheduleResult);
        }
        return scheduleResult;
    } catch (err) {
        log('CHECK B' + batchId + ' schedule error: ' + err.message);
        return null;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TICK - Pääsilmukka
// ═══════════════════════════════════════════════════════════════════════════════

async function tick(context) {
    ctx = context || {};
    
    const p = state.phase;
    let nextPhase = p;
    
    // Kasvata syklin tick-laskuria
    state.cycleTickCount++;
    
    // Päivitä TASKS-tilakoneen tila synkronointia varten
    state.tasksPhase = ctx.tasksPhase || 0;
    
    // PLC: tick-tila ring bufferiin
    log('TICK phase=' + p + ' (' + getPhaseName(p) + '), tasksPhase=' + state.tasksPhase + ', simTick=' + (ctx.simTick || 0));
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 0: WAITING_FOR_TASKS
    // Odota kunnes TASKS-tilakone on valmis (READY = 10000 tai SAVE = 10001)
    // ═══════════════════════════════════════════════════════════════════════════════
    if (p === PHASE.WAITING_FOR_TASKS) {
        const TASKS_READY = 10000;
        const TASKS_SAVE = 10001;
        const tasksConflictResolved = ctx.tasksConflictResolved || false;
        
        log('WAITING_FOR_TASKS: tasksPhase=' + state.tasksPhase + ', conflictResolved=' + tasksConflictResolved);
        
        // DEPARTURE odottaa kunnes:
        // 1. TASKS on valmis (phase >= READY)
        // 2. TASKS:n konfliktianalyysi on stabiili (conflictResolved = true)
        // Stabiili lähtötilanne takaa luotettavat idle-slotit.
        if (state.tasksPhase >= TASKS_READY && tasksConflictResolved) {
            log('TASKS ready & stable (phase=' + state.tasksPhase + ', conflictResolved=' + tasksConflictResolved + '), starting DEPARTURE cycle');
            state.lastTasksReadyTick = ctx.simTick || 0;
            nextPhase = PHASE.INIT;
        } else if (state.tasksPhase >= TASKS_READY && !tasksConflictResolved) {
            log('TASKS ready but conflicts unresolved — waiting for stable state');
        } else {
            log('Waiting for TASKS... (current: ' + state.tasksPhase + ')');
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 100: INIT
    // Kopioi tarvittava data kontekstista
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.INIT) {
        log('INIT: Loading raw data from context (no schedules — DEPARTURE calculates them)');
        // Syklin ajoituksen aloitus
        state.cycleStartTime = Date.now();
        state.cycleStartTick = Number.isFinite(Number(ctx.simTick)) ? Number(ctx.simTick) : 0;
        state.cycleTickCount = 0;
        const periodMs = Number(ctx.tickPeriodMs);
        const dtMs = Number(ctx.tickDtMs);
        // Departure saa tickin joka toinen PLC-tick → efektiivinen jakso = 2×
        state.cycleTickPeriodMs = Number.isFinite(periodMs) ? periodMs * 2 : (Number.isFinite(dtMs) ? dtMs * 2 : 0);
        
        // Kopioi RAAKADATA kontekstista - DEEP COPY kaikelle!
        // PLC-vastine: FB:n IN-parametrit ovat aina kopioita DB:stä.
        // JavaScript-viitteet vaativat eksplisiittisen kopioinnin,
        // jotta departure ei mutatoi server.js:n live-dataa.
        //
        // HUOM: schedulesByBatchId EI kopioida TASKS:lta!
        // DEPARTURE laskee KAIKKI aikataulut itse DEPARTURE_CALC -vaiheessa.
        state.batches = ctx.batches ? _copyBatchesArray(ctx.batches) : [];
        // PLC: FOR-loop copy (korvaa .slice())
        state.stations = [];
        if (ctx.stations) { for (let _si = 0; _si < ctx.stations.length; _si++) state.stations[_si] = ctx.stations[_si]; }
        state.transporters = [];
        if (ctx.transporters) { for (let _ti = 0; _ti < ctx.transporters.length; _ti++) state.transporters[_ti] = ctx.transporters[_ti]; }
        state.transporterStates = ctx.transporterStates ? _copyTransporterStatesArray(ctx.transporterStates) : [];
        // schedules EI nollata tässä — API lukee sen suoraan.
        // Käytetään _calcScheds-välimuistia laskennassa, korvataan atomisesti CALC_DONE:ssa.
        state._calcScheds = [];
        state._calcSchedCount = 0;
        
        // Säilytä odottavan erän sandboxin ohjelma ja batch-tiedot jos samaa erää jatketaan (round > 0)
        // Stage 0 viive kirjataan sandbox-batchin calc_time_s:ään, ja sen pitää säilyä
        // kierrosten välillä jotta seuraava kierros laskee aikataulun viiveen kanssa.
        const continuingBatchId = state._currentDepartureBatchId;
        let savedWaitingProgram = null;
        let savedWaitingBatchTimes = null;
        if (continuingBatchId && state.departureSandbox && state.departureSandbox.programsByBatchId && state.departureSandbox.programsByBatchId[String(continuingBatchId)]) {
            savedWaitingProgram = _copyProgram(
                state.departureSandbox.programsByBatchId[String(continuingBatchId)]
            );
            // Säilytä myös sandbox-batchin calc_time_s/min_time_s/max_time_s (stage 0 viive)
            // PLC: FOR-loop (korvaa .find())
            let savedBatch = null;
            if (state.departureSandbox.batches) { for (let _sbi = 0; _sbi < state.departureSandbox.batches.length; _sbi++) { if (state.departureSandbox.batches[_sbi].batch_id === continuingBatchId) { savedBatch = state.departureSandbox.batches[_sbi]; break; } } }
            if (savedBatch) {
                savedWaitingBatchTimes = {
                    calc_time_s: savedBatch.calc_time_s,
                    min_time_s: savedBatch.min_time_s,
                    max_time_s: savedBatch.max_time_s
                };
            }
            // PLC: explicit null checks (korvaa ?.)
            var _calcStr = (savedWaitingBatchTimes && savedWaitingBatchTimes.calc_time_s != null && typeof savedWaitingBatchTimes.calc_time_s.toFixed === 'function') ? savedWaitingBatchTimes.calc_time_s.toFixed(1) : '?';
            log('INIT: Säilytetään B' + continuingBatchId + ' sandboxin ohjelma ja batch-ajat (round=' + state.departureRound + ', calc=' + _calcStr + 's)');
        }
        
        _programsFromHashMap(ctx.programsByBatchId ? _copyProgramsHashMap(ctx.programsByBatchId) : {});
        
        // Luo puhdas sandbox (ei valmiita aikatauluja, ei TASKS:n taskeja)
        // Sandbox käyttää hash map -muotoa sisäisesti (väliaikainen laskentarakenne)
        state.departureSandbox = {
            batches: _copyBatchesArray(state.batches),
            schedulesByBatchId: {},  // Lasketaan DEPARTURE_CALC:ssa
            programsByBatchId: _copyProgramsHashMap(_programsToHashMap()),
            tasks: []  // Rakennetaan schedulen pohjalta
        };
        
        // Palauta säilytetty ohjelma sandboxiin ja state:een
        if (continuingBatchId && savedWaitingProgram) {
            state.departureSandbox.programsByBatchId[String(continuingBatchId)] = savedWaitingProgram;
            _setProgram(continuingBatchId, _copyProgram(savedWaitingProgram));
            log('INIT: Palautettu B' + continuingBatchId + ' ohjelma sandboxista (viiveet säilytetty)');
        }
        
        // Nollaa kierroksen muuttujat
        state.waitingBatches = [];
        state.waitingScheds = []; state.waitingSchedCount = 0;
        state.waitingAnalyses = []; state.waitingAnalysisCount = 0;
        state.waitingTaskSets = []; state.waitingTaskSetCount = 0;
        state.departureCandidateStretches = [];
        state.departureLockedStages = []; state.depLockedStageCount = 0;
        state.departureIteration = 0;
        state.lastDepartureConflict = null;
        
        nextPhase = PHASE.DEPARTURE_CALC_START;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 1000: DEPARTURE_CALC_START
    // Collect ALL batches that need schedule calculation:
    //   - Line batches (stage 1-60): active in the line
    //   - Waiting batches (stage 90): waiting for departure permission
    // DEPARTURE calculates ALL schedules itself from programs.
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.DEPARTURE_CALC_START) {
        // Collect ALL batches needing schedules: line batches first, then waiting
        state.allCalcBatches = [];  // Indices into state.batches
        state.waitingBatches = [];
        
        for (let i = 0; i < state.batches.length; i++) {
            const batch = state.batches[i];
            if (!batch) continue;
            
            if (batch.stage >= 0 && batch.stage <= 89) {
                // Line batch — needs schedule
                state.allCalcBatches.push(i);
            } else if (batch.stage === 90) {
                // Waiting batch — schedule calculated per-batch in CHECK_CREATE_TASKS
                // Only add to waitingBatches, NOT allCalcBatches
                const unitForBatch = ctx.getUnitByBatchId ? ctx.getUnitByBatchId(batch.batch_id) : null;
                if (unitForBatch && unitForBatch.target && unitForBatch.target !== 'none') {
                    log('CALC_START: B' + batch.batch_id + ' stage=90 SKIP — unit U' + unitForBatch.unit_id + ' target=\'' + unitForBatch.target + '\' (not \'none\')');
                    continue;
                }
                state.waitingBatches.push(i);
                // Populate analysis metadata for SORT (no schedule needed)
                const prog = _getProgram(batch.batch_id);
                _setWaitingAnalysis(batch.batch_id, {
                    batch_id: batch.batch_id,
                    program_id: batch.treatment_program,
                    loaded_s: batch.loaded_s || batch.start_time_s || 0,
                    stage_count: prog ? prog.length : 0
                });
            }
            // stage 0, 61-89, 91+: skip
        }
        
        state.waitingBatchCount = state.waitingBatches.length;
        state.allCalcCount = state.allCalcBatches.length;
        state.currentCalcIndex = 0;
        state.currentWaitingIndex = 0;
        
        log('CALC_START: ' + state.allCalcBatches.length + ' line batches to calculate, ' + state.waitingBatches.length + ' waiting for CHECK phase');
        
        // ═══════════════════════════════════════════════════════════════
        // Rakenna in-flight-tehtävät nostimien tiloista.
        // Kun erä on nostimessa, meneillään oleva siirto (lift→sink) ei
        // näy schedule-pohjaisissa tehtävälistoissa koska aikataulu alkaa
        // vasta seuraavasta stagesta. In-flight-tehtävä varmistaa:
        //   1) Idle-slot-laskenta näkee nostimen varattuna est_finish:iin asti
        //   2) Odottavan erän stage0CalcTime lasketaan oikein
        // ═══════════════════════════════════════════════════════════════
        state._inFlightTasks = [];
        for (const t of (ctx.transporterStates || [])) {
            // PLC: explicit null check (korvaa ?.)
            const s = (t != null) ? t.state : null;
            if (!s || s.phase === 0) continue;
            if (s.current_task_batch_id == null) continue;
            const estFinish = Number(s.current_task_est_finish_s);
            if (!Number.isFinite(estFinish) || estFinish <= 0) continue;
            
            state._inFlightTasks.push({
                batch_id: s.current_task_batch_id,
                transporter_id: t.id,
                lift_station_id: s.current_task_lift_station_id || s.lift_station_target,
                sink_station_id: s.current_task_sink_station_id || s.sink_station_target,
                task_start_time: ctx.currentTimeSec || 0,
                task_finished_time: estFinish,
                stage: -1,  // pseudo-stage: meneillään oleva siirto
                isInFlight: true
            });
            log('CALC_START: In-flight T' + t.id + ' B' + s.current_task_batch_id + ' ' + s.current_task_lift_station_id + '→' + s.current_task_sink_station_id + ' est_finish=' + estFinish.toFixed(1) + 's');
        }
        
        if (state.allCalcCount > 0) {
            nextPhase = PHASE.DEPARTURE_CALC_START + 1;  // 1001
        } else {
            log('No batches to calculate');
            nextPhase = PHASE.DEPARTURE_CALC_DONE;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 1001-1099: DEPARTURE_CALC
    // Calculate schedule for each batch (line + waiting)
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p >= PHASE.DEPARTURE_CALC_START + 1 && p <= PHASE.DEPARTURE_CALC_END) {
        const calcIndex = state.currentCalcIndex;
        
        if (calcIndex >= state.allCalcCount) {
            nextPhase = PHASE.DEPARTURE_CALC_DONE;
        } else {
            const batchIndex = state.allCalcBatches[calcIndex];
            const batch = state.batches[batchIndex];
            // PLC: explicit null check (korvaa ?.)
            const batchId = batch ? batch.batch_id : null;
            const isWaiting = batch ? batch.stage === 90 : false;
            
            if (batch && batchId) {
                log('CALC B' + batchId + ' stage=' + batch.stage + ' (' + (calcIndex + 1) + '/' + state.allCalcCount + ')' + (isWaiting ? ' [WAITING]' : ''));
                
                const program = _getProgram(batchId);
                
                if (program) {
                    const transporter = state.transporters[0];
                    const now = ctx.currentTimeSec || 0;
                    
                    // Base time = now (kaikille erille, myös odottaville)
                    const baseTime = now;
                    
                    // ═══════════════════════════════════════════════════════════════
                    // Odottavan erän stage 0 -ajat ENNEN aikataulun laskentaa
                    // (departure_target_description.md: "Ensimmäisen tehtävän ajoitus")
                    //
                    // CalcTime = MinTime = pickup_time - start_time
                    //   pickup_time = idle_start + travel(idle_start_pos → pickup_station)
                    //   start_time  = now (currentTimeSec)
                    // MaxTime = 2 × MinTime
                    //
                    // Näin calculateBatchSchedule saa oikean stage 0:n keston,
                    // ja koko aikataulun stage 1+ ajoitus on oikein alusta alkaen.
                    // ═══════════════════════════════════════════════════════════════
                    if (isWaiting) {
                        // 1. Rakenna tehtävälista jo lasketuista linja-erien aikatauluista
                        const lineTasks = [];
                        for (let ci = 0; ci < state._calcSchedCount; ci++) {
                            const calcEntry = state._calcScheds[ci];
                            // PLC: FOR-loop (korvaa .find())
                            let lineBatch = null;
                            for (let _bi = 0; _bi < state.batches.length; _bi++) { if (state.batches[_bi].batch_id === calcEntry.batchId) { lineBatch = state.batches[_bi]; break; } }
                            if (lineBatch && calcEntry.data) {
                                const tasks = scheduler.createTaskListFromSchedule(calcEntry.data, lineBatch, state.transporters);
                                // PLC: FOR-loop (korvaa .push(...spread))
                                for (let _ti = 0; _ti < tasks.length; _ti++) lineTasks.push(tasks[_ti]);
                            }
                        }
                        
                        // 1b. Lisää in-flight-tehtävät → nostimien meneillään olevat
                        //     siirrot näkyvät idle-sloteissa (varaus now→est_finish)
                        if (state._inFlightTasks && state._inFlightTasks.length > 0) {
                            for (const ift of state._inFlightTasks) {
                                lineTasks.push(ift);
                            }
                            log('CALC B' + batchId + ': Added ' + state._inFlightTasks.length + ' in-flight tasks to lineTasks');
                        }
                        
                        // 2. Selvitä mikä nostin hoitaa ensimmäisen siirron
                        // PLC: explicit null check (korvaa ?.)
                        const firstStageStation = parseInt(program[0] ? program[0].min_station : 0, 10);
                        const batchLoc = ctx.getBatchLocation(batch.batch_id);
                        const pickupStation = scheduler.findStation(batchLoc, state.stations);
                        let stage0Transporter = null;
                        for (const t of state.transporters) {
                            if (scheduler.canTransporterHandleTask(t, batchLoc, firstStageStation)) {
                                stage0Transporter = t;
                                break;
                            }
                        }
                        if (!stage0Transporter) stage0Transporter = transporter;
                        
                        // 3. Laske idle-slotit tälle nostimelle
                        const tId = stage0Transporter.id;
                        const idleSlots = scheduler.calculateTransporterIdleSlots(tId, lineTasks, now);
                        
                        // 4. Etsi ensimmäinen sopiva idle-slot ja laske pickup_time
                        const maxInitWait = state.maxInitialWaitS || 120;
                        let stage0CalcTime = 0;
                        
                        for (const slot of idleSlots) {
                            if (slot.end <= now) continue;
                            
                            // idle_start_pos: edellisen tehtävän sink tai nostimen TODELLINEN sijainti
                            // Nostin ajaa TYHJÄNÄ hakemaan erää → vain matka-aika (phase3),
                            // EI nosto+lasku -sykliä (calculateTransferTime laskee koko syklin).
                            let travelToPickup = 0;
                            if (pickupStation) {
                                let fromStation = null;
                                if (slot.prevTask) {
                                    fromStation = scheduler.findStation(slot.prevTask.sink_station_id, state.stations);
                                } else {
                                    // Ensimmäinen idle-slot ilman edeltävää tehtävää:
                                    // Käytä nostimen TODELLISTA sijaintia, ei konfiguraation start_station:ia.
                                    // PLC: FOR-loop (korvaa .find())
                                    let tCurrentState = null;
                                    const _tsArr3 = ctx.transporterStates || [];
                                    for (let _tsi = 0; _tsi < _tsArr3.length; _tsi++) { if (_tsArr3[_tsi].id === tId) { tCurrentState = _tsArr3[_tsi]; break; } }
                                    const currentX = (tCurrentState && tCurrentState.state) ? tCurrentState.state.x_position : undefined;
                                    if (currentX != null && Number.isFinite(currentX)) {
                                        // Luo virtuaalinen "asema" nostimen x-positiosta
                                        fromStation = { number: -1, x_position: currentX };
                                    } else if (stage0Transporter.start_station) {
                                        fromStation = scheduler.findStation(stage0Transporter.start_station, state.stations);
                                    }
                                }
                                if (fromStation && fromStation.number !== pickupStation.number) {
                                    // Virtuaaliasemalle tai eri asemalle: laske matka-aika suoraan
                                    if (fromStation.number === -1) {
                                        // Virtuaalinen sijainti → laske suoraan x-etäisyydestä
                                        travelToPickup = scheduler.calculateHorizontalTravelTime(
                                            fromStation, pickupStation, stage0Transporter
                                        );
                                    } else {
                                        const transfer = scheduler.calculateTransferTime(
                                            fromStation, pickupStation, stage0Transporter,
                                            ctx.movementTimes || null
                                        );
                                        // PLC: explicit null check (korvaa ?. ??)
                                        travelToPickup = (transfer && transfer.phase3_travel_s != null) ? transfer.phase3_travel_s : 0;
                                    }
                                }
                            }
                            
                            const pickupTime = Math.max(slot.start, now) + travelToPickup;
                            const waitTime = pickupTime - now;
                            
                            if (waitTime > maxInitWait) continue;  // Liian kaukana
                            
                            stage0CalcTime = waitTime;
                            break;
                        }
                        
                        // 5. Kirjoita batch-tietoihin → calculateBatchSchedule lukee nämä
                        const minTime = stage0CalcTime;
                        const maxTime = Math.max(minTime, 2 * minTime);
                        batch.calc_time_s = stage0CalcTime;
                        batch.min_time_s = minTime;
                        batch.max_time_s = maxTime;
                        log('CALC B' + batchId + ': stage 0 pre-calc → calc=' + stage0CalcTime.toFixed(1) + 's, min=' + minTime.toFixed(1) + 's, max=' + maxTime.toFixed(1) + 's (T' + tId + ', ' + idleSlots.length + ' idle-slots)');
                    }
                    
                    try {
                        // Other batch schedules for parallel station selection (use current calc results)
                        const existingSchedules = [];
                        for (let ci = 0; ci < state._calcSchedCount; ci++) {
                            if (state._calcScheds[ci].batchId !== batchId) {
                                existingSchedules.push(state._calcScheds[ci].data);
                            }
                        }
                        
                        // PLC: FOR-loop (korvaa .filter().map() → Set)
                        const occupiedStations = new Set();
                        const _dcUnits = ctx.units || [];
                        for (let _ui = 0; _ui < _dcUnits.length; _ui++) {
                            const _u = _dcUnits[_ui];
                            if (_u.batch_id != null && _u.batch_id !== batch.batch_id && _u.location > 0) occupiedStations.add(_u.location);
                        }
                        
                        // Etsi nostimen tila jos erä on nostimessa
                        // → calculateBatchSchedule käyttää est_finish_s:ää entry_time:na
                        const batchLocForCalc = ctx.getBatchLocation(batch.batch_id);
                        const isOnTransporter = batchLocForCalc != null && batchLocForCalc < 100;
                        let calcTransporterState = null;
                        if (isOnTransporter) {
                            // PLC: FOR-loop (korvaa .find())
                            const _tsArr4 = ctx.transporterStates || [];
                            for (let _tsi = 0; _tsi < _tsArr4.length; _tsi++) { if (_tsArr4[_tsi].id === batchLocForCalc) { calcTransporterState = _tsArr4[_tsi]; break; } }
                        }
                        
                        const scheduleResult = scheduler.calculateBatchSchedule(
                            batch,
                            program,
                            state.stations,
                            isOnTransporter ? (function() { for (var _fi = 0; _fi < state.transporters.length; _fi++) { if (state.transporters[_fi].id === batchLocForCalc) return state.transporters[_fi]; } return transporter; })() : transporter,
                            baseTime,
                            batch.isDelayed,
                            calcTransporterState,
                            { 
                                movementTimes: ctx.movementTimes || null,
                                lineSchedules: existingSchedules,
                                occupiedStations: occupiedStations,
                                stationIdleSince: ctx.stationIdleSince || new Map(),
                                units: ctx.units || []
                            }
                        );
                        
                        if (scheduleResult) {
                            scheduleResult.batchStage = batch.stage;
                            if (isWaiting) {
                                scheduleResult.dynamicOffsetSec = baseTime - now;
                                
                                // Kirjoita stage 0:n calc_time sandbox-batchiin
                                // ACTIVATE lukee sandbox.batches — EI state.batches!
                                // PLC: FOR-loop (korvaa .find())
                                let stage0 = null;
                                if (scheduleResult.stages) { for (let _si = 0; _si < scheduleResult.stages.length; _si++) { if (scheduleResult.stages[_si].stage === 0) { stage0 = scheduleResult.stages[_si]; break; } } }
                                if (stage0) {
                                    // PLC: FOR-loop (korvaa .find())
                                    let sandboxBatch = null;
                                    if (state.departureSandbox && state.departureSandbox.batches) { for (let _sbi = 0; _sbi < state.departureSandbox.batches.length; _sbi++) { if (state.departureSandbox.batches[_sbi].batch_id === batchId) { sandboxBatch = state.departureSandbox.batches[_sbi]; break; } } }
                                    if (sandboxBatch) {
                                        sandboxBatch.calc_time_s = stage0.treatment_time_s;
                                        sandboxBatch.min_time_s = stage0.min_time_s;
                                        sandboxBatch.max_time_s = stage0.max_time_s;
                                    }
                                    // Kirjoita myös state.batches:iin (resolver lukee tätä)
                                    batch.calc_time_s = stage0.treatment_time_s;
                                    batch.min_time_s = stage0.min_time_s;
                                    batch.max_time_s = stage0.max_time_s;
                                    log('CALC B' + batchId + ': stage 0 → calc=' + stage0.treatment_time_s.toFixed(1) + 's, min=' + stage0.min_time_s.toFixed(1) + 's, max=' + stage0.max_time_s.toFixed(1) + 's');
                                }
                            }
                            
                            // Store in _calcScheds (temp buffer, swapped to schedules in CALC_DONE)
                            _setCalcSched(batchId, scheduleResult);
                            state.departureSandbox.schedulesByBatchId[String(batchId)] = scheduleResult;
                            
                            if (isWaiting) {
                                _setWaitingSched(batchId, scheduleResult);
                                _setWaitingAnalysis(batchId, {
                                    batch_id: batchId,
                                    program_id: batch.treatment_program,
                                    loaded_s: batch.loaded_s || batch.start_time_s || 0,
                                    stage_count: program.length
                                });
                            }
                        }
                    } catch (err) {
                        log('CALC B' + batchId + ' error: ' + err.message);
                    }
                }
            }
            
            state.currentCalcIndex++;
            if (state.currentCalcIndex < state.allCalcCount) {
                nextPhase = p + 1;
                if (nextPhase > PHASE.DEPARTURE_CALC_END) {
                    nextPhase = PHASE.DEPARTURE_CALC_DONE;
                }
            } else {
                nextPhase = PHASE.DEPARTURE_CALC_DONE;
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 1900: DEPARTURE_CALC_DONE
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.DEPARTURE_CALC_DONE) {
        // Atomic swap: copy _calcScheds → schedules (PLC: indexed array copy)
        state.schedules = [];
        state.scheduleCount = 0;
        for (let ci = 0; ci < state._calcSchedCount; ci++) {
            state.schedules[state.scheduleCount++] = { batchId: state._calcScheds[ci].batchId, data: state._calcScheds[ci].data };
        }
        state._calcScheds = [];
        state._calcSchedCount = 0;
        
        const totalSchedules = state.scheduleCount;
        const waitingSchedTotal = state.waitingSchedCount;
        log('CALC done: ' + totalSchedules + ' total schedules (' + (totalSchedules - waitingSchedTotal) + ' line + ' + waitingSchedTotal + ' waiting)');
        
        // Build sandbox tasks from ALL calculated schedules
        const allTasks = [];
        for (let si = 0; si < state.scheduleCount; si++) {
            const schedule = state.schedules[si].data;
            if (!schedule || !schedule.stages) continue;
            // PLC: FOR-loop (korvaa .find())
            let batch = null;
            for (let _bi = 0; _bi < state.batches.length; _bi++) { if (state.batches[_bi].batch_id === state.schedules[si].batchId) { batch = state.batches[_bi]; break; } }
            if (!batch) continue;
            // Only non-waiting batch tasks go into sandbox.tasks (waiting batch tasks are added per-check)
            if (batch.stage !== 90) {
                const tasks = scheduler.createTaskListFromSchedule(schedule, batch, state.transporters);
                // PLC: FOR-loop (korvaa .push(...spread))
                for (let _ti = 0; _ti < tasks.length; _ti++) allTasks.push(tasks[_ti]);
            }
        }
        state.departureSandbox.tasks = allTasks;
        log('Built ' + allTasks.length + ' sandbox tasks from line batch schedules');
        
        nextPhase = PHASE.WAITING_SORT_START;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 2000-2900: WAITING_SORT
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.WAITING_SORT_START) {
        log('SORT start');
        nextPhase = PHASE.WAITING_SORT_LOADED;
    }
    
    else if (p === PHASE.WAITING_SORT_LOADED) {
        if (state.waitingBatches.length > 1) {
            // PLC: _insertionSort (korvaa .sort())
            _insertionSort(state.waitingBatches, state.waitingBatches.length, function(aIdx, bIdx) {
                const batchA = state.batches[aIdx];
                const batchB = state.batches[bIdx];
                const analysisA = _getWaitingAnalysis(batchA ? batchA.batch_id : undefined) || {};
                const analysisB = _getWaitingAnalysis(batchB ? batchB.batch_id : undefined) || {};
                const loadedA = analysisA.loaded_s || (batchA ? batchA.loaded_s : 0) || (batchA ? batchA.start_time_s : 0) || 0;
                const loadedB = analysisB.loaded_s || (batchB ? batchB.loaded_s : 0) || (batchB ? batchB.start_time_s : 0) || 0;
                return loadedA - loadedB;
            });
            log('Sorted ' + state.waitingBatches.length + ' batches by loaded_s (FIFO)');
        }
        
        state.currentWaitingIndex = 0;
        nextPhase = PHASE.WAITING_SORT_DONE;
    }
    
    else if (p === PHASE.WAITING_SORT_DONE) {
        log('SORT done');
        nextPhase = PHASE.CHECK_START;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3000: CHECK_START
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_START) {
        state.pendingDelay = null;
        state.pendingDelays = [];
        state.departureAnalysis = null;
        
        log('CHECK_START: waitingBatchCount=' + state.waitingBatchCount + ', currentIndex=' + state.currentWaitingIndex);
        if (state.waitingBatches && state.waitingBatches.length > 0) {
            for (let i = 0; i < state.waitingBatches.length; i++) {
                const bIdx = state.waitingBatches[i];
                const b = state.batches[bIdx];
                // PLC: explicit null check (korvaa ?.)
                log('  [' + i + '] B' + (b ? b.batch_id : '?') + ' stage=' + (b ? b.stage : '?') + ' location=' + (b ? b.location : '?'));
            }
        }
        
        if (state.waitingBatchCount === 0) {
            log('No waiting batches → back to WAITING_FOR_TASKS');
            nextPhase = PHASE.WAITING_FOR_TASKS;
        } else if (state.currentWaitingIndex >= state.waitingBatchCount) {
            log('All batches processed, no departure granted → back to WAITING_FOR_TASKS');
            nextPhase = PHASE.WAITING_FOR_TASKS;
        } else {
            log('CHECK: ' + state.waitingBatchCount + ' waiting, index=' + state.currentWaitingIndex);
            nextPhase = PHASE.CHECK_CREATE_TASKS;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3001: CHECK_CREATE_TASKS
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_CREATE_TASKS) {
        const batchIndex = state.waitingBatches[state.currentWaitingIndex];
        const batch = state.batches[batchIndex];
        // PLC: explicit null check (korvaa ?.)
        const batchId = batch ? batch.batch_id : null;
        
        if (!batch || !batchId) {
            state.currentWaitingIndex++;
            nextPhase = PHASE.CHECK_START;
        } else {
            log('CHECK B' + batchId + ': Create tasks');
            
            // Nollaa kierroslaskuri ja snapshot VAIN kun erä vaihtuu
            // (saman erän jatko-kierroksilla sandbox ja round säilyvät)
            if (state._currentDepartureBatchId !== batchId) {
                state._currentDepartureBatchId = batchId;
                state.sandboxSnapshot = _copyDepartureSandbox(state.departureSandbox);
                state.departureRound = 0;  // Kierroslaskuri tälle erälle
                log('New batch B' + batchId + ' — reset round=0, fresh snapshot');
            } else {
                log('Continue batch B' + batchId + ' — round=' + state.departureRound + ', keeping sandbox');
            }
            state.departureCandidateStretches = [];
            state.departureIteration = 0;
            
            // Calculate schedule for this waiting batch (if not already done by RECALC)
            if (!_getWaitingSched(batchId)) {
                calculateWaitingBatchSchedule(batch, batchId);
            }
            
            const schedule = _getWaitingSched(batchId);
            
            if (!schedule || !schedule.stages) {
                state.currentWaitingIndex++;
                nextPhase = PHASE.CHECK_START;
            } else {
                // DEBUG: Näytä schedulen joustovarat
                log('DEBUG B' + batchId + ' schedule stages:');
                // PLC: FOR-loop (korvaa .slice(0, 5))
                const _stgLimit1 = Math.min(schedule.stages.length, 5);
                for (let _di = 0; _di < _stgLimit1; _di++) {
                    const s = schedule.stages[_di];
                    log('  stage ' + s.stage + ': treatment=' + s.treatment_time_s + 's, min=' + s.min_time_s + 's, max=' + s.max_time_s + 's');
                }
                
                const tasks = scheduler.createTaskListFromSchedule(
                    schedule,
                    batch,
                    state.transporters
                );
                
                _setWaitingTaskSet(batchId, tasks);
                
                // Lue in-flight tehtävät
                const inFlightTasks = [];
                for (const t of (ctx.transporterStates || [])) {
                    // PLC: explicit null check (korvaa ?.)
                    const s = (t != null) ? t.state : null;
                    if (!s || s.phase === 0) continue;
                    
                    let pendingBatchId = s.pending_batch_id;
                    const liftStation = s.lift_station_target;
                    const sinkStation = s.sink_station_target;
                    
                    if (pendingBatchId == null && s.phase > 0) {
                        const unitOnT = ctx.getUnitAtLocation(t.id);
                        // PLC: FOR-loop (korvaa .find())
                        let batchOnTransporter = null;
                        if (unitOnT) { for (let _bi = 0; _bi < state.batches.length; _bi++) { if (state.batches[_bi].batch_id === unitOnT.batch_id) { batchOnTransporter = state.batches[_bi]; break; } } }
                        if (batchOnTransporter) pendingBatchId = batchOnTransporter.batch_id;
                    }
                    
                    if (pendingBatchId != null && liftStation != null && sinkStation != null) {
                        // PLC: FOR-loop (korvaa .find())
                        let batchObj = null;
                        for (let _bi = 0; _bi < state.batches.length; _bi++) { if (state.batches[_bi].batch_id === pendingBatchId) { batchObj = state.batches[_bi]; break; } }
                        const inferredStage = (batchObj ? batchObj.stage : 0) || 0;
                        
                        const batchSchedule = (state.departureSandbox && state.departureSandbox.schedulesByBatchId) ? state.departureSandbox.schedulesByBatchId[String(pendingBatchId)] : null;
                        // PLC: FOR-loop (korvaa .find())
                        let sinkStageSchedule = null;
                        if (batchSchedule && batchSchedule.stages) { for (let _si = 0; _si < batchSchedule.stages.length; _si++) { if (batchSchedule.stages[_si].station_id === sinkStation) { sinkStageSchedule = batchSchedule.stages[_si]; break; } } }
                        const taskFinishedTime = (sinkStageSchedule ? sinkStageSchedule.entry_time : null) || (ctx.currentTimeSec + 60);
                        let liftStageSchedule = null;
                        if (batchSchedule && batchSchedule.stages) { for (let _si = 0; _si < batchSchedule.stages.length; _si++) { if (batchSchedule.stages[_si].station_id === liftStation) { liftStageSchedule = batchSchedule.stages[_si]; break; } } }
                        const taskStartTime = (liftStageSchedule ? liftStageSchedule.exit_time : null) || ctx.currentTimeSec;
                        
                        inFlightTasks.push({
                            batch_id: pendingBatchId,
                            transporter_id: t.id,
                            lift_station_id: liftStation,
                            sink_station_id: sinkStation,
                            task_start_time: taskStartTime,
                            task_finished_time: taskFinishedTime,
                            stage: inferredStage,
                            isInFlight: true
                        });
                    }
                }
                
                // Yhdistä: in-flight + sandbox + odottavan erän tehtävät
                let sandboxTasks = (state.departureSandbox ? state.departureSandbox.tasks : null) || [];
                
                // DEBUG: Näytä sandboxin tehtävien joustovarat
                log('DEBUG Sandbox tasks (' + sandboxTasks.length + '):');
                // PLC: FOR-loop (korvaa .slice(0, 5))
                const _sbLimit = Math.min(sandboxTasks.length, 5);
                for (let _di = 0; _di < _sbLimit; _di++) {
                    const t = sandboxTasks[_di];
                    log('  B' + t.batch_id + 's' + t.stage + ': calc=' + t.calc_time_s + 's, min=' + t.min_time_s + 's, max=' + t.max_time_s + 's');
                }
                
                // Suodata pois in-flight tehtävät (korvataan tuoreemmilla)
                // PLC: lineaarinen haku avaintaulukkoon (korvaa Set)
                if (inFlightTasks.length > 0) {
                    const ifKeys = [];
                    for (let ifi = 0; ifi < inFlightTasks.length; ifi++) {
                        ifKeys[ifi] = inFlightTasks[ifi].batch_id + '_' + inFlightTasks[ifi].stage;
                    }
                    const filtered = [];
                    for (let si = 0; si < sandboxTasks.length; si++) {
                        const key = sandboxTasks[si].batch_id + '_' + sandboxTasks[si].stage;
                        let isInFlight = false;
                        for (let ki = 0; ki < ifKeys.length; ki++) {
                            if (ifKeys[ki] === key) { isInFlight = true; break; }
                        }
                        if (!isInFlight) filtered.push(sandboxTasks[si]);
                    }
                    sandboxTasks = filtered;
                }
                
                // combinedTasks = vain linja-erien taskit (in-flight + sandbox)
                // Odottavan erän taskit EIVÄT kuulu tänne — ne haetaan erikseen CHECK_ANALYZE:ssa
                // waitingBatchTasks-mapista. Jos ne olisivat täällä, SORT ja SWAP sotkisivat
                // linja-erien taskijärjestyksen ja idle-slotit laskettaisiin väärin.
                // PLC: FOR-loop concat (korvaa [...spread])
                state.combinedTasks = [];
                for (let _ci = 0; _ci < inFlightTasks.length; _ci++) state.combinedTasks.push(inFlightTasks[_ci]);
                for (let _ci = 0; _ci < sandboxTasks.length; _ci++) state.combinedTasks.push(sandboxTasks[_ci]);
                log('Combined: ' + inFlightTasks.length + ' in-flight + ' + sandboxTasks.length + ' sandbox = ' + state.combinedTasks.length + ' total (waiting B' + batchId + ': ' + tasks.length + ' tasks separate)');
                
                nextPhase = PHASE.CHECK_SORT;
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3002: CHECK_SORT
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_SORT) {
        const batchIndex = state.waitingBatches[state.currentWaitingIndex];
        const batch = state.batches[batchIndex];
        // PLC: explicit null check (korvaa ?.)
        const batchId = batch ? batch.batch_id : null;
        
        // Idle-slot -strategia: yksi läpikäynti, ei iteraatiota
        log('CHECK_SORT B' + batchId + ': sorting ' + (state.combinedTasks || []).length + ' tasks');
        
        if (state.combinedTasks && state.combinedTasks.length > 0) {
            // PLC: _insertionSort (korvaa .sort())
            _insertionSort(state.combinedTasks, state.combinedTasks.length, function(a, b) { return a.task_start_time - b.task_start_time; });
        }
        
        nextPhase = PHASE.CHECK_SWAP;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3003: CHECK_SWAP
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_SWAP) {
        let swapCount = 0;
        
        if (state.combinedTasks && state.combinedTasks.length > 1) {
            // PLC: Collect unique transporter IDs without Set
            const transporterIds = [];
            const tIdSeen = [];
            for (let i = 0; i <= MAX_TRANSPORTERS; i++) tIdSeen[i] = false;
            for (let ti = 0; ti < state.combinedTasks.length; ti++) {
                const tid = state.combinedTasks[ti].transporter_id;
                if (tid !== null && tid !== undefined && tid >= 0 && tid <= MAX_TRANSPORTERS && !tIdSeen[tid]) {
                    tIdSeen[tid] = true;
                    transporterIds.push(tid);
                }
            }
            
            for (const transporterId of transporterIds) {
                if (transporterId === null) continue;
                
                // PLC: FOR-loop (korvaa .filter())
                const transporterTasks = [];
                for (let _fi = 0; _fi < state.combinedTasks.length; _fi++) { if (state.combinedTasks[_fi].transporter_id === transporterId) transporterTasks.push(state.combinedTasks[_fi]); }
                
                for (let i = 0; i < transporterTasks.length - 1; i++) {
                    const prevTask = transporterTasks[i];
                    const nextTask = transporterTasks[i + 1];
                    
                    if (prevTask.batch_id !== nextTask.batch_id &&
                        prevTask.sink_station_id === nextTask.lift_station_id) {
                        
                        swapCount++;
                        [transporterTasks[i], transporterTasks[i + 1]] = [transporterTasks[i + 1], transporterTasks[i]];
                        
                        // PLC: FOR-loop (korvaa .indexOf())
                        let globalPrevIdx = -1;
                        for (let _gi = 0; _gi < state.combinedTasks.length; _gi++) { if (state.combinedTasks[_gi] === prevTask) { globalPrevIdx = _gi; break; } }
                        let globalNextIdx = -1;
                        for (let _gi = 0; _gi < state.combinedTasks.length; _gi++) { if (state.combinedTasks[_gi] === nextTask) { globalNextIdx = _gi; break; } }
                        if (globalPrevIdx !== -1 && globalNextIdx !== -1) {
                            [state.combinedTasks[globalPrevIdx], state.combinedTasks[globalNextIdx]] = 
                                [state.combinedTasks[globalNextIdx], state.combinedTasks[globalPrevIdx]];
                        }
                    }
                }
            }
        }
        
        nextPhase = PHASE.CHECK_ANALYZE;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3004: CHECK_ANALYZE (TAVOITETILA: kierroksittainen idle-slot-sovitus)
    //
    // departure_target_description.md mukaan:
    //   1. Laske idle-slotit linja-erien tehtävistä
    //   2. Käy odottavan erän tehtävät alusta järjestyksessä
    //   3. Jos tehtävä mahtuu sellaisenaan → jatka seuraavaan (saman kierroksen aikana)
    //   4. Jos ei mahdu → yritä viivästää flex_up:lla
    //      4a. Jos riittää → kirjaa viive, päätä kierros → WAITING_FOR_TASKS
    //      4b. Jos ei riitä → backward chain aiempiin tehtäviin
    //          - Riittää → kirjaa kaikki viiveet, päätä kierros
    //          - Ei riitä → REJECT
    //   5. Kaikki mahtuvat ilman muutoksia → ACTIVATE
    //
    // Ensimmäinen tehtävä (stage 0): aikarajat idle-slotista, max_initial_wait_s
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_ANALYZE) {
        const batchIndex = state.waitingBatches[state.currentWaitingIndex];
        const batch = state.batches[batchIndex];
        // PLC: explicit null check (korvaa ?.)
        const batchId = batch ? batch.batch_id : null;
        
        log('CHECK_ANALYZE B' + batchId + ' (TAVOITETILA) round=' + state.departureRound);
        
        const currentTimeSec = ctx.currentTimeSec || 0;
        const flexUpFactor = state.flexUpFactor;
        const maxInitialWaitS = state.maxInitialWaitS;
        const fitParams = {
            stations: state.stations,
            transporters: state.transporters,
            movementTimes: ctx.movementTimes || null,
            marginSec: 5,
            conflictMarginSec: state.departureConflictMarginSec || 1,
            flexUpFactor: flexUpFactor,
        };
        
        // Hae odottavan erän taskit — tallennettu erikseen 3001:ssä
        // EI JÄRJESTETÄ: tehtävälista pysyy laskennan mukaisena (target)
        const waitingBatchTasks = (_getWaitingTaskSet(batchId) || []);
        
        // Kerää nostintunnisteet SEKÄ linja-erien ETTÄ odottavan erän taskeista
        // PLC: Collect unique transporter IDs without Set
        const transporterIds = [];
        const tIdSeen = [];
        for (let i = 0; i <= MAX_TRANSPORTERS; i++) tIdSeen[i] = false;
        const combined = state.combinedTasks || [];
        for (let ti = 0; ti < combined.length; ti++) {
            const tid = combined[ti].transporter_id;
            if (tid !== null && tid !== undefined && tid >= 0 && tid <= MAX_TRANSPORTERS && !tIdSeen[tid]) {
                tIdSeen[tid] = true;
                transporterIds.push(tid);
            }
        }
        for (let ti = 0; ti < waitingBatchTasks.length; ti++) {
            const tid = waitingBatchTasks[ti].transporter_id;
            if (tid !== null && tid !== undefined && tid >= 0 && tid <= MAX_TRANSPORTERS && !tIdSeen[tid]) {
                tIdSeen[tid] = true;
                transporterIds.push(tid);
            }
        }
        
        // Laske idle-slotit VAIN linja-erien tehtävistä (odottavan erän taskit eivät mukana)
        // PLC: FOR-loop (korvaa .filter())
        const existingTasks = [];
        const _ctArr = state.combinedTasks || [];
        for (let _fi = 0; _fi < _ctArr.length; _fi++) { if (_ctArr[_fi].batch_id !== batchId) existingTasks.push(_ctArr[_fi]); }
        
        // ★ OVERLAP: Laske overlap-asemat (asemat joissa useampi nostin voi toimia)
        const overlapStations = computeOverlapStations(state.transporters);
        if (overlapStations.count > 0) {
            // PLC: Muodosta lokitettava lista overlap-asemista
            let overlapList = '';
            for (let oi = 0; oi <= MAX_STATIONS; oi++) {
                if (overlapStations.flags[oi]) {
                    if (overlapList.length > 0) overlapList += ', ';
                    overlapList += String(oi);
                }
            }
            log('OVERLAP Overlap-asemat: [' + overlapList + ']');
            // Logita olemassa olevat overlap-tehtävät per nostin
            for (const tId of transporterIds) {
                // PLC: FOR-loop (korvaa .filter())
                const overlapTasks = [];
                for (let _oi = 0; _oi < existingTasks.length; _oi++) {
                    const _ot = existingTasks[_oi];
                    if (_ot.transporter_id !== tId && (overlapStations.flags[_ot.lift_station_id] || overlapStations.flags[_ot.sink_station_id])) overlapTasks.push(_ot);
                }
                if (overlapTasks.length > 0) {
                    log('OVERLAP T' + tId + ': ' + overlapTasks.length + ' cross-transporter overlap task(s):');
                    // PLC: FOR-loop (korvaa .slice(0, 5))
                    const _otLimit = Math.min(overlapTasks.length, 5);
                    for (let _oi = 0; _oi < _otLimit; _oi++) {
                        const ot = overlapTasks[_oi];
                        log('OVERLAP   B' + ot.batch_id + 's' + ot.stage + ' T' + ot.transporter_id + ': lift=' + ot.lift_station_id + ' sink=' + ot.sink_station_id + ' ' + (ot.task_start_time ? ot.task_start_time.toFixed(0) : '?') + '-' + (ot.task_finished_time ? ot.task_finished_time.toFixed(0) : '?') + 's');
                    }
                }
            }
        }
        
        const idleSlotsPerTransporter = {};
        for (const tId of transporterIds) {
            idleSlotsPerTransporter[tId] = scheduler.calculateTransporterIdleSlots(
                tId, existingTasks, currentTimeSec
            );
        }
        
        // Log idle-slotit
        for (const tId of transporterIds) {
            const slots = idleSlotsPerTransporter[tId];
            log('IDLE-SLOT T' + tId + ': ' + slots.length + ' idle-slottia');
            // PLC: FOR-loop (korvaa .slice(0, 10))
            const _slotLimit = Math.min(slots.length, 10);
            for (let _si = 0; _si < _slotLimit; _si++) {
                const s = slots[_si];
                const prevInfo = s.prevTask ? ('B' + s.prevTask.batch_id + 's' + s.prevTask.stage) : 'START';
                const nextInfo = s.nextTask ? ('B' + s.nextTask.batch_id + 's' + s.nextTask.stage) : 'END';
                log('IDLE-SLOT   ' + s.start.toFixed(0) + '-' + s.end.toFixed(0) + ' (' + s.duration.toFixed(0) + 's) [' + prevInfo + ' -> ' + nextInfo + ']');
            }
        }
        
        log('IDLE-SLOT B' + batchId + ': ' + waitingBatchTasks.length + ' taskia sovitettavana');
        for (const t of waitingBatchTasks) {
            const flex_up = Math.max(0, (t.max_time_s || 0) - (t.calc_time_s || 0));
            // PLC: explicit null check (korvaa ?.)
            var _tStart = (t.task_start_time != null && typeof t.task_start_time.toFixed === 'function') ? t.task_start_time.toFixed(1) : '?';
            var _tEnd = (t.task_finished_time != null && typeof t.task_finished_time.toFixed === 'function') ? t.task_finished_time.toFixed(1) : '?';
            log('IDLE-SLOT   B' + batchId + 's' + t.stage + ' T' + (t.transporter_id || '?') + ': ' + _tStart + 's -> ' + _tEnd + 's (flex_up=' + flex_up.toFixed(0) + 's)');
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // KIERROKSITTAINEN SOVITUS (departure_target_description.md)
        // Käydään tehtävät alusta alkaen järjestyksessä.
        // ═══════════════════════════════════════════════════════════════════
        // cumulativeShift poistettu — viiveet kirjataan sandboxiin ja
        // RECALC_SCHEDULE laskee aikataulun uudelleen.  Jokainen viive
        // päättää tämän CHECK_ANALYZE-kierroksen ja palaa RECALC-silmukan kautta.
        let allFitNoChanges = true;
        let delayNeeded = false;
        let rejected = false;
        const delayActions = [];  // Kirjattavat viiveet tällä kierroksella
        
        for (let taskIdx = 0; taskIdx < waitingBatchTasks.length; taskIdx++) {
            const task = waitingBatchTasks[taskIdx];
            
            // ═══════════════════════════════════════════════════════════════
            // Ensimmäinen tehtävä (stage 0): tarkista mahtuuko idle-slottiin
            // CALC on jo laskenut stage 0:n ajat (batch.calc_time_s, min, max)
            // ja aikataulu sisältää oikean keston → tehtävän task_start/finished
            // ovat oikein. Tässä vain tarkistetaan slottiin mahtuminen.
            // ═══════════════════════════════════════════════════════════════
            if (task.stage === 0) {
                const tId = task.transporter_id;
                const slots = idleSlotsPerTransporter[tId] || [];
                log('IDLE-SLOT-DBG Stage 0: tId=' + tId + ', slots=' + slots.length + ', keys=' + Object.keys(idleSlotsPerTransporter));
                
                let stage0Fitted = false;
                for (const slot of slots) {
                    if (slot.end <= currentTimeSec) continue;
                    
                    // Travel idle_start_pos → nostoasema
                    let travelToPickup = 0;
                    // PLC: FOR-loop (korvaa .find())
                    let transporter = null;
                    for (let _ti = 0; _ti < state.transporters.length; _ti++) { if (state.transporters[_ti].id === tId) { transporter = state.transporters[_ti]; break; } }
                    const pickupStation = scheduler.findStation(task.lift_station_id, state.stations);
                    if (slot.prevTask) {
                        const fromStation = scheduler.findStation(slot.prevTask.sink_station_id, state.stations);
                        if (fromStation && pickupStation && transporter) {
                            // Tyhjä nosturi siirtyy → vain horisontaalinen matka-aika (ei nosto/lasku)
                            const transfer = scheduler.calculateTransferTime(
                                fromStation, pickupStation, transporter,
                                ctx.movementTimes || null
                            );
                            // PLC: explicit null check (korvaa ?. ??)
                            travelToPickup = (transfer && transfer.phase3_travel_s != null) ? transfer.phase3_travel_s : 0;
                        }
                    } else if (transporter && transporter.start_station) {
                        const fromStation = scheduler.findStation(transporter.start_station, state.stations);
                        if (fromStation && pickupStation) {
                            // Tyhjä nosturi siirtyy → vain horisontaalinen matka-aika (ei nosto/lasku)
                            const transfer = scheduler.calculateTransferTime(
                                fromStation, pickupStation, transporter,
                                ctx.movementTimes || null
                            );
                            // PLC: explicit null check (korvaa ?. ??)
                            travelToPickup = (transfer && transfer.phase3_travel_s != null) ? transfer.phase3_travel_s : 0;
                        }
                    }
                    
                    const earliestPickup = Math.max(slot.start, currentTimeSec) + travelToPickup;
                    
                    // Mahtuuko tehtävä slottiin?
                    const taskDuration = task.task_finished_time - task.task_start_time;
                    let travelFromSink = 0;
                    if (slot.nextTask) {
                        const sinkStation = scheduler.findStation(task.sink_station_id, state.stations);
                        const toStation = scheduler.findStation(slot.nextTask.lift_station_id, state.stations);
                        if (sinkStation && toStation && transporter) {
                            // Tyhjä nosturi siirtyy → vain horisontaalinen matka-aika (ei nosto/lasku)
                            const transfer = scheduler.calculateTransferTime(
                                sinkStation, toStation, transporter,
                                ctx.movementTimes || null
                            );
                            // PLC: explicit null check (korvaa ?. ??)
                            travelFromSink = (transfer && transfer.phase3_travel_s != null) ? transfer.phase3_travel_s : 0;
                        }
                    }
                    
                    const slotEnd = slot.nextTask ? slot.end - travelFromSink - fitParams.conflictMarginSec : slot.end;
                    let effectiveStart = earliestPickup;
                    
                    // ★ OVERLAP CHECK: Stage 0 – jos nosto/lasku käyttää overlap-asemaa,
                    // varmista ettei toisen nostimen overlap-tehtävä ole samaan aikaan.
                    if (overlapStations.count > 0 &&
                        (overlapStations.flags[task.lift_station_id] || overlapStations.flags[task.sink_station_id])) {
                        const stage0OverlapDelay = calculateOverlapDelay(
                            task, effectiveStart - task.task_start_time,
                            existingTasks, overlapStations, fitParams.conflictMarginSec
                        );
                        if (stage0OverlapDelay > 0) {
                            log('OVERLAP B' + batchId + 's0: overlap conflict, shift effectiveStart +' + stage0OverlapDelay.toFixed(1) + 's');
                            effectiveStart += stage0OverlapDelay;
                        }
                    }
                    
                    log('IDLE-SLOT-DBG Stage 0 check: effectiveStart=' + effectiveStart.toFixed(1) + ', taskDuration=' + taskDuration.toFixed(1) + ', slotEnd=' + slotEnd.toFixed(1) + ', fits=' + (effectiveStart + taskDuration <= slotEnd));
                    
                    if (effectiveStart + taskDuration <= slotEnd) {
                        // Laske stage 0:n viive: ero sovitetun aloitusajan ja schedulen aloitusajan välillä
                        const stage0Delay = effectiveStart - task.task_start_time;
                        
                        // ★ maxInitialWaitS -tarkistus: odotus ei saa ylittää maksimiarvoa (oletus 120s)
                        const maxInitWait = state.maxInitialWaitS || 120;
                        if (stage0Delay > maxInitWait) {
                            log('IDLE-SLOT Stage 0: slot ' + slot.start.toFixed(0) + '-' + slot.end.toFixed(0) + ' delay=' + stage0Delay.toFixed(1) + 's > maxInitialWait=' + maxInitWait + 's, rejected');
                            continue;  // Kokeillaan seuraavaa slottia
                        }
                        
                        stage0Fitted = true;
                        log('IDLE-SLOT Stage 0: fits slot ' + slot.start.toFixed(0) + '-' + slot.end.toFixed(0) + ' (delay=' + stage0Delay.toFixed(1) + 's)');
                        
                        // Typistä idle-slottia
                        const taskEndTime = effectiveStart + taskDuration;
                        slot.start = taskEndTime;
                        slot.duration = slot.end - slot.start;
                        
                        // Stage 0 offset = nosturin matka-aika (idle slot vs. schedule).
                        // Merkittävä viive → kirjaa sandboxiin ja laske aikataulu uudelleen.
                        if (stage0Delay > fitParams.marginSec) {
                            delayActions.push({
                                stage: 0,
                                delay: stage0Delay,
                                writeTarget: 'batch',
                                log: 'Stage 0: calc_time offset ' + stage0Delay.toFixed(1) + 's (slot ' + slot.start.toFixed(0) + '-' + slot.end.toFixed(0) + ')'
                            });
                            allFitNoChanges = false;
                            log('Stage 0 offset: ' + stage0Delay.toFixed(1) + 's, RECALC');
                        }
                        break;
                    }
                }
                
                if (!stage0Fitted) {
                    log('B' + batchId + ': Stage 0 ei mahdu, REJECT');
                    state.idleSlotResult = {
                        fits: false, actions: [], log: ['Stage 0: ei sopivaa idle-slottia'],
                        userReason: 'Nostin T' + task.transporter_id + ' varattu — ei vapaata slottia'
                    };
                    rejected = true;
                    break;
                }
                // Stage 0 offset on nosturin matka-aika (fysiikka), EI konfliktiratkaisu.
                // Se kirjataan sandboxiin mutta sovitus JATKAA samalla kierroksella
                // stage 1+ tehtäviin. Vain stage 1+ viive triggeröi RECALC-kierroksen.
                continue;  // Stage 0 OK, jatka seuraavaan tehtävään
            }
            
            // ═══════════════════════════════════════════════════════════════
            // Muut tehtävät (stage 1+): fitSingleTaskToIdleSlots
            // ★ OVERLAP CHECK: Jos tehtävä käyttää overlap-asemaa, tarkista
            //   ettei toisen nostimen overlap-tehtävä ole samaan aikaan.
            //   Lisää tarvittava viive ENNEN idle-slot -sovitusta jotta
            //   fitSingleTaskToIdleSlots etsii slotin oikeasta ajankohdasta.
            // ═══════════════════════════════════════════════════════════════
            // cumulativeShift = 0 — RECALC on jo päivittänyt task-ajat
            const overlapDelay = calculateOverlapDelay(
                task, 0, existingTasks, overlapStations, fitParams.conflictMarginSec
            );
            if (overlapDelay > 0) {
                log('OVERLAP B' + batchId + 's' + task.stage + ' T' + task.transporter_id + ': overlap conflict, delay ' + overlapDelay.toFixed(1) + 's (lift=' + task.lift_station_id + ', sink=' + task.sink_station_id + ')');
                allFitNoChanges = false;
            }
            
            // Overlap-viive on ainoa shift — ei kumulatiivista kertymää
            const fitResult = scheduler.fitSingleTaskToIdleSlots(
                task, idleSlotsPerTransporter, overlapDelay, fitParams
            );
            log('IDLE-SLOT ' + fitResult.log);
            
            if (fitResult.fits) {
                // Typistä idle-slottia: tehtävä varaa alun, slotin start siirtyy tehtävän loppuun
                if (fitResult.slot && fitResult.taskEndTime != null) {
                    const oldStart = fitResult.slot.start;
                    fitResult.slot.start = fitResult.taskEndTime;
                    fitResult.slot.duration = fitResult.slot.end - fitResult.slot.start;
                    log('IDLE-SLOT Slot trimmed: ' + oldStart.toFixed(0) + '-' + fitResult.slot.end.toFixed(0) + ' -> ' + fitResult.slot.start.toFixed(0) + '-' + fitResult.slot.end.toFixed(0) + ' (' + fitResult.slot.duration.toFixed(0) + 's remaining)');
                }
                // Mahtuu — kirjaa mahdollinen viive
                // Nostimen vaihtuminen ei vaadi erillistä tarkistusta:
                // jokainen tehtävä sovitetaan oman nostimensa idle-slottiin
                // automaattisesti. TASKS hoitaa handoff-konfliktit.
                
                // ★ OVERLAP: Kokonaisviive = overlap-viive + idle-slot-viive
                const totalDelay = overlapDelay + (fitResult.delay || 0);
                
                if (totalDelay > fitParams.marginSec) {
                    allFitNoChanges = false;
                    delayActions.push({
                        stage: task.stage,
                        delay: totalDelay,
                        writeTarget: 'program',  // Stage 1+ → käsittelyohjelma
                        log: overlapDelay > 0
                            ? fitResult.log + ' + overlap delay ' + overlapDelay.toFixed(1) + 's'
                            : fitResult.log
                    });
                    // Tavoitetila: yksi viive per kierros → päätä kierros tähän
                    log('Delay stage ' + task.stage + ': ' + totalDelay.toFixed(1) + 's (overlap=' + overlapDelay.toFixed(1) + 's, idle=' + (fitResult.delay || 0).toFixed(1) + 's), ending round');
                    delayNeeded = true;
                    break;
                }
                // Ei viivettä → jatka seuraavaan tehtävään saman kierroksen aikana
                continue;
            }
            
            // ═══════════════════════════════════════════════════════════════
            // Ei mahdu → backward chaining
            // Kulje taaksepäin yksi tehtävä kerrallaan, ketjuta viiveet
            // ═══════════════════════════════════════════════════════════════
            log('IDLE-SLOT Stage ' + task.stage + ' no fit, backward chaining');
            
            // needExtra = viivästystarve joka ylittää tehtävän oman jouston (dokumentti: "jäljelle jäävä viivästystarve")
            // Jos needExtra puuttuu, slot ei löytynyt lainkaan → backward chaining ei voi auttaa
            if (fitResult.needExtra == null || fitResult.needExtra <= 0) {
                log('B' + batchId + ': Stage ' + task.stage + ' no idle-slot, REJECT');
                state.idleSlotResult = {
                    fits: false, actions: [], log: ['Stage ' + task.stage + ': ei sopivaa idle-slottia'],
                    userReason: 'Stage ' + task.stage + ': nostin T' + task.transporter_id + ' varattu'
                };
                rejected = true;
                break;
            }
            let remainingNeed = fitResult.needExtra;
            const chainDelays = [];  // Ketjutetut viiveet
            let chainSuccess = false;
            
            // Aloita nykyisestä tehtävästä (sen oma flex_up on jo käytetty fitSingleTaskToIdleSlots:ssa)
            // ja kulje taaksepäin
            for (let backIdx = taskIdx - 1; backIdx >= 0 && remainingNeed > 0; backIdx--) {
                const prevTask = waitingBatchTasks[backIdx];
                const prevFlexUp = Math.max(0, (prevTask.max_time_s || 0) - (prevTask.calc_time_s || 0));
                const prevCappedFlex = prevFlexUp * flexUpFactor;
                const useDelay = Math.min(prevCappedFlex, remainingNeed);
                
                if (useDelay > fitParams.marginSec) {
                    chainDelays.push({
                        stage: prevTask.stage,
                        delay: useDelay,
                        writeTarget: prevTask.stage === 0 ? 'batch' : 'program',
                        log: 'backward chain: stage ' + prevTask.stage + ' delay ' + useDelay.toFixed(1) + 's (flex_up=' + prevFlexUp.toFixed(0) + 's × ' + flexUpFactor + ')'
                    });
                    remainingNeed -= useDelay;
                    log('BACKWARD Stage ' + prevTask.stage + ': delay ' + useDelay.toFixed(1) + 's, remaining need ' + remainingNeed.toFixed(1) + 's');
                }
            }
            
            if (remainingNeed <= fitParams.marginSec) {
                // Backward chaining riitti!
                log('BACKWARD chain sufficient, ' + chainDelays.length + ' delays');
                allFitNoChanges = false;
                delayNeeded = true;
                
                // Lisää ketjutetut viiveet + alkuperäinen tehtävä
                // PLC: FOR-loop (korvaa .push(...spread))
                for (let _di = 0; _di < chainDelays.length; _di++) delayActions.push(chainDelays[_di]);
                // Alkuperäinen tehtävä saa saman viiveen mikä oli fitResult.delay (se mahtuisi nyt)
                if (fitResult.delay > fitParams.marginSec) {
                    delayActions.push({
                        stage: task.stage,
                        delay: fitResult.delay,
                        writeTarget: 'program',
                        log: 'Stage ' + task.stage + ': delay ' + fitResult.delay.toFixed(1) + 's (after backward chain)'
                    });
                }
                break;  // Kierros päätetään
            } else {
                // Backward chaining ei riittänyt → REJECT
                log('B' + batchId + ': backward chaining insufficient (remaining ' + remainingNeed.toFixed(1) + 's), REJECT');
                state.idleSlotResult = {
                    fits: false, actions: [], log: ['Stage ' + task.stage + ': backward chain insufficient, remaining ' + remainingNeed.toFixed(1) + 's'],
                    userReason: 'Stage ' + task.stage + ': joustovara ei riitä, puuttuu ' + remainingNeed.toFixed(0) + 's'
                };
                rejected = true;
                break;
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // Päätöspuu (departure_target_description.md)
        // ═══════════════════════════════════════════════════════════════════
        if (rejected) {
            // 3) Joustot eivät riitä → REJECT
            nextPhase = PHASE.CHECK_RESOLVE;
        } else if (!delayNeeded) {
            // 1) Kaikki tehtävät mahtuvat — ei viiveitä tarvita
            log('B' + batchId + ': All tasks fit (round ' + state.departureRound + '), ACTIVATE');
            state.idleSlotResult = { fits: true, actions: delayActions, log: ['Kaikki mahtuvat'] };
            nextPhase = PHASE.CHECK_RESOLVE;
        } else if (delayNeeded) {
            // 2) Viive tarvitaan → kirjaa viiveet sandboxiin, laske uusi aikataulu
            //    Sovittelukierros B: EI palata WAITING_FOR_TASKS:iin.
            //    Kirjataan viiveet → RECALC_SCHEDULE → RECALC_TASKS → SORT → ANALYZE
            state.departureRound++;
            
            // Turvarajoitin: max 50 sovittelukierrosta
            const MAX_FIT_ROUNDS = 50;
            if (state.departureRound > MAX_FIT_ROUNDS) {
                log('B' + batchId + ': Max fit rounds (' + MAX_FIT_ROUNDS + ') exceeded, REJECT');
                state.idleSlotResult = {
                    fits: false, actions: [], log: ['Max ' + MAX_FIT_ROUNDS + ' fit-rounds exceeded'],
                    userReason: 'Sovittelu ei konvergoidu ' + MAX_FIT_ROUNDS + ' kierroksella'
                };
                nextPhase = PHASE.CHECK_RESOLVE;
            } else {
                log('B' + batchId + ': Delays recorded, fit round ' + state.departureRound + ', RECALC');
                
                // Kirjaa viiveet sandbox-batchiin ja -ohjelmaan
                for (const action of delayActions) {
                    if (action.writeTarget === 'batch') {
                        // Stage 0: kirjaa batch-tietoihin
                        // PLC: FOR-loop (korvaa .find())
                        let sandboxBatch = null;
                        if (state.departureSandbox && state.departureSandbox.batches) { for (let _sbi = 0; _sbi < state.departureSandbox.batches.length; _sbi++) { if (state.departureSandbox.batches[_sbi].batch_id === batchId) { sandboxBatch = state.departureSandbox.batches[_sbi]; break; } } }
                        if (sandboxBatch) {
                            sandboxBatch.calc_time_s = (sandboxBatch.calc_time_s || 0) + action.delay;
                            sandboxBatch.min_time_s = sandboxBatch.calc_time_s;
                            sandboxBatch.max_time_s = Math.max(sandboxBatch.calc_time_s, 2 * sandboxBatch.calc_time_s);
                            log('Viive kirjattu batch B' + batchId + ' stage 0: calc=' + sandboxBatch.calc_time_s.toFixed(1) + 's');
                        }
                        // Kirjaa myös state.batches (RECALC_SCHEDULE lukee tätä)
                        if (batch) {
                            batch.calc_time_s = (batch.calc_time_s || 0) + action.delay;
                            batch.min_time_s = batch.calc_time_s;
                            batch.max_time_s = Math.max(batch.calc_time_s, 2 * batch.calc_time_s);
                        }
                    } else {
                        // Stage 1+: kirjaa käsittelyohjelmaan
                        // PLC: explicit null check (korvaa ?.)
                        const program = (state.departureSandbox && state.departureSandbox.programsByBatchId) ? state.departureSandbox.programsByBatchId[String(batchId)] : null;
                        if (program) {
                            const programIdx = action.stage - 1;
                            const stageEntry = program[programIdx];
                            if (stageEntry) {
                                const oldCalcS = scheduler.parseTimeToSeconds(stageEntry.calc_time) || 0;
                                const maxTimeS = scheduler.parseTimeToSeconds(stageEntry.max_time) || oldCalcS;
                                const newCalcS = Math.min(maxTimeS, oldCalcS + action.delay);
                                stageEntry.calc_time = scheduler.formatSecondsToTime(newCalcS);
                                log('Viive kirjattu program B' + batchId + ' stage ' + action.stage + ': ' + oldCalcS.toFixed(0) + 's → ' + newCalcS.toFixed(0) + 's');
                            }
                        }
                        // Kirjaa myös server-puolen ohjelmaan
                        const serverProgram = _getProgram(batchId);
                        if (serverProgram) {
                            const programIdx = action.stage - 1;
                            const stageEntry = serverProgram[programIdx];
                            if (stageEntry) {
                                const oldCalcS = scheduler.parseTimeToSeconds(stageEntry.calc_time) || 0;
                                const maxTimeS = scheduler.parseTimeToSeconds(stageEntry.max_time) || oldCalcS;
                                const newCalcS = Math.min(maxTimeS, oldCalcS + action.delay);
                                stageEntry.calc_time = scheduler.formatSecondsToTime(newCalcS);
                            }
                        }
                    }
                }
                
                log('Sovittelukierros ' + state.departureRound + ': viiveet kirjattu → RECALC_SCHEDULE');
                
                // Sovittelukierros: laske aikataulu uudelleen sandboxista → uudet taskit → uusi sovitus
                nextPhase = PHASE.CHECK_RECALC_SCHEDULE;
            }
        } else {
            // Kaikki mahtuvat viiveillä jotka eivät vaadi uutta kierrosta
            log('B' + batchId + ': All tasks fit (delays recorded), ACTIVATE');
            // PLC: FOR-loop (korvaa .map())
            const _daLogs = [];
            for (let _di = 0; _di < delayActions.length; _di++) _daLogs.push(delayActions[_di].log);
            state.idleSlotResult = { fits: true, actions: delayActions, log: _daLogs };
            nextPhase = PHASE.CHECK_RESOLVE;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3005: CHECK_RESOLVE (IDLE-SLOT ONLY)
    //
    // Yksinkertainen päätös idle-slot -tuloksen perusteella:
    //   fits  → suoraan ACTIVATE (viiveet kirjataan ACTIVATE:ssa)
    //   !fits → REJECT
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_RESOLVE) {
        const batchIndex = state.waitingBatches[state.currentWaitingIndex];
        const batch = state.batches[batchIndex];
        // PLC: explicit null check (korvaa ?.)
        const batchId = batch ? batch.batch_id : null;
        
        const idleSlotResult = state.idleSlotResult || { fits: false, actions: [], log: [] };
        
        if (idleSlotResult.fits) {
            // ═══════════════════════════════════════════════════════════════
            // OK: Kaikki taskit mahtuivat → suoraan ACTIVATE
            // Viiveet kirjataan ACTIVATE-vaiheessa batchiin ja ohjelmaan
            // ═══════════════════════════════════════════════════════════════
            log('B' + batchId + ': Idle-slot OK, ACTIVATE (' + idleSlotResult.actions.length + ' delays)');
            log('CHECK B' + batchId + ': Idle-slot fit → ACTIVATE');
            state.lastDepartureConflict = null;
            nextPhase = PHASE.ACTIVATE;
        } else {
            // ═══════════════════════════════════════════════════════════════
            // FAIL: Taski ei mahtunut → REJECT
            // ═══════════════════════════════════════════════════════════════
            // PLC: FOR-loop (korvaa .filter() + .includes())
            const failLog = [];
            for (let _fl = 0; _fl < idleSlotResult.log.length; _fl++) {
                const _l = idleSlotResult.log[_fl];
                if (_l.indexOf('FAIL') !== -1 || _l.indexOf('OVERFLOW') !== -1) failLog.push(_l);
            }
            
            log('IDLE-SLOT FAIL B' + batchId + ': REJECTED');
            for (var _fli = 0; _fli < failLog.length; _fli++) {
                log('FAIL: ' + failLog[_fli]);
            }
            
            log('CHECK B' + batchId + ': REJECT (idle-slot fail)');
            
            state.lastDepartureConflict = {
                waitingBatchId: batchId,
                reason: 'IDLE_SLOT_FAIL: ' + (failLog[0] || 'unknown')
            };
            
            // Palauta sandbox snapshotista (palauttaa vain linja-erien schedulet)
            if (state.sandboxSnapshot) {
                state.departureSandbox = _copyDepartureSandbox(state.sandboxSnapshot);
            }
            // Poista hylätyn erän schedule
            _removeSchedule(batchId);
            _removeWaitingSched(batchId);
            state.departureRound = 0;  // Nollaa sovittelukierros REJECT:in jälkeen
            state.departureCandidateStretches = [];
            state.departureLockedStages = []; state.depLockedStageCount = 0;
            
            // Siirry seuraavaan odottavaan erään
            state.currentWaitingIndex++;
            
            if (state.currentWaitingIndex >= state.waitingBatchCount) {
                log('All waiting batches checked, no activation → resync with TASKS');
                state.finalDepartureConflict = state.lastDepartureConflict || null;
                state.lastDepartureConflict = null;
                nextPhase = PHASE.WAITING_FOR_TASKS;
            } else {
                nextPhase = PHASE.CHECK_START;
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3006: CHECK_UPDATE_PROGRAM
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_UPDATE_PROGRAM) {
        const pendingList = state.pendingDelays || [];
        
        if (pendingList.length === 0) {
            nextPhase = PHASE.CHECK_SORT;
        } else {
            // PLC: explicit function (korvaa =>)
            var applyDeltaToProgram = function(program, targetStage, delay_s, propagate) {
                if (propagate === undefined) propagate = false;
                if (!program) return null;
                
                const results = [];
                const startIdx = targetStage - 1;
                const endIdx = propagate ? program.length : targetStage;
                
                for (let i = startIdx; i < endIdx; i++) {
                    if (!program[i]) continue;
                    const stage = program[i];
                    const oldCalc = scheduler.parseTimeToSeconds(stage.calc_time) || 
                                    scheduler.parseTimeToSeconds(stage.min_time) || 0;
                    const minTime = scheduler.parseTimeToSeconds(stage.min_time) || oldCalc;
                    const maxTime = scheduler.parseTimeToSeconds(stage.max_time) || oldCalc;
                    const newCalc = Math.min(maxTime, Math.max(minTime, oldCalc + delay_s));
                    stage.calc_time = scheduler.formatSecondsToTime(newCalc);
                    results.push({ stage: i + 1, oldCalc, newCalc, minTime, maxTime });
                }
                return results.length > 0 ? results : null;
            };
            
            for (const pending of pendingList) {
                // Stage 0 ei ole käsittelyohjelmassa (program on 1-pohjainen)
                // propagateDelayToBatch (applyResolutionActions:ssa) on JO päivittänyt
                // sandbox-batchin calc_time_s:n → ei saa lisätä uudelleen (tuplaus!)
                // Tarvitaan vain loki.
                if (pending.stage === 0) {
                    // PLC: FOR-loop (korvaa .find())
                    let sandboxBatch = null;
                    if (state.departureSandbox && state.departureSandbox.batches) { for (let _sbi = 0; _sbi < state.departureSandbox.batches.length; _sbi++) { if (state.departureSandbox.batches[_sbi].batch_id === pending.batch_id) { sandboxBatch = state.departureSandbox.batches[_sbi]; break; } } }
                    if (sandboxBatch) {
                        // Stage 0 ei ole käsittelyohjelmassa.
                        // propagateDelayToBatch on päivittänyt calc, min JA max (suhteellinen flex-ikkuna).
                        log('Stage 0 delay for B' + pending.batch_id + ': calc=' + (sandboxBatch.calc_time_s ? sandboxBatch.calc_time_s.toFixed(1) : '?') + 's, min=' + (sandboxBatch.min_time_s ? sandboxBatch.min_time_s.toFixed(1) : '?') + 's, max=' + (sandboxBatch.max_time_s ? sandboxBatch.max_time_s.toFixed(1) : '?') + 's (applied by propagateDelayToBatch)');
                    }
                    continue;
                }
                
                const results = applyDeltaToProgram(
                    (state.departureSandbox && state.departureSandbox.programsByBatchId) ? state.departureSandbox.programsByBatchId[String(pending.batch_id)] : null,
                    pending.stage,
                    pending.delay_s,
                    pending.propagate
                );
                
                if (results && results.length > 0) {
                    // PLC: FOR-loop (korvaa .find())
                    let sandboxBatch2 = null;
                    if (state.departureSandbox && state.departureSandbox.batches) { for (let _sbi = 0; _sbi < state.departureSandbox.batches.length; _sbi++) { if (state.departureSandbox.batches[_sbi].batch_id === pending.batch_id) { sandboxBatch2 = state.departureSandbox.batches[_sbi]; break; } } }
                    // PLC: FOR-loop (korvaa .find())
                    let currentStageResult = null;
                    const _sbStage = sandboxBatch2 ? sandboxBatch2.stage : undefined;
                    for (let _ri = 0; _ri < results.length; _ri++) { if (results[_ri].stage === _sbStage) { currentStageResult = results[_ri]; break; } }
                    if (sandboxBatch2 && currentStageResult) {
                        sandboxBatch2.calc_time_s = currentStageResult.newCalc;
                        sandboxBatch2.min_time_s = currentStageResult.minTime;
                        sandboxBatch2.max_time_s = currentStageResult.maxTime;
                    }
                }
            }
            
            nextPhase = PHASE.CHECK_RECALC_SCHEDULE;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3007: CHECK_RECALC_SCHEDULE
    // Recalculate ALL batch schedules from sandbox programs after conflict resolution.
    // This ensures that every schedule reflects the updated calc_times, so that
    // subsequent conflict analysis operates on accurate task times.
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_RECALC_SCHEDULE) {
        log('RECALC_SCHEDULE: Recalculating ALL schedules from updated sandbox programs');
        
        const sandboxBatches = (state.departureSandbox ? state.departureSandbox.batches : null) || [];
        const transporter = state.transporters[0];
        let recalcCount = 0;
        
        for (const batch of sandboxBatches) {
            if (!batch || !batch.batch_id) continue;
            // Only recalculate batches in the line (stage 0-60) or waiting (stage 90)
            if (batch.stage > 60 && batch.stage !== 90) continue;
            
            const batchIdStr = String(batch.batch_id);
            const program = (state.departureSandbox && state.departureSandbox.programsByBatchId) ? state.departureSandbox.programsByBatchId[batchIdStr] : null;
            if (!program) continue;
            
            // Only recalculate batches that have an existing schedule in sandbox
            // (other waiting batches are not part of this cycle)
            const existingSchedule = (state.departureSandbox && state.departureSandbox.schedulesByBatchId) ? state.departureSandbox.schedulesByBatchId[batchIdStr] : null;
            if (!existingSchedule) continue;
            const baseTime = existingSchedule.calculated_at || (ctx.currentTimeSec || 0);
            
            // Other schedules for parallel station selection
            // PLC: FOR-loop (korvaa .filter().map())
            const otherSchedules = [];
            const _sbSchedMap = (state.departureSandbox ? state.departureSandbox.schedulesByBatchId : null) || {};
            const _sbSchedKeys = Object.keys(_sbSchedMap);
            for (let _ki = 0; _ki < _sbSchedKeys.length; _ki++) {
                if (_sbSchedKeys[_ki] !== batchIdStr) otherSchedules.push(_sbSchedMap[_sbSchedKeys[_ki]]);
            }
            
            // PLC: FOR-loop (korvaa .filter().map() → Set)
            const occupiedStations = new Set();
            const _rcUnits = ctx.units || [];
            for (let _ui = 0; _ui < _rcUnits.length; _ui++) {
                const _u = _rcUnits[_ui];
                if (_u.batch_id != null && _u.batch_id !== batch.batch_id && _u.location > 0) occupiedStations.add(_u.location);
            }
            
            const newSchedule = scheduler.calculateBatchSchedule(
                batch,
                program,
                state.stations,
                transporter,
                baseTime,
                false,
                null,
                { 
                    movementTimes: ctx.movementTimes || null,
                    lineSchedules: otherSchedules,
                    occupiedStations: occupiedStations,
                    stationIdleSince: ctx.stationIdleSince || new Map(),
                    units: ctx.units || []
                }
            );
            
            if (newSchedule && newSchedule.stages) {
                // DEBUG: Trace stage 0 timing for waiting batches
                if (batch.stage === 90) {
                    // PLC: FOR-loop (korvaa .find())
                    let s0 = null;
                    for (let _si = 0; _si < newSchedule.stages.length; _si++) { if (newSchedule.stages[_si].stage === 0) { s0 = newSchedule.stages[_si]; break; } }
                    if (s0) {
                        // PLC: explicit null checks (korvaa ?.)
                        var _bct = (batch.calc_time_s != null && typeof batch.calc_time_s.toFixed === 'function') ? batch.calc_time_s.toFixed(1) : '?';
                        var _s0e = (s0.entry_time_s != null && typeof s0.entry_time_s.toFixed === 'function') ? s0.entry_time_s.toFixed(1) : '?';
                        var _s0x = (s0.exit_time_s != null && typeof s0.exit_time_s.toFixed === 'function') ? s0.exit_time_s.toFixed(1) : '?';
                        var _s0t = (s0.treatment_time_s != null && typeof s0.treatment_time_s.toFixed === 'function') ? s0.treatment_time_s.toFixed(1) : '?';
                        var _bt = (baseTime != null && typeof baseTime.toFixed === 'function') ? baseTime.toFixed(1) : '?';
                        log('RECALC_SCHEDULE-DEBUG B' + batch.batch_id + ' stage=90: batch.calc_time_s=' + _bct + 's, schedule stage0: entry=' + _s0e + 's, exit=' + _s0x + 's, treatment=' + _s0t + 's, baseTime=' + _bt + 's');
                    }
                }
                state.departureSandbox.schedulesByBatchId[batchIdStr] = newSchedule;
                
                // Synkronoi batch-tiedot aikataulun nykyisestä stagesta.
                // Kun erä ON asemalla, aikataulun laskenta alkaa batch-tiedoista.
                // min/max pitää olla ajan tasalla jotta propagateDelayToBatch clamp toimii oikein.
                // HUOM: EI synkronoida calc_time_s:ää — aktiivisille erille schedule
                // sisältää remainingTime (jäljellä oleva), ei kokonaisaikaa.
                const recalcBatchLoc = ctx.getBatchLocation(batch.batch_id);
                if (recalcBatchLoc != null && recalcBatchLoc >= 100) {
                    const batchCurrentStage = batch.stage === 90 ? 0 : (Number(batch.stage) || 0);
                    // PLC: FOR-loop (korvaa .find())
                    let currentStageInSchedule = null;
                    for (let _si = 0; _si < newSchedule.stages.length; _si++) { if (newSchedule.stages[_si].stage === batchCurrentStage) { currentStageInSchedule = newSchedule.stages[_si]; break; } }
                    if (currentStageInSchedule) {
                        const oldMin = batch.min_time_s;
                        const oldMax = batch.max_time_s;
                        batch.min_time_s = currentStageInSchedule.min_time_s;
                        batch.max_time_s = currentStageInSchedule.max_time_s;
                        if (oldMax !== batch.max_time_s) {
                            // PLC: explicit null checks (korvaa ?.)
                            var _omStr = (oldMin != null && typeof oldMin.toFixed === 'function') ? oldMin.toFixed(1) : '?';
                            var _nmStr = (batch.min_time_s != null && typeof batch.min_time_s.toFixed === 'function') ? batch.min_time_s.toFixed(1) : '?';
                            var _oxStr = (oldMax != null && typeof oldMax.toFixed === 'function') ? oldMax.toFixed(1) : '?';
                            var _nxStr = (batch.max_time_s != null && typeof batch.max_time_s.toFixed === 'function') ? batch.max_time_s.toFixed(1) : '?';
                            log('RECALC_SCHEDULE B' + batch.batch_id + ': Synced batch min/max from schedule stage ' + batchCurrentStage + ': min ' + _omStr + '->' + _nmStr + 's, max ' + _oxStr + '->' + _nxStr + 's');
                        }
                    }
                }
                
                // Update waitingScheds for waiting batches
                if (batch.stage === 90) {
                    _setWaitingSched(Number(batchIdStr), newSchedule);
                }
                recalcCount++;
            }
        }
        
        log('RECALC_SCHEDULE: ' + recalcCount + ' schedules recalculated');
        nextPhase = PHASE.CHECK_RECALC_TASKS;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3008: CHECK_RECALC_TASKS
    // Rebuild ALL tasks from ALL sandbox schedules.
    // This is the key fix: after a conflict resolve and schedule recalculation,
    // combinedTasks is rebuilt from scratch so task times accurately reflect
    // the resolved changes. No stale times from previous iterations.
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.CHECK_RECALC_TASKS) {
        const batchIndex = state.waitingBatches[state.currentWaitingIndex];
        const waitingBatch = state.batches[batchIndex];
        // PLC: explicit null check (korvaa ?.)
        const waitingBatchId = waitingBatch ? waitingBatch.batch_id : null;
        
        log('RECALC_TASKS: Rebuilding ALL tasks from sandbox schedules');
        
        // 1. Build in-flight tasks (real-time transporter state, same logic as CHECK_CREATE_TASKS)
        const inFlightTasks = [];
        for (const t of (ctx.transporterStates || [])) {
            // PLC: explicit null check (korvaa ?.)
            const s = (t != null) ? t.state : null;
            if (!s || s.phase === 0) continue;
            
            let pendingBatchId = s.pending_batch_id;
            const liftStation = s.lift_station_target;
            const sinkStation = s.sink_station_target;
            
            if (pendingBatchId == null && s.phase > 0) {
                const unitOnT = ctx.getUnitAtLocation(t.id);
                // PLC: FOR-loop (korvaa .find())
                let batchOnTransporter = null;
                if (unitOnT) { for (let _bi = 0; _bi < state.batches.length; _bi++) { if (state.batches[_bi].batch_id === unitOnT.batch_id) { batchOnTransporter = state.batches[_bi]; break; } } }
                if (batchOnTransporter) pendingBatchId = batchOnTransporter.batch_id;
            }
            
            if (pendingBatchId != null && liftStation != null && sinkStation != null) {
                // PLC: FOR-loop (korvaa .find())
                let batchObj = null;
                for (let _bi = 0; _bi < state.batches.length; _bi++) { if (state.batches[_bi].batch_id === pendingBatchId) { batchObj = state.batches[_bi]; break; } }
                const inferredStage = (batchObj ? batchObj.stage : 0) || 0;
                
                const batchSchedule = (state.departureSandbox && state.departureSandbox.schedulesByBatchId) ? state.departureSandbox.schedulesByBatchId[String(pendingBatchId)] : null;
                // PLC: FOR-loop (korvaa .find())
                let sinkStageSchedule = null;
                if (batchSchedule && batchSchedule.stages) { for (let _si = 0; _si < batchSchedule.stages.length; _si++) { if (batchSchedule.stages[_si].station_id === sinkStation) { sinkStageSchedule = batchSchedule.stages[_si]; break; } } }
                const taskFinishedTime = (sinkStageSchedule ? sinkStageSchedule.entry_time : null) || (ctx.currentTimeSec + 60);
                let liftStageSchedule = null;
                if (batchSchedule && batchSchedule.stages) { for (let _si = 0; _si < batchSchedule.stages.length; _si++) { if (batchSchedule.stages[_si].station_id === liftStation) { liftStageSchedule = batchSchedule.stages[_si]; break; } } }
                const taskStartTime = (liftStageSchedule ? liftStageSchedule.exit_time : null) || ctx.currentTimeSec;
                
                inFlightTasks.push({
                    batch_id: pendingBatchId,
                    transporter_id: t.id,
                    lift_station_id: liftStation,
                    sink_station_id: sinkStation,
                    task_start_time: taskStartTime,
                    task_finished_time: taskFinishedTime,
                    stage: inferredStage,
                    isInFlight: true
                });
            }
        }
        
        // 2. Create tasks from ALL sandbox schedules
        let allTasks = [];
        const sandboxBatches = (state.departureSandbox ? state.departureSandbox.batches : null) || [];
        
        const _rtSchedMap = (state.departureSandbox ? state.departureSandbox.schedulesByBatchId : null) || {};
        const _rtSchedKeys = Object.keys(_rtSchedMap);
        for (let _ki = 0; _ki < _rtSchedKeys.length; _ki++) {
            const batchIdStr = _rtSchedKeys[_ki];
            const schedule = _rtSchedMap[batchIdStr];
            if (!schedule || !schedule.stages) continue;
            // PLC: FOR-loop (korvaa .find() × 2)
            let batch = null;
            const _bIdNum = Number(batchIdStr);
            for (let _bi = 0; _bi < sandboxBatches.length; _bi++) { if (sandboxBatches[_bi].batch_id === _bIdNum) { batch = sandboxBatches[_bi]; break; } }
            if (!batch) { for (let _bi = 0; _bi < state.batches.length; _bi++) { if (state.batches[_bi].batch_id === _bIdNum) { batch = state.batches[_bi]; break; } } }
            if (!batch) continue;
            
            const tasks = scheduler.createTaskListFromSchedule(schedule, batch, state.transporters);
            // PLC: FOR-loop (korvaa .push(...spread))
            for (let _ti = 0; _ti < tasks.length; _ti++) allTasks.push(tasks[_ti]);
        }
        
        // 3. Filter out in-flight tasks (replaced by real-time transporter data)
        // PLC: lineaarinen haku avaintaulukkoon (korvaa Set)
        if (inFlightTasks.length > 0) {
            const ifKeys = [];
            for (let ifi = 0; ifi < inFlightTasks.length; ifi++) {
                ifKeys[ifi] = inFlightTasks[ifi].batch_id + '_' + inFlightTasks[ifi].stage;
            }
            const filteredTasks = [];
            for (let ti = 0; ti < allTasks.length; ti++) {
                const key = allTasks[ti].batch_id + '_' + allTasks[ti].stage;
                let isInFlight = false;
                for (let ki = 0; ki < ifKeys.length; ki++) {
                    if (ifKeys[ki] === key) { isInFlight = true; break; }
                }
                if (!isInFlight) filteredTasks.push(allTasks[ti]);
            }
            allTasks = filteredTasks;
        }
        
        // 4. Update sandbox.tasks (for potential subsequent waiting batch checks)
        // PLC: FOR-loop (korvaa .filter())
        const _sbFiltered1 = [];
        for (let _fi = 0; _fi < allTasks.length; _fi++) { if (allTasks[_fi].batch_id !== waitingBatchId) _sbFiltered1.push(allTasks[_fi]); }
        state.departureSandbox.tasks = _sbFiltered1;
        
        // 5. Store waiting batch tasks separately
        if (waitingBatchId) {
            // PLC: FOR-loop (korvaa .filter())
            const _wbFiltered = [];
            for (let _fi = 0; _fi < allTasks.length; _fi++) { if (allTasks[_fi].batch_id === waitingBatchId) _wbFiltered.push(allTasks[_fi]); }
            _setWaitingTaskSet(waitingBatchId, _wbFiltered);
        }
        
        // 6. Rebuild combinedTasks completely from scratch
        // PLC: FOR-loop concat (korvaa [...spread])
        state.combinedTasks = [];
        for (let _ci = 0; _ci < inFlightTasks.length; _ci++) state.combinedTasks.push(inFlightTasks[_ci]);
        for (let _ci = 0; _ci < allTasks.length; _ci++) state.combinedTasks.push(allTasks[_ci]);
        
        state.pendingDelay = null;
        state.pendingDelays = [];
        
        log('RECALC_TASKS: ' + inFlightTasks.length + ' in-flight + ' + allTasks.length + ' from schedules = ' + state.combinedTasks.length + ' total');
        
        // Sovittelukierros: palaa CHECK_SORT → CHECK_ANALYZE uusilla tehtävillä
        log('RECALC_TASKS done → CHECK_SORT (sovittelukierros ' + state.departureRound + ')');
        nextPhase = PHASE.CHECK_SORT;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3090: ACTIVATE
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.ACTIVATE) {
        const batchIndex = state.waitingBatches[state.currentWaitingIndex];
        const batch = state.batches[batchIndex];
        const batchId = batch ? batch.batch_id : null;
        
        var _ctStr = (ctx.currentTimeSec != null && typeof ctx.currentTimeSec.toFixed === 'function') ? ctx.currentTimeSec.toFixed(1) : String(ctx.currentTimeSec);
        var _prevStr = (state.departureTimes && state.departureTimes.length > 0) ? state.departureTimes[state.departureTimes.length-1].simTimeSec.toFixed(1) + 's' : 'N/A';
        log('DIAG: ACTIVATE B' + batchId + ' @ ' + _ctStr + 's, prev=' + _prevStr);
        
        log('ACTIVATE B' + batchId);
        
        // ═══════════════════════════════════════════════════════════════
        // SNAPSHOT: Tallenna aktivointihetken aikataulut debug-analyysiin
        // ═══════════════════════════════════════════════════════════════
        try {
            const snapshotDir = path.join(__dirname, '..', 'debug_snapshots');
            if (!fs.existsSync(snapshotDir)) fs.mkdirSync(snapshotDir, { recursive: true });
            
            const sandbox = state.departureSandbox || {};
            const currentTimeSec = ctx.currentTimeSec || 0;
            
            // Kerää kaikkien linjalla olevien erien aikataulut
            const lineSchedules = {};
            if (sandbox.schedulesByBatchId) {
                for (const [bid, sched] of Object.entries(sandbox.schedulesByBatchId)) {
                    if (sched && sched.stages && sched.stages.length > 0) {
                        lineSchedules['B' + bid] = {
                            batch_id: Number(bid),
                            batchStage: sched.batchStage,
                            // PLC: FOR-loop (korvaa .map())
                            stages: (function() {
                                const _stgs = [];
                                for (let _si = 0; _si < sched.stages.length; _si++) {
                                    const s = sched.stages[_si];
                                    _stgs.push({
                                        stage: s.stage,
                                        station: s.station,
                                        entry_time_s: s.entry_time_s,
                                        exit_time_s: s.exit_time_s,
                                        treatment_time_s: s.treatment_time_s,
                                        min_time_s: s.min_time_s,
                                        max_time_s: s.max_time_s,
                                        transfer_time_s: s.transfer_time_s
                                    });
                                }
                                return _stgs;
                            })()
                        };
                    }
                }
            }
            
            // Kerää sandbox-taskit
            // PLC: FOR-loop (korvaa .map())
            const _sbSrc = sandbox.tasks || [];
            const sandboxTasks = [];
            for (let _ti = 0; _ti < _sbSrc.length; _ti++) {
                const t = _sbSrc[_ti];
                sandboxTasks.push({
                    batch_id: t.batch_id,
                    stage: t.stage,
                    transporter_id: t.transporter_id,
                    lift_station_id: t.lift_station_id,
                    sink_station_id: t.sink_station_id,
                    task_start_time: t.task_start_time,
                    task_finished_time: t.task_finished_time,
                    calc_time_s: t.calc_time_s,
                    min_time_s: t.min_time_s,
                    max_time_s: t.max_time_s
                });
            }
            
            // Kerää idle-slot tulokset
            const idleSlotInfo = state.idleSlotResult ? {
                allFit: state.idleSlotResult.allFit,
                actions: state.idleSlotResult.actions,
                logs: state.idleSlotResult.logs
            } : null;
            
            // Kerää erien nykytilat
            // PLC: FOR-loop (korvaa .filter().map())
            const batchStates = [];
            const _bsSrc = state.batches || [];
            for (let _bi = 0; _bi < _bsSrc.length; _bi++) {
                const b = _bsSrc[_bi];
                if (!b) continue;
                const _bLoc = ctx.getBatchLocation(b.batch_id);
                batchStates.push({
                    batch_id: b.batch_id,
                    stage: b.stage,
                    location: _bLoc != null ? _bLoc : b.location,
                    calc_time_s: b.calc_time_s,
                    min_time_s: b.min_time_s,
                    max_time_s: b.max_time_s
                });
            }
            
            const snapshot = {
                event: 'ACTIVATE',
                activated_batch_id: batchId,
                sim_time_sec: currentTimeSec,
                sim_time_formatted: scheduler.formatSecondsToTime(currentTimeSec),
                batch_states: batchStates,
                schedules: lineSchedules,
                sandbox_tasks: sandboxTasks,
                idle_slot_result: idleSlotInfo,
                timestamp: new Date().toISOString()
            };
            
            const filename = 'activate_B' + batchId + '_t' + Math.round(currentTimeSec) + '.json';
            fs.writeFileSync(path.join(snapshotDir, filename), JSON.stringify(snapshot, null, 2));
            log('SNAPSHOT: Saved activation snapshot: ' + filename);
        } catch (snapshotErr) {
            log('SNAPSHOT ERROR: ' + snapshotErr.message);
        }
        
        const currentSimTimeSec = ctx.currentTimeSec || 0;
        
        // Tallenna linjaanlähtöaika
        state.departureTimes.push({ batchId, simTimeSec: currentSimTimeSec });
        
        // Laske keskimääräinen linjaanlähtöväli
        if (state.departureTimes.length >= 2) {
            // PLC: FOR-loop (korvaa .map())
            const times = [];
            for (let _ti = 0; _ti < state.departureTimes.length; _ti++) times[_ti] = state.departureTimes[_ti].simTimeSec;
            let totalInterval = 0;
            for (let i = 1; i < times.length; i++) {
                totalInterval += times[i] - times[i - 1];
            }
            state.avgDepartureIntervalSec = totalInterval / (times.length - 1);
        }
        
        // Muuta stage 90 → 0 ja kirjaa sovittelun viiveet
        if (batch) {
            batch.stage = 0;
            batch.justActivated = true;
            
            // ═══════════════════════════════════════════════════════════════
            // Sandbox sisältää lopulliset arvot: kaikki viiveet (stage 0 + 1+)
            // on jo kirjattu RECALC-kierroksilla → lue suoraan sandboxista
            // ═══════════════════════════════════════════════════════════════
            // PLC: FOR-loop (korvaa .find())
            let sandboxBatch = null;
            if (state.departureSandbox && state.departureSandbox.batches) { for (let _sbi = 0; _sbi < state.departureSandbox.batches.length; _sbi++) { if (state.departureSandbox.batches[_sbi].batch_id === batchId) { sandboxBatch = state.departureSandbox.batches[_sbi]; break; } } }
            
            batch.start_time = Math.round(currentSimTimeSec * 1000);
            batch.calc_time_s = (sandboxBatch ? sandboxBatch.calc_time_s : 0) || 0;
            batch.min_time_s = (sandboxBatch ? sandboxBatch.min_time_s : 0) || 0;
            batch.max_time_s = (sandboxBatch ? sandboxBatch.max_time_s : 0) || 0;
            
            var _bctStr = (batch.calc_time_s != null && typeof batch.calc_time_s.toFixed === 'function') ? batch.calc_time_s.toFixed(1) : String(batch.calc_time_s);
            log('ACTIVATE B' + batchId + ': stage 0 → start=' + currentSimTimeSec.toFixed(1) + 's, calc=' + _bctStr + 's');
            
            // ═══════════════════════════════════════════════════════════════
            // Viiveet on jo kirjattu sandboxiin RECALC-kierroksilla.
            // Logataan lopulliset sandbox-ohjelman arvot.
            // ═══════════════════════════════════════════════════════════════
            const sandboxProgram = (state.departureSandbox && state.departureSandbox.programsByBatchId) ? state.departureSandbox.programsByBatchId[String(batchId)] : null;
            if (sandboxProgram) {
                for (let pi = 0; pi < sandboxProgram.length; pi++) {
                    const entry = sandboxProgram[pi];
                    if (!entry) continue;
                    const calcS = scheduler.parseTimeToSeconds(entry.calc_time) || 0;
                    log('ACTIVATE B' + batchId + ': program[' + pi + '] calc_time=' + calcS.toFixed(0) + 's');
                }
            }
            
            // Kutsu serverin setBatchStage — justActivated-lippu tallentuu batches.json:iin
            if (ctx.setBatchStage) {
                try {
                    await ctx.setBatchStage(batchId, 0, {
                        start_time: batch.start_time,
                        calc_time_s: batch.calc_time_s,
                        min_time_s: batch.min_time_s,
                        max_time_s: batch.max_time_s,
                        justActivated: true
                    });
                } catch (err) {
                    log('setBatchStage failed: ' + err.message);
                }
            }
            
            // ═══════════════════════════════════════════════════════════════
            // Tallenna lähtevän erän aikataulu (EntryTime / ExitTime)
            // Tämä on DEPARTUREn laskema aikataulu, jota vasten voidaan
            // verrata TASKSin ja toteutuneen suorituksen ajoituksia.
            // ═══════════════════════════════════════════════════════════════
            const activatedSchedule = (state.departureSandbox && state.departureSandbox.schedulesByBatchId) ? state.departureSandbox.schedulesByBatchId[String(batchId)] : null;
            if (activatedSchedule && activatedSchedule.stages) {
                log('SCHEDULE B' + batchId + ' aktivointihetken aikataulu:');
                for (const s of activatedSchedule.stages) {
                    var _sEntry = (s.entry_time_s != null && typeof s.entry_time_s.toFixed === 'function') ? s.entry_time_s.toFixed(1) : String(s.entry_time_s);
                    var _sExit = (s.exit_time_s != null && typeof s.exit_time_s.toFixed === 'function') ? s.exit_time_s.toFixed(1) : String(s.exit_time_s);
                    var _sTreat = (s.treatment_time_s != null && typeof s.treatment_time_s.toFixed === 'function') ? s.treatment_time_s.toFixed(1) : String(s.treatment_time_s);
                    var _sMin = (s.min_time_s != null && typeof s.min_time_s.toFixed === 'function') ? s.min_time_s.toFixed(1) : String(s.min_time_s);
                    var _sMax = (s.max_time_s != null && typeof s.max_time_s.toFixed === 'function') ? s.max_time_s.toFixed(1) : String(s.max_time_s);
                    log('SCHEDULE   stage=' + s.stage + ' station=' + s.station + ' entry=' + _sEntry + 's exit=' + _sExit + 's treatment=' + _sTreat + 's min=' + _sMin + 's max=' + _sMax + 's');
                }
                // Tallenna stateen niin TASKS ja debug voivat verrata
                state.activatedSchedules = state.activatedSchedules || {};
                state.activatedSchedules[String(batchId)] = _copySchedule(activatedSchedule);
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // Store pending write data — DO NOT write files here!
        // Files are written by TASKS SAVE phase to avoid race conditions.
        // DEPARTURE waits in WAIT_FOR_SAVE until TASKS has written.
        // ═══════════════════════════════════════════════════════════════════
        if (state.departureSandbox) {
            // Copy schedules and programs from sandbox hash maps to indexed arrays
            const sbSchedMap = state.departureSandbox.schedulesByBatchId || {};
            const copiedSchedMap = {};
            for (const k of Object.keys(sbSchedMap)) { copiedSchedMap[k] = _copySchedule(sbSchedMap[k]); }
            _schedulesFromHashMap(copiedSchedMap);
            _programsFromHashMap(_copyProgramsHashMap(state.departureSandbox.programsByBatchId || {}));
            
            // Collect batch calc_time updates for server
            const batchCalcUpdates = [];
            for (const [batchIdStr, program] of Object.entries(state.departureSandbox.programsByBatchId)) {
                const targetBatchId = parseInt(batchIdStr, 10);
                if (!Number.isFinite(targetBatchId) || targetBatchId === batchId) continue;
                
                // PLC: FOR-loop (korvaa .find())
                let targetBatch = null;
                if (state.departureSandbox.batches) { for (let _bi = 0; _bi < state.departureSandbox.batches.length; _bi++) { if (state.departureSandbox.batches[_bi].batch_id === targetBatchId) { targetBatch = state.departureSandbox.batches[_bi]; break; } } }
                if (!targetBatch || targetBatch.stage < 1 || targetBatch.stage >= 90) continue;
                
                const stageData = program[targetBatch.stage - 1];
                if (!stageData) continue;
                
                const calcTimeS = scheduler.parseTimeToSeconds(stageData.calc_time) || 0;
                if (calcTimeS > 0) {
                    batchCalcUpdates.push({ batchId: targetBatchId, stage: targetBatch.stage, calcTimeS });
                }
            }
            
            // Store pending data for TASKS SAVE to write
            state.pendingWriteData = {
                valid: true,
                programsByBatchId: _copyProgramsHashMap(_programsToHashMap()),
                schedulesByBatchId: (function() { const m = {}; const src = _schedulesToHashMap(); for (const k of Object.keys(src)) { m[k] = _copySchedule(src[k]); } return m; })(),
                batchCalcUpdates,
                currentTimeSec: ctx.currentTimeSec || 0
            };
            
            log('ACTIVATE B' + batchId + ': Pending write data stored, waiting for TASKS SAVE');
        }
        
        // Siirrä väliaikaiset viivästykset pysyvään listaan
        if (state.departureCandidateStretches && state.departureCandidateStretches.length > 0) {
            state.candidateStretches = state.candidateStretches || [];
            // PLC: FOR-loop (korvaa .push(...spread))
            for (let _si = 0; _si < state.departureCandidateStretches.length; _si++) state.candidateStretches.push(state.departureCandidateStretches[_si]);
            state.departureCandidateStretches = [];
        }
        
        // Siivoa
        _removeWaitingTaskSet(batchId);
        _removeWaitingSched(batchId);
        state.departureSandbox = null;
        state.sandboxSnapshot = null;
        state.finalDepartureConflict = null;
        
        state.currentWaitingIndex++;
        
        // Aseta handshake-lippu: TASKS-tilakone tietää olla ylikirjoittamatta CSV:tä
        state.activatedThisCycle = true;
        
        const waitSec = batch.calc_time_s || 0;
        log('ACTIVATE B' + batchId + ' DONE → WAIT_FOR_SAVE');
        nextPhase = PHASE.WAIT_FOR_SAVE;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3091: WAIT_FOR_SAVE
    // Wait for TASKS to reach SAVE phase and write our pending data.
    // This ensures no race condition: TASKS writes DEPARTURE's changes
    // before reading them back in the next INIT.
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.WAIT_FOR_SAVE) {
        // ACTIVATE-tikki palautti activated=true kerran → server.js reagoi.
        // Nollataan heti seuraavalla tikillä, ettei signaali toistu.
        state.activatedThisCycle = false;
        
        const TASKS_SAVE = 10001;
        
        // Check if TASKS has written our data (signaled via ctx.departureSaveConfirmed)
        if (ctx.departureSaveConfirmed) {
            log('WAIT_FOR_SAVE: TASKS confirmed save, proceeding to END_DELAY');
            state.pendingWriteData = { valid: false };
            nextPhase = PHASE.END_DELAY_START;
        } else {
            // Keep waiting — pendingWriteData stays available for TASKS to read
            log('WAIT_FOR_SAVE: Waiting for TASKS to save our data (tasksPhase=' + state.tasksPhase + ')');
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 4000-4100: END_DELAY
    // 100 tyhjää tickiä stabilointia varten - VAIN onnistuneen aktivoinnin jälkeen
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.END_DELAY_START) {
        log('END_DELAY start (100 ticks) after successful activation');
        state.endDelayCounter = 0;
        nextPhase = PHASE.END_DELAY_START + 1;
    }
    
    else if (p > PHASE.END_DELAY_START && p <= PHASE.END_DELAY_END) {
        state.endDelayCounter++;
        if (state.endDelayCounter >= END_DELAY_TICKS) {
            log('END_DELAY done');
            nextPhase = PHASE.RESTART;
        } else {
            nextPhase = p + 1;
            if (nextPhase > PHASE.END_DELAY_END) {
                nextPhase = PHASE.RESTART;
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 4101: RESTART
    // Palaa odottamaan TASKS-tilakonetta
    // ═══════════════════════════════════════════════════════════════════════════════
    else if (p === PHASE.RESTART) {
        // Syklin ajoitustilastot — PLC: _getSystemTimeMs(), _isFinite(), _ringBufferWrite()
        state.lastCycleTimeMs = _getSystemTimeMs() - state.cycleStartTime;
        state.totalCycles++;
        state.lastCycleTicks = state.cycleTickCount;
        state.lastCycleSimTimeMs = Math.round(state.lastCycleTicks * (_isFinite(state.cycleTickPeriodMs) ? state.cycleTickPeriodMs : 0));
        if (state.lastCycleTimeMs > state.longestCycleTimeMs) state.longestCycleTimeMs = state.lastCycleTimeMs;
        if (state.lastCycleTicks > state.longestCycleTicks) state.longestCycleTicks = state.lastCycleTicks;
        
        state.cycleHistoryCount = _ringBufferWrite(state.cycleHistory, state.cycleHistoryCount, MAX_CYCLE_HISTORY, state.lastCycleTimeMs);
        state.cycleTickHistoryCount = _ringBufferWrite(state.cycleTickHistory, state.cycleTickHistoryCount, MAX_CYCLE_HISTORY, state.lastCycleTicks);
        state.cycleSimTimeHistoryCount = _ringBufferWrite(state.cycleSimTimeHistory, state.cycleSimTimeHistoryCount, MAX_CYCLE_HISTORY, state.lastCycleSimTimeMs);
        
        log('Cycle complete: ' + state.lastCycleTimeMs + 'ms wall, ' + state.lastCycleTicks + ' ticks');

        log('RESTART → waiting for TASKS');
        state.finalDepartureConflict = state.lastDepartureConflict || null;
        state.lastDepartureConflict = null;
        // Nollaa handshake-lippu vasta kun TASKS on kuitannut sen
        // (activatedThisCycle nollataan WAITING_FOR_TASKS:ssa kun TASKS on lukenut uudet CSV:t)
        nextPhase = PHASE.WAITING_FOR_TASKS;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // Aseta seuraava vaihe
    // ═══════════════════════════════════════════════════════════════════════════════
    state.phase = nextPhase;
    
    return {
        phase: state.phase,
        phaseName: getPhaseName(state.phase),
        activated: state.activatedThisCycle,
        // Pending write data for TASKS SAVE to merge and write
        pendingWriteData: state.pendingWriteData,
        schedulesByBatchId: _schedulesToHashMap(),
        programsByBatchId: _programsToHashMap(),
        candidateStretches: state.candidateStretches,
        departureTimes: state.departureTimes,
        avgDepartureIntervalSec: state.avgDepartureIntervalSec,
        lastDepartureConflict: state.lastDepartureConflict,
        finalDepartureConflict: state.finalDepartureConflict
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// APUFUNKTIOT
// ═══════════════════════════════════════════════════════════════════════════════

function getPhaseName(p) {
    if (p === PHASE.WAITING_FOR_TASKS) return 'WAITING_FOR_TASKS';
    if (p === PHASE.INIT) return 'INIT';
    if (p === PHASE.DEPARTURE_CALC_START) return 'DEPARTURE_CALC_START';
    if (p >= PHASE.DEPARTURE_CALC_START + 1 && p <= PHASE.DEPARTURE_CALC_END) return 'DEPARTURE_CALC';
    if (p === PHASE.DEPARTURE_CALC_DONE) return 'DEPARTURE_CALC_DONE';
    if (p === PHASE.WAITING_SORT_START) return 'WAITING_SORT_START';
    if (p === PHASE.WAITING_SORT_LOADED) return 'WAITING_SORT_LOADED';
    if (p === PHASE.WAITING_SORT_DONE) return 'WAITING_SORT_DONE';
    if (p === PHASE.CHECK_START) return 'CHECK_START';
    if (p === PHASE.CHECK_CREATE_TASKS) return 'CHECK_CREATE_TASKS';
    if (p === PHASE.CHECK_SORT) return 'CHECK_SORT';
    if (p === PHASE.CHECK_SWAP) return 'CHECK_SWAP';
    if (p === PHASE.CHECK_ANALYZE) return 'CHECK_ANALYZE';
    if (p === PHASE.CHECK_RESOLVE) return 'CHECK_RESOLVE';
    if (p === PHASE.CHECK_UPDATE_PROGRAM) return 'CHECK_UPDATE_PROGRAM';
    if (p === PHASE.CHECK_RECALC_SCHEDULE) return 'CHECK_RECALC_SCHEDULE';
    if (p === PHASE.CHECK_RECALC_TASKS) return 'CHECK_RECALC_TASKS';
    if (p === PHASE.ACTIVATE) return 'ACTIVATE';
    if (p === PHASE.WAIT_FOR_SAVE) return 'WAIT_FOR_SAVE';
    if (p === PHASE.END_DELAY_START) return 'END_DELAY_START';
    if (p > PHASE.END_DELAY_START && p <= PHASE.END_DELAY_END) return 'END_DELAY';
    if (p === PHASE.RESTART) return 'RESTART';
    return 'UNKNOWN(' + p + ')';
}

function getState() {
    return state;
}

function getPhase() {
    return state.phase;
}

function reset() {
    state.phase = PHASE.WAITING_FOR_TASKS;
    state.batches = [];
    state.batchCount = 0;
    state.stations = [];
    state.stationCount = 0;
    state.transporters = [];
    state.transporterCount = 0;
    state.transporterStates = [];
    state.transporterStateCount = 0;
    state.schedules = []; state.scheduleCount = 0;
    state.programs = []; state.programCount = 0;
    state.waitingScheds = []; state.waitingSchedCount = 0;
    state.waitingAnalyses = []; state.waitingAnalysisCount = 0;
    state.waitingTaskSets = []; state.waitingTaskSetCount = 0;
    state.waitingBatches = [];
    state.waitingBatchCount = 0;
    state.currentWaitingIndex = 0;
    state.allCalcBatches = [];
    state.allCalcCount = 0;
    state.currentCalcIndex = 0;
    state.departureSandbox = null;
    state.sandboxSnapshot = null;
    state.combinedTasks = [];
    state.combinedTaskCount = 0;
    state.departureAnalysis = null;
    state.departureCandidateStretches = [];
    state.candidateStretches = [];
    state.candidateStretchCount = 0;
    state.pendingDelay = null;
    state.pendingDelays = [];
    state.pendingDelayCount = 0;
    state.departureLockedStages = []; state.depLockedStageCount = 0;
    state.inFlightTasks = [];
    state.inFlightTaskCount = 0;
    state.departureIteration = 0;
    state.departureRound = 0;
    state._currentDepartureBatchId = null;
    state.departureTimes = [];
    state.departureTimeCount = 0;
    state.avgDepartureIntervalSec = 0;
    state.lastDepartureConflict = null;
    state.finalDepartureConflict = null;
    state.pendingWriteData = { valid: false };
    state.endDelayCounter = 0;
    state.activatedThisCycle = false;
    state.phaseLog = [];
    state.phaseLogCount = 0;
    log('RESET');
}

// ═══════════════════════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════════════════════

module.exports = {
    tick,
    getState,
    getPhase,
    reset,
    getPhaseName,
    PHASE
};

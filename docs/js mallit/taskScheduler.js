/**
 * SchedulerStateMachine - V3.4 (PLC-compatible structure)
 *
 * State machine called every PLC cycle (tick).
 * Departure logic is handled by departureScheduler.js.
 *
 * PLC compatibility:
 * - Single phase counter
 * - Phase set ONLY at end of tick
 * - One tick = one step (no nested execution)
 * - When a 1000-range completes → advance to next thousand (1900 → 2000)
 *
 * Phase structure:
 *   0:           STOPPED
 *   1:           INIT (load runtime files)
 *   2:           INIT_PROGRAMS (one program per tick)
 *   3:           INIT_DONE (finalize → SCHEDULE_START)
 *   1000:        SCHEDULE start
 *   1001-1899:   SCHEDULE batch N
 *   1900:        SCHEDULE save
 *   2000:        TASKS start
 *   2001-2199:   TASKS batch N
 *   2200:        TASKS sort
 *   2201:        TASKS same-station swap
 *   2202:        TASKS analyze conflicts
 *   2203:        TASKS resolve conflict (→ SAVE, one conflict per cycle)
 *   2204:        TASKS no-treatment (Unit target tasks) — runs only when list is stable
 *   2900:        TASKS save + create departure sandbox
 *   10000:       READY
 *   10001:       SAVE_STRETCHES (apply calc_time stretches)
 *   10002:       SAVE_SCHEDULES (write schedules.json)
 *   10003:       SAVE_TASKS (write transporter_tasks.json)
 *   10004:       SAVE_ANALYSIS (write task_analysis.json)
 *   10005:       SAVE_DEPARTURE (merge DEPARTURE data)
 *   10006:       SAVE_PROGRAMS (write treatment programs)
 *   10007:       SAVE_CSV (write CSVs, one batch per tick)
 *   10099:       SAVE_DONE
 *   10100-10109: END_DELAY (idle ticks)
 *   10110:       RESTART → INIT
 *
 * @module schedulerStateMachine
 */

const scheduler = require('./transporterTaskScheduler');

// ═══════════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════

const PHASE = {
    STOPPED: 0,
    INIT: 1,
    INIT_PROGRAMS: 2,
    INIT_DONE: 3,
    SCHEDULE_START: 1000,
    SCHEDULE_SAVE: 1900,
    TASKS_START: 2000,
    TASKS_SORT: 2200,
    TASKS_SWAP: 2201,
    TASKS_ANALYZE: 2202,
    TASKS_RESOLVE: 2203,
    TASKS_NO_TREATMENT: 2204,
    TASKS_SAVE: 2900,
    READY: 10000,
    SAVE_STRETCHES: 10001,
    SAVE_SCHEDULES: 10002,
    SAVE_TASKS: 10003,
    SAVE_ANALYSIS: 10004,
    SAVE_DEPARTURE: 10005,
    SAVE_PROGRAMS: 10006,
    SAVE_CSV: 10007,
    SAVE_DONE: 10099,
    END_DELAY_START: 10100,
    END_DELAY_END: 10109,
    RESTART: 10110
};


const END_DELAY_TICKS = 1;

// ── PLC fixed-array bounds (ST: VAR_GLOBAL CONSTANT) ──
const MAX_TASKS = 200;
const MAX_STRETCHES = 50;
const MAX_RESOLVE = 100;
const MAX_BATCHES = 50;
const MAX_TRANSPORTERS = 10;
const MAX_STATIONS = 200;
const MAX_UNITS = 20;
const MAX_IDLE_SLOTS = 20;
const MAX_INIT_BATCHES = 50;
const MAX_LINE_SCHEDULES = 50;
const MAX_BATCH_CALC_UPDATES = 50;
const MAX_ACTUAL_CONFLICTS = 50;
const MAX_LOCKED_STAGES = 50;
const MAX_CYCLE_HISTORY = 1000;
const MAX_PHASE_LOG = 100;
const REAL_MAX = 1.0e+38;
const REAL_MIN = -1.0e+38;

// ── A3: Lock direction constants (ST: INT enum) ──
const LOCK_DELAY = 1;
const LOCK_ADVANCE = 2;

// ═══════════════════════════════════════════════════════════════════════════════
// STATE (persists between ticks)
// ═══════════════════════════════════════════════════════════════════════════════

const state = {
    // Phase counter — the only control variable
    phase: 0,

    // Cycle data (copied in INIT, persists for the cycle)
    batches: [],
    stations: [],
    transporters: [],
    transporterStates: [],
    batchCount: 0,
    stationCount: 0,
    transporterCount: 0,
    transporterStateCount: 0,

    // Computed results (A1/A2: indexed arrays instead of hash maps)
    schedules: [],
    scheduleCount: 0,
    programs: [],
    programCount: 0,
    tasks: [],
    taskCount: 0,

    // Departure sandbox (created in TASKS_SAVE, consumed by departureScheduler)
    departureSandbox: null,
    candidateStretches: [],
    candidateStretchCount: 0,
    departureCandidateStretches: [],

    // TASKS conflict resolution (A3: indexed array instead of hash map)
    conflictIteration: 0,
    conflictResolved: false,
    lockedStages: [],
    lockedStageCount: 0,
    resolveHistory: [],
    resolveHistoryCount: 0,
    taskAnalysis: null,

    // I/O sub-phase tracking (PLC: step counters within INIT/SAVE)
    initProgramIndex: 0,
    initBatchList: [],
    initBatchCount: 0,
    saveCsvIndex: 0,
    saveCsvBatches: [],
    lastError: 0,

    // Statistics
    cycleStartTime: 0,
    cycleStartTick: 0,
    cycleTickCount: 0,
    cycleTickPeriodMs: 0,
    totalCycles: 0,
    lastCycleTimeMs: 0,
    lastCycleTicks: 0,
    lastCycleSimTimeMs: 0,
    longestCycleTimeMs: 0,
    longestCycleTicks: 0,
    cycleHistory: [],
    cycleHistoryCount: 0,
    cycleTickHistory: [],
    cycleTickHistoryCount: 0,
    cycleSimTimeHistory: [],
    cycleSimTimeHistoryCount: 0,

    // Departure interval tracking
    departureTimes: [],
    avgDepartureIntervalSec: 0,

    // Debug
    phaseLog: [],
    phaseLogCount: 0
};

// ═══════════════════════════════════════════════════════════════════════════════
// CONTEXT (provided each tick, not persisted)
// ═══════════════════════════════════════════════════════════════════════════════

let ctx = {};

// ═══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

function log(msg) {
    const entry = { phase: state.phase, msg, time: _getSystemTimeMs() };
    state.phaseLogCount = _ringBufferWrite(state.phaseLog, state.phaseLogCount, MAX_PHASE_LOG, entry);
}

// G2: PLC → GET_SYSTEM_TIME (RTC milliseconds)
function _getSystemTimeMs() { return Date.now(); }

// G2: PLC → DT_TO_STRING(GET_DATE_AND_TIME())
function _getTimestampString() { return new Date().toISOString(); }

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

// ─── PLC-compatible helpers (ST: inline FOR loops) ───────────────────────────

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

/** Safe station types — buffer/loading/unloading (PLC: constant array) */
const SAFE_STATION_OPS = [20, 21, 22, 30, 31, 32, 33];
const SAFE_STATION_OPS_COUNT = 7;
function _isSafeStationOp(type) {
    const t = Number(type) || 0;
    for (let i = 0; i < SAFE_STATION_OPS_COUNT; i++) {
        if (SAFE_STATION_OPS[i] === t) return true;
    }
    return false;
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

/** Convert schedules array → hash map for external API (saveSchedules, sandbox) */
function _schedulesToHashMap() {
    const map = {};
    for (let i = 0; i < state.scheduleCount; i++) {
        map[String(state.schedules[i].batchId)] = state.schedules[i].data;
    }
    return map;
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

/** Convert programs array → hash map for external API (writeTreatmentPrograms, getData, sandbox) */
function _programsToHashMap() {
    const map = {};
    for (let i = 0; i < state.programCount; i++) {
        map[String(state.programs[i].batchId)] = state.programs[i].data;
    }
    return map;
}

// ── A3: LockedStages indexed-array helpers (replaces lockedStages hash map) ──
// lockKey: INT packed as batchId * 100 + stage (e.g. B3s5 → 305)
// lockDirection: LOCK_DELAY (1) or LOCK_ADVANCE (2)

function _lockKeyToInt(stringKey) {
    // Parse "B{batchId}s{stage}" → batchId * 100 + stage
    const bIdx = stringKey.indexOf('B');
    const sIdx = stringKey.indexOf('s', bIdx + 1);
    if (bIdx < 0 || sIdx < 0) return -1;
    const batchId = parseInt(stringKey.substring(bIdx + 1, sIdx), 10);
    const stage = parseInt(stringKey.substring(sIdx + 1), 10);
    if (batchId !== batchId || stage !== stage) return -1; // NaN check
    return batchId * 100 + stage;
}

function _lockDirectionToInt(dir) {
    if (dir === 'DELAY') return LOCK_DELAY;
    if (dir === 'ADVANCE') return LOCK_ADVANCE;
    return 0;
}

function _lockDirectionToString(dirInt) {
    if (dirInt === LOCK_DELAY) return 'DELAY';
    if (dirInt === LOCK_ADVANCE) return 'ADVANCE';
    return '';
}

function _findLockedStageIndex(lockKeyInt) {
    for (let i = 0; i < state.lockedStageCount; i++) {
        if (state.lockedStages[i].lockKey === lockKeyInt) return i;
    }
    return -1;
}

function _setLockedStage(lockKeyString, lockDirectionString) {
    const keyInt = _lockKeyToInt(lockKeyString);
    const dirInt = _lockDirectionToInt(lockDirectionString);
    if (keyInt < 0 || dirInt === 0) return;
    const idx = _findLockedStageIndex(keyInt);
    if (idx >= 0) {
        state.lockedStages[idx].lockDirection = dirInt;
    } else if (state.lockedStageCount < MAX_LOCKED_STAGES) {
        state.lockedStages[state.lockedStageCount++] = { lockKey: keyInt, lockDirection: dirInt };
    }
}

function _clearLockedStages() {
    state.lockedStages = [];
    state.lockedStageCount = 0;
}

/** Convert lockedStages array → hash map for resolveConflict API */
function _lockedStagesToHashMap() {
    const map = {};
    for (let i = 0; i < state.lockedStageCount; i++) {
        const entry = state.lockedStages[i];
        const batchId = Math.floor(entry.lockKey / 100);
        const stage = entry.lockKey % 100;
        map['B' + batchId + 's' + stage] = _lockDirectionToString(entry.lockDirection);
    }
    return map;
}

/** Explicit sandbox copy — replaces JSON.parse(JSON.stringify(state))
 *  PLC: field-by-field struct copy, no Object.assign / JSON deep copy */
function _copySandbox() {
    const sb = {};
    // Scalar fields
    sb.phase = state.phase;
    sb.batchCount = state.batchCount;
    sb.stationCount = state.stationCount;
    sb.transporterCount = state.transporterCount;
    sb.transporterStateCount = state.transporterStateCount;
    sb.taskCount = state.taskCount;
    sb.conflictIteration = state.conflictIteration;
    sb.conflictResolved = state.conflictResolved;
    sb.candidateStretchCount = 0;
    sb.resolveHistoryCount = 0;
    sb.lastError = 0;

    // Config references (read-only, shared)
    sb.stations = state.stations;
    sb.transporters = state.transporters;

    // Copy batches entry-by-entry (PLC: field-by-field struct copy)
    sb.batches = [];
    for (let i = 0; i < state.batchCount; i++) {
        const src = state.batches[i];
        sb.batches[i] = {
            batch_id: src.batch_id,
            stage: src.stage,
            treatment_program: src.treatment_program,
            start_time: src.start_time,
            calc_time_s: src.calc_time_s,
            min_time_s: src.min_time_s,
            max_time_s: src.max_time_s,
            isDelayed: src.isDelayed,
            justActivated: src.justActivated
        };
    }

    // Copy transporter states (nested .state object — PLC: two-level struct copy)
    sb.transporterStates = [];
    for (let i = 0; i < state.transporterStateCount; i++) {
        const src = state.transporterStates[i];
        const tsCopy = {
            id: src.id,
            name: src.name
        };
        if (src.state) {
            tsCopy.state = {
                status: src.state.status,
                phase: src.state.phase,
                x_position: src.state.x_position,
                sink_station_target: src.state.sink_station_target
            };
        } else {
            tsCopy.state = null;
        }
        sb.transporterStates[i] = tsCopy;
    }

    // Copy tasks entry-by-entry (PLC: field-by-field struct copy)
    sb.tasks = [];
    for (let i = 0; i < state.taskCount; i++) {
        const src = state.tasks[i];
        sb.tasks[i] = {
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
            calc_time_s: src.calc_time_s
        };
    }

    // ── B1: Deep copy schedules field-by-field (PLC: nested struct copy) ──
    sb.schedulesByBatchId = {};
    for (let i = 0; i < state.scheduleCount; i++) {
        const entry = state.schedules[i];
        const srcData = entry.data;
        const copiedSchedule = {};
        // Copy scalar schedule fields
        if (srcData.batchStage !== undefined) copiedSchedule.batchStage = srcData.batchStage;
        if (srcData.totalTime !== undefined) copiedSchedule.totalTime = srcData.totalTime;
        if (srcData.totalTransferTime !== undefined) copiedSchedule.totalTransferTime = srcData.totalTransferTime;
        // Copy stages array field-by-field
        if (srcData.stages) {
            copiedSchedule.stages = [];
            const stageLen = srcData.stages.length;
            for (let si = 0; si < stageLen; si++) {
                copiedSchedule.stages[si] = _copyScheduleStage(srcData.stages[si]);
            }
        }
        sb.schedulesByBatchId[String(entry.batchId)] = copiedSchedule;
    }

    // ── B2: Deep copy programs field-by-field (PLC: nested struct copy) ──
    sb.programsByBatchId = {};
    for (let i = 0; i < state.programCount; i++) {
        const entry = state.programs[i];
        const srcProg = entry.data;
        // Program is an array of stage objects
        const copiedProgram = [];
        if (srcProg) {
            const progLen = srcProg.length;
            for (let pi = 0; pi < progLen; pi++) {
                copiedProgram[pi] = _copyProgramStage(srcProg[pi]);
            }
        }
        sb.programsByBatchId[String(entry.batchId)] = copiedProgram;
    }

    // Other needed fields (A3: array → hash map for sandbox)
    sb.lockedStages = _lockedStagesToHashMap();
    sb.candidateStretches = [];
    sb.departureCandidateStretches = [];
    sb.resolveHistory = [];
    if (state.taskAnalysis) {
        sb.taskAnalysis = {
            hasConflict: state.taskAnalysis.hasConflict,
            conflict: state.taskAnalysis.conflict,
            conflicts: state.taskAnalysis.conflicts,
            checkedTasks: state.taskAnalysis.checkedTasks,
            summary: state.taskAnalysis.summary
        };
    } else {
        sb.taskAnalysis = null;
    }

    return sb;
}

/** B1 helper: Copy a single schedule stage struct field-by-field.
 *  PLC: ST_ScheduleStage := src_stage; (struct assignment) */
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
    // Optional fields (present only in some stages)
    if (src.station_name !== undefined) copy.station_name = src.station_name;
    if (src.min_exit_time_s !== undefined) copy.min_exit_time_s = src.min_exit_time_s;
    if (src.max_exit_time_s !== undefined) copy.max_exit_time_s = src.max_exit_time_s;
    if (src.transfer_details !== undefined) copy.transfer_details = src.transfer_details;
    if (src.parallel_stations !== undefined) copy.parallel_stations = src.parallel_stations;
    if (src.selected_from_parallel !== undefined) copy.selected_from_parallel = src.selected_from_parallel;
    return copy;
}

/** B2 helper: Copy a single program stage struct field-by-field.
 *  PLC: ST_ProgramStage := src_stage; (struct assignment) */
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

// ─── C2: Overtime ratio (extracted from TASKS_SORT closure) ──────────────────

/** C2: Laskee erän yliaikakertoimen. Itsenäinen funktio, kaikki riippuvuudet parametreina.
 *  PLC: FUNCTION _getOvertimeRatio : REAL */
function _getOvertimeRatio(task, batches, batchCount, currentTimeSec, getBatchLocation) {
    // PLC: FOR-loop find batch by id
    let batch = null;
    for (let i = 0; i < batchCount; i++) {
        const b = batches[i];
        if (b != null && Number(b.batch_id) === task.batch_id) { batch = b; break; }
    }
    if (!batch) return 0;

    // Only if batch IS at station (lift = current location) and this is the batch's current stage
    if (getBatchLocation(batch.batch_id) !== task.lift_station_id) return 0;
    if (batch.stage !== task.stage) return 0;

    const startTimeMs = Number(batch.start_time) || 0;
    const maxTimeS = Number(batch.max_time_s) || 0;

    if (startTimeMs <= 0 || maxTimeS <= 0) return 0;

    const elapsedS = currentTimeSec - (startTimeMs / 1000);
    return elapsedS / maxTimeS;
}

// ─── C3: Task priority comparator (extracted from TASKS_SORT arrow callback) ─

/** C3: Vertailufunktio tehtävien priorisointiin. Ei sulkeumia — context-struct sisältää tilan.
 *  PLC: FUNCTION _compareTasksPriority : INT (negatiivinen = a ensin, positiivinen = b ensin) */
function _compareTasksPriority(a, b, context) {
    // 1. Group by transporter
    if (a.transporter_id !== b.transporter_id) {
        return a.transporter_id - b.transporter_id;
    }

    // 2. EMERGENCY priority (overtimeRatio > 1.0)
    const aRatio = _getOvertimeRatio(a, context.batches, context.batchCount, context.currentTimeSec, context.getBatchLocation);
    const bRatio = _getOvertimeRatio(b, context.batches, context.batchCount, context.currentTimeSec, context.getBatchLocation);
    const aEmergency = aRatio > 1.0;
    const bEmergency = bRatio > 1.0;

    // If both emergency, higher ratio first
    if (aEmergency && bEmergency) return bRatio - aRatio;

    // Only one is emergency — it goes first
    if (aEmergency && !bEmergency) return -1;
    if (!aEmergency && bEmergency) return 1;

    // 3. Normal order: earliest task_start_time first
    return a.task_start_time - b.task_start_time;
}

// ─── NO-TREATMENT helpers ────────────────────────────────────────────────────

/**
 * Etsi nostin jonka x-alue kattaa Unitin aseman ja jolla on targetDef-konfiguraatio.
 * @returns {{ transporter, config }} | null
 */
function _findCoveringTransporter(unit, targetDef) {
    const unitStationObj = scheduler.findStation(unit.location, state.stations);
    if (!unitStationObj) return null;
    const unitX = unitStationObj.x_position;

    for (let ti = 0; ti < state.transporterCount; ti++) {
        const tCfg = state.transporters[ti];
        const tMin = (tCfg.x_min_drive_limit != null) ? tCfg.x_min_drive_limit : REAL_MIN;
        const tMax = (tCfg.x_max_drive_limit != null) ? tCfg.x_max_drive_limit : REAL_MAX;
        if (unitX < tMin || unitX > tMax) continue;

        const tTransporters = targetDef.transporters;
        const tTargetDef = (tTransporters != null) ? tTransporters[String(tCfg.id)] : null;
        if (tTargetDef && tTargetDef.stations && tTargetDef.stations.length > 0) {
            return { transporter: tCfg, config: tTargetDef };
        }
    }
    return null;
}

/** C1: Aseman vapaustarkistus — irrotettu _findSinkStation-sulkeumasta.
 *  PLC: FUNCTION _isStationFree : BOOL, kaikki riippuvuudet parametreina. */
function _isStationFree(sid, unitStation, isLocationOccupied, transporterStates, transporterStateCount, tasks, taskCount) {
    if (sid === unitStation) return false;
    if (isLocationOccupied(sid)) return false;
    // Nostin matkalla tähän asemaan? (PLC: FOR-loop)
    for (let i = 0; i < transporterStateCount; i++) {
        const ts = transporterStates[i];
        if (ts.state && ts.state.sink_station_target === sid &&
            ts.state.phase >= 1 && ts.state.phase <= 4) {
            return false;
        }
    }
    // Task-listalla jo tehtävä tähän asemaan? (PLC: FOR-loop)
    for (let i = 0; i < taskCount; i++) {
        if (tasks[i].sink_station_id === sid) return false;
    }
    return true;
}

/**
 * Etsi vapaa kohde-asema (primary > fallback).
 * Jos unit on jo primary-asemalla → null.
 * Jos unit on fallback-asemalla → vain primary sallittu.
 * C1: isFree-sulkeuma korvattu _isStationFree-kutsulla.
 * @returns {{ sinkStationId, isPrimaryDestination }} | null
 */
function _findSinkStation(unitStation, transporterCfg, transporterStates, transporterStateCount) {
    const primaryStations = transporterCfg.stations || [];
    const primaryCount = primaryStations.length;
    const fallbackStations = transporterCfg.fallback_stations || [];
    const fallbackCount = fallbackStations.length;

    // Unit on jo primary-kohteessa → ei tehdä mitään
    if (_arrayIncludes(primaryStations, primaryCount, unitStation)) return null;

    const unitAtFallback = _arrayIncludes(fallbackStations, fallbackCount, unitStation);

    // Ensisijaiset kohteet (C1: explicit params instead of closure)
    for (let pi = 0; pi < primaryCount; pi++) {
        const sid = primaryStations[pi];
        if (_isStationFree(sid, unitStation, ctx.isLocationOccupied, transporterStates, transporterStateCount, state.tasks, state.taskCount)) {
            return { sinkStationId: sid, isPrimaryDestination: true };
        }
    }

    // Toissijaiset — vain jos Unit EI ole jo fallback-asemalla
    if (!unitAtFallback) {
        for (let fi = 0; fi < fallbackCount; fi++) {
            const sid = fallbackStations[fi];
            if (_isStationFree(sid, unitStation, ctx.isLocationOccupied, transporterStates, transporterStateCount, state.tasks, state.taskCount)) {
                return { sinkStationId: sid, isPrimaryDestination: false };
            }
        }
    }

    return null;
}

/**
 * Laske idle-slot, matka-ajat ja kokonaiskesto.
 * @returns {{ travelToPickup, taskDuration, totalTime, idleRemaining, currentSlot, pickupStation, sinkStation }} | null
 */
function _calculateTiming(tId, unitStation, sinkStationId, coveringTransporter, tState, currentTimeSec, movementTimes, MARGIN_S) {
    const idleSlots = scheduler.calculateTransporterIdleSlots(tId, state.tasks, currentTimeSec);
    if (!idleSlots || idleSlots.length === 0) return null;

    // PLC: FOR-loop find instead of .find()
    let currentSlot = null;
    for (let si = 0; si < idleSlots.length; si++) {
        const s = idleSlots[si];
        if (s.start <= currentTimeSec && s.end > currentTimeSec) { currentSlot = s; break; }
    }
    if (!currentSlot) currentSlot = idleSlots[0];
    if (!currentSlot || currentSlot.end <= currentTimeSec) return null;

    const idleRemaining = currentSlot.end - currentTimeSec;

    const pickupStation = scheduler.findStation(unitStation, state.stations);
    const sinkStation = scheduler.findStation(sinkStationId, state.stations);
    if (!pickupStation || !sinkStation) return null;

    // Nostimen nykyinen paikka → noutoasema
    let travelToPickup = 0;
    const currentX = (tState.state != null) ? tState.state.x_position : undefined;
    if (currentX != null && _isFinite(currentX)) {
        travelToPickup = scheduler.calculateHorizontalTravelTime(
            { x_position: currentX }, pickupStation, coveringTransporter
        );
    }

    // Siirtotehtävän kesto (nosto + matka + lasku)
    const transferTime = scheduler.calculateTransferTime(
        pickupStation, sinkStation, coveringTransporter, movementTimes
    );
    const taskDuration = (transferTime != null) ? (transferTime.total_s || 0) : 0;
    if (taskDuration <= 0) return null;

    // Matka jättöpaikasta → seuraavan tehtävän nouto
    let travelToNext = 0;
    if (currentSlot.nextTask) {
        const nextLiftStation = scheduler.findStation(currentSlot.nextTask.lift_station_id, state.stations);
        if (nextLiftStation) {
            travelToNext = scheduler.calculateHorizontalTravelTime(
                sinkStation, nextLiftStation, coveringTransporter
            );
        }
    }

    const totalTime = travelToPickup + taskDuration + travelToNext + MARGIN_S;

    return { travelToPickup, taskDuration, totalTime, idleRemaining, currentSlot, pickupStation, sinkStation };
}

/**
 * Flex-fit: yritä viivästää seuraavaa taskia niin, että NO-TREATMENT mahtuu idle-slottiin.
 * @returns {boolean} true = onnistui (tai ei tarvittu), false = ei mahdu
 */
function _tryFlexFit(unit, tId, unitStation, sinkStationId, totalTime, idleRemaining, currentSlot) {
    const nextTask = currentSlot.nextTask;
    if (!nextTask || !nextTask.batch_id) return false;

    const deficit = totalTime - idleRemaining;

    // 1. Joustovara: max_time - calc_time
    const flexRoom = (nextTask.max_time_s || 0) - (nextTask.calc_time_s || 0);
    if (flexRoom <= 0 || deficit > flexRoom) {
        log('NO-TREATMENT: FLEX-FIT U' + unit.unit_id + ' T' + tId + ' ' + unitStation + '→' + sinkStationId + ' deficit=' + deficit.toFixed(1) + 's > flex=' + flexRoom.toFixed(1) + 's → SKIP');
        return false;
    }

    // 2. Ei uutta konfliktia: tarkista seuraava-seuraava taski (PLC: FOR-loop scan)
    let taskAfterNext = null;
    let minStartAfter = REAL_MAX;
    for (let i = 0; i < state.taskCount; i++) {
        const t = state.tasks[i];
        if (t.transporter_id === tId && t.task_start_time > nextTask.task_start_time) {
            if (t.task_start_time < minStartAfter) {
                minStartAfter = t.task_start_time;
                taskAfterNext = t;
            }
        }
    }
    if (taskAfterNext) {
        const gapAfter = taskAfterNext.task_start_time - nextTask.task_finished_time;
        if (deficit > gapAfter) {
            log('NO-TREATMENT: FLEX-FIT U' + unit.unit_id + ' T' + tId + ' deficit=' + deficit.toFixed(1) + 's > gap=' + gapAfter.toFixed(1) + 's → CONFLICT');
            return false;
        }
    }

    // 3. Siirrä seuraavan taskin erän kaikki myöhemmät vaiheet (PLC: FOR-loop)
    for (let i = 0; i < state.taskCount; i++) {
        const t = state.tasks[i];
        if (t.batch_id === nextTask.batch_id && t.task_start_time >= nextTask.task_start_time) {
            t.task_start_time += deficit;
            t.task_finished_time += deficit;
        }
    }

    // 4. Tallenna stretch (PLC: counter-based push)
    if (state.candidateStretchCount < MAX_STRETCHES) {
        state.candidateStretches[state.candidateStretchCount++] = {
            batchId: nextTask.batch_id,
            stage: nextTask.stage,
            delayS: deficit
        };
    }

    log('NO-TREATMENT: FLEX-FIT U' + unit.unit_id + ' T' + tId + ' ' + unitStation + '→' + sinkStationId + ': delayed B' + nextTask.batch_id + ' s' + nextTask.stage + ' +' + deficit.toFixed(1) + 's (flex=' + flexRoom.toFixed(1) + 's)');
    return true;
}

/**
 * Overlap-tarkistus: onko sink-asema overlap-alueella ja toisella nostimella päällekkäinen tehtävä?
 * @returns {boolean} true = konflikti löytyi
 */
function _hasOverlapConflict(tId, coveringTransporter, sinkStation, estTaskStart, taskDuration, transporterStates, transporterStateCount) {
    const sinkX = sinkStation.x_position;
    const phys2D = coveringTransporter.physics_2D;
    const avoidDist = (phys2D != null) ? (phys2D.avoid_distance_mm || 0) : 0;
    const estTaskEnd = estTaskStart + taskDuration;
    const myMin = (coveringTransporter.x_min_drive_limit != null) ? coveringTransporter.x_min_drive_limit : REAL_MIN;
    const myMax = (coveringTransporter.x_max_drive_limit != null) ? coveringTransporter.x_max_drive_limit : REAL_MAX;

    for (let oi = 0; oi < state.transporterCount; oi++) {
        const otherT = state.transporters[oi];
        if (otherT.id === tId) continue;
        const otherMin = (otherT.x_min_drive_limit != null) ? otherT.x_min_drive_limit : REAL_MAX;
        const otherMax = (otherT.x_max_drive_limit != null) ? otherT.x_max_drive_limit : REAL_MIN;
        const overlapMin = Math.max(myMin, otherMin);
        const overlapMax = Math.min(myMax, otherMax);
        if (overlapMin >= overlapMax) continue; // Ei overlappia

        // Sink ei ole overlap-alueella?
        if (sinkX < overlapMin || sinkX > overlapMax) continue;

        // Danger zone = overlap ± avoidDist
        const dangerZoneMin = overlapMin - avoidDist;
        const dangerZoneMax = overlapMax + avoidDist;

        // Tarkista toisen nostimen tehtävät
        for (let ti = 0; ti < state.taskCount; ti++) {
            const otherTask = state.tasks[ti];
            if (otherTask.transporter_id !== otherT.id) continue;
            if (otherTask.task_finished_time <= estTaskStart || otherTask.task_start_time >= estTaskEnd) continue;
            const otherLift = scheduler.findStation(otherTask.lift_station_id, state.stations);
            const otherSink = scheduler.findStation(otherTask.sink_station_id, state.stations);
            const otherLiftX = (otherLift != null) ? (otherLift.x_position != null ? otherLift.x_position : REAL_MIN) : REAL_MIN;
            const otherSinkX = (otherSink != null) ? (otherSink.x_position != null ? otherSink.x_position : REAL_MIN) : REAL_MIN;
            if ((otherLiftX >= dangerZoneMin && otherLiftX <= dangerZoneMax) ||
                (otherSinkX >= dangerZoneMin && otherSinkX <= dangerZoneMax)) {
                log('NO-TREATMENT: OVERLAP T' + tId + '→' + sinkStation.id + ' vs T' + otherT.id + ' task ' + otherTask.lift_station_id + '→' + otherTask.sink_station_id);
                return true;
            }
        }

        // Tarkista toisen nostimen aktiivinen sijainti (PLC: FOR-loop find)
        let otherState = null;
        for (let i = 0; i < transporterStateCount; i++) {
            if (transporterStates[i].id === otherT.id) { otherState = transporterStates[i]; break; }
        }
        if (otherState && otherState.state && otherState.state.phase >= 1 && otherState.state.phase <= 4) {
            const otherX = (otherState.state.x_position != null) ? otherState.state.x_position : REAL_MIN;
            const otherSinkTarget = otherState.state.sink_station_target;
            const otherSinkObj = otherSinkTarget ? scheduler.findStation(otherSinkTarget, state.stations) : null;
            const otherTargetX = (otherSinkObj != null) ? (otherSinkObj.x_position != null ? otherSinkObj.x_position : REAL_MIN) : REAL_MIN;
            if ((otherX >= dangerZoneMin && otherX <= dangerZoneMax) ||
                (otherTargetX >= dangerZoneMin && otherTargetX <= dangerZoneMax)) {
                log('NO-TREATMENT: OVERLAP T' + tId + '→' + sinkStation.id + ' vs T' + otherT.id + ' active x=' + otherX);
                return true;
            }
        }
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// STATE MACHINE - TICK
//
// PLC-compatible structure:
// 1. Read phase
// 2. Execute ONE case branch (no nesting)
// 3. Set nextPhase
// 4. phase := nextPhase (ONCE, at the very end)
// ═══════════════════════════════════════════════════════════════════════════════

async function tick(context) {
    ctx = context;
    const p = state.phase;
    let nextPhase = p;
    let pauseRequested = false;
    state.cycleTickCount++;
    
    if (p === PHASE.STOPPED) {
        // PHASE 0: STOPPED — waiting for start()
        nextPhase = PHASE.STOPPED;
    }
    
    else if (p === PHASE.INIT) {
        // PHASE 1: INIT — load runtime files, set config
        // PLC: one I/O request per phase (file reads)
        state.cycleStartTime = _getSystemTimeMs();
        state.cycleStartTick = _isFinite(Number(ctx.simTick)) ? Number(ctx.simTick) : 0;
        state.cycleTickCount = 0;

        const periodMs = Number(ctx.tickPeriodMs);
        const dtMs = Number(ctx.tickDtMs);
        state.cycleTickPeriodMs = _isFinite(periodMs) ? periodMs * 2 : (_isFinite(dtMs) ? dtMs * 2 : 0);

        // Read runtime files (PLC: COMM_READ FB)
        const batchesData = await ctx.loadRuntimeFile('batches.json');
        state.batches = (batchesData && batchesData.batches) ? batchesData.batches : [];

        const statesData = await ctx.loadRuntimeFile('transporter_states.json');
        state.transporterStates = (statesData && statesData.transporters) ? statesData.transporters : [];
        state.transporterStateCount = state.transporterStates.length;

        state.schedules = [];
        state.scheduleCount = 0;
        state.tasks = [];
        state.taskCount = 0;

        log('INIT: Loaded ' + state.batches.length + ' batches, ' + state.transporterStateCount + ' transporter states');

        // Config data (passed via context by server)
        state.stations = ctx.stations || [];
        state.stationCount = state.stations.length;
        state.transporters = ctx.transporters || [];
        state.transporterCount = state.transporters.length;

        // Count batches (PLC: FOR-loop count)
        state.batchCount = 0;
        const totalBatches = state.batches.length;
        for (let i = 0; i < totalBatches; i++) {
            const b = state.batches[i];
            if (b && b.stage >= 0 && b.stage < 90) state.batchCount++;
        }

        // Prepare program loading list for INIT_PROGRAMS phase (PLC: counter-based append)
        state.programs = [];
        state.programCount = 0;
        state.initBatchList = [];
        state.initBatchCount = 0;
        for (let i = 0; i < totalBatches; i++) {
            const batch = state.batches[i];
            if (batch && batch.batch_id && batch.treatment_program) {
                if (state.initBatchCount < MAX_INIT_BATCHES) {
                    state.initBatchList[state.initBatchCount++] = batch;
                }
            }
        }
        state.initProgramIndex = 0;

        log('INIT: ' + state.batchCount + ' batches, ' + state.initBatchCount + ' programs to load');
        nextPhase = (state.initBatchCount > 0) ? PHASE.INIT_PROGRAMS : PHASE.INIT_DONE;
    }

    else if (p === PHASE.INIT_PROGRAMS) {
        // PHASE 2: Load ONE treatment program per tick (PLC: one COMM_READ per scan)
        const idx = state.initProgramIndex;
        if (idx < state.initBatchCount) {
            const batch = state.initBatchList[idx];
            let program = ctx.programs ? ctx.programs[batch.batch_id] : null;
            if (!program && ctx.loadTreatmentProgram) {
                const programNumber = parseInt(batch.treatment_program || '001', 10);
                program = await ctx.loadTreatmentProgram(batch.batch_id, programNumber);
            }
            if (program) {
                _setProgram(batch.batch_id, program);
            }
            state.initProgramIndex++;
            nextPhase = (state.initProgramIndex < state.initBatchCount)
                ? PHASE.INIT_PROGRAMS : PHASE.INIT_DONE;
        } else {
            nextPhase = PHASE.INIT_DONE;
        }
    }

    else if (p === PHASE.INIT_DONE) {
        // PHASE 3: Finalize INIT — reset counters, go to SCHEDULE
        log('INIT: Loaded ' + state.programCount + ' treatment programs');

        state.conflictIteration = 0;
        state.departureSandbox = null;
        state.sandboxSnapshot = null;
        state.candidateStretches = [];
        state.candidateStretchCount = 0;
        state.departureCandidateStretches = [];
        state.lastError = 0;

        log('INIT_DONE: ' + state.batchCount + ' batches');
        nextPhase = PHASE.SCHEDULE_START;
    }
    
    else if (p === PHASE.SCHEDULE_START) {
        // PHASE 1000: SCHEDULE start
        if (state.batchCount === 0) {
            log('No batches, skip to TASKS');
            nextPhase = PHASE.TASKS_START;
        } else {
            nextPhase = PHASE.SCHEDULE_START + 1; // 1001
        }
    }
    
    else if (p >= PHASE.SCHEDULE_START + 1 && p <= PHASE.SCHEDULE_SAVE - 1) {
        // PHASE 1001-1899: SCHEDULE batch N (N = phase - 1000)
        const batchIndex = p - PHASE.SCHEDULE_START - 1;
        
        if (batchIndex < state.batchCount) {
            const batch = state.batches[batchIndex];
            const batchId = (batch != null) ? batch.batch_id : undefined;
            const existingSchedule = _getSchedule(batchId);
            
            // Schedule is recalculated ONLY when the batch is AT A STATION.
            // When on a transporter, keep the existing schedule (transfer in progress).
            // Stage 90 batches are scheduled in the departure scheduler, not here.
            const isStage90 = batch && batch.stage === 90;
            const isOnTransporter = batch && ctx.isBatchOnTransporter(batch.batch_id);
            const shouldKeepSchedule = isOnTransporter && !isStage90 && !!existingSchedule;
            
            // Stage 90 (waiting) batches: skip here, handled by departureScheduler
            if (isStage90) {
                // Advance to next batch or SAVE
                if (batchIndex + 1 < state.batchCount) {
                    nextPhase = p + 1;
                } else {
                    nextPhase = PHASE.SCHEDULE_SAVE;
                }
            } else {
            
            // ═══ DEPARTURE ACTIVATED: 1. kerta kun TASKS käsittelee erän ═══
            // Departure asetti: start_time, calc_time_s, min_time_s, max_time_s
            // TASKS päivittää: start=now, calc=calc-elapsed, min=calc, max=2×min
            if (batch.justActivated) {
                const now = ctx.currentTimeSec || 0;
                const originalStartSec = (batch.start_time || 0) / 1000;
                const elapsed = Math.max(0, now - originalStartSec);
                const oldCalc = batch.calc_time_s || 0;
                batch.calc_time_s = Math.max(1, oldCalc - elapsed);
                batch.start_time = Math.round(now * 1000);
                batch.min_time_s = batch.calc_time_s;
                batch.max_time_s = 2 * batch.min_time_s;
                log('B' + batchId + ' ACTIVATED → TASKS 1st: elapsed=' + elapsed.toFixed(1) + 's, calc=' + oldCalc.toFixed(1) + '→' + batch.calc_time_s.toFixed(1) + 's, min=' + batch.min_time_s.toFixed(1) + 's, max=' + batch.max_time_s.toFixed(1) + 's');
                // justActivated säilytetään SAVE-vaihetta varten (CSV overwrite:true + persistointi)
            }
            
            // Programs loaded in INIT — no I/O here.
            // Conflict resolution updates programs in memory; SAVE writes to CSV.
            const program = _getProgram(batchId);

            // Batch on transporter with existing schedule: keep it (transfer in progress)
            if (shouldKeepSchedule) {
                existingSchedule.batchStage = batch.stage;
                _setSchedule(batchId, existingSchedule);
            } else if (batch && batch.batch_id && batch.treatment_program) {
                // Calculate schedule
                {
                    if (program) {
                        const batchLoc = ctx.getBatchLocation(batch.batch_id);
                        
                        // PLC: FOR-loop find transporter
                        let transporter = state.transporters[0];
                        if (isOnTransporter) {
                            for (let fi = 0; fi < state.transporterCount; fi++) {
                                if (state.transporters[fi].id === batchLoc) { transporter = state.transporters[fi]; break; }
                            }
                        }
                        // PLC: FOR-loop find
                        let tState = null;
                        for (let ti = 0; ti < state.transporterStateCount; ti++) {
                            if (state.transporterStates[ti].id === transporter.id) { tState = state.transporterStates[ti]; break; }
                        }

                        // ── A4: Collect occupied stations (PLC: ARRAY[0..MAX_STATIONS-1] OF BOOL) ──
                        // Station numbers (e.g. 101–118) are used directly as array indices.
                        // MAX_STATIONS = 200 covers all valid station numbers.
                        const occupiedStationFlags = new Array(MAX_STATIONS);
                        for (let si = 0; si < MAX_STATIONS; si++) occupiedStationFlags[si] = false;
                        const occupiedStationList = new Array(MAX_STATIONS);
                        let occupiedStationCount = 0;
                        const ctxUnits = ctx.units || [];
                        const ctxUnitCount = ctxUnits.length;
                        for (let ui = 0; ui < ctxUnitCount; ui++) {
                            const u = ctxUnits[ui];
                            if (u.batch_id != null && u.batch_id !== batch.batch_id && u.location > 0) {
                                const loc = u.location;
                                if (loc < MAX_STATIONS && !occupiedStationFlags[loc]) {
                                    occupiedStationFlags[loc] = true;
                                    occupiedStationList[occupiedStationCount++] = loc;
                                }
                            }
                        }
                        // Wrap as Set-like for scheduler API compatibility (.has() and [...spread])
                        const occupiedStations = {
                            has: function(loc) { return loc >= 0 && loc < MAX_STATIONS && occupiedStationFlags[loc] === true; },
                            [Symbol.iterator]: function() {
                                let idx = 0;
                                return { next: function() {
                                    if (idx < occupiedStationCount) return { value: occupiedStationList[idx++], done: false };
                                    return { done: true };
                                }};
                            }
                        };
                        const stationIdleSince = ctx.stationIdleSince || new Map();

                        // Collect all other batch schedules for parallel station selection (PLC: counter-based)
                        const lineSchedules = [];
                        let lineScheduleCount = 0;
                        for (let bi = 0; bi < state.batchCount; bi++) {
                            const otherBatch = state.batches[bi];
                            if (otherBatch && otherBatch.batch_id !== batch.batch_id) {
                                const otherSchedule = _getSchedule(otherBatch.batch_id);
                                if (otherSchedule && otherSchedule.stages) {
                                    if (lineScheduleCount < MAX_LINE_SCHEDULES) {
                                        lineSchedules[lineScheduleCount++] = otherSchedule;
                                    }
                                }
                            }
                        }

                        const scheduleResult = scheduler.calculateBatchSchedule(
                            batch,
                            program,
                            state.stations,
                            transporter,
                            ctx.currentTimeSec || 0,
                            batch.isDelayed,
                            tState,
                            { 
                                movementTimes: ctx.movementTimes || null,
                                stationIdleSince: stationIdleSince,
                                occupiedStations: occupiedStations,
                                lineSchedules: lineSchedules,
                                units: ctx.units || []
                            }
                        );
                        
                        log('Batch ' + (batchIndex + 1) + ' NEW schedule created');

                        if (batch.batch_id != null && scheduleResult) {
                            // Store batchStage in schedule (UI checks stage === 90 for waiting)
                            scheduleResult.batchStage = batch.stage;
                            _setSchedule(batch.batch_id, scheduleResult);
                            _setProgram(batch.batch_id, program);
                            // CSV writing happens in the SAVE phase
                        }
                    } else {
                        // No program available for this batch
                    }
                }
            } else {
                // Batch missing id or program
            }
            
            // Next batch or SAVE
            if (batchIndex + 1 < state.batchCount) {
                nextPhase = p + 1;
            } else {
                nextPhase = PHASE.SCHEDULE_SAVE;
            }
            }  // End of else (not isStage90)
        } else {
            nextPhase = PHASE.SCHEDULE_SAVE;
        }
    }
    
    else if (p === PHASE.SCHEDULE_SAVE) {
        // PHASE 1900: SCHEDULE complete (saves deferred to SAVE phase)
        nextPhase = PHASE.TASKS_START;
    }
    
    else if (p === PHASE.TASKS_START) {
        // PHASE 2000: TASKS start
        state.tasks = [];
        state.taskCount = 0;
        if (state.batchCount === 0) {
            log('No batches, skip to sort');
            nextPhase = PHASE.TASKS_SORT;
        } else {
            nextPhase = PHASE.TASKS_START + 1; // 2001
        }
    }
    
    else if (p >= PHASE.TASKS_START + 1 && p <= PHASE.TASKS_SORT - 1) {
        // PHASE 2001-2198: TASKS — create task list for batch N
        // KRIITTINEN: Käy läpi KAIKKI batches (mukaan lukien stage 90),
        // koska stage 90 -erät ovat taulukossa ja "syövät" indeksejä.
        // batchCount laskee vain linjalla olevat, mutta taulukko sisältää kaikki.
        const totalBatchCount = state.batches.length;
        const batchIndex = p - PHASE.TASKS_START - 1;
        
        if (batchIndex < totalBatchCount) {
            const batch = state.batches[batchIndex];
            const schedule = (batch != null && batch.batch_id != null)
                ? _getSchedule(batch.batch_id)
                : null;

            // Do NOT create tasks for stage 90 (waiting) batches.
            // They are shown in the schedule but not given departure permission.
            const isWaiting = batch && batch.stage === 90;
            const hasStages = schedule != null && schedule.stages != null && schedule.stages.length > 0;
            
            if (!isWaiting && hasStages) {
                const batchTasks = scheduler.createTaskListFromSchedule(schedule, batch, state.transporters);
                const batchTaskCount = batchTasks.length;
                // PLC: counter-based append instead of .push(...)
                for (let ti = 0; ti < batchTaskCount; ti++) {
                    if (state.taskCount < MAX_TASKS) {
                        state.tasks[state.taskCount++] = batchTasks[ti];
                    }
                }
                state.tasks.length = state.taskCount;
                log('Batch ' + (batchIndex + 1) + ': ' + batchTaskCount + ' tasks');
            } else if (isWaiting && hasStages) {
                log('Batch ' + (batchIndex + 1) + ': stage=90 (waiting) - no tasks created');
            }
            
            if (batchIndex + 1 < totalBatchCount) {
                nextPhase = p + 1;
            } else {
                nextPhase = PHASE.TASKS_SORT;
            }
        } else {
            nextPhase = PHASE.TASKS_SORT;
        }
    }
    
    else if (p === PHASE.TASKS_SORT) {
        // PHASE 2200: Sort tasks. Emergency priority: batches over max_time
        // are moved to the front (higher priority). Among emergencies,
        // the highest overtime ratio comes first.
        // C2+C3: getOvertimeRatio ja sort-callback irrotettu itsenäisiksi funktioiksi.
        if (state.taskCount > 0) {
            const currentTimeSec = ctx.currentTimeSec || 0;

            // C3: Sort context struct — replaces closure-captured variables
            const sortContext = {
                batches: state.batches,
                batchCount: state.batchCount,
                currentTimeSec: currentTimeSec,
                getBatchLocation: ctx.getBatchLocation
            };

            // PLC: insertion sort with named comparator + context (no closure)
            _insertionSort(state.tasks, state.taskCount, _compareTasksPriority, sortContext);

            // Log emergency tasks (PLC: FOR-loop count instead of .filter)
            let emergencyCount = 0;
            for (let ei = 0; ei < state.taskCount; ei++) {
                if (_getOvertimeRatio(state.tasks[ei], state.batches, state.batchCount, currentTimeSec, ctx.getBatchLocation) > 1.0) emergencyCount++;
            }
            if (emergencyCount > 0) {
                log('EMERGENCY: ' + emergencyCount + ' tasks over max_time, prioritized first');
            }
        }
        nextPhase = PHASE.TASKS_SWAP;
    }
    
    else if (p === PHASE.TASKS_SWAP) {
        // PHASE 2201: Swap same-station tasks (lift before sink)
        if (state.taskCount > 0) {
            const swapResult = scheduler.swapSameStationTasks(state.tasks);
            if (swapResult.swapCount > 0) {
                log('Swapped ' + swapResult.swapCount + ' same-station tasks');
            }
        }
        nextPhase = PHASE.TASKS_ANALYZE;
    }
    
    else if (p === PHASE.TASKS_ANALYZE) {
        // PHASE 2202: Analyze task conflicts.
        // analyzeTaskConflicts() stops at the first conflict found.
        // If conflict → RESOLVE → SAVE → RESTART → new ANALYZE.
        // If none → NO_TREATMENT → SAVE (list is stable).
        
        if (state.taskCount > 0) {
            // Analyze current state — conflicts computed from task times
            const analysis = scheduler.analyzeTaskConflicts(
                state.tasks,
                state.batches,
                state.transporters,
                state.stations,
                { movementTimes: ctx.movementTimes || null, transporterStates: state.transporterStates || [] }
            );
            
            // Save analysis to state
            state.taskAnalysis = analysis;
            const { hasConflict, conflict } = analysis;

            // No conflicts → check no-treatment tasks
            if (!hasConflict) {
                state.conflictResolved = true;
                _clearLockedStages();
                nextPhase = PHASE.TASKS_NO_TREATMENT;
            }
            // Conflict found → RESOLVE
            else {
                log('Conflict: ' + conflict.conflictType + ' ' + conflict.nextTaskKey + ', deficit=' + conflict.deficit.toFixed(1) + 's');
                nextPhase = PHASE.TASKS_RESOLVE;
            }
        } else {
            // Ei taskeja → ei konflikteja → check no-treatment tasks
            state.taskAnalysis = null;
            state.conflictIteration = 0;
            state.conflictResolved = true;
            nextPhase = PHASE.TASKS_NO_TREATMENT;
        }
    }
    
    else if (p === PHASE.TASKS_RESOLVE) {
        // ───────────────────────────────────────────────────────────
        // PHASE 2203: Conflict resolution (v3.4 algorithm)
        //
        // Uses resolveConflict() with delay-first strategy,
        // lockedStages for oscillation prevention.
        // One conflict per cycle → SAVE → RESTART → INIT
        // ───────────────────────────────────────────────────────────
        if (state.taskAnalysis && state.taskCount > 0) {
            const { hasConflict, conflict, checkedTasks } = state.taskAnalysis;
            
            if (!hasConflict || !conflict) {
                // No conflict — should not reach here, but safe fallback
                state.conflictIteration = 0;
                _clearLockedStages();
                nextPhase = PHASE.TASKS_SAVE;
            } else {
                // Use resolveConflict algorithm (A3: convert array → hash map for API)
                const result = scheduler.resolveConflict(
                    conflict,
                    checkedTasks,
                    state.tasks,
                    state.batches,
                    {
                        lockedStages: _lockedStagesToHashMap(),
                        currentTimeSec: ctx.currentTimeSec
                    }
                );
                
                if (!result.solved) {
                    // Conflict could not be fully resolved
                    const missingStr = (result.missing != null) ? result.missing.toFixed(1) : '?';
                    log('ALERT - ' + result.reason + ', missing ' + missingStr + 's');
                    // Apply partial solution; keep lockedStages for oscillation prevention
                } else {
                    log('Resolve OK: ' + result.reason);
                }
                
                // Save locks for oscillation prevention (A3: store as INT-packed array)
                const actionCount = result.actions ? result.actions.length : 0;
                for (let ai = 0; ai < actionCount; ai++) {
                    const action = result.actions[ai];
                    if (action.lockKey && action.lockDirection) {
                        _setLockedStage(action.lockKey, action.lockDirection);
                    }
                }
                
                // Cumulative tracking (PLC: counter-based append)
                if (!state.resolveHistory) state.resolveHistory = [];
                if (!state.resolveHistoryCount) state.resolveHistoryCount = 0;
                for (let ai = 0; ai < actionCount; ai++) {
                    const action = result.actions[ai];
                    if (state.resolveHistoryCount < MAX_RESOLVE) {
                        state.resolveHistory[state.resolveHistoryCount++] = {
                            iteration: state.conflictIteration,
                            action: action.action,
                            batch_id: action.batch_id,
                            stage: action.stage,
                            amount: action.amount
                        };
                        state.resolveHistory.length = state.resolveHistoryCount;
                    }
                }
                
                // Summary logging
                if (result.totalDelay > 0) {
                    log('Delay: +' + result.totalDelay.toFixed(1) + 's');
                }
                if (result.totalEarlier > 0) {
                    log('Advance: -' + result.totalEarlier.toFixed(1) + 's');
                }
                
                // ONE CONFLICT PER CYCLE — save and restart
                // Lista ei ole vielä stabiili → SAVE → INIT → uusi ANALYZE
                // NO_TREATMENT ajetaan vasta kun ANALYZE ei löydä konflikteja
                state.conflictIteration = (state.conflictIteration || 0) + 1;
                nextPhase = PHASE.TASKS_SAVE;
            }
        } else {
            nextPhase = PHASE.TASKS_SAVE;
        }
    }
    
    else if (p === PHASE.TASKS_NO_TREATMENT) {
        // ───────────────────────────────────────────────────────────
        // PHASE 2204: No-treatment tasks (Unit target based)
        //
        // Tehtävälista on nyt stabiili (ei konflikteja). Käydään läpi
        // Unitit joilla on target, ja luodaan siirtotehtävä jos se
        // mahtuu nostimen idle-slottiin.
        // ───────────────────────────────────────────────────────────
        const noTreatmentConfig = ctx.noTreatmentTasks || null;
        const units = ctx.units || [];
        const unitCount = units.length;
        const transporterStates = ctx.transporterStates || [];
        const transporterStateCountLocal = transporterStates.length;
        const currentTimeSec = ctx.currentTimeSec || 0;
        const movementTimes = ctx.movementTimes || null;
        const MARGIN_S = 5;

        // ── TO_AVOID tunnistus siirretty server.js → updateUnitTargets() ──
        // Säännöt 4 ja 5 käsittelevät to_avoid -asetuksen keskitetysti.

        if (noTreatmentConfig && noTreatmentConfig.targets) {
            for (let ui = 0; ui < unitCount; ui++) {
                const unit = units[ui];
                if (!unit.target || unit.target === 'none' || unit.target === 'empty') continue;
                if (unit.location == null || unit.location < 100) continue;

                const targetDef = noTreatmentConfig.targets[unit.target];
                if (!targetDef) continue;

                const covering = _findCoveringTransporter(unit, targetDef);
                if (!covering) continue;

                const { transporter: coveringTransporter, config: coveringTransporterCfg } = covering;
                const tId = coveringTransporter.id;
                // PLC: FOR-loop find instead of .find()
                let tState = null;
                for (let tsi = 0; tsi < transporterStateCountLocal; tsi++) {
                    if (transporterStates[tsi].id === tId) { tState = transporterStates[tsi]; break; }
                }
                if (!tState) { log('NO-TREATMENT: U' + unit.unit_id + ' T' + tId + ' state not found'); continue; }
                if (!tState.state || tState.state.status !== 3 || tState.state.phase !== 0) continue;

                {
                    const unitStation = unit.location;

                    // 1. Kohteen valinta
                    const dest = _findSinkStation(unitStation, coveringTransporterCfg, transporterStates, transporterStateCountLocal);
                    if (!dest) continue;
                    const { sinkStationId, isPrimaryDestination } = dest;

                    // 2. Ajoituksen laskenta
                    const timing = _calculateTiming(tId, unitStation, sinkStationId, coveringTransporter, tState, currentTimeSec, movementTimes, MARGIN_S);
                    if (!timing) continue;
                    const { travelToPickup, taskDuration, totalTime, idleRemaining, currentSlot, pickupStation, sinkStation } = timing;

                    // 3. Flex-fit (jos ei mahdu suoraan)
                    if (totalTime > idleRemaining) {
                        const flexOk = _tryFlexFit(unit, tId, unitStation, sinkStationId, totalTime, idleRemaining, currentSlot);
                        if (!flexOk) continue;
                    }

                    // 4. Overlap-tarkistus
                    if (_hasOverlapConflict(tId, coveringTransporter, sinkStation, currentTimeSec + travelToPickup, taskDuration, transporterStates, transporterStateCountLocal)) {
                        continue;
                    }

                    // 5. Luo tehtävä (PLC: counter-based append)
                    const taskStartTime = currentTimeSec + travelToPickup;
                    if (state.taskCount < MAX_TASKS) {
                        state.tasks[state.taskCount++] = {
                            batch_id: null,
                            stage: null,
                            transporter_id: tId,
                            lift_station_id: unitStation,
                            sink_station_id: sinkStationId,
                            task_start_time: taskStartTime,
                            task_finished_time: taskStartTime + taskDuration,
                            is_no_treatment: true,
                            is_primary_destination: isPrimaryDestination,
                            unit_id: unit.unit_id,
                            unit_target: unit.target,
                            min_time_s: 0,
                            max_time_s: 0,
                            calc_time_s: 0,
                        };
                        state.tasks.length = state.taskCount;
                    }
                    log('NO-TREATMENT: U' + unit.unit_id + ' T' + tId + ' ' + unitStation + '→' + sinkStationId + ' CREATED (' + totalTime.toFixed(1) + 's/' + idleRemaining.toFixed(1) + 's)');
                    break; // Yksi tehtävä per nostin per sykli
                }
            }
        }

        nextPhase = PHASE.TASKS_SAVE;
    }
    
    else if (p === PHASE.TASKS_SAVE) {
        // PHASE 2900: Collect resolve decisions into candidateStretches,
        // then create departure sandbox for departureScheduler.
        // taskCount is already maintained by counter-based operations

        // Collect delays/advances from resolveHistory for the SAVE phase
        state.candidateStretches = state.candidateStretches || [];
        if (!state.candidateStretchCount) state.candidateStretchCount = 0;

        if (state.resolveHistory && state.resolveHistoryCount > 0) {
            for (let ri = 0; ri < state.resolveHistoryCount; ri++) {
                const decision = state.resolveHistory[ri];
                const stage = decision.targetStage || decision.stage;

                // DELAY: increase calc_time (positive delayS)
                if ((decision.action === 'DELAY' || decision.action === 'DELAY_SPLIT') && 
                    decision.batch_id && decision.amount > 0) {
                    if (state.candidateStretchCount < MAX_STRETCHES) {
                        state.candidateStretches[state.candidateStretchCount++] = {
                            batchId: decision.batch_id, stage: stage, delayS: decision.amount
                        };
                    }
                }

                // ADVANCE: decrease calc_time (negative delayS)
                if (decision.action === 'ADVANCE' && 
                    decision.batch_id && decision.amount > 0) {
                    if (state.candidateStretchCount < MAX_STRETCHES) {
                        state.candidateStretches[state.candidateStretchCount++] = {
                            batchId: decision.batch_id, stage: stage, delayS: -decision.amount
                        };
                    }
                }

                // COMBINED: both advance and delay when one flex alone isn't enough
                if (decision.action === 'COMBINED') {
                    if (decision.earlierAmount > 0 && decision.prevBatch && decision.prevStage !== undefined) {
                        if (state.candidateStretchCount < MAX_STRETCHES) {
                            state.candidateStretches[state.candidateStretchCount++] = {
                                batchId: decision.prevBatch, stage: decision.prevStage, delayS: -decision.earlierAmount
                            };
                        }
                    }
                    if (decision.delayAmount > 0 && decision.nextBatch && decision.nextStage !== undefined) {
                        if (state.candidateStretchCount < MAX_STRETCHES) {
                            state.candidateStretches[state.candidateStretchCount++] = {
                                batchId: decision.nextBatch, stage: decision.nextStage, delayS: decision.delayAmount
                            };
                        }
                    }
                }

                // ALERT: partial solution — apply whatever was possible
                if (decision.action === 'ALERT') {
                    if (decision.usedEarlier > 0 && decision.prevTask && decision.prevTask.batch_id && decision.prevTask.stage) {
                        if (state.candidateStretchCount < MAX_STRETCHES) {
                            state.candidateStretches[state.candidateStretchCount++] = {
                                batchId: decision.prevTask.batch_id, stage: decision.prevTask.stage, delayS: -decision.usedEarlier
                            };
                        }
                    }
                    if (decision.usedDelay > 0 && decision.nextTask && decision.nextTask.batch_id && decision.nextTask.stage) {
                        if (state.candidateStretchCount < MAX_STRETCHES) {
                            state.candidateStretches[state.candidateStretchCount++] = {
                                batchId: decision.nextTask.batch_id, stage: decision.nextTask.stage, delayS: decision.usedDelay
                            };
                        }
                    }
                }
            }
            state.candidateStretches.length = state.candidateStretchCount;
        }

        // Clear resolveHistory for next cycle
        state.resolveHistory = [];
        state.resolveHistoryCount = 0;
        
        // Create departureSandbox — PLC: explicit field copy instead of JSON deep copy.
        // DepartureScheduler uses this to trial-add waiting batches without affecting
        // the official state. If departure is granted, sandbox replaces the state.

        // Clear old sandbox references BEFORE copying to prevent memory leaks
        state.departureSandbox = null;
        state.sandboxSnapshot = null;

        state.departureSandbox = _copySandbox(state);
        state.departureSandbox.created_s = ctx.currentTimeSec || 0;

        // Remove stage 90 (waiting) batch tasks from sandbox.
        // PLC: FOR-loop filter instead of Set + .filter()
        if (state.departureSandbox.tasks) {
            const sandboxTaskTotal = state.departureSandbox.taskCount || state.departureSandbox.tasks.length;
            let writeIdx = 0;
            for (let ri = 0; ri < sandboxTaskTotal; ri++) {
                const t = state.departureSandbox.tasks[ri];
                // Check if this task's batch is waiting (stage 90)
                let isWaitingBatch = false;
                for (let bi = 0; bi < state.batchCount; bi++) {
                    const b = state.batches[bi];
                    if (b && b.stage === 90 && b.batch_id === t.batch_id) { isWaitingBatch = true; break; }
                }
                if (!isWaitingBatch) {
                    state.departureSandbox.tasks[writeIdx++] = t;
                }
            }
            state.departureSandbox.tasks.length = writeIdx;
        }

        nextPhase = PHASE.READY;
    }

    else if (p === PHASE.READY) {
        // PHASE 10000: Cycle complete
        nextPhase = PHASE.SAVE_STRETCHES;
    }

    else if (p === PHASE.SAVE_STRETCHES) {
        // ── SUB-PHASE 10001: Apply candidateStretches to programsByBatchId ──
        if (state.candidateStretches && state.candidateStretchCount > 0) {
            const batchCalcUpdates = [];
            let batchCalcUpdateCount = 0;
            
            for (let si = 0; si < state.candidateStretchCount; si++) {
                const stretch = state.candidateStretches[si];
                const { batchId, stage, delayS } = stretch;
                if (!batchId || !stage || delayS === 0 || delayS === undefined) continue;
                
                const program = _getProgram(batchId);
                if (!program || !Array.isArray(program)) continue;
                
                const stageIdx = stage - 1;
                if (stageIdx < 0 || stageIdx >= program.length) continue;
                
                const stageData = program[stageIdx];
                if (!stageData) continue;
                
                const oldCalcS = scheduler.parseTimeToSeconds(stageData.calc_time) || 
                                 scheduler.parseTimeToSeconds(stageData.min_time) || 0;
                const minS = scheduler.parseTimeToSeconds(stageData.min_time) || 0;
                const maxS = scheduler.parseTimeToSeconds(stageData.max_time) || oldCalcS;
                const newCalcS = Math.min(maxS, Math.max(minS, oldCalcS + delayS));
                
                stageData.calc_time = scheduler.formatSecondsToTime(newCalcS);
                log('Applied stretch: B' + batchId + 's' + stage + ' calc_time ' + oldCalcS.toFixed(1) + 's → ' + newCalcS.toFixed(1) + 's');

                // PLC: FOR-loop find batch instead of .find()
                let batch = null;
                for (let bi = 0; bi < state.batchCount; bi++) {
                    if (state.batches[bi].batch_id === batchId) { batch = state.batches[bi]; break; }
                }
                if (batch && batch.stage === stage && batch.stage >= 1 && batch.stage < 90) {
                    if (batchCalcUpdateCount < MAX_BATCH_CALC_UPDATES) {
                        batchCalcUpdates[batchCalcUpdateCount++] = { batchId, stage, calcTimeS: newCalcS };
                    }
                }
            }

            if (batchCalcUpdateCount > 0 && ctx.updateBatchCalcTimes) {
                batchCalcUpdates.length = batchCalcUpdateCount;
                await ctx.updateBatchCalcTimes(batchCalcUpdates);
            }

            state.candidateStretches = [];
            state.candidateStretchCount = 0;
        }
        nextPhase = PHASE.SAVE_SCHEDULES;
    }

    else if (p === PHASE.SAVE_SCHEDULES) {
        // ── SUB-PHASE 10002: Save schedules.json (A1: convert array → hash map for API) ──
        if (ctx.saveSchedules && state.scheduleCount > 0) {
            const scheduleTime = ctx.currentTimeSec || 0;
            const ok = await ctx.saveSchedules(_schedulesToHashMap(), scheduleTime);
            if (ok !== false) {
                const schedTimeStr = (scheduleTime != null) ? scheduleTime.toFixed(1) : '?';
                log('Schedules saved (calculatedAt: ' + schedTimeStr + 's)');
            } else {
                state.lastError = 'SAVE_SCHEDULES_FAIL';
                log('Schedules save error');
            }
        }
        nextPhase = PHASE.SAVE_TASKS;
    }

    else if (p === PHASE.SAVE_TASKS) {
        // ── SUB-PHASE 10003: Save transporter_tasks.json ──
        if (ctx.saveTransporterTasks && state.tasks && state.taskCount > 0) {
            const ok = await ctx.saveTransporterTasks(state.tasks);
            if (ok !== false) {
                log('Tasks saved: ' + state.taskCount);
            } else {
                state.lastError = 'SAVE_TASKS_FAIL';
                log('Tasks save error');
            }
        }
        nextPhase = PHASE.SAVE_ANALYSIS;
    }

    else if (p === PHASE.SAVE_ANALYSIS) {
        // ── SUB-PHASE 10004: Save task_analysis.json ──
        if (ctx.saveRuntimeFile && state.taskAnalysis) {
            // PLC: FOR-loop filter instead of .filter()
            const allConflicts = state.taskAnalysis.conflicts || [];
            const allConflictCount = allConflicts.length;
            const actualConflicts = [];
            let actualConflictCount = 0;
            for (let ci = 0; ci < allConflictCount; ci++) {
                const timing = allConflicts[ci].timing;
                if (timing && timing.is_conflict) {
                    if (actualConflictCount < MAX_ACTUAL_CONFLICTS) {
                        actualConflicts[actualConflictCount++] = allConflicts[ci];
                    }
                }
            }
            actualConflicts.length = actualConflictCount;
            ctx.saveRuntimeFile('task_analysis.json', JSON.stringify({
                timestamp: _getTimestampString(),
                currentTime_s: ctx.currentTimeSec || 0,
                summary: state.taskAnalysis.summary,
                conflicts: actualConflicts
            }, null, 2));
        }
        nextPhase = PHASE.SAVE_DEPARTURE;
    }

    else if (p === PHASE.SAVE_DEPARTURE) {
        // ── SUB-PHASE 10005: Merge DEPARTURE pending data ──
        // DEPARTURE builds hash maps; convert to internal arrays (A1/A2).
        // ── A5: departurePendingWriteData uses .valid flag (PLC: fixed struct, no null) ──
        if (ctx.departurePendingWriteData && ctx.departurePendingWriteData.valid) {
            const depPrograms = ctx.departurePendingWriteData.programsByBatchId;
            const depProgKeys = Object.keys(depPrograms);
            const depProgCount = depProgKeys.length;
            for (let di = 0; di < depProgCount; di++) {
                const batchIdStr = depProgKeys[di];
                _setProgram(parseInt(batchIdStr, 10), depPrograms[batchIdStr]);
            }
            log('Merged DEPARTURE programs for ' + depProgCount + ' batches');
            
            if (ctx.saveSchedules && ctx.departurePendingWriteData.schedulesByBatchId) {
                const depSchedules = ctx.departurePendingWriteData.schedulesByBatchId;
                const depSchedKeys = Object.keys(depSchedules);
                const depSchedCount = depSchedKeys.length;
                for (let di = 0; di < depSchedCount; di++) {
                    const batchIdStr = depSchedKeys[di];
                    _setSchedule(parseInt(batchIdStr, 10), depSchedules[batchIdStr]);
                }
                const ok = await ctx.saveSchedules(_schedulesToHashMap(), ctx.departurePendingWriteData.currentTimeSec);
                if (ok !== false) {
                    log('Merged DEPARTURE schedules saved');
                } else {
                    state.lastError = 'SAVE_DEP_SCHEDULES_FAIL';
                    log('DEPARTURE schedules save error');
                }
            }
            
            if (ctx.updateBatchCalcTimes && ctx.departurePendingWriteData.batchCalcUpdates) {
                const updates = ctx.departurePendingWriteData.batchCalcUpdates;
                const updateCount = updates.length;
                if (updateCount > 0) {
                    const ok = await ctx.updateBatchCalcTimes(updates);
                    if (ok !== false) {
                        log('Applied ' + updateCount + ' DEPARTURE batch calc_time updates');
                    } else {
                        state.lastError = 'SAVE_DEP_CALC_FAIL';
                        log('DEPARTURE batch calc update error');
                    }
                }
            }
            
            state._departureSaveConfirmed = true;
        } else {
            state._departureSaveConfirmed = false;
        }
        nextPhase = PHASE.SAVE_PROGRAMS;
    }

    else if (p === PHASE.SAVE_PROGRAMS) {
        // ── SUB-PHASE 10006: Write treatment programs (A2: convert array → hash map for API) ──
        if (ctx.writeTreatmentPrograms) {
            const ok = await ctx.writeTreatmentPrograms(_programsToHashMap());
            if (ok !== false) {
                log('Treatment programs written');
            } else {
                state.lastError = 'SAVE_PROGRAMS_FAIL';
                log('Program write error');
            }
        }
        // Initialize CSV batch index for next sub-phase
        state.saveCsvIndex = 0;
        nextPhase = PHASE.SAVE_CSV;
    }

    else if (p === PHASE.SAVE_CSV) {
        // ── SUB-PHASE 10007: Write CSVs — one batch per tick ──
        // Scan from saveCsvIndex for next stage-0 batch
        let found = false;
        const totalBatchesForCsv = state.batches.length;
        while (state.saveCsvIndex < totalBatchesForCsv) {
            const batch = state.batches[state.saveCsvIndex];
            state.saveCsvIndex++;
            
            if (batch.stage !== 0 || !ctx.writeBatchScheduleCsv) continue;
            found = true;
            
            if (batch.justActivated) {
                delete batch.justActivated;
                
                if (ctx.setBatchStage) {
                    const ok = await ctx.setBatchStage(batch.batch_id, batch.stage, {
                        start_time: batch.start_time,
                        calc_time_s: batch.calc_time_s,
                        min_time_s: batch.min_time_s,
                        max_time_s: batch.max_time_s,
                        justActivated: false
                    });
                    if (ok !== false) {
                        const calcStr = (batch.calc_time_s != null) ? batch.calc_time_s.toFixed(1) : '?';
                        const minStr = (batch.min_time_s != null) ? batch.min_time_s.toFixed(1) : '?';
                        const maxStr = (batch.max_time_s != null) ? batch.max_time_s.toFixed(1) : '?';
                        log('B' + batch.batch_id + ': Persisted activated batch times (calc=' + calcStr + 's, min=' + minStr + 's, max=' + maxStr + 's)');
                    } else {
                        state.lastError = 'SAVE_CSV_STAGE_FAIL';
                        log('B' + batch.batch_id + ': Activated batch save error');
                    }
                }
                
                const scheduleResult = _getSchedule(batch.batch_id);
                if (scheduleResult && scheduleResult.stages && scheduleResult.stages.length > 0) {
                    const written = await ctx.writeBatchScheduleCsv({ 
                        batchId: batch.batch_id, 
                        scheduleResult, 
                        overwrite: true 
                    });
                    
                    if (written) {
                        log('B' + batch.batch_id + ': Wrote calculated CSV (activated, ' + scheduleResult.stages.length + ' stages)');
                        
                        const stage0 = scheduleResult.stages[0];
                        if (ctx.updateBatchActualCsv && stage0) {
                            const entryTimeSec = (batch.start_time || 0) / 1000;
                            await ctx.updateBatchActualCsv({
                                batchId: batch.batch_id,
                                station: stage0.station,
                                entryTimeSec
                            });
                        }
                    }
                }
                break; // One batch per tick
            }
            
            const scheduleResult = _getSchedule(batch.batch_id);
            if (scheduleResult && scheduleResult.stages && scheduleResult.stages.length > 0) {
                const stage0 = scheduleResult.stages[0];
                const written = await ctx.writeBatchScheduleCsv({ 
                    batchId: batch.batch_id, 
                    scheduleResult, 
                    overwrite: false 
                });
                
                if (written) {
                    log('B' + batch.batch_id + ': Wrote calculated CSV (' + scheduleResult.stages.length + ' stages)');
                    
                    if (ctx.updateBatchActualCsv && stage0) {
                        const actualEntryTimeSec = (batch.start_time || 0) / 1000;
                        await ctx.updateBatchActualCsv({
                            batchId: batch.batch_id,
                            station: stage0.station,
                            entryTimeSec: actualEntryTimeSec
                        });
                    }
                }
            }
            break; // One batch per tick
        }
        
        // If more batches remain, stay in SAVE_CSV; otherwise advance
        if (state.saveCsvIndex < totalBatchesForCsv && found) {
            nextPhase = PHASE.SAVE_CSV; // Stay — more batches to check
        } else {
            nextPhase = PHASE.SAVE_DONE;
        }
    }

    else if (p === PHASE.SAVE_DONE) {
        // ── SUB-PHASE 10099: SAVE complete ──
        nextPhase = PHASE.END_DELAY_START;
    }
    
    else if (p >= PHASE.END_DELAY_START && p <= PHASE.END_DELAY_END) {
        // ───────────────────────────────────────────────────────────
        // PHASE 10100-10109: END_DELAY (idle ticks)
        // HANDSHAKE: If departure activated a batch, skip delay for fast restart
        // ───────────────────────────────────────────────────────────
        if (ctx.departureActivated) {
            nextPhase = PHASE.RESTART;
        } else {
            nextPhase = p + 1;
        }
    }
    
    else if (p === PHASE.RESTART) {
        // ───────────────────────────────────────────────────────────
        // PHASE 10110: RESTART — begin new cycle
        // ───────────────────────────────────────────────────────────
        state.lastCycleTimeMs = _getSystemTimeMs() - state.cycleStartTime;
        state.totalCycles++;
        state.lastCycleTicks = state.cycleTickCount;
        state.lastCycleSimTimeMs = Math.round(state.lastCycleTicks * (_isFinite(state.cycleTickPeriodMs) ? state.cycleTickPeriodMs : 0));
        
        // Track longest cycle
        if (state.lastCycleTimeMs > state.longestCycleTimeMs) {
            state.longestCycleTimeMs = state.lastCycleTimeMs;
        }
        if (state.lastCycleTicks > state.longestCycleTicks) {
            state.longestCycleTicks = state.lastCycleTicks;
        }
        
        state.cycleHistoryCount = _ringBufferWrite(state.cycleHistory, state.cycleHistoryCount, MAX_CYCLE_HISTORY, state.lastCycleTimeMs);
        
        state.cycleTickHistoryCount = _ringBufferWrite(state.cycleTickHistory, state.cycleTickHistoryCount, MAX_CYCLE_HISTORY, state.lastCycleTicks);
        
        state.cycleSimTimeHistoryCount = _ringBufferWrite(state.cycleSimTimeHistory, state.cycleSimTimeHistoryCount, MAX_CYCLE_HISTORY, state.lastCycleSimTimeMs);
        
        log('Cycle complete: ' + state.lastCycleTimeMs + 'ms, tasks: ' + state.taskCount);

        if (context && typeof context.speedMultiplier !== 'undefined' && Number(context.speedMultiplier) === 0) {
            pauseRequested = true;
        }

        nextPhase = PHASE.INIT;
    }
    
    else {
        // ───────────────────────────────────────────────────────────
        // Unknown phase → reset to INIT
        // ───────────────────────────────────────────────────────────
        log('Unknown phase ' + p + ', reset to INIT');
        nextPhase = PHASE.INIT;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // PHASE ASSIGNMENT — once, at the end of tick
    // ═══════════════════════════════════════════════════════════════
    state.phase = nextPhase;
    
    const result = getStatus();
    if (pauseRequested) {
        result.pauseRequested = true;
    }
    // HANDSHAKE: Acknowledge departure activation after INIT reads fresh data
    if (ctx.departureActivated && nextPhase === PHASE.SCHEDULE_START) {
        result.departureAcknowledged = true;
    }
    // SYNKRONOINTI: Tell server.js that DEPARTURE's pending data was saved
    if (state._departureSaveConfirmed) {
        result.departureSaveConfirmed = true;
        state._departureSaveConfirmed = false;
    }
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════════
// PUBLIC API
// ═══════════════════════════════════════════════════════════════════════════════

function getPhase() {
    return state.phase;
}

/**
 * getStatus() — Kevyt: vain skalaariarvot ja viittaukset historiataulukoihin.
 * Kutsutaan joka tick + API-kutsuissa. Ei deep copya.
 */
function getStatus() {
    return {
        phase: state.phase,
        phaseName: getPhaseName(state.phase),
        batchCount: state.batchCount,
        taskCount: state.taskCount,
        totalCycles: state.totalCycles,
        lastCycleTimeMs: state.lastCycleTimeMs,
        longestCycleTimeMs: state.longestCycleTimeMs,
        cycleHistory: state.cycleHistory,
        lastCycleTicks: state.lastCycleTicks,
        longestCycleTicks: state.longestCycleTicks,
        lastCycleSimTimeMs: state.lastCycleSimTimeMs,
        cycleTickPeriodMs: state.cycleTickPeriodMs,
        cycleTickHistory: state.cycleTickHistory,
        cycleSimTimeHistory: state.cycleSimTimeHistory,
        avgDepartureIntervalSec: state.avgDepartureIntervalSec,
        departureCount: state.departureTimes.length,
        conflictResolved: state.conflictResolved || false
    };
}

/**
 * getData() — B3: Kenttäkohtainen kopio ohjelmista departurelle.
 * Departure muokkaa ohjelmiaan itsenäisesti (calc_time jne.) joten
 * palautetaan KOPIO, ei viittausta tasks-tilakoneen dataan.
 * PLC: departure_programs := tasks_programs kenttä kerrallaan.
 */
function getData() {
    const programsByBatchId = {};
    for (let i = 0; i < state.programCount; i++) {
        const entry = state.programs[i];
        const srcProg = entry.data;
        const copiedProgram = [];
        if (srcProg) {
            const progLen = srcProg.length;
            for (let pi = 0; pi < progLen; pi++) {
                copiedProgram[pi] = _copyProgramStage(srcProg[pi]);
            }
        }
        programsByBatchId[String(entry.batchId)] = copiedProgram;
    }
    return { programsByBatchId };
}

function getPhaseName(p) {
    if (p === PHASE.STOPPED) return 'STOPPED';
    if (p === PHASE.INIT) return 'INIT';
    if (p === PHASE.INIT_PROGRAMS) return 'INIT_PROGRAMS';
    if (p === PHASE.INIT_DONE) return 'INIT_DONE';
    if (p === PHASE.SCHEDULE_START) return 'SCHEDULE_START';
    if (p > PHASE.SCHEDULE_START && p < PHASE.SCHEDULE_SAVE) return 'SCHEDULE_BATCH_' + (p - PHASE.SCHEDULE_START);
    if (p === PHASE.SCHEDULE_SAVE) return 'SCHEDULE_SAVE';
    if (p === PHASE.TASKS_START) return 'TASKS_START';
    if (p > PHASE.TASKS_START && p < PHASE.TASKS_SORT) return 'TASKS_CREATE_' + (p - PHASE.TASKS_START);
    if (p === PHASE.TASKS_SORT) return 'TASKS_SORT';
    if (p === PHASE.TASKS_SWAP) return 'TASKS_SWAP';
    if (p === PHASE.TASKS_ANALYZE) return 'TASKS_ANALYZE';
    if (p === PHASE.TASKS_RESOLVE) return 'TASKS_RESOLVE';
    if (p === PHASE.TASKS_NO_TREATMENT) return 'TASKS_NO_TREATMENT';
    if (p === PHASE.TASKS_SAVE) return 'TASKS_SAVE';
    // END
    if (p === PHASE.READY) return 'READY';
    if (p === PHASE.SAVE_STRETCHES) return 'SAVE_STRETCHES';
    if (p === PHASE.SAVE_SCHEDULES) return 'SAVE_SCHEDULES';
    if (p === PHASE.SAVE_TASKS) return 'SAVE_TASKS';
    if (p === PHASE.SAVE_ANALYSIS) return 'SAVE_ANALYSIS';
    if (p === PHASE.SAVE_DEPARTURE) return 'SAVE_DEPARTURE';
    if (p === PHASE.SAVE_PROGRAMS) return 'SAVE_PROGRAMS';
    if (p === PHASE.SAVE_CSV) return 'SAVE_CSV';
    if (p === PHASE.SAVE_DONE) return 'SAVE_DONE';
    if (p >= PHASE.END_DELAY_START && p <= PHASE.END_DELAY_END) return 'END_DELAY_' + (p - PHASE.END_DELAY_START + 1) + '/' + END_DELAY_TICKS;
    if (p === PHASE.RESTART) return 'RESTART';
    return 'UNKNOWN';
}

function getTasks() {
    return state.tasks;
}

function canAssignTasks() {
    // Allow task assignment after SWAP phase — tasks include NO_TREATMENT tasks
    // which are created in TASKS_NO_TREATMENT (2204). Even if batch task count is 0,
    // NO_TREATMENT tasks (to_unloading, to_empty_buffer etc.) must be dispatchable.
    return state.phase > PHASE.TASKS_SWAP;
}

function start() {
    if (state.phase === PHASE.STOPPED) {
        state.phase = PHASE.INIT;
        log('State machine started');
    }
}

function reset() {
    state.phase = PHASE.STOPPED;
    state.batches = [];
    state.stations = [];
    state.transporters = [];
    state.transporterStates = [];
    state.batchCount = 0;
    state.stationCount = 0;
    state.transporterCount = 0;
    state.transporterStateCount = 0;
    state.schedules = [];
    state.scheduleCount = 0;
    state.programs = [];
    state.programCount = 0;
    state.tasks = [];
    state.taskCount = 0;
    state.totalCycles = 0;
    state.longestCycleTimeMs = 0;
    state.longestCycleTicks = 0;
    state.phaseLog = [];
    state.phaseLogCount = 0;
    state.departureTimes = [];
    state.avgDepartureIntervalSec = 0;
    state.departureSandbox = null;
    state.sandboxSnapshot = null;
    state.candidateStretches = [];
    state.candidateStretchCount = 0;
    state.conflictResolved = false;
    _clearLockedStages();
    state.resolveHistory = [];
    state.resolveHistoryCount = 0;
    state.taskAnalysis = null;
    state.initProgramIndex = 0;
    state.initBatchList = [];
    state.initBatchCount = 0;
    state.saveCsvIndex = 0;
    state.lastError = null;
    log('State machine reset');
}

// ═══════════════════════════════════════════════════════════════════════════════
// EXPORT
// ═══════════════════════════════════════════════════════════════════════════════

module.exports = {
    tick,
    getPhase,
    getStatus,
    getData,
    getTasks,
    canAssignTasks,
    start,
    reset,
    getPhaseName,
    PHASE
};

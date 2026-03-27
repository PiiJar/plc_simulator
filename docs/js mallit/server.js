const express = require('express');
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const cors = require('cors');
const { calculateWorkingAreas } = require('./transporterWorkingArea');
const scheduler = require('./transporterTaskScheduler');
const stateMachine = require('./taskScheduler');
const departureScheduler = require('./departureScheduler');

const app = express();
const PORT = process.env.PORT || 3001;

// Root directory for plant_templates (works in both dev and Docker)
// Docker: /app/plant_templates, Dev: KOKKO/plant_templates
const getPlantTemplatesDir = () => {
  if (process.env.PLANT_TEMPLATES_DIR) return process.env.PLANT_TEMPLATES_DIR;
  // Check Docker path first (/app/plant_templates)
  const dockerPath = path.join(__dirname, '..', 'plant_templates');
  if (fsSync.existsSync(dockerPath)) return dockerPath;
  // Fall back to dev path (KOKKO/plant_templates)
  return path.join(__dirname, '..', '..', 'plant_templates');
};
const PLANT_TEMPLATES_DIR = getPlantTemplatesDir();

// ─────────────────────────────────────────────────────────────────────────────
// File helpers
// ─────────────────────────────────────────────────────────────────────────────
const ensureDir = async (dirPath) => {
  await fs.mkdir(dirPath, { recursive: true });
};

const ensureDirForFile = async (filePath) => {
  const dir = path.dirname(filePath);
  await ensureDir(dir);
};

const loadJson = async (filePath) => {
  const raw = await fs.readFile(filePath, 'utf8');
  return JSON.parse(raw);
};

const readJsonSafe = async (filePath, fallback) => {
  try {
    return await loadJson(filePath);
  } catch (error) {
    if (error && error.code === 'ENOENT') return fallback;
    // Treat invalid JSON or other IO errors as fatal unless a fallback is explicitly wanted.
    if (typeof fallback !== 'undefined') return fallback;
    throw error;
  }
};

const writeJsonAtomic = async (filePath, data) => {
  await ensureDirForFile(filePath);

  const tmpPath = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  const payload = JSON.stringify(data, null, 2);

  await fs.writeFile(tmpPath, payload, 'utf8');
  await fs.rename(tmpPath, filePath);
};

const writeTextAtomic = async (filePath, text) => {
  await ensureDirForFile(filePath);
  const tmpPath = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  await fs.writeFile(tmpPath, text, 'utf8');
  await fs.rename(tmpPath, filePath);
};

// ═══════════════════════════════════════════════════════════════════════════════
// TASK EXECUTION LOG - Vertailee suunniteltuja vs toteutuneita kuljetintehtävien aikoja
// ═══════════════════════════════════════════════════════════════════════════════
// Key: `${batch_id}|${lift_station}|${sink_station}` → {planned_start, planned_end, actual_start, actual_end, ...}
const taskExecutionLog = new Map();

const getTaskExecutionLogPath = () =>
  path.join(__dirname, '..', 'debug_snapshots', 'task_execution_log.csv');

const appendTaskExecutionLog = async (entry) => {
  const logPath = getTaskExecutionLogPath();
  const dir = path.dirname(logPath);
  if (!fsSync.existsSync(dir)) {
    fsSync.mkdirSync(dir, { recursive: true });
  }
  
  const header = 'transporter_id,batch_id,stage,lift_station,sink_station,planned_start,planned_end,actual_start,actual_end,delta_start,delta_end\n';
  const fileExists = fsSync.existsSync(logPath);
  
  const deltaStart = entry.actual_start != null && entry.planned_start != null
    ? (entry.actual_start - entry.planned_start).toFixed(2)
    : '';
  const deltaEnd = entry.actual_end != null && entry.planned_end != null
    ? (entry.actual_end - entry.planned_end).toFixed(2)
    : '';
  
  const line = [
    entry.transporter_id ?? '',
    entry.batch_id ?? '',
    entry.stage ?? '',
    entry.lift_station ?? '',
    entry.sink_station ?? '',
    entry.planned_start?.toFixed(2) ?? '',
    entry.planned_end?.toFixed(2) ?? '',
    entry.actual_start?.toFixed(2) ?? '',
    entry.actual_end?.toFixed(2) ?? '',
    deltaStart,
    deltaEnd
  ].join(',') + '\n';
  
  if (!fileExists) {
    fsSync.writeFileSync(logPath, header + line);
  } else {
    fsSync.appendFileSync(logPath, line);
  }
  console.log(`[TASK-EXEC-LOG] Written: B${entry.batch_id} ${entry.lift_station}→${entry.sink_station} deltaStart=${deltaStart}s deltaEnd=${deltaEnd}s`);
};

const clearTaskExecutionLog = () => {
  taskExecutionLog.clear();
  plannedTaskTimes.clear();
  const logPath = getTaskExecutionLogPath();
  if (fsSync.existsSync(logPath)) {
    fsSync.unlinkSync(logPath);
    console.log('[TASK-EXEC-LOG] Cleared previous log file');
  }
};

// Suunnitellut tehtäväajat snapshotista (täytetään writeDebugSnapshot:ssa)
// Key: `${batch_id}|${lift_station}|${sink_station}` → {task_start_time, task_finished_time, stage}
const plannedTaskTimes = new Map();

const storePlannedTaskTimes = (snapshot) => {
  // Kerää tehtävät sandboxTasks + waitingBatchTasks
  const allTasks = [];
  
  if (Array.isArray(snapshot.sandboxTasks)) {
    allTasks.push(...snapshot.sandboxTasks);
  }
  if (Array.isArray(snapshot.waitingBatchTasks)) {
    allTasks.push(...snapshot.waitingBatchTasks);
  }
  
  for (const task of allTasks) {
    if (task.batch_id != null && task.lift_station_id != null && task.sink_station_id != null) {
      const key = `${task.batch_id}|${task.lift_station_id}|${task.sink_station_id}`;
      plannedTaskTimes.set(key, {
        task_start_time: task.task_start_time,
        task_finished_time: task.task_finished_time,
        stage: task.stage
      });
    }
  }
  console.log(`[PLANNED-TIMES] Stored ${allTasks.length} planned task times from snapshot`);
};

// ═══════════════════════════════════════════════════════════════════════════════
// GLOBAALI TILA - Auktoritatiivinen lähde, muistissa
// Tiedostot ladataan käynnistyksessä, kirjoitetaan tickin lopussa
// ═══════════════════════════════════════════════════════════════════════════════
// VAIHE 2: Server omistaa VAIN fysiikan tilan
// Batches, schedules, tasks → Tilakone omistaa (lukee/kirjoittaa suoraan tiedostoista)
const runtimeState = {
  transporters: [],        // Nostimien tilat (SERVER OMISTAA - fysiikka)
  avoidStatuses: {},       // Asemien välttöstatukset (collision avoidance tarvitsee)
  initialized: false       // Onko ladattu tiedostoista
};

// Simulation settings (scaled time support)
// BASE_DT_MS = PLC:n ohjelmakierros, aina kiinteä. Ei muutu koskaan.
// speedMultiplier = kuinka monta ohjelmakierrosta ajetaan per seinäkello-tick.
//   x1:  1 tick / 20ms interval → 50 tick/s (reaaliaikainen)
//   x10: 10 tick / 20ms interval → 500 tick/s (10× nopeutettu)
const BASE_DT_MS = 20;
let speedMultiplier = 1;
let simDebt = 0;          // Aikavelka: kerää osittaiset tickit (tukee desimaalinopeuksia)
let loopTimer = null;
let simTick = 0;
let cachedTransporters = null;
let cachedStations = null;
let cachedNoTreatmentTasks = null;
let cachedProgram = null;
let simTimeMs = 0;
let tickInProgress = false;

// HANDSHAKE-lippu: Departure → TASKS synkronointi
// PLC-vastine: DB-bitti (esim. DB_HANDSHAKE.DepartureActivated)
let departureActivatedFlag = false;

let nextUnitId = 1;  // Seuraavan luotavan Unitin ID
// SYNKRONOINTI: TASKS SAVE → DEPARTURE kuittaus
// Asetetaan kun TASKS SAVE on kirjoittanut DEPARTURE:n pending datan tiedostoihin
let departureSaveConfirmedFlag = false;
// TASKS konfliktit ratkaistu: true kun linja on stabiili (ei konflikteja tai kaikki ratkaistu).
// Alkutila true (tyhjä linja = stabiili). DEPARTURE-aktivointi → false, TASKS stabiloi → true.
let tasksConflictResolved = true;

// PLC-scan-cycle mutex: ensures that simulation tick and any mutating API call
// cannot interleave. This prevents "rinnakkaisajo" effects caused by async awaits.
let scanMutex = Promise.resolve();
const withScanLock = async (fn) => {
  let release;
  const prev = scanMutex;
  scanMutex = new Promise((resolve) => {
    release = resolve;
  });
  await prev;
  try {
    return await fn();
  } finally {
    release();
  }
};

/**
 * Tarkista onko asematyyppi märkä
 * Station operations:
 * - 0: treatment (kind determines wet/dry)
 * - 10: cross-transporter (kind determines wet/dry)
 * - 20: loading, 21: unloading, 22: loading/unloading
 * - 30: buffer, 31: empty buffer, 32: loaded buffer, 33: processed buffer
 *
 * kind: 0=dry, 1=wet
 */
const isWetStation = (station) => (Number(station.kind) || 0) === 1;

let lastBatchLocations = new Map();
let productionPlan = null;
let lastStartStationClearTime = 0; // Track when the start station became empty

// Rinnakkaiset asemat: seuraa milloin asema vapautui (simTimeMs)
// Käytetään valitsemaan pisimpään tyhjänä ollut rinnakkaisasema
const stationIdleSince = new Map();  // stationNumber → simTimeMs when became idle

// Dashboard: hoist X-position history (sim-time based)
const HOIST_X_SAMPLE_EVERY_MS = 1000; // 1 Hz
const HOIST_X_WINDOW_MS = 60 * 60 * 1000; // 60 min
const hoistXHistory = {
  sampleEveryMs: HOIST_X_SAMPLE_EVERY_MS,
  windowMs: HOIST_X_WINDOW_MS,
  lastSampleAtMsByLine: new Map(),
  // line -> Map(transporterId -> Array<[tMs, xMm]>)
  buffersByLine: new Map()
};

const normalizeLineKey = (line) => {
  const n = Number(line);
  if (!Number.isFinite(n)) return null;
  const key = Math.floor(n / 100) * 100;
  return [100, 200, 300, 400].includes(key) ? key : null;
};

const lineKeyFromStartStation = (startStation) => normalizeLineKey(startStation);
const lineKeyFromStationNumber = (stationNumber) => normalizeLineKey(stationNumber);

const getLineXDomain = (lineKey) => {
  const stations = Array.isArray(cachedStations) ? cachedStations : [];
  let minX = Infinity;
  let maxX = -Infinity;
  for (const s of stations) {
    const n = s && s.number != null ? Number(s.number) : NaN;
    if (!Number.isFinite(n)) continue;
    const lk = lineKeyFromStationNumber(n);
    if (lk !== lineKey) continue;
    const x = Number(s.x_position);
    if (!Number.isFinite(x)) continue;
    minX = Math.min(minX, x);
    maxX = Math.max(maxX, x);
  }
  if (!Number.isFinite(minX) || !Number.isFinite(maxX)) {
    return { minX: 0, maxX: 0 };
  }
  return { minX, maxX };
};

const sampleHoistXHistory = (simNowMs, transportersCfg, transporterStates) => {
  if (!Number.isFinite(simNowMs)) return;
  const cfg = Array.isArray(transportersCfg) ? transportersCfg : [];
  const states = Array.isArray(transporterStates) ? transporterStates : [];

  const xById = new Map();
  for (const t of states) {
    const id = t && t.id != null ? Number(t.id) : NaN;
    const x = Number(t && t.state ? t.state.x_position : NaN);
    if (!Number.isFinite(id) || !Number.isFinite(x)) continue;
    xById.set(id, x);
  }

  const maxSamples = Math.max(1, Math.ceil(hoistXHistory.windowMs / hoistXHistory.sampleEveryMs));

  // We sample at most once per line per tick.
  const sampledLines = new Set();
  for (const t of cfg) {
    const id = t && t.id != null ? Number(t.id) : NaN;
    if (!Number.isFinite(id)) continue;

    const lineKey = lineKeyFromStartStation(t.start_station);
    if (lineKey == null) continue;

    const lastSampleAt = hoistXHistory.lastSampleAtMsByLine.get(lineKey);
    if (Number.isFinite(lastSampleAt) && simNowMs - lastSampleAt < hoistXHistory.sampleEveryMs) {
      continue;
    }
    if (sampledLines.has(lineKey)) continue;

    // For the selected lineKey, write one point for each hoist we can read.
    if (!hoistXHistory.buffersByLine.has(lineKey)) {
      hoistXHistory.buffersByLine.set(lineKey, new Map());
    }
    const lineMap = hoistXHistory.buffersByLine.get(lineKey);

    for (const t2 of cfg) {
      const id2 = t2 && t2.id != null ? Number(t2.id) : NaN;
      if (!Number.isFinite(id2)) continue;
      const lk2 = lineKeyFromStartStation(t2.start_station);
      if (lk2 !== lineKey) continue;
      const x2 = xById.get(id2);
      if (!Number.isFinite(x2)) continue;
      if (!lineMap.has(id2)) lineMap.set(id2, []);
      const arr = lineMap.get(id2);
      arr.push([simNowMs, x2]);
      if (arr.length > maxSamples) arr.splice(0, arr.length - maxSamples);
    }

    hoistXHistory.lastSampleAtMsByLine.set(lineKey, simNowMs);
    sampledLines.add(lineKey);
  }
};

// Precomputed movement-times cache (line 100, 2D)
let cachedMovementTimes = null;
let cachedMovementTimesPlantSetup = null;
let cachedMovementTimesLastAttemptMs = 0;

const getMovementTimesPath = () =>
  path.join(__dirname, '..', 'visualization', 'runtime', 'movement_times.json');

const ensureMovementTimesLoaded = async () => {
  // If already loaded for current plant setup, keep it.
  if (cachedMovementTimes && cachedMovementTimesPlantSetup === currentPlantSetup) {
    return cachedMovementTimes;
  }

  // If we already attempted recently and failed, avoid hammering disk every tick.
  const nowMs = Date.now();
  if (nowMs - cachedMovementTimesLastAttemptMs < 2000) {
    return cachedMovementTimesPlantSetup === currentPlantSetup ? cachedMovementTimes : null;
  }
  cachedMovementTimesLastAttemptMs = nowMs;

  const p = getMovementTimesPath();
  const loaded = await readJsonSafe(p, null);
  // Hyväksy tiedosto jos: 1) meta.plant_setup täsmää, TAI 2) meta puuttuu mutta transporters on olemassa
  const metaMatches = loaded && loaded.meta && loaded.meta.plant_setup === currentPlantSetup;
  const noMetaButValid = loaded && !loaded.meta && loaded.transporters;
  if (metaMatches || noMetaButValid) {
    cachedMovementTimes = loaded;
    cachedMovementTimesPlantSetup = currentPlantSetup;
    console.log(`[MovementTimes] Loaded ${path.basename(p)} for ${currentPlantSetup}${noMetaButValid ? ' (no meta)' : ''}`);
    return cachedMovementTimes;
  }

  // No (valid) file for this setup.
  cachedMovementTimes = null;
  cachedMovementTimesPlantSetup = currentPlantSetup;
  return null;
};

// Plant setup selection — empty on startup, set via /api/copy-customer-plant from gateway RESET
let currentPlantSetup = '';
let isCustomerPlant = false; // true when using customer plant, false when using template

// Middleware
app.use(cors());
app.use(express.json());

// Movement times endpoint

// --- DEBUG: Watch movement_times.json for changes/deletion ---
const movementTimesPathDebug = path.join(__dirname, '..', 'visualization', 'runtime', 'movement_times.json');
const fsWatch = require('fs');
function startMovementTimesWatcher() {
  try {
    fsWatch.watch(movementTimesPathDebug, (eventType, filename) => {
      const now = new Date().toISOString();
      if (eventType === 'change') {
        console.log(`[WATCH] ${now} movement_times.json changed`);
      } else if (eventType === 'rename') {
        console.log(`[WATCH] ${now} movement_times.json deleted or renamed`);
        // Yritä käynnistää watcher uudelleen, jos tiedosto syntyy myöhemmin
        setTimeout(() => startMovementTimesWatcher(), 1000);
      } else {
        console.log(`[WATCH] ${now} movement_times.json event:`, eventType);
      }
    });
    console.log('[WATCH] movement_times.json watcher active');
  } catch (err) {
    if (err.code === 'ENOENT') {
      // Tiedostoa ei vielä ole, yritä myöhemmin uudelleen
      setTimeout(() => startMovementTimesWatcher(), 1000);
    } else {
      console.warn('[WATCH] movement_times.json watcher could not be started:', err.message);
    }
  }
}
startMovementTimesWatcher();
app.get('/api/movement-times', async (req, res) => {
  try {
    const movementTimesPath = path.join(__dirname, '..', 'visualization', 'runtime', 'movement_times.json');
    const data = await readJsonSafe(movementTimesPath, null);
    if (!data) {
      return res.status(404).json({ success: false, error: 'movement_times.json not found' });
    }
    res.json({ success: true, movementTimes: data });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Serve static files from visualization directories
app.use(express.static(path.join(__dirname, '..', 'visualization', 'public')));
app.use('/src', express.static(path.join(__dirname, '..', 'visualization', 'src')));
// NOTE: Runtime files are an internal persistence detail; prefer API endpoints.
// Enable direct serving only for debugging.
if (process.env.EXPOSE_RUNTIME_FILES === 'true') {
  app.use(
    '/runtime',
    express.static(path.join(__dirname, '..', 'visualization', 'runtime'), {
      etag: false,
      lastModified: false,
      setHeaders: (res) => {
        res.setHeader('Cache-Control', 'no-store');
      }
    })
  );
}
app.use('/plant_templates', express.static(PLANT_TEMPLATES_DIR));
app.use(express.static(path.join(__dirname, '..', 'visualization')));

// Dynamic config endpoint - returns config from current plant setup
app.get('/api/config/:filename', async (req, res) => {
  try {
    let filename = req.params.filename;
    // Add .json extension if not present
    if (!filename.endsWith('.json')) {
      filename = filename + '.json';
    }
    const filepath = getPlantSetupPath(filename);
    const data = await loadJson(filepath);
    res.json(data);
  } catch (error) {
    res.status(404).json({ success: false, error: `Config file not found: ${req.params.filename}` });
  }
});

// Dynamic config PUT endpoint - saves config to current plant setup
app.put('/api/config/:filename', async (req, res) => {
  try {
    let filename = req.params.filename;
    // Add .json extension if not present
    if (!filename.endsWith('.json')) {
      filename = filename + '.json';
    }
    // Only allow specific config files to be updated
    const allowedFiles = ['layout_config.json'];
    if (!allowedFiles.includes(filename)) {
      return res.status(403).json({ success: false, error: `Cannot update config file: ${filename}` });
    }
    const filepath = getPlantSetupPath(filename);
    const data = req.body;
    await fs.writeFile(filepath, JSON.stringify(data, null, 2));
    console.log(`[config] Updated ${filename} in ${currentPlantSetup}`);
    res.json({ success: true, message: `Config file ${filename} updated` });
  } catch (error) {
    console.error(`[config] Failed to update config:`, error);
    res.status(500).json({ success: false, error: `Failed to update config file: ${error.message}` });
  }
});

// Basic API root for quick sanity checks
app.get('/api', (req, res) => {
  res.json({
    ok: true,
    message: 'PLC Simulator API',
    endpoints: [
      'GET  /api/transporter-states',
      'POST /api/transporter-states',
      'POST /api/command/move',
      'POST /api/reset-transporters',
      'POST /api/sim/start',
      'POST /api/sim/pause',
      'GET  /api/sim/speed',
      'POST /api/sim/speed'
    ]
  });
});

// Helpers: file paths (dynamic based on plant setup)
const getPlantSetupPath = (filename) => {
  const baseDir = isCustomerPlant ? CUSTOMERS_DIR : PLANT_TEMPLATES_DIR;
  return path.join(baseDir, currentPlantSetup, filename);
};

// Dynamic paths - config files read directly from plant_setup folder
const getPaths = () => ({
  // Config files (read directly from plant_setup, persistent per setup)
  transporters: getPlantSetupPath('transporters.json'),
  stations: getPlantSetupPath('stations.json'),
  layoutConfig: getPlantSetupPath('layout_config.json'),
  unitSetup: getPlantSetupPath('unit_setup.json'),
  noTreatmentTasks: getPlantSetupPath('no_treatment_tasks.json'),
  // Runtime files (change during simulation, can be cleared on reset)
  states: path.join(__dirname, '..', 'visualization', 'runtime', 'transporter_states.json'),
  batches: path.join(__dirname, '..', 'visualization', 'runtime', 'batches.json'),
  units: path.join(__dirname, '..', 'visualization', 'runtime', 'units.json'),
  avoidStatuses: path.join(__dirname, '..', 'visualization', 'runtime', 'station_avoid_status.json'),
  transporterTasks: path.join(__dirname, '..', 'visualization', 'runtime', 'transporter_tasks.json'),
  schedules: path.join(__dirname, '..', 'visualization', 'runtime', 'schedules.json'),
  productionSetup: path.join(__dirname, '..', 'visualization', 'runtime', 'production_setup.json'),
  batchSchedulesDir: path.join(__dirname, '..', 'visualization', 'runtime', 'batch_schedules'),
  // simulation_purpose.json is the master runtime file - contains customer/plant selection AND production config
  simulationPurpose: path.join(__dirname, '..', 'visualization', 'runtime', 'simulation_purpose.json')
});

// For backward compatibility, paths is now a getter
let paths = getPaths();

// Helper: zero-pad to 3 digits
const pad3 = (n) => String(n).padStart(3, '0');

// Persist per-batch schedule CSV (batch-only; no transporter phases)
// Columns: Station, EntryTime, ExitTime (seconds)
// NOTE: Calculated schedule is intended to be a snapshot written once at batch start.
const writeBatchScheduleCsv = async ({ batchId, scheduleResult, startExitTimeSec, overwrite = false }) => {
  const filePath = path.join(paths.batchSchedulesDir, `B${batchId}_calculated.csv`);

  // By default, do not overwrite an existing calculated schedule.
  // This prevents dashboard/API polling from truncating the beginning of the file.
  if (!overwrite) {
    try {
      await fs.access(filePath);
      return false; // Tiedosto oli jo olemassa, ei kirjoitettu
    } catch (err) {
      // ENOENT -> OK to create
    }
  }

  const fmt = (n) => {
    if (!Number.isFinite(n)) return '';
    // Round to whole seconds for CSV output
    return String(Math.round(n));
  };

  // Kirjoita aikataulu suoraan schedules.json:sta ILMAN ankkurointia tai offsetteja
  // Tämä varmistaa että CSV vastaa täsmälleen laskettua aikataulua
  const rows = [['Station', 'EntryTime_s', 'ExitTime_s']];

  if (scheduleResult && Array.isArray(scheduleResult.stages) && scheduleResult.stages.length > 0) {
    for (const stage of scheduleResult.stages) {
      const station = stage && stage.station != null ? stage.station : null;
      const entry = Number(stage && stage.entry_time_s);
      const exit = Number(stage && stage.exit_time_s);
      if (station == null || !Number.isFinite(entry) || !Number.isFinite(exit)) continue;

      // Kirjoita ajat suoraan scheduleResult:sta - ei erikoiskäsittelyä
      rows.push([station, fmt(entry), fmt(exit)]);
    }
  }

  const lines = rows.map((r) => r.join(','));
  await ensureDir(paths.batchSchedulesDir);
  await writeTextAtomic(filePath, lines.join('\n'));
  console.log(`[SCHEDULE CSV] Wrote ${filePath}`);
  return true; // Tiedosto luotiin
};

// Persist per-batch actual timing CSV (toteuma; cumulative updates)
// Columns: Station, EntryTime_s, ExitTime_s (seconds; whole numbers)
const updateBatchActualCsv = async ({ batchId, station, entryTimeSec, exitTimeSec }) => {
  if (batchId == null || station == null) return;

  const filePath = path.join(paths.batchSchedulesDir, `B${batchId}_actual.csv`);
  await ensureDir(paths.batchSchedulesDir);
  let rowsByStation = new Map();

  // readJsonSafe() is for JSON; for CSV we'll read raw.
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    const lines = raw.split(/\r?\n/).filter((l) => l.trim().length > 0);
    if (lines.length > 0) {
      for (let i = 1; i < lines.length; i += 1) {
        const [st, en, ex] = lines[i].split(',');
        const key = String(st).trim();
        if (!key) continue;
        rowsByStation.set(key, {
          station: key,
          entry: en != null && String(en).trim() !== '' ? String(en).trim() : '',
          exit: ex != null && String(ex).trim() !== '' ? String(ex).trim() : ''
        });
      }
    }
  } catch (err) {
    if (!(err && err.code === 'ENOENT')) {
      throw err;
    }
  }

  const key = String(station);
  const prev = rowsByStation.get(key) || { station: key, entry: '', exit: '' };
  const next = { ...prev };

  // Käytetään Math.round molemmille - sama kuin calculated CSV:ssä
  if (Number.isFinite(Number(entryTimeSec))) {
    next.entry = String(Math.round(Number(entryTimeSec)));
  }
  if (Number.isFinite(Number(exitTimeSec))) {
    next.exit = String(Math.round(Number(exitTimeSec)));
  }
  rowsByStation.set(key, next);

  // Stable order by station number
  const sorted = [...rowsByStation.values()].sort((a, b) => Number(a.station) - Number(b.station));
  const outLines = ['Station,EntryTime_s,ExitTime_s'];
  for (const r of sorted) {
    outLines.push([r.station, r.entry, r.exit].join(','));
  }
  await writeTextAtomic(filePath, outLines.join('\n'));
};


// List of all required state fields and their default values
const TRANSPORTER_STATE_FIELDS = {
  x_position: 0,
  y_position: 0,  // 2D transporters: fixed y-position (line number)
  z_position: 0,
  operation: "idle",
  current_station: null,
  load: null,
  velocity_x: 0,
  velocity_y: 0,  // 3D transporters: velocity in y direction
  status: 3,
  phase: 0,
  target_x: 0,
  target_y: 0,  // 3D transporters: target y position
  z_stage: "idle",
  z_timer: 0,
  velocity_z: 0,
  pending_batch_id: null,
  // In-flight task metadata (planned times from task list)
  current_task_batch_id: null,
  current_task_lift_station_id: null,
  current_task_sink_station_id: null,
  current_task_est_finish_s: null,
  initial_delay: 0,
  lift_station_target: null,
  sink_station_target: null,
  x_drive_target: 0,
  x_final_target: 0,
  y_drive_target: 0,  // 3D transporters: working y drive limit
  y_final_target: 0,  // 3D transporters: final y target
  x_min_drive_limit: 0,
  x_max_drive_limit: 0,
  y_min_drive_limit: 0,
  y_max_drive_limit: 0,
  z_min_drive_limit: 0,
  z_max_drive_limit: 0,
  // Phase statistics (cumulative times in ms for pie chart)
  phase_stats_idle_ms: 0,
  phase_stats_move_to_lift_ms: 0,
  phase_stats_lifting_ms: 0,
  phase_stats_move_to_sink_ms: 0,
  phase_stats_sinking_ms: 0,
  phase_stats_last_phase: 0,
  phase_stats_last_time_ms: 0
};

/**
 * Päivitä nostimen phase_stats kumulatiiviset ajat.
 * Kutsutaan jokaisen tikin alussa laskemaan edellisen vaiheen kesto.
 * @param {object} state - Nostimen tila (mutatoidaan in-place)
 * @param {number} currentTimeMs - Nykyinen simulaatioaika (ms)
 */
function updatePhaseStats(state, currentTimeMs) {
  if (!state || typeof currentTimeMs !== 'number') return;
  
  const lastPhase = state.phase_stats_last_phase || 0;
  const lastTimeMs = state.phase_stats_last_time_ms || 0;
  
  // Jos tämä on ensimmäinen kutsu, alusta lastTime
  if (lastTimeMs === 0) {
    state.phase_stats_last_time_ms = currentTimeMs;
    state.phase_stats_last_phase = state.phase || 0;
    return;
  }
  
  const elapsedMs = currentTimeMs - lastTimeMs;
  if (elapsedMs <= 0) return;
  
  // Lisää kulunut aika edelliseen vaiheeseen
  switch (lastPhase) {
    case 0: // idle
      state.phase_stats_idle_ms = (state.phase_stats_idle_ms || 0) + elapsedMs;
      break;
    case 1: // move_to_lift
      state.phase_stats_move_to_lift_ms = (state.phase_stats_move_to_lift_ms || 0) + elapsedMs;
      break;
    case 2: // lifting
      state.phase_stats_lifting_ms = (state.phase_stats_lifting_ms || 0) + elapsedMs;
      break;
    case 3: // move_to_sink
      state.phase_stats_move_to_sink_ms = (state.phase_stats_move_to_sink_ms || 0) + elapsedMs;
      break;
    case 4: // sinking
      state.phase_stats_sinking_ms = (state.phase_stats_sinking_ms || 0) + elapsedMs;
      break;
  }
  
  // Päivitä viimeisin aika ja vaihe
  state.phase_stats_last_time_ms = currentTimeMs;
  state.phase_stats_last_phase = state.phase || 0;
}

function normalizeTransporterState(state) {
  const norm = { ...TRANSPORTER_STATE_FIELDS };
  for (const key of Object.keys(TRANSPORTER_STATE_FIELDS)) {
    if (state && Object.prototype.hasOwnProperty.call(state, key)) {
      norm[key] = state[key];
    }
  }
  // Auto-update status based on operation: 3 = idle, 4 = active
  norm.status = (norm.operation === 'idle') ? 3 : 4;
  return norm;
}

function normalizeTransporter(t) {
  return {
    id: t.id,
    model: t.model,
    state: normalizeTransporterState(t.state)
  };
}


const normalizeStatesShape = (stateData = {}) => {
  // Only allow timestamp + transporters array, and normalize all transporter states
  const transporters = Array.isArray(stateData.transporters) ? stateData.transporters.map(normalizeTransporter) : [];
  return {
    timestamp: new Date().toISOString(),
    transporters
  };
};

const normalizeStatesData = (raw) => {
  const ts = raw && typeof raw.timestamp === 'string' ? raw.timestamp : new Date().toISOString();
  const transporters = Array.isArray(raw && raw.transporters) ? raw.transporters : [];
  return { timestamp: ts, transporters };
};

// Track last known transporter count to prevent accidental wipe
let lastKnownTransporterCount = 0;

const saveStates = async (stateData) => {
  const data = normalizeStatesShape(stateData);
  // Prevent saving empty transporters if we had transporters before
  if ((!data.transporters || data.transporters.length === 0) && lastKnownTransporterCount > 0) {
    console.log(`[BLOCK] Refusing to save empty transporters (had ${lastKnownTransporterCount} before)`);
    return data;
  }
  if (data.transporters && data.transporters.length > 0) {
    lastKnownTransporterCount = data.transporters.length;
  }
  await writeJsonAtomic(paths.states, data);
  return data;
};

const loadStates = async () => {
  try {
    const parsed = await loadJson(paths.states);
    return normalizeStatesData(parsed);
  } catch (_) {
    return normalizeStatesData({});
  }
};
const loadTransporters = async () => {
  // Always reload from disk to pick up changes without rebuild
  return await loadJson(paths.transporters);
};
const loadStations = async () => {
  // Always reload from disk to pick up changes without rebuild
  return await loadJson(paths.stations);
};

// Load no_treatment_tasks.json (Unit target → transport config)
const loadNoTreatmentTasks = async () => {
  if (cachedNoTreatmentTasks) return cachedNoTreatmentTasks;
  try {
    const data = await loadJson(paths.noTreatmentTasks);
    cachedNoTreatmentTasks = data || null;
  } catch (err) {
    cachedNoTreatmentTasks = null;
  }
  return cachedNoTreatmentTasks;
};
const stripScheduleFromBatch = (batch) => {
  if (!batch || typeof batch !== 'object') return batch;
  if (!Object.prototype.hasOwnProperty.call(batch, 'schedule')) return batch;
  // schedule kuuluu schedules.json:iin, ei batches.json runtime-tilaan
  // Poistetaan schedule aina kun luetaan/kirjoitetaan batchit
  const { schedule: _schedule, ...rest } = batch;
  return rest;
};

const normalizeBatchesPayload = (data) => {
  if (Array.isArray(data)) {
    return data.map(stripScheduleFromBatch);
  }
  if (data && typeof data === 'object' && Array.isArray(data.batches)) {
    return {
      ...data,
      batches: data.batches.map(stripScheduleFromBatch)
    };
  }
  return data;
};

const loadBatches = async () => {
  const data = await readJsonSafe(paths.batches, { batches: [] });
  return normalizeBatchesPayload(data);
};
const loadSchedules = async () => readJsonSafe(paths.schedules, { schedules: {}, timestamp: new Date().toISOString() });

const saveBatches = async (data) => {
  const normalized = normalizeBatchesPayload(data);
  await writeJsonAtomic(paths.batches, normalized);
  return normalized;
};

// ═══════════════════════════════════════════════════════════════════════════════
// UNITS: Fyysiset siirtoyksiköt (räkki/kori/rumpu)
//
// Unit omistaa sijainnin (location). Batch on Unitin sisällä.
// Transporter siirtää Unitteja, ei suoraan Batcheja.
//
// unit = { unit_id, location, batch_id|null }
//   - location: asema (>=100) tai nostin (<100), sama konventio kuin batch.location
//   - batch_id: null = tyhjä Unit (vapaa), muuten sidottu erään
// ═══════════════════════════════════════════════════════════════════════════════
const loadUnits = async () => {
  const data = await readJsonSafe(paths.units, { units: [] });
  return data?.units || [];
};
const saveUnits = async (units) => {
  await writeJsonAtomic(paths.units, { units });
};

// ─── Unit adapter -funktiot ─────────────────────────────────────────────────
// Näillä korvataan suorat batch.location -viittaukset.
// units-array annetaan parametrina (ei globaali), koska tick-funktio omistaa sen.
// ─────────────────────────────────────────────────────────────────────────────

/** Missä tämä batch on? Palauttaa location (station/transporter) tai null. */
const getUnitByBatchId = (units, batchId) =>
  units.find(u => u.batch_id === batchId) || null;

/** Mikä Unit on tässä paikassa? Palauttaa unit tai null. */
const getUnitAtLocation = (units, location) =>
  units.find(u => u.location === location) || null;

/** Onko paikka varattu (onko siellä Unit)? */
const isLocationOccupied = (units, location) =>
  units.some(u => u.location === location);

/** Hae batch:n sijainti Unitin kautta. */
const getBatchLocation = (units, batchId) => {
  const unit = getUnitByBatchId(units, batchId);
  return unit ? unit.location : null;
};

/** Siirrä Unit uuteen paikkaan (= siirrä batch). */
const setUnitLocation = (units, unitId, newLocation) => {
  const unit = units.find(u => u.unit_id === unitId);
  if (unit) unit.location = newLocation;
  return unit;
};

/** Sido batch Unitiin (lastaus). */
const attachBatchToUnit = (units, unitId, batchId) => {
  const unit = units.find(u => u.unit_id === unitId);
  if (unit) unit.batch_id = batchId;
  return unit;
};

/** Irrota batch Unitista (purku). */
const detachBatchFromUnit = (units, unitId) => {
  const unit = units.find(u => u.unit_id === unitId);
  if (unit) unit.batch_id = null;
  return unit;
};

/** Etsi vapaa Unit (ei batch:iä). */
const findFreeUnit = (units) =>
  units.find(u => u.batch_id == null) || null;

/** Onko batch nostimella? (Unit.location < 100) */
const isBatchOnTransporter = (units, batchId) => {
  const unit = getUnitByBatchId(units, batchId);
  return unit ? unit.location < 100 : false;
};

/** Kaikki varatut asemat (Unit on asemalla). */
const getOccupiedStations = (units) =>
  units.filter(u => u.location >= 100).map(u => u.location);

// ─── Unit-tavoitepohjainen automaattinen tehtävänluonti ─────────────────────
// Asematyypit: 20=loading, 21=unloading, 22=loading/unloading
//              30=buffer, 31=empty_buffer, 32=loaded_buffer, 33=processed_buffer
const LOADING_STATION_OPS = new Set([20, 22]);
const UNLOADING_STATION_OPS = new Set([21, 22]);
const BUFFER_STATION_OPS = new Set([30, 31, 32, 33]);

// ═══════════════════════════════════════════════════════════════════════════════
// updateUnitTargets — Keskitetty Unit target -arviointi
// Kutsutaan joka tickillä. Evaluoi jokaisen Unitin tila ja asettaa tarpeen
// mukaisen targetin. Tasks-tilakone lukee targetit ja luo kuljetustehtävät.
//
// Säännöt:
//   1. Viimeinen stage, calc_time kulunut         → 'to_unloading'
//   2. Tyhjä unit finish-stationilla, jono tyhjä  → 'to_empty_buffer'
//   3. 'to_loading' mutta jono tyhjä              → 'none'
//   4. Tyhjä unit prosessiasemalla, sinne tulossa erä (task) → 'to_avoid'
//   5. Unit on unloading-tyyppisellä asemalla (type 21 tai 22)
//      JA unit.state === 'empty'
//      JA unit.batch_id === null (ei erää)
//      JA jollakin toisella unitilla target === 'to_unloading'
//      → 'to_avoid' (väistä, jotta purkautuva erä pääsee unloading-asemalle)
//
// POIKKEUS (inline, EI tässä funktiossa):
//   - Batch attach → 'to_loaded_buffer' (spawn-koodi)
//   - Transport complete → 'none' (SINK DONE -koodi)
// ═══════════════════════════════════════════════════════════════════════════════
const updateUnitTargets = ({ units, batches, batchPrograms, productionPlan, simTimeMs, stations, transporterTasks }) => {
  let changed = false;

  for (const unit of units) {
    // Älä ylikirjoita olemassa olevaa targetia (paitsi 'none')
    if (unit.target && unit.target !== 'none') continue;

    // ── Sääntö 1: Viimeinen stage, calc_time kulunut → 'to_unloading' ──
    if (unit.batch_id != null && unit.status === 'used') {
      const batch = batches.find(b => b.batch_id === unit.batch_id);
      if (batch && batch.stage != null && batch.stage > 0 && batch.stage !== 90) {
        const program = batchPrograms.get(batch.batch_id);
        if (program && program.length > 0 && batch.stage === program.length) {
          const calcTimeS = Number(batch.calc_time_s) || 0;
          const elapsedS = (simTimeMs - (Number(batch.start_time) || 0)) / 1000;
          if (elapsedS >= calcTimeS && calcTimeS > 0) {
            unit.target = 'to_unloading';
            changed = true;
            console.log(`[UNIT-TARGET] U${unit.unit_id} → 'to_unloading' (B${batch.batch_id} last stage ${batch.stage}: ${elapsedS.toFixed(1)}s >= ${calcTimeS.toFixed(1)}s)`);
            continue;
          }
        }
      }
    }

    // ── Sääntö 2: Tyhjä unit finish-stationilla, jono tyhjä → 'to_empty_buffer' ──
    if (unit.state === 'empty' && unit.batch_id == null && productionPlan) {
      const queueEmpty = !productionPlan.queue || productionPlan.queue.length === 0;
      if (queueEmpty && unit.location === productionPlan.finishStation) {
        unit.target = 'to_empty_buffer';
        changed = true;
        console.log(`[UNIT-TARGET] U${unit.unit_id} → 'to_empty_buffer' (finish station ${productionPlan.finishStation}, queue empty)`);
        continue;
      }
    }

    // ── Sääntö 3: 'to_loading' mutta jono tyhjä → 'none' ──
    // (Tätä tarvitaan vain kun target on jo 'to_loading', mutta
    //  to_loading ei läpäise alkufiltteriä. Käsitellään erikseen alla.)
  }

  // ── Sääntö 3: 'to_loading' mutta jono tyhjä → 'none' ──
  if (productionPlan && (!productionPlan.queue || productionPlan.queue.length === 0)) {
    for (const unit of units) {
      if (unit.target === 'to_loading') {
        unit.target = 'none';
        changed = true;
        console.log(`[UNIT-TARGET] U${unit.unit_id} → 'none' (to_loading but queue empty)`);
      }
    }
  }

  // ── Sääntö 4: Tyhjä unit prosessiasemalla, sinne tulossa erä → 'to_avoid' ──
  for (const unit of units) {
    if (unit.state !== 'empty' || unit.batch_id != null) continue;
    if (unit.target && unit.target !== 'none') continue;
    if (unit.location == null || unit.location < 100) continue;

    const stObj = stations.find(s => s.number === unit.location);
    if (!stObj) continue;
    const stOp = Number(stObj.operation) || 0;
    // Bufferit, loading ja unloading ovat turvallisia — ei tarvitse väistää
    if (LOADING_STATION_OPS.has(stOp) || UNLOADING_STATION_OPS.has(stOp) || BUFFER_STATION_OPS.has(stOp)) continue;

    // Onko prosessiasemalle tulossa erä (task)?
    let incoming = false;
    if (transporterTasks) {
      for (const t of transporterTasks) {
        if (!t.is_no_treatment && t.sink_station_id === unit.location) { incoming = true; break; }
      }
    }
    if (incoming) {
      unit.target = 'to_avoid';
      changed = true;
      console.log(`[UNIT-TARGET] U${unit.unit_id} → 'to_avoid' (at process station ${unit.location}, incoming task)`);
    }
  }

  // ── Sääntö 5: Unit unloading-asemalla + empty + ei erää + toinen unit 'to_unloading' → 'to_avoid' ──
  // Ehdot: (1) unit on unloading-tyyppisellä asemalla (type 21/22)
  //        (2) unit.state === 'empty'
  //        (3) unit.batch_id === null
  //        (4) jollakin toisella unitilla target === 'to_unloading'
  // Tarkista ensin onko yhtään unitia jolla on 'to_unloading'
  let hasToUnloading = false;
  for (const u of units) {
    if (u.target === 'to_unloading') { hasToUnloading = true; break; }
  }
  if (hasToUnloading) {
    for (const unit of units) {
      if (unit.state !== 'empty' || unit.batch_id != null) continue;
      if (unit.location == null || unit.location < 100) continue;
      // to_avoid on korkein prioriteetti — ylikirjoittaa muut targetit (paitsi to_unloading)
      if (unit.target === 'to_unloading') continue;

      const stObj = stations.find(s => s.number === unit.location);
      if (!stObj) continue;
      const stOp = Number(stObj.operation) || 0;
      if (!UNLOADING_STATION_OPS.has(stOp)) continue;

      const prevTarget = unit.target || 'none';
      unit.target = 'to_avoid';
      changed = true;
      console.log(`[UNIT-TARGET] U${unit.unit_id} → 'to_avoid' (empty at unloading station ${unit.location}, another unit to_unloading, was '${prevTarget}')`);
    }
  }

  return changed;
};

/**
 * Etsi nostin jonka task_area kattaa annetun aseman numeron.
 * Palauttaa nostimen config-objektin tai null.
 */
const findTransporterForStation = (transportersCfg, stationNumber) => {
  for (const cfg of transportersCfg) {
    if (!cfg.task_areas) continue;
    for (const area of Object.values(cfg.task_areas)) {
      const minLift = area.min_lift_station || 0;
      const maxLift = area.max_lift_station || 0;
      const minSink = area.min_sink_station || 0;
      const maxSink = area.max_sink_station || 0;
      if (minLift > 0 && maxLift > 0 && stationNumber >= minLift && stationNumber <= maxLift) return cfg;
      if (minSink > 0 && maxSink > 0 && stationNumber >= minSink && stationNumber <= maxSink) return cfg;
    }
  }
  return null;
};

/**
 * Etsi KAIKKI nostimet joiden LIFT-alue kattaa annetun aseman.
 * Palauttaa taulukon nostimen config-objekteista.
 */
const findAllTransportersWithLiftCoverage = (transportersCfg, stationNumber) => {
  const result = [];
  for (const cfg of transportersCfg) {
    if (!cfg.task_areas) continue;
    for (const area of Object.values(cfg.task_areas)) {
      const minLift = area.min_lift_station || 0;
      const maxLift = area.max_lift_station || 0;
      if (minLift > 0 && maxLift > 0 && stationNumber >= minLift && stationNumber <= maxLift) {
        result.push(cfg);
        break; // Älä lisää samaa nostinta kahdesti
      }
    }
  }
  return result;
};

/**
 * Palauttaa nostimen lift- tai sink-alueen asemanumerot Set:inä.
 * @param {object} transporterCfg - Nostimen config
 * @param {'lift'|'sink'} type - Haettava aluetyyppi
 */
const getTransporterStationSet = (transporterCfg, type) => {
  const result = new Set();
  if (!transporterCfg?.task_areas) return result;
  for (const area of Object.values(transporterCfg.task_areas)) {
    const min = type === 'lift' ? (area.min_lift_station || 0) : (area.min_sink_station || 0);
    const max = type === 'lift' ? (area.max_lift_station || 0) : (area.max_sink_station || 0);
    if (min > 0 && max > 0) {
      for (let n = min; n <= max; n++) result.add(n);
    }
  }
  return result;
};

/**
 * Etsi loading/loading_unloading -tyyppinen asema nostimen sink-alueelta.
 * Palauttaa aseman numeron tai null.
 */
const findLoadingStationInTransporterArea = (transporterCfg, stations) => {
  if (!transporterCfg || !transporterCfg.task_areas) return null;
  const sinkStations = new Set();
  for (const area of Object.values(transporterCfg.task_areas)) {
    const minSink = area.min_sink_station || 0;
    const maxSink = area.max_sink_station || 0;
    if (minSink > 0 && maxSink > 0) {
      for (let n = minSink; n <= maxSink; n++) sinkStations.add(n);
    }
  }
  // Etsi ensimmäinen loading-tyyppinen asema sink-alueelta
  for (const s of stations) {
    if (sinkStations.has(s.number) && LOADING_STATION_OPS.has(Number(s.operation) || 0)) {
      return s.number;
    }
  }
  return null;
};

/**
 * Etsi unloading/loading_unloading -tyyppinen asema nostimen sink-alueelta.
 * Palauttaa aseman numeron tai null.
 */
const findUnloadingStationInTransporterArea = (transporterCfg, stations) => {
  if (!transporterCfg || !transporterCfg.task_areas) return null;
  const sinkStations = new Set();
  for (const area of Object.values(transporterCfg.task_areas)) {
    const minSink = area.min_sink_station || 0;
    const maxSink = area.max_sink_station || 0;
    if (minSink > 0 && maxSink > 0) {
      for (let n = minSink; n <= maxSink; n++) sinkStations.add(n);
    }
  }
  // Etsi ensimmäinen unloading-tyyppinen asema sink-alueelta
  for (const s of stations) {
    if (sinkStations.has(s.number) && UNLOADING_STATION_OPS.has(Number(s.operation) || 0)) {
      return s.number;
    }
  }
  return null;
};



const saveSchedules = async (schedules, currentTimeSec = null) => {
  const data = {
    schedules: schedules && typeof schedules === 'object' ? schedules : {},
    currentTimeSec: currentTimeSec,  // Simulaation aika jolloin laskettu
    timestamp: new Date().toISOString()
  };
  await writeJsonAtomic(paths.schedules, data);
  return data;
};
const saveTransporterTasks = async (tasks) => {
  // Filter out tasks for batches that are already on a transporter
  const activeBatchIds = new Set();
  if (runtimeState && runtimeState.transporters) {
    runtimeState.transporters.forEach(t => {
      if (t.state && t.state.pending_batch_id != null) {
        activeBatchIds.add(t.state.pending_batch_id);
      }
    });
  }

  const filteredTasks = tasks.filter(t => !activeBatchIds.has(t.batchId));
  
  if (tasks.length !== filteredTasks.length) {
    console.log(`[TASK FILTER] Filtered out ${tasks.length - filteredTasks.length} tasks for active batches:`, 
      tasks.filter(t => activeBatchIds.has(t.batchId)).map(t => t.batchId));
  }

  const data = { tasks: filteredTasks, timestamp: new Date().toISOString() };
  await writeJsonAtomic(paths.transporterTasks, data);
  return data;
};

// ═══════════════════════════════════════════════════════════════════════════════
// RUNTIME STATE - Lataus ja tallennus
// ═══════════════════════════════════════════════════════════════════════════════

// Lataa kaikki runtime-tiedostot muistiin (kutsutaan käynnistyksessä)
const loadRuntimeState = async () => {
  console.log('[STATE] Loading runtime state from files...');
  
  // VAIHE 2: Lataa VAIN server:in omistamat tiedot
  // Batches, schedules, tasks → Tilakone lukee itse INIT:ssä
  
  // 1. Lataa transporter states (SERVER OMISTAA)
  try {
    const statesData = await loadJson(paths.states);
    runtimeState.transporters = Array.isArray(statesData?.transporters) ? statesData.transporters : [];
    console.log(`[STATE] Loaded ${runtimeState.transporters.length} transporters`);
  } catch (e) {
    runtimeState.transporters = [];
    console.log('[STATE] No transporter_states.json, starting empty');
  }
  
  // 2. Lataa avoid statuses (collision avoidance tarvitsee)
  try {
    const avoidData = await readJsonSafe(paths.avoidStatuses, { stations: {} });
    runtimeState.avoidStatuses = avoidData?.stations || {};
  } catch (e) {
    runtimeState.avoidStatuses = {};
  }
  
  runtimeState.initialized = true;
  console.log('[STATE] Runtime state loaded (server: transporters + avoidStatuses only)');
};

// Tallenna kaikki runtime-tiedostot (kutsutaan tickin lopussa)
const saveRuntimeState = async () => {
  // VAIHE 2: Tallenna VAIN server:in omistamat tiedot
  // Batches, schedules, tasks → Tilakone tallentaa itse (phase 1900, 2900)
  
  // Tallenna transporter states (SERVER OMISTAA)
  const statesData = {
    timestamp: new Date().toISOString(),
    transporters: runtimeState.transporters
  };
  await writeJsonAtomic(paths.states, statesData);
  
  // Huom: batches.json, schedules.json, transporter_tasks.json
  // tallennetaan tilakoneesta (ctx.saveSchedules, ctx.saveTransporterTasks)
  // ja server päivittää batches.json joka tick kun fysiikka muuttuu
};

const normalizeBatchPayload = (raw) => {
  const errors = [];
  const toNum = (v, field) => {
    const n = Number(v);
    if (!Number.isFinite(n)) {
      errors.push(`${field} must be a number`);
      return null;
    }
    return n;
  };

  const batchId = toNum(raw.batch_id, 'batch_id');
  const location = toNum(raw.location, 'location');
  const program = toNum(raw.treatment_program, 'treatment_program');
  const stage = toNum(raw.stage, 'stage');
  const minTime = toNum(raw.min_time_s, 'min_time_s');
  const maxTime = toNum(raw.max_time_s, 'max_time_s');
  const calcTime = Number.isFinite(Number(raw.calc_time_s)) ? Number(raw.calc_time_s) : minTime;
  const startTime = Number.isFinite(Number(raw.start_time)) ? Number(raw.start_time) : 0;

  if (minTime < 0) {
    errors.push('min_time_s must be >= 0');
  }
  if (minTime != null && maxTime != null && maxTime < minTime) {
    errors.push('max_time_s cannot be less than min_time_s');
  }
  if (startTime < 0) {
    errors.push('start_time must be >= 0');
  }

  const payload = {
    batch_id: batchId,
    location,
    treatment_program: program,
    stage,
    min_time_s: minTime,
    max_time_s: maxTime,
    calc_time_s: calcTime < 0 ? 0 : calcTime,
    start_time: startTime
  };

  return { payload, errors };
};

const parseTimeToSeconds = (timeStr) => {
  if (!timeStr || typeof timeStr !== 'string') return 0;
  const parts = timeStr.split(':').map((p) => Number(p));
  if (parts.some((n) => !Number.isFinite(n))) return 0;
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return 0;
};

const formatSecondsToTime = (seconds) => {
  const s = Math.max(0, Math.round(Number(seconds) || 0));
  const hh = Math.floor(s / 3600);
  const mm = Math.floor((s % 3600) / 60);
  const ss = s % 60;
  return `${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}`;
};

const applyTreatmentProgramStretches = async (stretches = []) => {
  if (!Array.isArray(stretches) || stretches.length === 0) return;

  // Group stretches by batch so each CSV is read/written once.
  const byBatch = new Map();
  for (const s of stretches) {
    const batchId = Number(s && s.batchId);
    const stage = Number(s && s.stage);
    const delayS = Number(s && s.delayS);
    const targetCalcTimeS = Number(s && s.targetCalcTimeS); // legacy shape

    // Hyväksy sekä positiiviset (VIIVÄSTÄ) että negatiiviset (AIKAISTA) arvot
    const hasDelay = Number.isFinite(delayS) && delayS !== 0;
    const hasTarget = Number.isFinite(targetCalcTimeS) && targetCalcTimeS >= 0;

    if (!Number.isFinite(batchId) || !Number.isFinite(stage)) continue;
    if (stage < 1) continue; // program CSV uses stage 1..N
    if (!hasDelay && !hasTarget) continue;

    if (!byBatch.has(batchId)) byBatch.set(batchId, []);
    byBatch.get(batchId).push({ stage, delayS, targetCalcTimeS });
  }
  if (byBatch.size === 0) return;

  for (const [batchId, items] of byBatch.entries()) {
    // VAIHE 2: Lue batches tiedostosta
    const batchesData = await loadBatches();
    const batch = (batchesData?.batches || []).find((b) => Number(b && b.batch_id) === batchId);
    if (!batch) {
      console.warn(`[PROGRAM STRETCH] Skip B${batchId}: batch not found`);
      continue;
    }

    const currentStage = Number(batch.stage);
    const programNumber = batch ? parseInt(batch.treatment_program || '001', 10) : NaN;
    if (!Number.isFinite(programNumber)) continue;

    // Apply stretches to the exact stage(s) reported by task fitting.
    // No other stages are modified.
    const filteredItems = items;
    if (filteredItems.length === 0) {
      continue;
    }

    const batchIdStr = String(batchId).padStart(3, '0');
    const programNumStr = String(programNumber).padStart(3, '0');
    const filename = `Batch_${batchIdStr}_treatment_program_${programNumStr}.csv`;
    const filepath = path.join(__dirname, '..', 'visualization', 'runtime', filename);

    let raw;
    try {
      raw = await fs.readFile(filepath, 'utf8');
    } catch (err) {
      console.error(`[PROGRAM STRETCH] Missing program CSV for B${batchId}: ${filename}`);
      continue;
    }

    const lines = raw.split(/\r?\n/);
    if (lines.length < 2) continue;

    // Build per-stage additive delay (positive = VIIVÄSTÄ, negative = AIKAISTA).
    // If the legacy target form is used, we convert it to an effective delay at edit time.
    const delayByStage = new Map();
    const legacyTargetByStage = new Map();
    for (const it of filteredItems) {
      const st = Number(it && it.stage);
      const d = Number(it && it.delayS);
      const target = Number(it && it.targetCalcTimeS);
      if (!Number.isFinite(st)) continue;
      // Hyväksy sekä positiiviset (VIIVÄSTÄ) että negatiiviset (AIKAISTA) arvot
      if (Number.isFinite(d) && d !== 0) {
        delayByStage.set(st, (delayByStage.get(st) || 0) + d);
      }
      if (Number.isFinite(target) && target >= 0) {
        const prev = legacyTargetByStage.get(st);
        legacyTargetByStage.set(st, Number.isFinite(prev) ? Math.max(prev, target) : target);
      }
    }

    const out = [];
    out.push(lines[0]);
    for (let i = 1; i < lines.length; i += 1) {
      const line = lines[i];
      if (!line || !line.trim()) continue;
      const cols = line.split(',');
      if (cols.length < 5) {
        out.push(line);
        continue;
      }

      const stage = Number(cols[0]);
      const addDelay = delayByStage.get(stage);
      const legacyTarget = legacyTargetByStage.get(stage);
      if (!Number.isFinite(stage) || (!Number.isFinite(addDelay) && !Number.isFinite(legacyTarget))) {
        out.push(cols.join(','));
        continue;
      }

      // CSV columns: stage, min_station, max_station, min_time, max_time, calc_time(optional)
      const minTimeStr = cols[3] || '00:00:00';
      const maxTimeStr = cols[4] || '00:00:00';
      const calcTimeStr = (cols[5] != null && String(cols[5]).trim() !== '') ? cols[5] : maxTimeStr;

      const minS = parseTimeToSeconds(String(minTimeStr).trim());
      const maxS = parseTimeToSeconds(String(maxTimeStr).trim());
      const calcS = parseTimeToSeconds(String(calcTimeStr).trim());

      let effectiveDelayS = 0;
      // Hyväksy sekä positiiviset että negatiiviset delay-arvot
      if (Number.isFinite(addDelay) && addDelay !== 0) {
        effectiveDelayS += addDelay;
      }
      if (Number.isFinite(legacyTarget)) {
        // Convert target into a delay relative to current value in file.
        // This keeps older scheduler output working without mixing semantics.
        effectiveDelayS += Math.max(0, legacyTarget - calcS);
      }
      // Ohita vain jos ei muutosta
      if (!Number.isFinite(effectiveDelayS) || effectiveDelayS === 0) {
        out.push(cols.join(','));
        continue;
      }

      // Laske uusi calc_time: nykyinen + viive (positiivinen TAI negatiivinen)
      // VIIVÄSTÄ: rajoita max_time:iin
      // AIKAISTA: rajoita min_time:iin
      const targetCalcS = calcS + effectiveDelayS;
      let nextCalcS;
      if (effectiveDelayS > 0) {
        // VIIVÄSTÄ: ei saa ylittää max_time
        nextCalcS = Math.min(targetCalcS, maxS);
        if (targetCalcS > maxS + 1e-6) {
          console.warn(`[PROGRAM STRETCH] B${batchId} stage ${stage}: delay clamped to max_time (${targetCalcS.toFixed(1)}s → ${nextCalcS.toFixed(1)}s)`);
        }
      } else {
        // AIKAISTA: ei saa alittaa min_time
        nextCalcS = Math.max(targetCalcS, minS);
        if (targetCalcS < minS - 1e-6) {
          console.warn(`[PROGRAM STRETCH] B${batchId} stage ${stage}: advance clamped to min_time (${targetCalcS.toFixed(1)}s → ${nextCalcS.toFixed(1)}s)`);
        }
      }
      const nextCalcStr = formatSecondsToTime(nextCalcS);

      // Jos erä on TÄLLÄ stagella, päivitä myös runtime batch.calc_time_s
      // Tämä varmistaa että venytys vaikuttaa heti nykyiseen erään
      const batchStage = Number(batch.stage);
      if (Number.isFinite(batchStage) && batchStage === stage) {
        const oldBatchCalc = Number(batch.calc_time_s) || 0;
        batch.calc_time_s = nextCalcS;
        console.log(`[PROGRAM STRETCH] B${batchId} CURRENT stage ${stage}: batch.calc_time_s ${oldBatchCalc.toFixed(1)}s -> ${nextCalcS.toFixed(1)}s`);
      }

      // Ensure column exists
      if (cols.length >= 6) {
        cols[5] = nextCalcStr;
      } else {
        cols.push(nextCalcStr);
      }

      out.push(cols.join(','));

      const action = effectiveDelayS > 0 ? 'DELAY' : 'ADVANCE';
      const sign = effectiveDelayS > 0 ? '+' : '';
      console.log(`[PROGRAM STRETCH] B${batchId} stage ${stage} ${action}: calc_time ${calcS.toFixed(1)}s -> ${nextCalcS.toFixed(1)}s (${sign}${effectiveDelayS.toFixed(1)}s, min=${minS}s max=${maxS}s)`);
    }

    console.log(`[PROGRAM STRETCH] Writing ${filepath} with ${out.length} lines`);
    try {
      await writeTextAtomic(filepath, out.join('\n'));
      console.log(`[PROGRAM STRETCH] Successfully wrote ${filepath}`);
    } catch (writeErr) {
      console.error(`[PROGRAM STRETCH] FAILED to write ${filepath}:`, writeErr.message);
    }
  }
};

const loadTreatmentProgram = async (batchId, programNumber) => {
  // Build filename: Batch_001_treatment_program_001.csv
  const batchIdStr = String(batchId).padStart(3, '0');
  const programNumStr = String(programNumber).padStart(3, '0');
  const filename = `Batch_${batchIdStr}_treatment_program_${programNumStr}.csv`;
  const filepath = path.join(__dirname, '..', 'visualization', 'runtime', filename);
  
  // Always reload from disk to pick up changes without rebuild
  const csv = await fs.readFile(filepath, 'utf8');
  const lines = csv.trim().split(/\r?\n/);
  const out = [];
  for (let i = 1; i < lines.length; i += 1) {
    const cols = lines[i].split(',');
    if (cols.length < 5) continue;
    out.push({
      stage: Number(cols[0]),
      min_station: cols[1],
      max_station: cols[2],
      min_time: cols[3],
      max_time: cols[4],
      calc_time: cols[5] || cols[4]
    });
  }
  return out;
};

const listProductionFiles = async () => {
  const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
  const entries = await fs.readdir(runtimeDir);
  const parsed = [];
  for (const name of entries) {
    const m = name.match(/^Batch_(\d+)_treatment_program_(\d+)\.csv$/i);
    if (!m) continue;
    const batchId = Number(m[1]);
    const program = Number(m[2]);
    if (!Number.isFinite(batchId) || !Number.isFinite(program)) continue;
    parsed.push({ batchId, program, filename: name });
  }
  parsed.sort((a, b) => a.batchId - b.batchId);
  return parsed;
};

const parseBatchScheduleCsvFile = async (filePath) => {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    const lines = raw.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    if (lines.length <= 1) return [];
    const out = [];
    for (let i = 1; i < lines.length; i += 1) {
      const cols = lines[i].split(',');
      if (cols.length < 3) continue;

      // Support both formats:
      // 1) station,entry,exit (no stage column)
      // 2) stage,station,entry,exit (stage included)
      let stage = null;
      let station;
      let entry;
      let exit;

      if (cols.length >= 4) {
        stage = Number(cols[0]);
        station = Number(cols[1]);
        entry = cols[2] === '' ? null : Number(cols[2]);
        exit = cols[3] === '' ? null : Number(cols[3]);
      } else {
        station = Number(cols[0]);
        entry = cols[1] === '' ? null : Number(cols[1]);
        exit = cols[2] === '' ? null : Number(cols[2]);
      }

      if (!Number.isFinite(station)) continue;
      out.push({ stage: Number.isFinite(stage) ? stage : null, station, entryTime_s: Number.isFinite(entry) ? entry : null, exitTime_s: Number.isFinite(exit) ? exit : null });
    }
    return out;
  } catch (err) {
    if (err && err.code === 'ENOENT') return [];
    throw err;
  }
};

// Command endpoint: removed (manual tasks no longer supported)

// Units API endpoint (debug/UI)
app.get('/api/units', async (req, res) => {
  try {
    const units = await loadUnits();
    res.json({ units });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Update unit location and/or status
app.put('/api/units/:id', async (req, res) => {
  return withScanLock(async () => {
    try {
      const unitId = Number(req.params.id);
      if (!Number.isFinite(unitId)) {
        return res.status(400).json({ success: false, error: 'Invalid unit id' });
      }
      const { location, status, state: _stateFromBody, target: _targetFromBody } = req.body || {};
      const currentUnits = await loadUnits();
      const unit = currentUnits.find(u => u.unit_id === unitId);
      if (!unit) {
        return res.status(404).json({ success: false, error: `Unit ${unitId} not found` });
      }

      // Update status if provided
      if (status !== undefined) {
        if (status !== 'used' && status !== 'not_used') {
          return res.status(400).json({ success: false, error: 'Status must be "used" or "not_used"' });
        }
        const oldStatus = unit.status || 'used';
        unit.status = status;
        console.log(`[UNIT] Updated unit ${unitId} status: ${oldStatus} -> ${status}`);
      }

      // Update state if provided
      const VALID_STATES = ['empty', 'loaded', 'processed'];
      const { state: unitState, target: unitTarget } = req.body || {};
      if (unitState !== undefined) {
        if (!VALID_STATES.includes(unitState)) {
          return res.status(400).json({ success: false, error: `State must be one of: ${VALID_STATES.join(', ')}` });
        }
        const oldState = unit.state || 'empty';
        unit.state = unitState;
        console.log(`[UNIT] Updated unit ${unitId} state: ${oldState} -> ${unitState}`);
      }

      // Update target if provided
      const VALID_TARGETS = ['none', 'empty', 'to_loading', 'to_unloading', 'to_empty_buffer', 'to_loaded_buffer', 'to_processed_buffer', 'to_avoid'];
      if (unitTarget !== undefined) {
        if (!VALID_TARGETS.includes(unitTarget)) {
          return res.status(400).json({ success: false, error: `Target must be one of: ${VALID_TARGETS.join(', ')}` });
        }
        const oldTarget = unit.target || 'none';
        unit.target = unitTarget;
        console.log(`[UNIT] Updated unit ${unitId} target: ${oldTarget} -> ${unitTarget}`);
      }

      // Update location if provided
      if (location != null) {
        if (!Number.isFinite(Number(location))) {
          return res.status(400).json({ success: false, error: 'Valid location is required' });
        }
        const newLocation = Math.round(Number(location));
        // Tarkista ettei kohde-lokaatio ole jo varattu toisella unitilla
        const occupant = currentUnits.find(u => u.location === newLocation && u.unit_id !== unitId);
        if (occupant) {
          return res.status(409).json({ success: false, error: `Location ${newLocation} is already occupied by unit ${occupant.unit_id}` });
        }
        const oldLocation = unit.location;
        unit.location = newLocation;
        // Synkronoi batch.location shadow-kenttä jos unitilla on batch
        if (unit.batch_id != null) {
          const batchesData = await loadBatches();
          const batchesArr = batchesData?.batches || [];
          const batch = batchesArr.find(b => b.batch_id === unit.batch_id);
          if (batch) {
            batch.location = newLocation;
            await saveBatches({ batches: batchesArr });
            console.log(`[UNIT] Synced batch ${unit.batch_id} location shadow to ${newLocation}`);
          }
        }
        console.log(`[UNIT] Updated unit ${unitId} location: ${oldLocation} -> ${newLocation}`);
      }

      await saveUnits(currentUnits);
      res.json({ success: true, unit });
    } catch (error) {
      console.error('Error updating unit:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

// Simulation loop (time-scaled)
const stepSimulation = async (dtMs) => {
  const dt = dtMs / 1000;
  simTick += 1;
  
  // Käytä muistissa olevaa tilaa - lataa vain staattiset konfiguraatiot tiedostoista
  const [transporterConfig, stationsData] = await Promise.all([
    loadTransporters(),
    loadStations()
  ]);
  
  const transportersCfg = transporterConfig.transporters || [];
  const stations = stationsData.stations || [];

  // Cache latest config for dashboard endpoints
  cachedTransporters = transportersCfg;
  cachedStations = stations;
  
  // VAIHE 2: Batches, units ja schedules luetaan TIEDOSTOISTA (tilakone omistaa)
  const batchesData = await loadBatches();
  const batches = batchesData?.batches || [];
  
  const units = await loadUnits();
  // Synkronoi nextUnitId olemassaolevien unit_id:iden mukaan
  if (units.length > 0) {
    const maxId = Math.max(...units.map(u => u.unit_id));
    if (maxId >= nextUnitId) nextUnitId = maxId + 1;
  }
  
  const schedulesData = await loadSchedules();
  const schedulesByBatchId = schedulesData?.schedules || {};
  
  const avoidStatuses = runtimeState.avoidStatuses || {};
  
  // Varmista että transporters-tila on synkronoitu (SERVER omistaa)
  let transporterStates = runtimeState.transporters;
  if (!transporterStates || transporterStates.length === 0) {
    // Ei ole vielä ladattu - lataa kerran
    const stateData = await loadStates();
    transporterStates = stateData.transporters || [];
    runtimeState.transporters = transporterStates;
  }
  
  // DEBUG: Check z_timer at start of tick
  const t2AtStart = transporterStates.find(t => t.id === 2);
  if (t2AtStart && t2AtStart.state.phase === 1) {
    console.log(`[TICK-START] T2 z_timer=${t2AtStart.state.z_timer?.toFixed(3)}`);
  }

  // Dashboard sampling (sim time based)
  sampleHoistXHistory(simTimeMs, transportersCfg, transporterStates);
  let batchesChanged = false;
  const removedBatchIds = new Set();

  // Auto-spawn batches based on production plan (start station, loading interval)
  // DEBUG: Log spawn check
  if (productionPlan) {
    console.log(`[SPAWN-CHECK] queue=${productionPlan.queue?.length || 0}, simTimeMs=${simTimeMs}, nextSpawnMs=${productionPlan.nextSpawnMs}, active=${productionPlan.active}`);
  }
  if (productionPlan && productionPlan.startStation && productionPlan.active !== false) {
    // Tarkista onko aloitusasemalla Unit, joka on käytössä (used) ja tyhjä (empty)
    // Vain tällöin uusi erä voidaan aloittaa — viive alkaa tästä hetkestä
    const startUnit = getUnitAtLocation(units, productionPlan.startStation);
    const unitReadyForLoading = startUnit 
      && startUnit.status === 'used' 
      && startUnit.state === 'empty'
      && startUnit.batch_id === null;
    
    if (!unitReadyForLoading) {
      // Ei valmista Unittia aloitusasemalla — lykkää spawnaamista.
      // Asetetaan nextSpawnMs nollaksi jotta ensimmäinen erä ladataan heti
      // kun Unit tulee valmiiksi (ei turhaa lastausajan odotusta).
      // Jos erä on jo spawnattu aiemmin, nextSpawnMs > 0, joten
      // seuraava erä saa lastausajan normaalisti kun Unit on taas valmis.
      if (productionPlan.nextSpawnMs === 0) {
        // Ensimmäinen erä — pidetään 0 jotta ladataan heti
      } else {
        productionPlan.nextSpawnMs = simTimeMs + productionPlan.loadingIntervalMs;
      }
    } else {
      // Unit on valmis lastattavaksi. Tarkista onko viive kulunut.
      while (productionPlan.queue && productionPlan.queue.length > 0 && simTimeMs >= productionPlan.nextSpawnMs) {
        const next = productionPlan.queue.shift();
        try {
          const program = await loadTreatmentProgram(next.batchId, next.program);
          const firstStage = program[0];
          const minTime = firstStage ? parseTimeToSeconds(firstStage.min_time) : 0;
          const maxTime = firstStage ? parseTimeToSeconds(firstStage.max_time) : minTime;
          batches.push({
            batch_id: next.batchId,
            location: productionPlan.startStation,
            treatment_program: next.program,
            stage: 90, // 90 = loaded (waiting for start)
            min_time_s: 0,
            max_time_s: 0,
            calc_time_s: 0,
            start_time: simTimeMs,
            scheduleNeedsRecalc: true
          });
          
          // Sido batch olemassa olevaan Unittiin ja muuta tila loaded:ksi
          startUnit.batch_id = next.batchId;
          startUnit.state = 'loaded';
          startUnit.target = 'to_loaded_buffer';
          console.log(`[UNIT] Attached batch ${next.batchId} to unit ${startUnit.unit_id} at station ${productionPlan.startStation}, state -> loaded, target -> to_loaded_buffer`);
          
          // Upload batch + treatment program to PLC via gateway
          try {
            const plcStages = program.map(st => {
              const minSt = Number(st.min_station) || 0;
              const maxSt = Number(st.max_station) || minSt;
              const stations = [];
              for (let s = minSt; s <= maxSt && stations.length < 5; s++) {
                stations.push(s);
              }
              return {
                stations,
                minTime: parseTimeToSeconds(st.min_time),
                maxTime: parseTimeToSeconds(st.max_time),
                calTime: parseTimeToSeconds(st.calc_time || st.min_time)
              };
            });
            const batchPayload = {
              unitIndex: startUnit.unit_id,
              batchCode: next.batchId,
              batchState: 0, // NOT_PROCESSED
              programId: next.program,
              stages: plcStages
            };
            const gwRes = await fetch('http://gateway:3001/api/batch', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(batchPayload)
            });
            const gwData = await gwRes.json();
            if (gwData.ok) {
              console.log(`[PLC-BATCH] Uploaded batch ${next.batchId} to PLC unit ${startUnit.unit_id}: ${gwData.stagesWritten} stages`);
            } else {
              console.error(`[PLC-BATCH] Gateway error: ${gwData.error}`);
            }
          } catch (plcErr) {
            console.error(`[PLC-BATCH] Failed to upload to PLC: ${plcErr.message}`);
          }
          
          lastBatchLocations.set(next.batchId, productionPlan.startStation);
          batchesChanged = true;
          console.log(`[PROD] Spawned batch ${next.batchId} (program ${next.program}) at station ${productionPlan.startStation}`);
          
          // Onnistuneesti luotu. Seuraava viiveen jälkeen.
          productionPlan.nextSpawnMs = simTimeMs + productionPlan.loadingIntervalMs;
          
          // Unit on nyt loaded — ei enää tyhjä. Break estää päällekkäiset batchit.
          break; 
        } catch (err) {
          console.error('[PROD] Failed to spawn batch', next, err.message);
        }
      }
    }
    
    if (!productionPlan.queue || productionPlan.queue.length === 0) {
      productionPlan.active = false;
      // Viimeinen erä kiinnitetty → to_loading nollaus hoituu updateUnitTargets() säännössä 3
    }
  }

  // Auto-remove batches at finish station after unloading time
  // HUOM: Poistetaan VAIN erät jotka ovat käyneet käsittelyohjelman läpi (stage >= 1).
  // Stage 90 = juuri lastattu (odottaa aloitusta) — EI poisteta.
  if (productionPlan && productionPlan.finishStation && productionPlan.unloadingMs >= 0) {
    const keep = [];
    for (const b of batches) {
      const bUnit = getUnitByBatchId(units, b.batch_id);
      if (bUnit && bUnit.location === productionPlan.finishStation && b.stage !== 90 && b.stage !== 0) {
        const elapsedMs = simTimeMs - (Number(b.start_time) || 0);
        if (elapsedMs >= productionPlan.unloadingMs) {
          removedBatchIds.add(b.batch_id);
          batchesChanged = true;
          
          // Irrota batch Unitista — Unit jää finishStation-asemalle tyhjänä (vapaa kierrätettäväksi)
          const unit = getUnitByBatchId(units, b.batch_id);
          if (unit) {
            const queueHasBatches = productionPlan.queue && productionPlan.queue.length > 0;
            unit.batch_id = null;
            unit.state = 'empty';
            // Jos jonossa eriä → jää odottamaan lastaustapahtumaa (target=none)
            // Jos jono tyhjä → ohjaa bufferiin
            unit.target = queueHasBatches ? 'none' : 'to_buffer';
            console.log(`[UNIT] Detached batch ${b.batch_id} from unit ${unit.unit_id} at finish station ${productionPlan.finishStation}, state -> empty, target -> ${unit.target} (queue ${queueHasBatches ? 'has batches' : 'empty'})`);

            // Nollaa PLC:n batch- ja käsittelyohjelmatiedot tälle unit-indeksille
            try {
              const clearPayload = {
                unitIndex: unit.unit_id,
                batchCode: 0,
                batchState: 0,
                programId: 0,
                stages: []
              };
              const gwRes = await fetch('http://gateway:3001/api/batch', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(clearPayload)
              });
              const gwData = await gwRes.json();
              if (gwData.ok) {
                console.log(`[PLC-BATCH] Cleared batch+program for PLC unit ${unit.unit_id}`);
              } else {
                console.error(`[PLC-BATCH] Gateway clear error: ${gwData.error}`);
              }
            } catch (plcErr) {
              console.error(`[PLC-BATCH] Failed to clear PLC data for unit ${unit.unit_id}: ${plcErr.message}`);
            }
          }
          
          console.log(`[PROD] Removed batch ${b.batch_id} at finish station ${productionPlan.finishStation} after ${elapsedMs.toFixed(0)}ms`);
          
          // Write final ExitTime to actual CSV
          const exitTimeSec = simTimeMs / 1000;
          updateBatchActualCsv({ 
            batchId: b.batch_id, 
            station: productionPlan.finishStation, 
            exitTimeSec 
          }).catch(err => console.error(`[PROD] Failed to write final ExitTime for batch ${b.batch_id}:`, err));
          
          continue;
        }
      }
      keep.push(b);
    }
    if (keep.length !== batches.length) {
      batches.splice(0, batches.length, ...keep);
    }
    
    // ═══════════════════════════════════════════════════════════════════════════════
    // TUOTANNON VALMISTUMISEN TUNNISTUS
    // Kun kaikki erät on luotu (queue tyhjä) JA ei ole enää eriä linjalla
    // ═══════════════════════════════════════════════════════════════════════════════
    const queueEmpty = !productionPlan.queue || productionPlan.queue.length === 0;
    const allBatchesCompleted = batches.length === 0 && queueEmpty;
    
    if (allBatchesCompleted && productionPlan.active !== false) {
      console.log(`[PROD] ════════════════════════════════════════════════════════════`);
      console.log(`[PROD] PRODUCTION COMPLETE! All batches finished at ${(simTimeMs/1000).toFixed(1)}s`);
      console.log(`[PROD] Total batches processed: ${productionPlan.totalBatches || 'unknown'}`);
      console.log(`[PROD] ════════════════════════════════════════════════════════════`);
      
      productionPlan.active = false;
      productionPlan.completedAt = simTimeMs;
      
      // Merkitse tuotanto valmistuneeksi - tämä triggeröi pysäytyksen ja raportin tallennuksen
      productionPlan.productionCompleted = true;
    }
  }

  // Calculate and update drive limits for all transporters based on stations and other transporters
  // This modifies transporterStates in-place
  calculateWorkingAreas(transportersCfg, transporterStates, stations, avoidStatuses);

  const setBatchLocation = (idx, newLocation, extra = {}) => {
    const current = batches[idx];
    const locationChanged = current.location !== newLocation;
    const payload = {
      ...current,
      location: newLocation,
      ...extra
    };
    if (locationChanged) {
      console.log(`[SET LOCATION] Batch ${current.batch_id} moved: ${current.location} -> ${newLocation}`);
      payload.start_time = simTimeMs;
      payload.scheduleNeedsRecalc = true;
      payload.isDelayed = false;
      
      // Synkronoi Unit-sijainti batch-sijainnin kanssa
      const unit = getUnitByBatchId(units, current.batch_id);
      if (unit) {
        unit.location = newLocation;
      }
      
      // Rinnakkaiset asemat: päivitä stationIdleSince
      const oldLocation = current.location;
      // Jos vanha sijainti oli asema (>= 100), se vapautui nyt
      if (oldLocation >= 100) {
        stationIdleSince.set(oldLocation, simTimeMs);
        console.log(`[STATION IDLE] Station ${oldLocation} became idle at ${(simTimeMs/1000).toFixed(1)}s`);
      }
      // Jos uusi sijainti on asema (>= 100), se on nyt varattu
      if (newLocation >= 100) {
        stationIdleSince.delete(newLocation);
      }
    }
    lastBatchLocations.set(current.batch_id, newLocation);
    batches[idx] = payload;
    batchesChanged = true;
    console.log(`[SET LOCATION] batchesChanged set to true`);
  };

  // Ensure all batches have a valid start_time tied to sim clock
  let batchesTouched = false;
  batches.forEach((b, idx) => {
    const rawStart = Number(b.start_time);
    const normalizedStart = Number.isFinite(rawStart) ? Math.max(0, rawStart) : simTimeMs;
    const clampedStart = Math.min(simTimeMs, normalizedStart);
    if (clampedStart !== rawStart) {
      console.log(`[BATCH-TOUCH] B${b.batch_id} start_time: ${rawStart} -> ${clampedStart}`);
      batches[idx] = { ...batches[idx], start_time: clampedStart };
      batchesTouched = true;
    }
    // NOTE: calc_time_s must NOT be forced back to min_time_s every tick.
    // calc_time_s is initialized (typically to min_time_s) when per-batch program is created,
    // and later modified by task fitting / scheduling logic.
    // Here we only sanitize invalid values to keep runtime state stable.
    const calcTime = Number(b.calc_time_s);
    const minTime = Number(b.min_time_s);
    if (!Number.isFinite(calcTime)) {
      const fallback = Number.isFinite(minTime) ? minTime : 0;
      console.log(`[BATCH-TOUCH] B${b.batch_id} calc_time_s invalid (${b.calc_time_s}) -> ${fallback}`);
      batches[idx] = { ...batches[idx], calc_time_s: fallback };
      batchesTouched = true;
    } else if (calcTime < 0) {
      console.log(`[BATCH-TOUCH] B${b.batch_id} calc_time_s negative (${calcTime}) -> 0`);
      batches[idx] = { ...batches[idx], calc_time_s: 0 };
      batchesTouched = true;
    }
    // If location changed externally between ticks, stamp start_time to sim clock
    const prevLoc = lastBatchLocations.get(b.batch_id);
    const bUnitLoc = getBatchLocation(units, b.batch_id);
    if (prevLoc !== undefined && prevLoc !== bUnitLoc) {
      console.log(`[BATCH-TOUCH] B${b.batch_id} location changed externally: ${prevLoc} -> ${bUnitLoc}`);
      batches[idx] = { ...batches[idx], start_time: simTimeMs };
      batchesTouched = true;
    }
    lastBatchLocations.set(b.batch_id, bUnitLoc ?? b.location);
  });
  if (batchesTouched) {
    batchesChanged = true;
  }

  // Pre-load treatment programs for all batches (needed for sink completion)
  const batchPrograms = new Map();
  for (const batch of batches) {
    try {
      const programNumber = parseInt(batch.treatment_program || '1', 10);
      const program = await loadTreatmentProgram(batch.batch_id, programNumber);
      batchPrograms.set(batch.batch_id, program);
    } catch (err) {
      console.error(`Failed to load program for batch ${batch.batch_id}:`, err.message);
      batchPrograms.set(batch.batch_id, []);
    }
  }

  // VAIHE 2: Tasks luetaan TIEDOSTOSTA (tilakone omistaa)
  const tasksData = await loadJson(paths.transporterTasks);
  let transporterTasks = (tasksData?.tasks || []).slice(); // kopio, jotta voidaan muokata

  // ═══════════════════════════════════════════════════════════════════════════════
  // Keskitetty Unit target -arviointi (säännöt 1-5)
  // ═══════════════════════════════════════════════════════════════════════════════
  if (updateUnitTargets({ units, batches, batchPrograms, productionPlan, simTimeMs, stations, transporterTasks })) {
    batchesChanged = true;
  }
  const nowSec = simTimeMs / 1000;
  let tasksModified = false;

  if (removedBatchIds.size > 0 && transporterTasks.length > 0) {
    const before = transporterTasks.length;
    transporterTasks = transporterTasks.filter((t) => !removedBatchIds.has(t.batch_id));
    if (transporterTasks.length !== before) {
      tasksModified = true;
    }
  }

  const updatedTransporters = await Promise.all(transporterStates.map(async (tState) => {
    const cfg = transportersCfg.find((c) => c.id === tState.id);
    if (!cfg) return tState;

    const station = stations.find((s) => s.number === tState.state.current_station) || {};

    // Use physics_3D for 3D transporters, physics_2D for 2D
    const physics = (tState.model === "3D" && cfg.physics_3D) ? cfg.physics_3D : (cfg.physics_2D || {});
    const vMax = physics.x_max_speed_mm_s || 0;
    const tAcc = physics.x_acceleration_time_s || 0.001;
    const tDec = physics.x_deceleration_time_s || 0.001;
    const aAcc = vMax / tAcc;
    const aDec = vMax / tDec;

    const zTotal = physics.z_total_distance_mm || 0;
    const zSlowDry = physics.z_slow_distance_dry_mm || 0;
    const zSlowWet = physics.z_slow_distance_wet_mm || 0;
    const zSlowEnd = physics.z_slow_end_distance_mm || 0;
    const zSlowSpeed = physics.z_slow_speed_mm_s || 0;
    const zFastSpeed = physics.z_fast_speed_mm_s || 0;
    const dripDelay = physics.drip_tray_delay_s || 0;
    const deviceDelay = Number(station.device_delay) || 0;
    const stationOp = Number(station.operation) || 0;
    const stationKind = Number(station.kind) || 0;

    const state = { ...tState.state };
    
    // Päivitä phase_stats kumulatiiviset ajat (piirakkakaavio UI:ssa)
    updatePhaseStats(state, simTimeMs);
    
    // DEBUG: Check tState.state vs state copy
    if (tState.id === 2 && state.phase === 1) {
      console.log(`[COPY-DEBUG] T2 tState.state.z_timer=${tState.state.z_timer?.toFixed(3)} state.z_timer=${state.z_timer?.toFixed(3)}`);
    }
    
    if (typeof state.velocity_x !== 'number') state.velocity_x = 0;
    if (typeof state.velocity_y !== 'number') state.velocity_y = 0;
    if (typeof state.phase !== 'number') state.phase = 0; // 0 idle
    if (typeof state.target_x !== 'number') state.target_x = state.x_position;
    if (typeof state.target_y !== 'number') state.target_y = state.y_position;
    if (typeof state.z_position !== 'number') state.z_position = 0;
    if (!state.z_stage) state.z_stage = 'idle';
    if (typeof state.z_timer !== 'number') state.z_timer = 0;
    if (typeof state.velocity_z !== 'number') state.velocity_z = 0;
    if (!state.pending_batch_id) state.pending_batch_id = null;
    if (typeof state.initial_delay !== 'number') state.initial_delay = 0;

    // Yritä antaa uusi tehtävä idle-nostimelle
    // Tarkista ensin että tilakone sallii tehtävien annon (vaihe >= TASKS_SAVE)
    const canAssign = stateMachine.canAssignTasks();
    if (state.status === 3 && state.phase === 0 && canAssign) {
      // ═══ DISPATCH-VALINTA ═══
      // Dispatch kunnioittaa task_start_time -ajoitusta.
      //
      // Kandidaattien valinta:
      //   Batch: erä on nostoasemalla
      //
      // Dispatch-järjestys: aikaisin task_start_time ensin.

      // Yhteinen suodatin: oikea nostin + sink-asema vapaa (tai rinnakkaisasema)
      const myTasks = transporterTasks.filter((task) => {
        if (task.transporter_id !== tState.id) return false;
        if (task.sink_station_id == null) return true;

        // Sink vapaa → OK
        if (!isLocationOccupied(units, task.sink_station_id)) return true;

        // Sink varattu → tarkista rinnakkaisasemat (vain batch-tehtävillä)
        if (task.is_no_treatment) return false;

        const bForPar = batches.find(b => b.batch_id === task.batch_id);
        if (!bForPar) return false;
        // Käytä batchPrograms-Mapia (ladattu aiemmin loadTreatmentProgram:lla)
        const prog = batchPrograms.get(task.batch_id);
        if (!prog || !prog.length || !task.stage) return false;

        // sink = seuraava stage → ohjelman indeksi = task.stage (0-pohjainen: stage N+1 → prog[N])
        // stage on 1-pohjainen, prog on 0-indeksoitu: stage 12 = prog[11] = prog[task.stage]
        // kun task.stage = 11 (nosto-stage), prog[11] = sink-stage (stage 12)
        const sinkStageIdx = task.stage;
        const stageInfo = sinkStageIdx >= 0 && sinkStageIdx < prog.length ? prog[sinkStageIdx] : null;
        if (!stageInfo) return false;

        const parallelStations = scheduler.getParallelStations(stageInfo, stations);
        if (!parallelStations || parallelStations.length <= 1) return false;

        // Etsi vapaa rinnakkaisasema
        for (const ps of parallelStations) {
          if (ps.number === task.sink_station_id) continue;
          if (!isLocationOccupied(units, ps.number)) {
            console.log('[TASK-ASSIGN] T' + tState.id + ' PARALLEL-REDIRECT B' + task.batch_id + 's' + task.stage + ': ' + task.sink_station_id + '→' + ps.number + ' (original occupied)');
            task.sink_station_id = ps.number;
            return true;
          }
        }
        return false; // Kaikki rinnakkaiset varattu
      });

      // Kerää dispatch-kandidaatit: erä/unit on nostoasemalla
      const dispatchCandidates = myTasks.filter((task) => {
        // No-treatment tasks: unit on nostoasemalla
        if (task.is_no_treatment) {
          const unitForTask = units.find(u => u.unit_id === task.unit_id);
          return unitForTask && unitForTask.location === task.lift_station_id;
        }
        const batchForTask = batches.find(b => b.batch_id === task.batch_id);
        return batchForTask && batchForTask.location === task.lift_station_id;
      });

      // Järjestä task_start_time mukaan — aikaisin ensin
      dispatchCandidates.sort((a, b) => (a.task_start_time || 0) - (b.task_start_time || 0));

      // ═══ DISPATCH-VALINTA ═══
      // Kandidaatit on jo suodatettu (erä nostoasemalla) ja järjestetty task_start_time mukaan.
      //
      // Batch: dispatch kun timeUntilStart <= travelTime + 5 TAI canStartEarly (min_time kulunut)
      let nextTask = null;

      for (const candidate of dispatchCandidates) {
        // No-treatment: dispatch heti (ei batch-ajoitusta)
        if (candidate.is_no_treatment) {
          nextTask = candidate;
          break;
        }

        const candidateLiftStation = stations.find((s) => s.number === candidate.lift_station_id);
        if (!candidateLiftStation) continue;

        const candidateTravelTime = scheduler.calculateHorizontalTravelTime(
          { x_position: state.x_position || 0 }, candidateLiftStation, cfg
        );
        const candidateTimeUntilStart = candidate.task_start_time - nowSec;

        // Batch-kandidaatti: canStartEarly jos min_time kulunut
        let candidateCanStartEarly = false;
        const batchToCheck = batches.find(b => b.batch_id === candidate.batch_id);
        if (batchToCheck && batchToCheck.stage_start_time != null) {
          const timeOnStation = nowSec - (batchToCheck.stage_start_time / 1000);
          const programId = batchToCheck.treatment_program || batchToCheck.program;
          const program = productionPlan?.programs?.[programId];
          const batchStage = batchToCheck.stage;
          const stageIndex = batchStage >= 1 ? batchStage - 1 : -1;
          const stageInfo = stageIndex >= 0 ? program?.[stageIndex] : null;
          const minTime = stageInfo
            ? scheduler.parseTimeToSeconds(stageInfo.min_time)
            : (Number(batchToCheck.min_time_s) || 0);
          if (timeOnStation >= minTime) candidateCanStartEarly = true;
        }

        if (candidateTimeUntilStart <= candidateTravelTime + 5 || candidateCanStartEarly) {
          nextTask = candidate;
          break;
        } else {
          console.log('[TASK-ASSIGN] T' + tState.id + ' SKIP-BATCH B' + candidate.batch_id + 's' + candidate.stage + '@' + candidate.lift_station_id + ': tUntil=' + candidateTimeUntilStart.toFixed(1) + ' > travel+5=' + (candidateTravelTime + 5).toFixed(1) + ', early=' + candidateCanStartEarly);
        }
      }

      const nextTaskLabel = nextTask ? 'B' + nextTask.batch_id + 's' + nextTask.stage + '@' + nextTask.lift_station_id : 'none';
      console.log('[TASK-ASSIGN] T' + tState.id + ': idle, canAssign=' + canAssign + ', tasks=' + transporterTasks.length + ', candidates=' + dispatchCandidates.length + ', nextTask=' + nextTaskLabel);
      if (nextTask) {
        const liftStation = stations.find((s) => s.number === nextTask.lift_station_id);
        if (liftStation) {
          const batchToMove = batches.find(b => b.batch_id === nextTask.batch_id);
          {
            // Dispatch-päätös on jo tehty yllä (task_start_time + canStartEarly -tarkistus).
            // Ajetaan suoraan kohti nostoa.
              state.lift_station_target = nextTask.lift_station_id;
              state.sink_station_target = nextTask.sink_station_id;
              state.pending_batch_id = nextTask.batch_id;
              state.current_task_batch_id = nextTask.batch_id;
              state.current_task_lift_station_id = nextTask.lift_station_id;
              state.current_task_sink_station_id = nextTask.sink_station_id;
              state.current_task_est_finish_s = nextTask.task_finished_time;
              state.current_task_is_no_treatment = nextTask.is_no_treatment || false;
              state.current_task_is_primary_destination = nextTask.is_primary_destination || false;
              state.target_x = liftStation.x_position;
              state.x_final_target = liftStation.x_position;
              if (tState.model === "3D") {
                state.target_y = liftStation.y_position || 0;
                state.y_final_target = liftStation.y_position || 0;
                state.y_drive_target = liftStation.y_position || 0;
              }
              state.phase = 1; // move_to_lifting
              state.velocity_x = 0;
              state.operation = 'task_move';
              state.velocity_z = 0;

              // Timer-pohjainen phase 1 X-siirto (2D)
              if (tState.model !== '3D') {
                const fromNum = String(state.current_station);
                const toNum = String(state.lift_station_target);
                const tId = String(tState.id);
                let travelS = 0;
                if (cachedMovementTimes?.transporters?.[tId]?.travel_s?.[fromNum]?.[toNum] != null) {
                  travelS = Number(cachedMovementTimes.transporters[tId].travel_s[fromNum][toNum]);
                }
                if (travelS > 0) {
                  state._travel_total_time = travelS;
                  state._travel_from_x = state.x_position;
                  state._travel_to_x = liftStation.x_position;
                  state.z_timer = travelS;
                  state.z_stage = 'timer_travel_phase1';
                  console.log(`[TRAVEL-TIMER-P1] T${tState.id} ${fromNum}→${toNum} travel_s=${travelS.toFixed(2)}s`);
                } else {
                  // Sama asema tai ei esilaskettua aikaa → skip suoraan
                  state.z_stage = 'idle';
                  state.z_timer = 0;
                }
              } else {
                state.z_stage = 'idle';
                state.z_timer = 0;
              }
              // Poista tehtävä listalta, ettei sitä anneta uudelleen
              transporterTasks = transporterTasks.filter((t) => t !== nextTask);
              tasksModified = true;
              

          }
        }
      }
    }

    // Update current_station to nearest station based on x/y position
    const updateCurrentStation = () => {
      const is2D = tState.model === '2D';
      let minDist = Infinity;
      let nearestStation = state.current_station;
      
      // For 2D: find stations in transporter's task area to determine y-line
      let validStations = stations;
      if (is2D && cfg.task_areas) {
        const taskStations = new Set();
        for (const area of Object.values(cfg.task_areas)) {
          const minLift = area.min_lift_station || 0;
          const maxLift = area.max_lift_station || 0;
          const minSink = area.min_sink_station || 0;
          const maxSink = area.max_sink_station || 0;
          if (minLift > 0 && maxLift > 0) {
            for (let n = minLift; n <= maxLift; n++) taskStations.add(n);
          }
          if (minSink > 0 && maxSink > 0) {
            for (let n = minSink; n <= maxSink; n++) taskStations.add(n);
          }
        }
        validStations = stations.filter(st => taskStations.has(st.number));
      }
      
      for (const st of validStations) {
        const dx = (st.x_position || 0) - (state.x_position || 0);
        let dist;
        if (is2D) {
          // 2D: only check x distance (stations already filtered by task area)
          dist = Math.abs(dx);
        } else {
          // 3D: check both x and y distance
          const dy = (st.y_position || 0) - (state.y_position || 0);
          dist = Math.sqrt(dx * dx + dy * dy);
        }
        
        if (dist < minDist) {
          minDist = dist;
          nearestStation = st.number;
        }
      }
      
      // Debug: log when current_station changes
      if (state.current_station !== nearestStation) {
        console.log(`[UPDATE-STATION] T${tState.id} current_station ${state.current_station}→${nearestStation} x=${state.x_position} minDist=${minDist.toFixed(1)} validStations=${validStations.map(s=>s.number).join(',')}`);
      }
      state.current_station = nearestStation;
    };

    const arriveLift = () => {
      state.current_station = state.lift_station_target || state.current_station;
      // Get device_delay from the LIFT station, not from current_station at update start
      const liftStation = stations.find((s) => s.number === state.lift_station_target) || {};
      const liftDeviceDelay = Number(liftStation.device_delay) || 0;
      let extraWait = 0;
      const unitAtLift = getUnitAtLocation(units, state.current_station);
      const batchAtStation = unitAtLift ? batches.find(b => b.batch_id === unitAtLift.batch_id) : null;
      if (batchAtStation) {
        const elapsed = Math.max(0, (simTimeMs - (Number(batchAtStation.start_time) || 0)) / 1000);
        const minRequired = Number(batchAtStation.min_time_s) || 0;
        extraWait = Math.max(0, minRequired - elapsed);
      }
      const initialDelay = extraWait > liftDeviceDelay ? extraWait : liftDeviceDelay;
      console.log(`[LIFT-DELAY] T${tState.id} Station=${state.current_station} deviceDelay=${liftDeviceDelay}s extraWait=${extraWait.toFixed(1)}s initialDelay=${initialDelay.toFixed(1)}s`);
      state.phase = 1;
      // 3D transporters use 'idle' stage, 2D use 'delay_up'
      state.z_stage = (tState.model === "3D") ? 'idle' : 'delay_up';
      state.z_timer = initialDelay;
      state.initial_delay = initialDelay;
      state.operation = 'lifting_wait';
      state.velocity_z = 0;
      state.pending_batch_id = batchAtStation ? batchAtStation.batch_id : null;
    };

    const arriveSink = () => {
      const phase3Duration = state.phase_start_time ? (simTimeMs - state.phase_start_time) / 1000 : 0;
      console.log(`[PHASE-TIMING] T${tState.id} phase3 ACTUAL=${phase3Duration.toFixed(1)}s`);
      console.log(`[ARRIVE SINK] Transporter ${tState.id} arrived at sink station ${state.sink_station_target}`);
      state.current_station = state.sink_station_target || state.current_station;
      state.phase = 4; // sinking
      state.phase_start_time = simTimeMs;
      state.z_stage = 'idle';
      state.z_timer = 0;
      state.operation = 'sink_prep';
    };

    const transferPendingBatchToTransporter = async () => {
      console.log(`[TRANSFER DEBUG] T${tState.id} current_station=${state.current_station} pending=${state.pending_batch_id} units:`, units.map(u => `U${u.unit_id}@${u.location}(B${u.batch_id})`).join(' '));
      if (state.pending_batch_id == null) {
        // Tyhjä Unit -siirto (esim. unit target -tehtävä): siirrä Unit nostimelle
        const emptyUnit = getUnitAtLocation(units, state.current_station);
        if (emptyUnit && emptyUnit.batch_id == null) {
          console.log(`[TRANSFER] Empty unit U${emptyUnit.unit_id} lifted from station ${state.current_station} to transporter ${tState.id}`);
          emptyUnit.location = tState.id;
          batchesChanged = true;
          return true;
        }
        return false;
      }
      const batchIdxById = batches.findIndex((b) => b.batch_id === state.pending_batch_id);
      const unitAtStaLoc = getUnitAtLocation(units, state.current_station);
      const batchIdxByLoc = unitAtStaLoc ? batches.findIndex(b => b.batch_id === unitAtStaLoc.batch_id) : -1;
      const targetIdx = batchIdxById >= 0 ? batchIdxById : batchIdxByLoc;
      if (targetIdx >= 0) {
        const sink = stations.find((s) => s.number === state.sink_station_target);
        const sinkX = sink ? sink.x_position : state.target_x;
        const sinkY = sink ? (sink.y_position || 0) : (state.target_y || 0);

        let phase2, phase3, phase4;
        let xTravelTime = 0, yTravelTime = 0;

        // ═══════════════════════════════════════════════════════════════════════════════════════════
        // 2D: Käytä movement_times.json arvoja (SAMA lähde kuin timer-pohjainen toteutus)
        // 3D: Käytä analyyttistä fysiikkaa (3D ei käytä timereita)
        // ═══════════════════════════════════════════════════════════════════════════════════════════
        if (tState.model !== '3D' && cachedMovementTimes) {
          const tId = String(tState.id);
          const fromNum = String(state.current_station);
          const toNum = String(state.sink_station_target);
          const mt = cachedMovementTimes.transporters?.[tId] || {};

          // PHASE 2: initial_delay (= device_delay tai extraWait, jo delay_up:ssa) + lift_s + dropping + drip
          // HUOM: device_delay EI lisätä erikseen, koska initial_delay sisältää sen
          const liftS = Number(mt.lift_s?.[fromNum]) || 0;
          const stationDroppingTime = Number(station.dropping_time) || 0;
          phase2 = (Number(state.initial_delay) || 0) + liftS + stationDroppingTime + dripDelay;

          // PHASE 3: travel_s[from][to]
          const travelS = Number(mt.travel_s?.[fromNum]?.[toNum]) || 0;
          phase3 = travelS;
          xTravelTime = travelS;

          // PHASE 4: drip_tray_delay + device_delay + sink_s
          const sinkStation = sink || station;
          const sinkDeviceDelay = Number(sinkStation.device_delay) || 0;
          const sinkS = Number(mt.sink_s?.[toNum]) || 0;
          phase4 = dripDelay + sinkDeviceDelay + sinkS;

          console.log(`[PHASE2-CALC] Station=${state.current_station} TIMER: initial_delay=${state.initial_delay?.toFixed(1)}s lift_s=${liftS.toFixed(1)}s dropping=${stationDroppingTime}s drip=${dripDelay}s TOTAL=${phase2.toFixed(1)}s`);
        } else {
          // 3D: analyyttinen fysiikka (ei muuttunut)
          const slowStart = (stationKind === 1) ? zSlowWet : zSlowDry;
          const slowEndStart = Math.max(0, zTotal - zSlowEnd);
          const safeDiv = (dist, speed) => (speed > 0 ? dist / speed : 0);

          const tSlowUp = safeDiv(Math.max(0, Math.min(slowStart, zTotal)), zSlowSpeed);
          const tFastUp = safeDiv(Math.max(0, slowEndStart - slowStart), zFastSpeed);
          const tSlowTop = safeDiv(Math.max(0, zTotal - slowEndStart), zSlowSpeed);
          const stationDroppingTime = Number(station.dropping_time) || 0;
          const tDrip = stationDroppingTime + dripDelay;
          phase2 = (Number(state.initial_delay) || 0) + tSlowUp + tFastUp + tSlowTop + tDrip;

          console.log(`[PHASE2-CALC] Station=${state.current_station} ANALYTICAL: initial_delay=${state.initial_delay?.toFixed(1)}s lift=${(tSlowUp+tFastUp+tSlowTop).toFixed(1)}s dropping=${stationDroppingTime}s drip_tray=${dripDelay}s TOTAL=${phase2.toFixed(1)}s`);

          // Helper: Calculate travel time with acceleration/deceleration
          const calculateTravelTime = (distance, maxSpeed, accelTime, decelTime) => {
            if (distance <= 0 || maxSpeed <= 0) return 0;
            const accelDist = 0.5 * maxSpeed * accelTime;
            const decelDist = 0.5 * maxSpeed * decelTime;
            if (distance <= accelDist + decelDist) {
              const ratio = distance / (accelDist + decelDist);
              return ratio * (accelTime + decelTime);
            } else {
              const cruiseDist = distance - accelDist - decelDist;
              const cruiseTime = cruiseDist / maxSpeed;
              return accelTime + cruiseTime + decelTime;
            }
          };

          const xDistance = Math.abs((sinkX || 0) - state.x_position);
          xTravelTime = calculateTravelTime(xDistance, vMax, tAcc, tDec);

          if (tState.model === "3D" && cfg.physics_3D) {
            const physics3D = cfg.physics_3D;
            const vMaxY = physics3D.y_max_speed_mm_s || 0;
            const tAccY = physics3D.y_acceleration_time_s || 0.001;
            const tDecY = physics3D.y_deceleration_time_s || 0.001;
            const yDistance = Math.abs((sinkY || 0) - (state.y_position || 0));
            yTravelTime = calculateTravelTime(yDistance, vMaxY, tAccY, tDecY);
          }

          phase3 = Math.max(xTravelTime, yTravelTime);

          const sinkStation = sink || station;
          const sinkDeviceDelay = Number(sinkStation.device_delay) || 0;
          const sinkOp = Number(sinkStation.operation) || 0;
          const sinkSlowStart = ((Number(sinkStation.kind) || 0) === 1) ? zSlowWet : zSlowDry;
          const safeDiv2 = safeDiv;
          const tDripSink = dripDelay;
          const tDelayDown = sinkDeviceDelay;
          const tFastDown = safeDiv2(Math.max(0, zTotal - sinkSlowStart), zFastSpeed);
          const tSlowDown = safeDiv2(Math.max(0, sinkSlowStart), zSlowSpeed);
          phase4 = tDripSink + tDelayDown + tFastDown + tSlowDown;
        }

        const total = phase2 + phase3 + phase4;
        
        console.log(`[TRANSFER-TIMING] B${state.pending_batch_id} ${state.current_station}→${state.sink_station_target}: phase2=${phase2.toFixed(1)}s phase3=${phase3.toFixed(1)}s phase4=${phase4.toFixed(1)}s TOTAL=${total.toFixed(1)}s`);
        
        // Nostovaihe: siirrä erä nostimelle, ÄLÄ muuta stagea.
        // Stage muutetaan VAIN sink completionissa (lasku kohteeseen).
        // Ajoitustiedot päivitetään visualisointia varten.
        const currentBatch = batches[targetIdx];
        console.log(`[TRANSFER DEBUG] B${state.pending_batch_id} currentStage=${currentBatch?.stage} → lift (stage unchanged)`);
        setBatchLocation(targetIdx, tState.id, {
          min_time_s: total,
          calc_time_s: total,
          max_time_s: 600,
          phase2_lift_s: phase2,
          phase3_travel_s: phase3,
          phase3_x_travel_s: xTravelTime,
          phase3_y_travel_s: yTravelTime,
          phase4_sink_s: phase4
        });
        
        // HUOM: Aikataulu luetaan schedules.json:sta (state machine kirjoittaa sinne)
        // Ei kirjoiteta CSV:tä erikseen - yksi totuuden lähde
        
        state.pending_batch_id = null;
        return true;
      }
      state.pending_batch_id = null;
      return false;
    };

    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    // x_drive_target CALCULATION - Must happen BEFORE movement logic!
    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    // DriveTarget = where the transporter CAN drive right now (within limits)
    // FinalTarget = where the transporter WANTS to go (task destination)
    //
    // RULES:
    // 1. DriveTarget must always be within limits
    // 2. If FinalTarget is within limits → DriveTarget = FinalTarget
    // 3. If FinalTarget is outside limits → DriveTarget = closest limit
    // 4. If current position is outside limits → DriveTarget = closest limit (drive back inside)
    {
      const xMin = state.x_min_drive_limit || 0;
      const xMax = state.x_max_drive_limit || 0;
      const xFinal = state.x_final_target || state.target_x || 0;
      const xPos = state.x_position || 0;
      
      let calculatedDriveTarget;
      
      // First priority: if outside limits, drive back inside
      if (xPos > xMax && xMax > 0) {
        calculatedDriveTarget = xMax;
      } else if (xPos < xMin && xMin > 0) {
        calculatedDriveTarget = xMin;
      }
      // Second: if FinalTarget is outside limits, drive to the limit
      else if (xFinal > xMax && xMax > 0) {
        calculatedDriveTarget = xMax;
      } else if (xFinal < xMin && xMin > 0) {
        calculatedDriveTarget = xMin;
      }
      // Otherwise: FinalTarget is within limits, drive there
      else {
        calculatedDriveTarget = xFinal;
      }
      
      state.x_drive_target = calculatedDriveTarget;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TIMER-POHJAINEN PHASE 1 vaakasiirto nostoasemalle (2D transportterit)
    // Käyttää movement_times.json travel_s esilaskettua aikaa.
    // X-position interpoloidaan lineaarisesti visualisointia varten.
    // ═══════════════════════════════════════════════════════════════════════════════
    if (state.phase === 1 && state.z_stage === 'timer_travel_phase1' && tState.model !== '3D') {
      state.z_timer = Math.max(0, state.z_timer - dt);
      const totalTime = state._travel_total_time || 1;
      const elapsed = totalTime - state.z_timer;
      const progress = Math.min(1, elapsed / totalTime);
      const fromX = state._travel_from_x ?? state.x_position;
      const toX = state._travel_to_x ?? (state.target_x || state.x_position);
      // Interpoloi x_position: fromX → toX, clamp drive-rajojen sisään
      let interpX = fromX + progress * (toX - fromX);
      const xMinP1 = state.x_min_drive_limit || 0;
      const xMaxP1 = state.x_max_drive_limit || 0;
      if (xMaxP1 > xMinP1) {
        interpX = Math.max(xMinP1, Math.min(xMaxP1, interpX));
      }
      state.x_position = interpX;
      state.velocity_x = progress < 1 ? vMax * 0.5 : 0;
      state.operation = 'travelling_to_lift';

      if (state.z_timer <= 0) {
        // Clamp myös lopullinen positio drive-rajojen sisään
        let finalX = toX;
        if (xMaxP1 > xMinP1) {
          finalX = Math.max(xMinP1, Math.min(xMaxP1, finalX));
        }
        // Tarkista onko nostin todella perillä (clamp saattoi pysäyttää ennen kohdetta)
        const ARRIVAL_TOL = 50; // mm toleranssi
        if (Math.abs(finalX - toX) > ARRIVAL_TOL) {
          // Nostin ei päässyt perille — drive limit estää. Jää odottamaan rajan vapautumista.
          state.x_position = finalX;
          state.z_timer = 0.1; // Pidä timer aktiivisena, tarkistetaan uudelleen seuraavalla tickillä
          state.velocity_x = 0;
          state.operation = 'waiting_for_clearance';
        } else {
          state.x_position = finalX;
          state.velocity_x = 0;
          console.log(`[TRAVEL-P1 DONE] T${tState.id} arrived at lift station ${state.lift_station_target} travel=${totalTime.toFixed(2)}s`);
          // Siirry delay_up -tilaan (sama kuin arriveLift)
          state.current_station = state.lift_station_target || state.current_station;
          const liftSt = stations.find((s) => s.number === state.lift_station_target) || {};
          const liftDevDelay = Number(liftSt.device_delay) || 0;
          let extraWait = 0;
          const unitAtLift2 = getUnitAtLocation(units, state.current_station);
          const batchAtStation = unitAtLift2 ? batches.find(b => b.batch_id === unitAtLift2.batch_id) : null;
          if (batchAtStation) {
            const elapsed2 = Math.max(0, (simTimeMs - (Number(batchAtStation.start_time) || 0)) / 1000);
            const minRequired = Number(batchAtStation.min_time_s) || 0;
            extraWait = Math.max(0, minRequired - elapsed2);
          }
          const initialDelay = extraWait > liftDevDelay ? extraWait : liftDevDelay;
          console.log(`[LIFT-DELAY] T${tState.id} Station=${state.current_station} deviceDelay=${liftDevDelay}s extraWait=${extraWait.toFixed(1)}s initialDelay=${initialDelay.toFixed(1)}s`);
          state.z_stage = 'delay_up';
          state.z_timer = initialDelay;
          state.initial_delay = initialDelay;
          state.operation = 'lifting_wait';
          state.velocity_z = 0;
          state.pending_batch_id = batchAtStation ? batchAtStation.batch_id : null;
        }
      }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TIMER-POHJAINEN PHASE 3 vaakasiirto laskuasemalle (2D transportterit)
    // Käyttää movement_times.json travel_s esilaskettua aikaa.
    // X-position interpoloidaan lineaarisesti visualisointia varten.
    // ═══════════════════════════════════════════════════════════════════════════════
    if (state.phase === 3 && state.z_stage === 'timer_travel' && tState.model !== "3D") {
      state.z_timer = Math.max(0, state.z_timer - dt);
      const totalTime = state._travel_total_time || 1;
      const elapsed = totalTime - state.z_timer;
      const progress = Math.min(1, elapsed / totalTime);
      const fromX = state._travel_from_x ?? state.x_position;
      const toX = state._travel_to_x ?? (state.target_x || state.x_position);
      // Interpoloi x_position: fromX → toX, clamp drive-rajojen sisään
      let interpX3 = fromX + progress * (toX - fromX);
      const xMinP3 = state.x_min_drive_limit || 0;
      const xMaxP3 = state.x_max_drive_limit || 0;
      if (xMaxP3 > xMinP3) {
        interpX3 = Math.max(xMinP3, Math.min(xMaxP3, interpX3));
      }
      state.x_position = interpX3;
      state.velocity_x = progress < 1 ? vMax * 0.5 : 0; // visuaalinen indikaattori
      state.operation = 'travelling';

      if (state.z_timer <= 0) {
        // Clamp lopullinen positio drive-rajojen sisään
        let finalX3 = toX;
        if (xMaxP3 > xMinP3) {
          finalX3 = Math.max(xMinP3, Math.min(xMaxP3, finalX3));
        }
        // Tarkista onko nostin todella perillä (clamp saattoi pysäyttää ennen kohdetta)
        const ARRIVAL_TOL3 = 50; // mm toleranssi
        if (Math.abs(finalX3 - toX) > ARRIVAL_TOL3) {
          // Nostin ei päässyt perille — drive limit estää. Jää odottamaan.
          state.x_position = finalX3;
          state.z_timer = 0.1; // Pidä timer aktiivisena
          state.velocity_x = 0;
          state.operation = 'waiting_for_clearance';
        } else {
          state.x_position = finalX3;
          state.velocity_x = 0;
          const phase3Duration = state.phase_start_time ? (simTimeMs - state.phase_start_time) / 1000 : 0;
          console.log(`[PHASE-TIMING] T${tState.id} phase3 ACTUAL=${phase3Duration.toFixed(1)}s (timer, expected=${totalTime.toFixed(1)}s)`);
          // Arrived at sink station
          state.current_station = state.sink_station_target || state.current_station;
          state.phase = 4; // sinking
          state.phase_start_time = simTimeMs;
          state.z_stage = 'idle'; // handleSink will start timer_sink from idle
          state.z_timer = 0;
          state.operation = 'sink_prep';
          console.log(`[TRAVEL DONE] T${tState.id} arrived at sink station ${state.current_station}`);
        }
      }
    }

    // Phase 1 ja Phase 3: 2D timer-pohjaiset käsiteltiin yllä, ohitetaan tässä
    // Analyyttinen fysiikka vain 3D-transporttereille tai jos timer ei ole käytössä
    const isMoving = 
      (state.phase === 1 && (tState.model === '3D' || state.z_stage !== 'timer_travel_phase1')) ||
      (state.phase === 3 && (tState.model === '3D' || state.z_stage !== 'timer_travel'));

    if (isMoving) {
      // Drive towards x_drive_target (already calculated above to respect limits)
      const driveTarget = state.x_drive_target || state.target_x;
      const finalTarget = state.target_x || 0;
      const xMin = state.x_min_drive_limit || 0;
      const xMax = state.x_max_drive_limit || 0;
      const xPos = state.x_position || 0;
      
      // ═══════════════════════════════════════════════════════════════════════════════════════════
      // ARRIVAL TOLERANCE CALCULATION
      // ═══════════════════════════════════════════════════════════════════════════════════════════
      // - If driveTarget == finalTarget → tolerance ±3 mm (centered on target)
      // - If driveTarget == x_max_limit → arrived when xPos >= max - 6 mm
      // - If driveTarget == x_min_limit → arrived when xPos <= min + 6 mm
      const ARRIVAL_TOLERANCE = 6; // mm
      
      let arrivedAtDriveTarget = false;
      
      if (driveTarget === finalTarget) {
        // Normal arrival: within ±3 mm of target
        arrivedAtDriveTarget = Math.abs(xPos - driveTarget) <= (ARRIVAL_TOLERANCE / 2);
      } else if (driveTarget === xMax && xMax > 0) {
        // Arrived at max limit: within 6 mm from the left side
        arrivedAtDriveTarget = xPos >= (xMax - ARRIVAL_TOLERANCE);
      } else if (driveTarget === xMin && xMin > 0) {
        // Arrived at min limit: within 6 mm from the right side
        arrivedAtDriveTarget = xPos <= (xMin + ARRIVAL_TOLERANCE);
      } else {
        // Fallback: standard tolerance check
        arrivedAtDriveTarget = Math.abs(xPos - driveTarget) <= (ARRIVAL_TOLERANCE / 2);
      }
      
      const dir = Math.sign(driveTarget - xPos);
      const remainingToDrive = Math.abs(driveTarget - xPos);
      const remainingToFinal = Math.abs(finalTarget - xPos);
      // For 3D transporters, also check Y arrival
      const remainingToFinalY = tState.model === "3D" ? Math.abs(state.target_y - state.y_position) : 0;
      const arrivedY = tState.model === "3D" ? remainingToFinalY < (ARRIVAL_TOLERANCE / 2) : true;
      const hasArrived = arrivedAtDriveTarget && arrivedY;

      if (hasArrived) {
        // Arrived at drive target (both X and Y for 3D)
        state.x_position = driveTarget;
        state.velocity_x = 0;
        if (tState.model === "3D") {
          state.y_position = state.target_y;
          state.velocity_y = 0;
        }

        // If driveTarget != target_x, emuloidaan "saapuminen" rajoille
        // Jos driveTarget == target_x, käyttäydytään kuten ennen
        if (driveTarget === state.target_x) {
          if (state.phase === 1) {
            // At lift station - only initialize delay once (skip if already in delay_up)
            if (state.z_stage !== 'delay_up') {
              state.current_station = state.lift_station_target || state.current_station;
              // Get device_delay from LIFT station
              const liftSt = stations.find((s) => s.number === state.lift_station_target) || {};
              const liftDevDelay = Number(liftSt.device_delay) || 0;
              let extraWait = 0;
              const unitAtLift3D = getUnitAtLocation(units, state.current_station);
              const batchAtStation = unitAtLift3D ? batches.find(b => b.batch_id === unitAtLift3D.batch_id) : null;
              if (batchAtStation) {
                const elapsed = Math.max(0, (simTimeMs - (Number(batchAtStation.start_time) || 0)) / 1000);
                const minRequired = Number(batchAtStation.min_time_s) || 0;
                extraWait = Math.max(0, minRequired - elapsed);
              }
              const initialDelay = extraWait > liftDevDelay ? extraWait : liftDevDelay;
              // ...existing code...
              state.phase = 1;
              state.z_stage = (tState.model === "3D") ? 'idle' : 'delay_up';
              state.z_timer = initialDelay;
              state.initial_delay = initialDelay;
              state.operation = 'lifting_wait';
              state.velocity_z = 0;
              state.pending_batch_id = batchAtStation ? batchAtStation.batch_id : null;
            }
            // else: already in delay_up, timer countdown happens elsewhere
          } else if (state.phase === 3) {
            // Arrived at sink station
            state.current_station = state.sink_station_target || state.current_station;
            state.phase = 4; // sinking
            state.z_stage = 'idle';
            state.z_timer = 0;
            state.operation = 'sink_prep';
          }
        } else {
          // Emuloidaan "saapuminen" rajoille: nostin jää odottamaan, kunnes raja vapautuu
          // Ei vaihdeta phasea, mutta pysäytetään liike
          state.velocity_x = 0;
          // Voit halutessasi lisätä tähän logiikkaa, esim. odotustila, logitus tms.
        }
      } else {
        // ANALYYTTINEN LIIKE (sama kuin scheduler)
        // Laske optimaalinen nopeus tälle tikiille
        const distance = remainingToDrive;
        
        // Kiihdytyksen/jarrutuksen aikana kuljettu matka
        const accelDist = 0.5 * vMax * tAcc;
        const decelDist = 0.5 * vMax * tDec;
        
        let targetVel;
        let accelPhase;
        
        if (distance <= accelDist + decelDist) {
          // Kolmio-profiili: ei ehditä täysnopeuteen
          // Maksimi saavutettu nopeus
          const vPeak = Math.sqrt(2 * distance * aAcc * aDec / (aAcc + aDec));
          targetVel = Math.min(vPeak, vMax);
          
          // Onko vielä kiihdyttämässä vai jo jarruttamassa?
          const accelDistToVPeak = (targetVel * targetVel) / (2 * aAcc);
          if (state.velocity_x < targetVel && distance > accelDistToVPeak) {
            accelPhase = 'accel';
            targetVel = state.velocity_x + aAcc * dt;
            targetVel = Math.min(targetVel, vPeak, vMax);
          } else {
            accelPhase = 'decel';
            // Jarrutusnopeus jotta pysähdytään perille
            const vNeeded = Math.sqrt(2 * aDec * distance);
            targetVel = Math.min(state.velocity_x, vNeeded);
            if (targetVel < 0.1) targetVel = 0;
          }
        } else {
          // Normaali: kiihdytys → cruise → jarrutus
          const brakeNeeded = (state.velocity_x * state.velocity_x) / (2 * aDec);
          
          if (distance > brakeNeeded + decelDist * 0.1) {
            // Voidaan vielä kiihdyttää tai ajaa täysillä
            if (state.velocity_x < vMax) {
              accelPhase = 'accel';
              targetVel = state.velocity_x + aAcc * dt;
              targetVel = Math.min(targetVel, vMax);
            } else {
              accelPhase = 'cruise';
              targetVel = vMax;
            }
          } else {
            // Aloita jarrutus
            accelPhase = 'decel';
            targetVel = state.velocity_x - aDec * dt;
            targetVel = Math.max(0, targetVel);
          }
        }
        
        // Laske matka tällä tikillä (keskimääräinen nopeus)
        const avgVel = (state.velocity_x + targetVel) / 2;
        const travel = avgVel * dt;
        
        // Check if arriving this tick
        if (travel >= distance || targetVel === 0) {
          // Snap to target
          if (driveTarget === finalTarget) {
            state.x_position = finalTarget;
          } else {
            state.x_position += dir * distance;
          }
          state.velocity_x = 0;
          
          if (arrivedY && driveTarget === finalTarget) {
            if (tState.model === "3D") {
              state.y_position = state.target_y;
              state.velocity_y = 0;
            }
            if (state.phase === 1) {
              arriveLift();
            } else {
              arriveSink();
            }
          }
        } else {
          // Continue moving
          state.x_position += dir * travel;
          state.velocity_x = targetVel;
        }
      }
    }

    // Y-axis movement for 3D transporters (parallel to X-axis movement)
    if (tState.model === "3D" && isMoving) {
      const physics3D = cfg.physics_3D || {};
      const vMaxY = physics3D.y_max_speed_mm_s || 0;
      const tAccY = physics3D.y_acceleration_time_s || 0.001;
      const tDecY = physics3D.y_deceleration_time_s || 0.001;
      const aAccY = vMaxY / tAccY;
      const aDecY = vMaxY / tDecY;

      const driveTargetY = state.y_drive_target || state.target_y;
      const dirY = Math.sign(driveTargetY - state.y_position);
      const remainingToDriveY = Math.abs(driveTargetY - state.y_position);
      const remainingToFinalY = Math.abs(state.target_y - state.y_position);

      if (remainingToFinalY >= 1e-3 && dirY !== 0) {
        // Decide acceleration or braking based on drive target
        const brakeDistanceY = (state.velocity_y * state.velocity_y) / (2 * (aDecY || 1));
        let accelY = aAccY;
        if (brakeDistanceY >= remainingToDriveY) {
          accelY = -aDecY;
        }

        // Update velocity
        let newVelY = state.velocity_y + accelY * dt;
        newVelY = Math.max(0, Math.min(vMaxY, newVelY));

        // If braking to stop at final target, snap to target
        if (newVelY === 0 && accelY < 0 && brakeDistanceY > 0 && remainingToFinalY < 1e-2) {
          state.y_position = state.target_y;
          state.velocity_y = 0;
        } else {
          const travelY = newVelY * dt;
          if (travelY >= remainingToFinalY) {
            // Snap to target
            state.y_position = state.target_y;
            state.velocity_y = 0;
          } else {
            // Continue moving toward target
            state.y_position += dirY * travelY;
            state.velocity_y = newVelY;
          }
        }
      } else {
        // Already at Y target
        state.y_position = state.target_y;
        state.velocity_y = 0;
      }
    }

    // Z-axis phases: 2 = lifting, 4 = sinking
    
    // 3D transporter Z-lift logic
    const handleLift3D = async () => {
      const zIdleHeight = physics.z_idle_height_mm || 100;
      const dripTrayDelay = physics.drip_tray_delay_s || 0;
      const catcherDelay = physics.catcher_delay_s || 0;
      const speedChangeLimit = (stationKind === 1) ? (physics.z_speed_change_limit_wet_mm || 800) : (physics.z_speed_change_limit_dry_mm || 300);

      if (state.z_stage === 'idle') {
        state.z_position = zIdleHeight;
        state.z_stage = 'drip_tray_delay_up';
        state.z_timer = dripTrayDelay;
        state.operation = 'lifting_wait';
      }

      if (state.z_stage === 'drip_tray_delay_up') {
        state.z_timer = Math.max(0, state.z_timer - dt);
        if (state.z_timer <= 0) {
          state.z_stage = 'fast_down_to_slow_end';
        }
        return;
      }

      // Fast down: z_idle_height → z_slow_end_distance
      if (state.z_stage === 'fast_down_to_slow_end') {
        const target = zSlowEnd;
        const remaining = state.z_position - target;
        const step = Math.min(Math.max(0, zFastSpeed * dt), remaining);
        state.z_position -= step;
        state.velocity_z = -zFastSpeed;
        if (remaining - step <= 1e-3) {
          state.z_stage = 'slow_down_to_bottom';
        }
        return;
      }

      // Slow down: z_slow_end → 0
      if (state.z_stage === 'slow_down_to_bottom') {
        const target = 0;
        const remaining = state.z_position - target;
        const step = Math.min(Math.max(0, zSlowSpeed * dt), remaining);
        state.z_position -= step;
        state.velocity_z = -zSlowSpeed;
        if (remaining - step <= 1e-3) {
          state.z_position = 0;
          state.z_stage = 'catcher_delay';
          state.z_timer = catcherDelay;
        }
        return;
      }

      if (state.z_stage === 'catcher_delay') {
        state.velocity_z = 0;
        state.z_timer = Math.max(0, state.z_timer - dt);
        if (state.z_timer <= 0) {
          state.z_stage = 'slow_up_to_change';
        }
        return;
      }

      // Slow up: 0 → speed_change_limit
      if (state.z_stage === 'slow_up_to_change') {
        const target = speedChangeLimit;
        const remaining = target - state.z_position;
        const step = Math.min(Math.max(0, zSlowSpeed * dt), remaining);
        state.z_position += step;
        state.velocity_z = zSlowSpeed;
        if (remaining - step <= 1e-3) {
          state.z_stage = 'fast_up_to_slow_end';
        }
        return;
      }

      // Fast up: speed_change_limit → (z_total - z_slow_end)
      if (state.z_stage === 'fast_up_to_slow_end') {
        const target = zTotal - zSlowEnd;
        const remaining = target - state.z_position;
        const step = Math.min(Math.max(0, zFastSpeed * dt), remaining);
        state.z_position += step;
        state.velocity_z = zFastSpeed;
        if (remaining - step <= 1e-3) {
          state.z_stage = 'slow_up_to_top';
        }
        return;
      }

      // Slow up: (z_total - z_slow_end) → z_total
      if (state.z_stage === 'slow_up_to_top') {
        const target = zTotal;
        const remaining = target - state.z_position;
        const step = Math.min(Math.max(0, zSlowSpeed * dt), remaining);
        state.z_position += step;
        state.velocity_z = zSlowSpeed;
        if (remaining - step <= 1e-3) {
          state.z_position = zTotal;
          state.z_stage = 'drip';
          state.z_timer = Number.isFinite(station.dropping_time) ? station.dropping_time : 0;
          state.operation = 'dripping';
        }
        return;
      }

      // Drip stage - use station dropping_time
      if (state.z_stage === 'drip') {
        state.velocity_z = 0;
        state.z_timer = Math.max(0, state.z_timer - dt);
        if (state.z_timer <= 0) {
          state.z_stage = 'drip_tray_delay_down';
          state.z_timer = dripTrayDelay;
        }
        return;
      }

      if (state.z_stage === 'drip_tray_delay_down') {
        state.velocity_z = 0;
        state.z_timer = Math.max(0, state.z_timer - dt);
        if (state.z_timer <= 0) {
          const phase2Duration = state.phase_start_time ? (simTimeMs - state.phase_start_time) / 1000 : 0;
          console.log(`[PHASE-TIMING] T${tState.id} phase2 ACTUAL=${phase2Duration.toFixed(1)}s`);
          state.z_stage = 'done';
          state.phase = 3;
          state.phase_start_time = simTimeMs;

          // Jos nostettiin start-asemalta, päivitä lastStartStationClearTime
          if (productionPlan && state.current_station === productionPlan.startStation) {
            lastStartStationClearTime = simTimeMs;
            console.log(`[PROD-3D] Start station cleared at ${lastStartStationClearTime}`);
          }

          const sink = stations.find((s) => s.number === state.sink_station_target);
          if (sink) {
            state.target_x = sink.x_position;
            state.x_final_target = sink.x_position;
            state.target_y = sink.y_position || 0;
            state.y_final_target = sink.y_position || 0;
            state.y_drive_target = sink.y_position || 0;
          }
          state.operation = 'lift_done';
        }
      }
    };

    // 3D transporter Z-sink logic
    const handleSink3D = async () => {
      const zIdleHeight = physics.z_idle_height_mm || 100;
      const dripTrayDelay = physics.drip_tray_delay_s || 0;
      const catcherDelay = physics.catcher_delay_s || 0;
      // KORJAUS: Käytä kohde-aseman (sink_station_target) tyyppiä
      const sinkStation3D = stations.find((s) => s.number === state.sink_station_target) || station;
      const sinkStationOp3D = Number(sinkStation3D.operation) || 0;
      const speedChangeLimit = ((Number(sinkStation3D.kind) || 0) === 1) ? (physics.z_speed_change_limit_wet_mm || 800) : (physics.z_speed_change_limit_dry_mm || 300);

      if (state.z_stage === 'idle') {
        // SAFETY CHECK: Do not lower if station is occupied
        const isOccupied = isLocationOccupied(units, state.sink_station_target);
        if (isOccupied) {
          if (Math.random() < 0.05) { // Throttle logs
             console.log(`[SINK BLOCKED] Transporter ${tState.id} waiting for station ${state.sink_station_target} to clear`);
          }
          state.operation = 'waiting_for_clearance';
          return;
        }

        state.z_position = zTotal;
        state.z_stage = 'drip_tray_delay_sink';
        state.z_timer = dripTrayDelay;
        state.operation = 'lowering_wait';
      }

      if (state.z_stage === 'drip_tray_delay_sink') {
        state.z_timer = Math.max(0, state.z_timer - dt);
        if (state.z_timer <= 0) {
          state.z_stage = 'slow_down_to_slow_end';
        }
        return;
      }

      // Slow down: z_total → (z_total - z_slow_end)
      if (state.z_stage === 'slow_down_to_slow_end') {
        const target = zTotal - zSlowEnd;
        const remaining = state.z_position - target;
        const step = Math.min(Math.max(0, zSlowSpeed * dt), remaining);
        state.z_position -= step;
        state.velocity_z = -zSlowSpeed;
        if (remaining - step <= 1e-3) {
          state.z_stage = 'fast_down_to_change';
        }
        return;
      }

      // Fast down: (z_total - z_slow_end) → speed_change_limit
      if (state.z_stage === 'fast_down_to_change') {
        const target = speedChangeLimit;
        const remaining = state.z_position - target;
        const step = Math.min(Math.max(0, zFastSpeed * dt), remaining);
        state.z_position -= step;
        state.velocity_z = -zFastSpeed;
        if (remaining - step <= 1e-3) {
          state.z_stage = 'slow_down_to_bottom';
        }
        return;
      }

      // Slow down: speed_change_limit → 0
      if (state.z_stage === 'slow_down_to_bottom') {
        const target = 0;
        const remaining = state.z_position - target;
        const step = Math.min(Math.max(0, zSlowSpeed * dt), remaining);
        state.z_position -= step;
        state.velocity_z = -zSlowSpeed;
        if (remaining - step <= 1e-3) {
          state.z_position = 0;
          state.z_stage = 'catcher_delay_sink';
          state.z_timer = catcherDelay;
        }
        return;
      }

      if (state.z_stage === 'catcher_delay_sink') {
        state.velocity_z = 0;
        state.z_timer = Math.max(0, state.z_timer - dt);
        if (state.z_timer <= 0) {
          state.z_stage = 'fast_up_to_idle';
        }
        return;
      }

      // Fast up: 0 → z_idle_height
      if (state.z_stage === 'fast_up_to_idle') {
        const target = zIdleHeight;
        const remaining = target - state.z_position;
        const step = Math.min(Math.max(0, zFastSpeed * dt), remaining);
        state.z_position += step;
        state.velocity_z = zFastSpeed;
        if (remaining - step <= 1e-3) {
          state.z_position = zIdleHeight;
          state.z_stage = 'done';
          state.phase = 0;
          state.current_station = state.sink_station_target || state.current_station;
          state.operation = 'idle';
          state.velocity_z = 0;
          state.x_drive_target = 0;
          state.x_final_target = 0;
          state.y_drive_target = 0;
          state.y_final_target = 0;

          // Move batch from transporter to station and advance program (3D)
          const unitOnT3D = getUnitAtLocation(units, tState.id);
          const batchIdx = unitOnT3D ? batches.findIndex(b => b.batch_id === unitOnT3D.batch_id) : -1;
          if (batchIdx >= 0) {
            const currentBatch = batches[batchIdx];

            // Toteuma: when sink finishes, record EntryTime to this station.
            const entryTime3D = simTimeMs / 1000;
            console.log(`[ACTUAL-ENTRY-3D] B${currentBatch.batch_id} Station=${state.current_station} EntryTime=${entryTime3D.toFixed(1)}s`);
            updateBatchActualCsv({
              batchId: currentBatch.batch_id,
              station: state.current_station,
              entryTimeSec: entryTime3D
            }).catch(() => null);

            // ═══════════════════════════════════════════════════════════════════════════════
            // TASK EXECUTION LOG: Complete task and write to CSV (3D)
            // ═══════════════════════════════════════════════════════════════════════════════
            try {
              const logLift3D = state.lift_station_target;
              const logSink3D = state.sink_station_target ?? state.current_station;
              const logKey3D = `${currentBatch.batch_id}|${logLift3D}|${logSink3D}`;
              
              const logEntry3D = taskExecutionLog.get(logKey3D);
              if (logEntry3D) {
                logEntry3D.actual_end = entryTime3D;
                appendTaskExecutionLog(logEntry3D);
                taskExecutionLog.delete(logKey3D);
              } else {
                // Ei löytynyt aloitusmerkintää - luo uusi suoraan snapshotin tiedoilla
                const plannedTimes3D = plannedTaskTimes.get(logKey3D);
                appendTaskExecutionLog({
                  transporter_id: tState.id,
                  batch_id: currentBatch.batch_id,
                  stage: plannedTimes3D?.stage ?? currentBatch.stage ?? 0,
                  lift_station: logLift3D,
                  sink_station: logSink3D,
                  planned_start: plannedTimes3D?.task_start_time ?? null,
                  planned_end: plannedTimes3D?.task_finished_time ?? null,
                  actual_start: null,
                  actual_end: entryTime3D
                });
              }
            } catch (logErr) {
              console.error('[TASK-EXEC-LOG] Error completing 3D task:', logErr.message);
            }

            const currentStageNum = Number(currentBatch.stage) || 0;
            const nextStage = (currentStageNum === 90 || currentStageNum === 0) ? 1 : currentStageNum + 1;
            const program = batchPrograms.get(currentBatch.batch_id) || [];
            const nextProgramStage = program[nextStage - 1];
            const nextMinTime = nextProgramStage ? parseTimeToSeconds(nextProgramStage.min_time) : currentBatch.min_time_s;
            const nextMaxTime = nextProgramStage ? parseTimeToSeconds(nextProgramStage.max_time) : currentBatch.max_time_s;
            // Käytä calc_time:a (suunniteltu aika) - ei min_time:a!
            const nextCalcTime = nextProgramStage ? parseTimeToSeconds(nextProgramStage.calc_time) : nextMaxTime;

            // POIKKEUS: no-treatment task → erä pysyy nykyisellä stagella
            if (state.current_task_is_no_treatment) {
              setBatchLocation(batchIdx, state.current_station, {
                start_time: simTimeMs
              });
              console.log(`[SINK DONE 3D] B${currentBatch.batch_id} no-treatment → station ${state.current_station}, stage stays ${currentBatch.stage}`);
            } else {
              setBatchLocation(batchIdx, state.current_station, {
                stage: nextStage,
                min_time_s: nextMinTime,
                max_time_s: nextMaxTime,
                calc_time_s: nextCalcTime,
                start_time: simTimeMs
              });
            }

            // No-treatment task: nollaa Unitin target jos primary-kohde (3D)
            if (state.current_task_is_no_treatment) {
              const unitOnSink3D = getUnitAtLocation(units, state.current_station);
              if (unitOnSink3D && unitOnSink3D.target && unitOnSink3D.target !== 'none') {
                if (state.current_task_is_primary_destination) {
                  console.log(`[SINK DONE 3D] Unit U${unitOnSink3D.unit_id} no-treatment+batch PRIMARY station ${state.current_station} → target 'none'`);
                  unitOnSink3D.target = 'none';
                } else {
                  console.log(`[SINK DONE 3D] Unit U${unitOnSink3D.unit_id} no-treatment+batch FALLBACK station ${state.current_station} → target '${unitOnSink3D.target}' KEPT`);
                }
              }
            }
          } else {
            // 3D: Ei batchiä nostimella — Unit-siirto (no-treatment)
            const emptyUnitOn3D = getUnitAtLocation(units, tState.id);
            if (emptyUnitOn3D) {
              emptyUnitOn3D.location = state.current_station;
              if (emptyUnitOn3D.target && emptyUnitOn3D.target !== 'none') {
                if (state.current_task_is_no_treatment) {
                  if (state.current_task_is_primary_destination) {
                    console.log(`[SINK DONE 3D] Unit U${emptyUnitOn3D.unit_id} no-treatment PRIMARY station ${state.current_station} → target 'none'`);
                    emptyUnitOn3D.target = 'none';
                  } else {
                    console.log(`[SINK DONE 3D] Unit U${emptyUnitOn3D.unit_id} no-treatment FALLBACK station ${state.current_station} → target '${emptyUnitOn3D.target}' KEPT`);
                  }
                } else {
                  console.log(`[SINK DONE 3D] Unit U${emptyUnitOn3D.unit_id} target '${emptyUnitOn3D.target}' → 'none'`);
                  emptyUnitOn3D.target = 'none';
                }
              }
              console.log(`[SINK DONE 3D] Moved empty unit U${emptyUnitOn3D.unit_id} from transporter ${tState.id} to station ${state.current_station}`);
            }
          }

          // Clear in-flight task metadata (3D)
          state.current_task_batch_id = null;
          state.current_task_lift_station_id = null;
          state.current_task_sink_station_id = null;
          state.current_task_est_finish_s = null;
          state.current_task_is_no_treatment = false;
          state.current_task_is_primary_destination = false;

          state.lift_station_target = null;
          state.sink_station_target = null;
        }
      }
    };

    // ═══════════════════════════════════════════════════════════════════════════
    // 2D transporter Z-lift logic — TIMER-POHJAINEN (movement_times.json)
    // Käyttää esilaskettuja aikoja suoraan, ei tick-by-tick fysiikkaa.
    // Z-position interpoloidaan lineaarisesti visualisointia varten.
    // ═══════════════════════════════════════════════════════════════════════════
    const handleLift = async () => {
      // timer_lift: yksi countdown koko nostolle
      if (state.z_stage === 'timer_lift') {
        state.z_timer = Math.max(0, state.z_timer - dt);
        const totalTime = state._lift_total_time || 1;
        const elapsed = totalTime - state.z_timer;

        // Segmentoitu Z-interpolointi: [devDelay: Z=0] → [lift_s: Z 0→zTotal] → [dropping+drip: Z=zTotal]
        const devDelay = state._lift_device_delay || 0;
        const mechTime = state._lift_mechanical || 1;
        const afterMech = devDelay + mechTime; // dropping + drip alkaa tästä

        if (elapsed < devDelay) {
          // Odottaa device_delay — Z paikallaan alhaalla
          state.z_position = 0;
          state.velocity_z = 0;
          state.operation = 'device_wait';
        } else if (elapsed < afterMech) {
          // Mekaaninen nosto — Z liikkuu 0 → zTotal
          const mechElapsed = elapsed - devDelay;
          const mechProgress = Math.min(1, mechElapsed / mechTime);
          state.z_position = mechProgress * zTotal;
          state.velocity_z = zSlowSpeed;
          state.operation = 'lifting';
        } else {
          // Dropping + drip_tray — Z paikallaan ylhäällä
          state.z_position = zTotal;
          state.velocity_z = 0;
          state.operation = elapsed < afterMech + (state._lift_dropping || 0) ? 'dripping' : 'drip_tray_closing';
        }

        if (state.z_timer <= 0) {
          state.z_position = zTotal;
          state.velocity_z = 0;
          const phase2Duration = state.phase_start_time ? (simTimeMs - state.phase_start_time) / 1000 : 0;
          console.log(`[PHASE-TIMING] T${tState.id} phase2 ACTUAL=${phase2Duration.toFixed(1)}s (timer, expected=${totalTime.toFixed(1)}s)`);
          state.z_stage = 'done';
          state.phase = 3; // move_to_sinking
          state.phase_start_time = simTimeMs;
          console.log(`[LIFT DONE] Transporter ${tState.id} moving to sink station ${state.sink_station_target}`);

          // Jos nostettiin start-asemalta, päivitä lastStartStationClearTime
          if (productionPlan && state.current_station === productionPlan.startStation) {
            lastStartStationClearTime = simTimeMs;
            console.log(`[PROD] Start station cleared at ${lastStartStationClearTime}`);
          }

          // Aseta vaakasiirron kohde
          const sink = stations.find((s) => s.number === state.sink_station_target);
          if (sink) {
            state.target_x = sink.x_position;
            state.x_final_target = sink.x_position;
          }

          // ── Timer-pohjainen phase 3: hae esilaskettu travel_s ──
          const fromNum = String(state.current_station);
          const toNum = String(state.sink_station_target);
          const tId = String(tState.id);
          let travelS = 0;
          if (cachedMovementTimes?.transporters?.[tId]?.travel_s?.[fromNum]?.[toNum] != null) {
            travelS = Number(cachedMovementTimes.transporters[tId].travel_s[fromNum][toNum]);
          }
          state._travel_total_time = travelS;
          state._travel_from_x = state.x_position;
          state._travel_to_x = sink ? sink.x_position : state.x_position;
          state.z_timer = travelS;
          state.z_stage = 'timer_travel';
          console.log(`[TRAVEL-TIMER] T${tState.id} ${fromNum}→${toNum} travel_s=${travelS.toFixed(2)}s`);
          state.operation = 'travelling';
        }
        return;
      }

      // Fallback: vanha z_stage arvo → alusta timer_lift
      // (ei pitäisi tapahtua normaalissa käytössä)
      if (state.z_stage !== 'timer_lift' && state.z_stage !== 'done') {
        console.warn(`[LIFT] T${tState.id} unexpected z_stage='${state.z_stage}' in phase 2, forcing timer_lift`);
        const fromNum = String(state.lift_station_target || state.current_station);
        const tId = String(tState.id);
        let liftS = 0;
        if (cachedMovementTimes?.transporters?.[tId]?.lift_s?.[fromNum] != null) {
          liftS = Number(cachedMovementTimes.transporters[tId].lift_s[fromNum]);
        }
        const liftDevDelay = Number(station.device_delay) || 0;
        const droppingTime = Number(station.dropping_time) || 0;
        const totalLift = liftS + liftDevDelay + droppingTime + dripDelay;
        state._lift_total_time = totalLift;
        state._lift_device_delay = liftDevDelay;
        state._lift_mechanical = liftS;
        state._lift_dropping = droppingTime;
        state._lift_drip = dripDelay;
        state.z_timer = totalLift;
        state.z_stage = 'timer_lift';
      }
    };

    // ═══════════════════════════════════════════════════════════════════════════
    // 2D transporter Z-sink logic — TIMER-POHJAINEN (movement_times.json)
    // Käyttää esilaskettuja aikoja suoraan, ei tick-by-tick fysiikkaa.
    // Z-position interpoloidaan lineaarisesti visualisointia varten.
    // ═══════════════════════════════════════════════════════════════════════════
    const handleSink = async () => {
      // Alusta timer_sink idle-tilasta
      if (state.z_stage === 'idle') {
        // SAFETY CHECK: ei lasketa jos asema varattu
        const isOccupied = isLocationOccupied(units, state.sink_station_target);
        if (isOccupied) {
          if (Math.random() < 0.05) {
            console.log(`[SINK BLOCKED] Transporter ${tState.id} waiting for station ${state.sink_station_target} to clear`);
          }
          state.operation = 'waiting_for_clearance';
          return;
        }

        // Hae esilaskettu sink-aika + viiveet
        const sinkStation = stations.find((s) => s.number === state.sink_station_target) || station;
        const sinkDeviceDelay = Number(sinkStation.device_delay) || 0;
        const toNum = String(state.sink_station_target);
        const tId = String(tState.id);
        let sinkS = 0;
        if (cachedMovementTimes?.transporters?.[tId]?.sink_s?.[toNum] != null) {
          sinkS = Number(cachedMovementTimes.transporters[tId].sink_s[toNum]);
        }
        // Kokonaisaika = drip_tray_delay + device_delay + mekaaninen lasku
        const totalSink = dripDelay + sinkDeviceDelay + sinkS;
        state._sink_total_time = totalSink;
        // Komponentit segmentoituun Z-interpolointiin
        state._sink_drip = dripDelay;
        state._sink_device_delay = sinkDeviceDelay;
        state._sink_mechanical = sinkS;
        state.z_timer = totalSink;
        state.z_stage = 'timer_sink';
        state.operation = 'drip_tray_wait';
        console.log(`[SINK-TIMER] T${tState.id} station=${toNum} sink_s=${sinkS.toFixed(2)}s drip=${dripDelay}s devDelay=${sinkDeviceDelay}s TOTAL=${totalSink.toFixed(2)}s`);
      }

      // timer_sink: yksi countdown koko laskulle
      if (state.z_stage === 'timer_sink') {
        state.z_timer = Math.max(0, state.z_timer - dt);
        const totalTime = state._sink_total_time || 1;
        const elapsed = totalTime - state.z_timer;

        // Segmentoitu Z-interpolointi: [drip: Z=zTotal] → [devDelay: Z=zTotal] → [sink_s: Z zTotal→0]
        const dripWait = state._sink_drip || 0;
        const devWait = state._sink_device_delay || 0;
        const waitTotal = dripWait + devWait;
        const mechTime = state._sink_mechanical || 1;

        if (elapsed < dripWait) {
          // Tippakourun avaus — Z paikallaan ylhäällä
          state.z_position = zTotal;
          state.velocity_z = 0;
          state.operation = 'drip_tray_wait';
        } else if (elapsed < waitTotal) {
          // Device delay — Z paikallaan ylhäällä
          state.z_position = zTotal;
          state.velocity_z = 0;
          state.operation = 'device_wait';
        } else {
          // Mekaaninen lasku — Z liikkuu zTotal → 0
          const mechElapsed = elapsed - waitTotal;
          const mechProgress = Math.min(1, mechElapsed / mechTime);
          state.z_position = zTotal * (1 - mechProgress);
          state.velocity_z = -zSlowSpeed;
          state.operation = 'sinking';
        }

        if (state.z_timer <= 0) {
          state.z_position = 0;
          state.velocity_z = 0;
          const phase4Duration = state.phase_start_time ? (simTimeMs - state.phase_start_time) / 1000 : 0;
          console.log(`[PHASE-TIMING] T${tState.id} phase4 ACTUAL=${phase4Duration.toFixed(1)}s (timer, expected=${totalTime.toFixed(1)}s)`);
          console.log(`[PHASE CHANGE] T${tState.id} setting phase=0 from phase=${state.phase}`);
          state.z_stage = 'done';
          state.phase = 0; // idle
          state.current_station = state.sink_station_target || state.current_station;
          state.operation = 'idle';
          state.x_drive_target = 0;
          state.x_final_target = 0;

          // Task completed: clear in-flight task metadata
          const completedIsNoTreatment = state.current_task_is_no_treatment || false;
          const completedIsPrimaryDest = state.current_task_is_primary_destination || false;
          state.current_task_batch_id = null;
          state.current_task_lift_station_id = null;
          state.current_task_sink_station_id = null;
          state.current_task_est_finish_s = null;
          state.current_task_is_no_treatment = false;
          state.current_task_is_primary_destination = false;

          // Move batch from transporter to station and advance program
          console.log(`[SINK DEBUG] T${tState.id} looking for batch, units:`, units.map(u => `U${u.unit_id}@${u.location}(B${u.batch_id})`).join(' '));
          const unitOnT2D = getUnitAtLocation(units, tState.id);
          const batchIdx = unitOnT2D ? batches.findIndex(b => b.batch_id === unitOnT2D.batch_id) : -1;
          console.log(`[SINK DONE] Looking for batch on transporter ${tState.id}, found index: ${batchIdx}`);
          if (batchIdx >= 0) {
            console.log(`[SINK DONE] Moving batch ${batches[batchIdx].batch_id} from transporter ${tState.id} to station ${state.current_station}`);
            const currentBatch = batches[batchIdx];

            // Toteuma: when sink finishes, record EntryTime to this station.
            const entryTime = simTimeMs / 1000;
            console.log(`[ACTUAL-ENTRY] B${currentBatch.batch_id} Station=${state.current_station} EntryTime=${entryTime.toFixed(1)}s`);
            updateBatchActualCsv({
              batchId: currentBatch.batch_id,
              station: state.current_station,
              entryTimeSec: entryTime
            }).catch(() => null);

            // ═══════════════════════════════════════════════════════════════════════════════
            // TASK EXECUTION LOG: Complete task and write to CSV
            // ═══════════════════════════════════════════════════════════════════════════════
            try {
              const logLift = state.lift_station_target;
              const logSink = state.sink_station_target ?? state.current_station;
              const logKey = `${currentBatch.batch_id}|${logLift}|${logSink}`;
              
              const logEntry = taskExecutionLog.get(logKey);
              if (logEntry) {
                logEntry.actual_end = entryTime;
                appendTaskExecutionLog(logEntry);
                taskExecutionLog.delete(logKey);
              } else {
                // Ei löytynyt aloitusmerkintää - luo uusi suoraan snapshotin tiedoilla
                const plannedTimes = plannedTaskTimes.get(logKey);
                appendTaskExecutionLog({
                  transporter_id: tState.id,
                  batch_id: currentBatch.batch_id,
                  stage: plannedTimes?.stage ?? currentBatch.stage ?? 0,
                  lift_station: logLift,
                  sink_station: logSink,
                  planned_start: plannedTimes?.task_start_time ?? null,
                  planned_end: plannedTimes?.task_finished_time ?? null,
                  actual_start: null,
                  actual_end: entryTime
                });
              }
            } catch (logErr) {
              console.error('[TASK-EXEC-LOG] Error completing task:', logErr.message);
            }

            // If batch is at stage 90 (loaded), next stage is 1.
            // If batch is at stage 0 (start), next stage is 1.
            // Otherwise increment.
            // POIKKEUS: no-treatment task → erä pysyy nykyisellä stagella (ei käsittelyä)
            if (completedIsNoTreatment) {
              // No-treatment: erä siirretään mutta stage/ajat eivät muutu
              setBatchLocation(batchIdx, state.current_station, {
                start_time: simTimeMs
              });
              console.log(`[SINK DONE] B${currentBatch.batch_id} no-treatment → station ${state.current_station}, stage stays ${currentBatch.stage}`);
            } else {
            const currentStageNum = Number(currentBatch.stage) || 0;
            const nextStage = (currentStageNum === 90 || currentStageNum === 0) ? 1 : currentStageNum + 1;
            // Get program from pre-loaded batchPrograms map
            const program = batchPrograms.get(currentBatch.batch_id) || [];
            const nextProgramStage = program[nextStage - 1]; // program is 0-indexed, stage is 1-indexed
            const nextMinTime = nextProgramStage ? parseTimeToSeconds(nextProgramStage.min_time) : currentBatch.min_time_s;
            const nextMaxTime = nextProgramStage ? parseTimeToSeconds(nextProgramStage.max_time) : currentBatch.max_time_s;
            // Käytä calc_time:a (suunniteltu aika) - ei min_time:a!
            const nextCalcTime = nextProgramStage ? parseTimeToSeconds(nextProgramStage.calc_time) : nextMaxTime;
            
              setBatchLocation(batchIdx, state.current_station, {
                stage: nextStage,
                min_time_s: nextMinTime,
                max_time_s: nextMaxTime,
                calc_time_s: nextCalcTime,
                start_time: simTimeMs // keep explicit for clarity even though setBatchLocation sets on change
              });
            }

            // Kun Unit on tuonut erän unloading-asemalle → target = 'none'
            const sinkStation = stations.find(s => s.number === state.current_station);
            const sinkOp = sinkStation ? (Number(sinkStation.operation) || 0) : 0;
            if (UNLOADING_STATION_OPS.has(sinkOp)) {
              const unitOnSink = getUnitAtLocation(units, state.current_station);
              if (unitOnSink && unitOnSink.target === 'to_unloading') {
                console.log(`[SINK DONE] Unit U${unitOnSink.unit_id} arrived at unloading station ${state.current_station} → target 'none'`);
                unitOnSink.target = 'none';
              }
            }

            // No-treatment task: nollaa Unitin target jos primary-kohde
            if (completedIsNoTreatment) {
              const unitOnSink = getUnitAtLocation(units, state.current_station);
              if (unitOnSink && unitOnSink.target && unitOnSink.target !== 'none') {
                if (completedIsPrimaryDest) {
                  console.log(`[SINK DONE] Unit U${unitOnSink.unit_id} no-treatment+batch PRIMARY station ${state.current_station} → target 'none'`);
                  unitOnSink.target = 'none';
                } else {
                  console.log(`[SINK DONE] Unit U${unitOnSink.unit_id} no-treatment+batch FALLBACK station ${state.current_station} → target '${unitOnSink.target}' KEPT`);
                }
              }
            }
          } else {
            // Ei batchiä nostimella — mutta Unit voi silti olla (tyhjä Unit -siirto)
            const emptyUnitOnT = getUnitAtLocation(units, tState.id);
            if (emptyUnitOnT) {
              emptyUnitOnT.location = state.current_station;
              // Nollaa target kun Unit on saapunut kohteeseen
              if (emptyUnitOnT.target && emptyUnitOnT.target !== 'none') {
                if (completedIsNoTreatment) {
                  // to_avoid: aina 'none' kohteeseen saavuttaessa (väistö tehty)
                  if (emptyUnitOnT.target === 'to_avoid') {
                    console.log(`[SINK DONE] Unit U${emptyUnitOnT.unit_id} to_avoid DONE at station ${state.current_station} → target 'none'`);
                    emptyUnitOnT.target = 'none';
                  }
                  // No-treatment task: target → 'none' VAIN jos ensisijainen asema
                  else if (completedIsPrimaryDest) {
                    console.log(`[SINK DONE] Unit U${emptyUnitOnT.unit_id} no-treatment PRIMARY station ${state.current_station} → target 'none'`);
                    emptyUnitOnT.target = 'none';
                  } else {
                    console.log(`[SINK DONE] Unit U${emptyUnitOnT.unit_id} no-treatment FALLBACK station ${state.current_station} → target '${emptyUnitOnT.target}' KEPT`);
                  }
                } else {
                  // Muu siirto: alkuperäinen logiikka (asematyypin mukaan)
                  const destStation = stations.find(s => s.number === state.current_station);
                  const destOp = destStation ? (Number(destStation.operation) || 0) : 0;
                  if (emptyUnitOnT.target === 'to_loading' && !LOADING_STATION_OPS.has(destOp)) {
                    console.log(`[SINK DONE] Unit U${emptyUnitOnT.unit_id} target '${emptyUnitOnT.target}' KEPT (station ${state.current_station} type=${destOp}, not loading)`);
                  } else if (emptyUnitOnT.target === 'to_unloading' && !UNLOADING_STATION_OPS.has(destOp)) {
                    console.log(`[SINK DONE] Unit U${emptyUnitOnT.unit_id} target '${emptyUnitOnT.target}' KEPT (station ${state.current_station} type=${destOp}, not unloading)`);
                  } else {
                    console.log(`[SINK DONE] Unit U${emptyUnitOnT.unit_id} target '${emptyUnitOnT.target}' → 'none' (arrived at destination station ${state.current_station})`);
                    emptyUnitOnT.target = 'none';
                  }
                }
              }
              console.log(`[SINK DONE] Moved empty unit U${emptyUnitOnT.unit_id} from transporter ${tState.id} to station ${state.current_station}`);
              batchesChanged = true; // Triggeröi UI-päivitys
            } else {
              console.log(`[SINK DONE] No unit or batch found on transporter ${tState.id}. Units:`, units.map(u => ({uid: u.unit_id, loc: u.location, bid: u.batch_id})));
            }
          }
        }
      }
    };

    // Use 3D Z-logic for 3D transporters, 2D Z-logic for 2D transporters
    if (state.phase === 2) {
      if (tState.model === "3D") {
        await handleLift3D();
      } else {
        await handleLift();
      }
    } else if (state.phase === 4) {
      if (tState.model === "3D") {
        await handleSink3D();
      } else {
        await handleSink();
      }
    } else if (state.phase === 1) {
      const atLift = state.current_station === state.lift_station_target
        && Math.abs((state.target_x || 0) - (state.x_position || 0)) < 1e-3;

      // Debug: log atLift check when at position but station mismatch
      if (!atLift && Math.abs((state.target_x || 0) - (state.x_position || 0)) < 1e-3) {
        console.log(`[ATLIFT-DEBUG] T${tState.id} atLift=false BUT at position! current_station=${state.current_station} lift_station_target=${state.lift_station_target} x=${state.x_position} target_x=${state.target_x}`);
      }

      if (!atLift) {
        // Still moving horizontally; don't start lift timing yet
        state.z_stage = 'idle';
        state.z_timer = 0;
        state.velocity_z = 0;
      } else if (state.z_stage === 'delay_up' || (tState.model === "3D" && state.z_stage === 'idle')) {
        // Countdown once actually at lift (2D uses 'delay_up', 3D uses 'idle')
        const oldTimer = state.z_timer;
        state.z_timer = Math.max(0, state.z_timer - dt);
        console.log(`[TIMER-DEBUG] T${tState.id} z_timer=${oldTimer.toFixed(3)} -> ${state.z_timer.toFixed(3)} dt=${dt.toFixed(3)} z_stage=${state.z_stage}`);
        if (state.z_timer <= 0) {
          // Toteuma: when lift starts, record ExitTime from the lift station.
          try {
            const batchId = state.pending_batch_id != null
              ? state.pending_batch_id
              : (getUnitAtLocation(units, state.current_station)?.batch_id ?? null);
            if (batchId != null && state.current_station != null) {
              console.log(`[ACTUAL-EXIT] B${batchId} Station=${state.current_station} ExitTime=${(simTimeMs/1000).toFixed(1)}s`);
              updateBatchActualCsv({
                batchId,
                station: state.current_station,
                exitTimeSec: simTimeMs / 1000
              }).catch(() => null);
            }
          } catch (_) {
            // Non-fatal
          }

          await transferPendingBatchToTransporter();
          state.phase_start_time = simTimeMs;  // Store phase start time
          console.log(`[PHASE-SHIFT] T${tState.id} phase 1→2 (lifting) at simTime=${(simTimeMs/1000).toFixed(1)}s`);
          
          // ═══════════════════════════════════════════════════════════════════════════════
          // TASK EXECUTION LOG: Record task start with planned times from snapshot
          // ═══════════════════════════════════════════════════════════════════════════════
          try {
            const logBatchId = state.current_task_batch_id ?? state.pending_batch_id
              ?? (getUnitAtLocation(units, tState.id)?.batch_id ?? null);
            const liftStation = state.lift_station_target;
            const sinkStation = state.sink_station_target;
            
            if (logBatchId != null && liftStation != null && sinkStation != null) {
              const logKey = `${logBatchId}|${liftStation}|${sinkStation}`;
              
              // Hae suunnitellut ajat snapshotista (plannedTaskTimes Map)
              const plannedTimes = plannedTaskTimes.get(logKey);
              const currentBatch = batches.find(b => b.batch_id === logBatchId);
              const stage = plannedTimes?.stage ?? currentBatch?.stage ?? 0;
              
              taskExecutionLog.set(logKey, {
                transporter_id: tState.id,
                batch_id: logBatchId,
                stage: stage,
                lift_station: liftStation,
                sink_station: sinkStation,
                planned_start: plannedTimes?.task_start_time ?? null,
                planned_end: plannedTimes?.task_finished_time ?? null,
                actual_start: simTimeMs / 1000,
                actual_end: null
              });
              console.log(`[TASK-EXEC-LOG] Started: B${logBatchId} ${liftStation}→${sinkStation} planned=${plannedTimes?.task_start_time?.toFixed(1) ?? '?'}s actual=${(simTimeMs/1000).toFixed(1)}s`);
            }
          } catch (logErr) {
            console.error('[TASK-EXEC-LOG] Error recording task start:', logErr.message);
          }
          
          state.phase = 2;
          if (tState.model === "3D") {
            state.z_stage = 'idle'; // 3D uses handleLift3D
          } else {
            // Timer-pohjainen nosto: hae esilaskettu aika movement_times.json:sta
            const fromNum = String(state.lift_station_target || state.current_station);
            const tId = String(tState.id);
            let liftS = 0;
            if (cachedMovementTimes?.transporters?.[tId]?.lift_s?.[fromNum] != null) {
              liftS = Number(cachedMovementTimes.transporters[tId].lift_s[fromNum]);
            }
            // HUOM: device_delay on jo kulutettu delay_up vaiheessa (phase 1)
            // timer_lift sisältää VAIN mekaanisen noston + dropping + drip
            const droppingTime = Number(station.dropping_time) || 0;
            const totalLift = liftS + droppingTime + dripDelay;
            state._lift_total_time = totalLift;
            // Komponentit segmentoituun Z-interpolointiin
            state._lift_device_delay = 0; // delay_up jo käsitteli
            state._lift_mechanical = liftS;
            state._lift_dropping = droppingTime;
            state._lift_drip = dripDelay;
            state.z_timer = totalLift;
            state.z_stage = 'timer_lift';
            console.log(`[LIFT-TIMER] T${tState.id} station=${fromNum} lift_s=${liftS.toFixed(2)}s dropping=${droppingTime}s drip=${dripDelay}s TOTAL=${totalLift.toFixed(2)}s (devDelay served in delay_up)`);
          }
          state.operation = 'lifting_start';
        }
      } else {
        // At lift but delay not started yet - initialize it
        arriveLift();
      }
    } else if (state.phase === 3) {
      // Phase 3 (vaakasiirto laskuasemalle): ÄLÄ nollaa z_stage/z_timer!
      // Timer-pohjainen travel käyttää z_stage='timer_travel' ja z_timer countdown.
      // Jos nollataan tässä, timer_travel ei koskaan toimi ja
      // analyyttinen fysiikka hoitaa liikkeen eri ajalla → schedule-ero.
      // Pidetään z_stage ja z_timer ennallaan.
    } else {
      // Idle fallback (phase 0 tai tuntematon)
      state.z_stage = 'idle';
      state.z_timer = 0;
      state.velocity_z = 0;
    }

    // Update current_station to nearest station after all movement
    updateCurrentStation();

    // x_final_target: show final x target only during horizontal movement (phase 1 or 3), otherwise zero
    if (state.phase !== 1 && state.phase !== 3) {
      state.x_final_target = 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    // IDLE CORRECTION MOVEMENT - Drive back inside limits when in idle state (phase 0)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    // Only execute when:
    // - status = 3 (automatic-idle)
    // - phase = 0 (idle, waiting for task)
    // - position is outside limits (need to move back inside)
    if (state.status === 3 && state.phase === 0) {
      const xPos = state.x_position || 0;
      const xMin = state.x_min_drive_limit || 0;
      const xMax = state.x_max_drive_limit || 0;
      const IDLE_ARRIVAL_TOLERANCE = 6; // mm - tolerance is INSIDE the limits
      
      // Check if outside limits
      const outsideMax = xMax > 0 && xPos > xMax;
      const outsideMin = xMin > 0 && xPos < xMin;
      const outsideLimits = outsideMax || outsideMin;
      
      // Arrived = position is INSIDE the limits (within tolerance zone inside the boundary)
      // For min limit: arrived when xPos >= xMin AND xPos <= xMin + tolerance
      // For max limit: arrived when xPos <= xMax AND xPos >= xMax - tolerance
      // If outside, we have NOT arrived - must keep moving until inside
      const insideMinZone = xMin > 0 && xPos >= xMin && xPos <= (xMin + IDLE_ARRIVAL_TOLERANCE);
      const insideMaxZone = xMax > 0 && xPos <= xMax && xPos >= (xMax - IDLE_ARRIVAL_TOLERANCE);
      const arrivedAtLimit = insideMinZone || insideMaxZone;
      
      if (outsideLimits && state.x_drive_target !== 0) {
        const dir = Math.sign(state.x_drive_target - xPos);
        const remaining = Math.abs(state.x_drive_target - xPos);
        
        // Simple proportional speed based on distance (with velocity limits)
        const brakeDistance = (state.velocity_x * state.velocity_x) / (2 * (aDec || 1));
        let accel = aAcc;
        if (brakeDistance >= remaining) {
          accel = -aDec;
        }
        
        // Update velocity
        let newVel = Math.abs(state.velocity_x) + accel * dt;
        newVel = Math.max(0, Math.min(vMax, newVel));
        
        const travel = newVel * dt;
        if (travel >= remaining || remaining < 1) {
          // Snap to drive target (which is on the limit)
          state.x_position = state.x_drive_target;
          state.velocity_x = 0;
        } else {
          state.x_position += dir * travel;
          state.velocity_x = dir * newVel;
        }
      } else if (!outsideLimits) {
        // Inside limits - just stop any correction movement
        state.velocity_x = 0;
      }
    }

    return { ...tState, state };
  }));

  // DEBUG: Check if z_timer was preserved
  const t2Updated = updatedTransporters.find(t => t.id === 2);
  if (t2Updated && t2Updated.state.phase === 1) {
    console.log(`[STATE-DEBUG] T2 after update: z_timer=${t2Updated.state.z_timer?.toFixed(3)} z_stage=${t2Updated.state.z_stage}`);
  }

  // VAIHE 2: Tallenna tasks TIEDOSTOON (tilakone omistaa, server voi poistaa vanhentuneita)
  if (tasksModified) {
    await saveTransporterTasks(transporterTasks);
  }

  // Päivitä muistissa oleva tila (SERVER omistaa vain transporters!)
  runtimeState.transporters = updatedTransporters;
  
  // ═══════════════════════════════════════════════════════════════════════════════
  // POIKITTAISSIIRTOKULJETTIMET - Erillinen osio nostinlogiikasta
  // ═══════════════════════════════════════════════════════════════════════════════
  // Tarkkaillaan eriä jotka ovat poikittaissiirtoasemilla (type 10/11).
  // Kun puolet CalcTime:sta on kulunut, siirretään erän lokaatio "toiseen päähän"
  // (saman ryhmän asema joka on samalla linjalla kuin seuraava ohjelma-askel).
  // ═══════════════════════════════════════════════════════════════════════════════
  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];
    if (!batch) continue;
    const batchUnitLoc = getBatchLocation(units, batch.batch_id);
    if (batchUnitLoc == null || batchUnitLoc < 100) continue; // Ohita erät nostimissa
    
    const batchStation = stations.find(s => s.number === batchUnitLoc);
    if (!batchStation) continue;
    
    // Tarkista onko asema poikittaissiirtokuljetin
    if (!scheduler.isCrossTransporterOp(batchStation.operation)) continue;
    
    // Laske kuinka kauan erä on ollut asemalla
    const startTime = batch.start_time || 0;
    const elapsedMs = simTimeMs - startTime;
    const calcTimeMs = (batch.calc_time_s || 0) * 1000;
    
    // Jos puolet CalcTime:sta on kulunut, siirrä lokaatio toiseen päähän
    if (calcTimeMs > 0 && elapsedMs >= calcTimeMs / 2) {
      // Etsi seuraava ohjelma-askel
      const program = batchPrograms.get(batch.batch_id) || [];
      const currentStage = batch.stage || 0;
      const nextProgramStage = program[currentStage]; // currentStage on 1-indexed, joten [currentStage] on seuraava
      
      if (nextProgramStage) {
        const nextStationNum = parseInt(nextProgramStage.min_station, 10);
        const nextStation = stations.find(s => s.number === nextStationNum);
        
        if (nextStation) {
          // Etsi poikittaissiirtokuljettimen toinen pää (samalla linjalla kuin seuraava asema)
          const crossEndStation = scheduler.findCrossTransporterEndStation(
            batchStation, 
            nextStation, 
            stations
          );
          
          if (crossEndStation && crossEndStation.number !== batchUnitLoc) {
            console.log(`[CROSS-TRANSFER] B${batch.batch_id} halfway through CalcTime (${(elapsedMs/1000).toFixed(1)}s / ${(calcTimeMs/1000).toFixed(1)}s), transferring: ${batchUnitLoc} → ${crossEndStation.number}`);
            // Päivitä Unit-sijainti (source of truth)
            const unit = getUnitByBatchId(units, batch.batch_id);
            if (unit) unit.location = crossEndStation.number;
            batch.location = crossEndStation.number;  // shadow-kenttä
            batchesChanged = true;
          }
        }
      }
    }
  }

  // VAIHE 2: Tallenna batches ja units TIEDOSTOON (server päivittää location/stage/calc_time)
  if (batchesChanged) {
    await saveBatches({ batches });
    await saveUnits(units);
  }
  
  // Tallenna tiedostoihin (tick:n lopussa visualisointia varten)
  await saveRuntimeState(); // Tallentaa VAIN transporter_states.json

  // Check for delayed batches (treatment time exceeded but not picked up)
  const currentTimeSec = simTimeMs / 1000;
  let hasDelayedBatches = false;
  const transporter = transportersCfg[0];
  
  if (transporter) {
    for (let i = 0; i < batches.length; i++) {
      const batch = batches[i];
      const schedule = (batch && schedulesByBatchId && schedulesByBatchId[batch.batch_id]) || (batch && batch.schedule);
      if (batch && schedule && schedule.stages && schedule.stages.length > 0) {
        // Find current stage in schedule
        const currentStage = schedule.stages.find(s => s.stage === batch.stage);
        const delayCheckLoc = getBatchLocation(units, batch.batch_id);
        if (currentStage && delayCheckLoc === currentStage.station) {
          // Check if exit time has been exceeded (batch should have been picked up already)
          const exitTimeExceeded = currentTimeSec > currentStage.exit_time_s;
          
          if (exitTimeExceeded) {
            // Batch is delayed - recalculate every second
            // Check if at least 1 second has passed since last recalculation
            const lastCalcTime = schedule.calculated_at || 0;
            const timeSinceLastCalc = currentTimeSec - lastCalcTime;
            
            if (timeSinceLastCalc >= 1.0) {
              // Recalculate with ExitTime = AikaNyt + 1 sekunti
              hasDelayedBatches = true;
              batchesChanged = true;
              batches[i] = { ...batch, scheduleNeedsRecalc: true, isDelayed: true };
            }
          }
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════════
  // OPTIMIZATION / DISPATCHER (Placeholder)
  // Stage 90 (Waiting) pysyy kunnes käyttäjä/optimoija aktivoi erän manuaalisesti
  // Automaattinen 90 -> 0 muunnos poistettu - erät odottavat start-asemalla
  // ═══════════════════════════════════════════════════════════════════════════════════════════════
  // Stage 90 -> 0 aktivointi tapahtuu nyt vain manuaalisesti (API-kutsu tai UI)

  // ═══════════════════════════════════════════════════════════════════════════════════════════════
  // TILAKONE - Jatkuvatoiminen aikataulutus ja tehtävälista
  // Tilakone pyörii AINA - käsittelee yhden vaiheen per tick
  // ═══════════════════════════════════════════════════════════════════════════════════════════════
  
  const smState = stateMachine.getStatus();
  
  // DEBUG: Näytä tilakoneen tila joka 50. tick
  if (Math.floor(simTimeMs / 100) % 50 === 0) {
    console.log(`[SM-DEBUG] phase=${smState.phase} (${smState.phaseName}), batches=${batches.length}, taskCount=${smState.taskCount}`);
  }
  
  // Kutsu tilakoneen tick (käsittelee yhden vaiheen per kutsu)
  const currentTimeSec2 = simTimeMs / 1000;
  const movementTimes = await ensureMovementTimesLoaded();
  const smContext = {
    batches: batches,
    units: units,
    // Unit adapter -funktiot (käytä näitä batch.location:in sijaan)
    getUnitByBatchId: (batchId) => getUnitByBatchId(units, batchId),
    getUnitAtLocation: (location) => getUnitAtLocation(units, location),
    isLocationOccupied: (location) => isLocationOccupied(units, location),
    getBatchLocation: (batchId) => getBatchLocation(units, batchId),
    setUnitLocation: (unitId, newLocation) => setUnitLocation(units, unitId, newLocation),
    findFreeUnit: () => findFreeUnit(units),
    isBatchOnTransporter: (batchId) => isBatchOnTransporter(units, batchId),
    getOccupiedStations: () => getOccupiedStations(units),
    stations: stations,
    transporters: transportersCfg,
    transporterStates: runtimeState.transporters || [],
    programs: {},  // Cache täytetään tarvittaessa
    currentTimeSec: currentTimeSec2,
    // Tick metadata for KPI tracking
    simTick,
    tickDtMs: dtMs,
    // Dashboard/scheduler tick period is the base scan time; speedMultiplier should not affect it.
    tickPeriodMs: BASE_DT_MS,
    simTimeMs,
    speedMultiplier,
    movementTimes,
    noTreatmentTasks: await loadNoTreatmentTasks(),
    // Rinnakkaiset asemat: välitä stationIdleSince tilakonetielle
    stationIdleSince: stationIdleSince,

    // VAIHE 2: schedules ei enää context:issa - tilakone lukee itse!
    loadTreatmentProgram: loadTreatmentProgram,
    applyTreatmentProgramStretches: applyTreatmentProgramStretches,
    forceRecalc: false,
    // Runtime-tiedostojen LUKU (tilakone kutsuu INIT:ssä)
    loadRuntimeFile: async (filename) => {
      const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
      const fullPath = path.join(runtimeDir, filename);
      try {
        const content = await fs.readFile(fullPath, 'utf8');
        return JSON.parse(content);
      } catch (err) {
        if (err.code !== 'ENOENT') {
          console.warn(`[RUNTIME] Failed to read ${filename}:`, err.message);
        }
        return null;
      }
    },
    // Yleinen tiedostontallennusfunktio runtime-kansioon
    saveRuntimeFile: async (filename, content) => {
      try {
        const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
        const fullPath = path.join(runtimeDir, filename);
        // Varmista kansio olemassa
        const dir = path.dirname(fullPath);
        await fs.mkdir(dir, { recursive: true });
        await fs.writeFile(fullPath, content, 'utf8');
      } catch (err) {
        console.error(`[RUNTIME] Failed to save ${filename}:`, err.message);
      }
    },
    // Tiedoston poistofunktio runtime-kansiosta
    deleteRuntimeFile: async (filename) => {
      try {
        const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
        const fullPath = path.join(runtimeDir, filename);
        await fs.unlink(fullPath);
        console.log(`[RUNTIME] Deleted ${filename}`);
      } catch (err) {
        // Tiedostoa ei löytynyt - OK, ei haittaa
        if (err.code !== 'ENOENT') {
          console.error(`[RUNTIME] Failed to delete ${filename}:`, err.message);
        }
      }
    },
    // Batch stage päivitys (VAIN stage 90→0, tilakone kutsuu)
    // waitTimes on valinnainen objekti: { start_time, min_time_s, calc_time_s, max_time_s }
    setBatchStage: async (batchId, newStage, waitTimes = null) => {
      const batchIdx = batches.findIndex(b => b.batch_id === batchId);
      if (batchIdx >= 0) {
        const updateData = { ...batches[batchIdx], stage: newStage };
        
        // Jos waitTimes annettu (aktivoinnin yhteydessä), päivitä odotusajat
        if (waitTimes && typeof waitTimes === 'object') {
          if (waitTimes.start_time !== undefined) updateData.start_time = waitTimes.start_time;
          if (waitTimes.min_time_s !== undefined) updateData.min_time_s = waitTimes.min_time_s;
          if (waitTimes.calc_time_s !== undefined) updateData.calc_time_s = waitTimes.calc_time_s;
          if (waitTimes.max_time_s !== undefined) updateData.max_time_s = waitTimes.max_time_s;
          // justActivated-lippu: true = DEPARTURE aktivoi, false = TASKS käsitteli → poista
          if (waitTimes.justActivated === true) {
            updateData.justActivated = true;
          } else if (waitTimes.justActivated === false) {
            delete updateData.justActivated;
          }
          console.log(`[BATCH-STAGE] B${batchId}: wait times set - start=${waitTimes.start_time}, min=${waitTimes.min_time_s}s, calc=${waitTimes.calc_time_s}s, max=${waitTimes.max_time_s}s${updateData.justActivated ? ', justActivated=true' : ''}`);
        }
        
        batches[batchIdx] = updateData;
        // Tallenna HETI tiedostoon - tilakone lukee tiedostosta joka kierros
        try {
          await saveBatches({ batches });
          console.log(`[BATCH-STAGE] B${batchId}: stage → ${newStage} (saved to file)`);
        } catch (err) {
          console.error(`[BATCH-STAGE] B${batchId}: save error: ${err.message}`);
        }
        return true;
      }
      return false;
    },
    // ═══════════════════════════════════════════════════════════════════════════════
    // Batch calc_time_s päivitys (ACTIVATE kutsuu kun departure muutti linjalla olevan erän aikaa)
    // Päivittää VAIN asemalla olevien erien calc_time_s (stage vastaa annettua stagea)
    // ═══════════════════════════════════════════════════════════════════════════════
    updateBatchCalcTimes: async (updates) => {
      // updates = [{ batchId, stage, calcTimeS }, ...]
      if (!Array.isArray(updates) || updates.length === 0) return 0;
      
      let updatedCount = 0;
      for (const { batchId, stage, calcTimeS } of updates) {
        const batch = batches.find(b => b.batch_id === batchId);
        if (!batch) continue;
        
        // TURVALLISUUS: Päivitä vain jos erä on kyseisellä stagella (asemalla)
        if (batch.stage !== stage) {
          console.log(`[BATCH-CALCTIME] B${batchId}: skip - batch stage ${batch.stage} ≠ requested ${stage}`);
          continue;
        }
        
        const oldCalc = batch.calc_time_s || 0;
        batch.calc_time_s = calcTimeS;
        updatedCount++;
        console.log(`[BATCH-CALCTIME] B${batchId} stage ${stage}: calc_time_s ${oldCalc.toFixed(1)}s → ${calcTimeS.toFixed(1)}s`);
      }
      
      // Tallenna HETI tiedostoon - tilakone lukee tiedostosta joka kierros
      if (updatedCount > 0) {
        try {
          await saveBatches({ batches });
          console.log(`[BATCH-CALCTIME] Saved ${updatedCount} updates to batches.json`);
        } catch (err) {
          console.error(`[BATCH-CALCTIME] save error: ${err.message}`);
        }
      }
      
      return updatedCount;
    },
    // ═══════════════════════════════════════════════════════════════════════════════
    // Debug snapshot tallennus (ACTIVATE kutsuu analyysiä varten)
    // Tallentaa kaiken oleellisen tiedon debug_snapshots hakemistoon
    // ═══════════════════════════════════════════════════════════════════════════════
    writeDebugSnapshot: async (batchId, snapshot) => {
      const fs = require('fs');
      const path = require('path');
      
      // Luo hakemisto jos ei ole
      const snapshotDir = path.join(__dirname, '..', 'debug_snapshots');
      if (!fs.existsSync(snapshotDir)) {
        fs.mkdirSync(snapshotDir, { recursive: true });
      }
      
      // Tiedostonimi: B{batchId}_activated_{timestamp}.json
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const filename = `B${batchId}_activated_${timestamp}.json`;
      const filepath = path.join(snapshotDir, filename);
      
      fs.writeFileSync(filepath, JSON.stringify(snapshot, null, 2));
      console.log(`[DEBUG-SNAPSHOT] Written: ${filepath}`);
      
      // Tallenna suunnitellut tehtäväajat muistiin vertailua varten
      storePlannedTaskTimes(snapshot);
    },
    // Tallennusfunktiot - tilakone kutsuu näitä kun laskenta valmis
    saveSchedules: async (schedules, currentTimeSec) => {
      try {
        // VAIHE 2: EI enää päivitetä runtimeState:a (tilakone omistaa)
        await saveSchedules(schedules, currentTimeSec);
        console.log('[StateMachine] Schedules saved');
        // HUOM: Calculated CSV kirjoitetaan nyt ACTIVATE-vaiheessa (6090), ei täällä
      } catch (err) {
        console.error('[StateMachine] Schedules save error:', err.message);
      }
    },
    saveTransporterTasks: async (tasks) => {
      try {
        // VAIHE 2: EI enää päivitetä runtimeState:a (tilakone omistaa)
        // Filter out tasks that are already in execution (transporters mid-flight)
        const transporterIds = new Set((runtimeState.transporters || []).map((t) => t.id));
        
        // Lue batches ja units tiedostosta (ei runtimeState:sta)
        const batchesData = await loadBatches();
        const currentBatches = batchesData?.batches || [];
        const currentUnitsForTasks = await loadUnits();
        
        const carriedBatchByTransporterId = new Map();
        for (const u of currentUnitsForTasks) {
          if (transporterIds.has(u.location) && u.batch_id != null) {
            carriedBatchByTransporterId.set(u.location, u.batch_id);
          }
        }

        const inFlightKeys = new Set();
        for (const t of runtimeState.transporters || []) {
          const s = t && t.state ? t.state : {};
          const phase = Number(s.phase);
          if (!Number.isFinite(phase) || phase === 0) continue;
          const lift = s.lift_station_target;
          const sink = s.sink_station_target;
          if (lift == null || sink == null) continue;
          const batchId = s.pending_batch_id != null ? s.pending_batch_id : carriedBatchByTransporterId.get(t.id);
          if (batchId == null) continue;
          inFlightKeys.add(`${batchId}|${lift}|${sink}`);
        }

        const filtered = Array.isArray(tasks)
          ? tasks.filter((task) => !inFlightKeys.has(`${task.batch_id}|${task.lift_station_id}|${task.sink_station_id}`))
          : [];

        await saveTransporterTasks(filtered);
        console.log('[StateMachine] Tasks saved:', filtered.length);
      } catch (err) {
        console.error('[StateMachine] Tasks save error:', err.message);
      }
    },
    // ═══════════════════════════════════════════════════════════════════════════════
    // Calculated CSV:n kirjoitus - kutsutaan kun erä lähtee linjaan (6090 ACTIVATE)
    // ═══════════════════════════════════════════════════════════════════════════════
    writeBatchScheduleCsv: async ({ batchId, scheduleResult, overwrite = true }) => {
      return await writeBatchScheduleCsv({ batchId, scheduleResult, overwrite });
    },
    // ═══════════════════════════════════════════════════════════════════════════════
    // Actual CSV:n päivitys - kutsutaan kun stage 0:n entry-aika kirjataan
    // ═══════════════════════════════════════════════════════════════════════════════
    updateBatchActualCsv: async ({ batchId, station, entryTimeSec, exitTimeSec }) => {
      await updateBatchActualCsv({ batchId, station, entryTimeSec, exitTimeSec });
    },
    // ═══════════════════════════════════════════════════════════════════════════════
    // Käsittelyohjelmien tallennus (DEPARTURE-tarkastelun calc_time-päivitykset)
    // Kutsutaan SAVE-vaiheessa kun käsittelyohjelmat ovat muuttuneet
    // ═══════════════════════════════════════════════════════════════════════════════
    writeTreatmentPrograms: async (programsByBatchId) => {
      if (!programsByBatchId || typeof programsByBatchId !== 'object') {
        console.log('[SM-SAVE] No programs to write');
        return;
      }
      
      const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
      let writtenCount = 0;
      
      for (const [batchIdStr, program] of Object.entries(programsByBatchId)) {
        if (!Array.isArray(program) || program.length === 0) continue;
        
        const batchId = parseInt(batchIdStr, 10);
        if (!Number.isFinite(batchId)) continue;
        
        // Etsi erän treatment_program numero
        const batch = batches.find(b => b.batch_id === batchId);
        const programNumber = batch ? parseInt(batch.treatment_program || '1', 10) : 1;
        
        // Tiedostonimi: Batch_001_treatment_program_001.csv
        const batchIdPad = String(batchId).padStart(3, '0');
        const programNumPad = String(programNumber).padStart(3, '0');
        const filename = `Batch_${batchIdPad}_treatment_program_${programNumPad}.csv`;
        const filepath = path.join(runtimeDir, filename);
        
        // Muodosta CSV
        const header = 'Stage,MinStat,MaxStat,MinTime,MaxTime,CalcTime';
        const rows = program.map(s => 
          `${s.stage},${s.min_station},${s.max_station},${s.min_time},${s.max_time},${s.calc_time || s.max_time}`
        );
        const csv = [header, ...rows].join('\n');
        
        try {
          await fs.writeFile(filepath, csv, 'utf8');
          writtenCount++;
          console.log(`[SM-SAVE] Wrote ${filename} (${program.length} stages)`);
        } catch (err) {
          console.error(`[SM-SAVE] Failed to write ${filename}:`, err.message);
        }
      }
      
      console.log(`[StateMachine] Treatment programs saved: ${writtenCount} files`);
    }
  };
  
  // ═══════════════════════════════════════════════════════════════════════════════
  // VUOROTTELU: TASKS (parillinen tick) / DEPARTURES (pariton tick)
  // Molemmat tilakoneet synkronoidaan:
  //  1. DEPARTURE odottaa TASKS:n READY/SAVE valmistumista (INIT-synkronointi)
  //  2. DEPARTURE:n ACTIVATE odottaa TASKS:n SAVE-vaihetta (file I/O synkronointi)
  // ═══════════════════════════════════════════════════════════════════════════════
  
  try {
    if (simTick % 2 === 0) {
      // PARILLINEN TICK: TASKS-tilakone (aikataulutus + tehtävät)
      // Pass DEPARTURE's pending write data for TASKS SAVE to merge and write
      const depState = departureScheduler.getState();
      smContext.departurePendingWriteData = depState.pendingWriteData || { valid: false };
      smContext.departureActivated = departureActivatedFlag;
      const tickResult = await stateMachine.tick(smContext);
      
      // Debug: näytä TASKS-tikin tulos stabiili-lipulle
      if (tickResult) {
        const phase = tickResult.phase || tickResult.currentPhase || '?';
        console.log(`[STABLE-DEBUG] TASKS tick phase=${phase} conflictResolved=${tickResult.conflictResolved} tasksConflictResolved=${tasksConflictResolved}`);
      }
      
      if (tickResult && tickResult.pauseRequested) {
        console.log('[StateMachine] Pause requested by state machine (cycle end, speedMultiplier=0)');
        stopLoop();
      }
      // Jos TASKS kuittasi aktivoinnin (INIT lukenut uudet CSV:t), nollaa lippu
      if (tickResult && tickResult.departureAcknowledged) {
        departureActivatedFlag = false;
        console.log('[HANDSHAKE] TASKS acknowledged departure activation, flag cleared');
      }
      // If TASKS saved DEPARTURE's pending data, set confirmation flag
      if (tickResult && tickResult.departureSaveConfirmed) {
        departureSaveConfirmedFlag = true;
        console.log('[HANDSHAKE] TASKS confirmed DEPARTURE save in SAVE phase');
      }
      // Päivitä TASKS stabiili-lippu: kun conflictResolved = true, linja on stabiili.
      // Lippu menee false:ksi VAIN kun DEPARTURE aktivoi erän (alempana).
      // Lippu palautuu true:ksi kun TASKS on ratkaissut kaikki konfliktit.
      if (tickResult && tickResult.conflictResolved && !tasksConflictResolved) {
        tasksConflictResolved = true;
        console.log('[HANDSHAKE] TASKS stable — no conflicts, DEPARTURE can proceed');
      }
    } else {
      // PARITON TICK: DEPARTURES-tilakone (lähtöluvat)
      // Välitä TASKS-tilakoneen tila synkronointia varten
      const tasksPhase = stateMachine.getPhase();
      const tasksData = stateMachine.getData();
      const departureContext = {
        ...smContext,
        simTick,
        tasksPhase,
        // Server-tason stabiili-lippu: true kun TASKS:n edellinen sykli oli konfliktivapaa
        tasksConflictResolved: tasksConflictResolved,
        // Raw data from TASKS (deep copy)
        // DEPARTURE copies these in its own INIT and calculates schedules independently
        programsByBatchId: tasksData.programsByBatchId || {},
        // Signal from TASKS that pending data was written successfully
        departureSaveConfirmed: departureSaveConfirmedFlag
      };
      
      const departureResult = await departureScheduler.tick(departureContext);
      
      // Jos DEPARTURE aktivoi erän, aseta handshake-lippu ja nollaa stabiili-lippu
      if (departureResult && departureResult.activated) {
        departureActivatedFlag = true;
        tasksConflictResolved = false;
        console.log(`[HANDSHAKE] Departure activated batch → tasksConflictResolved=false, waiting for TASKS to stabilize`);
      }
      
      // Clear save confirmed flag after DEPARTURE has seen it
      if (departureSaveConfirmedFlag) {
        departureSaveConfirmedFlag = false;
      }
    }
  } catch (err) {
    console.error('[StateMachine] Tick error:', err.message);
  }

  // Save batches at end of tick if any runtime state changed
  // (saveRuntimeState on jo kutsuttu - ei tarvitse erikseen)
  if (batchesChanged) {
    console.log(`[SAVE] Batches changed:`, units.map(u => `U${u.unit_id}@${u.location}(B${u.batch_id})`).join(' '));
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════════
  // TUOTANNON VALMISTUMINEN - Pysäytä simulaatio ja tallenna raportit
  // ═══════════════════════════════════════════════════════════════════════════════════════════════
  if (productionPlan && productionPlan.productionCompleted && !productionPlan.reportsSaved) {
    productionPlan.reportsSaved = true;
    
    console.log('[PROD] Pausing simulation and exporting results...');
    
    // Pysäytä simulaatio
    stopLoop();
    
    // Tallenna raportit asynkronisesti
    (async () => {
      try {
        // Kutsu export-results endpointia sisäisesti
        const exportResult = await exportSimulationResults();
        if (exportResult.success) {
          console.log(`[PROD] Results exported to: ${exportResult.target_dir}`);
          console.log(`[PROD] Files exported: ${exportResult.files_exported}`);
        } else {
          console.error('[PROD] Export failed:', exportResult.error);
        }
      } catch (err) {
        console.error('[PROD] Export error:', err.message);
      }
    })();
  }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    // PRODUCTION SPAWN LOGIC (MOVED TO START OF TICK)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    // Duplicate logic removed. See lines 1150+

};

const startLoop = () => {
  if (loopTimer) return { running: true, simTimeMs };
  simDebt = 0;
  loopTimer = setInterval(async () => {
    // Guard against overlapping ticks: setInterval does not await async callbacks.
    // Overlap can cause productionPlan spawning to run twice before state is visible.
    if (tickInProgress) return;
    tickInProgress = true;
    try {
      await withScanLock(async () => {
        // PLC-ohjelmakierros: tick on AINA kiinteä BASE_DT_MS (20 ms).
        // speedMultiplier määrää kuinka monta ohjelmakierrosta ajetaan
        // per seinäkello-intervalli:
        //   x1:  1 tick / intervalli → 50 tick/s
        //   x10: 10 tickiä / intervalli → 500 tick/s
        //   x0.5: 1 tick joka toinen intervalli → 25 tick/s
        // simDebt-laskuri kerää osittaiset tickit desimaalinopeuksia varten.
        simDebt += speedMultiplier;
        while (simDebt >= 1) {
          simDebt -= 1;
          simTimeMs += BASE_DT_MS;
          await stepSimulation(BASE_DT_MS);
        }
      });
    } catch (err) {
      console.error('Simulation tick failed:', err);
    } finally {
      tickInProgress = false;
    }
  }, BASE_DT_MS);
  return { running: true, simTimeMs };
};

const stopLoop = () => {
  // Freeze the clock at the moment pause is requested; ignore any pending dt
  const frozenSim = simTimeMs;
  if (loopTimer) {
    clearInterval(loopTimer);
    loopTimer = null;
  }
  simTimeMs = frozenSim;
  return { running: false, simTimeMs: frozenSim };
};

// Batches CRUD endpoints
app.get('/api/batches', async (req, res) => {
  try {
    // VAIHE 2: Lue batches tiedostosta
    const batchesData = await loadBatches();
    res.json({
      batches: (batchesData?.batches || []).map(stripScheduleFromBatch),
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error reading batches:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.post('/api/batches', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { payload, errors } = normalizeBatchPayload(req.body || {});
      if (errors.length || Object.values(payload).some((v) => v == null)) {
        return res.status(400).json({ success: false, error: errors.join(', ') || 'Invalid payload' });
      }

      // VAIHE 2: Lue ja tallenna batches tiedostoon
      const batchesData = await loadBatches();
      const batchesArr = batchesData?.batches || [];
      if (batchesArr.some((b) => b.batch_id === payload.batch_id)) {
        return res.status(409).json({ success: false, error: 'batch_id already exists' });
      }

      // Mark new batch for schedule calculation
      payload.scheduleNeedsRecalc = true;

      const updatedBatches = [...batchesArr, payload];
      await saveBatches({ batches: updatedBatches });
      
      // Luo Unit manuaalisesti lisätylle batchille
      const currentUnits = await loadUnits();
      if (currentUnits.length > 0) {
        const maxId = Math.max(...currentUnits.map(u => u.unit_id));
        if (maxId >= nextUnitId) nextUnitId = maxId + 1;
      }
      // Käytä clientin antamaa unit_id:tä jos annettu, muuten generoi automaattisesti
      const requestedUnitId = req.body.unit_id;
      let unitId;
      if (requestedUnitId != null && Number.isFinite(Number(requestedUnitId))) {
        unitId = Math.round(Number(requestedUnitId));
        // Tarkista ettei unit_id ole jo käytössä
        if (currentUnits.some(u => u.unit_id === unitId)) {
          return res.status(409).json({ success: false, error: `unit_id ${unitId} already exists` });
        }
        if (unitId >= nextUnitId) nextUnitId = unitId + 1;
      } else {
        unitId = nextUnitId++;
      }
      currentUnits.push({ unit_id: unitId, location: payload.location, batch_id: payload.batch_id });
      await saveUnits(currentUnits);
      console.log(`[UNIT] Created unit ${unitId} for manually added batch ${payload.batch_id} at location ${payload.location}`);
      
      lastBatchLocations.clear();
      res.status(201).json({ success: true, batch: payload, unit_id: unitId, batches: updatedBatches.map(stripScheduleFromBatch) });
    } catch (error) {
      console.error('Error creating batch:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

app.put('/api/batches/:id', async (req, res) => {
  return withScanLock(async () => {
    try {
      const targetId = Number(req.params.id);
      if (!Number.isFinite(targetId)) {
        return res.status(400).json({ success: false, error: 'Invalid batch id' });
      }

      // VAIHE 2: Lue ja tallenna batches tiedostoon
      const batchesData = await loadBatches();
      const batchesArr = batchesData?.batches || [];
      const idx = batchesArr.findIndex((b) => b.batch_id === targetId);
      if (idx === -1) {
        return res.status(404).json({ success: false, error: 'Batch not found' });
      }

      const { payload, errors } = normalizeBatchPayload({ ...req.body, batch_id: targetId });
      if (errors.length || Object.values(payload).some((v) => v == null)) {
        return res.status(400).json({ success: false, error: errors.join(', ') || 'Invalid payload' });
      }

      // Mark updated batch for schedule recalculation
      payload.scheduleNeedsRecalc = true;

      const updatedBatches = [...batchesArr];
      updatedBatches[idx] = payload;
      await saveBatches({ batches: updatedBatches });
      
      // Synkronoi Unit-sijainti jos batch-sijainti muuttui
      const currentUnits = await loadUnits();
      const unit = currentUnits.find(u => u.batch_id === targetId);
      if (unit && unit.location !== payload.location) {
        unit.location = payload.location;
        await saveUnits(currentUnits);
        console.log(`[UNIT] Synced unit ${unit.unit_id} location to ${payload.location} (batch ${targetId} updated)`);
      }
      
      lastBatchLocations.clear();
      res.json({ success: true, batch: payload, unit_id: unit ? unit.unit_id : null, batches: updatedBatches.map(stripScheduleFromBatch) });
    } catch (error) {
      console.error('Error updating batch:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

app.delete('/api/batches/:id', async (req, res) => {
  return withScanLock(async () => {
    try {
      const targetId = Number(req.params.id);
      if (!Number.isFinite(targetId)) {
        return res.status(400).json({ success: false, error: 'Invalid batch id' });
      }

      // VAIHE 2: Lue ja tallenna batches tiedostoon
      const batchesData = await loadBatches();
      const batchesArr = batchesData?.batches || [];
      const nextBatches = batchesArr.filter((b) => b.batch_id !== targetId);
      if (nextBatches.length === batchesArr.length) {
        return res.status(404).json({ success: false, error: 'Batch not found' });
      }

      await saveBatches({ batches: nextBatches });
      
      // Irrota poistetun batchin Unit (jää paikalleen tyhjänä)
      const currentUnits = await loadUnits();
      const unit = currentUnits.find(u => u.batch_id === targetId);
      if (unit) {
        unit.batch_id = null;
        await saveUnits(currentUnits);
        console.log(`[UNIT] Detached batch ${targetId} from unit ${unit.unit_id} (batch deleted)`);
      }
      
      lastBatchLocations.clear();
      res.json({ success: true, batches: nextBatches.map(stripScheduleFromBatch) });
    } catch (error) {
      console.error('Error deleting batch:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

// API endpoint to reset transporter states
app.post('/api/reset-transporters', async (req, res) => {
  return withScanLock(async () => {
    try {
      // Reset simulation clock and previous-location cache so timing restarts cleanly
      stopLoop();
      simTimeMs = 0;
      productionPlan = null;
      lastBatchLocations.clear();
      
      // Reset handshake flags for clean start
      tasksConflictResolved = true;      // Tyhjä linja on stabiili → DEPARTURE voi aloittaa heti
      departureActivatedFlag = false;
      departureSaveConfirmedFlag = false;
      
      // Clear task execution log for new run
      clearTaskExecutionLog();

    // Tyhjennä tehtävälista heti resetin alussa, ettei vanha data jää elämään jos jokin myöhempi vaihe epäonnistuu
    await saveTransporterTasks([]);

    // Clear runtime directory - remove all files EXCEPT production_setup.json
    const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
    console.log(`Reset: Clearing runtime directory: ${runtimeDir}`);
    
    // Files to preserve during reset (simulation_purpose.json contains customer/plant selection)
    const preserveFiles = new Set(['simulation_purpose.json']);
    
    try {
      const runtimeFiles = await fs.readdir(runtimeDir);
      let deletedCount = 0;
      
      for (const file of runtimeFiles) {
        // Skip files that should be preserved
        if (preserveFiles.has(file)) {
          console.log(`Reset: Preserving ${file}`);
          continue;
        }
        const filePath = path.join(runtimeDir, file);
        try {
          const stat = await fs.stat(filePath);
          if (stat.isFile()) {
            await fs.unlink(filePath);
            deletedCount++;
            console.log(`Reset: Deleted ${file}`);
          }
        } catch (err) {
          console.error(`Reset: Error deleting ${file}:`, err);
        }
      }
      
      console.log(`Reset: Cleared ${deletedCount} files from runtime directory`);
    } catch (err) {
      // Runtime directory might not exist yet, that's OK
      console.log('Reset: Runtime directory empty or not found, continuing...');
    }

    // Also clear per-batch calculated CSVs under runtime/batch_schedules (these are inside a subdir).
    // Use runtimeDir-derived path here to avoid any mismatch with cached paths.
    try {
      const batchSchedulesDir = path.join(runtimeDir, 'batch_schedules');
      await fs.mkdir(batchSchedulesDir, { recursive: true });
      const scheduleFiles = await fs.readdir(batchSchedulesDir);
      let deleted = 0;
      for (const file of scheduleFiles) {
        if (!/^B\d+_(calculated|actual)\.csv$/i.test(file)) continue;
        try {
          await fs.rm(path.join(batchSchedulesDir, file), { force: true });
          deleted++;
        } catch (err) {
          console.warn(`Reset: Could not delete ${file} from batch_schedules:`, err.message);
        }
      }
      if (deleted > 0) {
        console.log(`Reset: Cleared ${deleted} files from batch_schedules`);
      }
    } catch (err) {
      console.warn('Reset: Could not clear batch_schedules:', err.message);
    }

    // Clear departure_check directory
    try {
      const departureCheckDir = path.join(runtimeDir, 'departure_check');
      await fs.mkdir(departureCheckDir, { recursive: true });
      const depFiles = await fs.readdir(departureCheckDir);
      let depDeleted = 0;
      for (const file of depFiles) {
        try {
          await fs.rm(path.join(departureCheckDir, file), { force: true });
          depDeleted++;
        } catch (err) {
          console.warn(`Reset: Could not delete ${file} from departure_check:`, err.message);
        }
      }
      if (depDeleted > 0) {
        console.log(`Reset: Cleared ${depDeleted} files from departure_check`);
      }
    } catch (err) {
      console.warn('Reset: Could not clear departure_check:', err.message);
    }

    // Create empty batches.json in runtime directory
    await saveBatches({ batches: [] });

    // Load unit_setup.json from plant directory (if exists), otherwise start with empty units
    let initialUnits = [];
    try {
      const unitSetupData = await loadJson(paths.unitSetup);
      if (unitSetupData && Array.isArray(unitSetupData.units)) {
        initialUnits = unitSetupData.units.map(u => ({
          unit_id: u.unit_id,
          location: u.location,
          batch_id: u.batch_id != null ? u.batch_id : null,
          status: u.status || 'used',
          state: u.state || 'empty',
          target: u.target || 'none'
        }));
        console.log(`Reset: Loaded ${initialUnits.length} units from unit_setup.json`);
      }
    } catch (err) {
      console.log('Reset: No unit_setup.json found, starting with empty units');
    }
    await saveUnits(initialUnits);
    // Set nextUnitId past any existing unit IDs
    if (initialUnits.length > 0) {
      nextUnitId = Math.max(...initialUnits.map(u => u.unit_id)) + 1;
    } else {
      nextUnitId = 1;
    }
    console.log(`Reset: Created units.json with ${initialUnits.length} units, nextUnitId=${nextUnitId}`);
    // Create empty schedules.json in runtime directory
    await saveSchedules({});
    console.log('Reset: Created empty schedules.json');

    const transportersData = await loadJson(paths.transporters);
    const stationsData = await loadJson(paths.stations);

    // Generoi movement_times.json (siirtoajat asemalta asemalle)
    try {
      const transporters = transportersData.transporters || [];
      const stations = stationsData.stations || [];
      const movementTimes = { transporters: {} };
      if (transporters.length > 0 && stations.length > 0) {
        for (const transporter of transporters) {
          const transporterId = String(transporter.id);
          movementTimes.transporters[transporterId] = {
            lift_s: {},
            sink_s: {},
            travel_s: {}
          };
          stations.forEach(fromStation => {
            movementTimes.transporters[transporterId].lift_s[fromStation.number] = scheduler.calculateLiftTime2D(Number(fromStation.kind) || 0, transporter.physics_2D);
            movementTimes.transporters[transporterId].sink_s[fromStation.number] = scheduler.calculateSinkTime2D(Number(fromStation.kind) || 0, transporter.physics_2D);
            movementTimes.transporters[transporterId].travel_s[fromStation.number] = {};
            stations.forEach(toStation => {
              const xDistance = Math.abs((toStation.x_position || 0) - (fromStation.x_position || 0));
              const xTime = scheduler.calculateAxisTime(xDistance, transporter.physics_2D.x_max_speed_mm_s, transporter.physics_2D.x_acceleration_time_s, transporter.physics_2D.x_deceleration_time_s);
              movementTimes.transporters[transporterId].travel_s[fromStation.number][toStation.number] = xTime;
            });
          });
        }
      } else {
        console.warn('[RESET] Ei nostimia tai asemia saatavilla, movement_times.json luodaan tyhjänä.');
      }
      const movementTimesPath = path.join(__dirname, '..', 'visualization', 'runtime', 'movement_times.json');
      await writeJsonAtomic(movementTimesPath, movementTimes);
      console.log(`[RESET] Movement times tallennettu: ${movementTimesPath}`);
    } catch (err) {
      console.error('[RESET] Movement times generation failed:', err.message);
    }

    // Create station_avoid_status.json with all stations set to avoid_status: 0
    const avoidStatusData = { stations: {} };
    for (const station of stationsData.stations || []) {
      avoidStatusData.stations[station.number] = { avoid_status: 0 };
    }
    await writeJsonAtomic(paths.avoidStatuses, avoidStatusData);
    console.log(`Reset: Created station_avoid_status.json with ${Object.keys(avoidStatusData.stations).length} stations`);
    
    console.log('Reset: transportersData=', JSON.stringify(transportersData, null, 2));
    console.log('Reset: transporters count=', transportersData.transporters?.length);
    
    // Calculate initial states from start_station values (both 2D and 3D)
    const resetStates = transportersData.transporters.map(transporter => {
      const startStation = stationsData.stations.find(
        s => s.number === transporter.start_station
      );
      
      // Get drive limits directly from transporter configuration
      const x_min_drive_limit = transporter.x_min_drive_limit || 0;
      const x_max_drive_limit = transporter.x_max_drive_limit || 0;
      const y_min_drive_limit = transporter.y_min_drive_limit || 0;
      const y_max_drive_limit = transporter.y_max_drive_limit || 0;
      const z_min_drive_limit = transporter.z_min_drive_limit || 0;
      const z_max_drive_limit = transporter.z_max_drive_limit || 0;
      
      // For 3D transporters, z_position starts at idle height
      const is3D = transporter.model === "3D";
      const z_idle_height = is3D && transporter.physics_3D ? (transporter.physics_3D.z_idle_height_mm || 100) : 0;
      const initialZPosition = is3D ? z_idle_height : z_min_drive_limit;
      
      // Täytetään kaikki state-kentät normalisoidusti
      return {
        id: transporter.id,
        model: transporter.model,
        state: {
          x_position: startStation ? startStation.x_position : 0,
          y_position: y_min_drive_limit,
          z_position: initialZPosition,
          operation: "idle",
          current_station: transporter.start_station,
          load: null,
          velocity_x: 0,
          status: 3,  // 3 = idle, valmis ottamaan tehtäviä
          phase: 0,
          target_x: startStation ? startStation.x_position : 0,
          z_stage: "idle",
          z_timer: 0,
          velocity_z: 0,
          pending_batch_id: null,
          initial_delay: 0,
          x_min_drive_limit,
          x_max_drive_limit,
          y_min_drive_limit,
          y_max_drive_limit,
          z_min_drive_limit,
          z_max_drive_limit
        }
      };
    });
    
    // Preserve existing structure: load current file, update transporters, keep other keys as-is
    const stateData = { transporters: resetStates };

    // Write to transporter_states.json (saveStates will refresh timestamp)
    await saveStates(stateData);
    
    // VAIHE 2: Päivitä vain server:in omistamat tiedot muistiin
    runtimeState.transporters = resetStates;
    runtimeState.avoidStatuses = avoidStatusData.stations || {};
    
    // Tyhjennä batches, tasks, schedules TIEDOSTOISTA (tilakone omistaa)
    // Units ladataan unit_setup.json:sta (tehty jo aiemmin), ei tyhjennetä
    await saveBatches({ batches: [] });
    await saveSchedules({});
    await saveTransporterTasks([]);
    
    // Nollaa tilakoneet
    stateMachine.reset();
    departureScheduler.reset();
    
    console.log('Transporter states reset successfully, state machines reset');
      res.json({ 
        success: true, 
        message: 'Transporter states reset to initial positions',
        transporters: resetStates,
        simTimeMs
      });
      
    } catch (error) {
      console.error('Error resetting transporter states:', error);
      res.status(500).json({ 
        success: false, 
        error: error.message 
      });
    }
  });
});

// API endpoint to get current transporter states
app.get('/api/transporter-states', async (req, res) => {
  try {
    res.json({
      timestamp: new Date().toISOString(),
      transporters: runtimeState.transporters
    });
  } catch (error) {
    console.error('Error reading transporter states:', error);
    res.status(500).json({ 
      success: false, 
      error: error.message 
    });
  }
});

// API endpoint to update transporter states (for simulation)
app.post('/api/transporter-states', async (req, res) => {
  return withScanLock(async () => {
    try {
      const saved = await saveStates(req.body);
      runtimeState.transporters = Array.isArray(saved?.transporters) ? saved.transporters : runtimeState.transporters;
      res.json({ 
        success: true, 
        message: 'Transporter states updated'
      });
    } catch (error) {
      console.error('Error updating transporter states:', error);
      res.status(500).json({ 
        success: false, 
        error: error.message 
      });
    }
  });
});

// Simulation control endpoints
app.post('/api/sim/start', async (req, res) => {
  return withScanLock(async () => {
    try {
      productionPlan = await buildProductionPlan();
      
      // Käynnistä tilakone
      stateMachine.start();
      
      // Force first spawn immediately if queue exists
      if (productionPlan && productionPlan.queue && productionPlan.queue.length > 0) {
        productionPlan.nextSpawnMs = 0;
      }
    } catch (err) {
      console.warn('Could not build production plan:', err.message);
      productionPlan = null;
    }
    const result = startLoop();
    res.json({ success: true, ...result, speedMultiplier, simTimeMs, productionPlan });
  });
});

app.post('/api/sim/pause', (req, res) => {
  return withScanLock(async () => {
    const result = stopLoop();
    // Talleta runtime-tilanne tiedostoihin heti pausen yhteydessä
    await saveRuntimeState();
    res.json({ success: true, ...result, speedMultiplier, simTimeMs: result.simTimeMs });
  });
});

// ═══════════════════════════════════════════════════════════════════════════════
// EXPORT RESULTS - Tallenna PLC-simulaation tulokset simulation_results kansioon
// ═══════════════════════════════════════════════════════════════════════════════

// Helper: format simulation time
const formatSimTime = (ms) => {
  const totalSec = Math.floor(ms / 1000);
  const hours = Math.floor(totalSec / 3600);
  const mins = Math.floor((totalSec % 3600) / 60);
  const secs = totalSec % 60;
  return `${hours}h ${mins}m ${secs}s`;
};

/**
 * Tallenna PLC-simulaation tulokset - kutsuttavissa sekä API:sta että automaattisesti
 * @returns {Promise<{success: boolean, target_dir?: string, files_exported?: number, error?: string}>}
 */
const exportSimulationResults = async () => {
  try {
    // 1. Lue nykyinen asiakasvalinta
    const simPurpose = await readJsonSafe(paths.simulationPurpose, null);
    if (!simPurpose || !simPurpose.customer) {
      return { 
        success: false, 
        error: 'No active customer/plant selection found' 
      };
    }
    
    const customer = simPurpose.customer;
    const plantName = simPurpose.plant?.name || 'Unknown_Plant';
    
    // 2. Tarkista viimeisin output-hakemisto
    const getInitDir = () => {
      const dockerPath = '/data/initialization';
      if (fsSync.existsSync(dockerPath)) return dockerPath;
      return path.join(__dirname, '..', '..', 'initialization');
    };
    
    const getSimResultsDir = () => {
      const dockerPath = '/data/simulation_results';
      if (fsSync.existsSync(dockerPath)) return dockerPath;
      return path.join(__dirname, '..', '..', 'simulation_results');
    };
    
    const initDir = getInitDir();
    const simResultsDir = getSimResultsDir();
    const currentOutputPath = path.join(initDir, 'current_output_dir.txt');
    
    let targetDir = null;
    let usedExistingDir = false;
    
    // Yritä lukea viimeisin output-hakemisto
    try {
      const mathOutputDir = (await fs.readFile(currentOutputPath, 'utf8')).trim();
      const normalizedPath = mathOutputDir.replace('/data/simulation_results/', '');
      const pathParts = normalizedPath.split('/');
      
      if (pathParts.length >= 2) {
        const mathCustomer = pathParts[0];
        const mathPlant = pathParts[1];
        const normalizeForCompare = (s) => s.toLowerCase().replace(/[\s_-]+/g, '');
        
        if (normalizeForCompare(mathCustomer) === normalizeForCompare(customer) &&
            normalizeForCompare(mathPlant) === normalizeForCompare(plantName)) {
          const relativePath = mathOutputDir.replace('/data/simulation_results/', '');
          targetDir = path.join(simResultsDir, relativePath, 'plc-sim');
          usedExistingDir = true;
        }
      }
    } catch (err) {
      console.log('[Export] Output dir not found or not matching, creating new directory');
    }
    
    // 3. Jos ei löytynyt sopivaa MATH-hakemistoa, luo uusi
    if (!targetDir) {
      const timestamp = new Date().toISOString()
        .replace(/[:.]/g, '-')
        .replace('T', '_')
        .slice(0, 19);
      const newDirName = `PLC_${timestamp}`;
      targetDir = path.join(simResultsDir, customer, plantName, newDirName, 'plc-sim');
    }
    
    // 4. Luo kohdekansio
    await ensureDir(targetDir);
    
    // 5. Kerää ja tallenna PLC-simulaation tulokset
    const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
    const batchSchedulesDir = path.join(runtimeDir, 'batch_schedules');
    
    // 5a. Kopioi batch_schedules tiedostot
    const batchSchedulesTargetDir = path.join(targetDir, 'batch_schedules');
    await ensureDir(batchSchedulesTargetDir);
    
    let copiedFiles = [];
    try {
      const files = await fs.readdir(batchSchedulesDir);
      for (const file of files) {
        if (file.endsWith('.csv')) {
          const src = path.join(batchSchedulesDir, file);
          const dest = path.join(batchSchedulesTargetDir, file);
          await fs.copyFile(src, dest);
          copiedFiles.push(file);
        }
      }
    } catch (err) {
      console.log('[Export] No batch_schedules to copy:', err.message);
    }
    
    // 5b. Luo yhdistetty plc_batch_schedule.csv (ajat normalisoitu: alkavat 0:sta)
    const consolidatedCsvPath = path.join(targetDir, 'plc_batch_schedule.csv');
    
    const actualFiles = copiedFiles
      .filter(f => /^B\d+_actual\.csv$/i.test(f))
      .sort((a, b) => {
        const aNum = parseInt(a.match(/B(\d+)/)[1]);
        const bNum = parseInt(b.match(/B(\d+)/)[1]);
        return aNum - bNum;
      });
    
    // Kerää kaikki aikarivit ensin, etsi pienin entry-aika (offset)
    const allRows = [];
    let minEntryTime = Infinity;
    
    for (const file of actualFiles) {
      const batchMatch = file.match(/B(\d+)/);
      if (!batchMatch) continue;
      const batchId = batchMatch[1];
      
      try {
        const content = await fs.readFile(path.join(batchSchedulesDir, file), 'utf8');
        const lines = content.split(/\r?\n/).filter(l => l.trim());
        
        for (let i = 1; i < lines.length; i++) {
          const cols = lines[i].split(',');
          if (cols.length >= 3) {
            const station = cols[0];
            const entryTime = cols[1] !== '' ? parseInt(cols[1], 10) : null;
            const exitTime = cols[2] !== '' ? parseInt(cols[2], 10) : null;
            
            allRows.push({ batchId, station, entryTime, exitTime });
            
            // Etsi pienin entry-aika (offset)
            if (entryTime !== null && Number.isFinite(entryTime) && entryTime < minEntryTime) {
              minEntryTime = entryTime;
            }
          }
        }
      } catch (err) {
        console.log(`[Export] Error reading ${file}:`, err.message);
      }
    }
    
    // Jos ei löytynyt yhtään entry-aikaa, käytä 0
    if (!Number.isFinite(minEntryTime)) {
      minEntryTime = 0;
    }
    
    console.log(`[Export] Time offset removed: ${minEntryTime}s`);
    
    // Luo CSV normalisoiduilla ajoilla
    const csvLines = ['Batch,Station,EntryTime,ExitTime'];
    for (const row of allRows) {
      const normEntry = row.entryTime !== null ? row.entryTime - minEntryTime : '';
      const normExit = row.exitTime !== null ? row.exitTime - minEntryTime : '';
      csvLines.push(`${row.batchId},${row.station},${normEntry},${normExit}`);
    }
    
    await fs.writeFile(consolidatedCsvPath, csvLines.join('\n'), 'utf8');
    
    // 5c. Tallenna simulaation metadata
    const metadata = {
      export_time: new Date().toISOString(),
      customer: customer,
      plant: plantName,
      simulation_purpose: simPurpose.purpose || 'UNKNOWN',
      simulation_time_ms: simTimeMs,
      simulation_time_formatted: formatSimTime(simTimeMs),
      production_completed: productionPlan?.productionCompleted || false,
      total_batches: productionPlan?.totalBatches || null,
      used_existing_dir: usedExistingDir,
      files_exported: {
        batch_schedules: copiedFiles,
        consolidated_csv: 'plc_batch_schedule.csv'
      }
    };
    
    await writeJsonAtomic(path.join(targetDir, 'export_metadata.json'), metadata);
    
    // 5d. Kopioi simulation_purpose.json
    try {
      await fs.copyFile(paths.simulationPurpose, path.join(targetDir, 'simulation_purpose.json'));
    } catch (err) {
      console.log('[Export] Could not copy simulation_purpose.json:', err.message);
    }
    
    console.log(`[Export] Results saved to: ${targetDir}`);
    
    return {
      success: true,
      target_dir: targetDir,
      used_existing_dir: usedExistingDir,
      files_exported: copiedFiles.length + 2,
      message: usedExistingDir 
        ? 'Results exported to existing simulation directory'
        : 'Results exported to new simulation directory'
    };
    
  } catch (error) {
    console.error('[Export] Error exporting results:', error);
    return { success: false, error: error.message };
  }
};

// API endpoint for manual export
app.post('/api/sim/export-results', async (req, res) => {
  const result = await exportSimulationResults();
  if (result.success) {
    res.json(result);
  } else {
    res.status(result.error?.includes('No active') ? 400 : 500).json(result);
  }
});

// Simulation speed control
app.get('/api/sim/speed', (req, res) => {
  res.json({ speedMultiplier });
});

app.post('/api/sim/speed', (req, res) => {
  return withScanLock(async () => {
    const { multiplier } = req.body || {};
    const parsed = Number(multiplier);
    if (!Number.isFinite(parsed) || parsed < 0) {
      return res.status(400).json({ success: false, error: 'Multiplier must be zero or positive' });
    }
    speedMultiplier = parsed;
    res.json({ success: true, speedMultiplier });
  });
});

// Expose current simulation clock and running status
app.get('/api/sim/time', (req, res) => {
  res.json({ simTimeMs, running: Boolean(loopTimer), speedMultiplier });
});

// Avoid statuses endpoints
app.get('/api/avoid-statuses', async (req, res) => {
  try {
    res.json({
      stations: runtimeState.avoidStatuses || {},
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error reading avoid statuses:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.post('/api/avoid-statuses', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { stationNumber, avoid_status } = req.body;
      if (!stationNumber || typeof avoid_status !== 'number') {
        return res.status(400).json({ success: false, error: 'stationNumber and avoid_status are required' });
      }

      if (!runtimeState.avoidStatuses) runtimeState.avoidStatuses = {};
      if (!runtimeState.avoidStatuses[stationNumber]) runtimeState.avoidStatuses[stationNumber] = {};
      runtimeState.avoidStatuses[stationNumber].avoid_status = avoid_status;
      await writeJsonAtomic(paths.avoidStatuses, {
        stations: runtimeState.avoidStatuses,
        timestamp: new Date().toISOString()
      });
      res.json({ success: true, stationNumber, avoid_status });
    } catch (error) {
      console.error('Error updating avoid status:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

// Customer endpoints
// Customers dir: same logic as PLANT_TEMPLATES_DIR
const getCustomersDir = () => {
  if (process.env.CUSTOMERS_DIR) return process.env.CUSTOMERS_DIR;
  // Check Docker path first (/app/customers)
  const dockerPath = path.join(__dirname, '..', 'customers');
  if (fsSync.existsSync(dockerPath)) return dockerPath;
  // Fall back to dev path (KOKKO/customers)
  return path.join(__dirname, '..', '..', 'customers');
};
const CUSTOMERS_DIR = getCustomersDir();

// Current selection API - get saved customer/plant selection from runtime/simulation_purpose.json
app.get('/api/current-selection', async (req, res) => {
  try {
    const data = await readJsonSafe(paths.simulationPurpose, null);
    if (data && data.customer) {
      const plantName = data.plant?.name || null;
      res.json({ success: true, customer: data.customer, plant: plantName });
    } else {
      res.json({ success: true, customer: null, plant: null });
    }
  } catch (error) {
    // No saved selection - return empty
    res.json({ success: true, customer: null, plant: null });
  }
});

// Current selection API - save customer/plant selection
// Copies simulation_purpose.json from customer folder to runtime folder
app.post('/api/current-selection', async (req, res) => {
  try {
    const { customer, plant } = req.body;
    
    if (!customer || !plant) {
      // Clear selection - write minimal simulation_purpose.json
      await writeJsonAtomic(paths.simulationPurpose, { 
        customer: null,
        plant: { name: null },
        purpose: 'TEST',
        treatment_program_batches: [],
        simulation_duration: 8,
        available_containers: 20,
        updated_at: new Date().toISOString()
      });
      return res.json({ success: true });
    }
    
    // Try to copy simulation_purpose.json from customer folder
    const customerSimPurposePath = path.join(CUSTOMERS_DIR, customer, plant, 'simulation_purpose.json');
    
    try {
      const masterData = await loadJson(customerSimPurposePath);
      // Ensure customer and plant.name are set correctly
      masterData.customer = customer;
      if (!masterData.plant) masterData.plant = {};
      masterData.plant.name = plant;
      masterData.updated_at = new Date().toISOString();
      
      await writeJsonAtomic(paths.simulationPurpose, masterData);
      console.log(`Copied simulation_purpose.json from ${customer}/${plant} to runtime`);
    } catch (copyError) {
      // No master file exists - create default
      console.log(`No simulation_purpose.json in ${customer}/${plant}, creating default`);
      await writeJsonAtomic(paths.simulationPurpose, {
        customer: customer,
        plant: { name: plant, country: '', town: '' },
        purpose: 'TEST',
        treatment_program_batches: [],
        simulation_duration: 8,
        available_containers: 20,
        updated_at: new Date().toISOString()
      });
    }
    
    res.json({ success: true });
  } catch (error) {
    console.error('Error saving current selection:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get('/api/customers', async (req, res) => {
  try {
    const entries = await fs.readdir(CUSTOMERS_DIR, { withFileTypes: true });
    const customers = entries
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name);
    res.json({ success: true, customers });
  } catch (error) {
    console.error('Error reading customers:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Create new customer
app.post('/api/customers', async (req, res) => {
  try {
    const { name } = req.body;
    if (!name || !name.trim()) {
      return res.status(400).json({ success: false, error: 'Customer name is required' });
    }
    const customerDir = path.join(CUSTOMERS_DIR, name.trim());
    // Check if already exists
    try {
      await fs.access(customerDir);
      return res.status(400).json({ success: false, error: 'Customer already exists' });
    } catch {
      // Does not exist, create it
    }
    await fs.mkdir(customerDir, { recursive: true });
    res.json({ success: true, customer: name.trim() });
  } catch (error) {
    console.error('Error creating customer:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get('/api/customers/:customer/plants', async (req, res) => {
  try {
    const customerDir = path.join(CUSTOMERS_DIR, req.params.customer);
    const entries = await fs.readdir(customerDir, { withFileTypes: true });
    const plants = entries
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name);
    res.json({ success: true, plants });
  } catch (error) {
    console.error('Error reading plants:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Create new plant for customer
app.post('/api/customers/:customer/plants', async (req, res) => {
  try {
    const { name } = req.body;
    if (!name || !name.trim()) {
      return res.status(400).json({ success: false, error: 'Plant name is required' });
    }
    const plantDir = path.join(CUSTOMERS_DIR, req.params.customer, name.trim());
    // Check if already exists
    try {
      await fs.access(plantDir);
      return res.status(400).json({ success: false, error: 'Plant already exists' });
    } catch {
      // Does not exist, create it
    }
    await fs.mkdir(plantDir, { recursive: true });
    res.json({ success: true, plant: name.trim() });
  } catch (error) {
    console.error('Error creating plant:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Check plant status and analyze configuration
app.get('/api/customers/:customer/plants/:plant/status', async (req, res) => {
  try {
    const plantDir = path.join(CUSTOMERS_DIR, req.params.customer, req.params.plant);
    const files = await fs.readdir(plantDir).catch(() => []);
    
    const hasStations = files.includes('stations.json');
    const hasTransporters = files.includes('transporters.json');
    const hasSimPurpose = files.includes('simulation_purpose.json');
    const treatmentPrograms = files.filter(f => /^treatment_program.*\.csv$/i.test(f));
    const hasTreatmentProgram = treatmentPrograms.length > 0;
    
    const isConfigured = hasStations && hasTransporters && hasSimPurpose && hasTreatmentProgram;
    
    let analysis = null;
    if (isConfigured) {
      // Analyze stations
      const stationsContent = await fs.readFile(path.join(plantDir, 'stations.json'), 'utf8');
      const stationsData = JSON.parse(stationsContent);
      // Handle both array and object with stations key
      const stations = Array.isArray(stationsData) ? stationsData : (stationsData.stations || []);
      const yPositions = [...new Set(stations.map(s => s.y_position))];
      const lineCount = yPositions.length;
      
      // Analyze transporters
      const transportersContent = await fs.readFile(path.join(plantDir, 'transporters.json'), 'utf8');
      const transportersData = JSON.parse(transportersContent);
      const transporterList = Array.isArray(transportersData)
        ? transportersData
        : Array.isArray(transportersData.transporters)
          ? transportersData.transporters
          : [];
      const transporterCount = transporterList.length;
      const models = transporterList.map(t => (t && t.model) || '2D');
      const model2D = models.filter(m => m === '2D').length;
      const model3D = models.filter(m => m === '3D').length;
      
      let transporterDesc = '';
      if (model2D > 0 && model3D > 0) {
        transporterDesc = `${model2D}x 2D + ${model3D}x 3D`;
      } else if (model3D > 0) {
        transporterDesc = `${model3D}x 3D`;
      } else {
        transporterDesc = `${model2D}x 2D`;
      }
      
      analysis = {
        lines: lineCount,
        transporters: transporterCount,
        transporterDesc,
        treatmentPrograms: treatmentPrograms.length,
        summary: `${lineCount} line${lineCount > 1 ? 's' : ''}, ${transporterDesc} transporter${transporterCount > 1 ? 's' : ''}, ${treatmentPrograms.length} program${treatmentPrograms.length > 1 ? 's' : ''}`
      };
    }
    
    res.json({
      success: true,
      isConfigured,
      hasStations,
      hasTransporters,
      hasSimPurpose,
      hasTreatmentProgram,
      treatmentProgramCount: treatmentPrograms.length,
      analysis
    });
  } catch (error) {
    console.error('Error checking plant status:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Copy template to plant
app.post('/api/customers/:customer/plants/:plant/copy-template', async (req, res) => {
  try {
    const { template, customer, plant, country, city } = req.body;
    if (!template) {
      return res.status(400).json({ success: false, error: 'Template name is required' });
    }
    
    const templateDir = path.join(PLANT_TEMPLATES_DIR, template);
    const plantDir = path.join(CUSTOMERS_DIR, req.params.customer, req.params.plant);
    
    // Check template exists
    try {
      await fs.access(templateDir);
    } catch {
      return res.status(404).json({ success: false, error: 'Template not found' });
    }
    
    // Ensure plant dir exists
    await fs.mkdir(plantDir, { recursive: true });
    
    // Copy all files from template to plant
    const files = await fs.readdir(templateDir);
    for (const file of files) {
      const srcPath = path.join(templateDir, file);
      const destPath = path.join(plantDir, file);
      const stat = await fs.stat(srcPath);
      if (stat.isFile()) {
        await fs.copyFile(srcPath, destPath);
      }
    }
    
    // Update simulation_purpose.json with customer info
    const simPurposePath = path.join(plantDir, 'simulation_purpose.json');
    try {
      const content = await fs.readFile(simPurposePath, 'utf8');
      const data = JSON.parse(content);
      data.customer = customer || req.params.customer;
      if (!data.plant) data.plant = {};
      data.plant.name = plant || req.params.plant;
      if (country) data.plant.country = country;
      if (city) data.plant.town = city;
      await fs.writeFile(simPurposePath, JSON.stringify(data, null, 2), 'utf8');
    } catch (err) {
      console.error('Error updating simulation_purpose.json:', err);
    }
    
    res.json({ success: true, copiedFiles: files.filter(f => !f.startsWith('.')) });
  } catch (error) {
    console.error('Error copying template:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Simulation purpose endpoints
app.get('/api/customers/:customer/plants/:plant/simulation-purpose', async (req, res) => {
  try {
    const filePath = path.join(CUSTOMERS_DIR, req.params.customer, req.params.plant, 'simulation_purpose.json');
    const content = await fs.readFile(filePath, 'utf8');
    const data = JSON.parse(content);
    res.json({ success: true, data });
  } catch (error) {
    console.error('Error reading simulation purpose:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.put('/api/customers/:customer/plants/:plant/simulation-purpose', async (req, res) => {
  try {
    const filePath = path.join(CUSTOMERS_DIR, req.params.customer, req.params.plant, 'simulation_purpose.json');
    const content = await fs.readFile(filePath, 'utf8');
    const data = JSON.parse(content);
    
    // Update only allowed fields
    const { country, city, purpose } = req.body;
    if (country !== undefined) data.plant.country = country;
    if (city !== undefined) data.plant.town = city;
    if (purpose !== undefined) data.purpose = purpose;
    
    await fs.writeFile(filePath, JSON.stringify(data, null, 2), 'utf8');
    res.json({ success: true, data });
  } catch (error) {
    console.error('Error updating simulation purpose:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Plant setup endpoints
app.get('/api/plant-setups', async (req, res) => {
  try {
    const plantSetupDir = PLANT_TEMPLATES_DIR;
    const entries = await fs.readdir(plantSetupDir, { withFileTypes: true });
    const setups = entries
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name);
    res.json({ setups, current: currentPlantSetup });
  } catch (error) {
    console.error('Error reading plant setups:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// List treatment programs available in the current plant setup
app.get('/api/treatment-programs', async (_req, res) => {
  try {
    const baseDir = isCustomerPlant ? CUSTOMERS_DIR : PLANT_TEMPLATES_DIR;
    const setupDir = path.join(baseDir, currentPlantSetup);
    const entries = await fs.readdir(setupDir);
    const programs = entries
      .map((name) => {
        const match = name.match(/treatment_program_(\d+)\.csv$/i);
        return match ? { number: Number(match[1]), filename: name } : null;
      })
      .filter((p) => p !== null && Number.isFinite(p.number))
      .sort((a, b) => a.number - b.number);
    // Return both full objects and legacy number array for compatibility
    res.json({ success: true, programs: programs.map(p => p.number), programDetails: programs });
  } catch (error) {
    console.error('Error reading treatment programs:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Production setup (start/finish stations and timing)
const defaultProductionSetup = () => ({
  start_station: null,
  finish_station: null,
  loading_time_s: 0,
  unloading_time_s: 0,
  duration_hours: null,
  plant_setup: currentPlantSetup,
  updated_at: new Date().toISOString()
});

const buildProductionPlan = async () => {
  const setup = await readJsonSafe(paths.productionSetup, defaultProductionSetup());
  const startStation = Number(setup.start_station);
  const finishStation = Number(setup.finish_station);
  if (!Number.isFinite(startStation) || startStation <= 0 || !Number.isFinite(finishStation) || finishStation <= 0) {
    return null;
  }

  const loadingIntervalMs = Math.max(1, Math.round((Number(setup.loading_time_s) || 0) * 1000));
  const unloadingMs = Math.max(0, Math.round((Number(setup.unloading_time_s) || 0) * 1000));

  const files = await listProductionFiles();
  const batchesData = await loadBatches();
  const existingIds = new Set((batchesData.batches || []).map((b) => Number(b.batch_id)));
  const queue = files
    .filter((f) => !existingIds.has(f.batchId))
    .map((f) => ({ batchId: f.batchId, program: f.program }));

  // Laske kokonaiserämäärä: jonossa olevat + jo linjalla olevat
  const totalBatches = files.length;

  return {
    startStation,
    finishStation,
    loadingIntervalMs,
    unloadingMs,
    queue,
    totalBatches,
    nextSpawnMs: 0,  // Ensimmäinen erä syntyy heti
    active: true,
    productionCompleted: false,
    reportsSaved: false
  };
};

app.get('/api/production-setup', async (_req, res) => {
  try {
    const data = await readJsonSafe(paths.productionSetup, defaultProductionSetup());
    res.json({ success: true, setup: data });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

app.post('/api/production-setup', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { start_station, finish_station, loading_time_s, unloading_time_s, duration_hours } = req.body || {};
      const toInt = (v, field) => {
        const n = Number(v);
        if (!Number.isFinite(n) || n < 0) {
          throw new Error(`${field} must be a non-negative number`);
        }
        return Math.round(n);
      };

      const setup = {
        start_station: Number.isFinite(Number(start_station)) ? Number(start_station) : null,
        finish_station: Number.isFinite(Number(finish_station)) ? Number(finish_station) : null,
        loading_time_s: toInt(loading_time_s || 0, 'loading_time_s'),
        unloading_time_s: toInt(unloading_time_s || 0, 'unloading_time_s'),
        duration_hours: Number.isFinite(Number(duration_hours)) ? Number(duration_hours) : null,
        plant_setup: currentPlantSetup,
        updated_at: new Date().toISOString()
      };

      await fs.writeFile(paths.productionSetup, JSON.stringify(setup, null, 2), 'utf8');
      
      // Also update simulation_purpose.json with duration
      if (Number.isFinite(Number(duration_hours))) {
        const simPurposePath = path.join(__dirname, '..', 'visualization', 'runtime', 'simulation_purpose.json');
        try {
          let simPurpose = {};
          try {
            const content = await fs.readFile(simPurposePath, 'utf8');
            simPurpose = JSON.parse(content);
          } catch (e) {
            // File doesn't exist, start fresh
          }
          simPurpose.simulation_duration = Number(duration_hours);
          await fs.writeFile(simPurposePath, JSON.stringify(simPurpose, null, 2), 'utf8');
          console.log('Updated simulation_purpose.json with duration:', duration_hours);
        } catch (err) {
          console.error('Failed to update simulation_purpose.json:', err);
        }
      }
      
      res.json({ success: true, setup });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  });
});

// Create new batch treatment CSV files in runtime based on requested counts
app.post('/api/production', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { pairs } = req.body || {};
      console.log('Received production request:', JSON.stringify(pairs));
      if (!Array.isArray(pairs) || pairs.length === 0) {
        console.warn('Production request failed: pairs array is required or empty');
        return res.status(400).json({ success: false, error: 'pairs array is required' });
      }

    const setupBaseDir = isCustomerPlant ? CUSTOMERS_DIR : PLANT_TEMPLATES_DIR;
    const setupDir = path.join(setupBaseDir, currentPlantSetup);
    const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');

    // Build a map of program -> actual filename (case-insensitive) to handle treatment_program_001.csv
    const setupFiles = await fs.readdir(setupDir);
    const programFileMap = new Map();
    setupFiles.forEach((name) => {
      const match = name.match(/treatment_program_(\d+)\.csv$/i);
      if (match) {
        const programNum = Number(match[1]);
        if (Number.isFinite(programNum)) {
          programFileMap.set(programNum, name);
        }
      }
    });

    const programCache = new Map();
    const ensureProgramExists = async (program) => {
      if (programCache.has(program)) return programCache.get(program);
      const filename = programFileMap.get(program) || `treatment_program_${pad3(program)}.csv`;
      const filepath = path.join(setupDir, filename);
      try {
        await fs.access(filepath);
        programCache.set(program, filepath);
        return filepath;
      } catch {
        return null;
      }
    };

    // Validate payload
    const normalized = [];
    for (const entry of pairs) {
      const count = Number(entry && entry.count);
      const program = Number(entry && entry.program);
      const startStation = entry && entry.start_station != null ? Number(entry.start_station) : null;
      const endStation = entry && entry.end_station != null ? Number(entry.end_station) : null;
      if (!Number.isInteger(count) || count <= 0) {
        return res.status(400).json({ success: false, error: 'count must be a positive integer' });
      }
      if (!Number.isInteger(program) || program <= 0) {
        return res.status(400).json({ success: false, error: 'program must be a positive integer' });
      }
      const src = await ensureProgramExists(program);
      if (!src) {
        return res.status(400).json({ success: false, error: `Program ${program} not found in ${currentPlantSetup}` });
      }
      normalized.push({ count, program, src, start_station: startStation, end_station: endStation });
    }

    // Delete all existing Batch files from runtime directory
    const runtimeFiles = await fs.readdir(runtimeDir);
    let deletedCount = 0;
    for (const file of runtimeFiles) {
      if (file.match(/^Batch_\d+_treatment_program_\d+\.csv$/i)) {
        try {
          await fs.unlink(path.join(runtimeDir, file));
          deletedCount++;
        } catch (err) {
          console.warn(`Could not delete ${file}:`, err.message);
        }
      }
    }
    console.log(`Production: Deleted ${deletedCount} old batch files`);

    // Päivitä production_setup.json start/finish asemat tuotantodatasta
    // Käytä ensimmäisen rivin start_station ja end_station
    const firstWithStart = normalized.find(n => Number.isFinite(n.start_station));
    const firstWithEnd = normalized.find(n => Number.isFinite(n.end_station));
    if (firstWithStart || firstWithEnd) {
      try {
        const currentSetup = await readJsonSafe(paths.productionSetup, {});
        if (firstWithStart) currentSetup.start_station = firstWithStart.start_station;
        if (firstWithEnd) currentSetup.finish_station = firstWithEnd.end_station;
        currentSetup.updated_at = new Date().toISOString();
        await fs.writeFile(paths.productionSetup, JSON.stringify(currentSetup, null, 2), 'utf8');
        console.log(`Production: Updated production_setup.json start=${currentSetup.start_station}, finish=${currentSetup.finish_station}`);
      } catch (err) {
        console.warn('Production: Could not update production_setup.json:', err.message);
      }
    }

    // Clear batches.json — Unitit säilyvät ennallaan (fyysisiä laitteita, ei liity tuotannon luontiin)
    await saveBatches({ batches: [] });
    console.log('Production: Cleared batches.json (units untouched)');

    // Create new batch files starting from 1
    let batchNumber = 0;
    const created = [];
    for (const { count, program, src } of normalized) {
      // Read source program file and add CalcTime column
      const sourceContent = await fs.readFile(src, 'utf8');
      // Normalize line endings: remove \r to handle Windows CRLF files
      const normalizedContent = sourceContent.replace(/\r/g, '');
      const lines = normalizedContent.split('\n').filter(line => line.trim());
      
      if (lines.length === 0) {
        throw new Error(`Empty treatment program file: ${src}`);
      }
      
      // Add CalcTime to header
      const header = lines[0];
      const modifiedHeader = header + ',CalcTime';
      
      // Process data lines: add MinTime value as CalcTime
      const modifiedLines = [modifiedHeader];
      for (let lineIdx = 1; lineIdx < lines.length; lineIdx++) {
        const line = lines[lineIdx];
        const columns = line.split(',');
        if (columns.length >= 5) {
          // columns[3] is MinTime
          const minTime = columns[3];
          const modifiedLine = line + ',' + minTime;
          modifiedLines.push(modifiedLine);
        } else {
          modifiedLines.push(line); // Keep invalid lines as-is
        }
      }
      
      const modifiedContent = modifiedLines.join('\n') + '\n';
      
      for (let i = 0; i < count; i += 1) {
        batchNumber += 1;
        const destName = `Batch_${pad3(batchNumber)}_treatment_program_${pad3(program)}.csv`;
        const destPath = path.join(runtimeDir, destName);
        await fs.writeFile(destPath, modifiedContent, 'utf8');
        created.push({ batch: batchNumber, program, file: destName });
      }
    }

    console.log(`Production: Created ${created.length} new batch files`);
    
    // Update runtime/simulation_purpose.json with treatment program batches
    const simPurposePath = path.join(runtimeDir, 'simulation_purpose.json');
    try {
      // Build treatment_program_batches array with per-program start/end stations
      const treatmentProgramBatches = [];
      for (const { count, program, start_station, end_station } of normalized) {
        const entry = {
          treatment_program: program,
          batches: count
        };
        // Only add start_station if explicitly set
        if (Number.isFinite(start_station)) {
          entry.start_station = start_station;
        }
        // Only add end_station if explicitly set
        if (Number.isFinite(end_station)) {
          entry.end_station = end_station;
        }
        treatmentProgramBatches.push(entry);
      }
      
      // Read existing simulation_purpose.json or create new
      let simPurpose = {};
      try {
        const existing = await fs.readFile(simPurposePath, 'utf8');
        simPurpose = JSON.parse(existing);
      } catch (err) {
        // File doesn't exist, create default structure
        simPurpose = {
          purpose: 'TEST',
          simulation_duration: 8,
          available_containers: 20
        };
      }
      
      // Update with new production data
      simPurpose.treatment_program_batches = treatmentProgramBatches;
      simPurpose.updated_at = new Date().toISOString();
      
      await fs.writeFile(simPurposePath, JSON.stringify(simPurpose, null, 2), 'utf8');
      console.log('Production: Updated runtime/simulation_purpose.json');
    } catch (err) {
      console.error('Error updating simulation_purpose.json:', err);
      // Don't fail the whole request if this fails
    }
    
      res.json({ success: true, createdCount: created.length, created, deletedCount });
    } catch (error) {
      console.error('Error creating production files:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

// Runtime simulation_purpose.json endpoint (read/write from runtime directory)
// This is the single source of truth for customer/plant selection AND production config
app.get('/api/simulation-purpose', async (_req, res) => {
  try {
    const data = await readJsonSafe(paths.simulationPurpose, {
      customer: null,
      plant: { name: null },
      purpose: 'TEST',
      treatment_program_batches: [],
      simulation_duration: 8,
      available_containers: 20
    });
    res.json({ success: true, data });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

app.put('/api/simulation-purpose', async (req, res) => {
  try {
    const data = req.body;
    data.updated_at = new Date().toISOString();
    await writeJsonAtomic(paths.simulationPurpose, data);
    res.json({ success: true, data });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Static configuration endpoints (read from plant_setup files)
app.get('/api/config/transporters', async (req, res) => {
  try {
    const transportersData = await loadJson(paths.transporters);
    res.json(transportersData);
  } catch (error) {
    console.error('Error reading transporters config:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get('/api/config/stations', async (req, res) => {
  try {
    const stationsData = await loadJson(paths.stations);
    res.json(stationsData);
  } catch (error) {
    console.error('Error reading stations config:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Schedule calculation API
app.get('/api/schedule/:batchId', async (req, res) => {
  try {
    const batchId = parseInt(req.params.batchId, 10);
    
    // PLC-arkkitehtuuri: Aikataulu lasketaan VAIN tilakoneessa
    // API vain lukee schedules.json:sta
    const schedulesData = await loadSchedules();
    const saved = schedulesData && schedulesData.schedules ? schedulesData.schedules[batchId] : null;
    
    if (!saved) {
      return res.status(404).json({ 
        success: false, 
        error: `Schedule for batch ${batchId} not found - state machine has not yet calculated it` 
      });
    }
    
    res.json({
      success: true,
      schedule: saved
    });
  } catch (error) {
    console.error('Error loading schedule:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Get all batch schedules
// PLC-arkkitehtuuri: Aikataulu lasketaan VAIN tilakoneessa
// API vain lukee schedules.json:sta
app.get('/api/schedules', async (req, res) => {
  try {
    const schedulesData = await loadSchedules();
    const savedSchedules = (schedulesData && schedulesData.schedules) || {};
    
    // Käytä tiedostosta luettua aikaa (jolloin schedules laskettiin)
    // Fallback nykyhetkeen vain jos tiedostossa ei ole aikaa
    const currentTimeSec = schedulesData?.currentTimeSec ?? (simTimeMs / 1000);

    // Return all schedules from state machine
    const schedules = Object.values(savedSchedules).filter(s => s && s.stages && s.stages.length > 0);
    
    // ═══════════════════════════════════════════════════════════════════════════
    // Yhdistä odottavien erien (stage 90) aikataulut departure-tilakoneesta.
    // TaskScheduler ohittaa stage-90 erien aikataulut SCHEDULE-vaiheessa,
    // mutta departureScheduler laskee ne CALC-vaiheessa.
    // Käytetään schedulesByBatchId:tä (pysyvä) eikä waitingSchedules:ia
    // (nollataan joka INIT-syklissä) → ei vilkuntaa API-kutsujen välillä.
    // batchStage: 90 on asetettu departureScheduler.js:ssä (rivi 415).
    // ═══════════════════════════════════════════════════════════════════════════
    const depState = departureScheduler.getState();
    if (depState && depState.schedulesByBatchId) {
      const existingBatchIds = new Set(schedules.map(s => String(s.batch_id)));
      for (const [batchId, schedule] of Object.entries(depState.schedulesByBatchId)) {
        if (schedule && schedule.batchStage === 90 && schedule.stages && schedule.stages.length > 0 && !existingBatchIds.has(String(batchId))) {
          schedules.push(schedule);
        }
      }
    }

    res.json({
      success: true,
      currentTimeSec,
      schedules
    });
  } catch (error) {
    console.error('Error reading schedules:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get('/api/transporter-tasks', async (req, res) => {
  try {
    res.json({
      success: true,
      // VAIHE 2: Lue tasks tiedostosta
      tasks: (await loadJson(paths.transporterTasks))?.tasks || [],
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
// TRANSPORTER SCHEDULE API - Nostin-aikajana (Gantt) visualisointia varten
// Palauttaa nostimien varatut ajanjaksot taskien perusteella + odottavien erien
// taskit erikseen. Käytetään schedule.html Transporters-välilehdessä.
// ═══════════════════════════════════════════════════════════════════════════════
app.get('/api/transporter-schedule', async (req, res) => {
  try {
    const tasksData = await loadJson(paths.transporterTasks);
    const tasks = tasksData?.tasks || [];
    const schedulesData = await loadSchedules();
    const currentTimeSec = schedulesData?.currentTimeSec ?? (simTimeMs / 1000);

    // Ryhmittele taskit nostimittain
    const transporterMap = {};
    const transporterCount = runtimeState.transporters?.length || 2;
    
    // Alusta kaikki nostimet
    for (let i = 1; i <= transporterCount; i++) {
      transporterMap[i] = { id: i, tasks: [] };
    }

    // In-flight taskit: nostin on juuri suorittamassa taskia (ei tasks-listalla)
    if (runtimeState.transporters) {
      for (const t of runtimeState.transporters) {
        const s = t.state;
        if (s && s.phase > 0 && s.current_task_batch_id != null) {
          // Nostin suorittaa juuri: lisää in-flight palkki
          const tId = t.id;
          if (transporterMap[tId]) {
            transporterMap[tId].tasks.push({
              batch_id: s.current_task_batch_id,
              stage: null, // Ei tiedossa
              lift_station_id: s.current_task_lift_station_id || s.lift_station_target,
              sink_station_id: s.current_task_sink_station_id || s.sink_station_target,
              task_start_time: null, // Menneisyydessä
              task_finished_time: s.current_task_est_finish_s || null,
              in_flight: true
            });
          }
        }
      }
    }

    // Jonossa olevat taskit
    for (const task of tasks) {
      const tId = task.transporter_id;
      if (tId != null && transporterMap[tId]) {
        transporterMap[tId].tasks.push({
          batch_id: task.batch_id,
          stage: task.stage,
          lift_station_id: task.lift_station_id,
          sink_station_id: task.sink_station_id,
          task_start_time: task.task_start_time,
          task_finished_time: task.task_finished_time,
          in_flight: false
        });
      }
    }

    // Odottavien erien taskit (departure sandbox)
    const waitingTasks = [];
    const depState = departureScheduler.getState();
    if (depState?.departureSandbox?.tasks) {
      for (const task of depState.departureSandbox.tasks) {
        if (task.transporter_id != null) {
          waitingTasks.push({
            batch_id: task.batch_id,
            stage: task.stage,
            transporter_id: task.transporter_id,
            lift_station_id: task.lift_station_id,
            sink_station_id: task.sink_station_id,
            task_start_time: task.task_start_time,
            task_finished_time: task.task_finished_time
          });
        }
      }
    }

    res.json({
      success: true,
      currentTimeSec,
      transporters: Object.values(transporterMap),
      waitingTasks,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error building transporter schedule:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Batch schedule CSV endpoints (for dashboard)
app.get('/api/batch-schedules/batches', async (req, res) => {
  try {
    await ensureDir(paths.batchSchedulesDir);
    const files = await fs.readdir(paths.batchSchedulesDir);
    const ids = new Set();
    for (const f of files) {
      const m = /^B(\d+)_(calculated|actual)\.csv$/i.exec(f);
      if (m) ids.add(Number(m[1]));
    }
    const batchIds = [...ids].filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
    res.json({ success: true, batchIds });
  } catch (error) {
    console.error('Error listing batch schedule CSVs:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get('/api/batch-schedules/:batchId', async (req, res) => {
  try {
    const batchId = parseInt(req.params.batchId, 10);
    if (!Number.isFinite(batchId)) {
      return res.status(400).json({ success: false, error: 'Invalid batchId' });
    }
    
    // CALCULATED: Prefer CSV (B{batchId}_calculated.csv) to show full planned curve; fallback to schedules.json
    const calcCsvPath = path.join(paths.batchSchedulesDir, `B${batchId}_calculated.csv`);
    let calculated = await parseBatchScheduleCsvFile(calcCsvPath);
    if (!Array.isArray(calculated) || calculated.length === 0) {
      try {
        const schedulesData = await loadSchedules();
        if (schedulesData.schedules && schedulesData.schedules[batchId]) {
          const jsonSchedule = schedulesData.schedules[batchId];
          if (jsonSchedule.stages && Array.isArray(jsonSchedule.stages)) {
            // Normalize to camelCase keys expected by dashboard (renderBatchChart)
            calculated = jsonSchedule.stages.map(stage => ({
              stage: stage.stage,
              station: stage.station ?? stage.station_id ?? null,
              entryTime_s: stage.entry_time_s ?? stage.entryTime_s ?? null,
              exitTime_s: stage.exit_time_s ?? stage.exitTime_s ?? null,
              calc_time_s: stage.calc_time_s ?? stage.calcTime_s ?? null,
              min_time_s: stage.min_time_s ?? stage.minTime_s ?? null,
              max_time_s: stage.max_time_s ?? stage.maxTime_s ?? null
            })).filter(r => r.station != null);
          }
        }
      } catch (jsonErr) {
        console.warn(`[SCHEDULE API] Could not load schedules.json for B${batchId}:`, jsonErr.message);
      }
    }
    
    // ACTUAL: Luetaan CSV (toteuma päivittyy reaaliajassa)
    const actualPath = path.join(paths.batchSchedulesDir, `B${batchId}_actual.csv`);
    const actual = await parseBatchScheduleCsvFile(actualPath);
    
    res.json({ success: true, batchId, calculated, actual });
  } catch (error) {
    console.error('Error reading batch schedule:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// TILAKONE API
// ═══════════════════════════════════════════════════════════════════════════════════════════════

// Get state machine status
app.get('/api/scheduler/state', async (req, res) => {
  try {
    const state = stateMachine.getStatus();
    
    // Yhdistä departure-tilakoneen linjaanlähtöväli TASKS-tilaan
    // Departure laskee avgDepartureIntervalSec aktivoinneista,
    // TASKS:in oma arvo on aina 0 (dead code).
    const depState = departureScheduler.getState();
    if (depState && typeof depState.avgDepartureIntervalSec === 'number' && depState.avgDepartureIntervalSec > 0) {
      state.avgDepartureIntervalSec = depState.avgDepartureIntervalSec;
      state.departureCount = depState.departureTimes?.length || 0;
    }
    
    // DEPARTURE cycle stats for dashboard (separate chart)
    state.departureCycles = {
      totalCycles: depState.totalCycles || 0,
      lastCycleTimeMs: depState.lastCycleTimeMs || 0,
      longestCycleTimeMs: depState.longestCycleTimeMs || 0,
      lastCycleTicks: depState.lastCycleTicks || 0,
      longestCycleTicks: depState.longestCycleTicks || 0,
      cycleTickPeriodMs: depState.cycleTickPeriodMs || 0,
      cycleHistory: depState.cycleHistory || [],
      cycleTickHistory: depState.cycleTickHistory || [],
      cycleSimTimeHistory: depState.cycleSimTimeHistory || []
    };
    
    // Calculate production progress stats
    const batchesData = await loadBatches();
    const batchesList = batchesData?.batches || [];
    const queueLength = productionPlan?.queue?.length || 0;
    const inProgressCount = batchesList.length;
    const totalBatches = productionPlan?.totalBatches || 0;
    const completedCount = Math.max(0, totalBatches - queueLength - inProgressCount);
    res.json({
      success: true,
      state,
      productionStats: {
        queueLength,
        inProgressCount,
        completedCount,
        totalBatches
      }
    });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// DASHBOARD API (hoist x-position history)
// ═══════════════════════════════════════════════════════════════════════════════════════════════

app.get('/api/dashboard/hoist-x', (req, res) => {
  try {
    const lineKey = normalizeLineKey(req.query.line);
    if (lineKey == null) {
      return res.status(400).json({ success: false, error: 'Invalid line. Use 100/200/300/400.' });
    }

    const buffers = hoistXHistory.buffersByLine.get(lineKey) || new Map();
    const series = [];
    for (const [transporterId, points] of buffers.entries()) {
      series.push({ transporterId, points: Array.isArray(points) ? points : [] });
    }
    series.sort((a, b) => a.transporterId - b.transporterId);

    const yDomain = getLineXDomain(lineKey);

    res.json({
      success: true,
      line: lineKey,
      windowMs: hoistXHistory.windowMs,
      sampleEveryMs: hoistXHistory.sampleEveryMs,
      nowSimTimeMs: simTimeMs,
      yDomain,
      series
    });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// STATION TIMING STATS API (for treatment time visualization)
// ═══════════════════════════════════════════════════════════════════════════════════════════════

/**
 * Palauttaa asemakohtaiset min/max/actual ajat viimeisille erille
 * Käyttö: visualisointi joka näyttää kuinka hyvin käsittelyajat pysyvät aikaikkunassa
 */
app.get('/api/station-timing-stats', async (req, res) => {
  try {
    // 1. Lataa kaikki eri käsittelyohjelmien min/max ajat asemittain
    const stationLimits = new Map(); // station -> { min_s, max_s }
    
    // Käy läpi erien käsittelyohjelmat
    const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
    const files = await fs.readdir(runtimeDir);
    
    for (const file of files) {
      if (!/^Batch_\d+_treatment_program_\d+\.csv$/i.test(file)) continue;
      
      const m = file.match(/^Batch_(\d+)_treatment_program_(\d+)\.csv$/i);
      if (!m) continue;
      
      const batchId = Number(m[1]);
      const programNum = Number(m[2]);
      
      try {
        const program = await loadTreatmentProgram(batchId, programNum);
        for (const stage of program) {
          const station = Number(stage.min_station);
          if (!Number.isFinite(station)) continue;
          
          // Parse min/max times (HH:MM:SS -> seconds)
          const parseTime = (t) => {
            if (!t) return 0;
            const parts = String(t).split(':').map(Number);
            if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
            if (parts.length === 2) return parts[0] * 60 + parts[1];
            return Number(t) || 0;
          };
          
          const minS = parseTime(stage.min_time);
          const maxS = parseTime(stage.max_time);
          
          // Tallenna (käytä suurinta max ja pienintä min jos useita eriä)
          const existing = stationLimits.get(station);
          if (!existing) {
            stationLimits.set(station, { min_s: minS, max_s: maxS });
          } else {
            existing.min_s = Math.min(existing.min_s, minS);
            existing.max_s = Math.max(existing.max_s, maxS);
          }
        }
      } catch (err) {
        // Ohita virheelliset tiedostot
      }
    }
    
    // 2. Lataa actual-ajat erittäin (viimeiset 10 erää)
    const batchActuals = []; // [{ batchId, stations: [{ station, duration_s }] }]
    
    // Lue batch_schedules kansion tiedostot
    let batchScheduleFiles = [];
    try {
      batchScheduleFiles = await fs.readdir(paths.batchSchedulesDir);
    } catch (err) {
      // Kansio ei ehkä vielä ole olemassa
    }
    
    const actualFiles = batchScheduleFiles
      .filter(f => /^B\d+_actual\.csv$/i.test(f))
      .map(f => {
        const m = f.match(/^B(\d+)_actual\.csv$/i);
        return m ? { file: f, batchId: Number(m[1]) } : null;
      })
      .filter(Boolean)
      .sort((a, b) => b.batchId - a.batchId) // Uusimmat ensin
      .slice(0, 10); // 10 viimeisintä
    
    for (const { file, batchId } of actualFiles) {
      try {
        const csv = await fs.readFile(path.join(paths.batchSchedulesDir, file), 'utf8');
        const lines = csv.split(/\r?\n/).filter(l => l.trim());
        const stations = [];
        
        for (let i = 1; i < lines.length; i++) {
          const cols = lines[i].split(',');
          const station = Number(cols[0]);
          const entry = cols[1] ? Number(cols[1]) : null;
          const exit = cols[2] ? Number(cols[2]) : null;
          
          if (Number.isFinite(station) && entry !== null && exit !== null) {
            stations.push({ station, duration_s: exit - entry });
          }
        }
        
        batchActuals.push({ batchId, stations });
      } catch (err) {
        // Ohita virheelliset tiedostot
      }
    }
    
    // 3. Muodosta vastaus
    const stationList = [...stationLimits.keys()].sort((a, b) => a - b);
    
    res.json({
      success: true,
      stations: stationList.map(st => ({
        station: st,
        min_s: stationLimits.get(st)?.min_s || 0,
        max_s: stationLimits.get(st)?.max_s || 0
      })),
      batches: batchActuals.reverse() // Vanhimmasta uusimpaan (piirretään vasemmalta oikealle)
    });
    
  } catch (error) {
    console.error('Error getting station timing stats:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Get tasks from state machine (validated)
app.get('/api/scheduler/tasks', (req, res) => {
  try {
    const tasks = stateMachine.getTasks();
    const state = stateMachine.getStatus();
    
    res.json({
      success: true,
      canAssign: stateMachine.canAssignTasks(),
      phase: state.phase,
      phaseName: state.phaseName,
      taskCount: tasks.length,
      tasks
    });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Request recalculation
app.post('/api/scheduler/recalc', (req, res) => {
  return withScanLock(async () => {
    try {
      // recalc no longer needed — state machine runs continuously
      res.json({ success: true, message: 'Recalculation requested' });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

// Start state machine
app.post('/api/scheduler/start', (req, res) => {
  return withScanLock(async () => {
    try {
      stateMachine.start();
      res.json({ success: true, message: 'State machine started' });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

app.post('/api/plant-setup', async (req, res) => {
    console.log('[DEBUG] /api/plant-setup endpoint called. Stacktrace:');
    console.trace();
  return withScanLock(async () => {
    try {
      const { setup } = req.body;
      if (!setup) {
        return res.status(400).json({ success: false, error: 'setup name is required' });
      }
    
    const plantSetupDir = path.join(PLANT_TEMPLATES_DIR, setup);
    const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
    
    try {
      await fs.access(plantSetupDir);
    } catch {
      return res.status(404).json({ success: false, error: 'Plant setup not found' });
    }
    
    // Only copy CSV files (treatment programs) to runtime
    // Config files (json) are read directly from plant_setup folder
    const setupFiles = await fs.readdir(plantSetupDir);
    const copiedFiles = [];
    
    for (const file of setupFiles) {
      if (!file.endsWith('.csv')) continue;
      
      const srcPath = path.join(plantSetupDir, file);
      const destPath = path.join(runtimeDir, file);
      
      try {
        const stat = await fs.stat(srcPath);
        if (stat.isFile()) {
          const srcContent = await fs.readFile(srcPath, 'utf8');
          
          await fs.writeFile(destPath, srcContent, 'utf8');
          copiedFiles.push(file);
          console.log(`Copied ${file} from ${setup} to runtime`);
        }
      } catch (err) {
        console.warn(`Could not copy ${file}:`, err.message);
      }
    }
    
    currentPlantSetup = setup;
    isCustomerPlant = false; // Using template, not customer plant
    paths = getPaths(); // Refresh paths for new setup
    cachedMovementTimes = null;
    cachedMovementTimesPlantSetup = null;
    cachedNoTreatmentTasks = null;
    console.log(`Plant setup changed to: ${currentPlantSetup}, copied ${copiedFiles.length} CSV files`);
      res.json({ success: true, setup: currentPlantSetup, copiedFiles });
    } catch (error) {
      console.error('Error changing plant setup:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

// Copy customer plant files to be used in simulation
app.post('/api/copy-customer-plant', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { customer, plant } = req.body;
      if (!customer || !plant) {
        return res.status(400).json({ success: false, error: 'customer and plant are required' });
      }

      const customerPlantDir = path.join(CUSTOMERS_DIR, customer, plant);
      const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
      
      // Check if customer plant directory exists
      try {
        await fs.access(customerPlantDir);
      } catch {
        return res.status(404).json({ success: false, error: 'Customer plant not found' });
      }
      
      // Update paths to use customer plant directory
      currentPlantSetup = `${customer}/${plant}`;
      isCustomerPlant = true;
      
      // Refresh paths for customer plant
      paths = getPaths();
      cachedMovementTimes = null;
      cachedMovementTimesPlantSetup = null;
      cachedNoTreatmentTasks = null;
      
      // Copy CSV files to runtime
      const setupFiles = await fs.readdir(customerPlantDir);
      const copiedFiles = [];
      
      for (const file of setupFiles) {
        if (!file.endsWith('.csv')) continue;
        
        const srcPath = path.join(customerPlantDir, file);
        const destPath = path.join(runtimeDir, file);
        
        try {
          const stat = await fs.stat(srcPath);
          if (stat.isFile()) {
            const srcContent = await fs.readFile(srcPath, 'utf8');
            await fs.writeFile(destPath, srcContent, 'utf8');
            copiedFiles.push(file);
            console.log(`Copied ${file} from ${customer}/${plant} to runtime`);
          }
        } catch (err) {
          console.warn(`Could not copy ${file}:`, err.message);
        }
      }
      
      // Reset transporter states
      stopLoop();
      simTimeMs = 0;
      lastBatchLocations.clear();
      
      const transportersData = await loadJson(paths.transporters);
      const stationsData = await loadJson(paths.stations);
      
      const resetStates = transportersData.transporters.map(transporter => {
        const startStation = stationsData.stations.find(
          s => s.number === transporter.start_station
        );
        
        const x_min_drive_limit = transporter.x_min_drive_limit || 0;
        const x_max_drive_limit = transporter.x_max_drive_limit || 0;
        const y_min_drive_limit = transporter.y_min_drive_limit || 0;
        const y_max_drive_limit = transporter.y_max_drive_limit || 0;
        const z_min_drive_limit = transporter.z_min_drive_limit || 0;
        const z_max_drive_limit = transporter.z_max_drive_limit || 0;
        
        const is3D = transporter.model === "3D";
        const z_idle_height = is3D && transporter.physics_3D ? (transporter.physics_3D.z_idle_height_mm || 100) : 0;
        const initialZPosition = is3D ? z_idle_height : z_min_drive_limit;
        
        return {
          id: transporter.id,
          model: transporter.model || "2D",
          state: {
            phase: 0,
            x_position: startStation?.x_position ?? 0,
            y_position: startStation?.y_position ?? 0,
            z_position: initialZPosition,
            x_target: startStation?.x_position ?? 0,
            y_target: startStation?.y_position ?? 0,
            z_target: initialZPosition,
            payload: null,
            z_stage: 'idle',
            z_timer: 0,
            x_min_drive_limit,
            x_max_drive_limit,
            y_min_drive_limit,
            y_max_drive_limit,
            z_min_drive_limit,
            z_max_drive_limit,
          }
        };
      });
      
      transporterStates = resetStates;
      await writeJsonAtomic(paths.states, { transporters: resetStates });
      await writeJsonAtomic(paths.batches, []);
      await writeJsonAtomic(paths.transporterTasks, { tasks: [] });
      
      res.json({ 
        success: true, 
        copiedFiles,
        customer,
        plant,
        transporterCount: resetStates.length
      });
    } catch (error) {
      console.error('Error copying customer plant:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

app.post('/api/copy-plant-setup', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { setup } = req.body;
      if (!setup) {
        return res.status(400).json({ success: false, error: 'setup name is required' });
      }

    // Switch setup first so subsequent config reads use the correct plant_setup folder
    currentPlantSetup = setup;
    isCustomerPlant = false; // Using template, not customer plant
    paths = getPaths();
    cachedMovementTimes = null;
    cachedMovementTimesPlantSetup = null;
    cachedNoTreatmentTasks = null;
    
    const plantSetupDir = path.join(PLANT_TEMPLATES_DIR, setup);
    const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
    
    // Check if plant setup directory exists
    try {
      await fs.access(plantSetupDir);
    } catch {
      return res.status(404).json({ success: false, error: 'Plant setup not found' });
    }
    
    // Only copy runtime files (CSV) from plant setup to runtime directory
    // Config files (json) are read directly from plant_setup folder
    const setupFiles = await fs.readdir(plantSetupDir);
    const copiedFiles = [];
    
      for (const file of setupFiles) {
        // Only copy CSV files to runtime (treatment programs)
        if (!file.endsWith('.csv')) continue;
        
        const srcPath = path.join(plantSetupDir, file);
        const destPath = path.join(runtimeDir, file);
        
        try {
          const stat = await fs.stat(srcPath);
          if (stat.isFile()) {
            const srcContent = await fs.readFile(srcPath, 'utf8');
            
            await fs.writeFile(destPath, srcContent, 'utf8');
            
            // Verify file was written correctly by reading it back
            const destContent = await fs.readFile(destPath, 'utf8');
            if (srcContent !== destContent) {
              throw new Error(`File verification failed for ${file}`);
            }
            
            copiedFiles.push(file);
            console.log(`Copied ${file} from ${setup} to runtime`);
          }
        } catch (err) {
          console.warn(`Could not copy ${file}:`, err.message);
        }
      }    // Reset transporter states to match new configuration
    stopLoop();
    simTimeMs = 0;
    lastBatchLocations.clear();
    
    const transportersData = await loadJson(paths.transporters);
    const stationsData = await loadJson(paths.stations);
    
    const resetStates = transportersData.transporters.map(transporter => {
      const startStation = stationsData.stations.find(
        s => s.number === transporter.start_station
      );
      
      const x_min_drive_limit = transporter.x_min_drive_limit || 0;
      const x_max_drive_limit = transporter.x_max_drive_limit || 0;
      const y_min_drive_limit = transporter.y_min_drive_limit || 0;
      const y_max_drive_limit = transporter.y_max_drive_limit || 0;
      const z_min_drive_limit = transporter.z_min_drive_limit || 0;
      const z_max_drive_limit = transporter.z_max_drive_limit || 0;
      
      const is3D = transporter.model === "3D";
      const z_idle_height = is3D && transporter.physics_3D ? (transporter.physics_3D.z_idle_height_mm || 100) : 0;
      const initialZPosition = is3D ? z_idle_height : z_min_drive_limit;
      
      return {
        id: transporter.id,
        model: transporter.model,
        state: {
          x_position: startStation ? startStation.x_position : 0,
          y_position: y_min_drive_limit,
          z_position: initialZPosition,
          operation: "idle",
          current_station: transporter.start_station,
          load: null,
          velocity_x: 0,
          phase: 0,
          target_x: startStation ? startStation.x_position : 0,
          z_stage: "idle",
          z_timer: 0,
          velocity_z: 0,
          pending_batch_id: null,
          initial_delay: 0,
          x_min_drive_limit,
          x_max_drive_limit,
          y_min_drive_limit,
          y_max_drive_limit,
          z_min_drive_limit,
          z_max_drive_limit
        }
      };
    });
    
    await saveStates({ transporters: resetStates });
    
    // Verify states were written correctly
    const savedStates = await loadStates();
    if (!savedStates.transporters || savedStates.transporters.length !== resetStates.length) {
      throw new Error('Failed to verify saved transporter states');
    }
    
    // VAIHE 2: Päivitä vain server:in omistamat tiedot muistiin
    runtimeState.transporters = resetStates;

    // Reset avoid statuses for the new station list
    const avoidStatusData = { stations: {} };
    for (const station of stationsData.stations || []) {
      avoidStatusData.stations[station.number] = { avoid_status: 0 };
    }
    runtimeState.avoidStatuses = avoidStatusData.stations;
    await writeJsonAtomic(paths.avoidStatuses, avoidStatusData);

    // Persist the full cleared runtime snapshot
    await saveRuntimeState();

    console.log(`Plant setup ${setup} activated, files copied, and runtime state reset and verified`);
      res.json({ success: true, setup: currentPlantSetup, transporters: resetStates });
    } catch (error) {
      console.error('Error copying plant setup:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  });
});

// Initialize server - no file copying needed, reading directly from plant_setup
(async () => {
  try {
    // Ensure runtime directory exists
    const runtimeDir = path.join(__dirname, '..', 'visualization', 'runtime');
    try {
      await fs.access(runtimeDir);
    } catch {
      await fs.mkdir(runtimeDir, { recursive: true });
      console.log('Created runtime directory');
    }
    
    if (currentPlantSetup) {
      console.log(`Initializing plant setup: ${currentPlantSetup}`);
      // Lataa runtime-tila muistiin käynnistyksessä
      await loadRuntimeState();
      console.log(`Plant setup ready: ${currentPlantSetup}`);
    } else {
      console.log('No plant setup selected — waiting for customer/plant selection via RESET');
    }
  } catch (err) {
    console.error('Error initializing:', err.message);
  }
  
  // Start server
  app.listen(PORT, () => {
    console.log(`PLC Simulator server running on http://localhost:${PORT}`);
    console.log(`API available at http://localhost:${PORT}/api`);
    console.log(`Current plant setup: ${currentPlantSetup}`);
  });
})();

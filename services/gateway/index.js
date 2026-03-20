/**
 * CODESYS OPC UA Gateway
 *
 * Thin Node.js gateway that reads PLC state via OPC UA
 * and serves REST API compatible with the existing React/Vite UI.
 *
 * Replaces Modbus TCP with OPC UA via the PlcAdapter abstraction.
 * All REST endpoint signatures remain identical for UI compatibility.
 */

const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs');

// OPC UA adapter (replaces modbus-serial + modbus_map.js)
const OpcuaAdapter = require('./opcua_adapter');
const adapter = new OpcuaAdapter();

// Event consumer + PostgreSQL
const dbPool = require('./db');
const { processEvents, checkDb } = require('./event_consumer');

// File-based routes (customer/plant mgmt, batch CRUD, production, etc.)
const fileRoutes = require('./file_routes');

// Legacy stub endpoints (sim control, scheduler, etc.)
const legacyStubs = require('./legacy_stubs');

// Production queue dispatcher
const dispatcher = require('./production_dispatcher');

// ── Simulation log helper ─────────────────────────────────────────
async function simLog(event, detail = null) {
  try {
    await dbPool.query(
      `INSERT INTO sim_log (event, customer, plant, detail) VALUES ($1, $2, $3, $4)`,
      [event, currentCustomer || null, currentPlant || null, detail ? JSON.stringify(detail) : null]
    );
    console.log(`[SIM-LOG] ${event} — ${currentCustomer}/${currentPlant}`);
  } catch (err) {
    console.error(`[SIM-LOG] Failed to log '${event}': ${err.message}`);
  }
}

// --- Configuration ---
const API_PORT = parseInt(process.env.API_PORT || '3001');
const POLL_MS = parseInt(process.env.POLL_MS || '100');
const TIME_SYNC_MS = parseInt(process.env.TIME_SYNC_MS || '60000');

// Customers root directory
const CUSTOMERS_ROOT = process.env.CUSTOMERS_ROOT ||
  (fs.existsSync('/data/customers')
    ? '/data/customers'
    : path.join(__dirname, '..', '..', 'data', 'customers'));

const PLANT_TEMPLATES_ROOT = process.env.PLANT_TEMPLATES_ROOT ||
  (fs.existsSync('/data/plant_templates')
    ? '/data/plant_templates'
    : path.join(__dirname, '..', '..', 'data', 'plant_templates'));

const RUNTIME_ROOT = process.env.RUNTIME_ROOT ||
  (fs.existsSync('/data/runtime')
    ? '/data/runtime'
    : path.join(__dirname, '..', '..', 'data', 'runtime'));

// Current selection — empty on startup, set by user via RESET
let currentCustomer = '';
let currentPlant = '';

function getCustomerPath(customer, plant) {
  return path.join(CUSTOMERS_ROOT, customer || currentCustomer, plant || currentPlant);
}
function getCurrentCustomerPath() {
  return getCustomerPath(currentCustomer, currentPlant);
}

// --- Mappings ---
const TARGET_INT_TO_STR = { 0: 'none', 1: 'to_loading', 2: 'to_buffer', 3: 'to_process', 4: 'to_unload', 5: 'to_avoid' };
const TARGET_STR_TO_INT = Object.fromEntries(Object.entries(TARGET_INT_TO_STR).map(([k, v]) => [v, parseInt(k)]));
const BATCH_STATE_INT_TO_STR = { 0: 'not_processed', 1: 'in_process', 2: 'processed' };

// --- State cache (updated by polling loop) ---
let plcState = { timestamp: new Date().toISOString(), transporters: [] };
let plcMeta = { station_count: 0, init_done: false, cycle_count: 0 };
let plcAlive = false;
let simStartTime = Date.now();
let simRunning = false;
let plcUnits = [];
let depState = {};
let schedulerDebug = {};
let twaLimits = { 1: { x_min: 0, x_max: 0 }, 2: { x_min: 0, x_max: 0 }, 3: { x_min: 0, x_max: 0 } };
let plcTaskQueues = { 1: { count: 0, tasks: [] }, 2: { count: 0, tasks: [] }, 3: { count: 0, tasks: [] } };
let plcSchedules = [];

// Schedule sliding window
let scheduleTickCounter = 0;
const SCHEDULE_POLL_TICKS = 2;
let schReqUnit = 0;

// Time sync
let lastTimeSyncMs = 0;

// Transporter + station configs (loaded from customer JSON)
let transporterConfig = { transporters: [] };
let stationsConfig = { stations: [] };

function loadConfigs() {
  if (!currentCustomer || !currentPlant) {
    transporterConfig = { transporters: [] };
    stationsConfig = { stations: [] };
    return;
  }
  const cp = getCurrentCustomerPath();
  try {
    transporterConfig = JSON.parse(fs.readFileSync(path.join(cp, 'transporters.json'), 'utf8'));
    stationsConfig = JSON.parse(fs.readFileSync(path.join(cp, 'stations.json'), 'utf8'));
    console.log(`[CONFIG] Loaded ${transporterConfig.transporters.length} transporters, ${stationsConfig.stations.length} stations`);
  } catch (err) {
    console.error('[CONFIG] Failed to load configs:', err.message);
  }
}

// ── Polling loop ──────────────────────────────────────────────
let pollTimer = null;
let polling = false;
let pausePolling = false;

function startPolling() {
  pollTimer = setInterval(async () => {
    if (polling || pausePolling) return;
    polling = true;
    try {
      if (!adapter.isConnected()) {
        await adapter.connect();
        return;
      }

      // Periodic time sync
      const now = Date.now();
      if (now - lastTimeSyncMs >= TIME_SYNC_MS) {
        const unixSec = Math.floor(now / 1000);
        await adapter.writeTime(unixSec);
        lastTimeSyncMs = now;
        console.log(`[TIME] Synced PLC time: ${unixSec}`);
      }

      // Read full state
      const state = await adapter.readState();
      if (!state) return;

      // Update caches
      plcState = { timestamp: state.timestamp, transporters: state.transporters };
      plcUnits = state.units;
      plcMeta = state.meta;
      twaLimits = state.twaLimits;
      plcTaskQueues = state.taskQueues;
      depState = state.depState;
      schedulerDebug = state.schedulerDebug;
      plcAlive = true;

      if (plcMeta.init_done && !simRunning) {
        simRunning = true;
        simStartTime = Date.now();
        console.log('[PLC] Init done, simulation running');
      }

      // Schedule sliding window
      scheduleTickCounter++;
      if (scheduleTickCounter >= SCHEDULE_POLL_TICKS) {
        scheduleTickCounter = 0;
        schReqUnit = (schReqUnit % 10) + 1;
        const sched = await adapter.readScheduleWindow(schReqUnit);
        if (sched && sched.stages.length > 0) {
          const unitInfo = plcUnits.find(pu => pu.unit_id === schReqUnit);
          const entry = {
            batch_id: schReqUnit,
            batchStage: unitInfo ? unitInfo.batch_stage : 0,
            batchState: unitInfo ? unitInfo.batch_state_int : 0,
            stage_count: sched.stage_count,
            total_duration_s: sched.stages[sched.stages.length - 1].exit_time_s - sched.stages[0].entry_time_s,
            stages: sched.stages,
          };
          const idx = plcSchedules.findIndex(s => s.batch_id === schReqUnit);
          if (idx >= 0) plcSchedules[idx] = entry;
          else plcSchedules.push(entry);
        } else {
          const idx = plcSchedules.findIndex(s => s.batch_id === schReqUnit);
          if (idx >= 0) plcSchedules.splice(idx, 1);
        }
      }

      // Production queue dispatcher
      if (plcMeta.init_done) {
        await dispatcher.tick(plcUnits);
      }

      // Process PLC event queue
      await processEvents(adapter, dbPool);

    } catch (err) {
      console.error(`[POLL] tick error: ${err.message}`);
    } finally {
      polling = false;
    }
  }, POLL_MS);
}

// --- Express server ---
const app = express();
app.use(cors());
app.use(express.json());

// ── Initialize & mount file-based routes ──
fileRoutes.init({
  getCurrentSelection: () => ({ customer: currentCustomer, plant: currentPlant }),
  setCurrentSelection: (c, p) => { currentCustomer = c; currentPlant = p; loadConfigs(); },
});
app.use('/api', fileRoutes.router);

// ── Initialize & mount legacy stub routes ──
legacyStubs.init({
  getSimTime: () => ({ running: simRunning }),
});
app.use('/api', legacyStubs.router);

// Serve static visualization files
app.use(express.static(path.join(__dirname, 'public')));

// Serve static config files from current customer/plant
app.get('/api/config/:filename', (req, res) => {
  let filePath = path.join(getCurrentCustomerPath(), req.params.filename);
  if (!fs.existsSync(filePath) && !req.params.filename.endsWith('.json')) {
    filePath = filePath + '.json';
  }
  if (fs.existsSync(filePath)) {
    res.json(JSON.parse(fs.readFileSync(filePath, 'utf8')));
  } else {
    res.status(404).json({ error: `Config file not found: ${req.params.filename}` });
  }
});

app.put('/api/config/:filename', (req, res) => {
  try {
    let filename = req.params.filename;
    if (!filename.endsWith('.json')) filename += '.json';
    const allowedFiles = ['layout_config.json'];
    if (!allowedFiles.includes(filename)) {
      return res.status(403).json({ success: false, error: `Cannot update config file: ${filename}` });
    }
    const filePath = path.join(getCurrentCustomerPath(), filename);
    fs.writeFileSync(filePath, JSON.stringify(req.body, null, 2));
    res.json({ success: true, message: `Config file ${filename} updated` });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// ============================================================
// Avoid status
// ============================================================
let avoidStatuses = {};

app.get('/api/avoid-statuses', (req, res) => {
  res.json({ stations: avoidStatuses, timestamp: new Date().toISOString() });
});

app.post('/api/avoid-statuses', async (req, res) => {
  try {
    const { stationNumber, avoid_status } = req.body;
    if (!stationNumber || typeof avoid_status !== 'number') {
      return res.status(400).json({ success: false, error: 'stationNumber and avoid_status are required' });
    }
    if (!adapter.isConnected()) {
      return res.status(503).json({ success: false, error: 'PLC not connected' });
    }
    await adapter.writeAvoidStatus(parseInt(stationNumber), avoid_status);
    avoidStatuses[stationNumber] = { avoid_status };
    res.json({ success: true, stationNumber: parseInt(stationNumber), avoid_status });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Main state endpoint (polled every 400ms by UI)
app.get('/api/transporter-states', (req, res) => {
  res.json(plcState);
});

app.post('/api/transporter-states', (req, res) => {
  res.json(plcState);
});

// --- Manual task tracking ---
let manualTasks = [];
let manualTaskSeq = 0;

app.post('/api/command/move', async (req, res) => {
  try {
    const { transporterId, liftStation, sinkStation, lift_station, sink_station } = req.body;
    const lift = liftStation || lift_station;
    const sink = sinkStation || sink_station;
    if (!transporterId || !lift || !sink) {
      return res.status(400).json({ error: 'Missing transporterId, liftStation, sinkStation' });
    }
    await adapter.writeCommand(transporterId, lift, sink);
    manualTaskSeq++;
    const task = {
      id: manualTaskSeq,
      transporterId,
      liftStation: lift,
      sinkStation: sink,
      status: 'queued',
      createdAt: new Date().toISOString(),
    };
    manualTasks.push(task);
    setTimeout(() => { manualTasks = manualTasks.filter(t => t.id !== task.id); }, 60000);
    res.json({ ok: true, queued: true, taskId: task.id });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/manual-tasks', (req, res) => {
  res.json({ tasks: manualTasks });
});

app.delete('/api/manual-tasks/:id', (req, res) => {
  const id = parseInt(req.params.id);
  manualTasks = manualTasks.filter(t => t.id !== id);
  res.json({ ok: true });
});

// Task queue from PLC
app.get('/api/transporter-tasks', (req, res) => {
  const tasks = [];
  for (const tid of [1, 2, 3]) {
    const tq = plcTaskQueues[tid];
    if (!tq) continue;
    for (const task of tq.tasks) {
      tasks.push({
        transporter_id: tid,
        unit_id: task.unit_id,
        stage: task.stage,
        lift_station_id: task.lift_station,
        sink_station_id: task.sink_station,
        task_start_time: task.start_time,
        task_finished_time: task.finish_time,
        calc_time: task.calc_time,
        min_time: task.min_time,
        max_time: task.max_time,
        is_manual: false,
      });
    }
  }
  tasks.sort((a, b) => a.task_start_time - b.task_start_time);
  res.json({ tasks });
});

// Unit schedules (Gantt chart)
app.get('/api/schedules', (req, res) => {
  res.json({
    success: true,
    currentTimeSec: Math.floor(Date.now() / 1000),
    schedules: plcSchedules,
  });
});

// Transporter schedule (Gantt)
app.get('/api/transporter-schedule', (req, res) => {
  const currentTimeSec = Math.floor(Date.now() / 1000);
  const transporterSchedule = [];
  for (const tid of [1, 2, 3]) {
    const tq = plcTaskQueues[tid];
    if (!tq) continue;
    const slots = tq.tasks.map(task => ({
      transporter_id: tid,
      unit_id: task.unit_id,
      lift_station: task.lift_station,
      sink_station: task.sink_station,
      start_time_s: task.start_time,
      end_time_s: task.finish_time,
    }));
    transporterSchedule.push({ transporter_id: tid, task_count: tq.count, slots });
  }
  res.json({ success: true, currentTimeSec, transporters: transporterSchedule });
});

// Legacy alias
app.post('/api/reset-transporters', (req, res) => {
  res.json({ ok: true, message: 'Use /api/reset instead' });
});

// ============================================================
// RESET — Upload station config to PLC via OPC UA
// ============================================================
app.post('/api/reset', async (req, res) => {
  try {
    const { customer, plant } = req.body;
    if (!customer || !plant) {
      return res.status(400).json({ success: false, error: 'customer and plant required' });
    }

    const plantPath = getCustomerPath(customer, plant);
    const stationsFile = path.join(plantPath, 'stations.json');
    const tanksFile = path.join(plantPath, 'tanks.json');
    const transportersFile = path.join(plantPath, 'transporters.json');

    if (!fs.existsSync(stationsFile)) {
      return res.status(404).json({ success: false, error: 'stations.json not found' });
    }

    const stationsRaw = JSON.parse(fs.readFileSync(stationsFile, 'utf8'));
    const stations = Array.isArray(stationsRaw) ? stationsRaw : (stationsRaw.stations || []);
    const tanksRaw = fs.existsSync(tanksFile) ? JSON.parse(fs.readFileSync(tanksFile, 'utf8')) : [];
    const tanks = Array.isArray(tanksRaw) ? tanksRaw : (tanksRaw.tanks || []);
    const transportersRaw = fs.existsSync(transportersFile) ? JSON.parse(fs.readFileSync(transportersFile, 'utf8')) : [];
    const transporters = Array.isArray(transportersRaw) ? transportersRaw : (transportersRaw.transporters || []);

    if (!adapter.isConnected()) {
      return res.status(503).json({ success: false, error: 'PLC not connected' });
    }

    // Pause poll loop
    pausePolling = true;
    while (polling) await new Promise(r => setTimeout(r, 10));

    // Load NTT data
    const nttFile = path.join(plantPath, 'no_treatment_tasks.json');
    const nttData = fs.existsSync(nttFile)
      ? JSON.parse(fs.readFileSync(nttFile, 'utf8'))
      : null;

    // Load unit setup
    const unitSetupFile = path.join(plantPath, 'unit_setup.json');
    let units = [];
    if (fs.existsSync(unitSetupFile)) {
      const unitRaw = JSON.parse(fs.readFileSync(unitSetupFile, 'utf8'));
      units = Array.isArray(unitRaw) ? unitRaw : (unitRaw.units || []);
    }

    // Upload config via adapter
    const result = await adapter.uploadConfig({
      stations,
      transporters,
      units,
      nttData,
      stationCount: stations.length,
    });

    if (!result.success) {
      return res.status(504).json({ success: false, error: result.error });
    }

    console.log(`[RESET] Uploaded ${stations.length} stations + ${transporters.length} transporters + ${units.length} units`);

    // Update current selection
    currentCustomer = customer;
    currentPlant = plant;
    loadConfigs();

    // Copy customer plant files to runtime
    try {
      const simPurposeSrc = path.join(plantPath, 'simulation_purpose.json');
      if (fs.existsSync(simPurposeSrc)) {
        const spData = JSON.parse(fs.readFileSync(simPurposeSrc, 'utf8'));
        spData.customer = customer;
        if (!spData.plant) spData.plant = {};
        spData.plant.name = plant;
        spData.updated_at = new Date().toISOString();
        fs.mkdirSync(RUNTIME_ROOT, { recursive: true });
        fs.writeFileSync(path.join(RUNTIME_ROOT, 'simulation_purpose.json'), JSON.stringify(spData, null, 2));
      }
      const mtSrc = path.join(plantPath, 'movement_times.json');
      if (fs.existsSync(mtSrc)) {
        fs.copyFileSync(mtSrc, path.join(RUNTIME_ROOT, 'movement_times.json'));
      }
    } catch (cpErr) {
      console.warn(`[RESET] Could not copy plant files to runtime: ${cpErr.message}`);
    }

    // Load movement times from JSON (overrides calculated values)
    try {
      const mtFile = path.join(plantPath, 'movement_times.json');
      if (fs.existsSync(mtFile)) {
        const mtData = JSON.parse(fs.readFileSync(mtFile, 'utf8'));
        for (const key of Object.keys(mtData)) {
          const tr = mtData[key];
          const tid = tr.id;
          if (tid >= 1 && tid <= 3) {
            await adapter.writeMovementTimes(tid, tr);
          }
        }
        console.log(`[RESET] Movement times loaded`);
      }
    } catch (mtErr) {
      console.warn(`[RESET] Movement times load failed: ${mtErr.message}`);
    }

    // Reset simulation timer and production queue
    simRunning = true;
    simStartTime = Date.now();
    try {
      await adapter.writeProductionQueue(0);
      await dispatcher.deactivate();
      if (dispatcher.queue) {
        dispatcher.queue.pointer = 0;
        dispatcher.queue.dispatched = [];
        await dispatcher.saveState();
      }
    } catch (e) {
      console.warn(`[RESET] Could not clear production_queue: ${e.message}`);
    }

    // Include layout_config if available
    let layoutConfig = null;
    const layoutFile = path.join(plantPath, 'layout_config.json');
    if (fs.existsSync(layoutFile)) {
      const raw = JSON.parse(fs.readFileSync(layoutFile, 'utf8'));
      layoutConfig = raw.layout || raw;
    }

    res.json({ success: true, stations, tanks, transporters, units, layoutConfig });

    simLog('RESET', {
      stations_count: stations.length,
      transporters_count: transporters.length,
      units_count: units.length,
    });
  } catch (err) {
    console.error(`[RESET] Error: ${err.message}`);
    res.status(500).json({ success: false, error: err.message });
  } finally {
    pausePolling = false;
  }
});

// Units
app.get('/api/units', (req, res) => {
  res.json({ units: plcUnits });
});

app.put('/api/units/:id', async (req, res) => {
  try {
    const uid = parseInt(req.params.id);
    if (uid < 1 || uid > 10) return res.status(400).json({ error: 'unit_id must be 1..10' });
    if (!adapter.isConnected()) return res.status(503).json({ error: 'PLC not connected' });

    const { location, status, target } = req.body;
    const targetInt = typeof target === 'string' ? (TARGET_STR_TO_INT[target] ?? 0) : (target || 0);
    await adapter.writeUnit(uid, location || 0, status || 0, targetInt);
    res.json({ ok: true });
  } catch (err) {
    res.status(err.message.includes('ack timeout') ? 504 : 500).json({ error: err.message });
  }
});

// ============================================================
// Batch + Treatment Program
// ============================================================
app.post('/api/batch', async (req, res) => {
  try {
    if (!adapter.isConnected()) return res.status(503).json({ error: 'PLC not connected' });
    const { unitIndex, batchCode, batchState, programId, stages } = req.body;
    if (!unitIndex || unitIndex < 1 || unitIndex > 10) {
      return res.status(400).json({ error: 'unitIndex must be 1..10' });
    }

    await adapter.writeBatch(unitIndex, batchCode || 0, batchState || 0, programId || 0);
    if (Array.isArray(stages)) {
      for (let i = 0; i < stages.length && i < 30; i++) {
        const st = stages[i];
        await adapter.writeProgramStage(
          unitIndex, i + 1,
          st.stations || [], st.minTime || 0, st.maxTime || 0, st.calTime || 0
        );
      }
    }
    res.json({ ok: true, stagesWritten: (stages || []).length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// PLC info endpoint
app.get('/api/plc/status', async (req, res) => {
  let runtimeStatus = 'unknown';
  let runtimeDetail = null;
  try {
    const plcState = await adapter.getPlcStatus();
    runtimeStatus = plcState.status;
    runtimeDetail = plcState.detail || null;
  } catch (_) {}
  res.json({
    connected: adapter.isConnected(),
    plc_alive: plcAlive,
    runtime_status: runtimeStatus,
    runtime_detail: runtimeDetail,
    init_done: plcMeta.init_done,
    station_count: plcMeta.station_count,
    cycle_count: plcMeta.cycle_count,
    sim_running: simRunning,
    production_queue: plcMeta.production_queue || 0,
    protocol: 'opcua',
    host: process.env.OPCUA_ENDPOINT || 'opc.tcp://localhost:4840',
  });
});

// Scheduler debug
app.get('/api/scheduler/debug', (req, res) => {
  res.json({
    dep_state: depState,
    scheduler: schedulerDebug,
    timestamp: new Date().toISOString(),
  });
});

// Production queue control
app.post('/api/production-queue', async (req, res) => {
  try {
    if (!adapter.isConnected()) return res.status(503).json({ error: 'PLC not connected' });
    const value = parseInt(req.body.value) || 0;

    if (value === 1) {
      if (!plcMeta.init_done) return res.status(409).json({ error: 'PLC not initialized — run RESET first' });
      const ok = await dispatcher.activate();
      if (!ok) return res.status(400).json({ error: 'No production queue found — create production first' });
      const qs = dispatcher.getStatus();
      simLog('PRODUCTION_START', { total_batches: qs.total, start_station: qs.start_station, finish_station: qs.finish_station, loading_time_s: qs.loading_time_s });
    } else {
      await dispatcher.deactivate();
      const qs = dispatcher.getStatus();
      simLog('PRODUCTION_STOP', { dispatched_count: qs.dispatched.length, remaining: qs.remaining });
    }

    await adapter.writeProductionQueue(value);
    res.json({ success: true, production_queue: value });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/production-queue/status', (req, res) => {
  res.json(dispatcher.getStatus());
});

// PLC Runtime control — RUN/STOP via docker exec (codesyscontrol service)
app.post('/api/plc/start', async (req, res) => {
  try {
    const result = await adapter.startPlc();
    if (result.success) {
      res.json({ success: true, message: result.message });
    } else {
      res.status(500).json({ success: false, error: result.error });
    }
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.post('/api/plc/stop', async (req, res) => {
  try {
    const result = await adapter.stopPlc();
    if (result.success) {
      // Clear state caches
      plcAlive = false;
      simRunning = false;
      plcMeta = { station_count: 0, init_done: false, cycle_count: 0 };
      res.json({ success: true, message: result.message });
    } else {
      res.status(500).json({ success: false, error: result.error });
    }
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/api/plc/logs', async (req, res) => {
  try {
    const result = await adapter.getPlcLogs(parseInt(req.query.lines) || 200);
    res.json({ success: result.success, logs: result.logs });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Health check
app.get('/api/health', (req, res) => {
  res.json({ ok: true, uptime: process.uptime(), protocol: 'opcua' });
});

// --- Startup ---
async function main() {
  loadConfigs();

  console.log(`[GATEWAY] Connecting to CODESYS via OPC UA...`);
  await adapter.connect();

  // Check DB connectivity
  checkDb(dbPool);

  // Initialize production dispatcher
  dispatcher.init({
    runtimeDir: RUNTIME_ROOT,
    writeBatchToPLC: (ui, bc, bs, pi) => adapter.writeBatch(ui, bc, bs, pi),
    writeProgramStageToPLC: (ui, si, stns, min, max, cal) => adapter.writeProgramStage(ui, si, stns, min, max, cal),
    writeUnitToPLC: (uid, loc, st, tgt) => adapter.writeUnit(uid, loc, st, tgt),
  });
  await dispatcher.loadQueue();

  startPolling();

  app.listen(API_PORT, () => {
    console.log(`[GATEWAY] REST API on http://localhost:${API_PORT}`);
    console.log(`[GATEWAY] PLC polling every ${POLL_MS}ms via OPC UA`);
    console.log(`[GATEWAY] OPC UA endpoint: ${process.env.OPCUA_ENDPOINT || 'opc.tcp://localhost:4840'}`);
    console.log(`[GATEWAY] Event DB: ${process.env.DB_HOST || 'localhost'}:${process.env.DB_PORT || '5432'}/${process.env.DB_NAME || 'plc_events'}`);
    console.log(`[GATEWAY] Customers root: ${CUSTOMERS_ROOT}`);
  });
}

main().catch(err => {
  console.error('[FATAL]', err);
  process.exit(1);
});

/**
 * File-based API routes — migrated from simulator container
 *
 * Handles: customer/plant management, plant templates, batch CRUD,
 * treatment programs, production setup, production CSV generation,
 * current selection, movement times.
 *
 * All paths resolve via environment variables:
 *   CUSTOMERS_ROOT  → /data/customers
 *   PLANT_TEMPLATES_ROOT → /data/plant_templates
 *   RUNTIME_ROOT    → /data/runtime
 */

const express = require('express');
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');

const router = express.Router();

// ─── Directory resolution ────────────────────────────────────────────────
const CUSTOMERS_DIR = process.env.CUSTOMERS_ROOT ||
  (fsSync.existsSync('/data/customers')
    ? '/data/customers'
    : path.join(__dirname, '..', '..', 'data', 'customers'));

const PLANT_TEMPLATES_DIR = process.env.PLANT_TEMPLATES_ROOT ||
  (fsSync.existsSync('/data/plant_templates')
    ? '/data/plant_templates'
    : path.join(__dirname, '..', '..', 'data', 'plant_templates'));

const RUNTIME_DIR = process.env.RUNTIME_ROOT ||
  (fsSync.existsSync('/data/runtime')
    ? '/data/runtime'
    : path.join(__dirname, '..', '..', 'data', 'runtime'));

// Ensure runtime dir exists on startup
fsSync.mkdirSync(RUNTIME_DIR, { recursive: true });

// ─── Shared state (set from index.js via init()) ────────────────────────
let _getCurrentSelection = () => ({ customer: '', plant: '' });
let _setCurrentSelection = () => {};

function init({ getCurrentSelection, setCurrentSelection }) {
  _getCurrentSelection = getCurrentSelection;
  _setCurrentSelection = setCurrentSelection;
}

// ─── File helpers ────────────────────────────────────────────────────────
const loadJson = async (filePath) => JSON.parse(await fs.readFile(filePath, 'utf8'));

const readJsonSafe = async (filePath, fallback) => {
  try { return await loadJson(filePath); }
  catch (e) {
    if (e.code === 'ENOENT' || typeof fallback !== 'undefined') return fallback;
    throw e;
  }
};

const writeJsonAtomic = async (filePath, data) => {
  const dir = path.dirname(filePath);
  await fs.mkdir(dir, { recursive: true });
  const tmp = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  await fs.writeFile(tmp, JSON.stringify(data, null, 2), 'utf8');
  await fs.rename(tmp, filePath);
};

const pad3 = (n) => String(n).padStart(3, '0');

// ─── Runtime paths (relative to RUNTIME_DIR) ────────────────────────────
const runtimePath = (name) => path.join(RUNTIME_DIR, name);
const PATHS = {
  batches:           () => runtimePath('batches.json'),
  units:             () => runtimePath('units.json'),
  productionSetup:   () => runtimePath('production_setup.json'),
  productionQueue:   () => runtimePath('production_queue.json'),
  simulationPurpose: () => runtimePath('simulation_purpose.json'),
  movementTimes:     () => runtimePath('movement_times.json'),
};

// ─── Batch helpers ───────────────────────────────────────────────────────
const stripScheduleFromBatch = (b) => {
  if (!b || typeof b !== 'object') return b;
  const { schedule, scheduleNeedsRecalc, scheduledEntryTime, scheduledFinishTime, scheduleStages, ...rest } = b;
  return rest;
};

const normalizeBatchesPayload = (data) => {
  if (Array.isArray(data)) return data.map(stripScheduleFromBatch);
  if (data && typeof data === 'object' && Array.isArray(data.batches))
    return { ...data, batches: data.batches.map(stripScheduleFromBatch) };
  return data;
};

const loadBatches = async () => {
  const data = await readJsonSafe(PATHS.batches(), { batches: [] });
  return normalizeBatchesPayload(data);
};

const saveBatches = async (data) => {
  const norm = normalizeBatchesPayload(data);
  await writeJsonAtomic(PATHS.batches(), norm);
  return norm;
};

const loadUnits = async () => {
  const data = await readJsonSafe(PATHS.units(), { units: [] });
  return data?.units || [];
};

const saveUnits = async (units) => {
  await writeJsonAtomic(PATHS.units(), { units });
};

const normalizeBatchPayload = (raw) => {
  const errors = [];
  const toNum = (v, field) => {
    const n = Number(v);
    if (!Number.isFinite(n)) { errors.push(`${field} must be a number`); return null; }
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

  if (minTime < 0) errors.push('min_time_s must be >= 0');
  if (minTime != null && maxTime != null && maxTime < minTime) errors.push('max_time_s cannot be less than min_time_s');
  if (startTime < 0) errors.push('start_time must be >= 0');

  return {
    payload: {
      batch_id: batchId, location, treatment_program: program, stage,
      min_time_s: minTime, max_time_s: maxTime,
      calc_time_s: calcTime < 0 ? 0 : calcTime,
      start_time: startTime
    },
    errors
  };
};

// Simple write-lock (no contention expected, just serializes writes)
let scanMutex = Promise.resolve();
const withScanLock = async (fn) => {
  let release;
  const prev = scanMutex;
  scanMutex = new Promise(r => { release = r; });
  await prev;
  try { return await fn(); }
  finally { release(); }
};

let nextUnitId = 1;

// ─── Helper: get current customer plant dir ──────────────────────────────
function getPlantDir(customer, plant) {
  return path.join(CUSTOMERS_DIR, customer || '', plant || '');
}
function getCurrentPlantDir() {
  const { customer, plant } = _getCurrentSelection();
  return getPlantDir(customer, plant);
}

// ================================================================
//  CUSTOMER / PLANT MANAGEMENT
// ================================================================

// GET /api/customers — list customer directories
router.get('/customers', async (req, res) => {
  try {
    const entries = await fs.readdir(CUSTOMERS_DIR, { withFileTypes: true });
    const customers = entries.filter(e => e.isDirectory()).map(e => e.name);
    res.json({ success: true, customers });
  } catch (err) {
    console.error('[FILE] Error reading customers:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// POST /api/customers — create customer directory
router.post('/customers', async (req, res) => {
  try {
    const { name } = req.body;
    if (!name || !name.trim()) return res.status(400).json({ success: false, error: 'Customer name is required' });
    const dir = path.join(CUSTOMERS_DIR, name.trim());
    try { await fs.access(dir); return res.status(400).json({ success: false, error: 'Customer already exists' }); }
    catch { /* ok */ }
    await fs.mkdir(dir, { recursive: true });
    res.json({ success: true, customer: name.trim() });
  } catch (err) {
    console.error('[FILE] Error creating customer:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// GET /api/customers/:customer/plants — list plant directories
router.get('/customers/:customer/plants', async (req, res) => {
  try {
    const dir = path.join(CUSTOMERS_DIR, req.params.customer);
    const entries = await fs.readdir(dir, { withFileTypes: true });
    const plants = entries.filter(e => e.isDirectory()).map(e => e.name);
    res.json({ success: true, plants });
  } catch (err) {
    console.error('[FILE] Error reading plants:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// POST /api/customers/:customer/plants — create plant directory
router.post('/customers/:customer/plants', async (req, res) => {
  try {
    const { name } = req.body;
    if (!name || !name.trim()) return res.status(400).json({ success: false, error: 'Plant name is required' });
    const dir = path.join(CUSTOMERS_DIR, req.params.customer, name.trim());
    try { await fs.access(dir); return res.status(400).json({ success: false, error: 'Plant already exists' }); }
    catch { /* ok */ }
    await fs.mkdir(dir, { recursive: true });
    res.json({ success: true, plant: name.trim() });
  } catch (err) {
    console.error('[FILE] Error creating plant:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// GET /api/customers/:customer/plants/:plant/status — check plant config completeness
router.get('/customers/:customer/plants/:plant/status', async (req, res) => {
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
      const stationsData = JSON.parse(await fs.readFile(path.join(plantDir, 'stations.json'), 'utf8'));
      const stations = Array.isArray(stationsData) ? stationsData : (stationsData.stations || []);
      const lineCount = [...new Set(stations.map(s => s.y_position))].length;

      const transportersData = JSON.parse(await fs.readFile(path.join(plantDir, 'transporters.json'), 'utf8'));
      const transporterList = Array.isArray(transportersData)
        ? transportersData
        : Array.isArray(transportersData.transporters) ? transportersData.transporters : [];
      const transporterCount = transporterList.length;
      const model2D = transporterList.filter(t => (t?.model || '2D') === '2D').length;
      const model3D = transporterList.filter(t => t?.model === '3D').length;

      let transporterDesc = '';
      if (model2D > 0 && model3D > 0) transporterDesc = `${model2D}x 2D + ${model3D}x 3D`;
      else if (model3D > 0) transporterDesc = `${model3D}x 3D`;
      else transporterDesc = `${model2D}x 2D`;

      analysis = {
        lines: lineCount, transporters: transporterCount, transporterDesc,
        treatmentPrograms: treatmentPrograms.length,
        summary: `${lineCount} line${lineCount > 1 ? 's' : ''}, ${transporterDesc} transporter${transporterCount > 1 ? 's' : ''}, ${treatmentPrograms.length} program${treatmentPrograms.length > 1 ? 's' : ''}`
      };
    }

    res.json({
      success: true, isConfigured, hasStations, hasTransporters, hasSimPurpose,
      hasTreatmentProgram, treatmentProgramCount: treatmentPrograms.length, analysis
    });
  } catch (err) {
    console.error('[FILE] Error checking plant status:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// POST /api/customers/:customer/plants/:plant/copy-template — copy template to plant
router.post('/customers/:customer/plants/:plant/copy-template', async (req, res) => {
  try {
    const { template, customer, plant, country, city } = req.body;
    if (!template) return res.status(400).json({ success: false, error: 'Template name is required' });

    const templateDir = path.join(PLANT_TEMPLATES_DIR, template);
    const plantDir = path.join(CUSTOMERS_DIR, req.params.customer, req.params.plant);

    try { await fs.access(templateDir); }
    catch { return res.status(404).json({ success: false, error: 'Template not found' }); }

    await fs.mkdir(plantDir, { recursive: true });

    const files = await fs.readdir(templateDir);
    for (const file of files) {
      const src = path.join(templateDir, file);
      const stat = await fs.stat(src);
      if (stat.isFile()) await fs.copyFile(src, path.join(plantDir, file));
    }

    // Update simulation_purpose.json with customer info
    const simPurposePath = path.join(plantDir, 'simulation_purpose.json');
    try {
      const data = JSON.parse(await fs.readFile(simPurposePath, 'utf8'));
      data.customer = customer || req.params.customer;
      if (!data.plant) data.plant = {};
      data.plant.name = plant || req.params.plant;
      if (country) data.plant.country = country;
      if (city) data.plant.town = city;
      await fs.writeFile(simPurposePath, JSON.stringify(data, null, 2), 'utf8');
    } catch (e) {
      console.error('[FILE] Error updating simulation_purpose.json:', e);
    }

    res.json({ success: true, copiedFiles: files.filter(f => !f.startsWith('.')) });
  } catch (err) {
    console.error('[FILE] Error copying template:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// GET /api/customers/:customer/plants/:plant/simulation-purpose
router.get('/customers/:customer/plants/:plant/simulation-purpose', async (req, res) => {
  try {
    const fp = path.join(CUSTOMERS_DIR, req.params.customer, req.params.plant, 'simulation_purpose.json');
    const data = JSON.parse(await fs.readFile(fp, 'utf8'));
    res.json({ success: true, data });
  } catch (err) {
    console.error('[FILE] Error reading simulation purpose:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// PUT /api/customers/:customer/plants/:plant/simulation-purpose
router.put('/customers/:customer/plants/:plant/simulation-purpose', async (req, res) => {
  try {
    const fp = path.join(CUSTOMERS_DIR, req.params.customer, req.params.plant, 'simulation_purpose.json');
    const data = JSON.parse(await fs.readFile(fp, 'utf8'));
    const { country, city, purpose } = req.body;
    if (country !== undefined) data.plant.country = country;
    if (city !== undefined) data.plant.town = city;
    if (purpose !== undefined) data.purpose = purpose;
    await fs.writeFile(fp, JSON.stringify(data, null, 2), 'utf8');
    res.json({ success: true, data });
  } catch (err) {
    console.error('[FILE] Error updating simulation purpose:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// ================================================================
//  PLANT TEMPLATES
// ================================================================

// GET /api/plant-setups — list available plant templates
router.get('/plant-setups', async (req, res) => {
  try {
    const entries = await fs.readdir(PLANT_TEMPLATES_DIR, { withFileTypes: true });
    const setups = entries.filter(e => e.isDirectory()).map(e => e.name);
    const { customer, plant } = _getCurrentSelection();
    res.json({ setups, current: customer && plant ? `${customer}/${plant}` : '' });
  } catch (err) {
    console.error('[FILE] Error reading plant setups:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// ================================================================
//  CURRENT SELECTION
// ================================================================

// GET /api/current-selection
router.get('/current-selection', async (req, res) => {
  try {
    const data = await readJsonSafe(PATHS.simulationPurpose(), null);
    if (data && data.customer) {
      res.json({ success: true, customer: data.customer, plant: data.plant?.name || null });
    } else {
      res.json({ success: true, customer: null, plant: null });
    }
  } catch (err) {
    res.json({ success: true, customer: null, plant: null });
  }
});

// POST /api/current-selection
router.post('/current-selection', async (req, res) => {
  try {
    const { customer, plant } = req.body;

    if (!customer || !plant) {
      await writeJsonAtomic(PATHS.simulationPurpose(), {
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

    const customerSimPurposePath = path.join(CUSTOMERS_DIR, customer, plant, 'simulation_purpose.json');
    try {
      const masterData = await loadJson(customerSimPurposePath);
      masterData.customer = customer;
      if (!masterData.plant) masterData.plant = {};
      masterData.plant.name = plant;
      masterData.updated_at = new Date().toISOString();
      await writeJsonAtomic(PATHS.simulationPurpose(), masterData);
    } catch {
      await writeJsonAtomic(PATHS.simulationPurpose(), {
        customer, plant: { name: plant, country: '', town: '' },
        purpose: 'TEST', treatment_program_batches: [],
        simulation_duration: 8, available_containers: 20,
        updated_at: new Date().toISOString()
      });
    }

    res.json({ success: true });
  } catch (err) {
    console.error('[FILE] Error saving current selection:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// ================================================================
//  BATCHES CRUD
// ================================================================

// GET /api/batches
router.get('/batches', async (req, res) => {
  try {
    const batchesData = await loadBatches();
    res.json({
      batches: (batchesData?.batches || []).map(stripScheduleFromBatch),
      timestamp: new Date().toISOString()
    });
  } catch (err) {
    console.error('[FILE] Error reading batches:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// POST /api/batches
router.post('/batches', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { payload, errors } = normalizeBatchPayload(req.body || {});
      if (errors.length || Object.values(payload).some(v => v == null)) {
        return res.status(400).json({ success: false, error: errors.join(', ') || 'Invalid payload' });
      }

      const batchesData = await loadBatches();
      const batchesArr = batchesData?.batches || [];
      if (batchesArr.some(b => b.batch_id === payload.batch_id)) {
        return res.status(409).json({ success: false, error: 'batch_id already exists' });
      }

      payload.scheduleNeedsRecalc = true;
      const updatedBatches = [...batchesArr, payload];
      await saveBatches({ batches: updatedBatches });

      // Create Unit for manually added batch
      const currentUnits = await loadUnits();
      if (currentUnits.length > 0) {
        const maxId = Math.max(...currentUnits.map(u => u.unit_id));
        if (maxId >= nextUnitId) nextUnitId = maxId + 1;
      }
      const requestedUnitId = req.body.unit_id;
      let unitId;
      if (requestedUnitId != null && Number.isFinite(Number(requestedUnitId))) {
        unitId = Math.round(Number(requestedUnitId));
        if (currentUnits.some(u => u.unit_id === unitId)) {
          return res.status(409).json({ success: false, error: `unit_id ${unitId} already exists` });
        }
        if (unitId >= nextUnitId) nextUnitId = unitId + 1;
      } else {
        unitId = nextUnitId++;
      }
      currentUnits.push({ unit_id: unitId, location: payload.location, batch_id: payload.batch_id });
      await saveUnits(currentUnits);

      res.status(201).json({ success: true, batch: payload, unit_id: unitId, batches: updatedBatches.map(stripScheduleFromBatch) });
    } catch (err) {
      console.error('[FILE] Error creating batch:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });
});

// PUT /api/batches/:id
router.put('/batches/:id', async (req, res) => {
  return withScanLock(async () => {
    try {
      const targetId = Number(req.params.id);
      if (!Number.isFinite(targetId)) return res.status(400).json({ success: false, error: 'Invalid batch id' });

      const batchesData = await loadBatches();
      const batchesArr = batchesData?.batches || [];
      const idx = batchesArr.findIndex(b => b.batch_id === targetId);
      if (idx === -1) return res.status(404).json({ success: false, error: 'Batch not found' });

      const { payload, errors } = normalizeBatchPayload({ ...req.body, batch_id: targetId });
      if (errors.length || Object.values(payload).some(v => v == null)) {
        return res.status(400).json({ success: false, error: errors.join(', ') || 'Invalid payload' });
      }

      payload.scheduleNeedsRecalc = true;
      const updatedBatches = [...batchesArr];
      updatedBatches[idx] = payload;
      await saveBatches({ batches: updatedBatches });

      const currentUnits = await loadUnits();
      const unit = currentUnits.find(u => u.batch_id === targetId);
      if (unit && unit.location !== payload.location) {
        unit.location = payload.location;
        await saveUnits(currentUnits);
      }

      res.json({ success: true, batch: payload, unit_id: unit ? unit.unit_id : null, batches: updatedBatches.map(stripScheduleFromBatch) });
    } catch (err) {
      console.error('[FILE] Error updating batch:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });
});

// DELETE /api/batches/:id
router.delete('/batches/:id', async (req, res) => {
  return withScanLock(async () => {
    try {
      const targetId = Number(req.params.id);
      if (!Number.isFinite(targetId)) return res.status(400).json({ success: false, error: 'Invalid batch id' });

      const batchesData = await loadBatches();
      const batchesArr = batchesData?.batches || [];
      const nextBatches = batchesArr.filter(b => b.batch_id !== targetId);
      if (nextBatches.length === batchesArr.length) return res.status(404).json({ success: false, error: 'Batch not found' });

      await saveBatches({ batches: nextBatches });

      const currentUnits = await loadUnits();
      const unit = currentUnits.find(u => u.batch_id === targetId);
      if (unit) {
        unit.batch_id = null;
        await saveUnits(currentUnits);
      }

      res.json({ success: true, batches: nextBatches.map(stripScheduleFromBatch) });
    } catch (err) {
      console.error('[FILE] Error deleting batch:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });
});

// ================================================================
//  TREATMENT PROGRAMS
// ================================================================

// GET /api/treatment-programs — list treatment program files from current plant
router.get('/treatment-programs', async (req, res) => {
  try {
    const { customer, plant } = _getCurrentSelection();
    if (!customer || !plant) {
      return res.json({ success: true, programs: [], programDetails: [] });
    }
    const setupDir = path.join(CUSTOMERS_DIR, customer, plant);
    const entries = await fs.readdir(setupDir);
    const programs = entries
      .map(name => {
        const m = name.match(/treatment_program_(\d+)\.csv$/i);
        return m ? { number: Number(m[1]), filename: name } : null;
      })
      .filter(p => p !== null && Number.isFinite(p.number))
      .sort((a, b) => a.number - b.number);
    res.json({ success: true, programs: programs.map(p => p.number), programDetails: programs });
  } catch (err) {
    console.error('[FILE] Error reading treatment programs:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// ================================================================
//  PRODUCTION SETUP
// ================================================================

const defaultProductionSetup = () => ({
  start_station: null, finish_station: null,
  loading_time_s: 0, unloading_time_s: 0,
  duration_hours: null, plant_setup: '',
  updated_at: new Date().toISOString()
});

// GET /api/production-setup
router.get('/production-setup', async (req, res) => {
  try {
    const data = await readJsonSafe(PATHS.productionSetup(), defaultProductionSetup());
    res.json({ success: true, setup: data });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// POST /api/production-setup
router.post('/production-setup', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { start_station, finish_station, loading_time_s, unloading_time_s, duration_hours } = req.body || {};
      const toInt = (v, field) => {
        const n = Number(v);
        if (!Number.isFinite(n) || n < 0) throw new Error(`${field} must be a non-negative number`);
        return Math.round(n);
      };
      const { customer, plant } = _getCurrentSelection();
      const setup = {
        start_station: Number.isFinite(Number(start_station)) ? Number(start_station) : null,
        finish_station: Number.isFinite(Number(finish_station)) ? Number(finish_station) : null,
        loading_time_s: toInt(loading_time_s || 0, 'loading_time_s'),
        unloading_time_s: toInt(unloading_time_s || 0, 'unloading_time_s'),
        duration_hours: Number.isFinite(Number(duration_hours)) ? Number(duration_hours) : null,
        plant_setup: customer && plant ? `${customer}/${plant}` : '',
        updated_at: new Date().toISOString()
      };

      await fs.writeFile(PATHS.productionSetup(), JSON.stringify(setup, null, 2), 'utf8');

      // Also update simulation_purpose.json with duration
      if (Number.isFinite(Number(duration_hours))) {
        try {
          let simPurpose = {};
          try { simPurpose = JSON.parse(await fs.readFile(PATHS.simulationPurpose(), 'utf8')); }
          catch { /* ok */ }
          simPurpose.simulation_duration = Number(duration_hours);
          await fs.writeFile(PATHS.simulationPurpose(), JSON.stringify(simPurpose, null, 2), 'utf8');
        } catch (e) { console.error('[FILE] Failed to update simulation_purpose:', e); }
      }

      res.json({ success: true, setup });
    } catch (err) {
      res.status(400).json({ success: false, error: err.message });
    }
  });
});

// ================================================================
//  PRODUCTION — create batch CSV files
// ================================================================

// POST /api/production
router.post('/production', async (req, res) => {
  return withScanLock(async () => {
    try {
      const { pairs } = req.body || {};
      if (!Array.isArray(pairs) || pairs.length === 0) {
        return res.status(400).json({ success: false, error: 'pairs array is required' });
      }

      const { customer, plant } = _getCurrentSelection();
      if (!customer || !plant) {
        return res.status(400).json({ success: false, error: 'No customer/plant selected' });
      }
      const setupDir = path.join(CUSTOMERS_DIR, customer, plant);

      // Build program -> filename map
      const setupFiles = await fs.readdir(setupDir);
      const programFileMap = new Map();
      setupFiles.forEach(name => {
        const m = name.match(/treatment_program_(\d+)\.csv$/i);
        if (m) {
          const num = Number(m[1]);
          if (Number.isFinite(num)) programFileMap.set(num, name);
        }
      });

      const programCache = new Map();
      const ensureProgram = async (program) => {
        if (programCache.has(program)) return programCache.get(program);
        const filename = programFileMap.get(program) || `treatment_program_${pad3(program)}.csv`;
        const fp = path.join(setupDir, filename);
        try { await fs.access(fp); programCache.set(program, fp); return fp; }
        catch { return null; }
      };

      // Validate
      const normalized = [];
      for (const entry of pairs) {
        const count = Number(entry?.count);
        const program = Number(entry?.program);
        const startStation = entry?.start_station != null ? Number(entry.start_station) : null;
        const endStation = entry?.end_station != null ? Number(entry.end_station) : null;
        if (!Number.isInteger(count) || count <= 0)
          return res.status(400).json({ success: false, error: 'count must be a positive integer' });
        if (!Number.isInteger(program) || program <= 0)
          return res.status(400).json({ success: false, error: 'program must be a positive integer' });
        const src = await ensureProgram(program);
        if (!src) return res.status(400).json({ success: false, error: `Program ${program} not found in ${customer}/${plant}` });
        normalized.push({ count, program, src, start_station: startStation, end_station: endStation });
      }

      // Delete old batch files from runtime
      const runtimeFiles = await fs.readdir(RUNTIME_DIR).catch(() => []);
      let deletedCount = 0;
      for (const file of runtimeFiles) {
        if (/^Batch_\d+_treatment_program_\d+\.csv$/i.test(file)) {
          try { await fs.unlink(path.join(RUNTIME_DIR, file)); deletedCount++; } catch { /* skip */ }
        }
      }

      // Update production_setup start/finish from production data
      const firstWithStart = normalized.find(n => Number.isFinite(n.start_station));
      const firstWithEnd = normalized.find(n => Number.isFinite(n.end_station));
      if (firstWithStart || firstWithEnd) {
        try {
          const curSetup = await readJsonSafe(PATHS.productionSetup(), {});
          if (firstWithStart) curSetup.start_station = firstWithStart.start_station;
          if (firstWithEnd) curSetup.finish_station = firstWithEnd.end_station;
          curSetup.updated_at = new Date().toISOString();
          await fs.writeFile(PATHS.productionSetup(), JSON.stringify(curSetup, null, 2), 'utf8');
        } catch { /* skip */ }
      }

      // Clear batches.json
      await saveBatches({ batches: [] });

      // Create new batch CSV files
      let batchNumber = 0;
      const created = [];
      for (const { count, program, src } of normalized) {
        const sourceContent = await fs.readFile(src, 'utf8');
        const normalizedContent = sourceContent.replace(/\r/g, '');
        const lines = normalizedContent.split('\n').filter(l => l.trim());
        if (lines.length === 0) throw new Error(`Empty treatment program file: ${src}`);

        // Add CalcTime column (default = MinTime)
        const header = lines[0];
        const modifiedLines = [header + ',CalcTime'];
        for (let li = 1; li < lines.length; li++) {
          const cols = lines[li].split(',');
          if (cols.length >= 5) {
            modifiedLines.push(lines[li] + ',' + cols[3]); // CalcTime = MinTime
          } else {
            modifiedLines.push(lines[li]);
          }
        }
        const modifiedContent = modifiedLines.join('\n') + '\n';

        for (let i = 0; i < count; i++) {
          batchNumber++;
          const destName = `Batch_${pad3(batchNumber)}_treatment_program_${pad3(program)}.csv`;
          await fs.writeFile(path.join(RUNTIME_DIR, destName), modifiedContent, 'utf8');
          created.push({ batch: batchNumber, program, file: destName });
        }
      }

      // Update runtime simulation_purpose.json
      try {
        const treatmentProgramBatches = [];
        for (const { count, program, start_station, end_station } of normalized) {
          const entry = { treatment_program: program, batches: count };
          if (Number.isFinite(start_station)) entry.start_station = start_station;
          if (Number.isFinite(end_station)) entry.end_station = end_station;
          treatmentProgramBatches.push(entry);
        }

        let simPurpose = {};
        try { simPurpose = JSON.parse(await fs.readFile(PATHS.simulationPurpose(), 'utf8')); }
        catch { simPurpose = { purpose: 'TEST', simulation_duration: 8, available_containers: 20 }; }
        simPurpose.treatment_program_batches = treatmentProgramBatches;
        simPurpose.updated_at = new Date().toISOString();
        await fs.writeFile(PATHS.simulationPurpose(), JSON.stringify(simPurpose, null, 2), 'utf8');
      } catch { /* non-fatal */ }

      // Build production_queue.json for the dispatcher
      try {
        const setup = await readJsonSafe(PATHS.productionSetup(), {});
        const productionQueue = {
          start_station: setup.start_station || null,
          finish_station: setup.finish_station || null,
          loading_time_s: setup.loading_time_s || 60,
          batches: created.map(c => ({
            batch_number: c.batch,
            program_id: c.program,
            csv_file: c.file,
          })),
          pointer: 0,
          active: false,
          dispatched: [],
          created_at: new Date().toISOString(),
        };
        await fs.writeFile(
          PATHS.productionQueue(),
          JSON.stringify(productionQueue, null, 2),
          'utf8'
        );
        console.log(`[FILE] production_queue.json created: ${created.length} batches`);
      } catch (e) {
        console.error('[FILE] Failed to write production_queue.json:', e);
      }

      res.json({ success: true, createdCount: created.length, created, deletedCount });
    } catch (err) {
      console.error('[FILE] Error creating production files:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });
});

// ================================================================
//  MOVEMENT TIMES
// ================================================================

// GET /api/movement-times
router.get('/movement-times', async (req, res) => {
  try {
    // Try runtime first, then customer plant dir
    let data = await readJsonSafe(PATHS.movementTimes(), null);
    if (!data) {
      const plantDir = getCurrentPlantDir();
      data = await readJsonSafe(path.join(plantDir, 'movement_times.json'), null);
    }
    if (!data) return res.status(404).json({ success: false, error: 'movement_times.json not found' });
    res.json({ success: true, movementTimes: data });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// ================================================================
//  COPY-CUSTOMER-PLANT (called internally during RESET)
// ================================================================

// POST /api/copy-customer-plant — copy customer plant files to runtime
router.post('/copy-customer-plant', async (req, res) => {
  try {
    const { customer, plant } = req.body;
    if (!customer || !plant) return res.status(400).json({ success: false, error: 'customer and plant required' });

    const srcDir = path.join(CUSTOMERS_DIR, customer, plant);
    try { await fs.access(srcDir); }
    catch { return res.status(404).json({ success: false, error: 'Plant directory not found' }); }

    // Copy simulation_purpose.json to runtime
    const simSrc = path.join(srcDir, 'simulation_purpose.json');
    try {
      const data = await loadJson(simSrc);
      data.customer = customer;
      if (!data.plant) data.plant = {};
      data.plant.name = plant;
      data.updated_at = new Date().toISOString();
      await writeJsonAtomic(PATHS.simulationPurpose(), data);
    } catch {
      await writeJsonAtomic(PATHS.simulationPurpose(), {
        customer, plant: { name: plant }, purpose: 'TEST',
        treatment_program_batches: [], simulation_duration: 8,
        available_containers: 20, updated_at: new Date().toISOString()
      });
    }

    // Copy movement_times.json if exists
    const mtSrc = path.join(srcDir, 'movement_times.json');
    try {
      const mtData = await loadJson(mtSrc);
      await writeJsonAtomic(PATHS.movementTimes(), mtData);
    } catch { /* ok, might not exist */ }

    _setCurrentSelection(customer, plant);

    res.json({ success: true });
  } catch (err) {
    console.error('[FILE] Error copying customer plant:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

module.exports = { router, init };

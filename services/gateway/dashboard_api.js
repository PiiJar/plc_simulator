/**
 * dashboard_api.js — Real-time dashboard API endpoints
 *
 * Replaces legacy stubs with live data sourced from:
 * - OPC UA polling loop (transporter X positions, scheduler phases)
 * - PostgreSQL event database (lift events → station treatment times)
 *
 * Lifecycle:
 *   init({ dbPool, getState })   — inject dependencies
 *   tick({ transporters, meta, schedulerDebug })  — call every poll cycle
 *   router                       — mount on Express app.use('/api', ...)
 */

const express = require('express');
const router = express.Router();

// ── Dependencies (injected via init()) ──────────────────────────
let _dbPool = null;
let _getState = null;   // () => { plcState, plcMeta, schedulerDebug, twaLimits, stationsConfig }
let _getDispatcher = null;  // () => dispatcher

// ═══════════════════════════════════════════════════════════════════════
// 1. TRANSPORTER X-POSITION RING BUFFER
// ═══════════════════════════════════════════════════════════════════════
const HOIST_WINDOW_MS = 60 * 60 * 1000;    // 60 min display window
const HOIST_SAMPLE_INTERVAL_MS = 1000;      // sample every 1 s of sim-time
const MAX_HOIST_SAMPLES = 3600;             // hard cap per transporter

// hoistHistory[tid] = [[simTimeMs, xPositionMm], ...]
const hoistHistory = {};
let lastHoistSampleSimMs = 0;

function sampleHoistPositions(transporters, simTimeMs) {
  if (!Number.isFinite(simTimeMs) || simTimeMs <= 0) return;
  if (simTimeMs - lastHoistSampleSimMs < HOIST_SAMPLE_INTERVAL_MS) return;
  lastHoistSampleSimMs = simTimeMs;

  for (const tr of transporters) {
    if (!tr || !tr.state) continue;
    const tid = tr.id;
    if (!hoistHistory[tid]) hoistHistory[tid] = [];
    const arr = hoistHistory[tid];
    arr.push([simTimeMs, tr.state.x_position || 0]);
    // Evict old samples outside window
    const cutoff = simTimeMs - HOIST_WINDOW_MS;
    while (arr.length > 0 && arr[0][0] < cutoff) arr.shift();
    while (arr.length > MAX_HOIST_SAMPLES) arr.shift();
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 2. SCHEDULER ROUND-TIME TRACKING (PLC tick-based)
//    PLC reports round_ticks for TSK and DEP via OPC UA.
//    Each scheduler tick = 40 ms (20 ms PLC cycle × 2 alternation).
// ═══════════════════════════════════════════════════════════════════════
const MAX_ROUND_HISTORY = 1000;
const TICK_MS = 40; // TSK/DEP each execute every other PLC cycle

function freshRoundStats() {
  return { history: [], prevTicks: 0 };
}

const tskRound = freshRoundStats();
const depRound = freshRoundStats();

function pushRound(stats, ticks) {
  if (ticks <= 0) return;
  stats.history.push(ticks);
  while (stats.history.length > MAX_ROUND_HISTORY) stats.history.shift();
}

function roundSummary(stats) {
  const h = stats.history;
  if (h.length === 0) return { count: 0, avgMs: 0, maxMs: 0, lastMs: 0, avgTicks: 0, maxTicks: 0, historyMs: [] };
  const sum = h.reduce((a, b) => a + b, 0);
  const max = Math.max(...h);
  const last = h[h.length - 1];
  return {
    count: h.length,
    avgMs: Math.round((sum / h.length) * TICK_MS),
    maxMs: max * TICK_MS,
    lastMs: last * TICK_MS,
    avgTicks: +(sum / h.length).toFixed(1),
    maxTicks: max,
    historyMs: h.map(t => t * TICK_MS),
  };
}

function trackRoundTicks(schedulerDebug) {
  if (!schedulerDebug) return;
  const tskTicks = schedulerDebug.tsk_round_ticks || 0;
  const depTicks = schedulerDebug.dep_round_ticks || 0;
  // PLC updates round_ticks at RESTART; value changes = new round completed
  if (tskTicks > 0 && tskTicks !== tskRound.prevTicks) {
    pushRound(tskRound, tskTicks);
    tskRound.prevTicks = tskTicks;
  }
  if (depTicks > 0 && depTicks !== depRound.prevTicks) {
    pushRound(depRound, depTicks);
    depRound.prevTicks = depTicks;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// tick()  — called from gateway poll loop every POLL_MS
// ═══════════════════════════════════════════════════════════════════════
function tick({ transporters, meta, schedulerDebug }) {
  const simMs = (meta.time_s || 0) * 1000;
  sampleHoistPositions(transporters || [], simMs);
  trackRoundTicks(schedulerDebug);
}

// ═══════════════════════════════════════════════════════════════════════
// init()
// ═══════════════════════════════════════════════════════════════════════
function init({ dbPool, getState, getDispatcher }) {
  _dbPool = dbPool;
  _getState = getState;
  _getDispatcher = getDispatcher || null;
}

// ═══════════════════════════════════════════════════════════════════════
// ROUTES
// ═══════════════════════════════════════════════════════════════════════

// ── GET /api/scheduler/state — TSK + DEP cycle-time stats + production ─
router.get('/scheduler/state', async (req, res) => {
  try {
    // Production stats from dispatcher + DB
    let productionStats = null;
    let avgDepartureIntervalSec = 0;
    const dp = _getDispatcher ? _getDispatcher() : null;
    if (dp) {
      const st = dp.getStatus();
      const total = st.total || 0;
      const dispatched = (st.dispatched || []).length;

      let completed = 0;
      let prodStartTs = null;
      if (_dbPool && total > 0) {
        // Find current production run start
        const ps = await _dbPool.query(
          `SELECT created_at FROM sim_log WHERE event = 'PRODUCTION_START' ORDER BY created_at DESC LIMIT 1`);
        prodStartTs = ps.rows.length > 0 ? ps.rows[0].created_at : null;

        const r = await _dbPool.query(
          `SELECT COUNT(DISTINCT batch_code) AS n FROM batch_completed WHERE ($1::timestamptz IS NULL OR received_at >= $1)`,
          [prodStartTs]);
        completed = parseInt(r.rows[0].n, 10) || 0;
      }

      const inProgress = Math.max(0, dispatched - completed);

      productionStats = {
        totalBatches: total,
        inProgressCount: inProgress,
        completedCount: completed,
        queueLength: Math.max(0, total - completed - inProgress),
      };

      // Average cycle time from batch_activated timestamps (current run only)
      if (_dbPool && dispatched >= 2) {
        const r2 = await _dbPool.query(
          `SELECT EXTRACT(EPOCH FROM (MAX(plc_ts) - MIN(plc_ts))) / NULLIF(COUNT(*) - 1, 0) AS avg_s
           FROM batch_activated
           WHERE ($1::timestamptz IS NULL OR received_at >= $1)`,
          [prodStartTs]);
        avgDepartureIntervalSec = parseFloat(r2.rows[0].avg_s) || 0;
      }
    }

    // Waiting batch info from sim_ui snapshot
    const stateData = _getState ? _getState() : {};
    const waitInfo = stateData.simUi || { wait_unit: 0, wait_reason: 0 };

    res.json({
      success: true,
      state: {
        tsk: roundSummary(tskRound),
        dep: roundSummary(depRound),
        tickMs: TICK_MS,
        avgDepartureIntervalSec,
        waitUnit: waitInfo.wait_unit,
        waitReason: waitInfo.wait_reason,
      },
      productionStats,
    });
  } catch (err) {
    console.error('[dashboard] /scheduler/state error:', err.message);
    res.status(500).json({ success: false, error: err.message });
  }
});

// ── GET /api/dashboard/hoist-x?line=100 — Transporter X timeline ───
router.get('/dashboard/hoist-x', (req, res) => {
  const lineKey = parseInt(req.query.line) || 100;
  const state = _getState ? _getState() : {};
  const { stationsConfig, twaLimits, plcMeta } = state;
  const stations = (stationsConfig && stationsConfig.stations) || [];
  const simMs = ((plcMeta && plcMeta.time_s) || 0) * 1000;

  // Stations belonging to the requested line (floor(number/100)*100)
  const lineStations = stations.filter(s =>
    Math.floor((s.number || 0) / 100) * 100 === lineKey
  );
  const lineXPositions = lineStations
    .map(s => s.x_position)
    .filter(Number.isFinite);

  // Find transporters whose TWA overlaps with line stations
  const matchedTids = new Set();
  if (lineXPositions.length > 0 && twaLimits) {
    const stMinX = Math.min(...lineXPositions);
    const stMaxX = Math.max(...lineXPositions);
    for (const [tid, lim] of Object.entries(twaLimits)) {
      if (lim.x_max >= stMinX && lim.x_min <= stMaxX) {
        matchedTids.add(Number(tid));
      }
    }
  }
  // Fallback: if nothing matched, return everything we have
  if (matchedTids.size === 0) {
    for (const tid of Object.keys(hoistHistory)) matchedTids.add(Number(tid));
  }

  const series = [];
  for (const tid of matchedTids) {
    series.push({ transporterId: tid, points: hoistHistory[tid] || [] });
  }

  const yDomain = {
    minX: lineXPositions.length > 0 ? Math.min(...lineXPositions) : 0,
    maxX: lineXPositions.length > 0 ? Math.max(...lineXPositions) : 1,
  };

  res.json({
    success: true,
    series,
    yDomain,
    windowMs: HOIST_WINDOW_MS,
    nowSimTimeMs: simMs,
  });
});

// ── GET /api/station-timing-stats — Treatment times vs min/max ─────
router.get('/station-timing-stats', async (req, res) => {
  if (!_dbPool) {
    return res.json({ success: true, stations: [], batches: [] });
  }

  try {
    // Find the start of the latest production run
    const prodStartResult = await _dbPool.query(`
      SELECT created_at FROM sim_log
      WHERE event = 'PRODUCTION_START'
      ORDER BY created_at DESC
      LIMIT 1
    `);
    const prodStartTs = prodStartResult.rows.length > 0
      ? prodStartResult.rows[0].created_at
      : null;

    // 1) Per-station min/max treatment window (from lift events, current run only)
    const stationsResult = await _dbPool.query(`
      SELECT station,
             MIN(min_time_s) AS min_s,
             MAX(max_time_s) AS max_s
      FROM lift_events
      WHERE stage > 0 AND min_time_s > 0
        AND ($1::timestamptz IS NULL OR received_at >= $1)
      GROUP BY station
      ORDER BY station
    `, [prodStartTs]);

    // 2) Up to 10 most recent batches with per-station actual durations (current run only)
    const batchesResult = await _dbPool.query(`
      WITH recent AS (
        SELECT batch_code, MAX(id) AS last_ev
        FROM lift_events
        WHERE stage > 0
          AND ($1::timestamptz IS NULL OR received_at >= $1)
        GROUP BY batch_code
        ORDER BY last_ev DESC
        LIMIT 10
      )
      SELECT le.batch_code, le.station, le.actual_time_s
      FROM lift_events le
      JOIN recent r ON le.batch_code = r.batch_code
      WHERE le.stage > 0
        AND ($1::timestamptz IS NULL OR le.received_at >= $1)
      ORDER BY le.batch_code, le.station
    `, [prodStartTs]);

    const stations = stationsResult.rows.map(r => ({
      station: r.station,
      min_s: Number(r.min_s) || 0,
      max_s: Number(r.max_s) || 0,
    }));

    // Group by batch_code → batches array
    const batchMap = new Map();
    for (const row of batchesResult.rows) {
      if (!batchMap.has(row.batch_code)) batchMap.set(row.batch_code, []);
      batchMap.get(row.batch_code).push({
        station: row.station,
        duration_s: row.actual_time_s,
      });
    }
    const batches = [];
    for (const [code, stns] of batchMap) {
      batches.push({ batchId: code, stations: stns });
    }

    res.json({ success: true, stations, batches });
  } catch (err) {
    console.error('[DASHBOARD] station-timing-stats error:', err.message);
    res.json({ success: true, stations: [], batches: [] });
  }
});


// ── GET /api/live-programs — Get active production programs ────────
router.get('/live-programs', async (req, res) => {
  const { plcUnits, adapter, stationsConfig } = _getState();
  if (!adapter) {
    return res.status(503).json({ error: 'Not connected to PLC' });
  }

  try {
    // Collect active UID list
    const activeUids = [];
    if (plcUnits) {
      for (const u of plcUnits) {
        if (u.batch_state_int === 1) { // 1 = IN_PROCESS
          activeUids.push(u.unit_id);
        }
      }
    }

    if (activeUids.length === 0) {
      return res.json([]);
    }

    const programs = await adapter.getActivePrograms(activeUids);
    
    // Map station names
    const stationNameMap = {};
    const stationList = (stationsConfig && stationsConfig.stations) || [];
    stationList.forEach(s => {
      stationNameMap[s.number] = s.name || s.operation || `Station ${s.number}`;
    });

    if (programs) {
      programs.forEach(p => {
        p.steps.forEach(s => {
          s.station_name = stationNameMap[s.station_id] || `Station ${s.station_id}`;
        });
      });
    }

    res.json(programs || []);
  } catch (err) {
    console.error('Error in /live-programs:', err);
    res.status(500).json({ error: 'Failed to read live programs' });
  }
});

module.exports = { router, init, tick };

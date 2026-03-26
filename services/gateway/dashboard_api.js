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
// 2. SCHEDULER CYCLE-TIME TRACKING
// ═══════════════════════════════════════════════════════════════════════
const MAX_CYCLE_HISTORY = 1000;
const TSK_READY_PHASE = 10000;
const DEP_DONE_PHASE = 9000;

function freshStats() {
  return {
    total: 0, longest: 0,
    history: [], simHistory: [], tickHistory: [],
    startWall: 0, startTick: 0, startSimMs: 0,
    inCycle: false,
  };
}

const tskStats = freshStats();
const depStats = freshStats();
let prevTskPhase = -1;
let prevDepPhase = -1;
const tickPeriodMs = { tsk: 0, dep: 0 };
const longestTicks = { tsk: 0, dep: 0 };

function recordCycle(stats, wallMs, ticks, simDeltaMs, key) {
  stats.total++;
  if (wallMs > stats.longest) stats.longest = wallMs;
  stats.history.push(wallMs);
  stats.simHistory.push(simDeltaMs);
  stats.tickHistory.push(ticks);
  while (stats.history.length > MAX_CYCLE_HISTORY) {
    stats.history.shift();
    stats.simHistory.shift();
    stats.tickHistory.shift();
  }
  if (ticks > longestTicks[key]) longestTicks[key] = ticks;
  // Estimate tick period from last N completed cycles
  const n = Math.min(10, stats.history.length);
  const sumW = stats.history.slice(-n).reduce((a, b) => a + b, 0);
  const sumT = stats.tickHistory.slice(-n).reduce((a, b) => a + b, 0);
  tickPeriodMs[key] = sumT > 0 ? Math.round(sumW / sumT) : 0;
}

function detectCycleEdge(stats, key, prevPhase, curPhase, readyPhase, now, cycleCount, simMs) {
  // Cycle start: phase drops from >= ready to < ready (scheduler restarted)
  if (prevPhase >= readyPhase && curPhase < readyPhase && curPhase > 0) {
    stats.startWall = now;
    stats.startTick = cycleCount;
    stats.startSimMs = simMs;
    stats.inCycle = true;
  }
  // First-ever start: 0 → >0
  if (prevPhase === 0 && curPhase > 0 && curPhase < readyPhase) {
    stats.startWall = now;
    stats.startTick = cycleCount;
    stats.startSimMs = simMs;
    stats.inCycle = true;
  }
  // Cycle complete: phase reaches ready
  if (curPhase >= readyPhase && prevPhase < readyPhase && stats.inCycle) {
    const wallMs = now - stats.startWall;
    const ticks = cycleCount - stats.startTick;
    const simDelta = simMs - stats.startSimMs;
    if (wallMs > 0) recordCycle(stats, wallMs, ticks, simDelta, key);
    stats.inCycle = false;
  }
}

function trackSchedulerPhases(schedulerDebug, cycleCount, timeS) {
  if (!schedulerDebug) return;
  const tskPhase = schedulerDebug.tsk_phase || 0;
  const depPhase = schedulerDebug.dep_phase || 0;
  const now = Date.now();
  const simMs = (timeS || 0) * 1000;

  if (prevTskPhase >= 0) {
    detectCycleEdge(tskStats, 'tsk', prevTskPhase, tskPhase, TSK_READY_PHASE, now, cycleCount, simMs);
  }
  if (prevDepPhase >= 0) {
    detectCycleEdge(depStats, 'dep', prevDepPhase, depPhase, DEP_DONE_PHASE, now, cycleCount, simMs);
  }

  prevTskPhase = tskPhase;
  prevDepPhase = depPhase;
}

// ═══════════════════════════════════════════════════════════════════════
// tick()  — called from gateway poll loop every POLL_MS
// ═══════════════════════════════════════════════════════════════════════
function tick({ transporters, meta, schedulerDebug }) {
  const simMs = (meta.time_s || 0) * 1000;
  sampleHoistPositions(transporters || [], simMs);
  trackSchedulerPhases(schedulerDebug, meta.cycle_count || 0, meta.time_s || 0);
}

// ═══════════════════════════════════════════════════════════════════════
// init()
// ═══════════════════════════════════════════════════════════════════════
function init({ dbPool, getState }) {
  _dbPool = dbPool;
  _getState = getState;
}

// ═══════════════════════════════════════════════════════════════════════
// ROUTES
// ═══════════════════════════════════════════════════════════════════════

// ── GET /api/scheduler/state — TSK + DEP cycle-time stats ──────────
router.get('/scheduler/state', (req, res) => {
  res.json({
    success: true,
    state: {
      totalCycles: tskStats.total,
      longestCycleTimeMs: tskStats.longest,
      cycleTickPeriodMs: tickPeriodMs.tsk,
      longestCycleTicks: longestTicks.tsk,
      cycleHistory: tskStats.history,
      cycleSimTimeHistory: tskStats.simHistory,
      cycleTickHistory: tskStats.tickHistory,
      departureCycles: {
        totalCycles: depStats.total,
        longestCycleTimeMs: depStats.longest,
        cycleTickPeriodMs: tickPeriodMs.dep,
        longestCycleTicks: longestTicks.dep,
        cycleHistory: depStats.history,
        cycleSimTimeHistory: depStats.simHistory,
        cycleTickHistory: depStats.tickHistory,
      },
    },
  });
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
    // 1) Per-station min/max treatment window (from lift events)
    const stationsResult = await _dbPool.query(`
      SELECT station,
             MIN(min_time_s) AS min_s,
             MAX(max_time_s) AS max_s
      FROM lift_events
      WHERE stage > 0 AND min_time_s > 0
      GROUP BY station
      ORDER BY station
    `);

    // 2) Up to 10 most recent batches with per-station actual durations
    const batchesResult = await _dbPool.query(`
      WITH recent AS (
        SELECT batch_code, MAX(id) AS last_ev
        FROM lift_events
        WHERE stage > 0
        GROUP BY batch_code
        ORDER BY last_ev DESC
        LIMIT 10
      )
      SELECT le.batch_code, le.station, le.actual_time_s
      FROM lift_events le
      JOIN recent r ON le.batch_code = r.batch_code
      WHERE le.stage > 0
      ORDER BY le.batch_code, le.station
    `);

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

module.exports = { router, init, tick };

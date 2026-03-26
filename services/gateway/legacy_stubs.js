/**
 * Legacy stub endpoints — returns empty/default responses for
 * simulator endpoints that are no longer needed now that PLC
 * handles all simulation logic.
 *
 * These stubs prevent the UI from getting 502/404 errors for
 * features that haven't been fully removed from the frontend yet.
 */

const express = require('express');
const router = express.Router();

// ─── Sim control (PLC runs natively, no JS sim) ─────────────────────────

// GET /api/sim/time — return current unix time in seconds
let _getSimTime = () => ({ running: false });
function init({ getSimTime }) {
  _getSimTime = getSimTime;
}

router.get('/sim/time', (req, res) => {
  const { running, plcTime } = _getSimTime();
  res.json({
    time: plcTime || 0,
    running,
    speed: 1,
    timestamp: new Date().toISOString()
  });
});

router.post('/sim/start', (req, res) => {
  res.json({ success: true, message: 'PLC runs natively — use /api/plc/start instead' });
});

router.get('/sim/speed', (req, res) => {
  res.json({ speed: 1 });
});

router.post('/sim/speed', (req, res) => {
  res.json({ success: true, speed: 1, message: 'Speed control not applicable — PLC runs in real time' });
});

// ─── Scheduler / schedules — real endpoints in index.js ──────────────────

// /api/scheduler/state — now served by dashboard_api.js

// ─── Batch schedules (legacy) ────────────────────────────────────────────

router.get('/batch-schedules', (req, res) => {
  res.json({ batchSchedules: [] });
});

router.get('/batch-schedules/:id', (req, res) => {
  res.json({ batchId: req.params.id, schedule: [] });
});

// /api/dashboard/hoist-x — now served by dashboard_api.js
// /api/station-timing-stats — now served by dashboard_api.js

// ─── Departure cycles (endpoint never existed, UI may reference it) ─────

router.get('/departure-cycles', (req, res) => {
  res.json({ cycles: [] });
});

module.exports = { router, init };

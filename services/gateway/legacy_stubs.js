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
  const { running } = _getSimTime();
  res.json({
    time: Math.floor(Date.now() / 1000),
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

// /api/schedules, /api/transporter-schedule, /api/scheduler/state
// are now served from index.js with actual PLC Modbus data.
// Only keep /api/scheduler/state stub for backward compatibility.
router.get('/scheduler/state', (req, res) => {
  res.json({
    state: 'idle',
    message: 'PLC handles scheduling natively',
    transporters: []
  });
});

// ─── Batch schedules (legacy) ────────────────────────────────────────────

router.get('/batch-schedules', (req, res) => {
  res.json({ batchSchedules: [] });
});

router.get('/batch-schedules/:id', (req, res) => {
  res.json({ batchId: req.params.id, schedule: [] });
});

// ─── Dashboard (legacy hoist-x timeline) ─────────────────────────────────

router.get('/dashboard/hoist-x', (req, res) => {
  res.json({ data: [], timestamp: new Date().toISOString() });
});

// ─── Station timing stats (legacy) ──────────────────────────────────────

router.get('/station-timing-stats', (req, res) => {
  res.json({ stats: [], timestamp: new Date().toISOString() });
});

// ─── Departure cycles (endpoint never existed, UI may reference it) ─────

router.get('/departure-cycles', (req, res) => {
  res.json({ cycles: [] });
});

module.exports = { router, init };

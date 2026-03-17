/**
 * Production Queue Dispatcher
 *
 * Maintains a production queue (list of batches with treatment programs).
 * Watches the start station via Modbus polling. When a unit is at the start
 * station with status=USED, target=TO_NONE, no batch assigned, and has been
 * there for >= loading_time_s, dispatches the next batch from the queue:
 *   - Writes batch header (code, state=NOT_PROCESSED, program_id) to PLC
 *   - Writes all treatment program stages to PLC
 *
 * The PLC then handles physical unit movement (DispatchTask / RunTasks).
 * The gateway only "loads" batches — it never moves units.
 *
 * Queue data lives in runtime/production_queue.json, written by
 * POST /api/production and updated here as batches are dispatched.
 */

const fs = require('fs').promises;
const path = require('path');

const QUEUE_FILE = 'production_queue.json';

class ProductionDispatcher {
  constructor() {
    this.runtimeDir = null;
    this._writeBatch = null;   // writeBatchToPLC(unitIndex, batchCode, batchState, programId)
    this._writeStage = null;   // writeProgramStageToPLC(unitIndex, stageIndex, stations[], min, max, cal)
    this._writeUnit  = null;   // writeUnitToPLC(unitId, location, status, target)

    // Queue state (loaded from / persisted to production_queue.json)
    this.queue = null;
    // { start_station, finish_station, loading_time_s, batches: [...], pointer, active, dispatched }

    // Parsed-stages cache: csv_file → stages[]
    this.stagesCache = new Map();

    // Loading timer
    this.loadingUnitId = null;
    this.loadingStartMs = null;

    // Dispatch lock (prevent re-entrant tick)
    this.dispatching = false;
  }

  /**
   * Inject dependencies. Called once at gateway startup.
   */
  init({ runtimeDir, writeBatchToPLC, writeProgramStageToPLC, writeUnitToPLC }) {
    this.runtimeDir = runtimeDir;
    this._writeBatch = writeBatchToPLC;
    this._writeStage = writeProgramStageToPLC;
    this._writeUnit  = writeUnitToPLC;
  }

  // ── Queue persistence ──────────────────────────────────────────

  async loadQueue() {
    try {
      const fp = path.join(this.runtimeDir, QUEUE_FILE);
      const raw = await fs.readFile(fp, 'utf8');
      this.queue = JSON.parse(raw);
      if (!Array.isArray(this.queue.dispatched)) this.queue.dispatched = [];
      if (typeof this.queue.pointer !== 'number') this.queue.pointer = 0;
      this.stagesCache.clear();
      console.log(
        `[DISPATCH] Queue loaded: ${this.queue.batches.length} batches, ` +
        `pointer=${this.queue.pointer}, active=${!!this.queue.active}`
      );
      return true;
    } catch (err) {
      console.error(`[DISPATCH] Failed to load queue: ${err.message}`);
      this.queue = null;
      return false;
    }
  }

  async saveState() {
    if (!this.queue) return;
    try {
      const fp = path.join(this.runtimeDir, QUEUE_FILE);
      await fs.writeFile(fp, JSON.stringify(this.queue, null, 2), 'utf8');
    } catch (err) {
      console.error(`[DISPATCH] Save error: ${err.message}`);
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────

  async activate() {
    const loaded = await this.loadQueue();
    if (!loaded || !this.queue) return false;
    this.queue.active = true;
    this.loadingUnitId = null;
    this.loadingStartMs = null;
    await this.saveState();
    const remaining = this.queue.batches.length - this.queue.pointer;
    console.log(
      `[DISPATCH] Activated — ${remaining} batches remaining, ` +
      `start_station=${this.queue.start_station}, loading=${this.queue.loading_time_s}s`
    );
    return true;
  }

  async deactivate() {
    if (this.queue) {
      this.queue.active = false;
      await this.saveState();
    }
    this.loadingUnitId = null;
    this.loadingStartMs = null;
    console.log('[DISPATCH] Deactivated');
  }

  getStatus() {
    if (!this.queue) {
      return { active: false, total: 0, pointer: 0, remaining: 0, dispatched: [] };
    }
    return {
      active: !!this.queue.active,
      total: this.queue.batches.length,
      pointer: this.queue.pointer,
      remaining: Math.max(0, this.queue.batches.length - this.queue.pointer),
      start_station: this.queue.start_station,
      finish_station: this.queue.finish_station,
      loading_time_s: this.queue.loading_time_s,
      dispatched: this.queue.dispatched,
      loading_unit_id: this.loadingUnitId,
      loading_elapsed_s: this.loadingStartMs
        ? Math.round((Date.now() - this.loadingStartMs) / 1000)
        : null,
    };
  }

  // ── CSV parsing helpers ────────────────────────────────────────

  /**
   * Parse HH:MM:SS  or  MM:SS  or plain integer  → seconds.
   */
  parseTime(str) {
    if (typeof str === 'number') return str;
    const s = String(str).trim();
    const parts = s.split(':');
    if (parts.length === 3) {
      return parseInt(parts[0]) * 3600 + parseInt(parts[1]) * 60 + parseInt(parts[2]);
    }
    if (parts.length === 2) {
      return parseInt(parts[0]) * 60 + parseInt(parts[1]);
    }
    return parseInt(s) || 0;
  }

  /**
   * Parse a Batch CSV file into an array of stage objects.
   *
   * CSV format:  Stage,MinStat,MaxStat,MinTime,MaxTime[,CalcTime]
   *   1,115,115,00:02:00,00:03:00,00:02:00
   *   12,104,106,00:22:00,00:40:00,00:22:00
   *
   * Returns: [{ stations: [115], minTime: 120, maxTime: 180, calTime: 120 }, ...]
   */
  async parseCSV(csvFile) {
    const fp = path.join(this.runtimeDir, csvFile);
    const content = await fs.readFile(fp, 'utf8');
    const lines = content.replace(/\r/g, '').split('\n').filter(l => l.trim());
    if (lines.length < 2) return [];

    const stages = [];
    for (let i = 1; i < lines.length; i++) {
      const cols = lines[i].split(',').map(c => c.trim());
      if (cols.length < 5) continue;

      const minStat = parseInt(cols[1]) || 0;
      const maxStat = parseInt(cols[2]) || minStat;
      const minTime = this.parseTime(cols[3]);
      const maxTime = this.parseTime(cols[4]);
      const calTime = cols.length > 5 ? this.parseTime(cols[5]) : minTime;

      // Station range → array (PLC supports max 5 stations per stage)
      const stations = [];
      for (let s = minStat; s <= maxStat && stations.length < 5; s++) {
        stations.push(s);
      }

      stages.push({ stations, minTime, maxTime, calTime });
    }
    return stages;
  }

  /**
   * Get (cached) stages for a batch entry.
   */
  async getStages(batch) {
    if (this.stagesCache.has(batch.csv_file)) {
      return this.stagesCache.get(batch.csv_file);
    }
    const stages = await this.parseCSV(batch.csv_file);
    this.stagesCache.set(batch.csv_file, stages);
    return stages;
  }

  // ── Main tick — called every Modbus poll cycle ─────────────────

  /**
   * Check if conditions are met to dispatch the next batch.
   * @param {Array} plcUnits - array of unit objects from readPLCState()
   */
  async tick(plcUnits) {
    if (!this.queue || !this.queue.active) return;
    if (this.dispatching) return;

    // Queue exhausted?
    if (this.queue.pointer >= this.queue.batches.length) {
      console.log('[DISPATCH] Queue exhausted — all batches dispatched');
      await this.deactivate();
      return;
    }

    const startStation = Number(this.queue.start_station);
    const loadingTimeS = Number(this.queue.loading_time_s) || 60;

    // Find unit at start station: USED + TO_NONE + no batch
    const candidate = plcUnits.find(u =>
      u.location === startStation &&
      u.status === 1 &&                                         // USED
      (u.target === 'none' || u.target === 0) &&                // TO_NONE
      (!u.batch_code || u.batch_code === 0)                     // no batch
    );

    if (!candidate) {
      // No qualifying unit — reset timer
      if (this.loadingUnitId !== null) {
        this.loadingUnitId = null;
        this.loadingStartMs = null;
      }
      return;
    }

    // First batch dispatches immediately (no loading wait)
    const isFirstBatch = this.queue.pointer === 0 && this.queue.dispatched.length === 0;

    if (!isFirstBatch) {
      // Start or continue loading timer
      if (this.loadingUnitId !== candidate.unit_id) {
        this.loadingUnitId = candidate.unit_id;
        this.loadingStartMs = Date.now();
        console.log(
          `[DISPATCH] Unit ${candidate.unit_id} at station ${startStation}` +
          ` — loading timer started (${loadingTimeS}s)`
        );
        return;
      }

      // Check elapsed
      const elapsedS = (Date.now() - this.loadingStartMs) / 1000;
      if (elapsedS < loadingTimeS) return;
    } else {
      console.log(`[DISPATCH] First batch — dispatching immediately to Unit ${candidate.unit_id}`);
    }

    // ═══════════════  DISPATCH  ═══════════════
    this.dispatching = true;
    const batch = this.queue.batches[this.queue.pointer];

    try {
      const stages = await this.getStages(batch);
      if (stages.length === 0) {
        console.error(`[DISPATCH] Batch ${batch.batch_number} has 0 stages — skipping`);
        this.queue.pointer++;
        await this.saveState();
        return;
      }

      // 1) Write batch header: NOT_PROCESSED = 0
      await this._writeBatch(
        candidate.unit_id,
        batch.batch_number,
        0,                       // NOT_PROCESSED
        batch.program_id
      );

      // 1b) Set unit target to TO_PROCESS (3)
      await this._writeUnit(
        candidate.unit_id,
        candidate.location,      // keep current location
        1,                       // USED
        3                        // TO_PROCESS
      );

      // 2) Write every treatment program stage
      for (let i = 0; i < stages.length; i++) {
        const st = stages[i];
        await this._writeStage(
          candidate.unit_id,
          i + 1,                  // stageIndex (1-based)
          st.stations,
          st.minTime,
          st.maxTime,
          st.calTime
        );
      }

      // 3) Record dispatch
      this.queue.dispatched.push({
        batch_number: batch.batch_number,
        program_id: batch.program_id,
        unit_id: candidate.unit_id,
        stages_count: stages.length,
        dispatched_at: new Date().toISOString(),
      });
      this.queue.pointer++;
      await this.saveState();

      console.log(
        `[DISPATCH] ✓ Batch ${batch.batch_number} ` +
        `(prog ${batch.program_id}, ${stages.length} stages) → Unit ${candidate.unit_id} ` +
        `[${this.queue.pointer}/${this.queue.batches.length}]`
      );

      // Reset timer for next batch
      this.loadingUnitId = null;
      this.loadingStartMs = null;

    } catch (err) {
      console.error(`[DISPATCH] Error dispatching batch ${batch.batch_number}: ${err.message}`);
      // Don't advance pointer — will retry on next tick
    } finally {
      this.dispatching = false;
    }
  }
}

module.exports = new ProductionDispatcher();

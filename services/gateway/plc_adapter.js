/**
 * plc_adapter.js — Abstract PLC communication interface
 *
 * Defines the contract between the gateway REST API and the PLC runtime.
 * Implementations: opcua_adapter.js (CODESYS), modbus_adapter.js (OpenPLC fallback).
 *
 * All methods return Promises. The adapter manages its own connection lifecycle.
 */

class PlcAdapter {
  constructor() {
    this.connected = false;
    this.onStateUpdate = null;   // callback: (state) => void
  }

  /** Connect to PLC runtime. Resolves when initial connection is established. */
  async connect() { throw new Error('Not implemented'); }

  /** Disconnect gracefully. */
  async disconnect() { throw new Error('Not implemented'); }

  /** @returns {boolean} Whether the adapter has an active connection. */
  isConnected() { return this.connected; }

  // ── Read operations ───────────────────────────────────────────

  /**
   * Read full PLC state (transporters, units, batches, meta, etc.)
   * @returns {object|null} Parsed state object or null on error
   *   { transporters[], units[], meta, twaLimits, taskQueues, depState, schedulerDebug }
   */
  async readState() { throw new Error('Not implemented'); }

  /**
   * Read schedule window for a specific unit.
   * @param {number} unitId - 1..10
   * @returns {object|null} { unit_id, stages[] } or null
   */
  async readScheduleWindow(unitId) { throw new Error('Not implemented'); }

  /**
   * Read event queue head from PLC.
   * @returns {object|null} { count, seq, msgType, timestamp, fields[] } or null
   */
  async readEventHead() { throw new Error('Not implemented'); }

  // ── Write operations ──────────────────────────────────────────

  /**
   * Send plant configuration to PLC (stations, transporters, NTT, etc.)
   * Replaces the entire RESET Modbus sequence.
   * @param {object} config - { stations[], transporters[], units[], nttData, stationCount }
   * @returns {object} { success, error? }
   */
  async uploadConfig(config) { throw new Error('Not implemented'); }

  /**
   * Send manual move command.
   * @param {number} transporterId - 1..3
   * @param {number} liftStation
   * @param {number} sinkStation
   */
  async writeCommand(transporterId, liftStation, sinkStation) { throw new Error('Not implemented'); }

  /**
   * Write unit state (location, status, target).
   * @param {number} unitId - 1..10
   * @param {number} location - station number
   * @param {number} status - 0=NOT_USED, 1=USED
   * @param {number} target - 0..5
   */
  async writeUnit(unitId, location, status, target) { throw new Error('Not implemented'); }

  /**
   * Write batch header to PLC.
   * @param {number} unitIndex - 1..10
   * @param {number} batchCode
   * @param {number} batchState - 0=NOT_PROCESSED, 1=IN_PROCESS, 2=PROCESSED
   * @param {number} programId
   */
  async writeBatch(unitIndex, batchCode, batchState, programId) { throw new Error('Not implemented'); }

  /**
   * Write one treatment program stage.
   * @param {number} unitIndex - 1..10
   * @param {number} stageIndex - 1..30
   * @param {number[]} stations - up to 5 station numbers
   * @param {number} minTime - seconds
   * @param {number} maxTime - seconds
   * @param {number} calTime - seconds
   */
  async writeProgramStage(unitIndex, stageIndex, stations, minTime, maxTime, calTime) {
    throw new Error('Not implemented');
  }

  /**
   * Write avoid status for a station.
   * @param {number} stationNumber
   * @param {number} avoidStatus - 0=none, 1=passable, 2=block
   */
  async writeAvoidStatus(stationNumber, avoidStatus) { throw new Error('Not implemented'); }

  /**
   * Acknowledge event (write ack_seq back to PLC).
   * @param {number} seq - sequence number to acknowledge
   */
  async ackEvent(seq) { throw new Error('Not implemented'); }

  /**
   * Write unix time to PLC for clock sync.
   * @param {number} unixSeconds
   */
  async writeTime(unixSeconds) { throw new Error('Not implemented'); }

  /**
   * Write production queue flag.
   * @param {number} value - 0 or 1
   */
  async writeProductionQueue(value) { throw new Error('Not implemented'); }

  /**
   * Write schedule request (unit_id for sliding window protocol).
   * @param {number} unitId - 1..10
   */
  async writeScheduleRequest(unitId) { throw new Error('Not implemented'); }

  // ── PLC Runtime control ────────────────────────────────────

  /**
   * Start the PLC runtime.
   * @returns {object} { success, message?, error? }
   */
  async startPlc() { throw new Error('Not implemented'); }

  /**
   * Stop the PLC runtime.
   * @returns {object} { success, message?, error? }
   */
  async stopPlc() { throw new Error('Not implemented'); }

  /**
   * Get PLC runtime status.
   * @returns {object} { status: 'running'|'stopped'|'unknown', detail? }
   */
  async getPlcStatus() { return { status: 'unknown' }; }

  /**
   * Get PLC runtime logs.
   * @param {number} lines - number of tail lines (default 100)
   * @returns {object} { success, logs }
   */
  async getPlcLogs(lines = 100) { throw new Error('Not implemented'); }
}

module.exports = PlcAdapter;

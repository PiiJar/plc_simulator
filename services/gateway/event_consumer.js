/**
 * event_consumer.js — PLC event queue consumer (OPC UA version)
 *
 * Reads the head event message via the PlcAdapter,
 * inserts it into PostgreSQL, and acknowledges via adapter.
 *
 * Called every poll cycle from the main gateway loop.
 * The adapter's readState() already includes event head data.
 */

const MSG_TYPE_NAMES = {
  1: 'TASK_DISPATCHED',
  2: 'LIFT',
  3: 'TASK_COMPLETE',
  4: 'BATCH_ACTIVATED',
  5: 'BATCH_COMPLETED',
};

let lastAckedSeq = 0;
let dbReady = false;
let plcTimeOffset = null;   // unix_seconds - plc_g_time_s (computed once)

/**
 * Verify database connectivity.
 */
async function checkDb(pool) {
  try {
    await pool.query('SELECT 1');
    if (!dbReady) console.log('[EVENT] Database connection OK');
    dbReady = true;
  } catch (err) {
    if (dbReady) console.error('[EVENT] Database connection lost:', err.message);
    dbReady = false;
  }
}

/**
 * Main event processing — call from poll loop.
 * Reads event from adapter state, inserts to DB, writes ack.
 *
 * @param {PlcAdapter} adapter  Connected PLC adapter
 * @param {object} pool         pg Pool instance (or null if DB disabled)
 */
async function processEvents(adapter, pool) {
  if (!pool) return;

  if (!dbReady) {
    await checkDb(pool);
    if (!dbReady) return;
  }

  try {
    // Read event head via adapter
    const event = await adapter.readEventHead();
    if (!event || event.count === 0) return;
    if (event.seq === 0) return;
    if (event.seq === lastAckedSeq) return;

    // Reconstruct timestamp
    const unixSeconds = event.timestamp;
    const plcTs = new Date(unixSeconds * 1000);

    // Payload fields
    const f = event.fields || [];
    while (f.length < 12) f.push(0);

    // Insert into PostgreSQL
    await pool.query(
      `INSERT INTO events (seq, msg_type, plc_ts, f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`,
      [event.seq, event.msgType, plcTs, ...f]
    );

    // Acknowledge
    await adapter.ackEvent(event.seq);
    lastAckedSeq = event.seq;

    const typeName = MSG_TYPE_NAMES[event.msgType] || `TYPE_${event.msgType}`;
    console.log(`[EVENT] ${typeName} seq=${event.seq} f=[${f.join(',')}] ts=${plcTs.toISOString()}`);

  } catch (err) {
    if (err.message && err.message.includes('No OPC-UA session')) {
      return;  // Connection error — handled by adapter reconnect
    }
    console.error('[EVENT] Error:', err.message);
    dbReady = false;
  }
}

module.exports = { processEvents, checkDb };

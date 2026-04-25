#!/usr/bin/env node
/**
 * export_movement_times.js — Read gMove[1..N] from PLC via OPC UA
 * and save as movement_times.json to the active customer's plant folder.
 *
 * Usage:  node export_movement_times.js
 */

const fs = require('fs');
const path = require('path');
const { OPCUAClient, AttributeIds } = require('node-opcua-client');

// ─── Config ──────────────────────────────────────────────────────────────
const OPCUA_URL = process.env.OPCUA_ENDPOINT || process.env.OPCUA_URL || 'opc.tcp://localhost:4840';
const NS = parseInt(process.env.OPCUA_NS || '4');
const DEVICE = process.env.OPCUA_DEVICE || 'CODESYS Control for Linux SL';
const MAX_TRANSPORTERS = 3;
const MAX_STATIONS = 30;   // station indices 1..30  (station 101 = index 1)
const STATION_OFFSET = 100;

const CUSTOMERS_DIR = fs.existsSync('/data/customers')
  ? '/data/customers'
  : path.join(__dirname, '..', '..', 'data', 'customers');

const RUNTIME_DIR = fs.existsSync('/data/runtime')
  ? '/data/runtime'
  : path.join(__dirname, '..', '..', 'data', 'runtime');

// ─── OPC UA helpers ──────────────────────────────────────────────────────
function nodeId(gvl, varPath) {
  const prefix = DEVICE ? `${DEVICE}.Application` : 'Application';
  return `ns=${NS};s=|var|${prefix}.${gvl}.${varPath}`;
}
const S = (v) => nodeId('GVL_JC_Scheduler', v);

async function readInt(session, nid) {
  const r = await session.read({ nodeId: nid, attributeId: AttributeIds.Value });
  return r.value.value ?? 0;
}

// ─── Main ────────────────────────────────────────────────────────────────
(async () => {
  // 1. Determine active customer plant dir
  const simFile = path.join(RUNTIME_DIR, 'simulation_purpose.json');
  if (!fs.existsSync(simFile)) {
    console.error('No simulation_purpose.json — no active customer.');
    process.exit(1);
  }
  const sim = JSON.parse(fs.readFileSync(simFile, 'utf8'));
  const customer = sim.customer;
  const plant = sim.plant?.name;
  if (!customer || !plant) {
    console.error('No customer/plant in simulation_purpose.json.');
    process.exit(1);
  }
  const plantDir = path.join(CUSTOMERS_DIR, customer, plant);
  if (!fs.existsSync(plantDir)) {
    console.error(`Plant dir not found: ${plantDir}`);
    process.exit(1);
  }

  // 2. Connect OPC UA
  const client = OPCUAClient.create({ endpointMustExist: false });
  await client.connect(OPCUA_URL);
  const session = await client.createSession();
  console.log('Connected to PLC');

  // 3. Read gMove[1..N]
  const result = {};
  for (let tid = 1; tid <= MAX_TRANSPORTERS; tid++) {
    const key = `transporter_${tid}`;
    const lift_s = {};
    const sink_s = {};
    const travel = {};

    // Lift & sink times (×10 in PLC → seconds)
    for (let idx = 1; idx <= MAX_STATIONS; idx++) {
      const stn = idx + STATION_OFFSET;
      const liftVal = await readInt(session, S(`gMove[${tid}].LiftTime[${idx}]`));
      const sinkVal = await readInt(session, S(`gMove[${tid}].SinkTime[${idx}]`));
      if (liftVal !== 0) lift_s[stn] = liftVal / 10;
      if (sinkVal !== 0) sink_s[stn] = sinkVal / 10;
    }

    // Travel times (×10 in PLC → seconds)
    for (let from = 1; from <= MAX_STATIONS; from++) {
      const fromStn = from + STATION_OFFSET;
      const row = {};
      let hasAny = false;
      for (let to = 1; to <= MAX_STATIONS; to++) {
        const toStn = to + STATION_OFFSET;
        const val = await readInt(session, S(`gMove[${tid}].Travel[${from}].ToTime[${to}]`));
        if (val !== 0) {
          row[toStn] = val / 10;
          hasAny = true;
        }
      }
      if (hasAny) travel[fromStn] = row;
    }

    result[key] = { id: tid, lift_s, sink_s, travel };

    // Read last transfer status from gActualMove[tid]
    const amBase = `gActualMove[${tid}]`;
    const lastStartStn = await readInt(session, S(`${amBase}.StartStation`));
    const lastLiftStn  = await readInt(session, S(`${amBase}.LiftStation`));
    const lastSinkStn  = await readInt(session, S(`${amBase}.SinkStation`));
    const invalidated  = await readInt(session, S(`${amBase}.Invalidated`));
    result[key].last_transfer = {
      start_station: lastStartStn,
      lift_station: lastLiftStn,
      sink_station: lastSinkStn,
      invalidated: !!invalidated,
    };

    console.log(`  transporter ${tid}: ${Object.keys(lift_s).length} lift, ${Object.keys(sink_s).length} sink, ${Object.keys(travel).length} travel rows, last_invalidated=${!!invalidated}`);

  }

  await session.close();
  await client.disconnect();

  // 4. Backup existing file, then write new
  const outFile = path.join(plantDir, 'movement_times.json');
  const bakFile = outFile + '.bak';
  if (fs.existsSync(outFile)) {
    fs.copyFileSync(outFile, bakFile);
    console.log(`Backup: ${bakFile}`);
  }
  const tmp = `${outFile}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmp, JSON.stringify(result, null, 2), 'utf8');
  fs.renameSync(tmp, outFile);
  console.log(`Saved: ${outFile}`);
})().catch(err => {
  console.error(err);
  process.exit(1);
});

/**
 * db.js — PostgreSQL connection pool for event storage.
 * Reads config from environment variables (set in docker-compose.yml).
 */
const { Pool } = require('pg');

const pool = new Pool({
  host:     process.env.DB_HOST || 'localhost',
  port:     parseInt(process.env.DB_PORT || '5432'),
  user:     process.env.DB_USER || 'plc',
  password: process.env.DB_PASS || 'plc_pass',
  database: process.env.DB_NAME || 'plc_events',
  max: 5,
  connectionTimeoutMillis: 5000,
  idleTimeoutMillis: 30000,
});

pool.on('error', (err) => {
  console.error('[DB] Unexpected pool error:', err.message);
});

module.exports = pool;

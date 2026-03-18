-- ============================================================
-- init.sql — PLC event database schema
-- ============================================================
-- Automatically executed by PostgreSQL Docker on first start.
-- Stores all PLC events in a single generic table.
-- Decoded views provide msg_type-specific column names.
-- ============================================================

CREATE TABLE IF NOT EXISTS events (
  id          SERIAL PRIMARY KEY,
  seq         INT NOT NULL,                     -- PLC sequence number (1..32000)
  msg_type    INT NOT NULL,                     -- 1=TASK_DISPATCHED, 2=LIFT
  plc_ts      TIMESTAMPTZ NOT NULL,             -- PLC-side unix timestamp
  f1          INT, f2  INT, f3  INT, f4  INT,
  f5          INT, f6  INT, f7  INT, f8  INT,
  f9          INT, f10 INT, f11 INT, f12 INT,
  received_at TIMESTAMPTZ DEFAULT NOW()         -- gateway receive time
);

-- Index for fast time-range queries
CREATE INDEX IF NOT EXISTS idx_events_plc_ts ON events (plc_ts);
CREATE INDEX IF NOT EXISTS idx_events_msg_type ON events (msg_type);

-- ============================================================
-- VIEW: task_dispatched
-- msg_type = 1: Task assigned to transporter by DispatchTask FB
-- Payload: f1=TaskId_Hi f2=TaskId_Lo f3=transporter f4=UnitId
--          f5=lift_stn f6=sink_stn f7=stage f8=batch_code
--          f9=calc_time(s) f10=min_time(s) f11=max_time(s)
--          f12=xfer_total(s)
-- ============================================================
CREATE OR REPLACE VIEW task_dispatched AS
SELECT
  id, seq, plc_ts, received_at,
  f1 * 65536 + f2 AS task_id,
  f3              AS transporter_id,
  f4              AS unit_id,
  f5              AS lift_station,
  f6              AS sink_station,
  f7              AS stage,            -- 0 = NTT (no-treatment task)
  f8              AS batch_code,
  f9              AS calc_time_s,
  f10             AS min_time_s,
  f11             AS max_time_s,
  f12             AS xfer_total_s      -- calculated transfer time (seconds)
FROM events
WHERE msg_type = 1;

-- ============================================================
-- VIEW: lift_events
-- msg_type = 2: Transporter lifts unit from station
-- Payload: f1=TaskId_Hi f2=TaskId_Lo f3=transporter f4=UnitId
--          f5=lift_stn f6=batch_code f7=stage f8=actual_time(s)
--          f9=calc_time(s) f10=min_time(s) f11=max_time(s)
--          f12=xfer_total(s)
-- ============================================================
CREATE OR REPLACE VIEW lift_events AS
SELECT
  id, seq, plc_ts, received_at,
  f1 * 65536 + f2 AS task_id,
  f3              AS transporter_id,
  f4              AS unit_id,
  f5              AS station,
  f6              AS batch_code,
  f7              AS stage,
  f8              AS actual_time_s,    -- how long unit was at station (seconds)
  f9              AS calc_time_s,
  f10             AS min_time_s,
  f11             AS max_time_s,
  f12             AS xfer_total_s      -- calculated transfer time (seconds)
FROM events
WHERE msg_type = 2;

-- ============================================================
-- VIEW: task_complete
-- msg_type = 3: Full task lifecycle timing breakdown
-- Payload: f1=TaskId_Hi f2=TaskId_Lo f3=transporter
--          f4=siirto_nostoasemalle(s)  f5=odotus_ennen_nostoa(s)
--          f6=nosto(s) f7=valutus(s) f8=trip_close(s)
--          f9=siirto_laskuasemalle(s) f10=trip_open(s)
--          f11=lasku(s) f12=total(s)
-- ============================================================
CREATE OR REPLACE VIEW task_complete AS
SELECT
  id, seq, plc_ts, received_at,
  f1 * 65536 + f2 AS task_id,
  f3              AS transporter_id,
  f4              AS travel_to_lift_s,   -- siirto nostoasemalle
  f5              AS wait_before_lift_s, -- odotus ennen nostoa (max(treat,dev_delay))
  f6              AS lift_s,             -- nosto
  f7              AS dripping_s,         -- valutus
  f8              AS trip_close_s,       -- trip close (drip tray)
  f9              AS travel_to_sink_s,   -- siirto laskuasemalle
  f10             AS trip_open_s,        -- trip open (drip tray)
  f11             AS sink_s,             -- lasku
  f12             AS total_s             -- kokonaisaika
FROM events
WHERE msg_type = 3;

-- ============================================================
-- TABLE: sim_log
-- Simulation lifecycle log (reset, start, stop, etc.)
-- Used to correlate PLC events with production runs.
-- ============================================================
CREATE TABLE IF NOT EXISTS sim_log (
  id          SERIAL PRIMARY KEY,
  event       TEXT NOT NULL,           -- 'RESET', 'PRODUCTION_START', 'PRODUCTION_STOP', ...
  customer    TEXT,
  plant       TEXT,
  detail      JSONB,                   -- optional extra data (e.g. queue status)
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sim_log_created ON sim_log (created_at);
CREATE INDEX IF NOT EXISTS idx_sim_log_event   ON sim_log (event);

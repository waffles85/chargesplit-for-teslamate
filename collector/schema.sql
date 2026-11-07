-- ChargeSplit database schema. Safe to re-run: everything is IF NOT EXISTS / CREATE OR REPLACE.
-- Lives in ChargeSplit's own database; nothing here touches any other system.

CREATE SCHEMA IF NOT EXISTS chargesplit;

-- ---------------------------------------------------------------- settings
CREATE TABLE IF NOT EXISTS chargesplit.settings (
    key   text PRIMARY KEY,
    value text NOT NULL
);
INSERT INTO chargesplit.settings (key, value) VALUES
    ('home_geofence', 'Home'),          -- overwritten from HOME_GEOFENCE at every start
    ('other_car_noise_kwh', '0.3')      -- per-hour residual below this (while the Tesla charges) is metering noise
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------- tariff
-- One row per tariff period. Add a row when your rates change; history keeps its old rates.
CREATE TABLE IF NOT EXISTS chargesplit.tariff (
    valid_from         date PRIMARY KEY,
    supplier           text,
    plan               text,
    day_c_per_kwh      numeric NOT NULL,
    night_c_per_kwh    numeric NOT NULL,
    night_start        time    NOT NULL DEFAULT '23:00',
    night_end          time    NOT NULL DEFAULT '08:00',
    standing_c_per_day numeric NOT NULL
);
-- Example Irish day/night tariff only. Replace with your own — see README.
INSERT INTO chargesplit.tariff VALUES
    ('2026-01-01', 'Example', 'Day/Night', 27.577, 13.462, '23:00', '08:00', 90.361)
ON CONFLICT (valid_from) DO NOTHING;

-- ---------------------------------------------------------------- raw data
-- Hourly history from myenergi (Zappi grid CT + Zappi output), kWh.
CREATE TABLE IF NOT EXISTS chargesplit.myenergi_hourly (
    hour_utc        timestamptz PRIMARY KEY,
    import_kwh      numeric NOT NULL DEFAULT 0,
    export_kwh      numeric NOT NULL DEFAULT 0,
    generated_kwh   numeric NOT NULL DEFAULT 0,
    zappi_kwh       numeric NOT NULL DEFAULT 0,
    zappi_boost_kwh numeric NOT NULL DEFAULT 0,
    fetched_at      timestamptz NOT NULL DEFAULT now()
);

-- Per-minute Zappi output (only minutes with charging), used for exact other-car session times.
CREATE TABLE IF NOT EXISTS chargesplit.myenergi_minute (
    ts        timestamptz PRIMARY KEY,
    zappi_kwh numeric NOT NULL
);
-- Days whose minute data has been fetched (complete = the day had ended when fetched).
CREATE TABLE IF NOT EXISTS chargesplit.myenergi_minute_days (
    day        date PRIMARY KEY,
    complete   boolean NOT NULL DEFAULT false,
    fetched_at timestamptz NOT NULL DEFAULT now()
);

-- Optional ESB Networks smart-meter 30-min intervals. Overrides the CT for grid import where present.
CREATE TABLE IF NOT EXISTS chargesplit.esb_interval (
    end_utc    timestamptz PRIMARY KEY,
    import_kwh numeric NOT NULL
);

-- Zappi live samples every ~30 s. Pruned after LIVE_RETENTION_DAYS.
CREATE TABLE IF NOT EXISTS chargesplit.live (
    ts            timestamptz PRIMARY KEY,
    grid_w        integer,
    zappi_w       integer,
    generation_w  integer,
    zappi_status  text,
    plug_status   text,
    session_kwh   numeric
);

-- Tesla charging snapshots built from MQTT: one row every ~30 s while charging,
-- plus one at every charging-state change. No location, VIN or other vehicle data is stored.
CREATE TABLE IF NOT EXISTS chargesplit.tesla_snapshots (
    ts              timestamptz NOT NULL,
    car_id          integer     NOT NULL,
    charging        boolean     NOT NULL,
    kw              numeric     NOT NULL DEFAULT 0,
    geofence        text,
    energy_added    numeric,
    PRIMARY KEY (car_id, ts)
);
CREATE INDEX IF NOT EXISTS tesla_snapshots_ts ON chargesplit.tesla_snapshots (ts);

-- Earlier Tesla charging imported from CSV (see import_history.py). Only used for
-- times before ChargeSplit's own MQTT tracking began, so nothing is counted twice.
CREATE TABLE IF NOT EXISTS chargesplit.tesla_import_hourly (
    hour_utc timestamptz PRIMARY KEY,
    kwh      numeric NOT NULL,
    source   text
);
CREATE TABLE IF NOT EXISTS chargesplit.tesla_import_sessions (
    start_utc timestamptz PRIMARY KEY,
    end_utc   timestamptz NOT NULL,
    kwh       numeric NOT NULL,
    source    text
);

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION chargesplit.is_home(g text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    -- matches "Home", "home", "🏡 Home" etc. against the configured geofence name
    SELECT lower(regexp_replace(coalesce(g, ''), '^[^[:alnum:]]+', ''))
         = lower(regexp_replace((SELECT value FROM chargesplit.settings WHERE key = 'home_geofence'), '^[^[:alnum:]]+', ''))
$$;

CREATE OR REPLACE FUNCTION chargesplit.is_night(ts timestamptz) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN t.night_start > t.night_end
                THEN (ts AT TIME ZONE 'Europe/Dublin')::time >= t.night_start
                  OR (ts AT TIME ZONE 'Europe/Dublin')::time <  t.night_end
                ELSE (ts AT TIME ZONE 'Europe/Dublin')::time >= t.night_start
                 AND (ts AT TIME ZONE 'Europe/Dublin')::time <  t.night_end END
    FROM chargesplit.tariff t
    WHERE t.valid_from <= (ts AT TIME ZONE 'Europe/Dublin')::date
    ORDER BY t.valid_from DESC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION chargesplit.rate_c(ts timestamptz) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN chargesplit.is_night(ts) THEN t.night_c_per_kwh ELSE t.day_c_per_kwh END
    FROM chargesplit.tariff t
    WHERE t.valid_from <= (ts AT TIME ZONE 'Europe/Dublin')::date
    ORDER BY t.valid_from DESC LIMIT 1
$$;

-- Energy per Tesla snapshot at home: power held until the next snapshot, gap capped at 2 min.
-- LEAD runs over all snapshots (incl. the "stopped" row), so a session's last sample ends exactly when charging stopped.
CREATE OR REPLACE VIEW chargesplit.tesla_home_energy AS
-- The newest sample (no next row yet) counts up to now, so in-progress sessions stay live.
SELECT car_id, ts, kw, held, ts + held * interval '1 second' AS end_ts, kw * held / 3600.0 AS kwh
FROM (
  SELECT y.*, LEAST(COALESCE(secs, GREATEST(EXTRACT(EPOCH FROM (now() - ts)), 0)), 120) AS held
  FROM (
    SELECT s.*, EXTRACT(EPOCH FROM (LEAD(s.ts) OVER (PARTITION BY s.car_id ORDER BY s.ts) - s.ts)) AS secs
    FROM chargesplit.tesla_snapshots s
  ) y
) x
WHERE charging AND chargesplit.is_home(geofence);

DROP MATERIALIZED VIEW IF EXISTS chargesplit.tesla_home_hourly CASCADE;
CREATE MATERIALIZED VIEW chargesplit.tesla_home_hourly AS
WITH first_live AS (SELECT date_trunc('hour', MIN(ts)) AS h FROM chargesplit.tesla_snapshots)
SELECT date_trunc('hour', ts) AS hour_utc, SUM(kwh) AS tesla_kwh
FROM chargesplit.tesla_home_energy GROUP BY 1
UNION ALL
SELECT i.hour_utc, i.kwh
FROM chargesplit.tesla_import_hourly i, first_live f
WHERE f.h IS NULL OR i.hour_utc < f.h;
CREATE UNIQUE INDEX ON chargesplit.tesla_home_hourly (hour_utc);

-- ---------------------------------------------------------------- combined hourly view
CREATE OR REPLACE VIEW chargesplit.hourly AS
WITH esb AS (
    SELECT date_trunc('hour', end_utc - interval '30 minutes') AS hour_utc, SUM(import_kwh) AS import_kwh
    FROM chargesplit.esb_interval GROUP BY 1
),
hours AS (
    SELECT hour_utc FROM chargesplit.myenergi_hourly
    UNION SELECT hour_utc FROM esb
    UNION SELECT hour_utc FROM chargesplit.tesla_home_hourly
),
base AS (
    SELECT h.hour_utc,
        (h.hour_utc AT TIME ZONE 'Europe/Dublin') AS hour_local,
        COALESCE(e.import_kwh, m.import_kwh, 0) AS grid_import_kwh,
        CASE WHEN e.import_kwh IS NOT NULL THEN 'ESB' ELSE 'Zappi CT' END AS import_source,
        m.zappi_kwh AS zappi_kwh_raw,
        COALESCE(t.tesla_kwh, 0) AS tesla_raw
    FROM hours h
    LEFT JOIN esb e                          ON e.hour_utc = h.hour_utc
    LEFT JOIN chargesplit.myenergi_hourly m  ON m.hour_utc = h.hour_utc
    LEFT JOIN chargesplit.tesla_home_hourly t ON t.hour_utc = h.hour_utc
),
split AS (
    SELECT b.*,
        COALESCE(b.zappi_kwh_raw, b.tesla_raw) AS zappi_kwh,
        CASE WHEN b.zappi_kwh_raw IS NULL THEN b.tesla_raw ELSE LEAST(b.tesla_raw, b.zappi_kwh_raw) END AS tesla_kwh
    FROM base b
),
calc AS (
    SELECT s.*,
        CASE
            WHEN s.zappi_kwh - s.tesla_kwh <= 0 THEN 0
            WHEN s.tesla_kwh > 0 AND s.zappi_kwh - s.tesla_kwh
                 < (SELECT value::numeric FROM chargesplit.settings WHERE key = 'other_car_noise_kwh') THEN 0
            ELSE s.zappi_kwh - s.tesla_kwh
        END AS other_car_kwh,
        chargesplit.rate_c(s.hour_utc) AS rate_c,
        CASE WHEN chargesplit.is_night(s.hour_utc) THEN 'night' ELSE 'day' END AS band
    FROM split s
),
adj AS (
    SELECT c.*,
        -- Tesla absorbs small metering differences so Tesla + other car = Zappi
        CASE WHEN c.zappi_kwh_raw IS NOT NULL AND c.tesla_raw > 0 THEN c.zappi_kwh - c.other_car_kwh
             ELSE c.tesla_kwh END AS tesla_adj
    FROM calc c
)
SELECT
    hour_utc, hour_local, band, import_source, rate_c,
    grid_import_kwh, zappi_kwh,
    tesla_adj AS tesla_kwh,
    other_car_kwh,
    GREATEST(grid_import_kwh - tesla_adj - other_car_kwh, 0) AS house_kwh,
    grid_import_kwh * rate_c / 100 AS grid_eur,
    zappi_kwh       * rate_c / 100 AS zappi_eur,
    tesla_adj       * rate_c / 100 AS tesla_eur,
    other_car_kwh   * rate_c / 100 AS other_car_eur,
    GREATEST(grid_import_kwh - tesla_adj - other_car_kwh, 0) * rate_c / 100 AS house_eur
FROM adj;

-- ---------------------------------------------------------------- daily view (adds standing charge)
CREATE OR REPLACE VIEW chargesplit.daily AS
WITH d AS (
    SELECT hour_local::date AS day,
        SUM(grid_import_kwh) AS grid_import_kwh,
        SUM(grid_import_kwh) FILTER (WHERE band = 'night') AS grid_night_kwh,
        SUM(grid_import_kwh) FILTER (WHERE band = 'day')   AS grid_day_kwh,
        SUM(zappi_kwh) AS zappi_kwh, SUM(tesla_kwh) AS tesla_kwh,
        SUM(other_car_kwh) AS other_car_kwh, SUM(house_kwh) AS house_kwh,
        SUM(grid_eur) AS grid_eur, SUM(zappi_eur) AS zappi_eur, SUM(tesla_eur) AS tesla_eur,
        SUM(other_car_eur) AS other_car_eur, SUM(house_eur) AS house_eur
    FROM chargesplit.hourly GROUP BY 1
)
SELECT d.*, (d.day::timestamp AT TIME ZONE 'Europe/Dublin') AS day_start_utc,
       tr.standing_c_per_day / 100 AS standing_eur
FROM d
LEFT JOIN LATERAL (
    SELECT standing_c_per_day FROM chargesplit.tariff t
    WHERE t.valid_from <= d.day ORDER BY t.valid_from DESC LIMIT 1
) tr ON true;

-- ---------------------------------------------------------------- live snapshot
CREATE OR REPLACE VIEW chargesplit.now AS
WITH z AS (SELECT * FROM chargesplit.live ORDER BY ts DESC LIMIT 1),
t AS (
    SELECT COALESCE(SUM(kw), 0) * 1000 AS tesla_w FROM (
        SELECT DISTINCT ON (car_id) car_id, kw, charging, geofence, ts
        FROM chargesplit.tesla_snapshots ORDER BY car_id, ts DESC
    ) latest
    WHERE charging AND chargesplit.is_home(geofence) AND ts > now() - interval '3 minutes'
)
SELECT
    z.ts AS zappi_ts, z.grid_w, z.zappi_w, z.zappi_status, z.plug_status, z.session_kwh,
    t.tesla_w,
    CASE WHEN t.tesla_w > 0 AND COALESCE(z.zappi_w, 0) - t.tesla_w < 500 THEN 0
         ELSE GREATEST(COALESCE(z.zappi_w, 0) - t.tesla_w, 0) END AS other_car_w,
    CASE WHEN chargesplit.is_night(now()) THEN 'Night' ELSE 'Day' END AS band,
    chargesplit.rate_c(now()) AS rate_c
FROM t LEFT JOIN z ON true;

-- ---------------------------------------------------------------- charging sessions per car
-- Tesla: from MQTT snapshots (to ~30 s) or imported history.
-- Other car: the Zappi has one cable, so any charging minute outside a Tesla session is the other car
-- (to the minute). Days without minute data fall back to hourly blocks (to the hour).
CREATE OR REPLACE VIEW chargesplit.charge_sessions AS
WITH te AS (
    SELECT car_id, ts, end_ts, kwh,
           chargesplit.rate_c(ts) AS rate_c,
           CASE WHEN ts - LAG(ts) OVER (PARTITION BY car_id ORDER BY ts) > interval '5 minutes'
                  OR LAG(ts) OVER (PARTITION BY car_id ORDER BY ts) IS NULL THEN 1 ELSE 0 END AS new_session
    FROM chargesplit.tesla_home_energy
),
tg AS (SELECT *, SUM(new_session) OVER (PARTITION BY car_id ORDER BY ts) AS sid FROM te),
tesla AS (
    SELECT 'Tesla'::text AS car, MIN(ts) AS start_utc,
           CASE WHEN MAX(ts) > now() - interval '2 minutes' THEN NULL ELSE MAX(end_ts) END AS end_utc,
           SUM(kwh) AS kwh, SUM(kwh * rate_c) / 100 AS cost_eur, 'to ~30 s'::text AS precision
    FROM tg GROUP BY car_id, sid
),
imported AS (
    SELECT 'Tesla'::text, s.start_utc, s.end_utc, s.kwh,
           (SELECT SUM(s.kwh * EXTRACT(EPOCH FROM (LEAST(s.end_utc, h + interval '1 hour') - GREATEST(s.start_utc, h)))
                       / NULLIF(EXTRACT(EPOCH FROM (s.end_utc - s.start_utc)), 0)
                       * chargesplit.rate_c(GREATEST(s.start_utc, h))) / 100
            FROM generate_series(date_trunc('hour', s.start_utc), s.end_utc, interval '1 hour') h
            WHERE h < s.end_utc),
           'imported'::text
    FROM chargesplit.tesla_import_sessions s
    WHERE s.start_utc < COALESCE((SELECT MIN(ts) FROM chargesplit.tesla_snapshots), 'infinity')
),
tesla_windows AS (
    SELECT start_utc - interval '2 minutes' AS w_start, COALESCE(end_utc, now()) + interval '2 minutes' AS w_end FROM tesla
    UNION ALL
    SELECT start_utc - interval '2 minutes', end_utc + interval '2 minutes' FROM imported
),
om AS (   -- charging minutes (>= ~1 kW) not inside any Tesla session
    SELECT m.ts, m.zappi_kwh
    FROM chargesplit.myenergi_minute m
    WHERE m.zappi_kwh >= 1.0 / 60
      AND EXISTS (SELECT 1 FROM chargesplit.myenergi_minute_days d WHERE d.day = (m.ts AT TIME ZONE 'UTC')::date)
      AND NOT EXISTS (SELECT 1 FROM tesla_windows w WHERE m.ts >= w.w_start AND m.ts < w.w_end)
),
omn AS (
    SELECT *, CASE WHEN ts - LAG(ts) OVER (ORDER BY ts) <= interval '5 minutes' THEN 0 ELSE 1 END AS new_session
    FROM om
),
omg AS (SELECT *, SUM(new_session) OVER (ORDER BY ts) AS sid FROM omn),
other_minute AS (
    SELECT 'Other car'::text, MIN(ts), MAX(ts) + interval '1 minute', SUM(zappi_kwh),
           SUM(zappi_kwh * chargesplit.rate_c(ts)) / 100, 'to the minute'::text
    FROM omg GROUP BY sid HAVING SUM(zappi_kwh) >= 0.2
),
other_hourly AS (   -- fallback for days without minute data
    SELECT 'Other car'::text, MIN(hour_utc), MAX(hour_utc) + interval '1 hour',
           SUM(other_car_kwh), SUM(other_car_eur), 'to the hour'::text
    FROM (
        SELECT hour_utc, other_car_kwh, other_car_eur,
               hour_utc - ROW_NUMBER() OVER (ORDER BY hour_utc) * interval '1 hour' AS grp
        FROM chargesplit.hourly h
        WHERE other_car_kwh >= 0.2
          AND NOT EXISTS (SELECT 1 FROM chargesplit.myenergi_minute_days d
                          WHERE d.day = (h.hour_utc AT TIME ZONE 'UTC')::date)
    ) i GROUP BY grp
)
SELECT * FROM tesla
UNION ALL SELECT * FROM imported
UNION ALL SELECT * FROM other_minute
UNION ALL SELECT * FROM other_hourly;

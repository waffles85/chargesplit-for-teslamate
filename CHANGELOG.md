# Changelog

## 1.2.0 — 2026-11-07
- Name your non-Tesla car (`OTHER_CAR_NAME`); the dashboard uses it everywhere instead of "Other car".
- New `configure.sh`: interactive setup of `.env` (generates database passwords, never shows secrets); `--name` changes just the car name.

## 1.1.0 — 2026-11-07
- Other car's sessions are now accurate to the minute, using the Zappi's per-minute history (fetched only for days with charging, including a one-off backfill). Days without minute data fall back to hourly blocks.
- Costs unchanged: still priced from metered hourly kWh.

## 1.0.0 — 2026-11-07
First public release.
- Standalone stack: collector, PostgreSQL and Grafana, running next to TeslaMate.
- Tesla charging read from TeslaMate's MQTT feed (charging topics only).
- Zappi live power and hourly history from the myenergi API, with backfill.
- Day/night tariff costing; per-car monthly costs, night-rate share, charging times and sessions.
- Optional ESB Networks smart-meter import for billing-grade grid figures.
- Read-only database user for Grafana; importable dashboard for an existing Grafana.
- One-off import of earlier Tesla charging history from CSV (sessions or hourly), merged without double counting.

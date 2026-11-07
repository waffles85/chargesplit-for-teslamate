# ChargeSplit for TeslaMate

> **This project is an unofficial community tool and is not affiliated with, endorsed by, or supported by the official TeslaMate project.**

ChargeSplit works out what each of your cars costs to charge at home when two cars share one myenergi **Zappi**, and only one of them is a Tesla logged by TeslaMate.

It gets the Tesla's charging from TeslaMate's MQTT feed and the Zappi and grid figures from the myenergi API. It works out the other car's share as **Zappi minus Tesla**, then prices everything on your day/night tariff. The results appear in a live Grafana dashboard:

- **Live** (every 30 s): grid power, Zappi output, Tesla, other car, the current rate.
- **Per car, per month:** € cost, kWh, effective c/kWh, and the share charged at the night rate.
- **Charging times:** when each car charged, start and end times of day against the night-rate window, and a sessions table.
- **Totals and trends:** estimated bill, charging's share of it, daily kWh and € by Tesla / other car / rest of house.

Free to use, non-commercial, AGPL-3.0.

## What you need

- **TeslaMate** with its MQTT broker running (on by default in TeslaMate's standard Docker install).
- A **myenergi Zappi with a hub**, plus a myenergi API key.
- **Docker** with Compose, on the same machine as TeslaMate (or with network access to its MQTT broker).
- A **geofence for your home** set up in TeslaMate.

## Install

```bash
git clone https://github.com/waffles85/chargesplit-for-teslamate.git
cd chargesplit-for-teslamate
bash configure.sh
```

`configure.sh` asks for each setting and writes `.env`, which only your user can read. It generates the database passwords itself and never displays secrets. It asks for:

| Setting | What to enter |
|---|---|
| Grafana admin password | Your login for the dashboard |
| myenergi hub serial and API key | myaccount.myenergi.com → your hub → Advanced → Generate new API key |
| Home geofence | The name of your home geofence in TeslaMate, e.g. `Home` |
| Other car's name | What to call your non-Tesla car on the dashboard, e.g. `Leaf`. Defaults to "Other car". |

If your TeslaMate stack doesn't use the default Docker network name, also set `MQTT_DOCKER_NETWORK` in `.env` (check with `docker network ls`). You can also copy `.env.example` to `.env` and edit it by hand instead.

Start it:

```bash
docker compose up -d --build
docker compose logs -f collector
```

You should see `schema ready`, then `MQTT connected`, then `Zappi found`. A backfill of 180 days of Zappi history then runs in the background, ending with `backfill done` after about 5–10 minutes.

Open **http://localhost:3001** and log in as `admin` with your `GRAFANA_ADMIN_PASSWORD`. The ChargeSplit dashboard is the home page.

**History:** Zappi and grid history is backfilled automatically. Tesla charging is tracked live from install. To include earlier Tesla charging, import it once (see below).

### If your MQTT broker isn't in Docker

Set `MQTT_HOST` (and `MQTT_PORT`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_TLS` as needed). Then remove the `mqtt` network lines from `docker-compose.yml`: the `- mqtt` entry under `collector`, and the `networks.mqtt` block at the end. For a broker on the same machine, use `MQTT_HOST=host.docker.internal`.

## How the numbers are worked out

| Figure | Source |
|---|---|
| Grid import | Zappi grid CT clamp, hourly. If you import an ESB smart-meter file, its data replaces the CT figure for those hours. |
| Zappi total | myenergi hourly history (boost + diverted energy) |
| Tesla at home | TeslaMate MQTT charging topics, sampled every 30 s while charging at the home geofence: current × voltage × phases, or `charger_power` |
| Other car | Zappi total − Tesla, per hour. Gaps under 0.3 kWh/h while the Tesla charges count as metering noise and go to the Tesla. |
| Cost | Each hour is priced at the day or night rate in force on that date, in local time (`Europe/Dublin`) |
| Effective c/kWh | A car's € ÷ its kWh for the period, i.e. the blend of day and night charging |

Costs are energy only. The standing charge is shown in the bill estimate but not split between cars. Levies such as PSO aren't included.

**Precision:** Tesla sessions are accurate to about 30 s. Other-car sessions are accurate to the minute: the Zappi has one cable, so every charging minute outside a Tesla session is the other car's. Minute data is fetched only for days with charging; if it's unavailable for a day, that day falls back to hourly blocks. Costs always come from the metered hourly kWh, so precision doesn't change them.

## Renaming the other car

```bash
bash configure.sh --name
docker compose up -d
```

The dashboard updates within a minute.

## Your tariff

The database starts with an **example** day/night tariff: 27.577c day, 13.462c night (23:00–08:00) and 90.361c/day standing charge. Replace it with your own:

```bash
docker compose exec db psql -U chargesplit chargesplit
```
```sql
DELETE FROM chargesplit.tariff;   -- remove the example
INSERT INTO chargesplit.tariff VALUES ('2026-02-01', 'My supplier', 'Day/Night', 27.577, 13.462, '23:00', '08:00', 90.361);
-- when prices change, add a row from that date; earlier periods keep their old rates
```

Use the rates as they appear on your bill, i.e. including VAT if your bill shows rates with VAT.

Day/night bands use `Europe/Dublin` time. If you're elsewhere, replace `Europe/Dublin` in `collector/schema.sql` and in the dashboard JSON.

## Importing earlier Tesla charging history

MQTT only carries live data, so for the time before ChargeSplit was installed you can import a CSV once. Imported data fills in only the period before ChargeSplit's own tracking began, so nothing is counted twice. Re-importing a file updates it rather than duplicating it.

Two formats are accepted. Column names are matched case-insensitively, and extra columns are ignored.

| Kind | Columns | Notes |
|---|---|---|
| `sessions` | `start`, `end`, `kWh` (also `start_date`, `end_date`, `charge_energy_used`, `charge_energy_added`) | Each session's kWh is spread across the hours it ran. If there's a location column (`address`, `location` or `geofence`), only rows at your `HOME_GEOFENCE` are imported. |
| `hourly` | `hour`, `kwh` (also `hour_utc`, `tesla_kwh`) | More precise for day/night splits. Takes priority over hours worked out from sessions. |

Timestamps with a zone (`…Z`, `+01:00`) are used as given. Timestamps without one are read as `Europe/Dublin` time; change this with `--tz`.

A session list is the easiest to get, e.g. from TeslaMate's **Charges** dashboard in Grafana: set the time range, open the table's panel menu, then **Inspect → Data → Download CSV**. Rename the columns if they don't match the table above.

```bash
docker compose cp charges.csv collector:/tmp/charges.csv
docker compose exec collector python import_history.py sessions /tmp/charges.csv
```

## Optional: ESB Networks smart-meter data (Ireland)

Download the 30-min HDF file from myaccount.esbnetworks.ie (My Energy Consumption → Downloads), then run:

```bash
docker compose cp HDF_kw_*.csv collector:/tmp/hdf.csv
docker compose exec collector python esb_import.py /tmp/hdf.csv
```

Only timestamps and kWh are stored. Your MPRN and meter serial in the file are ignored. Don't commit HDF files; `.gitignore` excludes them.

## Using a Grafana you already run

ChargeSplit's own Grafana is the supported setup. To use another Grafana instead:

1. Make the ChargeSplit database reachable from it, for example by publishing it on localhost only. Create `docker-compose.override.yml`:
   ```yaml
   services:
     db:
       ports:
         - "127.0.0.1:5433:5432"
   ```
2. In your Grafana, add a **PostgreSQL** datasource:
   - host `host.docker.internal:5433` (or the machine's address)
   - database `chargesplit`
   - user `chargesplit_reader`, with your `GRAFANA_DB_PASSWORD`
   - SSL off
3. Import `dashboards/chargesplit-import.json` and choose that datasource when asked.

## Upgrading

```bash
git pull
docker compose up -d --build
```

Database changes are applied automatically when the collector starts. Your data and `.env` are kept. See `CHANGELOG.md` for what's changed.

## Security & privacy

- **Secrets** come only from `.env`, which `.gitignore` excludes.
- **MQTT:** the collector subscribes only to the charging topics: `charging_state`, `charger_power`, `charger_actual_current`, `charger_voltage`, `charger_phases`, `charge_energy_added`, `geofence`. It never subscribes to location, VIN or other vehicle data, and stores none.
- **Grafana's database access:** it uses a **read-only** database user.
- **Ports:** the database isn't exposed outside Docker, and the collector opens no ports. Outbound, it connects only to your MQTT broker and to `*.myenergi.net` over HTTPS with certificate checks on.
- **Logs** never include your API key, and show only the last 3 digits of the Zappi serial.
- **Remote access:** don't expose Grafana (port 3001) to the internet. Use a VPN such as Tailscale.

## Limitations

- One Zappi and one home. Tesla cars logged by TeslaMate are summed together as "Tesla".
- myenergi's API is unofficial and could change without notice.
- The other car's figure is worked out by subtraction, so it absorbs anything else the Zappi supplies.

## Licence & trademarks

ChargeSplit is licensed under the **GNU AGPL-3.0**; see `LICENSE`. It's non-commercial and free to use.

It works with TeslaMate only through TeslaMate's MQTT integration and contains no TeslaMate code. TeslaMate is a trademark of the TeslaMate project. Tesla is a trademark of Tesla, Inc. myenergi and Zappi are trademarks of myenergi Ltd.

**This project is an unofficial community tool and is not affiliated with, endorsed by, or supported by the official TeslaMate project.**

"""
ChargeSplit collector.

- myenergi (Zappi): live status every LIVE_SECONDS, hourly history every HISTORY_SECONDS,
  backfill of BACKFILL_DAYS on first start.
- Tesla: subscribes to the charging topics TeslaMate publishes over MQTT and stores a snapshot
  every LIVE_SECONDS while a car is charging, plus one at each charging-state change.

Only these MQTT topics are subscribed: charging_state, charger_power, charger_actual_current,
charger_voltage, charger_phases, charge_energy_added, geofence. No location, VIN or other data.

This project is an unofficial community tool and is not affiliated with, endorsed by,
or supported by the official TeslaMate project.
"""
import datetime as dt
import logging
import os
import pathlib
import queue
import re
import sys
import threading
import time

import paho.mqtt.client as mqtt
import psycopg2
import psycopg2.extras
import requests
from psycopg2 import sql
from requests.auth import HTTPDigestAuth

log = logging.getLogger("chargesplit")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")

HERE = pathlib.Path(__file__).parent
VERSION = (HERE / "VERSION").read_text().strip() if (HERE / "VERSION").exists() else "dev"

HUB = os.environ.get("MYENERGI_HUB_SERIAL", "")
KEY = os.environ.get("MYENERGI_API_KEY", "")
ZAPPI = os.environ.get("MYENERGI_ZAPPI_SERIAL", "")
HOME_GEOFENCE = os.getenv("HOME_GEOFENCE", "Home")
OTHER_CAR_NAME_RAW = os.getenv("OTHER_CAR_NAME", "").strip()
DASHBOARD_TEMPLATE = pathlib.Path(os.getenv("DASHBOARD_TEMPLATE", "/app/dashboard-template/chargesplit.json"))
DASHBOARD_OUT = pathlib.Path(os.getenv("DASHBOARD_OUT", "/app/dashboard-out"))
READER_PASSWORD = os.getenv("GRAFANA_DB_PASSWORD", "")

MQTT_HOST = os.getenv("MQTT_HOST", "mosquitto")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USERNAME = os.getenv("MQTT_USERNAME") or None
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD") or None
MQTT_TLS = os.getenv("MQTT_TLS", "false").lower() == "true"
MQTT_PREFIX = os.getenv("MQTT_TOPIC_PREFIX", "teslamate").rstrip("/")

LIVE_SECONDS = int(os.getenv("LIVE_SECONDS", "30"))
HISTORY_SECONDS = int(os.getenv("HISTORY_SECONDS", "300"))
BACKFILL_DAYS = int(os.getenv("BACKFILL_DAYS", "180"))
LIVE_RETENTION_DAYS = int(os.getenv("LIVE_RETENTION_DAYS", "35"))
J_PER_KWH = 3_600_000

TOPICS = ("charging_state", "charger_power", "charger_actual_current", "charger_voltage",
          "charger_phases", "charge_energy_added", "geofence")
ZAPPI_STATUS = {0: "Starting", 1: "Waiting for surplus", 2: "DSR", 3: "Charging", 4: "Boosting", 5: "Complete", 6: "Stopped"}
PLUG_STATUS = {"A": "EV disconnected", "B1": "EV connected", "B2": "Waiting for EV", "C1": "EV ready", "C2": "Charging", "F": "Fault"}


def other_car_name(raw=None):
    """Display name for the non-Tesla car. Letters, digits, spaces and . _ - only (it's used in SQL and JSON)."""
    raw = (OTHER_CAR_NAME_RAW if raw is None else raw).strip()
    if not raw:
        return "Other car"
    if not re.fullmatch(r"[\w .\-]{1,30}", raw) or raw.lower() == "tesla":
        log.warning("OTHER_CAR_NAME %r not allowed (letters, digits, spaces, . _ - ; max 30; not 'Tesla') — using 'Other car'", raw)
        return "Other car"
    return raw


def render_dashboard(name):
    """Write the provisioned dashboard with the other car's name filled in."""
    if not DASHBOARD_TEMPLATE.exists():
        log.warning("dashboard template not found at %s — dashboard keeps its default names", DASHBOARD_TEMPLATE)
        return
    text = DASHBOARD_TEMPLATE.read_text(encoding="utf-8").replace("Other car", name)
    DASHBOARD_OUT.mkdir(parents=True, exist_ok=True)
    tmp = DASHBOARD_OUT / ".chargesplit.json.tmp"
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, DASHBOARD_OUT / "chargesplit.json")
    log.info("dashboard ready (other car shown as '%s')", name)


# ------------------------------------------------------------------ database
def db():
    return psycopg2.connect(
        host=os.getenv("DATABASE_HOST", "db"),
        port=int(os.getenv("DATABASE_PORT", "5432")),
        user=os.environ["DATABASE_USER"],
        password=os.environ["DATABASE_PASS"],
        dbname=os.environ["DATABASE_NAME"],
    )


def init_schema(conn):
    with conn, conn.cursor() as cur:
        cur.execute((HERE / "schema.sql").read_text())
        cur.execute("""INSERT INTO chargesplit.settings (key, value) VALUES
                         ('home_geofence', %s), ('version', %s), ('other_car_name', %s)
                       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value""", (HOME_GEOFENCE, VERSION, other_car_name()))
        if READER_PASSWORD:
            # read-only login for Grafana
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = 'chargesplit_reader'")
            verb = "ALTER" if cur.fetchone() else "CREATE"
            cur.execute(sql.SQL(verb + " ROLE chargesplit_reader WITH LOGIN PASSWORD {}").format(sql.Literal(READER_PASSWORD)))
            cur.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO chargesplit_reader").format(sql.Identifier(os.environ["DATABASE_NAME"])))
            cur.execute("GRANT USAGE ON SCHEMA chargesplit TO chargesplit_reader")
            cur.execute("GRANT SELECT ON ALL TABLES IN SCHEMA chargesplit TO chargesplit_reader")
            cur.execute("GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA chargesplit TO chargesplit_reader")
    log.info("schema ready (ChargeSplit v%s, home geofence '%s')", VERSION, HOME_GEOFENCE)


# ------------------------------------------------------------------ myenergi
class MyEnergi:
    def __init__(self, hub, key):
        self.auth = HTTPDigestAuth(hub, key)
        self.s = requests.Session()
        self.s.headers.update({"Accept": "application/json", "User-Agent": "chargesplit"})
        self.host = None

    def _resolve(self):
        r = self.s.get("https://director.myenergi.net/cgi-jstatus-*", auth=self.auth, timeout=20)
        asn = r.headers.get("x_myenergi-asn")
        if r.status_code == 401:
            raise RuntimeError("myenergi rejected the hub serial / API key (HTTP 401)")
        if not r.ok:
            raise RuntimeError(f"myenergi director: HTTP {r.status_code}")
        self.host = asn if asn and asn != "undefined" else "s18.myenergi.net"
        log.info("myenergi server: %s", self.host)

    def get(self, path):
        if not self.host:
            self._resolve()
        r = self.s.get(f"https://{self.host}/{path}", auth=self.auth, timeout=30)
        if r.status_code in (401, 404, 502):
            self._resolve()
            r = self.s.get(f"https://{self.host}/{path}", auth=self.auth, timeout=30)
        if not r.ok:  # keep the Zappi serial out of logs
            raise RuntimeError(f"myenergi {path.split('-')[1] if '-' in path else path}: HTTP {r.status_code}")
        return r.json()

    def zappi_serial(self):
        for z in self.get("cgi-jstatus-Z").get("zappi", []):
            return str(z["sno"])
        raise RuntimeError("No Zappi found on this hub")

    def zappi_status(self, sno):
        return self.get(f"cgi-jstatus-Z{sno}")["zappi"][0]

    def day_hours(self, sno, day):
        data = self.get(f"cgi-jdayhour-Z{sno}-{day.year}-{day.month}-{day.day}")
        rows = next((v for v in data.values() if isinstance(v, list)), [])
        out = []
        for r in rows:
            ts = dt.datetime(r["yr"], r["mon"], r["dom"], r.get("hr", 0), tzinfo=dt.timezone.utc)
            boost = sum(r.get(k, 0) for k in ("h1b", "h2b", "h3b"))
            divert = sum(r.get(k, 0) for k in ("h1d", "h2d", "h3d"))
            out.append((ts, r.get("imp", 0) / J_PER_KWH, r.get("exp", 0) / J_PER_KWH,
                        r.get("gep", 0) / J_PER_KWH, (boost + divert) / J_PER_KWH, boost / J_PER_KWH))
        return out


def day_minutes(me, sno, day):
    """Per-minute Zappi output for one UTC day: [(ts, kWh)] for minutes with charging."""
    data = me.get(f"cgi-jday-Z{sno}-{day.year}-{day.month}-{day.day}")
    rows = next((v for v in data.values() if isinstance(v, list)), [])
    out = []
    for r in rows:
        j = sum(r.get(k, 0) for k in ("h1b", "h2b", "h3b", "h1d", "h2d", "h3d"))
        if j > 0:
            ts = dt.datetime(r["yr"], r["mon"], r["dom"], r.get("hr", 0), r.get("min", 0), tzinfo=dt.timezone.utc)
            out.append((ts, j / J_PER_KWH))
    return out


def save_minutes(conn, day, rows):
    complete = day < dt.datetime.now(dt.timezone.utc).date()
    with conn, conn.cursor() as cur:
        if rows:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO chargesplit.myenergi_minute (ts, zappi_kwh) VALUES %s
                ON CONFLICT (ts) DO UPDATE SET zappi_kwh = EXCLUDED.zappi_kwh""", rows)
        cur.execute("""INSERT INTO chargesplit.myenergi_minute_days (day, complete) VALUES (%s, %s)
                       ON CONFLICT (day) DO UPDATE SET complete = EXCLUDED.complete, fetched_at = now()""",
                    (day, complete))


def backfill_minutes(conn, me, sno, sleep=time.sleep):
    """Fetch minute data for past days that had charging and aren't complete yet."""
    with conn, conn.cursor() as cur:
        cur.execute("""
            SELECT DISTINCT (hour_utc AT TIME ZONE 'UTC')::date AS day
            FROM chargesplit.myenergi_hourly h
            WHERE zappi_kwh > 0.1
              AND NOT EXISTS (SELECT 1 FROM chargesplit.myenergi_minute_days d
                              WHERE d.day = (h.hour_utc AT TIME ZONE 'UTC')::date AND d.complete)
            ORDER BY 1""")
        days = [r[0] for r in cur.fetchall()]
    if not days:
        return
    log.info("fetching minute-by-minute charging data for %d days", len(days))
    for i, day in enumerate(days, 1):
        try:
            save_minutes(conn, day, day_minutes(me, sno, day))
        except Exception as e:
            log.warning("minute data %s failed: %s", day, e)
        if i % 10 == 0:
            log.info("minute data progress: %d/%d days", i, len(days))
        sleep(1)
    log.info("minute data done: %d days", len(days))


def save_hours(conn, rows):
    if not rows:
        return
    with conn, conn.cursor() as cur:
        psycopg2.extras.execute_values(cur, """
            INSERT INTO chargesplit.myenergi_hourly
                (hour_utc, import_kwh, export_kwh, generated_kwh, zappi_kwh, zappi_boost_kwh)
            VALUES %s
            ON CONFLICT (hour_utc) DO UPDATE SET
                import_kwh = EXCLUDED.import_kwh, export_kwh = EXCLUDED.export_kwh,
                generated_kwh = EXCLUDED.generated_kwh, zappi_kwh = EXCLUDED.zappi_kwh,
                zappi_boost_kwh = EXCLUDED.zappi_boost_kwh, fetched_at = now()""", rows)


def save_live(conn, z):
    with conn, conn.cursor() as cur:
        cur.execute("""INSERT INTO chargesplit.live
                       (ts, grid_w, zappi_w, generation_w, zappi_status, plug_status, session_kwh)
                       VALUES (now(), %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING""",
                    (int(z.get("grd", 0)), int(z.get("div", 0)), int(z.get("gen", 0)),
                     ZAPPI_STATUS.get(z.get("sta"), str(z.get("sta"))), PLUG_STATUS.get(z.get("pst"), z.get("pst")),
                     z.get("che")))


def backfill(conn, me, sno, sleep=time.sleep):
    with conn, conn.cursor() as cur:
        cur.execute("SELECT min(hour_utc) FROM chargesplit.myenergi_hourly")
        earliest = cur.fetchone()[0]
    today = dt.datetime.now(dt.timezone.utc).date()
    start, end = today - dt.timedelta(days=BACKFILL_DAYS), (earliest.date() if earliest else today)
    if start >= end:
        log.info("hourly history up to date")
        return
    log.info("backfilling myenergi history %s -> %s", start, end)
    day, n = start, 0
    while day < end:
        try:
            save_hours(conn, me.day_hours(sno, day))
        except Exception as e:
            log.warning("backfill %s failed: %s", day, e)
        day += dt.timedelta(days=1)
        n += 1
        if n % 20 == 0:
            log.info("backfill progress: up to %s", day)
        sleep(1)
    log.info("backfill done: %s -> %s", start, end)


def backfill_all(conn, me, sno):
    backfill(conn, me, sno)
    backfill_minutes(conn, me, sno)


# ------------------------------------------------------------------ Tesla via MQTT
class TeslaState:
    """Latest charging-related values per car, fed by MQTT messages."""

    def __init__(self):
        self.cars = {}
        self.lock = threading.Lock()
        self.events = queue.Queue()  # (ts, car_id) on charging-state changes

    @staticmethod
    def _num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None

    def update(self, car_id, field, payload, now=None):
        now = now or dt.datetime.now(dt.timezone.utc)
        with self.lock:
            car = self.cars.setdefault(car_id, {})
            before = car.get("charging_state")
            car[field] = payload if field in ("charging_state", "geofence") else self._num(payload)
            if field == "charging_state" and payload != before:
                self.events.put((now, car_id))

    def snapshot(self, car_id):
        with self.lock:
            c = dict(self.cars.get(car_id, {}))
        charging = c.get("charging_state") == "Charging"
        amps, volts, phases = c.get("charger_actual_current"), c.get("charger_voltage"), c.get("charger_phases")
        if charging and amps and volts:
            kw = amps * volts * (3 if phases == 3 else 1) / 1000.0
        else:
            kw = c.get("charger_power") or 0.0
        return charging, (kw if charging else 0.0), c.get("geofence"), c.get("charge_energy_added")

    def charging_cars(self):
        with self.lock:
            return [cid for cid, c in self.cars.items() if c.get("charging_state") == "Charging"]


def save_snapshot(conn, ts, car_id, snap):
    charging, kw, geofence, energy = snap
    with conn, conn.cursor() as cur:
        cur.execute("""INSERT INTO chargesplit.tesla_snapshots (ts, car_id, charging, kw, geofence, energy_added)
                       VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING""",
                    (ts, car_id, charging, kw, geofence, energy))


def start_mqtt(state):
    def on_connect(client, userdata, flags, reason_code, properties=None):
        if reason_code != 0:
            log.error("MQTT connect failed: %s", reason_code)
            return
        for t in TOPICS:
            client.subscribe(f"{MQTT_PREFIX}/cars/+/{t}")
        log.info("MQTT connected to %s:%s, subscribed to %d charging topics", MQTT_HOST, MQTT_PORT, len(TOPICS))

    def on_message(client, userdata, msg):
        parts = msg.topic.split("/")
        try:
            car_id, field = int(parts[-2]), parts[-1]
        except (ValueError, IndexError):
            return
        state.update(car_id, field, msg.payload.decode("utf-8", "replace").strip())

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"chargesplit-{os.getpid()}")
    if MQTT_USERNAME:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    if MQTT_TLS:
        client.tls_set()
    client.on_connect, client.on_message = on_connect, on_message
    client.reconnect_delay_set(min_delay=1, max_delay=60)
    client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()
    return client


# ------------------------------------------------------------------ main loop
def main():
    if not (HUB and KEY):
        log.error("Set MYENERGI_HUB_SERIAL and MYENERGI_API_KEY")
        sys.exit(1)
    conn = db()
    init_schema(conn)
    render_dashboard(other_car_name())
    state = TeslaState()
    start_mqtt(state)

    me = MyEnergi(HUB, KEY)
    sno = ZAPPI or me.zappi_serial()
    log.info("Zappi found (serial ending %s)", sno[-3:])

    # backfill in the background so Tesla snapshots start straight away
    threading.Thread(target=backfill_all, args=(db(), me, sno), daemon=True).start()

    next_live = next_history = 0.0
    while True:
        try:
            if conn.closed:
                conn = db()
            while not state.events.empty():  # exact start/stop times
                ts, car_id = state.events.get_nowait()
                save_snapshot(conn, ts, car_id, state.snapshot(car_id))
            now = time.time()
            if now >= next_live:
                next_live = now + LIVE_SECONDS
                ts = dt.datetime.now(dt.timezone.utc)
                for car_id in state.charging_cars():
                    save_snapshot(conn, ts, car_id, state.snapshot(car_id))
                save_live(conn, me.zappi_status(sno))
            if now >= next_history:
                next_history = now + HISTORY_SECONDS
                with conn, conn.cursor() as cur:  # Tesla figures refresh even if myenergi is down
                    cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY chargesplit.tesla_home_hourly")
                    cur.execute("DELETE FROM chargesplit.live WHERE ts < now() - %s * interval '1 day'", (LIVE_RETENTION_DAYS,))
                today = dt.datetime.now(dt.timezone.utc).date()
                for d in (today - dt.timedelta(days=1), today):
                    save_hours(conn, me.day_hours(sno, d))
                    save_minutes(conn, d, day_minutes(me, sno, d))
        except psycopg2.Error as e:
            log.error("database error: %s", e)
            try:
                conn.close()
            except Exception:  # nosec B110 - reconnecting next cycle
                pass
        except Exception as e:
            log.error("cycle failed: %s", e)
        time.sleep(2)


if __name__ == "__main__":
    main()

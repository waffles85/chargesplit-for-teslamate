"""
Import earlier Tesla home-charging history from CSV, for the period before ChargeSplit started.

Two kinds of file are accepted (columns are matched case-insensitively; extra columns are ignored):

  hourly    one row per hour:     hour (or hour_utc / time),  kwh (or tesla_kwh / energy)
  sessions  one row per session:  start (or start_date / start_utc), end (or end_date / end_utc),
                                  kWh (charge_energy_used / energy used / kwh / charge_energy_added)
            If the file has a location column (address / location / geofence), only rows matching
            HOME_GEOFENCE are imported unless --all-locations is given.

Timestamps: ISO 8601 with a zone ("...Z" or "+01:00") are used as-is; timestamps without a zone are
read in --tz (default Europe/Dublin). Epoch milliseconds are also accepted.

Imported data is only used for times before ChargeSplit's own tracking began, so nothing is
counted twice. Importing the same file again updates rather than duplicates.

Usage (from the ChargeSplit folder):
  docker compose cp history.csv collector:/tmp/history.csv
  docker compose exec collector python import_history.py hourly   /tmp/history.csv
  docker compose exec collector python import_history.py sessions /tmp/history.csv
"""
import argparse
import csv
import datetime as dt
import os
import re
import sys
from zoneinfo import ZoneInfo

import psycopg2.extras

from collector import db

START = ("start", "start_date", "start_utc", "start time", "started")
END = ("end", "end_date", "end_utc", "end time", "ended")
KWH_SESSION = ("charge_energy_used", "energy used", "kwh", "charge_energy_added", "energy added", "energy", "kwh used")
HOUR = ("hour", "hour_utc", "time", "timestamp")
KWH_HOUR = ("kwh", "tesla_kwh", "energy", "tesla kwh")
LOCATION = ("address", "location", "geofence", "geofence_name")


def find(cols, names):
    low = {c.strip().lower(): c for c in cols}
    for n in names:
        if n in low:
            return low[n]
    return None


def num(v):
    m = re.search(r"-?\d+(?:[.,]\d+)?", v or "")
    return float(m.group(0).replace(",", ".")) if m else None


def when(v, tz):
    v = (v or "").strip()
    if not v:
        return None
    if re.fullmatch(r"\d{11,14}", v):  # epoch ms
        return dt.datetime.fromtimestamp(int(v) / 1000, dt.timezone.utc)
    try:
        t = dt.datetime.fromisoformat(v.replace(" ", "T", 1) if re.match(r"\d{4}-\d\d-\d\d \d", v) else v)
    except ValueError:
        for fmt in ("%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M", "%Y-%m-%d %H:%M"):
            try:
                t = dt.datetime.strptime(v, fmt)
                break
            except ValueError:
                continue
        else:
            raise ValueError(f"unrecognised timestamp: {v!r}")
    if t.tzinfo is None:
        t = t.replace(tzinfo=tz)
    return t.astimezone(dt.timezone.utc)


def home(loc, geofence):
    strip = lambda s: re.sub(r"^[^\w]+", "", (s or "").strip()).lower()
    return strip(loc) == strip(geofence)


def spread(start, end, kwh):
    """Split a session's kWh across the hours it covers, in proportion to time."""
    total = (end - start).total_seconds()
    if total <= 0:
        return {start.replace(minute=0, second=0, microsecond=0): kwh}
    out, h = {}, start.replace(minute=0, second=0, microsecond=0)
    while h < end:
        nxt = h + dt.timedelta(hours=1)
        secs = (min(end, nxt) - max(start, h)).total_seconds()
        if secs > 0:
            out[h] = out.get(h, 0) + kwh * secs / total
        h = nxt
    return out


def main():
    ap = argparse.ArgumentParser(description="Import earlier Tesla home-charging history into ChargeSplit")
    ap.add_argument("kind", choices=["hourly", "sessions"])
    ap.add_argument("file")
    ap.add_argument("--tz", default="Europe/Dublin", help="zone for timestamps without one (default Europe/Dublin)")
    ap.add_argument("--all-locations", action="store_true", help="don't filter sessions by home geofence")
    ap.add_argument("--source", default=None, help="label stored with the rows (default: file name)")
    a = ap.parse_args()
    tz, source = ZoneInfo(a.tz), a.source or os.path.basename(a.file)
    geofence = os.getenv("HOME_GEOFENCE", "Home")

    with open(a.file, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("file is empty")
    cols = rows[0].keys()
    conn = db()

    if a.kind == "hourly":
        ch, ck = find(cols, HOUR), find(cols, KWH_HOUR)
        if not (ch and ck):
            sys.exit(f"need an hour column {HOUR} and a kWh column {KWH_HOUR}; found {list(cols)}")
        data = {}
        for r in rows:
            t, k = when(r[ch], tz), num(r[ck])
            if t is not None and k is not None:
                h = t.replace(minute=0, second=0, microsecond=0)
                data[h] = data.get(h, 0) + k
        with conn, conn.cursor() as cur:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO chargesplit.tesla_import_hourly (hour_utc, kwh, source) VALUES %s
                ON CONFLICT (hour_utc) DO UPDATE SET kwh = EXCLUDED.kwh, source = EXCLUDED.source""",
                [(h, k, source) for h, k in sorted(data.items())])
        print(f"imported {len(data)} hours, {sum(data.values()):.1f} kWh"
              + (f", {min(data):%Y-%m-%d} -> {max(data):%Y-%m-%d}" if data else ""))

    else:
        cs, ce, ck, cl = find(cols, START), find(cols, END), find(cols, KWH_SESSION), find(cols, LOCATION)
        if not (cs and ce and ck):
            sys.exit(f"need start {START}, end {END} and kWh {KWH_SESSION} columns; found {list(cols)}")
        sessions, skipped_loc, skipped_bad = [], 0, 0
        for r in rows:
            if cl and not a.all_locations and not home(r.get(cl), geofence):
                skipped_loc += 1
                continue
            try:
                s, e, k = when(r[cs], tz), when(r[ce], tz), num(r[ck])
            except ValueError:
                skipped_bad += 1
                continue
            if s and e and k and k > 0 and e > s:
                sessions.append((s, e, k))
            else:
                skipped_bad += 1
        hourly = {}
        for s, e, k in sessions:
            for h, v in spread(s, e, k).items():
                hourly[h] = hourly.get(h, 0) + v
        with conn, conn.cursor() as cur:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO chargesplit.tesla_import_sessions (start_utc, end_utc, kwh, source) VALUES %s
                ON CONFLICT (start_utc) DO UPDATE SET end_utc = EXCLUDED.end_utc, kwh = EXCLUDED.kwh, source = EXCLUDED.source""",
                [(s, e, k, source) for s, e, k in sessions])
            # hourly figures from sessions never overwrite a more precise hourly import
            psycopg2.extras.execute_values(cur, """
                INSERT INTO chargesplit.tesla_import_hourly (hour_utc, kwh, source) VALUES %s
                ON CONFLICT (hour_utc) DO NOTHING""",
                [(h, v, source + " (from sessions)") for h, v in sorted(hourly.items())])
        print(f"imported {len(sessions)} sessions, {sum(k for _, _, k in sessions):.1f} kWh"
              + (f"; skipped {skipped_loc} not at '{geofence}'" if skipped_loc else "")
              + (f"; skipped {skipped_bad} unreadable/empty" if skipped_bad else ""))

    with conn, conn.cursor() as cur:
        cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY chargesplit.tesla_home_hourly")
        cur.execute("REFRESH MATERIALIZED VIEW chargesplit.tesla_windows")
    print("dashboard figures updated")


if __name__ == "__main__":
    main()

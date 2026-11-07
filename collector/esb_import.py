"""
ChargeSplit — optional: import an ESB Networks HDF file (30-min smart meter data) for billing-grade grid import.
Where ESB data exists it replaces the Zappi CT reading for grid import.

Usage (from the folder with docker-compose.yml):
  docker compose cp HDF_kw_xxxx.csv collector:/tmp/hdf.csv
  docker compose exec collector python esb_import.py /tmp/hdf.csv
"""
import csv
import datetime as dt
import sys
from zoneinfo import ZoneInfo

import psycopg2.extras

from collector import db

IE = ZoneInfo("Europe/Dublin")


def parse(path):
    rows = {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            rtype = r.get("Read Type", "")
            if "Import" not in rtype:
                continue  # skip export rows
            value = float(r["Read Value"])
            kwh = value * 0.5 if "(kW)" in rtype else value  # kW averages over 30 min -> kWh
            local = dt.datetime.strptime(r["Read Date and End Time"].strip(), "%d-%m-%Y %H:%M")
            end_utc = local.replace(tzinfo=IE).astimezone(dt.timezone.utc)
            rows[end_utc] = kwh
    return sorted(rows.items())


def main(path):
    rows = parse(path)
    conn = db()
    with conn, conn.cursor() as cur:
        psycopg2.extras.execute_values(cur, """
            INSERT INTO chargesplit.esb_interval (end_utc, import_kwh) VALUES %s
            ON CONFLICT (end_utc) DO UPDATE SET import_kwh = EXCLUDED.import_kwh""", rows)
    print(f"imported {len(rows)} intervals: {rows[0][0]} -> {rows[-1][0]}" if rows else "no import rows found")


if __name__ == "__main__":
    main(sys.argv[1])

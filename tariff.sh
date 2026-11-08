#!/bin/bash
# ChargeSplit — manage your electricity tariff (ChargeSplit must be running).
#
#   bash tariff.sh list            show your tariff history
#   bash tariff.sh add             add rates from a date (e.g. after a price change), or correct an existing date
#   bash tariff.sh remove DATE     delete the tariff that starts on DATE (YYYY-MM-DD, or 'start')
#
# Rates are in cents, as on your bill. Each tariff applies from its date until the next one.
# Changes show on the dashboard straight away, including past periods.
set -euo pipefail
cd "$(dirname "$0")"

psqlc() { docker compose exec -T db psql -U chargesplit chargesplit -q -v ON_ERROR_STOP=1 "$@"; }
die()   { echo "Error: $*" >&2; exit 1; }
is_num()  { printf '%s' "$1" | grep -Eq '^[0-9]+([.][0-9]+)?$'; }
is_time() { printf '%s' "$1" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; }
is_date() { printf '%s' "$1" | grep -Eq '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'; }

running=$(docker compose ps --status running --services 2>/dev/null || true)
grep -qx db <<< "$running" || die "ChargeSplit isn't running — start it with: docker compose up -d"

list() {
    psqlc -P pager=off -c "SELECT CASE WHEN valid_from <= '2000-01-01' THEN 'the start' ELSE valid_from::text END AS \"from\", COALESCE(supplier,'') AS supplier,
        day_c_per_kwh AS \"day c/kWh\", night_c_per_kwh AS \"night c/kWh\",
        to_char(night_start,'HH24:MI') || '–' || to_char(night_end,'HH24:MI') AS \"night hours\",
        standing_c_per_day AS \"standing c/day\"
        FROM chargesplit.tariff ORDER BY valid_from"
}

prompt() { # prompt "question" default check-function -> echoes answer
    local q="$1" def="$2" chk="$3" a
    while :; do
        printf '%s%s: ' "$q" "${def:+ [$def]}" >&2; read -r a; a="${a:-$def}"
        if [ -z "$chk" ] || "$chk" "$a"; then printf '%s' "$a"; return; fi
        echo "  not valid — try again" >&2
    done
}

case "${1:-}" in
  list)
    list ;;

  add)
    # defaults from the most recent tariff
    IFS='|' read -r d_sup d_day d_night d_ns d_ne d_st <<< "$(psqlc -tA -c "SELECT COALESCE(supplier,''), day_c_per_kwh, night_c_per_kwh,
        to_char(night_start,'HH24:MI'), to_char(night_end,'HH24:MI'), standing_c_per_day
        FROM chargesplit.tariff ORDER BY valid_from DESC LIMIT 1" | tr -d '\r')"
    [ "$d_sup" = "Example" ] && d_sup=""
    echo "New tariff — press Enter to keep the value in [brackets] (rates in cents, as on your bill)."
    from=$(prompt "Applies from (YYYY-MM-DD)" "$(date +%Y-%m-%d)" is_date)
    sup=$(prompt "Supplier (optional)" "$d_sup" "")
    day=$(prompt "Day rate c/kWh" "$d_day" is_num)
    night=$(prompt "Night rate c/kWh" "$d_night" is_num)
    ns=$(prompt "Night rate starts (HH:MM)" "${d_ns:-23:00}" is_time)
    ne=$(prompt "Night rate ends (HH:MM)" "${d_ne:-08:00}" is_time)
    [ "$ns" != "$ne" ] || die "night start and end can't be the same"
    st=$(prompt "Standing charge c/day" "$d_st" is_num)
    printf '\nFrom %s: day %sc, night %sc (%s–%s), standing %sc/day%s\nSave? [Y/n] ' \
        "$from" "$day" "$night" "$ns" "$ne" "$st" "${sup:+, $sup}"
    read -r ok; case "$ok" in n|N|no|No) echo "Not saved."; exit 0 ;; esac
    # values go in as psql variables (:'name'), never pasted into the SQL text
    psqlc -v from="$from" -v sup="$sup" -v day="$day" -v night="$night" -v ns="$ns" -v ne="$ne" -v st="$st" 2>/dev/null <<'SQL' \
      || die "not saved — the database rejected it (is $from a real date?). Nothing was changed."

BEGIN;
INSERT INTO chargesplit.tariff (valid_from, supplier, plan, day_c_per_kwh, night_c_per_kwh, night_start, night_end, standing_c_per_day)
VALUES (:'from'::date, NULLIF(:'sup', ''), 'Day/Night', :'day'::numeric, :'night'::numeric, :'ns'::time, :'ne'::time, :'st'::numeric)
ON CONFLICT (valid_from) DO UPDATE SET supplier = EXCLUDED.supplier, plan = EXCLUDED.plan,
    day_c_per_kwh = EXCLUDED.day_c_per_kwh, night_c_per_kwh = EXCLUDED.night_c_per_kwh,
    night_start = EXCLUDED.night_start, night_end = EXCLUDED.night_end, standing_c_per_day = EXCLUDED.standing_c_per_day;
-- once you have a real tariff, the example goes
DELETE FROM chargesplit.tariff WHERE supplier = 'Example'
  AND EXISTS (SELECT 1 FROM chargesplit.tariff WHERE supplier IS DISTINCT FROM 'Example');
COMMIT;
SQL
    echo "Saved."; list
    gap=$(psqlc -tA -c "SELECT to_char(min(hour_local), 'YYYY-MM-DD') FROM chargesplit.hourly
        WHERE hour_local::date < (SELECT min(valid_from) FROM chargesplit.tariff)" | tr -d '\r')
    [ -z "$gap" ] || echo "Note: your history from $gap has no tariff yet, so it shows no cost. Add a tariff dated $gap or earlier." ;;

  remove)
    d="${2:-}"; [ "$d" = "start" ] && d="2000-01-01"
    is_date "$d" || die "give the start date to remove (as shown by: bash tariff.sh list), e.g.: bash tariff.sh remove 2026-02-01"
    n=$(psqlc -tA -v d="$d" <<'SQL' | tr -d '\r'
SELECT count(*) FROM chargesplit.tariff WHERE valid_from = :'d'::date;
SQL
)
    [ "$n" = 1 ] || die "no tariff starts on $d (see: bash tariff.sh list)"
    total=$(psqlc -tA -c "SELECT count(*) FROM chargesplit.tariff" | tr -d '\r')
    [ "$total" -gt 1 ] || die "that's your only tariff — add another first, then remove this one"
    printf 'Remove the tariff starting %s? [y/N] ' "$d"; read -r ok
    case "$ok" in y|Y|yes|Yes) ;; *) echo "Not removed."; exit 0 ;; esac
    psqlc -v d="$d" <<'SQL'
DELETE FROM chargesplit.tariff WHERE valid_from = :'d'::date;
SQL
    echo "Removed."; list ;;

  *)
    sed -n '2,9p' "$0"; exit 1 ;;
esac

#!/bin/bash
# ChargeSplit — interactive setup of .env.
#   bash configure.sh            first-time setup (asks for everything)
#   bash configure.sh --name     change only the other car's name
# Tariff changes after the first start: bash tariff.sh
# Secrets are never shown. Existing values are kept unless you type a new one.
set -euo pipefail
cd "$(dirname "$0")"

ENV=.env
sedi() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }
get()  { grep -E "^$1=" "$ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
put()  { sedi "/^$1=/d" "$ENV"; printf '%s=%s\n' "$1" "$2" >> "$ENV"; }
ask()  { # ask VAR "question" [default]
    local cur def ans; cur=$(get "$1"); def="${cur:-${3:-}}"
    printf '%s%s: ' "$2" "${def:+ [$def]}"; read -r ans
    put "$1" "${ans:-$def}"
}
ask_secret() { # ask_secret VAR "question"  (keeps current value on Enter)
    local cur ans; cur=$(get "$1")
    printf '%s%s: ' "$2" "${cur:+ [press Enter to keep current]}"; read -rs ans; echo
    if [ -n "$ans" ]; then put "$1" "$ans"
    elif [ -z "$cur" ]; then echo "  required — try again"; ask_secret "$1" "$2"; fi
}
ask_num() { # ask_num VAR "question"
    local cur ans; cur=$(get "$1")
    while :; do
        printf '%s%s: ' "$2" "${cur:+ [$cur]}"; read -r ans; ans="${ans:-$cur}"
        if [ -z "$ans" ] || printf '%s' "$ans" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then put "$1" "$ans"; return; fi
        echo "  a number like 27.577 — try again"
    done
}
ask_time() { # ask_time VAR "question" default
    local cur ans; cur=$(get "$1"); cur="${cur:-$3}"
    while :; do
        printf '%s [%s]: ' "$2" "$cur"; read -r ans; ans="${ans:-$cur}"
        if printf '%s' "$ans" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then put "$1" "$ans"; return; fi
        echo "  a time like 23:00 — try again"
    done
}
ask_tariff() {
    echo
    echo "Your electricity tariff — rates in cents, as on your bill (leave the rates blank to start with an example)."
    ask TARIFF_SUPPLIER "Supplier (optional)"
    ask_num TARIFF_DAY_C "Day rate c/kWh"
    ask_num TARIFF_NIGHT_C "Night rate c/kWh"
    ask_time TARIFF_NIGHT_START "Night rate starts (HH:MM)" "23:00"
    ask_time TARIFF_NIGHT_END "Night rate ends (HH:MM)" "08:00"
    ask_num TARIFF_STANDING_C "Standing charge c/day"
    if [ "$(get TARIFF_NIGHT_START)" = "$(get TARIFF_NIGHT_END)" ]; then
        echo "  night start and end can't be the same — let's redo the times"; ask_tariff; return
    fi
}
ask_name() {
    local cur ans; cur=$(get OTHER_CAR_NAME)
    while :; do
        printf "Name for your other (non-Tesla) car, as shown on the dashboard [%s]: " "${cur:-Other car}"; read -r ans
        ans="${ans:-${cur:-Other car}}"
        if ! printf '%s' "$ans" | LC_ALL=C grep -Eq '^[A-Za-z0-9 ._-]{1,30}$'; then
            echo "  letters, digits, spaces, . _ - only, up to 30 characters"
        elif [ "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" = "tesla" ]; then
            echo "  can't be 'Tesla'"
        else put OTHER_CAR_NAME "$ans"; break; fi
    done
}

[ -f "$ENV" ] || { cp .env.example "$ENV"; }
chmod 600 "$ENV"

if [ "${1:-}" = "--name" ]; then
    ask_name
else
    echo "ChargeSplit setup — press Enter to keep the value in [brackets]."
    for v in DB_PASSWORD GRAFANA_DB_PASSWORD; do
        case "$(get $v)" in ""|change-me*) put "$v" "$(openssl rand -hex 24)"; echo "Generated $v." ;; esac
    done
    case "$(get GRAFANA_ADMIN_PASSWORD)" in change-me*) put GRAFANA_ADMIN_PASSWORD "" ;; esac
    ask_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password (avoid \$)"
    ask MYENERGI_HUB_SERIAL "myenergi hub serial"
    ask_secret MYENERGI_API_KEY "myenergi API key"
    ask HOME_GEOFENCE "Name of your home geofence in TeslaMate" "Home"
    ask_name
    ask_tariff
    echo
    echo "The tariff is applied when ChargeSplit first starts. For later changes, use: bash tariff.sh"
fi

echo
echo "Saved to $ENV. Apply with:  docker compose up -d"

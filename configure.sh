#!/bin/bash
# ChargeSplit — interactive setup of .env.
#   bash configure.sh            first-time setup (asks for everything)
#   bash configure.sh --name     change only the other car's name
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
fi

echo
echo "Saved to $ENV. Apply with:  docker compose up -d"

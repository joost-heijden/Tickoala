#!/bin/bash
# ControlPlane-adapter: geeft één start- of stopsignaal door aan de tracker.
#
# Gebruik in ControlPlane (Actions → Run Shell Script):
#   /pad/naar/controlplane-event.sh start "Kantoor A"
#   /pad/naar/controlplane-event.sh stop  "Kantoor A"
#
# De adapter is bewust dom: hij beslist niets zelf. De tracker bepaalt of het
# signaal geldig is, voorkomt dubbele blokken en logt alles.
set -uo pipefail

kind="${1:-}"
context="${2:-${WIFIHOURS_CONTEXT:-}}"

if [ -z "$kind" ] || [ -z "$context" ]; then
    echo "gebruik: $(basename "$0") start|stop <context>" >&2
    exit 2
fi

# Zoek het adaptercommando: eerst naast dit script, dan in de app, dan in PATH.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in \
    "$here/../build/WifiHours.app/Contents/Helpers/wifihours" \
    "/Applications/WifiHours.app/Contents/Helpers/wifihours" \
    "$here/../.build/release/wifihours" \
    "$here/../.build/debug/wifihours" \
    "$(command -v wifihours 2>/dev/null || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        binary="$candidate"
        break
    fi
done

if [ -z "${binary:-}" ]; then
    echo "wifihours niet gevonden — draai eerst scripts/build-app.sh" >&2
    exit 1
fi

log="${HOME}/Library/Logs/WifiHours-adapter.log"
mkdir -p "$(dirname "$log")"
# Nooit falen richting ControlPlane: alles gaat naar het logbestand.
"$binary" "$kind" --context "$context" >>"$log" 2>&1 || echo "$(date '+%F %T') adapter faalde: $kind $context" >>"$log"
exit 0

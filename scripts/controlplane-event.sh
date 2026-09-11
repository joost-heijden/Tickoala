#!/bin/bash
# ControlPlane adapter: passes a single start or stop signal to the tracker.
#
# Use in ControlPlane (Actions → Run Shell Script):
#   /path/to/controlplane-event.sh start "Office A"
#   /path/to/controlplane-event.sh stop  "Office A"
#
# The adapter is deliberately dumb: it decides nothing itself. The tracker
# determines whether the signal is valid, prevents duplicate blocks and logs
# everything.
set -uo pipefail

kind="${1:-}"
context="${2:-${WIFIHOURS_CONTEXT:-}}"

if [ -z "$kind" ] || [ -z "$context" ]; then
    echo "usage: $(basename "$0") start|stop <context>" >&2
    exit 2
fi

# Find the adapter command: first next to this script, then in the app, then in PATH.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in \
    "$here/../build/Tickoala.app/Contents/Helpers/tickoala" \
    "/Applications/Tickoala.app/Contents/Helpers/tickoala" \
    "$here/../.build/release/tickoala" \
    "$here/../.build/debug/tickoala" \
    "$(command -v tickoala 2>/dev/null || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        binary="$candidate"
        break
    fi
done

if [ -z "${binary:-}" ]; then
    echo "tickoala not found — run scripts/build-app.sh first" >&2
    exit 1
fi

log="${HOME}/Library/Logs/Tickoala-adapter.log"
mkdir -p "$(dirname "$log")"
# Never fail toward ControlPlane: everything goes to the log file.
"$binary" "$kind" --context "$context" >>"$log" 2>&1 || echo "$(date '+%F %T') adapter failed: $kind $context" >>"$log"
exit 0

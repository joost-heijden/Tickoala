#!/bin/bash
# Updates a git clone of Tickoala to the newest version and restarts the app.
# Everyone builds their own: no ready-made bundle is downloaded, because it gets
# a quarantine flag and is rejected by Gatekeeper without a Developer ID.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

target="${TICKOALA_APP_DIR:-/Applications}"

# Without a git clone there is nothing to update: a zip has no history.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "This is not a git clone of Tickoala, so updating is not possible." >&2
    echo "If you downloaded the app as a zip, unpack the latest zip again," >&2
    echo "or follow the installation in the README: git clone https://github.com/joost-heijden/Tickoala.git" >&2
    exit 1
fi

# Never silently build over someone else's work.
if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree is not clean; there are still uncommitted changes." >&2
    echo "Save or commit them first (git status), then try again." >&2
    exit 1
fi

# Forward only, never rebase or merge: if it can't, the user has to see why.
before="$(git describe --tags --always)"
git pull --ff-only
after="$(git describe --tags --always)"

if [ "$before" = "$after" ]; then
    echo "Already at the newest version ($after); nothing changed and nothing was rebuilt."
    exit 0
fi

echo "Updated: $before -> $after"

"$root/scripts/build-app.sh" release

# The running app holds the old bundle open. Ask it to stop cleanly first; only
# if that fails do we step in with pkill. Only if it is really running, because
# osascript would otherwise start it just to be able to quit it.
if pgrep -x Tickoala >/dev/null 2>&1; then
    osascript -e 'tell application "Tickoala" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        pgrep -x Tickoala >/dev/null 2>&1 || break
        sleep 0.3
    done
fi
pkill -x Tickoala >/dev/null 2>&1 || true

# cp -R copies the symlink at the top of the bundle as a symlink; without that
# symlink Bundle.module cannot find the icons outside this Mac.
mkdir -p "$target"
rm -rf "$target/Tickoala.app"
cp -R "$root/build/Tickoala.app" "$target"/

open "$target/Tickoala.app"
echo "Tickoala $after is running from $target."

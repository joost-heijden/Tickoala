#!/bin/bash
# Werkt een git-clone van Tickoala bij naar de nieuwste versie en herstart de app.
# Iedereen bouwt zelf: er wordt geen kant-en-klare bundel gedownload, want die
# krijgt een quarantainevlag en wordt door Gatekeeper geweigerd zonder Developer ID.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

doel="${TICKOALA_APP_DIR:-/Applications}"

# Zonder git-clone valt er niets bij te werken: een zip heeft geen geschiedenis.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Dit is geen git-clone van Tickoala, dus bijwerken kan niet." >&2
    echo "Heb je de app als zip gedownload, pak dan de nieuwste zip opnieuw uit," >&2
    echo "of volg de installatie in de README: git clone https://github.com/joost-heijden/Tickoala.git" >&2
    exit 1
fi

# Nooit stilletjes over andermans werk heen bouwen.
if [ -n "$(git status --porcelain)" ]; then
    echo "De werkmap is niet schoon; er staan nog niet-gecommitte wijzigingen." >&2
    echo "Bewaar of commit die eerst (git status), en probeer het daarna opnieuw." >&2
    exit 1
fi

# Alleen vooruit, nooit rebasen of mergen: kan het niet, dan moet de gebruiker
# zelf zien waarom.
voor="$(git describe --tags --always)"
git pull --ff-only
na="$(git describe --tags --always)"

if [ "$voor" = "$na" ]; then
    echo "Al bij de nieuwste versie ($na); er is niets veranderd en niets herbouwd."
    exit 0
fi

echo "Bijgewerkt: $voor -> $na"

"$root/scripts/build-app.sh" release

# De draaiende app houdt de oude bundel open. Vraag hem eerst netjes te stoppen;
# pas als dat niet lukt grijpen we met pkill in. Alleen als hij echt draait, want
# osascript zou hem anders juist starten om hem te kunnen afsluiten.
if pgrep -x Tickoala >/dev/null 2>&1; then
    osascript -e 'tell application "Tickoala" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        pgrep -x Tickoala >/dev/null 2>&1 || break
        sleep 0.3
    done
fi
pkill -x Tickoala >/dev/null 2>&1 || true

# cp -R neemt de symlink bovenin de bundel als symlink over; zonder die symlink
# vindt Bundle.module de iconen niet buiten deze Mac.
mkdir -p "$doel"
rm -rf "$doel/Tickoala.app"
cp -R "$root/build/Tickoala.app" "$doel"/

open "$doel/Tickoala.app"
echo "Tickoala $na draait vanuit $doel."

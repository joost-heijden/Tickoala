#!/bin/bash
# Bouwt Tickoala.app (menubalk-app zonder Dock-icoon) plus het adaptercommando.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

configuration="${1:-release}"
swift build -c "$configuration"
binaries="$(swift build -c "$configuration" --show-bin-path)"

app="$root/build/Tickoala.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"

cp "$binaries/TickoalaApp" "$app/Contents/MacOS/Tickoala"
# Het adaptercommando reist mee, zodat ControlPlane één vast pad kan gebruiken.
# Let op: het bestandssysteem is hoofdletterongevoelig, dus 'tickoala' kan niet
# naast 'Tickoala' in Contents/MacOS staan.
cp "$binaries/tickoala" "$app/Contents/Helpers/tickoala"

# De menubalk-iconen zitten in de resource-bundle die SwiftPM maakt. Zonder deze
# kopie valt `Bundle.module` terug op het pad in .build, en buiten deze Mac
# bestaat dat pad niet: dan stopt de app meteen bij het eerste icoon.
# De bundel hoort in Contents/Resources, zodat de ondertekening klopt, maar
# `Bundle.module` zoekt hem naast de app zelf; vandaar de verwijzing erheen.
bundle="Tickoala_TickoalaApp.bundle"
cp -R "$binaries/$bundle" "$app/Contents/Resources/$bundle"
ln -s "Contents/Resources/$bundle" "$app/$bundle"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tickoala</string>
    <key>CFBundleDisplayName</key>
    <string>Tickoala</string>
    <key>CFBundleIdentifier</key>
    <string>local.tickoala.app</string>
    <key>CFBundleExecutable</key>
    <string>Tickoala</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__VERSIE__</string>
    <key>CFBundleVersion</key>
    <string>__BUILD__</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menubalk-app: geen Dock-icoon, geen menubalk bovenin. -->
    <key>LSUIElement</key>
    <true/>
    <!-- macOS geeft de naam van het wifinetwerk alleen vrij aan programma's met
         toestemming voor Locatievoorzieningen. Zonder deze twee sleutels toont
         het systeem de vraag niet eens. Er wordt geen locatie opgeslagen. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Tickoala gebruikt dit alleen om de naam van het wifinetwerk te zien, zodat de urenregistratie vanzelf start en stopt bij een klant. Er wordt geen locatie opgeslagen of verstuurd.</string>
    <key>NSLocationUsageDescription</key>
    <string>Tickoala gebruikt dit alleen om de naam van het wifinetwerk te zien, zodat de urenregistratie vanzelf start en stopt bij een klant. Er wordt geen locatie opgeslagen of verstuurd.</string>
</dict>
</plist>
PLIST

# De versie komt uit git. Zonder tags (een losse zip, een verse clone) mag de
# build niet breken: dan wordt het 0.0.0 en houdt de updatecontrole in de app zich
# stil. De heredoc hierboven staat tussen aanhalingstekens, zodat er niets wordt
# uitgevouwen; daarom vullen we de plaatsaanduidingen pas hier in.
versie="$(git describe --tags --abbrev=0 2>/dev/null || true)"
versie="${versie#v}"
versie="${versie:-0.0.0}"
build="$(git rev-list --count HEAD 2>/dev/null || true)"
build="${build:-0}"
sed -i '' "s/__VERSIE__/$versie/; s/__BUILD__/$build/" "$app/Contents/Info.plist"

# Ad-hoc ondertekening: genoeg voor lokaal gebruik op de eigen Mac.
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || true

echo "gebouwd: $app"
echo "adapter: $app/Contents/Helpers/tickoala"

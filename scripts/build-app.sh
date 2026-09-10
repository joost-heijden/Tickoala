#!/bin/bash
# Bouwt WifiHours.app (menubalk-app zonder Dock-icoon) plus het adaptercommando.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

configuration="${1:-release}"
swift build -c "$configuration"
binaries="$(swift build -c "$configuration" --show-bin-path)"

app="$root/build/WifiHours.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"

cp "$binaries/WifiHoursApp" "$app/Contents/MacOS/WifiHours"
# Het adaptercommando reist mee, zodat ControlPlane één vast pad kan gebruiken.
# Let op: het bestandssysteem is hoofdletterongevoelig, dus 'wifihours' kan niet
# naast 'WifiHours' in Contents/MacOS staan.
cp "$binaries/wifihours" "$app/Contents/Helpers/wifihours"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WifiHours</string>
    <key>CFBundleDisplayName</key>
    <string>WifiHours</string>
    <key>CFBundleIdentifier</key>
    <string>local.wifihours.app</string>
    <key>CFBundleExecutable</key>
    <string>WifiHours</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menubalk-app: geen Dock-icoon, geen menubalk bovenin. -->
    <key>LSUIElement</key>
    <true/>
    <!-- macOS geeft de naam van het wifinetwerk alleen vrij aan programma's met
         toestemming voor Locatievoorzieningen. Zonder deze twee sleutels toont
         het systeem de vraag niet eens. Er wordt geen locatie opgeslagen. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>WifiHours gebruikt dit alleen om de naam van het wifinetwerk te zien, zodat de urenregistratie vanzelf start en stopt bij een klant. Er wordt geen locatie opgeslagen of verstuurd.</string>
    <key>NSLocationUsageDescription</key>
    <string>WifiHours gebruikt dit alleen om de naam van het wifinetwerk te zien, zodat de urenregistratie vanzelf start en stopt bij een klant. Er wordt geen locatie opgeslagen of verstuurd.</string>
</dict>
</plist>
PLIST

# Ad-hoc ondertekening: genoeg voor lokaal gebruik op de eigen Mac.
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || true

echo "gebouwd: $app"
echo "adapter: $app/Contents/Helpers/wifihours"

#!/bin/bash
# Builds Tickoala.app (menu bar app without a Dock icon) plus the adapter command.
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
# The adapter command travels along, so ControlPlane can use one fixed path.
# Note: the file system is case-insensitive, so 'tickoala' cannot sit next to
# 'Tickoala' in Contents/MacOS.
cp "$binaries/tickoala" "$app/Contents/Helpers/tickoala"

# The menu bar icons live in the resource bundle SwiftPM builds. Without this
# copy, `Bundle.module` falls back to the path in .build, and that path doesn't
# exist outside this Mac: the app would then stop at the first icon.
# The bundle belongs in Contents/Resources so the signing is correct, but
# `Bundle.module` looks for it next to the app itself; hence the symlink to it.
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
    <string>__VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__BUILD__</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menu bar app: no Dock icon, no menu bar at the top. -->
    <key>LSUIElement</key>
    <true/>
    <!-- macOS only reveals the name of the Wi-Fi network to programs with
         Location Services permission. Without these two keys the system won't
         even show the prompt. No location is ever stored. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Tickoala uses this only to see the name of the Wi-Fi network, so time tracking starts and stops automatically at a client. No location is stored or transmitted.</string>
    <key>NSLocationUsageDescription</key>
    <string>Tickoala uses this only to see the name of the Wi-Fi network, so time tracking starts and stops automatically at a client. No location is stored or transmitted.</string>
</dict>
</plist>
PLIST

# The version comes from git. Without tags (a loose zip, a fresh clone) the build
# must not break: it becomes 0.0.0 and the update check in the app keeps quiet.
# The heredoc above is quoted, so nothing is expanded; that is why we fill in the
# placeholders only here.
version="$(git describe --tags --abbrev=0 2>/dev/null || true)"
version="${version#v}"
version="${version:-0.0.0}"
build="$(git rev-list --count HEAD 2>/dev/null || true)"
build="${build:-0}"
sed -i '' "s/__VERSION__/$version/; s/__BUILD__/$build/" "$app/Contents/Info.plist"

# Ad-hoc signing: enough for local use on your own Mac.
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || true

echo "built: $app"
echo "adapter: $app/Contents/Helpers/tickoala"

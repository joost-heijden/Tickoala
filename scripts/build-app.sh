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

# The menu bar and welcome icons. They go flat into Contents/Resources, where
# `Bundle.main` finds them. The app must not carry the SwiftPM resource bundle at
# its root: that needs a symlink, and codesign then refuses to sign the app
# ("unsealed contents present in the bundle root"), which in turn makes macOS
# show a generic icon in Finder, notifications and System Settings.
bundle="Tickoala_TickoalaApp.bundle"
cp "$binaries/$bundle/"* "$app/Contents/Resources/"

# App icon: a square master PNG is turned into a real .icns, so Finder,
# notifications and the About panel show the logo instead of a placeholder. A
# checkout without the master still builds; that key is then simply absent.
icon_source="$root/design/AppIcon.png"
if [ -f "$icon_source" ]; then
    iconset="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset"
    for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
                "512 512x512" "1024 512x512@2x"; do
        read -r size name <<< "$pair"
        sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_$name.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$iconset")"
fi

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
         even show the prompt. The same permission covers optional location
         detection; coordinates stay on this Mac. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Tickoala uses this to see the name of the Wi-Fi network, so time tracking starts and stops automatically at a client. If you switch detection to Location, the same permission is used to compare your coordinates with the places you stored; nothing is transmitted.</string>
    <key>NSLocationUsageDescription</key>
    <string>Tickoala uses this to see the name of the Wi-Fi network, so time tracking starts and stops automatically at a client. If you switch detection to Location, the same permission is used to compare your coordinates with the places you stored; nothing is transmitted.</string>
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

# Only point at the icon when it was actually generated.
if [ -f "$app/Contents/Resources/AppIcon.icns" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
fi

# Ad-hoc signing: enough for local use on your own Mac.
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || true

echo "built: $app"
echo "adapter: $app/Contents/Helpers/tickoala"

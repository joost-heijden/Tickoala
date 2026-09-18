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

# App icon. Modern macOS reads it from a compiled asset catalog, so a square
# master PNG is turned into Assets.car (and an .icns for older paths). Without
# the master, or without actool on the machine, the build still succeeds; the
# icon keys are then simply absent.
icon_source="$root/design/AppIcon.png"
if [ -f "$icon_source" ]; then
    # actool only ships with a full Xcode. `xcode-select -p` can point at the
    # Command Line Tools (for example when DEVELOPER_DIR is set for the build), so
    # the Xcode app itself is a candidate too.
    actool=""
    for candidate in "$(xcode-select -p 2>/dev/null)/usr/bin/actool" \
                     "/Applications/Xcode.app/Contents/Developer/usr/bin/actool"; do
        if [ -x "$candidate" ]; then actool="$candidate"; break; fi
    done
    icons=("16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
           "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
           "512 512x512" "1024 512x512@2x")
    if [ -n "$actool" ]; then
        assets="$(mktemp -d)"
        folder="$assets/Assets.xcassets/AppIcon.appiconset"
        mkdir -p "$folder"
        printf '{"info":{"author":"xcode","version":1}}' > "$assets/Assets.xcassets/Contents.json"
        cat > "$folder/Contents.json" <<'JSON'
{
  "images": [
    {"idiom":"mac","size":"16x16","scale":"1x","filename":"icon_16x16.png"},
    {"idiom":"mac","size":"16x16","scale":"2x","filename":"icon_16x16@2x.png"},
    {"idiom":"mac","size":"32x32","scale":"1x","filename":"icon_32x32.png"},
    {"idiom":"mac","size":"32x32","scale":"2x","filename":"icon_32x32@2x.png"},
    {"idiom":"mac","size":"128x128","scale":"1x","filename":"icon_128x128.png"},
    {"idiom":"mac","size":"128x128","scale":"2x","filename":"icon_128x128@2x.png"},
    {"idiom":"mac","size":"256x256","scale":"1x","filename":"icon_256x256.png"},
    {"idiom":"mac","size":"256x256","scale":"2x","filename":"icon_256x256@2x.png"},
    {"idiom":"mac","size":"512x512","scale":"1x","filename":"icon_512x512.png"},
    {"idiom":"mac","size":"512x512","scale":"2x","filename":"icon_512x512@2x.png"}
  ],
  "info": {"author":"xcode","version":1}
}
JSON
        for pair in "${icons[@]}"; do
            read -r size name <<< "$pair"
            sips -z "$size" "$size" "$icon_source" --out "$folder/icon_$name.png" >/dev/null
        done
        "$actool" "$assets/Assets.xcassets" --compile "$app/Contents/Resources" \
            --platform macosx --minimum-deployment-target 13.0 \
            --app-icon AppIcon --output-partial-info-plist "$assets/info.plist" >/dev/null 2>&1 || true
        rm -rf "$assets"
    fi
    # Fallback for machines without Xcode: a plain .icns, enough for Finder.
    if [ ! -f "$app/Contents/Resources/AppIcon.icns" ]; then
        iconset="$(mktemp -d)/AppIcon.iconset"
        mkdir -p "$iconset"
        for pair in "${icons[@]}"; do
            read -r size name <<< "$pair"
            sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_$name.png" >/dev/null
        done
        iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
        rm -rf "$(dirname "$iconset")"
    fi
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
    <string>nl.tickoala.app</string>
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

# Only point at the icon when it was actually generated. Modern system UI reads
# the asset catalog through CFBundleIconName; the older keys cover the rest.
if [ -f "$app/Contents/Resources/AppIcon.icns" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
fi
if [ -f "$app/Contents/Resources/Assets.car" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$app/Contents/Info.plist"
fi

# Ad-hoc signing: enough for local use on your own Mac.
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || true

echo "built: $app"
echo "adapter: $app/Contents/Helpers/tickoala"

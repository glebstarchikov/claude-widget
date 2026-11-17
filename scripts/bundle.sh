#!/bin/bash
# Builds "Claude Widget.app". With --install, copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep build/ out of Spotlight/Launchpad so the intermediate .app never shows up
# as a duplicate icon alongside the installed one.
mkdir -p build && touch build/.metadata_never_index

swift build -c release

APP="build/Claude Widget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ClaudeWidget "$APP/Contents/MacOS/Claude Widget"
cp .build/release/claude-widget-hook "$APP/Contents/MacOS/"

# Render the critter app icon into an iconset, then compile to .icns.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
.build/release/ClaudeWidget --render-icon "$ICONSET"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  cp "$ICONSET/icon_${d}x${d}.png" "$ICONSET/icon_${s}x${s}@2x.png"
done
rm "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Widget</string>
    <key>CFBundleDisplayName</key><string>Claude Widget</string>
    <key>CFBundleExecutable</key><string>Claude Widget</string>
    <key>CFBundleIdentifier</key><string>com.glebstarchikov.claude-widget</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built: $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -f "Claude Widget.app/Contents/MacOS" 2>/dev/null || true
  sleep 0.4
  rm -rf "/Applications/Claude Widget.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Widget.app"
  echo "installed to /Applications and launched"
fi

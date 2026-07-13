#!/bin/bash
# Builds a pretty drag-to-install disk image: a framed Finder window with a
# background arrow pointing from the app to an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh              # produce build/Claude Widget.app (release, signed)

APP="build/Claude Widget.app"
VOL="Claude Widget"
DMG="build/Claude Widget.dmg"
RW="build/rw.dmg"
STAGE="build/dmg-stage"

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
.build/release/ClaudeWidget --render-dmg-bg "$STAGE/.background/bg.png"

# Writable image we can arrange with Finder, then compress.
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT=$(hdiutil attach "$RW" -nobrowse -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)

# Lay out the window. Needs Finder automation permission the first time.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 556}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 120
    set background picture of opts to file ".background:bg.png"
    set position of item "Claude Widget.app" of container window to {150, 205}
    set position of item "Applications" of container window to {450, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "warning: Finder layout step failed (grant automation permission?); DMG will be plain."
fi

sync
hdiutil detach "$MOUNT" >/dev/null || hdiutil detach "$MOUNT" -force >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"
echo "built: $DMG ($(du -h "$DMG" | cut -f1))"

#!/bin/bash
# Builds a drag-to-install disk image: build/Claude Widget.dmg containing the
# app next to an Applications shortcut, so a user just drags it across.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh              # produce build/Claude Widget.app (release, signed)

APP="build/Claude Widget.app"
DMG="build/Claude Widget.dmg"
STAGE="build/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # the drag target

hdiutil create -volname "Claude Widget" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "built: $DMG ($(du -h "$DMG" | cut -f1))"

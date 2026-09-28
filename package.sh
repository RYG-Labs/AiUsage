#!/bin/bash
# Builds the app and wraps it in a drag-to-install DMG.
set -e
cd "$(dirname "$0")"
./build.sh
OUT="${1:-AiUsage.dmg}"
STAGE=$(mktemp -d)
cp -R AiUsage.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "AiUsage" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Packaged $OUT"

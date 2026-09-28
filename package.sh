#!/bin/bash
# Builds the app and wraps it in a drag-to-install DMG.
set -e
cd "$(dirname "$0")"
./build.sh
OUT="${1:-ClaudeUsage.dmg}"
STAGE=$(mktemp -d)
cp -R ClaudeUsage.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "ClaudeUsage" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Packaged $OUT"

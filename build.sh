#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="AiUsage.app"
VERSION=$(cat VERSION)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
# Universal binary: Apple Silicon + Intel
TMP=$(mktemp -d)
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 AiUsage.swift -o "$TMP/arm64"
swiftc -O -parse-as-library -target x86_64-apple-macosx14.0 AiUsage.swift -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/AiUsage"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.aiusage</string>
  <key>CFBundleName</key><string>AiUsage</string>
  <key>CFBundleExecutable</key><string>AiUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

#!/bin/bash
# Builds "App Monitor.app" next to this script, as a universal app (Apple Silicon + Intel).
# Needs only the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="App Monitor.app"
SOURCES=(main.swift Views.swift Demo.swift)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

[ -f Icon/AppIcon.icns ] || swift Icon/MakeIcon.swift Icon
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
  echo "Compiling for $ARCH…"
  swiftc -O -parse-as-library -swift-version 5 -target "$ARCH-apple-macos14.0" \
    "${SOURCES[@]}" -o "$TMP/AppMonitor-$ARCH"
done
lipo -create "$TMP/AppMonitor-arm64" "$TMP/AppMonitor-x86_64" -output "$APP/Contents/MacOS/AppMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>App Monitor</string>
  <key>CFBundleDisplayName</key><string>App Monitor</string>
  <key>CFBundleIdentifier</key><string>io.github.laimis91.appmonitor</string>
  <key>CFBundleExecutable</key><string>AppMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force -s - "$APP" >/dev/null   # ad-hoc signature (not notarized)
echo "Built: $(pwd)/$APP"

#!/bin/bash
# Builds "App Monitor.app" next to this script, as a universal app (Apple Silicon + Intel).
# Needs only the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

# APPMON_VERSION sets the app version (the release workflow passes the tag, without the "v").
VERSION="${APPMON_VERSION:-1.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APPMON_VERSION must look like 1.2.3" >&2; exit 1; }
APP="${APPMON_OUT:-App Monitor.app}"   # APPMON_OUT: build somewhere else (fixture tests)
SOURCES=(main.swift Views.swift Demo.swift CleanerModel.swift CleanerViews.swift
         Cleaner/Model.swift Cleaner/PathGuard.swift Cleaner/Keys.swift Cleaner/ScanEngine.swift
         Cleaner/InstalledApps.swift Cleaner/Rules.swift Cleaner/Actions.swift Cleaner/Permissions.swift
         Cleaner/SystemProbes.swift Cleaner/Headless.swift)
# APPMON_DEBUG=1 compiles in the developer switches (fixture roots, headless scan). Release builds never set it.
FLAGS=(-O)
[ "${APPMON_DEBUG:-}" = "1" ] && FLAGS+=(-D APPMON_DEBUG)
# APPMON_ARCHS limits the architectures (for quick local test builds).
ARCHS=(${APPMON_ARCHS:-arm64 x86_64})
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT   # keep the failure code (bash 3.2 loses it otherwise)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

[ -f Icon/AppIcon.icns ] || swift Icon/MakeIcon.swift Icon
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for ARCH in "${ARCHS[@]}"; do
  echo "Compiling for ${ARCH}…"
  swiftc "${FLAGS[@]}" -parse-as-library -swift-version 5 -target "$ARCH-apple-macos14.0" \
    "${SOURCES[@]}" -o "$TMP/AppMonitor-$ARCH"
done
lipo -create "${ARCHS[@]/#/$TMP/AppMonitor-}" -output "$APP/Contents/MacOS/AppMonitor"

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
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__VERSION__</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>App Monitor asks Finder to move the items you clean to the Trash, so Finder's Put Back can return them to where they were.</string>
</dict></plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

codesign --force -s - "$APP" >/dev/null   # ad-hoc signature (not notarized)
echo "Built: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

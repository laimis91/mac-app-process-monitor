#!/bin/bash
# Builds "App Monitor.app" next to this script, as a universal app (Apple Silicon + Intel).
# Needs only the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

# APPMON_VERSION sets the app version (the release workflow passes the tag, without the "v").
VERSION="${APPMON_VERSION:-1.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APPMON_VERSION must look like 1.2.3" >&2; exit 1; }
# APPMON_RELEASE=1 (set by the release workflow) refuses to build without a signing identity.
if [ "${APPMON_RELEASE:-}" = "1" ] && [ -z "${APPMON_SIGN_IDENTITY:-}" ]; then
  echo "APPMON_RELEASE=1 needs APPMON_SIGN_IDENTITY: release builds must not be ad-hoc signed." >&2
  exit 1
fi
APP="${APPMON_OUT:-App Monitor.app}"   # APPMON_OUT: build somewhere else (fixture tests)
SOURCES=(main.swift Views.swift Demo.swift CleanerModel.swift CleanerViews.swift
         Cleaner/Model.swift Cleaner/PathGuard.swift Cleaner/Keys.swift Cleaner/ScanEngine.swift
         Cleaner/InstalledApps.swift Cleaner/Rules.swift Cleaner/Actions.swift Cleaner/Permissions.swift
         Cleaner/SystemProbes.swift Cleaner/Headless.swift Cleaner/SpaceMap.swift
         Cleaner/LeftoverMatcher.swift Cleaner/Leftovers.swift
         SpaceMapModel.swift SpaceMapViews.swift)
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

# Signing (spec section 11). APPMON_SIGN_IDENTITY names a code-signing identity in your keychain,
# such as the self-signed "App Monitor Signing" (scripts/make-signing-cert.sh). Without it the
# build is ad-hoc signed, which is fine for trying things out, but macOS then treats every build
# as a new app and forgets Full Disk Access. APPMON_SIGN_KEYCHAIN limits the search to one
# keychain (the release workflow's temporary one). APPMON_RELEASE=1 refuses to sign ad-hoc.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")"
if [ -n "${APPMON_SIGN_IDENTITY:-}" ]; then
  SIGN=(--force --sign "$APPMON_SIGN_IDENTITY")
  [ -n "${APPMON_SIGN_KEYCHAIN:-}" ] && SIGN+=(--keychain "$APPMON_SIGN_KEYCHAIN")
  echo "Signing with \"$APPMON_SIGN_IDENTITY\"…"
  codesign "${SIGN[@]}" "$APP"
  codesign --verify --strict "$APP"
  # A stable signature's designated requirement names the bundle ID and the certificate.
  # A cdhash requirement would change with every build and lose Full Disk Access.
  REQ="$(codesign -d -r- "$APP" 2>&1 | grep '^designated => ' || true)"
  if [[ "$REQ" != *"identifier \"$BUNDLE_ID\""* || "$REQ" != *certificate* || "$REQ" == *cdhash* ]]; then
    echo "Signed build has no stable designated requirement: ${REQ:-none}" >&2
    exit 1
  fi
  echo "${REQ}"
else
  codesign --force -s - "$APP" >/dev/null
  echo "Ad-hoc signed (set APPMON_SIGN_IDENTITY to keep Full Disk Access across builds)."
fi
echo "Built: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

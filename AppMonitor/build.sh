#!/bin/bash
# Builds "App Monitor.app" next to this script, as a universal app (Apple Silicon + Intel).
# Needs only the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

# APPMON_VERSION sets the app version (the release workflow passes the tag, without the "v").
VERSION="${APPMON_VERSION:-1.2.1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APPMON_VERSION must look like 1.2.3" >&2; exit 1; }
# APPMON_RELEASE=1 (set by the release workflow) refuses to build without a signing identity.
if [ "${APPMON_RELEASE:-}" = "1" ] && [ -z "${APPMON_SIGN_IDENTITY:-}" ]; then
  echo "APPMON_RELEASE=1 needs APPMON_SIGN_IDENTITY: release builds must not be ad-hoc signed." >&2
  exit 1
fi
# A debug build has the developer switches (headless listing, window capture). Signed with the
# release certificate it would get the release app's Full Disk Access, so debug builds are ad-hoc only.
if [ "${APPMON_DEBUG:-}" = "1" ] && { [ -n "${APPMON_SIGN_IDENTITY:-}" ] || [ "${APPMON_RELEASE:-}" = "1" ]; }; then
  echo "APPMON_DEBUG=1 can't be combined with APPMON_SIGN_IDENTITY or APPMON_RELEASE: debug builds are ad-hoc signed only." >&2
  exit 1
fi
APP="${APPMON_OUT:-App Monitor.app}"   # APPMON_OUT: build somewhere else (fixture tests)
# The build starts with rm -rf "$APP": refuse anything that isn't an app bundle path.
[[ "$APP" == *?.app ]] || { echo "APPMON_OUT must end in .app, got: $APP" >&2; exit 1; }
SOURCES=(main.swift Views.swift Demo.swift CleanerModel.swift CleanerViews.swift
         DiskTabView.swift ResultRows.swift UninstallerViews.swift DiskPanels.swift CleanerSheets.swift SettingsView.swift
         Cleaner/Model.swift Cleaner/PathGuard.swift Cleaner/Keys.swift Cleaner/ScanEngine.swift
         Cleaner/InstalledApps.swift Cleaner/Rules.swift Cleaner/Actions.swift Cleaner/Probes.swift
         Cleaner/Permissions.swift Cleaner/SystemProbes.swift Cleaner/Headless.swift Cleaner/SpaceMap.swift
         Cleaner/SpaceGuard.swift
         Cleaner/LeftoverMatcher.swift Cleaner/Leftovers.swift Cleaner/Uninstaller.swift
         SpaceMapModel.swift SpaceMapViews.swift)
SOURCES+=(ProcessTree.swift)   # process ownership, also compiled by scripts/grouping-test.sh
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
# keychain (the release workflow's temporary one, or a dedicated one: README, Signing).
# APPMON_RELEASE=1 refuses to sign ad-hoc.
# Every build, signed or ad-hoc, uses the hardened runtime, so another process can't load code
# into the app (for example with DYLD_INSERT_LIBRARIES) and use its Full Disk Access. Its only
# entitlement lets it send Apple events to Finder (Trash with Put Back).
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")"
RUNTIME=(--options runtime --entitlements AppMonitor.entitlements)
if [ -n "${APPMON_SIGN_IDENTITY:-}" ]; then
  SIGN=(--force "${RUNTIME[@]}" --sign "$APPMON_SIGN_IDENTITY")
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
  codesign --force "${RUNTIME[@]}" -s - "$APP" >/dev/null
  echo "Ad-hoc signed (set APPMON_SIGN_IDENTITY to keep Full Disk Access across builds)."
fi
# The signature must have the hardened runtime flag and the Apple events entitlement, and no
# entitlement that would let other code into the process again.
CD="$(codesign -dv "$APP" 2>&1 | grep '^CodeDirectory ' || true)"
if [[ "$CD" != *"flags="*runtime* ]]; then
  echo "Build is not signed with the hardened runtime: ${CD:-no CodeDirectory}" >&2
  exit 1
fi
codesign -d --entitlements - --xml "$APP" > "$TMP/entitlements.plist" 2>/dev/null || true
ENTS="$(cat "$TMP/entitlements.plist")"
if [ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.automation.apple-events" "$TMP/entitlements.plist" 2>/dev/null)" != "true" ]; then
  echo "Build lacks the com.apple.security.automation.apple-events entitlement." >&2
  exit 1
fi
if [[ "$ENTS" == *disable-library-validation* || "$ENTS" == *allow-dyld-environment-variables* ]]; then
  echo "Build has an entitlement that weakens the hardened runtime." >&2
  exit 1
fi
echo "Hardened runtime on; entitlement: com.apple.security.automation.apple-events."
echo "Built: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

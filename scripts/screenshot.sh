#!/bin/bash
# Regenerates docs/screenshot.png from demo mode (made-up processes, nothing from your Mac).
# Demo mode and the capture switch exist only in debug builds, so this builds one (APPMON_DEBUG=1)
# into a temporary folder and leaves AppMonitor/App Monitor.app alone. The app writes the PNG
# into that folder (it never overwrites a file), then it is moved to docs/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT
APP="$TMP/App Monitor.app"
env -u APPMON_SIGN_IDENTITY -u APPMON_SIGN_KEYCHAIN -u APPMON_RELEASE APPMON_OUT="$APP" APPMON_DEBUG=1 APPMON_ARCHS="$(uname -m)" "$ROOT/AppMonitor/build.sh"
SHOT="$TMP/shot.png"
OUT="$ROOT/docs/screenshot.png"
open -n "$APP" --env APPMON_DEMO=1 --env APPMON_CAPTURE="$SHOT"
for _ in $(seq 1 20); do [ -s "$SHOT" ] && break; sleep 0.5; done
sleep 0.5   # the app exits right after writing
[ -s "$SHOT" ] || { echo "Screenshot failed" >&2; exit 1; }
mv -f "$SHOT" "$OUT"
echo "Saved $OUT"

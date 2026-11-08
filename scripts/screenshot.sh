#!/bin/bash
# Regenerates docs/screenshot*.png (Monitor and Disk tabs, light and dark) from demo mode (made-up processes, nothing from your Mac).
# Demo mode and the capture switch exist only in debug builds, so this builds one (APPMON_DEBUG=1)
# into a temporary folder and leaves AppMonitor/App Monitor.app alone. The app writes each PNG
# into that folder (it never overwrites a file), then it is moved to docs/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT
APP="$TMP/App Monitor.app"
env -u APPMON_SIGN_IDENTITY -u APPMON_SIGN_KEYCHAIN -u APPMON_RELEASE APPMON_OUT="$APP" APPMON_DEBUG=1 APPMON_ARCHS="$(uname -m)" "$ROOT/AppMonitor/build.sh"
# capture <tab> <appearance> <output>: opens the demo app on that tab in light or dark mode and saves its window.
capture() {
    local shot="$TMP/shot-$1-$2.png"
    open -n "$APP" --env APPMON_DEMO=1 --env APPMON_TAB="$1" --env APPMON_APPEARANCE="$2" --env APPMON_CAPTURE="$shot"
    for _ in $(seq 1 20); do [ -s "$shot" ] && break; sleep 0.5; done
    sleep 0.5   # the app exits right after writing
    [ -s "$shot" ] || { echo "Screenshot of the $1 tab failed" >&2; exit 1; }
    mv -f "$shot" "$3"
    echo "Saved $3"
}
capture monitor light "$ROOT/docs/screenshot.png"
capture disk light "$ROOT/docs/screenshot-disk.png"
capture monitor dark "$ROOT/docs/screenshot-dark.png"
capture disk dark "$ROOT/docs/screenshot-disk-dark.png"

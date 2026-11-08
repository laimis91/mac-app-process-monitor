#!/bin/bash
# Regenerates docs/screenshot.png from demo mode (made-up processes, nothing from your Mac).
# Builds into a temporary folder, so it leaves AppMonitor/App Monitor.app alone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT
APP="$TMP/App Monitor.app"
APPMON_OUT="$APP" "$ROOT/AppMonitor/build.sh"
OUT="$ROOT/docs/screenshot.png"
rm -f "$OUT"
open -n "$APP" --env APPMON_DEMO=1 --env APPMON_CAPTURE="$OUT"
for _ in $(seq 1 20); do [ -f "$OUT" ] && break; sleep 0.5; done
[ -f "$OUT" ] && echo "Saved $OUT" || { echo "Screenshot failed" >&2; exit 1; }

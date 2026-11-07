#!/bin/bash
# Regenerates docs/screenshot.png from demo mode (made-up processes, nothing from your Mac).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/AppMonitor/build.sh"
OUT="$ROOT/docs/screenshot.png"
rm -f "$OUT"
open -n "$ROOT/AppMonitor/App Monitor.app" --env APPMON_DEMO=1 --env APPMON_CAPTURE="$OUT"
for _ in $(seq 1 20); do [ -f "$OUT" ] && break; sleep 0.5; done
[ -f "$OUT" ] && echo "Saved $OUT" || { echo "Screenshot failed" >&2; exit 1; }

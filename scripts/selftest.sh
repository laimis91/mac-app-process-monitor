#!/bin/bash
# Compiles the disk cleaner's AppKit-free logic with a test main and runs it (spec 13).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/AppMonitor/Cleaner"
OUT="$(mktemp -d)"
trap 'rc=$?; rm -rf "$OUT"; exit $rc' EXIT
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$C/Model.swift" "$C/PathGuard.swift" "$C/Keys.swift" "$C/ScanEngine.swift" "$C/InstalledApps.swift" \
  "$C/Rules.swift" "$C/Actions.swift" "$C/Permissions.swift" "$C/SpaceMap.swift" \
  "$ROOT/scripts/selftest/SelfTest.swift" -o "$OUT/selftest"
"$OUT/selftest"

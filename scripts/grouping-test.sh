#!/bin/bash
# Compiles the process monitor's AppKit-free ownership logic with a test main and runs it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rc=$?; rm -rf "$OUT"; exit $rc' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$ROOT/AppMonitor/ProcessTree.swift" "$ROOT/scripts/grouping/main.swift" -o "$OUT/grouping-test"
"$OUT/grouping-test"

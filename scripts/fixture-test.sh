#!/bin/bash
# End-to-end fixture test for the disk cleaner (spec 13). Builds a debug app into a temporary
# folder, scans a fake tree, compares with scripts/fixtures/expected-scan.json, then cleans it.
#
# The act step moves the fixture's fake files to your Trash (they are tiny and made up).
#   scripts/fixture-test.sh            # dry run and act
#   UPDATE_GOLDEN=1 scripts/fixture-test.sh   # rewrite the golden file after checking it by hand
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
FIX="$("$ROOT/scripts/make-fixtures.sh")"
HOLDER=""
cleanup() { [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null || true; chmod -R u+rwx "$FIX" 2>/dev/null; rm -rf "$WORK" "$FIX"; }
trap cleanup EXIT

APPMON_OUT="$WORK/Debug.app" APPMON_ARCHS="$(uname -m)" APPMON_DEBUG=1 "$ROOT/AppMonitor/build.sh" >/dev/null 2>&1
BIN="$WORK/Debug.app/Contents/MacOS/AppMonitor"
run() { APPMON_SCAN_ROOT="$FIX" "$@"; }
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 1. Scan matches the golden file (acceptance 7.2: 1, 2, 8)
run "$BIN" --scan-json > "$WORK/scan.json"
if [ "${UPDATE_GOLDEN:-}" = "1" ]; then cp "$WORK/scan.json" "$ROOT/scripts/fixtures/expected-scan.json"; fi
if diff -u "$ROOT/scripts/fixtures/expected-scan.json" "$WORK/scan.json" > "$WORK/scan.diff"; then ok "scan matches golden file"
else bad "scan differs from golden file"; cat "$WORK/scan.diff"; fi

# 2. Unsafe roots are refused
set +e; APPMON_SCAN_ROOT=/private/tmp "$BIN" --scan-json >/dev/null 2>&1; code=$?; set -e
[ "$code" = 2 ] && ok "unsafe scan root refused" || bad "unsafe scan root accepted (exit $code)"

# 3. Without Full Disk Access the Mail container is skipped and flagged (7.2: 6)
APPMON_FIXTURE_FDA=denied run "$BIN" --scan-json > "$WORK/nofda.json"
python3 - "$WORK/nofda.json" <<'PY' && ok "no FDA: container skipped, notice shown" || bad "no FDA handling"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))}
m = c["J-MAILDL"]
assert m.get("notice") == "Needs Full Disk Access", m
assert [i["path"] for i in m["items"]] == ["<root>/home/Library/Mail Downloads/OLD-UUID"], m
PY

SELECT="home/Library/Caches/com.fixture.gone,home/Library/Caches/com.fixture.running,home/Library/Caches/com.unity3d.fixture,tmp/old-item,tmp/held-item,J-NPM"
snapshot() { (cd "$FIX" && find . 2>/dev/null | sort) || true; }

# 4. Dry run (the fixture default) changes nothing and runs no tool
before="$(snapshot)"
APPMON_SELECT="$SELECT" run "$BIN" --clean-json > "$WORK/dry.json"
[ "$before" = "$(snapshot)" ] && [ ! -e "$FIX/tool-log.txt" ] && ok "dry run changed nothing" || bad "dry run changed the tree"
python3 - "$WORK/dry.json" <<'PY' && ok "dry run plans the right actions" || bad "dry run plan"
import json, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
assert o["home/Library/Caches/com.fixture.running"]["reason"] == "Running App is running", o
assert o["home/Library/Caches/com.unity3d.fixture"]["reason"] == "Unity is running"
assert o["tool://J-NPM"]["status"] == "planned"
assert o["tool://J-NPM"]["command"] == ["<root>/bin/npm cache clean --force"]
planned = {k for k, v in o.items() if v["status"] == "planned"}
for k in ["home/Library/Caches/com.fixture.installed", "home/Library/Caches/com.fixture.gone", "tmp/old-item",
          "home/Library/Logs/com.fixture.gone", "home/Library/Developer/Xcode/DerivedData/Proj-abc"]:
    assert k in planned, k
assert "home/Library/Caches/PlainName" not in o, "not selected, not touched"
# every item that wasn't expected to be skipped is planned (catches allow-root mistakes)
expected_skips = {"home/Library/Caches/com.fixture.running", "home/Library/Caches/com.unity3d.fixture"}
for k, v in o.items():
    if k not in expected_skips and not k.startswith("tool://"):
        assert v["status"] == "planned", (k, v)
PY

# 5. Act: items really go to the Trash, open items and running apps are skipped, the tool runs
exec 3<"$FIX/tmp/held-item/x"
sleep 300 <&3 & HOLDER=$!; disown "$HOLDER"
exec 3<&-
sleep 0.3
APPMON_FIXTURE_ACT=1 APPMON_SELECT="$SELECT" run "$BIN" --clean-json > "$WORK/act.json"
kill "$HOLDER" 2>/dev/null || true; HOLDER=""
python3 - "$WORK/act.json" "$WORK/scan.json" "$FIX" <<'PY' && ok "act: moved, skipped and ran as expected" || bad "act results"
import json, os, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
scan = {i["path"].replace("<root>/", ""): i["kb"] for c in json.load(open(sys.argv[2])) for i in c["items"]}
fix = sys.argv[3]
moved = [k for k, v in o.items() if v["status"] == "moved"]
assert moved, o
for k in moved:
    assert not os.path.lexists(os.path.join(fix, k)), "still there: " + k
    assert o[k]["kb"] == scan[k], (k, o[k]["kb"], scan[k])        # 7.2: 7, totals match the scan
assert o["tmp/held-item"]["status"] == "skipped" and o["tmp/held-item"]["reason"].startswith("In use by"), o["tmp/held-item"]
assert os.path.exists(os.path.join(fix, "tmp/held-item"))
assert o["home/Library/Caches/com.fixture.running"]["status"] == "skipped"
assert os.path.exists(os.path.join(fix, "home/Library/Caches/com.fixture.running"))
assert os.path.exists(os.path.join(fix, "home/Library/Caches/PlainName"))
npm = o["tool://J-NPM"]
assert npm["status"] == "ran" and npm["kb"] == 32, npm               # measured shrink
assert open(os.path.join(fix, "tool-log.txt")).read() == "npm cache clean --force\n"
PY

# 6. A re-scan no longer lists the moved items
run "$BIN" --scan-json > "$WORK/rescan.json"
python3 - "$WORK/act.json" "$WORK/rescan.json" <<'PY' && ok "re-scan no longer lists moved items" || bad "re-scan"
import json, sys
moved = {x["path"] for x in json.load(open(sys.argv[1])) if x["status"] == "moved"}
listed = {i["path"] for c in json.load(open(sys.argv[2])) for i in c["items"]}
assert not (moved & listed), moved & listed
PY

[ "$fail" = 0 ] && echo "fixture-test: all passed" || { echo "fixture-test: FAILED"; exit 1; }

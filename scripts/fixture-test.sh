#!/bin/bash
# End-to-end fixture test for the disk cleaner (spec 13). Builds a debug app into a temporary
# folder, scans a fake tree, compares with scripts/fixtures/expected-scan.json, then cleans it.
#
# The act steps move the fixture's fake files to your Trash (they are tiny and made up).
#   scripts/fixture-test.sh            # dry run and act
#   UPDATE_GOLDEN=1 scripts/fixture-test.sh   # rewrite the golden file after checking it by hand
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="" FIX="" UFIX="" HOLDER=""
cleanup() {
  rc=$?
  if [ -n "$HOLDER" ]; then kill "$HOLDER" 2>/dev/null || true; fi
  for d in "$WORK" "$FIX" "$UFIX"; do
    [ -n "$d" ] || continue
    chmod -R u+rwx "$d" 2>/dev/null || true
    rm -rf "$d" || true
  done
  exit $rc
}
trap cleanup EXIT
WORK="$(mktemp -d)"
FIX="$("$ROOT/scripts/make-fixtures.sh")"
UFIX="$("$ROOT/scripts/make-fixtures.sh" --uninstall)"

if ! APPMON_OUT="$WORK/Debug.app" APPMON_ARCHS="$(uname -m)" APPMON_DEBUG=1 "$ROOT/AppMonitor/build.sh" > "$WORK/build.log" 2>&1; then
  cat "$WORK/build.log" >&2
  echo "fixture-test: debug build failed" >&2
  exit 1
fi
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
python3 -I - "$WORK/nofda.json" <<'PY' && ok "no FDA: container skipped, notice shown" || bad "no FDA handling"
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
python3 -I - "$WORK/dry.json" <<'PY' && ok "dry run plans the right actions" || bad "dry run plan"
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
python3 -I - "$WORK/act.json" "$WORK/scan.json" "$FIX" <<'PY' && ok "act: moved, skipped and ran as expected" || bad "act results"
import json, os, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
scan = {i["path"].replace("<root>/", ""): i["kb"] for c in json.load(open(sys.argv[2])) for i in c["items"]}
fix = sys.argv[3]
moved = [k for k, v in o.items() if v["status"] == "moved"]
assert moved, o
for k in moved:
    assert not os.path.lexists(os.path.join(fix, k)), "still there: " + k
    assert o[k]["kb"] == scan[k], (k, o[k]["kb"], scan[k])        # 7.2: 7, totals match the scan
    assert o[k].get("reason") in (None, "Moved without Put Back"), o[k]   # found in the Trash by device and inode
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
python3 -I - "$WORK/act.json" "$WORK/rescan.json" <<'PY' && ok "re-scan no longer lists moved items" || bad "re-scan"
import json, sys
moved = {x["path"] for x in json.load(open(sys.argv[1])) if x["status"] == "moved"}
listed = {i["path"] for c in json.load(open(sys.argv[2])) for i in c["items"]}
assert not (moved & listed), moved & listed
PY

# 7. Space map (spec 8): sizes match du -kx, labels, Reveal-only items, one-item dry run and act
run "$BIN" --space-json > "$WORK/space.json"
python3 -I - "$WORK/space.json" "$FIX" <<'PY' && ok "space map: sizes match du -kx, labels and reasons" || bad "space map scan"
import json, subprocess, sys
fix = sys.argv[2]
n = {x["path"]: x for x in json.load(open(sys.argv[1]))}
for rel in ["home", "home/Projects", "home/Projects/site", "home/Library", "home/Downloads", "Applications"]:
    du = int(subprocess.run(["du", "-skx", fix + "/" + rel], capture_output=True, text=True).stdout.split()[0])
    assert n[rel]["kb"] == du, (rel, n[rel]["kb"], du)
assert n["Applications/Fixture App.app"]["owner"] == "Fixture App"
assert n["home/Library/Caches/com.fixture.running"]["owner"] == "Running App"      # named by bundle ID
for ok_item in ["home/Projects/site", "home/Downloads/old.iso", "home/Documents/secret"]:
    assert "reason" not in n[ok_item], (ok_item, n[ok_item])
for kept in ["home", "home/Library", "home/Library/Caches/com.fixture.running", "home/Projects/site/.git",
             "home/Projects/Tool.app", "home/Projects", "home/Pictures", "home/Pictures/Old.photoslibrary",
             "home/Dropbox", "home/.config", "home/Documents", "Applications/Fixture App.app"]:
    assert "reason" in n[kept], kept
assert n["home/Projects"]["reason"].startswith("Contains an app"), n["home/Projects"]
PY

SPACE="home/Projects/site,home/Downloads/old.iso,home/Projects/held,home/Projects/site/.git,home/Library/Caches/com.fixture.running"
before="$(snapshot)"
APPMON_SELECT="$SPACE" run "$BIN" --space-trash > "$WORK/space-dry.json"
[ "$before" = "$(snapshot)" ] && ok "space map dry run changed nothing" || bad "space map dry run changed the tree"
python3 -I - "$WORK/space-dry.json" <<'PY' && ok "space map dry run plans only allowed items" || bad "space map dry run plan"
import json, sys
o = {x["path"]: x for x in json.load(open(sys.argv[1]))}
for k in ["home/Projects/site", "home/Downloads/old.iso", "home/Projects/held"]:
    assert o[k]["status"] == "planned", (k, o[k])
for k in ["home/Projects/site/.git", "home/Library/Caches/com.fixture.running"]:
    assert o[k]["status"] == "refused", (k, o[k])
PY

exec 3<"$FIX/home/Projects/held/x"
sleep 300 <&3 & HOLDER=$!; disown "$HOLDER"
exec 3<&-
sleep 0.3
APPMON_FIXTURE_ACT=1 APPMON_SELECT="$SPACE" run "$BIN" --space-trash > "$WORK/space-act.json"
kill "$HOLDER" 2>/dev/null || true; HOLDER=""
python3 -I - "$WORK/space-act.json" "$WORK/space.json" "$FIX" <<'PY' && ok "space map act: moved, open item skipped" || bad "space map act"
import json, os, sys
o = {x["path"]: x for x in json.load(open(sys.argv[1]))}
scan = {x["path"]: x["kb"] for x in json.load(open(sys.argv[2]))}
fix = sys.argv[3]
for k in ["home/Projects/site", "home/Downloads/old.iso"]:
    assert o[k]["status"] == "moved", (k, o[k])
    assert o[k]["kb"] == scan[k], (k, o[k]["kb"], scan[k])
    assert not os.path.lexists(os.path.join(fix, k)), k
assert o["home/Projects/held"]["status"] == "skipped" and o["home/Projects/held"]["reason"].startswith("In use by"), o["home/Projects/held"]
assert os.path.exists(os.path.join(fix, "home/Projects/held/x"))
assert os.path.exists(os.path.join(fix, "home/Library/Caches/com.fixture.running"))
PY

# 8. Leftovers (spec 9): golden file, then the 9.4 acceptance criteria one by one
run "$BIN" --leftovers-json > "$WORK/left.json"
if [ "${UPDATE_GOLDEN:-}" = "1" ]; then cp "$WORK/left.json" "$ROOT/scripts/fixtures/expected-leftovers.json"; fi
if diff -u "$ROOT/scripts/fixtures/expected-leftovers.json" "$WORK/left.json" > "$WORK/left.diff"; then ok "leftovers match golden file"
else bad "leftovers differ from golden file"; cat "$WORK/left.diff"; fi
python3 -I - "$WORK/left.json" <<'PY' && ok "leftovers: installed, recent, protected and ambiguous data kept; one group per removed app" || bad "leftovers scan"
import json, sys
cats = json.load(open(sys.argv[1]))
g = {c["id"]: c for c in cats}
paths = {i["path"].replace("<root>/home/Library/", ""): i for c in cats for i in c["items"]}
def listed(s): return any(s in p for p in paths)
# 9.4 (1), (2): installed apps, their extensions and an app inside Application Support
for s in ["com.fixture.installed", "com.fixture.webtool", "WebDeployed"]: assert not listed(s), s
# 9.4 (4): recent data; found by Spotlight, a launchd label or as a plug-in; running; named like an installed app
for s in ["org.newvendor.tool", "org.spotvendor.app", "org.labelvendor.app", "org.panevendor.pane",
          "com.fixture.daemononly", "org.clashvendor.runningapp"]: assert not listed(s), s
# protected names and plain names without evidence
for s in ["com.apple.fixture", "com.google.fixture", "1Password", "PlainName"]: assert not listed(s), s
# 9.4 (3): one High group with every item, named from its settings file
ed = g["L:org.oldvendor.editor"]
assert ed["title"] == "Old Editor" and ed["group"] == "Leftovers", ed
want = {"Application Support/org.oldvendor.editor", "Caches/org.oldvendor.editor", "Caches/org.oldvendor.editor.helper",
        "Preferences/org.oldvendor.editor.plist", "Saved Application State/org.oldvendor.editor.savedState",
        "HTTPStorages/org.oldvendor.editor", "WebKit/org.oldvendor.editor", "Cookies/org.oldvendor.editor.binarycookies",
        "Containers/org.oldvendor.editor", "Group Containers/ABCDE12345.org.oldvendor.editor",
        "Application Scripts/org.oldvendor.editor", "<root>/Library/Application Support/org.oldvendor.editor"}
got = {i["path"].replace("<root>/home/Library/", "") for i in ed["items"]}
assert got == want, got ^ want
admin = [i for i in ed["items"] if i["path"].startswith("<root>/Library/")][0]
assert admin["risk"] == "Info" and not admin["selectable"], admin
# 9.4 (5): nothing is pre-selected; every item is Review or Info; every reason gives the limit
for c in cats:
    for i in c["items"]:
        assert not i["preselected"] and i["risk"] in ("Review", "Info"), i
        assert "limit" in i["reason"], i
# Low: same vendor as an installed app, and the folder named like the removed app
assert g["L:com.fixture.gone"]["group"].startswith("Possible"), g["L:com.fixture.gone"]
assert [i["path"] for i in g["L:name:org.oldvendor.editor"]["items"]] == ["<root>/home/Library/Application Support/Old Editor"]
# a container whose metadata names another app stays out
assert [i["path"] for i in g["L:org.mismatch.app"]["items"]] == ["<root>/home/Library/Application Support/org.mismatch.app"]
PY

APPMON_FIXTURE_FDA=denied run "$BIN" --leftovers-json > "$WORK/left-nofda.json"
python3 -I - "$WORK/left-nofda.json" <<'PY' && ok "leftovers without FDA: containers not entered, notice shown" || bad "leftovers FDA handling"
import json, sys
cats = json.load(open(sys.argv[1]))
assert any(c["id"] == "L-FDA" and c.get("notice") == "Needs Full Disk Access" for c in cats), cats
assert not any("Containers/" in i["path"] for c in cats for i in c["items"])
assert any(c["id"] == "L:org.oldvendor.editor" for c in cats)
PY

APPMON_FIXTURE_SPOTLIGHT=fail run "$BIN" --leftovers-json > "$WORK/left-nospot.json"
python3 -I - "$WORK/left-nospot.json" <<'PY' && ok "leftovers without Spotlight: scan completes, nothing unconfirmed listed (9.4: 6)" || bad "leftovers Spotlight failure"
import json, sys
cats = json.load(open(sys.argv[1]))
assert not any(c["id"].startswith("L:") for c in cats), [c["id"] for c in cats]
assert any(c["id"] == "L-SPOTLIGHT" for c in cats)
PY

LEFT="home/Library/Application Support/org.oldvendor.editor,home/Library/Caches/org.oldvendor.editor,home/Library/Preferences/org.oldvendor.editor.plist,home/Library/Application Support/com.fixture.gone,Library/Application Support/org.oldvendor.editor"
before="$(snapshot)"
APPMON_SELECT="$LEFT" run "$BIN" --leftovers-clean > "$WORK/left-dry.json"
[ "$before" = "$(snapshot)" ] && ok "leftovers dry run changed nothing" || bad "leftovers dry run changed the tree"
python3 -I - "$WORK/left-dry.json" <<'PY' && ok "leftovers dry run: only picked items planned, running vendor and admin items skipped" || bad "leftovers dry run plan"
import json, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
for k in ["home/Library/Application Support/org.oldvendor.editor", "home/Library/Caches/org.oldvendor.editor",
          "home/Library/Preferences/org.oldvendor.editor.plist"]:
    assert o[k]["status"] == "planned", (k, o[k])
assert o["home/Library/Application Support/com.fixture.gone"]["reason"] == "Running App is running", o   # same vendor, running
assert o["Library/Application Support/org.oldvendor.editor"]["status"] == "skipped", o     # Info: needs admin
assert len(o) == 5, o
PY

APPMON_FIXTURE_ACT=1 APPMON_SELECT="$LEFT" run "$BIN" --leftovers-clean > "$WORK/left-act.json"
python3 -I - "$WORK/left-act.json" "$WORK/left.json" "$FIX" <<'PY' && ok "leftovers act: picked items moved, sizes match the scan" || bad "leftovers act"
import json, os, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
scan = {i["path"].replace("<root>/", ""): i["kb"] for c in json.load(open(sys.argv[2])) for i in c["items"]}
fix = sys.argv[3]
moved = [k for k, v in o.items() if v["status"] == "moved"]
assert len(moved) == 3, o
for k in moved:
    assert not os.path.lexists(os.path.join(fix, k)), k
    assert o[k]["kb"] == scan[k], (k, o[k]["kb"], scan[k])
for k in ["home/Library/Application Support/com.fixture.gone", "Library/Application Support/org.oldvendor.editor",
          "home/Library/WebKit/org.oldvendor.editor"]:
    assert os.path.exists(os.path.join(fix, k)), k
PY
run "$BIN" --leftovers-json > "$WORK/left-rescan.json"
python3 -I - "$WORK/left-act.json" "$WORK/left-rescan.json" <<'PY' && ok "leftovers re-scan no longer lists moved items" || bad "leftovers re-scan"
import json, sys
moved = {x["path"] for x in json.load(open(sys.argv[1])) if x["status"] == "moved"}
listed = {i["path"] for c in json.load(open(sys.argv[2])) for i in c["items"]}
assert moved and not (moved & listed), moved & listed
PY

# 8b. A folder above an item swapped for a symlink after the checks (S13e): the event names the
# file itself (a file reference URL), so Finder moves the checked file, never the decoy.
D="home/Library/Logs/DiagnosticReports"
echo real > "$FIX/$D/Swap.ips"; touch -t 202001010000 "$FIX/$D/Swap.ips"
mkdir -p "$FIX/decoy"; echo decoy > "$FIX/decoy/Swap.ips"
APPMON_FIXTURE_ACT=1 APPMON_FIXTURE_SWAP="$D" APPMON_SELECT="$D/Swap.ips" run "$BIN" --clean-json > "$WORK/swap.json"
python3 -I - "$WORK/swap.json" "$FIX" "$D" <<'PY' && ok "swapped folder: the checked file moved, the decoy stayed" || bad "swapped folder"
import json, os, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
fix, d = sys.argv[2], sys.argv[3]
r = o[d + "/Swap.ips"]
assert open(os.path.join(fix, "decoy/Swap.ips")).read() == "decoy\n", "decoy changed"
if r.get("reason") == "Moved without Put Back":
    print("     (Finder can't be used here: the FileManager mover ran and the swap hook didn't)")
else:
    assert os.path.islink(os.path.join(fix, d)), "the swap hook didn't run"
    assert r["status"] == "moved" and "reason" not in r, r            # found in the Trash by device and inode
    assert not os.path.lexists(os.path.join(fix, d + ".moved/Swap.ips")), "the checked file wasn't moved"
PY

# 9. Uninstaller (spec 10), on its own fixture tree
urun() { APPMON_SCAN_ROOT="$UFIX" "$@"; }
usnap() { (cd "$UFIX" && find . 2>/dev/null | sort) || true; }
U="Applications/Vendor App.app"
APPMON_UNINSTALL="$U" urun "$BIN" --uninstall-json > "$WORK/un.json"
python3 -I - "$WORK/un.json" <<'PY' && ok "uninstaller lists the app and all its files, Pro's none, the shared group as Info (10 acceptance)" || bad "uninstaller plan"
import json, sys
d = json.load(open(sys.argv[1]))
items = {i["path"].replace("<root>/", ""): (c["id"], i) for c in d["categories"] for i in c["items"]}
L = "home/Library/"
want = {
    "Applications/Vendor App.app": ("U-APP", "Requested", True),
    L + "Caches/com.uvendor.app": ("U-CACHE", "Safe", True),          # new data: no age limit
    L + "Caches/com.uvendor.login": ("U-CACHE", "Safe", True),        # the login item's own ID
    L + "Logs/com.uvendor.app": ("U-CACHE", "Safe", True),
    L + "HTTPStorages/com.uvendor.app": ("U-CACHE", "Safe", True),
    L + "WebKit/com.uvendor.app": ("U-CACHE", "Safe", True),
    L + "Saved Application State/com.uvendor.app.savedState": ("U-CACHE", "Safe", True),
    L + "Application Support/com.uvendor.app": ("U-DATA", "Review", True),
    L + "Preferences/com.uvendor.app.plist": ("U-DATA", "Review", True),
    L + "Cookies/com.uvendor.app.binarycookies": ("U-DATA", "Review", True),
    L + "Containers/com.uvendor.app": ("U-MORE", "Review", False),
    L + "Group Containers/group.com.uvendor.app": ("U-MORE", "Review", False),
    L + "Application Scripts/com.uvendor.app": ("U-MORE", "Review", False),
    L + "LaunchAgents/com.uvendor.app.agent.plist": ("U-MORE", "Review", False),
    L + "Application Support/Vendor App": ("U-NAMED", "Review", False),
    L + "Group Containers/ABCDE12345.com.uvendor.shared": ("U-KEPT", "Info", False),
    L + "Group Containers/group.com.apple.fixturenotes": ("U-KEPT", "Info", False),   # S6: protected group name
    "Library/LaunchDaemons/com.uvendor.app.daemon.plist": ("U-KEPT", "Info", False),
    L + "Application Support/com.uvendor.app.bundled": ("U-KEPT", "Info", False),
}
assert set(items) == set(want), (set(items) ^ set(want))
for p, (cat, risk, pre) in want.items():
    c, i = items[p]
    assert (c, i["risk"], i["preselected"]) == (cat, risk, pre), (p, c, i)
    assert i["selectable"] == (risk != "Info"), (p, i)
assert "Shared with Vendor App Pro" in items[L + "Group Containers/ABCDE12345.com.uvendor.shared"][1]["reason"]
assert "Contains Other" in items[L + "Application Support/com.uvendor.app.bundled"][1]["reason"]
assert items[L + "Group Containers/group.com.apple.fixturenotes"][1]["reason"].endswith("Not moved: protected name"), items[L + "Group Containers/group.com.apple.fixturenotes"]
assert d["ids"] == ["com.uvendor.app", "com.uvendor.login"], d["ids"]   # the library XPC service is left out
assert not any("pro" in p or "sparkle" in p or "fake" in p or "unrelated" in p or p.endswith("helper.plist") for p in items), items.keys()
PY

python3 -I - "$BIN" "$UFIX" <<'PY' && ok "uninstaller refuses Apple, outside Applications, links and missing apps" || bad "uninstaller refusals"
import json, os, subprocess, sys
binp, fix = sys.argv[1], sys.argv[2]
def plan(app):
    env = dict(os.environ, APPMON_SCAN_ROOT=fix, APPMON_UNINSTALL=app)
    return json.loads(subprocess.run([binp, "--uninstall-json"], env=env, capture_output=True, check=True).stdout)
assert plan("Applications/Fake Safari.app")["refused"] == "Apps that come with macOS can't be removed."
assert "own uninstaller" in plan("home/Library/Application Support/WebDeployed/Web Tool.app")["refused"]
assert "link" in plan("Applications/Vendor Link.app")["refused"]
assert "no longer there" in plan("Applications/Nope.app")["refused"]
busy = plan("Applications/Busy.app")
assert busy["running"] == ["Busy Helper"], busy
assert all(not i["preselected"] for c in busy["categories"] for i in c["items"]), busy   # running helper: nothing pre-selected
twin = plan("Applications/Twin.app")
assert twin["copies"] == ["<root>/home/Applications/Twin.app"], twin
PY

APPMON_FIXTURE_FDA=denied APPMON_UNINSTALL="$U" urun "$BIN" --uninstall-json > "$WORK/un-nofda.json"
python3 -I - "$WORK/un-nofda.json" <<'PY' && ok "uninstaller without FDA: containers not entered, notice shown" || bad "uninstaller FDA handling"
import json, sys
d = json.load(open(sys.argv[1]))
assert any(c["id"] == "U-FDA" and c.get("notice") == "Needs Full Disk Access" for c in d["categories"]), d
assert not any("Containers/" in i["path"] for c in d["categories"] for i in c["items"])
PY

MORE="home/Library/Containers/com.uvendor.app,home/Library/Group Containers/group.com.uvendor.app,home/Library/Application Scripts/com.uvendor.app,home/Library/LaunchAgents/com.uvendor.app.agent.plist,home/Library/Application Support/Vendor App,home/Library/Group Containers/ABCDE12345.com.uvendor.shared"
before="$(usnap)"
APPMON_UNINSTALL="Applications/Busy.app" APPMON_SELECT="Applications/Busy.app" urun "$BIN" --uninstall-clean > "$WORK/un-busy.json"
APPMON_UNINSTALL="$U" APPMON_SELECT="$MORE" urun "$BIN" --uninstall-clean > "$WORK/un-dry.json"
[ "$before" = "$(usnap)" ] && ok "uninstaller dry run changed nothing" || bad "uninstaller dry run changed the tree"
python3 -I - "$WORK/un-dry.json" "$WORK/un-busy.json" <<'PY' && ok "uninstaller dry run: everything picked planned, Info refused, running app skipped" || bad "uninstaller dry run plan"
import json, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
assert len(o) == 16, len(o)
for k, v in o.items():
    if k.endswith("ABCDE12345.com.uvendor.shared"):
        assert v["status"] == "skipped", v
    else:
        assert v["status"] == "planned", (k, v)
b = json.load(open(sys.argv[2]))
assert [x["status"] for x in b] == ["skipped"] and b[0]["reason"] == "Busy Helper is running", b
PY

APPMON_FIXTURE_ACT=1 APPMON_UNINSTALL="$U" APPMON_SELECT="$MORE" urun "$BIN" --uninstall-clean > "$WORK/un-act.json"
python3 -I - "$WORK/un-act.json" "$WORK/un.json" "$UFIX" <<'PY' && ok "uninstaller act: the app and its files moved, sizes match, other apps' files stay" || bad "uninstaller act"
import json, os, sys
o = {x["path"].replace("<root>/", ""): x for x in json.load(open(sys.argv[1]))}
scan = {i["path"].replace("<root>/", ""): i["kb"] for c in json.load(open(sys.argv[2]))["categories"] for i in c["items"]}
fix = sys.argv[3]
moved = [k for k, v in o.items() if v["status"] == "moved"]
assert len(moved) == 15 and "Applications/Vendor App.app" in moved, o
for k in moved:
    assert not os.path.lexists(os.path.join(fix, k)), k
    assert o[k]["kb"] == scan[k], (k, o[k]["kb"], scan[k])
L = "home/Library/"
for k in ["Applications/Vendor App Pro.app", L + "Caches/com.uvendor.app.pro", L + "Application Support/com.uvendor.app.pro",
          L + "Preferences/com.uvendor.app.pro.plist", L + "LaunchAgents/helper.plist", L + "Containers/com.uvendor.app.fake",
          L + "Group Containers/ABCDE12345.com.uvendor.shared", L + "Group Containers/group.com.apple.fixturenotes",
          "Library/LaunchDaemons/com.uvendor.app.daemon.plist",
          L + "Application Support/com.uvendor.app.bundled", L + "Caches/org.sparkle-project.Sparkle", L + "Caches/com.unrelated.tool"]:
    assert os.path.lexists(os.path.join(fix, k)), k
PY
APPMON_UNINSTALL="$U" urun "$BIN" --uninstall-json > "$WORK/un-after.json"
grep -q "no longer there" "$WORK/un-after.json" && ok "uninstaller: the moved app is gone" || bad "uninstaller re-plan"

[ "$fail" = 0 ] && echo "fixture-test: all passed" || { echo "fixture-test: FAILED"; exit 1; }

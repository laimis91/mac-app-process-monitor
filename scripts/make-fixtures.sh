#!/bin/bash
# Builds a throw-away fixture tree for the disk cleaner (spec 13) and prints its path.
# Everything is fake: made-up apps, folders and files under /private/tmp/appmon-fixture-*.
set -euo pipefail
ROOT="$(mktemp -d /private/tmp/appmon-fixture-XXXXXX)"
FINISHED=""   # set just before printing the path; on any earlier exit the half-built tree is removed
trap 'rc=$?; [ -n "$FINISHED" ] || { chmod -R u+rwx "$ROOT" 2>/dev/null || true; rm -rf "$ROOT"; }; exit $rc' EXIT
H="$ROOT/home"
OLD=202001010000   # 1 Jan 2020: older than every age limit

file() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/zero > "$1"; }   # path, bytes
app() {  # bundle path, bundle ID, name
  mkdir -p "$1/Contents"
  cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$2</string><key>CFBundleName</key><string>$3</string></dict></plist>
PLIST
}

plist() {  # path, then key/value pairs
  local f="$1"; shift; mkdir -p "$(dirname "$f")"
  { echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    while [ $# -gt 1 ]; do echo "<key>$1</key><string>$2</string>"; shift 2; done
    echo '</dict></plist>'; } > "$f"
}

# The uninstaller (spec 10) gets its own tree:  make-fixtures.sh --uninstall
if [ "${1:-}" = "--uninstall" ]; then
  L="$H/Library"
  # A signed app: a copy of /usr/bin/true as its executable, ad-hoc signed with app-group entitlements.
  signed() {  # bundle path, bundle ID, name, app groups…
    local b="$1" id="$2" name="$3"; shift 3
    mkdir -p "$b/Contents/MacOS"; cp /usr/bin/true "$b/Contents/MacOS/$name"
    plist "$b/Contents/Info.plist" CFBundleIdentifier "$id" CFBundleName "$name" CFBundleExecutable "$name"
    local e="$ROOT/.ent.plist"
    { echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.application-groups</key><array>'
      for g in "$@"; do echo "<string>$g</string>"; done
      echo '</array></dict></plist>'; } > "$e"
    codesign -f -s - --entitlements "$e" "$b" 2>/dev/null; rm -f "$e"
  }
  A="$ROOT/Applications"
  # The app to uninstall: a login item outside its own ID, a library XPC service (left out), and a
  # second app whose ID extends it (com.uvendor.app.pro: none of its files may be listed).
  mkdir -p "$A/Vendor App.app/Contents/Library/LoginItems" "$A/Vendor App.app/Contents/XPCServices"
  signed "$A/Vendor App.app/Contents/Library/LoginItems/Vendor Login.app" com.uvendor.login "Vendor Login" group.com.uvendor.app
  signed "$A/Vendor App.app/Contents/XPCServices/Downloader.xpc" org.sparkle-project.Downloader Downloader
  signed "$A/Vendor App.app" com.uvendor.app "Vendor App" group.com.uvendor.app ABCDE12345.com.uvendor.shared
  signed "$A/Vendor App Pro.app" com.uvendor.app.pro "Vendor App Pro" ABCDE12345.com.uvendor.shared
  # Its files, one of each kind (spec 10 table). The caches are new: no age limit applies.
  for d in Caches Logs HTTPStorages WebKit "Application Support" "Application Scripts"; do file "$L/$d/com.uvendor.app/x" 8192; done
  file "$L/Caches/com.uvendor.login/x" 4096                                  # the login item's own ID
  file "$L/Saved Application State/com.uvendor.app.savedState/windows.plist" 4096
  plist "$L/Preferences/com.uvendor.app.plist" CFBundleName "Vendor App"
  file "$L/Cookies/com.uvendor.app.binarycookies" 4096
  file "$L/Containers/com.uvendor.app/Data/x" 8192
  plist "$L/Containers/com.uvendor.app/.com.apple.containermanagerd.metadata.plist" MCMMetadataIdentifier com.uvendor.app
  file "$L/Group Containers/group.com.uvendor.app/x" 4096                    # its own app group
  file "$L/Group Containers/ABCDE12345.com.uvendor.shared/x" 4096            # also claimed by Pro: Info
  plist "$L/LaunchAgents/com.uvendor.app.agent.plist" Label com.uvendor.app.agent
  file "$L/Application Support/Vendor App/notes" 4096                        # named like it: not pre-selected
  file "$ROOT/Library/LaunchDaemons/com.uvendor.app.daemon.plist" 1024       # needs admin: Info
  file "$L/Application Support/com.uvendor.app.bundled/x" 4096                # holds another app: Info
  plist "$L/Application Support/com.uvendor.app.bundled/Other.app/Contents/Info.plist" CFBundleIdentifier org.unrelated.other
  # Not this app's: Pro's files, a container whose record names another app, a launch agent whose
  # label is Pro's, a library's cache, and an unrelated app.
  for d in Caches "Application Support"; do file "$L/$d/com.uvendor.app.pro/x" 4096; done
  plist "$L/Preferences/com.uvendor.app.pro.plist" CFBundleName "Vendor App Pro"
  file "$L/Containers/com.uvendor.app.fake/Data/x" 4096
  plist "$L/Containers/com.uvendor.app.fake/.com.apple.containermanagerd.metadata.plist" MCMMetadataIdentifier org.other.thing
  plist "$L/LaunchAgents/helper.plist" Label com.uvendor.app.pro.agent
  file "$L/Caches/org.sparkle-project.Sparkle/x" 4096
  file "$L/Caches/com.unrelated.tool/x" 4096
  # Refused: an Apple ID, an app outside Applications, a link to an app; a running app; two copies.
  app "$A/Fake Safari.app" com.apple.fakesafari "Fake Safari"; mkdir -p "$A/Fake Safari.app/Contents/MacOS"
  app "$L/Application Support/WebDeployed/Web Tool.app" com.fixture.webtool "Web Tool"; mkdir -p "$L/Application Support/WebDeployed/Web Tool.app/Contents/MacOS"
  ln -s "Vendor App.app" "$A/Vendor Link.app"
  app "$A/Busy.app" com.fixture.busy "Busy"; mkdir -p "$A/Busy.app/Contents/MacOS"
  file "$L/Caches/com.fixture.busy/x" 4096
  printf 'com.fixture.busy.helper|Busy Helper\n' > "$ROOT/running.txt"
  app "$A/Twin.app" com.fixture.twin "Twin"; mkdir -p "$A/Twin.app/Contents/MacOS"
  app "$H/Applications/Twin.app" com.fixture.twin "Twin"; mkdir -p "$H/Applications/Twin.app/Contents/MacOS"
  file "$L/Caches/com.fixture.twin/x" 4096
  FINISHED=1; echo "$ROOT"
  exit 0
fi

# Installed and running apps (fixture-only inventory)
app "$ROOT/Applications/Fixture App.app" com.fixture.installed "Fixture App"
app "$ROOT/Applications/Fixture App.app/Contents/PlugIns/Share.appex" com.fixture.installed.share "Share"
app "$ROOT/Applications/Tools/Running App.app" com.fixture.running "Running App"
printf 'com.fixture.running|Running App\ncom.unity3d.UnityEditor5.x|Unity\n' > "$ROOT/running.txt"

# J-CACHE and the rules that claim paths under Caches (S14)
C="$H/Library/Caches"
file "$C/com.fixture.installed/data" 409600          # Safe, pre-selected
file "$C/com.fixture.installed.share/data" 40960     # embedded bundle: Safe
file "$C/com.fixture.running/data" 81920             # Safe, but its app is running
file "$C/com.fixture.gone/data" 122880               # app not found: Review
file "$C/PlainName/data" 40960                       # name only: Review
file "$C/com.apple.fixture/data" 4096                # never listed
file "$C/Google/data" 4096                           # never listed
file "$C/Homebrew/downloads/x" 8192                  # J-DEVCACHE-DIRS only
file "$C/Unity/upm/x" 8192                           # J-UNITY-UPM only; Unity never in J-CACHE
file "$C/com.unity3d.fixture/x" 16384                # J-UNITY, Unity is running
mkdir -p "$H/Documents/secret"
ln -s "$H/Documents" "$C/linked"                     # symlinks are never listed

# Logs, crash reports, temp
file "$H/Library/Logs/com.fixture.gone/old.log" 20480
file "$H/Library/Logs/Fresh/new.log" 4096            # too new
file "$H/Library/Logs/DiagnosticReports/Old.ips" 8192
file "$H/Library/Logs/DiagnosticReports/New.ips" 4096
file "$ROOT/tmp/old-item/x" 12288
file "$ROOT/tmp/held-item/x" 4096                    # kept open during the act test
file "$ROOT/tmp/new-item/x" 4096
file "$ROOT/tmp/com.apple.fixture/x" 4096            # never listed
mkdir -p "$ROOT/tmp/fifo-item" && mkfifo "$ROOT/tmp/fifo-item/pipe"   # holds a pipe: never listed
file "$C/com.fixture.locked/open/x" 4096             # part unreadable: never listed (S5)
mkdir -p "$C/com.fixture.locked/closed"

# Xcode
file "$H/Library/Developer/Xcode/DerivedData/Proj-abc/Build/x" 65536
for v in "15.0" "16.4 (20E247)" "17.0 (21A329)" "iPhone15,2 17.2 (21C62)" "weird"; do
  file "$H/Library/Developer/Xcode/iOS DeviceSupport/$v/Symbols/x" 8192
done

# Mail, backups, Trash
file "$H/Library/Mail Downloads/OLD-UUID/a.pdf" 8192
file "$H/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/OLD2/b.pdf" 8192
mkdir -p "$H/Library/Application Support/MobileSync/Backup/0000-FIXTURE"
cat > "$H/Library/Application Support/MobileSync/Backup/0000-FIXTURE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Device Name</key><string>Fixture iPhone</string></dict></plist>
PLIST
file "$H/.Trash/thing" 4096

# Developer tool caches and fake tools that only touch this tree
file "$H/.npm/_cacache/x" 32768
file "$H/.nuget/packages/x" 16384
file "$H/.local/share/NuGet/http-cache/x" 8192
mkdir -p "$ROOT/bin"
for t in npm dotnet; do
  cat > "$ROOT/bin/$t" <<'TOOL'
#!/bin/sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$(basename "$0") $*" >> "$ROOT/tool-log.txt"
case "$(basename "$0") $*" in
  "npm cache clean --force") rm -rf "$ROOT/home/.npm/_cacache/"* ;;
esac
TOOL
  chmod +x "$ROOT/bin/$t"
done

# Space map (spec 8): user items outside ~/Library, and things it must never move
file "$H/Projects/site/src/main.c" 204800             # a project folder: may be moved
file "$H/Projects/site/.git/objects/pack" 102400      # a repo's .git: Reveal only
ln "$H/Projects/site/src/main.c" "$H/Projects/site/hardlink.c"   # counted once
file "$H/Projects/held/x" 4096                       # kept open during the Space-map act test
file "$H/Projects/Tool.app/Contents/MacOS/tool" 8192  # an app in the home folder: Reveal only
file "$H/Downloads/old.iso" 1048576                  # a large old download: may be moved
file "$H/Pictures/Old.photoslibrary/database/x" 16384 # a photo library: Reveal only
file "$H/Dropbox/shared.txt" 4096                    # a sync folder: Reveal only
file "$H/.config/tool/settings" 4096                 # a home dot-folder: Reveal only

# Leftovers (spec 9). Every app here is made up.
L="$H/Library"
# An installed app's data, its embedded extension's data and a web-deployed app: never reported
file "$L/Application Support/com.fixture.installed/db" 8192
plist "$L/Preferences/com.fixture.installed.plist" CFBundleName "Fixture App"
file "$L/Application Support/com.fixture.installed.share/x" 4096
app "$L/Application Support/WebDeployed/Web Tool.app" com.fixture.webtool "Web Tool"
file "$L/Application Support/WebDeployed/Web Tool.app/Contents/MacOS/webtool" 4096
plist "$L/Preferences/com.fixture.webtool.plist" CFBundleName "Web Tool"
# A removed app (Old Editor): one High group, with Review-only and Info items, and a folder named
# like it (Possible). Its container and group container need Full Disk Access.
for d in "Application Support" "HTTPStorages" "WebKit" "Application Scripts"; do file "$L/$d/org.oldvendor.editor/x" 16384; done
file "$L/Caches/org.oldvendor.editor/x" 16384
file "$L/Caches/org.oldvendor.editor.helper/x" 4096
plist "$L/Preferences/org.oldvendor.editor.plist" CFBundleName "Old Editor"
file "$L/Saved Application State/org.oldvendor.editor.savedState/windows.plist" 4096
file "$L/Cookies/org.oldvendor.editor.binarycookies" 4096
file "$L/Containers/org.oldvendor.editor/Data/x" 8192
plist "$L/Containers/org.oldvendor.editor/.com.apple.containermanagerd.metadata.plist" MCMMetadataIdentifier org.oldvendor.editor
file "$L/Group Containers/ABCDE12345.org.oldvendor.editor/x" 4096
file "$ROOT/Library/Application Support/org.oldvendor.editor/x" 4096      # needs admin: Info
file "$L/Application Support/Old Editor/notes" 4096                       # named like it: Possible
# A removed app whose settings changed recently: not reported
file "$L/Caches/org.newvendor.tool/x" 4096
plist "$L/Preferences/org.newvendor.tool.plist" CFBundleName "New Tool"
# Found only by Spotlight, by a launchd label, or as a plug-in: not reported
file "$L/Application Support/org.spotvendor.app/x" 4096
echo "org.spotvendor.app" > "$ROOT/spotlight.txt"
file "$L/Application Support/org.labelvendor.app/x" 4096
plist "$ROOT/Library/LaunchDaemons/org.labelvendor.app.helper.plist" Label org.labelvendor.app.helper
plist "$L/PreferencePanes/Pane.prefPane/Contents/Info.plist" CFBundleIdentifier org.panevendor.pane CFBundleName Pane
plist "$L/Preferences/org.panevendor.pane.plist" CFBundleName Pane
# Named like an installed app, protected names, plain names without evidence, a running app's data
file "$L/Application Support/org.clashvendor.runningapp/x" 4096           # "Running App" is installed
file "$L/Application Support/com.apple.fixture/x" 4096
file "$L/Application Support/com.google.fixture/x" 4096
file "$L/Application Support/1Password/x" 4096
file "$L/Application Support/PlainName/x" 4096
file "$L/Application Support/com.fixture.daemononly/x" 4096              # running, not in Applications
printf 'com.fixture.daemononly|Daemon Only\n' >> "$ROOT/running.txt"
# A container whose metadata names another app: left out of its group
file "$L/Application Support/org.mismatch.app/x" 4096
file "$L/Containers/org.mismatch.app/Data/x" 4096
plist "$L/Containers/org.mismatch.app/.com.apple.containermanagerd.metadata.plist" MCMMetadataIdentifier org.other.app
# The same vendor as an installed app: Possible (com.fixture.gone's cache and logs are above)
file "$L/Application Support/com.fixture.gone/x" 4096

# Dates: everything old, except the "new" items
find "$ROOT" -exec touch -h -t "$OLD" {} +
touch "$H/Library/Logs/Fresh/new.log" "$H/Library/Logs/Fresh" "$H/Library/Logs/DiagnosticReports/New.ips" \
      "$ROOT/tmp/new-item/x" "$ROOT/tmp/new-item" "$L/Preferences/org.newvendor.tool.plist"
chmod 000 "$C/com.fixture.locked/closed"
FINISHED=1; echo "$ROOT"

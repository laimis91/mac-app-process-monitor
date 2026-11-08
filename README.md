<p align="center">
  <img src="AppMonitor/Icon/AppIcon.png" width="128" alt="App Monitor icon">
</p>

<h1 align="center">App Monitor</h1>

<p align="center">
  A clear, free process monitor for macOS that shows what each app <i>really</i> costs,
  including every process it started.
</p>

![App Monitor screenshot](docs/screenshot.png)

<sub>The screenshot uses demo mode: every process, folder and number in it is made up.</sub>

## Why

Activity Monitor shows each process on its own row. An app that starts helpers, terminals or
scripts looks idle while its child processes heat up your Mac. Its memory numbers also make it
hard to tell how much RAM you actually have left.

App Monitor groups everything under the app that started it, adds the numbers up, and explains
memory in plain terms.

## Features

- **Per-app totals.** CPU, GPU and RAM for each app, including all its child processes.
- **Process tree.** Expand an app to see what it started, all the way down to the script doing
  the work. Shell processes show their command line and working folder.
- **Show hottest.** One click opens the busiest branch.
- **CPU panel.** Overall load, "N of M cores busy", a 3-minute graph, and the busiest app.
- **GPU panel.** Overall GPU load, GPU memory in use, a graph, and per-app GPU use.
- **Memory panel.** How much RAM is *really* available, split into Apps, System, Compressed,
  Cache and Free, plus memory pressure and swap. Hover over any part for an explanation.
- **End or force-quit** a process, a process with all its children, or a whole app, always
  after a confirmation.
- Search, sort by CPU / GPU / RAM, hide idle child processes, pause.
- **Disk cleaner** (Disk tab). Finds app caches, old logs and crash reports, old temporary files,
  Mail attachment copies and developer caches (Xcode, Unity, NuGet, npm, pnpm, Yarn, pip,
  Homebrew, Docker). Every item says why it was found. Only items marked *Safe* are pre-selected,
  files go to the Trash through Finder, so Finder's **Put Back** restores them, and tool caches are cleared with the tool's own
  command, shown to you before it runs. Age limits are adjustable in Settings (⌘,).
- **Space map** (Disk tab → Space map). Shows which folders in your home folder and Applications
  take the most space, largest first, labelled with the app they belong to. Large folders
  unchanged for six months are highlighted. Everything can be revealed in Finder. Items you pick
  one at a time can go to the Trash after a confirmation; everything in `~/Library`, apps, photo
  libraries, hidden folders and synced folders stay Reveal only.
- **Leftovers** (Disk tab → Leftovers). Finds data left behind by apps you deleted by dragging
  them to the Trash: settings, caches, app data, web data and logs, grouped per app. An item is
  listed only if no check finds its app on this Mac (installed apps and their helpers, apps
  LaunchServices or Spotlight know, launch jobs, plug-ins, running apps) and nothing of that app
  changed for 30 days. Nothing is pre-selected; uncertain matches are kept apart under
  "Possible leftovers". App containers are checked only with Full Disk Access.
- **Uninstaller** (Disk tab → Uninstaller). Pick an app from Applications, or drop one onto the
  Disk tab, to see the app and every file that belongs to it: caches, logs, settings, app data,
  containers and launch agents, matched by its bundle IDs. Another app's files are never listed,
  and data an app shares with another app is shown but kept. The app, its caches and its settings
  are pre-selected; everything goes to the Trash, so Put Back works. Apps that come with macOS,
  apps outside Applications and running apps are not removed.
- Lightweight: uses about 1–3% of one CPU core.
- Native SwiftUI, no dependencies, universal (Apple Silicon and Intel).

## Install

### Build from source (recommended)

You need macOS 14 Sonoma or later and the Xcode Command Line Tools (`xcode-select --install`).
Full Xcode isn't needed.

```bash
git clone https://github.com/laimis91/mac-app-process-monitor.git
cd mac-app-process-monitor
./AppMonitor/build.sh
open "AppMonitor/App Monitor.app"
```

Drag `App Monitor.app` into Applications to keep it.

A plain build is ad-hoc signed, so macOS treats every rebuild as a new app and forgets Full Disk
Access. To keep it, sign with your own certificate (see [Signing](#signing)):

```bash
APPMON_SIGN_IDENTITY="App Monitor Signing" ./AppMonitor/build.sh
```

### Downloaded build

Builds from the [Releases page](https://github.com/laimis91/mac-app-process-monitor/releases)
are signed with the project's own certificate but not notarized by Apple, so macOS blocks them
the first time. Open the app once, then go to **System Settings → Privacy & Security** and
click **Open Anyway**.

## Reading the numbers

| Value | Meaning |
|---|---|
| **CPU %** (per app or process) | 100% = one fully busy CPU core. 250% means about 2.5 cores. Same convention as `ps`, `top` and Activity Monitor. |
| **LOAD %** (CPU panel) | Share of the whole Mac: all cores together = 100%. |
| **GPU %** | Share of GPU time the app used over the last refresh (2 seconds). |
| **RAM** | Resident memory, summed per process. Memory shared between processes can be counted more than once, so app totals can read a little high. |
| **Available** (memory panel) | Total RAM minus Apps, System and Compressed. Cache counts as available, because macOS frees it the moment an app needs it. |
| **Pressure** | The best single sign of whether you need more RAM. Green is fine, whatever the other numbers say. |

## Privacy

App Monitor runs entirely on your Mac. It has no network code and collects nothing. The only
things it saves are the disk cleaner's settings and ignore list, in the app's preferences; scan
results are never stored. It reads the same information as Activity Monitor: the process list
from `ps`, memory statistics from the kernel, and GPU statistics from IOKit.

### Moving items to the Trash

The disk cleaner asks Finder to move items to the Trash, so you can restore any of them with
**Put Back**. The first time you clean, macOS asks whether App Monitor may control Finder. If
you decline, items are still moved to the Trash, but without Put Back (drag them back instead).
You can change this in **System Settings → Privacy & Security → Automation**.

### Full Disk Access

The disk cleaner works without it, but skips folders macOS protects (app containers, Mail, the
Trash) and marks them "Needs Full Disk Access". To include them, switch App Monitor on in
**System Settings → Privacy & Security → Full Disk Access**. Releases after 1.1.0 are all signed
with the same certificate, so macOS should keep this permission when you update. Updating from
1.1.0 or earlier (ad-hoc signed), or running an ad-hoc build of your own: switch App Monitor off
and on again after each update.

## Demo mode and screenshots

Demo mode replaces real processes with made-up ones, which is handy for screenshots:

```bash
open -n "AppMonitor/App Monitor.app" --env APPMON_DEMO=1
```

`scripts/screenshot.sh` rebuilds the app and regenerates `docs/screenshot.png` from demo mode.

## Also included

`scripts/apptop.py` is a small terminal version: per-app CPU and RAM including child
processes, refreshed every 2 seconds.

```bash
python3 scripts/apptop.py              # live view
python3 scripts/apptop.py --detail Safari
```

## Project layout

```
AppMonitor/
  main.swift        data collection: processes, memory, GPU
  Views.swift       UI and theme
  Demo.swift        demo mode and window capture
  CleanerModel.swift, CleanerViews.swift   Disk tab and Settings window
  SpaceMapModel.swift, SpaceMapViews.swift Space map view
  Cleaner/          disk cleaner engine: rules, path guard, scanner, actions
  Icon/             app icon and the script that draws it
  build.sh          builds App Monitor.app
scripts/            apptop.py, screenshot.sh, selftest.sh, fixture-test.sh, make-signing-cert.sh
docs/               README screenshot, disk cleaner specification
```

## Tests

```bash
scripts/selftest.sh       # disk cleaner logic: path guards, rules, key parsing, settings, Space map
scripts/fixture-test.sh   # scans and cleans a made-up folder tree (its tiny fake files go to your Trash)
```

## Releases

Pushing a version tag builds the app on GitHub Actions and publishes it on the Releases page
([`.github/workflows/release.yml`](.github/workflows/release.yml)). The workflow checks the
signing secrets, runs the self-test, builds a signed universal app with the tag's version, checks
the signature, and uploads `AppMonitor-<version>.zip`. If the signing secrets are missing it
fails before building and publishes nothing.

```bash
git tag v1.2.0
git push origin v1.2.0
```

Local builds use version 1.1.0 unless `APPMON_VERSION` is set.

## Signing

macOS remembers Full Disk Access by the app's *designated requirement*. An ad-hoc signature's
requirement is a hash of that one build (`designated => cdhash H"…"`), so every update looks
like a new app. A build signed with a certificate has a requirement that names the bundle ID and
the certificate (`designated => identifier "io.github.laimis91.appmonitor" and certificate
leaf = H"…"`), which stays the same as long as the same certificate signs every release.

`build.sh` reads these variables:

| Variable | Effect |
|---|---|
| `APPMON_SIGN_IDENTITY` | Sign with this keychain identity (name or SHA-1). Unset: ad-hoc. The build fails if the result has no identifier-and-certificate requirement. |
| `APPMON_SIGN_KEYCHAIN` | Look for the identity only in this keychain. |
| `APPMON_RELEASE=1` | Refuse to build without `APPMON_SIGN_IDENTITY`. The release workflow sets it. |

Check a build with `codesign -d -r- "AppMonitor/App Monitor.app"`.

### Create the certificate (maintainer, once)

The release certificate is a self-signed code-signing certificate named "App Monitor Signing".
It lives in the maintainer's keychain and in GitHub secrets, never in the repo. Create it once
and keep it: a new certificate makes every user grant Full Disk Access again.

```bash
scripts/make-signing-cert.sh --p12 ~/Desktop/appmon-signing.p12
```

The script makes the certificate and key in a private temporary folder, adds them to your login
keychain, and exports them to the `.p12` (it asks for a `.p12` password, at least 12
characters, without echoing it; it refuses to write it inside any git checkout). macOS may ask for your
login password. The first signed build may ask whether `codesign` can use the key: click
**Always Allow**. `security find-identity -p codesigning` then lists it as
`CSSMERR_TP_NOT_TRUSTED`; that is expected for a self-signed certificate and doesn't stop
`codesign`.

Contributors who build from source can make their own certificate the same way (without
`--p12`), or stay ad-hoc.

### GitHub secrets (maintainer, once)

The release workflow needs two repository secrets:

| Secret | Value |
|---|---|
| `APPMON_SIGN_P12` | The `.p12`, base64-encoded |
| `APPMON_SIGN_P12_PASSWORD` | The `.p12` password |

```bash
base64 -i ~/Desktop/appmon-signing.p12 | gh secret set APPMON_SIGN_P12
gh secret set APPMON_SIGN_P12_PASSWORD
rm ~/Desktop/appmon-signing.p12
```

`gh secret set` without a value asks for it without echoing. You can also add both under
**Settings → Secrets and variables → Actions**. The workflow imports the `.p12` into a temporary
keychain with a random password, signs, and deletes the keychain at the end of the job. To export
the `.p12` again later, use Keychain Access: **My Certificates → App Monitor Signing → Export**.

## License

[MIT](LICENSE)

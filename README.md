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

### Downloaded build

Builds from the [Releases page](https://github.com/laimis91/mac-app-process-monitor/releases) are ad-hoc signed, not notarized by Apple, so macOS blocks them
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
**System Settings → Privacy & Security → Full Disk Access**. Builds are ad-hoc signed, so macOS
forgets this permission after each update: switch it off and on again.

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
  Cleaner/          disk cleaner engine: rules, path guard, scanner, actions
  Icon/             app icon and the script that draws it
  build.sh          builds App Monitor.app
scripts/            apptop.py, screenshot.sh, selftest.sh, fixture-test.sh
docs/               README screenshot, disk cleaner specification
```

## Tests

```bash
scripts/selftest.sh       # disk cleaner logic: path guard, rules, key parsing, settings
scripts/fixture-test.sh   # scans and cleans a made-up folder tree (its tiny fake files go to your Trash)
```

## Releases

Pushing a version tag builds the app on GitHub Actions and publishes it on the Releases page
([`.github/workflows/release.yml`](.github/workflows/release.yml)). The workflow runs the
self-test, builds a universal app with the tag's version, and uploads `AppMonitor-<version>.zip`.

```bash
git tag v1.1.0
git push origin v1.1.0
```

Local builds use version 1.1.0 unless `APPMON_VERSION` is set.

## License

[MIT](LICENSE)

# Disk Cleaner: Specification

| | |
|---|---|
| **Status** | Decisions made (section 14). Ready for phase 1. Not implemented. |
| **Applies to** | App Monitor 1.x (SwiftUI, macOS 14+, not sandboxed) |
| **Delivery** | Five phases, each shippable on its own (section 12) |

The words **MUST**, **MUST NOT** and **SHOULD** are used as in RFC 2119.

---

## 1. Goal

Help users get disk space back from two kinds of waste, safely and with full understanding of
what is removed:

1. **Junk.** Caches, logs, crash reports, old temporary files and developer caches (NuGet,
   npm, Xcode and so on) that apps did not clean up.
2. **Leftovers.** Files and folders left behind after an app was deleted.

The cleaner lives inside App Monitor, next to the existing process monitor.

### User stories

- As a user, I can scan my Mac and see, per category, how much space is reclaimable, and why
  each item was found.
- As a developer, I can clear package-manager and build caches with the tools' own commands,
  without remembering each one.
- As a user who deleted apps by dragging them to the Trash, I can find the data they left behind
  and remove it without risking data that belongs to apps I still use.
- As a user, I can see which folders are taking the most space, labelled by the app that owns
  them.
- As a cautious user, I can undo a cleanup, because removed items go to the Trash.

### Non-goals (v1)

- Cleaning anything that needs administrator rights. Root-owned locations are shown read-only.
- Automatic or scheduled cleaning.
- Cleaning other users' home folders or external drives.
- "Speed up your Mac" features: RAM purging, maintenance scripts, login-item management.
- Removing apps that ship with macOS, or anything protected by System Integrity Protection.
- Duplicate-file finding.

---

## 2. Safety principles (normative)

These rules override any feature behaviour described later.

| # | Rule |
|---|---|
| S1 | **Preview first.** Nothing is removed without a results list the user has reviewed and an explicit confirmation step. |
| S2 | **Trash, not delete.** File removal MUST move items to the Trash: through Finder (an Apple event `core/delo` built from file URLs, never script text), so Finder's Put Back works (decision D8). If macOS refuses Automation access or Finder isn't running, `FileManager.trashItem(at:resultingItemURL:)` is used instead and the summary says those items have no Put Back. `removeItem` MUST NOT be used for user-selected cleanup. The only exception is S3. |
| S3 | **Official tool commands** (for example `dotnet nuget locals`, `npm cache clean`) remove data permanently. They are a separate action type, labelled "Runs <tool>'s own cleanup, can't be undone", MUST be opt-in, and MUST show the exact command before running it. |
| S4 | **Protected paths.** The app MUST NOT target anything under `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, `/private/var` (except the current user's own temp folder, rule J-TMP), Apple's shipped apps, or another user's home. Enforced by a central path allow-list (section 6.4), not per feature. |
| S5 | **Doubt means keep.** If any check is uncertain (a probe fails or times out, a permission error, an unreadable bundle), the item is treated as in use or installed and not offered for cleanup. |
| S6 | **No risky defaults.** Only *Safe* items that are moved to the Trash MAY be pre-selected. Tool-command items (S3) are never pre-selected, whatever their risk. *Review* items are never pre-selected, except the uninstaller rows marked so in section 10, where the user has named the app to remove. *Requested* items (section 5) are pre-selected. *Info* items cannot be selected at all. |
| S7 | **Running apps.** Items owned by a running app MUST be skipped, or the user is asked to quit the app first. Ownership is checked with the same bundle-ID logic used for leftovers. |
| S8 | **Failures don't cascade.** An item that fails to move (permission, missing, locked) is skipped and reported. It never fails the whole operation. Moving a file that another process has open usually *succeeds* on macOS, so open files are detected before acting (S13), not by waiting for a failure. |
| S9 | **Explain every item.** Every result shows its rule ("Cache folder of com.example.app, an app not found on this Mac, unchanged for 94 days"). |
| S10 | **Honest sizes.** Reclaimable sizes use allocated size with hard links counted once. Totals are labelled as estimates where APFS clones or snapshots can make the real gain smaller (section 6.2). |
| S11 | **No network, minimal storage.** The cleaner sends nothing anywhere. Rule data is bundled in the app. Only settings (age limits, section 4.6) and the user's ignore list are stored, in `UserDefaults`. Scan results are never stored. |
| S12 | **Symlinks.** Scans MUST NOT follow symbolic links or cross onto another volume. A selected item that is a symlink is moved to the Trash as the link itself, never its target. An item whose *parent chain* contains a symlink is dropped. |
| S13 | **Re-check at action time.** Immediately before acting on each item, re-check: (a) the path guard (6.4), (b) the owning app is not running, (c) no file inside is open (temp and cache items only), checked against one open-file snapshot taken per Clean: for each process of the current user, its open files (`PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`), working directory and memory-mapped files, matched by path prefix. If the snapshot can't be taken, those items are skipped (S5). Processes of root and other users are not visible, which is an accepted limit, (d) the newest modification date still meets the rule's age limit, (e) the item's `fileResourceIdentifier` is unchanged since the scan. Any failed check skips the item with its reason. The checks run again after the user uses a [Quit] button. |
| S14 | **Most specific rule wins.** Each path belongs to exactly one rule. A general rule (for example "children of `~/Library/Caches`") excludes every path claimed by a more specific rule, **and every parent folder of such a path** (so `Caches/Unity` is never offered when `Caches/Unity/upm` is claimed). |

---

## 3. Permissions

### 3.1 Full Disk Access (FDA)

macOS offers no API to request FDA and no prompt for it. The app detects it and guides the user.
Product decision (from the user): *ask for FDA by guiding to System Settings; if the user
declines, work only where access is available.*

**Detection.** Try to read the contents of each probe path in order:

1. `~/Library/Containers/com.apple.stocks`
2. `~/Library/Safari`
3. `~/Library/Mail`

| Result of the read | Meaning |
|---|---|
| Success on any probe | `granted` |
| `EPERM` (from `NSUnderlyingErrorKey`) on at least one probe, no successes | `denied` |
| Only `ENOENT` or other errors | `unknown`, treated as denied for scanning, with no "denied" wording |

Reportedly, checking for access adds App Monitor to the FDA list in System Settings (switched
off), so the user only has to switch it on. This is unverified; if it doesn't happen, the banner
text tells the user to add the app with the **+** button.

**Re-check** when the app becomes active (`NSApplication.didBecomeActiveNotification`) and when a
scan starts.

**Asking.** The Disk tab shows a banner while access isn't `granted`:

> **Full Disk Access is off.** App Monitor can't look inside some folders, such as app
> containers and Mail. Those parts are skipped. [Open System Settings] [Not now]

The button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
This URL is not documented by Apple, so if opening it fails, fall back to
`x-apple.systempreferences:com.apple.preference.security`. "Not now" hides the banner for the
session; a small "Limited access" chip stays visible in the Disk header.

**Partial mode.** Locations that fail with `EPERM` appear in results as a greyed
"Needs Full Disk Access" row with no size, never silently omitted.

### 3.2 Signing dependency

macOS stores an FDA grant against the app's code-signing designated requirement. The current
ad-hoc signature's requirement is a build hash, so **every update loses the grant**. Phase 5
(section 11) fixes this, and phase 3 depends on it to be truly useful.

Until then, the FDA banner SHOULD add: "If you just updated App Monitor, switch it off and on
again in Full Disk Access."

### 3.3 Administrator rights

None in v1. Items in `/Library` that are not writable by the user are shown as *Info* with the
note "Needs administrator rights to remove. Remove it in Finder."

---

## 4. User interface

### 4.1 Placement

A segmented switch in the title bar row, next to the LIVE badge: **Monitor | Disk**. Each tab
keeps its own state. The process sampler keeps running in the background, so switching back is
instant.

### 4.2 Disk tab layout

```
┌ Header panels ──────────────────────────────────────────────────────────┐
│ Disk ring: used/free · Reclaimable now: 14.2 GB · Access: Full/Limited  │
├ Toolbar ────────────────────────────────────────────────────────────────┤
│ [Scan] [Stop]  View: Junk | Leftovers | Space map   Search…   Selected: 3.1 GB [Move to Trash…]
├ Results ────────────────────────────────────────────────────────────────┤
│ ▸ ☑ App caches                    2.4 GB   Safe     38 items            │
│ ▾ ☐ NuGet package cache           5.1 GB   Review   runs dotnet …       │
│      ~/.nuget/packages  ·  why: "Restore downloads these again"         │
│ ▸ ☐ Needs Full Disk Access: Containers     —  (Open Settings)           │
└─────────────────────────────────────────────────────────────────────────┘
```

- Reuse the existing `Panel`, `Ring`, `Chip`, `HeatBar`, `ToolButton` and `Theme` styles.
- Each category row can be expanded to show its items (path, size, last modified, reason).
- A category checkbox selects that category's *Safe* items. In a category with no *Safe*
  items it selects all its *Review* items that go to the Trash, except items whose app is
  running. The category row's context menu has "Select All N Items" (including *Review*) and
  "Deselect All". Nothing here changes S6: these are user actions, not pre-selection.
- Rows have a context menu with Reveal in Finder, Copy path, and "Always ignore this item"
  (section 9.3).

### 4.3 Confirmation sheet

Shown before any change:

- The selected item count and total size.
- Separate counts for "Moved to Trash" and "Runs tool cleanup, can't be undone", with the
  commands listed.
- Apps that need quitting first, with a [Quit] button for each.
- [Cancel] (the default) and [Clean].

### 4.4 Result summary

- Space moved to the Trash, space freed by tool commands, and items skipped (with reasons).
- "Space in the Trash is freed when you empty it." with an [Open Trash] button. Emptying the
  Trash is left to the user (decision D3).

### 4.5 Progress and responsiveness

- Scanning runs off the main thread, reports progress per location, and can be stopped at any
  time.
- Partial results appear as they are found.
- The process monitor's own CPU budget (about 1–3% of a core when idle) MUST NOT change while
  no scan is running.

### 4.6 Settings (decision D6)

A Settings window (App menu → Settings…, ⌘,) with:

| Setting | Default | Allowed range |
|---|---|---|
| Logs and crash reports older than | 7 days | 1–365 days |
| Temporary files older than | 3 days | 3–90 days (macOS itself cleans temp files after 3 idle days) |
| Leftovers unchanged for | 30 days | 14–365 days |
| Possible (Low-confidence) leftovers unchanged for | 90 days | at least the leftovers limit, up to 730 days |
| Mail attachments older than | 30 days | 7–365 days |
| Ignored items | empty | list with Remove buttons; filled from "Always ignore this item" |

- The minimums are deliberate: values outside a range are refused with a message, never clamped
  silently.
- Raising the leftovers limit above the current Low-confidence limit is refused with a message
  ("Raise the Possible-leftovers limit first").
- On launch, every stored value is checked again. A value out of range (for example one set
  with `defaults write`) is replaced by its default.
- A **Restore defaults** button resets the age limits (not the ignore list).
- The rules (sections 7 and 9) read the current values. Every result's reason shows the limit
  that applied ("unchanged for 94 days, limit 30").

---

## 5. Risk levels

| Level | Meaning | Selectable | Pre-selected |
|---|---|---|---|
| **Safe** | The app or the OS re-creates it, and Apple or the tool documents it as safe to clear | yes | yes, Trash method only (S6) |
| **Review** | Safe in principle, but has a cost (re-download, lost history) or can't be fully attributed | yes | no, except the section 10 uninstaller rows marked so |
| **Requested** | The item the user explicitly asked to remove: the app bundle in the uninstaller (section 10) | yes | yes |
| **Info** | Shown for awareness only (needs admin, belongs to an installed app, user data) | no | — |

---

## 6. Shared engine

### 6.1 Components (new files)

| File | Responsibility |
|---|---|
| `Cleaner/ScanEngine.swift` | Walks folders, measures sizes, streams results, handles cancellation |
| `Cleaner/Rules.swift` | Declarative category and rule definitions: id, paths, risk, age limits, owner hints, command |
| `Cleaner/InstalledApps.swift` | Installed and running app inventory and bundle-ID key parsing (section 9.2). Delivered in phase 1, because S7 needs it |
| `Cleaner/LeftoverMatcher.swift` | Matches folders to apps; orphan decision (phase 3) |
| `Cleaner/Actions.swift` | Trash mover, tool-command runner, path guard |
| `Cleaner/Permissions.swift` | FDA detection and the Settings link |
| `Cleaner/SpaceMap.swift` | Space map tree, scanner and Space-map guard (phase 2, section 8.1) |
| `CleanerViews.swift` | Disk tab UI |
| `Demo.swift` (extended) | Demo results for screenshots |

Integration with the existing code:

- `build.sh`'s `SOURCES` list gains the `Cleaner/…` paths.
- Developer-only switches (`APPMON_SCAN_ROOT`) are compiled in only with `-D APPMON_DEBUG`. The
  release build doesn't set it.
- Rules, key parsing, the matcher and the path guard are kept free of AppKit and SwiftUI, so
  `scripts/selftest.sh` can compile them with a test `main` using plain `swiftc`.
- Disk tab state lives in a `CleanerModel` `@StateObject` owned by `AppMonitorApp`, next to
  `Sampler`, so it survives tab switches.

### 6.2 Size measurement

- Enumerate with `FileManager.enumerator(at:includingPropertiesForKeys:options:)`, prefetching
  `totalFileAllocatedSizeKey`, `isDirectoryKey`, `isSymbolicLinkKey`, `fileResourceIdentifierKey`,
  `contentModificationDateKey` and `volumeIdentifierKey`.
- Use **allocated** size (`totalFileAllocatedSizeKey`), never the logical `fileSize`.
- Count hard links once, using `fileResourceIdentifierKey` within one scan.
- Stop at volume boundaries: skip a child whose `volumeIdentifierKey` differs from the scan root's.
- APFS clones can't be detected through public API. Totals are labelled "up to X". The UI
  MUST NOT promise an exact gain.
- A folder's age is the newest `contentModificationDate` of anything inside it, capped at
  10,000 entries. If the cap is reached the folder is treated as "recently used" (S5).

### 6.3 Performance targets

- A full Junk scan of a typical developer Mac (about 1 million files in scope) SHOULD finish in
  under 60 seconds on Apple Silicon.
- Memory use during a scan SHOULD stay under 300 MB.
- Use one serial enumeration per scan root and up to 4 roots in parallel.

### 6.4 Path guard

`Actions.swift` checks **every** path right before acting on it (S13).

**Canonical form.** Every allow/deny root is canonicalized with `realpath(3)` (which keeps
`/private`). For the item, only its **parent folder** is canonicalized with `realpath(3)`; the
last name component is appended unchanged and the item itself is checked with `lstat`, so a
symlinked item is judged by where the link sits, not where it points (S12). Paths are compared
**component by component** and **without case** (APFS is case-insensitive by default).
`/Users/bob` never matches `/Users/bobby`.

**Allow per rule, not globally.** An item passes only if it lies strictly *inside* the root of
the rule that produced it (the root itself is never an item). There is no global "home folder"
allow. The roots used by v1 rules are:

- `~/Library/Caches`, `~/Library/Logs`, `~/Library/Application Support`, `~/Library/Preferences`,
  `~/Library/Saved Application State`, `~/Library/HTTPStorages`, `~/Library/WebKit`,
  `~/Library/Cookies`, `~/Library/Containers`, `~/Library/Group Containers`,
  `~/Library/Application Scripts`, `~/Library/LaunchAgents`
- `~/Library/Developer/Xcode/DerivedData`, `~/Library/Developer/Xcode/iOS DeviceSupport`
- `~/Library/Mail Downloads`
- the user's temp folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`)
- for the uninstaller only: `/Applications` and `~/Applications` (app bundles only, section 10)
- for the Space map only: see "Space-map guard" below

**Deny (overrides allow):**

- the S4 list
- `~/Library/Keychains`, `~/.ssh`, `~/.gnupg`
- iCloud and sync: `~/Library/Mobile Documents`, `~/Library/CloudStorage`
- Apple data: `~/Library/Mail`, `~/Library/Safari`, `~/Library/Messages`, `~/Library/Photos`,
  `~/Library/Application Support/MobileSync`, `~/Library/Application Support/AddressBook`,
  `~/Library/Application Support/CallHistoryDB`, `~/Library/Application Support/Knowledge`,
  `~/Library/Application Support/FileProvider`
- user content: `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures` (including
  `*.photoslibrary`), `~/Music`, `~/Movies`, `~/.Trash`
- the home folder root, `~/Library` itself, and every allow root itself

**Space-map guard.** The Space map (section 8) is the only feature that acts on items the user
picks by hand, so it adds its own allow set. It is never used by automatic rules. The S4 list
and the main deny entries for Keychains, `~/.ssh` and `~/.gnupg` still apply.

Every denial below covers **the path and everything inside it**, unless the entry says
otherwise (only the home root and the standard folders are denied as folders while their
contents stay allowed).

**No protected contents.** A folder may be trashed only if nothing inside it, at any depth, is
*always protected*: a photo library, an `.app` bundle, a cloud-synced item or sync folder, an
item owned by another user, or a mount point. For example, a folder holding a photo library
can't be trashed as a whole. (The "inside a dot-folder" and "inside a package" denials only stop
picking those inner items one by one. They don't block trashing the parent, so a whole project
folder with its `.git` can still be trashed.) The Space-map scan records this for every folder.
A folder that wasn't fully scanned (permission error, cap reached) can't be trashed.

- **Allow:** items inside the home folder, outside `~/Library`, owned by the user, on the same
  volume as the home folder. Within this set, items inside `~/Documents`, `~/Desktop`,
  `~/Downloads`, `~/Pictures`, `~/Movies` and `~/Music` are allowed, because the user picks
  each item explicitly.
- **Deny:**
  - the home folder root, and the standard folders themselves (`~/Documents`, `~/Desktop` and so
    on), though not items inside them,
  - `~/Library`,
  - every dot-folder directly in the home folder (`~/.Trash`, `~/.ssh`, `~/.aws`, `~/.config`
    and so on),
  - anything inside a dot-folder at any depth (for example a repo's `.git`); the parent folder
    as a whole may still be trashed,
  - anything *inside* a package (`isPackageKey`, for example `.photoslibrary`, `.fcpbundle`,
    `.musiclibrary`, `.imovielibrary`); the whole package may still be trashed, except photo
    libraries, which are always denied,
  - `.app` bundles anywhere: "Use the Uninstaller" (section 10), so its refusals and
    running-app checks apply,
  - cloud-synced items: any item whose `isUbiquitousItemKey` is true (iCloud Drive, including
    Desktop and Documents when iCloud sync is on), and the third-party sync folders `~/Dropbox`,
    `~/Google Drive`, `~/OneDrive`, `~/Box` and `~/pCloud Drive`. Trashing these would delete
    them on every synced device, so the UI says "Remove synced items in Finder".
- **Action-time checks for Space-map items** (instead of S13 b and d): the guard (a), the
  unchanged `fileResourceIdentifier` (e), the open-file snapshot (c), and the same-volume check.

A path that fails the guard is dropped and logged. This is defence in depth: rules SHOULD never
produce it.

### 6.5 Tool command runner

- Find the executable at known absolute paths, in order: `/opt/homebrew/bin`, `/usr/local/bin`,
  `/usr/local/share/dotnet`, `~/.dotnet`, then `/usr/bin`. Never look it up through a shell.
- Run with `Process`, using a fixed argument array (no shell, no string interpolation into
  commands) and a 5-minute timeout. Capture stdout and stderr for the result summary.
- Set `PATH` in the child's environment to the tool's own folder followed by
  `/usr/bin:/bin`, because GUI apps inherit a minimal `PATH` and tools like `npm`, `yarn` and
  `pnpm` start with `#!/usr/bin/env node`.
- `/usr/bin/python3`, `/usr/bin/xcrun` and other `/usr/bin` developer tools are stubs that open
  an install dialog when the Command Line Tools are missing. Call them only if
  `xcode-select -p` succeeds.
- Run only if the tool is found and its cache folder exists. Otherwise hide the category.
- Before and after running, measure the documented cache folder to report the space freed.

---

## 7. Phase 1: Junk and developer caches

### 7.1 Categories

`~` = the user's home folder. "Age" = folder unchanged for at least that long (section 6.2).
Age limits come from Settings (section 4.6). Acceptance criteria use the defaults.
Per S14, each general row excludes the paths claimed by more specific rows.

| ID | Category | What and where | Method | Risk | Extra conditions |
|---|---|---|---|---|---|
| J-CACHE | App caches | Children of `~/Library/Caches` not claimed by another row | Trash | Safe if named by a bundle ID whose app is identified and not running; otherwise Review | Never: `com.apple.*`, `Google` (Chrome live cache), CloudKit, and any name on the protection list (9.3). Children with plain names ("Firefox") can't be checked against running apps, so they are Review |
| J-LOGS | Logs | Children of `~/Library/Logs`, except `DiagnosticReports` | Trash | Safe | Age ≥ logs limit (default 7 days) |
| J-CRASH | Crash reports | `~/Library/Logs/DiagnosticReports` files | Trash | Safe | Age ≥ logs limit (default 7 days) |
| J-TMP | Old temporary files | Children of the user's own temp folder | Trash | Review | Age ≥ temp limit (default 3 days); nothing inside open by the user's processes (S13c); never other users' folders or `/private/var/folders` generally |
| J-NUGET-HTTP | NuGet download cache | `dotnet nuget locals http-cache --clear` | Tool | Safe (not pre-selected, S6) | `dotnet` found |
| J-NUGET-PKG | NuGet packages | `dotnet nuget locals global-packages --clear` | Tool | Review | Warn: "Every project downloads its packages again on next build. Fails if an IDE has projects open." |
| J-NPM | npm cache | `npm cache clean --force` | Tool | Review | |
| J-PNPM | pnpm store | `pnpm store prune` | Tool | Safe (not pre-selected, S6) | |
| J-YARN | Yarn cache | `yarn cache clean` | Tool | Review | |
| J-PIP | pip cache | `python3 -m pip cache purge` | Tool | Review | |
| J-BREW | Homebrew cleanup | `brew cleanup --prune=all` | Tool | Review | Removes old *installed* versions of formulae and casks as well as downloads; label it so. Show `brew cleanup -n` output in the confirmation sheet |
| J-DOCKER | Docker build cache | `docker builder prune -f` and `docker image prune -f` | Tool | Review | Docker running. Never `--volumes` and never `system prune -a` |
| J-XC-DD | Xcode DerivedData | Children of `~/Library/Developer/Xcode/DerivedData` | Trash | Safe | Xcode not running |
| J-XC-SIM | Unavailable simulators | `xcrun simctl delete unavailable` | Tool | Review | Deletes those simulators' data too. Xcode not running; no simulator booted; `xcode-select -p` succeeds |
| J-XC-DS | Old device support | `~/Library/Developer/Xcode/iOS DeviceSupport` children, except the newest 2 | Trash | Review | "Newest" by the OS version parsed from the folder name (numeric compare), not by date. Names like `iPhone15,2 17.0 (21A…)` take the version after the device model. Every folder whose version is among the 2 newest distinct versions is kept, across device models. Folders whose name can't be parsed are kept (S5) |
| J-UNITY | Unity caches | `~/Library/Caches/com.unity3d.*` | Trash | Review | Unity not running |
| J-UNITY-UPM | Unity package cache | `~/Library/Caches/Unity/upm` | — | Info | Manages its own size |
| J-DEVCACHE-DIRS | Tool cache folders | Exactly these children of `~/Library/Caches`: `Homebrew`, `pip`, `pip-tools`, `Yarn`, `yarn`, `pnpm`, `node-gyp`, `NuGetPackages`, `JetBrains` | — | Info | Claimed so J-CACHE never trashes them; cleaned only through their Tool rows. The list lives in `Rules.swift` and grows by explicit additions only |
| J-MAILDL | Mail attachments | Files in `~/Library/Mail Downloads` and in `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | Trash | Review | Age ≥ Mail limit (default 30 days); container path only when FDA is `granted` |
| J-IOSBK | iPhone/iPad backups | `~/Library/Application Support/MobileSync/Backup/*` | — | Info | Show device name, date and size; "Delete in Finder → your device → Manage Backups" |
| J-TRASH | Trash | `~/.Trash` | — | Info | Show size only (D3) |

Developer categories are grouped under **Developer** and hidden when the tool isn't installed.

### 7.2 Acceptance criteria

1. A scan lists every category above that exists on the Mac, with size, risk and reason.
2. Only Safe Trash-method items are pre-selected. No Tool item is pre-selected. Info rows can't
   be selected.
3. **Clean** moves every selected Trash-method item to the Trash, where the user can restore it.
   Items moved through Finder can be restored with Put Back. Tested on macOS 27: items moved
   by `trashItem` have no Put Back, which is why Finder is used (decision D8).
4. A Tool category runs exactly the listed command with fixed arguments, after the
   confirmation sheet showed it.
5. Items owned by a running app are not cleaned. They appear as "Skipped: <App> is running".
6. Without FDA, protected locations appear as "Needs Full Disk Access" rows and the scan
   completes.
7. After a clean, the summary's "moved to the Trash" total equals the sum of the moved items'
   sizes from the scan (±1%). A re-scan no longer lists those items. Space freed by Tool rows is
   the measured cache-folder shrink (6.5).
8. A fixture where `~/Library/Caches/Homebrew` and `com.unity3d.x` exist shows them only under
   their own rows, never in J-CACHE (S14).

---

## 8. Phase 2: Space map

A read-only view of where space goes, to help users find large things the rules don't cover.

- Top-level breakdown of the home folder and `/Applications`, then drill down. Show allocated
  sizes, sorted largest first.
- Label known folders with their owning app (icon and name) using `InstalledApps`. Folders
  named by bundle ID resolve to that app.
- Highlight "large and old": over 1 GB and unchanged for at least 180 days.
- Actions (decision D5):
  - **Reveal in Finder** for everything.
  - **Move to Trash** only for items the user picks one at a time, that are owned by the user,
    and that pass the Space-map guard (6.4). Nothing in the Space map is ever pre-selected or
    selected in bulk.
  - The confirmation names each item with its full path and size.
  - Everything under `~/Library`, and anything else, is Reveal-only.
- Cache the last scan in memory only (S11), and show its age.

**Acceptance:** sizes match `du -kx` (disk usage, one volume) to within 2%; drill-down responds
in under 200 ms from cached data.

### 8.1 Implementation (phase 2)

- `Cleaner/SpaceMap.swift` (AppKit-free): the tree (`SpaceNode`), the scanner and the
  Space-map guard. `SpaceMapModel.swift` and `SpaceMapViews.swift` hold the Disk tab's
  **Space map** view, chosen with the **Junk | Space map** switch in the toolbar.
- **Scan.** One `fts` walk per folder (`FTS_PHYSICAL | FTS_XDEV`), up to 4 folders at a time:
  each child of the home folder and of `~/Library`, and `/Applications`. Sizes are allocated
  blocks of every entry, folders included, with hard links counted once per scan, so they equal
  `du -kx`. The scan thread never downloads cloud ("dataless") files or folders
  (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`); such folders show "In the cloud, not downloaded".
  Without Full Disk Access, `~/Library/Containers` and `~/Library/Group Containers` are not
  entered (see 9.1) and show "Needs Full Disk Access".
- **Memory.** Each folder lists its 100 largest entries; the rest are shown as one "N smaller
  items" row. Folders under 1 MB keep their totals but don't list their contents. Totals and
  protections still count everything.
- **Labels.** An `.app` bundle is labelled with its own name and icon. A folder named by bundle
  ID resolves through `InstalledApps`. Inside `~/Library`, a folder named exactly like an
  installed app belongs to it.
- **Before picking.** Each row shows why it is Reveal only, from what the scan recorded
  (the same rules as the guard). Choosing Move to Trash runs the full guard on the disk first,
  then shows the confirmation with the full path and size.
- **Acting.** The item goes through `Cleaner.clean` as a single item, with the Space-map guard
  in place of the rule roots, the unchanged `fileResourceIdentifier`, the open-file snapshot,
  and a fresh walk that refuses always-protected contents (an app, a photo library, another
  user's item, a mount point), sockets and locked files. Finder's Put Back works as in phase 1.
- **Cache.** The last scan stays in memory until the app quits; its age is shown. After a move,
  the totals of every parent folder are updated without a re-scan.
- **Measured** on a developer Mac (about 1.9 million entries, without Full Disk Access):
  about 6–15 s, peak memory about 130 MB; drill-down reads cached data (well under 1 ms).
  Folder sizes equalled `du -skx` exactly on the 12 folders compared.
- **Known limits.** Cloud sync is checked on the item, its parents and the folders two levels
  below home, not on every file inside a folder. Removing an item doesn't refresh its parents'
  dates or protections until the next scan (which can only make the map more careful).

---

## 9. Phase 3: Leftovers finder

### 9.1 Where to look

**Scanned for orphans** (direct children only, no recursion for matching):

- `~/Library/Application Support`
- `~/Library/Caches`
- `~/Library/Preferences` (`*.plist` files)
- `~/Library/Saved Application State` (`*.savedState`)
- `~/Library/HTTPStorages`
- `~/Library/WebKit`
- `~/Library/Logs`
- `~/Library/Cookies` (`*.binarycookies`)

**Shown as Review only, never pre-selected:**

- `~/Library/Containers`, only when FDA is `granted` (without it, macOS 14+ may show an "access
  data from other apps" prompt instead of failing cleanly; to be tested). Resolved through
  `.com.apple.containermanagerd.metadata.plist`, and only when its `MCMMetadataIdentifier` matches
  the orphaned bundle ID.
- `~/Library/Group Containers`
- `~/Library/Application Scripts`
- `~/Library/LaunchAgents`

**Info only (needs admin):** `/Library/LaunchAgents`, `/Library/LaunchDaemons`,
`/Library/PrivilegedHelperTools` and `/Library/Application Support`.

Rationale: two open-source tools disagree here. Pearcleaner includes containers and launch
agents; Mole refuses them ("NEVER add Containers/", "NEVER add LaunchAgents…"). This spec
takes Mole's stricter position for automatic selection and Pearcleaner's coverage for display.

### 9.2 Installed-app inventory

An app counts as **installed** if *any* of the following finds it. A failing or timed-out probe
counts as installed (S5).

1. `NSWorkspace.urlsForApplications(withBundleIdentifier:)` returns at least one URL.
2. Spotlight (`NSMetadataQuery`, `kMDItemCFBundleIdentifier == id`, 5-second limit) finds it.
3. Its bundle is found in a scanned folder:
   - `/Applications` and `~/Applications` (recursive, depth 3),
   - `/System/Applications`,
   - Homebrew Caskroom (`/opt/homebrew/Caskroom`, `/usr/local/Caskroom`),
   - `~/Library/Application Support/Setapp/Applications`.
4. It is running (`NSWorkspace.runningApplications`).
5. Any `*.plist` label in `~/Library/LaunchAgents`, `/Library/LaunchAgents` or
   `/Library/LaunchDaemons` equals or starts with its bundle ID.

6. Its ID is an *embedded* bundle of a found app: everything under `Contents/PlugIns`,
   `Contents/Library/LoginItems`, `Contents/Helpers`, `Contents/Frameworks/*.app`,
   `Contents/XPCServices` and `Contents/Library/LaunchServices`.
7. It is a non-app bundle in a plug-in folder: `~/Library` and `/Library` subfolders `Audio/Plug-Ins/*`,
   `PreferencePanes`, `QuickLook`, `Spotlight`, `Input Methods`, `Screen Savers`, `Services`,
   `Internet Plug-Ins`, `Extensions`.

**Matching IDs.** IDs are compared without case. A candidate ID counts as installed if it
*equals* an installed ID or *starts with* an installed ID followed by a dot (so
`com.vendor.app.FinderSync` and `com.vendor.app.widget` belong to `com.vendor.app`).

**Shared vendors.** If any installed app shares the candidate's vendor prefix (the first two
components, for example `com.vendor`), the candidate is downgraded to Low confidence.

**Limits.** Apps on unplugged external drives or run from unusual folders may be missed by
probes 3–7. Probe 1 usually still finds them, because LaunchServices remembers registered apps.
This is a residual risk. It is why every leftover is Review and never pre-selected.

Probe 1 matters for apps installed outside the usual folders (for example web-deployed apps
that live inside Application Support). Such an app's own folder MUST never be flagged.

### 9.3 Matching and orphan decision

**Candidate key.** A folder or file name is turned into a candidate key:

- `com.vendor.app`, `com.vendor.app.plist` and `com.vendor.app.savedState` become `com.vendor.app`.
- A reverse-DNS name (at least 2 dots, first component a known top-level domain such as `com`,
  `org`, `net`, `io`, `app`, `dev`, `co` or any 2-letter country code like `de` or `uk`) is a
  **bundle-ID candidate**.
- `group.<id>` and `<TEAMID>.<id>` (a 10-character team ID) names reduce to `<id>` for matching,
  but stay Review only (9.1).
- Anything else is a **name candidate** (for example `Spotify`).

**High confidence.** An item is reported as a High-confidence leftover only if all of the
following hold:

1. It is a bundle-ID candidate whose ID, and whose base ID, belong to no installed app (9.2).
   - The base ID is the ID with a trailing `helper`, `agent`, `daemon`, `xpc`, `updater`,
     `launcher`, `loginitem`, `findersync`, `widget`, `shareextension`, `extension` or
     `intents` component removed (compared without case).
   - Name candidates are never reported as High confidence (see below).
2. It is not protected. Protection entries match the key without case, either as an exact
   key, a prefix (entries ending in `.*`), or a whole name component. Plain substring matching is
   used only for the `apple` entry.
   - Apple: `com.apple.*`, anything containing `apple`, and the Apple folder names in the 6.4
     deny list (MobileSync, AddressBook, CallHistoryDB, Knowledge, FileProvider and similar).
   - System: `org.cups.*`, `loginwindow`, `dock`, `finder`, `systemuiserver`.
   - Vendor namespaces: `com.microsoft.*`, `com.google.*`, `org.mozilla.*`,
     `com.jetbrains.*`/`JetBrains`, `com.docker.*`.
   - Password managers and security: 1Password, Bitwarden, LastPass, KeePass, Dashlane,
     `gpg`, `ssh`, `keychain`.
   - Developer tools: Homebrew, `python`, `pip`, `node`, `npm`, `Code` (VS Code), `swiftpm`,
     `CoreSimulator`.
   - The user's own ignore list.

   **Licensing:** the bundled list MUST be written independently for this project.
   - Pearcleaner is Apache 2.0 with the Commons Clause (no selling), and Mole is GPL-3.0.
   - Neither's code or lists may be copied into this MIT project.
   - They may be read as references for which kinds of names need protecting.
3. It is unchanged for at least the leftovers age limit (default 30 days, section 4.6).
4. It is not the App Monitor app itself.
5. No installed app's name or display name equals (without case) a whole dot-separated
   component of the key. The name is compared as one string with spaces removed, and is never
   split (so "Visual Studio Code" is compared as `visualstudiocode`). Selftest cases cover names
   with spaces, dots and hyphens.

**Low confidence.** A name candidate is reported as Low confidence only if all of the following
hold:

1. Its name is at least 5 characters long.
2. It is not protected (condition 2 above).
3. Its name doesn't equal (without case) the name, display name or executable name of any
   installed app (9.2).
4. Positive evidence: its name equals the app name (`CFBundleName` from a leftover preferences
   plist or saved state) of a High-confidence group.
5. It is unchanged for at least the Low-confidence age limit (default 90 days, section 4.6).

A bundle-ID candidate downgraded by the shared-vendor rule (9.2) is also Low.

**Confidence**

| | When | Risk |
|---|---|---|
| **High** | All High-confidence conditions above hold | Review (never Safe, never pre-selected) |
| **Low** | The Low-confidence conditions above | Review, shown collapsed under "Possible leftovers, check before removing" |

**Grouping.** Items with the same base ID group into one entry ("Spotify, 4 items, 1.2 GB"),
showing the app's last-known name from the plist's `CFBundleName` when available, otherwise
the key.

### 9.4 Acceptance criteria

1. With a fixture app installed in `/Applications`, none of its folders are reported.
2. With the same fixture app installed under `~/Library/Application Support/X/App.app` (outside
   the usual folders), none of its folders are reported.
3. With the fixture app deleted and its data at least 30 days old, its Application Support,
   Caches, Preferences and Saved Application State items are reported as one High-confidence
   group.
4. If its data is newer than 30 days, it is not reported.
5. No `com.apple.*` item, no Group Container and no LaunchAgent is ever pre-selected.
6. If Spotlight is disabled or times out, the scan completes and no item is reported only
   because Spotlight couldn't find its app.

---

## 10. Phase 4: Uninstaller

The uninstaller has its **own matching rules**. The leftover rules don't apply, because "belongs
to no installed app" and the 30-day age limit would exclude the target app's own data.

- Drop an `.app` onto the Disk tab, or pick an installed app from a list.
- **Target ID set:** the app's bundle ID plus every embedded bundle ID (9.2, probe 6).
- **Related items** (keys compared without case; "dot-prefix" means equal to the ID, or starting
  with the ID followed by a dot):
  - children of the 9.1 locations, except `~/Library/LaunchAgents`, whose key dot-prefix-matches
    a target ID,
  - `~/Library/Containers` entries whose metadata identifier is a target ID (FDA `granted` only),
  - Group Containers listed in the app's `com.apple.security.application-groups` entitlement,
    **unless another installed app's entitlement also claims that group** (then shown as Info:
    "Shared with <App>"),
  - `~/Library/LaunchAgents` plists whose label dot-prefix-matches a target ID.
- **Other installed apps win.** An item is dropped if its key equals, or dot-prefix-matches, the
  ID of any *other* installed app (or that app's embedded bundles), and the longest matching ID
  decides the owner. So with `com.vendor.app` and `com.vendor.app.pro` both installed, removing
  `com.vendor.app` never touches `com.vendor.app.pro` data.
- **No nested apps.** A related item that contains an app bundle belonging to another app (found
  by 9.2 probes 1–3 or by scanning the item for `*.app`, depth 3) is shown as Info ("Contains
  <App>") and never moved.
- **Risk per item kind:**

  | Kind | Risk | Pre-selected |
  |---|---|---|
  | App bundle | Requested (the user chose this app) | yes |
  | Caches, Logs, Saved Application State, HTTPStorages, WebKit | Safe | yes |
  | Preferences, Application Support, Cookies | Review | yes, because the user asked to uninstall this app; shown with "contains your settings and data" |
  | Containers, Group Containers, Application Scripts, LaunchAgents | Review | no |
- **Before trashing:**
  - The app and all its helpers MUST NOT be running. Check running processes by bundle ID and by
    executable path inside the bundle, and offer Quit.
  - If `urlsForApplications(withBundleIdentifier:)` returns other copies of the app, warn and
    move only the related files the user keeps selected.
- The app bundle goes to the Trash together with the related items. The bundle passes the path
  guard through the uninstaller-only `/Applications` and `~/Applications` roots.
- **Refuse**, with the reason shown:
  - any app whose bundle ID starts with `com.apple.`, wherever it is (Safari lives in
    `/Applications`),
  - apps in `/System/Applications`,
  - bundles not writable by the user (for example root-owned App Store apps),
  - App Monitor itself,
  - apps outside `/Applications` and `~/Applications` (for example web-deployed apps inside
    Application Support, or Setapp apps): "Use the app's own uninstaller".

**Acceptance:** dropping a fixture app lists its bundle plus all its fixture data (including
data newer than 30 days), and trashing it moves everything to the Trash. A fixture group
container also claimed by a second installed fixture app is shown as shared and not moved.
With fixture apps `com.vendor.app` and `com.vendor.app.pro` both installed, uninstalling
`com.vendor.app` lists none of `com.vendor.app.pro`'s files.

## 11. Phase 5: Stable code signing

**Problem.** An ad-hoc signature's designated requirement is a build hash
(`designated => cdhash H"…"`), so macOS treats each build as a different app and FDA is lost on
update.

**Options** (decision D1: self-signed first, Developer ID if that fails):

| Option | Cost | FDA survives updates | Removes Gatekeeper "Open Anyway" |
|---|---|---|---|
| Apple Developer ID + notarization | $99/year | yes (Apple's recommendation) | yes |
| Self-signed certificate kept by the maintainer | free | probably; must be tested | no |
| Stay ad-hoc | free | no | no |

**Plan (decision D1):**

1. Create a self-signed code-signing certificate, "App Monitor Signing", in the maintainer's
   keychain. It is never committed to the repo.
2. `build.sh` signs with that identity when `APPMON_SIGN_IDENTITY` is set, and falls back to
   ad-hoc (`codesign -s -`) otherwise, so contributors can still build. A release build
   (`APPMON_RELEASE=1`, used by the release script) fails if `APPMON_SIGN_IDENTITY` isn't set.
3. Run the acceptance test below on macOS 14 and 15.
4. If Full Disk Access does not survive an update, switch to an Apple Developer ID
   (`--options runtime --timestamp` plus notarization) before phase 3 ships.

Note: release builds must always be signed with the same certificate. Users who build from
source sign with their own identity, or ad-hoc.

**Acceptance** for the chosen option: after granting FDA to build N, installing build N+1
keeps FDA granted (checked with the section 3.1 detection), and `codesign -d -r-` shows a
requirement based on identifier and certificate, not a cdhash.

---

## 12. Delivery plan

| Phase | Ships | Depends on | Size |
|---|---|---|---|
| 1 | Disk tab, engine, permissions, path guard, `InstalledApps` and key parsing, Junk categories | — | Large |
| 2 | Space map | 1 (engine) | Medium |
| 3 | Leftovers finder | 1 (engine, `InstalledApps`), 5 for practical FDA | Large |
| 4 | Uninstaller | 3 (matcher) | Medium |
| 5 | Stable signing | D1 | Small (once decided) |

Each phase is a separate branch, review and release.

---

## 13. Verification

The repo has no automated tests today.

- **Rules and matcher unit checks.** `scripts/selftest.sh` compiles the AppKit-free logic files
  with a test `main` and runs pure-logic checks: candidate-key parsing (including `group.`,
  team-ID and country prefixes), base-ID stripping, prefix and case matching, the protection
  list, the path guard (component and case rules, `/private` handling, symlinked parents), rule
  precedence (S14), and the confidence rules. It exits non-zero on failure.
- **Fixture scans.** `scripts/make-fixtures.sh` builds a throw-away tree at
  `/tmp/appmon-fixture-<random>` (outside the user's temp folder, so real J-TMP scans never list
  it), with fake apps and data dated with `touch -t`. The scanner runs against it with a root
  override, `APPMON_SCAN_ROOT`, compiled in only with `-D APPMON_DEBUG`. In fixture mode:
  - **Separate mapped roots.** `~` maps to `<root>/home`, the temp folder to `<root>/tmp`,
    `/Applications` to `<root>/Applications` and `/Library` to `<root>/Library`. The 6.4 allow and
    deny lists use the mapped roots, so the guard treats fixture paths exactly like real ones.
  - **Refuse unsafe roots.** The app refuses to start fixture mode unless the canonical root is
    under `/private/tmp/appmon-fixture-`.
  - **Fixture-only inventory.** Installed-app probes use only the fixture tree. LaunchServices,
    Spotlight, running apps and Caskroom are not consulted, so real apps never affect results.
  - **Dry run by default.** Fixture mode implies `APPMON_DRY_RUN=1` unless `APPMON_FIXTURE_ACT=1`
    is also set. A dry run prints planned actions as JSON for comparison with a golden file.
- **Dry run.** `APPMON_DRY_RUN=1` makes Actions log instead of acting. All manual testing starts
  here.
- **Manual checklist** per phase: covers the FDA granted, denied and unknown states, running-app
  skip, an app started between scan and clean (S13), Put Back behaviour on macOS 14 and 15,
  missing tools and missing Command Line Tools.
- **Demo mode** gains made-up Disk results, so README screenshots never show real paths.
- **Space map** (phase 2): `scripts/selftest.sh` checks the Space-map guard rules and its disk
  checks, sizes against `du -kx`, hard links, listing limits, roll-up of totals and
  protections, and one-item clean dry runs. `scripts/fixture-test.sh` adds a Space-map scan of the
  fixture tree (`--space-json`, sizes against `du -kx`, labels, Reveal-only reasons) and a
  one-item dry run and act (`--space-trash`), including an item kept open.

---

## 14. Decisions

Decided by the project owner.

| ID | Question | Decision |
|---|---|---|
| D1 | Signing: Developer ID ($99/yr), self-signed, or stay ad-hoc? | Self-signed certificate first. Switch to Developer ID before phase 3 ships if Full Disk Access doesn't survive updates (section 11). |
| D2 | Run tool commands (permanent) from the app, or only show them? | Run them, with the S3 safeguards. Also offer "Copy command". |
| D3 | Offer "Empty Trash" in the app after cleaning? | No. Show the size and an Open Trash button. Emptying stays a Finder action. |
| D4 | Cleaner placement? | Tab in the same window (section 4.1). |
| D5 | Allow Move to Trash from the Space map? | Yes, for user-owned items inside the home folder and outside `~/Library`, picked one at a time, within the Space-map guard (sections 6.4 and 8). |
| D6 | Age limits user-adjustable? | Yes, in a Settings window with safe minimums (section 4.6). |
| D7 | Include Low-confidence (name-based) leftovers? | Yes, only with the positive evidence in 9.3, collapsed and never pre-selected. |
| D8 | Items moved by `trashItem` showed no Put Back. Use Finder instead? | Yes. Move items through Finder so Put Back works; macOS asks once for Automation access. Fall back to `trashItem` (no Put Back) if that's refused. |

## 15. Known gaps

- Apple doesn't document which folders FDA protects, or the System Settings deep link. Both
  need re-testing on each macOS release.
- No public API detects APFS clones or purgeable space, so reclaimable sizes are upper bounds.
- To be tested before relying on them:
  - Put Back for Finder-moved items on macOS 14 and 15 (verified on macOS 27 only),
  - whether an FDA check adds the app to the Settings list,
  - how macOS 14+ reacts to reading other apps' containers without FDA.
- Not verified:
  - whether a self-signed certificate keeps FDA across builds,
  - Steam cache locations,
  - old iOS update file locations,
  - Apple documentation for Xcode DerivedData and DeviceSupport (the rules follow Mole's
    behaviour).
- Some apps keep data under unrelated names. These can't be attributed, so they are left
  alone (by design).

---

## 16. Sources

Each source was opened during research and checked to support the claim it is cited for.

- Apple, File System Programming Guide, macOS library directories:
  https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html
- Apple, File System Programming Guide, Caches may be deleted:
  https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html
- Apple, `NSWorkspace.urlsForApplications(withBundleIdentifier:)`:
  https://developer.apple.com/tutorials/data/documentation/appkit/nsworkspace/urlsforapplications(withbundleidentifier:).json
- Apple, `FileManager.trashItem`:
  https://developer.apple.com/tutorials/data/documentation/foundation/filemanager/trashitem(at:resultingitemurl:).json
- Apple, `totalFileAllocatedSizeKey`:
  https://developer.apple.com/tutorials/data/documentation/foundation/urlresourcekey/totalfileallocatedsizekey.json
- Apple, `fileResourceIdentifierKey`:
  https://developer.apple.com/tutorials/data/documentation/foundation/urlresourcekey/fileresourceidentifierkey.json
- Apple, About Apple File System (clones):
  https://developer.apple.com/tutorials/data/documentation/foundation/about-apple-file-system.json
- Apple, TN3127 Inside Code Signing: Requirements:
  https://developer.apple.com/tutorials/data/documentation/technotes/tn3127-inside-code-signing-requirements.json
- Apple Developer Forums (DTS) on TCC and file-system protection: https://developer.apple.com/forums/thread/678819
- Apple Developer Forums (DTS) on ad-hoc signing and TCC: https://developer.apple.com/forums/thread/795739
- Apple Developer Forums on temp-folder cleanup: https://developer.apple.com/forums/thread/71382
- Apple Support, System Integrity Protection: https://support.apple.com/en-us/102149
- Apple Support, iPhone backups: https://support.apple.com/en-us/108809
- Pearcleaner (Apache 2.0 with Commons Clause; reference only, see 9.3):
  - locations: https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Logic/Locations.swift
  - orphan logic: https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Logic/ReversePathsFetch.swift
  - exclusions: https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Logic/Conditions.swift
  - FDA check: https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Views/Components/PermissionsSheetView.swift
- Mole (GPL-3.0; reference only):
  - app-data rules: https://raw.githubusercontent.com/tw93/Mole/main/lib/clean/apps.sh
  - developer caches: https://raw.githubusercontent.com/tw93/Mole/main/lib/clean/dev.sh
- FullDiskAccess Swift package: https://github.com/inket/FullDiskAccess
- Microsoft, managing the NuGet cache: https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-nuget-cache
- npm cache: https://docs.npmjs.com/cli/v10/commands/npm-cache
- pnpm store: https://pnpm.io/cli/store
- pip cache: https://pip.pypa.io/en/stable/cli/pip_cache/
- Homebrew manpage: https://docs.brew.sh/Manpage
- Docker system prune: https://docs.docker.com/reference/cli/docker/system/prune/
- Unity UPM cache: https://docs.unity.com/en-us/engine/current/manual/packages-list/package-manager-caches/upm-cache

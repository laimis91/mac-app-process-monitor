// Actions (spec 2 S2, S3, S8, S13 and 6.5): the Trash mover, running tool commands and the
// action-time re-checks. The probes they use (tool runner, open files, processes) are in
// Probes.swift. Foundation and Darwin only.

import Foundation

/// Finds an item in the user's Trash after a move whose outcome is unclear (Finder reported an
/// error but the item is gone). Only the same file counts: same device and inode as before the
/// move, under its own name or a name Finder made unique ("name 2", "name 10.32.16.ext").
enum TrashLookup {
    /// Names in `trash` that could be `name` after a move, the plain name first.
    static func candidates(_ name: String, in names: [String]) -> [String] {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let tail = ext.isEmpty ? "" : "." + ext
        let more = names.filter { n in
            n != name && (n.hasPrefix(name + " ")
                          || (n.hasPrefix(stem + " ") && n.hasSuffix(tail) && n.count > stem.count + 1 + tail.count))
        }
        return [name] + more.sorted()
    }

    /// True if the file with `fileID` sits directly in `trash` under a likely name.
    static func found(_ name: String, fileID: [UInt64], trash: String) -> Bool {
        found(name, fileID: fileID, trash: trash, listed: listing(trash))
    }

    /// `listed`: the Trash's names, read once for a batch (`listing`).
    static func found(_ name: String, fileID: [UInt64], trash: String, listed: [String]) -> Bool {
        guard fileID.count == 2 else { return false }
        return candidates(name, in: listed).contains { ScanEngine.fileID(trash + "/" + $0) == fileID }
    }

    /// The names in the Trash. May be refused (no Full Disk Access): then only the plain name is tried.
    static func listing(_ trash: String) -> [String] {
        if case .ok(let names) = ScanEngine.children(trash) { return names }
        return []
    }
}

// MARK: - Cleaning

struct Outcome: Codable {
    enum Status: String, Codable { case moved, ran, skipped, failed, planned }
    let path: String
    let name: String
    let category: String
    let status: Status
    var reason: String? = nil
    var size: Int64 = 0              // scan size of a moved item, or measured shrink for a tool
    var command: [String]? = nil
    var output: String? = nil
}

/// How one item ended up after a move to the Trash.
enum TrashResult: Equatable {
    case moved(putBack: Bool)        // putBack: Finder moved it, so Finder's Put Back works
    case movedDespiteError           // Finder reported an error, but the same file is now in the Trash
    case movedUnverified             // it left its place, but the same file wasn't found in the Trash
    case skipped(String)             // its quick checks failed right before the move: never handed over
    case failed(String)              // this item failed; others in the batch may still work
    case failedAll(String)           // the move failed as a whole (Finder hung, quit, cancelled): don't retry
}

/// One item for a Trash mover. The mover runs `recheck` (path guard and identity, S13a and e)
/// right before it hands this item over, and leaves the item out if that returns a reason.
struct TrashItem {
    let path: String
    let fileID: [UInt64]            // [device, inode] the checks confirmed
    var recheck: () -> String? = { nil }
}

typealias TrashMover = ([TrashItem]) -> [String: TrashResult]

struct CleanEnvironment {
    let guardian: PathGuard
    let runningNow: () -> [RunningApp]
    let inventory: AppInventory
    let roots: Roots
    let dryRun: Bool
    let now: () -> Date
    /// Picks the mover for this clean, before any item is checked. In the app this settles the
    /// "control Finder" permission first (it may wait for the user), then returns Finder's mover,
    /// or the FileManager mover (no Put Back) if Finder can't be used.
    var prepareTrash: () -> TrashMover = { Cleaner.trashWithFileManager }
    /// Items per Finder request. Small, so the full checks of a batch's first item stay recent.
    var batchSize = 25
    /// Checks items picked in the Space map instead of the rule-based path guard (6.4).
    var spaceGuard: SpaceGuard? = nil
    /// Processes running from inside a folder (the uninstaller's app bundle, spec 10).
    var processesInside: (String) -> [String] = ProcessList.inside
}

enum Cleaner {
    /// Acts on the selected items. Each item is re-checked first (S13); a failure only skips
    /// that item (S8). Trash items go to the Trash (S2); tool rows run their own command (S3).
    static func clean(_ selected: [(Category, CleanItem)], env: CleanEnvironment,
                      progress: (String) -> Void = { _ in }) -> [Outcome] {
        var out: [Outcome] = []
        var pending: [(Category, CleanItem)] = []   // checked items waiting to be moved together
        // Settle how items are moved before checking any of them, so no check waits on a prompt.
        let needsTrash = !env.dryRun && selected.contains { $0.1.method == .trash && $0.1.selectable }
        let trash = needsTrash ? env.prepareTrash() : Cleaner.trashWithFileManager
        var snapshotTaken = false             // taken once, only if needed
        var openFiles: OpenFiles? = nil
        var stopped: String? = nil            // set by the first whole-request failure: no more Finder requests

        /// Moves the waiting items, after the quick checks once more, right before acting.
        func flush() {
            guard !pending.isEmpty else { return }
            var ready: [(Category, CleanItem)] = []
            for (cat, item) in pending {
                if let why = lastChecks(item, env) {
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped, reason: why))
                } else {
                    ready.append((cat, item))
                }
            }
            pending = []
            guard !ready.isEmpty else { return }
            var results: [String: TrashResult] = [:]
            // The mover runs the quick location checks again for each item right before handing it over.
            func request(_ item: CleanItem) -> TrashItem {
                TrashItem(path: item.path, fileID: item.fileID, recheck: { locationChecks(item, env) })
            }
            if let why = stopped {
                for (_, item) in ready { results[item.path] = .failedAll(why) }
            } else {
                results = trash(ready.map { request($0.1) })
                stopped = wholeFailure(results)
            }
            if ready.count > 1 {
                // One item Finder couldn't move must not fail the rest: retry those one by one,
                // each re-checked right before. A whole-request failure stops all further requests.
                for (_, item) in ready {
                    guard case .failed? = results[item.path], ScanEngine.fileID(item.path) == item.fileID else { continue }
                    if let why = stopped { results[item.path] = .failedAll(why); continue }
                    if let why = lastChecks(item, env) { results[item.path] = .failed(why); continue }
                    let r = trash([request(item)])[item.path] ?? .failed("No answer")
                    results[item.path] = r
                    stopped = wholeFailure([item.path: r])
                }
            }
            for (cat, item) in ready {
                switch results[item.path] ?? .failed("No answer") {
                case .moved(let putBack):
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .moved,
                                       reason: putBack ? nil : "Moved without Put Back", size: item.size))
                case .movedDespiteError:
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .moved,
                                       reason: "Finder reported an error but moved it; Put Back may not work", size: item.size))
                case .movedUnverified:
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .moved,
                                       reason: Cleaner.notFoundInTrash, size: item.size))
                case .skipped(let why):
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped, reason: why))
                case .failed(let why), .failedAll(let why):
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .failed, reason: why))
                }
            }
        }

        for (cat, item) in selected {
            progress(item.name)
            func skip(_ why: String) {
                out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped, reason: why))
            }
            guard item.selectable else { skip("Can't be selected"); continue }
            if let app = env.inventory.runningOwner(item.owners, names: item.ownerNames, snapshot: env.runningNow()) {
                skip("\(app) is running"); continue
            }

            if item.method == .tool {
                guard let tool = cat.tool else { skip("No command"); continue }
                out.append(runTool(cat, item, tool, env))
                continue
            }
            guard item.method == .trash else { skip("Can't be cleaned"); continue }
            if let why = stopped {
                out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .failed, reason: why))
                continue
            }
            // (a) and (e) before the slow checks too, so nothing outside its guard is walked;
            // they run again right before acting.
            if let why = locationChecks(item, env) { skip(why); continue }

            // Slow checks first: (d) age limit, readability and sockets, then (c) open files.
            do {
                let m = ScanEngine.measure(item.path, links: nil, inspect: item.spaceMap || item.inspect,
                                           synced: item.spaceMap ? env.spaceGuard?.isSynced : nil,
                                           strictApps: item.inspect && !item.spaceMap)
                if let why = m.protected { skip(why); continue }
                guard m.complete else { skip("Part of it can't be read"); continue }
                guard !m.special else { skip("Contains a socket or pipe an app may be using"); continue }
                guard !m.locked else { skip("Contains a locked file"); continue }
                if let st = ScanEngine.lstatInfo(item.path), !userCanMove(item.path, st) {
                    skip("Needs administrator rights. Remove it in Finder."); continue
                }
                if let limit = item.ageLimitDays {
                    guard let d = days(since: m.newest, now: env.now()), d >= limit else { skip("Changed recently"); continue }
                }
            }
            if item.checkOpenFiles {
                if !snapshotTaken { openFiles = OpenFiles.snapshot(); snapshotTaken = true }
                guard let s = openFiles else { skip("Couldn't check for open files"); continue }
                if let who = s.user(of: item.path) { skip("In use by \(who)"); continue }
            }
            if env.dryRun {
                if let why = lastChecks(item, env) { skip(why); continue }
                out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .planned,
                                   reason: "Move to Trash", size: item.size))
                continue
            }
            pending.append((cat, item))
            if pending.count >= env.batchSize { flush() }
        }
        flush()
        return out
    }

    /// The reason of the first whole-request failure in a set of results, if any.
    static func wholeFailure(_ results: [String: TrashResult]) -> String? {
        for r in results.values { if case .failedAll(let why) = r { return why } }
        return nil
    }

    /// The user can move this item: they own it, can write to its folder, and (for a folder) to
    /// the folder itself, which moving it to another parent needs.
    static func userCanMove(_ path: String, _ st: stat) -> Bool {
        guard st.st_uid == getuid() else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard access(parent, W_OK) == 0 else { return false }
        if (st.st_mode & S_IFMT) == S_IFDIR && access(path, W_OK) != 0 { return false }
        return true
    }

    /// The quick checks, run right before acting: (b) owner not running, (a) path guard, (e) same item.
    /// Space-map items use the Space-map guard, which also checks the volume (6.4).
    static func lastChecks(_ item: CleanItem, _ env: CleanEnvironment) -> String? {
        if let app = env.inventory.runningOwner(item.owners, names: item.ownerNames, snapshot: env.runningNow()) {
            return "\(app) is running"
        }
        if let why = locationChecks(item, env) { return why }
        // Uninstaller items: no process may run from inside the app's bundle, whatever its bundle ID (spec 10).
        if let b = item.insideBundle, let who = env.processesInside(b).first { return "\(who) is running from inside the app" }
        return nil
    }

    /// (a) the guard the item's scope names, and (e) the same item as at scan time.
    static func locationChecks(_ item: CleanItem, _ env: CleanEnvironment) -> String? {
        if let why = guardCheck(item, env) { return why }
        if ScanEngine.fileID(item.path) != item.fileID { return "Changed since the scan" }
        return nil
    }

    /// The one guard for the item's scope. Tool and info rows have none, so they are never moved.
    static func guardCheck(_ item: CleanItem, _ env: CleanEnvironment) -> String? {
        switch item.scope {
        case .spaceMap:
            guard let g = env.spaceGuard else { return "No Space-map guard" }
            return g.check(item.path)
        case .rule(let root):
            guard !root.isEmpty else { return "No rule folder for this item" }
            return env.guardian.check(item.path, allowRoot: root)
        case .appBundle(let root):
            guard !root.isEmpty else { return "No app folder for this item" }
            return env.guardian.check(item.path, allowRoot: root, appBundle: true)
        case .none:
            return "Nothing may be moved from this row"
        }
    }

    static let notFoundInTrash = "Moved, but not found in the Trash: check it"

    /// Why nothing was moved when Finder didn't answer a quick question before the clean.
    static let finderNotResponding = "Finder isn't responding, so nothing was moved. Relaunch Finder (Option-right-click it in the Dock, then choose Relaunch) and try again"

    /// The mover used when Finder is busy with something else: it hands nothing over, so no
    /// request waits behind Finder's queue (and none is acted on later, after the clean ended).
    static func finderBusy(_ items: [TrashItem]) -> [String: TrashResult] {
        Dictionary(items.map { ($0.path, TrashResult.failedAll(finderNotResponding)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Fallback mover: works without Finder, but macOS doesn't record where items came from,
    /// so Finder's Put Back isn't offered for them. Each item is re-checked, and its folder
    /// opened without following any symlink, right before it is moved.
    static func trashWithFileManager(_ items: [TrashItem]) -> [String: TrashResult] {
        var r: [String: TrashResult] = [:]
        for it in items {
            let p = it.path
            if let why = it.recheck() { r[p] = .skipped(why); continue }
            guard sameItemInFolder(it) else { r[p] = .skipped("Changed since the scan"); continue }
            do {
                var moved: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &moved)
                let there = moved?.path.flatMap(ScanEngine.fileID) == it.fileID
                r[p] = there ? .moved(putBack: false) : .movedUnverified
            } catch {
                r[p] = .failed((error as NSError).localizedDescription)
            }
        }
        return r
    }

    /// True if the item's folder, opened without following a symlink anywhere on its path, is the
    /// folder at that path now, and the entry in it is still the checked item (same device and inode).
    static func sameItemInFolder(_ it: TrashItem) -> Bool {
        let url = URL(fileURLWithPath: it.path)
        let parent = url.deletingLastPathComponent().path
        guard it.fileID.count == 2, let want = ScanEngine.fileID(parent) else { return false }
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var ps = stat(), st = stat()
        guard fstat(fd, &ps) == 0, [UInt64(bitPattern: Int64(ps.st_dev)), UInt64(ps.st_ino)] == want,
              fstatat(fd, url.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return [UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino)] == it.fileID
    }

    static func runTool(_ cat: Category, _ item: CleanItem, _ tool: ToolCommand, _ env: CleanEnvironment) -> Outcome {
        let cmds = tool.commands.map { [tool.tool] + $0 }
        guard let exe = tool.executable, let place = tool.place else {
            return Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped,
                           reason: "\(tool.tool) not found", command: cmds.map { $0.joined(separator: " ") })
        }
        // The lookup's checks again, right before it runs (spec 6.5).
        if let why = ToolTrust.refusal(exe, place: place) {
            return Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped,
                           reason: "Not run: \(why)", command: cmds.map { $0.joined(separator: " ") })
        }
        if env.dryRun {
            return Outcome(path: item.path, name: item.name, category: cat.id, status: .planned,
                           reason: "Run command", command: cmds.map { ([exe] + $0.dropFirst()).joined(separator: " ") })
        }
        if cat.id == "J-XC-SIM" {
            let booted = ToolRunner.run(exe, ["simctl", "list", "devices", "booted"], timeout: 30)
            if booted.status != 0 || booted.output.contains("(Booted)") {
                return Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped,
                               reason: "A simulator is running", command: cmds.map { $0.joined(separator: " ") })
            }
        }
        let measured = !item.sizeUnknown && item.measurePath != nil
        let target = item.measurePath ?? ""
        let before = measured ? ScanEngine.measure(target, links: nil).size : 0
        var log = ""
        var failed = false
        for args in tool.commands {
            let r = ToolRunner.run(exe, args)
            log += "$ \(tool.tool) \(args.joined(separator: " "))\n\(r.output)\n"
            if r.status != 0 { failed = true; log += r.timedOut ? "Stopped after 5 minutes.\n" : "Exit code \(r.status)\n"; break }
        }
        let after = measured ? ScanEngine.measure(target, links: nil).size : 0
        return Outcome(path: item.path, name: item.name, category: cat.id, status: failed ? .failed : .ran,
                       reason: failed ? "The command reported an error" : nil, size: max(0, before - after),
                       command: cmds.map { $0.joined(separator: " ") }, output: String(log.suffix(4000)))
    }
}

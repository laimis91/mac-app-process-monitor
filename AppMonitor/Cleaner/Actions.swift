// Actions (spec 2 S2, S3, S8, S13 and 6.5): the Trash mover, the tool-command runner and the
// action-time re-checks. Foundation and Darwin only.

import Foundation

// MARK: - Tool lookup and runner

struct ToolLocator {
    let dirs: [String]
    let xcodeSelectOK: Bool

    /// The tool at a known absolute path. Never looked up through a shell or PATH.
    func find(_ tool: String) -> String? {
        for d in dirs {
            let candidates = tool == "dotnet" ? [d + "/dotnet"] : [d + "/" + tool]
            for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
                // /usr/bin developer tools are stubs that open an install dialog without the CLT.
                if d == "/usr/bin" && !xcodeSelectOK { return nil }
                return p
            }
        }
        return nil
    }

    static func commandLineToolsInstalled() -> Bool {
        ToolRunner.run("/usr/bin/xcode-select", ["-p"], timeout: 10).status == 0
    }
}

enum ToolRunner {
    struct Result { let status: Int32; let output: String; let timedOut: Bool }

    /// Runs `exe` with a fixed argument list: no shell, nothing interpolated.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 300) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = URL(fileURLWithPath: exe).deletingLastPathComponent().path + ":/usr/bin:/bin"
        env["NO_COLOR"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var data = Data()
        let lock = NSLock()
        let eof = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; eof.signal(); return }
            lock.lock(); if data.count < 200_000 { data.append(d) }; lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }     // set before run(), so a fast exit isn't missed
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, output: "Couldn't start \(exe): \(error.localizedDescription)", timedOut: false)
        }
        var timedOut = false
        var exited = true
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited = done.wait(timeout: .now() + 5) == .success
            }
        }
        // A child the tool left running may keep the pipe open: wait for the end of output briefly, never forever.
        if eof.wait(timeout: .now() + 2) == .timedOut { pipe.fileHandleForReading.readabilityHandler = nil }
        lock.lock(); let text = String(decoding: data, as: UTF8.self); lock.unlock()
        return Result(status: timedOut || !exited ? -2 : p.terminationStatus, output: text, timedOut: timedOut)
    }
}

// MARK: - Open-file snapshot (S13c)

/// Paths the current user's processes have open, as working folder or mapped into memory.
struct OpenFiles {
    let paths: [(String, String)]   // (lowercased path, process name)

    /// nil if the snapshot couldn't be taken for one of the user's processes.
    static func snapshot() -> OpenFiles? {
        let uid = getuid()
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return nil }
        var out: [(String, String)] = []
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            if r <= 0 { continue }                               // gone, or not ours to see
            guard bsd.pbi_uid == uid, bsd.pbi_status != UInt32(SZOMB) else { continue }   // zombies hold no files
            let name = withUnsafePointer(to: bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            guard let paths = Self.paths(of: pid) else {
                // Exited or became a zombie meanwhile: nothing open any more.
                var again = proc_bsdinfo()
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &again, Int32(MemoryLayout<proc_bsdinfo>.size)) <= 0
                    || again.pbi_status == UInt32(SZOMB) { continue }
                return nil
            }
            for p in paths { out.append((p.lowercased(), name)) }
        }
        return OpenFiles(paths: out)
    }

    static func cString<T>(_ t: T) -> String {
        withUnsafePointer(to: t) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
    }

    private static func paths(of pid: Int32) -> [String]? {
        var out: [String] = []
        // working folder
        var vp = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            out.append(cString(vp.pvi_cdir.vip_path))
        } else { return nil }
        // open files
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size >= 0 else { return nil }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.size + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * MemoryLayout<proc_fdinfo>.size))
        guard used >= 0 else { return nil }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var vi = vnode_fdinfowithpath()
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 {
                out.append(cString(vi.pvip.vip_path))
            }
        }
        // memory-mapped files
        var addr: UInt64 = 0
        var last = ""
        for _ in 0..<100_000 {
            var ri = proc_regionwithpathinfo()
            let r = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &ri, Int32(MemoryLayout<proc_regionwithpathinfo>.size))
            if r <= 0 { break }
            let p = cString(ri.prp_vip.vip_path)
            if !p.isEmpty && p != last { out.append(p); last = p }
            let next = ri.prp_prinfo.pri_address + ri.prp_prinfo.pri_size
            if next <= addr { break }
            addr = next
        }
        return out
    }

    /// The name of a process with something open at or inside `path`.
    func user(of path: String) -> String? {
        let p = path.lowercased()
        for (o, name) in paths where o == p || o.hasPrefix(p + "/") { return name }
        return nil
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
    case failed(String)              // this item failed; others in the batch may still work
    case failedAll(String)           // the move failed as a whole (Finder hung, quit, cancelled): don't retry
}

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
    var prepareTrash: () -> ([String]) -> [String: TrashResult] = { Cleaner.trashWithFileManager }
    var batchSize = 100
    /// Checks items picked in the Space map instead of the rule-based path guard (6.4).
    var spaceGuard: SpaceGuard? = nil
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

            // Slow checks first: (d) age limit, readability and sockets, then (c) open files.
            do {
                let m = ScanEngine.measure(item.path, links: nil, inspect: item.spaceMap)
                guard m.complete else { skip("Part of it can't be read"); continue }
                if let why = m.protected { skip(why); continue }
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
            if let why = stopped {
                for (_, item) in ready { results[item.path] = .failedAll(why) }
            } else {
                results = trash(ready.map(\.1.path))
                stopped = wholeFailure(results)
            }
            if ready.count > 1 {
                // One item Finder couldn't move must not fail the rest: retry those one by one,
                // each re-checked right before. A whole-request failure stops all further requests.
                for (_, item) in ready {
                    guard case .failed? = results[item.path], ScanEngine.lstatInfo(item.path) != nil else { continue }
                    if let why = stopped { results[item.path] = .failedAll(why); continue }
                    if let why = lastChecks(item, env) { results[item.path] = .failed(why); continue }
                    let r = trash([item.path])[item.path] ?? .failed("No answer")
                    results[item.path] = r
                    stopped = wholeFailure([item.path: r])
                }
            }
            for (cat, item) in ready {
                switch results[item.path] ?? .failed("No answer") {
                case .moved(let putBack):
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .moved,
                                       reason: putBack ? nil : "Moved without Put Back", size: item.size))
                case .failed(let why), .failedAll(let why):
                    out.append(Outcome(path: item.path, name: item.name, category: cat.id, status: .failed, reason: why))
                }
            }
        }
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
        if item.spaceMap {
            guard let g = env.spaceGuard else { return "No Space-map guard" }
            if let why = g.check(item.path) { return why }
        } else if let why = env.guardian.check(item.path, allowRoot: item.allowRoot) { return why }
        if ScanEngine.fileID(item.path) != item.fileID { return "Changed since the scan" }
        return nil
    }

    /// Fallback mover: works without Finder, but macOS doesn't record where items came from,
    /// so Finder's Put Back isn't offered for them.
    static func trashWithFileManager(_ paths: [String]) -> [String: TrashResult] {
        var r: [String: TrashResult] = [:]
        for p in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                r[p] = .moved(putBack: false)
            } catch {
                r[p] = .failed((error as NSError).localizedDescription)
            }
        }
        return r
    }

    static func runTool(_ cat: Category, _ item: CleanItem, _ tool: ToolCommand, _ env: CleanEnvironment) -> Outcome {
        let cmds = tool.commands.map { [tool.tool] + $0 }
        guard let exe = tool.executable, FileManager.default.isExecutableFile(atPath: exe) else {
            return Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped,
                           reason: "\(tool.tool) not found", command: cmds.map { $0.joined(separator: " ") })
        }
        if cat.id == "J-XC-SIM" {
            let booted = ToolRunner.run(exe, ["simctl", "list", "devices", "booted"], timeout: 30)
            if booted.status != 0 || booted.output.contains("(Booted)") {
                return Outcome(path: item.path, name: item.name, category: cat.id, status: .skipped,
                               reason: "A simulator is running", command: cmds.map { $0.joined(separator: " ") })
            }
        }
        if env.dryRun {
            return Outcome(path: item.path, name: item.name, category: cat.id, status: .planned,
                           reason: "Run command", command: cmds.map { ([exe] + $0.dropFirst()).joined(separator: " ") })
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

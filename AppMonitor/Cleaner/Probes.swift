// System probes without AppKit: tool lookup and runner, the open-file snapshot (S13c), the
// process list and code-signing entitlements. Foundation, Darwin and Security only, so
// scripts/selftest.sh can compile it.

import Foundation
import Security

// MARK: - Tool lookup and runner

/// A folder a tool may be found in (spec 6.5), and where its executable may really live when it
/// is a symlink (Homebrew links into its own prefix, Docker into Docker.app).
struct ToolPlace: Equatable {
    let folder: String              // canonical
    let targets: [String]           // canonical folders a symlinked executable may resolve into
}

struct ToolLocator {
    /// The places each tool is looked up in, in order. A tool not listed here is never found.
    let places: [String: [ToolPlace]]
    let xcodeSelectOK: Bool
    var uid: uid_t = getuid()

    /// The tool at a known absolute path, if it passes `ToolTrust`. Never looked up through a shell or PATH.
    func find(_ tool: String) -> String? { locate(tool)?.path }

    func locate(_ tool: String) -> (path: String, place: ToolPlace)? {
        for place in places[tool] ?? [] {
            let p = place.folder + "/" + tool
            guard ScanEngine.lstatInfo(p) != nil else { continue }
            // /usr/bin developer tools are stubs that open an install dialog without the CLT.
            if place.folder == "/usr/bin" && !xcodeSelectOK { return nil }
            guard ToolTrust.refusal(p, place: place, uid: uid) == nil else { continue }
            return (p, place)
        }
        return nil
    }

    /// Where each tool is looked up on a real Mac (spec 6.5). Each tool has only its own folders,
    /// so nothing planted in one tool's folder (~/.dotnet) is ever run as another tool (xcrun).
    static func realPlaces(home: String) -> [String: [ToolPlace]] {
        let brew = [ToolPlace(folder: "/opt/homebrew/bin", targets: ["/opt/homebrew"]),
                    ToolPlace(folder: "/usr/local/bin", targets: ["/usr/local"])]
        let docker = brew.map { ToolPlace(folder: $0.folder, targets: $0.targets + ["/Applications/Docker.app/Contents/Resources"]) }
        let system = [ToolPlace(folder: "/usr/bin", targets: [])]
        let dotnet = [ToolPlace(folder: "/usr/local/share/dotnet", targets: ["/usr/local/share/dotnet"]),
                      ToolPlace(folder: home + "/.dotnet", targets: [home + "/.dotnet"])]
        return ["xcrun": system, "python3": system, "dotnet": dotnet,
                "brew": brew, "npm": brew, "yarn": brew, "pnpm": brew, "docker": docker]
    }

    static func commandLineToolsInstalled() -> Bool {
        ToolRunner.run("/usr/bin/xcode-select", ["-p"], timeout: 10).status == 0
    }
}

/// Whether an executable may be run (spec 6.5): its folder is reached without a symlink, a
/// symlinked executable resolves into one of its place's targets, and every folder on the way to
/// its folder and to the real file, and the file itself, belongs to root or the user and can't be
/// changed by other users. Group write is accepted only for the admin group (Homebrew's folders
/// and /Applications are group-writable by admin by design); world write only for a root-owned
/// sticky folder such as /private/tmp.
enum ToolTrust {
    static let adminGroup: gid_t = 80

    /// nil if the executable at `path`, found in `place`, may be run; otherwise why not.
    static func refusal(_ path: String, place: ToolPlace, uid: uid_t = getuid()) -> String? {
        guard place.folder.hasPrefix("/"), Roots.canonical(place.folder) == place.folder else {
            return "its folder is reached through a symlink"
        }
        guard let st = ScanEngine.lstatInfo(path) else { return "not found" }
        var real = path
        if (st.st_mode & S_IFMT) == S_IFLNK {
            real = Roots.canonical(path)
            guard place.targets.contains(where: { real.hasPrefix($0 + "/") }) else { return "it links outside its folder" }
        }
        guard let rst = ScanEngine.lstatInfo(real), (rst.st_mode & S_IFMT) == S_IFREG, access(real, X_OK) == 0 else {
            return "not an executable file"
        }
        for p in chain(place.folder) + chain(real) {
            guard let s = ScanEngine.lstatInfo(p) else { return "\(p) is missing" }
            if (s.st_mode & S_IFMT) == S_IFLNK { return "\(p) is a symlink" }
            if let why = entryRefusal(s, uid: uid) { return "\(p) is \(why)" }
        }
        return nil
    }

    /// "/", "/a", "/a/b", … down to `path` itself.
    static func chain(_ path: String) -> [String] {
        var out = ["/"]
        var cur = ""
        for c in path.split(separator: "/") { cur += "/" + c; out.append(cur) }
        return out
    }

    static func entryRefusal(_ st: stat, uid: uid_t) -> String? {
        guard st.st_uid == 0 || st.st_uid == uid else { return "owned by another user" }
        let m = st.st_mode
        // A root-owned sticky folder: others can add entries but not replace the user's own.
        if (m & S_IFMT) == S_IFDIR && m & S_ISVTX != 0 && st.st_uid == 0 { return nil }
        if m & S_IWOTH != 0 { return "writable by other users" }
        if m & S_IWGRP != 0 && st.st_gid != adminGroup { return "writable by its group" }
        return nil
    }
}

/// The environment a tool runs with (spec 6.5): nothing of App Monitor's own environment except
/// the locale. HOME, USER, LOGNAME and TMPDIR are the user's real values, PATH is fixed.
enum ToolEnvironment {
    static func make(for exe: String, inherited: [String: String] = ProcessInfo.processInfo.environment,
                     home: String = realHome(), user: String = realUser(),
                     tmp: String = Roots.userTempDir()) -> [String: String] {
        var env: [String: String] = [
            // npm, yarn and pnpm start with "#!/usr/bin/env node": node sits next to them.
            "PATH": URL(fileURLWithPath: exe).deletingLastPathComponent().path + ":/usr/bin:/bin",
            "NO_COLOR": "1",
        ]
        if !tmp.isEmpty { env["TMPDIR"] = tmp.hasSuffix("/") ? tmp : tmp + "/" }
        if !home.isEmpty { env["HOME"] = home }
        if !user.isEmpty { env["USER"] = user; env["LOGNAME"] = user }
        for (k, v) in inherited where (k == "LANG" || k.hasPrefix("LC_")) && localeValue(v) { env[k] = v }
        return env
    }

    /// A locale name such as "en_US.UTF-8": no path, so no locale data is read from elsewhere.
    static func localeValue(_ v: String) -> Bool {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-@")
        return !v.isEmpty && v.count <= 64 && v.allSatisfy(ok.contains)
    }

    /// From the user database, not from the environment.
    static func realHome() -> String {
        guard let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir else { return "" }
        return String(cString: d)
    }

    static func realUser() -> String {
        guard let pw = getpwuid(getuid()), let n = pw.pointee.pw_name else { return "" }
        return String(cString: n)
    }
}

/// Starts tools so that they don't get App Monitor's privacy permissions (spec 6.5): with
/// `responsibility_spawnattrs_setdisclaim` the child is responsible for itself, so macOS checks
/// the child's own Full Disk Access instead of App Monitor's. Private API, looked up at run time;
/// if it is missing the tool still runs, and then has App Monitor's permissions.
enum Responsibility {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t

    private static let handle = dlopen(nil, RTLD_NOW)
    private static let disclaimFn: Disclaim? = dlsym(handle, "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: Disclaim.self) }
    private static let responsibleFn: ResponsibleFor? = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFor.self) }

    static var available: Bool { disclaimFn != nil }

    /// True if the spawn attributes now disclaim responsibility.
    static func disclaim(_ attr: inout posix_spawnattr_t?) -> Bool {
        guard let f = disclaimFn else { return false }
        return f(&attr, 1) == 0
    }

    /// The process macOS holds responsible for `pid` (used by the self-test), if that can be asked.
    static func responsible(for pid: pid_t) -> pid_t? { responsibleFn.map { $0(pid) } }
}

enum ToolRunner {
    struct Result { let status: Int32; let output: String; let timedOut: Bool }

    /// Runs `exe` with a fixed argument list: no shell, nothing interpolated, a fresh environment
    /// (`ToolEnvironment`), only stdin, stdout and stderr open, and responsibility disclaimed.
    /// `started` is told the child's pid (self-test).
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 300,
                    environment: [String: String]? = nil, started: ((pid_t) -> Void)? = nil) -> Result {
        let env = environment ?? ToolEnvironment.make(for: exe)
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return Result(status: -1, output: "Couldn't start \(exe): no pipe", timedOut: false) }
        let (rd, wr) = (fds[0], fds[1])
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, wr, 1)
        posix_spawn_file_actions_adddup2(&actions, wr, 2)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // No other descriptor reaches the child; default signal handling, nothing blocked.
        // Its own process group, so a timeout stops the tool's helpers too (killpg).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var all = sigset_t(); sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        _ = Responsibility.disclaim(&attr)

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.keys.sorted().map { strdup($0 + "=" + env[$0]!) } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        close(wr)
        guard rc == 0 else {
            close(rd)
            return Result(status: -1, output: "Couldn't start \(exe): \(String(cString: strerror(rc)))", timedOut: false)
        }
        started?(pid)

        let reader = FileHandle(fileDescriptor: rd, closeOnDealloc: true)
        var data = Data()
        let lock = NSLock()
        let eof = DispatchSemaphore(value: 0)
        reader.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; eof.signal(); return }
            lock.lock(); if data.count < 200_000 { data.append(d) }; lock.unlock()
        }
        final class Exit: @unchecked Sendable { var status: Int32 = 0; var reaped = false }
        let exit = Exit()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var st: Int32 = 0
            var r: pid_t
            repeat { r = waitpid(pid, &st, 0) } while r < 0 && errno == EINTR
            exit.status = st
            exit.reaped = r == pid   // otherwise the exit status is unknown: never report success
            done.signal()
        }
        var timedOut = false
        var exited = true
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            killpg(pid, SIGTERM)
            if done.wait(timeout: .now() + 5) == .timedOut {
                killpg(pid, SIGKILL)
                exited = done.wait(timeout: .now() + 5) == .success
            }
        }
        // A child the tool left running may keep the pipe open: wait for the end of output briefly, never forever.
        if eof.wait(timeout: .now() + 2) == .timedOut { reader.readabilityHandler = nil }
        lock.lock(); let text = String(decoding: data, as: UTF8.self); lock.unlock()
        let st = exit.status
        let code = (st & 0x7f) == 0 ? (st >> 8) & 0xff : st & 0x7f   // exit code, or the signal that ended it
        if timedOut { killpg(pid, SIGKILL) }   // helpers the tool left behind
        if !timedOut && exited && !exit.reaped { return Result(status: -1, output: text, timedOut: false) }
        return Result(status: timedOut || !exited ? -2 : code, output: text, timedOut: timedOut)
    }
}

// MARK: - Open-file snapshot (S13c)

/// Paths the current user's processes have open, as working folder, open file or mapped into memory.
struct OpenFiles {
    /// Unique open paths, sorted by their key bytes, with the first process seen for each.
    private let keys: [[UInt8]]
    private let names: [String]

    /// Paths are compared without case (and in one Unicode form), as UTF-8 bytes, so a sorted
    /// list finds every path at or inside an item with a binary search.
    static func key(_ path: String) -> [UInt8] {
        Array(path.lowercased().precomposedStringWithCanonicalMapping.utf8)
    }

    /// `pairs` are (path, process name); a path listed more than once keeps its first process.
    init(_ pairs: [(String, String)]) {
        var seen: [[UInt8]: String] = [:]
        for (p, name) in pairs {
            let k = Self.key(p)
            if seen[k] == nil { seen[k] = name }
        }
        let sorted = seen.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        keys = sorted.map(\.key)
        names = sorted.map(\.value)
    }

    var count: Int { keys.count }

    /// nil if the snapshot couldn't be taken for one of the user's processes.
    static func snapshot() -> OpenFiles? {
        let uid = getuid()
        guard let pids = ProcessList.allPIDs() else { return nil }
        var out: [(String, String)] = []
        for pid in pids {
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
            for p in paths { out.append((p, name)) }
        }
        return OpenFiles(out)
    }

    static func cString<T>(_ t: T) -> String {
        withUnsafePointer(to: t) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
    }

    /// Regions looked at per process at most. A process with more is treated as unreadable (S5).
    static let regionCap = 100_000

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
        // memory-mapped files: walked region by region until the kernel reports no region at or
        // after the address (EINVAL). Any other error, a walk that doesn't move forward, or more
        // than `regionCap` regions fails this process's snapshot.
        var addr: UInt64 = 0
        var last = ""
        for _ in 0..<regionCap {
            var ri = proc_regionwithpathinfo()
            errno = 0
            let r = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &ri, Int32(MemoryLayout<proc_regionwithpathinfo>.size))
            if r <= 0 { return errno == EINVAL ? out : nil }
            let p = cString(ri.prp_vip.vip_path)
            if !p.isEmpty && p != last { out.append(p); last = p }
            let next = ri.prp_prinfo.pri_address + ri.prp_prinfo.pri_size
            if next <= addr { return nil }
            addr = next
        }
        return nil
    }

    /// The name of a process with something open at or inside `path` (component-wise, without case).
    func user(of path: String) -> String? {
        let p = Self.key(path)
        let i = lowerBound(p)
        if i < keys.count, keys[i] == p { return names[i] }
        // Anything inside sorts right after "<path>/" (siblings such as "<path>-x" sort before it).
        let inside = p + [UInt8(ascii: "/")]
        let j = lowerBound(inside)
        if j < keys.count, keys[j].starts(with: inside) { return names[j] }
        return nil
    }

    /// The index of the first key not before `k`.
    private func lowerBound(_ k: [UInt8]) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid].lexicographicallyPrecedes(k) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Processes

enum ProcessList {
    /// Stands for the processes when they can't be listed: doubt counts as running (S5).
    static let unknown = "a process App Monitor couldn't check"

    /// Every process ID macOS lists (any user's), or nil when the list can't be read.
    static func allPIDs() -> [Int32]? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return nil }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    /// Names of processes (any user's, as far as macOS shows them) whose executable is inside `folder`.
    static func inside(_ folder: String) -> [String] {
        let prefix = folder.lowercased() + "/"
        guard let pids = allPIDs() else { return [unknown] }
        var out: [String] = []
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let p = String(cString: buf)
            if p.lowercased().hasPrefix(prefix) { out.append(URL(fileURLWithPath: p).lastPathComponent) }
        }
        return Array(Set(out)).sorted()
    }
}

// MARK: - Entitlements

enum Entitlements {
    /// `com.apple.security.application-groups` of a signed bundle, lowercased.
    static func appGroups(_ path: String) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code
        else { return [] }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let d = info as? [String: Any],
              let ent = d[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups.map { $0.lowercased() }
    }
}

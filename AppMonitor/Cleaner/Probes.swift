// System probes without AppKit: tool lookup and runner, the open-file snapshot (S13c), the
// process list and code-signing entitlements. Foundation, Darwin and Security only, so
// scripts/selftest.sh can compile it.

import Foundation
import Security

// MARK: - Tool lookup and runner

struct ToolLocator {
    let dirs: [String]
    let xcodeSelectOK: Bool

    /// The tool at a known absolute path. Never looked up through a shell or PATH.
    func find(_ tool: String) -> String? {
        for d in dirs {
            let p = d + "/" + tool
            guard FileManager.default.isExecutableFile(atPath: p) else { continue }
            // /usr/bin developer tools are stubs that open an install dialog without the CLT.
            if d == "/usr/bin" && !xcodeSelectOK { return nil }
            return p
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

// Process ownership and identity: which app owns each process, and whether a pid is still the
// process we sampled. No AppKit, so scripts/grouping-test.sh can compile it on its own.

import Foundation
import Darwin

struct RawProc {
    let pid: Int32
    let ppid: Int32
    let cpu: Double
    let rssKB: Int
    let exe: String
    var args: String = ""
}

func outerAppPath(_ exe: String) -> String? {
    guard let r = exe.range(of: ".app/") else { return nil }
    return String(exe[..<r.lowerBound]) + ".app"
}

func innerAppPath(_ exe: String) -> String? {
    guard let r = exe.range(of: ".app/", options: .backwards) else { return nil }
    return String(exe[..<r.lowerBound]) + ".app"
}

func baseName(_ path: String) -> String {
    let s = (path as NSString).lastPathComponent
    return s.isEmpty ? path : s
}

struct ProcOwner: Equatable {
    let key: String     // .app bundle path, or the top process's executable name
    let isApp: Bool
}

/// Owner of each process, worked out top-down so the result never depends on visit order:
/// a process inherits its parent's app; otherwise its own .app; otherwise, below a top-level
/// process (one launchd started), its parent's owner; otherwise its own executable name.
/// `order` only exists so the test can visit the processes in different orders.
func processOwners(_ procs: [Int32: RawProc], order: [Int32]? = nil) -> [Int32: ProcOwner] {
    var memo: [Int32: ProcOwner] = [:]
    var visiting: Set<Int32> = []   // cycle guard: a parent still being worked out counts as absent
    func owner(_ pid: Int32) -> ProcOwner {
        if let m = memo[pid] { return m }
        guard let p = procs[pid] else { return ProcOwner(key: "?", isApp: false) }
        visiting.insert(pid)
        var parent: ProcOwner?
        if p.ppid > 1, procs[p.ppid] != nil, !visiting.contains(p.ppid) { parent = owner(p.ppid) }
        visiting.remove(pid)
        let result: ProcOwner
        if let po = parent, po.isApp { result = po }
        else if let a = outerAppPath(p.exe) { result = ProcOwner(key: a, isApp: true) }
        else if let po = parent { result = po }
        else { result = ProcOwner(key: baseName(p.exe), isApp: false) }
        memo[pid] = result
        return result
    }
    for pid in order ?? Array(procs.keys) { _ = owner(pid) }
    return memo
}

/// What identifies a process beyond its pid: pids are reused, start times aren't. The parent
/// isn't part of it: a process whose parent quit is moved to launchd but is still the same process.
struct ProcIdentity: Equatable {
    let ppid: Int32
    let startSec: UInt64
    let startUsec: UInt64
    static func == (a: Self, b: Self) -> Bool { a.startSec == b.startSec && a.startUsec == b.startUsec }
}

func procIdentity(_ pid: Int32) -> ProcIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return ProcIdentity(ppid: Int32(info.pbi_ppid), startSec: info.pbi_start_tvsec, startUsec: info.pbi_start_tvusec)
}

/// True only if `pid` is still the process sampled with `identity` (same start time).
func stillSameProcess(_ pid: Int32, _ identity: ProcIdentity?) -> Bool {
    guard let identity, let now = procIdentity(pid) else { return false }
    return now == identity
}

func executablePath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

/// Whether "Quit <group>" may fall back to a plain signal for a process with this executable:
/// for an app, only when the executable is inside that app's bundle; for a non-app group, only
/// for the group's own executable.
func quitSignalAllowed(exe: String?, appBundle: String?, groupKey: String) -> Bool {
    guard let exe, !exe.isEmpty else { return false }
    if let b = appBundle { return exe.hasPrefix(b + "/") }
    return baseName(exe) == groupKey
}

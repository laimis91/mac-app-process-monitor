// App Monitor — shows CPU and RAM per app, including everything each app started.
// Build: ./build.sh   (needs only the Xcode Command Line Tools)

import SwiftUI
import AppKit
import Darwin
import IOKit

// MARK: - Raw data

// RawProc, the .app path helpers and the ownership logic live in ProcessTree.swift.

func runPS(_ format: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axww", "-o", format]
    p.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]   // fixed lstart format, whatever the user's locale
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Splits off the first `n` whitespace-separated fields and returns them plus the rest of the line.
func fields(_ line: Substring, _ n: Int) -> ([Substring], String)? {
    var out: [Substring] = []
    var rest = line.drop(while: { $0 == " " })
    for _ in 0..<n {
        guard let end = rest.firstIndex(of: " ") else { return nil }
        out.append(rest[..<end])
        rest = rest[end...].drop(while: { $0 == " " })
    }
    return (out, String(rest))
}

func readProcs() -> [Int32: RawProc] {
    // comm and args both run to the end of the line, so they need two ps calls. The start time
    // (lstart, five fields) ties the args to the same process: a reused pid has another one.
    var procs: [Int32: RawProc] = [:]
    var started: [Int32: String] = [:]
    for line in runPS("pid=,ppid=,pcpu=,rss=,lstart=,comm=").split(separator: "\n") {
        guard let (f, exe) = fields(line, 9),
              let pid = Int32(f[0]), let ppid = Int32(f[1]),
              let cpu = Double(f[2]), let rss = Int(f[3]) else { continue }
        procs[pid] = RawProc(pid: pid, ppid: ppid, cpu: cpu, rssKB: rss, exe: exe)
        started[pid] = f[4...8].joined(separator: " ")
        procs[pid]?.lstart = started[pid] ?? ""
    }
    for line in runPS("pid=,lstart=,args=").split(separator: "\n") {
        guard let (f, args) = fields(line, 6), let pid = Int32(f[0]),
              started[pid] == f[1...5].joined(separator: " ") else { continue }
        procs[pid]?.args = args
    }
    return procs
}

/// True if ps's start time (lstart in the C locale, "Sat Nov 8 03:29:00 2026", local time) is
/// the second `sec`. `sec` is formatted the way ps prints it rather than lstart parsed, so no
/// daylight-saving hour is ambiguous.
func sameStart(_ lstart: String, _ sec: UInt64) -> Bool {
    guard !lstart.isEmpty else { return false }
    var t = time_t(sec)
    var tm = tm()
    guard localtime_r(&t, &tm) != nil, (0..<7).contains(tm.tm_wday), (0..<12).contains(tm.tm_mon) else { return false }
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    let text = "\(days[Int(tm.tm_wday)]) \(months[Int(tm.tm_mon)]) \(tm.tm_mday) "
        + String(format: "%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec) + " \(Int(tm.tm_year) + 1900)"
    return text == lstart
}

/// Helper bundles inside an app often have no icon; then the outer app's icon is more useful.
var iconCheck: [String: Bool] = [:]
func hasOwnIcon(_ appPath: String) -> Bool {
    if let v = iconCheck[appPath] { return v }
    let info = Bundle(path: appPath)?.infoDictionary
    let v = info?["CFBundleIconFile"] != nil || info?["CFBundleIconName"] != nil
    iconCheck[appPath] = v
    return v
}

func appName(_ appPath: String) -> String {
    ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
}

func workingDir(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty ? nil : path
}

let home = NSHomeDirectory()
func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

// MARK: - Tree

final class Node: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let tooltip: String
    let iconPath: String?   // .app bundle to take the icon from
    let isGroup: Bool
    var ownCPU: Double
    var ownRSS: Int
    var extraCount = 0
    var pid: Int32 = 0          // process pid, or the app's main pid for a group (0 = none)
    var identity: ProcIdentity? // pid's parent and start time when sampled; nil = never signal it
    var command = ""            // full command line, for search
    var appBundle: String?      // a group's .app bundle
    var ownGPU = 0.0
    var gpu = 0.0
    var kids: [Node] = []
    var cpu = 0.0, rssKB = 0, count = 0

    init(id: String, title: String, subtitle: String?, tooltip: String, iconPath: String?,
         isGroup: Bool, ownCPU: Double, ownRSS: Int) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.tooltip = tooltip
        self.iconPath = iconPath; self.isGroup = isGroup; self.ownCPU = ownCPU; self.ownRSS = ownRSS
    }

    @discardableResult func sum() -> Node {
        cpu = ownCPU; gpu = ownGPU; rssKB = ownRSS; count = isGroup ? extraCount : 1
        for k in kids { k.sum(); cpu += k.cpu; gpu += k.gpu; rssKB += k.rssKB; count += k.count }
        return self
    }

    func matches(_ q: String) -> Bool {
        let folder = subtitle.map { $0.hasPrefix("in ") ? String($0.dropFirst(3)) : $0 } ?? ""
        return title.localizedCaseInsensitiveContains(q) || folder.localizedCaseInsensitiveContains(q)
            || command.localizedCaseInsensitiveContains(q) || kids.contains { $0.matches(q) }
    }
}

func buildGroups(gpu: [Int32: Double] = [:]) -> [Node] {
    let procs = readProcs()
    // Owner of each process: the outermost .app among its ancestors, otherwise the
    // top-level process (the one launchd started).
    let owners = processOwners(procs)

    var members: [String: [Int32]] = [:]
    var groupIsApp: [String: Bool] = [:]
    for pid in procs.keys {
        guard let o = owners[pid] else { continue }
        members[o.key, default: []].append(pid)
        groupIsApp[o.key] = o.isApp
    }

    var groups: [Node] = []
    var cwds: [Int32: String?] = [:]
    func cwdOf(_ pid: Int32) -> String? {
        if let c = cwds[pid] { return c }
        let d = workingDir(pid); cwds[pid] = d; return d
    }
    for (key, pids) in members {
        let isApp = groupIsApp[key] ?? false
        let group = Node(id: "g:" + key, title: isApp ? appName(key) : key, subtitle: nil,
                         tooltip: key, iconPath: isApp ? key : nil, isGroup: true, ownCPU: 0, ownRSS: 0)
        group.appBundle = isApp ? key : nil
        let set = Set(pids)
        var nodes: [Int32: Node] = [:]
        for pid in pids {
            guard let p = procs[pid] else { continue }
            let inApp = innerAppPath(p.exe)
            var title = baseName(p.exe)
            var subtitle: String?
            if inApp == nil {
                var tail = p.args
                if tail.hasPrefix(p.exe) { tail = String(tail.dropFirst(p.exe.count)) }
                else if let sp = tail.firstIndex(of: " ") { tail = String(tail[sp...]) } else { tail = "" }
                tail = tail.trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { title += "  " + tail }
            }
            if title == "disclaimer" && p.args.contains("/claude.app/Contents/MacOS/claude") {
                title = "Claude Code session"
            }
            if let d = cwdOf(pid), d != "/", d != cwdOf(p.ppid) { subtitle = "in " + tilde(d) }
            nodes[pid] = Node(id: "p:\(pid)", title: title, subtitle: subtitle,
                              tooltip: "PID \(pid)\n\(p.args.isEmpty ? p.exe : p.args)",
                              iconPath: inApp.map { hasOwnIcon($0) ? $0 : (outerAppPath(p.exe) ?? $0) }, isGroup: false, ownCPU: p.cpu, ownRSS: p.rssKB)
            nodes[pid]?.pid = pid
            // Only if the pid still is the process ps listed: a pid reused since then gets no identity.
            nodes[pid]?.identity = procIdentity(pid).flatMap { sameStart(p.lstart, $0.startSec) ? $0 : nil }
            nodes[pid]?.command = p.args.isEmpty ? p.exe : p.args
            nodes[pid]?.ownGPU = gpu[pid] ?? 0
        }
        for pid in pids {
            guard let n = nodes[pid], let p = procs[pid] else { continue }
            if set.contains(p.ppid), p.ppid != pid, let parent = nodes[p.ppid] { parent.kids.append(n) }
            else { group.kids.append(n) }
        }
        // The app's own main process doesn't need its own level: fold it into the group row.
        if let i = group.kids.firstIndex(where: { r in
            group.kids.count == 1 || (isApp && procs[r.pid].map { $0.exe.hasPrefix(key + "/Contents/MacOS/") } == true)
        }) {
            let root = group.kids.remove(at: i)
            group.kids += root.kids
            group.ownCPU = root.ownCPU; group.ownRSS = root.ownRSS; group.extraCount = 1
            group.ownGPU = root.ownGPU; group.pid = root.pid; group.identity = root.identity
            group.command = root.command
        }
        groups.append(group.sum())
    }
    return groups
}

// MARK: - Memory

struct MemInfo {
    var total: Double = 0, app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0, free = 0.0
    var swapUsed = 0.0
    var pressure: Int32 = 1
    var available: Double { max(0, total - app - wired - compressed) }
}

func readMem() -> MemInfo {
    var m = MemInfo()
    m.total = Double(ProcessInfo.processInfo.physicalMemory)
    var s = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let page = Double(getpagesize())
        m.app = max(0, Double(Int64(s.internal_page_count) - Int64(s.purgeable_count)) * page)
        m.wired = Double(s.wire_count) * page
        m.compressed = Double(s.compressor_page_count) * page
        m.cached = Double(UInt64(s.external_page_count) + UInt64(s.purgeable_count)) * page
        m.free = max(0, m.total - m.app - m.wired - m.compressed - m.cached)
    }
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = Double(swap.xsu_used) }
    var level: Int32 = 1
    size = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressure = level }
    return m
}

// MARK: - GPU

struct GPUSample {
    var utilization = 0.0          // whole GPU, %
    var memoryUsed = 0.0           // bytes the GPU is using
    var name = "GPU"
    var perPid: [Int32: Double] = [:]   // % of GPU time each process used since the last sample
}

/// Reads GPU load from IOKit: the accelerator's PerformanceStatistics for the total, and each
/// GPU client's accumulatedGPUTime (nanoseconds) for per-process use.
final class GPUReader {
    private var lastTimes: [Int32: UInt64] = [:]
    private var lastWall: UInt64 = 0

    func sample() -> GPUSample {
        var out = GPUSample()
        var times: [Int32: UInt64] = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            if let stats = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                out.utilization = max(out.utilization, (stats["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
                out.memoryUsed += (stats["In use system memory"] as? NSNumber)?.doubleValue ?? 0
            }
            if let model = IORegistryEntryCreateCFProperty(svc, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let s = model as? String { out.name = s }
                else if let d = model as? Data { out.name = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .controlCharacters) }
            }
            var kids: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(svc, kIOServicePlane, &kids) == KERN_SUCCESS else { continue }
            while case let c = IOIteratorNext(kids), c != 0 {
                defer { IOObjectRelease(c) }
                guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      creator.hasPrefix("pid "),
                      let pid = Int32(creator.dropFirst(4).prefix(while: { $0.isNumber })),
                      let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                for u in usage { times[pid, default: 0] += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
            }
            IOObjectRelease(kids)
        }
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        if lastWall > 0, now > lastWall {
            let wall = Double(now - lastWall)
            for (pid, t) in times {
                if let prev = lastTimes[pid], t > prev { out.perPid[pid] = min(100, Double(t - prev) / wall * 100) }
            }
        }
        lastTimes = times; lastWall = now
        return out
    }
}

final class Sampler: ObservableObject {
    @Published var groups: [Node] = []
    @Published var mem = MemInfo()
    @Published var paused = false
    @Published var cpuHistory: [Double] = []   // % of whole Mac, one sample per refresh
    @Published var memHistory: [Double] = []   // % of RAM in real use
    static let historyLength = 90              // 3 minutes at 2 s
    let cores = demoMode ? 12 : ProcessInfo.processInfo.activeProcessorCount
    private var timer: Timer?
    private let queue = DispatchQueue(label: "sampler", qos: .utility)
    private var busy = false
    private var demoTick = 0
    private let gpuReader = GPUReader()
    @Published var gpu = GPUSample()
    @Published var gpuHistory: [Double] = []

    var totalCPU: Double { groups.reduce(0) { $0 + $1.cpu } }

    init() {
        if demoMode {
            (cpuHistory, gpuHistory, memHistory) = Demo.history(Sampler.historyLength)
        }
        refresh()
        startTimer()
        // Sample only while a window is on screen: closing the window keeps the app running, so a
        // hidden, minimised, closed or fully covered window stops sampling until it shows again.
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSApplication.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the notification, so a closing window no longer counts as visible.
                DispatchQueue.main.async { self?.updateVisibility() }
            })
        }
        // A window that opens already covered (or on a locked screen) may post nothing: check once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.updateVisibility() }
    }

    private var observers: [NSObjectProtocol] = []

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.paused else { return }
            self.refresh()
        }
    }

    private func updateVisibility() {
        let visible = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        if visible, timer == nil {
            startTimer()
            if !paused { refresh() }   // show fresh numbers straight away
        } else if !visible, let t = timer {
            t.invalidate(); timer = nil
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        if demoMode {
            demoTick += 1
            (groups, mem, gpu) = Demo.sample(tick: demoTick)
            busy = false
            return
        }
        queue.async {
            let gs = self.gpuReader.sample()
            let g = buildGroups(gpu: gs.perPid)
            let m = readMem()
            let pct = min(100, g.reduce(0) { $0 + $1.cpu } / Double(self.cores))
            let used = m.total > 0 ? (m.total - m.available) / m.total * 100 : 0
            DispatchQueue.main.async {
                self.groups = g; self.mem = m; self.gpu = gs; self.busy = false
                self.gpuHistory = Array((self.gpuHistory + [gs.utilization]).suffix(Sampler.historyLength))
                self.cpuHistory = Array((self.cpuHistory + [pct]).suffix(Sampler.historyLength))
                self.memHistory = Array((self.memHistory + [used]).suffix(Sampler.historyLength))
            }
        }
    }
}

// MARK: - Icons

final class Icons {
    static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}


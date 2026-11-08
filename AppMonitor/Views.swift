// Views: panels, the process list, live graphs and the window. Colours live in Theme.swift.

import SwiftUI
import AppKit

// MARK: - Formatting

func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }
func ramText(_ kb: Int) -> String {
    let mb = Double(kb) / 1024
    return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

/// "PRESSURE NORMAL" → "Pressure normal", keeping acronyms such as CPU and GB.
func sentenceCase(_ s: String) -> String {
    let keep: Set<String> = ["CPU", "GPU", "RAM", "GB", "MB", "TB", "KB", "SSD", "PID"]
    return s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, w in
        let word = String(w)
        if keep.contains(word) { return word }
        let lower = word.lowercased()
        return i == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
    }.joined(separator: " ")
}

enum SortKey: String, CaseIterable { case cpu = "CPU", gpu = "GPU", ram = "RAM" }

// MARK: - Building blocks

struct Panel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(sentenceCase(title))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dim)
                Spacer()
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.field))
                    .overlay(Circle().strokeBorder(Theme.stroke))
                    .accessibilityHidden(true)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

struct Ring: View {
    let value: Double        // 0...1
    let color: Color
    let label: String
    let caption: String
    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.005, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(label).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text(sentenceCase(caption)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 96, height: 96)
    }
}

struct Sparkline: View {
    let values: [Double]     // 0...100
    let color: Color
    var body: some View {
        GeometryReader { g in
            let n = Sampler.historyLength
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(n - values.count + i) / CGFloat(n - 1),
                        y: g.size.height * (1 - CGFloat(min(100, max(0, v)) / 100)))
            }
            ZStack {
                // grid
                ForEach(1..<4) { i in
                    Path { p in
                        let y = g.size.height * CGFloat(i) / 4
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                    }.stroke(Theme.track, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(sentenceCase(text)).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct HeatBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: max(fraction > 0.002 ? 3 : 0, g.size.width * min(1, fraction)))
            }
        }
    }
}

// MARK: - Header panels

struct CPUPanel: View {
    @EnvironmentObject var s: Sampler
    var body: some View {
        let busy = s.totalCPU / 100
        let pct = min(100, busy / Double(s.cores) * 100)
        let color = Theme.heat(pct / 100)
        Panel(title: "CPU", icon: "cpu") {
            HStack(spacing: 16) {
                Ring(value: pct / 100, color: color, label: String(format: "%.0f%%", pct), caption: "LOAD")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", busy)).font(.system(size: 28, weight: .regular, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.text)
                        Text("/ \(s.cores) cores busy").font(.callout).foregroundStyle(Theme.dim)
                    }
                    Sparkline(values: s.cpuHistory, color: color).frame(height: 44)
                    if let top = s.groups.max(by: { $0.cpu < $1.cpu }), top.cpu >= 1 {
                        HStack(spacing: 5) {
                            if let p = top.iconPath { Image(nsImage: Icons.icon(p)).resizable().frame(width: 14, height: 14) }
                            Text("Top: \(top.title)").foregroundStyle(Theme.text)
                            Text(String(format: "%.1f cores", top.cpu / 100)).foregroundStyle(Theme.cpuHeat(top.cpu))
                        }.font(.caption.weight(.semibold)).lineLimit(1)
                    }
                }
            }
        }
    }
}

struct MemoryPanel: View {
    @EnvironmentObject var s: Sampler
    var body: some View {
        let m = s.mem
        let usedFrac = m.total > 0 ? (m.total - m.available) / m.total : 0
        let parts: [(String, Double, Color, String)] = [
            ("Apps", m.app, Theme.purple, "Memory your apps are using."),
            ("System", m.wired, Theme.orange, "Wired: used by macOS itself, can't be freed."),
            ("Compressed", m.compressed, Theme.pink, "App memory squeezed to save space. A lot of it means RAM is getting tight."),
            ("Cache", m.cached, Theme.cyan.opacity(0.75), "Recently used files kept in RAM. Freed instantly when an app needs it, so it counts as available."),
            ("Free", m.free, Theme.free, "Completely unused."),
        ]
        let (pName, pColor): (String, Color) = m.pressure >= 4 ? ("CRITICAL", Theme.red)
            : m.pressure >= 2 ? ("WARNING", Theme.orange) : ("NORMAL", Theme.green)
        Panel(title: "MEMORY", icon: "memorychip") {
            HStack(alignment: .top, spacing: 16) {
                Ring(value: usedFrac, color: Theme.heat(usedFrac * 0.9), label: gb(m.available).replacingOccurrences(of: " GB", with: ""),
                     caption: "GB AVAILABLE")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(gb(m.available)).font(.system(size: 28, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                        Text("available of \(gb(m.total))").font(.callout).foregroundStyle(Theme.dim)
                        Spacer()
                        Chip(text: "PRESSURE \(pName)", color: pColor)
                            .help("The best single sign of whether you need more RAM. Green is fine, whatever the other numbers say.")
                    }
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            ForEach(parts, id: \.0) { p in
                                Capsule().fill(p.2)
                                    .frame(width: max(0, g.size.width * p.1 / max(1, m.total) - 2))
                                    .help("\(p.0): \(gb(p.1))\n\(p.3)")
                            }
                        }
                    }.frame(height: 12)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow { legend(parts[0]); legend(parts[1]); legend(parts[2]) }
                        GridRow {
                            legend(parts[3]); legend(parts[4])
                            legend(("Swap", m.swapUsed, m.swapUsed > 1_073_741_824 ? Theme.orange : Theme.free,
                                    "Memory moved to disk because RAM was full. Some is normal; a lot that keeps growing means you're short on RAM."))
                        }
                    }.font(.caption)
                    Sparkline(values: s.memHistory, color: Theme.purple).frame(height: 22)
                        .help("RAM in real use over the last 3 minutes")
                }
            }
        }
    }
}

extension MemoryPanel {
    func legend(_ p: (String, Double, Color, String)) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 8, height: 8)
            Text(p.0).foregroundStyle(Theme.dim)
            Text(gb(p.1)).font(.caption.monospaced()).foregroundStyle(Theme.text)
        }
        .fixedSize()
        .help(p.3)
    }
}

struct GPUPanel: View {
    @EnvironmentObject var s: Sampler
    var body: some View {
        let g = s.gpu
        let color = Theme.heat(g.utilization / 100)
        Panel(title: "GPU", icon: "square.3.layers.3d") {
            HStack(spacing: 16) {
                Ring(value: g.utilization / 100, color: color, label: String(format: "%.0f%%", g.utilization), caption: "LOAD")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(gb(g.memoryUsed).replacingOccurrences(of: " GB", with: ""))
                            .font(.system(size: 28, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                        Text("GB in use").font(.callout).foregroundStyle(Theme.dim)
                    }
                    .help("Memory the GPU is using right now. On Apple Silicon this comes out of the same RAM as everything else.")
                    Sparkline(values: s.gpuHistory, color: color).frame(height: 44)
                    if let top = s.groups.max(by: { $0.gpu < $1.gpu }), top.gpu >= 0.5 {
                        HStack(spacing: 5) {
                            if let p = top.iconPath { Image(nsImage: Icons.icon(p)).resizable().frame(width: 14, height: 14) }
                            Text("Top: \(top.title)").foregroundStyle(Theme.text)
                            Text(String(format: "%.0f%%", top.gpu)).foregroundStyle(Theme.cyan)
                        }.font(.caption.weight(.semibold)).lineLimit(1)
                    } else {
                        Text(g.name).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject var s: Sampler
    @State var expanded: Set<String>
    init(expanded: Set<String> = []) {
        _expanded = State(initialValue: expanded)
    }
    @State private var search = ""
    @State private var sort: SortKey = .cpu
    @State private var hideIdle = true

    struct Row: Identifiable { let node: Node; let depth: Int; var id: String { node.id } }

    func sorted(_ n: [Node]) -> [Node] {
        n.sorted { a, b in
            switch sort {
            case .cpu: if (a.cpu, a.rssKB) != (b.cpu, b.rssKB) { return (a.cpu, a.rssKB) > (b.cpu, b.rssKB) }
            case .gpu: if (a.gpu, a.cpu, a.rssKB) != (b.gpu, b.cpu, b.rssKB) { return (a.gpu, a.cpu, a.rssKB) > (b.gpu, b.cpu, b.rssKB) }
            case .ram: if (a.rssKB, a.cpu) != (b.rssKB, b.cpu) { return (a.rssKB, a.cpu) > (b.rssKB, b.cpu) }
            }
            // Equal on the sort key: a fixed order, so rows don't swap places between samples.
            return (a.title, a.id) < (b.title, b.id)
        }
    }

    var rows: [Row] {
        var out: [Row] = []
        func walk(_ nodes: [Node], _ depth: Int) {
            for n in sorted(nodes) {
                if depth > 0 && hideIdle && n.cpu < 0.1 && n.gpu < 0.1 { continue }
                out.append(Row(node: n, depth: depth))
                if expanded.contains(n.id) { walk(n.kids, depth + 1) }
            }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        walk(q.isEmpty ? s.groups : s.groups.filter { $0.matches(q) }, 0)
        return out
    }

    var maxCPU: Double { max(1, s.groups.map(\.cpu).max() ?? 1) }
    var maxRAM: Int { max(1, s.groups.map(\.rssKB).max() ?? 1) }
    var maxGPU: Double { max(1, s.groups.map(\.gpu).max() ?? 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CPUPanel().frame(width: 320)
                GPUPanel().frame(width: 320)
                MemoryPanel()
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)

            toolbar.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            VStack(spacing: 0) {
                columnHeader
                Rectangle().fill(Theme.stroke).frame(height: 1)
                ScrollView { LazyVStack(spacing: 0) { rowList } }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .card()
            .padding(.horizontal, 18)

            Text("CPU 100% = one fully busy core  ·  RAM is summed per process, so shared memory can be counted more than once")
                .font(.caption2).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 8)
        }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Search apps, commands, folders", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.field))
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .frame(maxWidth: 300)

            PillPicker(title: "Sort", selection: $sort, items: SortKey.allCases) { "Sort: \($0.rawValue)" }
                .frame(width: 260)

            Toggle("Hide idle", isOn: $hideIdle).toggleStyle(.switch).controlSize(.small)
                .foregroundStyle(Theme.dim)
            Spacer()
            ToolButton(icon: expanded.isEmpty ? "flame" : "arrow.down.right.and.arrow.up.left",
                       text: expanded.isEmpty ? "Show hottest" : "Collapse") {
                if expanded.isEmpty { expandTop() } else { expanded.removeAll() }
            }
            ToolButton(icon: s.paused ? "play.fill" : "pause.fill", text: s.paused ? "Resume" : "Pause") { s.paused.toggle() }
        }
    }

    var columnHeader: some View {
        HStack(spacing: 0) {
            Text("App / process").padding(.leading, 44)
            Spacer()
            Text("CPU").frame(width: 200, alignment: .leading)
            Text("GPU").frame(width: 120, alignment: .leading)
            Text("RAM").frame(width: 150, alignment: .leading)
            Text("Procs").frame(width: 56, alignment: .trailing)
            Color.clear.frame(width: 40, height: 1)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
        .padding(.vertical, 10)
    }

    @ViewBuilder var rowList: some View {
        ForEach(Array(rows), id: \.id) { r in
            RowView(node: r.node, depth: r.depth, maxCPU: maxCPU, maxRAM: maxRAM, maxGPU: maxGPU,
                    isExpanded: expanded.contains(r.node.id)) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if expanded.contains(r.node.id) { expanded.remove(r.node.id) } else { expanded.insert(r.node.id) }
                }
            }
            if r.depth == 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, 12) }
        }
    }

    func expandTop() { expanded = topExpansion(s.groups) }
    func topExpansion(_ groups: [Node]) -> Set<String> {
        var e: Set<String> = []
        guard var n = sorted(groups).first else { return e }
        e.insert(n.id)
        while let k = sorted(n.kids).first, !k.kids.isEmpty { e.insert(k.id); n = k }
        return e
    }
}

struct ToolButton: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: icon); Text(text) }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(hover ? Theme.hover : Theme.field))
                .overlay(Capsule().strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RowView: View {
    let node: Node
    let depth: Int
    let maxCPU: Double
    let maxRAM: Int
    let maxGPU: Double
    let isExpanded: Bool
    let toggle: () -> Void
    @EnvironmentObject var s: Sampler
    @State private var hover = false
    @State private var confirmKill = false
    @State private var killError: String?

    var canKill: Bool { node.pid > 0 && node.pid != getpid() }

    var body: some View {
        let heat = Theme.cpuHeat(node.cpu)
        let idle = node.cpu < 5   // cpuHeat shows these as dim
        HStack(spacing: 8) {
            // tree guides
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle().fill(Theme.track).frame(width: 1).padding(.leading, 7).padding(.trailing, 8)
                }
            }
            Group {
                if node.kids.isEmpty { Color.clear } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }.frame(width: 12, height: 12)
            icon.frame(width: node.isGroup ? 22 : 16, height: node.isGroup ? 22 : 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).lineLimit(1).truncationMode(.tail)
                    .font(node.isGroup ? .system(size: 13, weight: .semibold)
                          : node.iconPath == nil ? .system(size: 12, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(node.isGroup ? Theme.text : Theme.text.opacity(0.85))
                if let sub = node.subtitle {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill").font(.system(size: 9))
                        Text(sub.hasPrefix("in ") ? String(sub.dropFirst(3)) : sub)
                    }
                    .font(.caption).foregroundStyle(Theme.cyan.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                HeatBar(fraction: node.cpu / maxCPU, color: idle ? Theme.purple : heat).frame(width: 80, height: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.1f%%", node.cpu)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(idle ? Theme.text.opacity(0.7) : heat)
                    if node.isGroup && node.cpu >= 10 {
                        Text(String(format: "%.1f cores", node.cpu / 100)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }.frame(width: 100, alignment: .trailing)
            }.frame(width: 200, alignment: .leading)
            HStack(spacing: 8) {
                HeatBar(fraction: node.gpu / maxGPU, color: Theme.cyan).frame(width: 50, height: 6)
                Text(node.gpu >= 0.05 ? String(format: "%.1f%%", node.gpu) : "–")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(node.gpu >= 5 ? Theme.cyan : Theme.text.opacity(node.gpu >= 0.05 ? 0.7 : 0.25))
                    .frame(width: 56, alignment: .trailing)
            }.frame(width: 120, alignment: .leading)
            HStack(spacing: 8) {
                HeatBar(fraction: Double(node.rssKB) / Double(maxRAM), color: Theme.purple).frame(width: 50, height: 6)
                Text(ramText(node.rssKB)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.85))
                    .frame(width: 80, alignment: .trailing)
            }.frame(width: 150, alignment: .leading)
            Text("\(node.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                .frame(width: 56, alignment: .trailing)
            Group {
                if canKill && (hover || confirmKill) {
                    Button { confirmKill = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                            .foregroundStyle(Theme.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help(node.isGroup ? "Quit \(node.title)" : "End this process")
                } else { Color.clear }
            }.frame(width: 40, height: 18)
        }
        .padding(.leading, 12).padding(.vertical, node.isGroup ? 7 : 4)
        .background(
            ZStack(alignment: .leading) {
                Rectangle().fill(hover ? Theme.purple.opacity(0.08) : isExpanded && node.isGroup ? Theme.hover : .clear)
                if node.isGroup && node.cpu >= 30 {   // hot-app marker on the left edge
                    Rectangle().fill(heat).frame(width: 3)
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if !node.kids.isEmpty { toggle() } }
        .help(node.tooltip)
        .contextMenu {
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.tooltip, forType: .string)
            }
            if node.isGroup, let p = node.iconPath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
            if canKill {
                Divider()
                Button(node.isGroup ? "Quit \(node.title)…" : "End process…") { confirmKill = true }
            }
        }
        .confirmationDialog(node.isGroup ? "Quit \(node.title)?" : "End \(shortTitle)?", isPresented: $confirmKill, titleVisibility: .visible) {
            if node.isGroup {
                Button("Quit \(node.title)") { quitApp(force: false) }
                Button("Force Quit", role: .destructive) { quitApp(force: true) }
            } else {
                Button("End process") { send(SIGTERM, tree: false) }
                if !node.kids.isEmpty {
                    Button("End process and its \(node.count - 1) child processes") { send(SIGTERM, tree: true) }
                }
                Button(node.kids.isEmpty ? "Force quit" : "Force quit, with child processes", role: .destructive) {
                    send(SIGKILL, tree: !node.kids.isEmpty)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(node.isGroup
                 ? "Processes it started usually close with it. Unsaved work may be lost."
                 : "PID \(node.pid). Unsaved work in it may be lost. Force quit stops it immediately, even if it's stuck.")
        }
        .alert("Couldn't end process", isPresented: Binding(get: { killError != nil }, set: { if !$0 { killError = nil } })) {
            Button("OK") {}
        } message: { Text(killError ?? "") }
    }

    var shortTitle: String {
        let t = node.title.split(separator: " ").first.map(String.init) ?? node.title
        return "“\(t)”"
    }

    static let changedMessage = "It has already quit, or its process ID now belongs to another process, so it was left alone."

    func quitApp(force: Bool) {
        // The pid must still be the process we sampled: pids are reused.
        guard stillSameProcess(node.pid, node.identity) else {
            killError = kill(node.pid, 0) != 0 && errno == EPERM
                ? "macOS didn't allow ending it. It belongs to the system or another user." : RowView.changedMessage
            refreshSoon(); return
        }
        if let app = NSRunningApplication(processIdentifier: node.pid) {
            _ = force ? app.forceTerminate() : app.terminate()
            refreshSoon()
        } else if quitSignalAllowed(exe: executablePath(node.pid), appBundle: node.appBundle, groupKey: node.title) {
            send(force ? SIGKILL : SIGTERM, tree: false)
        } else {
            killError = "Its main process isn't part of \(node.title), so it was left alone."
        }
    }

    /// Sends a signal to this process, or to it and everything under it (children first).
    /// Skips any pid whose parent or start time changed since the sample.
    func send(_ sig: Int32, tree: Bool) {
        var targets: [Node] = []
        func collect(_ n: Node) { n.kids.forEach(collect); if n.pid > 0 { targets.append(n) } }
        if tree { collect(node) } else { targets = [node] }
        var denied = 0, changed = 0
        for n in targets where n.pid != getpid() {
            guard stillSameProcess(n.pid, n.identity) else {
                // Another user's process can't be read, so it can't be checked: report it as denied.
                if kill(n.pid, 0) != 0 && errno == EPERM { denied += 1 } else { changed += 1 }
                continue
            }
            if kill(n.pid, sig) != 0 && errno == EPERM { denied += 1 }
        }
        if denied > 0 {
            killError = "macOS didn't allow ending \(denied == targets.count ? "it" : "\(denied) of \(targets.count) processes"). It belongs to the system or another user."
        } else if changed > 0 {
            killError = changed == targets.count ? RowView.changedMessage
                : "\(changed) of \(targets.count) processes had already quit or changed, so they were left alone."
        }
        refreshSoon()
    }

    func refreshSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { s.refresh() } }

    @ViewBuilder var icon: some View {
        if let p = node.iconPath {
            Image(nsImage: Icons.icon(p)).resizable()
        } else {
            Image(systemName: node.isGroup ? "gearshape.2.fill" : "terminal.fill").resizable().scaledToFit()
                .foregroundStyle(node.isGroup ? Theme.dim : Theme.green.opacity(0.8)).padding(node.isGroup ? 2 : 1)
        }
    }
}

// MARK: - Window

enum Tab: String, CaseIterable {
    case monitor = "Monitor", disk = "Disk"
    var icon: String { self == .monitor ? "waveform.path.ecg" : "internaldrive" }
    var heading: String { self == .monitor ? "System Activity" : "Disk Cleanup" }
}

struct RootView: View {
    @EnvironmentObject var s: Sampler
    @EnvironmentObject var cleaner: CleanerModel
    @State private var tab: Tab = RootView.firstTab
    @AppStorage(AppearanceMode.key) private var appearance: AppearanceMode = .system

    /// APPMON_TAB=disk opens the Disk tab (debug builds only).
    static var firstTab: Tab {
        #if APPMON_DEBUG
        if ProcessInfo.processInfo.environment["APPMON_TAB"] == "disk" { return .disk }
        #endif
        return .monitor
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            heading
            // Both tabs stay alive, so each keeps its own state (spec 4.1).
            ZStack {
                ContentView(expanded: demoMode ? Demo.expanded : [])
                    .opacity(tab == .monitor ? 1 : 0).allowsHitTesting(tab == .monitor)
                CleanerView()
                    .opacity(tab == .disk ? 1 : 0).allowsHitTesting(tab == .disk)
            }
        }
        .foregroundStyle(Theme.text)
        .background(PageBackground())
        .ignoresSafeArea(.container, edges: .top)   // draw into the hidden title bar strip
        .tint(Theme.purple)
        .onAppear {
            if tab == .disk { cleaner.activate() }
        }
        .onChange(of: appearance) { _, m in m.apply() }
        .onChange(of: tab) { _, t in if t == .disk { cleaner.activate() } }
    }

    /// Large page title, as in the reference design.
    var heading: some View {
        Text(tab.heading)
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
    }

    var titleBar: some View {
        ZStack {
            HStack(spacing: 10) {
                Image(nsImage: NSApp?.applicationIconImage ?? NSImage()).resizable().frame(width: 20, height: 20)
                Text("App Monitor").font(.system(size: 14, weight: .semibold))
                Spacer()
                Chip(text: s.paused ? "PAUSED" : "LIVE", color: s.paused ? Theme.yellow : Theme.green)
                AppearanceButton()
            }
            .padding(.leading, 92)   // sits right of the window buttons
            .padding(.trailing, 18)
            PillPicker(title: "Tab", selection: $tab, items: Tab.allCases, icon: { $0.icon }) { $0.rawValue }
                .frame(width: 220)   // centred on the window
        }
        .frame(height: TitleBarHeight.value)   // the window buttons are centred in this height (TallTitleBar)
        .background(TallTitleBar())
    }
}

enum TitleBarHeight { static let value: CGFloat = 52 }

/// Gives the window an empty unified toolbar, which makes macOS draw a 52pt title bar and centre the
/// window buttons in it. The SwiftUI title row then has room above and below its taller controls.
struct TallTitleBar: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, w.toolbar == nil else { return }
            let bar = NSToolbar(identifier: "AppMonitorTitleBar")
            bar.showsBaselineSeparator = false
            w.toolbar = bar
            w.toolbarStyle = .unified
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - App

@main
struct AppMonitorApp: App {
    @StateObject private var sampler = Sampler()
    @StateObject private var cleaner = CleanerModel()
    @StateObject private var space = SpaceMapModel()

    init() {
        #if APPMON_DEBUG
        Headless.runIfRequested()
        #endif
        // Before any window is shown, so a saved Light or Dark choice doesn't flash the system look.
        NotificationCenter.default.addObserver(forName: NSApplication.willFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppearanceMode.initial.apply() }
        }
    }

    var body: some Scene {
        WindowGroup("App Monitor") {
            RootView()
                .environmentObject(sampler)
                .environmentObject(cleaner)
                .environmentObject(space)
                .frame(minWidth: 1180, minHeight: 620)
                .onAppear {
                    #if APPMON_DEBUG
                    if let path = captureTo { captureWindow(to: path) }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 860)

        Settings {
            SettingsView().environmentObject(cleaner)
        }
    }
}

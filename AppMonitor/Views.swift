// Views and theme: dark "HUD" look, heat colours, live graphs.

import SwiftUI
import AppKit

// MARK: - Theme

extension Color {
    init(hex: UInt32, _ opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0D0F14)
    static let bgTop = Color(hex: 0x141826)
    static let panel = Color.white.opacity(0.035)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color(hex: 0xE6EDF3)
    static let dim = Color(hex: 0x8B949E)
    static let faint = Color(hex: 0x5A6270)
    static let purple = Color(hex: 0x8B6CFF)   // a nod to .NET purple
    static let cyan = Color(hex: 0x22D3EE)
    static let green = Color(hex: 0x3FB950)
    static let yellow = Color(hex: 0xE3B341)
    static let orange = Color(hex: 0xF0883E)
    static let red = Color(hex: 0xF85149)
    static let accent = LinearGradient(colors: [purple, cyan], startPoint: .leading, endPoint: .trailing)
    static let mono = Font.system(.body, design: .monospaced)

    /// Green → yellow → orange → red as load goes 0 → 1.
    static func heat(_ v: Double) -> Color {
        switch v {
        case ..<0.25: return green
        case ..<0.5: return yellow
        case ..<0.8: return orange
        default: return red
        }
    }
    /// Colour for a per-process CPU value (100 = one full core).
    static func cpuHeat(_ cpu: Double) -> Color { cpu < 5 ? dim : heat(cpu / 100) }
}

// MARK: - Formatting

func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }
func ramText(_ kb: Int) -> String {
    let mb = Double(kb) / 1024
    return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

enum SortKey: String, CaseIterable { case cpu = "CPU", gpu = "GPU", ram = "RAM" }

// MARK: - Building blocks

struct Panel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(title).tracking(1.5)
            }
            .font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }
}

struct Ring: View {
    let value: Double        // 0...1
    let color: Color
    let label: String
    let caption: String
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.005, min(1, value)))
                .stroke(LinearGradient(colors: [Theme.purple, color], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 6)
            VStack(spacing: 0) {
                Text(label).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                Text(caption).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.dim)
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
                    }.stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .shadow(color: color.opacity(0.7), radius: 3)
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
            Circle().fill(color).frame(width: 7, height: 7).shadow(color: color, radius: 3)
            Text(text).font(.caption.weight(.bold)).tracking(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
    }
}

struct HeatBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
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
                        Text(String(format: "%.1f", busy)).font(.system(size: 20, weight: .bold, design: .monospaced))
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
            ("Compressed", m.compressed, Color(hex: 0xDB61A2), "App memory squeezed to save space. A lot of it means RAM is getting tight."),
            ("Cache", m.cached, Theme.cyan.opacity(0.75), "Recently used files kept in RAM. Freed instantly when an app needs it, so it counts as available."),
            ("Free", m.free, Color.white.opacity(0.18), "Completely unused."),
        ]
        let (pName, pColor): (String, Color) = m.pressure >= 4 ? ("CRITICAL", Theme.red)
            : m.pressure >= 2 ? ("WARNING", Theme.orange) : ("NORMAL", Theme.green)
        Panel(title: "MEMORY", icon: "memorychip") {
            HStack(alignment: .top, spacing: 16) {
                Ring(value: usedFrac, color: Theme.heat(usedFrac * 0.9), label: gb(m.available).replacingOccurrences(of: " GB", with: ""),
                     caption: "GB FREE")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(gb(m.available)).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                        Text("available of \(gb(m.total))").font(.callout).foregroundStyle(Theme.dim)
                        Spacer()
                        Chip(text: "PRESSURE \(pName)", color: pColor)
                            .help("The best single sign of whether you need more RAM. Green is fine, whatever the other numbers say.")
                    }
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            ForEach(parts, id: \.0) { p in
                                RoundedRectangle(cornerRadius: 3).fill(p.2)
                                    .frame(width: max(0, g.size.width * p.1 / max(1, m.total) - 2))
                                    .help("\(p.0): \(gb(p.1))\n\(p.3)")
                            }
                        }
                    }.frame(height: 12)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow { legend(parts[0]); legend(parts[1]); legend(parts[2]) }
                        GridRow {
                            legend(parts[3]); legend(parts[4])
                            legend(("Swap", m.swapUsed, m.swapUsed > 1_073_741_824 ? Theme.orange : Color.white.opacity(0.35),
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
                            .font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
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
        n.sorted {
            switch sort {
            case .cpu: return ($0.cpu, $0.rssKB) > ($1.cpu, $1.rssKB)
            case .gpu: return ($0.gpu, $0.cpu) > ($1.gpu, $1.cpu)
            case .ram: return ($0.rssKB, $0.cpu) > ($1.rssKB, $1.cpu)
            }
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
            .padding(.horizontal, 14)

            toolbar.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

            VStack(spacing: 0) {
                columnHeader
                Rectangle().fill(Theme.stroke).frame(height: 1)
                ScrollView { LazyVStack(spacing: 0) { rowList } }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 14)

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
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            .frame(maxWidth: 300)

            Picker("", selection: $sort) {
                ForEach(SortKey.allCases, id: \.self) { Text("Sort: \($0.rawValue)") }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 260)

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
            Text("APP / PROCESS").padding(.leading, 44)
            Spacer()
            Text("CPU").frame(width: 200, alignment: .leading)
            Text("GPU").frame(width: 120, alignment: .leading)
            Text("RAM").frame(width: 150, alignment: .leading)
            Text("PROCS").frame(width: 56, alignment: .trailing)
            Color.clear.frame(width: 40, height: 1)
        }
        .font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(Theme.faint)
        .padding(.vertical, 8)
    }

    @ViewBuilder var rowList: some View {
        ForEach(Array(rows), id: \.id) { r in
            RowView(node: r.node, depth: r.depth, maxCPU: maxCPU, maxRAM: maxRAM, maxGPU: maxGPU,
                    isExpanded: expanded.contains(r.node.id)) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if expanded.contains(r.node.id) { expanded.remove(r.node.id) } else { expanded.insert(r.node.id) }
                }
            }
            if r.depth == 0 { Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1) }
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
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.12 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
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
        HStack(spacing: 8) {
            // tree guides
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1).padding(.leading, 7).padding(.trailing, 8)
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
                HeatBar(fraction: node.cpu / maxCPU, color: heat == Theme.dim ? Theme.purple : heat).frame(width: 80, height: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.1f%%", node.cpu)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(heat == Theme.dim ? Theme.text.opacity(0.7) : heat)
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
                Rectangle().fill(hover ? Theme.purple.opacity(0.10) : isExpanded && node.isGroup ? Color.white.opacity(0.03) : .clear)
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

    func quitApp(force: Bool) {
        if let app = NSRunningApplication(processIdentifier: node.pid) {
            _ = force ? app.forceTerminate() : app.terminate()
            refreshSoon()
        } else {
            send(force ? SIGKILL : SIGTERM, tree: false)
        }
    }

    /// Sends a signal to this process, or to it and everything under it (children first).
    func send(_ sig: Int32, tree: Bool) {
        var pids: [Int32] = []
        func collect(_ n: Node) { n.kids.forEach(collect); if n.pid > 0 { pids.append(n.pid) } }
        if tree { collect(node) } else { pids = [node.pid] }
        var denied = 0
        for p in pids where p != getpid() {
            if kill(p, sig) != 0 && errno == EPERM { denied += 1 }
        }
        if denied > 0 {
            killError = "macOS didn't allow ending \(denied == pids.count ? "it" : "\(denied) of \(pids.count) processes"). It belongs to the system or another user."
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

enum Tab: String, CaseIterable { case monitor = "Monitor", disk = "Disk" }

struct RootView: View {
    @EnvironmentObject var s: Sampler
    @EnvironmentObject var cleaner: CleanerModel
    @State private var tab: Tab = ProcessInfo.processInfo.environment["APPMON_TAB"] == "disk" ? .disk : .monitor

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            // Both tabs stay alive, so each keeps its own state (spec 4.1).
            ZStack {
                ContentView(expanded: demoMode ? Demo.expanded : [])
                    .opacity(tab == .monitor ? 1 : 0).allowsHitTesting(tab == .monitor)
                CleanerView()
                    .opacity(tab == .disk ? 1 : 0).allowsHitTesting(tab == .disk)
            }
        }
        .foregroundStyle(Theme.text)
        .background(LinearGradient(colors: [Theme.bgTop, Theme.bg], startPoint: .top, endPoint: .center).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)   // draw into the hidden title bar strip
        .preferredColorScheme(.dark)
        .tint(Theme.purple)
        .onAppear { if tab == .disk { cleaner.activate() } }
        .onChange(of: tab) { _, t in if t == .disk { cleaner.activate() } }
    }

    var titleBar: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage()).resizable().frame(width: 18, height: 18)
            Text("App Monitor").font(.headline)
            Chip(text: s.paused ? "PAUSED" : "LIVE", color: s.paused ? Theme.yellow : Theme.green)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            .padding(.leading, 8)
            Spacer()
        }
        .padding(.leading, 76)   // sits right of the window buttons
        .padding(.trailing, 14)
        .frame(height: 28)                    // same height as the title bar, so it lines up with the buttons
        .padding(.top, 3).padding(.bottom, 5)  // nudged to the window buttons' centre line
    }
}

// MARK: - App

@main
struct AppMonitorApp: App {
    @StateObject private var sampler = Sampler()
    @StateObject private var cleaner = CleanerModel()

    init() {
        #if APPMON_DEBUG
        Headless.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup("App Monitor") {
            RootView()
                .environmentObject(sampler)
                .environmentObject(cleaner)
                .frame(minWidth: 1180, minHeight: 620)
                .onAppear { if let path = captureTo { captureWindow(to: path) } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 820)

        Settings {
            SettingsView().environmentObject(cleaner).preferredColorScheme(.dark)
        }
    }
}

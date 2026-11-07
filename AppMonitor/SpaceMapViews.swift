// Space map view (spec 8): where space goes in the home folder and /Applications, with
// drill-down from cached data, owner labels, "large and old" highlights, Reveal in Finder for
// everything and Move to Trash for single items that pass the Space-map guard.

import SwiftUI
import AppKit

/// App icons, read once per bundle.
@MainActor enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

func copyText(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct SpaceToolbar: View {
    @EnvironmentObject var s: SpaceMapModel
    @EnvironmentObject var m: CleanerModel

    var body: some View {
        HStack(spacing: 10) {
            if s.scanning {
                ToolButton(icon: "stop.fill", text: "Stop") { s.stop() }
                ProgressView().controlSize(.small)
                Text(s.progress).font(.caption.monospacedDigit()).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            } else {
                ToolButton(icon: "chart.pie", text: s.scannedAt == nil ? "Map space" : "Scan again") {
                    m.refreshFDA()
                    s.scan(fda: m.fda)
                }
                .disabled(s.acting)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(ageText(now: ctx.date)).font(.caption).foregroundStyle(s.stopped ? Theme.yellow : Theme.dim).lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Filter this folder", text: $s.filter).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            .frame(maxWidth: 240)
        }
    }

    /// The scan is kept in memory only; its age tells how current it is.
    func ageText(now: Date) -> String {
        guard let d = s.scannedAt else { return "Shows which folders in your home folder and Applications take the most space." }
        let age = now.timeIntervalSince(d) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: d, relativeTo: now)
        return (s.stopped ? "Stopped part-way, " : "Scanned ") + age + "  ·  kept in memory only"
    }
}

struct SpaceMapView: View {
    @EnvironmentObject var s: SpaceMapModel
    @State private var shown = SpaceMapView.pageSize

    static let pageSize = 100

    enum Row: Identifiable {
        case node(SpaceNode)
        case other(SpaceNode)
        case more(Int)
        var id: String {
            switch self {
            case .node(let n): return "n:\(n.id.hashValue)"
            case .other(let n): return "o:\(n.id.hashValue)"
            case .more: return "more"
            }
        }
    }

    /// One flat list, so the lazy stack only builds the rows on screen (as the Junk view does).
    var rows: [Row] {
        guard let c = s.current else { return [] }
        let q = s.filter.trimmingCharacters(in: .whitespaces).lowercased()
        let kids = q.isEmpty ? c.children : c.children.filter {
            $0.name.lowercased().contains(q) || ($0.owner?.name.lowercased().contains(q) ?? false)
        }
        var out = kids.prefix(shown).map(Row.node)
        if kids.count > shown { out.append(.more(kids.count - shown)) }
        if q.isEmpty && c.otherCount > 0 { out.append(.other(c)) }
        return out
    }

    var body: some View {
        let _ = s.version
        VStack(spacing: 0) {
            if s.root == nil {
                empty
            } else {
                header
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { r in
                            switch r {
                            case .node(let n):
                                SpaceRow(node: n, parentSize: max(1, s.current?.size ?? 1), version: s.version)
                            case .other(let n):
                                HStack {
                                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.faint).frame(width: 22)
                                    Text("\(n.otherCount) smaller item\(n.otherCount == 1 ? "" : "s"), not listed one by one")
                                        .font(.caption).foregroundStyle(Theme.dim)
                                    Spacer()
                                    Text(byteText(n.otherSize)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
                                        .frame(width: 90, alignment: .trailing)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                            case .more(let left):
                                HStack {
                                    Button("Show \(min(left, Self.pageSize)) more (\(left) not shown)") { shown += Self.pageSize }
                                        .buttonStyle(.link).font(.caption)
                                    Spacer()
                                }
                                .padding(.leading, 50).padding(.vertical, 6)
                            }
                        }
                    }
                }
                .id(s.current.map { "\($0.id.hashValue)" } ?? "root")   // a new folder starts at the top
            }
        }
        .onChange(of: s.trail.count) { _, _ in shown = Self.pageSize }
        .sheet(item: $s.pending) { n in SpaceConfirmSheet(node: n).environmentObject(s) }
        .sheet(item: $s.result) { o in SpaceResultSheet(outcome: o).environmentObject(s) }
        .alert(item: $s.refusal) { r in
            Alert(title: Text("“\(r.name)” stays where it is"), message: Text(r.reason + ". You can still reveal it in Finder."),
                  dismissButton: .default(Text("OK")))
        }
    }

    var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Map where your space goes").font(.headline)
            Text("Lists the largest folders in your home folder and Applications, labelled by the app they belong to. Nothing is changed by looking.")
                .font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var header: some View {
        HStack(spacing: 8) {
            Button { s.goTo(depth: max(0, s.trail.count - 1)) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(s.trail.isEmpty).foregroundStyle(s.trail.isEmpty ? Theme.faint : Theme.text)
                .help("Up one level")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    crumb("Space map", depth: 0)
                    ForEach(Array(s.trail.enumerated()), id: \.offset) { i, n in
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                        crumb(n.name, depth: i + 1)
                    }
                }
            }
            Spacer()
            if let c = s.current, c.base != "" {
                Text("\(c.items.formatted()) items").font(.caption).foregroundStyle(Theme.dim)
                Text(byteText(c.size)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Button { reveal(c.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    func crumb(_ title: String, depth: Int) -> some View {
        let last = depth == s.trail.count
        return Button(title) { s.goTo(depth: depth) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: last ? .semibold : .regular))
            .foregroundStyle(last ? Theme.text : Theme.dim)
            .disabled(last)
    }
}

struct SpaceRow: View {
    let node: SpaceNode
    let parentSize: Int64
    let version: Int
    @EnvironmentObject var s: SpaceMapModel
    @State private var hover = false

    var body: some View {
        let why = s.reason(node)
        let old = node.largeAndOld(now: Date())
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let o = node.owner, o.name.caseInsensitiveCompare(node.name) != .orderedSame,
                       o.name.caseInsensitiveCompare((node.name as NSString).deletingPathExtension) != .orderedSame {
                        Text(o.name).font(.caption2.weight(.semibold)).foregroundStyle(Theme.cyan)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.cyan.opacity(0.12)))
                    }
                    if old {
                        Text("LARGE & OLD").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Theme.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.orange.opacity(0.14)))
                            .help("Over 1 GB and unchanged for at least \(SpaceNode.oldDays) days")
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(node.note != nil ? Theme.yellow : Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 12)
            if hover {
                Button { reveal(node.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Reveal in Finder")
                Button { s.ask(node) } label: { Image(systemName: why == nil ? "trash" : "lock") }
                    .buttonStyle(.plain).foregroundStyle(why == nil ? Theme.text : Theme.faint)
                    .help(why.map { "Reveal only: \($0)" } ?? "Move to Trash…")
            }
            HeatBar(fraction: Double(node.size) / Double(parentSize), color: old ? Theme.orange : Theme.purple)
                .frame(width: 120, height: 6)
            Text(byteText(node.size)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 90, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                .foregroundStyle(node.isDir && node.hasContents ? Theme.dim : .clear).frame(width: 10)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hover ? Theme.purple.opacity(0.08) : old ? Theme.orange.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { s.open(node) }
        .contextMenu {
            Button("Reveal in Finder") { reveal(node.path) }
            Button("Copy path") { copyText(node.path) }
            if node.isDir && node.hasContents { Button("Open") { s.open(node) } }
            Divider()
            if let why {
                Text("Reveal only: \(why)")
            } else {
                Button("Move to Trash…") { s.ask(node) }.disabled(s.acting || s.scanning)
            }
        }
    }

    var subtitle: String {
        if let n = node.note { return n }
        var parts: [String] = []
        if node.base != nil, node.base != "" { parts.append(tilde(node.path)) }
        if node.isDir { parts.append("\(node.items.formatted()) item\(node.items == 1 ? "" : "s")") }
        parts.append(ageLabel(node.newestDate))
        if node.incomplete { parts.append("not fully read") }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder var icon: some View {
        if let o = node.owner, !o.path.isEmpty, !demoMode || FileManager.default.fileExists(atPath: o.path) {
            Image(nsImage: AppIcons.icon(o.path)).resizable().scaledToFit()
        } else {
            Image(systemName: node.base == "" ? "chart.pie" : node.base != nil ? (node.name == "Applications" ? "square.grid.2x2" : "house")
                  : node.isDir ? (node.flags.contains(.package) ? "shippingbox" : "folder") : "doc")
                .font(.system(size: 14)).foregroundStyle(node.isDir ? Theme.accent : LinearGradient(colors: [Theme.dim], startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - Confirmation (one item, with its full path and size)

struct SpaceConfirmSheet: View {
    let node: SpaceNode
    @EnvironmentObject var s: SpaceMapModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move “\(node.name)” to the Trash?").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(node.path).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("\(byteText(node.size))\(node.isDir ? ", \(node.items.formatted()) items inside" : "")  ·  \(ageLabel(node.newestDate))")
                    .font(.callout).foregroundStyle(Theme.dim)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            Text("It goes to the Trash, so you can put it back. It is checked again first: it is skipped if it changed since the scan, or if an app has a file inside it open.")
                .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            if s.dryRun { Text("Dry run: nothing will be changed.").foregroundStyle(Theme.yellow) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { let n = node; dismiss(); s.trash(n) }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct SpaceResultSheet: View {
    let outcome: Outcome
    @EnvironmentObject var s: SpaceMapModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch outcome.status {
            case .moved:
                Label("Moved “\(outcome.name)” to the Trash, \(byteText(outcome.size))", systemImage: "trash").font(.headline)
                Text(outcome.reason == "Moved without Put Back"
                     ? "Moved without Finder, so Put Back isn't available for it. Space is freed when you empty the Trash."
                     : "Space is freed when you empty the Trash. To restore it, right-click it in the Trash and choose Put Back.")
                    .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            case .planned:
                Label("Dry run: “\(outcome.name)” would be moved to the Trash. Nothing was changed.", systemImage: "eye")
                    .foregroundStyle(Theme.yellow)
            default:
                Label("“\(outcome.name)” was not moved", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(Theme.orange)
                Text(outcome.reason ?? outcome.status.rawValue).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if outcome.status == .moved {
                    Button("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

extension Outcome: Identifiable { var id: String { path + status.rawValue } }

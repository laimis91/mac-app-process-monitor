// Disk tab (spec 4): header panels, toolbar, results, confirmation sheet, result summary,
// and the Settings window.

import SwiftUI
import AppKit

extension Risk {
    var color: Color {
        switch self {
        case .safe: return Theme.green
        case .review: return Theme.yellow
        case .requested: return Theme.cyan
        case .info: return Theme.dim
        }
    }
}

func ageLabel(_ d: Date?) -> String {
    guard let n = days(since: d, now: Date()) else { return "recently used" }
    return n == 0 ? "changed today" : n == 1 ? "1 day old" : "\(n) days old"
}

struct CheckBox: View {
    let state: Bool?          // nil = mixed
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : state == nil ? "minus.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(enabled ? (state == false ? Theme.dim : Theme.purple) : Theme.faint.opacity(0.5))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

// MARK: - Disk tab

struct CleanerView: View {
    @EnvironmentObject var m: CleanerModel
    @EnvironmentObject var space: SpaceMapModel
    @State private var expanded: Set<String> = []
    @State private var search = ""
    @State private var shown: [String: Int] = [:]   // items shown per expanded category

    var visible: [Category] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return m.categories }
        return m.categories.compactMap { c in
            if c.title.lowercased().contains(q) { return c }
            var c2 = c
            c2.items = c.items.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            return c2.items.isEmpty ? nil : c2
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                DiskPanel().frame(width: 320)
                ReclaimPanel().frame(width: 320)
                AccessPanel()
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)

            if m.fda != .granted && !m.bannerHidden { FDABanner().padding(.horizontal, 14).padding(.top, 12) }

            HStack(spacing: 12) {
                Picker("", selection: $m.view) {
                    ForEach(DiskView.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                if m.view == .spaceMap { SpaceToolbar() } else { toolbar }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

            VStack(spacing: 0) {
                if m.view == .spaceMap {
                    SpaceMapView()
                } else if m.categories.isEmpty { emptyState } else {
                    ScrollView { LazyVStack(spacing: 0) { results } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 14)

            Text((m.view == .spaceMap
                  ? "Sizes are space used on disk, as du counts it  ·  Only items you pick one at a time can go to the Trash; everything in ~/Library is Reveal only"
                  : "Sizes are upper estimates: APFS clones and snapshots can make the real gain smaller  ·  Moved items stay in the Trash until you empty it")
                 + (m.dryRun ? "  ·  DRY RUN: nothing is changed" : ""))
                .font(.caption2).foregroundStyle(m.dryRun ? Theme.yellow : Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .onAppear {
            #if APPMON_DEBUG
            // Fixture UI tests: APPMON_AUTOSCAN=1 scans at launch, APPMON_EXPAND=J-TMP,… opens categories.
            let env = ProcessInfo.processInfo.environment
            if CleanerConfig.fixtureRoot != nil {
                if let e = env["APPMON_EXPAND"] { expanded = Set(e.split(separator: ",").map(String.init)) }
                if env["APPMON_AUTOSCAN"] == "1" { m.view == .spaceMap ? space.scan(fda: m.fda) : m.scan() }
            }
            #endif
        }
        .sheet(isPresented: $m.confirming) { ConfirmSheet().environmentObject(m) }
        .sheet(isPresented: Binding(get: { m.outcomes != nil }, set: { if !$0 { m.outcomes = nil } })) {
            ResultSheet().environmentObject(m)
        }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            if m.scanning {
                ToolButton(icon: "stop.fill", text: "Stop") { m.stop() }
                ProgressView().controlSize(.small)
            } else {
                ToolButton(icon: "magnifyingglass.circle", text: m.lastScan == nil ? "Scan" : "Scan again") { m.scan() }
                    .disabled(m.cleaning)
            }
            Text(m.cleaning || m.scanning ? m.progress : lastScanText)
                .font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Filter results", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            .frame(maxWidth: 240)
            Text("Selected: \(byteText(m.selectedSize))").font(.callout.monospaced()).foregroundStyle(Theme.text)
            Button {
                m.confirming = true
            } label: {
                HStack(spacing: 5) { Image(systemName: "trash"); Text("Clean…") }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(m.selected.isEmpty ? Color.white.opacity(0.06) : Theme.purple.opacity(0.8)))
            }
            .buttonStyle(.plain)
            .disabled(m.selected.isEmpty || m.scanning || m.cleaning)
        }
    }

    var lastScanText: String {
        guard let d = m.lastScan else { return "Finds caches, logs, temporary files and developer caches you can remove." }
        if Date().timeIntervalSince(d) < 60 { return "Last scan just now" }
        return "Last scan " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: m.scanning ? "hourglass" : "internaldrive").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text(m.scanning ? m.progress : "Scan to see what you can clean").font(.headline)
            Text("Nothing is removed without your confirmation. Files go to the Trash, so you can restore them.")
                .font(.callout).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One flat list, so the lazy stack only builds the rows on screen. A category with
    /// thousands of items (old temporary files) shows them a page at a time.
    enum Row: Identifiable {
        case header(CategoryGroup)
        case category(Category, Bool)
        case item(Category, CleanItem)
        case more(Category, Int)
        case empty(Category)
        var id: String {
            switch self {
            case .header(let g): return "h:" + g.rawValue
            case .category(let c, _): return "c:" + c.id
            case .item(let c, let i): return "i:" + c.id + ":" + i.id
            case .more(let c, _): return "m:" + c.id
            case .empty(let c): return "e:" + c.id
            }
        }
    }

    static let pageSize = 100

    var rows: [Row] {
        var out: [Row] = []
        for g in [CategoryGroup.general, .developer] {
            let cats = visible.filter { $0.group == g }
            guard !cats.isEmpty else { continue }
            out.append(.header(g))
            for c in cats {
                let open = expanded.contains(c.id) || !search.isEmpty
                out.append(.category(c, open))
                guard open else { continue }
                if c.items.isEmpty { out.append(.empty(c)); continue }
                let limit = shown[c.id] ?? Self.pageSize
                out += c.items.prefix(limit).map { .item(c, $0) }
                if c.items.count > limit { out.append(.more(c, c.items.count - limit)) }
            }
        }
        return out
    }

    @ViewBuilder var results: some View {
        ForEach(rows) { r in
            switch r {
            case .header(let g):
                HStack {
                    Text(g.rawValue.uppercased()).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(Theme.faint)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            case .category(let c, let open):
                VStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                    CategoryRow(category: c, isExpanded: open) {
                        if expanded.contains(c.id) { expanded.remove(c.id) } else { expanded.insert(c.id) }
                    }
                }
            case .item(let c, let i):
                ItemRow(item: i, category: c)
            case .more(let c, let left):
                HStack {
                    Button("Show \(min(left, Self.pageSize)) more (\(left) not shown)") {
                        shown[c.id] = (shown[c.id] ?? Self.pageSize) + Self.pageSize
                    }
                    .buttonStyle(.link).font(.caption)
                    Spacer()
                }
                .padding(.leading, 60).padding(.vertical, 6)
            case .empty(let c):
                Text(c.notice ?? "Nothing to clean here.").font(.caption).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 60).padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Header panels

struct DiskPanel: View {
    var body: some View {
        let (total, free) = Self.capacity()
        let used = total > 0 ? (total - free) / total : 0
        Panel(title: "DISK", icon: "internaldrive") {
            HStack(spacing: 16) {
                Ring(value: used, color: Theme.heat(used * 0.9), label: String(format: "%.0f", free / 1e9), caption: "GB FREE")
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "%.0f GB", total / 1e9)).font(.system(size: 20, weight: .bold, design: .monospaced))
                    Text("Startup disk").font(.callout).foregroundStyle(Theme.dim)
                    Text(String(format: "%.0f%% used", used * 100)).font(.caption).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    static func capacity() -> (Double, Double) {
        if demoMode { return (994e9, 312e9) }
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Double(v?.volumeTotalCapacity ?? 0), Double(v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

struct ReclaimPanel: View {
    @EnvironmentObject var m: CleanerModel
    var body: some View {
        Panel(title: "RECLAIMABLE", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("up to").font(.callout).foregroundStyle(Theme.dim)
                    Text(byteText(m.reclaimable)).font(.system(size: 20, weight: .bold, design: .monospaced))
                }
                Text("\(byteText(m.selectedSize)) selected in \(m.selected.count) item\(m.selected.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(Theme.dim)
                Text(m.lastScan == nil ? "Run a scan to find out" : "Safe items are pre-selected. Review items are yours to pick.")
                    .font(.caption).foregroundStyle(Theme.faint)
            }
        }
    }
}

struct AccessPanel: View {
    @EnvironmentObject var m: CleanerModel
    var body: some View {
        Panel(title: "ACCESS", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Chip(text: m.fda == .granted ? "FULL DISK ACCESS" : "LIMITED ACCESS",
                         color: m.fda == .granted ? Theme.green : Theme.yellow)
                    Spacer()
                    if m.fda != .granted {
                        ToolButton(icon: "gearshape", text: "Open System Settings") { m.openFDASettings() }
                    }
                }
                Text(m.fda == .granted
                     ? "App Monitor can look in every folder it cleans."
                     : "Some folders, such as app containers and Mail, are skipped and shown as “Needs Full Disk Access”.")
                    .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Text("Removes only with your confirmation  ·  Never needs administrator rights")
                    .font(.caption).foregroundStyle(Theme.faint)
            }
        }
    }
}

struct FDABanner: View {
    @EnvironmentObject var m: CleanerModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.yellow).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access is off.").font(.callout.weight(.semibold))
                Text("App Monitor can't look inside some folders, such as app containers and Mail. Those parts are skipped. In System Settings, switch App Monitor on (or add it with the + button). If you just updated App Monitor, switch it off and on again.")
                    .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            ToolButton(icon: "gearshape", text: "Open System Settings") { m.openFDASettings() }
            ToolButton(icon: "xmark", text: "Not now") { m.bannerHidden = true }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.yellow.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.yellow.opacity(0.35)))
    }
}

// MARK: - Result rows

struct CategoryRow: View {
    let category: Category
    let isExpanded: Bool
    let toggle: () -> Void
    @EnvironmentObject var m: CleanerModel
    @State private var hover = false

    var risk: Risk {
        let rs = Set(category.items.map(\.risk))
        return rs.count == 1 ? rs.first! : rs.contains(.review) ? .review : rs.first ?? .info
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 12)
                if category.method == .tool, let i = category.items.first {
                    CheckBox(state: m.selected.contains(i.id), enabled: i.selectable) { m.toggle(i) }
                } else {
                    let items = m.checkboxItems(category)
                    CheckBox(state: items.isEmpty ? false : m.categoryState(category),
                             enabled: !items.isEmpty) { m.toggleCategory(category) }
                        .help(checkboxHelp)
                }
                Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                if let n = category.notice {
                    Text(n).font(.caption).foregroundStyle(Theme.yellow)
                    if n.contains("Full Disk Access") {
                        Button("Open Settings") { m.openFDASettings() }.buttonStyle(.link).font(.caption)
                    }
                }
                Chip(text: risk.rawValue.uppercased(), color: risk.color).frame(width: 92, alignment: .trailing)
                Text(sizeText).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(hover ? Theme.purple.opacity(0.08) : .clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: toggle)
            .contextMenu {
                if category.method == .trash {
                    let all = m.allTrashItems(category)
                    Button("Select All \(all.count) Items") { m.selectAll(category) }.disabled(all.isEmpty)
                    Button("Deselect All") { m.deselectAll(category) }
                }
            }
        }
    }

    var checkboxHelp: String {
        if category.items.contains(where: \.preselected) {
            return "Selects this category's Safe items. Right-click to select all, including Review items."
        }
        return "Selects every item that can be moved now. Items whose app is running are left out."
    }

    var sizeText: String {
        if category.items.first?.sizeUnknown == true { return "—" }
        return category.items.isEmpty && category.notice != nil ? "—" : byteText(category.size)
    }

    var subtitle: String {
        if category.method == .tool, let t = category.tool {
            return "Runs “\(t.command.joined(separator: "”, then “"))”, can't be undone"
        }
        let n = category.items.count
        return "\(n) item\(n == 1 ? "" : "s")  ·  \(category.explanation)"
    }

    var icon: String {
        switch category.id {
        case "J-CACHE": return "shippingbox"
        case "J-LOGS", "J-CRASH": return "doc.text"
        case "J-TMP": return "clock.arrow.circlepath"
        case "J-MAILDL": return "paperclip"
        case "J-IOSBK": return "iphone"
        case "J-TRASH": return "trash"
        case "J-DOCKER": return "cube"
        case "J-XC-DD", "J-XC-DS", "J-XC-SIM": return "hammer"
        case "J-UNITY", "J-UNITY-UPM": return "gamecontroller"
        default: return category.method == .tool ? "terminal" : "folder"
        }
    }
}

struct ItemRow: View {
    let item: CleanItem
    let category: Category
    @EnvironmentObject var m: CleanerModel
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 22, height: 1)
            if category.method == .tool { Color.clear.frame(width: 14, height: 1) } else {
                CheckBox(state: m.selected.contains(item.id), enabled: item.selectable) { m.toggle(item) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if item.risk != category.items.first?.risk || category.items.count > 1 {
                        Text(item.risk.rawValue).font(.caption2.weight(.bold)).foregroundStyle(item.risk.color)
                    }
                    if let r = item.runningOwner {
                        Text("\(r) is running: quit it first").font(.caption2.weight(.bold)).foregroundStyle(Theme.orange)
                    }
                }
                if let shown = item.measurePath ?? (item.path.hasPrefix("tool://") ? nil : item.path) {
                    Text(tilde(shown)).font(.caption.monospaced()).foregroundStyle(Theme.cyan.opacity(0.7))
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(item.reason).font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if item.method == .trash {
                Text(ageLabel(item.newest)).font(.caption).foregroundStyle(Theme.faint).frame(width: 100, alignment: .trailing)
            }
            Text(item.sizeUnknown ? "—" : byteText(item.size)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.85)).frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(hover ? Color.white.opacity(0.03) : .clear)
        .onHover { hover = $0 }
        .contextMenu {
            if let shown = item.measurePath ?? (item.path.hasPrefix("tool://") ? nil : item.path) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shown)]) }
                Button("Copy path") { copy(shown) }
            }
            if let t = category.tool { Button("Copy command") { copy(t.command.joined(separator: " && ")) } }
            if item.method == .trash {
                Divider()
                Button("Always ignore this item") { m.ignoreItem(item) }
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Confirmation sheet (spec 4.3)

struct ConfirmSheet: View {
    @EnvironmentObject var m: CleanerModel
    @Environment(\.dismiss) var dismiss
    @State private var quitList: [(String, [String])] = []
    @State private var previews: [String: String] = [:]

    var body: some View {
        let pairs = m.selectedPairs
        let trash = pairs.filter { $0.1.method == .trash }
        let tools = pairs.filter { $0.1.method == .tool }
        VStack(alignment: .leading, spacing: 14) {
            Text("Clean \(pairs.count) item\(pairs.count == 1 ? "" : "s"), up to \(byteText(m.selectedSize))?").font(.title3.weight(.semibold))
            if !trash.isEmpty {
                Label("\(trash.count) moved to the Trash, \(byteText(trash.reduce(0) { $0 + $1.1.size })). Finder's Put Back returns them to where they were.",
                      systemImage: "trash").foregroundStyle(Theme.text)
            }
            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(tools.count) tool cleanup\(tools.count == 1 ? "" : "s"). These can't be undone:", systemImage: "terminal")
                        .foregroundStyle(Theme.orange)
                    ForEach(tools, id: \.1.id) { c, _ in
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(c.tool?.commands ?? [], id: \.self) { args in
                                Text(([c.tool?.executable ?? c.tool?.tool ?? ""] + args).joined(separator: " "))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let p = previews[c.id] {
                                ScrollView { Text(p).font(.caption2.monospaced()).foregroundStyle(Theme.dim)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                                    .frame(maxHeight: 90)
                            }
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    }
                }
            }
            if !quitList.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These apps are running. Their items are skipped unless you quit them first:").foregroundStyle(Theme.yellow)
                    ForEach(quitList, id: \.0) { name, ids in
                        HStack { Text(name); Spacer(); Button(m.dryRun ? "Quit (off in dry run)" : "Quit") { m.quit(ids); refreshSoon() }.disabled(m.dryRun) }
                    }
                }
            }
            if m.dryRun { Text("Dry run: nothing will be changed.").foregroundStyle(Theme.yellow) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clean", role: .destructive) { dismiss(); m.clean() }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            quitList = m.appsToQuit()
            for (c, _) in tools { if let t = c.tool, let exe = t.executable, let pv = t.preview { loadPreview(c.id, exe, pv) } }
        }
    }

    func refreshSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { quitList = m.appsToQuit() } }

    func loadPreview(_ id: String, _ exe: String, _ args: [String]) {
        previews[id] = "Checking what it would remove…"
        Task.detached {
            let r = ToolRunner.run(exe, args, timeout: 60)
            let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { previews[id] = text.isEmpty ? "Nothing to remove." : String(text.suffix(3000)) }
        }
    }
}

// MARK: - Result summary (spec 4.4)

struct ResultSheet: View {
    @EnvironmentObject var m: CleanerModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let o = m.outcomes ?? []
        let moved = o.filter { $0.status == .moved }
        let ran = o.filter { $0.status == .ran }
        let planned = o.filter { $0.status == .planned }
        let skipped = o.filter { $0.status == .skipped || $0.status == .failed }
        VStack(alignment: .leading, spacing: 12) {
            Text(m.lastRunWasDry ? "Dry run finished" : "Cleaning finished").font(.title3.weight(.semibold))
            if !moved.isEmpty {
                Label("\(byteText(moved.reduce(0) { $0 + $1.size })) moved to the Trash (\(moved.count) items)", systemImage: "trash")
            }
            if !ran.isEmpty {
                Label("\(byteText(ran.reduce(0) { $0 + $1.size })) freed by tool cleanups", systemImage: "terminal")
            }
            if !planned.isEmpty {
                Label("\(planned.count) actions planned, none taken (dry run)", systemImage: "eye").foregroundStyle(Theme.yellow)
            }
            if !skipped.isEmpty {
                Text("Skipped \(skipped.count):").foregroundStyle(Theme.orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(skipped.enumerated()), id: \.offset) { _, s in
                            Text("\(s.name): \(s.reason ?? s.status.rawValue)").font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
            if !moved.isEmpty {
                Text("Space in the Trash is freed when you empty it. To restore an item, right-click it in the Trash and choose Put Back.")
                    .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            let noPutBack = moved.filter { $0.reason == "Moved without Put Back" }.count
            if noPutBack > 0 {
                Text("\(noPutBack) item\(noPutBack == 1 ? " was" : "s were") moved without Finder, so Put Back isn't available for \(noPutBack == 1 ? "it" : "them"). To use Finder next time, allow App Monitor to control Finder in System Settings → Privacy & Security → Automation.")
                    .font(.callout).foregroundStyle(Theme.yellow).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !moved.isEmpty {
                    Button("Open Trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - Settings window (spec 4.6)

struct SettingsView: View {
    @EnvironmentObject var m: CleanerModel
    @State private var drafts: [AgeField: String] = [:]
    @State private var errors: [AgeField: String] = [:]

    let fields: [AgeField] = [.logs, .temp, .leftovers, .lowConfidence, .mail]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Age limits").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(fields, id: \.self) { f in
                    GridRow {
                        Text(f.title)
                        HStack(spacing: 4) {
                            TextField("", text: binding(f)).frame(width: 56).multilineTextAlignment(.trailing)
                                .onSubmit { commit(f) }
                            Text("days").foregroundStyle(.secondary)
                        }
                        Text(errors[f] ?? "\(f.range(m.limits).lowerBound)–\(f.range(m.limits).upperBound)")
                            .font(.caption).foregroundStyle(errors[f] == nil ? Color.secondary : Color.red)
                    }
                }
            }
            HStack {
                Button("Restore defaults") { m.restoreDefaults(); drafts = [:]; errors = [:] }
                Spacer()
                // Applied twice, because the two leftover limits depend on each other.
                Button("Apply") { for _ in 0..<2 { fields.forEach(commit) } }.keyboardShortcut(.defaultAction)
            }
            Divider()
            Text("Ignored items").font(.headline)
            if m.ignore.isEmpty {
                Text("None. Right-click an item in the Disk tab and choose “Always ignore this item”.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(m.ignore, id: \.self) { p in
                            HStack {
                                Text(tilde(p)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Remove") { m.unignore(p) }
                            }
                        }
                    }
                }.frame(maxHeight: 140)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func binding(_ f: AgeField) -> Binding<String> {
        Binding(get: { drafts[f] ?? String(m.limits[f]) }, set: { drafts[f] = $0 })
    }

    func commit(_ f: AgeField) {
        guard let text = drafts[f] else { return }
        guard let v = Int(text.trimmingCharacters(in: .whitespaces)) else { errors[f] = "Enter a whole number of days"; return }
        if let why = m.setLimit(f, v) { errors[f] = why } else { errors[f] = nil; drafts[f] = nil }
    }
}

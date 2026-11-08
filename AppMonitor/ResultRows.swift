// Disk tab results (spec 4.2): the flat list of groups, categories and items.

import SwiftUI
import AppKit

struct ResultsList: View {
    @EnvironmentObject var m: CleanerModel

    /// The categories that match the filter `q` (already trimmed), with only their matching
    /// items unless the title matches.
    func visible(_ q: String) -> [Category] {
        guard !q.isEmpty else { return m.categories }
        return m.categories.compactMap { c in
            if c.title.localizedCaseInsensitiveContains(q) { return c }
            var c2 = c
            c2.items = c.items.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) }
            return c2.items.isEmpty ? nil : c2
        }
    }

    var body: some View {
        if m.categories.isEmpty { emptyState } else {
            ScrollView { LazyVStack(spacing: 0) { results } }
        }
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: m.scanning ? "hourglass" : m.kind.emptyIcon)
                .font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text(m.scanning ? m.progress
                 : m.stopped ? "The scan was stopped before it finished"
                 : m.kind.emptyTitle(scanned: m.lastScan != nil)).font(.headline)
            Text(m.stopped && !m.scanning ? "Scan again to see the whole list. " + m.kind.emptyDetail(m.limitsInUse)
                 : m.kind.emptyDetail(m.limitsInUse))
                .font(.callout).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One flat list, so the lazy stack only builds the rows on screen. A category with
    /// thousands of items (old temporary files) shows them a page at a time.
    enum Row: Identifiable {
        case header(CategoryGroup, Int)
        case category(Category, Bool)
        case item(Category, CleanItem)
        case more(Category, Int)
        case empty(Category)
        var id: String {
            switch self {
            case .header(let g, _): return "h:" + g.rawValue
            case .category(let c, _): return "c:" + c.id
            case .item(let c, let i): return "i:" + c.id + ":" + i.id
            case .more(let c, _): return "m:" + c.id
            case .empty(let c): return "e:" + c.id
            }
        }
    }

    static let pageSize = 100

    func rows(_ q: String) -> [Row] {
        var out: [Row] = []
        let shown = visible(q)
        for g in m.kind.groups {
            let cats = shown.filter { $0.group == g }
            guard !cats.isEmpty else { continue }
            out.append(.header(g, cats.count))
            // Possible (Low-confidence) leftovers stay collapsed until the user opens them (spec 9.3).
            if g == .possible && !m.possibleOpen && q.isEmpty { continue }
            for c in cats {
                let open = m.expanded.contains(c.id) || !q.isEmpty
                out.append(.category(c, open))
                guard open else { continue }
                if c.items.isEmpty { out.append(.empty(c)); continue }
                let limit = m.shown[c.id] ?? Self.pageSize
                out += c.items.prefix(limit).map { .item(c, $0) }
                if c.items.count > limit { out.append(.more(c, c.items.count - limit)) }
            }
        }
        return out
    }

    @ViewBuilder var results: some View {
        let q = m.query
        ForEach(rows(q)) { r in
            switch r {
            case .header(let g, let n):
                if g == .possible {
                    Button { m.possibleOpen.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(m.possibleOpen || !q.isEmpty ? 90 : 0))
                            Text(g.rawValue.uppercased()).font(.caption2.weight(.bold)).tracking(1.2)
                            Text("\(n) app\(n == 1 ? "" : "s")").font(.caption2)
                            Spacer()
                        }
                        .foregroundStyle(Theme.yellow.opacity(0.9)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                } else {
                    HStack {
                        Text(g.rawValue.uppercased()).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(Theme.faint)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                }
            case .category(let c, let open):
                VStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                    CategoryRow(category: c, isExpanded: open) {
                        if m.expanded.contains(c.id) { m.expanded.remove(c.id) } else { m.expanded.insert(c.id) }
                    }
                }
            case .item(let c, let i):
                ItemRow(item: i, category: c)
            case .more(let c, let left):
                ShowMoreRow(left: left, pageSize: Self.pageSize, leading: 60) {
                    m.shown[c.id] = (m.shown[c.id] ?? Self.pageSize) + Self.pageSize
                }
            case .empty(let c):
                Text(m.kind.emptyCategoryText(c)).font(.caption).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 60).padding(.bottom, 8)
            }
        }
    }
}

struct CategoryRow: View {
    let category: Category
    let isExpanded: Bool
    let toggle: () -> Void
    @EnvironmentObject var m: CleanerModel
    @State private var hover = false

    var body: some View {
        let s = m.summary(category)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 12)
                    .accessibilityHidden(true)
                if category.method == .tool, let i = category.items.first {
                    CheckBox(label: category.title, state: m.selected.contains(i.id), enabled: i.selectable) { m.toggle(i) }
                } else {
                    CheckBox(label: category.title, state: s.checkboxIDs.isEmpty ? false : m.categoryState(s),
                             enabled: !s.checkboxIDs.isEmpty) { m.toggleCategory(category) }
                        .help(s.hasSafe ? "Selects this category's Safe items. Right-click to select all, including Review items."
                              : "Selects every item that can be moved now. Items whose app is running are left out.")
                }
                Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityAction { toggle() }
                Spacer()
                if let n = category.notice {
                    Text(n).font(.caption).foregroundStyle(Theme.yellow)
                    if n.contains("Full Disk Access") {
                        Button("Open Settings") { m.openFDASettings() }.buttonStyle(.link).font(.caption)
                    }
                }
                Chip(text: s.risk.rawValue.uppercased(), color: s.risk.color).fixedSize().frame(width: 110, alignment: .trailing)
                Text(sizeText(s)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(hover ? Theme.purple.opacity(0.08) : .clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: toggle)
            .contextMenu {
                if category.method == .trash {
                    Button("Select All \(s.trashIDs.count) Items") { m.selectAll(category) }.disabled(s.trashIDs.isEmpty)
                    Button("Deselect All") { m.deselectAll(category) }
                }
            }
        }
    }

    func sizeText(_ s: CategorySummary) -> String {
        if category.items.first?.sizeUnknown == true { return "—" }
        return category.items.isEmpty && category.notice != nil ? "—" : byteText(s.size)
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
        case Leftovers.fdaID: return "lock"
        case Leftovers.spotlightID: return "magnifyingglass"
        case Uninstaller.fdaID: return "lock"
        case "U-APP": return "app"
        case "U-CACHE": return "shippingbox"
        case "U-DATA": return "gearshape"
        case "U-MORE": return "shippingbox.and.arrow.backward"
        case "U-NAMED": return "questionmark.folder"
        case "U-KEPT": return "lock.shield"
        default:
            if category.id.hasPrefix("L:") { return "app.dashed" }
            return category.method == .tool ? "terminal" : "folder"
        }
    }
}

struct ItemRow: View {
    let item: CleanItem
    let category: Category
    @EnvironmentObject var m: CleanerModel
    @State private var hover = false

    /// The folder shown and revealed: a tool row's measured cache folder, otherwise the item.
    var shownPath: String? { item.measurePath ?? (item.path.hasPrefix("tool://") ? nil : item.path) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 22, height: 1)
            if category.method == .tool { Color.clear.frame(width: 14, height: 1) } else {
                CheckBox(label: item.name, state: m.selected.contains(item.id), enabled: item.selectable) { m.toggle(item) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if category.items.count > 1 {   // a single item has its category's risk
                        Text(item.risk.rawValue).font(.caption2.weight(.bold)).foregroundStyle(item.risk.color)
                    }
                    if let r = item.runningOwner {
                        Text("\(r) is running: quit it first").font(.caption2.weight(.bold)).foregroundStyle(Theme.orange)
                    }
                }
                if let shown = shownPath {
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
            if let shown = shownPath {
                Button("Reveal in Finder") { reveal(shown) }
                Button("Copy path") { copyText(shown) }
            }
            if let t = category.tool { Button("Copy command") { copyText(t.command.joined(separator: " && ")) } }
            if item.method == .trash && !item.appBundle {
                Divider()
                Button("Always ignore this item") { m.ignoreItem(item) }
            }
        }
    }
}

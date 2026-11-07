// Disk tab state. Owned by AppMonitorApp next to Sampler, so it survives tab switches.

import SwiftUI
import AppKit

/// The Disk tab's views (spec 4.2). Leftovers arrive in phase 3.
enum DiskView: String, CaseIterable { case junk = "Junk", spaceMap = "Space map" }

@MainActor
final class CleanerModel: ObservableObject {
    @Published var view: DiskView = ProcessInfo.processInfo.environment["APPMON_DISKVIEW"] == "space" ? .spaceMap : .junk
    @Published var categories: [Category] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var selected: Set<String> = []
    @Published var fda: FDAStatus = .unknown
    @Published var bannerHidden = false
    @Published var lastScan: Date?
    @Published var cleaning = false
    @Published var confirming = false
    @Published var outcomes: [Outcome]?
    @Published var lastRunWasDry = false
    @Published private(set) var limits: AgeLimits
    @Published private(set) var ignore: [String]

    private var cancel: CancelFlag?
    private var context: ScanContext?
    let dryRun = CleanerConfig.dryRun
    private let defaults = UserDefaults.standard

    init() {
        var stored: [AgeField: Int] = [:]
        for f in AgeField.allCases where defaults.object(forKey: "age." + f.rawValue) != nil {
            stored[f] = defaults.integer(forKey: "age." + f.rawValue)
        }
        limits = AgeLimits.sanitized(stored)
        ignore = defaults.stringArray(forKey: "ignoredItems") ?? []
        saveLimits()
        if demoMode {
            categories = Demo.diskCategories()
            selected = Set(categories.flatMap(\.items).filter(\.preselected).map(\.id))
            fda = .denied
            lastScan = Date()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.active == true { self?.refreshFDA() } }
        }
    }

    // MARK: Permissions

    /// Probing for Full Disk Access may show a macOS prompt, so it starts only once the Disk tab is opened.
    private var active = false
    func activate() {
        guard !active else { return }
        active = true
        refreshFDA()
    }

    func refreshFDA() {
        guard !demoMode else { return }
        fda = CleanerConfig.fda(CleanerConfig.roots)
    }

    func openFDASettings() {
        if let u = URL(string: Permissions.settingsURL), NSWorkspace.shared.open(u) { return }
        if let u = URL(string: Permissions.settingsFallbackURL) { NSWorkspace.shared.open(u) }
    }

    // MARK: Scanning

    func scan() {
        guard !scanning, !cleaning else { return }
        if demoMode { categories = Demo.diskCategories(); lastScan = Date(); return }
        refreshFDA()
        let flag = CancelFlag()
        cancel = flag
        scanning = true
        categories = []
        selected = []
        progress = "Starting…"
        let limits = self.limits, ignore = self.ignore
        Task.detached(priority: .utility) { [self] in
            let ctx = CleanerConfig.context(limits: limits, ignore: ignore, cancel: flag)
            await MainActor.run { self.context = ctx }
            Rules.scan(ctx, progress: { id in
                Task { @MainActor in self.progress = Self.progressText(id) }
            }, found: { c in
                Task { @MainActor in self.add(c) }
            })
            await MainActor.run {
                self.scanning = false
                self.progress = flag.isSet ? "Stopped" : ""
                self.lastScan = Date()
            }
        }
    }

    nonisolated static func progressText(_ id: String) -> String {
        "Scanning " + (Rules.titles[id] ?? id).lowercased() + "…"
    }

    func stop() { cancel?.set() }

    private func add(_ c: Category) {
        guard scanning else { return }
        var list = categories.filter { $0.id != c.id } + [c]
        list.sort { (Rules.order.firstIndex(of: $0.id) ?? 99) < (Rules.order.firstIndex(of: $1.id) ?? 99) }
        categories = list
        for i in c.items where i.preselected { selected.insert(i.id) }
    }

    // MARK: Selection

    var allItems: [(Category, CleanItem)] { categories.flatMap { c in c.items.map { (c, $0) } } }
    var selectedPairs: [(Category, CleanItem)] { allItems.filter { selected.contains($0.1.id) } }
    var selectedSize: Int64 { selectedPairs.reduce(0) { $0 + $1.1.size } }
    var reclaimable: Int64 { allItems.filter { $0.1.selectable }.reduce(0) { $0 + $1.1.size } }

    func toggle(_ item: CleanItem) {
        guard item.selectable else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    /// What a category checkbox selects (spec 4.2): its Safe items when it has any. A category
    /// with only Review items selects all of them, except items whose app is running.
    func checkboxItems(_ c: Category) -> [CleanItem] {
        let safe = c.items.filter(\.preselected)
        return safe.isEmpty ? allTrashItems(c) : safe
    }

    /// Every item of the category that can be moved to the Trash now (context menu "Select all").
    func allTrashItems(_ c: Category) -> [CleanItem] {
        c.items.filter { $0.selectable && $0.method == .trash && $0.runningOwner == nil }
    }

    /// true: all ticked, false: none, nil: some. nil with an empty list means nothing to select.
    func categoryState(_ c: Category) -> Bool? {
        let items = checkboxItems(c)
        guard !items.isEmpty else { return nil }
        let n = items.filter { selected.contains($0.id) }.count
        return n == items.count ? true : n == 0 ? false : nil
    }

    func toggleCategory(_ c: Category) {
        let items = checkboxItems(c)
        if items.allSatisfy({ selected.contains($0.id) }) { selected.subtract(items.map(\.id)) }
        else { selected.formUnion(items.map(\.id)) }
    }

    func selectAll(_ c: Category) { selected.formUnion(allTrashItems(c).map(\.id)) }
    func deselectAll(_ c: Category) { selected.subtract(c.items.map(\.id)) }

    // MARK: Cleaning

    /// Apps that must quit before some selected items can be cleaned.
    func appsToQuit() -> [(String, [String])] {
        let running = CleanerConfig.runningApps()
        var out: [String: Set<String>] = [:]
        for (_, i) in selectedPairs {
            for r in running where i.owners.contains(where: { BundleIDs.related(r.id, $0) })
                || i.ownerNames.contains(where: { $0.caseInsensitiveCompare(r.name) == .orderedSame }) {
                out[r.name, default: []].insert(r.id)
            }
        }
        return out.map { ($0.key, Array($0.value)) }.sorted { $0.0 < $1.0 }
    }

    func quit(_ ids: [String]) {
        guard !dryRun, CleanerConfig.fixtureRoot == nil, !demoMode else { return }   // never quits real apps when testing
        for a in NSWorkspace.shared.runningApplications where ids.contains(a.bundleIdentifier ?? "") { a.terminate() }
    }

    func clean() {
        guard !cleaning, !scanning else { return }
        let pairs = selectedPairs
        guard !pairs.isEmpty else { return }
        if demoMode {
            outcomes = pairs.map { Outcome(path: $0.1.path, name: $0.1.name, category: $0.0.id,
                                           status: $0.1.method == .tool ? .ran : .moved, size: $0.1.size) }
            return
        }
        guard let ctx = context else { return }
        cleaning = true
        let env = CleanerConfig.cleanEnvironment(ctx)
        Task.detached(priority: .userInitiated) { [self] in
            let result = Cleaner.clean(pairs, env: env) { name in
                Task { @MainActor in self.progress = "Cleaning \(name)…" }
            }
            await MainActor.run {
                let done = Set(result.filter { $0.status == .moved || $0.status == .ran }.map(\.path))
                for i in self.categories.indices {
                    if self.categories[i].method == .trash { self.categories[i].items.removeAll { done.contains($0.path) } }
                }
                self.categories.removeAll { $0.items.isEmpty && $0.notice == nil }
                self.selected.subtract(done)
                self.lastRunWasDry = env.dryRun
                self.outcomes = result
                self.cleaning = false
                self.progress = ""
            }
        }
    }

    // MARK: Ignore list and settings

    func ignoreItem(_ item: CleanItem) {
        guard !ignore.contains(where: { $0.caseInsensitiveCompare(item.path) == .orderedSame }) else { return }
        ignore.append(item.path)
        defaults.set(ignore, forKey: "ignoredItems")
        selected.remove(item.id)
        for i in categories.indices { categories[i].items.removeAll { $0.id == item.id } }
    }

    func unignore(_ path: String) {
        ignore.removeAll { $0 == path }
        defaults.set(ignore, forKey: "ignoredItems")
    }

    /// Stores a new age limit, or returns the reason it was refused (never clamped).
    func setLimit(_ f: AgeField, _ value: Int) -> String? {
        if let why = limits.validate(f, value) { return why }
        limits[f] = value
        saveLimits()
        return nil
    }

    func restoreDefaults() { limits = AgeLimits(); saveLimits() }

    private func saveLimits() {
        for f in AgeField.allCases { defaults.set(limits[f], forKey: "age." + f.rawValue) }
    }
}

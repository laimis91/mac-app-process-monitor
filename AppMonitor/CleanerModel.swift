// Disk tab state. Owned by AppMonitorApp next to Sampler, so it survives tab switches.

import SwiftUI
import AppKit

/// The Disk tab's views (spec 4.2).
enum DiskView: String, CaseIterable {
    case junk = "Junk", leftovers = "Leftovers", uninstall = "Uninstaller", spaceMap = "Space map"
}

/// What a results list holds: junk rules (spec 7), the leftovers finder (spec 9) or the files of
/// one app being uninstalled (spec 10).
enum CleanerKind { case junk, leftovers, uninstall }

/// An app the user can pick in the Uninstaller, with the reason it can't be uninstalled, if any.
struct AppChoice: Identifiable {
    let app: AppInfo
    let refusal: String?
    var id: String { app.path }
}

/// One results list with its own scan, selection and clean. The junk model owns the settings and
/// the ignore list and holds the leftovers model as `leftovers`; both use the same row views.
@MainActor
final class CleanerModel: ObservableObject {
    @Published var view: DiskView = {
        switch ProcessInfo.processInfo.environment["APPMON_DISKVIEW"] {
        case "space": return .spaceMap
        case "leftovers": return .leftovers
        case "uninstall": return .uninstall
        default: return .junk
        }
    }()
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
    // List state, kept here so it survives switching views
    @Published var search = ""
    @Published var expanded: Set<String> = []
    @Published var shown: [String: Int] = [:]
    @Published var possibleOpen = false

    let kind: CleanerKind
    private weak var owner: CleanerModel?          // the junk model, for the leftovers model
    // Uninstaller state (uninstall model only)
    @Published var choices: [AppChoice] = []
    @Published var loadingChoices = false
    @Published var target: UninstallTarget?
    @Published var refusal: String?          // why the last dropped or picked app can't be uninstalled
    private(set) var targetPath: String?

    /// The leftovers list (junk model only).
    private(set) lazy var leftovers: CleanerModel = CleanerModel(kind: .leftovers, owner: self)
    /// The uninstaller's list (junk model only).
    private(set) lazy var uninstaller: CleanerModel = CleanerModel(kind: .uninstall, owner: self)
    /// Every results list, for changes that concern them all.
    private var lists: [CleanerModel] { [root, root.leftovers, root.uninstaller] }
    private var root: CleanerModel { owner ?? self }
    /// The age limits the next scan uses (the junk model's settings).
    var limitsInUse: AgeLimits { root.limits }

    private var cancel: CancelFlag?
    private var context: ScanContext?
    let dryRun = CleanerConfig.dryRun
    private let defaults = UserDefaults.standard

    init(kind: CleanerKind = .junk, owner: CleanerModel? = nil) {
        self.kind = kind
        self.owner = owner
        var stored: [AgeField: Int] = [:]
        for f in AgeField.allCases where defaults.object(forKey: "age." + f.rawValue) != nil {
            stored[f] = defaults.integer(forKey: "age." + f.rawValue)
        }
        limits = AgeLimits.sanitized(stored)
        ignore = defaults.stringArray(forKey: "ignoredItems") ?? []
        saveLimits()
        if demoMode {
            switch kind {
            case .junk: categories = Demo.diskCategories()
            case .leftovers: categories = Demo.leftoverCategories()
            case .uninstall: (target, categories) = Demo.uninstall()
            }
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
        if demoMode { lastScan = Date(); return }
        if kind == .uninstall && targetPath == nil { loadChoices(); return }
        refreshFDA()
        let flag = CancelFlag()
        cancel = flag
        scanning = true
        categories = []
        selected = []
        progress = "Starting…"
        let limits = root.limits, ignore = root.ignore
        let kind = self.kind
        Task.detached(priority: .utility) { [self] in
            let ctx = CleanerConfig.context(limits: limits, ignore: ignore, cancel: flag)
            await MainActor.run { self.context = ctx }
            if kind == .uninstall, let path = await MainActor.run(body: { self.targetPath }) {
                let result = Uninstaller.plan(path, ctx: ctx, probes: CleanerConfig.uninstallProbes(ctx.roots)) { text in
                    Task { @MainActor in self.progress = text }
                }
                await MainActor.run {
                    if !flag.isSet, let result, self.targetPath == path {
                        self.target = result.target
                        self.categories = result.categories
                        self.selected = Set(result.categories.flatMap(\.items).filter(\.preselected).map(\.id))
                    }
                    self.scanning = false
                    self.progress = flag.isSet ? "Stopped" : ""
                    self.lastScan = Date()
                    if flag.isSet && self.target == nil { self.targetPath = nil; self.lastScan = nil }   // back to the app list
                    if result == nil { self.refusal = "This app is no longer there."; self.chooseAnother() }
                }
                return
            }
            if kind == .leftovers {
                let result = Leftovers.scan(ctx) { text in Task { @MainActor in self.progress = text } }
                await MainActor.run {
                    if !flag.isSet { self.categories = result.categories }
                    self.scanning = false
                    self.progress = flag.isSet ? "Stopped" : ""
                    self.lastScan = Date()
                }
                return
            }
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

    // MARK: Uninstaller (spec 10)

    /// Lists the apps in /Applications and ~/Applications.
    func loadChoices() {
        guard !loadingChoices else { return }
        if demoMode { return }
        loadingChoices = true
        Task.detached(priority: .userInitiated) { [self] in
            let list = Uninstaller.choices(CleanerConfig.roots, selfIDs: Uninstaller.selfIDs).map { AppChoice(app: $0.app, refusal: $0.refusal) }
            await MainActor.run { self.choices = list; self.loadingChoices = false }
        }
    }

    /// Picks the app to uninstall (dropped onto the Disk tab or chosen from the list), then lists its files.
    func choose(_ path: String) {
        guard !scanning, !cleaning else { return }
        if let why = Uninstaller.refusal(path, roots: CleanerConfig.roots, selfIDs: Uninstaller.selfIDs) {
            refusal = "\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent): \(why)"
            return
        }
        refusal = nil
        targetPath = Uninstaller.located(path)
        target = nil            // the previous app's header and Quit button go away at once
        categories = []
        selected = []
        scan()
    }

    /// Back to the app list.
    func chooseAnother() {
        guard !scanning, !cleaning else { return }
        targetPath = nil
        target = nil
        categories = []
        selected = []
        lastScan = nil
        loadChoices()
    }

    /// Quits the app being uninstalled and its helpers, then lists its files again.
    func quitTarget() {
        guard let t = target, t.app.path == targetPath, !scanning else { return }
        let ids = CleanerConfig.runningApps().filter { r in t.ids.contains { BundleIDs.related(r.id, $0) } }.map(\.id)
        quit(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scan() }
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
                || i.ownerNames.contains(where: { EvidenceName.key($0) == EvidenceName.key(r.name) }) {
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
                // The lists can show the same folder (a cache of a removed app), so all drop it.
                for list in self.lists { list.removeMoved(done) }
                if self.kind == .uninstall, done.contains(where: { $0 == self.targetPath }) { self.choices.removeAll { $0.id == self.targetPath } }
                self.lastRunWasDry = env.dryRun
                self.outcomes = result
                self.cleaning = false
                self.progress = ""
            }
        }
    }

    private func removeMoved(_ done: Set<String>) {
        for i in categories.indices {
            if categories[i].method == .trash { categories[i].items.removeAll { done.contains($0.path) } }
        }
        categories.removeAll { $0.items.isEmpty && $0.notice == nil }
        selected.subtract(done)
    }

    // MARK: Ignore list and settings (stored by the junk model, shared by both lists)

    func ignoreItem(_ item: CleanItem) {
        let r = root
        guard !r.ignore.contains(where: { $0.caseInsensitiveCompare(item.path) == .orderedSame }) else { return }
        r.ignore.append(item.path)
        r.defaults.set(r.ignore, forKey: "ignoredItems")
        for list in lists {
            list.selected.remove(item.id)
            for i in list.categories.indices { list.categories[i].items.removeAll { $0.id == item.id } }
            list.categories.removeAll { $0.items.isEmpty && $0.notice == nil }
        }
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

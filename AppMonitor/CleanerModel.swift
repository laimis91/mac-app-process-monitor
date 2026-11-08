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

/// What a category row and its checkbox show, computed once each time the categories change.
struct CategorySummary {
    let count: Int                  // items it was computed from (a filtered copy has fewer)
    let risk: Risk
    let checkboxIDs: [String]       // what the category checkbox selects (spec 4.2)
    let trashIDs: [String]          // every item that can go to the Trash now (context menu "Select All")
    let hasSafe: Bool
    let size: Int64
}

/// One results list with its own scan, selection and clean. The junk model owns the settings and
/// the ignore list and holds the leftovers and uninstaller models; all three use the same row views.
@MainActor
final class CleanerModel: ObservableObject {
    @Published var view: DiskView = {
        #if APPMON_DEBUG
        switch ProcessInfo.processInfo.environment["APPMON_DISKVIEW"] {
        case "space": return .spaceMap
        case "leftovers": return .leftovers
        case "uninstall": return .uninstall
        default: break
        }
        #endif
        return .junk
    }()
    @Published var categories: [Category] = [] { didSet { categoriesChanged() } }
    @Published var scanning = false
    @Published private(set) var stopped = false      // the last scan was stopped before it finished
    @Published var progress = ""
    @Published var selected: Set<String> = [] { didSet { selectionChanged() } }
    @Published private(set) var selectedSize: Int64 = 0
    @Published private(set) var reclaimable: Int64 = 0
    @Published var fda: FDAStatus = .unknown
    @Published var bannerHidden = false
    @Published var lastScan: Date?
    @Published var cleaning = false
    @Published var confirming = false
    @Published var outcomes: [Outcome]?
    @Published var lastRunWasDry = false
    @Published private(set) var limits: AgeLimits
    @Published private(set) var ignore: [String]
    @Published private(set) var diskTick = 0          // junk model: bumped when free space may have changed
    @Published private(set) var previews: [String: String] = [:]   // tool previews by category, for this session
    // List state, kept here so it survives switching views
    @Published var search = ""
    @Published var expanded: Set<String> = []
    @Published var shown: [String: Int] = [:]
    @Published var possibleOpen = false

    let kind: CleanerKind
    private weak var owner: CleanerModel?          // the junk model, for the other two lists
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
    /// The filter text without surrounding spaces; empty means no filter.
    var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var cancel: CancelFlag?
    private var context: ScanContext?
    private var summaries: [String: CategorySummary] = [:]
    private var itemSizes: [String: Int64] = [:]
    private var movedWhileScanning: Set<String> = []   // moved by another list while this one scans
    private var cleanConfirmed = false
    private var activeObserver: NSObjectProtocol?
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
        categoriesChanged()   // property observers don't run during init
        // Full Disk Access is shown from the junk model only, so only it refreshes on activation.
        if kind == .junk {
            activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.active == true { self?.refreshFDA() } }
            }
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

    /// Free space may have changed: the Disk panel reads it again.
    func diskChanged() { root.diskTick += 1 }

    // MARK: Scanning

    func scan() {
        guard !scanning, !cleaning else { return }
        if demoMode { lastScan = Date(); stopped = false; return }
        if kind == .uninstall && targetPath == nil { loadChoices(); return }
        root.refreshFDA()
        let flag = CancelFlag()
        cancel = flag
        scanning = true
        stopped = false
        movedWhileScanning = []
        // The uninstaller keeps the app's earlier list until the new one arrives, so a stopped
        // re-scan leaves it usable. `choose` clears it when another app is picked.
        if kind != .uninstall {
            categories = []
            selected = []
        }
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
                        let cats = self.withoutMoved(result.categories)
                        self.target = result.target
                        self.categories = cats
                        self.selected = Set(cats.flatMap(\.items).filter(\.preselected).map(\.id))
                    }
                    self.finishScan(stopped: flag.isSet, dated: true)
                    if flag.isSet && self.target == nil { self.targetPath = nil; self.lastScan = nil }   // back to the app list
                    if result == nil { self.refusal = "This app is no longer there."; self.chooseAnother() }
                }
                return
            }
            if kind == .leftovers {
                let result = Leftovers.scan(ctx) { text in Task { @MainActor in self.progress = text } }
                await MainActor.run {
                    if !flag.isSet { self.categories = self.withoutMoved(result.categories) }
                    // A stopped leftovers scan lists nothing, so it doesn't count as a scan.
                    self.finishScan(stopped: flag.isSet, dated: !flag.isSet)
                }
                return
            }
            Rules.scan(ctx, progress: { id in
                Task { @MainActor in self.progress = Self.progressText(id) }
            }, found: { c in
                Task { @MainActor in self.add(c) }
            })
            await MainActor.run { self.finishScan(stopped: flag.isSet, dated: true) }
        }
    }

    private func finishScan(stopped: Bool, dated: Bool) {
        scanning = false
        self.stopped = stopped
        progress = ""
        if dated { lastScan = Date() }
        movedWhileScanning = []
        diskChanged()
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
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard !scanning, !cleaning else {
            refusal = "\(name): wait until the current \(cleaning ? "uninstall" : "listing") has finished, then try again."
            return
        }
        if let why = Uninstaller.refusal(path, roots: CleanerConfig.roots, selfIDs: Uninstaller.selfIDs) {
            refusal = "\(name): \(why)"
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
        stopped = false
        loadChoices()
    }

    /// Quits the app being uninstalled and its helpers, then lists its files again.
    func quitTarget() {
        guard let t = target, t.app.path == targetPath, !scanning, !cleaning else { return }
        let ids = CleanerConfig.runningApps().filter { r in t.ids.contains { BundleIDs.related(r.id, $0) } }.map(\.id)
        quit(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.confirming, !self.cleanConfirmed else { return }   // never under an open confirmation
            self.scan()
        }
    }

    nonisolated static func progressText(_ id: String) -> String {
        "Scanning " + (Rules.titles[id] ?? id).lowercased() + "…"
    }

    func stop() { cancel?.set() }

    private func add(_ c: Category) {
        guard scanning else { return }
        var c = c
        if !movedWhileScanning.isEmpty {
            let had = !c.items.isEmpty
            c.items.removeAll { movedWhileScanning.contains($0.path) }
            if had && c.items.isEmpty && c.notice == nil { return }
        }
        var list = categories.filter { $0.id != c.id } + [c]
        list.sort { (Rules.order.firstIndex(of: $0.id) ?? 99) < (Rules.order.firstIndex(of: $1.id) ?? 99) }
        categories = list
        selected.formUnion(c.items.filter(\.preselected).map(\.id))
    }

    /// Drops the items another list moved to the Trash while this list was scanning.
    private func withoutMoved(_ cats: [Category]) -> [Category] {
        guard !movedWhileScanning.isEmpty else { return cats }
        var out = cats
        for i in out.indices { out[i].items.removeAll { movedWhileScanning.contains($0.path) } }
        out.removeAll { $0.items.isEmpty && $0.notice == nil }
        return out
    }

    // MARK: Selection and derived totals

    private func categoriesChanged() {
        var sums: [String: CategorySummary] = [:], sizes: [String: Int64] = [:]
        var total: Int64 = 0
        for c in categories {
            sums[c.id] = Self.summarize(c)
            for i in c.items {
                sizes[i.id, default: 0] += i.size
                if i.selectable { total += i.size }
            }
        }
        summaries = sums
        itemSizes = sizes
        if reclaimable != total { reclaimable = total }
        selectionChanged()
    }

    private func selectionChanged() {
        let size = selected.reduce(Int64(0)) { $0 + (itemSizes[$1] ?? 0) }
        if selectedSize != size { selectedSize = size }
    }

    private static func summarize(_ c: Category) -> CategorySummary {
        var risks = Set<Risk>(), safe: [String] = [], trash: [String] = [], size: Int64 = 0
        for i in c.items {
            risks.insert(i.risk)
            size += i.size
            if i.preselected { safe.append(i.id) }
            if i.selectable && i.method == .trash && i.runningOwner == nil { trash.append(i.id) }
        }
        let risk = risks.count == 1 ? risks.first! : risks.contains(.review) ? .review : risks.first ?? .info
        return CategorySummary(count: c.items.count, risk: risk, checkboxIDs: safe.isEmpty ? trash : safe,
                               trashIDs: trash, hasSafe: !safe.isEmpty, size: size)
    }

    /// The summary of a category as shown; a filtered copy (fewer items) is summarized on the spot.
    func summary(_ c: Category) -> CategorySummary {
        if let s = summaries[c.id], s.count == c.items.count { return s }
        return Self.summarize(c)
    }

    var selectedPairs: [(Category, CleanItem)] {
        categories.flatMap { c in c.items.filter { selected.contains($0.id) }.map { (c, $0) } }
    }

    func toggle(_ item: CleanItem) {
        guard item.selectable else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    /// The category checkbox (spec 4.2) selects the category's Safe items when it has any. A
    /// category with only Review items selects all of them, except items whose app is running.
    /// true: all ticked, false: none, nil: some. nil with an empty list means nothing to select.
    func categoryState(_ s: CategorySummary) -> Bool? {
        guard !s.checkboxIDs.isEmpty else { return nil }
        let n = s.checkboxIDs.reduce(0) { selected.contains($1) ? $0 + 1 : $0 }
        return n == s.checkboxIDs.count ? true : n == 0 ? false : nil
    }

    func toggleCategory(_ c: Category) {
        let ids = summary(c).checkboxIDs
        if ids.allSatisfy({ selected.contains($0) }) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func selectAll(_ c: Category) { selected.formUnion(summary(c).trashIDs) }
    func deselectAll(_ c: Category) { selected.subtract(c.items.map(\.id)) }

    // MARK: Cleaning

    /// Apps that must quit before some selected items can be cleaned.
    func appsToQuit() -> [(String, [String])] {
        let running = CleanerConfig.runningApps().map { ($0, EvidenceName.key($0.name)) }
        var out: [String: Set<String>] = [:]
        for (_, i) in selectedPairs {
            let names = Set(i.ownerNames.map(EvidenceName.key))
            for (r, key) in running where i.owners.contains(where: { BundleIDs.related(r.id, $0) }) || names.contains(key) {
                out[r.name, default: []].insert(r.id)
            }
        }
        return out.map { ($0.key, Array($0.value)) }.sorted { $0.0 < $1.0 }
    }

    func quit(_ ids: [String]) {
        guard !dryRun, CleanerConfig.fixtureRoot == nil, !demoMode else { return }   // never quits real apps when testing
        for a in NSWorkspace.shared.runningApplications where ids.contains(a.bundleIdentifier ?? "") { a.terminate() }
    }

    /// The confirmed clean waits until the confirmation sheet has closed, so the result sheet
    /// that follows can always be shown (as in the Space map).
    func confirmClean() { cleanConfirmed = true }
    func confirmationClosed() {
        guard cleanConfirmed else { return }
        cleanConfirmed = false
        clean()
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
                for o in result where o.status == .ran { self.previews[o.category] = nil }   // its preview is out of date
                self.lastRunWasDry = env.dryRun
                self.outcomes = result
                self.cleaning = false
                self.progress = ""
                self.diskChanged()
            }
        }
    }

    private func removeMoved(_ done: Set<String>) {
        guard !done.isEmpty else { return }
        if scanning { movedWhileScanning.formUnion(done) }
        var cats = categories, changed = false
        for i in cats.indices where cats[i].method == .trash {
            let n = cats[i].items.count
            cats[i].items.removeAll { done.contains($0.path) }
            changed = changed || cats[i].items.count != n
        }
        let n = cats.count
        cats.removeAll { $0.items.isEmpty && $0.notice == nil }
        if changed || cats.count != n { categories = cats }
        if !selected.isDisjoint(with: done) { selected.subtract(done) }
    }

    // MARK: Tool previews (spec 4.3)

    static let checkingPreview = "Checking what it would remove…"

    /// Runs each tool's read-only preview once per session, from the confirmation sheet's `.task`.
    /// ToolRunner can't be cancelled, so a run that is going or done is never started again; a
    /// run that finishes after the sheet closed still fills the cache. A preview is a tool run:
    /// only a tool that passed the lookup runs one, after the lookup's checks once more (spec 6.5).
    func loadPreviews(_ cats: [Category]) async {
        await withTaskGroup(of: Void.self) { g in
            for c in cats where previews[c.id] == nil {
                guard !Task.isCancelled, let t = c.tool, let exe = t.executable, let place = t.place,
                      let args = t.preview else { continue }
                let id = c.id
                if let why = ToolTrust.refusal(exe, place: place) { previews[id] = "Not run: \(why)"; continue }
                previews[id] = Self.checkingPreview
                g.addTask {
                    let r = ToolRunner.run(exe, args, timeout: 60)
                    let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run { self.previews[id] = text.isEmpty ? "Nothing to remove." : String(text.suffix(3000)) }
                }
            }
        }
    }

    // MARK: Ignore list and settings (stored by the junk model, shared by all three lists)

    func ignoreItem(_ item: CleanItem) {
        let r = root
        guard !r.ignore.contains(where: { $0.caseInsensitiveCompare(item.path) == .orderedSame }) else { return }
        r.ignore.append(item.path)
        r.defaults.set(r.ignore, forKey: "ignoredItems")
        for list in lists {
            if list.selected.contains(item.id) { list.selected.remove(item.id) }
            guard list.categories.contains(where: { $0.items.contains { $0.id == item.id } }) else { continue }
            var cats = list.categories
            for i in cats.indices { cats[i].items.removeAll { $0.id == item.id } }
            cats.removeAll { $0.items.isEmpty && $0.notice == nil }
            list.categories = cats
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

// Leftovers finder, disk side (spec 9): lists the places, measures candidates, runs the extra
// installed-app probes and turns the matcher's decision into Disk-tab categories.
// Foundation only; Spotlight (probe 2) is passed in through ScanContext.spotlight.

import Foundation

enum Leftovers {
    static let fdaID = "L-FDA"
    static let spotlightID = "L-SPOTLIGHT"

    // MARK: Extra probes (spec 9.2: 5, 7, and apps kept outside the usual folders)

    struct Probes {
        var labels: [String] = []        // lowercased launchd labels (and plist names, if a label can't be read)
        var bundles: [AppInfo] = []      // plug-ins, and apps found inside ~/Library/Application Support
        var toolNames: [String] = []     // command-line tools, which keep data under their own names
    }

    static let pluginFolders = ["PreferencePanes", "QuickLook", "Spotlight", "Input Methods", "Screen Savers",
                                "Services", "Internet Plug-Ins", "Extensions"]

    static func probes(_ r: Roots) -> Probes {
        var p = Probes()
        // Probe 5: launchd jobs. A job whose label matches an ID means something of that app is set up to run.
        for dir in [r.h("Library/LaunchAgents"), r.library + "/LaunchAgents", r.library + "/LaunchDaemons"] {
            guard case .ok(let names) = ScanEngine.children(dir) else { continue }
            for n in names where n.lowercased().hasSuffix(".plist") {
                p.labels.append(CandidateKey.parse(n).key.lowercased())
                if let l = NSDictionary(contentsOfFile: dir + "/" + n)?["Label"] as? String { p.labels.append(l.lowercased()) }
            }
        }
        // Probe 7: non-app bundles in plug-in folders, in ~/Library and /Library.
        for lib in [r.h("Library"), r.library] {
            var dirs = pluginFolders.map { lib + "/" + $0 }
            if case .ok(let kinds) = ScanEngine.children(lib + "/Audio/Plug-Ins") { dirs += kinds.map { lib + "/Audio/Plug-Ins/" + $0 } }
            for dir in dirs {
                guard case .ok(let names) = ScanEngine.children(dir) else { continue }
                for n in names { if let b = bundleInfo(dir + "/" + n) { p.bundles.append(b) } }
            }
        }
        // Apps installed outside the usual folders (for example web-deployed apps inside Application
        // Support, spec 9.2): their own folders and data must never be flagged.
        // Helper apps under /Library/Application Support (updaters, agents) count the same way.
        for dir in [r.h("Library/Application Support"), r.library + "/Application Support"] {
            nestedApps(dir, depth: 4) { app in
                if let a = AppInventory.info(app) {
                    p.bundles.append(a)
                    for e in AppInventory.embeddedIDs(app) { p.bundles.append(AppInfo(id: e, name: a.name, path: app)) }
                }
            }
        }
        // Command-line tools: data named after a tool (org.carthage.CarthageKit, …) is not an app's leftover.
        var toolDirs = r.toolDirs.filter { $0 != "/usr/bin" }
        if !r.fixture {
            toolDirs += [".local/bin", "bin", ".cargo/bin", "go/bin", ".dotnet/tools"].map { r.h($0) }
            for cask in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
                if case .ok(let names) = ScanEngine.children(cask) { p.toolNames += names }
            }
        }
        for d in toolDirs { if case .ok(let names) = ScanEngine.children(d) { p.toolNames += names } }
        return p
    }

    /// The bundle ID and names of a bundle folder (an app, plug-in, panel, …), if it has one.
    static func bundleInfo(_ path: String) -> AppInfo? {
        guard let st = ScanEngine.lstatInfo(path), (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        guard let d = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") ?? NSDictionary(contentsOfFile: path + "/Info.plist"),
              let id = d["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let file = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let names = [d["CFBundleName"] as? String, d["CFBundleDisplayName"] as? String, d["CFBundleExecutable"] as? String, file]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return AppInfo(id: id, name: names.first ?? file, path: path, names: names)
    }

    /// Calls `found` for every `.app` folder up to `depth` levels below `dir`, without following links.
    static func nestedApps(_ dir: String, depth: Int, _ found: (String) -> Void) {
        guard depth > 0, case .ok(let names) = ScanEngine.children(dir) else { return }
        for n in names {
            let p = dir + "/" + n
            guard let st = ScanEngine.lstatInfo(p), (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            if isBundle(p) { found(p) } else { nestedApps(p, depth: depth - 1, found) }
        }
    }

    /// A folder named "….app" that looks like an app bundle (data folders named "com.vendor.app" don't).
    static func isBundle(_ p: String) -> Bool {
        p.lowercased().hasSuffix(".app")
            && (ScanEngine.lstatInfo(p + "/Contents/Info.plist") != nil || ScanEngine.lstatInfo(p + "/Contents/MacOS") != nil)
    }

    static func containsApp(_ path: String, depth: Int = 3) -> Bool {
        if isBundle(path) { return true }
        var any = false
        nestedApps(path, depth: depth) { _ in any = true }
        return any
    }

    // MARK: Evidence

    static let ownIDs = ["io.github.laimis91.appmonitor"]

    static func evidence(_ ctx: ScanContext, _ p: Probes) -> LeftoverEvidence {
        let inv = ctx.inventory
        let running = ctx.running
        let known = Array(inv.apps.values) + Array(inv.embedded.values) + p.bundles
        let installedIDs = Array(inv.apps.keys) + Array(inv.embedded.keys) + p.bundles.map { $0.id.lowercased() }
        var names = Set<String>()
        for a in known { for n in [a.name] + a.names { names.insert(LeftoverEvidence.normalize(n)) } }
        for r in running { names.insert(LeftoverEvidence.normalize(r.name)) }
        for t in p.toolNames { names.insert(LeftoverEvidence.normalize(t)) }
        names.remove("")
        var vendors = Set(installedIDs.map(BundleIDs.vendor))
        for r in running { vendors.insert(BundleIDs.vendor(r.id)) }
        let labels = p.labels, bundles = p.bundles
        let installed: (String) -> String? = { id in
            let k = id.lowercased()
            if let a = inv.owner(of: k) { return a.name }
            // An installed app whose ID starts with this one (com.vendor.app.pro for com.vendor.app)
            // may use the same data, so it counts too.
            if let a = inv.apps.first(where: { BundleIDs.belongs($0.key, to: k) }) { return a.value.name }
            if let a = inv.embedded.first(where: { BundleIDs.belongs($0.key, to: k) }) { return a.value.name }
            if let lookup = inv.lookup {   // probe 1 for each shorter ID: com.vendor.app for com.vendor.app.x
                for pre in LeftoverMatcher.prefixes(k).dropFirst() { if let a = lookup(pre) { return a.name } }
            }
            if let l = labels.first(where: { $0.hasPrefix(k) || BundleIDs.belongs(k, to: $0) }) { return "launchd job \(l)" }
            if let b = bundles.first(where: { BundleIDs.related(k, $0.id) }) { return b.name }
            if let r = running.first(where: { BundleIDs.related(k, $0.id) }) { return r.name }
            return nil
        }
        var selfIDs = ownIDs
        if let me = Bundle.main.bundleIdentifier, !selfIDs.contains(me.lowercased()) { selfIDs.append(me.lowercased()) }
        return LeftoverEvidence(installed: installed, names: names, vendors: vendors, spotlight: ctx.spotlight, selfIDs: selfIDs)
    }

    // MARK: Scan

    struct Result {
        var categories: [Category]
        var decision: LeftoverDecision
    }

    static func scan(_ ctx: ScanContext, progress: (String) -> Void = { _ in }) -> Result {
        progress("Listing installed apps…")
        let ev = evidence(ctx, probes(ctx.roots))
        var cands: [LeftoverCandidate] = []
        var pendingNames: [(LeftoverCandidate, stat)] = []
        var notices: [Category] = []
        var fdaPlaces: [LeftoverPlace] = []

        for place in LeftoverPlace.all {
            if ctx.cancel.isSet { break }
            progress("Looking in \(place.rel)…")
            let root = place.root(ctx.roots)
            if place.needsFDA && ctx.fda != .granted {
                // Without Full Disk Access these folders aren't entered: macOS may ask the user about
                // each app's data instead of failing (spec 9.1). Shown as a greyed row.
                if ScanEngine.lstatInfo(root) != nil { fdaPlaces.append(place) }
                continue
            }
            let names: [String]
            switch ScanEngine.children(root) {
            case .missing: continue
            case .noAccess(let e):
                if e == EPERM { fdaPlaces.append(place) } else {
                    notices.append(Category(id: "L-ACCESS-" + place.id, title: place.rel, group: .leftovers, method: .none,
                                            explanation: "Couldn't be checked for leftovers.", items: [], notice: Rules.noticeFor(e)))
                }
                continue
            case .ok(let n): names = n
            }
            for n in names {
                if ctx.cancel.isSet { break }
                if let s = place.suffix, !n.lowercased().hasSuffix(s) { continue }
                let p = root + "/" + n
                guard !ctx.ignored(p), let st = ScanEngine.lstatInfo(p), (st.st_mode & S_IFMT) != S_IFLNK else { continue }
                var c = LeftoverCandidate(place: place, name: n, path: p)
                switch LeftoverMatcher.screen(c.key, ev) {
                case .drop: continue
                case .name: if place.tier == .orphan { pendingNames.append((c, st)) }
                case .bundle: measure(&c, st, ctx); cands.append(c)
                }
            }
        }
        // Plain names are measured only if they could be positive evidence (9.3 Low): equal to an
        // app name found in a leftover settings file or saved state.
        let known = Set(cands.compactMap(\.bundleName).map(EvidenceName.key))
        for (var c, st) in pendingNames where known.contains(EvidenceName.key(c.key.key)) && !ctx.cancel.isSet {
            measure(&c, st, ctx)
            cands.append(c)
        }
        progress("Checking with Spotlight…")
        let decision = ctx.cancel.isSet ? LeftoverDecision()
            : LeftoverMatcher.decide(cands, ev: ev, limits: ctx.limits, now: ctx.now)

        var cats = decision.groups.map(category).sorted { ($0.size, $1.title) > ($1.size, $0.title) }
        for c in cats.indices {     // S7: shown as "quit it first", and skipped when cleaned
            for i in cats[c].items.indices {
                let it = cats[c].items[i]
                cats[c].items[i].runningOwner = ctx.inventory.runningOwner(it.owners, names: it.ownerNames, snapshot: ctx.running)
            }
        }
        if !fdaPlaces.isEmpty {
            cats.append(Category(id: fdaID, title: "App containers and shared app data", group: .leftovers, method: .none,
                                 explanation: "Leftovers in \(fdaPlaces.map(\.rel).joined(separator: ", ")) are checked only with Full Disk Access.",
                                 items: [], notice: "Needs Full Disk Access"))
        }
        if decision.spotlightFailed > 0 {
            let n = decision.spotlightFailed
            cats.append(Category(id: spotlightID, title: "Not confirmed by Spotlight", group: .leftovers, method: .none,
                                 explanation: "Spotlight didn't answer, so \(n) app\(n == 1 ? "" : "s") can't be confirmed as removed. Their data isn't listed.",
                                 items: [], notice: "Spotlight didn't answer"))
        }
        return Result(categories: cats + notices, decision: decision)
    }

    /// Size, age and the things that keep a whole group (S5). Also reads the name evidence.
    static func measure(_ c: inout LeftoverCandidate, _ st: stat, _ ctx: ScanContext) {
        let info = c.place.tier == .infoOnly
        // Items in /Library belong to root, so "owned by another user" says nothing there; apps
        // inside are looked for on their own.
        let m = ScanEngine.measure(c.path, links: ctx.links, cancel: ctx.cancel, inspect: !info, strictApps: true)
        c.size = m.size
        c.fileID = m.fileID
        c.newest = m.complete ? m.newest : nil
        if let why = m.protected { c.doubt = why }
        else if info && containsApp(c.path) { c.doubt = ScanEngine.Protected.app.rawValue }
        else if !m.complete { c.doubt = "Part of it can't be read" }
        else if m.special { c.doubt = "Contains a socket or pipe an app may be using" }
        if !info {
            if !Cleaner.userCanMove(c.path, st) { c.immovable = "You can't move it yourself. Remove it in Finder." }
            else if m.locked { c.immovable = "Contains a locked file. Remove it in Finder." }
        }
        switch c.place.id {
        case "preferences":
            c.bundleName = plistName(NSDictionary(contentsOfFile: c.path))
        case "savedState":
            c.bundleName = plistName(NSDictionary(contentsOfFile: c.path + "/Info.plist"))
        case "containers":
            c.containerID = NSDictionary(contentsOfFile: c.path + "/.com.apple.containermanagerd.metadata.plist")?["MCMMetadataIdentifier"] as? String
        default: break
        }
    }

    static func plistName(_ d: NSDictionary?) -> String? {
        let n = (d?["CFBundleName"] as? String) ?? (d?["CFBundleDisplayName"] as? String)
        guard let n, !n.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return n
    }

    static func category(_ g: LeftoverGroup) -> Category {
        let items = g.items.map { li -> CleanItem in
            let c = li.candidate
            var owners = [c.key.key]
            if g.id.caseInsensitiveCompare(c.key.key) != .orderedSame { owners.append(g.id) }
            // Same vendor as an installed app: while any app of that vendor runs, it may be using this.
            if g.sameVendor { owners.append(BundleIDs.vendor(g.id)) }
            var i = CleanItem(path: c.path, name: c.name, size: c.size, newest: c.newest,
                              risk: li.selectable ? .review : .info, method: li.selectable ? .trash : .none,
                              reason: li.reason, allowRoot: c.place.system ? "" : URL(fileURLWithPath: c.path).deletingLastPathComponent().path,
                              fileID: c.fileID, owners: owners, ageLimitDays: li.ageLimit, checkOpenFiles: true)
            if c.key.kind == .name { i.ownerNames = [c.key.key, g.title] }
            i.inspect = true
            return i
        }
        return Category(id: "L:" + g.key, title: g.title, group: g.confidence == .high ? .leftovers : .possible,
                        method: .trash, explanation: g.explanation, items: items.sorted { $0.size > $1.size })
    }
}

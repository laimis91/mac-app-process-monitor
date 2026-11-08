// Uninstaller (spec 10): which files belong to the one app the user chose, the refusals, and the
// Disk-tab categories. It has its own matching rules: the leftover rules (no installed owner, age
// limits) would exclude the chosen app's own data.
// Foundation and Darwin only, so scripts/selftest.sh can compile it. Its probes are in Probes.swift.

import Foundation

/// The app being uninstalled.
struct UninstallTarget {
    let app: AppInfo                // its path is the bundle as it sits (parent folder canonical)
    let ids: [String]               // target ID set, lowercased: the app's ID and its embedded bundles' IDs
    let groups: [String]            // app-group entitlements of the app and its embedded bundles, lowercased
    var otherCopies: [String] = []  // other bundles with the same ID (LaunchServices and the app folders)
    var running: [String] = []      // names of the app, its helpers, or processes inside the bundle, now running
    var runningByID = false         // one of them is an app Quit can stop (found by bundle ID)
}

/// What the uninstaller asks the system. Real probes in the app, plain closures in tests.
struct UninstallProbes {
    /// App-group entitlements of a signed bundle, lowercased. Empty when unsigned or unreadable.
    var groups: (String) -> [String] = Entitlements.appGroups
    /// Other copies of an app with this bundle ID.
    var copies: (String) -> [String] = { _ in [] }
    /// Names of processes whose executable is inside this folder.
    var processesInside: (String) -> [String] = ProcessList.inside
}

enum Uninstaller {
    static let fdaID = "U-FDA"

    /// App Monitor's own bundle IDs: it never uninstalls itself.
    static var selfIDs: [String] {
        var ids = Leftovers.ownIDs
        if let me = Bundle.main.bundleIdentifier?.lowercased(), !ids.contains(me) { ids.append(me) }
        return ids
    }

    // MARK: Refusals (spec 10)

    /// The bundle as it sits: its parent folder canonical, the item itself not resolved (S12).
    static func located(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return Roots.canonical(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
    }

    /// nil when `path` may be uninstalled, otherwise the reason shown to the user.
    static func refusal(_ path: String, roots: Roots, selfIDs: [String]) -> String? {
        let p = located(path)
        guard let st = ScanEngine.lstatInfo(p) else { return "This app is no longer there." }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "This is a link to an app, not the app. Remove the link in Finder." }
        // iPhone and iPad apps on a Mac are wrappers around the real bundle, installed by the App Store.
        if ScanEngine.lstatInfo(p + "/Wrapper") != nil || ScanEngine.lstatInfo(p + "/WrappedBundle") != nil {
            return "This is an iPhone or iPad app. Remove it in Finder or Launchpad."
        }
        guard Leftovers.isBundle(p), let a = AppInventory.info(p) else { return "This isn't an app." }
        let c = PathGuard.comps(p)
        if a.id.lowercased().hasPrefix("com.apple.")
            || PathGuard.within(c, PathGuard.comps(Roots.canonical(roots.systemApplications)))
            || PathGuard.within(c, ["system"]) {
            return "Apps that come with macOS can't be removed."
        }
        if selfIDs.contains(a.id.lowercased()) || (Bundle.main.bundlePath.lowercased() == p.lowercased()) {
            return "App Monitor can't uninstall itself. Quit it and move it to the Trash in Finder."
        }
        let roots = [roots.applications, roots.h("Applications")].map { PathGuard.comps(Roots.canonical($0)) }
        guard let root = roots.first(where: { PathGuard.strictlyInside(c, $0) }) else {
            return "This app isn't in Applications. Use the app's own uninstaller."
        }
        // A helper or extension inside another bundle is part of that app, never an app to remove.
        // Only the folders between Applications and the app count.
        if c[root.count..<(c.count - 1)].contains(where: PathGuard.isBundleName) {
            return "This is part of another app. Uninstall that app instead."
        }
        if case .failure(let r) = PathGuard.locate(p) { return r.reason }
        guard Cleaner.userCanMove(p, st) else {
            return "You can't move this app yourself (it belongs to the system or another user). Remove it in Finder."
        }
        return nil
    }

    // MARK: Target

    /// The target ID set (spec 10): the app's ID plus every embedded bundle ID. An embedded ID
    /// that names a shared library (Sparkle, an analytics SDK, …) and isn't under the app's own
    /// ID is left out, because other apps use the same ID.
    static func target(_ app: AppInfo, probes: UninstallProbes) -> UninstallTarget {
        let own = app.id.lowercased()
        var ids = [own]
        var groups = Set(probes.groups(app.path))
        for e in AppInventory.embeddedBundles(app.path) {
            let k = e.id.lowercased()
            groups.formUnion(probes.groups(e.path))
            guard CandidateKey.parse(k).kind == .bundleID, !ids.contains(k) else { continue }
            if Protection.isProtected(k) && !BundleIDs.belongs(k, to: own) { continue }
            ids.append(k)
        }
        var t = UninstallTarget(app: app, ids: ids, groups: groups.sorted())
        t.otherCopies = probes.copies(app.id).filter { $0.lowercased() != located(app.path).lowercased() }
        return t
    }

    // MARK: Ownership

    enum Owner: Equatable { case target, other(String) }

    /// Who `key` belongs to. The longest matching ID decides; on a tie the other app wins, so
    /// with com.vendor.app and com.vendor.app.pro installed, com.vendor.app.pro's data stays.
    /// `lookup` asks LaunchServices (probe 1) about a key that is longer than the target ID it
    /// matched, and each shorter ID down to it: an app installed outside the scanned folders
    /// (com.vendor.app.beta in Downloads) then wins too. An app LaunchServices names is the
    /// target only by a target ID or by sitting inside `targetPath`; an empty `targetPath`
    /// matches no app. The matched ID itself is asked about too when it is an embedded ID (not
    /// the app's own, `target[0]`): an app can embed a bundle with any ID, so an app
    /// LaunchServices knows by exactly that ID at another path wins.
    static func owner(of key: String, target: [String], others: [(id: String, name: String)],
                      lookup: ((String) -> AppInfo?)? = nil, targetPath: String) -> Owner? {
        let k = key.lowercased()
        var best = -1
        var who: Owner?
        var matched = ""
        for t in target where BundleIDs.belongs(k, to: t) && t.count > best { best = t.count; who = .target; matched = t }
        guard who != nil else { return nil }
        for o in others where BundleIDs.belongs(k, to: o.id) && o.id.count >= best { best = o.id.count; who = .other(o.name) }
        guard who == .target, let lookup else { return who }
        let tp = PathGuard.comps(targetPath)
        func inside(_ a: AppInfo) -> Bool { !tp.isEmpty && PathGuard.within(PathGuard.comps(a.path), tp) }
        if k.count > best {
            for pre in LeftoverMatcher.prefixes(key) where pre.count > best {
                guard let a = lookup(pre) else { continue }
                let same = target.contains(a.id.lowercased()) || inside(a)
                if !same { return .other(a.name) }
            }
        }
        if matched != target.first, let a = lookup(matched), !inside(a) { return .other(a.name) }
        return who
    }

    /// Bundle IDs of every installed app other than the target (and its copies), with their
    /// embedded bundles, and of plug-ins and apps found outside the app folders.
    static func others(_ t: UninstallTarget, _ inv: AppInventory, extra: [AppInfo]) -> [(id: String, name: String)] {
        let own = t.app.id.lowercased()
        func isTarget(_ a: AppInfo) -> Bool {
            a.id.lowercased() == own || PathGuard.within(PathGuard.comps(a.path), PathGuard.comps(t.app.path))
        }
        var out: [(id: String, name: String)] = []
        for a in inv.apps.values where !isTarget(a) { out.append((a.id.lowercased(), a.name)) }
        for (eid, owners) in inv.embeddedAll {
            for a in owners where !isTarget(a) { out.append((eid, a.name)) }
        }
        for b in extra where !isTarget(b) { out.append((b.id.lowercased(), b.name)) }
        return out
    }

    /// Name keys the target is known by (for folders named after the app), without other apps'
    /// names and without names the protection list covers (an Electron app's executable is
    /// "Electron", which says nothing about whose folder it is).
    static func nameKeys(_ app: AppInfo, others: [String]) -> Set<String> {
        let taken = Set(others.map(EvidenceName.key))
        let mine = Set(([app.name] + app.names).filter { !Protection.isProtectedName($0) }.map(EvidenceName.key))
            .filter { $0.count >= 4 }
        return mine.subtracting(taken)
    }

    // MARK: Item kinds (spec 10 table)

    enum Kind { case safe, data, review, info }

    static func kind(_ place: LeftoverPlace) -> Kind {
        switch place.id {
        case "caches", "logs", "savedState", "httpStorages", "webKit": return .safe
        case "preferences", "appSupport", "cookies": return .data
        case "containers", "groupContainers", "appScripts", "launchAgents": return .review
        default: return .info
        }
    }

    /// Places where a folder may be named after the app instead of its bundle ID.
    static let namedPlaces: Set<String> = ["appSupport", "caches", "logs", "httpStorages", "webKit"]

    // MARK: Plan

    struct Result {
        var target: UninstallTarget
        var categories: [Category]
    }

    /// Why an entry of a place belongs to the target (spec 10).
    struct Match { var why: String; var shared: [String] = []; var byName = false; var kept: String? = nil }

    static let protectedGroup = "Not moved: protected name"

    /// The per-place rule for the entry `n` at `p`: an app container by its own record, a group
    /// container by an entitlement or its ID, a launch job by its label, anything else by bundle
    /// ID or, in a few places, by the app's name. nil if it isn't the target's.
    static func match(_ n: String, at p: String, in place: LeftoverPlace, app: AppInfo, target t: UninstallTarget,
                      named: Set<String>, own: (String) -> Owner?, claimers: (String) -> [String]) -> Match? {
        let key = CandidateKey.parse(n)
        switch place.id {
        case "containers":
            // Only the container's own record says whose it is (spec 10).
            guard let meta = NSDictionary(contentsOfFile: p + "/.com.apple.containermanagerd.metadata.plist")?["MCMMetadataIdentifier"] as? String,
                  t.ids.contains(meta.lowercased()),
                  own(meta) == .target else { return nil }
            return Match(why: "\(place.noun) of \(meta)")
        case "groupContainers":
            let byGroup = t.groups.contains(n.lowercased())
            let o = key.kind == .bundleID ? own(key.key) : nil
            if case .other = o { return nil }
            guard byGroup || o == .target else { return nil }
            // Entitlements are read without checking the signature, so any app can claim any
            // group: one with a protected name (group.com.apple.…) is shown, never moved.
            let protected = Protection.isProtected(n) || Protection.isProtected(key.key)
            return Match(why: byGroup ? "\(place.noun) of the app group \(n), listed in \(app.name)'s entitlements"
                                      : "\(place.noun) of \(key.key)",
                         shared: claimers(n.lowercased()), kept: protected ? protectedGroup : nil)
        case "launchAgents", "sysLaunchAgents", "sysLaunchDaemons":
            let label = (NSDictionary(contentsOfFile: p)?["Label"] as? String) ?? key.key
            guard own(label) == .target else { return nil }
            return Match(why: "\(place.noun) \(label)")
        default:
            if key.kind == .bundleID {
                guard own(key.key) == .target else { return nil }
                return Match(why: "\(place.noun) of \(key.key)")
            }
            if namedPlaces.contains(place.id) && place.tier == .orphan && named.contains(EvidenceName.key(n)) {
                return Match(why: "\(place.noun) named like \(app.name). It isn't matched by bundle ID, so check it belongs to this app.",
                             byName: true)
            }
            return nil
        }
    }

    /// Lists the app bundle and every related item (spec 10). Nothing here moves anything.
    static func plan(_ appPath: String, ctx: ScanContext, probes: UninstallProbes,
                     progress: (String) -> Void = { _ in }) -> Result? {
        let path = located(appPath)
        guard let app0 = AppInventory.info(path) else { return nil }
        let app = AppInfo(id: app0.id, name: app0.name, path: path, names: app0.names)
        progress("Reading \(app.name)…")
        var t = target(app, probes: probes)
        let extra = Leftovers.probes(ctx.roots).bundles
        let others = others(t, ctx.inventory, extra: extra)
        let otherNames = ctx.inventory.apps.values.filter { $0.id.lowercased() != t.app.id.lowercased() }
            .flatMap { [$0.name] + $0.names } + extra.flatMap { [$0.name] + $0.names }
        let named = nameKeys(app, others: otherNames)
        let ownerNames = [app.name]
        let lookup = ctx.inventory.lookup
        func own(_ key: String) -> Owner? { owner(of: key, target: t.ids, others: others, lookup: lookup, targetPath: path) }

        // Who else claims an app group (only read when a group container is related).
        var claimsCache: [String: [String]]?
        func claimers(_ group: String) -> [String] {
            if claimsCache == nil {
                var c: [String: [String]] = [:]
                for a in ctx.inventory.apps.values where a.id.lowercased() != t.app.id.lowercased()
                    && !PathGuard.within(PathGuard.comps(a.path), PathGuard.comps(t.app.path)) {
                    var gs = Set(probes.groups(a.path))
                    for e in AppInventory.embeddedBundles(a.path) { gs.formUnion(probes.groups(e.path)) }
                    for g in gs { c[g, default: []].append(a.name) }
                }
                claimsCache = c
            }
            return (claimsCache?[group] ?? []).sorted()
        }

        var rows: [(kind: Kind, item: CleanItem, named: Bool)] = []
        var fdaPlaces: [String] = []

        // The app bundle itself: Requested (the user chose it), pre-selected.
        let appRoot = [ctx.roots.applications, ctx.roots.h("Applications")].map(Roots.canonical)
            .first { PathGuard.strictlyInside(PathGuard.comps(path), PathGuard.comps($0)) } ?? ""
        let am = ScanEngine.measure(path, links: ctx.links, cancel: ctx.cancel)
        var appItem = CleanItem(path: path, name: URL(fileURLWithPath: path).lastPathComponent, size: am.size,
                                newest: am.newest, risk: .requested, method: .trash,
                                reason: "The app you chose (\(app.id))", scope: .appBundle(root: appRoot), fileID: am.fileID,
                                owners: t.ids, ownerNames: ownerNames, checkOpenFiles: true)
        appItem.insideBundle = path
        if !am.complete { appItem = info(appItem, "Part of the app can't be read. Remove it in Finder.") }
        else if am.locked { appItem = info(appItem, "The app contains a locked file. Remove it in Finder.") }
        rows.append((.data, appItem, false))

        for place in LeftoverPlace.all {
            if ctx.cancel.isSet { break }
            progress("Looking in \(place.rel)…")
            let root = place.root(ctx.roots)
            let names: [String]
            switch Leftovers.list(place, ctx) {
            case .skip, .failed: continue
            case .needsFDA: fdaPlaces.append(place.rel); continue
            case .ok(let n): names = n
            }
            for n in names {
                if let s = place.suffix, !n.lowercased().hasSuffix(s) { continue }
                let p = root + "/" + n
                guard !ctx.ignored(p), let st = ScanEngine.lstatInfo(p), (st.st_mode & S_IFMT) != S_IFLNK else { continue }
                guard let hit = match(n, at: p, in: place, app: app, target: t, named: named, own: own, claimers: claimers)
                else { continue }
                let (why, shared, byName) = (hit.why, hit.shared, hit.byName)
                let k: Kind = byName ? .review : kind(place)
                let isInfo = place.system || k == .info
                let m = ScanEngine.measure(p, links: ctx.links, cancel: ctx.cancel, inspect: !isInfo, strictApps: true)
                // Anything that keeps the item shows it as Info with the reason (S5).
                var kept: String?
                if isInfo { kept = "Needs administrator rights to remove. Remove it in Finder." }
                else if let reason = hit.kept { kept = reason }
                else if !shared.isEmpty { kept = "Shared with \(shared.joined(separator: ", ")), so it stays." }
                else if let nested = nestedApp(p) { kept = "Contains \(nested), so it stays. Remove it in Finder." }
                else if let pr = m.protected { kept = pr }
                else if !m.complete { kept = "Part of it can't be read." }
                else if m.special { kept = "Contains a socket or pipe an app may be using." }
                else if m.locked { kept = "Contains a locked file. Remove it in Finder." }
                else if !Cleaner.userCanMove(p, st) { kept = "Needs administrator rights to remove. Remove it in Finder." }
                var item = CleanItem(path: p, name: n, size: m.size, newest: m.complete ? m.newest : nil,
                                     risk: k == .safe ? .safe : .review, method: .trash,
                                     reason: why + (k == .data ? ". Contains your settings and data." : ""),
                                     scope: place.system ? .none : .rule(root: root), fileID: m.fileID, owners: t.ids,
                                     ownerNames: ownerNames, checkOpenFiles: true)
                item.inspect = true
                item.preselect = k == .data
                item.insideBundle = path   // S7/S13: nothing of the app is moved while anything runs from its bundle
                if let kept { item = info(item, why + ". " + kept) }
                rows.append((k, item, byName))
            }
        }

        // S7: the app, a helper, or anything running from inside the bundle blocks the whole uninstall.
        var running = Set<String>()
        if let r = ctx.inventory.runningOwner(t.ids, names: ownerNames, snapshot: ctx.running) { running.insert(r) }
        // Quit can stop only apps found by bundle ID; a match by name alone is blocked but not offered.
        t.runningByID = ctx.running.contains { r in t.ids.contains { BundleIDs.related(r.id, $0) } }
        for n in probes.processesInside(path) { running.insert(n) }
        t.running = running.sorted()
        if let who = t.running.first {
            for i in rows.indices where rows[i].item.selectable { rows[i].item.runningOwner = who }
        }

        var cats: [Category] = []
        func add(_ id: String, _ title: String, _ group: CategoryGroup, _ explanation: String,
                 _ pick: ((kind: Kind, item: CleanItem, named: Bool)) -> Bool) {
            let items = rows.filter(pick).map(\.item)
            guard !items.isEmpty else { return }
            cats.append(Category(id: id, title: title, group: group, method: .trash, explanation: explanation,
                                 items: items.sorted { ($0.appBundle ? 1 : 0, $0.size) > ($1.appBundle ? 1 : 0, $1.size) }))
        }
        let movable: ((kind: Kind, item: CleanItem, named: Bool)) -> Bool = { $0.item.risk != .info }
        add("U-APP", app.name, .uninstall, "The app itself", { $0.item.appBundle && movable($0) })
        add("U-CACHE", "Caches, logs and saved state", .uninstall, "Re-created if you install the app again",
            { $0.kind == .safe && !$0.item.appBundle && movable($0) })
        add("U-DATA", "Settings and data", .uninstall, "Contains your settings and data",
            { $0.kind == .data && !$0.item.appBundle && !$0.named && movable($0) })
        add("U-MORE", "Containers, scripts and launch agents", .uninstall, "Not pre-selected: check each one",
            { $0.kind == .review && !$0.named && movable($0) })
        add("U-NAMED", "Named like \(app.name)", .uninstall, "Not matched by bundle ID: check each one",
            { $0.named && movable($0) })
        add("U-KEPT", "Not moved", .kept, "Shown so you know they exist", { !movable($0) })
        if !fdaPlaces.isEmpty {
            cats.append(Category(id: fdaID, title: "App containers and shared app data", group: .kept, method: .none,
                                 explanation: "\(fdaPlaces.joined(separator: ", ")) are checked only with Full Disk Access.",
                                 items: [], notice: "Needs Full Disk Access"))
        }
        return Result(target: t, categories: cats)
    }

    /// The same item as Info: shown, never selectable.
    static func info(_ i: CleanItem, _ reason: String) -> CleanItem {
        var n = CleanItem(path: i.path, name: i.name, size: i.size, newest: i.newest, risk: .info, method: .none,
                          reason: reason, scope: i.scope, fileID: i.fileID, owners: i.owners, ownerNames: i.ownerNames)
        n.insideBundle = i.insideBundle
        return n
    }

    /// The name of an app bundle inside `path` (depth 3), if any. No related item holding an app is moved.
    static func nestedApp(_ path: String) -> String? {
        var found: String?
        if Leftovers.isBundle(path) { return AppInventory.info(path)?.name ?? URL(fileURLWithPath: path).lastPathComponent }
        Leftovers.nestedApps(path, depth: 3) { p in
            if found == nil { found = AppInventory.info(p)?.name ?? URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent }
        }
        return found
    }

    /// Apps the user can pick from: everything in /Applications and ~/Applications, with the reason
    /// an app can't be uninstalled, if any.
    static func choices(_ roots: Roots, selfIDs: [String]) -> [(app: AppInfo, refusal: String?)] {
        var out: [(app: AppInfo, refusal: String?)] = []
        for dir in [roots.applications, roots.h("Applications")] {
            Leftovers.nestedApps(Roots.canonical(dir), depth: 3) { p in
                guard let a = AppInventory.info(p) else { return }
                if a.id.lowercased().hasPrefix("com.apple.") { return }   // shipped with macOS: not offered
                out.append((a, refusal(p, roots: roots, selfIDs: selfIDs)))
            }
        }
        return out.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }
}

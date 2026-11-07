// Leftovers finder (spec 9): the places it looks, the installed-app evidence, and the orphan
// decision. Foundation only, so scripts/selftest.sh can compile it. The disk side (listing,
// measuring, probes) is in Leftovers.swift.
//
// Everything here leans towards keeping: an item is reported only when every check says its app
// is gone, and every reported item is Review, never pre-selected (S5, S6).

import Foundation

// MARK: - Places (spec 9.1)

struct LeftoverPlace: Equatable {
    enum Tier: Equatable {
        case orphan       // scanned for orphans: its names can start a group
        case reviewOnly   // only joins a group found elsewhere; never pre-selected
        case infoOnly     // needs administrator rights: shown, never selectable
    }
    let id: String
    let rel: String            // relative to the home folder, or to /Library when `system`
    var system = false
    let tier: Tier
    var suffix: String? = nil  // only names with this extension (compared without case)
    let noun: String           // used in reasons: "<noun> of <app>"
    var needsFDA = false       // entered only with Full Disk Access (spec 3.1, 9.1)

    func root(_ r: Roots) -> String { system ? r.library + "/" + rel : r.h(rel) }

    static let all: [LeftoverPlace] = [
        LeftoverPlace(id: "appSupport", rel: "Library/Application Support", tier: .orphan, noun: "App data"),
        LeftoverPlace(id: "caches", rel: "Library/Caches", tier: .orphan, noun: "Cache"),
        LeftoverPlace(id: "preferences", rel: "Library/Preferences", tier: .orphan, suffix: ".plist", noun: "Settings file"),
        LeftoverPlace(id: "savedState", rel: "Library/Saved Application State", tier: .orphan, suffix: ".savedstate",
                      noun: "Saved window state"),
        LeftoverPlace(id: "httpStorages", rel: "Library/HTTPStorages", tier: .orphan, noun: "Web storage"),
        LeftoverPlace(id: "webKit", rel: "Library/WebKit", tier: .orphan, noun: "WebKit data"),
        LeftoverPlace(id: "logs", rel: "Library/Logs", tier: .orphan, noun: "Logs"),
        LeftoverPlace(id: "cookies", rel: "Library/Cookies", tier: .orphan, suffix: ".binarycookies", noun: "Cookies"),
        LeftoverPlace(id: "containers", rel: "Library/Containers", tier: .reviewOnly, noun: "App container", needsFDA: true),
        LeftoverPlace(id: "groupContainers", rel: "Library/Group Containers", tier: .reviewOnly, noun: "Shared app data",
                      needsFDA: true),
        LeftoverPlace(id: "appScripts", rel: "Library/Application Scripts", tier: .reviewOnly, noun: "App scripts folder"),
        LeftoverPlace(id: "launchAgents", rel: "Library/LaunchAgents", tier: .reviewOnly, suffix: ".plist",
                      noun: "Launch agent"),
        LeftoverPlace(id: "sysLaunchAgents", rel: "LaunchAgents", system: true, tier: .infoOnly, suffix: ".plist",
                      noun: "Launch agent for all users"),
        LeftoverPlace(id: "sysLaunchDaemons", rel: "LaunchDaemons", system: true, tier: .infoOnly, suffix: ".plist",
                      noun: "Background service"),
        LeftoverPlace(id: "privilegedHelpers", rel: "PrivilegedHelperTools", system: true, tier: .infoOnly,
                      noun: "Privileged helper"),
        LeftoverPlace(id: "sysAppSupport", rel: "Application Support", system: true, tier: .infoOnly,
                      noun: "App data for all users"),
    ]

    static func named(_ id: String) -> LeftoverPlace { all.first { $0.id == id }! }
}

// MARK: - Candidates

/// One child of a leftover place, measured.
struct LeftoverCandidate {
    let place: LeftoverPlace
    let name: String               // file or folder name as on disk
    let path: String
    let key: CandidateKey
    var size: Int64 = 0
    var newest: Date? = nil        // nil: unknown (unreadable or too many entries), so treated as recent
    var fileID: [UInt64] = []
    var doubt: String? = nil       // something that keeps its whole group (an app inside, a socket, unreadable…)
    var immovable: String? = nil   // the user can't move it: shown as Info with this reason
    var bundleName: String? = nil  // CFBundleName found in its settings file or saved state
    var containerID: String? = nil // Containers: MCMMetadataIdentifier from the container's metadata

    init(place: LeftoverPlace, name: String, path: String) {
        self.place = place
        self.name = name
        self.path = path
        self.key = CandidateKey.parse(name)
    }
}

// MARK: - Evidence that an app is installed (spec 9.2)

enum SpotlightAnswer: Equatable { case found, notFound, failed }

/// What the scan knows about installed apps. Built by Leftovers.evidence from the inventory and
/// the extra probes; selftests build it by hand.
struct LeftoverEvidence {
    /// The installed thing an ID belongs to (probes 1, 3–7), or nil when nothing claims it.
    /// Must answer "installed" whenever a probe fails (S5).
    var installed: (String) -> String?
    /// Normalized names (`normalize`) of installed apps, their executables, plug-ins, running apps
    /// and command-line tools.
    let names: Set<String>
    /// The same names as `EvidenceName.key` (no spaces, dots, hyphens or underscores).
    let nameKeys: Set<String>
    /// Vendor prefixes (first two components, lowercased) of installed apps.
    var vendors: Set<String>
    /// Probe 2, asked once per group with every ID of the group and their dot-prefixes.
    var spotlight: ([String]) -> SpotlightAnswer
    /// App Monitor's own bundle IDs, never reported.
    var selfIDs: [String]

    init(installed: @escaping (String) -> String?, names: Set<String>, vendors: Set<String>,
         spotlight: @escaping ([String]) -> SpotlightAnswer, selfIDs: [String]) {
        self.installed = installed
        self.names = names
        self.nameKeys = Set(names.map(EvidenceName.key))
        self.vendors = vendors
        self.spotlight = spotlight
        self.selfIDs = selfIDs
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

// MARK: - The decision (spec 9.3)

struct LeftoverItem {
    let candidate: LeftoverCandidate
    let reason: String
    let selectable: Bool           // false: Info row (needs admin, or the user can't move it)
    let ageLimit: Int
}

struct LeftoverGroup {
    enum Confidence: Equatable { case high, low }
    let key: String                // lowercased group ID, or "name:" + the High group it mirrors
    let id: String                 // the group's ID as found on disk (for display)
    let title: String              // last-known app name, or the ID
    let confidence: Confidence
    var sameVendor = false         // Low because an app of the same vendor is on this Mac
    var appName: String? = nil     // the app's last-known name (used for the running-app check by name)
    let explanation: String
    let items: [LeftoverItem]
    var size: Int64 { items.reduce(0) { $0 + $1.candidate.size } }
}

struct LeftoverDecision {
    var groups: [LeftoverGroup] = []
    var spotlightFailed = 0        // groups left out because Spotlight didn't answer (S5)
}

enum LeftoverMatcher {
    enum Screen: Equatable {
        case drop(String)                       // never a leftover, with the reason (for tests and logs)
        case bundle(group: String, low: Bool)   // bundle-ID candidate; low: an app of the same vendor is installed
        case name                               // name candidate: needs positive evidence (9.3, Low)
    }

    /// The cheap checks, run on a name before anything is measured.
    static func screen(_ k: CandidateKey, _ ev: LeftoverEvidence) -> Screen {
        let key = k.key.lowercased()
        if Protection.isProtected(k.key) { return .drop("protected") }
        if ev.selfIDs.contains(where: { BundleIDs.related(key, $0) }) { return .drop("App Monitor") }
        guard k.kind == .bundleID else { return .name }
        let base = BundleIDs.base(key)
        // 9.3 High (1): neither the ID nor its base belongs to an installed app. Asked with the
        // case found on disk, because LaunchServices may compare IDs with case.
        let diskBase = BundleIDs.base(k.key)
        if let who = ev.installed(k.key) ?? (base != key ? ev.installed(diskBase) : nil) { return .drop("installed: \(who)") }
        // 9.3 High (5): an installed app's name equals a whole component of the key. Hyphens and
        // underscores are ignored too ("orca-slicer" is OrcaSlicer), which only keeps more.
        let comps = key.split(separator: ".").map(String.init)
        if let c = comps.first(where: { ev.names.contains($0) || ev.nameKeys.contains(EvidenceName.key($0)) }) {
            return .drop("named like an installed app: \(c)")
        }
        return .bundle(group: base, low: ev.vendors.contains(BundleIDs.vendor(key)))
    }

    /// `id` and every dot-prefix of it with at least 3 components (com.a.b.c → com.a.b.c, com.a.b).
    static func prefixes(_ id: String) -> [String] {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return [id] }
        return (3...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }

    static func ageDays(_ c: LeftoverCandidate, _ now: Date) -> Int? { days(since: c.newest, now: now) }

    /// Groups the candidates and decides which groups are reported. Every candidate should come
    /// from `screen` first; candidates it drops are ignored here too.
    /// `kept` are keys of names the scan dropped because something installed claims them: a group
    /// that one of them belongs to, or that belongs to one of them, may be read by that app, so it
    /// is left out too (a helper still registered keeps its main app's data).
    static func decide(_ candidates: [LeftoverCandidate], ev: LeftoverEvidence, limits: AgeLimits,
                       now: Date, kept: [String] = []) -> LeftoverDecision {
        var decision = LeftoverDecision()
        var screened: [(LeftoverCandidate, String, Bool)] = []   // candidate, group ID, low
        var names: [LeftoverCandidate] = []
        for c in candidates {
            switch screen(c.key, ev) {
            case .drop: continue
            case .name:
                if c.place.tier == .orphan { names.append(c) }
            case .bundle(let g, let low):
                // Containers count only when the container's own metadata names this ID (9.1).
                if c.place.id == "containers" {
                    guard let mid = c.containerID, mid.caseInsensitiveCompare(c.key.key) == .orderedSame else { continue }
                }
                screened.append((c, g, low))
            }
        }

        // Groups start from the places scanned for orphans. A group ID that belongs to a shorter
        // one (com.vendor.app.thing → com.vendor.app) joins it, so one app is one entry.
        let starts = Set(screened.filter { $0.0.place.tier == .orphan }.map(\.1))
        let roots = starts.sorted { ($0.split(separator: ".").count, $0) < ($1.split(separator: ".").count, $1) }
        var rootOf: [String: String] = [:]
        for g in roots {
            rootOf[g] = roots.first { $0 != g && rootOf[$0] == $0 && BundleIDs.belongs(g, to: $0) } ?? g
        }
        func owner(_ c: LeftoverCandidate, _ g: String) -> String? {
            if let r = rootOf[g] { return rootOf[r] ?? r }
            // Review-only and Info places join the longest group their key belongs to.
            let key = c.key.key.lowercased()
            return roots.filter { rootOf[$0] == $0 && BundleIDs.belongs(key, to: $0) }.max { $0.count < $1.count }
        }
        var members: [String: [(LeftoverCandidate, Bool)]] = [:]
        for (c, g, low) in screened {
            guard let r = owner(c, g) else { continue }
            members[r, default: []].append((c, low))
        }

        var high: [String: (title: String, group: LeftoverGroup)] = [:]
        for (g, list) in members.sorted(by: { $0.key < $1.key }) {
            let keys = list.map { $0.0.key.key.lowercased() } + [g]
            if kept.contains(where: { k in keys.contains { BundleIDs.related(k, $0) } }) { continue }
            let vendorLow = list.contains { $0.1 }
            // Libraries inside other apps write settings under their own IDs too, so a group that is
            // only settings files can't be pinned on a removed app.
            let onlySettings = list.filter { $0.0.place.tier == .orphan }.allSatisfy { $0.0.place.id == "preferences" }
            // Its last-known name is an installed app's name: the app may live on under a new ID.
            let renamed = list.compactMap { $0.0.bundleName }.contains { ev.nameKeys.contains(EvidenceName.key($0)) }
            let low = vendorLow || onlySettings || renamed
            let limit = low ? limits.lowConfidence : limits.leftovers
            let cands = list.map(\.0)
            // 9.3 High (3), for the whole group: if any part of the app's data is recent or can't be
            // read, the app may still be in use somewhere, so none of it is reported (S5).
            guard cands.allSatisfy({ $0.doubt == nil }),
                  cands.allSatisfy({ (ageDays($0, now) ?? -1) >= limit }) else { continue }
            // Probe 2 last, because it is the slowest. No answer counts as installed (S5).
            var ids: [String] = []
            for c in cands { for p in prefixes(c.key.key) where !ids.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) { ids.append(p) } }
            switch ev.spotlight(ids) {
            case .found: continue
            case .failed: decision.spotlightFailed += 1; continue
            case .notFound: break
            }
            let shown = cands.filter { $0.place.tier == .orphan }.min { $0.key.key.count < $1.key.key.count }?.key.key ?? g
            let bundleName = cands.compactMap(\.bundleName).first { !$0.isEmpty }
            let title = bundleName ?? shown
            let vendor = BundleIDs.vendor(shown)
            let note = vendorLow ? "Another app from \(vendor) is on this Mac and may use it, so check it first."
                : renamed ? "An app with the same name is on this Mac and may use it under a new ID, so check it first."
                : onlySettings ? "Only a settings file was found. Libraries inside other apps write settings like this too, so check it first."
                : nil
            let items = cands.sorted { $0.path < $1.path }.map { c in
                item(c, reason: "\(c.place.noun) of \(bundleName.map { "\($0) (\(shown))" } ?? shown), an app not found on this Mac",
                     note: note, limit: limit, now: now)
            }
            let group = LeftoverGroup(key: g, id: shown, title: title, confidence: low ? .low : .high, sameVendor: vendorLow, appName: bundleName,
                                      explanation: vendorLow ? "\(shown) · same vendor as an app on this Mac"
                                          : renamed ? "\(shown) · an app with this name is on this Mac"
                                          : onlySettings ? "\(shown) · settings file only" : "\(shown) · not found on this Mac",
                                      items: items)
            decision.groups.append(group)
            if !low, let bundleName { high[EvidenceName.key(bundleName)] = (bundleName, group) }
        }

        // 9.3 Low: a plain name counts only when it equals the last-known name of a High group,
        // and nothing installed has that name.
        var byGroup: [String: [LeftoverCandidate]] = [:]
        for c in names {
            let n = EvidenceName.key(c.key.key)
            guard c.key.key.count >= 5, !ev.names.contains(LeftoverEvidence.normalize(c.key.key)),
                  !ev.nameKeys.contains(n),
                  let h = high[n], c.doubt == nil, (ageDays(c, now) ?? -1) >= limits.lowConfidence else { continue }
            byGroup[h.group.key, default: []].append(c)
        }
        for (g, cands) in byGroup.sorted(by: { $0.key < $1.key }) {
            guard let h = high.values.first(where: { $0.group.key == g }) else { continue }
            let items = cands.sorted { $0.path < $1.path }.map { c in
                item(c, reason: "\(c.place.noun) named “\(c.key.key)”, like \(h.title) (\(h.group.id)), an app not found on this Mac",
                     note: "Items named by app name can belong to another app, so check it first.",
                     limit: limits.lowConfidence, now: now)
            }
            decision.groups.append(LeftoverGroup(key: "name:" + g, id: h.group.id, title: "Named like \(h.title)", confidence: .low,
                                                 appName: h.title, explanation: "named like \(h.title), which isn't on this Mac",
                                                 items: items))
        }
        return decision
    }

    /// "<noun> of <app>, an app not found on this Mac, unchanged for 94 days, limit 30." (S9),
    /// then the caveat and, for rows that can't be selected, why.
    static func item(_ c: LeftoverCandidate, reason: String, note: String?, limit: Int, now: Date) -> LeftoverItem {
        let age = ageDays(c, now).map { ", " + Rules.ageText($0, limit) } ?? ""
        var text = reason + age + "."
        if let note { text += " " + note }
        if c.place.tier == .infoOnly {
            return LeftoverItem(candidate: c, reason: text + " Needs administrator rights to remove. Remove it in Finder.",
                                selectable: false, ageLimit: limit)
        }
        if let why = c.immovable { return LeftoverItem(candidate: c, reason: text + " " + why, selectable: false, ageLimit: limit) }
        return LeftoverItem(candidate: c, reason: text, selectable: true, ageLimit: limit)
    }
}

/// Names compared for the Low-confidence evidence: without case, spaces, dots and hyphens.
enum EvidenceName {
    static func key(_ s: String) -> String {
        String(s.lowercased().filter { !" .-_".contains($0) })
    }
}

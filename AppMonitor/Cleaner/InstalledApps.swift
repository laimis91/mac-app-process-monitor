// Installed and running app inventory (spec 9.2). Foundation only: the folder scan lives here,
// and the AppKit probes (LaunchServices, running apps) are passed in by SystemProbes.swift.
//
// The junk rules use probes 1 (LaunchServices), 3 (folders), 4 (running) and 6 (embedded bundles).
// The leftovers finder (Leftovers.swift) adds probes 2 (Spotlight), 5 (launchd labels) and
// 7 (plug-in folders) on top, only for its own decisions, so they never make a junk item Safe.

import Foundation

struct AppInfo: Codable, Equatable {
    let id: String
    let name: String
    let path: String
    var names: [String] = []      // every name the bundle gives: name, display name, executable, file name
}

struct RunningApp: Codable, Equatable {
    let id: String
    let name: String
}

final class AppInventory {
    private(set) var apps: [String: AppInfo] = [:]       // lowercased bundle ID → app
    private(set) var embedded: [String: AppInfo] = [:]   // embedded bundle ID → its outer app
    private(set) var embeddedAll: [String: [AppInfo]] = [:]   // embedded bundle ID → every app that embeds it
    let lookup: ((String) -> AppInfo?)?                  // LaunchServices probe, real mode only
    let running: () -> [RunningApp]

    init(roots: Roots, lookup: ((String) -> AppInfo?)?, running: @escaping () -> [RunningApp]) {
        self.lookup = lookup
        self.running = running
        var folders: [(String, Int)] = [(roots.applications, 3), (roots.home + "/Applications", 3),
                                        (roots.systemApplications, 2)]
        if !roots.fixture {
            folders += [("/opt/homebrew/Caskroom", 3), ("/usr/local/Caskroom", 3),
                        (roots.home + "/Library/Application Support/Setapp/Applications", 2)]
        }
        for (dir, depth) in folders { scan(dir, depth: depth) }
    }

    private func scan(_ dir: String, depth: Int) {
        guard depth > 0, case .ok(let names) = ScanEngine.children(dir) else { return }
        for n in names {
            let p = dir + "/" + n
            guard let st = ScanEngine.lstatInfo(p), (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            if n.lowercased().hasSuffix(".app") {
                if let a = Self.info(p) {
                    apps[a.id.lowercased()] = a
                    for e in Self.embeddedIDs(p) {
                        embeddedAll[e.lowercased(), default: []].append(a)
                        if apps[e.lowercased()] == nil { embedded[e.lowercased()] = a }
                    }
                }
            } else {
                scan(p, depth: depth - 1)
            }
        }
    }

    /// A bundle's Info.plist: Contents/Info.plist, or with `flat` also a top-level Info.plist
    /// (bundles without a Contents folder, such as some plug-ins and XPC services).
    static func infoPlist(_ bundle: String, flat: Bool = false) -> NSDictionary? {
        NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")
            ?? (flat ? NSDictionary(contentsOfFile: bundle + "/Info.plist") : nil)
    }

    static func info(_ bundle: String) -> AppInfo? {
        guard let d = infoPlist(bundle),
              let id = d["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let file = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
        let name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String) ?? file
        var names: [String] = []
        for n in [d["CFBundleName"] as? String, d["CFBundleDisplayName"] as? String, d["CFBundleExecutable"] as? String, file]
            where n != nil && !n!.isEmpty && !names.contains(n!) { names.append(n!) }
        return AppInfo(id: id, name: name, path: bundle, names: names)
    }

    /// Bundle IDs of helpers, extensions and login items inside an app (probe 6).
    static func embeddedIDs(_ app: String) -> [String] { embeddedBundles(app).map(\.id) }

    /// The helpers, extensions and login items inside an app, with their paths.
    static func embeddedBundles(_ app: String) -> [(id: String, path: String)] {
        var out: [(id: String, path: String)] = []
        let c = app + "/Contents"
        for sub in ["PlugIns", "Library/LoginItems", "Helpers", "XPCServices", "Library/LaunchServices",
                    "Frameworks"] {
            guard case .ok(let names) = ScanEngine.children(c + "/" + sub) else { continue }
            for n in names {
                if sub == "Frameworks" && !n.lowercased().hasSuffix(".app") { continue }
                let p = c + "/" + sub + "/" + n
                if let id = infoPlist(p, flat: true)?["CFBundleIdentifier"] as? String {
                    out.append((id, p))
                }
            }
        }
        return out
    }

    /// The installed app that owns `id` (equal, or `id` starts with its ID and a dot).
    func owner(of id: String) -> AppInfo? {
        let k = id.lowercased()
        if let a = apps[k] ?? embedded[k] { return a }
        // longest matching installed ID wins
        var best: AppInfo?
        for (aid, a) in apps where BundleIDs.belongs(k, to: aid) {
            if best == nil || aid.count > best!.id.count { best = a }
        }
        if let best { return best }
        // the same for embedded IDs: the longest matching one, not whichever comes first
        var bestEmbedded: (id: String, app: AppInfo)?
        for (eid, a) in embedded where BundleIDs.belongs(k, to: eid) {
            if bestEmbedded == nil || eid.count > bestEmbedded!.id.count { bestEmbedded = (eid, a) }
        }
        if let bestEmbedded { return bestEmbedded.app }
        if let l = lookup, let a = l(id) { return a }
        let base = BundleIDs.base(id)
        if base != id { return owner(of: base) }
        return nil
    }

    /// Name of a running app that owns or is owned by one of `ids`, if any.
    func runningOwner(_ ids: [String], names: [String] = [], snapshot: [RunningApp]) -> String? {
        for r in snapshot {
            if ids.contains(where: { BundleIDs.related(r.id, $0) }) { return r.name }
            // without case, spaces, dots and hyphens: a folder "GoneApp" matches a running "Gone App"
            if names.contains(where: { !$0.isEmpty && EvidenceName.key($0) == EvidenceName.key(r.name) }) { return r.name }
        }
        return nil
    }
}

/// Fixture mode: running apps are listed in `<root>/running.txt` as `bundle.id|Name` lines.
enum FixtureRunning {
    static func read(_ root: String) -> [RunningApp] {
        guard let s = try? String(contentsOfFile: root + "/running.txt", encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", maxSplits: 1).map(String.init)
            return p.count == 2 ? RunningApp(id: p[0], name: p[1]) : nil
        }
    }
}

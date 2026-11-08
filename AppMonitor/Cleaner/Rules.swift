// Phase 1 junk rules (spec 7.1). Foundation only.
//
// Each rule owns exactly the paths it lists (S14). The general cache rule excludes every path a
// more specific rule claims, and every parent folder of such a path.

import Foundation

struct ScanContext {
    let roots: Roots
    let limits: AgeLimits
    let fda: FDAStatus
    let ignore: Set<String>          // lowercased canonical paths
    let inventory: AppInventory
    let running: [RunningApp]
    let tools: ToolLocator
    let links = LinkSet()
    let cancel: CancelFlag
    let now: Date
    let uid = getuid()
    /// Probe 2 for the leftovers finder (spec 9.2). No answer counts as installed (S5).
    var spotlight: ([String]) -> SpotlightAnswer = { _ in .failed }

    func ignored(_ path: String) -> Bool { ignore.contains(path.lowercased()) }
}

enum Rules {
    // MARK: Claims under ~/Library/Caches (S14)

    /// Children of ~/Library/Caches owned by the tool rows; never offered as app caches.
    static let devCacheDirs = ["Homebrew", "pip", "pip-tools", "Yarn", "yarn", "pnpm", "node-gyp",
                               "NuGetPackages", "JetBrains"]
    /// Paths below ~/Library/Caches claimed by specific rules.
    static let claimedCachePaths = devCacheDirs + ["Unity/upm"]
    static let claimedCachePrefixes = ["com.unity3d."]

    /// True if a child of ~/Library/Caches belongs to a more specific rule, or is a parent of one.
    static func cacheChildClaimed(_ name: String) -> Bool {
        let n = name.lowercased()
        if claimedCachePrefixes.contains(where: { n.hasPrefix($0) }) { return true }
        return claimedCachePaths.contains { $0.split(separator: "/").first!.lowercased() == n }
    }

    // MARK: Rule order (also the display order)

    static let order = ["J-CACHE", "J-LOGS", "J-CRASH", "J-TMP", "J-MAILDL", "J-IOSBK", "J-TRASH",
                        "J-XC-DD", "J-XC-DS", "J-XC-SIM", "J-UNITY", "J-UNITY-UPM", "J-NUGET-HTTP",
                        "J-NUGET-PKG", "J-NPM", "J-PNPM", "J-YARN", "J-PIP", "J-BREW", "J-DOCKER",
                        "J-DEVCACHE-DIRS"]

    static let titles: [String: String] = [
        "J-CACHE": "App caches", "J-LOGS": "Logs", "J-CRASH": "Crash reports", "J-TMP": "Temporary files",
        "J-MAILDL": "Mail attachments", "J-IOSBK": "Device backups", "J-TRASH": "Trash",
        "J-XC-DD": "Xcode DerivedData", "J-XC-DS": "Device support", "J-XC-SIM": "Simulators",
        "J-UNITY": "Unity caches", "J-UNITY-UPM": "Unity packages", "J-DEVCACHE-DIRS": "Tool caches",
        "J-NUGET-HTTP": "NuGet", "J-NUGET-PKG": "NuGet packages", "J-NPM": "npm", "J-PNPM": "pnpm",
        "J-YARN": "Yarn", "J-PIP": "pip", "J-BREW": "Homebrew", "J-DOCKER": "Docker",
    ]

    static let builders: [(String, (ScanContext) -> Category?)] = [
        ("J-CACHE", appCaches), ("J-LOGS", logs), ("J-CRASH", crashReports), ("J-TMP", temp),
        ("J-MAILDL", mailDownloads), ("J-IOSBK", backups), ("J-TRASH", trash),
        ("J-XC-DD", derivedData), ("J-XC-DS", deviceSupport), ("J-XC-SIM", simulators),
        ("J-UNITY", unity), ("J-UNITY-UPM", unityUPM), ("J-DEVCACHE-DIRS", devCacheFolders),
    ] + toolRules.map { t in (t.id, { ctx in toolCategory(t, ctx) }) }

    /// Runs every rule, at most 4 at a time, and reports each category as it finishes.
    static func scan(_ ctx: ScanContext, progress: @escaping (String) -> Void,
                     found: @escaping (Category) -> Void) {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        for (id, build) in builders {
            q.addOperation {
                if ctx.cancel.isSet { return }
                progress(id)
                if let c = build(ctx), !ctx.cancel.isSet { found(c) }
            }
        }
        q.waitUntilAllOperationsAreFinished()
    }

    // MARK: Helpers

    static func noticeFor(_ err: Int32) -> String {
        err == EPERM ? "Needs Full Disk Access" : "Can't read this folder"
    }

    static func ageText(_ d: Int, _ limit: Int) -> String { "unchanged for \(d) days, limit \(limit)" }

    /// Lists a folder's direct children and turns each into an item with `make`.
    /// Returns nil when the folder doesn't exist.
    static func children(_ ctx: ScanContext, _ root: String,
                         needsWrite: Bool = true,
                         want: (String, stat) -> Bool = { _, _ in true },
                         make: (String, String, Measure, stat) -> CleanItem?) -> (items: [CleanItem], notice: String?)? {
        switch ScanEngine.children(root) {
        case .missing: return nil
        case .noAccess(let e): return ([], noticeFor(e))
        case .ok(let names):
            var out: [CleanItem] = []
            for n in names {
                if ctx.cancel.isSet { break }
                let p = root + "/" + n
                guard !ctx.ignored(p), let st = ScanEngine.lstatInfo(p) else { continue }
                if (st.st_mode & S_IFMT) == S_IFLNK { continue }      // nothing to reclaim (S12)
                guard want(n, st) else { continue }                    // measured by its own rule only
                // Items the user can't move on their own would make Finder ask for a password: not offered.
                if needsWrite && !Cleaner.userCanMove(p, st) { continue }
                let m = ScanEngine.measure(p, links: ctx.links, cancel: ctx.cancel)
                // S5: not fully readable, or holding sockets/pipes an app may be using: not offered.
                guard m.complete, !m.special, !m.locked else { continue }
                if let item = make(n, p, m, st) { out.append(item) }
            }
            return (out, nil)
        }
    }

    static func aged(_ m: Measure, _ limit: Int, _ ctx: ScanContext) -> Int? {
        guard m.complete, let d = days(since: m.newest, now: ctx.now), d >= limit else { return nil }
        return d
    }

    static func appCategory(_ id: String, _ title: String, _ group: CategoryGroup, _ explanation: String,
                            _ r: (items: [CleanItem], notice: String?)?, method: Method = .trash) -> Category? {
        guard let r, !(r.items.isEmpty && r.notice == nil) else { return nil }
        return Category(id: id, title: title, group: group, method: method, explanation: explanation,
                        items: r.items.sorted { $0.size > $1.size }, notice: r.notice)
    }

    static func blockedBy(_ ids: [String], names: [String] = [], _ ctx: ScanContext) -> String? {
        ctx.inventory.runningOwner(ids, names: names, snapshot: ctx.running)
    }

    // MARK: General

    static func appCaches(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Caches")
        let r = children(ctx, root, want: { n, _ in
            !cacheChildClaimed(n) && !Protection.isProtected(CandidateKey.parse(n).key)
        }) { n, p, m, _ in
            let k = CandidateKey.parse(n)
            var risk = Risk.review
            var reason: String
            var owners: [String] = []
            if k.kind == .bundleID {
                owners = [k.key]
                if let app = ctx.inventory.owner(of: k.key) {
                    risk = .safe
                    if app.id.caseInsensitiveCompare(k.key) != .orderedSame { owners.append(app.id) }
                    reason = "Cache folder of \(app.name), an app on this Mac. Apps re-create their caches."
                } else {
                    reason = "Cache folder of \(k.key). Its app wasn't found on this Mac, so check it first."
                }
            } else {
                reason = "Cache folder “\(n)”. Its app can't be identified by name, so check it first."
            }
            var item = CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: risk, method: .trash,
                                 reason: reason, scope: .rule(root: root), fileID: m.fileID, owners: owners,
                                 checkOpenFiles: true)
            item.ownerNames = k.kind == .name ? [n] : []
            item.runningOwner = blockedBy(owners, names: item.ownerNames, ctx)
            return item
        }
        return appCategory("J-CACHE", "App caches", .general,
                           "Caches apps keep to work faster. Apps re-create them when needed.", r)
    }

    static func logs(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Logs"), limit = ctx.limits.logs
        let r = children(ctx, root, want: { n, _ in
            n.caseInsensitiveCompare("DiagnosticReports") != .orderedSame
        }) { n, p, m, _ in
            guard let d = aged(m, limit, ctx) else { return nil }
            let k = CandidateKey.parse(n)
            let owners = k.kind == .bundleID ? [k.key] : []
            var item = CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .safe, method: .trash,
                                 reason: "Log files, \(ageText(d, limit)).", scope: .rule(root: root), fileID: m.fileID,
                                 owners: owners, ageLimitDays: limit)
            item.runningOwner = blockedBy(owners, ctx)
            return item
        }
        return appCategory("J-LOGS", "Logs", .general, "Old log files written by apps.", r)
    }

    static func crashReports(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Logs/DiagnosticReports"), limit = ctx.limits.logs
        let r = children(ctx, root, want: { _, st in (st.st_mode & S_IFMT) == S_IFREG }) { n, p, m, _ in
            guard let d = aged(m, limit, ctx) else { return nil }
            return CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .safe, method: .trash,
                             reason: "Crash report, \(ageText(d, limit)).", scope: .rule(root: ctx.roots.h("Library/Logs")), fileID: m.fileID,
                             ageLimitDays: limit)
        }
        return appCategory("J-CRASH", "Crash reports", .general, "Reports saved when an app crashed.", r)
    }

    static func temp(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.temp, limit = ctx.limits.temp
        let r = children(ctx, root, want: { n, st in
            st.st_uid == ctx.uid && n != "TemporaryItems" && !Protection.isProtected(CandidateKey.parse(n).key)
        }) { n, p, m, _ in
            guard let d = aged(m, limit, ctx) else { return nil }
            return CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .review, method: .trash,
                             reason: "Temporary item, \(ageText(d, limit)). Moved only if no app has it open.",
                             scope: .rule(root: root), fileID: m.fileID, ageLimitDays: limit, checkOpenFiles: true)
        }
        return appCategory("J-TMP", "Old temporary files", .general,
                           "Files apps left in your temporary folder.", r)
    }

    static func mailDownloads(_ ctx: ScanContext) -> Category? {
        let limit = ctx.limits.mail
        var roots: [(String, String)] = [(ctx.roots.h("Library/Mail Downloads"), ctx.roots.h("Library/Mail Downloads"))]
        let container = ctx.roots.h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        if ctx.fda == .granted { roots.append((container, ctx.roots.h("Library/Containers"))) }
        var items: [CleanItem] = []
        var notice: String? = nil
        var any = false
        for (dir, allow) in roots {
            guard let r = children(ctx, dir, make: { n, p, m, _ in
                guard let d = aged(m, limit, ctx) else { return nil }
                var item = CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .review, method: .trash,
                                     reason: "Attachment Mail saved for opening, \(ageText(d, limit)). The original stays in the email.",
                                     scope: .rule(root: allow), fileID: m.fileID, owners: ["com.apple.mail"], ageLimitDays: limit)
                item.runningOwner = blockedBy(["com.apple.mail"], ctx)
                return item
            }) else { continue }
            any = true
            items += r.items
            notice = notice ?? r.notice
        }
        if ctx.fda != .granted, FileManager.default.fileExists(atPath: ctx.roots.h("Library/Containers/com.apple.mail")) {
            any = true; notice = notice ?? "Needs Full Disk Access"
        }
        guard any else { return nil }
        return appCategory("J-MAILDL", "Mail attachments", .general,
                           "Copies of attachments you opened from Mail.", (items, notice))
    }

    static func backups(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Application Support/MobileSync/Backup")
        let r = children(ctx, root, needsWrite: false) { n, p, m, _ in
            let info = NSDictionary(contentsOfFile: p + "/Info.plist")
            let device = (info?["Device Name"] as? String) ?? n
            var when = ""
            if let d = info?["Last Backup Date"] as? Date {
                let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
                when = ", made \(f.string(from: d))"
            }
            return CleanItem(path: p, name: device, size: m.size, newest: m.newest, risk: .info, method: .none,
                             reason: "Backup of \(device)\(when). Delete it in Finder → your device → Manage Backups.",
                             scope: .none, fileID: m.fileID)
        }
        return appCategory("J-IOSBK", "iPhone and iPad backups", .general,
                           "Shown for information. Manage them in Finder.", r, method: .none)
    }

    static func trash(_ ctx: ScanContext) -> Category? {
        let p = ctx.roots.h(".Trash")
        switch ScanEngine.children(p) {
        case .missing: return nil
        case .noAccess(let e):
            return Category(id: "J-TRASH", title: "Trash", group: .general, method: .none,
                            explanation: "Empty the Trash in Finder to free this space.", items: [], notice: noticeFor(e))
        case .ok:
            let m = ScanEngine.measure(p, links: ctx.links, cancel: ctx.cancel)
            let item = CleanItem(path: p, name: "Trash", size: m.size, newest: m.newest, risk: .info, method: .none,
                                 reason: "Items already in the Trash. Empty it in Finder to free this space.",
                                 scope: .none, fileID: m.fileID)
            return Category(id: "J-TRASH", title: "Trash", group: .general, method: .none,
                            explanation: "Empty the Trash in Finder to free this space.", items: [item])
        }
    }

    // MARK: Developer (Trash method and info)

    static let xcode = "com.apple.dt.Xcode"

    static func derivedData(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Developer/Xcode/DerivedData")
        let r = children(ctx, root) { n, p, m, _ in
            var item = CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .safe, method: .trash,
                                 reason: "Xcode build data. Xcode rebuilds it on the next build.",
                                 scope: .rule(root: root), fileID: m.fileID, owners: [xcode], checkOpenFiles: true)
            item.runningOwner = blockedBy([xcode], ctx)
            return item
        }
        return appCategory("J-XC-DD", "Xcode DerivedData", .developer, "Build products and indexes.", r)
    }

    static func deviceSupport(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Developer/Xcode/iOS DeviceSupport")
        let names: [String]
        switch ScanEngine.children(root) {
        case .missing: return nil
        case .noAccess(let e): return appCategory("J-XC-DS", "Old device support", .developer, "", ([], noticeFor(e)))
        case .ok(let n): names = n
        }
        let old = Set(Versions.oldDeviceSupport(names))
        let r = children(ctx, root, want: { n, _ in old.contains(n) }) { n, p, m, _ in
            var item = CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .review, method: .trash,
                                 reason: "Debug symbols for an older iOS version. The 2 newest versions are kept; Xcode copies them again when that device connects.",
                                 scope: .rule(root: root), fileID: m.fileID, owners: [xcode])
            item.runningOwner = blockedBy([xcode], ctx)
            return item
        }
        return appCategory("J-XC-DS", "Old device support", .developer, "Symbols for iOS versions you may no longer test on.", r)
    }

    static func unity(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Caches")
        let r = children(ctx, root, want: { n, _ in n.lowercased().hasPrefix("com.unity3d.") }) { n, p, m, _ in
            var item = CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .review, method: .trash,
                                 reason: "Unity cache. Unity re-creates it, which can make the next start slower.",
                                 scope: .rule(root: root), fileID: m.fileID, owners: ["com.unity3d"], checkOpenFiles: true)
            item.runningOwner = blockedBy(["com.unity3d"], ctx)
            return item
        }
        guard let r, !r.items.isEmpty else { return nil }
        return appCategory("J-UNITY", "Unity caches", .developer, "Caches of the Unity Editor and Hub.", (r.items, nil))
    }

    static func unityUPM(_ ctx: ScanContext) -> Category? {
        let p = ctx.roots.h("Library/Caches/Unity/upm")
        guard ScanEngine.lstatInfo(p) != nil else { return nil }
        let m = ScanEngine.measure(p, links: ctx.links, cancel: ctx.cancel)
        let item = CleanItem(path: p, name: "Unity/upm", size: m.size, newest: m.newest, risk: .info, method: .none,
                             reason: "Unity's package cache manages its own size.", scope: .none, fileID: m.fileID)
        return Category(id: "J-UNITY-UPM", title: "Unity package cache", group: .developer, method: .none,
                        explanation: "Shown for information.", items: [item])
    }

    static func devCacheFolders(_ ctx: ScanContext) -> Category? {
        let root = ctx.roots.h("Library/Caches")
        let r = children(ctx, root, needsWrite: false, want: { n, _ in devCacheDirs.contains(n) }) { n, p, m, _ in
            return CleanItem(path: p, name: n, size: m.size, newest: m.newest, risk: .info, method: .none,
                             reason: "Cleaned only with the tool's own command (see its row, when the tool is installed).",
                             scope: .none, fileID: m.fileID)
        }
        guard let r, !r.items.isEmpty else { return nil }
        return appCategory("J-DEVCACHE-DIRS", "Tool cache folders", .developer,
                           "Shown so they are never treated as app caches.", (r.items, nil), method: .none)
    }

    // MARK: Developer tool commands (S3)

    struct ToolRule {
        let id: String, title: String, risk: Risk, tool: String
        let commands: [[String]]
        var preview: [String]? = nil
        let cacheDirs: [String]          // relative to home; the first that exists is measured
        let explanation: String
    }

    static let toolRules: [ToolRule] = [
        ToolRule(id: "J-NUGET-HTTP", title: "NuGet download cache", risk: .safe, tool: "dotnet",
                 commands: [["nuget", "locals", "http-cache", "--clear"]],
                 cacheDirs: [".local/share/NuGet/http-cache", ".local/share/NuGet/v3-cache"],
                 explanation: "Downloaded package files. NuGet downloads them again when needed."),
        ToolRule(id: "J-NUGET-PKG", title: "NuGet packages", risk: .review, tool: "dotnet",
                 commands: [["nuget", "locals", "global-packages", "--clear"]],
                 cacheDirs: [".nuget/packages"],
                 explanation: "Every project downloads its packages again on next build. Fails if an IDE has projects open."),
        ToolRule(id: "J-NPM", title: "npm cache", risk: .review, tool: "npm",
                 commands: [["cache", "clean", "--force"]], cacheDirs: [".npm/_cacache"],
                 explanation: "Downloaded npm packages. Installs get slower until it fills again."),
        ToolRule(id: "J-PNPM", title: "pnpm store", risk: .safe, tool: "pnpm",
                 commands: [["store", "prune"]], cacheDirs: ["Library/pnpm/store"],
                 explanation: "Removes packages no project uses any more."),
        ToolRule(id: "J-YARN", title: "Yarn cache", risk: .review, tool: "yarn",
                 commands: [["cache", "clean"]], cacheDirs: ["Library/Caches/Yarn", "Library/Caches/yarn"],
                 explanation: "Downloaded Yarn packages. Installs get slower until it fills again."),
        ToolRule(id: "J-PIP", title: "pip cache", risk: .review, tool: "python3",
                 commands: [["-m", "pip", "cache", "purge"]], cacheDirs: ["Library/Caches/pip"],
                 explanation: "Downloaded Python packages and built wheels."),
        ToolRule(id: "J-BREW", title: "Homebrew cleanup", risk: .review, tool: "brew",
                 commands: [["cleanup", "--prune=all"]], preview: ["cleanup", "-n", "--prune=all"],
                 cacheDirs: ["Library/Caches/Homebrew"],
                 explanation: "Removes old installed versions of formulae and casks, as well as downloads."),
        ToolRule(id: "J-DOCKER", title: "Docker build cache", risk: .review, tool: "docker",
                 commands: [["builder", "prune", "-f"], ["image", "prune", "-f"]], cacheDirs: [],
                 explanation: "Unused build cache and dangling images. Volumes are never touched."),
    ]

    static func toolCategory(_ t: ToolRule, _ ctx: ScanContext) -> Category? {
        guard let exe = ctx.tools.find(t.tool) else { return nil }
        let path = "tool://" + t.id         // unique ID; the folder it shrinks is measurePath
        var measurePath: String? = nil
        var m = Measure()
        var sizeUnknown = false
        if t.id == "J-DOCKER" {
            // Needs a running Docker; there is no folder to measure.
            guard ToolRunner.run(exe, ["info"], timeout: 8).status == 0 else { return nil }
            sizeUnknown = true
        } else {
            guard let dir = t.cacheDirs.map({ ctx.roots.h($0) }).first(where: { ScanEngine.lstatInfo($0) != nil })
            else { return nil }
            measurePath = dir
            m = ScanEngine.measure(dir, links: ctx.links, cancel: ctx.cancel)
        }
        var item = CleanItem(path: path, name: t.title, size: m.size, newest: m.newest, risk: t.risk, method: .tool,
                             reason: t.explanation, scope: .none, fileID: m.fileID)
        item.sizeUnknown = sizeUnknown
        item.measurePath = measurePath
        var cmd = ToolCommand(tool: t.tool, commands: t.commands, preview: t.preview)
        cmd.executable = exe
        return Category(id: t.id, title: t.title, group: .developer, method: .tool, explanation: t.explanation,
                        items: [item], tool: cmd)
    }

    static func simulators(_ ctx: ScanContext) -> Category? {
        guard let exe = ctx.tools.find("xcrun") else { return nil }
        let list = ToolRunner.run(exe, ["simctl", "list", "devices"], timeout: 30)
        guard list.status == 0 else { return nil }
        let lines = list.output.split(separator: "\n")
        let unavailable = lines.filter { $0.contains("(unavailable") }.count
        guard unavailable > 0 else { return nil }
        let booted = lines.contains { $0.contains("(Booted)") }
        var item = CleanItem(path: "tool://J-XC-SIM", name: "Unavailable simulators", size: 0, newest: nil,
                             risk: .review, method: .tool,
                             reason: "\(unavailable) simulator\(unavailable == 1 ? "" : "s") for runtimes no longer installed. Deletes those simulators' data too.",
                             scope: .none, fileID: [], owners: [xcode])
        item.sizeUnknown = true
        item.runningOwner = blockedBy([xcode], ctx) ?? (booted ? "A booted simulator" : nil)
        var cmd = ToolCommand(tool: "xcrun", commands: [["simctl", "delete", "unavailable"]], preview: nil)
        cmd.executable = exe
        return Category(id: "J-XC-SIM", title: "Unavailable simulators", group: .developer, method: .tool,
                        explanation: "Simulators whose iOS version is no longer installed.", items: [item], tool: cmd)
    }
}

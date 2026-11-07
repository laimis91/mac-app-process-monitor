// Pure-logic checks for the disk cleaner (spec 13). Built and run by scripts/selftest.sh.

import Foundation

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { passes += 1 } else { failures += 1; print("FAIL line \(line): \(what)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    check(a == b, "\(what): got \(a), expected \(b)", line: line)
}

@main enum SelfTest {
    static func main() {
        keys()
        protection()
        claims()
        versions()
        settings()
        selection()
        pathGuard()
        sizes()
        batchRetry()
        print("selftest: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func keys() {
        eq(CandidateKey.parse("com.vendor.app.plist"), CandidateKey(key: "com.vendor.app", kind: .bundleID, wrapped: false), "plist")
        eq(CandidateKey.parse("com.vendor.app.savedState").key, "com.vendor.app", "savedState")
        eq(CandidateKey.parse("com.vendor.App.binarycookies").key, "com.vendor.App", "binarycookies")
        eq(CandidateKey.parse("group.com.vendor.app"), CandidateKey(key: "com.vendor.app", kind: .bundleID, wrapped: true), "group.")
        eq(CandidateKey.parse("ABCDE12345.com.vendor.app"), CandidateKey(key: "com.vendor.app", kind: .bundleID, wrapped: true), "team ID")
        eq(CandidateKey.parse("abcde12345.com.vendor.app").wrapped, false, "lower-case team ID is not a team ID")
        eq(CandidateKey.parse("de.vendor.app").kind, .bundleID, "country TLD")
        eq(CandidateKey.parse("uk.co.vendor").kind, .bundleID, "2-letter TLD")
        eq(CandidateKey.parse("io.github.someone.tool").kind, .bundleID, "io")
        eq(CandidateKey.parse("Spotify").kind, .name, "plain name")
        eq(CandidateKey.parse("com.vendor").kind, .name, "only one dot")
        eq(CandidateKey.parse("Visual Studio Code").kind, .name, "spaces")
        eq(CandidateKey.parse("zz9.vendor.app").kind, .name, "not a TLD")
        eq(CandidateKey.parse("com..app").kind, .name, "empty component")
        eq(CandidateKey.parse("node-gyp").kind, .name, "hyphen name")

        eq(BundleIDs.base("com.vendor.app.helper"), "com.vendor.app", "base helper")
        eq(BundleIDs.base("com.vendor.app.FinderSync"), "com.vendor.app", "base findersync, case")
        eq(BundleIDs.base("com.vendor.helper"), "com.vendor.helper", "base keeps 3 components")
        eq(BundleIDs.base("com.vendor.app.pro"), "com.vendor.app.pro", "base unknown suffix")
        check(BundleIDs.belongs("com.vendor.app.FinderSync", to: "COM.vendor.app"), "dot-prefix, case")
        check(BundleIDs.belongs("com.vendor.app", to: "com.vendor.app"), "equal")
        check(!BundleIDs.belongs("com.vendor.application", to: "com.vendor.app"), "no plain prefix")
        check(!BundleIDs.belongs("com.vendor.app", to: ""), "empty owner")
        check(BundleIDs.related("com.vendor.app", "com.vendor.app.helper"), "related both ways")
        eq(BundleIDs.vendor("com.Vendor.app.x"), "com.vendor", "vendor prefix")
    }

    static func protection() {
        for k in ["com.apple.Safari", "com.Apple.x", "something.apple.y", "com.google.Chrome", "Google", "CloudKit",
                  "JetBrains", "com.jetbrains.rider", "com.docker.docker", "org.mozilla.firefox", "1Password",
                  "com.1password.1password", "com.agilebits.onepassword7", "Homebrew", "node", "org.cups.printers",
                  "com.microsoft.VSCode", "pip"] {
            check(Protection.isProtected(k), "protected: \(k)")
        }
        for k in ["com.vendor.app", "Spotify", "com.spotify.client", "io.github.someone.tool", "nodejs-tool", "Codex"] {
            check(!Protection.isProtected(k), "not protected: \(k)")
        }
        check(Protection.isProtected("com.vendor.app", ignore: ["com.vendor.app"]), "ignore list")
        check(Protection.isProtected("com.vendor.code"), "whole component match")
    }

    static func claims() {
        for n in ["Homebrew", "homebrew", "pip", "Yarn", "yarn", "pnpm", "JetBrains", "Unity", "unity",
                  "com.unity3d.UnityEditor5.x", "com.unity3d.unityhub"] {
            check(Rules.cacheChildClaimed(n), "claimed: \(n)")
        }
        for n in ["com.vendor.app", "Unityx", "UnityHub", "node-gyp-x", "Google"] {
            check(!Rules.cacheChildClaimed(n), "not claimed: \(n)")
        }
        // every rule ID is in the display order exactly once
        let ids = Rules.builders.map(\.0)
        eq(Set(ids), Set(Rules.order), "rule order covers every rule")
        eq(ids.count, Set(ids).count, "no duplicate rule")
    }

    static func versions() {
        eq(Versions.deviceSupport("17.0 (21A329)"), [17, 0], "plain")
        eq(Versions.deviceSupport("iPhone15,2 17.0 (21A331)"), [17, 0], "with model")
        eq(Versions.deviceSupport("16.4.1"), [16, 4, 1], "three parts")
        eq(Versions.deviceSupport("weird"), nil, "unparsable")
        eq(Versions.deviceSupport("17.x"), nil, "letters")
        check(Versions.less([9, 9], [10]), "numeric compare, not text")
        let names = ["16.4 (20E247)", "17.0 (21A329)", "iPhone15,2 17.0 (21A331)", "17.2 (21C62)", "15.0", "weird", "9.3"]
        eq(Set(Versions.oldDeviceSupport(names)), ["16.4 (20E247)", "15.0", "9.3"], "keeps 2 newest versions across models")
        eq(Versions.oldDeviceSupport(["17.0", "17"]), [], "17 and 17.0 are one version")
        eq(Versions.oldDeviceSupport(["weird", "odd"]), [], "unparsable kept")
    }

    static func settings() {
        let d = AgeLimits()
        eq(d, AgeLimits(logs: 7, temp: 3, leftovers: 30, lowConfidence: 90, mail: 30), "defaults")
        check(d.validate(.temp, 2) != nil, "temp below 3 refused")
        check(d.validate(.temp, 3) == nil, "temp 3 ok")
        check(d.validate(.temp, 91) != nil, "temp above 90 refused")
        check(d.validate(.logs, 0) != nil && d.validate(.logs, 1) == nil && d.validate(.logs, 366) != nil, "logs range")
        check(d.validate(.mail, 6) != nil && d.validate(.mail, 7) == nil, "mail range")
        eq(d.validate(.leftovers, 100), "Raise the Possible-leftovers limit first", "leftovers above low-confidence")
        check(d.validate(.leftovers, 13) != nil && d.validate(.leftovers, 90) == nil, "leftovers range")
        check(d.validate(.lowConfidence, 29) != nil, "low-confidence below leftovers refused")
        check(d.validate(.lowConfidence, 30) == nil && d.validate(.lowConfidence, 731) != nil, "low-confidence range")
        let s = AgeLimits.sanitized([.temp: 1, .leftovers: 200, .logs: 400, .mail: 10])
        eq(s, AgeLimits(logs: 7, temp: 3, leftovers: 200, lowConfidence: 200, mail: 10), "sanitized")
        eq(AgeLimits.sanitized([.lowConfidence: 20]).lowConfidence, 90, "low-confidence below leftovers reset")
        eq(AgeLimits.sanitized([:]), d, "empty store")
    }

    static func item(_ risk: Risk, _ method: Method, running: String? = nil, note: String? = nil) -> CleanItem {
        var i = CleanItem(path: "/x", name: "x", size: 1, newest: nil, risk: risk, method: method, reason: "",
                          allowRoot: "/", fileID: [])
        i.runningOwner = running; i.note = note
        return i
    }

    static func selection() {
        check(item(.safe, .trash).preselected, "safe trash pre-selected")
        check(!item(.safe, .tool).preselected, "tool never pre-selected")
        check(!item(.review, .trash).preselected, "review not pre-selected")
        check(!item(.review, .tool).preselected, "review tool not pre-selected")
        check(!item(.info, .none).selectable, "info not selectable")
        check(!item(.safe, .trash, running: "Xcode").preselected, "running owner not pre-selected")
        check(!item(.safe, .trash, note: "Needs Full Disk Access").selectable, "notice rows not selectable")
    }

    static func pathGuard() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-\(getpid())"
        try? fm.removeItem(atPath: root)
        defer { try? fm.removeItem(atPath: root) }
        guard let r = Roots.fixture(root + "/") ?? { try? fm.createDirectory(atPath: root, withIntermediateDirectories: true); return Roots.fixture(root) }()
        else { check(false, "fixture roots"); return }
        for d in ["Library/Caches/com.vendor.app", "Library/Caches/Deep/inner", "Documents/secret", "Library/Logs",
                  ".ssh", "Library/Caches/com.vendor.other"] {
            try? fm.createDirectory(atPath: r.h(d), withIntermediateDirectories: true)
        }
        try? fm.createDirectory(atPath: r.temp + "/old", withIntermediateDirectories: true)
        let caches = r.h("Library/Caches")
        let g = PathGuard(roots: r)
        eq(g.check(r.h("Library/Caches/com.vendor.app"), allowRoot: caches), nil, "child of Caches allowed")
        eq(g.check(r.h("Library/caches/COM.vendor.app"), allowRoot: caches), nil, "case-insensitive")
        eq(g.check(r.h("Library/Caches/Deep/inner"), allowRoot: caches), nil, "deeper inside allowed")
        check(g.check(caches, allowRoot: caches) != nil, "the allow root itself is denied")
        check(g.check(r.h("Library"), allowRoot: r.h("Library")) != nil, "~/Library denied")
        check(g.check(r.home, allowRoot: r.home) != nil, "home root denied")
        check(g.check(r.h("Documents/secret"), allowRoot: caches) != nil, "outside its rule's root")
        check(g.check(r.h("Documents/secret"), allowRoot: r.h("Documents")) != nil, "Documents not an allow root")
        check(g.check(r.h("Library/Caches/../../Documents/secret"), allowRoot: caches) != nil, "dot-dot refused")
        check(g.check(r.h("Library/Caches/missing"), allowRoot: caches) != nil, "missing item")
        check(g.check(r.h(".ssh"), allowRoot: r.home) != nil, ".ssh denied")
        eq(g.check(r.temp + "/old", allowRoot: r.temp), nil, "temp child allowed")
        check(g.check(r.h("Library/Logs/x"), allowRoot: caches) != nil, "wrong root and missing")

        // a symlinked parent is dropped; a symlinked item is judged where it sits
        try? fm.createSymbolicLink(atPath: r.h("Library/Caches/link"), withDestinationPath: r.h("Documents"))
        check(g.check(r.h("Library/Caches/link/secret"), allowRoot: caches) != nil, "symlinked parent dropped")
        eq(g.check(r.h("Library/Caches/link"), allowRoot: caches), nil, "symlink item judged where it sits")
        try? fm.createSymbolicLink(atPath: r.h("Library/Caches/inside"), withDestinationPath: r.h("Library/Caches/com.vendor.other"))
        try? fm.createDirectory(atPath: r.h("Library/Caches/com.vendor.other/x"), withIntermediateDirectories: true)
        check(g.check(r.h("Library/Caches/inside/x"), allowRoot: caches) != nil, "symlink inside the root still dropped")

        // component-wise, not string prefix
        check(!PathGuard.within(PathGuard.comps("/Users/bobby/x"), PathGuard.comps("/Users/bob")), "bob is not bobby")
        check(PathGuard.within(PathGuard.comps("/Users/BOB/x"), PathGuard.comps("/users/bob")), "case-insensitive within")

        // real roots: system locations and other users are denied whatever the allow root
        let real = PathGuard(roots: Roots.real())
        let t = Roots.userTempDir()
        check(t.hasPrefix("/private/var/folders/"), "temp folder keeps /private: \(t)")
        check(real.check("/private/var/db/dyld", allowRoot: t) != nil, "/private/var denied outside temp")
        check(real.check("/usr/bin/true", allowRoot: t) != nil, "/usr denied")
        check(real.check("/System/Library", allowRoot: t) != nil, "/System denied")
        check(real.check("/Users/Shared", allowRoot: t) != nil, "other users' folders denied")
        check(real.check(Roots.real().h("Library/Keychains/login.keychain-db"), allowRoot: Roots.real().h("Library/Caches")) != nil, "keychains denied")
        check(Roots.fixture("/tmp/elsewhere") == nil && Roots.fixture("/Users/x") == nil, "unsafe fixture roots refused")
    }

    /// Cleaner.clean with a stand-in mover: an item-level failure is retried one by one, a
    /// whole-request failure (Finder hung or cancelled) is not.
    static func batchRetry() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-batch-\(getpid())"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        guard let r = Roots.fixture(root) else { check(false, "batch fixture"); return }
        let caches = r.h("Library/Caches")
        var pairs: [(Category, CleanItem)] = []
        for n in ["com.a.one", "com.a.two", "com.a.three"] {
            try? fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
            fm.createFile(atPath: caches + "/" + n, contents: Data([1]), attributes: nil)
            let p = caches + "/" + n
            let item = CleanItem(path: p, name: n, size: 1, newest: nil, risk: .safe, method: .trash, reason: "",
                                 allowRoot: caches, fileID: ScanEngine.fileID(p) ?? [])
            let cat = Category(id: "J-CACHE", title: "", group: .general, method: .trash, explanation: "", items: [item])
            pairs.append((cat, item))
        }
        let inv = AppInventory(roots: r, lookup: nil, running: { [] })
        func env(_ mover: @escaping ([String]) -> [String: TrashResult], batch: Int = 100) -> CleanEnvironment {
            CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] }, inventory: inv, roots: r,
                             dryRun: false, now: Date.init, prepareTrash: { mover }, batchSize: batch)
        }
        // item-level failure: the batch fails, each item is retried alone; "two" keeps failing
        var calls: [[String]] = []
        let out1 = Cleaner.clean(pairs, env: env({ paths in
            calls.append(paths)
            if paths.count > 1 { return Dictionary(uniqueKeysWithValues: paths.map { ($0, TrashResult.failed("busy")) }) }
            return [paths[0]: paths[0].hasSuffix("two") ? .failed("locked") : .moved(putBack: true)]
        }))
        eq(calls.count, 4, "one batch call, then one retry per item")
        eq(out1.filter { $0.status == .moved }.count, 2, "retried items moved")
        eq(out1.first { $0.name == "com.a.two" }?.reason, "locked", "per-item failure kept")
        // whole-request failure: no retries
        calls = []
        let out2 = Cleaner.clean(pairs, env: env({ paths in
            calls.append(paths)
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, TrashResult.failedAll("Finder didn't answer in time")) })
        }))
        eq(calls.count, 1, "no per-item retry after a whole-request failure")
        check(out2.allSatisfy { $0.status == .failed }, "all reported failed")
        // a whole-request failure during the one-by-one retries stops the remaining retries
        calls = []
        let out4 = Cleaner.clean(pairs, env: env({ paths in
            calls.append(paths)
            if paths.count > 1 { return Dictionary(uniqueKeysWithValues: paths.map { ($0, TrashResult.failed("busy")) }) }
            return [paths[0]: .failedAll("Cancelled in Finder")]
        }))
        eq(calls.count, 2, "retries stop after a whole-request failure")
        eq(out4.filter { $0.reason == "Cancelled in Finder" }.count, 3, "the rest share that reason")
        // ...and stops later batches
        calls = []
        let out5 = Cleaner.clean(pairs, env: env({ paths in
            calls.append(paths)
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, TrashResult.failedAll("Finder didn't answer in time")) })
        }, batch: 1))
        eq(calls.count, 1, "no further batches after a whole-request failure")
        eq(out5.count, 3, "every item reported")
        // dry run never calls the mover
        calls = []
        var dry = env({ p in calls.append(p); return [:] })
        dry = CleanEnvironment(guardian: dry.guardian, runningNow: dry.runningNow, inventory: inv, roots: r,
                               dryRun: true, now: Date.init, prepareTrash: { { p in calls.append(p); return [:] } })
        let out3 = Cleaner.clean(pairs, env: dry)
        check(calls.isEmpty && out3.allSatisfy { $0.status == .planned }, "dry run plans only")
    }

    static func sizes() {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "appmon-selftest-\(getpid())"
        try? fm.createDirectory(atPath: dir + "/a", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: dir + "/b", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let data = Data(repeating: 7, count: 300_000)
        fm.createFile(atPath: dir + "/a/f", contents: data)
        try? fm.linkItem(atPath: dir + "/a/f", toPath: dir + "/b/f")
        try? fm.createSymbolicLink(atPath: dir + "/b/link", withDestinationPath: "/usr")
        let links = LinkSet()
        let a = ScanEngine.measure(dir + "/a", links: links)
        let b = ScanEngine.measure(dir + "/b", links: links)
        check(a.size >= 300_000 && a.size < 400_000, "allocated size of 300 KB file: \(a.size)")
        check(b.size < 20_000, "hard link counted once, symlink not followed: \(b.size)")
        check(a.complete && a.newest != nil && a.entries == 2, "entries and age")
        eq(ScanEngine.fileID(dir + "/a/f"), ScanEngine.fileID(dir + "/b/f"), "hard links share file ID")
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: dir + "/a/f")
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: dir + "/a")
        eq(days(since: ScanEngine.newest(dir + "/a"), now: Date()), 40, "newest date inside")
    }
}

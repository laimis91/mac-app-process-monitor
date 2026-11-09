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
        spaceRules()
        spaceMap()
        leftoverScreen()
        leftoverDecide()
        leftoverScan()
        uninstallRules()
        uninstallScan()
        openFiles()
        guardScopes()
        embeddedOwner()
        trashLookup()
        toolLookup()
        toolEnvironment()
        toolRunner()
        groupProtection()
        swappedFolder()
        print("selftest: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// Tool lookup (spec 6.5), with stub executables in a scratch folder: each tool only in its
    /// own folders, and nothing run whose path others can change or that links elsewhere.
    static func toolLookup() {
        let fm = FileManager.default
        let root = Roots.canonical(NSTemporaryDirectory()) + "/appmon-selftest-tools-\(getpid())"
        defer { _ = chmod(root + "/groupw", 0o755); try? fm.removeItem(atPath: root) }
        func stub(_ path: String, mode: mode_t = 0o755) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            _ = chmod(path, mode)
        }
        func dir(_ path: String, mode: mode_t = 0o755) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            _ = chmod(path, mode)
        }
        dir(root, mode: 0o755)
        let dotnet = ToolPlace(folder: root + "/dotnet", targets: [root + "/dotnet"])
        let brew = ToolPlace(folder: root + "/brew/bin", targets: [root + "/brew"])
        stub(root + "/dotnet/dotnet")
        stub(root + "/dotnet/xcrun")                             // planted where only dotnet belongs
        dir(root + "/brew/bin")
        stub(root + "/brew/Cellar/npm/npm")
        try? fm.createSymbolicLink(atPath: root + "/brew/bin/npm", withDestinationPath: "../Cellar/npm/npm")
        stub(root + "/elsewhere/yarn")
        try? fm.createSymbolicLink(atPath: root + "/brew/bin/yarn", withDestinationPath: root + "/elsewhere/yarn")
        stub(root + "/brew/bin/pnpm", mode: 0o775)               // group-writable file
        stub(root + "/brew/bin/brew", mode: 0o757)               // world-writable file
        let loc = ToolLocator(places: ["dotnet": [dotnet], "npm": [brew], "yarn": [brew], "pnpm": [brew], "brew": [brew],
                                       "xcrun": [ToolPlace(folder: "/usr/bin", targets: [])]], xcodeSelectOK: true)
        eq(loc.find("dotnet"), root + "/dotnet/dotnet", "tool in its own folder")
        eq(loc.find("xcrun"), "/usr/bin/xcrun", "xcrun only from /usr/bin, never a planted copy in another tool's folder")
        eq(ToolLocator(places: loc.places, xcodeSelectOK: false).find("xcrun"), nil, "/usr/bin stub without the CLT")
        eq(loc.find("python3"), nil, "a tool without places is never found")
        eq(loc.find("npm"), root + "/brew/bin/npm", "symlink into its own prefix")
        eq(loc.find("yarn"), nil, "symlink outside its prefix refused")
        eq(loc.find("pnpm"), nil, "group-writable executable refused")
        eq(loc.find("brew"), nil, "world-writable executable refused")
        // A group-writable folder on the way (not the admin group) refuses everything below it.
        dir(root + "/groupw/bin")
        stub(root + "/groupw/bin/dotnet")
        _ = chown(root + "/groupw", getuid(), 20)                // staff: every user is in it
        _ = chmod(root + "/groupw", 0o775)
        let gw = ToolPlace(folder: root + "/groupw/bin", targets: [root + "/groupw/bin"])
        check(ToolTrust.refusal(root + "/groupw/bin/dotnet", place: gw)?.contains("writable by its group") == true,
              "group-writable folder on the path refused")
        // ...but the admin group may write (Homebrew's folders, /Applications).
        if chown(root + "/groupw", getuid(), ToolTrust.adminGroup) == 0 {
            eq(ToolTrust.refusal(root + "/groupw/bin/dotnet", place: gw), nil, "admin-group-writable folder accepted")
        } else { print("     (skipped: can't give a folder to the admin group here)") }
        _ = chmod(root + "/groupw", 0o755)
        // A folder reached through a symlink, and the first place refused: the next place is used.
        try? fm.createSymbolicLink(atPath: root + "/linked", withDestinationPath: root + "/dotnet")
        let linked = ToolPlace(folder: root + "/linked", targets: [root + "/linked"])
        check(ToolTrust.refusal(root + "/linked/dotnet", place: linked) != nil, "folder through a symlink refused")
        let two = ToolLocator(places: ["dotnet": [linked, dotnet]], xcodeSelectOK: true)
        eq(two.find("dotnet"), root + "/dotnet/dotnet", "a refused place falls through to the next")
        // Another owner (root-owned files are fine: /usr/bin passes above).
        var st = stat(); st.st_uid = getuid() + 1; st.st_mode = S_IFREG | 0o755
        eq(ToolTrust.entryRefusal(st, uid: getuid()), "owned by another user", "another user's file refused")
        st.st_uid = 0; st.st_mode = S_IFDIR | 0o1777
        eq(ToolTrust.entryRefusal(st, uid: getuid()), nil, "root-owned sticky folder (/private/tmp) accepted")
        st.st_uid = getuid(); st.st_mode = S_IFDIR | 0o1777
        check(ToolTrust.entryRefusal(st, uid: getuid()) != nil, "a sticky folder not owned by root refused")
        // The real places: each tool only in its own folders.
        let real = ToolLocator.realPlaces(home: "/Users/x")
        eq(real["xcrun"]?.map(\.folder), ["/usr/bin"], "xcrun: /usr/bin only")
        eq(real["python3"]?.map(\.folder), ["/usr/bin"], "python3: /usr/bin only")
        eq(real["dotnet"]?.map(\.folder), ["/usr/local/share/dotnet", "/Users/x/.dotnet"], "dotnet folders")
        for t in ["brew", "npm", "yarn", "pnpm", "docker"] {
            eq(real[t]?.map(\.folder), ["/opt/homebrew/bin", "/usr/local/bin"], "\(t): Homebrew folders only")
        }
    }

    /// The tool environment (S4 review): a fixed allow-list, nothing else of App Monitor's.
    static func toolEnvironment() {
        let inherited = ["NODE_OPTIONS": "--require /tmp/x.js", "BASH_ENV": "/tmp/x", "PYTHONPATH": "/tmp",
                         "DOTNET_STARTUP_HOOKS": "/tmp/x.dll", "DEVELOPER_DIR": "/tmp/xc", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
                         "HOME": "/tmp/fakehome", "PATH": "/tmp/bin:/usr/bin", "TMPDIR": "/tmp/evil/", "USER": "mallory",
                         "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "LC_ALL": "../../tmp/x", "LC_MESSAGES": ""]
        let env = ToolEnvironment.make(for: "/opt/homebrew/bin/npm", inherited: inherited, home: "/Users/u", user: "u",
                                       tmp: "/private/var/folders/xy/T")
        eq(env, ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "NO_COLOR": "1", "HOME": "/Users/u", "USER": "u", "LOGNAME": "u",
                 "TMPDIR": "/private/var/folders/xy/T/", "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8"],
           "only the allow-list, with the user's real values; locale values with a path are dropped")
        check(ToolEnvironment.realHome().hasPrefix("/"), "home from the user database")
        check(!ToolEnvironment.realUser().isEmpty, "user name from the user database")
        // End to end: a variable set in this process doesn't reach the child.
        setenv("NODE_OPTIONS", "--require /tmp/x.js", 1)
        setenv("DOTNET_STARTUP_HOOKS", "/tmp/x.dll", 1)
        let r = ToolRunner.run("/usr/bin/env", [], timeout: 10)
        unsetenv("NODE_OPTIONS"); unsetenv("DOTNET_STARTUP_HOOKS")
        let keys = Set(r.output.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        let allowed: Set<String> = ["PATH", "NO_COLOR", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]
        check(r.status == 0 && !keys.isEmpty, "env ran")
        check(keys.allSatisfy { allowed.contains($0) || $0.hasPrefix("LC_") }, "child sees only the allow-list: \(keys.sorted())")
        check(r.output.contains("HOME=" + ToolEnvironment.realHome() + "\n"), "child's HOME is the real home")
    }

    /// The runner (spec 6.5): exit codes, the timeout, no inherited descriptors, and children
    /// that are responsible for themselves (so they don't get App Monitor's Full Disk Access).
    static func toolRunner() {
        eq(ToolRunner.run("/bin/sh", ["-c", "echo hi; exit 3"], timeout: 10).status, 3, "exit code")
        eq(ToolRunner.run("/bin/sh", ["-c", "echo hi"], timeout: 10).output, "hi\n", "output")
        let slow = ToolRunner.run("/bin/sleep", ["5"], timeout: 0.5)
        check(slow.timedOut && slow.status == -2, "timeout stops the tool")
        eq(ToolRunner.run("/nonexistent/tool", []).status, -1, "missing executable")
        // A descriptor of this process (not close-on-exec) isn't open in the child.
        let fd = open("/dev/null", O_RDONLY)
        // A timeout stops the tool's helpers too: the background sleep must not survive the run.
        let marker = NSTemporaryDirectory() + "appmon-pg-\(getpid())"
        _ = ToolRunner.run("/bin/sh", ["-c", "(sleep 3; touch \(marker)) & sleep 30"], timeout: 0.5)
        Thread.sleep(forTimeInterval: 3.5)
        check(!FileManager.default.fileExists(atPath: marker), "timeout stops the tool's whole process group")
        try? FileManager.default.removeItem(atPath: marker)
        let fds = ToolRunner.run("/bin/sh", ["-c", "[ -e /dev/fd/\(fd) ] && echo open || echo closed"], timeout: 10)
        close(fd)
        eq(fds.output, "closed\n", "only stdin, stdout and stderr reach the child")
        check(Responsibility.available, "responsibility_spawnattrs_setdisclaim is available")
        var child: pid_t = 0
        var responsible: pid_t? = nil
        _ = ToolRunner.run("/bin/sleep", ["1"], timeout: 10, started: { pid in
            child = pid; responsible = Responsibility.responsible(for: pid)
        })
        if let responsible { eq(responsible, child, "the child is responsible for itself") }
        else { print("     (skipped: responsibility can't be asked here)") }
        // With Full Disk Access in this process (a terminal that has it), the child must not have it.
        // GitHub's macOS runners don't enforce privacy protection (TCC): every process there can list
        // ~/Library/Safari, disclaimed or not, so the check means nothing there. The responsibility
        // check above still runs.
        let safari = ToolEnvironment.realHome() + "/Library/Safari"
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
            print("     (skipped: CI runners don't enforce Full Disk Access)")
        } else if (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil {
            let r = ToolRunner.run("/bin/ls", [safari], timeout: 10)
            check(r.status != 0, "a child can't list ~/Library/Safari although this process can")
        } else { print("     (skipped: this process has no Full Disk Access, so the FDA check can't run)") }
    }

    /// S6 review: a group container with a protected name is Info, and an embedded ID that
    /// LaunchServices knows from another path belongs to that app.
    static func groupProtection() {
        let app = AppInfo(id: "com.evil.app", name: "Evil", path: "/Applications/Evil.app")
        let t = UninstallTarget(app: app, ids: ["com.evil.app"], groups: ["group.com.apple.notes", "group.com.evil.app"])
        let place = LeftoverPlace.named("groupContainers")
        func m(_ n: String) -> Uninstaller.Match? {
            Uninstaller.match(n, at: "/x/" + n, in: place, app: app, target: t, named: [], own: { _ in nil }, claimers: { _ in [] })
        }
        eq(m("group.com.apple.notes")?.kept, Uninstaller.protectedGroup, "claimed Apple group: not moved")
        eq(m("group.com.evil.app")?.kept, nil, "its own group: may be moved")
        // Embedded IDs: one LaunchServices knows at another path is that app's.
        let ids = ["com.evil.app", "com.real.tool"]
        let ls: (String) -> AppInfo? = { id in
            switch id {
            case "com.real.tool": return AppInfo(id: id, name: "Real Tool", path: "/Users/x/Downloads/Real Tool.app")
            case "com.evil.app": return AppInfo(id: id, name: "Evil copy", path: "/Users/x/Downloads/Evil.app")
            default: return nil
            }
        }
        eq(Uninstaller.owner(of: "com.real.tool", target: ids, others: [], lookup: ls, targetPath: app.path),
           .other("Real Tool"), "embedded ID equal to an app elsewhere: that app wins")
        eq(Uninstaller.owner(of: "com.real.tool.cache", target: ids, others: [], lookup: ls, targetPath: app.path),
           .other("Real Tool"), "...and its sub-IDs")
        eq(Uninstaller.owner(of: "com.evil.app", target: ids, others: [], lookup: ls, targetPath: app.path),
           .target, "the app's own ID: another copy doesn't take its data")
        let inside: (String) -> AppInfo? = { id in AppInfo(id: id, name: "Helper", path: app.path + "/Contents/Library/LoginItems/H.app") }
        eq(Uninstaller.owner(of: "com.real.tool", target: ids, others: [], lookup: inside, targetPath: app.path),
           .target, "an embedded ID LaunchServices knows inside the app stays the app's")
    }

    /// S5 review: a folder above an item swapped for a symlink after the last checks. The
    /// FileManager mover opens the folder without following symlinks and checks the item, so
    /// neither the decoy behind the link nor anything else is moved.
    static func swappedFolder() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-swap-\(getpid())"
        defer { try? fm.removeItem(atPath: root) }
        let dir = root + "/home/Library/Caches/com.a.app", decoy = root + "/decoy"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: decoy, withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/item", contents: Data("real".utf8))
        fm.createFile(atPath: decoy + "/item", contents: Data("decoy".utf8))
        let id = ScanEngine.fileID(dir + "/item") ?? []
        let swap = TrashItem(path: dir + "/item", fileID: id, recheck: {
            try? fm.moveItem(atPath: dir, toPath: dir + ".moved")
            try? fm.createSymbolicLink(atPath: dir, withDestinationPath: decoy)
            return nil                                       // the checks passed, then the folder was swapped
        })
        let r = Cleaner.trashWithFileManager([swap])
        eq(r[dir + "/item"], .skipped("Changed since the scan"), "swapped folder: not moved")
        check(fm.fileExists(atPath: decoy + "/item") && fm.fileExists(atPath: dir + ".moved/item"), "decoy and real item both stay")
        // A recheck that fails leaves the item out; so does a changed identity.
        eq(Cleaner.trashWithFileManager([TrashItem(path: decoy + "/item", fileID: id, recheck: { "Changed since the scan" })])[decoy + "/item"],
           .skipped("Changed since the scan"), "failed recheck: not handed over")
        eq(Cleaner.trashWithFileManager([TrashItem(path: decoy + "/item", fileID: id)])[decoy + "/item"],
           .skipped("Changed since the scan"), "another file at the path: not moved")
        check(fm.fileExists(atPath: decoy + "/item"), "decoy still there")
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
                          scope: .rule(root: "/"), fileID: [])
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
        // Spec 5 and 10: Requested is pre-selected; Review only when the uninstaller marks it.
        check(item(.requested, .trash).preselected, "requested pre-selected")
        check(!item(.requested, .trash, running: "X").preselected, "requested, app running: not pre-selected")
        var marked = item(.review, .trash); marked.preselect = true
        check(marked.preselected, "marked review pre-selected")
        var markedTool = item(.review, .tool); markedTool.preselect = true
        check(!markedTool.preselected, "marked review tool not pre-selected")
        var markedInfo = item(.info, .none); markedInfo.preselect = true
        check(!markedInfo.preselected && !markedInfo.selectable, "marked info neither selectable nor pre-selected")
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
                                 scope: .rule(root: caches), fileID: ScanEngine.fileID(p) ?? [])
            let cat = Category(id: "J-CACHE", title: "", group: .general, method: .trash, explanation: "", items: [item])
            pairs.append((cat, item))
        }
        let inv = AppInventory(roots: r, lookup: nil, running: { [] })
        func env(_ mover: @escaping ([String]) -> [String: TrashResult], batch: Int = 100) -> CleanEnvironment {
            CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] }, inventory: inv, roots: r,
                             dryRun: false, now: Date.init, prepareTrash: { { items in mover(items.map(\.path)) } }, batchSize: batch)
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
        // Finder busy before the clean: nothing handed over, every item failed once, no retries
        let busyEnv = CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] }, inventory: inv, roots: r,
                                       dryRun: false, now: Date.init, prepareTrash: { Cleaner.finderBusy }, batchSize: 1)
        let out6 = Cleaner.clean(pairs, env: busyEnv)
        eq(out6.count, 3, "every item reported when Finder is busy")
        check(out6.allSatisfy { $0.status == .failed && $0.reason == Cleaner.finderNotResponding }, "all failed with the busy reason")
        check(pairs.allSatisfy { FileManager.default.fileExists(atPath: $0.1.path) }, "nothing moved when Finder is busy")
        // dry run never calls the mover
        calls = []
        var dry = env({ p in calls.append(p); return [:] })
        dry = CleanEnvironment(guardian: dry.guardian, runningNow: dry.runningNow, inventory: inv, roots: r,
                               dryRun: true, now: Date.init, prepareTrash: { { items in calls.append(items.map(\.path)); return [:] } })
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
        eq(days(since: ScanEngine.measure(dir + "/a", links: nil).newest, now: Date()), 40, "newest date inside")
    }

    // MARK: Space map (spec 8, 6.4)

    static func du(_ path: String) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-skx", path]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (Int64(out.split(separator: "\t").first ?? "") ?? -1) * 1024
    }

    /// The Space-map guard's path rules on their own (no disk access).
    static func spaceRules() {
        func r(_ rel: [String], _ tweak: (inout SpaceGuard.Facts) -> Void = { _ in }) -> String? {
            var f = SpaceGuard.Facts(rel: rel); tweak(&f); return SpaceGuard.rule(f)
        }
        eq(r(["Projects", "site"]), nil, "project folder allowed")
        eq(r(["Downloads", "big.iso"]), nil, "item inside Downloads allowed")
        eq(r(["Documents", "a", "b"]), nil, "item deep inside Documents allowed")
        eq(r(["notes.txt"]), nil, "plain file in home allowed")
        check(r([]) != nil, "home itself denied")
        for std in ["Documents", "desktop", "Downloads", "Pictures", "Movies", "Music"] {
            check(r([std]) != nil, "standard folder itself denied: \(std)")
        }
        check(r(["Library"]) != nil && r(["library", "Caches", "x"]) != nil, "~/Library and everything inside denied")
        check(r([".config"]) != nil && r([".Trash", "x"]) != nil && r([".ssh"]) != nil, "home dot-folders denied")
        check(r(["Projects", "site", ".git"]) != nil, "a repo's .git denied")
        check(r(["Projects", "site", ".git", "objects"]) != nil, "inside .git denied")
        check(r(["Projects", ".hidden", "x"]) != nil, "inside a deeper dot-folder denied")
        check(r(["Pictures", "Photos Library.photoslibrary"]) != nil, "photo library denied")
        check(r(["Pictures", "Old.PhotosLibrary", "x"]) != nil, "inside a photo library denied")
        check(r(["Applications", "Tool.app"]) != nil && r(["Projects", "Tool.APP", "Contents"]) != nil, ".app denied anywhere")
        for sync in ["Dropbox", "Google Drive", "OneDrive", "OneDrive - Acme", "Box", "pCloud Drive", "Dropbox (Personal)"] {
            check(r([sync]) != nil && r([sync, "x"]) != nil, "sync folder denied: \(sync)")
        }
        eq(r(["Boxes"]), nil, "Boxes is not Box")
        eq(r(["Dropboxes"]), nil, "Dropboxes is not Dropbox")
        check(r(["Documents", "x"]) { $0.synced = true } != nil, "iCloud-synced item denied")
        check(r(["Movies", "Edit.fcpbundle", "x"]) { $0.ancestorPackage = true } != nil, "inside a package denied")
        eq(r(["Movies", "Edit.fcpbundle"]), nil, "whole package allowed")
        check(r(["x"]) { $0.ownedByUser = false } != nil, "other owner denied")
        check(r(["x"]) { $0.sameVolume = false } != nil, "other volume denied")
    }

    static func spaceMap() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-space-\(getpid())"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        guard let r = Roots.fixture(root) else { check(false, "space fixture"); return }
        func file(_ rel: String, _ bytes: Int) {
            let p = r.h(rel)
            try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: p, contents: Data(repeating: 1, count: bytes))
        }
        file("Projects/site/src/a", 300_000)
        file("Projects/site/.git/objects/x", 100_000)
        file("Projects/Tool.app/Contents/Info.plist", 1000)
        file("Projects/Thing.bundle/Contents/x", 5000)
        file("Pictures/Lib.photoslibrary/database/x", 20_000)
        file("Library/Caches/c/x", 40_000)
        file("Documents/report.txt", 70_000)
        file("Dropbox/x", 1000)
        file(".config/x", 1000)
        for i in 0..<9 { file("Many/f\(i)", (i + 1) * 10_000) }
        file("Many/small.app/x", 100)              // the smallest entry: folded into "smaller items"
        try? fm.linkItem(atPath: r.h("Projects/site/src/a"), toPath: r.h("Projects/copy"))
        try? fm.createSymbolicLink(atPath: r.h("Projects/link"), withDestinationPath: "/usr")

        // The scan: the home folder as a top, with ~/Library scanned folder by folder.
        var opts = SpaceOptions()
        opts.home = r.home
        opts.listMin = 0
        let top = SpaceScanner.shell(r.home, title: "Home")
        top.base = r.home
        let map = SpaceNode.root()
        map.attach(top)
        var lim = opts; lim.listLimit = 6
        let ok = SpaceScanner.scan([.init(node: top, path: r.home, split: [r.h("Library")])], opts: lim,
                                   links: LinkSet(), cancel: CancelFlag(), counter: SpaceCounter()) { p, c in p.attach(c) }
        check(ok, "scan complete")
        func find(_ rel: String) -> SpaceNode? {
            var n: SpaceNode? = top
            for c in rel.split(separator: "/") { n = n?.children.first { $0.name == c } }
            return n
        }
        // sizes as du -kx reports them, hard links counted once
        eq(top.size, du(r.home), "home size equals du -kx")
        eq(map.size, top.size, "the map's root adds up its tops")
        eq(find("Projects")?.size, du(r.h("Projects")), "Projects size equals du -kx (hard link once)")
        eq(find("Projects/site")?.size, du(r.h("Projects/site")), "site size equals du -kx")
        eq(find("Library")?.size, du(r.h("Library")), "split folder size equals du -kx")
        check(find("Projects/link").map { $0.size < 20_000 && !$0.isDir } == true, "symlink not followed")
        // every folder adds up: its own blocks + listed children + smaller items
        func sums(_ n: SpaceNode) -> Bool {
            guard n.isDir else { return true }
            let own = Int64(ScanEngine.lstatInfo(n.path)?.st_blocks ?? 0) * 512
            let kids = n.children.reduce(0) { $0 + $1.size }
            let sorted = zip(n.children, n.children.dropFirst()).allSatisfy { $0.size >= $1.size }
            return own + kids + n.otherSize == n.size && sorted && n.children.allSatisfy(sums)
        }
        check(sums(top), "folders add up and list largest first")
        // listing limit: 10 entries in Many, 6 listed, 4 folded, the .app found among the folded ones
        if let many = find("Many") {
            eq(many.children.count, 6, "listing limit")
            eq(many.otherCount, 4, "smaller items folded")
            check(many.blocker != nil, "protection found in a folded child still counts")
            check(!many.children.contains { $0.name == "small.app" }, "smallest entry folded")
        } else { check(false, "Many listed") }
        // under listMin: a folder lists nothing, but keeps its totals
        var small = opts; small.listMin = 10_000_000
        if let s = SpaceScanner.walk(r.h("Projects"), opts: small, links: LinkSet(), cancel: CancelFlag()),
           let site = s.children.first(where: { $0.name == "site" }) {
            check(site.children.isEmpty && site.otherCount == 2 && site.size > 300_000, "small folder lists nothing")
        } else { check(false, "walk Projects") }
        // labels: folders named by bundle ID or .app resolve to an app
        var lab = opts
        lab.label = { name, _ in name == "Tool.app" ? AppInfo(id: "com.x.tool", name: "Tool", path: "") : nil }
        let labelled = SpaceScanner.walk(r.h("Projects"), opts: lab, links: LinkSet(), cancel: CancelFlag())
        eq(labelled?.children.first { $0.name == "Tool.app" }?.owner?.name, "Tool", "owner label")

        // reasons shown before picking (from the tree)
        func why(_ rel: String) -> String?? { find(rel).map { SpaceGuard.reason(for: $0, home: top) } }
        eq(why("Projects/site"), .some(nil), "tree: project folder may be picked")
        eq(why("Documents/report.txt"), .some(nil), "tree: file in Documents may be picked")
        check(why("Projects/site/.git")! != nil, "tree: .git refused")
        check(why("Projects")!?.hasPrefix("Contains an app") == true, "tree: folder holding an app refused")
        check(why("Projects/Tool.app")! != nil, "tree: app refused")
        check(why("Pictures")! != nil, "tree: standard folder refused")
        check(why("Pictures/Lib.photoslibrary")! != nil, "tree: photo library refused")
        check(why("Library/Caches")! != nil, "tree: ~/Library refused")
        check(why("Dropbox")! != nil && why(".config")! != nil, "tree: sync and hidden folders refused")
        check(SpaceGuard.reason(for: top, home: top) != nil, "tree: home itself refused")
        let thing = find("Projects/Thing.bundle")
        let pkg = thing?.flags.contains(.package) == true
        check(pkg, "a .bundle folder is a package")
        if pkg, let inner = thing?.children.first {
            check(SpaceGuard.reason(for: inner, home: top) != nil, "tree: inside a package refused")
            eq(SpaceGuard.reason(for: thing!, home: top), nil, "tree: whole package allowed")
        }
        let other = SpaceNode(name: "Tool.app", isDir: true, dev: 0, ino: 0); other.base = "/Applications"
        let inApps = SpaceNode(name: "x", isDir: false, dev: 0, ino: 0)
        other.attach(inApps)
        check(SpaceGuard.reason(for: inApps, home: top)?.hasPrefix("Outside your home") == true, "tree: /Applications is Reveal only")
        if let site = find("Projects/site") {
            site.flags.insert(.incomplete)
            check(SpaceGuard.reason(for: site, home: top) != nil, "tree: not fully scanned refused")
            site.flags.remove(.incomplete)
        }

        // the guard on disk
        let g = SpaceGuard(roots: r)
        eq(g.check(r.h("Projects/site")), nil, "guard: project folder")
        eq(g.check(r.h("Documents/report.txt")), nil, "guard: file inside Documents")
        eq(g.check(r.h("projects/SITE")), nil, "guard: case-insensitive")
        eq(g.check(r.h("Projects/link")), nil, "guard: a symlink is judged where it sits")
        check(g.check(r.h("Projects/link/bin")) != nil, "guard: symlinked parent refused")
        check(g.check(r.h("Projects/site/.git")) != nil, "guard: .git refused")
        check(g.check(r.h("Projects/Tool.app")) != nil, "guard: app refused")
        check(g.check(r.h("Library/Caches/c")) != nil, "guard: ~/Library refused")
        check(g.check(r.h("Documents")) != nil, "guard: standard folder refused")
        check(g.check(r.home) != nil, "guard: home refused")
        check(g.check(r.h("Projects/missing")) != nil, "guard: missing item")
        check(g.check(r.h("Projects/../Documents/report.txt")) != nil, "guard: dot-dot refused")
        check(g.check("/private/tmp") != nil && g.check(r.applications) != nil, "guard: outside home refused")
        check(g.check("/usr/bin") != nil && g.check("/System/Library") != nil, "guard: S4 list")
        if pkg { check(g.check(r.h("Projects/Thing.bundle/Contents")) != nil, "guard: inside a package refused") }
        var synced = g
        synced.isSynced = { $0.lowercased().hasSuffix("/documents") }
        check(synced.check(r.h("Documents/report.txt")) != nil, "guard: inside a synced folder refused")
        let realG = SpaceGuard(roots: Roots.real())
        check(realG.check(Roots.real().h(".ssh")) != nil && realG.check(Roots.real().h("Library/Keychains")) != nil,
              "guard: keychains and .ssh refused")

        // removing a picked item updates every total
        if let site = find("Projects/site"), let projects = find("Projects") {
            let (hb, pb, mb) = (top.size, projects.size, map.size)
            projects.remove(site)
            check(top.size == hb - site.size && projects.size == pb - site.size && map.size == mb - site.size,
                  "remove updates totals")
            check(find("Projects/site") == nil, "removed from the list")
            projects.attach(site)
            eq(top.size, hb, "attach restores totals")
        }

        // large and old
        let big = SpaceNode(name: "big", isDir: false, dev: 0, ino: 0)
        let now = Date()
        big.size = SpaceNode.largeSize + 1; big.newest = now.timeIntervalSince1970 - 200 * 86_400
        check(big.largeAndOld(now: now), "over 1 GB, 200 days: large and old")
        big.newest = now.timeIntervalSince1970 - 100 * 86_400
        check(!big.largeAndOld(now: now), "100 days: not old")
        big.size = SpaceNode.largeSize; big.newest = now.timeIntervalSince1970 - 400 * 86_400
        check(!big.largeAndOld(now: now), "exactly 1 GB: not large")

        // a stopped scan is not complete
        let stopped = CancelFlag(); stopped.set()
        let t2 = SpaceScanner.shell(r.home)
        check(!SpaceScanner.scan([.init(node: t2, path: r.home)], opts: opts, links: LinkSet(), cancel: stopped,
                                 counter: SpaceCounter()) { p, c in p.attach(c) }, "stopped scan reported")

        // protected contents are found again when acting
        check(ScanEngine.measure(r.h("Projects"), links: nil, inspect: true).protected?.hasPrefix("Contains an app") == true,
              "measure finds an app inside")
        check(ScanEngine.measure(r.h("Pictures"), links: nil, inspect: true).protected == "Contains a photo library",
              "measure finds a photo library inside")
        eq(ScanEngine.measure(r.h("Projects/site"), links: nil, inspect: true).protected, nil, "nothing protected in site")
        check(ScanEngine.measure(r.h("Projects/site"), links: nil, inspect: true,
                                 synced: { $0.hasSuffix("/src") }).protected?.hasPrefix("Contains cloud-synced") == true,
              "measure finds a synced folder deep inside")
        if let site = find("Projects/site") {
            var syncedEnv = CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] },
                                             inventory: AppInventory(roots: r, lookup: nil, running: { [] }), roots: r,
                                             dryRun: true, now: Date.init)
            var sg = SpaceGuard(roots: r)
            sg.isSynced = { $0.hasSuffix("/src") }
            syncedEnv.spaceGuard = sg
            check(Cleaner.clean([SpaceMap.item(site)], env: syncedEnv).first?.reason?.hasPrefix("Contains cloud-synced") == true,
                  "clean: folder holding a synced folder skipped")
        }

        // a stopped walk leaves its folders incomplete, so they can't be picked
        _ = try? fm.createDirectory(atPath: r.h("Bulk"), withIntermediateDirectories: true)
        for i in 0..<1100 { fm.createFile(atPath: r.h("Bulk/f\(i)"), contents: nil) }
        let halt = CancelFlag(); halt.set()
        if let bulk = SpaceScanner.walk(r.h("Bulk"), opts: opts, links: LinkSet(), cancel: halt) {
            let holder = SpaceNode(name: "x", isDir: true, dev: 0, ino: 0)
            top.attach(holder)
            holder.attach(bulk)
            check(bulk.incomplete && SpaceGuard.reason(for: bulk, home: top) != nil, "stopped walk: refused")
            check(holder.incomplete && SpaceGuard.reason(for: holder, home: top) != nil,
                  "a folder holding a not fully scanned folder is refused")
            top.remove(holder)
        } else { check(false, "stopped walk returns a node") }

        // Cleaner.clean with Space-map items (dry run): every check runs, nothing moves
        let inv = AppInventory(roots: r, lookup: nil, running: { [] })
        var env = CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] }, inventory: inv, roots: r,
                                   dryRun: true, now: Date.init)
        env.spaceGuard = g
        func plan(_ rel: String) -> Outcome? {
            guard let n = find(rel) else { return nil }
            return Cleaner.clean([SpaceMap.item(n)], env: env).first
        }
        eq(plan("Projects/site")?.status, .planned, "clean: project folder planned")
        eq(plan("Documents/report.txt")?.status, .planned, "clean: file planned")
        check(plan("Projects")?.reason?.hasPrefix("Contains an app") == true, "clean: folder holding an app skipped")
        eq(plan("Projects/site/.git")?.status, .skipped, "clean: .git skipped")
        eq(plan("Library/Caches/c")?.status, .skipped, "clean: ~/Library skipped")
        // in use: this process holds a file open inside
        if let h = FileHandle(forReadingAtPath: r.h("Projects/site/src/a")) {
            check(plan("Projects/site")?.reason?.hasPrefix("In use by") == true, "clean: open file inside skipped")
            try? h.close()
        }
        // changed since the scan: a different item at the same path
        if let rep = find("Documents/report.txt") {
            try? fm.removeItem(atPath: r.h("Documents/report.txt"))
            file("Documents/report.txt", 70_000)
            eq(Cleaner.clean([SpaceMap.item(rep)], env: env).first?.reason, "Changed since the scan", "clean: replaced item skipped")
        }
        var noGuard = env; noGuard.spaceGuard = nil
        if let n = find("Projects/site") {
            eq(Cleaner.clean([SpaceMap.item(n)], env: noGuard).first?.reason, "No Space-map guard", "clean: no guard, no action")
        }
    }

    // MARK: Leftovers (spec 9)

    /// Evidence for the pure matcher tests: `ids` are installed (dot-prefix), `names` are app names.
    static func evidence(ids: [String] = ["com.inst.app"], exact: [String] = [], names: [String] = ["Inst App"],
                         spotlight: @escaping ([String]) -> SpotlightAnswer = { _ in .notFound }) -> LeftoverEvidence {
        LeftoverEvidence(
            installed: { id in
                if exact.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { return "exact" }
                return ids.first { BundleIDs.belongs(id, to: $0) }
            },
            names: Set(names.map(LeftoverEvidence.normalize)),
            vendors: Set((ids + exact).map(BundleIDs.vendor)), spotlight: spotlight, selfIDs: Leftovers.ownIDs)
    }

    static func leftoverScreen() {
        let ev = evidence(names: ["Inst App", "Spotify", "Visual Studio Code", "Foo.Bar", "Alt-Tab"])
        func s(_ name: String, _ e: LeftoverEvidence? = nil) -> LeftoverMatcher.Screen { LeftoverMatcher.screen(CandidateKey.parse(name), e ?? ev) }
        func dropped(_ name: String, _ e: LeftoverEvidence? = nil) -> Bool { if case .drop = s(name, e) { return true }; return false }
        // 9.3 High (1): installed IDs, their helpers, and base IDs
        eq(s("com.gone.app"), .bundle(group: "com.gone.app", low: false), "not installed: High")
        eq(s("com.gone.app.plist"), .bundle(group: "com.gone.app", low: false), "plist key")
        eq(s("com.gone.app.savedState"), .bundle(group: "com.gone.app", low: false), "savedState key")
        eq(s("com.gone.app.helper"), .bundle(group: "com.gone.app", low: false), "helper groups under its base")
        eq(s("com.gone.app.FinderSync"), .bundle(group: "com.gone.app", low: false), "base ID without case")
        check(dropped("com.inst.app"), "installed ID")
        check(dropped("COM.Inst.App"), "installed ID without case")
        check(dropped("com.inst.app.widget.extra"), "dot-prefix of an installed ID")
        check(!dropped("com.inst.application", evidence(ids: ["com.inst.app"], names: [])) , "plain prefix is not a match")
        check(dropped("com.solo.tool.helper", evidence(ids: [], exact: ["com.solo.tool"], names: [])), "base ID installed")
        check(dropped("com.solo.tool.Agent", evidence(ids: [], exact: ["com.solo.tool"], names: [])), "base ID: agent suffix")
        check(!dropped("com.solo.tool.pro", evidence(ids: [], exact: ["com.solo.tool"], names: [])), "unknown suffix is not a base")
        // 9.3 High (2): protection list
        for k in ["com.apple.Safari", "com.apple.Safari.plist", "something.apple.y", "com.google.Chrome", "Google",
                  "org.mozilla.firefox", "com.jetbrains.rider", "JetBrains", "com.docker.docker", "1Password",
                  "com.agilebits.onepassword7", "Bitwarden", "org.cups.printers", "loginwindow.plist", "Homebrew",
                  "group.com.apple.notes", "ABCDE12345.com.apple.x", "is.workflow.my.app", "group.is.workflow.shortcuts",
                  "MobileSync", "AddressBook", "CallHistoryDB", "Knowledge", "FileProvider", "CoreSimulator",
                  "com.microsoft.teams2", "org.python.python", "com.vendor.ssh"] {
            check(dropped(k), "protected: \(k)")
        }
        // 9.3 High (4): App Monitor itself
        check(dropped("io.github.laimis91.appmonitor"), "App Monitor")
        check(dropped("io.github.laimis91.appmonitor.plist"), "App Monitor settings")
        // 9.3 High (5): installed app names against whole key components, never split
        check(dropped("com.spotify.client"), "component equals an app name")
        check(dropped("com.vendor.visualstudiocode"), "name with spaces compared without them")
        check(!dropped("com.vendor.visual"), "a name is never split into words")
        check(!dropped("com.foo.bar"), "a name with a dot never matches one component")
        check(dropped("com.vendor.alt-tab"), "hyphenated name matches a whole component")
        check(!dropped("com.vendor.spotifyx"), "no substring matching")
        check(dropped("com.vendor.orca-slicer", evidence(names: ["OrcaSlicer"])), "hyphens ignored: orca-slicer is OrcaSlicer")
        check(dropped("com.vendor.my_tool", evidence(names: ["My Tool"])), "underscores and spaces ignored")
        for k in ["com.revenuecat.user_defaults", "com.segment.storage.x", "io.sentry.session", "org.sparkle-project.Sparkle",
                  "com.electron.someapp", "com.squirrel.foo.ShipIt"] {
            check(dropped(k), "library namespace protected: \(k)")
        }
        // 9.2 shared vendor: Low
        eq(s("com.inst.other"), .bundle(group: "com.inst.other", low: true), "same vendor: Low")
        // name candidates and wrapped keys
        eq(s("GoneApp"), .name, "plain name: name candidate")
        eq(s("group.com.gone.app"), .bundle(group: "com.gone.app", low: false), "group. prefix reduces to the ID")
        eq(s("ABCDE12345.com.gone.app"), .bundle(group: "com.gone.app", low: false), "team ID prefix reduces to the ID")
        eq(s("ABCDE12345.com.gone"), .name, "team ID with a short rest is a name")
        eq(LeftoverMatcher.prefixes("com.a.b.c"), ["com.a.b.c", "com.a.b"], "dot-prefixes")
        eq(LeftoverMatcher.prefixes("com.a"), ["com.a"], "short ID")
    }

    static func cand(_ place: String, _ name: String, days d: Double? = 100, bundleName: String? = nil,
                     containerID: String? = nil, doubt: String? = nil, immovable: String? = nil) -> LeftoverCandidate {
        let pl = LeftoverPlace.named(place)
        var c = LeftoverCandidate(place: pl, name: name, path: "/fixture/" + pl.rel + "/" + name)
        c.newest = d.map { Date(timeIntervalSinceNow: -$0 * 86_400) }
        c.size = 4096
        c.bundleName = bundleName; c.containerID = containerID; c.doubt = doubt; c.immovable = immovable
        return c
    }

    static func leftoverDecide() {
        let now = Date(timeIntervalSinceNow: 60), lim = AgeLimits()
        func run(_ cs: [LeftoverCandidate], _ ev: LeftoverEvidence? = nil) -> LeftoverDecision {
            LeftoverMatcher.decide(cs, ev: ev ?? evidence(), limits: lim, now: now)
        }
        let app = [cand("appSupport", "com.gone.app"), cand("caches", "com.gone.app"),
                   cand("preferences", "com.gone.app.plist", bundleName: "Gone App"),
                   cand("savedState", "com.gone.app.savedState"), cand("caches", "com.gone.app.helper"),
                   cand("caches", "com.gone.app.ShipIt")]
        // 9.4 (3): one High group with every item, named from the settings file
        let d = run(app)
        eq(d.groups.count, 1, "one group")
        eq(d.groups.first?.confidence, .high, "High")
        eq(d.groups.first?.items.count, 6, "all items, helpers and sub-IDs included")
        eq(d.groups.first?.title, "Gone App", "last-known name")
        check(d.groups.first?.items.allSatisfy(\.selectable) == true, "movable items selectable")
        check(d.groups.first?.items.first?.reason.contains("an app not found on this Mac, unchanged for 100 days, limit 30.") == true,
              "reason names the rule and the limit: \(d.groups.first?.items.first?.reason ?? "")")
        // 9.4 (4): data newer than the limit, anywhere in the group, keeps the whole group
        eq(run(app + [cand("logs", "com.gone.app", days: 10)]).groups.count, 0, "one recent item keeps the group")
        eq(run([cand("caches", "com.gone.app", days: 29)]).groups.count, 0, "29 days: not reported")
        eq(run([cand("caches", "com.gone.app", days: 30)]).groups.count, 1, "30 days: reported")
        eq(run(app + [cand("caches", "com.gone.app.x", days: nil)]).groups.count, 0, "unknown age keeps the group (S5)")
        eq(run(app + [cand("appSupport", "com.gone.app.web", doubt: "Contains an app")]).groups.count, 0, "an app inside keeps the group")
        // 9.4 (6): Spotlight finds it, or doesn't answer
        eq(run(app, evidence(spotlight: { _ in .found })).groups.count, 0, "found by Spotlight: kept")
        let failed = run(app, evidence(spotlight: { _ in .failed }))
        check(failed.groups.isEmpty && failed.spotlightFailed == 1, "Spotlight didn't answer: kept and counted")
        var asked: [String] = []
        _ = run([cand("caches", "com.gone.app.helper.x")], evidence(spotlight: { ids in asked = ids; return .notFound }))
        eq(asked, ["com.gone.app.helper.x", "com.gone.app.helper", "com.gone.app"], "Spotlight asked for the ID and its prefixes")
        // review-only and info places only join groups found elsewhere
        eq(run([cand("groupContainers", "group.com.gone.app"), cand("launchAgents", "com.gone.app.plist")]).groups.count, 0,
           "review-only places never start a group")
        let joined = run(app + [cand("groupContainers", "group.com.gone.app"), cand("groupContainers", "ABCDE12345.com.gone.app.shared"),
                                cand("appScripts", "com.gone.app"), cand("sysLaunchDaemons", "com.gone.app.helper.plist")])
        eq(joined.groups.first?.items.count, 10, "review-only and info items join the group")
        let info = joined.groups.first?.items.first { $0.candidate.place.id == "sysLaunchDaemons" }
        check(info?.selectable == false && info?.reason.contains("Needs administrator rights") == true, "info place: not selectable")
        // Containers count only when their metadata names the ID
        eq(run(app + [cand("containers", "com.gone.app", containerID: "com.gone.app")]).groups.first?.items.count, 7, "container with matching metadata")
        eq(run(app + [cand("containers", "com.gone.app", containerID: "com.other.app")]).groups.first?.items.count, 6, "container metadata mismatch")
        eq(run(app + [cand("containers", "com.gone.app")]).groups.first?.items.count, 6, "container without metadata")
        // only settings files: Low, because libraries inside other apps write settings under their own IDs
        let prefsOnly = run([cand("preferences", "com.lib.thing.plist", days: 120), cand("launchAgents", "com.lib.thing.plist", days: 120)])
        eq(prefsOnly.groups.first?.confidence, .low, "settings files only: Low")
        check(prefsOnly.groups.first?.items.first?.reason.contains("Only a settings file was found") == true, "settings-only reason")
        eq(run([cand("preferences", "com.lib.thing.plist", days: 60)]).groups.count, 0, "settings only: Low age limit")
        eq(run([cand("preferences", "com.lib.thing.plist"), cand("caches", "com.lib.thing")]).groups.first?.confidence, .high,
           "settings plus other data: High")
        check(Leftovers.category(prefsOnly.groups[0]).items.allSatisfy { !$0.owners.contains("com.lib") }, "settings-only: no vendor owner")
        // the user can't move it: shown, not selectable
        let im = run([cand("caches", "com.gone.app", immovable: "You can't move it yourself.")])
        eq(im.groups.first?.items.first?.selectable, false, "immovable: not selectable")
        // separate apps stay separate; a sub-ID joins the shorter group
        eq(run(app + [cand("caches", "com.gone.other")]).groups.count, 2, "two apps, two groups")
        // shared vendor: Low, with the Low age limit
        let vendor = evidence(ids: ["com.inst.app"])
        eq(run([cand("caches", "com.inst.oldapp", days: 60)], vendor).groups.count, 0, "Low needs the Low limit (90)")
        let low = run([cand("caches", "com.inst.oldapp", days: 120)], vendor)
        eq(low.groups.first?.confidence, .low, "same vendor: Low")
        check(low.groups.first?.items.first?.reason.contains("Another app from com.inst is on this Mac") == true, "Low reason")
        eq(run([cand("caches", "com.inst.oldapp", days: 120), cand("caches", "com.inst.oldapp.helper", days: 40)], vendor).groups.count, 0,
           "Low group: every item meets the Low limit")
        // 9.3 Low: plain names need positive evidence
        let named = run(app + [cand("appSupport", "GoneApp", days: 120), cand("caches", "Gone App", days: 120)])
        let possible = named.groups.first { $0.key.hasPrefix("name:") }
        eq(possible?.items.count, 2, "names equal to the last-known name: Low")
        eq(possible?.confidence, .low, "name evidence is Low")
        eq(run(app + [cand("appSupport", "GoneApp", days: 60)]).groups.count, 1, "name item needs the Low limit")
        eq(run(app + [cand("appSupport", "OtherName", days: 120)]).groups.count, 1, "no evidence: not reported")
        eq(run([cand("appSupport", "GoneApp", days: 120)]).groups.count, 0, "no High group: no evidence")
        let short = [cand("preferences", "com.gone.app.plist", bundleName: "Gone"), cand("appSupport", "Gone", days: 120)]
        eq(run(short).groups.count, 1, "names under 5 characters are never matched")
        eq(run(app + [cand("appSupport", "GoneApp", days: 120)], evidence(names: ["GoneApp"])).groups.filter { $0.key.hasPrefix("name:") }.count, 0,
           "a name equal to an installed app's name is never matched")
        // the installed-name check ignores hyphens and spaces the same way the evidence does
        for (folder, installed) in [("Gone-App", "GoneApp"), ("Gone App", "Gone-App"), ("gone_app", "Gone App")] {
            eq(run(app + [cand("appSupport", folder, days: 120)], evidence(names: [installed])).groups.filter { $0.key.hasPrefix("name:") }.count, 0,
               "folder \(folder) with installed \(installed) is never matched")
        }
        // a group whose last-known name is an installed app's name is Low (renamed app)
        let renamed = run(app, evidence(names: ["Gone App"]))
        eq(renamed.groups.first?.confidence, .low, "last-known name of an installed app: Low")
        check(renamed.groups.first?.items.first?.reason.contains("under a new ID") == true, "renamed reason")
        // a member claimed by something installed keeps the whole group out
        eq(LeftoverMatcher.decide(app, ev: evidence(), limits: lim, now: now, kept: ["com.gone.app.menu"]).groups.count, 0,
           "installed helper keeps its main app's data")
        eq(LeftoverMatcher.decide(app, ev: evidence(), limits: lim, now: now, kept: ["com.gone"]).groups.count, 0,
           "installed parent ID keeps the group")
        eq(LeftoverMatcher.decide(app, ev: evidence(), limits: lim, now: now, kept: ["com.gone.application"]).groups.count, 1,
           "an unrelated ID doesn't")
        // the running check by name uses the app's last-known name, compared loosely
        let nameCat = named.groups.map(Leftovers.category).first { $0.id.hasPrefix("L:name:") }!
        let inv0 = AppInventory(roots: Roots.fixture("/private/tmp/appmon-fixture-none")!, lookup: nil, running: { [] })
        eq(inv0.runningOwner(nameCat.items[0].owners, names: nameCat.items[0].ownerNames,
                             snapshot: [RunningApp(id: "com.newco.x", name: "Gone App")]), "Gone App", "name item blocked by its running app")
        let highCat = Leftovers.category(d.groups[0])
        eq(inv0.runningOwner(highCat.items[0].owners, names: highCat.items[0].ownerNames,
                             snapshot: [RunningApp(id: "com.newco.x", name: "Gone App")]), "Gone App", "High item blocked by an app of its name")
        eq(run(app + [cand("logs", "GoneApp", days: 120)]).groups.filter { $0.key.hasPrefix("name:") }.first?.items.count, 1,
           "any orphan place can hold a name item")
        eq(run(app + [cand("groupContainers", "GoneApp", days: 120)]).groups.count, 1, "review-only places hold no name items")

        // categories: Review, never pre-selected (9.4: 5), Low under Possible
        let cats = (named.groups + low.groups).map(Leftovers.category)
        check(cats.allSatisfy { $0.items.allSatisfy { !$0.preselected && ($0.risk == .review || $0.risk == .info) } }, "never pre-selected")
        check(cats.allSatisfy { $0.items.allSatisfy { $0.inspect && $0.checkOpenFiles && $0.ageLimitDays != nil } }, "re-checked when cleaned")
        eq(cats.filter { $0.group == .possible }.count, 2, "Low groups are Possible leftovers")
        check(Leftovers.category(low.groups[0]).items[0].owners.contains("com.inst"), "Low vendor: any running app of the vendor blocks it")
        let jc = Leftovers.category(joined.groups[0])
        check(jc.items.allSatisfy { !$0.preselected }, "no group container or launch agent pre-selected")
        check(jc.items.contains { $0.owners.contains("com.gone.app.helper") && $0.owners.contains("com.gone.app") }, "owners for the running check")
    }

    /// The disk side on a small tree (9.4: 1, 2, 3, 6).
    static func leftoverScan() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-lo-\(getpid())"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        guard let r = Roots.fixture(root) else { check(false, "leftover fixture"); return }
        func file(_ path: String, _ bytes: Int = 4096) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data(count: bytes))
        }
        func app(_ path: String, _ id: String, _ name: String) {
            file(path + "/Contents/MacOS/x")
            (["CFBundleIdentifier": id, "CFBundleName": name] as NSDictionary).write(toFile: path + "/Contents/Info.plist", atomically: true)
        }
        let L = r.h("Library")
        app(r.applications + "/Inst.app", "com.inst.app", "Inst")                         // 9.4 (1)
        app(L + "/Application Support/WebTool/Web Tool.app", "com.web.tool", "Web Tool")   // 9.4 (2)
        try? fm.createDirectory(atPath: L + "/Preferences", withIntermediateDirectories: true)
        for id in ["com.inst.app", "com.web.tool", "com.gone.app", "com.fresh.app"] {
            file(L + "/Caches/\(id)/data"); file(L + "/Application Support/\(id)/data")
            (["CFBundleName": id == "com.gone.app" ? "Gone App" : "X"] as NSDictionary).write(toFile: L + "/Preferences/\(id).plist", atomically: true)
            file(L + "/Saved Application State/\(id).savedState/windows.plist")
        }
        file(L + "/Application Support/GoneApp/x")                 // name evidence
        file(L + "/Group Containers/group.com.gone.app/x")
        file(L + "/Preferences/com.gone.app.notplist")             // wrong extension
        file(L + "/Caches/com.ignored.app/x")
        try? fm.createSymbolicLink(atPath: L + "/Caches/com.link.app", withDestinationPath: r.home)
        func age(_ path: String, _ d: Double) {
            let t = Date(timeIntervalSinceNow: -d * 86_400)
            let e = fm.enumerator(atPath: path)
            while let rel = e?.nextObject() as? String {
                try? fm.setAttributes([.modificationDate: t], ofItemAtPath: path + "/" + rel)
            }
            try? fm.setAttributes([.modificationDate: t], ofItemAtPath: path)
        }
        age(root, 200)
        for p in ["Caches/com.fresh.app/data", "Caches/com.fresh.app"] { try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: L + "/" + p) }

        func scan(fda: FDAStatus = .granted, spotlight: @escaping ([String]) -> SpotlightAnswer = { _ in .notFound }) -> [Category] {
            let inv = AppInventory(roots: r, lookup: nil, running: { [] })
            var ctx = ScanContext(roots: r, limits: AgeLimits(), fda: fda, ignore: [(L + "/Caches/com.ignored.app").lowercased()],
                                  inventory: inv, running: [], tools: ToolLocator(places: [:], xcodeSelectOK: true),
                                  cancel: CancelFlag(), now: Date())
            ctx.spotlight = spotlight
            return Leftovers.scan(ctx).categories
        }
        let cats = scan()
        let paths = Set(cats.flatMap(\.items).map { $0.path.replacingOccurrences(of: L + "/", with: "") })
        check(!paths.contains { $0.contains("com.inst.app") }, "9.4 (1): installed app's data not reported")
        check(!paths.contains { $0.contains("com.web.tool") || $0.contains("WebTool") }, "9.4 (2): app inside Application Support kept")
        check(!paths.contains { $0.contains("com.fresh.app") }, "9.4 (4): recent data not reported")
        let gone = cats.first { $0.id == "L:com.gone.app" }
        eq(gone?.group, .leftovers, "9.4 (3): one High group")
        eq(Set(gone?.items.map { $0.path.replacingOccurrences(of: L + "/", with: "") } ?? []),
           ["Application Support/com.gone.app", "Caches/com.gone.app", "Preferences/com.gone.app.plist",
            "Saved Application State/com.gone.app.savedState", "Group Containers/group.com.gone.app"], "9.4 (3): its items")
        eq(gone?.title, "Gone App", "name from the settings file")
        eq(cats.first { $0.id == "name:com.gone.app" || $0.id == "L:name:com.gone.app" }?.items.map(\.name), ["GoneApp"], "named folder: Possible")
        check(!paths.contains { $0.contains("ignored") || $0.contains("link") || $0.hasSuffix("notplist") }, "ignored, symlinks, wrong extension")
        check(cats.flatMap(\.items).allSatisfy { !$0.preselected }, "9.4 (5): nothing pre-selected")
        check(cats.flatMap(\.items).allSatisfy { i in
            if case .rule(let root) = i.scope { return PathGuard(roots: r).check(i.path, allowRoot: root) == nil }
            return i.scope == .none && !i.selectable
        }, "every item passes the path guard with its root; the rest are Info")
        // no Full Disk Access: containers aren't entered and are flagged
        let nofda = scan(fda: .denied)
        check(nofda.contains { $0.id == Leftovers.fdaID && $0.notice == "Needs Full Disk Access" }, "no FDA: notice row")
        check(!nofda.flatMap(\.items).contains { $0.path.contains("Group Containers") }, "no FDA: group containers not entered")
        // 9.4 (6): Spotlight doesn't answer: the scan completes and lists nothing it couldn't confirm
        let sp = scan(spotlight: { _ in .failed })
        check(!sp.contains { $0.id.hasPrefix("L:") }, "Spotlight failed: nothing reported")
        check(sp.contains { $0.id == Leftovers.spotlightID }, "Spotlight failed: notice row")
        // cleaning a leftover re-checks contents: an app put inside since the scan stops it
        if let g = cats.first(where: { $0.id == "L:com.gone.app" }), let item = g.items.first(where: { $0.path.hasSuffix("Application Support/com.gone.app") }) {
            app(item.path + "/Sneaky.app", "com.sneaky", "Sneaky")
            let inv = AppInventory(roots: r, lookup: nil, running: { [] })
            let env = CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] }, inventory: inv, roots: r, dryRun: true, now: Date.init)
            check(Cleaner.clean([(g, item)], env: env).first?.reason?.hasPrefix("Contains an app") == true, "app inside at clean time: skipped")
            let running = CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [RunningApp(id: "com.gone.app", name: "Gone App")] },
                                           inventory: inv, roots: r, dryRun: true, now: Date.init)
            eq(Cleaner.clean([(g, g.items[0])], env: running).first?.reason, "Gone App is running", "running app at clean time: skipped")
        }
    }

    // MARK: Uninstaller (spec 10)

    static func uninstallRules() {
        let t = ["com.vendor.app", "com.vendor.login"]
        let o: [(id: String, name: String)] = [("com.vendor.app.pro", "Pro"), ("com.other.app", "Other")]
        eq(Uninstaller.owner(of: "com.vendor.app", target: t, others: o, targetPath: "/Applications/Vendor.app"), .target, "own ID")
        eq(Uninstaller.owner(of: "COM.Vendor.App.cache", target: t, others: o, targetPath: "/Applications/Vendor.app"), .target, "dot-prefix, no case")
        eq(Uninstaller.owner(of: "com.vendor.login", target: t, others: o, targetPath: "/Applications/Vendor.app"), .target, "embedded ID")
        eq(Uninstaller.owner(of: "com.vendor.app.pro", target: t, others: o, targetPath: "/Applications/Vendor.app"), .other("Pro"), "longer installed ID wins")
        eq(Uninstaller.owner(of: "com.vendor.app.pro.helper", target: t, others: o, targetPath: "/Applications/Vendor.app"), .other("Pro"), "its helpers too")
        eq(Uninstaller.owner(of: "com.vendor.apps", target: t, others: o, targetPath: "/Applications/Vendor.app"), nil, "no partial component")
        eq(Uninstaller.owner(of: "com.vendor", target: t, others: o, targetPath: "/Applications/Vendor.app"), nil, "shorter key not matched")
        eq(Uninstaller.owner(of: "com.vendor.login", target: t, others: [("com.vendor.login", "Suite")], targetPath: "/Applications/Vendor.app"), .other("Suite"),
           "an ID another app also has: the other app wins")
        // un-4: LaunchServices knows an app the folders don't (com.vendor.app.beta in Downloads).
        let ls: (String) -> AppInfo? = { id in
            id.lowercased() == "com.vendor.app.beta" ? AppInfo(id: "com.vendor.app.beta", name: "Beta", path: "/Users/x/Downloads/Beta.app") : nil
        }
        eq(Uninstaller.owner(of: "com.vendor.app.beta", target: t, others: o, lookup: ls, targetPath: "/Applications/Vendor.app"),
           .other("Beta"), "app known only to LaunchServices wins")
        eq(Uninstaller.owner(of: "com.vendor.app.beta.cache", target: t, others: o, lookup: ls, targetPath: "/Applications/Vendor.app"),
           .other("Beta"), "its sub-IDs too")
        eq(Uninstaller.owner(of: "com.vendor.app", target: t, others: o, lookup: ls, targetPath: "/Applications/Vendor.app"),
           .target, "the target ID itself isn't looked up")
        let self_: (String) -> AppInfo? = { _ in AppInfo(id: "com.vendor.app", name: "Vendor", path: "/Applications/Vendor.app") }
        eq(Uninstaller.owner(of: "com.vendor.app.cache", target: t, others: o, lookup: self_, targetPath: "/Applications/Vendor.app"),
           .target, "LaunchServices answering with the target keeps it")
        // E10: an empty target path is no app's path, so an app LaunchServices names elsewhere wins.
        let elsewhere: (String) -> AppInfo? = { _ in AppInfo(id: "com.vendor.app.x", name: "X", path: "/Users/x/Downloads/X.app") }
        eq(Uninstaller.owner(of: "com.vendor.app.x.cache", target: t, others: o, lookup: elsewhere, targetPath: ""),
           .other("X"), "e10: empty target path matches no app")
        eq(Uninstaller.owner(of: "com.vendor.app.x.cache", target: t, others: o, lookup: elsewhere, targetPath: "/Users/x/Downloads/X.app"),
           .target, "e10: an app inside the target path is the target")
        eq(Uninstaller.owner(of: "com.vendor.app.x.cache", target: t, others: o, lookup: self_, targetPath: ""),
           .target, "e10: a target ID still counts without a path")
        eq(Uninstaller.kind(LeftoverPlace.named("caches")), .safe, "caches Safe")
        eq(Uninstaller.kind(LeftoverPlace.named("preferences")), .data, "settings Review, pre-selected")
        eq(Uninstaller.kind(LeftoverPlace.named("cookies")), .data, "cookies Review, pre-selected")
        eq(Uninstaller.kind(LeftoverPlace.named("groupContainers")), .review, "group containers Review")
        eq(Uninstaller.kind(LeftoverPlace.named("launchAgents")), .review, "launch agents Review")
        eq(Uninstaller.kind(LeftoverPlace.named("sysLaunchDaemons")), .info, "/Library Info")
        eq(Uninstaller.kind(LeftoverPlace.named("byHost")), .data, "per-computer settings Review, pre-selected")
        eq(Uninstaller.kind(LeftoverPlace.named("recentDocs")), .safe, "recent documents Safe")
        eq(CandidateKey.parse("com.vendor.app.sfl4").key, "com.vendor.app", "recent documents extension dropped")
        check(Uninstaller.distinctivePlainID("chatgpthelper"), "distinctive plain helper ID")
        check(!Uninstaller.distinctivePlainID("helper") && !Uninstaller.distinctivePlainID("updater")
              && !Uninstaller.distinctivePlainID("tool") && !Uninstaller.distinctivePlainID("electron"), "generic plain IDs refused")
        let a = AppInfo(id: "com.vendor.app", name: "Vendor App", path: "/x", names: ["Vendor App", "VendorApp", "App"])
        eq(Uninstaller.nameKeys(a, others: []), ["vendorapp"], "name keys, short names left out")
        eq(Uninstaller.nameKeys(a, others: ["Vendor-App"]), [], "a name another app has is not used")
        let electron = AppInfo(id: "com.vendor.chat", name: "Vendor Chat", path: "/x", names: ["Vendor Chat", "Electron", "Code", "Google"])
        eq(Uninstaller.nameKeys(electron, others: []), ["vendorchat"], "protected names (Electron, Code, Google) are not name keys")
    }

    static func uninstallScan() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-un-\(getpid())"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { _ = chmod(root + "/Applications/Locked", 0o755); try? fm.removeItem(atPath: root) }
        guard let r = Roots.fixture(root) else { check(false, "uninstall fixture"); return }
        func file(_ path: String, _ bytes: Int = 4096) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data(count: bytes))
        }
        func app(_ path: String, _ id: String, _ name: String) {
            file(path + "/Contents/MacOS/x")
            (["CFBundleIdentifier": id, "CFBundleName": name] as NSDictionary).write(toFile: path + "/Contents/Info.plist", atomically: true)
        }
        let A = r.applications, L = r.h("Library")
        app(A + "/Vendor.app", "com.vendor.app", "Vendor")
        app(A + "/Vendor.app/Contents/Library/LoginItems/Login.app", "com.vendor.login", "Login")
        app(A + "/Vendor.app/Contents/XPCServices/Updater.xpc", "org.sparkle-project.Updater", "Updater")
        app(A + "/Vendor.app/Contents/PlugIns/Widget.appex", "com.vendor.app.widget", "Widget")
        app(A + "/Vendor.app/Contents/Helpers/VendorHelper.app", "VendorHelper", "VendorHelper")   // plain helper ID
        app(A + "/Vendor.app/Contents/Helpers/Helper.app", "Helper", "Helper")                     // generic: left out
        app(A + "/Vendor.app/Contents/Helpers/Locked.app", "Locked", "Locked")                     // another app's name: left out
        app(A + "/Vendor.app/Contents/Helpers/CrashReporter.app", "CrashReporter", "CrashReporter") // generic word: left out
        app(A + "/Sub/Vendor Pro.app", "com.vendor.app.pro", "Vendor Pro")
        app(A + "/Fake.app", "com.apple.fake", "Fake")
        app(r.systemApplications + "/Sys.app", "com.fixture.sys", "Sys")
        app(r.h("Applications/Mine.app"), "com.fixture.mine", "Mine")
        app(L + "/Application Support/Web/Web.app", "com.fixture.web", "Web")
        app(A + "/Self.app", "io.github.laimis91.appmonitor", "App Monitor")
        app(A + "/Locked/Locked.app", "com.fixture.locked", "Locked")
        _ = chmod(A + "/Locked", 0o555)
        try? fm.createSymbolicLink(atPath: A + "/Link.app", withDestinationPath: A + "/Vendor.app")
        file(A + "/NotApp.app/readme")
        file(A + "/Phone.app/Wrapper/Phone.app/Info.plist")
        try? fm.createSymbolicLink(atPath: A + "/Phone.app/WrappedBundle", withDestinationPath: "Wrapper/Phone.app")
        let me = Uninstaller.selfIDs
        eq(Uninstaller.refusal(A + "/Vendor.app", roots: r, selfIDs: me), nil, "app in Applications accepted")
        eq(Uninstaller.refusal(A + "/Sub/Vendor Pro.app", roots: r, selfIDs: me), nil, "app in a subfolder accepted")
        eq(Uninstaller.refusal(r.h("Applications/Mine.app"), roots: r, selfIDs: me), nil, "app in ~/Applications accepted")
        check(Uninstaller.refusal(A + "/Fake.app", roots: r, selfIDs: me)?.contains("come with macOS") == true, "com.apple. refused anywhere")
        check(Uninstaller.refusal(r.systemApplications + "/Sys.app", roots: r, selfIDs: me)?.contains("come with macOS") == true, "System/Applications refused")
        check(Uninstaller.refusal(L + "/Application Support/Web/Web.app", roots: r, selfIDs: me)?.contains("own uninstaller") == true, "outside Applications refused")
        check(Uninstaller.refusal(A + "/Self.app", roots: r, selfIDs: me)?.contains("itself") == true, "App Monitor refused")
        check(Uninstaller.refusal(A + "/Locked/Locked.app", roots: r, selfIDs: me)?.contains("can't move") == true, "not movable by the user refused")
        check(Uninstaller.refusal(A + "/Link.app", roots: r, selfIDs: me)?.contains("link") == true, "link refused")
        check(Uninstaller.refusal(A + "/NotApp.app", roots: r, selfIDs: me)?.contains("isn't an app") == true, "folder named .app refused")
        check(Uninstaller.refusal(A + "/Phone.app", roots: r, selfIDs: me)?.contains("iPhone or iPad") == true, "iOS app wrapper refused")
        check(Uninstaller.refusal(A, roots: r, selfIDs: me) != nil, "Applications itself refused")
        check(Uninstaller.refusal(A + "/Vendor.app/Contents/Library/LoginItems/Login.app", roots: r, selfIDs: me)?.contains("part of another app") == true,
              "un-1: helper inside another app refused")
        // f-2: folders above the app root aren't looked at (a home folder named like a bundle).
        let odd = "/private/tmp/appmon-fixture-selftest-odd-\(getpid()).bundle"
        try? fm.createDirectory(atPath: odd, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: odd) }
        if let ro = Roots.fixture(odd) {
            app(ro.applications + "/Plain.app", "com.fixture.plain", "Plain")
            eq(Uninstaller.refusal(ro.applications + "/Plain.app", roots: ro, selfIDs: me), nil, "f-2: bundle-like name above Applications ignored")
            eq(PathGuard(roots: ro).check(ro.applications + "/Plain.app", allowRoot: ro.applications, appBundle: true), nil, "f-2: guard too")
        } else { check(false, "odd fixture root") }
        let choices = Uninstaller.choices(r, selfIDs: me)
        check(!choices.contains { $0.app.id.hasPrefix("com.apple.") }, "Apple apps not offered")
        check(choices.contains { $0.app.id == "com.vendor.app" && $0.refusal == nil }, "Vendor offered")
        check(choices.contains { $0.app.id == "io.github.laimis91.appmonitor" && $0.refusal != nil }, "App Monitor shown as refused")

        for d in ["Caches", "Application Support", "Logs"] { file(L + "/\(d)/com.vendor.app/x") }
        file(L + "/Caches/com.vendor.app.widget/x")
        file(L + "/Caches/com.vendor.login/x")
        file(L + "/Caches/com.vendor.app.pro/x")
        file(L + "/Caches/org.sparkle-project.Updater/x")
        file(L + "/Caches/com.vendor.apps/x")
        file(L + "/Containers/com.vendor.app.widget/Data/x")
        (["MCMMetadataIdentifier": "com.vendor.app.widget"] as NSDictionary).write(toFile: L + "/Containers/com.vendor.app.widget/.com.apple.containermanagerd.metadata.plist", atomically: true)
        file(L + "/Containers/com.vendor.app/Data/x")    // no metadata: not matched
        file(L + "/Group Containers/group.com.vendor.app/x")
        file(L + "/Group Containers/TEAMID1234.shared/x")
        file(L + "/Application Support/com.vendor.app.tool/Tool.app/Contents/MacOS/t")
        try? fm.createDirectory(atPath: L + "/LaunchAgents", withIntermediateDirectories: true)
        (["Label": "com.vendor.app.agent"] as NSDictionary).write(toFile: L + "/LaunchAgents/agent.plist", atomically: true)
        (["Label": "com.vendor.app.pro.agent"] as NSDictionary).write(toFile: L + "/LaunchAgents/com.vendor.app.x.plist", atomically: true)
        try? fm.createSymbolicLink(atPath: L + "/Caches/com.vendor.app.link", withDestinationPath: r.home)
        file(L + "/Caches/com.vendor.app.ignored/x")
        file(r.library + "/LaunchDaemons/com.vendor.app.daemon.plist")
        for n in ["VendorHelper.plist", "Helper.plist", "Locked.plist", "VendorHelperX.plist"] { file(L + "/Preferences/" + n) }
        file(L + "/HTTPStorages/VendorHelper.binarycookies")
        file(L + "/Logs/CrashReporter/x")
        file(L + "/Preferences/ByHost/com.vendor.app.0A1B2C3D-0000-1111-2222-333344445555.plist")
        file(L + "/Preferences/ByHost/com.other.app.0A1B2C3D-0000-1111-2222-333344445555.plist")
        let recent = "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
        file(L + "/" + recent + "/com.vendor.app.sfl4")
        file(L + "/" + recent + "/com.other.app.sfl4")
        file(L + "/Application Scripts/group.com.vendor.app/x")
        file(L + "/Application Scripts/TEAMID1234.shared/x")
        file(L + "/Application Scripts/group.com.other.app/x")

        var probes = UninstallProbes()
        probes.groups = { p in
            if p.hasSuffix("/Vendor.app") { return ["group.com.vendor.app", "teamid1234.shared"] }
            if p.hasSuffix("/Vendor Pro.app") { return ["teamid1234.shared"] }
            return []
        }
        probes.processesInside = { _ in [] }
        func ctx(fda: FDAStatus = .granted, running: [RunningApp] = []) -> ScanContext {
            ScanContext(roots: r, limits: AgeLimits(), fda: fda, ignore: [(L + "/Caches/com.vendor.app.ignored").lowercased()],
                        inventory: AppInventory(roots: r, lookup: nil, running: { running }), running: running,
                        tools: ToolLocator(places: [:], xcodeSelectOK: true), cancel: CancelFlag(), now: Date())
        }
        guard let plan = Uninstaller.plan(A + "/Vendor.app", ctx: ctx(), probes: probes) else { check(false, "plan"); return }
        eq(plan.target.ids.first, "com.vendor.app", "target IDs start with the app's")
        eq(Set(plan.target.ids), ["com.vendor.app", "com.vendor.login", "com.vendor.app.widget", "vendorhelper"],
           "target IDs: library XPC, generic, unrelated and other-app-named plain IDs left out")
        let items = Dictionary(uniqueKeysWithValues: plan.categories.flatMap(\.items).map { ($0.path.replacingOccurrences(of: root + "/", with: ""), $0) })
        let H = "home/Library/"
        eq(Set(items.keys), Set(["Applications/Vendor.app", H + "Caches/com.vendor.app", H + "Application Support/com.vendor.app",
                                 H + "Logs/com.vendor.app", H + "Caches/com.vendor.app.widget", H + "Caches/com.vendor.login",
                                 H + "Containers/com.vendor.app.widget", H + "Group Containers/group.com.vendor.app",
                                 H + "Group Containers/TEAMID1234.shared", H + "Application Support/com.vendor.app.tool",
                                 H + "LaunchAgents/agent.plist", "Library/LaunchDaemons/com.vendor.app.daemon.plist",
                                 H + "Preferences/VendorHelper.plist", H + "HTTPStorages/VendorHelper.binarycookies",
                                 H + "Preferences/ByHost/com.vendor.app.0A1B2C3D-0000-1111-2222-333344445555.plist",
                                 H + recent + "/com.vendor.app.sfl4",
                                 H + "Application Scripts/group.com.vendor.app", H + "Application Scripts/TEAMID1234.shared"]), "related items")
        eq(items[H + "Preferences/ByHost/com.vendor.app.0A1B2C3D-0000-1111-2222-333344445555.plist"]?.preselected, true, "per-computer settings pre-selected")
        eq(items[H + recent + "/com.vendor.app.sfl4"]?.risk, .safe, "recent documents list Safe")
        eq(items[H + "Application Scripts/group.com.vendor.app"]?.preselected, false, "app-group scripts folder not pre-selected")
        eq(items[H + "Application Scripts/TEAMID1234.shared"]?.risk, .info, "app-group scripts folder shared with another app: Info")
        check(items[H + "Preferences/VendorHelper.plist"]?.reason.contains("a helper inside Vendor") == true, "plain helper ID reason")
        let gd = PathGuard(roots: r)
        for p in [H + "Preferences/ByHost/com.vendor.app.0A1B2C3D-0000-1111-2222-333344445555.plist", H + recent + "/com.vendor.app.sfl4"] {
            guard let it = items[p], case .rule(let rr) = it.scope else { check(false, "rule scope \(p)"); continue }
            eq(gd.check(it.path, allowRoot: rr), nil, "guard allows \(p)")
        }
        let bundle = items["Applications/Vendor.app"]
        check(bundle?.appBundle == true && bundle?.risk == .requested && bundle?.preselected == true, "bundle Requested, pre-selected")
        eq(bundle?.scope, .appBundle(root: Roots.canonical(A)), "bundle's allow root is Applications")
        eq(items[H + "Application Support/com.vendor.app"]?.preselected, true, "app data pre-selected")
        eq(items[H + "Application Support/com.vendor.app"]?.risk, .review, "app data Review")
        eq(items[H + "Group Containers/group.com.vendor.app"]?.preselected, false, "group container not pre-selected")
        eq(items[H + "Group Containers/TEAMID1234.shared"]?.risk, .info, "group claimed by another app: Info")
        check(items[H + "Group Containers/TEAMID1234.shared"]?.reason.contains("Shared with Vendor Pro") == true, "shared reason")
        eq(items[H + "Application Support/com.vendor.app.tool"]?.risk, .info, "item holding an app: Info")
        eq(items["Library/LaunchDaemons/com.vendor.app.daemon.plist"]?.risk, .info, "/Library: Info")
        check(plan.categories.flatMap(\.items).allSatisfy { $0.ageLimitDays == nil }, "no age limits")

        let noFDA = Uninstaller.plan(A + "/Vendor.app", ctx: ctx(fda: .denied), probes: probes)
        check(noFDA?.categories.contains { $0.id == Uninstaller.fdaID } == true, "no FDA: notice")
        check(noFDA?.categories.flatMap(\.items).contains { $0.path.contains("Containers/") } == false, "no FDA: containers not entered")
        check(noFDA?.categories.flatMap(\.items).contains { $0.path.hasSuffix(".sfl4") } == false, "no FDA: recent documents not entered")
        let busy = Uninstaller.plan(A + "/Vendor.app", ctx: ctx(running: [RunningApp(id: "com.vendor.login", name: "Login")]), probes: probes)
        eq(busy?.target.running, ["Login"], "running helper found")
        eq(busy?.target.runningByID, true, "found by bundle ID: Quit offered")
        let byName = Uninstaller.plan(A + "/Vendor.app", ctx: ctx(running: [RunningApp(id: "org.unrelated.vendor", name: "Vendor")]), probes: probes)
        eq(byName?.target.running, ["Vendor"], "f-1: running by name alone blocks")
        eq(byName?.target.runningByID, false, "f-1: but Quit isn't offered")
        check(busy?.categories.flatMap(\.items).allSatisfy { !$0.preselected } == true, "running: nothing pre-selected")
        var inside = probes; inside.processesInside = { _ in ["tool"] }
        eq(Uninstaller.plan(A + "/Vendor.app", ctx: ctx(), probes: inside)?.target.running, ["tool"], "process inside the bundle counts")
        let pro = Uninstaller.plan(A + "/Sub/Vendor Pro.app", ctx: ctx(), probes: probes)
        check(pro?.categories.flatMap(\.items).contains { $0.path.hasSuffix("/Caches/com.vendor.app") } == false, "Pro: base app's data not listed")
        check(pro?.categories.flatMap(\.items).contains { $0.path.hasSuffix("/LaunchAgents/com.vendor.app.x.plist") } == true, "Pro: agent by label")

        // Path guard: app bundles only through the app roots, and only with the bundle flag (6.4).
        let g = PathGuard(roots: r)
        eq(g.check(A + "/Vendor.app", allowRoot: A, appBundle: true), nil, "bundle allowed in Applications")
        eq(g.check(A + "/Sub/Vendor Pro.app", allowRoot: A, appBundle: true), nil, "bundle in a subfolder allowed")
        check(g.check(A + "/Vendor.app", allowRoot: A) != nil, "Applications isn't a rule root")
        check(g.check(A + "/Sub", allowRoot: A, appBundle: true) != nil, "only .app folders")
        check(g.check(A, allowRoot: A, appBundle: true) != nil, "Applications itself denied")
        check(g.check(L + "/Caches/com.vendor.app", allowRoot: A, appBundle: true) != nil, "data outside Applications")
        check(g.check(L + "/Caches/com.vendor.app", allowRoot: L + "/Caches", appBundle: true) != nil, "bundle flag needs an app root")
        check(g.check(r.systemApplications + "/Sys.app", allowRoot: r.systemApplications, appBundle: true) != nil, "System/Applications denied")
        check(g.check(A + "/Vendor.app/Contents/Library/LoginItems/Login.app", allowRoot: A, appBundle: true) != nil, "un-1: guard denies a bundle inside a bundle")
        app(A + "/Tools.bundle/Kept.app", "com.fixture.kept", "Kept")
        eq(g.check(A + "/Tools.bundle/Kept.app", allowRoot: A, appBundle: true), "Part of another app", "f-2: a bundle folder inside Applications still counts")
        // E7: the guard itself refuses apps that come with macOS, and bundles whose ID can't be read.
        eq(g.check(A + "/Fake.app", allowRoot: A, appBundle: true), "Apps that come with macOS can't be removed", "e7: com.apple. bundle refused by the guard")
        app(A + "/Upper.app", "COM.Apple.upper", "Upper")
        eq(g.check(A + "/Upper.app", allowRoot: A, appBundle: true), "Apps that come with macOS can't be removed", "e7: without case")
        eq(g.check(A + "/NotApp.app", allowRoot: A, appBundle: true), "The app's bundle ID can't be read", "e7: no Info.plist refused")
        file(A + "/NoID.app/Contents/MacOS/x")
        (["CFBundleName": "NoID"] as NSDictionary).write(toFile: A + "/NoID.app/Contents/Info.plist", atomically: true)
        eq(g.check(A + "/NoID.app", allowRoot: A, appBundle: true), "The app's bundle ID can't be read", "e7: no bundle ID refused")
        eq(g.check(A + "/Link.app", allowRoot: A, appBundle: true), "Not an app", "e7: a link named .app refused")
        try? fm.createDirectory(atPath: A + "/Linked.app", withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: A + "/Linked.app/Contents", withDestinationPath: A + "/Vendor.app/Contents")
        eq(g.check(A + "/Linked.app", allowRoot: A, appBundle: true), "The app's bundle ID can't be read", "e7: a linked Contents folder refused")
        try? fm.removeItem(atPath: A + "/Linked.app")

        // un-3, un-6: at action time a process inside the bundle skips every uninstaller item, not only the bundle.
        guard let fresh = Uninstaller.plan(A + "/Vendor.app", ctx: ctx(), probes: probes) else { check(false, "plan again"); return }
        let movable = fresh.categories.flatMap { c in c.items.filter(\.selectable).map { (c, $0) } }
        check(movable.allSatisfy { $0.1.insideBundle == Uninstaller.located(A + "/Vendor.app") }, "every item knows its bundle")
        let inv = AppInventory(roots: r, lookup: nil, running: { [] })
        var env = CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] }, inventory: inv, roots: r, dryRun: true, now: Date.init)
        env.processesInside = { _ in ["tool"] }
        let busyOut = Cleaner.clean(movable, env: env)
        check(!busyOut.isEmpty && busyOut.allSatisfy { $0.status == .skipped && $0.reason == "tool is running from inside the app" },
              "process inside the bundle: everything skipped")
        env.processesInside = { _ in [] }
        let idle = Cleaner.clean(movable, env: env)
        check(!idle.isEmpty && idle.allSatisfy { $0.status == .planned }, "nothing running: everything planned")
    }

    // MARK: Review fixes

    /// E2: the open-file lookup finds a path equal to the item or inside it, component-wise and
    /// without case, never a sibling that only shares a prefix.
    static func openFiles() {
        let o = OpenFiles([("/a/b-c/x", "dash"), ("/a/b.d", "dot"), ("/a/bc", "longer"), ("/A/B/Inner/f", "inner"),
                           ("/a/b/inner/f", "dup"), ("/q/r", "exact"), ("/q/r", "again"), ("/z/Ünï/f", "unicode")])
        eq(o.count, 6, "duplicate paths kept once (case-insensitive)")
        eq(o.user(of: "/a/b"), "inner", "inside, case-insensitive, first process kept")
        eq(o.user(of: "/A/B/INNER"), "inner", "inside a deeper folder")
        eq(o.user(of: "/a/b/inner/f"), "inner", "the open file itself")
        eq(o.user(of: "/q/r"), "exact", "equal path")
        eq(o.user(of: "/Q/R"), "exact", "equal path without case")
        eq(o.user(of: "/a/bc"), "longer", "equal path among siblings")
        eq(o.user(of: "/a/b-c"), "dash", "a folder that sorts between siblings")
        eq(o.user(of: "/a/b-"), nil, "a prefix of a name is not a folder")
        eq(o.user(of: "/a/b/inner/f/g"), nil, "below an open file is nothing")
        eq(o.user(of: "/q"), "exact", "parent of an open file")
        eq(o.user(of: "/q/r2"), nil, "sibling sharing a prefix")
        eq(o.user(of: "/a/bcd"), nil, "longer sibling")
        eq(o.user(of: "/z/ünï"), "unicode", "non-ASCII without case")
        eq(o.user(of: "/z/u\u{0308}n\u{0131}"), nil, "different letters are different")
        eq(o.user(of: "/z/u\u{0308}ni\u{0308}"), "unicode", "decomposed form matches")
        eq(OpenFiles([]).user(of: "/a"), nil, "empty snapshot")
        // the real snapshot sees this process's own open file
        let p = NSTemporaryDirectory() + "appmon-open-\(getpid())"
        FileManager.default.createFile(atPath: p, contents: Data([1]))
        defer { try? FileManager.default.removeItem(atPath: p) }
        if let h = FileHandle(forReadingAtPath: p) {
            check(OpenFiles.snapshot()?.user(of: Roots.canonical(p)) != nil, "snapshot finds an open file")
            try? h.close()
        }
    }

    /// E3: one guard scope per item. Rows without a guard, or with an empty root, are refused at
    /// action time with a reason; a Space-map pick never uses the rule guard, and the reverse.
    static func guardScopes() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-scope-\(getpid())"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        guard let r = Roots.fixture(root) else { check(false, "scope fixture"); return }
        let caches = r.h("Library/Caches")
        try? fm.createDirectory(atPath: caches + "/com.x.y", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: r.h("Projects/site"), withIntermediateDirectories: true)
        let inv = AppInventory(roots: r, lookup: nil, running: { [] })
        var env = CleanEnvironment(guardian: PathGuard(roots: r), runningNow: { [] }, inventory: inv, roots: r,
                                   dryRun: true, now: Date.init)
        func item(_ p: String, _ s: GuardScope) -> CleanItem {
            CleanItem(path: p, name: "x", size: 1, newest: nil, risk: .safe, method: .trash, reason: "",
                      scope: s, fileID: ScanEngine.fileID(p) ?? [])
        }
        let cache = caches + "/com.x.y", site = r.h("Projects/site")
        eq(Cleaner.lastChecks(item(cache, .rule(root: caches)), env), nil, "rule scope checked by the path guard")
        eq(Cleaner.lastChecks(item(cache, .none), env), "Nothing may be moved from this row", "no scope: refused")
        eq(Cleaner.lastChecks(item(cache, .rule(root: "")), env), "No rule folder for this item", "empty rule root refused")
        eq(Cleaner.lastChecks(item(cache, .appBundle(root: "")), env), "No app folder for this item", "empty app root refused")
        check(Cleaner.lastChecks(item(cache, .appBundle(root: caches)), env) != nil, "a rule root is no app root")
        eq(Cleaner.lastChecks(item(site, .spaceMap), env), "No Space-map guard", "Space-map pick needs the Space-map guard")
        check(Cleaner.lastChecks(item(site, .rule(root: r.home)), env) != nil, "a Space-map path fails the rule guard")
        env.spaceGuard = SpaceGuard(roots: r)
        eq(Cleaner.lastChecks(item(site, .spaceMap), env), nil, "Space-map pick passes the Space-map guard")
        check(Cleaner.lastChecks(item(cache, .spaceMap), env) != nil, "~/Library refused for a Space-map pick")
        let cat = Category(id: "X", title: "", group: .general, method: .trash, explanation: "", items: [])
        eq(Cleaner.clean([(cat, item(cache, .none))], env: env).first?.reason, "Nothing may be moved from this row",
           "clean refuses a trash row without a guard before measuring")
        check(item(site, .spaceMap).spaceMap && !item(site, .spaceMap).appBundle, "Space-map flag from the scope")
        check(item(site, .appBundle(root: r.applications)).appBundle && !item(site, .appBundle(root: r.applications)).spaceMap,
              "app-bundle flag from the scope")
        check(!item(site, .rule(root: caches)).spaceMap && !item(site, .rule(root: caches)).appBundle, "rule scope sets neither flag")
    }

    /// E12: an embedded bundle ID owner is the longest matching embedded ID, not the first found.
    static func embeddedOwner() {
        let fm = FileManager.default
        let root = "/private/tmp/appmon-fixture-selftest-emb-\(getpid())"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        guard let r = Roots.fixture(root) else { check(false, "embedded fixture"); return }
        func bundle(_ path: String, _ id: String, _ name: String) {
            try? fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
            (["CFBundleIdentifier": id, "CFBundleName": name] as NSDictionary).write(toFile: path + "/Contents/Info.plist", atomically: true)
        }
        bundle(r.applications + "/A.app", "com.a.app", "A")
        bundle(r.applications + "/A.app/Contents/PlugIns/S.appex", "com.x.suite", "S")
        bundle(r.applications + "/B.app", "com.b.app", "B")
        bundle(r.applications + "/B.app/Contents/PlugIns/H.appex", "com.x.suite.helper", "H")
        let inv = AppInventory(roots: r, lookup: nil, running: { [] })
        eq(inv.owner(of: "com.x.suite.helper.cache")?.name, "B", "longest embedded ID wins")
        eq(inv.owner(of: "com.x.suite.other")?.name, "A", "shorter embedded ID when only it matches")
        eq(inv.owner(of: "com.x.suite.helper")?.name, "B", "exact embedded ID")
    }

    /// E8: after an unclear Finder answer, only the same file found in the Trash counts as moved.
    static func trashLookup() {
        let names = ["report.txt", "report 2.txt", "report 10.32.16.txt", "reports.txt", "report.txt.old",
                     "com.vendor.app 3", "data"]
        eq(TrashLookup.candidates("report.txt", in: names), ["report.txt", "report 10.32.16.txt", "report 2.txt"],
           "plain name first, then Finder's unique names")
        eq(TrashLookup.candidates("com.vendor.app", in: names), ["com.vendor.app", "com.vendor.app 3"], "folder named by bundle ID")
        eq(TrashLookup.candidates("data", in: names), ["data"], "no other candidates")
        let fm = FileManager.default
        let t = NSTemporaryDirectory() + "appmon-trash-\(getpid())"
        try? fm.createDirectory(atPath: t + "/src", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: t) }
        fm.createFile(atPath: t + "/src/report.txt", contents: Data([1]))
        let id = ScanEngine.fileID(t + "/src/report.txt") ?? []
        try? fm.moveItem(atPath: t + "/src/report.txt", toPath: t + "/report 2.txt")
        fm.createFile(atPath: t + "/report.txt", contents: Data([2]))       // another file with the same name
        check(TrashLookup.found("report.txt", fileID: id, trash: t), "the same file under a unique name")
        check(!TrashLookup.found("report.txt", fileID: ScanEngine.fileID(t + "/src") ?? [], trash: t), "another file isn't it")
        check(!TrashLookup.found("report.txt", fileID: [], trash: t), "unknown file ID never found")
        check(!TrashLookup.found("report.txt", fileID: id, trash: t + "/missing"), "no Trash, not found")
    }
}

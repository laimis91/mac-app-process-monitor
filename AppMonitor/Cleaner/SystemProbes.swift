// AppKit-backed probes and the cleaner's run configuration (real Mac, or a fixture tree in
// debug builds).

import AppKit

enum CleanerConfig {
    static let env = ProcessInfo.processInfo.environment

    /// The fixture root when fixture mode is on (debug builds only). Exits if it is unsafe.
    static let fixtureRoot: String? = {
        #if APPMON_DEBUG
        guard let root = env["APPMON_SCAN_ROOT"] else { return nil }
        guard Roots.fixture(root) != nil else {
            FileHandle.standardError.write("APPMON_SCAN_ROOT must be a folder under /private/tmp/appmon-fixture-\n".data(using: .utf8)!)
            exit(2)
        }
        return Roots.canonical(root)
        #else
        return nil
        #endif
    }()

    static var roots: Roots { fixtureRoot.flatMap(Roots.fixture) ?? Roots.real() }

    /// Dry run: log instead of acting. Fixture mode implies it unless APPMON_FIXTURE_ACT=1.
    static var dryRun: Bool {
        if env["APPMON_DRY_RUN"] == "1" { return true }
        if fixtureRoot != nil { return env["APPMON_FIXTURE_ACT"] != "1" }
        return false
    }

    static func fda(_ roots: Roots) -> FDAStatus {
        if fixtureRoot != nil { return FDAStatus(rawValue: env["APPMON_FIXTURE_FDA"] ?? "granted") ?? .granted }
        return Permissions.detect(home: roots.home)
    }

    static func runningApps() -> [RunningApp] {
        if let r = fixtureRoot { return FixtureRunning.read(r) }
        return NSWorkspace.shared.runningApplications.compactMap { a in
            guard let id = a.bundleIdentifier else { return nil }
            return RunningApp(id: id, name: a.localizedName ?? id)
        }
    }

    static func inventory(_ roots: Roots) -> AppInventory {
        if fixtureRoot != nil {
            return AppInventory(roots: roots, lookup: nil, running: runningApps)
        }
        return AppInventory(roots: roots, lookup: { id in
            // Probe 1: LaunchServices remembers apps outside the usual folders too.
            guard let url = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).first else { return nil }
            return AppInventory.info(url.path) ?? AppInfo(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path)
        }, running: runningApps)
    }

    static func tools(_ roots: Roots) -> ToolLocator {
        ToolLocator(dirs: roots.toolDirs, xcodeSelectOK: roots.fixture ? true : ToolLocator.commandLineToolsInstalled())
    }

    static func context(limits: AgeLimits, ignore: [String], cancel: CancelFlag) -> ScanContext {
        let r = roots
        let inv = inventory(r)
        return ScanContext(roots: r, limits: limits, fda: fda(r), ignore: Set(ignore.map { $0.lowercased() }),
                           inventory: inv, running: inv.running(), tools: tools(r), cancel: cancel, now: Date())
    }

    static func cleanEnvironment(_ ctx: ScanContext) -> CleanEnvironment {
        CleanEnvironment(guardian: PathGuard(roots: ctx.roots), runningNow: ctx.inventory.running,
                         inventory: ctx.inventory, roots: ctx.roots, dryRun: dryRun, now: Date.init,
                         prepareTrash: FinderTrash.prepare)
    }
}

extension CleanerConfig {
    /// Cleaning one item picked in the Space map: the Space-map guard instead of the rule roots.
    static func spaceEnvironment(_ roots: Roots, _ inv: AppInventory) -> CleanEnvironment {
        var env = CleanEnvironment(guardian: PathGuard(roots: roots), runningNow: inv.running, inventory: inv,
                                   roots: roots, dryRun: dryRun, now: Date.init, prepareTrash: FinderTrash.prepare)
        env.spaceGuard = SpaceGuard(roots: roots)
        return env
    }
}

/// Moves items to the Trash through Finder, so Finder's Put Back returns them where they were.
/// The Apple event is built from file URLs (no script text). macOS asks once whether App Monitor
/// may control Finder. If that's declined or Finder isn't running, items are moved with
/// FileManager instead, without Put Back.
enum FinderTrash {
    /// Asks for permission to control Finder (macOS shows its prompt once), then picks the mover.
    /// Runs before any item is checked, so waiting for the user never makes a check stale.
    static func prepare() -> ([String]) -> [String: TrashResult] {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(finder.aeDesc, AEEventClass(kAECoreSuite),
                                                           AEEventID(kAEDelete), true)
        return status == noErr ? move : Cleaner.trashWithFileManager
    }

    /// Items gone after Finder answered without an error were moved by Finder. If Finder reported
    /// an error, nothing is counted as moved: an item may have vanished for another reason.
    /// Errors that hit the whole request rather than one item: no point retrying item by item.
    /// (-1728 "no such object" is left out: it usually means one item vanished.)
    static let wholeRequest: Set<Int32> = [-1712, -128, -600, -609, -1743, -1744, -1708, -10661]

    static func move(_ paths: [String]) -> [String: TrashResult] {
        let code = send(paths)
        var r: [String: TrashResult] = [:]
        for p in paths {
            let gone = ScanEngine.lstatInfo(p) == nil
            if let c = code, wholeRequest.contains(c) {
                let why = c == -1712 ? "Finder didn't answer in time" : c == -128 ? "Cancelled in Finder"
                    : "Finder couldn't be used (error \(c))"
                r[p] = .failedAll(gone ? why + "; check the Trash" : why)
            } else if let c = code {
                r[p] = .failed(gone ? "Finder reported error \(c); check the Trash" : "Finder couldn't move it (error \(c))")
            } else {
                r[p] = gone ? .moved(putBack: true) : .failed("Finder didn't move it")
            }
        }
        return r
    }

    /// Sends Finder a "delete" event for the files. Returns an error code, or nil on success.
    static func send(_ paths: [String]) -> Int32? {
        let list = NSAppleEventDescriptor.list()
        for (i, p) in paths.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: p)), at: i + 1)
        }
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kAECoreSuite),
                                                      eventID: AEEventID(kAEDelete), targetDescriptor: finder,
                                                      returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(list, forKeyword: keyDirectObject)
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 120)
            if let e = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, e != 0 { return e }
            return nil
        } catch {
            return Int32((error as NSError).code)
        }
    }

}

// Path guard (spec 6.4): every path is checked right before anything is done to it.
// Foundation only.

import Foundation

struct PathGuard {
    struct Deny { let path: [String]; let except: [[String]] }

    let allowRoots: [[String]]
    let appRoots: [[String]]        // uninstaller only: app bundles in /Applications and ~/Applications
    let deny: [Deny]
    let denyExact: [[String]]       // denied as the folder itself only

    static func comps(_ p: String) -> [String] {
        p.split(separator: "/", omittingEmptySubsequences: true).map { $0.lowercased() }
    }
    /// `p` equals `root` or lies inside it, compared component by component, without case.
    static func within(_ p: [String], _ root: [String]) -> Bool {
        p.count >= root.count && Array(p.prefix(root.count)) == root
    }
    /// A folder name that marks a bundle (an app, or a part of one).
    static func isBundleName(_ c: String) -> Bool {
        [".app", ".appex", ".xpc", ".bundle", ".framework", ".plugin"].contains { c.lowercased().hasSuffix($0) }
    }
    static func strictlyInside(_ p: [String], _ root: [String]) -> Bool {
        p.count > root.count && within(p, root)
    }

    init(roots r: Roots) {
        let c: (String) -> [String] = { Self.comps(Roots.canonical($0)) }
        let h = r.home
        let allow = [
            "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
            "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies",
            "Library/Containers", "Library/Group Containers", "Library/Application Scripts",
            "Library/LaunchAgents", "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/iOS DeviceSupport", "Library/Mail Downloads",
        ].map { r.h($0) } + [r.temp]
        allowRoots = allow.map(c)
        appRoots = [r.applications, r.h("Applications")].map(c)

        let homeC = c(h)
        var d = Self.systemDeny(r)
        let homeDeny = [
            "Library/Keychains", ".ssh", ".gnupg", "Library/Mobile Documents", "Library/CloudStorage",
            "Library/Mail", "Library/Safari", "Library/Messages", "Library/Photos",
            "Library/Application Support/MobileSync", "Library/Application Support/AddressBook",
            "Library/Application Support/CallHistoryDB", "Library/Application Support/Knowledge",
            "Library/Application Support/FileProvider",
            "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", ".Trash",
        ]
        d += homeDeny.map { Deny(path: c(r.h($0)), except: []) }
        if r.fixture {   // fixture trees also map the system roots
            d += [r.systemApplications].map { Deny(path: c($0), except: []) }
        }
        deny = d
        denyExact = [homeC, c(r.h("Library"))] + allowRoots + appRoots
    }

    /// The S4 list: system locations and other users' homes. Shared with the Space-map guard.
    static func systemDeny(_ r: Roots) -> [Deny] {
        let c: (String) -> [String] = { Self.comps(Roots.canonical($0)) }
        return [
            Deny(path: c("/System"), except: []),
            Deny(path: c("/usr"), except: [c("/usr/local")]),
            Deny(path: c("/bin"), except: []),
            Deny(path: c("/sbin"), except: []),
            Deny(path: c("/private/var"), except: [c(r.temp)]),
            Deny(path: c("/Users"), except: [c(r.home)]),   // other users' homes
        ]
    }

    /// Checks the parts every guard shares: an absolute, plain path whose parent folder has no
    /// symbolic link in it, and an item that still exists. Returns the item's canonical
    /// components (lowercased), its parent's canonical path, and its lstat, or the reason.
    static func locate(_ path: String) -> Result<(item: [String], parent: String, st: stat), Refusal> {
        guard path.hasPrefix("/") else { return .failure(Refusal("Not an absolute path")) }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !path.contains("/../"), !path.contains("/./")
        else { return .failure(Refusal("Unusual path")) }
        let parent = url.deletingLastPathComponent().path
        guard let rp = realpath(parent, nil) else { return .failure(Refusal("Folder no longer exists")) }
        let canonParent = String(cString: rp); free(rp)
        // The scanner builds paths from canonical roots, so a changed parent means a symlink appeared.
        guard comps(canonParent) == comps(parent) else { return .failure(Refusal("A folder in its path is a symbolic link")) }
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(Refusal("No longer exists")) }
        return .success((comps(canonParent) + [name.lowercased()], canonParent, st))
    }

    struct Refusal: Error { let reason: String; init(_ r: String) { reason = r } }

    /// Returns nil when `path` may be acted on under `allowRoot`, otherwise the reason it may not.
    /// Only the parent folder is resolved; the item itself is judged where it sits (S12).
    /// The app roots take only app bundles the uninstaller picked (`appBundle`), and those take
    /// nothing else. An app bundle that comes with macOS (com.apple.*) is refused here too.
    func check(_ path: String, allowRoot: String, appBundle: Bool = false) -> String? {
        let item: [String], st: stat
        switch Self.locate(path) {
        case .failure(let r): return r.reason
        case .success(let l): item = l.item; st = l.st
        }
        for e in denyExact where item == e { return "Protected folder" }
        for e in deny where Self.within(item, e.path) && !e.except.contains(where: { Self.within(item, $0) }) {
            return "Protected location"
        }
        let rootC = Self.comps(Roots.canonical(allowRoot))
        if appBundle {
            guard appRoots.contains(rootC) else { return "Not an allowed location" }
            guard item.last?.hasSuffix(".app") == true else { return "Not an app" }
        } else {
            guard allowRoots.contains(rootC) else { return "Not an allowed location" }
        }
        guard Self.strictlyInside(item, rootC) else { return "Outside its rule's folder" }
        // Only the folders between the app root and the bundle: none may be a bundle itself.
        if appBundle, item[rootC.count..<(item.count - 1)].contains(where: Self.isBundleName) { return "Part of another app" }
        if appBundle, let why = Self.appBundleRefusal(path, st) { return why }
        return nil
    }

    /// Apps that come with macOS are never moved, wherever they sit: the bundle must be a real
    /// folder (not a link) whose own Info.plist names a bundle ID outside com.apple. An ID that
    /// can't be read refuses the bundle (S5).
    static func appBundleRefusal(_ path: String, _ st: stat) -> String? {
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return "Not an app" }
        var cst = stat()
        guard lstat(path + "/Contents", &cst) == 0, (cst.st_mode & S_IFMT) == S_IFDIR,
              let id = AppInventory.infoPlist(path)?["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return "The app's bundle ID can't be read" }
        if id.lowercased().hasPrefix("com.apple.") { return "Apps that come with macOS can't be removed" }
        return nil
    }
}

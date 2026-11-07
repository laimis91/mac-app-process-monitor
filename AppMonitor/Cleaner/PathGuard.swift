// Path guard (spec 6.4): every path is checked right before anything is done to it.
// Foundation only.

import Foundation

struct PathGuard {
    struct Deny { let path: [String]; let except: [[String]] }

    let allowRoots: [[String]]
    let deny: [Deny]
    let denyExact: [[String]]       // denied as the folder itself only

    static func comps(_ p: String) -> [String] {
        p.split(separator: "/", omittingEmptySubsequences: true).map { $0.lowercased() }
    }
    /// `p` equals `root` or lies inside it, compared component by component, without case.
    static func within(_ p: [String], _ root: [String]) -> Bool {
        p.count >= root.count && Array(p.prefix(root.count)) == root
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

        let tempC = c(r.temp)
        let homeC = c(h)
        var d: [Deny] = [
            Deny(path: c("/System"), except: []),
            Deny(path: c("/usr"), except: [c("/usr/local")]),
            Deny(path: c("/bin"), except: []),
            Deny(path: c("/sbin"), except: []),
            Deny(path: c("/private/var"), except: [tempC]),
            Deny(path: c("/Users"), except: [homeC]),   // other users' homes
        ]
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
        denyExact = [homeC, c(r.h("Library"))] + allowRoots
    }

    /// Returns nil when `path` may be acted on under `allowRoot`, otherwise the reason it may not.
    /// Only the parent folder is resolved; the item itself is judged where it sits (S12).
    func check(_ path: String, allowRoot: String) -> String? {
        guard path.hasPrefix("/") else { return "Not an absolute path" }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !path.contains("/../"), !path.contains("/./")
        else { return "Unusual path" }
        let parent = url.deletingLastPathComponent().path
        guard let rp = realpath(parent, nil) else { return "Folder no longer exists" }
        let canonParent = String(cString: rp); free(rp)
        // The scanner builds paths from canonical roots, so a changed parent means a symlink appeared.
        guard Self.comps(canonParent) == Self.comps(parent) else { return "A folder in its path is a symbolic link" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "No longer exists" }

        let item = Self.comps(canonParent) + [name.lowercased()]
        for e in denyExact where item == e { return "Protected folder" }
        for e in deny where Self.within(item, e.path) && !e.except.contains(where: { Self.within(item, $0) }) {
            return "Protected location"
        }
        let rootC = Self.comps(Roots.canonical(allowRoot))
        guard allowRoots.contains(rootC) else { return "Not an allowed location" }
        guard Self.strictlyInside(item, rootC) else { return "Outside its rule's folder" }
        return nil
    }
}

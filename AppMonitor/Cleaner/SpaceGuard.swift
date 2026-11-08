// Space-map guard (spec 6.4). Foundation and Darwin only, so scripts/selftest.sh can compile it.

import Foundation

/// Decides whether an item the user picked in the Space map may be moved to the Trash.
/// The S4 list and the Keychains, ~/.ssh and ~/.gnupg denials of the main guard still apply.
struct SpaceGuard {
    let home: String                   // canonical
    let homeComps: [String]
    let homeDev: Int32?
    let uid: uid_t
    let deny: [PathGuard.Deny]
    var isPackage: (String) -> Bool = SpaceGuard.packageProbe
    var isSynced: (String) -> Bool = SpaceGuard.syncedProbe

    static let standardFolders: Set<String> = ["documents", "desktop", "downloads", "pictures", "movies", "music"]
    /// Third-party sync folders directly in the home folder (also "OneDrive - Company" and similar).
    static let syncFolders = ["dropbox", "google drive", "onedrive", "box", "pcloud drive"]

    init(roots: Roots) {
        home = Roots.canonical(roots.home)
        homeComps = PathGuard.comps(home)
        homeDev = ScanEngine.lstatInfo(home)?.st_dev
        uid = getuid()
        let c: (String) -> [String] = { PathGuard.comps(Roots.canonical($0)) }
        deny = PathGuard.systemDeny(roots)
            + [".ssh", ".gnupg", "Library/Keychains"].map { PathGuard.Deny(path: c(roots.h($0)), except: []) }
    }

    /// What is known about an item, from the disk (`check`) or from the scanned tree (`reason`).
    struct Facts {
        var rel: [String]              // names below the home folder, the item's own name last
        var ancestorPackage = false    // a folder it is inside is a package
        var synced = false             // it, or a folder it is inside, is cloud-synced
        var ownedByUser = true
        var sameVolume = true
    }

    static func isSyncFolder(_ name: String) -> Bool {
        let n = name.lowercased()
        return syncFolders.contains { n == $0 || n.hasPrefix($0 + " ") || n.hasPrefix($0 + "-") || n.hasPrefix($0 + " (") }
    }

    /// The rules that depend on where the item is and what it is. nil means it may be picked.
    static func rule(_ f: Facts) -> String? {
        let r = f.rel.map { $0.lowercased() }
        guard let first = r.first else { return "Your home folder itself can't be moved" }
        if first == "library" { return "Everything in ~/Library is Reveal only" }
        if r.count == 1 && standardFolders.contains(first) {
            return "A standard folder can't be moved. Items inside it can."
        }
        if first.hasPrefix(".") { return "Hidden folders in your home folder are Reveal only" }
        if r.contains(where: { $0.hasPrefix(".") }) {
            return "Hidden items, and items inside hidden folders (such as .git), are Reveal only. You can move the folder that holds them."
        }
        if r.contains(where: { $0.hasSuffix(".photoslibrary") }) { return "Photo libraries are never moved from here" }
        if r.contains(where: { $0.hasSuffix(".app") }) {
            return "Apps are removed with an uninstaller, not from the Space map"
        }
        if isSyncFolder(first) || f.synced { return "Synced item: remove it in Finder, because it would be deleted on every synced device" }
        if f.ancestorPackage { return "Inside a package. You can move the whole package." }
        if !f.ownedByUser { return "Not owned by you" }
        if !f.sameVolume { return "On another volume" }
        return nil
    }

    /// The full check, right before acting and before the confirmation: nil if the item may be
    /// moved, otherwise the reason. Only the parent folder is resolved; the item is judged where
    /// it sits (S12).
    func check(_ path: String) -> String? {
        let loc: (item: [String], parent: String, st: stat)
        switch PathGuard.locate(path) {
        case .failure(let r): return r.reason
        case .success(let l): loc = l
        }
        for e in deny where PathGuard.within(loc.item, e.path) && !e.except.contains(where: { PathGuard.within(loc.item, $0) }) {
            return "Protected location"
        }
        if loc.item == homeComps { return "Your home folder itself can't be moved" }
        guard PathGuard.strictlyInside(loc.item, homeComps) else { return "Outside your home folder: Reveal only" }
        // Names below home, in their real case, from the canonical parent.
        let parentNames = loc.parent.split(separator: "/").map(String.init)
        let rel = Array(parentNames.dropFirst(homeComps.count)) + [URL(fileURLWithPath: path).lastPathComponent]
        var f = Facts(rel: rel)
        if let quick = Self.rule(f) { return quick }    // decided by the path alone: no probes needed
        var dir = home
        for name in rel.dropLast() {
            dir += "/" + name
            if isPackage(dir) { f.ancestorPackage = true }
            if isSynced(dir) { f.synced = true }
        }
        if isSynced(path) { f.synced = true }
        f.ownedByUser = loc.st.st_uid == uid
        f.sameVolume = homeDev != nil && loc.st.st_dev == homeDev
        return Self.rule(f)
    }

    /// The same rules, from what the scan recorded (shown before the user picks an item).
    /// `home` is the home folder's top-level node.
    static func reason(for n: SpaceNode, home: SpaceNode?) -> String? {
        if n.flags.contains(.shell) && n.base != nil { return "This folder itself can't be moved" }
        var rel: [String] = []
        var f = Facts(rel: [])
        var x: SpaceNode? = n
        while let c = x, c !== home {
            if c.base != nil { return "Outside your home folder: Reveal only" }   // another top
            rel.insert(c.name, at: 0)
            if c !== n && c.flags.contains(.package) { f.ancestorPackage = true }
            if c.flags.contains(.synced) { f.synced = true }
            x = c.parent
        }
        guard x != nil else { return "Outside your home folder: Reveal only" }
        f.rel = rel
        f.ownedByUser = !n.flags.contains(.foreign)
        f.sameVolume = !n.flags.contains(.otherVolume)
        if let why = rule(f) { return why }
        if let b = n.blocker { return b }
        if n.note != nil || n.incomplete { return "Part of it couldn't be read, so it can't be moved as a whole" }
        return nil
    }

    // Probes. Doubt means keep (S5): an error counts as "package" and as "synced".
    static func packageProbe(_ path: String) -> Bool {
        do { return try URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage == true }
        catch { return true }
    }
    static func syncedProbe(_ path: String) -> Bool {
        do { return try URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true }
        catch { return true }
    }
}

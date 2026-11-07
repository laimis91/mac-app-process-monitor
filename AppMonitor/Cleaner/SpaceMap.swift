// Space map (spec 8): a tree of where space goes in the home folder and /Applications, and the
// Space-map guard (spec 6.4). Foundation and Darwin only, so scripts/selftest.sh can compile it.
//
// Sizes are measured like `du -kx`: allocated blocks of every entry (folders included), hard
// links counted once per scan, no symbolic links followed, one volume only.

import Foundation

// MARK: - Tree

/// One file or folder in the Space map. Only the scan thread touches a node until it is handed
/// over with `attach`; after that only the caller's thread (the main thread in the app) does.
final class SpaceNode: Identifiable, @unchecked Sendable {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let incomplete = Flags(rawValue: 1)    // part of it couldn't be read, or the scan stopped
        static let package = Flags(rawValue: 2)       // a package (isPackageKey), e.g. .fcpbundle
        static let synced = Flags(rawValue: 4)        // cloud-synced (isUbiquitousItemKey)
        static let foreign = Flags(rawValue: 8)       // owned by another user
        static let otherVolume = Flags(rawValue: 16)  // on another volume (a mount point)
        static let shell = Flags(rawValue: 32)        // filled by several scan jobs (a top or split folder)
    }

    static let largeSize: Int64 = 1 << 30            // "large": over 1 GB
    static let oldDays = 180                         // "old": unchanged for at least 180 days

    let name: String
    let isDir: Bool
    let dev: UInt64
    let ino: UInt64
    var base: String?                 // absolute path; set on top-level nodes only
    weak var parent: SpaceNode?
    var size: Int64 = 0               // allocated bytes, this item and everything inside
    var newest: Double = 0            // newest modification inside (seconds since 1970), 0 = unknown
    var items = 0                     // entries inside, at any depth
    var children: [SpaceNode] = []    // largest first
    var otherCount = 0                // direct children not listed one by one (small ones)
    var otherSize: Int64 = 0
    var flags: Flags = []
    var blocker: String?              // something always protected at or below this item (6.4)
    var owner: AppInfo?               // the app this folder belongs to, for its label
    var note: String?                 // e.g. "Needs Full Disk Access"

    init(name: String, isDir: Bool, dev: UInt64, ino: UInt64) {
        self.name = name; self.isDir = isDir; self.dev = dev; self.ino = ino
    }

    var path: String { base ?? ((parent?.path ?? "") + "/" + name) }
    var fileID: [UInt64] { [dev, ino] }
    var incomplete: Bool { flags.contains(.incomplete) }
    var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: newest) : nil }
    var hasContents: Bool { !children.isEmpty || otherCount > 0 }

    /// Over 1 GB and unchanged for at least 180 days (spec 8).
    func largeAndOld(now: Date) -> Bool {
        size > Self.largeSize && newest > 0 && now.timeIntervalSince1970 - newest >= Double(Self.oldDays) * 86_400
    }

    /// Adds a child's totals to this node only (used while building, bottom-up).
    fileprivate func absorb(_ c: SpaceNode) {
        size += c.size
        items += 1 + c.items
        newest = max(newest, c.newest)
        if c.incomplete { flags.insert(.incomplete) }
        if blocker == nil { blocker = c.blocker }
    }

    /// Hands a finished child to this node. Totals roll up through every parent, and every
    /// list stays largest first.
    func attach(_ c: SpaceNode) {
        c.parent = self
        children.insert(c, at: children.firstIndex { $0.size < c.size } ?? children.count)
        var n: SpaceNode? = self
        while let x = n {
            x.absorb(c)
            x.parent?.children.sort { $0.size > $1.size }
            n = x.parent
        }
    }

    /// Takes a child out after it was moved to the Trash. Dates and protections are left as
    /// they were (a re-scan refreshes them), which can only make the map more careful.
    func remove(_ c: SpaceNode) {
        children.removeAll { $0 === c }
        c.parent = nil
        var n: SpaceNode? = self
        while let x = n {
            x.size -= c.size
            x.items -= 1 + c.items
            x.parent?.children.sort { $0.size > $1.size }
            n = x.parent
        }
    }

    /// A synthetic root holding the top-level nodes (home folder, Applications).
    static func root() -> SpaceNode {
        let r = SpaceNode(name: "Space map", isDir: true, dev: 0, ino: 0)
        r.base = ""
        r.flags.insert(.shell)
        return r
    }
}

// MARK: - Scanner

struct SpaceOptions {
    var uid: uid_t = getuid()
    var dev: Int32? = nil                         // the volume being mapped; other volumes aren't entered
    var home: String = ""                         // canonical home folder (for "synced" probes)
    var listLimit = 100                           // children listed one by one per folder
    var listMin: Int64 = 1 << 20                  // folders under 1 MB don't list their contents
    var skip: (String) -> String? = { _ in nil }  // folder path → note, for folders not to enter
    var label: (String, String) -> AppInfo? = { _, _ in nil }   // (folder name, path) → owning app
    var isPackage: (String) -> Bool = SpaceGuard.packageProbe
    var isSynced: (String) -> Bool = SpaceGuard.syncedProbe
}

/// Entries seen so far, for progress text. Updated in steps of 1,024.
final class SpaceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var where_ = ""
    func add(_ k: Int, at path: String) { lock.lock(); n += k; where_ = path; lock.unlock() }
    var value: (Int, String) { lock.lock(); defer { lock.unlock() }; return (n, where_) }
}

enum SpaceScanner {
    static let syncedDepth = 2       // folders this deep below home are probed for iCloud sync

    /// A top-level node (or a folder whose children are scanned as separate jobs): the item's
    /// own size only. Its contents arrive later through `attach`.
    static func shell(_ path: String, title: String? = nil) -> SpaceNode {
        let st = ScanEngine.lstatInfo(path)
        let n = SpaceNode(name: title ?? URL(fileURLWithPath: path).lastPathComponent, isDir: true,
                          dev: st.map { UInt64(bitPattern: Int64($0.st_dev)) } ?? 0,
                          ino: st.map { UInt64($0.st_ino) } ?? 0)
        n.flags.insert(.shell)
        if let st {
            n.size = Int64(st.st_blocks) * 512
            n.newest = ScanEngine.mtime(st).timeIntervalSince1970
            if st.st_uid != getuid() { n.flags.insert(.foreign) }
        } else {
            n.note = "Not found"
        }
        return n
    }

    /// Every entry of a folder except "." and "..", without following links.
    static func list(_ dir: String) -> [String]? {
        guard let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    struct Top {
        let node: SpaceNode           // made with `shell`
        let path: String
        var split: Set<String> = []   // child folders whose own children are scanned as separate jobs
    }

    /// Scans the tops, up to 4 folders at a time. Every finished child is handed over with
    /// `attach(parent, child)`, one call at a time, from a worker thread. Returns false if the
    /// scan was stopped or a top couldn't be listed (then the `.shell` nodes are not complete).
    @discardableResult
    static func scan(_ tops: [Top], opts: SpaceOptions, links: LinkSet, cancel: CancelFlag, counter: SpaceCounter,
                     attach: @escaping (SpaceNode, SpaceNode) -> Void) -> Bool {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        let lock = NSLock()
        var complete = true
        func hand(_ parent: SpaceNode, _ child: SpaceNode) { lock.lock(); attach(parent, child); lock.unlock() }

        func enqueue(_ dir: String, into parent: SpaceNode, split: Set<String>, opts: SpaceOptions) {
            guard let names = list(dir) else { lock.lock(); complete = false; lock.unlock(); return }
            for name in names.sorted() {
                let p = dir + "/" + name
                guard let st = ScanEngine.lstatInfo(p) else { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                if isDir && split.contains(p) && opts.skip(p) == nil {
                    let mid = shell(p)
                    hand(parent, mid)
                    enqueue(p, into: mid, split: [], opts: opts)
                } else if isDir {
                    q.addOperation {
                        if cancel.isSet { lock.lock(); complete = false; lock.unlock(); return }
                        if let n = walk(p, opts: opts, links: links, cancel: cancel, counter: counter) { hand(parent, n) }
                    }
                } else if let n = walk(p, opts: opts, links: links, cancel: cancel, counter: counter) {
                    hand(parent, n)
                }
            }
        }
        for t in tops where t.node.note == nil {
            var o = opts
            o.dev = ScanEngine.lstatInfo(t.path)?.st_dev
            enqueue(t.path, into: t.node, split: t.split, opts: o)
        }
        q.waitUntilAllOperationsAreFinished()
        return complete && !cancel.isSet
    }

    private final class Frame {
        let node: SpaceNode
        let ent: UnsafeMutablePointer<FTSENT>
        let inPackage: Bool           // this folder or a parent is a package: no more probes below
        var kids: [SpaceNode] = []
        init(_ n: SpaceNode, _ e: UnsafeMutablePointer<FTSENT>, _ p: Bool) { node = n; ent = e; inPackage = p }
    }

    /// Builds the tree of one file or folder with a single fts walk.
    static func walk(_ path: String, opts: SpaceOptions, links: LinkSet, cancel: CancelFlag,
                     counter: SpaceCounter? = nil) -> SpaceNode? {
        // Never download cloud files or folders just to look at them (S11): a "dataless" item
        // reports an error instead of being fetched.
        let prevPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if prevPolicy >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, prevPolicy) }
        }

        let rootName = URL(fileURLWithPath: path).lastPathComponent
        let cpath = strdup(path)
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }

        var stack: [Frame] = []
        var result: SpaceNode?
        var rootDev: Int32 = 0
        var seen = 0
        let homePrefix = opts.home.isEmpty ? nil : opts.home + "/"

        func node(_ e: UnsafeMutablePointer<FTSENT>, _ st: stat, isDir: Bool) -> SpaceNode {
            let name = e.pointee.fts_level == 0 ? rootName : ScanEngine.ftsName(e)
            let n = SpaceNode(name: name, isDir: isDir, dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino))
            if isDir || st.st_nlink <= 1 || links.first(UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino)) {
                n.size = Int64(st.st_blocks) * 512
            }
            n.newest = ScanEngine.mtime(st).timeIntervalSince1970
            if st.st_uid != opts.uid { n.flags.insert(.foreign) }
            if st.st_dev != rootDev { n.flags.insert(.otherVolume) }
            n.blocker = ScanEngine.protectedKind(name: { name }, st, rootDev: rootDev, uid: opts.uid)?.rawValue
            return n
        }

        func add(_ n: SpaceNode) {
            if let top = stack.last { top.kids.append(n); top.node.absorb(n); trim(top, keep: opts.listLimit, max: opts.listLimit * 4) }
            else { result = n }
        }

        /// Keeps the largest `keep` children and folds the rest into "smaller items".
        func trim(_ f: Frame, keep: Int, max: Int) {
            guard f.kids.count > max else { return }
            f.kids.sort { $0.size > $1.size }
            for k in f.kids[keep...] { f.node.otherCount += 1; f.node.otherSize += k.size }
            f.kids.removeSubrange(keep...)
        }

        func finish(_ f: Frame) {
            let n = f.node
            let keep = (n.size >= opts.listMin || f.ent.pointee.fts_level == 0) ? opts.listLimit : 0
            trim(f, keep: keep, max: keep)
            f.kids.sort { $0.size > $1.size }
            for k in f.kids { k.parent = n }
            n.children = f.kids
            add(n)
        }

        while let e = fts_read(fts) {
            seen += 1
            if seen & 1023 == 0 {
                counter?.add(1024, at: stack.last.map { String(cString: $0.ent.pointee.fts_path) } ?? path)
                if cancel.isSet { break }
            }
            let info = Int32(e.pointee.fts_info)
            if e.pointee.fts_level == 0, let sp = e.pointee.fts_statp, info != FTS_DP {
                rootDev = opts.dev ?? sp.pointee.st_dev
            }
            if let top = stack.last, top.ent == e, info == FTS_DP || info == FTS_DNR || info == FTS_ERR {
                // A folder is done (or couldn't be read).
                stack.removeLast()
                if info != FTS_DP {
                    top.node.flags.insert(.incomplete)
                    let err = e.pointee.fts_errno
                    if top.node.note == nil { top.node.note = err == EPERM || err == EACCES ? "No access" : "Couldn't be read" }
                }
                finish(top)
                continue
            }
            switch info {
            case FTS_D:
                guard let sp = e.pointee.fts_statp else { continue }
                let st = sp.pointee
                let n = node(e, st, isDir: true)
                let p = String(cString: e.pointee.fts_path)
                let parentInPackage = stack.last?.inPackage ?? false
                if !parentInPackage && n.name.contains(".") && !n.name.hasPrefix(".") && opts.isPackage(p) {
                    n.flags.insert(.package)
                }
                if let hp = homePrefix, p.hasPrefix(hp),
                   p.dropFirst(hp.count).split(separator: "/").count <= syncedDepth, opts.isSynced(p) {
                    n.flags.insert(.synced)
                }
                if !parentInPackage { n.owner = opts.label(n.name, p) }
                stack.append(Frame(n, e, parentInPackage || n.flags.contains(.package)))
                if st.st_dev != rootDev {
                    _ = fts_set(fts, e, FTS_SKIP)                 // a mount point: not entered
                } else if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
                    _ = fts_set(fts, e, FTS_SKIP)
                    n.note = "In the cloud, not downloaded"
                    n.flags.insert(.incomplete)               // its folders can't be moved as a whole
                } else if let why = opts.skip(p) {
                    _ = fts_set(fts, e, FTS_SKIP)
                    n.note = why
                    n.flags.insert(.incomplete)
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                stack.last?.node.flags.insert(.incomplete)    // an entry inside couldn't be read
            case FTS_DP:
                continue
            default:                                          // files, symbolic links, folder cycles
                guard let sp = e.pointee.fts_statp else { continue }
                add(node(e, sp.pointee, isDir: false))
            }
        }
        // Stopped part-way: close the open folders, marked as not fully scanned.
        while let top = stack.popLast() {
            top.node.flags.insert(.incomplete)
            finish(top)
        }
        counter?.add(seen & 1023, at: path)
        return result
    }
}

// MARK: - Space-map guard (spec 6.4)

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

// MARK: - Picking an item

enum SpaceMap {
    static let categoryID = "SPACE-MAP"

    /// The home folder (its ~/Library scanned folder by folder, for speed) and /Applications.
    static func tops(_ roots: Roots, homeTitle: String = "Home folder") -> [SpaceScanner.Top] {
        let home = SpaceScanner.shell(roots.home, title: homeTitle)
        home.base = roots.home
        let apps = SpaceScanner.shell(roots.applications, title: "Applications")
        apps.base = roots.applications
        return [.init(node: home, path: roots.home, split: [roots.h("Library")]), .init(node: apps, path: roots.applications)]
    }

    /// Scan options for the real Mac or a fixture tree. Without Full Disk Access, app containers
    /// are not entered: macOS may ask about "data from other apps" instead of refusing (9.1).
    static func options(_ roots: Roots, fda: FDAStatus, inventory: AppInventory) -> SpaceOptions {
        var o = SpaceOptions()
        o.home = roots.home
        let gated = [roots.h("Library/Containers"), roots.h("Library/Group Containers")]
        o.skip = { p in fda != .granted && gated.contains(p) ? "Needs Full Disk Access" : nil }
        o.label = labeler(roots, inventory)
        return o
    }

    /// Labels folders with their app (spec 8): an .app bundle is its own app; a folder named by
    /// bundle ID resolves to that app; inside ~/Library, a folder named exactly like an
    /// installed app belongs to it. Safe to call from several threads.
    static func labeler(_ roots: Roots, _ inv: AppInventory) -> (String, String) -> AppInfo? {
        let lock = NSLock()
        var cache: [String: AppInfo?] = [:]
        var byName: [String: AppInfo] = [:]
        for a in inv.apps.values.sorted(by: { $0.path < $1.path }) where byName[a.name.lowercased()] == nil {
            byName[a.name.lowercased()] = a
        }
        let lib = roots.h("Library") + "/"
        return { name, path in
            let lower = name.lowercased()
            if lower.hasSuffix(".app") { return AppInventory.info(path) }
            let k = CandidateKey.parse(name)
            guard k.kind == .bundleID || path.hasPrefix(lib) else { return nil }
            lock.lock()
            if let hit = cache[lower] { lock.unlock(); return hit }
            lock.unlock()
            let a = k.kind == .bundleID ? inv.owner(of: k.key) : byName[lower]
            lock.lock(); cache[lower] = a; lock.unlock()
            return a
        }
    }

    /// The clean item for one node the user picked. It goes through `Cleaner.clean` with the
    /// Space-map checks: the guard, the same file, nothing open inside, nothing protected inside.
    static func item(_ n: SpaceNode) -> (Category, CleanItem) {
        var i = CleanItem(path: n.path, name: n.name, size: n.size, newest: n.newestDate, risk: .review,
                          method: .trash, reason: "Picked in the Space map", allowRoot: "", fileID: n.fileID)
        i.checkOpenFiles = true
        i.spaceMap = true
        let c = Category(id: categoryID, title: "Space map", group: .general, method: .trash,
                         explanation: "An item you picked in the Space map", items: [i])
        return (c, i)
    }
}

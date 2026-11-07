// Size and age measurement (spec 6.2). Foundation and Darwin only.
//
// Uses fts(3) without following links (FTS_PHYSICAL) and without crossing volumes (FTS_XDEV).
// Size is allocated size (st_blocks × 512, as du reports), never the logical size.
// Files with more than one hard link are counted once per scan.

import Foundation

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Hard-link bookkeeping shared by every measurement in one scan.
final class LinkSet: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<[UInt64]>()
    /// True the first time this (device, inode) is seen.
    func first(_ dev: UInt64, _ ino: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert([dev, ino]).inserted
    }
}

struct Measure {
    var size: Int64 = 0
    var newest: Date? = nil          // nil when more than `ageCap` entries were seen
    var entries = 0
    var complete = true              // false if part of it couldn't be read
    var fileID: [UInt64] = []
    var cancelled = false
    var special = false              // contains a socket or FIFO (may be in use without an open file)
    var locked = false               // contains a locked file (Finder would stop to ask about it)
    var protected: String? = nil     // with `inspect`: the first always-protected thing inside (6.4)
}

enum ScanEngine {
    static let ageCap = 10_000

    static func fileID(_ path: String) -> [UInt64]? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return [UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino)]
    }

    static func mtime(_ st: stat) -> Date {
        Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Things that are always protected from the Space map (6.4, "No protected contents"): a
    /// folder holding one of them can't be moved as a whole. Cloud-synced items are checked by
    /// the Space-map guard on the item and its parents.
    enum Protected: String {
        case app = "Contains an app. Apps are removed with an uninstaller, not from the Space map."
        case photos = "Contains a photo library"
        case foreign = "Contains items owned by another user"
        case mount = "Contains a mount point"
        case cloud = "Contains items stored only in the cloud"
        case synced = "Contains cloud-synced items. Remove them in Finder, because they would be deleted on every synced device."
    }

    /// Whether this entry is always protected. `name` is checked for folders only. With
    /// `bundlePath`, a folder named "….app" counts as an app only if it looks like a bundle (it has
    /// Contents/Info.plist or Contents/MacOS), so data folders named by bundle ID ("com.vendor.app")
    /// aren't mistaken for apps.
    static func protectedKind(name: () -> String, _ st: stat, rootDev: Int32, uid: uid_t,
                              bundlePath: (() -> String)? = nil) -> Protected? {
        if st.st_uid != uid { return .foreign }
        if st.st_dev != rootDev { return .mount }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let n = name().lowercased()
        if n.hasSuffix(".app") {
            guard let bundlePath else { return .app }
            let p = bundlePath()
            if lstatInfo(p + "/Contents/Info.plist") != nil || lstatInfo(p + "/Contents/MacOS") != nil { return .app }
        }
        if n.hasSuffix(".photoslibrary") { return .photos }
        return nil
    }

    /// The name of an fts entry (fts_name is a C flexible array member).
    static func ftsName(_ e: UnsafeMutablePointer<FTSENT>) -> String {
        let off = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
        let p = (UnsafeRawPointer(e) + off).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(e.pointee.fts_namelen)), as: UTF8.self)
    }

    /// Measures a file or folder. `links` dedupes hard links across the whole scan. With
    /// `inspect`, also looks for always-protected contents (Space-map items, 6.4): folders are
    /// checked with `synced` for cloud sync, and nothing stored only in the cloud is downloaded
    /// to look at it (S11).
    static func measure(_ path: String, links: LinkSet?, cancel: CancelFlag? = nil, inspect: Bool = false,
                        synced: ((String) -> Bool)? = nil, strictApps: Bool = false) -> Measure {
        var m = Measure()
        let prevPolicy = inspect ? getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) : -1
        if inspect {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        }
        defer {
            if prevPolicy >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, prevPolicy) }
        }
        guard let id = fileID(path) else { m.complete = false; return m }
        m.fileID = id
        var newest: Date? = nil
        let cpath = strdup(path)
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            m.complete = false; return m
        }
        defer { fts_close(fts) }
        let uid = getuid()
        var rootDev: Int32? = nil
        while let e = fts_read(fts) {
            if m.entries & 1023 == 0, cancel?.isSet == true { m.cancelled = true; break }
            let info = Int32(e.pointee.fts_info)
            switch info {
            case FTS_DP:
                continue                                  // directory, second visit
            case FTS_DNR, FTS_ERR, FTS_NS:
                m.complete = false
                continue
            default:
                break
            }
            guard let sp = e.pointee.fts_statp else { continue }
            let st = sp.pointee
            if rootDev == nil { rootDev = st.st_dev }
            if inspect, m.protected == nil,
               let k = protectedKind(name: { ftsName(e) }, st, rootDev: rootDev!, uid: uid,
                                     bundlePath: strictApps ? { String(cString: e.pointee.fts_path) } : nil) {
                m.protected = k.rawValue
            }
            if inspect, m.protected == nil {
                if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
                    m.protected = Protected.cloud.rawValue
                } else if (st.st_mode & S_IFMT) == S_IFDIR, let synced, synced(String(cString: e.pointee.fts_path)) {
                    m.protected = Protected.synced.rawValue
                }
            }
            m.entries += 1
            if m.entries <= ageCap {
                let t = mtime(st)
                if newest == nil || t > newest! { newest = t }
            }
            let type = st.st_mode & S_IFMT
            if type == S_IFSOCK || type == S_IFIFO { m.special = true }
            if st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 { m.locked = true }
            let isDir = type == S_IFDIR
            if !isDir && st.st_nlink > 1, let l = links,
               !l.first(UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino)) {
                continue                                  // already counted through another link
            }
            m.size += Int64(st.st_blocks) * 512
        }
        m.newest = m.entries > ageCap ? nil : newest
        return m
    }

    /// Newest modification date only (S13d re-check). nil if the cap is reached or unreadable.
    static func newest(_ path: String) -> Date? {
        measure(path, links: nil).newest
    }

    enum ListResult { case ok([String]), missing, noAccess(Int32) }

    /// Direct children of a folder (names), without following links.
    static func children(_ dir: String) -> ListResult {
        guard let d = opendir(dir) else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .noAccess(errno)
        }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." || name == ".DS_Store" { continue }
            names.append(name)
        }
        return .ok(names.sorted())
    }

    static func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }
}

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

    /// Measures a file or folder. `links` dedupes hard links across the whole scan.
    static func measure(_ path: String, links: LinkSet?, cancel: CancelFlag? = nil) -> Measure {
        var m = Measure()
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

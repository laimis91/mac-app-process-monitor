// Bundle-ID key parsing, ID matching, the protection list and version parsing (spec 7.1, 9.2, 9.3).
// Foundation only. The protection list is written for this project; it is not copied from
// another cleaner (see spec 9.3, Licensing).

import Foundation

struct CandidateKey: Equatable {
    enum Kind: Equatable { case bundleID, name }
    let key: String          // without file extension and without group./team prefix
    let kind: Kind
    let wrapped: Bool        // came from a group.<id> or <TEAMID>.<id> name

    static let topLevel: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "info",
                                        "biz", "edu", "gov", "ai", "tv", "us", "xyz", "pro", "eu"]
    static let extensions = [".plist", ".savedstate", ".binarycookies"]

    static func parse(_ rawName: String) -> CandidateKey {
        var s = rawName
        for e in extensions where s.lowercased().hasSuffix(e) { s = String(s.dropLast(e.count)); break }
        var wrapped = false
        if s.lowercased().hasPrefix("group.") {
            s = String(s.dropFirst(6)); wrapped = true
        } else if let dot = s.firstIndex(of: "."), isTeamID(s[..<dot]) {
            s = String(s[s.index(after: dot)...]); wrapped = true
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let isID = parts.count >= 3 && !parts.contains(where: \.isEmpty)
            && isTopLevel(parts[0].lowercased())
            && !s.contains(" ") && !s.contains("/")
        return CandidateKey(key: s, kind: isID ? .bundleID : .name, wrapped: wrapped)
    }

    static func isTopLevel(_ c: String) -> Bool {
        topLevel.contains(c) || (c.count == 2 && c.allSatisfy { $0.isASCII && $0.isLetter })
    }
    static func isTeamID(_ s: Substring) -> Bool {
        s.count == 10 && s.allSatisfy { ($0.isASCII && $0.isUppercase && $0.isLetter) || $0.isNumber }
    }
}

enum BundleIDs {
    static let helperSuffixes: Set<String> = ["helper", "agent", "daemon", "xpc", "updater", "launcher",
                                              "loginitem", "findersync", "widget", "shareextension",
                                              "extension", "intents"]

    /// The ID with one trailing helper-like component removed.
    static func base(_ id: String) -> String {
        let parts = id.split(separator: ".")
        guard parts.count > 3, let last = parts.last, helperSuffixes.contains(last.lowercased()) else { return id }
        return parts.dropLast().joined(separator: ".")
    }

    /// `candidate` equals `owner`, or starts with `owner` followed by a dot. Without case.
    static func belongs(_ candidate: String, to owner: String) -> Bool {
        let c = candidate.lowercased(), o = owner.lowercased()
        return !o.isEmpty && (c == o || c.hasPrefix(o + "."))
    }

    /// Either one is the other's helper or parent (used for running-app checks, S7).
    static func related(_ a: String, _ b: String) -> Bool { belongs(a, to: b) || belongs(b, to: a) }

    static func vendor(_ id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
    }
}

enum Protection {
    /// Exact keys, prefixes (ending in ".*") and whole name components, compared without case.
    static let entries: [String] = [
        // Apple and macOS
        "com.apple.*", "mobilesync", "addressbook", "callhistorydb", "knowledge", "fileprovider",
        "cloudkit", "icloud", "org.cups.*", "loginwindow", "dock", "finder", "systemuiserver",
        // Large vendors whose apps share data across products
        "com.microsoft.*", "com.google.*", "google", "org.mozilla.*", "com.jetbrains.*", "jetbrains",
        "com.docker.*",
        // Passwords and security
        "1password", "com.agilebits.*", "bitwarden", "lastpass", "keepass", "keepassxc", "dashlane",
        "gpg", "gnupg", "ssh", "keychain", "keychains",
        // Developer tools that keep their own caches
        "homebrew", "python", "pip", "node", "npm", "code", "swiftpm", "coresimulator",
    ]

    static func isProtected(_ key: String, ignore: Set<String> = []) -> Bool {
        let k = key.lowercased()
        if k.contains("apple") { return true }
        if ignore.contains(k) { return true }
        let components = Set(k.split(whereSeparator: { $0 == "." || $0 == " " }).map(String.init))
        for e in entries {
            if e.hasSuffix(".*") {
                let p = String(e.dropLast(2))
                if k == p || k.hasPrefix(p + ".") { return true }
            } else if k == e || components.contains(e) {
                return true
            }
        }
        return false
    }
}

enum Versions {
    /// "17.0 (21A329)" → [17, 0]; "iPhone15,2 17.0 (21A…)" → [17, 0]; anything else → nil.
    static func deviceSupport(_ name: String) -> [Int]? {
        let tokens = name.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        if let v = numeric(first) { return v }
        if tokens.count >= 2, first.contains(where: \.isLetter), let v = numeric(tokens[1]) { return v }
        return nil
    }

    static func numeric(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    static func less(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// Names to offer for removal: everything except folders whose version is among the
    /// `keep` newest distinct versions. Unparsable names are always kept (S5).
    static func oldDeviceSupport(_ names: [String], keep: Int = 2) -> [String] {
        let parsed = names.compactMap { n in deviceSupport(n).map { (n, normalize($0)) } }
        var distinct: [[Int]] = []
        for (_, v) in parsed where !distinct.contains(v) { distinct.append(v) }
        distinct.sort { less($1, $0) }
        let kept = Array(distinct.prefix(keep))
        return parsed.filter { !kept.contains($0.1) }.map(\.0)
    }

    /// 17.0 and 17 count as the same version.
    static func normalize(_ v: [Int]) -> [Int] {
        var v = v
        while v.count > 1, v.last == 0 { v.removeLast() }
        return v
    }
}

// Disk cleaner: shared types, scan roots and age-limit settings.
// Foundation only (no AppKit/SwiftUI), so scripts/selftest.sh can compile it.

import Foundation

enum Risk: String, Codable { case safe = "Safe", review = "Review", requested = "Requested", info = "Info" }
enum Method: String, Codable { case trash, tool, none }
enum CategoryGroup: String, Codable {
    case general = "General", developer = "Developer"
    case leftovers = "Leftovers", possible = "Possible leftovers, check before removing"
    case uninstall = "Files of this app", kept = "Shown only, not moved"
}
enum FDAStatus: String, Codable { case granted, denied, unknown }

/// Which guard checks an item right before it is acted on (6.4, S13a). One value per item, so
/// no item can be both a Space-map pick and an app bundle, or carry an empty rule root.
enum GuardScope: Equatable {
    case rule(root: String)         // a junk, leftover or uninstaller item: the rule root it must stay inside
    case appBundle(root: String)    // the app bundle itself (uninstaller): the app root it sits in
    case spaceMap                   // picked in the Space map: the Space-map guard
    case none                       // tool and info rows: nothing may be moved through the guard
}

/// One thing the user can clean, or a row shown for information.
struct CleanItem: Identifiable {
    var id: String { path }
    let path: String                // canonical, as produced by the scanner
    let name: String
    let size: Int64                 // allocated bytes, hard links counted once
    let newest: Date?               // newest modification inside; nil when unknown (cap reached)
    let risk: Risk
    let method: Method
    let reason: String
    let scope: GuardScope           // the guard that checks it at action time
    let fileID: [UInt64]            // [device, inode] at scan time
    var owners: [String] = []       // bundle IDs whose running app blocks this item (S7)
    var ownerNames: [String] = []   // app names, for caches named by app name
    var ageLimitDays: Int? = nil    // re-checked at action time (S13d)
    var checkOpenFiles = false      // S13c
    var runningOwner: String? = nil // app name, when an owner was running at scan time
    var note: String? = nil         // shown greyed, e.g. "Needs Full Disk Access"
    var sizeUnknown = false         // tool rows with nothing to measure
    var measurePath: String? = nil  // tool rows: the cache folder measured before and after
    var inspect = false             // re-checked for always-protected contents (an app inside, …) when cleaned
    var preselect = false           // uninstaller Review rows the user asked for by naming the app (spec 10)
    var insideBundle: String? = nil // uninstaller: skipped while any process runs from inside this bundle

    /// Picked in the Space map: checked by the Space-map guard (6.4).
    var spaceMap: Bool { scope == .spaceMap }
    /// The app bundle itself (uninstaller): checked against the app roots (6.4).
    var appBundle: Bool { if case .appBundle = scope { return true }; return false }

    var selectable: Bool { risk != .info && note == nil }
    /// S6: only Safe and Requested items moved to the Trash are pre-selected, never tool commands.
    /// Review items only when the uninstaller marks them (spec 10).
    var preselected: Bool {
        selectable && method == .trash && runningOwner == nil
            && (risk == .safe || risk == .requested || (risk == .review && preselect))
    }
}

struct ToolCommand {
    let tool: String                // executable name, located at known absolute paths
    let commands: [[String]]        // argument lists, run one after another
    let preview: [String]?          // read-only "what would it do" arguments, shown in the sheet
    var executable: String? = nil   // resolved absolute path
    var place: ToolPlace? = nil     // where it was found: checked again right before it runs (spec 6.5)
    var command: [String] { commands.map { ([tool] + $0).joined(separator: " ") } }
}

struct Category: Identifiable {
    let id: String                  // rule ID, e.g. "J-CACHE"
    let title: String
    let group: CategoryGroup
    let method: Method
    let explanation: String
    var items: [CleanItem]
    var tool: ToolCommand? = nil
    var notice: String? = nil       // e.g. "Needs Full Disk Access"
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Where the cleaner looks. The real folders, or a fixture tree that maps them (debug builds).
struct Roots {
    let home: String
    let temp: String
    let applications: String
    let systemApplications: String
    let library: String
    /// Where each tool is looked up, in order (spec 6.5).
    let toolPlaces: [String: [ToolPlace]]
    let fixture: Bool

    /// Every folder a tool is looked up in, once each.
    var toolFolders: [String] {
        var seen = Set<String>()
        return toolPlaces.keys.sorted().flatMap { toolPlaces[$0]! }.map(\.folder).filter { seen.insert($0).inserted }
    }

    func h(_ rel: String) -> String { home + "/" + rel }

    static func canonical(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p }
        defer { free(r) }
        return String(cString: r)
    }

    static func userTempDir() -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let raw = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return canonical(raw)
    }

    static func real() -> Roots {
        let home = canonical(NSHomeDirectory())
        return Roots(home: home, temp: userTempDir(), applications: "/Applications",
                     systemApplications: "/System/Applications", library: "/Library",
                     toolPlaces: ToolLocator.realPlaces(home: home), fixture: false)
    }

    /// Fixture roots inside `root`. Returns nil unless the canonical root is a fixture folder.
    static func fixture(_ root: String) -> Roots? {
        let r = canonical(root)
        guard r.hasPrefix("/private/tmp/appmon-fixture-"), !r.contains("/../") else { return nil }
        return Roots(home: r + "/home", temp: r + "/tmp", applications: r + "/Applications",
                     systemApplications: r + "/System/Applications", library: r + "/Library",
                     toolPlaces: Dictionary(uniqueKeysWithValues: ToolLocator.realPlaces(home: r + "/home").keys.map {
                         ($0, [ToolPlace(folder: r + "/bin", targets: [r + "/bin"])])
                     }), fixture: true)
    }
}

// MARK: - Age limits (spec 4.6, decision D6)

enum AgeField: String, CaseIterable, Codable {
    case logs, temp, leftovers, lowConfidence, mail

    var title: String {
        switch self {
        case .logs: return "Logs and crash reports older than"
        case .temp: return "Temporary files older than"
        case .leftovers: return "Leftovers unchanged for"
        case .lowConfidence: return "Possible leftovers unchanged for"
        case .mail: return "Mail attachments older than"
        }
    }
    var defaultValue: Int {
        switch self { case .logs: return 7; case .temp: return 3; case .leftovers: return 30
        case .lowConfidence: return 90; case .mail: return 30 }
    }
    func range(_ current: AgeLimits) -> ClosedRange<Int> {
        switch self {
        case .logs: return 1...365
        case .temp: return 3...90
        case .leftovers: return 14...365
        case .lowConfidence: return max(14, current.leftovers)...730
        case .mail: return 7...365
        }
    }
}

struct AgeLimits: Equatable, Codable {
    var logs = 7, temp = 3, leftovers = 30, lowConfidence = 90, mail = 30

    subscript(f: AgeField) -> Int {
        get {
            switch f { case .logs: return logs; case .temp: return temp; case .leftovers: return leftovers
            case .lowConfidence: return lowConfidence; case .mail: return mail }
        }
        set {
            switch f { case .logs: logs = newValue; case .temp: temp = newValue; case .leftovers: leftovers = newValue
            case .lowConfidence: lowConfidence = newValue; case .mail: mail = newValue }
        }
    }

    /// Returns nil when `value` may be stored, otherwise the message to show. Never clamps.
    func validate(_ f: AgeField, _ value: Int) -> String? {
        if f == .leftovers, value > lowConfidence, (14...365).contains(value) {
            return "Raise the Possible-leftovers limit first"
        }
        let r = f.range(self)
        return r.contains(value) ? nil : "Choose \(r.lowerBound) to \(r.upperBound) days"
    }

    /// Re-checks stored values on launch: anything out of range goes back to its default.
    static func sanitized(_ stored: [AgeField: Int]) -> AgeLimits {
        var a = AgeLimits()
        for f in [AgeField.logs, .temp, .leftovers, .mail] {
            if let v = stored[f], f.range(a).contains(v) { a[f] = v }
        }
        if let v = stored[.lowConfidence], AgeField.lowConfidence.range(a).contains(v) {
            a.lowConfidence = v
        } else {
            a.lowConfidence = max(AgeField.lowConfidence.defaultValue, a.leftovers)
        }
        return a
    }
}

// MARK: - Small helpers

func byteText(_ b: Int64) -> String {
    let v = Double(b)
    if v >= 1_073_741_824 { return String(format: "%.1f GB", v / 1_073_741_824) }
    if v >= 1_048_576 { return String(format: "%.0f MB", v / 1_048_576) }
    if v >= 1024 { return String(format: "%.0f KB", v / 1024) }
    return b == 0 ? "0 KB" : "1 KB"
}

func days(since d: Date?, now: Date) -> Int? {
    guard let d else { return nil }
    return Int(now.timeIntervalSince(d) / 86_400)
}

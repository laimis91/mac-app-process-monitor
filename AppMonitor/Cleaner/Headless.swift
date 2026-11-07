// Headless scan and clean for fixture tests (debug builds only, spec 13).
//
//   APPMON_SCAN_ROOT=/private/tmp/appmon-fixture-x  AppMonitor --scan-json
//   APPMON_SCAN_ROOT=…  APPMON_SELECT="home/Library/Logs/old,J-NPM"  AppMonitor --clean-json
//
//   APPMON_SCAN_ROOT=…  AppMonitor --space-json          # Space map: every listed item, size, reason
//   APPMON_SCAN_ROOT=…  APPMON_SELECT="home/Projects/x" AppMonitor --space-trash
//
// --clean-json selects the pre-selected items plus the listed paths (relative to the root) and
// rule IDs, then cleans them. Fixture mode is a dry run unless APPMON_FIXTURE_ACT=1.
// Paths in the output start with "<root>" so they can be compared with a golden file.

import Foundation

#if APPMON_DEBUG
enum Headless {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--scan-json") || args.contains("--clean-json") || args.contains("--space-json")
              || args.contains("--space-trash") else { return }
        guard let root = CleanerConfig.fixtureRoot else {
            FileHandle.standardError.write("Headless mode needs APPMON_SCAN_ROOT (a fixture tree)\n".data(using: .utf8)!)
            exit(2)
        }
        if args.contains("--space-json") || args.contains("--space-trash") { space(root, trash: args.contains("--space-trash")) }
        let ctx = CleanerConfig.context(limits: AgeLimits(), ignore: [], cancel: CancelFlag())
        var cats: [Category] = []
        let lock = NSLock()
        Rules.scan(ctx, progress: { _ in }, found: { c in lock.lock(); cats.append(c); lock.unlock() })
        cats.sort { (Rules.order.firstIndex(of: $0.id) ?? 99) < (Rules.order.firstIndex(of: $1.id) ?? 99) }

        func rel(_ p: String) -> String { p.hasPrefix(root) ? "<root>" + p.dropFirst(root.count) : p }
        var out: [[String: Any]] = []
        if args.contains("--scan-json") {
            for c in cats {
                var d: [String: Any] = ["id": c.id, "group": c.group.rawValue, "method": c.method.rawValue]
                if let n = c.notice { d["notice"] = n }
                if let t = c.tool { d["command"] = t.commands.map { ([rel(t.executable ?? t.tool)] + $0).joined(separator: " ") } }
                d["items"] = c.items.sorted { $0.path < $1.path }.map { i -> [String: Any] in
                    var e: [String: Any] = ["path": rel(i.path), "risk": i.risk.rawValue, "kb": i.size / 1024,
                                            "selectable": i.selectable, "preselected": i.preselected]
                    if let r = i.runningOwner { e["running"] = r }
                    if let mp = i.measurePath { e["measures"] = rel(mp) }
                    return e
                }
                out.append(d)
            }
        } else {
            let wanted = Set((ProcessInfo.processInfo.environment["APPMON_SELECT"] ?? "")
                .split(separator: ",").map { String($0) })
            var pairs: [(Category, CleanItem)] = []
            for c in cats {
                for i in c.items where i.preselected || wanted.contains(c.id)
                    || wanted.contains(String(rel(i.path).dropFirst("<root>/".count))) {
                    pairs.append((c, i))
                }
            }
            let result = Cleaner.clean(pairs, env: CleanerConfig.cleanEnvironment(ctx))
            out = result.sorted { $0.path < $1.path }.map { o in
                var e: [String: Any] = ["path": rel(o.path), "category": o.category, "status": o.status.rawValue,
                                        "kb": o.size / 1024]
                if let r = o.reason { e["reason"] = r }
                if let c = o.command { e["command"] = c.map(rel) }
                return e
            }
        }
        write(out)
    }

    static func write(_ out: Any) -> Never {
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        exit(0)
    }

    /// Space map of the fixture tree. Every folder lists its contents (no 1 MB minimum).
    static func space(_ root: String, trash: Bool) -> Never {
        let roots = CleanerConfig.roots
        let inv = CleanerConfig.inventory(roots)
        var opts = SpaceMap.options(roots, fda: CleanerConfig.fda(roots), inventory: inv)
        opts.listMin = 0
        let tops = SpaceMap.tops(roots)
        SpaceScanner.scan(tops, opts: opts, links: LinkSet(), cancel: CancelFlag(), counter: SpaceCounter()) { p, c in p.attach(c) }
        let home = tops[0].node
        func rel(_ p: String) -> String { p.hasPrefix(root) ? String(p.dropFirst(root.count + 1)) : p }
        var nodes: [String: SpaceNode] = [:]
        var out: [[String: Any]] = []
        func visit(_ n: SpaceNode) {
            nodes[rel(n.path)] = n
            var e: [String: Any] = ["path": rel(n.path), "kb": n.size / 1024]
            if let r = SpaceGuard.reason(for: n, home: home) { e["reason"] = r }
            if let o = n.owner { e["owner"] = o.name }
            if let note = n.note { e["note"] = note }
            if n.otherCount > 0 { e["other"] = n.otherCount }
            out.append(e)
            n.children.forEach(visit)
        }
        tops.forEach { visit($0.node) }
        guard trash else { write(out.sorted { ($0["path"] as! String) < ($1["path"] as! String) }) }
        // Each selected item is cleaned on its own, as the Space map does (one at a time).
        let env = CleanerConfig.spaceEnvironment(roots, inv)
        var results: [[String: Any]] = []
        for want in (ProcessInfo.processInfo.environment["APPMON_SELECT"] ?? "").split(separator: ",").map(String.init) {
            guard let n = nodes[want] else { results.append(["path": want, "status": "not listed"]); continue }
            if let why = SpaceGuard.reason(for: n, home: home) {
                results.append(["path": want, "status": "refused", "reason": why]); continue
            }
            for o in Cleaner.clean([SpaceMap.item(n)], env: env) {
                var e: [String: Any] = ["path": rel(o.path), "status": o.status.rawValue, "kb": o.size / 1024]
                if let r = o.reason { e["reason"] = r }
                results.append(e)
            }
        }
        write(results)
    }
}
#endif

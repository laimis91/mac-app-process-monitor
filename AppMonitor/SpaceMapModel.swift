// Space map state (spec 8). Owned by AppMonitorApp next to CleanerModel, so the last scan stays
// in memory across tab switches. Scan results are never stored on disk (S11).

import SwiftUI
import AppKit

@MainActor
final class SpaceMapModel: ObservableObject {
    @Published private(set) var root: SpaceNode?
    @Published private(set) var trail: [SpaceNode] = []      // drill-down path; the last is shown
    @Published private(set) var scanning = false
    @Published private(set) var progress = ""
    @Published private(set) var scannedAt: Date?
    @Published private(set) var stopped = false
    @Published var filter = ""
    @Published var pending: SpaceNode?                       // waiting for confirmation
    @Published var refusal: Refusal?
    @Published var result: Outcome?
    @Published private(set) var acting = false
    @Published private(set) var version = 0                  // bumped when the tree changes

    struct Refusal: Identifiable { let id = UUID(); let name: String; let reason: String }

    private(set) var home: SpaceNode?
    private var cancel: CancelFlag?
    private var counter: SpaceCounter?
    private var inventory: AppInventory?
    private var roots: Roots?
    private var poll: Timer?
    let dryRun = CleanerConfig.dryRun

    init() {
        if demoMode {
            let (r, h) = Demo.spaceMap()
            root = r; home = h; trail = [h]; scannedAt = Date().addingTimeInterval(-4 * 60)
        }
    }

    var current: SpaceNode? { trail.last ?? root }

    // MARK: Scanning

    func scan(fda: FDAStatus) {
        guard !scanning, !acting else { return }
        if demoMode { scannedAt = Date(); return }
        let roots = CleanerConfig.roots
        let tops = SpaceMap.tops(roots)
        let map = SpaceNode.root()
        tops.forEach { map.attach($0.node) }
        let flag = CancelFlag(), count = SpaceCounter()
        self.roots = roots
        root = map; home = tops[0].node; trail = []; filter = ""
        cancel = flag; counter = count
        scanning = true; stopped = false; progress = "Starting…"
        version += 1
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        Task.detached(priority: .utility) { [weak self] in
            let inv = CleanerConfig.inventory(roots)
            let opts = SpaceMap.options(roots, fda: fda, inventory: inv)
            let complete = SpaceScanner.scan(tops, opts: opts, links: LinkSet(), cancel: flag, counter: count) { parent, child in
                DispatchQueue.main.async { MainActor.assumeIsolated { parent.attach(child); self?.version += 1 } }
            }
            // Queued after every attach above, so it runs once the whole tree is in place.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.cancel === flag else { return }
                    if !complete { Self.markShellsIncomplete(map) }
                    self.inventory = inv
                    self.scanning = false
                    self.stopped = flag.isSet
                    self.scannedAt = Date()
                    self.progress = ""
                    self.poll?.invalidate()
                    self.version += 1
                }
            }
        }
    }

    func stop() { cancel?.set() }

    private func updateProgress() {
        guard scanning, let (n, at) = counter?.value else { return }
        progress = n == 0 ? "Starting…" : "\(n.formatted()) items  ·  \(tilde(at))"
    }

    /// Folders filled by several jobs miss whatever didn't run: they can't be moved as a whole.
    private static func markShellsIncomplete(_ n: SpaceNode) {
        guard n.flags.contains(.shell) else { return }
        n.flags.insert(.incomplete)
        n.children.forEach(markShellsIncomplete)
    }

    // MARK: Navigation (from cached data, no disk access)

    func open(_ n: SpaceNode) {
        guard n.isDir, n.hasContents else { return }
        trail.append(n)
        filter = ""
    }

    func goTo(depth: Int) { trail = Array(trail.prefix(depth)); filter = "" }

    /// While a scan or a move is running, nothing else can be moved.
    var busyReason: String? {
        scanning ? "Wait for the scan to finish" : acting ? "Wait until the current move has finished" : nil
    }

    /// Why this item is Reveal only, from what the scan recorded; nil if it may be picked.
    func reason(_ n: SpaceNode) -> String? { SpaceGuard.reason(for: n, home: home) }

    // MARK: Move to Trash (decision D5): one item at a time, always confirmed

    /// Checks the item right now (the guard reads the disk), then asks for confirmation.
    func ask(_ n: SpaceNode) {
        if let busy = busyReason { refusal = Refusal(name: n.name, reason: busy); return }
        if let why = reason(n) { refusal = Refusal(name: n.name, reason: why); return }
        if !demoMode, let roots, let why = SpaceGuard(roots: roots).check(n.path) {
            refusal = Refusal(name: n.name, reason: why); return
        }
        pending = n
    }

    /// The confirmed item waits until the confirmation sheet has closed, so the result sheet or
    /// refusal that follows can always be shown.
    private var confirmed: SpaceNode?
    func confirm(_ n: SpaceNode) { confirmed = n }
    func confirmationClosed() {
        pending = nil
        if let n = confirmed { confirmed = nil; trash(n) }
    }

    func trash(_ n: SpaceNode) {
        pending = nil
        if let busy = busyReason { refusal = Refusal(name: n.name, reason: busy); return }
        if demoMode {
            n.parent?.remove(n); version += 1
            result = Outcome(path: n.path, name: n.name, category: SpaceMap.categoryID, status: .moved, size: n.size)
            return
        }
        guard let roots, let inventory else {
            refusal = Refusal(name: n.name, reason: "Scan again first: the map isn't ready"); return
        }
        acting = true
        let env = CleanerConfig.spaceEnvironment(roots, inventory)
        let pair = SpaceMap.item(n)
        Task.detached(priority: .userInitiated) { [self] in
            let out = Cleaner.clean([pair], env: env).first
            await MainActor.run {
                if out?.status == .moved { n.parent?.remove(n); self.version += 1 }
                self.result = out ?? Outcome(path: n.path, name: n.name, category: SpaceMap.categoryID,
                                             status: .failed, reason: "No answer")
                self.acting = false
            }
        }
    }
}

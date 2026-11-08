// Disk tab header panels (spec 4.2): disk ring, reclaimable space, access, and the Full Disk Access banner.

import SwiftUI
import AppKit

struct DiskPanel: View {
    /// Changes after a scan, clean, uninstall or Space map move, so free space is read again.
    let tick: Int
    @State private var space = DiskPanel.capacity()

    var body: some View {
        let (total, free) = space
        let used = total > 0 ? (total - free) / total : 0
        Panel(title: "DISK", icon: "internaldrive") {
            HStack(spacing: 16) {
                Ring(value: used, color: Theme.heat(used * 0.9), label: String(format: "%.0f", free / 1e9), caption: "GB FREE")
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "%.0f GB", total / 1e9)).font(.system(size: 28, weight: .regular, design: .rounded)).monospacedDigit()
                    Text("Startup disk").font(.callout).foregroundStyle(Theme.dim)
                    Text(String(format: "%.0f%% used", used * 100)).font(.caption).foregroundStyle(Theme.dim)
                }
            }
        }
        .onChange(of: tick) { _, _ in space = Self.capacity() }
    }

    static func capacity() -> (Double, Double) {
        if demoMode { return (994e9, 312e9) }
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Double(v?.volumeTotalCapacity ?? 0), Double(v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

struct ReclaimPanel: View {
    @EnvironmentObject var m: CleanerModel
    var body: some View {
        Panel(title: "RECLAIMABLE", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("up to").font(.callout).foregroundStyle(Theme.dim)
                    Text(byteText(m.reclaimable)).font(.system(size: 28, weight: .regular, design: .rounded)).monospacedDigit()
                }
                Text("\(byteText(m.selectedSize)) selected in \(m.selected.count) item\(m.selected.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(Theme.dim)
                Text(note).font(.caption).foregroundStyle(Theme.faint)
            }
        }
    }

    var note: String {
        switch m.kind {
        case .uninstall:
            guard let t = m.target else { return "Pick an app to see what uninstalling it frees" }
            if !t.running.isEmpty { return "Nothing is pre-selected while \(t.app.name) is running. Quit it to uninstall it." }
            return "The app, its caches and its settings are pre-selected. Containers and agents are yours to pick."
        case .leftovers:
            return m.lastScan == nil ? "Run a scan to find out" : "Leftovers are never pre-selected. Check each one before removing it."
        case .junk:
            return m.lastScan == nil ? "Run a scan to find out" : "Safe items are pre-selected. Review items are yours to pick."
        }
    }
}

struct AccessPanel: View {
    @EnvironmentObject var m: CleanerModel
    var body: some View {
        Panel(title: "ACCESS", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Chip(text: m.fda == .granted ? "FULL DISK ACCESS" : "LIMITED ACCESS",
                         color: m.fda == .granted ? Theme.green : Theme.yellow)
                    Spacer()
                    if m.fda != .granted {
                        ToolButton(icon: "gearshape", text: "Open System Settings") { m.openFDASettings() }
                    }
                }
                Text(m.fda == .granted
                     ? "App Monitor can look in every folder it cleans."
                     : "Some folders, such as app containers and Mail, are skipped and shown as “Needs Full Disk Access”.")
                    .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Text("Removes only with your confirmation  ·  Never needs administrator rights")
                    .font(.caption).foregroundStyle(Theme.faint)
            }
        }
    }
}

struct FDABanner: View {
    @EnvironmentObject var m: CleanerModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.yellow).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access is off.").font(.callout.weight(.semibold))
                Text("App Monitor can't look inside some folders, such as app containers and Mail. Those parts are skipped. In System Settings, switch App Monitor on, or add it with the + button. If it's already on, select it, remove it with the − button, add it again with +, then quit and reopen App Monitor.")
                    .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            ToolButton(icon: "gearshape", text: "Open System Settings") { m.openFDASettings() }
            ToolButton(icon: "xmark", text: "Not now") { m.bannerHidden = true }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.yellow.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.yellow.opacity(0.30)))
    }
}

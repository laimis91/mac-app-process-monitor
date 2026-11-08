// Disk tab (spec 4): header panels, view switch, toolbar, results and the sheets of each list.

import SwiftUI
import AppKit

struct CleanerView: View {
    @EnvironmentObject var m: CleanerModel          // the junk list; it owns the leftovers and uninstaller lists

    /// The list shown in the Junk, Leftovers or Uninstaller view.
    var list: CleanerModel {
        switch m.view {
        case .leftovers: return m.leftovers
        case .uninstall: return m.uninstaller
        default: return m
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                DiskPanel(tick: m.diskTick).frame(width: 320)
                ReclaimPanel().environmentObject(list).frame(width: 320)
                AccessPanel()
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)

            if m.fda != .granted && !m.bannerHidden { FDABanner().padding(.horizontal, 18).padding(.top, 14) }

            HStack(spacing: 12) {
                PillPicker(title: "Disk view", selection: $m.view, items: DiskView.allCases) { $0.rawValue }
                    .frame(width: 380)
                if m.view == .spaceMap { SpaceToolbar() } else { ResultsToolbar().environmentObject(list) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            VStack(spacing: 0) {
                switch m.view {
                case .spaceMap: SpaceMapView()
                case .uninstall: UninstallView().environmentObject(m.uninstaller)
                default: ResultsList().environmentObject(list)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .card()
            .padding(.horizontal, 18)

            Text(m.view.footer + (m.dryRun ? "  ·  DRY RUN: nothing is changed" : ""))
                .font(.caption2).foregroundStyle(m.dryRun ? Theme.yellow : Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(FixtureHooks())
        .background(ResultSheets().environmentObject(m))
        .background(ResultSheets().environmentObject(m.leftovers))
        .background(ResultSheets().environmentObject(m.uninstaller))
        // Spec 10: an app dropped anywhere on the Disk tab opens it in the Uninstaller.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let pr = providers.first else { return false }
            _ = pr.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "app" else { return }
                Task { @MainActor in m.view = .uninstall; m.uninstaller.choose(url.path) }
            }
            return true
        }
    }
}

/// Fixture UI tests (debug builds only). A separate view, so only it observes the Space map and
/// the Disk tab isn't redrawn on every Space map update.
struct FixtureHooks: View {
    #if APPMON_DEBUG
    @EnvironmentObject var m: CleanerModel
    @EnvironmentObject var space: SpaceMapModel

    var body: some View {
        Color.clear.onAppear {
            // APPMON_AUTOSCAN=1 scans at launch, APPMON_EXPAND=J-TMP,… opens categories.
            let env = ProcessInfo.processInfo.environment
            guard let root = CleanerConfig.fixtureRoot else { return }
            let list = m.view == .leftovers ? m.leftovers : m.view == .uninstall ? m.uninstaller : m
            if let e = env["APPMON_EXPAND"] { list.expanded = Set(e.split(separator: ",").map(String.init)); list.possibleOpen = true }
            if env["APPMON_AUTOSCAN"] == "1" { m.view == .spaceMap ? space.scan(fda: m.fda) : list.scan() }
            // APPMON_UNINSTALL=Applications/X.app picks that fixture app in the Uninstaller.
            if let u = env["APPMON_UNINSTALL"] { m.view = .uninstall; m.uninstaller.choose(root + "/" + u) }
        }
    }
    #else
    var body: some View { EmptyView() }
    #endif
}

/// The confirmation and result sheets of one list.
struct ResultSheets: View {
    @EnvironmentObject var m: CleanerModel
    var body: some View {
        Color.clear
            // The clean starts once the confirmation has closed, so the result sheet can open.
            .sheet(isPresented: $m.confirming, onDismiss: { m.confirmationClosed() }) { ConfirmSheet().environmentObject(m) }
            .sheet(isPresented: Binding(get: { m.outcomes != nil }, set: { if !$0 { m.outcomes = nil } })) {
                ResultSheet().environmentObject(m)
            }
    }
}

struct ResultsToolbar: View {
    @EnvironmentObject var m: CleanerModel

    var body: some View {
        HStack(spacing: 10) {
            if m.scanning {
                ToolButton(icon: "stop.fill", text: "Stop") { m.stop() }
                ProgressView().controlSize(.small)
            } else if m.kind == .uninstall {
                if m.target != nil {
                    ToolButton(icon: "chevron.left", text: "Choose another app") { m.chooseAnother() }.disabled(m.cleaning)
                }
            } else {
                ToolButton(icon: "magnifyingglass.circle", text: m.lastScan == nil ? "Scan" : "Scan again") { m.scan() }
                    .disabled(m.cleaning)
            }
            Text(m.cleaning || m.scanning ? m.progress : lastScanText)
                .font(.caption).foregroundStyle(m.stopped && !m.scanning && !m.cleaning ? Theme.yellow : Theme.dim).lineLimit(1)
            Spacer()
            SearchField(prompt: "Filter results", text: $m.search)
            if m.kind != .uninstall || m.target != nil {
                Text("Selected: \(byteText(m.selectedSize))").font(.callout.monospaced()).foregroundStyle(Theme.text)
                PrimaryButton(icon: "trash", text: m.kind.cleanButton,
                              enabled: !(m.selected.isEmpty || m.scanning || m.cleaning)) { m.confirming = true }
                .disabled(m.selected.isEmpty || m.scanning || m.cleaning)
            }
        }
    }

    var lastScanText: String {
        if m.kind == .uninstall {
            guard let t = m.target else {
                return m.loadingChoices ? "Listing apps…" : "Pick an app to uninstall, or drop one onto this window."
            }
            return m.stopped ? t.app.id + "  ·  Stopped: showing the earlier list" : t.app.id
        }
        if m.stopped && m.kind == .leftovers { return "Stopped before it finished: scan again to find leftovers." }
        guard let d = m.lastScan else { return m.kind.intro }
        return (m.stopped ? "Stopped part-way, " : "Last scan ") + sinceText(d)
    }
}

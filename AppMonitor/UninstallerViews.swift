// Disk tab, Uninstaller view (spec 10): the app list, the picked app's header and its files.

import SwiftUI
import AppKit

struct UninstallView: View {
    @EnvironmentObject var m: CleanerModel        // the uninstaller's list

    var body: some View {
        VStack(spacing: 0) {
            if let r = m.refusal {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.orange).accessibilityHidden(true)
                    Text(r).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { m.refusal = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                        .accessibilityLabel("Dismiss").help("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.orange.opacity(0.10))
            }
            if let t = m.target {
                TargetHeader(target: t)
                ResultsList()
            } else if m.scanning {
                ResultsList()
            } else {
                AppPicker()
            }
        }
        .onAppear { if m.target == nil && m.choices.isEmpty { m.loadChoices() } }
    }
}

struct TargetHeader: View {
    let target: UninstallTarget
    @EnvironmentObject var m: CleanerModel

    var body: some View {
        let busy = m.scanning || m.cleaning
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: AppIcons.icon(target.app.path)).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.app.name).font(.system(size: 15, weight: .semibold))
                    Text(tilde(target.app.path)).font(.caption.monospaced()).foregroundStyle(Theme.cyan.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                Text("\(target.ids.count) bundle ID\(target.ids.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.dim)
                    .help(target.ids.joined(separator: "\n"))
            }
            if !target.running.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange).accessibilityHidden(true)
                    Text("\(target.running.joined(separator: ", ")) \(target.running.count == 1 ? "is" : "are") running. Quit \(target.app.name) to uninstall it; nothing is selected until then.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if target.runningByID {
                        Button(m.dryRun ? "Quit (off in dry run)" : "Quit \(target.app.name)") { m.quitTarget() }.disabled(m.dryRun || busy)
                    } else {
                        Text("Quit it in Activity Monitor").font(.caption).foregroundStyle(Theme.dim)
                    }
                    Button("Check again") { m.scan() }.disabled(busy)
                }
            }
            if !target.otherCopies.isEmpty {
                Label("Another copy is on this Mac: \(target.otherCopies.map(tilde).joined(separator: ", ")). It may use the same settings and data, so check what stays selected.",
                      systemImage: "square.on.square").font(.callout).foregroundStyle(Theme.yellow).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.hover)
    }
}

struct AppPicker: View {
    @EnvironmentObject var m: CleanerModel

    var shown: [AppChoice] {
        let q = m.query
        guard !q.isEmpty else { return m.choices }
        return m.choices.filter { $0.app.name.localizedCaseInsensitiveContains(q) || $0.app.id.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        if m.choices.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: m.loadingChoices ? "hourglass" : "app.badge.checkmark").font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text(m.loadingChoices ? "Listing apps…" : "No apps found in Applications").font(.headline)
                Text("Drop an app onto this window to see everything it would remove.").font(.callout).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("APPS IN APPLICATIONS").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(Theme.faint)
                        Spacer()
                        Text("Nothing is removed until you confirm").font(.caption2).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                    ForEach(shown) { c in AppChoiceRow(choice: c) }
                }
            }
        }
    }
}

struct AppChoiceRow: View {
    let choice: AppChoice
    @EnvironmentObject var m: CleanerModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(choice.app.path)).resizable().frame(width: 24, height: 24)
                .opacity(choice.refusal == nil ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.app.name).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(choice.refusal == nil ? Theme.text : Theme.dim)
                Text(choice.refusal ?? tilde(choice.app.path)).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            if choice.refusal == nil {
                Text("Show files").font(.caption).foregroundStyle(hover ? Theme.purple : Theme.faint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(hover && choice.refusal == nil ? Theme.purple.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { pick() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(choice.refusal == nil ? .isButton : [])
        .accessibilityAction { pick() }
        .contextMenu {
            Button("Reveal in Finder") { reveal(choice.app.path) }
        }
    }

    func pick() { if choice.refusal == nil { m.choose(choice.app.path) } }
}

// Disk tab sheets: the confirmation before any change (spec 4.3) and the result summary (spec 4.4).

import SwiftUI
import AppKit

struct ConfirmSheet: View {
    @EnvironmentObject var m: CleanerModel
    @Environment(\.dismiss) var dismiss
    @State private var quitList: [(String, [String])] = []

    var body: some View {
        let pairs = m.selectedPairs
        let trash = pairs.filter { $0.1.method == .trash }
        let tools = pairs.filter { $0.1.method == .tool }
        VStack(alignment: .leading, spacing: 14) {
            if m.kind == .uninstall, let t = m.target {
                Text("Uninstall \(t.app.name)? \(pairs.count) item\(pairs.count == 1 ? "" : "s"), up to \(byteText(m.selectedSize))").font(.title3.weight(.semibold))
                if !pairs.contains(where: { $0.1.appBundle }) {
                    Label("The app itself isn't selected, so only its files are moved.", systemImage: "info.circle").foregroundStyle(Theme.yellow)
                }
                if !t.otherCopies.isEmpty {
                    Label("Another copy of \(t.app.name) is on this Mac (\(t.otherCopies.map(tilde).joined(separator: ", "))). It may use the same settings and data: only the files you keep selected are moved.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(Theme.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Clean \(pairs.count) item\(pairs.count == 1 ? "" : "s"), up to \(byteText(m.selectedSize))?").font(.title3.weight(.semibold))
            }
            if !trash.isEmpty {
                Label("\(trash.count) moved to the Trash, \(byteText(trash.reduce(0) { $0 + $1.1.size })). Finder's Put Back returns them to where they were.",
                      systemImage: "trash").foregroundStyle(Theme.text)
            }
            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(tools.count) tool cleanup\(tools.count == 1 ? "" : "s"). These can't be undone:", systemImage: "terminal")
                        .foregroundStyle(Theme.orange)
                    ForEach(tools, id: \.1.id) { c, _ in
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(c.tool?.commands ?? [], id: \.self) { args in
                                Text(([c.tool?.executable ?? c.tool?.tool ?? ""] + args).joined(separator: " "))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let p = m.previews[c.id] {
                                ScrollView { Text(p).font(.caption2.monospaced()).foregroundStyle(Theme.dim)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                                    .frame(maxHeight: 90)
                            }
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    }
                }
            }
            if !quitList.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These apps are running. Their items are skipped unless you quit them first:").foregroundStyle(Theme.yellow)
                    ForEach(quitList, id: \.0) { name, ids in
                        HStack { Text(name); Spacer(); Button(m.dryRun ? "Quit (off in dry run)" : "Quit") { m.quit(ids); refreshSoon() }.disabled(m.dryRun) }
                    }
                }
            }
            if m.dryRun { Text("Dry run: nothing will be changed.").foregroundStyle(Theme.yellow) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.defaultAction)   // spec 4.3: Cancel is the default
                Button(m.kind.confirmButton, role: .destructive) { m.confirmClean(); dismiss() }
            }
            .background(EscapeCloses { dismiss() })
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { quitList = m.appsToQuit() }
        .task { await m.loadPreviews(tools.map(\.0)) }
    }

    func refreshSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { quitList = m.appsToQuit() } }
}

struct ResultSheet: View {
    @EnvironmentObject var m: CleanerModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let o = m.outcomes ?? []
        let moved = o.filter { $0.status == .moved }
        let ran = o.filter { $0.status == .ran }
        let planned = o.filter { $0.status == .planned }
        let skipped = o.filter { $0.status == .skipped || $0.status == .failed }
        VStack(alignment: .leading, spacing: 12) {
            Text(m.lastRunWasDry ? "Dry run finished" : m.kind.finishedTitle).font(.title3.weight(.semibold))
            if !moved.isEmpty {
                Label("\(byteText(moved.reduce(0) { $0 + $1.size })) moved to the Trash (\(moved.count) items)", systemImage: "trash")
            }
            if !ran.isEmpty {
                Label("\(byteText(ran.reduce(0) { $0 + $1.size })) freed by tool cleanups", systemImage: "terminal")
            }
            if !planned.isEmpty {
                Label("\(planned.count) actions planned, none taken (dry run)", systemImage: "eye").foregroundStyle(Theme.yellow)
            }
            if !skipped.isEmpty {
                Text("Skipped \(skipped.count):").foregroundStyle(Theme.orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(skipped.enumerated()), id: \.offset) { _, s in
                            Text("\(s.name): \(s.reason ?? s.status.rawValue)").font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
            if !moved.isEmpty {
                Text("Space in the Trash is freed when you empty it. To restore an item, right-click it in the Trash and choose Put Back.")
                    .font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            let noPutBack = moved.filter(\.movedWithoutPutBack).count
            if noPutBack > 0 {
                Text("\(noPutBack) item\(noPutBack == 1 ? " was" : "s were") moved without Finder, so Put Back isn't available for \(noPutBack == 1 ? "it" : "them"). To use Finder next time, allow App Monitor to control Finder in System Settings → Privacy & Security → Automation.")
                    .font(.callout).foregroundStyle(Theme.yellow).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !moved.isEmpty { OpenTrashButton() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

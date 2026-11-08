// Settings window (spec 4.6): age limits and the ignore list.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var m: CleanerModel
    @State private var drafts: [AgeField: String] = [:]
    @State private var errors: [AgeField: String] = [:]
    @AppStorage(AppearanceMode.key) private var appearance: AppearanceMode = .system

    let fields: [AgeField] = [.logs, .temp, .leftovers, .lowConfidence, .mail]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance").font(.headline)
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            Divider()
            Text("Age limits").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(fields, id: \.self) { f in
                    GridRow {
                        Text(f.title)
                        HStack(spacing: 4) {
                            TextField("", text: binding(f)).frame(width: 56).multilineTextAlignment(.trailing)
                                .onSubmit { commit(f) }
                                .accessibilityLabel("\(f.title), in days")
                            Text("days").foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        Text(errors[f] ?? "\(f.range(m.limits).lowerBound)–\(f.range(m.limits).upperBound)")
                            .font(.caption).foregroundStyle(errors[f] == nil ? Color.secondary : Color.red)
                    }
                }
            }
            HStack {
                Button("Restore defaults") { m.restoreDefaults(); drafts = [:]; errors = [:] }
                Spacer()
                // Applied twice, because the two leftover limits depend on each other.
                Button("Apply") { for _ in 0..<2 { fields.forEach(commit) } }.keyboardShortcut(.defaultAction)
            }
            Divider()
            Text("Ignored items").font(.headline)
            if m.ignore.isEmpty {
                Text("None. Right-click an item in the Disk tab and choose “Always ignore this item”.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(m.ignore, id: \.self) { p in
                            HStack {
                                Text(tilde(p)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Remove") { m.unignore(p) }.accessibilityLabel("Remove \(tilde(p)) from the ignore list")
                            }
                        }
                    }
                }.frame(maxHeight: 140)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func binding(_ f: AgeField) -> Binding<String> {
        Binding(get: { drafts[f] ?? String(m.limits[f]) }, set: { drafts[f] = $0 })
    }

    func commit(_ f: AgeField) {
        guard let text = drafts[f] else { return }
        guard let v = Int(text.trimmingCharacters(in: .whitespaces)) else { errors[f] = "Enter a whole number of days"; return }
        if let why = m.setLimit(f, v) { errors[f] = why } else { errors[f] = nil; drafts[f] = nil }
    }
}

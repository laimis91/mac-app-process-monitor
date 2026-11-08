// Disk tab (spec 4): small views and wording shared by the Junk, Leftovers and Uninstaller
// lists and the Space map. The views themselves are in DiskTabView, ResultRows, UninstallerViews,
// DiskPanels, CleanerSheets and SettingsView.

import SwiftUI
import AppKit

extension Risk {
    var color: Color {
        switch self {
        case .safe: return Theme.green
        case .review: return Theme.yellow
        case .requested: return Theme.cyan
        case .info: return Theme.dim
        }
    }
}

func ageLabel(_ d: Date?) -> String {
    guard let n = days(since: d, now: Date()) else { return "recently used" }
    return n == 0 ? "changed today" : n == 1 ? "1 day old" : "\(n) days old"
}

/// "just now", or how long ago, e.g. "5 minutes ago".
func sinceText(_ d: Date, now: Date = Date()) -> String {
    now.timeIntervalSince(d) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: d, relativeTo: now)
}

func openTrash() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }

extension Outcome {
    /// Moved without Finder (no Automation permission), so Finder's Put Back can't return it.
    /// The engine reports this as the outcome's reason.
    var movedWithoutPutBack: Bool { status == .moved && reason == "Moved without Put Back" }
}

/// Wording that differs between the three results lists.
extension CleanerKind {
    var cleanButton: String { self == .leftovers ? "Move to Trash…" : self == .uninstall ? "Uninstall…" : "Clean…" }
    var confirmButton: String { self == .junk ? "Clean" : "Move to Trash" }
    var finishedTitle: String { self == .uninstall ? "Uninstall finished" : "Cleaning finished" }
    var groups: [CategoryGroup] {
        switch self {
        case .junk: return [.general, .developer]
        case .leftovers: return [.leftovers, .possible]
        case .uninstall: return [.uninstall, .kept]
        }
    }
    /// The toolbar text before the first scan.
    var intro: String {
        self == .leftovers ? "Finds data left behind by apps that are no longer on this Mac."
            : "Finds caches, logs, temporary files and developer caches you can remove."
    }
    var emptyIcon: String { self == .leftovers ? "app.dashed" : "internaldrive" }
    func emptyTitle(scanned: Bool) -> String {
        self == .leftovers ? (scanned ? "No leftovers found" : "Scan to find data of removed apps") : "Scan to see what you can clean"
    }
    func emptyDetail(_ limits: AgeLimits) -> String {
        self == .leftovers
            ? "Only data whose app is gone from this Mac, unchanged for \(limits.leftovers) days or more, is listed. Nothing is pre-selected."
            : "Nothing is removed without your confirmation. Files go to the Trash, so you can restore them."
    }
    /// What an opened category with no items says.
    func emptyCategoryText(_ c: Category) -> String {
        self == .junk ? c.notice ?? "Nothing to clean here." : c.notice.map { "\($0). \(c.explanation)" } ?? "Nothing to clean here."
    }
}

extension DiskView {
    var footer: String {
        switch self {
        case .spaceMap:
            return "Sizes are space used on disk, as du counts it  ·  Only items you pick one at a time can go to the Trash; everything in ~/Library is Reveal only"
        case .leftovers:
            return "Leftovers are never pre-selected: check each one  ·  Sizes are upper estimates  ·  Moved items stay in the Trash until you empty it"
        case .uninstall:
            return "Drop an app onto this window, or pick one  ·  The app and its files go to the Trash, so Put Back works  ·  Apps that come with macOS can't be removed"
        case .junk:
            return "Sizes are upper estimates: APFS clones and snapshots can make the real gain smaller  ·  Moved items stay in the Trash until you empty it"
        }
    }
}

struct CheckBox: View {
    let label: String         // what it selects, for VoiceOver
    let state: Bool?          // nil = mixed
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : state == nil ? "minus.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(enabled ? (state == false ? Theme.dim : Theme.purple) : Theme.faint.opacity(0.5))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue(state == true ? "Checked" : state == nil ? "Mixed" : "Unchecked")
    }
}

/// The filter field of a toolbar.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .frame(maxWidth: 240)
    }
}

/// "Show 100 more (n not shown)" at the end of a long list shown a page at a time.
struct ShowMoreRow: View {
    let left: Int
    let pageSize: Int
    let leading: CGFloat
    let action: () -> Void
    var body: some View {
        HStack {
            Button("Show \(min(left, pageSize)) more (\(left) not shown)", action: action)
                .buttonStyle(.link).font(.caption)
            Spacer()
        }
        .padding(.leading, leading).padding(.vertical, 6)
    }
}

struct OpenTrashButton: View {
    var body: some View { Button("Open Trash") { openTrash() } }
}

/// Escape closes a sheet whose default button isn't Cancel's `.cancelAction` (spec 4.3: Cancel
/// is the default, so Return cancels too).
struct EscapeCloses: View {
    let action: () -> Void
    var body: some View {
        Button("", action: action).keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}

// Theme: light and dark palettes, the appearance setting, and the shared pill controls.

import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, _ opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// A colour that follows the window's appearance: `light` in Light mode, `dark` in Dark mode.
    static func adaptive(_ light: UInt32, _ dark: UInt32, light la: Double = 1, dark da: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (hex, a) = isDark ? (dark, da) : (light, la)
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(a))
        })
    }
}

enum Theme {
    // Surfaces
    static let bg = Color.adaptive(0xE9EAE6, 0x0F1012)
    static let bgTop = Color.adaptive(0xF4F4F1, 0x17181B)
    static let panel = Color.adaptive(0xFFFFFF, 0x1B1C20, light: 0.72)
    static let stroke = Color.adaptive(0x000000, 0xFFFFFF, light: 0.07, dark: 0.07)
    /// Empty part of rings, bars and tracks.
    static let track = Color.adaptive(0x000000, 0xFFFFFF, light: 0.07, dark: 0.08)
    /// Fields and quiet buttons.
    static let field = Color.adaptive(0xFFFFFF, 0xFFFFFF, light: 0.85, dark: 0.06)
    /// Row hover and expanded-row tint.
    static let hover = Color.adaptive(0x000000, 0xFFFFFF, light: 0.035, dark: 0.04)
    static let shadow = Color.adaptive(0x000000, 0x000000, light: 0.06, dark: 0.35)
    /// The strong pill: selected tab, primary button.
    static let ink = Color.adaptive(0x1B1B1D, 0xF1F1F2)
    static let onInk = Color.adaptive(0xFFFFFF, 0x111214)

    // Text
    static let text = Color.adaptive(0x18191B, 0xECEDEF)
    static let dim = Color.adaptive(0x6C7077, 0x9A9EA6)
    static let faint = Color.adaptive(0x83878E, 0x7A7F87)

    // Accents
    static let purple = Color.adaptive(0x5B3FE0, 0x8B6CFF)
    static let cyan = Color.adaptive(0x0B7A8F, 0x22D3EE)
    static let green = Color.adaptive(0x1A8541, 0x3FB950)
    static let yellow = Color.adaptive(0x8F6300, 0xE3B341)
    static let orange = Color.adaptive(0xC85F00, 0xF5953C)
    static let red = Color.adaptive(0xE0393E, 0xF85149)
    static let pink = Color.adaptive(0xD1478F, 0xDB61A2)
    /// Free memory in the memory bar.
    static let free = Color.adaptive(0x000000, 0xFFFFFF, light: 0.12, dark: 0.18)
    static let accent = LinearGradient(colors: [purple, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let mono = Font.system(.body, design: .monospaced)

    /// Green → yellow → orange → red as load goes 0 → 1.
    static func heat(_ v: Double) -> Color {
        switch v {
        case ..<0.25: return green
        case ..<0.5: return yellow
        case ..<0.8: return orange
        default: return red
        }
    }
    /// Colour for a per-process CPU value (100 = one full core).
    static func cpuHeat(_ cpu: Double) -> Color { cpu < 5 ? dim : heat(cpu / 100) }
}

// MARK: - Appearance setting

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    static let key = "appearance"

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Sets the whole app's appearance, so every window (Settings too) and every adaptive colour follows.
    func apply() {
        NSApp?.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The saved choice. APPMON_APPEARANCE=light|dark overrides it in debug builds (screenshots).
    static var initial: AppearanceMode {
        #if APPMON_DEBUG
        if let e = ProcessInfo.processInfo.environment["APPMON_APPEARANCE"],
           let m = AppearanceMode.allCases.first(where: { $0.rawValue.lowercased() == e.lowercased() }) { return m }
        #endif
        return AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }
}

/// Small round button in the title bar that picks System, Light or Dark. RootView applies the change.
struct AppearanceButton: View {
    @AppStorage(AppearanceMode.key) private var mode: AppearanceMode = AppearanceMode.initial
    var body: some View {
        Menu {
            Picker("Appearance", selection: $mode) {
                ForEach(AppearanceMode.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }.pickerStyle(.inline)
        } label: {
            Image(systemName: mode.icon).font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .background(Circle().fill(Theme.field))
        .overlay(Circle().strokeBorder(Theme.stroke))
        .help("Appearance: \(mode.rawValue)")
        .accessibilityLabel("Appearance")
        .accessibilityValue(mode.rawValue)
    }
}

// MARK: - Pill segmented control

/// The reference look's tab strip: a soft capsule with the selected item as a dark (light in Dark mode) pill.
struct PillPicker<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let items: [T]
    var icon: (T) -> String? = { _ in nil }
    let label: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selection = item }
                } label: {
                    HStack(spacing: 5) {
                        if let i = icon(item) { Image(systemName: i).font(.system(size: 11, weight: .semibold)) }
                        Text(label(item)).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.onInk : Theme.dim)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if on { Capsule().fill(Theme.ink).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(item))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The main action button: a dark pill (light in Dark mode).
struct PrimaryButton: View {
    let icon: String
    let text: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon); Text(text) }
                .font(.callout.weight(.semibold))
                .foregroundStyle(enabled ? Theme.onInk : Theme.faint)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(enabled ? Theme.ink.opacity(hover ? 0.85 : 1) : Theme.track))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// Soft background for a page: a faint gradient from top to middle.
struct PageBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.bgTop, Theme.bg], startPoint: .top, endPoint: .center).ignoresSafeArea()
    }
}

/// Card surface used by panels and lists.
extension View {
    func card(radius: CGFloat = 18) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.panel)
                .shadow(color: Theme.shadow, radius: 10, y: 3))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke))
    }
}

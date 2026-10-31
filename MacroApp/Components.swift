import SwiftUI
import AppKit
import Observation

enum MacroPalette {
    static let recording = Color(red: 0.92, green: 0.20, blue: 0.24)
    static let keyboard = Color.blue
    static let timing = Color.orange
    static let mouse = Color.purple
}

enum AppearancePalette: String, CaseIterable, Identifiable {
    case current, graphite, highContrast

    var id: Self { self }
    var title: String {
        switch self {
        case .current: "Current"
        case .graphite: "Graphite"
        case .highContrast: "High Contrast"
        }
    }
    var description: String {
        switch self {
        case .current: "The original deep blue palette"
        case .graphite: "Softer neutral surfaces"
        case .highContrast: "Stronger borders and clearer separation"
        }
    }

    var previewColors: [Color] {
        [colors.window, colors.panel, colors.raised, colors.accent].map { hex in
            Color(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
        }
    }

    fileprivate var colors: ThemeColors {
        switch self {
        case .current:
            ThemeColors(window: 0x060C13, toolbar: 0x09111B, sidebar: 0x081019,
                        panel: 0x0A1420, canvas: 0x050B11, card: 0x0E1925,
                        raised: 0x121F2D, border: 0x1F3348, accent: 0x0E79FF, grid: 0x30526E)
        case .graphite:
            ThemeColors(window: 0x12171D, toolbar: 0x1B222A, sidebar: 0x171D24,
                        panel: 0x1E2630, canvas: 0x10161C, card: 0x26313C,
                        raised: 0x30404D, border: 0x455969, accent: 0x6AAEFF, grid: 0x647B8A)
        case .highContrast:
            ThemeColors(window: 0x07090B, toolbar: 0x101419, sidebar: 0x0B1015,
                        panel: 0x151C24, canvas: 0x05080B, card: 0x1D2833,
                        raised: 0x293949, border: 0x688097, accent: 0x69B5FF, grid: 0x7890A3)
        }
    }
}

private struct ThemeColors {
    let window, toolbar, sidebar, panel, canvas, card, raised, border, accent, grid: UInt32
}

@Observable
final class AppearanceThemeStore {
    static let shared = AppearanceThemeStore()
    private static let defaultsKey = "AppearancePalette"

    var selected: AppearancePalette {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        selected = AppearancePalette(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .current
    }
}

/// Shared application colors. Reading the observable selection here refreshes
/// every SwiftUI surface that uses a theme token when the palette changes.
enum MacroTheme {
    private static var colors: ThemeColors { AppearanceThemeStore.shared.selected.colors }
    private static var isCurrent: Bool { AppearanceThemeStore.shared.selected == .current }
    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    static var window: Color { isCurrent ? Color(red: 0.025, green: 0.047, blue: 0.073) : color(colors.window) }
    static var toolbar: Color { isCurrent ? Color(red: 0.035, green: 0.067, blue: 0.105) : color(colors.toolbar) }
    static var sidebar: Color { isCurrent ? Color(red: 0.030, green: 0.061, blue: 0.096) : color(colors.sidebar) }
    static var panel: Color { isCurrent ? Color(red: 0.040, green: 0.078, blue: 0.120) : color(colors.panel) }
    static var canvas: Color { isCurrent ? Color(red: 0.018, green: 0.043, blue: 0.068) : color(colors.canvas) }
    static var card: Color { isCurrent ? Color(red: 0.055, green: 0.098, blue: 0.145) : color(colors.card) }
    static var raised: Color { isCurrent ? Color(red: 0.071, green: 0.122, blue: 0.177) : color(colors.raised) }
    static var border: Color { isCurrent ? Color(red: 0.120, green: 0.200, blue: 0.282) : color(colors.border) }
    static var accent: Color { isCurrent ? Color(red: 0.055, green: 0.475, blue: 1.000) : color(colors.accent) }
    static var grid: Color { isCurrent ? Color(red: 0.190, green: 0.320, blue: 0.430) : color(colors.grid) }
}

/// A native AppKit button used for the recorder's critical controls.
///
/// SwiftUI's macOS button gesture currently crashes in `_ButtonGesture` on the
/// OS/Xcode combination this app is being run with. Keeping Play/Stop/Record in
/// an NSButton avoids that gesture path while still allowing SwiftUI to own the
/// surrounding layout and enabled state.
struct AppKitActionButton: NSViewRepresentable {
    enum Style {
        case toolbar
        case prominent
        case recordingCircle
    }

    var title: String?
    var systemImage: String
    var style: Style = .toolbar
    var isEnabled = true
    var help: String?
    var action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction(_:))
        button.focusRingType = .none
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.title = title ?? ""
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.isEnabled = isEnabled
        button.toolTip = help

        switch style {
        case .toolbar:
            button.bezelStyle = .texturedRounded
            button.imagePosition = title == nil ? .imageOnly : .imageLeading
            button.controlSize = .regular
            button.contentTintColor = .labelColor
        case .prominent:
            button.bezelStyle = .rounded
            button.imagePosition = .imageLeading
            button.controlSize = .large
            button.keyEquivalent = ""
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        case .recordingCircle:
            button.bezelStyle = .circular
            button.imagePosition = .imageOnly
            button.controlSize = .large
            button.bezelColor = NSColor(red: 0.92, green: 0.20, blue: 0.24, alpha: 1)
            button.contentTintColor = .white
            button.imageScaling = .scaleProportionallyUpOrDown
        }
    }

    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSButton) {
            // Let AppKit finish dispatching the control event before the action
            // changes SwiftUI state or tears down input monitors.
            DispatchQueue.main.async { [weak self] in
                self?.action()
            }
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MacroPalette.recording, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(.white.opacity(0.95), lineWidth: max(2, size * 0.08))
                .frame(width: size * 0.48, height: size * 0.48)
            Circle()
                .fill(.white)
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .shadow(color: MacroPalette.recording.opacity(0.25), radius: 8, y: 3)
        .accessibilityHidden(true)
    }
}

struct AppCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(MacroTheme.card)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(MacroTheme.border.opacity(0.75), lineWidth: 1)
            }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}

/// The shared search control used by library panels across the app.
/// Keeping this as a view (instead of relying on the native rounded field)
/// makes the search experience consistent on Macros and Automation.
struct AppSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFocused ? MacroTheme.accent : .secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .font(.callout)
                .foregroundStyle(.primary)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(MacroTheme.raised.opacity(isFocused ? 0.95 : 0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isFocused ? MacroTheme.accent.opacity(0.85) : MacroTheme.border.opacity(0.9), lineWidth: isFocused ? 1.25 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .accessibilityLabel(placeholder)
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MacroTheme.raised.opacity(0.9))
                    .shadow(color: .black.opacity(0.09), radius: 0, y: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(MacroTheme.border, lineWidth: 1)
            }
    }
}

struct HotkeyRecorderButton: View {
    let shortcut: HotkeyShortcut
    let onChange: (HotkeyShortcut) -> Void
    @StateObject private var capture = HotkeyCaptureSession()

    var body: some View {
        Button {
            capture.begin(onCapture: onChange)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: capture.isCapturing ? "keyboard.badge.ellipsis" : "keyboard")
                Text(capture.isCapturing ? "Press shortcut…" : shortcut.displayName)
                    .monospaced()
                if !capture.isCapturing {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 132)
        }
        .buttonStyle(.bordered)
        .tint(capture.isCapturing ? MacroPalette.recording : .accentColor)
        .onDisappear { capture.end() }
        .help(capture.isCapturing ? "Press Escape to cancel" : "Click, then press a new shortcut")
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.1), in: Capsule())
    }
}

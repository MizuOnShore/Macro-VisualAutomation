import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var eventPostingGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var lastChecked = Date()

    init() {
        refresh()
    }

    /// Checks authorization without displaying a system prompt.
    func refresh() {
        let newAccessibilityGranted = AXIsProcessTrusted()
        let newEventPostingGranted = CGPreflightPostEventAccess()
        let newInputMonitoringGranted = CGPreflightListenEventAccess()

        if accessibilityGranted != newAccessibilityGranted {
            accessibilityGranted = newAccessibilityGranted
        }
        if eventPostingGranted != newEventPostingGranted {
            eventPostingGranted = newEventPostingGranted
        }
        if inputMonitoringGranted != newInputMonitoringGranted {
            inputMonitoringGranted = newInputMonitoringGranted
        }
        lastChecked = .now
    }

    /// Requests the system-managed Accessibility prompt. The call returns before
    /// the user makes a choice, so status is refreshed again when the app activates.
    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
        refresh()
    }

    /// Requests permission to observe global keyboard and mouse events. This is
    /// separate from Accessibility and will be used by recording/emergency stop.
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

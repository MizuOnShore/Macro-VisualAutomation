import AppKit
import SwiftUI

@main
@MainActor
struct AutomationVisualSnapshot {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { return }
        let model = AppModel(
            targetManager: SnapshotTargets(),
            storage: SnapshotMacroStorage(),
            automationStorage: SnapshotAutomationStorage(),
            permissionManager: PermissionManager()
        )
        if CommandLine.arguments.count >= 3,
           let destination = SidebarDestination.allCases.first(where: {
               $0.rawValue.lowercased() == CommandLine.arguments[2].lowercased()
           }) {
            model.destination = destination
        } else {
            model.destination = .automation
        }

        let width = CommandLine.arguments.count >= 4 ? (Double(CommandLine.arguments[3]) ?? 1180) : 1180
        let height = CommandLine.arguments.count >= 5 ? (Double(CommandLine.arguments[4]) ?? 760) : 760
        let root = RootView()
            .environmentObject(model)
            .environmentObject(model.permissionManager)
            .frame(width: width, height: height)
            .preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        model.shutdown()
    }
}

private struct SnapshotMacroStorage: MacroStoring {
    func loadLibrary() throws -> [MacroDefinition] { [.example] }
    func saveLibrary(_ macros: [MacroDefinition]) throws {}
}

private struct SnapshotAutomationStorage: AutomationStoring {
    func loadAutomations() throws -> [AutomationDefinition] { [] }
    func saveAutomations(_ automations: [AutomationDefinition]) throws {}
}

private struct SnapshotTargets: TargetDiscovering {
    func discoverWindows() throws -> [TargetWindow] { [] }
}

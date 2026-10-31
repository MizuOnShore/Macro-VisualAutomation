import SwiftUI

@main
struct MacroApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(appModel.permissionManager)
                .frame(minWidth: 720, minHeight: 500)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandMenu("Macro") {
                Button("Play Selected Macro") { appModel.start() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!appModel.canStart)
                Button(appModel.runState == .paused ? "Resume" : "Pause") {
                    appModel.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!appModel.canPause)
                Button("Stop Recording or Playback") { appModel.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!appModel.canStop)
                Divider()
                Button("New Macro") { appModel.createMacro() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Save Macro Library") { appModel.saveLibrary() }
                    .keyboardShortcut("s", modifiers: [.command])
                Divider()
                Button(appModel.recording ? "Stop Recording" : "Start Recording") {
                    appModel.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .environmentObject(appModel.permissionManager)
                .frame(width: 620, height: 430)
        }
    }
}

import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brandHeader
                Divider().opacity(0.55)

                List(SidebarDestination.allCases, selection: $model.destination) { destination in
                    Label(destination.rawValue, systemImage: destination.symbol)
                        .font(.body.weight(model.destination == destination ? .semibold : .regular))
                        .padding(.vertical, 4)
                        .tag(destination)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                sidebarStatus
            }
            .background(MacroTheme.sidebar)
            .navigationSplitViewColumnWidth(min: 155, ideal: 190, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if model.destination != .automation {
                    appHeader
                    Divider().opacity(0.55)
                }

                Group {
                    switch model.destination ?? .macros {
                    case .macros: MacrosView()
                    case .recorder: RecorderView()
                    case .target: TargetSelectionView()
                    case .logs: LogsView()
                    case .automation: AutomationView(store: model.automationStore)
                    case .settings: SettingsView()
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .background(MacroTheme.window)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(MacroTheme.toolbar, for: .windowToolbar)
        .tint(MacroTheme.accent)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.shutdown()
            RecordingHUDController.shared.hide()
        }
        .onAppear { RecordingHUDController.shared.sync(model: model) }
        .onChange(of: model.recording) { _, _ in RecordingHUDController.shared.sync(model: model) }
        .onChange(of: model.recordingCountdown) { _, _ in RecordingHUDController.shared.sync(model: model) }
        .alert("Macro", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "Unknown error")
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 11) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Macro").font(.title3.weight(.bold))
                Text("Automation studio").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 13)
    }

    private var sidebarStatus: some View {
        VStack(spacing: 10) {
            Divider().opacity(0.55)

            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(model.selectedTarget == nil ? Color.secondary.opacity(0.12) : Color.green.opacity(0.14))
                    Image(systemName: "scope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.selectedTarget == nil ? Color.secondary : Color.green)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedTarget?.applicationName ?? "No target")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(model.selectedTarget == nil ? "Choose a window" : "Window connected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 7) {
                Circle().fill(activityColor).frame(width: 7, height: 7)
                Text(model.activityLabel)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
    }

    private var activityColor: Color {
        if model.recording || model.recordingCountdown != nil { return MacroPalette.recording }
        switch model.runState {
        case .running: return .green
        case .paused: return .orange
        case .idle: return .secondary
        }
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            if let destination = model.destination {
                Image(systemName: destination.symbol)
                    .foregroundStyle(MacroTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(MacroTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                Text(destination.rawValue)
                    .font(.title3.weight(.semibold))
            }

            HStack(spacing: 7) {
                Circle().fill(activityColor).frame(width: 7, height: 7)
                Text(model.activityLabel).font(.caption.weight(.medium))
                if let target = model.selectedTarget {
                    Text("·").foregroundStyle(.tertiary)
                    Text(target.applicationName).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(MacroTheme.raised, in: Capsule())

            Spacer(minLength: 8)

            if model.destination == .target {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshTargets() }
                    .buttonStyle(.bordered)
                    .disabled(model.isRefreshingTargets)
            } else if model.destination == .logs {
                Button("Clear", systemImage: "trash") { model.logs.removeAll() }
                    .buttonStyle(.bordered)
                    .disabled(model.logs.isEmpty)
            }

            AppKitActionButton(
                title: "Play",
                systemImage: "play.fill",
                isEnabled: model.canStart,
                help: "Play · \(model.hotkeys.play.displayName)",
                action: model.start
            )
            .frame(width: 70, height: 28)

            AppKitActionButton(
                title: nil,
                systemImage: model.runState == .paused ? "play.fill" : "pause.fill",
                isEnabled: model.canPause,
                help: model.runState == .paused ? "Resume" : "Pause",
                action: model.togglePause
            )
            .frame(width: 30, height: 28)

            AppKitActionButton(
                title: nil,
                systemImage: "stop.fill",
                isEnabled: model.canStop,
                help: "Stop · \(model.hotkeys.stop.displayName)",
                action: model.stop
            )
            .frame(width: 30, height: 28)
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(MacroTheme.toolbar)
    }
}

@MainActor
private final class RecordingHUDController {
    static let shared = RecordingHUDController()
    private var panel: NSPanel?

    func sync(model: AppModel) {
        guard model.recording || model.recordingCountdown != nil else {
            hide()
            return
        }
        if panel == nil {
            let hud = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 78),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            hud.isFloatingPanel = true
            hud.becomesKeyOnlyIfNeeded = true
            hud.hidesOnDeactivate = false
            hud.level = .floating
            hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            hud.isOpaque = false
            hud.backgroundColor = .clear
            hud.hasShadow = false
            hud.contentView = NSHostingView(rootView: RecordingStatusHUD(model: model))
            panel = hud
        }
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 18))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct RecordingStatusHUD: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let countdown = model.recordingCountdown {
                Text("\(countdown)")
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .frame(minWidth: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording starts in")
                        .font(.callout.weight(.semibold))
                    Text("Switch to your target window")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
                Button("Cancel") { model.toggleRecording() }
                    .buttonStyle(HUDButtonStyle())
                    .help("Cancel recording countdown · \(model.hotkeys.stop.displayName)")
            } else {
                Circle()
                    .fill(MacroPalette.recording)
                    .frame(width: 9, height: 9)
                    .shadow(color: MacroPalette.recording.opacity(0.75), radius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording")
                        .font(.callout.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(recordingTime(at: context.date))
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.82))
                            .contentTransition(.numericText())
                    }
                }
                .frame(minWidth: 135, alignment: .leading)
                Button {
                    model.toggleRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .background(MacroPalette.recording, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Stop recording · \(model.hotkeys.stop.displayName)")
                .accessibilityLabel("Stop recording")
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .background(MacroTheme.sidebar.opacity(0.92), in: Capsule())
        .overlay { Capsule().stroke(MacroPalette.recording.opacity(0.42), lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 7)
        .accessibilityElement(children: .contain)
    }

    private func recordingTime(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(model.recordingStartedAt ?? date)))
        let hours = elapsed / 3_600
        let minutes = (elapsed / 60) % 60
        let seconds = elapsed % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", elapsed / 60, seconds)
    }
}

private struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(configuration.isPressed ? 0.24 : 0.14), in: Capsule())
            .foregroundStyle(.white)
    }
}

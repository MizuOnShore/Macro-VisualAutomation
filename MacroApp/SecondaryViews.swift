import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Capture")
                    Text("Recorder")
                        .font(.largeTitle.weight(.bold))
                    Text("Keyboard, mouse clicks, pointer movement, and timing—captured automatically.")
                        .foregroundStyle(.secondary)
                }

                AppCard(padding: 24) {
                    HStack(spacing: 28) {
                        ZStack {
                            Circle()
                                .fill(MacroPalette.recording.opacity(model.recording ? 0.16 : 0.08))
                                .frame(width: 126, height: 126)
                            Circle()
                                .stroke(MacroPalette.recording.opacity(0.18), lineWidth: 1)
                                .frame(width: 105, height: 105)
                            AppKitActionButton(
                                title: nil,
                                systemImage: model.recording ? "stop.fill" : model.recordingCountdown != nil ? "xmark" : "record.circle.fill",
                                style: .recordingCircle,
                                isEnabled: model.recording || model.recordingCountdown != nil || model.runState == .idle,
                                help: model.recording ? "Stop recording" : "Start recording",
                                action: model.toggleRecording
                            )
                            .frame(width: 76, height: 76)
                            .shadow(color: MacroPalette.recording.opacity(0.3), radius: 14, y: 5)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(model.recording || model.recordingCountdown != nil ? MacroPalette.recording : .secondary)
                                    .frame(width: 8, height: 8)
                                Text(model.recordingCountdown.map { "STARTING IN \($0)" } ?? (model.recording ? "RECORDING" : "READY TO RECORD"))
                                    .font(.caption.weight(.bold))
                                    .tracking(0.8)
                                    .foregroundStyle(model.recording || model.recordingCountdown != nil ? MacroPalette.recording : .secondary)
                            }

                            Text(model.recordingCountdown != nil ? "Switch to your target" : model.recording ? "Capturing your input" : "Create the next sequence")
                                .font(.title.weight(.bold))

                            Text(model.recordingCountdown != nil
                                 ? "Recording begins after the countdown. Press Stop or F7 to cancel."
                                 : model.recording
                                    ? "\(model.recordedActionCount) actions captured. Use the Stop hotkey when you are finished."
                                    : model.recordingResultMessage ?? "Start here, switch to your target window, and perform the keyboard and mouse actions you want to replay.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                AppKitActionButton(
                                    title: model.recording ? "Stop Recording" : model.recordingCountdown != nil ? "Cancel Countdown" : "Start Recording",
                                    systemImage: model.recording ? "stop.fill" : model.recordingCountdown != nil ? "xmark" : "record.circle.fill",
                                    style: .prominent,
                                    isEnabled: model.recording || model.recordingCountdown != nil || model.runState == .idle,
                                    action: model.toggleRecording
                                )
                                .frame(width: 170, height: 32)

                                Keycap(text: model.recording || model.recordingCountdown != nil ? model.hotkeys.stop.displayName : model.hotkeys.record.displayName)
                            }
                            if !model.recording && model.recordingCountdown == nil && model.recordingResultMessage != nil {
                                Button("View saved macro", systemImage: "rectangle.stack") {
                                    model.destination = .macros
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(MacroTheme.accent)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        recordingInfoCard
                        targetInfoCard
                    }
                    VStack(spacing: 12) {
                        recordingInfoCard
                        targetInfoCard
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Global controls")
                    HStack(spacing: 10) {
                        hotkeyCard(title: "Record", symbol: "record.circle", shortcut: model.hotkeys.record, color: MacroPalette.recording)
                        hotkeyCard(title: "Stop", symbol: "stop.fill", shortcut: model.hotkeys.stop, color: .orange)
                        hotkeyCard(title: "Play", symbol: "play.fill", shortcut: model.hotkeys.play, color: .green)
                    }
                }

                if !permissions.inputMonitoringGranted {
                    AppCard {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Input Monitoring is required").font(.headline)
                                Text("Grant access to the compiled Macro.app, then relaunch it.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open Settings") { permissions.openInputMonitoringSettings() }
                        }
                    }
                }
            }
            .frame(maxWidth: 850)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background(MacroTheme.window)
        .onAppear { permissions.refresh() }
    }

    private func recorderInfo(title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingInfoCard: some View {
        AppCard {
            recorderInfo(
                title: "New macro for every recording",
                subtitle: "Saved and selected automatically when you press Stop",
                symbol: "waveform.path",
                color: .blue
            )
        }
    }

    private var targetInfoCard: some View {
        AppCard {
            recorderInfo(
                title: model.selectedTarget?.applicationName ?? "No target selected",
                subtitle: model.selectedTarget == nil ? "Mouse positions use screen coordinates" : "Mouse positions are window-relative",
                symbol: "scope",
                color: model.selectedTarget == nil ? .orange : .green
            )
        }
    }

    private func hotkeyCard(title: String, symbol: String, shortcut: HotkeyShortcut, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            Keycap(text: shortcut.displayName)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(MacroTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(MacroTheme.border.opacity(0.7)) }
    }

}

struct TargetSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingWindowID: TargetWindow.ID?
    @State private var searchText = ""

    private var filteredTargets: [TargetWindow] {
        guard !searchText.isEmpty else { return model.availableTargets }
        return model.availableTargets.filter { target in
            target.applicationName.localizedCaseInsensitiveContains(searchText)
                || target.windowTitle.localizedCaseInsensitiveContains(searchText)
                || (target.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
                || String(target.processIdentifier).contains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Available Windows")
                                .font(.headline)
                            Spacer()
                            Text("\(filteredTargets.count)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(MacroTheme.raised, in: Capsule())
                        }
                        AppSearchField(placeholder: "Search apps or windows", text: $searchText)
                    }
                    .padding(12)
                    .background(MacroTheme.sidebar)

                    if model.availableTargets.isEmpty {
                        ContentUnavailableView(
                            "No Application Windows",
                            systemImage: "macwindow.badge.plus",
                            description: Text(model.targetDiscoveryMessage)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredTargets.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("No Matching Windows")
                                .font(.headline)
                            Text("No window matches “\(searchText)”. Try another name or process ID.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Button("Clear Search") { searchText = "" }
                                .buttonStyle(.borderless)
                                .foregroundStyle(MacroTheme.accent)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(MacroTheme.window)
                    } else {
                        List(filteredTargets, selection: $pendingWindowID) { target in
                            TargetWindowRow(target: target)
                                .tag(target.id)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(MacroTheme.sidebar)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    HStack {
                        Text(model.targetDiscoveryMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.isRefreshingTargets { ProgressView().controlSize(.small) }
                    }
                    .padding(10)
                }
                .frame(minWidth: 220, idealWidth: 340, maxWidth: 400, maxHeight: .infinity, alignment: .top)

                Divider()

                Form {
                    Section("Selected Target") {
                        LabeledContent("Application") {
                            Text(model.selectedTarget?.applicationName ?? "Not selected")
                                .foregroundStyle(model.selectedTarget == nil ? .secondary : .primary)
                        }
                        LabeledContent("Window") { Text(model.selectedTarget?.windowTitle ?? "—").foregroundStyle(.secondary) }
                        LabeledContent("Process ID") {
                            Text(model.selectedTarget.map { String($0.processIdentifier) } ?? "—")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        LabeledContent("Bundle ID") {
                            Text(model.selectedTarget?.bundleIdentifier ?? "Unavailable")
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        }
                        LabeledContent("Window size") { Text(model.selectedTarget?.dimensions ?? "—").foregroundStyle(.secondary) }
                        LabeledContent("Status") {
                            StatusPill(
                                text: model.selectedTarget.map { $0.isOnScreen ? "Visible on this Space" : "Other Space or hidden" } ?? "No target",
                                color: model.selectedTarget == nil ? .secondary : .green
                            )
                        }
                    }

                    Section("Selection") {
                        Button("Select Highlighted Window") {
                            model.selectTarget(id: pendingWindowID)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pendingWindowID == nil)

                        Button("Clear Target", role: .destructive) { model.clearTarget() }
                            .disabled(model.selectedTarget == nil)
                    }

                    Section("Input Test") {
                        LabeledContent("Test action") {
                            Picker("", selection: $model.diagnosticAction) {
                                ForEach(TestInputAction.allCases) { action in Text(action.rawValue).tag(action) }
                            }
                                .labelsHidden()
                                .frame(width: 160)
                        }
                        Button("Send Test Input") { model.sendTestInput() }
                            .disabled(model.selectedTarget == nil)
                        Text(model.diagnosticMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.selectedTarget?.applicationName.localizedCaseInsensitiveContains("roblox") == true {
                        Section("Roblox Compatibility") {
                            Label("Background receipt is unverified and may require focus", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Roblox may read focused HID/game input rather than process-posted Quartz events. A successful attempt only means macOS accepted the event; it does not prove Roblox consumed it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Text("Window discovery and PID-targeted tests do not activate the selected application or move the physical cursor. Some window titles may appear as “Untitled Window” when macOS does not expose them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(MacroTheme.panel)
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.window)
        .onAppear {
            if model.availableTargets.isEmpty { model.refreshTargets() }
            pendingWindowID = model.selectedTarget?.id
        }
    }
}

private struct TargetWindowRow: View {
    let target: TargetWindow

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSRunningApplication(processIdentifier: target.processIdentifier)?.icon ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(target.applicationName)
                    .font(.body.weight(.medium))
                Text(target.windowTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("PID \(target.processIdentifier) · \(target.dimensions)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if !target.isOnScreen {
                    Text("Other Space or hidden")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("TIME").frame(width: 88, alignment: .leading)
                Text("LEVEL").frame(width: 70, alignment: .leading)
                Text("MESSAGE").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(MacroTheme.toolbar)

            Divider().overlay(MacroTheme.border.opacity(0.65))

            if model.logs.isEmpty {
                ContentUnavailableView("No Logs Yet", systemImage: "text.alignleft", description: Text("Activity and playback messages will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 88, alignment: .leading)
                                Text(label(for: entry.level))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 70, alignment: .leading)
                                Text(entry.message)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Divider()
                                .overlay(MacroTheme.border.opacity(0.35))
                                .padding(.leading, 14)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.window)
    }

    private func label(for level: LogEntry.Level) -> String {
        switch level { case .info: "Info"; case .warning: "Warning"; case .error: "Error" }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level { case .info: .secondary; case .warning: .orange; case .error: .red }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.symbol)
                            .font(.callout.weight(selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedTab == tab ? .white : .secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(selectedTab == tab ? MacroTheme.accent.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(selectedTab == tab ? MacroTheme.accent.opacity(0.55) : MacroTheme.border.opacity(0.5), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .background(MacroTheme.toolbar)

            Divider().overlay(MacroTheme.border.opacity(0.6))

            Group {
                switch selectedTab {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .hotkeys: HotkeySettingsView()
                case .permissions: PermissionsSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.panel.ignoresSafeArea())
        .tint(MacroTheme.accent)
        .preferredColorScheme(.dark)
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, hotkeys, permissions
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .hotkeys: "Hotkeys"
        case .permissions: "Permissions"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gear"
        case .appearance: "paintpalette"
        case .hotkeys: "keyboard"
        case .permissions: "hand.raised"
        }
    }
}

private struct AppearanceSettingsView: View {
    @State private var appearance = AppearanceThemeStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance").font(.title2.weight(.bold))
                    Text("Choose a color palette for Macro.")
                        .foregroundStyle(.secondary)
                }

                ForEach(AppearancePalette.allCases) { palette in
                    Button {
                        appearance.selected = palette
                    } label: {
                        HStack(spacing: 14) {
                            HStack(spacing: 3) {
                                ForEach(Array(palette.previewColors.enumerated()), id: \.offset) { _, color in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(color)
                                        .frame(width: 18, height: 30)
                                }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(palette.title).font(.headline)
                                Text(palette.description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if appearance.selected == palette {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(MacroTheme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(14)
                        .background(MacroTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(appearance.selected == palette ? MacroTheme.accent : MacroTheme.border, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(palette.title) palette")
                    .accessibilityAddTraits(appearance.selected == palette ? .isSelected : [])
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.panel)
    }
}

private struct GeneralSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("General").font(.title2.weight(.bold))
                    Text("Safety and target-window behavior")
                        .foregroundStyle(.secondary)
                }

                settingsCard(title: "Safety", symbol: "shield.lefthalf.filled", tint: .green) {
                    settingsRow("Emergency stop", value: "Escape")
                    Divider().overlay(MacroTheme.border.opacity(0.7))
                    Text("Escape stops active playback or recording. Stop, errors, target termination, and app termination release held automation keys and mouse buttons.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingsCard(title: "Window targeting", symbol: "macwindow", tint: MacroTheme.accent) {
                    settingsRow("Window discovery", value: "Across Spaces")
                    Divider().overlay(MacroTheme.border.opacity(0.7))
                    Text("Fullscreen and other-Space windows may need Compatibility playback, which brings the target app forward.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.panel)
    }

    private func settingsCard<Content: View>(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacroTheme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(MacroTheme.border.opacity(0.75)) }
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.callout)
    }
}

private struct HotkeySettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Hotkeys").font(.title2.weight(.bold))
                    Text("These shortcuts work while Macro is in the background.")
                        .foregroundStyle(.secondary)
                }

                AppCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element.id) { index, action in
                            HStack(spacing: 12) {
                                Image(systemName: action.symbol)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(color(for: action))
                                    .frame(width: 34, height: 34)
                                    .background(color(for: action).opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title).font(.headline)
                                    Text(detail(for: action)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                HotkeyRecorderButton(shortcut: model.hotkeys[action]) { shortcut in
                                    model.updateHotkey(action, to: shortcut)
                                }
                            }
                            .padding(14)

                            if index < HotkeyAction.allCases.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                }

                HStack {
                    Label(model.hotkeyRegistrationMessage, systemImage: model.hotkeyRegistrationMessage == "Global hotkeys are active." ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(model.hotkeyRegistrationMessage == "Global hotkeys are active." ? Color.green : Color.orange)
                    Spacer()
                    Button("Restore Defaults") { model.resetHotkeys() }
                }

                Text("Click a shortcut, then press a function key or a key combination. Bare letters and numbers are blocked so a global hotkey cannot interfere with normal typing. Press Escape while assigning to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.panel)
    }

    private func detail(for action: HotkeyAction) -> String {
        switch action {
        case .record: "Begins recording into the selected macro"
        case .stop: "Ends recording or stops active playback"
        case .play: "Runs the currently selected macro"
        }
    }

    private func color(for action: HotkeyAction) -> Color {
        switch action {
        case .record: MacroPalette.recording
        case .stop: .orange
        case .play: .green
        }
    }
}

private struct PermissionsSettingsView: View {
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                permissionCard(
                    title: "Accessibility & Event Posting",
                    symbol: "accessibility",
                    granted: permissions.accessibilityGranted && permissions.eventPostingGranted,
                    requirement: "Required for automation and Compatibility mouse playback",
                    explanation: "Allows Macro to use approved accessibility APIs and post system mouse events. Both checks must be granted. Macro never bypasses these macOS controls.",
                    request: permissions.requestAccessibility,
                    openSettings: permissions.openAccessibilitySettings
                )

                permissionCard(
                    title: "Input Monitoring",
                    symbol: "keyboard.badge.ellipsis",
                    granted: permissions.inputMonitoringGranted,
                    requirement: "Required for recording and global emergency stop",
                    explanation: "Allows Macro to observe keyboard and mouse events. It is not required for window discovery.",
                    request: permissions.requestInputMonitoring,
                    openSettings: permissions.openInputMonitoringSettings
                )

                HStack {
                    Text("Last checked \(permissions.lastChecked, format: .dateTime.hour().minute().second())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { permissions.refresh() }
                }

                Text("macOS owns these permission decisions. After changing a switch in System Settings, return to Macro and click Check Again. A relaunch may be required if macOS does not update the running process immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.panel)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func permissionCard(
        title: String,
        symbol: String,
        granted: Bool,
        requirement: String,
        explanation: String,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(granted ? Color.green : Color.orange)
                    .frame(width: 34, height: 34)
                    .background(
                        (granted ? Color.green : Color.orange).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(requirement).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    text: granted ? "Granted" : "Not Granted",
                    color: granted ? .green : .orange
                )
            }

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button(granted ? "Request Again" : "Request Access", action: request)
                    .disabled(granted)
                Button("Open System Settings", action: openSettings)
            }
        }
        .padding(14)
        .background(MacroTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(MacroTheme.border.opacity(0.7)) }
    }
}

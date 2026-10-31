import SwiftUI
import UniformTypeIdentifiers

struct MacrosView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: MacroJSONDocument?
    @State private var showActionEditor = false

    private var filteredMacros: [MacroDefinition] {
        guard !searchText.isEmpty else { return model.macros }
        return model.macros.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HSplitView {
            macroLibrary
                .frame(minWidth: 420, idealWidth: 680, maxHeight: .infinity, alignment: .top)
            inspector
                .frame(minWidth: 260, idealWidth: 310, maxWidth: 390, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacroTheme.window)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.importMacro(from: url)
            case .failure(let error): model.log("Import failed: \(error.localizedDescription)", level: .error)
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: model.selectedMacro?.name ?? "Macro"
        ) { result in
            switch result {
            case .success: model.log("Exported macro JSON")
            case .failure(let error): model.log("Export failed: \(error.localizedDescription)", level: .error)
            }
        }
        .onChange(of: model.selectedMacroID) { _, _ in showActionEditor = false }
    }

    private var macroLibrary: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recordings").font(.title2.weight(.bold))
                    Spacer()
                    Text("\(model.macros.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MacroTheme.raised, in: Capsule())
                    Button {
                        model.destination = .recorder
                    } label: {
                        Label("Record", systemImage: "record.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MacroPalette.recording)
                    .help("Open Recorder · \(model.hotkeys.record.displayName)")
                }
                AppSearchField(placeholder: "Search recordings", text: $searchText)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider().opacity(0.6)

            if showActionEditor, let index = model.selectedMacroIndex {
                ActionList(actions: $model.macros[index].actions)
                editorFooter
            } else if filteredMacros.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredMacros) { macro in
                            MacroLibraryRow(
                                macro: macro,
                                isSelected: model.selectedMacroID == macro.id,
                                action: { model.selectedMacroID = macro.id }
                            )
                            .contextMenu {
                                Button("Duplicate") {
                                    model.selectedMacroID = macro.id
                                    model.duplicateSelectedMacro()
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    model.selectedMacroID = macro.id
                                    model.deleteSelectedMacro()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            Divider().opacity(0.6)
            HStack(spacing: 10) {
                Button { model.createMacro() } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                Menu {
                    Button("Save Library") { model.saveLibrary() }
                    Button("Reload Library") { model.reloadLibrary() }
                    Divider()
                    Button("Duplicate") { model.duplicateSelectedMacro() }
                    Divider()
                    Button("Import JSON…") { showImporter = true }
                    Button("Export JSON…") {
                        guard let macro = model.selectedMacro else { return }
                        exportDocument = MacroJSONDocument(macro: macro)
                        showExporter = true
                    }
                    .disabled(model.selectedMacro == nil)
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteSelectedMacro() }
                        .disabled(model.selectedMacro == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(MacroTheme.window)
    }

    @ViewBuilder
    private var inspector: some View {
        if let index = model.selectedMacroIndex {
            MacroInspector(
                macro: $model.macros[index],
                model: model,
                onEditActions: { showActionEditor = true }
            )
        } else {
            ContentUnavailableView(
                "No Macro Selected",
                systemImage: "command.square",
                description: Text("Create a macro to begin adding actions.")
            )
        }
    }

    private var editorFooter: some View {
        HStack {
            Menu {
                Section("Keyboard") {
                    ForEach([MacroActionType.keyDown, .keyUp, .keyPress, .holdKey], id: \.self) { type in
                        Button(type.title) { model.addAction(type) }
                    }
                }
                Section("Timing") { Button("Wait") { model.addAction(.wait) } }
                Section("Mouse") {
                    ForEach([MacroActionType.leftClick, .rightClick, .middleClick, .mouseDown, .mouseUp, .move, .scroll], id: \.self) { type in
                        Button(type.title) { model.addAction(type) }
                    }
                }
            } label: {
                Label("Add Action", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            Spacer()
            Button("Overview", systemImage: "rectangle.grid.1x2") { showActionEditor = false }
                .buttonStyle(.borderless)
            Label("Drag to reorder · expand to edit", systemImage: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(MacroTheme.toolbar)
    }
}

private struct MacroInspector: View {
    @Binding var macro: MacroDefinition
    @ObservedObject var model: AppModel
    let onEditActions: () -> Void

    private var keyboardCount: Int {
        macro.actions.filter { [.keyDown, .keyUp, .keyPress, .holdKey].contains($0.type) }.count
    }
    private var mouseCount: Int {
        macro.actions.filter { [.leftClick, .rightClick, .middleClick, .mouseDown, .mouseUp, .move, .scroll].contains($0.type) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionLabel(text: "RECORDING DETAILS")
                    Spacer()
                    Menu {
                        Button("Duplicate") { model.selectedMacroID = macro.id; model.duplicateSelectedMacro() }
                        Divider()
                        Button("Delete", role: .destructive) { model.selectedMacroID = macro.id; model.deleteSelectedMacro() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                            .background(MacroTheme.raised, in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                }

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Recording name", text: $macro.name)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.bold))
                    RecordingWaveform(actionCount: macro.actions.count, tint: .accentColor)
                        .frame(height: 46)
                    HStack {
                        Label("\(macro.actions.count) actions", systemImage: "waveform")
                        Spacer()
                        Text(macro.loopMode.title)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button(action: model.start) {
                        Label("Play Recording", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                }
                .padding(14)
                .background(MacroTheme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 13).stroke(MacroTheme.border.opacity(0.7)) }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "PLAYBACK")
                    HStack {
                        Label("Repeat", systemImage: "repeat")
                        Spacer()
                        Picker("Loop", selection: $macro.loopMode) {
                            ForEach(LoopMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    if macro.loopMode == .count {
                        Stepper("\(macro.loopCount) times", value: $macro.loopCount, in: 2...999)
                            .font(.callout)
                    }
                    Picker("Mouse playback", selection: $macro.mousePlaybackMode) {
                        ForEach(MousePlaybackMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.runState != .idle || model.recording)
                    .help(macro.mousePlaybackMode.detail)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "RECORDED CONTENT")
                    inspectorMetric("Keyboard", value: keyboardCount, symbol: "keyboard", tint: .blue)
                    inspectorMetric("Mouse", value: mouseCount, symbol: "computermouse", tint: .purple)
                    inspectorMetric("Target", value: model.selectedTarget?.applicationName ?? "None", symbol: "scope", tint: .orange)
                }

                Button("Edit Actions", systemImage: "slider.horizontal.3", action: onEditActions)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
        }
        .background(MacroTheme.sidebar)
    }

    private func inspectorMetric(_ title: String, value: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(value)").fontWeight(.medium).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private func inspectorMetric(_ title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).lineLimit(1)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}

private struct MacroOverview: View {
    let macro: MacroDefinition
    let onEdit: () -> Void

    private var groups: [(String, String, Int, Color)] {
        let keyboard = macro.actions.filter { [.keyDown, .keyUp, .keyPress, .holdKey].contains($0.type) }.count
        let mouse = macro.actions.filter { [.leftClick, .rightClick, .middleClick, .mouseDown, .mouseUp, .move, .scroll].contains($0.type) }.count
        let timing = macro.actions.filter { $0.type == .wait }.count
        return [("Keyboard", "keyboard", keyboard, .blue), ("Mouse", "computermouse", mouse, .purple), ("Timing", "clock", timing, .orange)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recording overview").font(.title3.weight(.semibold))
                            Text("Actions are hidden until you choose to edit this macro.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit Actions", systemImage: "slider.horizontal.3", action: onEdit)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                    Divider()
                    HStack(spacing: 10) {
                        SummaryMetric(title: "Total actions", value: "\(macro.actions.count)", symbol: "list.bullet.rectangle", color: .accentColor)
                        SummaryMetric(title: "Playback", value: macro.loopMode.title, symbol: "repeat", color: .green)
                    }
                }
            }

            Text("Recorded content").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(groups, id: \.0) { group in
                    SummaryMetric(title: group.0, value: "\(group.2) events", symbol: group.1, color: group.3)
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacroTheme.window)
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 30, height: 30).background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(MacroTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(MacroTheme.border.opacity(0.7)) }
    }
}

private struct MacroLibraryRow: View {
    let macro: MacroDefinition
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(macro.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                RecordingWaveform(actionCount: macro.actions.count, tint: isSelected ? .accentColor : .secondary)
                    .frame(height: 28)

                HStack(spacing: 6) {
                    Text("\(macro.actions.count) actions")
                    Text("·")
                    Text(macro.loopMode.title)
                    Spacer(minLength: 0)
                    Image(systemName: "computermouse")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? MacroTheme.accent.opacity(0.16) : MacroTheme.card.opacity(0.3))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? MacroTheme.accent.opacity(0.65) : MacroTheme.border.opacity(0.45))
            }
        }
        .buttonStyle(.plain)
    }
}

/// A decorative, deterministic waveform so recordings have a recognizable audio-library feel.
private struct RecordingWaveform: View {
    let actionCount: Int
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let count = max(1, Int(size.width / 4))
            let step = size.width / CGFloat(count)
            for index in 0..<count {
                let seed = (index * 37 + actionCount * 19) % 29
                let variation = CGFloat((seed * seed + index * 11) % 23) / 23
                let height = max(3, size.height * (0.18 + variation * 0.82))
                let rect = CGRect(x: CGFloat(index) * step + step * 0.22,
                                  y: (size.height - height) / 2,
                                  width: max(1, step * 0.52),
                                  height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(2, rect.width / 2)), with: .color(tint.opacity(0.35 + variation * 0.55)))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MacroHeader: View {
    @Binding var macro: MacroDefinition
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            AppCard {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 15) {
                        macroIcon
                        macroDetails
                        Spacer(minLength: 8)
                        playControls
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            macroIcon
                            macroDetails
                        }
                        HStack(spacing: 8) {
                            playButton
                            Keycap(text: model.hotkeys.play.displayName)
                        }
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    loopControls
                    Spacer()
                    mouseControls
                    savedStatus
                }

                VStack(alignment: .leading, spacing: 10) {
                    loopControls
                    mouseControls
                    savedStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
        }
        .padding(18)
        .background(MacroTheme.window)
    }

    private var macroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.gradient)
            Image(systemName: "waveform.path.ecg")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 50, height: 50)
    }

    private var macroDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Macro name", text: $macro.name)
                .textFieldStyle(.plain)
                .font(.title2.weight(.bold))
                .lineLimit(1)
            HStack(spacing: 8) {
                Label("\(macro.actions.count) actions", systemImage: "list.bullet")
                Text("·")
                Label(model.selectedTarget?.applicationName ?? "No target", systemImage: "scope")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playButton: some View {
        AppKitActionButton(
            title: "Play",
            systemImage: "play.fill",
            style: .prominent,
            isEnabled: model.canStart,
            help: "Play · \(model.hotkeys.play.displayName)",
            action: model.start
        )
        .frame(width: 96, height: 32)
    }

    private var playControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            playButton
            Keycap(text: model.hotkeys.play.displayName)
        }
    }

    private var loopControls: some View {
        HStack(spacing: 9) {
            Image(systemName: "repeat")
                .foregroundStyle(.secondary)
            Picker("Loop", selection: $macro.loopMode) {
                ForEach(LoopMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 125)

            if macro.loopMode == .count {
                Stepper("\(macro.loopCount) times", value: $macro.loopCount, in: 2...999)
                    .fixedSize()
            }
        }
    }

    private var mouseControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "computermouse")
                .foregroundStyle(.secondary)
            Picker("Mouse playback", selection: $macro.mousePlaybackMode) {
                ForEach(MousePlaybackMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(model.runState != .idle || model.recording)
            .help(macro.mousePlaybackMode.detail)
        }
    }

    private var savedStatus: some View {
        Label(
            model.playbackProgress?.label ?? "Saved automatically",
            systemImage: model.playbackProgress == nil ? "checkmark.circle.fill" : "waveform.path"
        )
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct ActionList: View {
    @Binding var actions: [MacroAction]

    var body: some View {
        if actions.isEmpty {
            ContentUnavailableView(
                "No Actions Yet",
                systemImage: "waveform.path.badge.plus",
                description: Text("Record input or add a keyboard, timing, or mouse action.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach($actions) { $action in
                    ActionRow(action: $action)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18))
                }
                .onDelete { actions.remove(atOffsets: $0) }
                .onMove { actions.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ActionRow: View {
    @Binding var action: MacroAction
    @State private var isExpanded = false

    private var tint: Color {
        switch action.type.tintName {
        case "orange": MacroPalette.timing
        case "purple": MacroPalette.mouse
        case "teal": .teal
        default: MacroPalette.keyboard
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Toggle("", isOn: $action.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                Image(systemName: action.type.symbol)
                    .symbolVariant(.fill)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.type.title).font(.body.weight(.semibold))
                    Text(action.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if action.delay > 0 {
                    Text("+\(action.delay, specifier: "%.3f")s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button { withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() } } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Edit Action")
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
            }
            .padding(13)

            if isExpanded {
                Divider().padding(.horizontal, 13)
                actionEditor
                    .padding(14)
                    .padding(.leading, 42)
            }
        }
        .opacity(action.isEnabled ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(MacroTheme.card)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(MacroTheme.border.opacity(0.7))
        }
    }

    private var actionEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                Text("Type").foregroundStyle(.secondary)
                Picker("", selection: $action.type) {
                    ForEach(MacroActionType.allCases) { type in Text(type.title).tag(type) }
                }
                .labelsHidden()
            }

            if [.keyDown, .keyUp, .keyPress, .holdKey].contains(action.type) {
                GridRow {
                    Text("Key").foregroundStyle(.secondary)
                    TextField("w, e, space, shift…", text: Binding(
                        get: { action.key ?? "" },
                        set: { action.key = $0 }
                    ))
                }
            }

            if [.wait, .holdKey, .keyPress, .leftClick, .rightClick, .middleClick].contains(action.type) {
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    HStack {
                        TextField("Seconds", value: $action.duration, format: .number.precision(.fractionLength(3)))
                            .frame(width: 100)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            }

            if [.mouseDown, .mouseUp].contains(action.type) {
                GridRow {
                    Text("Mouse button").foregroundStyle(.secondary)
                    Picker("", selection: $action.mouseButton) {
                        ForEach(MacroMouseButton.allCases) { button in Text(button.title).tag(button) }
                    }
                    .labelsHidden()
                }
            }

            if [.leftClick, .rightClick, .middleClick, .mouseDown, .mouseUp].contains(action.type) {
                GridRow {
                    Text("Click count").foregroundStyle(.secondary)
                    Stepper("\(action.clickCount)", value: $action.clickCount, in: 1...3)
                        .fixedSize()
                }
            }

            GridRow {
                Text("Delay before").foregroundStyle(.secondary)
                HStack {
                    TextField("Seconds", value: $action.delay, format: .number.precision(.fractionLength(3)))
                        .frame(width: 100)
                    Text("seconds").foregroundStyle(.secondary)
                }
            }

            if [.leftClick, .rightClick, .middleClick, .mouseDown, .mouseUp, .move, .scroll].contains(action.type) {
                GridRow {
                    Text("Coordinates").foregroundStyle(.secondary)
                    HStack {
                        Text("X")
                        TextField("0", value: $action.x, format: .number).frame(width: 70)
                        Text("Y")
                        TextField("0", value: $action.y, format: .number).frame(width: 70)
                        Picker("", selection: $action.usesWindowCoordinates) {
                            Text("Window-relative").tag(true)
                            Text("Screen").tag(false)
                        }
                        .labelsHidden()
                    }
                }
            }


            if action.type == .scroll {
                GridRow {
                    Text("Scroll delta").foregroundStyle(.secondary)
                    HStack {
                        Text("X")
                        TextField("0", value: $action.scrollDeltaX, format: .number).frame(width: 70)
                        Text("Y")
                        TextField("0", value: $action.scrollDeltaY, format: .number).frame(width: 70)
                    }
                }
            }
        }
        .controlSize(.small)
    }
}

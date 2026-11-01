import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: AutomationStore
    @Binding var sidebarVisible: Bool
    @State private var showLibrary = true
    @State private var showInspector = true
    @State private var compactLayout = false
    @State private var didInitializeLayout = false

    var body: some View {
        VStack(spacing: 0) {
            automationToolbar
            Divider().opacity(0.6)

            GeometryReader { proxy in
                let libraryOverlayWidth = max(230, min(300, proxy.size.width * 0.72))
                let inspectorOverlayWidth = min(280, proxy.size.width * 0.78)
                let blockedDropRects: [CGRect] = {
                    guard proxy.size.width < 1120 else { return [] }
                    var rects: [CGRect] = []
                    if showLibrary {
                        rects.append(CGRect(x: 0, y: 0, width: libraryOverlayWidth, height: proxy.size.height))
                    }
                    if showInspector {
                        rects.append(CGRect(
                            x: proxy.size.width - inspectorOverlayWidth,
                            y: 0,
                            width: inspectorOverlayWidth,
                            height: proxy.size.height
                        ))
                    }
                    return rects
                }()
                Group {
                    if proxy.size.width >= 1120 {
                        HStack(spacing: 0) {
                            if showLibrary {
                                AutomationLibraryPanel(store: store, macros: model.macros)
                                    .frame(width: 285)
                                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .leading)))
                                Divider().opacity(0.55)
                            }
                            AutomationCanvasView(store: store, model: model, macros: model.macros, inputEnabled: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if showInspector {
                                Divider().opacity(0.55)
                                AutomationInspector(store: store, model: model)
                                    .frame(width: 300)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    } else {
                        ZStack(alignment: .leading) {
                            AutomationCanvasView(
                                store: store, model: model,
                                macros: model.macros,
                                inputEnabled: true,
                                blockedDropRects: blockedDropRects
                            )
                            if showLibrary {
                                AutomationLibraryPanel(store: store, macros: model.macros)
                                    .frame(width: libraryOverlayWidth)
                                    .background(MacroTheme.sidebar)
                                    .shadow(color: .black.opacity(0.2), radius: 18, x: 5)
                                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .leading)))
                            }
                            if showInspector {
                                HStack(spacing: 0) {
                                    Spacer()
                                    AutomationInspector(store: store, model: model)
                                        .frame(width: inspectorOverlayWidth)
                                        .background(MacroTheme.panel)
                                        .shadow(color: .black.opacity(0.2), radius: 18, x: -5)
                                }
                                .transition(.move(edge: .trailing))
                            }
                        }
                    }
                }
                .onAppear {
                    guard !didInitializeLayout else { return }
                    didInitializeLayout = true
                    compactLayout = proxy.size.width < 1120
                    if compactLayout {
                        showLibrary = false
                        showInspector = false
                    }
                }
                .onChange(of: proxy.size.width) { _, newWidth in
                    compactLayout = newWidth < 1120
                }
            }

            Divider().opacity(0.6)
            statusBar
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(MacroTheme.window)
        .tint(MacroTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var automationToolbar: some View {
        HStack(spacing: 8) {
            if !sidebarVisible {
                SidebarToggleControl(isVisible: $sidebarVisible)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Automation name", text: Binding(
                    get: { store.selectedAutomation?.name ?? "No Automation" },
                    set: { value in store.updateAutomation { $0.name = value } }
                ))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .disabled(store.selectedAutomation == nil || store.runState != .idle)
                if let automation = store.selectedAutomation {
                    Text("\(automation.nodes.count) nodes  ·  Edited \(automation.lastEdited.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 60, maxWidth: 300, alignment: .leading)

            Button("Save", systemImage: "square.and.arrow.down") { store.saveNow() }
                .buttonStyle(.bordered)
                .help("Save automation")

            Menu {
                Button("Undo", systemImage: "arrow.uturn.backward", action: store.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward", action: store.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
                Divider()
                Button("Delete Automation", systemImage: "trash", role: .destructive) {
                    store.deleteSelectedAutomation()
                }
                .disabled(store.selectedAutomation == nil || store.runState != .idle)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("More automation actions")

            Spacer(minLength: 8)

            AppKitActionButton(
                title: "Run",
                systemImage: "play.fill",
                style: .prominent,
                isEnabled: model.canStartAutomation,
                help: validationErrors.first?.message ?? "Run automation",
                action: model.startAutomation
            )
            .frame(width: 84, height: 32)

            AppKitActionButton(
                title: nil,
                systemImage: store.runState == .paused ? "play.fill" : "pause.fill",
                isEnabled: store.runState != .idle,
                help: store.runState == .paused ? "Resume automation" : "Pause automation",
                action: model.togglePause
            )
            .frame(width: 34, height: 30)

            AppKitActionButton(
                title: nil,
                systemImage: "stop.fill",
                isEnabled: store.runState != .idle,
                help: "Stop automation",
                action: model.stop
            )
            .frame(width: 34, height: 30)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            Button {
                withAnimation(.easeInOut(duration: 0.26)) {
                    showLibrary.toggle()
                    if compactLayout, showLibrary { showInspector = false }
                }
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(showLibrary ? "Hide automation library" : "Show automation library")
            .accessibilityLabel(showLibrary ? "Hide automation library" : "Show automation library")

            Button {
                withAnimation(.easeInOut(duration: 0.26)) {
                    showInspector.toggle()
                    if compactLayout, showInspector { showLibrary = false }
                }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(showInspector ? "Hide properties inspector" : "Show properties inspector")
            .accessibilityLabel(showInspector ? "Hide properties inspector" : "Show properties inspector")
        }
        .padding(.horizontal, 10)
        .frame(height: 60)
        .background(MacroTheme.toolbar)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.runState == .idle ? Color.secondary : store.runState == .paused ? .orange : .green)
                .frame(width: 7, height: 7)
            Text(store.runState.rawValue)
                .font(.caption.weight(.semibold))
            Text("·").foregroundStyle(.tertiary)
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !validationIssues.isEmpty, store.runState == .idle {
                Button {
                    if let nodeID = validationIssues.first?.nodeID { store.selectNode(nodeID) }
                    withAnimation(.easeOut(duration: 0.18)) {
                        showInspector = true
                        showLibrary = false
                    }
                } label: {
                    Label(
                        "\(validationIssues.count) \(validationIssues.count == 1 ? "issue" : "issues")",
                        systemImage: validationErrors.isEmpty ? "exclamationmark.triangle" : "xmark.octagon.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(validationErrors.isEmpty ? .orange : MacroPalette.recording)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if store.runState != .idle {
                Text("Step \(store.currentStep) / \(max(1, store.totalSteps))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(store.runState == .paused ? "Resume" : "Pause", action: model.togglePause)
                    .buttonStyle(.borderless)
                Button("Stop", action: model.stop)
                    .buttonStyle(.borderless)
                    .foregroundStyle(MacroPalette.recording)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(MacroTheme.toolbar)
    }

    private var validationIssues: [AutomationValidationIssue] {
        store.validationIssues(availableMacroIDs: Set(model.macros.map(\.id)))
    }

    private var validationErrors: [AutomationValidationIssue] {
        validationIssues.filter { $0.severity == .error }
    }
}

private struct AutomationLibraryPanel: View {
    @ObservedObject var store: AutomationStore
    let macros: [MacroDefinition]
    @State private var searchText = ""
    @State private var macrosExpanded = true
    @State private var flowExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(text: "Automation")
                        Spacer()
                        Button(action: store.createAutomation) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New automation")
                    }

                    AppSearchField(placeholder: "Search automations and nodes", text: $searchText)

                    ForEach(filteredAutomations) { automation in
                        Button {
                            store.selectAutomation(automation.id)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(store.selectedAutomationID == automation.id ? .blue : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(automation.name)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(automation.nodes.count) nodes")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(store.selectedAutomationID == automation.id ? MacroTheme.accent.opacity(0.30) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().opacity(0.5)

                DisclosureGroup(isExpanded: $macrosExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        if filteredMacros.isEmpty {
                            Text(macros.isEmpty ? "Record or create a macro first." : "No matching macros.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredMacros) { macro in
                                LibraryNodeRow(
                                    title: macro.name,
                                    subtitle: "\(macro.actions.count) actions",
                                    symbol: "point.3.connected.trianglepath.dotted",
                                    color: .blue
                                )
                                .draggable("macro:\(macro.id.uuidString)")
                            }
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    SectionLabel(text: "Macros")
                }

                DisclosureGroup(isExpanded: $flowExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredFlowKinds) { kind in
                            LibraryNodeRow(
                                title: kind.title,
                                subtitle: flowSubtitle(kind),
                                symbol: kind.symbol,
                                color: nodeColor(kind)
                            )
                            .draggable("flow:\(kind.rawValue)")
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    SectionLabel(text: "Flow")
                }

                Label("Drag a library item onto the canvas to add it. Drag a node on the canvas to move it.", systemImage: "hand.draw")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .overlay(alignment: .topLeading) {
            OverlayScrollerStyleProbe()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(MacroTheme.sidebar)
    }

    private var filteredAutomations: [AutomationDefinition] {
        guard !searchText.isEmpty else { return store.automations }
        return store.automations.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredMacros: [MacroDefinition] {
        guard !searchText.isEmpty else { return macros }
        return macros.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredFlowKinds: [AutomationNodeKind] {
        let kinds: [AutomationNodeKind] = [.start, .wait, .waitForWindow, .ifElse, .schedule, .repeatFlow, .loopBack, .merge, .resetTimer, .stop, .note]
        guard !searchText.isEmpty else { return kinds }
        return kinds.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || flowSubtitle($0).localizedCaseInsensitiveContains(searchText)
        }
    }

    private func flowSubtitle(_ kind: AutomationNodeKind) -> String {
        switch kind {
        case .start: "Workflow entry"
        case .wait: "Pause execution"
        case .waitForWindow: "Wait for an app window"
        case .ifElse: "Branch based on a configurable condition"
        case .schedule: "Run at a time or on an interval"
        case .repeatFlow: "Repeat by count, duration, or until stopped"
        case .loopBack: "Jump to a shared point in the workflow"
        case .merge: "Rejoin alternate paths into one sequence"
        case .stop: "End automation"
        case .resetTimer: "Restart elapsed-time conditions"
        case .note: "Add an editable canvas note"
        case .macro: "Run a saved macro"
        }
    }
}

/// Keep the Automation library's native macOS scroller in the slim overlay style.
private struct OverlayScrollerStyleProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScrollerProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollerProbeView)?.applyOverlayScrollerStyle()
    }

    private final class ScrollerProbeView: NSView {
        private weak var styledScrollView: NSScrollView?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleStyleUpdate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleStyleUpdate()
        }

        func applyOverlayScrollerStyle() {
            guard let rootView = window?.contentView else { return }
            let probePoint = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var matchingScrollViews: [NSScrollView] = []

            func collectScrollViews(in view: NSView) {
                if let scrollView = view as? NSScrollView,
                   scrollView.convert(scrollView.bounds, to: nil).contains(probePoint) {
                    matchingScrollViews.append(scrollView)
                }
                view.subviews.forEach(collectScrollViews)
            }

            collectScrollViews(in: rootView)
            guard let scrollView = matchingScrollViews.min(by: {
                $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
            }) else { return }

            guard styledScrollView !== scrollView || scrollView.scrollerStyle != .overlay else { return }
            styledScrollView = scrollView
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }

        private func scheduleStyleUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.applyOverlayScrollerStyle()
            }
        }
    }
}

private struct LibraryNodeRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct ConnectionDraft {
    var sourceNodeID: UUID
    var branch: AutomationBranch?
    var currentPoint: CGPoint
    var targetNodeID: UUID?
}

private enum AutomationCanvasTool: String, CaseIterable, Identifiable, Equatable {
    case select, pan, section, note

    var id: Self { self }
    var title: String {
        switch self {
        case .select: "Select"
        case .pan: "Pan"
        case .section: "Section"
        case .note: "Note"
        }
    }
    var helpTitle: String {
        switch self {
        case .select: "Select and move nodes"
        case .pan: "Pan canvas"
        case .section: "Create section"
        case .note: "Add note"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pan: "hand.draw"
        case .section: "square.dashed"
        case .note: "note.text"
        }
    }
}

private struct CanvasInputCapture: NSViewRepresentable {
    let isEnabled: Bool
    let onPan: (CGSize) -> Void
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onPan: onPan, onScroll: onScroll)
    }

    func makeNSView(context: Context) -> CanvasInputView {
        let view = CanvasInputView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: CanvasInputView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPan = onPan
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: CanvasInputView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onPan: (CGSize) -> Void
        var onScroll: (CGFloat, CGPoint) -> Void
        private weak var view: CanvasInputView?
        private var mouseMonitor: Any?
        private var scrollMonitor: Any?
        private var isRightDragging = false
        private var previousDragPoint: CGPoint?

        init(
            isEnabled: Bool,
            onPan: @escaping (CGSize) -> Void,
            onScroll: @escaping (CGFloat, CGPoint) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onPan = onPan
            self.onScroll = onScroll
        }

        func install(for view: CanvasInputView) {
            self.view = view
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]
            ) { [weak self] event in
                self?.handleRightMouse(event) ?? event
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event) ?? event
            }
        }

        func uninstall() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            mouseMonitor = nil
            scrollMonitor = nil
            isRightDragging = false
            previousDragPoint = nil
        }

        private func handleRightMouse(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, !isInsideScrollView(event), let view else { return event }
            switch event.type {
            case .rightMouseDown:
                guard let point = localPoint(for: event, in: view), view.bounds.contains(point) else {
                    return event
                }
                isRightDragging = true
                previousDragPoint = point
                return nil
            case .rightMouseDragged:
                guard isRightDragging,
                      let point = localPoint(for: event, in: view),
                      let previousDragPoint else { return event }
                onPan(CGSize(
                    width: point.x - previousDragPoint.x,
                    height: point.y - previousDragPoint.y
                ))
                self.previousDragPoint = point
                return nil
            case .rightMouseUp:
                guard isRightDragging else { return event }
                isRightDragging = false
                previousDragPoint = nil
                return nil
            default:
                return event
            }
        }

        private func handleScroll(_ event: NSEvent) -> NSEvent? {
            guard isEnabled,
                  !isInsideScrollView(event),
                  let view,
                  let point = localPoint(for: event, in: view),
                  view.bounds.contains(point) else {
                return event
            }
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.05
            onScroll(event.scrollingDeltaY * sensitivity, point)
            return nil
        }

        private func localPoint(for event: NSEvent, in view: NSView) -> CGPoint? {
            guard event.window === view.window else { return nil }
            return view.convert(event.locationInWindow, from: nil)
        }

        private func isInsideScrollView(_ event: NSEvent) -> Bool {
            guard let window = event.window,
                  var candidate = window.contentView?.hitTest(event.locationInWindow) else { return false }
            while true {
                if candidate is NSScrollView { return true }
                guard let parent = candidate.superview else { return false }
                candidate = parent
            }
        }
    }
}

private final class CanvasInputView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct CanvasLibraryDropDelegate: DropDelegate {
    let onDrop: (String, CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let token = object as? String else { return }
            DispatchQueue.main.async {
                _ = onDrop(token, location)
            }
        }
        return true
    }
}

private struct CanvasAlignmentGuides: Equatable {
    var x: CGFloat?
    var y: CGFloat?
}

private struct AutomationCanvasView: View {
    @ObservedObject var store: AutomationStore
    @ObservedObject var model: AppModel
    let macros: [MacroDefinition]
    let inputEnabled: Bool
    var blockedDropRects: [CGRect] = []
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize(width: 50, height: 40)
    @State private var draft: ConnectionDraft?
    @State private var nodeSearch = ""
    @State private var selectedNodeIDs = Set<UUID>()
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var groupDragOrigins: [UUID: CGPoint] = [:]
    @State private var nodeDragInProgress = false
    @State private var alignmentGuides = CanvasAlignmentGuides()
    @State private var sectionDragInProgress = false
    @State private var activeCanvasTool: AutomationCanvasTool = .select
    @State private var sectionToolStart: CGPoint?
    @State private var sectionToolEnd: CGPoint?
    @State private var canvasToolDragTranslation = CGSize.zero
    @State private var hoveredCanvasTool: AutomationCanvasTool?
    @State private var fitToolHovered = false

    private let nodeSize = CGSize(width: 238, height: 76)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                DottedWorkflowGrid(zoom: zoom, pan: pan)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(coordinateSpace: .named("automationCanvas")).onEnded { value in
                        switch activeCanvasTool {
                        case .note:
                            store.addNode(kind: .note, at: logicalPoint(from: value.location))
                            if let nodeID = store.selectedNodeID { selectedNodeIDs = [nodeID] }
                            activeCanvasTool = .select
                        case .select:
                            selectedNodeIDs.removeAll()
                            store.selectNode(nil)
                            store.selectConnection(nil)
                        case .pan, .section:
                            break
                        }
                    })

                workflowContent
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)
                    .allowsHitTesting(store.selectedAutomation != nil)

                if let marqueeRect {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        }
                        .frame(width: marqueeRect.width, height: marqueeRect.height)
                        .position(x: marqueeRect.midX, y: marqueeRect.midY)
                        .allowsHitTesting(false)
                }

                if activeCanvasTool == .section, let sectionToolRect {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [7, 4]))
                        }
                        .frame(width: sectionToolRect.width, height: sectionToolRect.height)
                        .position(x: sectionToolRect.midX, y: sectionToolRect.midY)
                        .allowsHitTesting(false)
                }

                if let automation = store.selectedAutomation, !automation.nodes.isEmpty {
                    WorkflowMinimap(automation: automation, selectedNodeID: store.selectedNodeID, activeNodeID: store.activeNodeID)
                        .frame(width: 150, height: 100)
                        .padding(8)
                        .background(MacroTheme.raised.opacity(0.96), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(MacroTheme.border) }
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .gesture(SpatialTapGesture().onEnded { value in
                            centerCanvas(on: CGPoint(x: value.location.x / 150 * 2400, y: value.location.y / 100 * 1600), in: proxy.size)
                        })
                }

                CanvasInputCapture(
                    isEnabled: inputEnabled,
                    onPan: { delta in
                        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
                    },
                    onScroll: { delta, location in
                        setZoom(zoom + delta, around: location)
                    }
                )
                .allowsHitTesting(false)

                canvasControls(size: proxy.size)
                canvasToolbox(size: proxy.size)
            }
            .clipped()
            .coordinateSpace(name: "automationCanvas")
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("automationCanvas"))
                    .onChanged { value in
                        guard store.canEdit,
                              !nodeDragInProgress,
                              !sectionDragInProgress,
                              isCanvasGestureAllowed(at: value.startLocation, canvasSize: proxy.size),
                              !isPointInsideNode(value.startLocation),
                              store.selectedConnectionID == nil else { return }
                        switch activeCanvasTool {
                        case .select:
                            if marqueeStart == nil { marqueeStart = value.startLocation }
                            marqueeEnd = value.location
                            updateMarqueeSelection()
                        case .pan:
                            let delta = CGSize(
                                width: value.translation.width - canvasToolDragTranslation.width,
                                height: value.translation.height - canvasToolDragTranslation.height
                            )
                            pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
                            canvasToolDragTranslation = value.translation
                        case .section:
                            if sectionToolStart == nil { sectionToolStart = value.startLocation }
                            sectionToolEnd = value.location
                        case .note:
                            break
                        }
                    }
                    .onEnded { value in
                        switch activeCanvasTool {
                        case .select:
                            guard marqueeStart != nil else { return }
                            marqueeEnd = value.location
                            updateMarqueeSelection()
                            marqueeStart = nil
                            marqueeEnd = nil
                        case .pan:
                            canvasToolDragTranslation = .zero
                        case .section:
                            guard sectionToolStart != nil else { return }
                            sectionToolEnd = value.location
                            createSectionFromCanvasRect()
                            sectionToolStart = nil
                            sectionToolEnd = nil
                        case .note:
                            break
                        }
                    }
            )
            .onDrop(of: [UTType.plainText], delegate: CanvasLibraryDropDelegate(onDrop: handleLibraryDrop))
            .onDeleteCommand(perform: deleteCanvasSelection)
            .focusable()
            .focusEffectDisabled()
            .background(MacroTheme.canvas)
            .onAppear {
                migrateSectionMemberships()
                DispatchQueue.main.async { fitWorkflow(in: proxy.size) }
            }
            .onChange(of: store.selectedAutomationID) { _, _ in
                selectedNodeIDs.removeAll()
                groupDragOrigins.removeAll()
                DispatchQueue.main.async {
                    migrateSectionMemberships()
                    fitWorkflow(in: proxy.size)
                }
            }
            .onChange(of: proxy.size) { _, newSize in
                DispatchQueue.main.async { fitWorkflow(in: newSize) }
            }
        }
    }

    private var workflowContent: some View {
        ZStack(alignment: .topLeading) {
            if let automation = store.selectedAutomation {
                let issues = automation.validationIssues(availableMacroIDs: Set(macros.map(\.id)))
                ForEach(automation.sections) { section in
                    let validNodeIDs = Set(automation.nodes.map(\.id))
                    let containedNodeIDs = section.nodeIDs.intersection(validNodeIDs)
                    WorkflowSectionCard(
                        section: section,
                        containedNodeCount: containedNodeIDs.count,
                        isSelected: store.selectedSectionID == section.id,
                        color: sectionColor(section.color),
                        canEdit: store.canEdit,
                        canDrag: activeCanvasTool == .select,
                        onSelect: {
                            selectedNodeIDs.removeAll()
                            store.selectSection(section.id)
                        },
                        onTitleEditingChanged: { isEditing in
                            if isEditing { store.beginContinuousEdit() }
                            else { store.endContinuousEdit() }
                        },
                        onRename: { store.renameSection(section.id, to: $0) },
                        onDelete: { store.deleteSection(section.id) },
                        onMoveBegan: {
                            selectedNodeIDs.removeAll()
                            store.selectSection(section.id)
                            sectionDragInProgress = true
                            marqueeStart = nil
                            marqueeEnd = nil
                            store.beginContinuousEdit()
                        },
                        onMove: { delta in
                            store.moveSection(
                                section.id,
                                by: CGSize(width: delta.width / zoom, height: delta.height / zoom)
                            )
                        },
                        onMoveEnded: {
                            sectionDragInProgress = false
                            store.endContinuousEdit()
                        },
                        onResizeBegan: {
                            sectionDragInProgress = true
                            marqueeStart = nil
                            marqueeEnd = nil
                            store.beginContinuousEdit()
                        },
                        onResize: { handle, delta in
                            store.resizeSection(
                                section.id,
                                from: handle,
                                by: CGSize(width: delta.width / zoom, height: delta.height / zoom)
                            )
                        },
                        onResizeEnded: {
                            sectionDragInProgress = false
                            expandSectionToFitMembers(sectionID: section.id)
                            store.endContinuousEdit()
                        }
                    )
                    .frame(width: max(190, section.frame.width), height: max(120, section.frame.height))
                    .position(x: section.frame.x + max(190, section.frame.width) / 2, y: section.frame.y + max(120, section.frame.height) / 2)
                }
                ForEach(automation.nodes.filter { $0.kind == .repeatFlow }) { repeatNode in
                    if let targetID = repeatNode.repeatTargetNodeID,
                       let start = loopPoint(repeatNode.id, in: automation),
                       let end = loopPoint(targetID, in: automation) {
                        let obstacles = wireObstacles(in: automation)
                        let wire = WorkflowConnectionShape(
                            start: start,
                            end: end,
                            style: .bent,
                            obstacles: obstacles,
                            portStubStyle: .rightSide
                        )
                        wire
                            .stroke(
                                Color.purple.opacity(0.9),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                        Image(systemName: "arrowtriangle.left.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.purple)
                            .position(x: end.x + 7, y: end.y)
                    }
                }
                ForEach(automation.nodes.filter { $0.kind == .loopBack }) { loopNode in
                    if let targetID = loopNode.jumpTargetNodeID,
                       let start = loopPoint(loopNode.id, in: automation),
                       let end = loopPoint(targetID, in: automation) {
                        let obstacles = wireObstacles(in: automation)
                        let wire = WorkflowConnectionShape(
                            start: start,
                            end: end,
                            style: .bent,
                            obstacles: obstacles,
                            portStubStyle: .rightSide
                        )
                        wire
                            .stroke(Color.teal.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        Image(systemName: "arrowtriangle.left.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.teal)
                            .position(x: end.x + 7, y: end.y)
                    }
                }
                ForEach(automation.connections) { connection in
                    if let start = outputPoint(connection.sourceNodeID, branch: connection.branch, in: automation),
                       let end = inputPoint(connection.targetNodeID, in: automation) {
                        let obstacles = wireObstacles(in: automation)
                        let wire = WorkflowConnectionShape(start: start, end: end, style: connection.resolvedStyle, obstacles: obstacles, bendPoint: connection.bendPoint?.cgPoint)
                        wire
                            .stroke(
                                store.selectedConnectionID == connection.id
                                    ? Color.accentColor
                                    : connection.branch == .yes ? Color.green.opacity(0.82)
                                    : connection.branch == .no ? Color.orange.opacity(0.82)
                                    : Color.secondary.opacity(0.55),
                                style: StrokeStyle(lineWidth: store.selectedConnectionID == connection.id ? 3 : 2, lineCap: .round)
                            )
                        wire
                            // Keep a generous hit target around thin bezier lines. A connection
                            // can be selected/deleted without pixel-perfect clicking.
                            .stroke(Color.black.opacity(0.001), lineWidth: 28)
                            .contentShape(WorkflowConnectionShape(start: start, end: end, style: connection.resolvedStyle, obstacles: obstacles, bendPoint: connection.bendPoint?.cgPoint).stroke(lineWidth: 28))
                            .onTapGesture { store.selectConnection(connection.id) }
                            .contextMenu {
                                Button("Delete Connection", systemImage: "trash", role: .destructive) {
                                    store.selectConnection(connection.id)
                                    store.deleteSelection()
                                }
                                .disabled(!store.canEdit)
                            }
                            .help("Click to select · right-click to delete · press Delete")
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(store.selectedConnectionID == connection.id ? Color.accentColor : .secondary)
                            .position(x: end.x, y: end.y - 8)
                            .allowsHitTesting(false)

                        if store.selectedConnectionID == connection.id, store.canEdit {
                            if let bendPoint = connection.bendPoint?.cgPoint {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 10, height: 10)
                                    .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 2) }
                                    .frame(width: 38, height: 38)
                                    .contentShape(Circle())
                                    .zIndex(9)
                                    .position(bendPoint)
                                    .highPriorityGesture(
                                        DragGesture(minimumDistance: 1, coordinateSpace: .named("automationCanvas"))
                                            .onChanged { store.setConnectionBendPoint(connection.id, to: logicalPoint(from: $0.location)) }
                                    )
                                    .help("Drag to reshape this wire")
                            }
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 12, height: 12)
                                .overlay { Circle().stroke(.white.opacity(0.8), lineWidth: 2) }
                                .frame(width: 48, height: 48)
                                .contentShape(Circle())
                                .zIndex(8)
                                .position(end)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .named("automationCanvas"))
                                        .onChanged { updateConnectionDraft(source: connection.sourceNodeID, branch: connection.branch, canvasPoint: $0.location, automation: automation) }
                                        .onEnded { finishConnection(from: connection.sourceNodeID, branch: connection.branch, at: logicalPoint(from: $0.location), in: automation) }
                                )
                            Button {
                                store.selectConnection(connection.id)
                                store.deleteSelection()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(MacroPalette.recording)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Delete connection")
                            .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 15)
                        }
                    }
                }

                if let draft,
                   let start = outputPoint(draft.sourceNodeID, branch: draft.branch, in: automation) {
                    WorkflowConnectionShape(start: start, end: draft.currentPoint)
                        .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                ForEach(automation.nodes) { node in
                    WorkflowNodeCard(
                        node: node,
                        title: title(for: node),
                        subtitle: subtitle(for: node),
                        color: nodeColor(node.kind),
                        size: nodeSize,
                        isSelected: selectedNodeIDs.contains(node.id) || store.selectedNodeID == node.id,
                        runState: store.nodeRunState(node.id),
                        validationIssue: issues.first { $0.nodeID == node.id },
                        isConnectionTarget: draft?.targetNodeID == node.id,
                        isEditable: store.canEdit && activeCanvasTool == .select,
                        zoom: zoom,
                        onSelect: {
                            if !selectedNodeIDs.contains(node.id) {
                                selectedNodeIDs = [node.id]
                            }
                            store.selectNode(node.id)
                        },
                        onMoveBegan: {
                            nodeDragInProgress = true
                            marqueeStart = nil
                            marqueeEnd = nil
                            groupDragOrigins.removeAll()
                            store.beginContinuousEdit()
                        },
                        onMove: { point in
                            moveSelectedNodes(draggedNodeID: node.id, to: point, nodes: automation.nodes)
                        },
                        onMoveEnded: {
                            nodeDragInProgress = false
                            alignmentGuides = CanvasAlignmentGuides()
                            groupDragOrigins.removeAll()
                            resolveNodeCollisions(for: selectedNodeIDs)
                            reconcileSectionMembership(for: selectedNodeIDs)
                            store.endContinuousEdit()
                        },
                        onConnectionChanged: { branch, canvasPoint in
                            updateConnectionDraft(source: node.id, branch: branch, canvasPoint: canvasPoint, automation: automation)
                        },
                        onConnectionEnded: { branch, canvasPoint in
                            finishConnection(from: node.id, branch: branch, at: logicalPoint(from: canvasPoint), in: automation)
                        },
                        onRun: { model.runAutomationFromNode(node) },
                        onRunNode: { model.testAutomationNode(node) },
                        onTest: { model.testAutomationNode(node) },
                        onDuplicate: {
                            store.duplicateNode(node.id)
                            if let duplicatedNodeID = store.selectedNodeID {
                                resolveNodeCollisions(for: [duplicatedNodeID])
                            }
                            expandAllSectionsToFitMembers()
                        },
                        onRename: { store.renameNode(node.id, to: $0) },
                        onDisable: { store.toggleNodeEnabled(node.id) },
                        onDelete: {
                            if selectedNodeIDs.contains(node.id), selectedNodeIDs.count > 1 {
                                deleteCanvasSelection()
                            } else {
                                store.selectNode(node.id)
                                store.deleteSelection()
                                selectedNodeIDs.remove(node.id)
                            }
                        }
                    )
                    .position(node.position.cgPoint)
                }

                if let x = alignmentGuides.x {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: max(1 / zoom, 0.75), height: 1600)
                        .position(x: x, y: 800)
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
                if let y = alignmentGuides.y {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: 2400, height: max(1 / zoom, 0.75))
                        .position(x: 1200, y: y)
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
            } else {
                ContentUnavailableView(
                    "No Automation",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Create an automation from the library panel.")
                )
                .frame(width: 500, height: 400)
                .position(x: 380, y: 280)
            }
        }
        .frame(width: 2400, height: 1600, alignment: .topLeading)
    }

    private func canvasControls(size: CGSize) -> some View {
        HStack(spacing: 4) {
            AppSearchField(placeholder: "Find node", text: $nodeSearch)
                .frame(width: 138)
                .help("Find a node in this workflow")
                .onChange(of: nodeSearch) { _, value in
                    guard !value.isEmpty, let node = filteredNodes.first else { return }
                    selectedNodeIDs = [node.id]
                    store.selectNode(node.id)
                }
            Button {
                setZoom(zoom - 0.1, around: CGPoint(x: size.width / 2, y: size.height / 2))
            } label: { Image(systemName: "minus") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
                .accessibilityLabel("Zoom out")
            Slider(
                value: Binding(
                    get: { Double(zoom) },
                    set: {
                        setZoom(CGFloat($0), around: CGPoint(x: size.width / 2, y: size.height / 2))
                    }
                ),
                in: 0.4...1.8
            )
            .frame(width: 78)
            .controlSize(.mini)
            .help("Adjust canvas zoom")
            .accessibilityLabel("Canvas zoom")
            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
                .help("Current zoom level")
            Button {
                setZoom(zoom + 0.1, around: CGPoint(x: size.width / 2, y: size.height / 2))
            } label: { Image(systemName: "plus") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+)")
                .accessibilityLabel("Zoom in")
            Button {
                fitWorkflow(in: size)
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit workflow")
            Button {
                if let node = store.selectedNode { centerCanvas(on: node.position.cgPoint, in: size) }
            } label: { Image(systemName: "scope") }
                .help("Center selected node")
                .disabled(store.selectedNode == nil)
            Button {
                store.autoArrangeSelected()
                expandAllSectionsToFitMembers()
                DispatchQueue.main.async { fitWorkflow(in: size) }
            } label: { Image(systemName: "rectangle.3.group") }
                .help("Arrange workflow vertically")
                .disabled(!store.canEdit)
            if selectedNodeIDs.count > 1 {
                Divider().frame(height: 18)
                Text("\(selectedNodeIDs.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(action: createSectionFromSelection) {
                    Image(systemName: "square.dashed")
                }
                .help("Create a section around selected nodes")
                .disabled(!store.canEdit)
                Button { alignSelectedNodes(.left) } label: { Image(systemName: "align.horizontal.left") }
                    .help("Align Left")
                    .disabled(!store.canEdit)
                Button { alignSelectedNodes(.center) } label: { Image(systemName: "align.horizontal.center") }
                    .help("Align Center")
                    .disabled(!store.canEdit)
                Button { distributeSelectedNodesVertically() } label: { Image(systemName: "distribute.vertical") }
                    .help("Evenly Distribute Vertically")
                    .disabled(!store.canEdit)
            }
        }
        .buttonStyle(.borderless)
        .padding(7)
        .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(MacroTheme.border.opacity(0.9)) }
        .help("Drag empty canvas to multi-select · Right-click and drag to pan · Scroll to zoom")
        .padding(.trailing, 16)
        .frame(width: size.width, height: 64, alignment: .trailing)
        .position(x: size.width / 2, y: 32)
    }

    private func canvasToolbox(size: CGSize) -> some View {
        HStack(spacing: 3) {
            ForEach(AutomationCanvasTool.allCases) { tool in
                Button {
                    activeCanvasTool = tool
                    marqueeStart = nil
                    marqueeEnd = nil
                    sectionToolStart = nil
                    sectionToolEnd = nil
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 48, height: 42)
                        .foregroundStyle(activeCanvasTool == tool ? Color.accentColor : Color.primary.opacity(0.78))
                        .background(activeCanvasTool == tool ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(tool.title)
                .help(tool.helpTitle)
                .onHover { isHovering in
                    hoveredCanvasTool = isHovering ? tool : (hoveredCanvasTool == tool ? nil : hoveredCanvasTool)
                }
            }
            Divider().frame(height: 22).padding(.horizontal, 3)
            Button { fitWorkflow(in: size) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Fit workflow")
            .onHover { fitToolHovered = $0 }
        }
        .padding(5)
        .background(MacroTheme.raised.opacity(0.97), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(MacroTheme.border) }
        .overlay(alignment: .top) {
            if let hoverLabel = fitToolHovered ? "Fit workflow" : hoveredCanvasTool?.helpTitle {
                Text(hoverLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(MacroTheme.raised.opacity(0.98), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(MacroTheme.border, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                    .offset(y: -34)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredCanvasTool)
        .animation(.easeOut(duration: 0.12), value: fitToolHovered)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .position(x: size.width / 2, y: size.height - 36)
    }

    private var marqueeRect: CGRect? {
        guard let marqueeStart, let marqueeEnd else { return nil }
        return CGRect(
            x: min(marqueeStart.x, marqueeEnd.x),
            y: min(marqueeStart.y, marqueeEnd.y),
            width: abs(marqueeEnd.x - marqueeStart.x),
            height: abs(marqueeEnd.y - marqueeStart.y)
        )
    }

    private func isPointInsideNode(_ point: CGPoint) -> Bool {
        guard let nodes = store.selectedAutomation?.nodes else { return false }
        return nodes.contains { node in
            let center = CGPoint(x: pan.width + CGFloat(node.position.x) * zoom, y: pan.height + CGFloat(node.position.y) * zoom)
            let frame = CGRect(x: center.x - nodeSize.width * zoom / 2, y: center.y - nodeSize.height * zoom / 2, width: nodeSize.width * zoom, height: nodeSize.height * zoom)
            // The node handles and their enlarged hit targets extend beyond the
            // visible card. Treat that margin as part of the node to prevent a
            // drag that starts on a handle/edge from becoming a marquee gesture.
            return frame.insetBy(dx: -max(22, 24 * zoom), dy: -max(22, 24 * zoom)).contains(point)
        }
    }

    private func isCanvasGestureAllowed(at point: CGPoint, canvasSize: CGSize) -> Bool {
        // Keep drags in the zoom toolbar, minimap, and bottom tool strip from
        // starting canvas actions.
        guard point.y > 58 else { return false }
        if point.x < 190 && point.y > canvasSize.height - 140 { return false }
        if point.y > canvasSize.height - 70 && abs(point.x - canvasSize.width / 2) < 220 { return false }
        return true
    }

    private func updateMarqueeSelection() {
        guard let marqueeRect, let nodes = store.selectedAutomation?.nodes else { return }
        let selected = nodes.filter { node in
            let center = CGPoint(x: pan.width + CGFloat(node.position.x) * zoom, y: pan.height + CGFloat(node.position.y) * zoom)
            let frame = CGRect(x: center.x - nodeSize.width * zoom / 2, y: center.y - nodeSize.height * zoom / 2, width: nodeSize.width * zoom, height: nodeSize.height * zoom)
            return marqueeRect.intersects(frame)
        }
        selectedNodeIDs = Set(selected.map(\.id))
        store.selectNode(selected.last?.id)
    }

    private func moveSelectedNodes(draggedNodeID: UUID, to point: CGPoint, nodes: [AutomationNode]) {
        if groupDragOrigins.isEmpty {
            let ids = selectedNodeIDs.contains(draggedNodeID) ? selectedNodeIDs : [draggedNodeID]
            groupDragOrigins = Dictionary(uniqueKeysWithValues: nodes.filter { ids.contains($0.id) }.map { ($0.id, $0.position.cgPoint) })
        }
        guard let draggedOrigin = groupDragOrigins[draggedNodeID] else {
            store.setNodePosition(draggedNodeID, to: point)
            return
        }
        let rawDelta = CGPoint(x: point.x - draggedOrigin.x, y: point.y - draggedOrigin.y)
        let snapped = snappedDragDelta(rawDelta, nodes: nodes)
        alignmentGuides = snapped.guides
        for (nodeID, origin) in groupDragOrigins {
            store.setNodePosition(nodeID, to: CGPoint(x: origin.x + snapped.delta.x, y: origin.y + snapped.delta.y))
        }
    }

    private func snappedDragDelta(_ delta: CGPoint, nodes: [AutomationNode]) -> (delta: CGPoint, guides: CanvasAlignmentGuides) {
        guard !NSEvent.modifierFlags.contains(.option), !groupDragOrigins.isEmpty else {
            return (delta, CanvasAlignmentGuides())
        }

        let movingIDs = Set(groupDragOrigins.keys)
        let stationaryNodes = nodes.filter { !movingIDs.contains($0.id) }
        guard !stationaryNodes.isEmpty else { return (delta, CanvasAlignmentGuides()) }

        let originFrames = groupDragOrigins.values.map { origin in
            CGRect(
                x: origin.x - nodeSize.width / 2,
                y: origin.y - nodeSize.height / 2,
                width: nodeSize.width,
                height: nodeSize.height
            )
        }
        guard let firstFrame = originFrames.first else { return (delta, CanvasAlignmentGuides()) }
        let originBounds = originFrames.dropFirst().reduce(firstFrame) { $0.union($1) }
        let proposedBounds = originBounds.offsetBy(dx: delta.x, dy: delta.y)
        let threshold = 8 / max(zoom, 0.25)

        let movingX = [proposedBounds.minX, proposedBounds.midX, proposedBounds.maxX]
        let movingY = [proposedBounds.minY, proposedBounds.midY, proposedBounds.maxY]
        let stationaryFrames = stationaryNodes.map(nodeFrame)
        let targetX = stationaryFrames.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let targetY = stationaryFrames.flatMap { [$0.minY, $0.midY, $0.maxY] }

        let xSnap = closestSnap(moving: movingX, targets: targetX, threshold: threshold)
        let ySnap = closestSnap(moving: movingY, targets: targetY, threshold: threshold)
        return (
            CGPoint(x: delta.x + (xSnap?.adjustment ?? 0), y: delta.y + (ySnap?.adjustment ?? 0)),
            CanvasAlignmentGuides(x: xSnap?.guide, y: ySnap?.guide)
        )
    }

    private func closestSnap(moving: [CGFloat], targets: [CGFloat], threshold: CGFloat) -> (adjustment: CGFloat, guide: CGFloat)? {
        var best: (adjustment: CGFloat, guide: CGFloat)?
        for movingValue in moving {
            for target in targets {
                let adjustment = target - movingValue
                guard abs(adjustment) <= threshold else { continue }
                if best == nil || abs(adjustment) < abs(best!.adjustment) {
                    best = (adjustment, target)
                }
            }
        }
        return best
    }

    private func deleteCanvasSelection() {
        if !selectedNodeIDs.isEmpty {
            let startNodeIDs = Set(
                (store.selectedAutomation?.nodes ?? [])
                    .filter { $0.kind == .start }
                    .map(\.id)
            )
            store.deleteNodes(selectedNodeIDs)
            selectedNodeIDs.formIntersection(startNodeIDs)
            if let remainingStartID = selectedNodeIDs.first {
                store.selectNode(remainingStartID)
            }
        } else {
            store.deleteSelection()
        }
    }

    private enum SelectionAlignment { case left, center }

    private func alignSelectedNodes(_ alignment: SelectionAlignment) {
        guard store.canEdit,
              let nodes = store.selectedAutomation?.nodes.filter({ selectedNodeIDs.contains($0.id) }),
              nodes.count > 1 else { return }
        let x: CGFloat
        switch alignment {
        case .left: x = nodes.map { $0.position.x }.min().map { CGFloat($0) } ?? 0
        case .center: x = CGFloat(nodes.map { $0.position.x }.reduce(0, +)) / CGFloat(nodes.count)
        }
        store.beginContinuousEdit()
        for node in nodes {
            store.setNodePosition(node.id, to: CGPoint(x: x, y: CGFloat(node.position.y)))
        }
        reconcileSectionMembership(for: selectedNodeIDs)
        store.endContinuousEdit()
    }

    private func distributeSelectedNodesVertically() {
        guard store.canEdit,
              let nodes = store.selectedAutomation?.nodes.filter({ selectedNodeIDs.contains($0.id) }).sorted(by: { $0.position.y < $1.position.y }),
              nodes.count > 2,
              let first = nodes.first?.position.y,
              let last = nodes.last?.position.y else { return }
        let step = (last - first) / Double(nodes.count - 1)
        store.beginContinuousEdit()
        for (index, node) in nodes.enumerated() {
            store.setNodePosition(node.id, to: CGPoint(x: CGFloat(node.position.x), y: CGFloat(first + Double(index) * step)))
        }
        reconcileSectionMembership(for: selectedNodeIDs)
        store.endContinuousEdit()
    }

    private func createSectionFromSelection() {
        guard store.canEdit,
              let nodes = store.selectedAutomation?.nodes.filter({ selectedNodeIDs.contains($0.id) }),
              nodes.count > 1 else { return }
        let minX = nodes.map { CGFloat($0.position.x) - nodeSize.width / 2 }.min() ?? 0
        let maxX = nodes.map { CGFloat($0.position.x) + nodeSize.width / 2 }.max() ?? 0
        let minY = nodes.map { CGFloat($0.position.y) - nodeSize.height / 2 }.min() ?? 0
        let maxY = nodes.map { CGFloat($0.position.y) + nodeSize.height / 2 }.max() ?? 0
        let padding: CGFloat = 30
        let header: CGFloat = 34
        let frame = WorkflowFrame(
            x: Double(minX - padding),
            y: Double(minY - padding - header),
            width: Double(max(220, maxX - minX + padding * 2)),
            height: Double(max(130, maxY - minY + padding * 2 + header))
        )
        let section = AutomationSection(
            title: "New Section",
            frame: frame,
            nodeIDs: Set(nodes.map(\.id))
        )
        store.addSection(section)
        claimNodes(section.nodeIDs, for: section.id)
        expandSectionToFitMembers(sectionID: section.id)
        selectedNodeIDs.removeAll()
        store.selectSection(section.id)
    }

    private var sectionToolRect: CGRect? {
        guard let sectionToolStart, let sectionToolEnd else { return nil }
        return CGRect(
            x: min(sectionToolStart.x, sectionToolEnd.x),
            y: min(sectionToolStart.y, sectionToolEnd.y),
            width: abs(sectionToolEnd.x - sectionToolStart.x),
            height: abs(sectionToolEnd.y - sectionToolStart.y)
        )
    }

    private func createSectionFromCanvasRect() {
        guard let rect = sectionToolRect else { return }
        let logicalTopLeft = logicalPoint(from: CGPoint(x: rect.minX, y: rect.minY))
        let logicalBottomRight = logicalPoint(from: CGPoint(x: rect.maxX, y: rect.maxY))
        let header: CGFloat = 34
        let frame = WorkflowFrame(
            x: Double(logicalTopLeft.x),
            y: Double(logicalTopLeft.y - header),
            width: Double(max(190, logicalBottomRight.x - logicalTopLeft.x)),
            height: Double(max(120, logicalBottomRight.y - logicalTopLeft.y + header))
        )
        let contentRect = CGRect(
            x: logicalTopLeft.x,
            y: logicalTopLeft.y,
            width: max(190, logicalBottomRight.x - logicalTopLeft.x),
            height: max(86, logicalBottomRight.y - logicalTopLeft.y)
        )
        let containedIDs = Set(
            (store.selectedAutomation?.nodes ?? [])
                .filter { contentRect.contains($0.position.cgPoint) }
                .map(\.id)
        )
        let section = AutomationSection(title: "New Section", frame: frame, nodeIDs: containedIDs)
        store.addSection(section)
        claimNodes(containedIDs, for: section.id)
        expandSectionToFitMembers(sectionID: section.id)
        selectedNodeIDs.removeAll()
        store.selectSection(section.id)
    }

    private func nodeFrame(_ node: AutomationNode) -> CGRect {
        CGRect(
            x: CGFloat(node.position.x) - nodeSize.width / 2,
            y: CGFloat(node.position.y) - nodeSize.height / 2,
            width: nodeSize.width,
            height: nodeSize.height
        )
    }

    private func handleLibraryDrop(_ token: String, at location: CGPoint) -> Bool {
        guard store.canEdit,
              !blockedDropRects.contains(where: { $0.contains(location) }) else { return false }
        let proposedPoint = logicalPoint(from: location)
        let targetSectionID = store.selectedAutomation?.sections.reversed().first {
            $0.frame.cgRect.contains(proposedPoint)
        }?.id
        let point = nonOverlappingDropPoint(proposedPoint)
        let existingNodeIDs = Set(store.selectedAutomation?.nodes.map(\.id) ?? [])

        if token.hasPrefix("macro:"),
           let id = UUID(uuidString: String(token.dropFirst("macro:".count))) {
            store.addNode(kind: .macro, macroID: id, at: point)
        } else if token.hasPrefix("flow:"),
                  let kind = AutomationNodeKind(rawValue: String(token.dropFirst("flow:".count))) {
            store.addNode(kind: kind, at: point)
        } else {
            return false
        }

        guard let nodeID = store.selectedNodeID, !existingNodeIDs.contains(nodeID) else { return false }
        selectedNodeIDs = [nodeID]
        if let targetSectionID {
            attachNode(nodeID, to: targetSectionID)
        } else {
            reconcileSectionMembership(for: [nodeID])
        }
        return true
    }

    /// Keeps a newly dropped library node from landing directly on an existing
    /// node. The user's horizontal drop position is preserved while the node is
    /// advanced downward to the nearest free row.
    private func nonOverlappingDropPoint(_ proposedPoint: CGPoint) -> CGPoint {
        if NSEvent.modifierFlags.contains(.option) { return proposedPoint }
        guard let nodes = store.selectedAutomation?.nodes, !nodes.isEmpty else { return proposedPoint }
        let verticalStep = nodeSize.height + 18
        var candidate = proposedPoint

        for _ in 0..<100 {
            let candidateFrame = CGRect(
                x: candidate.x - nodeSize.width / 2,
                y: candidate.y - nodeSize.height / 2,
                width: nodeSize.width,
                height: nodeSize.height
            ).insetBy(dx: -9, dy: -9)
            guard nodes.contains(where: { candidateFrame.intersects(nodeFrame($0)) }) else {
                return candidate
            }
            candidate.y += verticalStep
        }
        return candidate
    }

    /// Prevents node cards from stacking after a drag or duplication. Multiple
    /// selected nodes are shifted together so their internal layout and
    /// connections remain unchanged.
    private func resolveNodeCollisions(for movingNodeIDs: Set<UUID>) {
        guard let offset = collisionResolutionOffset(for: movingNodeIDs),
              let automation = store.selectedAutomation else { return }
        let movingNodes = automation.nodes.filter { movingNodeIDs.contains($0.id) }
        for node in movingNodes {
            store.setNodePosition(
                node.id,
                to: CGPoint(
                    x: CGFloat(node.position.x) + offset.width,
                    y: CGFloat(node.position.y) + offset.height
                )
            )
        }
    }

    private func collisionResolutionOffset(for movingNodeIDs: Set<UUID>) -> CGSize? {
        guard store.canEdit,
              !NSEvent.modifierFlags.contains(.option),
              !movingNodeIDs.isEmpty,
              let automation = store.selectedAutomation else { return nil }

        let movingNodes = automation.nodes.filter { movingNodeIDs.contains($0.id) }
        let stationaryFrames = automation.nodes
            .filter { !movingNodeIDs.contains($0.id) }
            .map(nodeFrame)
        guard !movingNodes.isEmpty else { return nil }

        let clearance: CGFloat = 10
        func isAvailable(_ delta: CGSize) -> Bool {
            !movingNodes.contains { node in
                let frame = nodeFrame(node)
                    .offsetBy(dx: delta.width, dy: delta.height)
                    .insetBy(dx: -clearance, dy: -clearance)
                return stationaryFrames.contains { frame.intersects($0) }
            }
        }
        guard !isAvailable(.zero) else { return nil }

        let horizontalStep = nodeSize.width + clearance * 2
        let verticalStep = nodeSize.height + clearance * 2
        var candidates: [CGSize] = []
        for verticalIndex in -12...12 {
            for horizontalIndex in -6...6 where verticalIndex != 0 || horizontalIndex != 0 {
                candidates.append(CGSize(
                    width: CGFloat(horizontalIndex) * horizontalStep,
                    height: CGFloat(verticalIndex) * verticalStep
                ))
            }
        }
        candidates.sort {
            let lhsDistance = $0.width * $0.width + $0.height * $0.height
            let rhsDistance = $1.width * $1.width + $1.height * $1.height
            return lhsDistance == rhsDistance ? abs($0.width) < abs($1.width) : lhsDistance < rhsDistance
        }
        return candidates.first(where: isAvailable)
    }

    private func attachNode(_ nodeID: UUID, to sectionID: UUID) {
        guard let automation = store.selectedAutomation else { return }
        for section in automation.sections {
            var nodeIDs = section.nodeIDs
            if section.id == sectionID {
                nodeIDs.insert(nodeID)
            } else {
                nodeIDs.remove(nodeID)
            }
            store.setSectionNodeIDs(section.id, to: nodeIDs)
        }
        if automation.sections.first(where: { $0.id == sectionID })?.layout == .vertical {
            store.arrangeSectionVertically(sectionID)
        } else {
            expandSectionToFitMembers(sectionID: sectionID)
        }
    }

    /// Assigns nodes to exactly one section. A node stays attached while its
    /// center remains inside its current container; dragging its center outside
    /// detaches it or transfers it to the topmost section beneath it.
    private func reconcileSectionMembership(for affectedNodeIDs: Set<UUID>) {
        guard store.canEdit,
              !affectedNodeIDs.isEmpty,
              let automation = store.selectedAutomation else { return }

        let validNodeIDs = Set(automation.nodes.map(\.id))
        var memberships = Dictionary(uniqueKeysWithValues: automation.sections.map {
            ($0.id, $0.nodeIDs.intersection(validNodeIDs))
        })

        for nodeID in affectedNodeIDs {
            guard let node = automation.nodes.first(where: { $0.id == nodeID }) else { continue }
            let currentOwner = automation.sections.first {
                memberships[$0.id, default: []].contains(nodeID)
            }
            let owner: AutomationSection?
            if let currentOwner, currentOwner.frame.cgRect.contains(node.position.cgPoint) {
                owner = currentOwner
            } else {
                owner = automation.sections.reversed().first {
                    $0.frame.cgRect.contains(node.position.cgPoint)
                }
            }

            for section in automation.sections {
                if section.id == owner?.id {
                    memberships[section.id, default: []].insert(nodeID)
                } else {
                    memberships[section.id, default: []].remove(nodeID)
                }
            }
        }

        for section in automation.sections {
            let nodeIDs = memberships[section.id, default: []]
            store.setSectionNodeIDs(section.id, to: nodeIDs)
            if section.layout == .vertical {
                store.arrangeSectionVertically(section.id)
            } else {
                expandSectionToFitMembers(sectionID: section.id, nodeIDs: nodeIDs)
            }
        }
    }

    /// Makes a newly created section the sole owner of its initial nodes.
    private func claimNodes(_ nodeIDs: Set<UUID>, for sectionID: UUID) {
        guard !nodeIDs.isEmpty, let automation = store.selectedAutomation else { return }
        for section in automation.sections where section.id != sectionID {
            store.setSectionNodeIDs(section.id, to: section.nodeIDs.subtracting(nodeIDs))
        }
    }

    /// Loads old section data safely. Sections saved before persistent
    /// membership existed adopt the nodes whose centers are already inside.
    private func migrateSectionMemberships() {
        guard store.canEdit, let automation = store.selectedAutomation else { return }
        let validNodeIDs = Set(automation.nodes.map(\.id))
        var claimedNodeIDs = Set<UUID>()
        var memberships: [UUID: Set<UUID>] = [:]

        for section in automation.sections.reversed() {
            var nodeIDs = section.nodeIDs.intersection(validNodeIDs).subtracting(claimedNodeIDs)
            if nodeIDs.isEmpty {
                nodeIDs = Set(automation.nodes.filter {
                    !claimedNodeIDs.contains($0.id) && section.frame.cgRect.contains($0.position.cgPoint)
                }.map(\.id))
            }
            memberships[section.id] = nodeIDs
            claimedNodeIDs.formUnion(nodeIDs)
        }

        for section in automation.sections {
            let nodeIDs = memberships[section.id, default: []]
            store.setSectionNodeIDs(section.id, to: nodeIDs)
            if section.layout == .vertical {
                store.arrangeSectionVertically(section.id)
            } else {
                expandSectionToFitMembers(sectionID: section.id, nodeIDs: nodeIDs)
            }
        }
    }

    /// Sections grow as attached nodes approach or cross an edge. They never
    /// shrink automatically, so a user's manual size remains intact.
    private func expandSectionToFitMembers(sectionID: UUID?, nodeIDs suppliedNodeIDs: Set<UUID>? = nil) {
        guard let sectionID,
              let automation = store.selectedAutomation,
              let section = automation.sections.first(where: { $0.id == sectionID }) else { return }
        let nodeIDs = suppliedNodeIDs ?? section.nodeIDs
        let memberFrames = automation.nodes.filter { nodeIDs.contains($0.id) }.map(nodeFrame)
        guard let firstFrame = memberFrames.first else { return }

        let bounds = memberFrames.dropFirst().reduce(firstFrame) { $0.union($1) }
        let headerHeight: CGFloat = 34
        let padding = CGFloat(section.padding)
        let requiredFrame = CGRect(
            x: bounds.minX - padding,
            y: bounds.minY - headerHeight - padding,
            width: bounds.width + padding * 2,
            height: bounds.height + headerHeight + padding * 2
        )
        let currentFrame = section.frame.cgRect
        let expandedFrame = CGRect(
            x: min(currentFrame.minX, requiredFrame.minX),
            y: min(currentFrame.minY, requiredFrame.minY),
            width: max(currentFrame.maxX, requiredFrame.maxX) - min(currentFrame.minX, requiredFrame.minX),
            height: max(currentFrame.maxY, requiredFrame.maxY) - min(currentFrame.minY, requiredFrame.minY)
        )
        guard expandedFrame != currentFrame else { return }
        store.setSectionFrame(
            sectionID,
            to: WorkflowFrame(
                x: Double(expandedFrame.minX),
                y: Double(expandedFrame.minY),
                width: Double(expandedFrame.width),
                height: Double(expandedFrame.height)
            )
        )
    }

    private func expandAllSectionsToFitMembers() {
        guard let automation = store.selectedAutomation else { return }
        for section in automation.sections {
            if section.layout == .vertical {
                store.arrangeSectionVertically(section.id)
            } else {
                expandSectionToFitMembers(sectionID: section.id)
            }
        }
    }

    private func setZoom(_ proposedZoom: CGFloat, around anchor: CGPoint) {
        let newZoom = min(1.8, max(0.4, proposedZoom))
        guard newZoom != zoom else { return }
        let logicalAnchor = CGPoint(
            x: (anchor.x - pan.width) / zoom,
            y: (anchor.y - pan.height) / zoom
        )
        pan = CGSize(
            width: anchor.x - logicalAnchor.x * newZoom,
            height: anchor.y - logicalAnchor.y * newZoom
        )
        zoom = newZoom
    }

    private var filteredNodes: [AutomationNode] {
        guard let nodes = store.selectedAutomation?.nodes else { return [] }
        let query = nodeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }
        return nodes.filter { title(for: $0).localizedCaseInsensitiveContains(query) || subtitle(for: $0).localizedCaseInsensitiveContains(query) }
    }

    private func centerCanvas(on point: CGPoint, in size: CGSize) {
        pan = CGSize(width: size.width / 2 - point.x * zoom, height: size.height / 2 - point.y * zoom)
    }

    private func logicalPoint(from canvasPoint: CGPoint) -> CGPoint {
        CGPoint(x: (canvasPoint.x - pan.width) / zoom, y: (canvasPoint.y - pan.height) / zoom)
    }

    private func outputPoint(_ id: UUID, branch: AutomationBranch? = nil, in automation: AutomationDefinition) -> CGPoint? {
        guard let node = automation.nodes.first(where: { $0.id == id }) else { return nil }
        let offset: CGFloat = branch == .yes ? -62 : branch == .no ? 62 : 0
        return CGPoint(x: CGFloat(node.position.x) + offset, y: CGFloat(node.position.y) + nodeSize.height / 2)
    }

    private func inputPoint(_ id: UUID, in automation: AutomationDefinition) -> CGPoint? {
        guard let node = automation.nodes.first(where: { $0.id == id }) else { return nil }
        return CGPoint(x: CGFloat(node.position.x), y: CGFloat(node.position.y) - nodeSize.height / 2)
    }

    private func loopPoint(_ id: UUID, in automation: AutomationDefinition) -> CGPoint? {
        guard let node = automation.nodes.first(where: { $0.id == id }) else { return nil }
        return CGPoint(x: CGFloat(node.position.x) + nodeSize.width / 2, y: CGFloat(node.position.y))
    }

    private func wireObstacles(in automation: AutomationDefinition) -> [CGRect] {
        automation.nodes.map { node in
            // Keep cards solid while preserving narrow, visually valid channels
            // between nearby nodes. The router adds another 12 points whenever
            // it deliberately chooses an outside channel.
            let clearance: CGFloat = 6
            return CGRect(
                x: CGFloat(node.position.x) - nodeSize.width / 2 - clearance,
                y: CGFloat(node.position.y) - nodeSize.height / 2 - clearance,
                width: nodeSize.width + clearance * 2,
                height: nodeSize.height + clearance * 2
            )
        }
    }

    private func finishConnection(from source: UUID, branch: AutomationBranch? = nil, at point: CGPoint, in automation: AutomationDefinition) {
        defer { draft = nil }
        guard store.canEdit else { return }
        guard let target = connectionTarget(at: point, excluding: source, in: automation) else {
            store.setStatusMessage("Drop the connection over a valid input node.")
            return
        }
        store.connect(source: source, target: target.id, branch: branch)
        store.setStatusMessage("Connected to (title(for: target))")
    }

    private func updateConnectionDraft(
        source: UUID,
        branch: AutomationBranch? = nil,
        canvasPoint: CGPoint,
        automation: AutomationDefinition
    ) {
        let point = logicalPoint(from: canvasPoint)
        let target = connectionTarget(at: point, excluding: source, in: automation)
        let snappedPoint = target.flatMap { inputPoint($0.id, in: automation) } ?? point
        draft = ConnectionDraft(
            sourceNodeID: source,
            branch: branch,
            currentPoint: snappedPoint,
            targetNodeID: target?.id
        )
    }

    private func connectionTarget(
        at point: CGPoint,
        excluding source: UUID,
        in automation: AutomationDefinition
    ) -> AutomationNode? {
        let candidates = automation.nodes.filter { $0.id != source && $0.kind.acceptsInput }

        // Dropping anywhere over a destination card should connect it. The expanded
        // bounds also make the small input handle forgiving at different zoom levels.
        if let contained = candidates.min(by: {
            distance(point, $0.position.cgPoint) < distance(point, $1.position.cgPoint)
        }).flatMap({ nearest in
            let bounds = CGRect(
                x: CGFloat(nearest.position.x) - nodeSize.width / 2 - 18,
                y: CGFloat(nearest.position.y) - nodeSize.height / 2 - 18,
                width: nodeSize.width + 36,
                height: nodeSize.height + 36
            )
            return bounds.contains(point) ? nearest : nil
        }) {
            return contained
        }

        return candidates
            .compactMap { node -> (AutomationNode, CGFloat)? in
                guard let input = inputPoint(node.id, in: automation) else { return nil }
                return (node, distance(point, input))
            }
            .filter { $0.1 <= 64 }
            .min(by: { $0.1 < $1.1 })?.0
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func title(for node: AutomationNode) -> String {
        if let customTitle = node.customTitle, !customTitle.isEmpty { return customTitle }
        if node.kind == .macro {
            return node.macroID.flatMap { id in macros.first { $0.id == id }?.name } ?? "Missing Macro"
        }
        return node.kind.title
    }

    private func subtitle(for node: AutomationNode) -> String {
        if !node.isEnabled { return "Disabled" }
        switch node.kind {
        case .start: return "Run immediately"
        case .macro:
            guard let macro = node.macroID.flatMap({ id in macros.first { $0.id == id } }) else { return "Reference unavailable" }
            return "\(macro.actions.count) actions · \(node.playbackOverride.resolve(using: macro.mousePlaybackMode).title)"
        case .wait: return formatDuration(node.waitDuration)
        case .waitForWindow:
            let app = model.availableTargets.first { $0.bundleIdentifier == node.waitForBundleIdentifier }?.applicationName
            let match = app ?? node.waitForWindowTitle
            return match.isEmpty ? "Choose a window · timeout after \(Int(node.waitForWindowTimeout))s" : "Wait for \(match) · max \(Int(node.waitForWindowTimeout))s"
        case .ifElse:
            switch node.conditionKind {
            case .windowOpen:
                let app = model.availableTargets.first { $0.bundleIdentifier == node.conditionBundleIdentifier }?.applicationName
                let match = app ?? node.conditionWindowTitle
                return match.isEmpty ? "Choose a window condition" : "If \(match) is open"
            case .elapsedTime:
                var parts: [String] = []
                if node.conditionElapsedHours > 0 { parts.append("\(node.conditionElapsedHours)h") }
                if node.conditionElapsedMinutes > 0 { parts.append("\(node.conditionElapsedMinutes)m") }
                if node.conditionElapsedSeconds > 0 { parts.append("\(node.conditionElapsedSeconds)s") }
                if node.conditionElapsedSubsecond > 0 { parts.append("\(node.conditionElapsedSubsecond)ms") }
                return "If \(parts.isEmpty ? "0s" : parts.joined(separator: " ")) have passed"
            case .macroRunCount:
                let macroName = model.macros.first { $0.id == node.conditionMacroID }?.name ?? "macro"
                return "If \(macroName) ran \(node.conditionMacroRunCount)+ times"
            }
        case .schedule:
            if node.scheduleMode == .interval {
                let count = node.scheduleInterval == node.scheduleInterval.rounded()
                    ? String(format: "%.0f", node.scheduleInterval)
                    : String(node.scheduleInterval)
                return "Every \(count) \(node.scheduleIntervalUnit.rawValue)"
            }
            return minuteString(node.scheduleMinuteOfDay)
        case .repeatFlow:
            let count: String
            if node.repeatForDuration {
                count = "For \(String(format: "%.0f", node.repeatDuration)) \(node.repeatDurationUnit.rawValue)"
            } else {
                count = node.repeatInfinitely ? "Until stopped" : "\(node.repeatCount) times"
            }
            let target = node.repeatTargetNodeID
                .flatMap { id in store.selectedAutomation?.nodes.first { $0.id == id } }
                .map { title(for: $0) }
            return target.map { "\(count) · back to \($0)" } ?? count
        case .loopBack:
            let target = node.jumpTargetNodeID
                .flatMap { id in store.selectedAutomation?.nodes.first { $0.id == id } }
                .map { title(for: $0) }
            return target.map { "Return to \($0)" } ?? "Choose a return point"
        case .merge: return "Continue from the active path"
        case .stop: return "End automation"
        case .resetTimer: return "Restart elapsed-time checks"
        case .note: return node.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Click to add a note" : node.noteText
        }
    }

    private func fitWorkflow(in size: CGSize) {
        guard let nodes = store.selectedAutomation?.nodes, !nodes.isEmpty else { return }
        let minX = nodes.map(\.position.x).min() ?? 0
        let maxX = nodes.map(\.position.x).max() ?? 0
        let minY = nodes.map(\.position.y).min() ?? 0
        let maxY = nodes.map(\.position.y).max() ?? 0
        let contentWidth = CGFloat(maxX - minX) + nodeSize.width + 160
        let contentHeight = CGFloat(maxY - minY) + nodeSize.height + 160
        zoom = min(1.0, max(0.4, min(size.width / contentWidth, size.height / contentHeight)))
        pan = CGSize(
            width: (size.width - CGFloat(minX + maxX) * zoom) / 2,
            height: (size.height - CGFloat(minY + maxY) * zoom) / 2
        )
    }
}

private struct WorkflowSectionCard: View {
    let section: AutomationSection
    let containedNodeCount: Int
    let isSelected: Bool
    let color: Color
    let canEdit: Bool
    let canDrag: Bool
    let onSelect: () -> Void
    let onTitleEditingChanged: (Bool) -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onMoveBegan: () -> Void
    let onMove: (CGSize) -> Void
    let onMoveEnded: () -> Void
    let onResizeBegan: () -> Void
    let onResize: (AutomationSectionResizeHandle, CGSize) -> Void
    let onResizeEnded: () -> Void
    @State private var title: String
    @State private var isDragging = false
    @State private var previousTranslation = CGSize.zero
    @State private var activeResizeHandle: AutomationSectionResizeHandle?
    @State private var hoveredResizeHandle: AutomationSectionResizeHandle?
    @State private var previousResizeTranslation = CGSize.zero

    init(
        section: AutomationSection,
        containedNodeCount: Int,
        isSelected: Bool,
        color: Color,
        canEdit: Bool,
        canDrag: Bool,
        onSelect: @escaping () -> Void,
        onTitleEditingChanged: @escaping (Bool) -> Void,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onMoveBegan: @escaping () -> Void,
        onMove: @escaping (CGSize) -> Void,
        onMoveEnded: @escaping () -> Void,
        onResizeBegan: @escaping () -> Void,
        onResize: @escaping (AutomationSectionResizeHandle, CGSize) -> Void,
        onResizeEnded: @escaping () -> Void
    ) {
        self.section = section
        self.containedNodeCount = containedNodeCount
        self.isSelected = isSelected
        self.color = color
        self.canEdit = canEdit
        self.canDrag = canDrag
        self.onSelect = onSelect
        self.onTitleEditingChanged = onTitleEditingChanged
        self.onRename = onRename
        self.onDelete = onDelete
        self.onMoveBegan = onMoveBegan
        self.onMove = onMove
        self.onMoveEnded = onMoveEnded
        self.onResizeBegan = onResizeBegan
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
        _title = State(initialValue: section.title)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(color.opacity(containedNodeCount > 0 ? 0.075 : 0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(
                            color.opacity(isSelected ? 0.95 : containedNodeCount > 0 ? 0.55 : 0.3),
                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1.2, dash: [7, 4])
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("automationCanvas"))
                        .onChanged { value in
                            guard canEdit, canDrag else { return }
                            if !isDragging {
                                isDragging = true
                                previousTranslation = .zero
                                onMoveBegan()
                            }
                            let delta = CGSize(
                                width: value.translation.width - previousTranslation.width,
                                height: value.translation.height - previousTranslation.height
                            )
                            if delta != .zero { onMove(delta) }
                            previousTranslation = value.translation
                        }
                        .onEnded { _ in
                            guard isDragging else { return }
                            isDragging = false
                            previousTranslation = .zero
                            onMoveEnded()
                        }
                )
                .simultaneousGesture(TapGesture().onEnded { onSelect() })

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color.opacity(0.9))
                    TextField(
                        "Section name",
                        text: $title,
                        onEditingChanged: onTitleEditingChanged,
                        onCommit: { onRename(title) }
                    )
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .disabled(!canEdit)
                    .onChange(of: title) { _, newValue in onRename(newValue) }
                    .onChange(of: section.title) { _, newValue in
                        if title != newValue { title = newValue }
                    }
                    Spacer(minLength: 4)
                    Text("\(containedNodeCount) \(containedNodeCount == 1 ? "NODE" : "NODES")")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(color.opacity(isSelected ? 0.15 : 0.08))

                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

        }
        .overlay {
            if canEdit && canDrag {
                sectionResizeHitAreas
            }
        }
        .animation(.easeOut(duration: 0.15), value: containedNodeCount)
        .contextMenu {
            Button("Delete Section", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(!canEdit)
        }
        .accessibilityElement(children: .contain)
        .help("Drag the section background to move it and its enclosed nodes")
    }

    private var sectionResizeHitAreas: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                resizeHitArea(.top, width: max(0, width - 28), height: 10)
                    .position(x: width / 2, y: 3)
                resizeHitArea(.bottom, width: max(0, width - 28), height: 10)
                    .position(x: width / 2, y: height - 3)
                resizeHitArea(.left, width: 10, height: max(0, height - 28))
                    .position(x: 3, y: height / 2)
                resizeHitArea(.right, width: 10, height: max(0, height - 28))
                    .position(x: width - 3, y: height / 2)

                resizeHitArea(.topLeft, width: 18, height: 18)
                    .position(x: 5, y: 5)
                resizeHitArea(.topRight, width: 18, height: 18)
                    .position(x: width - 5, y: 5)
                resizeHitArea(.bottomLeft, width: 18, height: 18)
                    .position(x: 5, y: height - 5)
                resizeHitArea(.bottomRight, width: 18, height: 18)
                    .position(x: width - 5, y: height - 5)
            }
        }
        .accessibilityLabel("Resize section from any edge or corner")
    }

    private func resizeHitArea(
        _ handle: AutomationSectionResizeHandle,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Rectangle()
            .fill(color.opacity(hoveredResizeHandle == handle ? 0.13 : 0))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredResizeHandle = handle
                    resizeCursor(for: handle).set()
                } else {
                    if hoveredResizeHandle == handle { hoveredResizeHandle = nil }
                    if activeResizeHandle == nil { NSCursor.arrow.set() }
                }
            }
            .highPriorityGesture(resizeGesture(for: handle))
            .help("Drag to resize section")
    }

    private func resizeGesture(for handle: AutomationSectionResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("automationCanvas"))
            .onChanged { value in
                guard canDrag else { return }
                if activeResizeHandle == nil {
                    activeResizeHandle = handle
                    previousResizeTranslation = .zero
                    onResizeBegan()
                }
                guard activeResizeHandle == handle else { return }
                let delta = CGSize(
                    width: value.translation.width - previousResizeTranslation.width,
                    height: value.translation.height - previousResizeTranslation.height
                )
                if delta != .zero { onResize(handle, delta) }
                previousResizeTranslation = value.translation
            }
            .onEnded { _ in
                guard activeResizeHandle == handle else { return }
                activeResizeHandle = nil
                previousResizeTranslation = .zero
                NSCursor.arrow.set()
                onResizeEnded()
            }
    }

    private func resizeCursor(for handle: AutomationSectionResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        }
    }
}

private struct WorkflowNodeCard: View {
    let node: AutomationNode
    let title: String
    let subtitle: String
    let color: Color
    let size: CGSize
    let isSelected: Bool
    let runState: AutomationNodeRunState
    let validationIssue: AutomationValidationIssue?
    let isConnectionTarget: Bool
    let isEditable: Bool
    let zoom: CGFloat
    let onSelect: () -> Void
    let onMoveBegan: () -> Void
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    let onConnectionChanged: (AutomationBranch?, CGPoint) -> Void
    let onConnectionEnded: (AutomationBranch?, CGPoint) -> Void
    let onRun: () -> Void
    let onRunNode: () -> Void
    let onTest: () -> Void
    let onDuplicate: () -> Void
    let onRename: (String) -> Void
    let onDisable: () -> Void
    let onDelete: () -> Void
    @State private var dragOrigin: CGPoint?
    @State private var isConnecting = false
    @State private var isHovering = false
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(MacroTheme.card)
                .shadow(color: .black.opacity(isSelected || runState == .running ? 0.2 : 0.09), radius: 10, y: 4)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isConnectionTarget ? Color.accentColor.opacity(0.18) : node.kind == .note ? Color.yellow.opacity(0.16) : color.opacity(0.10))
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    borderColor,
                    lineWidth: isSelected || runState == .running || isConnectionTarget || validationIssue != nil ? 2 : 1
                )

            HStack(spacing: 11) {
                Image(systemName: node.kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if runState != .idle {
                        nodeStatus
                    }
                }
                Spacer(minLength: 0)
                if isHovering && node.kind != .start && node.kind != .stop && node.kind != .note {
                    Button(action: onTest) { Image(systemName: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .help("Test this node")
                }
                if let validationIssue {
                    Image(systemName: validationIssue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(validationIssue.severity == .error ? MacroPalette.recording : .orange)
                        .help(validationIssue.message)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Drag this node to move it")
                }
            }
            .padding(13)

            if node.kind.acceptsInput {
                connectionHandle
                    .offset(y: -(size.height / 2 - 8))
                    .zIndex(6)
            }
            if node.kind.providesOutput && node.kind != .ifElse {
                connectionHandle
                    .offset(y: size.height / 2 - 8)
                    .zIndex(7)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("automationCanvas"))
                            .onChanged {
                                guard isEditable else { return }
                                isConnecting = true
                                onConnectionChanged(nil, $0.location)
                            }
                            .onEnded {
                                guard isEditable else { return }
                                onConnectionEnded(nil, $0.location)
                                isConnecting = false
                            }
                    )
            }
            if node.kind == .ifElse {
                branchOutputHandle(.yes)
                    .offset(x: -62, y: size.height / 2 - 8)
                    .zIndex(7)
                branchOutputHandle(.no)
                    .offset(x: 62, y: size.height / 2 - 8)
                    .zIndex(7)
            }
            if node.kind == .repeatFlow {
                Circle()
                    .fill(MacroTheme.card)
                    .frame(width: 14, height: 14)
                    .overlay { Circle().stroke(.purple, lineWidth: 2.5) }
                    .offset(x: size.width / 2)
                    .help("Loop-back output")
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .popover(isPresented: $showRename) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename Node").font(.headline)
                TextField("Node name", text: $renameText).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showRename = false }
                    Button("Save") { onRename(renameText); showRename = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 230)
        }
        .contextMenu {
            if node.kind != .start && node.kind != .note {
                Button("Run Node", systemImage: "play.fill", action: onRunNode)
                Button("Run From Here", systemImage: "arrow.right.circle", action: onRun)
                Divider()
            }
            if node.kind != .note {
                Button("Test Node", systemImage: "stethoscope", action: onTest)
                Divider()
            }
            Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
            Button("Rename", systemImage: "pencil") { renameText = title; showRename = true }
            Button(node.isEnabled ? "Disable" : "Enable", systemImage: node.isEnabled ? "eye.slash" : "eye", action: onDisable)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("automationCanvas"))
                .onChanged { value in
                    guard isEditable, !isConnecting else { return }
                    if dragOrigin == nil {
                        dragOrigin = node.position.cgPoint
                        onMoveBegan()
                        onSelect()
                    }
                    guard let origin = dragOrigin else { return }
                    onMove(CGPoint(
                        x: origin.x + value.translation.width / zoom,
                        y: origin.y + value.translation.height / zoom
                    ))
                }
                .onEnded { _ in
                    guard isEditable else { return }
                    dragOrigin = nil
                    onMoveEnded()
                }
        )
    }

    private var connectionHandle: some View {
        Circle()
            .fill(MacroTheme.card)
            .frame(width: 14, height: 14)
            .overlay { Circle().stroke(color, lineWidth: 2.5) }
            .shadow(color: .black.opacity(0.12), radius: 2)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .help("Drag this handle to connect to another node")
    }

    private func branchOutputHandle(_ branch: AutomationBranch) -> some View {
        connectionHandle
            .overlay(alignment: .bottom) {
                Text(branch.title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(branch == .yes ? .green : .orange)
                    .fixedSize()
                    .offset(y: 12)
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("automationCanvas"))
                    .onChanged {
                        guard isEditable else { return }
                        isConnecting = true
                        onConnectionChanged(branch, $0.location)
                    }
                    .onEnded {
                        guard isEditable else { return }
                        onConnectionEnded(branch, $0.location)
                        isConnecting = false
                    }
            )
    }

    private var borderColor: Color {
        if runState == .failed { return MacroPalette.recording }
        if runState == .running { return .green }
        if isConnectionTarget { return .accentColor }
        if isSelected { return .accentColor }
        if validationIssue?.severity == .error { return MacroPalette.recording.opacity(0.8) }
        if validationIssue?.severity == .warning { return .orange.opacity(0.8) }
        return .primary.opacity(0.1)
    }

    @ViewBuilder private var nodeStatus: some View {
        switch runState {
        case .running: StatusPill(text: "RUNNING", color: .green)
        case .complete: StatusPill(text: "COMPLETE", color: .green)
        case .failed: StatusPill(text: "FAILED", color: MacroPalette.recording)
        case .idle: EmptyView()
        }
    }
}

private enum WorkflowPortStubStyle {
    case vertical
    case rightSide
}

private struct WorkflowConnectionShape: Shape {
    let start: CGPoint
    let end: CGPoint
    var style: AutomationConnectionStyle = .curved
    var obstacles: [CGRect] = []
    var bendPoint: CGPoint? = nil
    var portStubStyle: WorkflowPortStubStyle = .vertical

    func path(in rect: CGRect) -> Path {
        if let bendPoint {
            return routedPath(through: bendPoint)
        }
        if style == .curved {
            let controlDistance = max(42, abs(end.y - start.y) * 0.45)
            let control1 = CGPoint(x: start.x, y: start.y + controlDistance)
            let control2 = CGPoint(x: end.x, y: end.y - controlDistance)
            if !curveIntersectsObstacles(control1: control1, control2: control2) {
                var curve = Path()
                curve.move(to: start)
                curve.addCurve(to: end, control1: control1, control2: control2)
                return curve
            }
        } else if style == .straight && !segmentIntersectsObstacles(start, end) {
            var straight = Path()
            straight.move(to: start)
            straight.addLine(to: end)
            return straight
        }

        return routedPath()
    }

    /// Keep an exposed vertical segment beside the visible connection handles.
    /// Without these stubs, an orthogonal route may turn along the card edge and
    /// the node (drawn above the wire) makes it look attached to a side instead.
    private func routedPath(through bendPoint: CGPoint? = nil) -> Path {
        // Node obstacles include 6 points of visual clearance. A 24-point stub
        // moves the routable part of the wire fully outside its source/target
        // card before obstacle avoidance begins.
        let stubLength: CGFloat = 24
        let startStub: CGPoint
        let endStub: CGPoint
        switch portStubStyle {
        case .vertical:
            startStub = CGPoint(x: start.x, y: start.y + stubLength)
            endStub = CGPoint(x: end.x, y: end.y - stubLength)
        case .rightSide:
            startStub = CGPoint(x: start.x + stubLength, y: start.y)
            endStub = CGPoint(x: end.x + stubLength, y: end.y)
        }
        let middle: [CGPoint]
        if let bendPoint {
            let first = WorkflowWireRouter.route(from: startStub, to: bendPoint, avoiding: obstacles)
            let second = WorkflowWireRouter.route(from: bendPoint, to: endStub, avoiding: obstacles)
            middle = first + second.dropFirst()
        } else {
            middle = WorkflowWireRouter.route(from: startStub, to: endStub, avoiding: obstacles)
        }
        return polyline([start] + middle + [end])
    }

    private func polyline<S: Sequence>(_ points: S) -> Path where S.Element == CGPoint {
        let points = Array(points)
        var path = Path()
        path.move(to: points.first ?? start)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    private func segmentIntersectsObstacles(_ from: CGPoint, _ to: CGPoint) -> Bool {
        let steps = max(24, Int(hypot(to.x - from.x, to.y - from.y) / 6))
        return (0...steps).contains { step in
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            return obstacles.contains { $0.contains(point) }
        }
    }

    private func curveIntersectsObstacles(control1: CGPoint, control2: CGPoint) -> Bool {
        (0...80).contains { step in
            let t = CGFloat(step) / 80
            let inverse = 1 - t
            let point = CGPoint(
                x: inverse * inverse * inverse * start.x + 3 * inverse * inverse * t * control1.x + 3 * inverse * t * t * control2.x + t * t * t * end.x,
                y: inverse * inverse * inverse * start.y + 3 * inverse * inverse * t * control1.y + 3 * inverse * t * t * control2.y + t * t * t * end.y
            )
            return obstacles.contains { $0.contains(point) }
        }
    }
}

fileprivate enum WorkflowWireRouter {
    static func path(from start: CGPoint, to end: CGPoint, avoiding obstacles: [CGRect]) -> Path {
        let points = route(from: start, to: end, avoiding: obstacles)
        var path = Path()
        path.move(to: points.first ?? start)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    static func route(from start: CGPoint, to end: CGPoint, avoiding obstacles: [CGRect]) -> [CGPoint] {
        guard !obstacles.isEmpty else { return [start, end] }
        var xChannels: [CGFloat] = [start.x, end.x, (start.x + end.x) / 2]
        var yChannels: [CGFloat] = [start.y, end.y, (start.y + end.y) / 2]
        for obstacle in obstacles {
            xChannels.append(contentsOf: [obstacle.minX - 12, obstacle.maxX + 12])
            yChannels.append(contentsOf: [obstacle.minY - 12, obstacle.maxY + 12])
        }
        xChannels = unique(xChannels)
        yChannels = unique(yChannels)

        var candidates: [[CGPoint]] = []
        for x in xChannels {
            candidates.append([start, CGPoint(x: x, y: start.y), CGPoint(x: x, y: end.y), end])
        }
        for y in yChannels {
            candidates.append([start, CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y), end])
        }
        for x in xChannels {
            for y in yChannels {
                candidates.append([start, CGPoint(x: x, y: start.y), CGPoint(x: x, y: y), CGPoint(x: end.x, y: y), end])
                candidates.append([start, CGPoint(x: start.x, y: y), CGPoint(x: x, y: y), CGPoint(x: x, y: end.y), end])
            }
        }

        let valid = candidates
            .map(simplify)
            .filter { points in
                zip(points, points.dropFirst()).allSatisfy { segment in
                    !segmentIntersects(segment.0, segment.1, obstacles: obstacles)
                }
            }
        if let best = valid.min(by: { cost($0) < cost($1) }) { return best }

        // Keep a last-resort path outside the entire node cluster if a dense layout
        // leaves no candidate channel inside the current bounds.
        let outerX = (obstacles.map(\.maxX).max() ?? max(start.x, end.x)) + 40
        return [start, CGPoint(x: outerX, y: start.y), CGPoint(x: outerX, y: end.y), end]
    }

    private static func unique(_ values: [CGFloat]) -> [CGFloat] {
        values.sorted().reduce(into: [CGFloat]()) { result, value in
            if result.last.map({ abs($0 - value) > 0.5 }) ?? true { result.append(value) }
        }
    }

    private static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if result.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.5 }) ?? true {
                result.append(point)
            }
            while result.count >= 3 {
                let a = result[result.count - 3]
                let b = result[result.count - 2]
                let c = result[result.count - 1]
                if (abs(a.x - b.x) < 0.5 && abs(b.x - c.x) < 0.5)
                    || (abs(a.y - b.y) < 0.5 && abs(b.y - c.y) < 0.5) {
                    result.remove(at: result.count - 2)
                } else { break }
            }
        }
        return result
    }

    private static func cost(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(CGFloat(max(0, points.count - 2)) * 18) { total, segment in
            total + abs(segment.1.x - segment.0.x) + abs(segment.1.y - segment.0.y)
        }
    }

    private static func segmentIntersects(_ start: CGPoint, _ end: CGPoint, obstacles: [CGRect]) -> Bool {
        obstacles.contains { rect in
            if abs(start.y - end.y) < 0.5 {
                return start.y > rect.minY && start.y < rect.maxY
                    && max(start.x, end.x) > rect.minX && min(start.x, end.x) < rect.maxX
            }
            if abs(start.x - end.x) < 0.5 {
                return start.x > rect.minX && start.x < rect.maxX
                    && max(start.y, end.y) > rect.minY && min(start.y, end.y) < rect.maxY
            }
            return true
        }
    }
}

private struct WorkflowLoopConnectionShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let routeX = max(start.x, end.x) + 82
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: routeX, y: start.y),
            control2: CGPoint(x: routeX, y: end.y)
        )
        return path
    }
}

private struct DottedWorkflowGrid: View {
    let zoom: CGFloat
    let pan: CGSize

    var body: some View {
        Canvas { context, size in
            let spacing = max(12, 24 * zoom)
            let xOffset = pan.width.truncatingRemainder(dividingBy: spacing)
            let yOffset = pan.height.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            var x = xOffset
            while x < size.width {
                var y = yOffset
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
                    y += spacing
                }
                x += spacing
            }
            context.fill(path, with: .color(MacroTheme.grid.opacity(0.34)))
        }
    }
}

private struct WorkflowMinimap: View {
    let automation: AutomationDefinition
    let selectedNodeID: UUID?
    let activeNodeID: UUID?

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 2400, size.height / 1600)
            for connection in automation.connections {
                guard let source = automation.nodes.first(where: { $0.id == connection.sourceNodeID }),
                      let target = automation.nodes.first(where: { $0.id == connection.targetNodeID }) else { continue }
                var path = Path()
                path.move(to: point(source.position.cgPoint, scale: scale))
                path.addLine(to: point(target.position.cgPoint, scale: scale))
                context.stroke(path, with: .color(MacroTheme.border), lineWidth: 1)
            }
            for node in automation.nodes {
                let rect = CGRect(x: node.position.x * scale - 6, y: node.position.y * scale - 3, width: 12, height: 6)
                let color: Color = node.id == activeNodeID ? .green : node.id == selectedNodeID ? MacroTheme.accent : nodeColor(node.kind)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
        .background(MacroTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func point(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }
}

private struct AutomationInspector: View {
    @ObservedObject var store: AutomationStore
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let node = store.selectedNode {
                    nodeInspector(node)
                } else if let connectionID = store.selectedConnectionID {
                    connectionInspector(connectionID)
                } else if let section = store.selectedSection {
                    sectionInspector(section)
                } else {
                    automationInspector
                }
                if !store.executionHistory.isEmpty {
                    Divider()
                    executionHistorySection
                }
            }
            .padding(16)
        }
        .background(MacroTheme.panel)
    }

    @ViewBuilder
    private func sectionInspector(_ section: AutomationSection) -> some View {
        SectionLabel(text: "Section Settings")
        HStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .foregroundStyle(sectionColor(section.color))
                .frame(width: 34, height: 34)
                .background(sectionColor(section.color).opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.headline).lineLimit(2)
                Text("\(section.nodeIDs.count) \(section.nodeIDs.count == 1 ? "node" : "nodes")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        InspectorField(title: "Name") {
            TextField("Section name", text: Binding(
                get: { store.selectedSection?.title ?? section.title },
                set: { store.renameSection(section.id, to: $0) }
            ))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(MacroTheme.border, lineWidth: 1) }
        }

        InspectorField(title: "Color") {
            Picker("Color", selection: Binding(
                get: { store.selectedSection?.color ?? section.color },
                set: { newColor in store.updateSection(section.id) { $0.color = newColor } }
            )) {
                ForEach(AutomationSectionColor.allCases) { color in
                    Label(color.title, systemImage: "circle.fill")
                        .foregroundStyle(sectionColor(color))
                        .tag(color)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .inspectorControl()
        }

        InspectorField(title: "Layout") {
            Picker("Layout", selection: Binding(
                get: { store.selectedSection?.layout ?? section.layout },
                set: { store.setSectionLayout(section.id, to: $0) }
            )) {
                ForEach(AutomationSectionLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .inspectorControl()
        }

        InspectorField(title: "Padding") {
            Stepper(
                "\(Int(store.selectedSection?.padding ?? section.padding)) pt",
                value: Binding(
                    get: { store.selectedSection?.padding ?? section.padding },
                    set: { store.setSectionPadding(section.id, to: $0) }
                ),
                in: 8...64,
                step: 2
            )
        }

        if section.layout == .vertical {
            Text("Vertical Auto Layout keeps nodes centered, evenly spaced, and ordered from top to bottom.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Freeform preserves manual node positions. Hold Option while dropping or moving to allow intentional overlap.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Button("Fit to Contents", systemImage: "arrow.up.left.and.arrow.down.right") {
            store.fitSectionToContents(section.id)
        }
        .disabled(section.nodeIDs.isEmpty || !store.canEdit)

        Divider()
        Button("Detach All Nodes", systemImage: "rectangle.portrait.and.arrow.right") {
            store.detachAllNodes(from: section.id)
        }
        .disabled(section.nodeIDs.isEmpty || !store.canEdit)

        Button("Delete Section (Keep Nodes)", systemImage: "trash", role: .destructive) {
            store.deleteSection(section.id)
        }
        .disabled(!store.canEdit)
    }

    @ViewBuilder
    private func nodeInspector(_ node: AutomationNode) -> some View {
        SectionLabel(text: "Node Settings")
        HStack(spacing: 10) {
            Image(systemName: node.kind.symbol)
                .foregroundStyle(nodeColor(node.kind))
                .frame(width: 34, height: 34)
                .background(nodeColor(node.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(model.automationNodeTitle(node)).font(.headline).lineLimit(2)
        }

        if node.kind != .note {
            HStack(spacing: 8) {
                Button("Run From Here", systemImage: "arrow.right.circle") { model.runAutomationFromNode(node) }
                Button("Test Node", systemImage: "stethoscope") { model.testAutomationNode(node) }
            }
            .controlSize(.small)
            .disabled(store.runState != .idle)
        }

        if let result = store.lastTestResult, result.nodeID == node.id {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Test Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack { Text(result.status == .completed ? "Completed" : result.status == .stopped ? "Stopped" : "Failed"); Spacer(); Text(String(format: "%.2fs", result.duration)).foregroundStyle(.secondary) }
                if let message = result.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
                if let actions = result.actionsExecuted { Text("Actions executed: \(actions)").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(9)
            .background(MacroTheme.card, in: RoundedRectangle(cornerRadius: 8))
        }

        ForEach(validationIssues.filter { $0.nodeID == node.id }) { issue in
            AutomationValidationRow(issue: issue)
        }

        switch node.kind {
        case .note: noteSettings(node)
        case .macro: macroSettings(node)
        case .wait: waitSettings(node)
        case .waitForWindow: waitForWindowSettings(node)
        case .ifElse: conditionSettings(node)
        case .schedule: scheduleSettings(node)
        case .repeatFlow: repeatSettings(node)
        case .loopBack: loopBackSettings(node)
        case .merge:
            InspectorField(title: "Behavior") {
                Text("Whichever branch reaches this node continues through its single output. Use it to rejoin Yes and No paths.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .start:
            InspectorField(title: "Behavior") { Text("Run immediately").foregroundStyle(.secondary) }
        case .stop:
            InspectorField(title: "Behavior") { Text("End automation").foregroundStyle(.secondary) }
        case .resetTimer:
            InspectorField(title: "Behavior") {
                Text("Reset the elapsed-time condition timer. Use after a timed action to start the next interval.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if node.kind != .note && node.kind != .loopBack {
            Toggle("Enabled", isOn: Binding(get: { node.isEnabled }, set: { newValue in store.updateNode(node.id) { $0.isEnabled = newValue } }))
                .toggleStyle(.switch)
        }

        Divider()
        Button("Delete Node", systemImage: "trash", role: .destructive, action: store.deleteSelection)
            .disabled(node.kind == .start || store.runState != .idle)
    }

    private func noteSettings(_ node: AutomationNode) -> some View {
        Group {
            InspectorField(title: "Note") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: nodeBinding(node.id, \.noteText, default: ""))
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                    if node.noteText.isEmpty {
                        Text("Write a reminder or describe this part of the workflow…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 110, maxHeight: 220)
                .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(MacroTheme.border, lineWidth: 1) }
            }
            Text("Notes are for organization only and do not affect automation execution.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macroSettings(_ node: AutomationNode) -> some View {
        Group {
            InspectorField(title: "Macro") {
                Picker("Macro", selection: nodeBinding(node.id, \.macroID, default: nil)) {
                    Text("Missing Macro").tag(UUID?.none)
                    ForEach(model.macros) { macro in
                        Text(macro.name).tag(Optional(macro.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }

            InspectorField(title: "Playback Mode") {
                Picker("Playback", selection: nodeBinding(node.id, \.playbackOverride, default: .useMacroSetting)) {
                    ForEach(MacroPlaybackOverride.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }

            InspectorField(title: "Target") {
                Picker("Target", selection: nodeBinding(node.id, \.targetBundleIdentifier, default: nil)) {
                    Text("Use macro target").tag(String?.none)
                    ForEach(uniqueTargets) { target in
                        Text(target.applicationName).tag(target.bundleIdentifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }

            InspectorField(title: "Loops") {
                Stepper(
                    "\(node.macroLoops)",
                    value: nodeBinding(node.id, \.macroLoops, default: 1),
                    in: 1...999
                )
            }

            Button("Test Macro", systemImage: "play.circle") {
                model.testAutomationMacro(node)
            }
            .disabled(node.macroID == nil || model.runState != .idle)
        }
    }

    private func waitSettings(_ node: AutomationNode) -> some View {
        InspectorField(title: "Duration") {
            HStack {
                TextField("Seconds", value: nodeBinding(node.id, \.waitDuration, default: 30), format: .number)
                    .frame(width: 90)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(MacroTheme.border, lineWidth: 1) }
                Text("Seconds").foregroundStyle(.secondary)
            }
        }
    }

    private func waitForWindowSettings(_ node: AutomationNode) -> some View {
        Group {
            InspectorField(title: "Application") {
                Picker("Application", selection: nodeBinding(node.id, \.waitForBundleIdentifier, default: nil)) {
                    Text("Any application").tag(String?.none)
                    ForEach(uniqueTargets) { target in
                        Text(target.applicationName).tag(Optional(target.bundleIdentifier))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }
            InspectorField(title: "Window title contains") {
                TextField("Optional title text", text: nodeBinding(node.id, \.waitForWindowTitle, default: ""))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(MacroTheme.border, lineWidth: 1) }
            }
            InspectorField(title: "Timeout") {
                HStack {
                    TextField("Seconds", value: nodeBinding(node.id, \.waitForWindowTimeout, default: 60), format: .number)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 9)
                        .frame(width: 90, height: 30)
                        .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(MacroTheme.border, lineWidth: 1) }
                    Text("Seconds").foregroundStyle(.secondary)
                }
            }
            Text("The workflow continues when a matching window appears. It fails with a timeout message if none appears.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func conditionSettings(_ node: AutomationNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorField(title: "Check") {
                Picker("Condition", selection: nodeBinding(node.id, \.conditionKind, default: .windowOpen)) {
                    ForEach(AutomationConditionKind.allCases) { condition in
                        Text(condition.title).tag(condition)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }

            switch node.conditionKind {
            case .windowOpen:
                InspectorField(title: "Application") {
                    Picker("Application", selection: nodeBinding(node.id, \.conditionBundleIdentifier, default: nil)) {
                        Text("Any application").tag(String?.none)
                        ForEach(uniqueTargets) { target in
                            Text(target.applicationName).tag(Optional(target.bundleIdentifier))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .inspectorControl()
                }
                InspectorField(title: "Window title contains") {
                    TextField("Optional title text", text: nodeBinding(node.id, \.conditionWindowTitle, default: ""))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 9).stroke(MacroTheme.border, lineWidth: 1) }
                }
                Text("If a matching window is detected, follow Yes; otherwise follow No. If both fields are set, both must match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .elapsedTime:
                InspectorField(title: "Elapsed") {
                    HStack(spacing: 6) {
                        elapsedTimeField("HOURS", value: nodeBinding(node.id, \.conditionElapsedHours, default: 0), width: 54)
                        elapsedTimeField("MIN", value: nodeBinding(node.id, \.conditionElapsedMinutes, default: 0), width: 48)
                        elapsedTimeField("SEC", value: nodeBinding(node.id, \.conditionElapsedSeconds, default: 0), width: 48)
                        elapsedTimeField("MS", value: nodeBinding(node.id, \.conditionElapsedSubsecond, default: 0), width: 58)
                    }
                }
                Text("Yes when this much time has passed since the automation started; otherwise No. The timer keeps running while the flow loops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .macroRunCount:
                InspectorField(title: "Macro") {
                    Picker("Macro", selection: nodeBinding(node.id, \.conditionMacroID, default: nil)) {
                        Text("Choose a macro").tag(UUID?.none)
                        ForEach(model.macros) { macro in Text(macro.name).tag(Optional(macro.id)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .inspectorControl()
                }
                InspectorField(title: "Has run at least") {
                    Stepper("\(node.conditionMacroRunCount) times", value: nodeBinding(node.id, \.conditionMacroRunCount, default: 1), in: 1...999)
                }
                Text("The count includes runs in this automation execution, including macro loops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scheduleSettings(_ node: AutomationNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorField(title: "Trigger") {
                Picker("Trigger", selection: nodeBinding(node.id, \.scheduleMode, default: .atTime)) {
                    ForEach(AutomationScheduleMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }

            if node.scheduleMode == .atTime {
                InspectorField(title: "Start") {
                    DatePicker(
                        "Start",
                        selection: Binding(
                            get: { dateForMinute(node.scheduleMinuteOfDay) },
                            set: { date in
                                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                                store.updateNode(node.id) { $0.scheduleMinuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .tint(MacroTheme.accent)
                    .inspectorControl()
                }
                InspectorField(title: "Repeat") {
                    Picker("Repeat", selection: nodeBinding(node.id, \.scheduleRepeat, default: .once)) {
                        ForEach(AutomationScheduleRepeat.allCases) { option in Text(option.title).tag(option) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .inspectorControl()
                }
                Text("The workflow waits until the next selected time before continuing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                InspectorField(title: "Every") {
                    HStack(spacing: 8) {
                        Stepper(value: nodeBinding(node.id, \.scheduleInterval, default: 5), in: 1...999, step: 1) {
                            Text(String(format: "%.0f", node.scheduleInterval))
                                .monospacedDigit()
                                .frame(minWidth: 28)
                        }
                        .fixedSize()
                        Picker("Unit", selection: nodeBinding(node.id, \.scheduleIntervalUnit, default: .minutes)) {
                            ForEach(AutomationScheduleUnit.allCases) { unit in Text(unit.title).tag(unit) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .inspectorControl()
                    }
                }
                Text("Each interval, the flow runs from Start through Stop, then waits for the next interval. Stop the automation to end the repeating schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func repeatSettings(_ node: AutomationNode) -> some View {
        Group {
            InspectorField(title: "Loop Back To") {
                Picker("Loop target", selection: nodeBinding(node.id, \.repeatTargetNodeID, default: nil)) {
                    Text("Choose a node").tag(UUID?.none)
                    ForEach(repeatTargets(for: node)) { target in
                        Text(model.automationNodeTitle(target)).tag(Optional(target.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }
            InspectorField(title: "Repeat Mode") {
                Picker("Repeat mode", selection: Binding<AutomationRepeatMode>(
                    get: {
                        guard let current = store.selectedAutomation?.nodes.first(where: { $0.id == node.id }) else { return .count }
                        if current.repeatForDuration { return .duration }
                        return current.repeatInfinitely ? .infinite : .count
                    },
                    set: { mode in
                        store.updateNode(node.id) {
                            $0.repeatInfinitely = mode == .infinite
                            $0.repeatForDuration = mode == .duration
                        }
                    }
                )) {
                    ForEach(AutomationRepeatMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }
            if node.repeatForDuration {
                InspectorField(title: "Duration") {
                    HStack(spacing: 8) {
                        Stepper(value: nodeBinding(node.id, \.repeatDuration, default: 9), in: 1...999, step: 1) {
                            Text(String(format: "%.0f", node.repeatDuration))
                                .monospacedDigit()
                                .frame(minWidth: 28)
                        }
                        .fixedSize()
                        Picker("Unit", selection: nodeBinding(node.id, \.repeatDurationUnit, default: .minutes)) {
                            ForEach(AutomationScheduleUnit.allCases) { unit in Text(unit.title).tag(unit) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .inspectorControl()
                    }
                }
            } else if !node.repeatInfinitely {
                InspectorField(title: "Times") {
                    Stepper(
                        "\(node.repeatCount)",
                        value: nodeBinding(node.id, \.repeatCount, default: 5),
                        in: 1...999
                    )
                }
            }
            Text(node.repeatForDuration
                 ? "The target section repeats while the timer runs. When time expires, the flow continues from this node's output. The timer starts again when the workflow returns to this Repeat node."
                 : "After the selected section repeats, execution continues through the Repeat node's normal output.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loopBackSettings(_ node: AutomationNode) -> some View {
        Group {
            InspectorField(title: "Return To") {
                Picker("Return target", selection: nodeBinding(node.id, \.jumpTargetNodeID, default: nil)) {
                    Text("Choose a node").tag(UUID?.none)
                    ForEach(loopBackTargets(for: node)) { target in
                        Text(model.automationNodeTitle(target)).tag(Optional(target.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .inspectorControl()
            }
            Text("Any path connected to this node jumps back to the selected node. Multiple If / Else branches can share one Loop Back node. The automation keeps running until a path reaches Stop or you stop it manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loopBackTargets(for loopNode: AutomationNode) -> [AutomationNode] {
        store.selectedAutomation?.nodes.filter {
            $0.id != loopNode.id && $0.kind != .note && $0.kind != .loopBack && $0.kind != .stop
        } ?? []
    }

    private func repeatTargets(for repeatNode: AutomationNode) -> [AutomationNode] {
        guard let automation = store.selectedAutomation,
              let start = automation.nodes.first(where: { $0.kind == .start }) else { return [] }
        var targets: [AutomationNode] = []
        var visited = Set<UUID>()
        var cursor = automation.connections.first(where: { $0.sourceNodeID == start.id })?.targetNodeID
        while let nodeID = cursor, nodeID != repeatNode.id, visited.insert(nodeID).inserted {
            guard let node = automation.nodes.first(where: { $0.id == nodeID }) else { break }
            if node.kind != .stop && node.kind != .repeatFlow && node.kind != .note { targets.append(node) }
            cursor = automation.connections.first(where: { $0.sourceNodeID == nodeID })?.targetNodeID
        }
        return targets
    }

    private var automationInspector: some View {
        Group {
            SectionLabel(text: "Automation Settings")
            if let automation = store.selectedAutomation {
                InspectorField(title: "Automation Name") {
                    TextField("Name", text: Binding(
                        get: { store.selectedAutomation?.name ?? "" },
                        set: { value in store.updateAutomation { $0.name = value } }
                    ))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(MacroTheme.border, lineWidth: 1) }
                }
                InspectorField(title: "Description") {
                    TextEditor(text: Binding(
                        get: { store.selectedAutomation?.automationDescription ?? "" },
                        set: { value in store.updateAutomation { $0.automationDescription = value } }
                    ))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.primary)
                    .padding(8)
                    .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(MacroTheme.border, lineWidth: 1) }
                }
                InspectorField(title: "Start Mode") {
                    Picker("Start mode", selection: Binding(
                        get: { store.selectedAutomation?.startMode ?? .immediately },
                        set: { value in store.updateAutomation { $0.startMode = value } }
                    )) {
                        ForEach(AutomationStartMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .inspectorControl()
                }
                InspectorField(title: "Status") {
                    StatusPill(
                        text: store.runState.rawValue,
                        color: store.runState == .idle ? .secondary : .green
                    )
                }
                Text("\(automation.nodes.count) nodes · \(automation.connections.count) connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                SectionLabel(text: "Validation")
                if validationIssues.isEmpty {
                    Label("Workflow ready", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    ForEach(validationIssues) { issue in
                        Button {
                            if let nodeID = issue.nodeID { store.selectNode(nodeID) }
                        } label: {
                            AutomationValidationRow(issue: issue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Create or select an automation.").foregroundStyle(.secondary)
            }
        }
    }

    private func connectionInspector(_ connectionID: UUID) -> some View {
        Group {
            SectionLabel(text: "Connection")
            let connection = store.selectedAutomation?.connections.first { $0.id == connectionID }
            Label(connection?.branch.map { "\($0.title) path" } ?? "Execution path", systemImage: "arrow.right")
                .font(.headline)
            Text("This connection defines which node runs next.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(connection?.bendPoint == nil ? "Add Bend Point" : "Reset Bend Point", systemImage: connection?.bendPoint == nil ? "point.topleft.down.curvedto.point.bottomright.up" : "arrow.counterclockwise") {
                    if connection?.bendPoint == nil {
                        store.addConnectionBendPoint(connectionID)
                    } else {
                        store.setConnectionBendPoint(connectionID, to: nil)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!store.canEdit || connection == nil)
                if connection?.bendPoint != nil {
                    Text("Drag the blue handle on the wire to reshape it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Delete Connection", systemImage: "trash", role: .destructive, action: store.deleteSelection)
                .disabled(store.runState != .idle)
        }
    }

    private var executionHistorySection: some View {
        Group {
            SectionLabel(text: "Execution History")
            ForEach(Array(store.executionHistory.suffix(20).reversed())) { record in
                Button {
                    store.selectNode(record.nodeID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: executionSymbol(record.status))
                            .foregroundStyle(executionColor(record.status))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(executionDetail(record))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(record.message ?? record.title)
            }
        }
    }

    private var validationIssues: [AutomationValidationIssue] {
        store.validationIssues(availableMacroIDs: Set(model.macros.map(\.id)))
    }

    private func executionSymbol(_ status: AutomationExecutionStatus) -> String {
        switch status {
        case .running: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    private func executionColor(_ status: AutomationExecutionStatus) -> Color {
        switch status {
        case .running: .blue
        case .completed: .green
        case .failed: MacroPalette.recording
        case .stopped: .orange
        }
    }

    private func executionDetail(_ record: AutomationExecutionRecord) -> String {
        let status: String = switch record.status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
        return "\(status) · \(String(format: "%.2fs", max(0, record.duration)))"
    }

    private var uniqueTargets: [TargetWindow] {
        var seen = Set<String>()
        return model.availableTargets.filter { target in
            guard let bundle = target.bundleIdentifier else { return false }
            return seen.insert(bundle).inserted
        }
    }

    private func nodeBinding<Value>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<AutomationNode, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { store.selectedAutomation?.nodes.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback },
            set: { value in store.updateNode(id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func elapsedTimeField(_ label: String, value: Binding<Int>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .padding(.horizontal, 5)
                .frame(width: width, height: 30)
                .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(MacroTheme.border, lineWidth: 1) }
        }
    }
}

private struct AutomationValidationRow: View {
    let issue: AutomationValidationIssue

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? MacroPalette.recording : .orange)
                .frame(width: 15)
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct InspectorField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func inspectorControl() -> some View {
        self
            .tint(MacroTheme.accent)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(minHeight: 30, alignment: .leading)
            .background(MacroTheme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MacroTheme.border, lineWidth: 1) }
    }
}

private func nodeColor(_ kind: AutomationNodeKind) -> Color {
    switch kind {
    case .start: .green
    case .macro: .blue
    case .wait: .purple
    case .waitForWindow: .teal
    case .ifElse: .cyan
    case .schedule: .orange
    case .repeatFlow: .indigo
    case .loopBack: .teal
    case .merge: .cyan
    case .stop: MacroPalette.recording
    case .resetTimer: .teal
    case .note: .yellow
    }
}

private func sectionColor(_ color: AutomationSectionColor) -> Color {
    switch color {
    case .blue: .blue
    case .purple: .purple
    case .green: .green
    case .orange: .orange
    case .pink: .pink
    case .gray: .gray
    }
}

private func formatDuration(_ seconds: Double) -> String {
    if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
        return "\(Int(seconds / 60)) minutes"
    }
    return "\(String(format: "%.1f", seconds)) seconds"
}

private func minuteString(_ minute: Int) -> String {
    dateForMinute(minute).formatted(date: .omitted, time: .shortened)
}

private func dateForMinute(_ minute: Int) -> Date {
    let safe = min(max(0, minute), 1439)
    return Calendar.current.date(
        bySettingHour: safe / 60,
        minute: safe % 60,
        second: 0,
        of: .now
    ) ?? .now
}

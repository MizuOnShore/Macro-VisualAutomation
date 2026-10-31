using System.ComponentModel;
using Macro.Core;

namespace Macro.Windows;

internal sealed class MainForm : Form
{
    private const int HotkeyRecord = 1, HotkeyStop = 2, HotkeyPlay = 3;
    private readonly JsonStorage storage = new();
    private readonly TargetService targetService = new();
    private readonly MacroRunner macroRunner = new();
    private readonly AutomationRunner automationRunner = new();
    private readonly WindowsRecorder recorder = new();
    private List<MacroDefinition> macros;
    private List<AutomationDefinition> automations;
    private List<TargetWindow> targets = [];
    private TargetWindow? selectedTarget;

    private readonly ListBox macroList = new(), actionList = new(), targetList = new(), automationList = new(), nodeList = new(), connectionList = new();
    private readonly PropertyGrid actionProperties = new(), nodeProperties = new();
    private readonly TextBox macroName = new(), automationName = new(), logBox = new();
    private readonly ComboBox loopMode = new(), playbackMode = new(), addActionType = new(), addNodeKind = new(), connectTarget = new(), branchChoice = new();
    private readonly NumericUpDown loopCount = new() { Minimum = 1, Maximum = 1_000_000, Value = 2 };
    private readonly Label status = new(), targetDetails = new(), recorderStatus = new(), validationLabel = new();
    private readonly ToolStripButton playButton = new("Play (F8)"), pauseButton = new("Pause"), stopButton = new("Stop (F7)");
    private readonly WorkflowCanvas canvas = new();
    private readonly TabControl pages = new();
    private CancellationTokenSource? recordingCountdown;
    private bool loading;

    public MainForm()
    {
        Text = "Macro for Windows"; MinimumSize = new(980, 680); Size = new(1280, 820); StartPosition = FormStartPosition.CenterScreen;
        Font = new("Segoe UI", 9F); BackColor = Color.FromArgb(248, 249, 251);
        Directory.CreateDirectory(storage.DirectoryPath);
        macros = SafeLoad(storage.LoadMacros, [MacroDefinition.Example()]);
        automations = SafeLoad(storage.LoadAutomations, [AutomationDefinition.Blank()]);
        BuildUi(); WireEvents(); RefreshMacros(); RefreshAutomations();
        macroRunner.Logged += (message, level) => Ui(() => Log(message, level));
        macroRunner.StateChanged += _ => Ui(UpdateState);
        macroRunner.Progress += (current, total) => Ui(() => status.Text = $"Running · {current}/{total}");
        automationRunner.Logged += (message, level) => Ui(() => Log(message, level));
        automationRunner.ActiveNodeChanged += id => Ui(() => { canvas.ActiveNodeId = id; status.Text = id is null ? "Ready" : "Running automation"; });
        recorder.ActionCountChanged += count => Ui(() => recorderStatus.Text = $"Recording · {count} actions");
        FormClosing += (_, _) => { recordingCountdown?.Cancel(); macroRunner.Stop(); automationRunner.Stop(); recorder.Dispose(); SaveAll(); UnregisterHotkeys(); };
        Shown += (_, _) => { RegisterHotkeys(); RefreshTargets(); Log("Macro is ready. Select a target before playback."); };
    }

    private void BuildUi()
    {
        var tool = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, Padding = new(8, 4, 8, 4), BackColor = Color.White };
        tool.Items.AddRange([playButton, pauseButton, stopButton, new ToolStripSeparator(), new ToolStripLabel("Status:"), new ToolStripControlHost(status)]);
        status.Text = "Ready"; status.AutoSize = true;
        tool.Dock = DockStyle.Top;
        pages.Dock = DockStyle.Fill; pages.Alignment = TabAlignment.Left; pages.Multiline = true; pages.ItemSize = new(42, 150); pages.SizeMode = TabSizeMode.Fixed;
        pages.TabPages.Add(MacrosPage()); pages.TabPages.Add(RecorderPage()); pages.TabPages.Add(TargetPage());
        pages.TabPages.Add(AutomationPage()); pages.TabPages.Add(LogsPage()); pages.TabPages.Add(SettingsPage());
        Controls.Add(pages); Controls.Add(tool); tool.BringToFront();
    }

    private TabPage MacrosPage()
    {
        var page = Page("Macros");
        var split = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 260, FixedPanel = FixedPanel.Panel1 };
        var leftButtons = Flow();
        leftButtons.Controls.AddRange([Button("New", NewMacro), Button("Duplicate", DuplicateMacro), Button("Delete", DeleteMacro), Button("Import", ImportMacro), Button("Export", ExportMacro)]);
        macroList.Dock = DockStyle.Fill; leftButtons.Dock = DockStyle.Bottom; split.Panel1.Controls.Add(macroList); split.Panel1.Controls.Add(leftButtons);

        var header = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 6, Padding = new(10) };
        header.ColumnStyles.Add(new(SizeType.Percent, 100));
        macroName.Dock = DockStyle.Fill; loopMode.DataSource = Enum.GetValues<LoopMode>(); playbackMode.DataSource = Enum.GetValues<MousePlaybackMode>();
        header.Controls.Add(macroName, 0, 0); header.Controls.Add(loopMode, 1, 0); header.Controls.Add(loopCount, 2, 0); header.Controls.Add(playbackMode, 3, 0);
        header.Controls.Add(Button("Save", SaveAll), 4, 0);
        var body = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Vertical, SplitterDistance = 430 };
        actionList.Dock = DockStyle.Fill;
        var actionButtons = Flow(); addActionType.DataSource = Enum.GetValues<MacroActionType>(); addActionType.Width = 145;
        actionButtons.Controls.AddRange([addActionType, Button("Add Action", AddAction), Button("Remove", RemoveAction), Button("Up", () => MoveAction(-1)), Button("Down", () => MoveAction(1))]);
        actionButtons.Dock = DockStyle.Bottom; body.Panel1.Controls.Add(actionList); body.Panel1.Controls.Add(actionButtons);
        actionProperties.Dock = DockStyle.Fill; actionProperties.HelpVisible = true; body.Panel2.Controls.Add(actionProperties);
        split.Panel2.Controls.Add(body); split.Panel2.Controls.Add(header); page.Controls.Add(split); return page;
    }

    private TabPage RecorderPage()
    {
        var page = Page("Recorder"); var panel = CenteredPanel();
        var title = Heading("Record global keyboard and mouse input");
        recorderStatus.Text = "Ready to record"; recorderStatus.AutoSize = true;
        var text = new Label { AutoSize = true, MaximumSize = new(620, 0), Text = "Recording starts after a three-second countdown. Input continues to reach the active application. A new timestamped macro is created when recording stops. F6 starts and F7 stops." };
        var buttons = Flow(); buttons.Controls.AddRange([Button("Start Recording (F6)", () => _ = StartRecording()), Button("Stop Recording (F7)", StopRecording)]);
        panel.Controls.AddRange([title, text, recorderStatus, buttons]); page.Controls.Add(panel); return page;
    }

    private TabPage TargetPage()
    {
        var page = Page("Target"); var split = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 600 };
        targetList.Dock = DockStyle.Fill; var buttons = Flow(); buttons.Dock = DockStyle.Bottom;
        buttons.Controls.AddRange([Button("Refresh", RefreshTargets), Button("Select Window", SelectTarget), Button("Clear", () => { selectedTarget = null; ShowTarget(); })]);
        split.Panel1.Controls.Add(targetList); split.Panel1.Controls.Add(buttons);
        targetDetails.Dock = DockStyle.Top; targetDetails.Padding = new(16); targetDetails.AutoSize = true; targetDetails.MaximumSize = new(420, 0);
        var tests = Flow(); tests.Dock = DockStyle.Top; tests.Controls.AddRange([Button("Test E", () => TestInput("e")), Button("Test Center Click", TestClick)]);
        split.Panel2.Controls.Add(tests); split.Panel2.Controls.Add(targetDetails); page.Controls.Add(split); return page;
    }

    private TabPage AutomationPage()
    {
        var page = Page("Automation");
        var outer = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 220, FixedPanel = FixedPanel.Panel1 };
        automationList.Dock = DockStyle.Fill; var autoButtons = Flow(); autoButtons.Dock = DockStyle.Bottom;
        autoButtons.Controls.AddRange([Button("New", NewAutomation), Button("Delete", DeleteAutomation), Button("Run", () => _ = RunAutomation())]);
        outer.Panel1.Controls.Add(automationList); outer.Panel1.Controls.Add(autoButtons);
        var right = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterDistance = 500 };
        var canvasPanel = new Panel { Dock = DockStyle.Fill }; canvas.Dock = DockStyle.Fill;
        var autoHeader = Flow(); autoHeader.Dock = DockStyle.Top; automationName.Width = 200;
        addNodeKind.DataSource = Enum.GetValues<AutomationNodeKind>().Where(k => k != AutomationNodeKind.Start).ToArray(); addNodeKind.Width = 125;
        connectTarget.Width = 140; branchChoice.DataSource = new object[] { "Normal", "Yes", "No" }; branchChoice.Width = 80;
        autoHeader.Controls.AddRange([automationName, addNodeKind, Button("Add Node", AddNode), connectTarget, branchChoice, Button("Connect", ConnectNode), Button("Delete Node", DeleteNode), Button("Delete Link", DeleteConnection)]);
        canvasPanel.Controls.Add(canvas); canvasPanel.Controls.Add(autoHeader); right.Panel1.Controls.Add(canvasPanel);
        var inspector = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 300 };
        var lists = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal };
        nodeList.Dock = DockStyle.Fill; connectionList.Dock = DockStyle.Fill; lists.Panel1.Controls.Add(nodeList); lists.Panel2.Controls.Add(connectionList);
        inspector.Panel1.Controls.Add(lists); nodeProperties.Dock = DockStyle.Fill; validationLabel.Dock = DockStyle.Bottom; validationLabel.AutoSize = true; validationLabel.ForeColor = Color.Firebrick;
        inspector.Panel2.Controls.Add(nodeProperties); inspector.Panel2.Controls.Add(validationLabel); right.Panel2.Controls.Add(inspector);
        outer.Panel2.Controls.Add(right); page.Controls.Add(outer); return page;
    }

    private TabPage LogsPage()
    {
        var page = Page("Logs"); logBox.Multiline = true; logBox.ReadOnly = true; logBox.ScrollBars = ScrollBars.Vertical; logBox.Dock = DockStyle.Fill;
        var clear = Button("Clear", () => logBox.Clear()); clear.Dock = DockStyle.Bottom; page.Controls.Add(logBox); page.Controls.Add(clear); return page;
    }

    private TabPage SettingsPage()
    {
        var page = Page("Settings"); var panel = CenteredPanel(); panel.Controls.Add(Heading("Windows controls"));
        panel.Controls.Add(new Label { AutoSize = true, MaximumSize = new(650, 0), Text = "Global hotkeys\n\nF6 — start recording\nF7 — stop recording or playback\nF8 — play selected macro\n\nStorage\n\n" + storage.DirectoryPath + "\n\nBackground mode posts messages directly to the selected window. Compatibility mode activates the target and uses SendInput. Some games only accept focused hardware-style input; Windows provides no reliable way to force those games to consume background messages." });
        panel.Controls.Add(Button("Open data folder", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", storage.DirectoryPath) { UseShellExecute = true })));
        page.Controls.Add(panel); return page;
    }

    private void WireEvents()
    {
        playButton.Click += (_, _) => _ = PlaySelected(); pauseButton.Click += (_, _) => TogglePause(); stopButton.Click += (_, _) => StopAll();
        macroList.SelectedIndexChanged += (_, _) => LoadSelectedMacro(); actionList.SelectedIndexChanged += (_, _) => actionProperties.SelectedObject = actionList.SelectedItem;
        actionProperties.PropertyValueChanged += (_, _) => { actionList.Refresh(); SaveAll(); };
        macroName.TextChanged += (_, _) => { if (!loading && SelectedMacro is { } m) { m.Name = macroName.Text; RefreshMacroName(m); SaveAll(); } };
        loopMode.SelectedValueChanged += (_, _) => { if (!loading && SelectedMacro is { } m && loopMode.SelectedItem is LoopMode v) { m.LoopMode = v; SaveAll(); } };
        loopCount.ValueChanged += (_, _) => { if (!loading && SelectedMacro is { } m) { m.LoopCount = (int)loopCount.Value; SaveAll(); } };
        playbackMode.SelectedValueChanged += (_, _) => { if (!loading && SelectedMacro is { } m && playbackMode.SelectedItem is MousePlaybackMode v) { m.MousePlaybackMode = v; SaveAll(); } };
        targetList.DoubleClick += (_, _) => SelectTarget();
        automationList.SelectedIndexChanged += (_, _) => LoadSelectedAutomation();
        automationName.TextChanged += (_, _) => { if (!loading && SelectedAutomation is { } a) { a.Name = automationName.Text; automationList.Refresh(); SaveAll(); } };
        nodeList.SelectedIndexChanged += (_, _) => SelectNode(nodeList.SelectedItem as AutomationNode);
        connectionList.SelectedIndexChanged += (_, _) => { };
        nodeProperties.PropertyValueChanged += (_, _) => { RefreshAutomationDetail(); SaveAll(); };
        canvas.NodeSelected += id => SelectNode(SelectedAutomation?.Nodes.FirstOrDefault(n => n.Id == id));
        canvas.WorkflowChanged += SaveAll;
    }

    private MacroDefinition? SelectedMacro => macroList.SelectedItem as MacroDefinition;
    private AutomationDefinition? SelectedAutomation => automationList.SelectedItem as AutomationDefinition;
    private AutomationNode? SelectedNode => nodeProperties.SelectedObject as AutomationNode;

    private void RefreshMacros(MacroDefinition? select = null)
    {
        loading = true; var chosen = select ?? SelectedMacro; macroList.DataSource = null; macroList.DataSource = macros;
        if (chosen is not null) macroList.SelectedItem = chosen; else if (macros.Count > 0) macroList.SelectedIndex = 0; loading = false; LoadSelectedMacro();
    }
    private void LoadSelectedMacro()
    {
        loading = true; var m = SelectedMacro;
        macroName.Text = m?.Name ?? ""; loopMode.SelectedItem = m?.LoopMode ?? LoopMode.Once; loopCount.Value = Math.Clamp(m?.LoopCount ?? 2, 1, 1_000_000); playbackMode.SelectedItem = m?.MousePlaybackMode ?? MousePlaybackMode.Background;
        actionList.DataSource = null; actionList.DataSource = m?.Actions; loading = false;
    }
    private void RefreshMacroName(MacroDefinition m) { var index = macroList.SelectedIndex; macroList.DataSource = null; macroList.DataSource = macros; macroList.SelectedIndex = index; }
    private void NewMacro() { var m = new MacroDefinition(); macros.Add(m); RefreshMacros(m); SaveAll(); }
    private void DuplicateMacro() { if (SelectedMacro is not { } m) return; var copy = m.DeepClone(); macros.Add(copy); RefreshMacros(copy); SaveAll(); }
    private void DeleteMacro() { if (SelectedMacro is not { } m || MessageBox.Show($"Delete {m.Name}?", "Delete macro", MessageBoxButtons.YesNo) != DialogResult.Yes) return; macros.Remove(m); RefreshMacros(); SaveAll(); }
    private void AddAction()
    {
        if (SelectedMacro is not { } m || addActionType.SelectedItem is not MacroActionType type) return;
        var hasPoint = type is MacroActionType.LeftClick or MacroActionType.RightClick or MacroActionType.MiddleClick
            or MacroActionType.MouseDown or MacroActionType.MouseUp or MacroActionType.Move or MacroActionType.Scroll;
        var a = new MacroAction { Type = type, Duration = type is MacroActionType.Wait or MacroActionType.HoldKey ? 1 : .1, Key = type is MacroActionType.KeyDown or MacroActionType.KeyUp or MacroActionType.KeyPress or MacroActionType.HoldKey ? "e" : null, X = hasPoint ? 100 : null, Y = hasPoint ? 100 : null };
        m.Actions.Add(a); LoadSelectedMacro(); actionList.SelectedItem = a; SaveAll();
    }
    private void RemoveAction() { if (SelectedMacro is { } m && actionList.SelectedItem is MacroAction a) { m.Actions.Remove(a); LoadSelectedMacro(); SaveAll(); } }
    private void MoveAction(int offset)
    {
        if (SelectedMacro is not { } m || actionList.SelectedItem is not MacroAction a) return; var old = m.Actions.IndexOf(a); var next = old + offset;
        if (next < 0 || next >= m.Actions.Count) return; m.Actions.RemoveAt(old); m.Actions.Insert(next, a); LoadSelectedMacro(); actionList.SelectedItem = a; SaveAll();
    }
    private void ImportMacro()
    {
        using var dialog = new OpenFileDialog { Filter = "JSON files|*.json|All files|*.*" }; if (dialog.ShowDialog() != DialogResult.OK) return;
        try
        {
            MacroDefinition? one = null;
            try { one = storage.Import<MacroDefinition>(dialog.FileName); } catch { }
            if (one is not null && one.Actions is not null) { one.Id = Guid.NewGuid(); macros.Add(one); RefreshMacros(one); }
            else { var many = storage.Import<List<MacroDefinition>>(dialog.FileName) ?? []; foreach (var item in many) item.Id = Guid.NewGuid(); macros.AddRange(many); RefreshMacros(many.LastOrDefault()); }
            SaveAll();
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Import failed"); }
    }
    private void ExportMacro() { if (SelectedMacro is not { } m) return; using var d = new SaveFileDialog { Filter = "JSON files|*.json", FileName = SafeName(m.Name) + ".json" }; if (d.ShowDialog() == DialogResult.OK) storage.Export(d.FileName, m); }

    private async Task PlaySelected()
    {
        if (macroRunner.State != RunState.Idle || automationRunner.State != RunState.Idle) return;
        if (SelectedMacro is not { } macro || macro.Actions.Count == 0) { MessageBox.Show("Select a macro with at least one action."); return; }
        if (selectedTarget is null) { pages.SelectedIndex = 2; MessageBox.Show("Select a target window first."); return; }
        await macroRunner.RunAsync(macro, selectedTarget, new WindowsInputBackend(macro.MousePlaybackMode)); UpdateState();
    }
    private void TogglePause() { if (automationRunner.State != RunState.Idle) automationRunner.TogglePause(); else macroRunner.TogglePause(); UpdateState(); }
    private void StopAll() { macroRunner.Stop(); automationRunner.Stop(); if (recorder.IsRecording || recordingCountdown is not null) StopRecording(); }
    private void UpdateState() { status.Text = macroRunner.State == RunState.Idle && automationRunner.State == RunState.Idle ? "Ready" : (automationRunner.State != RunState.Idle ? automationRunner.State : macroRunner.State).ToString(); pauseButton.Enabled = macroRunner.State != RunState.Idle || automationRunner.State != RunState.Idle; stopButton.Enabled = pauseButton.Enabled || recorder.IsRecording; }

    private async Task StartRecording()
    {
        if (recorder.IsRecording || recordingCountdown is not null || macroRunner.State != RunState.Idle) return;
        recordingCountdown = new();
        try
        {
            for (var i = 3; i > 0; i--) { recorderStatus.Text = $"Recording starts in {i}"; await Task.Delay(1000, recordingCountdown.Token); }
            recorder.Start(selectedTarget); recorderStatus.Text = "Recording · 0 actions"; status.Text = "Recording";
        }
        catch (OperationCanceledException) { recorderStatus.Text = "Recording cancelled"; status.Text = "Ready"; }
        finally { recordingCountdown?.Dispose(); recordingCountdown = null; }
    }
    private void StopRecording()
    {
        if (recordingCountdown is not null) { recordingCountdown.Cancel(); return; }
        if (!recorder.IsRecording) return; var actions = recorder.Stop();
        if (actions.Count > 0)
        {
            var m = new MacroDefinition { Name = "Recording " + DateTime.Now.ToString("yyyy-MM-dd HH.mm.ss"), Actions = actions,
                TargetBundleIdentifier = selectedTarget?.ProcessName, RecordedWindowWidth = selectedTarget?.Width, RecordedWindowHeight = selectedTarget?.Height };
            macros.Add(m); RefreshMacros(m); pages.SelectedIndex = 0; SaveAll();
        }
        recorderStatus.Text = actions.Count == 0 ? "No input was captured" : $"Saved {actions.Count} actions"; status.Text = "Ready";
    }

    private void RefreshTargets() { targets = targetService.Discover().ToList(); targetList.DataSource = null; targetList.DataSource = targets; ShowTarget(); Log($"Found {targets.Count} windows"); }
    private void SelectTarget()
    {
        if (targetList.SelectedItem is not TargetWindow t) return; selectedTarget = t;
        if (SelectedMacro is { } m) m.TargetBundleIdentifier = t.ProcessName; ShowTarget(); SaveAll(); Log("Target selected: " + t);
    }
    private void ShowTarget() { targetDetails.Text = selectedTarget is null ? "No target selected. Refresh and select a visible application window." : $"Selected target\n\n{selectedTarget.ApplicationName}\n{selectedTarget.WindowTitle}\nPID {selectedTarget.ProcessId}\n{selectedTarget.Width} × {selectedTarget.Height}\n\nBackground mode does not activate this window. Compatibility mode does."; }
    private void TestInput(string key) { if (selectedTarget is null) return; var b = new WindowsInputBackend(SelectedMacro?.MousePlaybackMode ?? MousePlaybackMode.Background); b.KeyDown(key, selectedTarget); b.KeyUp(key, selectedTarget); Log("Test input posted; application receipt cannot be verified."); }
    private void TestClick() { if (selectedTarget is null) return; var b = new WindowsInputBackend(SelectedMacro?.MousePlaybackMode ?? MousePlaybackMode.Background); var x = selectedTarget.X + selectedTarget.Width / 2; var y = selectedTarget.Y + selectedTarget.Height / 2; b.MouseDown(MacroMouseButton.Left, x, y, 1, selectedTarget); b.MouseUp(MacroMouseButton.Left, x, y, 1, selectedTarget); Log("Test click posted; application receipt cannot be verified."); }

    private void RefreshAutomations(AutomationDefinition? select = null) { loading = true; var chosen = select ?? SelectedAutomation; automationList.DataSource = null; automationList.DataSource = automations; if (chosen is not null) automationList.SelectedItem = chosen; else if (automations.Count > 0) automationList.SelectedIndex = 0; loading = false; LoadSelectedAutomation(); }
    private void LoadSelectedAutomation() { loading = true; automationName.Text = SelectedAutomation?.Name ?? ""; canvas.Workflow = SelectedAutomation; loading = false; RefreshAutomationDetail(); }
    private void RefreshAutomationDetail()
    {
        var a = SelectedAutomation; nodeList.DataSource = null; nodeList.DataSource = a?.Nodes; connectionList.DataSource = null;
        connectionList.DataSource = a?.Connections.Select(c => $"{a.Nodes.FirstOrDefault(n => n.Id == c.SourceNodeID)?.Title} → {a.Nodes.FirstOrDefault(n => n.Id == c.TargetNodeID)?.Title} {c.Branch}").ToList();
        connectTarget.DataSource = null; connectTarget.DataSource = a?.Nodes.Where(n => n != SelectedNode).ToList();
        canvas.Workflow = a; var errors = a?.Validate(macros.Select(m => m.Id).ToHashSet()) ?? [];
        validationLabel.Text = errors.Count == 0 ? "Workflow is valid" : string.Join("  •  ", errors.Take(3)); validationLabel.ForeColor = errors.Count == 0 ? Color.SeaGreen : Color.Firebrick;
    }
    private void NewAutomation() { var a = AutomationDefinition.Blank(); automations.Add(a); RefreshAutomations(a); SaveAll(); }
    private void DeleteAutomation() { if (SelectedAutomation is not { } a) return; automations.Remove(a); RefreshAutomations(); SaveAll(); }
    private void AddNode()
    {
        if (SelectedAutomation is not { } a || addNodeKind.SelectedItem is not AutomationNodeKind kind) return;
        var n = new AutomationNode { Kind = kind, Position = new() { X = 250 + a.Nodes.Count * 20, Y = 100 + a.Nodes.Count * 75 } };
        if (kind == AutomationNodeKind.Macro) n.MacroID = SelectedMacro?.Id ?? macros.FirstOrDefault()?.Id;
        a.Nodes.Add(n); RefreshAutomationDetail(); SelectNode(n); SaveAll();
    }
    private void SelectNode(AutomationNode? node) { nodeProperties.SelectedObject = node; canvas.SelectedNodeId = node?.Id; if (node is not null) nodeList.SelectedItem = node; RefreshConnectTargets(); }
    private void RefreshConnectTargets() { var selected = SelectedNode; connectTarget.DataSource = null; connectTarget.DataSource = SelectedAutomation?.Nodes.Where(n => n.Id != selected?.Id).ToList(); }
    private void ConnectNode()
    {
        if (SelectedAutomation is not { } a || SelectedNode is not { } source || connectTarget.SelectedItem is not AutomationNode target) return;
        var branch = branchChoice.SelectedItem?.ToString() switch { "Yes" => AutomationBranch.Yes, "No" => AutomationBranch.No, _ => (AutomationBranch?)null };
        if (source.Kind == AutomationNodeKind.IfElse && branch is null) { MessageBox.Show("Choose Yes or No for an If / Else connection."); return; }
        if (source.Kind != AutomationNodeKind.IfElse) branch = null;
        a.Connections.RemoveAll(c => c.SourceNodeID == source.Id && c.Branch == branch);
        a.Connections.Add(new() { SourceNodeID = source.Id, TargetNodeID = target.Id, Branch = branch }); RefreshAutomationDetail(); SaveAll();
    }
    private void DeleteNode()
    {
        if (SelectedAutomation is not { } a || SelectedNode is not { } n || n.Kind == AutomationNodeKind.Start) return;
        a.Nodes.Remove(n); a.Connections.RemoveAll(c => c.SourceNodeID == n.Id || c.TargetNodeID == n.Id); nodeProperties.SelectedObject = null; RefreshAutomationDetail(); SaveAll();
    }
    private void DeleteConnection()
    {
        if (SelectedAutomation is not { } a || connectionList.SelectedIndex < 0 || connectionList.SelectedIndex >= a.Connections.Count) return;
        a.Connections.RemoveAt(connectionList.SelectedIndex); RefreshAutomationDetail(); SaveAll();
    }
    private async Task RunAutomation()
    {
        if (SelectedAutomation is not { } a) return; var errors = a.Validate(macros.Select(m => m.Id).ToHashSet());
        if (errors.Count > 0) { MessageBox.Show(string.Join(Environment.NewLine, errors), "Workflow needs attention"); return; }
        await automationRunner.RunAsync(a, id => macros.FirstOrDefault(m => m.Id == id), ResolveTarget,
            mode => new WindowsInputBackend(mode), () => targetService.Discover(), macroRunner); UpdateState();
    }
    private TargetWindow? ResolveTarget(AutomationNode node, MacroDefinition macro)
    {
        var identity = node.TargetBundleIdentifier ?? macro.TargetBundleIdentifier;
        if (selectedTarget is not null) return selectedTarget;
        return targetService.Discover().FirstOrDefault(w => string.IsNullOrWhiteSpace(identity) || string.Equals(w.ProcessName, identity, StringComparison.OrdinalIgnoreCase));
    }

    private void SaveAll() { if (loading) return; try { storage.SaveMacros(macros); storage.SaveAutomations(automations); } catch (Exception ex) { Log("Save failed: " + ex.Message, "error"); } }
    private void Log(string message, string level = "info") { logBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {level.ToUpperInvariant(),-7} {message}{Environment.NewLine}"); }
    private static List<T> SafeLoad<T>(Func<List<T>> loader, List<T> fallback) { try { var result = loader(); return result.Count == 0 ? fallback : result; } catch { return fallback; } }
    private void Ui(Action action) { if (IsDisposed) return; if (InvokeRequired) BeginInvoke(action); else action(); }

    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312)
        {
            switch ((int)m.WParam) { case HotkeyRecord: _ = StartRecording(); break; case HotkeyStop: StopAll(); break; case HotkeyPlay: _ = PlaySelected(); break; }
        }
        base.WndProc(ref m);
    }
    private void RegisterHotkeys()
    {
        var ok = NativeMethods.RegisterHotKey(Handle, HotkeyRecord, 0, 0x75) & NativeMethods.RegisterHotKey(Handle, HotkeyStop, 0, 0x76) & NativeMethods.RegisterHotKey(Handle, HotkeyPlay, 0, 0x77);
        if (!ok) Log("One or more global hotkeys are already owned by another application.", "warning");
    }
    private void UnregisterHotkeys() { for (var i = 1; i <= 3; i++) NativeMethods.UnregisterHotKey(Handle, i); }

    private static TabPage Page(string title) => new(title) { Padding = new(8), BackColor = Color.FromArgb(248, 249, 251) };
    private static FlowLayoutPanel Flow() => new() { AutoSize = true, WrapContents = true, Padding = new(4) };
    private static FlowLayoutPanel CenteredPanel() => new() { AutoSize = true, FlowDirection = FlowDirection.TopDown, Padding = new(40), Dock = DockStyle.Top, WrapContents = false };
    private static Label Heading(string text) => new() { Text = text, AutoSize = true, Font = new("Segoe UI Semibold", 18F), Margin = new(3, 3, 3, 18) };
    private static Button Button(string text, Action action) { var b = new Button { Text = text, AutoSize = true, Margin = new(4) }; b.Click += (_, _) => action(); return b; }
    private static string SafeName(string name) => string.Concat(name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
}

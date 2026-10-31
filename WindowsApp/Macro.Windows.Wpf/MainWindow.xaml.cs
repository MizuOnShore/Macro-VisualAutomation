using System.Diagnostics;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Macro.Core;
using Microsoft.Win32;

namespace Macro.Windows;

public partial class MainWindow : Window
{
    private const int HotkeyRecord = 1;
    private const int HotkeyStop = 2;
    private const int HotkeyPlay = 3;

    private readonly JsonStorage storage = new();
    private readonly TargetService targetService = new();
    private readonly MacroRunner macroRunner = new();
    private readonly AutomationRunner automationRunner = new();
    private readonly WindowsRecorder recorder = new();
    private readonly ObservableCollection<UiLogEntry> logEntries = [];
    private List<MacroDefinition> macros;
    private List<AutomationDefinition> automations;
    private List<TargetWindow> targets = [];
    private TargetWindow? selectedTarget;
    private AutomationNode? selectedNode;
    private CancellationTokenSource? recordingCountdown;
    private HwndSource? windowSource;
    private bool loading;
    private bool actionEditing;

    private sealed class UiLogEntry
    {
        public string Time { get; init; } = "";
        public string Level { get; init; } = "Info";
        public string Message { get; init; } = "";
        public string Detail { get; init; } = "";
        public string Accent { get; init; } = "#6E8498";
    }

    private MacroDefinition? SelectedMacro => MacroList.SelectedItem as MacroDefinition;
    private AutomationDefinition? SelectedAutomation => AutomationList.SelectedItem as AutomationDefinition;
    private MacroAction? SelectedAction => ActionList.SelectedItem as MacroAction;

    public MainWindow()
    {
        InitializeComponent();
        LogList.ItemsSource = logEntries;
        UpdateLogEmptyState();
        Directory.CreateDirectory(storage.DirectoryPath);
        macros = SafeLoad(storage.LoadMacros, [MacroDefinition.Example()]);
        automations = SafeLoad(storage.LoadAutomations, [AutomationDefinition.Blank()]);

        LoopModeBox.ItemsSource = Enum.GetValues<LoopMode>();
        PlaybackModeBox.ItemsSource = Enum.GetValues<MousePlaybackMode>();
        StartModeBox.ItemsSource = Enum.GetValues<Macro.Core.AutomationStartMode>();
        AddActionBox.ItemsSource = Enum.GetValues<MacroActionType>();
        ActionTypeBox.ItemsSource = Enum.GetValues<MacroActionType>();
        NodeBranch.ItemsSource = new[] { "Normal", "Yes", "No" };
        NodeBranch.SelectedIndex = 0;
        BuildNodeLibrary();

        FlowCanvas.NodeSelected += SelectNode;
        FlowCanvas.ConnectionRequested += (source, target, branch) =>
        {
            SelectNode(source);
            CreateConnection(source, target, branch);
        };
        FlowCanvas.WorkflowChanged += SaveAll;
        macroRunner.Logged += (message, level) => Ui(() => Log(message, level));
        macroRunner.StateChanged += _ => Ui(UpdateState);
        macroRunner.Progress += (current, total) => Ui(() => SetStatus($"Running · {current}/{total}", "#27C884"));
        automationRunner.Logged += (message, level) => Ui(() => Log(message, level));
        automationRunner.ActiveNodeChanged += id => Ui(() =>
        {
            FlowCanvas.ActiveNodeId = id;
            SetStatus(id is null ? "Ready" : "Running workflow", id is null ? "#6E8498" : "#A774FF");
        });
        recorder.ActionCountChanged += count => Ui(() =>
        {
            RecordState.Text = $"RECORDING · {count} ACTIONS";
            RecordTitle.Text = "Capturing input";
        });

        SourceInitialized += (_, _) =>
        {
            FitWindowToWorkArea();
            RegisterHotkeys();
        };
        SizeChanged += (_, _) => AdaptLayout();
        Loaded += (_, _) =>
        {
            RefreshMacros();
            RefreshAutomations();
            RefreshTargets();
            DataFolderText.Text = storage.DirectoryPath;
            NavigateTo("Macros");
            Log("Macro is ready. Select a target before playback.");
        };
        Closing += (_, _) =>
        {
            recordingCountdown?.Cancel();
            macroRunner.Stop();
            automationRunner.Stop();
            recorder.Dispose();
            SaveAll();
            UnregisterHotkeys();
        };
    }

    private void Navigate(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string page }) NavigateTo(page);
    }

    private void NavigateTo(string page)
    {
        MacrosPage.Visibility = page == "Macros" ? Visibility.Visible : Visibility.Collapsed;
        RecorderPage.Visibility = page == "Recorder" ? Visibility.Visible : Visibility.Collapsed;
        TargetPage.Visibility = page == "Target" ? Visibility.Visible : Visibility.Collapsed;
        LogsPage.Visibility = page == "Logs" ? Visibility.Visible : Visibility.Collapsed;
        AutomationPage.Visibility = page == "Automation" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = page == "Settings" ? Visibility.Visible : Visibility.Collapsed;
        HeaderTitle.Text = page == "Automation" ? SelectedAutomation?.Name ?? "Automation" : page;
        HeaderIcon.Text = page switch
        {
            "Recorder" => "●", "Target" => "◎", "Logs" => "≡",
            "Automation" => "◇", "Settings" => "⚙", _ => "⌘"
        };
        PlayButton.Content = page == "Automation" ? "▶  Run" : "▶  Play";
        PlayButton.ToolTip = page == "Automation" ? "Run selected workflow" : "Play selected macro";
        foreach (var button in new[] { NavMacros, NavRecorder, NavTarget, NavLogs, NavAutomation, NavSettings })
        {
            var selected = string.Equals(button.Tag?.ToString(), page, StringComparison.Ordinal);
            button.Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(selected ? "#143955" : "#081827"));
            button.BorderBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(selected ? "#245B82" : "#081827"));
        }
        if (page == "Target") RefreshTargets();
        if (page == "Automation") FlowCanvas.Fit();
    }

    private void FitWindowToWorkArea()
    {
        var area = SystemParameters.WorkArea;
        MinWidth = Math.Max(640, Math.Min(920, area.Width - 24));
        MinHeight = Math.Max(480, Math.Min(600, area.Height - 24));
        Width = Math.Max(MinWidth, Math.Min(1240, area.Width - 36));
        Height = Math.Max(MinHeight, Math.Min(780, area.Height - 36));
        Left = area.Left + Math.Max(0, (area.Width - Width) / 2);
        Top = area.Top + Math.Max(0, (area.Height - Height) / 2);
        AdaptLayout();
    }

    private void AdaptLayout()
    {
        var compact = ActualWidth > 0 && ActualWidth < 1120;
        SidebarColumn.Width = new GridLength(compact ? 168 : 190);
        MacroLibraryColumn.Width = new GridLength(compact ? 205 : 235);
        MacroInspectorColumn.Width = new GridLength(compact ? 250 : 285);
        TargetLibraryColumn.Width = new GridLength(compact ? 300 : 350);
        AutomationLibraryColumn.Width = new GridLength(compact ? 195 : 220);
        AutomationInspectorColumn.Width = new GridLength(compact ? 250 : 285);
    }

    private void DragWindow(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (e.ClickCount == 2)
        {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
            return;
        }
        try { DragMove(); } catch (InvalidOperationException) { }
    }

    private async void PlayClicked(object sender, RoutedEventArgs e)
    {
        if (AutomationPage.Visibility == Visibility.Visible)
        {
            RunAutomation(sender, e);
            return;
        }
        await PlaySelected();
    }
    private void PauseClicked(object sender, RoutedEventArgs e)
    {
        if (automationRunner.State != RunState.Idle) automationRunner.TogglePause();
        else macroRunner.TogglePause();
        UpdateState();
    }
    private void StopClicked(object sender, RoutedEventArgs e) => StopAll();

    private async Task PlaySelected()
    {
        if (macroRunner.State != RunState.Idle || automationRunner.State != RunState.Idle) return;
        if (SelectedMacro is not { } macro || macro.Actions.Count == 0)
        {
            MessageBox.Show(this, "Select a macro with at least one action.", "Nothing to play", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (selectedTarget is null)
        {
            NavigateTo("Target");
            MessageBox.Show(this, "Select the window that should receive this macro.", "Target required", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var result = await macroRunner.RunAsync(macro, selectedTarget, new WindowsInputBackend(macro.MousePlaybackMode));
        if (result.Outcome == RunOutcome.Failed) Log(result.Error ?? "Playback failed", "error");
        UpdateState();
    }

    private void StopAll()
    {
        macroRunner.Stop();
        automationRunner.Stop();
        if (recorder.IsRecording || recordingCountdown is not null) StopRecording();
        UpdateState();
    }

    private void UpdateState()
    {
        var state = automationRunner.State != RunState.Idle ? automationRunner.State : macroRunner.State;
        var busy = state != RunState.Idle || recorder.IsRecording || recordingCountdown is not null;
        SetStatus(recorder.IsRecording ? "Recording" : state == RunState.Idle ? "Ready" : state.ToString(),
            recorder.IsRecording ? "#EF4053" : state == RunState.Paused ? "#F4A340" : state == RunState.Running ? "#27C884" : "#6E8498");
        PlayButton.IsEnabled = !busy;
        PauseButton.IsEnabled = state != RunState.Idle;
        StopButton.IsEnabled = busy;
    }

    private void SetStatus(string text, string color)
    {
        HeaderStatus.Text = SidebarActivity.Text = text;
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
        HeaderDot.Fill = ActivityDot.Fill = brush;
    }

    private void MacroSearchChanged(object sender, TextChangedEventArgs e) => RefreshMacroList(SelectedMacro);

    private void RefreshMacros(MacroDefinition? select = null)
    {
        RefreshMacroList(select ?? SelectedMacro);
        if (MacroList.SelectedItem is null && MacroList.Items.Count > 0) MacroList.SelectedIndex = 0;
        LoadSelectedMacro();
    }

    private void RefreshMacroList(MacroDefinition? select)
    {
        var search = MacroSearch?.Text?.Trim() ?? "";
        var visible = string.IsNullOrWhiteSpace(search)
            ? macros.ToList()
            : macros.Where(m => m.Name.Contains(search, StringComparison.CurrentCultureIgnoreCase)).ToList();
        loading = true;
        MacroList.ItemsSource = visible;
        MacroCount.Text = visible.Count.ToString(CultureInfo.InvariantCulture);
        if (select is not null && visible.Contains(select)) MacroList.SelectedItem = select;
        loading = false;
    }

    private void MacroSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!loading)
        {
            actionEditing = false;
            LoadSelectedMacro();
        }
    }

    private void LoadSelectedMacro()
    {
        loading = true;
        var macro = SelectedMacro;
        MacroName.Text = macro?.Name ?? "";
        LoopModeBox.SelectedItem = macro?.LoopMode ?? LoopMode.Once;
        LoopCountBox.Text = (macro?.LoopCount ?? 2).ToString(CultureInfo.InvariantCulture);
        PlaybackModeBox.SelectedItem = macro?.MousePlaybackMode ?? MousePlaybackMode.Background;
        ActionList.ItemsSource = null;
        ActionList.ItemsSource = macro?.Actions;
        ActionList.SelectedIndex = macro?.Actions.Count > 0 ? 0 : -1;
        OverviewTitle.Text = macro?.Name ?? "Select a macro";
        OverviewTarget.Text = macro is null ? "Create or select a macro to begin" : macro.TargetBundleIdentifier is null ? "No target selected" : macro.TargetBundleIdentifier;
        OverviewCount.Text = (macro?.Actions.Count ?? 0).ToString(CultureInfo.InvariantCulture);
        OverviewMode.Text = macro?.LoopMode.ToString() ?? "Once";
        OverviewInput.Text = macro?.MousePlaybackMode.ToString() ?? "Background";
        InspectorTarget.Text = OverviewTarget.Text;
        InspectorPlayback.Text = OverviewInput.Text;
        InspectorActions.Text = OverviewCount.Text;
        SetActionEditor(actionEditing);
        loading = false;
        LoadSelectedAction();
    }

    private void MacroNameChanged(object sender, TextChangedEventArgs e)
    {
        if (loading || SelectedMacro is not { } macro) return;
        macro.Name = string.IsNullOrWhiteSpace(MacroName.Text) ? "Untitled Macro" : MacroName.Text;
        OverviewTitle.Text = macro.Name;
        MacroList.Items.Refresh();
        SaveAll();
    }

    private void MacroOptionChanged(object sender, RoutedEventArgs e)
    {
        if (loading || SelectedMacro is not { } macro) return;
        if (LoopModeBox.SelectedItem is LoopMode loop) macro.LoopMode = loop;
        if (int.TryParse(LoopCountBox.Text, out var count)) macro.LoopCount = Math.Clamp(count, 1, 1_000_000);
        if (PlaybackModeBox.SelectedItem is MousePlaybackMode mode) macro.MousePlaybackMode = mode;
        OverviewMode.Text = macro.LoopMode.ToString();
        OverviewInput.Text = macro.MousePlaybackMode.ToString();
        InspectorPlayback.Text = OverviewInput.Text;
        SaveAll();
    }

    private void EditActions(object sender, RoutedEventArgs e) => SetActionEditor(true);

    private void SetActionEditor(bool editing)
    {
        actionEditing = editing;
        MacroOverviewCard.Visibility = editing ? Visibility.Collapsed : Visibility.Visible;
        ActionList.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        MacroInspectorOverview.Visibility = editing ? Visibility.Collapsed : Visibility.Visible;
        ActionInspectorScroll.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ActionSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!loading) LoadSelectedAction();
    }

    private void LoadSelectedAction()
    {
        loading = true;
        var action = SelectedAction;
        ActionInspector.IsEnabled = action is not null;
        ActionInspectorTitle.Text = action?.ToString() ?? "Select an action";
        ActionTypeBox.SelectedItem = action?.Type;
        ActionKey.Text = action?.Key ?? "";
        ActionDelay.Text = (action?.Delay ?? 0).ToString("0.###", CultureInfo.InvariantCulture);
        ActionDuration.Text = (action?.Duration ?? 0).ToString("0.###", CultureInfo.InvariantCulture);
        ActionX.Text = action?.X?.ToString("0.###", CultureInfo.InvariantCulture) ?? "";
        ActionY.Text = action?.Y?.ToString("0.###", CultureInfo.InvariantCulture) ?? "";
        WindowCoordinates.IsChecked = action?.UsesWindowCoordinates ?? true;
        ScrollX.Text = (action?.ScrollDeltaX ?? 0).ToString("0.###", CultureInfo.InvariantCulture);
        ScrollY.Text = (action?.ScrollDeltaY ?? 0).ToString("0.###", CultureInfo.InvariantCulture);
        UpdateActionFieldVisibility(action?.Type);
        BuildActionAdvancedFields(action);
        loading = false;
    }

    private void UpdateActionFieldVisibility(MacroActionType? type)
    {
        var key = type is MacroActionType.KeyDown or MacroActionType.KeyUp or MacroActionType.KeyPress or MacroActionType.HoldKey;
        var point = type is MacroActionType.LeftClick or MacroActionType.RightClick or MacroActionType.MiddleClick
            or MacroActionType.MouseDown or MacroActionType.MouseUp or MacroActionType.Move or MacroActionType.Scroll;
        KeyFields.Visibility = key ? Visibility.Visible : Visibility.Collapsed;
        DurationFields.Visibility = type is MacroActionType.Wait or MacroActionType.HoldKey or MacroActionType.KeyPress
            or MacroActionType.LeftClick or MacroActionType.RightClick or MacroActionType.MiddleClick ? Visibility.Visible : Visibility.Collapsed;
        PointFields.Visibility = point ? Visibility.Visible : Visibility.Collapsed;
        ScrollFields.Visibility = type == MacroActionType.Scroll ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BuildActionAdvancedFields(MacroAction? action)
    {
        ActionAdvancedFields.Children.Clear();
        if (action is null) return;
        if (action.Type is MacroActionType.MouseDown or MacroActionType.MouseUp)
            AddCombo(ActionAdvancedFields, "MOUSE BUTTON", Enum.GetValues<MacroMouseButton>(), action.MouseButton, value => action.MouseButton = value);
        if (action.Type is MacroActionType.LeftClick or MacroActionType.RightClick or MacroActionType.MiddleClick)
            AddText(ActionAdvancedFields, "CLICK COUNT", action.ClickCount.ToString(CultureInfo.InvariantCulture), value =>
            {
                if (int.TryParse(value, out var count)) action.ClickCount = Math.Clamp(count, 1, 100);
            });
    }

    private void ActionEditorChanged(object sender, RoutedEventArgs e)
    {
        if (loading || SelectedAction is not { } action) return;
        if (ActionTypeBox.SelectedItem is MacroActionType type) action.Type = type;
        action.Key = string.IsNullOrWhiteSpace(ActionKey.Text) ? null : ActionKey.Text.Trim();
        if (TryDouble(ActionDelay.Text, out var delay)) action.Delay = Math.Max(0, delay);
        if (TryDouble(ActionDuration.Text, out var duration)) action.Duration = Math.Max(0, duration);
        action.X = TryDouble(ActionX.Text, out var x) ? x : null;
        action.Y = TryDouble(ActionY.Text, out var y) ? y : null;
        action.UsesWindowCoordinates = WindowCoordinates.IsChecked == true;
        if (TryDouble(ScrollX.Text, out var sx)) action.ScrollDeltaX = sx;
        if (TryDouble(ScrollY.Text, out var sy)) action.ScrollDeltaY = sy;
        ActionInspectorTitle.Text = action.ToString();
        UpdateActionFieldVisibility(action.Type);
        ActionList.Items.Refresh();
        SaveAll();
    }

    private void ActionEnabledChanged(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox { DataContext: MacroAction action, IsChecked: not null } box)
        {
            action.IsEnabled = box.IsChecked == true;
            SaveAll();
        }
    }

    private void AddAction(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is not { } macro || AddActionBox.SelectedItem is not MacroActionType type) return;
        var hasPoint = type is MacroActionType.LeftClick or MacroActionType.RightClick or MacroActionType.MiddleClick
            or MacroActionType.MouseDown or MacroActionType.MouseUp or MacroActionType.Move or MacroActionType.Scroll;
        var action = new MacroAction
        {
            Type = type,
            Duration = type is MacroActionType.Wait or MacroActionType.HoldKey ? 1 : .1,
            Key = type is MacroActionType.KeyDown or MacroActionType.KeyUp or MacroActionType.KeyPress or MacroActionType.HoldKey ? "e" : null,
            X = hasPoint ? 100 : null,
            Y = hasPoint ? 100 : null
        };
        macro.Actions.Add(action);
        RefreshActionList(action);
        SaveAll();
    }

    private void RemoveAction(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is not { } macro || SelectedAction is not { } action) return;
        macro.Actions.Remove(action);
        RefreshActionList();
        SaveAll();
    }
    private void MoveActionUp(object sender, RoutedEventArgs e) => MoveAction(-1);
    private void MoveActionDown(object sender, RoutedEventArgs e) => MoveAction(1);
    private void MoveAction(int offset)
    {
        if (SelectedMacro is not { } macro || SelectedAction is not { } action) return;
        var old = macro.Actions.IndexOf(action);
        var next = old + offset;
        if (next < 0 || next >= macro.Actions.Count) return;
        macro.Actions.RemoveAt(old);
        macro.Actions.Insert(next, action);
        RefreshActionList(action);
        SaveAll();
    }

    private void RefreshActionList(MacroAction? select = null)
    {
        ActionList.ItemsSource = null;
        ActionList.ItemsSource = SelectedMacro?.Actions;
        if (select is not null) ActionList.SelectedItem = select;
        else if (ActionList.Items.Count > 0) ActionList.SelectedIndex = Math.Min(ActionList.Items.Count - 1, Math.Max(0, ActionList.SelectedIndex));
        LoadSelectedAction();
        OverviewCount.Text = (SelectedMacro?.Actions.Count ?? 0).ToString(CultureInfo.InvariantCulture);
        InspectorActions.Text = OverviewCount.Text;
    }

    private void NewMacro(object sender, RoutedEventArgs e)
    {
        var macro = new MacroDefinition();
        macros.Add(macro);
        MacroSearch.Text = "";
        RefreshMacros(macro);
        SaveAll();
    }

    private void DuplicateMacro(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is not { } macro) return;
        var copy = macro.DeepClone();
        macros.Add(copy);
        MacroSearch.Text = "";
        RefreshMacros(copy);
        SaveAll();
    }

    private void DeleteMacro(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is not { } macro) return;
        if (MessageBox.Show(this, $"Delete “{macro.Name}”?", "Delete macro", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        macros.Remove(macro);
        RefreshMacros();
        SaveAll();
    }

    private void ImportMacro(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*" };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            MacroDefinition? one = null;
            try { one = storage.Import<MacroDefinition>(dialog.FileName); } catch { }
            if (one?.Actions is not null)
            {
                one.Id = Guid.NewGuid();
                macros.Add(one);
                RefreshMacros(one);
            }
            else
            {
                var many = storage.Import<List<MacroDefinition>>(dialog.FileName) ?? [];
                foreach (var item in many) item.Id = Guid.NewGuid();
                macros.AddRange(many);
                RefreshMacros(many.LastOrDefault());
            }
            SaveAll();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Import failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ExportMacro(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is not { } macro) return;
        var dialog = new SaveFileDialog { Filter = "JSON files (*.json)|*.json", FileName = SafeName(macro.Name) + ".json" };
        if (dialog.ShowDialog(this) == true) storage.Export(dialog.FileName, macro);
    }

    private async void RecordClicked(object sender, RoutedEventArgs e)
    {
        if (recorder.IsRecording || recordingCountdown is not null) StopRecording();
        else await StartRecording();
    }

    private async Task StartRecording()
    {
        if (recorder.IsRecording || recordingCountdown is not null || macroRunner.State != RunState.Idle || automationRunner.State != RunState.Idle) return;
        recordingCountdown = new CancellationTokenSource();
        var token = recordingCountdown.Token;
        try
        {
            NavigateTo("Recorder");
            for (var i = 3; i > 0; i--)
            {
                RecordState.Text = $"STARTING IN {i}";
                RecordTitle.Text = "Switch to your target window";
                RecordDescription.Text = "Recording will begin automatically after the countdown.";
                await Task.Delay(1000, token);
            }
            recorder.Start(selectedTarget);
            RecordState.Text = "RECORDING · 0 ACTIONS";
            RecordTitle.Text = "Capturing input";
            RecordDescription.Text = "Press F7 or Stop when you are finished.";
            RecordMainButton.Content = "■  Stop Recording";
            UpdateState();
        }
        catch (OperationCanceledException)
        {
            ResetRecorderUi("Recording cancelled");
        }
        catch (Exception ex)
        {
            ResetRecorderUi("Could not start recording");
            MessageBox.Show(this, ex.Message, "Recorder", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            recordingCountdown?.Dispose();
            recordingCountdown = null;
            UpdateState();
        }
    }

    private void StopRecording()
    {
        if (recordingCountdown is not null)
        {
            recordingCountdown.Cancel();
            return;
        }
        if (!recorder.IsRecording) return;
        var actions = recorder.Stop();
        if (actions.Count > 0)
        {
            var macro = new MacroDefinition
            {
                Name = "Recording " + DateTime.Now.ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture),
                Actions = actions,
                TargetBundleIdentifier = selectedTarget?.ProcessName,
                RecordedWindowWidth = selectedTarget?.Width,
                RecordedWindowHeight = selectedTarget?.Height
            };
            macros.Add(macro);
            MacroSearch.Text = "";
            RefreshMacros(macro);
            NavigateTo("Macros");
            SaveAll();
        }
        ResetRecorderUi(actions.Count == 0 ? "No input was captured" : $"Saved {actions.Count} actions");
        UpdateState();
    }

    private void ResetRecorderUi(string message)
    {
        RecordState.Text = message.ToUpperInvariant();
        RecordTitle.Text = "Create the next sequence";
        RecordDescription.Text = "Start here, switch to your target window, and perform the keyboard and mouse actions you want to replay.";
        RecordMainButton.Content = "●  Start Recording";
    }

    private void RefreshTargets(object? sender = null, RoutedEventArgs? e = null)
    {
        var previous = selectedTarget;
        targets = targetService.Discover().ToList();
        ApplyTargetFilter();
        if (previous is not null)
            TargetList.SelectedItem = targets.FirstOrDefault(t => t.Handle == previous.Handle);
        Log($"Found {targets.Count} visible windows");
    }

    private void TargetSearchChanged(object sender, TextChangedEventArgs e) => ApplyTargetFilter();

    private void ApplyTargetFilter()
    {
        var query = TargetSearch.Text.Trim();
        var filtered = string.IsNullOrWhiteSpace(query)
            ? targets
            : targets.Where(target => target.ApplicationName.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || target.WindowTitle.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || (target.ProcessName?.Contains(query, StringComparison.CurrentCultureIgnoreCase) ?? false)
                || target.ProcessId.ToString(CultureInfo.InvariantCulture).Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
        TargetList.ItemsSource = filtered;
        TargetEmptyState.Visibility = filtered.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void TargetSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TargetList.SelectedItem is not TargetWindow target) return;
        TargetTitle.Text = target.ApplicationName;
        TargetSubtitle.Text = target.WindowTitle;
        DiagnosticText.Text = $"PID {target.ProcessId}  ·  {target.Width} × {target.Height}  ·  {target.ProcessName}";
    }

    private void SelectTarget(object sender, RoutedEventArgs e)
    {
        if (TargetList.SelectedItem is not TargetWindow target) return;
        selectedTarget = target;
        if (SelectedMacro is { } macro) macro.TargetBundleIdentifier = target.ProcessName;
        OverviewTarget.Text = target.ApplicationName;
        InspectorTarget.Text = target.ApplicationName;
        SidebarTarget.Text = target.ApplicationName;
        SidebarTargetSub.Text = target.WindowTitle;
        RecorderTarget.Text = "◎  " + target.ApplicationName;
        RecorderModeText.Text = target.ApplicationName;
        TargetTitle.Text = target.ApplicationName;
        TargetSubtitle.Text = target.WindowTitle;
        DiagnosticText.Text = $"Selected · PID {target.ProcessId} · {target.Width} × {target.Height}";
        Log("Target selected: " + target);
        SaveAll();
    }

    private void ClearTarget(object sender, RoutedEventArgs e)
    {
        selectedTarget = null;
        TargetList.SelectedItem = null;
        TargetTitle.Text = "No target selected";
        TargetSubtitle.Text = "Choose a visible application window to receive the macro.";
        DiagnosticText.Text = "";
        SidebarTarget.Text = "No target";
        SidebarTargetSub.Text = "Choose a window";
        RecorderTarget.Text = "◎  No target selected";
        RecorderModeText.Text = "No target";
        OverviewTarget.Text = "No target selected";
        InspectorTarget.Text = "No target selected";
        Log("Target cleared");
    }

    private void TestKey(object sender, RoutedEventArgs e)
    {
        if (!RequireTarget() || selectedTarget is not { } target) return;
        var backend = new WindowsInputBackend(SelectedMacro?.MousePlaybackMode ?? MousePlaybackMode.Background);
        backend.KeyDown("e", target);
        backend.KeyUp("e", target);
        DiagnosticText.Text = "Test E was posted. The target application decides whether to accept background input.";
        Log("Test E key posted to the selected target.");
    }

    private void TestClick(object sender, RoutedEventArgs e)
    {
        if (!RequireTarget()) return;
        var backend = new WindowsInputBackend(SelectedMacro?.MousePlaybackMode ?? MousePlaybackMode.Background);
        var x = selectedTarget!.X + selectedTarget.Width / 2;
        var y = selectedTarget.Y + selectedTarget.Height / 2;
        backend.MouseDown(MacroMouseButton.Left, x, y, 1, selectedTarget);
        backend.MouseUp(MacroMouseButton.Left, x, y, 1, selectedTarget);
        DiagnosticText.Text = "A center click was posted. The target application decides whether to accept background input.";
        Log("Test center click posted to the selected target.");
    }

    private bool RequireTarget()
    {
        if (selectedTarget is not null) return true;
        MessageBox.Show(this, "Select a target window first.", "Target required", MessageBoxButton.OK, MessageBoxImage.Information);
        return false;
    }

    private void BuildNodeLibrary()
    {
        NodeLibrary.Children.Clear();
        var query = AutomationSearch?.Text?.Trim() ?? "";
        foreach (var kind in Enum.GetValues<AutomationNodeKind>().Where(kind => kind != AutomationNodeKind.Start)
            .Where(kind => string.IsNullOrWhiteSpace(query) || NodeTitle(kind).Contains(query, StringComparison.CurrentCultureIgnoreCase)))
        {
            var button = new Button
            {
                Content = NodeTitle(kind), Tag = kind, Margin = new Thickness(0, 0, 0, 7), Padding = new Thickness(10, 7, 10, 7),
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left
            };
            button.Click += AddNode;
            NodeLibrary.Children.Add(button);
        }
    }

    private void AutomationSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!loading)
        {
            LoadSelectedAutomation();
            if (AutomationPage.Visibility == Visibility.Visible) HeaderTitle.Text = SelectedAutomation?.Name ?? "Automation";
        }
    }

    private void AutomationSearchChanged(object sender, TextChangedEventArgs e)
    {
        RefreshAutomationList(SelectedAutomation);
        BuildNodeLibrary();
    }

    private void RefreshAutomations(AutomationDefinition? select = null)
    {
        loading = true;
        RefreshAutomationList(select);
        if (select is null && AutomationList.Items.Count > 0) AutomationList.SelectedIndex = 0;
        loading = false;
        LoadSelectedAutomation();
    }

    private void RefreshAutomationList(AutomationDefinition? select)
    {
        var query = AutomationSearch?.Text?.Trim() ?? "";
        var visible = string.IsNullOrWhiteSpace(query)
            ? automations
            : automations.Where(automation => automation.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || automation.AutomationDescription.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        AutomationList.ItemsSource = null;
        AutomationList.ItemsSource = visible;
        if (select is not null && visible.Contains(select)) AutomationList.SelectedItem = select;
    }

    private void LoadSelectedAutomation()
    {
        loading = true;
        AutomationName.Text = SelectedAutomation?.Name ?? "";
        AutomationDescription.Text = SelectedAutomation?.AutomationDescription ?? "";
        StartModeBox.SelectedItem = SelectedAutomation?.StartMode ?? Macro.Core.AutomationStartMode.Immediately;
        FlowCanvas.Workflow = SelectedAutomation;
        selectedNode = null;
        loading = false;
        RefreshAutomationDetail();
        SelectNode(SelectedAutomation?.Nodes.FirstOrDefault(n => n.Kind == AutomationNodeKind.Start));
    }

    private void RefreshAutomationDetail()
    {
        var automation = SelectedAutomation;
        AutomationSummary.Text = automation is null ? "0 nodes · 0 connections" : $"{automation.Nodes.Count} nodes · {automation.Connections.Count} connections";
        NodeConnectTarget.ItemsSource = automation?.Nodes.Where(node => node.Id != selectedNode?.Id).ToList();
        NodeConnectTarget.DisplayMemberPath = nameof(AutomationNode.Title);
        var errors = automation?.Validate(macros.Select(m => m.Id).ToHashSet()) ?? [];
        ValidationText.Text = automation is null ? "Select a workflow" : errors.Count == 0 ? "✓ Workflow is valid and ready to run." : string.Join(Environment.NewLine, errors.Take(6));
        ValidationText.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString(errors.Count == 0 ? "#38C98A" : "#F06A79"));
        FlowCanvas.InvalidateVisual();
    }

    private void NewAutomation(object sender, RoutedEventArgs e)
    {
        var automation = AutomationDefinition.Blank();
        automations.Add(automation);
        RefreshAutomations(automation);
        SaveAll();
    }

    private void DeleteAutomation(object sender, RoutedEventArgs e)
    {
        if (SelectedAutomation is not { } automation) return;
        if (MessageBox.Show(this, $"Delete “{automation.Name}”?", "Delete workflow", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        automations.Remove(automation);
        RefreshAutomations();
        SaveAll();
    }

    private void AddNode(object sender, RoutedEventArgs e)
    {
        if (SelectedAutomation is not { } automation || sender is not FrameworkElement { Tag: AutomationNodeKind kind }) return;
        var node = new AutomationNode
        {
            Kind = kind,
            Position = new WorkflowPoint { X = 280 + (automation.Nodes.Count % 4) * 205, Y = 110 + (automation.Nodes.Count / 4) * 120 }
        };
        if (kind == AutomationNodeKind.Macro) node.MacroID = SelectedMacro?.Id ?? macros.FirstOrDefault()?.Id;
        automation.Nodes.Add(node);
        SelectNode(node);
        RefreshAutomationDetail();
        SaveAll();
    }

    private void SelectNode(AutomationNode? node)
    {
        selectedNode = node;
        FlowCanvas.SelectedNodeId = node?.Id;
        loading = true;
        NodeInspectorTitle.Text = node?.Title ?? "Select a node";
        NodeKindText.Text = node is null ? "" : NodeTitle(node.Kind);
        NodeMacroBox.ItemsSource = macros;
        NodeMacroBox.DisplayMemberPath = nameof(MacroDefinition.Name);
        NodeMacroBox.SelectedItem = node is null ? null : macros.FirstOrDefault(m => m.Id == node.MacroID);
        NodeWait.Text = (node?.WaitDuration ?? 0).ToString("0.###", CultureInfo.InvariantCulture);
        NodeRepeat.Text = (node?.RepeatCount ?? 0).ToString(CultureInfo.InvariantCulture);
        MacroNodeFields.Visibility = node?.Kind == AutomationNodeKind.Macro ? Visibility.Visible : Visibility.Collapsed;
        WaitNodeFields.Visibility = node?.Kind == AutomationNodeKind.Wait ? Visibility.Visible : Visibility.Collapsed;
        RepeatNodeFields.Visibility = node?.Kind == AutomationNodeKind.RepeatFlow ? Visibility.Visible : Visibility.Collapsed;
        var hasNode = node is not null;
        NodeConnectTarget.IsEnabled = hasNode;
        NodeBranch.IsEnabled = node?.Kind == AutomationNodeKind.IfElse;
        NodeBranch.Visibility = node?.Kind == AutomationNodeKind.IfElse ? Visibility.Visible : Visibility.Collapsed;
        ConnectButton.IsEnabled = hasNode;
        DisconnectButton.IsEnabled = hasNode;
        DeleteNodeButton.IsEnabled = node is not null && node.Kind != AutomationNodeKind.Start;
        BuildDynamicNodeFields(node);
        loading = false;
        RefreshAutomationDetail();
    }

    private void BuildDynamicNodeFields(AutomationNode? node)
    {
        DynamicNodeFields.Children.Clear();
        if (node is null) return;
        AddText(DynamicNodeFields, "CUSTOM TITLE", node.CustomTitle ?? "", value => node.CustomTitle = string.IsNullOrWhiteSpace(value) ? null : value);
        AddCheck(DynamicNodeFields, "Node enabled", node.IsEnabled, value => node.IsEnabled = value);
        switch (node.Kind)
        {
            case AutomationNodeKind.Macro:
                AddText(DynamicNodeFields, "MACRO LOOPS", node.MacroLoops.ToString(CultureInfo.InvariantCulture), value =>
                {
                    if (int.TryParse(value, out var count)) node.MacroLoops = Math.Clamp(count, 1, 1_000_000);
                });
                AddCombo(DynamicNodeFields, "PLAYBACK OVERRIDE", Enum.GetValues<MacroPlaybackOverride>(), node.PlaybackOverride, value => node.PlaybackOverride = value);
                break;
            case AutomationNodeKind.WaitForWindow:
                AddText(DynamicNodeFields, "PROCESS NAME", node.WaitForBundleIdentifier ?? "", value => node.WaitForBundleIdentifier = EmptyToNull(value));
                AddText(DynamicNodeFields, "WINDOW TITLE CONTAINS", node.WaitForWindowTitle, value => node.WaitForWindowTitle = value);
                AddText(DynamicNodeFields, "TIMEOUT (SECONDS)", node.WaitForWindowTimeout.ToString("0.###", CultureInfo.InvariantCulture), value =>
                {
                    if (TryDouble(value, out var seconds)) node.WaitForWindowTimeout = Math.Max(0, seconds);
                });
                break;
            case AutomationNodeKind.IfElse:
                AddCombo(DynamicNodeFields, "CONDITION", Enum.GetValues<AutomationConditionKind>(), node.ConditionKind, value => node.ConditionKind = value);
                AddText(DynamicNodeFields, "PROCESS NAME", node.ConditionBundleIdentifier ?? "", value => node.ConditionBundleIdentifier = EmptyToNull(value));
                AddText(DynamicNodeFields, "WINDOW TITLE CONTAINS", node.ConditionWindowTitle, value => node.ConditionWindowTitle = value);
                AddText(DynamicNodeFields, "ELAPSED DURATION", node.ConditionDuration.ToString("0.###", CultureInfo.InvariantCulture), value =>
                {
                    if (TryDouble(value, out var duration)) node.ConditionDuration = Math.Max(0, duration);
                });
                AddCombo(DynamicNodeFields, "DURATION UNIT", Enum.GetValues<AutomationScheduleUnit>(), node.ConditionDurationUnit, value => node.ConditionDurationUnit = value);
                AddMacroChoice(DynamicNodeFields, "COUNT MACRO RUNS", node.ConditionMacroID, value => node.ConditionMacroID = value);
                AddText(DynamicNodeFields, "RUN COUNT", node.ConditionMacroRunCount.ToString(CultureInfo.InvariantCulture), value =>
                {
                    if (int.TryParse(value, out var count)) node.ConditionMacroRunCount = Math.Max(1, count);
                });
                break;
            case AutomationNodeKind.Schedule:
                AddCombo(DynamicNodeFields, "SCHEDULE MODE", Enum.GetValues<AutomationScheduleMode>(), node.ScheduleMode, value => node.ScheduleMode = value);
                AddText(DynamicNodeFields, "MINUTE OF DAY (0–1439)", node.ScheduleMinuteOfDay.ToString(CultureInfo.InvariantCulture), value =>
                {
                    if (int.TryParse(value, out var minute)) node.ScheduleMinuteOfDay = Math.Clamp(minute, 0, 1439);
                });
                AddCombo(DynamicNodeFields, "REPEAT", Enum.GetValues<AutomationScheduleRepeat>(), node.ScheduleRepeat, value => node.ScheduleRepeat = value);
                AddText(DynamicNodeFields, "INTERVAL", node.ScheduleInterval.ToString("0.###", CultureInfo.InvariantCulture), value =>
                {
                    if (TryDouble(value, out var interval)) node.ScheduleInterval = Math.Max(0, interval);
                });
                AddCombo(DynamicNodeFields, "INTERVAL UNIT", Enum.GetValues<AutomationScheduleUnit>(), node.ScheduleIntervalUnit, value => node.ScheduleIntervalUnit = value);
                break;
            case AutomationNodeKind.RepeatFlow:
                AddCheck(DynamicNodeFields, "Repeat until stopped", node.RepeatInfinitely, value => node.RepeatInfinitely = value);
                AddCheck(DynamicNodeFields, "Limit by duration", node.RepeatForDuration, value => node.RepeatForDuration = value);
                AddText(DynamicNodeFields, "REPEAT DURATION", node.RepeatDuration.ToString("0.###", CultureInfo.InvariantCulture), value =>
                {
                    if (TryDouble(value, out var duration)) node.RepeatDuration = Math.Max(0, duration);
                });
                AddCombo(DynamicNodeFields, "DURATION UNIT", Enum.GetValues<AutomationScheduleUnit>(), node.RepeatDurationUnit, value => node.RepeatDurationUnit = value);
                AddNodeChoice(DynamicNodeFields, "REPEAT FROM NODE", node.RepeatTargetNodeID, value => node.RepeatTargetNodeID = value);
                break;
            case AutomationNodeKind.LoopBack:
                AddNodeChoice(DynamicNodeFields, "JUMP TO NODE", node.JumpTargetNodeID, value => node.JumpTargetNodeID = value);
                break;
            case AutomationNodeKind.Note:
                AddText(DynamicNodeFields, "NOTE", node.NoteText, value => node.NoteText = value, true);
                break;
        }
    }

    private void AutomationNameChanged(object sender, TextChangedEventArgs e)
    {
        if (loading || SelectedAutomation is not { } automation) return;
        automation.Name = string.IsNullOrWhiteSpace(AutomationName.Text) ? "Untitled Automation" : AutomationName.Text;
        automation.LastEdited = CocoaNow();
        AutomationList.Items.Refresh();
        SaveAll();
    }

    private void AutomationDescriptionChanged(object sender, TextChangedEventArgs e)
    {
        if (loading || SelectedAutomation is not { } automation) return;
        automation.AutomationDescription = AutomationDescription.Text;
        automation.LastEdited = CocoaNow();
        SaveAll();
    }

    private void AutomationStartModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || SelectedAutomation is not { } automation || StartModeBox.SelectedItem is not Macro.Core.AutomationStartMode mode) return;
        automation.StartMode = mode;
        automation.LastEdited = CocoaNow();
        SaveAll();
    }

    private void NodeEditorChanged(object sender, RoutedEventArgs e)
    {
        if (loading || selectedNode is null) return;
        if (NodeMacroBox.SelectedItem is MacroDefinition macro) selectedNode.MacroID = macro.Id;
        if (TryDouble(NodeWait.Text, out var wait)) selectedNode.WaitDuration = Math.Max(0, wait);
        if (int.TryParse(NodeRepeat.Text, out var repeat)) selectedNode.RepeatCount = Math.Max(0, repeat);
        NodeInspectorTitle.Text = selectedNode.Title;
        RefreshAutomationDetail();
        SaveAll();
    }

    private void ConnectNode(object sender, RoutedEventArgs e)
    {
        if (SelectedAutomation is not { } automation || selectedNode is null || NodeConnectTarget.SelectedItem is not AutomationNode target) return;
        var branch = NodeBranch.SelectedItem?.ToString() switch
        {
            "Yes" => AutomationBranch.Yes,
            "No" => AutomationBranch.No,
            _ => (AutomationBranch?)null
        };
        if (selectedNode.Kind == AutomationNodeKind.IfElse && branch is null)
        {
            MessageBox.Show(this, "Choose Yes or No for an If / Else connection.", "Branch required", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (selectedNode.Kind != AutomationNodeKind.IfElse) branch = null;
        CreateConnection(selectedNode, target, branch);
    }

    private void CreateConnection(AutomationNode source, AutomationNode target, AutomationBranch? branch)
    {
        if (SelectedAutomation is not { } automation || source.Id == target.Id) return;
        if (source.Kind == AutomationNodeKind.IfElse && branch is null) return;
        if (source.Kind != AutomationNodeKind.IfElse) branch = null;
        automation.Connections.RemoveAll(link => link.SourceNodeID == source.Id && link.Branch == branch);
        automation.Connections.Add(new AutomationConnection { SourceNodeID = source.Id, TargetNodeID = target.Id, Branch = branch });
        automation.LastEdited = CocoaNow();
        RefreshAutomationDetail();
        SaveAll();
    }

    private void DisconnectNode(object sender, RoutedEventArgs e)
    {
        if (SelectedAutomation is not { } automation || selectedNode is null) return;
        AutomationBranch? branch = selectedNode.Kind == AutomationNodeKind.IfElse
            ? NodeBranch.SelectedItem?.ToString() switch
            {
                "Yes" => AutomationBranch.Yes,
                "No" => AutomationBranch.No,
                _ => null
            }
            : null;
        automation.Connections.RemoveAll(link => link.SourceNodeID == selectedNode.Id && link.Branch == branch);
        automation.LastEdited = CocoaNow();
        RefreshAutomationDetail();
        SaveAll();
    }

    private void DeleteNode(object sender, RoutedEventArgs e)
    {
        if (SelectedAutomation is not { } automation || selectedNode is null || selectedNode.Kind == AutomationNodeKind.Start) return;
        automation.Nodes.Remove(selectedNode);
        automation.Connections.RemoveAll(link => link.SourceNodeID == selectedNode.Id || link.TargetNodeID == selectedNode.Id);
        SelectNode(null);
        RefreshAutomationDetail();
        SaveAll();
    }

    private void FitWorkflow(object sender, RoutedEventArgs e) => FlowCanvas.Fit();
    private async void RunAutomation(object sender, RoutedEventArgs e)
    {
        if (SelectedAutomation is not { } automation) return;
        var errors = automation.Validate(macros.Select(m => m.Id).ToHashSet());
        if (errors.Count > 0)
        {
            MessageBox.Show(this, string.Join(Environment.NewLine, errors), "Workflow needs attention", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        var result = await automationRunner.RunAsync(automation, id => macros.FirstOrDefault(m => m.Id == id), ResolveTarget,
            mode => new WindowsInputBackend(mode), () => targetService.Discover(), macroRunner);
        if (result.Outcome == RunOutcome.Failed)
            MessageBox.Show(this, result.Error ?? "The workflow failed.", "Workflow failed", MessageBoxButton.OK, MessageBoxImage.Error);
        UpdateState();
    }

    private TargetWindow? ResolveTarget(AutomationNode node, MacroDefinition macro)
    {
        if (selectedTarget is not null) return selectedTarget;
        var identity = node.TargetBundleIdentifier ?? macro.TargetBundleIdentifier;
        return targetService.Discover().FirstOrDefault(window => string.IsNullOrWhiteSpace(identity)
            || string.Equals(window.ProcessName, identity, StringComparison.OrdinalIgnoreCase));
    }

    private void AddText(Panel panel, string label, string value, Action<string> changed, bool multiline = false)
    {
        panel.Children.Add(FieldLabel(label));
        var box = new TextBox
        {
            Text = value,
            Margin = new Thickness(0, 0, 0, 14),
            AcceptsReturn = multiline,
            MinHeight = multiline ? 74 : 0,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap
        };
        box.TextChanged += (_, _) => { if (!loading) { changed(box.Text); DynamicNodeChanged(); } };
        panel.Children.Add(box);
    }

    private void AddCombo<T>(Panel panel, string label, IEnumerable<T> values, T selected, Action<T> changed)
    {
        panel.Children.Add(FieldLabel(label));
        var box = new ComboBox { ItemsSource = values, SelectedItem = selected, Margin = new Thickness(0, 0, 0, 14) };
        box.SelectionChanged += (_, _) => { if (!loading && box.SelectedItem is T value) { changed(value); DynamicNodeChanged(); } };
        panel.Children.Add(box);
    }

    private void AddCheck(Panel panel, string label, bool selected, Action<bool> changed)
    {
        var box = new CheckBox { Content = label, IsChecked = selected, Margin = new Thickness(0, 0, 0, 12) };
        box.Click += (_, _) => { if (!loading) { changed(box.IsChecked == true); DynamicNodeChanged(); } };
        panel.Children.Add(box);
    }

    private void AddMacroChoice(Panel panel, string label, Guid? selected, Action<Guid?> changed)
    {
        panel.Children.Add(FieldLabel(label));
        var box = new ComboBox { ItemsSource = macros, DisplayMemberPath = nameof(MacroDefinition.Name), SelectedItem = macros.FirstOrDefault(m => m.Id == selected), Margin = new Thickness(0, 0, 0, 14) };
        box.SelectionChanged += (_, _) => { if (!loading) { changed((box.SelectedItem as MacroDefinition)?.Id); DynamicNodeChanged(); } };
        panel.Children.Add(box);
    }

    private void AddNodeChoice(Panel panel, string label, Guid? selected, Action<Guid?> changed)
    {
        var nodes = SelectedAutomation?.Nodes.Where(node => node.Id != selectedNode?.Id).ToList() ?? [];
        panel.Children.Add(FieldLabel(label));
        var box = new ComboBox { ItemsSource = nodes, DisplayMemberPath = nameof(AutomationNode.Title), SelectedItem = nodes.FirstOrDefault(n => n.Id == selected), Margin = new Thickness(0, 0, 0, 14) };
        box.SelectionChanged += (_, _) => { if (!loading) { changed((box.SelectedItem as AutomationNode)?.Id); DynamicNodeChanged(); } };
        panel.Children.Add(box);
    }

    private static TextBlock FieldLabel(string text) => new()
    {
        Text = text,
        Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#708AA1")),
        FontSize = 11,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, 0, 0, 8)
    };

    private void DynamicNodeChanged()
    {
        if (selectedNode is not null) NodeInspectorTitle.Text = selectedNode.Title;
        if (SelectedAutomation is { } automation) automation.LastEdited = CocoaNow();
        RefreshAutomationDetail();
        SaveAll();
    }

    private void LogSearchChanged(object sender, TextChangedEventArgs e)
    {
        var query = LogSearch.Text.Trim();
        LogList.ItemsSource = string.IsNullOrWhiteSpace(query)
            ? logEntries
            : logEntries.Where(entry => entry.Message.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || entry.Detail.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || entry.Level.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        UpdateLogEmptyState();
    }

    private void ClearLogs(object sender, RoutedEventArgs e)
    {
        logEntries.Clear();
        LogList.ItemsSource = logEntries;
        UpdateLogEmptyState();
    }
    private void OpenDataFolder(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(storage.DirectoryPath);
        Process.Start(new ProcessStartInfo("explorer.exe", storage.DirectoryPath) { UseShellExecute = true });
    }

    private void SaveAll()
    {
        if (loading) return;
        try
        {
            storage.SaveMacros(macros);
            storage.SaveAutomations(automations);
        }
        catch (Exception ex)
        {
            Log("Save failed: " + ex.Message, "error");
        }
    }

    private void Log(string message, string level = "info")
    {
        var normalized = level.ToLowerInvariant();
        var (label, accent) = normalized switch
        {
            "error" => ("Error", "#F06A79"),
            "warning" => ("Warning", "#F4A340"),
            _ => ("System", "#4C9CFF")
        };
        logEntries.Add(new UiLogEntry
        {
            Time = DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture),
            Level = label,
            Message = message,
            Detail = normalized == "error" ? "Action required" : "Macro activity",
            Accent = accent
        });
        if (string.IsNullOrWhiteSpace(LogSearch.Text)) LogList.ScrollIntoView(logEntries.Last());
        UpdateLogEmptyState();
    }

    private void UpdateLogEmptyState() => LogEmptyState.Visibility = LogList.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void Ui(Action action)
    {
        if (Dispatcher.HasShutdownStarted) return;
        if (!Dispatcher.CheckAccess()) Dispatcher.BeginInvoke(action);
        else action();
    }

    private void RegisterHotkeys()
    {
        var handle = new WindowInteropHelper(this).Handle;
        windowSource = HwndSource.FromHwnd(handle);
        windowSource?.AddHook(WindowProc);
        var okay = NativeMethods.RegisterHotKey(handle, HotkeyRecord, 0, 0x75)
            & NativeMethods.RegisterHotKey(handle, HotkeyStop, 0, 0x76)
            & NativeMethods.RegisterHotKey(handle, HotkeyPlay, 0, 0x77);
        if (!okay) Log("One or more global hotkeys are already used by another application.", "warning");
    }

    private void UnregisterHotkeys()
    {
        var handle = new WindowInteropHelper(this).Handle;
        for (var id = HotkeyRecord; id <= HotkeyPlay; id++) NativeMethods.UnregisterHotKey(handle, id);
        windowSource?.RemoveHook(WindowProc);
        windowSource = null;
    }

    private nint WindowProc(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message != 0x0312) return 0;
        handled = true;
        switch ((int)wParam)
        {
            case HotkeyRecord:
                if (recorder.IsRecording || recordingCountdown is not null) StopRecording();
                else _ = StartRecording();
                break;
            case HotkeyStop: StopAll(); break;
            case HotkeyPlay: _ = PlaySelected(); break;
        }
        return 0;
    }

    private static string NodeTitle(AutomationNodeKind kind) => kind switch
    {
        AutomationNodeKind.IfElse => "If / Else",
        AutomationNodeKind.WaitForWindow => "Wait for Window",
        AutomationNodeKind.RepeatFlow => "Repeat",
        AutomationNodeKind.LoopBack => "Loop Back",
        AutomationNodeKind.ResetTimer => "Reset Timer",
        _ => kind.ToString()
    };
    private static string? EmptyToNull(string value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    private static bool TryDouble(string value, out double result) => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out result) && double.IsFinite(result);
    private static double CocoaNow() => (DateTime.UtcNow - new DateTime(2001, 1, 1)).TotalSeconds;
    private static string SafeName(string value) => string.Concat(value.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '_' : character));
    private static List<T> SafeLoad<T>(Func<List<T>> loader, List<T> fallback)
    {
        try
        {
            var loaded = loader();
            return loaded.Count == 0 ? fallback : loaded;
        }
        catch
        {
            return fallback;
        }
    }
}

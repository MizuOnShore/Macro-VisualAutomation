using System.Text.Json.Serialization;

namespace Macro.Core;

public enum AutomationNodeKind
{ Start, Macro, Wait, WaitForWindow, IfElse, Schedule, RepeatFlow, LoopBack, Merge, Stop, ResetTimer, Note }
public enum AutomationBranch { Yes, No }
public enum AutomationConditionKind { WindowOpen, ElapsedTime, MacroRunCount }
public enum MacroPlaybackOverride { UseMacroSetting, Background, Compatibility }
public enum AutomationScheduleRepeat { Once, EveryMinute, EveryHour, EveryDay }
public enum AutomationScheduleMode { AtTime, Interval }
public enum AutomationScheduleUnit { Seconds, Minutes, Hours }
public enum AutomationStartMode { Immediately, Scheduled }

public sealed class WorkflowPoint { public double X { get; set; } public double Y { get; set; } }
public sealed class WorkflowFrame
{
    public double X { get; set; } public double Y { get; set; }
    public double Width { get; set; } public double Height { get; set; }
}
public sealed class AutomationSection
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "Section";
    public WorkflowFrame Frame { get; set; } = new();
}

public sealed class AutomationNode
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public AutomationNodeKind Kind { get; set; }
    public WorkflowPoint Position { get; set; } = new();
    public Guid? MacroID { get; set; }
    public MacroPlaybackOverride PlaybackOverride { get; set; }
    public string? TargetBundleIdentifier { get; set; }
    public int MacroLoops { get; set; } = 1;
    public double WaitDuration { get; set; } = 30;
    public string? WaitForBundleIdentifier { get; set; }
    public string WaitForWindowTitle { get; set; } = "";
    public double WaitForWindowTimeout { get; set; } = 60;
    public string? ConditionBundleIdentifier { get; set; }
    public string ConditionWindowTitle { get; set; } = "";
    public AutomationConditionKind ConditionKind { get; set; }
    public double ConditionDuration { get; set; } = 9;
    public AutomationScheduleUnit ConditionDurationUnit { get; set; } = AutomationScheduleUnit.Minutes;
    public int? ConditionElapsedMilliseconds { get; set; }
    public Guid? ConditionMacroID { get; set; }
    public int ConditionMacroRunCount { get; set; } = 1;
    public int ScheduleMinuteOfDay { get; set; } = 1320;
    public AutomationScheduleRepeat ScheduleRepeat { get; set; }
    public AutomationScheduleMode ScheduleMode { get; set; }
    public double ScheduleInterval { get; set; } = 5;
    public AutomationScheduleUnit ScheduleIntervalUnit { get; set; } = AutomationScheduleUnit.Minutes;
    public int RepeatCount { get; set; } = 5;
    public bool RepeatInfinitely { get; set; }
    public bool RepeatForDuration { get; set; }
    public double RepeatDuration { get; set; } = 9;
    public AutomationScheduleUnit RepeatDurationUnit { get; set; } = AutomationScheduleUnit.Minutes;
    public Guid? RepeatTargetNodeID { get; set; }
    public Guid? JumpTargetNodeID { get; set; }
    public string? CustomTitle { get; set; }
    public string NoteText { get; set; } = "";
    public bool IsEnabled { get; set; } = true;

    [JsonIgnore] public string Title => string.IsNullOrWhiteSpace(CustomTitle) ? Kind switch
    {
        AutomationNodeKind.IfElse => "If / Else", AutomationNodeKind.WaitForWindow => "Wait for Window",
        AutomationNodeKind.RepeatFlow => "Repeat", AutomationNodeKind.LoopBack => "Loop Back",
        AutomationNodeKind.ResetTimer => "Reset Timer", _ => Kind.ToString()
    } : CustomTitle;
    [JsonIgnore] public double UnitSeconds => ConditionDurationUnit switch
    { AutomationScheduleUnit.Seconds => 1, AutomationScheduleUnit.Minutes => 60, _ => 3600 };
    public override string ToString() => Title;
}

public sealed class AutomationConnection
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid SourceNodeID { get; set; }
    public Guid TargetNodeID { get; set; }
    public AutomationBranch? Branch { get; set; }
    public string? Style { get; set; }
    public WorkflowPoint? BendPoint { get; set; }
}

public sealed class AutomationDefinition
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "Untitled Automation";
    public string AutomationDescription { get; set; } = "";
    public AutomationStartMode StartMode { get; set; }
    public List<AutomationNode> Nodes { get; set; } = [];
    public List<AutomationConnection> Connections { get; set; } = [];
    public List<AutomationSection> Sections { get; set; } = [];
    // Swift's default JSON date representation is a number; retaining it as a
    // number keeps existing files readable on both platforms.
    public double LastEdited { get; set; } = (DateTime.UtcNow - new DateTime(2001, 1, 1)).TotalSeconds;
    public override string ToString() => Name;

    public static AutomationDefinition Blank()
    {
        var start = new AutomationNode { Kind = AutomationNodeKind.Start, Position = new() { X = 420, Y = 150 } };
        var stop = new AutomationNode { Kind = AutomationNodeKind.Stop, Position = new() { X = 420, Y = 390 } };
        return new() { Nodes = [start, stop] };
    }

    public IReadOnlyList<string> Validate(ISet<Guid> macroIds)
    {
        var errors = new List<string>();
        var starts = Nodes.Count(n => n.Kind == AutomationNodeKind.Start);
        if (starts != 1) errors.Add(starts == 0 ? "Add one Start node." : "Only one Start node is allowed.");
        var ids = Nodes.Select(n => n.Id).ToHashSet();
        foreach (var c in Connections)
        {
            if (!ids.Contains(c.SourceNodeID) || !ids.Contains(c.TargetNodeID)) errors.Add("A connection references a missing node.");
            if (c.SourceNodeID == c.TargetNodeID) errors.Add("A node cannot connect to itself.");
        }
        foreach (var n in Nodes.Where(n => n.Kind == AutomationNodeKind.Macro))
            if (n.MacroID is null || !macroIds.Contains(n.MacroID.Value)) errors.Add($"{n.Title} does not reference an available macro.");
        foreach (var n in Nodes.Where(n => n.Kind is not AutomationNodeKind.Stop and not AutomationNodeKind.Note))
        {
            var outgoing = Connections.Where(c => c.SourceNodeID == n.Id).ToList();
            if (n.Kind == AutomationNodeKind.IfElse)
            {
                if (!outgoing.Any(c => c.Branch == AutomationBranch.Yes) || !outgoing.Any(c => c.Branch == AutomationBranch.No))
                    errors.Add("Every If / Else node needs Yes and No paths.");
            }
            else if (outgoing.Count != 1) errors.Add($"{n.Title} needs exactly one outgoing connection.");
        }
        return errors.Distinct().ToList();
    }
}

public sealed class AutomationRunner
{
    public RunState State { get; private set; }
    public Guid? ActiveNodeId { get; private set; }
    public event Action<string, string>? Logged;
    public event Action<Guid?>? ActiveNodeChanged;
    private CancellationTokenSource? cancellation;
    private bool paused;

    public async Task<MacroRunResult> RunAsync(
        AutomationDefinition automation,
        Func<Guid, MacroDefinition?> macroResolver,
        Func<AutomationNode, MacroDefinition, TargetWindow?> targetResolver,
        Func<MousePlaybackMode, IInputBackend> backendResolver,
        Func<IReadOnlyList<TargetWindow>> windowResolver,
        MacroRunner macroRunner)
    {
        if (State != RunState.Idle) throw new InvalidOperationException("An automation is already running.");
        cancellation = new(); State = RunState.Running; paused = false;
        var token = cancellation.Token;
        var started = DateTime.UtcNow; var timerOrigin = started;
        var runCounts = new Dictionary<Guid, int>();
        var repeatCounts = new Dictionary<Guid, int>();
        try
        {
            var current = automation.Nodes.Single(n => n.Kind == AutomationNodeKind.Start);
            var safety = 0;
            while (true)
            {
                token.ThrowIfCancellationRequested();
                while (paused) await Task.Delay(20, token);
                if (++safety > 1_000_000) throw new InvalidOperationException("Workflow exceeded the safety step limit.");
                ActiveNodeId = current.Id; ActiveNodeChanged?.Invoke(current.Id);
                Log("Running " + current.Title);
                if (!current.IsEnabled) { current = Next(automation, current, null); continue; }
                switch (current.Kind)
                {
                    case AutomationNodeKind.Stop:
                        Log("Automation completed"); return new(RunOutcome.Completed);
                    case AutomationNodeKind.Note:
                        return new(RunOutcome.Completed);
                    case AutomationNodeKind.Macro:
                        var macro = current.MacroID.HasValue ? macroResolver(current.MacroID.Value) : null;
                        if (macro is null) throw new InvalidOperationException("A workflow macro is missing.");
                        var target = targetResolver(current, macro) ?? throw new InvalidOperationException("No matching target window was found.");
                        var mode = current.PlaybackOverride switch
                        { MacroPlaybackOverride.Background => MousePlaybackMode.Background,
                          MacroPlaybackOverride.Compatibility => MousePlaybackMode.Compatibility, _ => macro.MousePlaybackMode };
                        for (var i = 0; i < Math.Max(1, current.MacroLoops); i++)
                        {
                            var oneRun = CloneOnce(macro);
                            var result = await macroRunner.RunAsync(oneRun, target, backendResolver(mode), token);
                            if (result.Outcome != RunOutcome.Completed) return result;
                        }
                        runCounts[macro.Id] = runCounts.GetValueOrDefault(macro.Id) + 1; break;
                    case AutomationNodeKind.Wait:
                        await Delay(current.WaitDuration, token); break;
                    case AutomationNodeKind.WaitForWindow:
                        var limit = DateTime.UtcNow.AddSeconds(Math.Max(0, current.WaitForWindowTimeout));
                        while (!MatchesAny(windowResolver(), current.WaitForBundleIdentifier, current.WaitForWindowTitle))
                        {
                            if (DateTime.UtcNow >= limit) throw new TimeoutException("Timed out waiting for a window.");
                            await Delay(.2, token);
                        }
                        break;
                    case AutomationNodeKind.Schedule:
                        await WaitForSchedule(current, token); break;
                    case AutomationNodeKind.ResetTimer:
                        timerOrigin = DateTime.UtcNow; break;
                    case AutomationNodeKind.IfElse:
                        var answer = current.ConditionKind switch
                        {
                            AutomationConditionKind.WindowOpen => MatchesAny(windowResolver(), current.ConditionBundleIdentifier, current.ConditionWindowTitle),
                            AutomationConditionKind.ElapsedTime => (DateTime.UtcNow - timerOrigin).TotalMilliseconds >=
                                (current.ConditionElapsedMilliseconds ?? current.ConditionDuration * current.UnitSeconds * 1000),
                            _ => current.ConditionMacroID.HasValue && runCounts.GetValueOrDefault(current.ConditionMacroID.Value) >= current.ConditionMacroRunCount
                        };
                        current = Next(automation, current, answer ? AutomationBranch.Yes : AutomationBranch.No); continue;
                    case AutomationNodeKind.RepeatFlow:
                        var count = repeatCounts.GetValueOrDefault(current.Id);
                        if ((current.RepeatInfinitely || count < Math.Max(0, current.RepeatCount)) && current.RepeatTargetNodeID is Guid repeatId)
                        {
                            repeatCounts[current.Id] = count + 1;
                            current = automation.Nodes.Single(n => n.Id == repeatId); continue;
                        }
                        repeatCounts.Remove(current.Id); break;
                    case AutomationNodeKind.LoopBack:
                        if (current.JumpTargetNodeID is Guid jumpId)
                        { current = automation.Nodes.Single(n => n.Id == jumpId); continue; }
                        break;
                }
                current = Next(automation, current, null);
            }
        }
        catch (OperationCanceledException) { return new(RunOutcome.Stopped); }
        catch (Exception ex) { Log(ex.Message, "error"); return new(RunOutcome.Failed, ex.Message); }
        finally { ActiveNodeId = null; ActiveNodeChanged?.Invoke(null); State = RunState.Idle; cancellation?.Dispose(); cancellation = null; }
    }

    public void TogglePause() { if (State == RunState.Idle) return; paused = !paused; State = paused ? RunState.Paused : RunState.Running; }
    public void Stop() => cancellation?.Cancel();

    private static AutomationNode Next(AutomationDefinition a, AutomationNode node, AutomationBranch? branch)
    {
        var link = a.Connections.SingleOrDefault(c => c.SourceNodeID == node.Id && c.Branch == branch)
            ?? throw new InvalidOperationException($"{node.Title} has no valid next node.");
        return a.Nodes.Single(n => n.Id == link.TargetNodeID);
    }
    private static bool MatchesAny(IReadOnlyList<TargetWindow> windows, string? process, string title) => windows.Any(w =>
        (string.IsNullOrWhiteSpace(process) || string.Equals(w.ProcessName, process, StringComparison.OrdinalIgnoreCase)) &&
        (string.IsNullOrWhiteSpace(title) || w.WindowTitle.Contains(title, StringComparison.OrdinalIgnoreCase)));
    private static async Task Delay(double seconds, CancellationToken token)
    { if (double.IsFinite(seconds) && seconds > 0) await Task.Delay(TimeSpan.FromSeconds(seconds), token); }
    private static async Task WaitForSchedule(AutomationNode n, CancellationToken token)
    {
        if (n.ScheduleMode == AutomationScheduleMode.Interval)
        {
            var unit = n.ScheduleIntervalUnit switch { AutomationScheduleUnit.Seconds => 1, AutomationScheduleUnit.Minutes => 60, _ => 3600 };
            await Delay(n.ScheduleInterval * unit, token); return;
        }
        var now = DateTime.Now; var target = now.Date.AddMinutes(Math.Clamp(n.ScheduleMinuteOfDay, 0, 1439));
        if (target <= now) target = target.AddDays(1);
        await Task.Delay(target - now, token);
    }
    private static MacroDefinition CloneOnce(MacroDefinition m) => new()
    {
        Id = m.Id, Name = m.Name, TargetBundleIdentifier = m.TargetBundleIdentifier,
        Actions = m.Actions, LoopMode = LoopMode.Once, LoopCount = 1,
        MousePlaybackMode = m.MousePlaybackMode,
        RecordedWindowWidth = m.RecordedWindowWidth, RecordedWindowHeight = m.RecordedWindowHeight
    };
    private void Log(string message, string level = "info") => Logged?.Invoke(message, level);
}

using Macro.Core;

var tests = new (string Name, Func<Task> Run)[]
{
    ("macOS-compatible JSON round trip", JsonRoundTrip),
    ("existing macOS example import", ExistingExampleImport),
    ("macro playback and held-input cleanup", RunnerCleanup),
    ("multi-click event ordering", MultiClickOrdering),
    ("pause excludes paused time", PauseTiming),
    ("workflow validation and execution", WorkflowRun)
};
var failures = 0;
foreach (var test in tests)
{
    try { await test.Run(); Console.WriteLine("PASS " + test.Name); }
    catch (Exception ex) { failures++; Console.Error.WriteLine("FAIL " + test.Name + ": " + ex.Message); }
}
return failures;

static Task JsonRoundTrip()
{
    var temp = Path.Combine(Path.GetTempPath(), "macro-tests-" + Guid.NewGuid());
    var store = new JsonStorage(temp); var macro = MacroDefinition.Example(); store.SaveMacros([macro]);
    var text = File.ReadAllText(store.MacrosPath);
    Assert(text.Contains("\"keyDown\""), "Enums must use the Swift-compatible camelCase representation.");
    var loaded = store.LoadMacros().Single();
    Assert(loaded.Actions.Count == 6 && loaded.LoopMode == LoopMode.Infinite, "Round trip changed macro data.");
    Directory.Delete(temp, true); return Task.CompletedTask;
}

static Task ExistingExampleImport()
{
    var path = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../Examples/RobloxTravelLoop.json"));
    var macro = new JsonStorage().Import<MacroDefinition>(path) ?? throw new Exception("Example did not decode.");
    Assert(macro.Name == "Roblox Travel Loop" && macro.Actions.Count == 6, "Existing Swift JSON changed during import.");
    Assert(macro.Actions[0].Type == MacroActionType.KeyDown && macro.LoopMode == LoopMode.Infinite, "Enum compatibility failed.");
    return Task.CompletedTask;
}

static async Task RunnerCleanup()
{
    var backend = new FakeBackend(); var runner = new MacroRunner();
    var macro = new MacroDefinition { Actions = [new() { Type = MacroActionType.KeyDown, Key = "w" }, new() { Type = MacroActionType.Wait, Duration = 5 }] };
    var task = runner.RunAsync(macro, Target(), backend); await Task.Delay(60); runner.Stop();
    var result = await task;
    Assert(result.Outcome == RunOutcome.Stopped, "Stop should return Stopped.");
    Assert(backend.Events.Contains("up:w"), "A stopped run must release held keys.");
    Assert(runner.State == RunState.Idle, "Runner did not return to idle.");
}

static async Task MultiClickOrdering()
{
    var backend = new FakeBackend(); var runner = new MacroRunner();
    var macro = new MacroDefinition { Actions = [new() { Type = MacroActionType.LeftClick, ClickCount = 2, Duration = .01, X = 10, Y = 20 }] };
    Assert((await runner.RunAsync(macro, Target(), backend)).Outcome == RunOutcome.Completed, "Double click did not complete.");
    Assert(backend.Events.SequenceEqual(["mouseDown:Left", "mouseUp:Left", "mouseDown:Left", "mouseUp:Left"]), "Double-click events were not interleaved correctly.");
}

static async Task PauseTiming()
{
    var runner = new MacroRunner(); var backend = new FakeBackend();
    var macro = new MacroDefinition { Actions = [new() { Type = MacroActionType.Wait, Duration = .15 }] };
    var started = DateTime.UtcNow; var task = runner.RunAsync(macro, Target(), backend);
    await Task.Delay(40); runner.TogglePause(); await Task.Delay(160); runner.TogglePause();
    Assert((await task).Outcome == RunOutcome.Completed, "Paused run did not complete.");
    Assert((DateTime.UtcNow - started).TotalMilliseconds >= 280, "Paused time incorrectly advanced the wait.");
}

static async Task WorkflowRun()
{
    var macro = new MacroDefinition { Actions = [new() { Type = MacroActionType.KeyPress, Key = "e", Duration = .01 }] };
    var start = new AutomationNode { Kind = AutomationNodeKind.Start };
    var run = new AutomationNode { Kind = AutomationNodeKind.Macro, MacroID = macro.Id };
    var stop = new AutomationNode { Kind = AutomationNodeKind.Stop };
    var flow = new AutomationDefinition
    {
        Nodes = [start, run, stop], Connections =
        [new() { SourceNodeID = start.Id, TargetNodeID = run.Id }, new() { SourceNodeID = run.Id, TargetNodeID = stop.Id }]
    };
    Assert(flow.Validate(new HashSet<Guid> { macro.Id }).Count == 0, "Valid workflow was rejected.");
    var backend = new FakeBackend(); var engine = new AutomationRunner();
    var result = await engine.RunAsync(flow, id => id == macro.Id ? macro : null, (_, _) => Target(), _ => backend, () => [Target()], new MacroRunner());
    Assert(result.Outcome == RunOutcome.Completed && backend.Events.SequenceEqual(["down:e", "up:e"]), "Workflow did not execute its macro.");
}

static TargetWindow Target() => new(1, "Test", "Window", 1, "test", 10, 20, 800, 600);
static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }

sealed class FakeBackend : IInputBackend
{
    public string DisplayName => "Fake"; public List<string> Events { get; } = [];
    public void KeyDown(string key, TargetWindow target) => Events.Add("down:" + key);
    public void KeyUp(string key, TargetWindow target) => Events.Add("up:" + key);
    public void MouseMove(int x, int y, TargetWindow target) => Events.Add($"move:{x},{y}");
    public void MouseDown(MacroMouseButton button, int x, int y, int clickCount, TargetWindow target) => Events.Add("mouseDown:" + button);
    public void MouseUp(MacroMouseButton button, int x, int y, int clickCount, TargetWindow target) => Events.Add("mouseUp:" + button);
    public void Scroll(int deltaX, int deltaY, int x, int y, TargetWindow target) => Events.Add($"scroll:{deltaX},{deltaY}");
}

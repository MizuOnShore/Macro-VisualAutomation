using System.Diagnostics;

namespace Macro.Core;

public interface IInputBackend
{
    string DisplayName { get; }
    void KeyDown(string key, TargetWindow target);
    void KeyUp(string key, TargetWindow target);
    void MouseMove(int x, int y, TargetWindow target);
    void MouseDown(MacroMouseButton button, int x, int y, int clickCount, TargetWindow target);
    void MouseUp(MacroMouseButton button, int x, int y, int clickCount, TargetWindow target);
    void Scroll(int deltaX, int deltaY, int x, int y, TargetWindow target);
}

public sealed class MacroRunner
{
    private readonly object stateLock = new();
    private readonly HashSet<string> heldKeys = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<MacroMouseButton> heldButtons = [];
    private CancellationTokenSource? cancellation;
    private IInputBackend? activeBackend;
    private TargetWindow? activeTarget;
    private int lastX, lastY;
    public RunState State { get; private set; } = RunState.Idle;
    public event Action<RunState>? StateChanged;
    public event Action<string, string>? Logged;
    public event Action<int, int>? Progress;

    public async Task<MacroRunResult> RunAsync(
        MacroDefinition macro, TargetWindow target, IInputBackend backend,
        CancellationToken externalToken = default)
    {
        lock (stateLock)
        {
            if (State != RunState.Idle) throw new InvalidOperationException("A macro is already running.");
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(externalToken);
            activeBackend = backend; activeTarget = target;
            SetState(RunState.Running);
        }

        var token = cancellation.Token;
        try
        {
            var actions = macro.Actions.Where(a => a.IsEnabled).ToList();
            var iterations = macro.LoopMode switch
            {
                LoopMode.Once => 1, LoopMode.Count => Math.Max(1, macro.LoopCount), _ => int.MaxValue
            };
            var total = iterations == int.MaxValue ? actions.Count : actions.Count * iterations;
            var done = 0;
            Log($"Macro started with {backend.DisplayName}");

            for (var iteration = 0; iteration < iterations; iteration++)
            {
                foreach (var action in actions)
                {
                    token.ThrowIfCancellationRequested();
                    await DelayPausably(action.Delay, token);
                    Progress?.Invoke(total == 0 ? 0 : done + 1, Math.Max(1, total));
                    await Execute(action, macro, target, backend, token);
                    done++;
                }
            }
            Log("Macro completed");
            return new(RunOutcome.Completed);
        }
        catch (OperationCanceledException)
        {
            Log("Macro stopped", "warning");
            return new(RunOutcome.Stopped);
        }
        catch (Exception ex)
        {
            Log("Macro error: " + ex.Message, "error");
            return new(RunOutcome.Failed, ex.Message);
        }
        finally
        {
            ReleaseHeld();
            lock (stateLock)
            {
                cancellation?.Dispose(); cancellation = null;
                activeBackend = null; activeTarget = null;
                SetState(RunState.Idle);
            }
        }
    }

    public void TogglePause()
    {
        lock (stateLock)
        {
            if (State == RunState.Running) SetState(RunState.Paused);
            else if (State == RunState.Paused) SetState(RunState.Running);
        }
    }

    public void Stop() => cancellation?.Cancel();

    private async Task Execute(MacroAction a, MacroDefinition macro, TargetWindow target,
        IInputBackend backend, CancellationToken token)
    {
        var (x, y) = ResolvePoint(a, macro, target);
        lastX = x; lastY = y;
        switch (a.Type)
        {
            case MacroActionType.KeyDown:
                RequireKey(a); backend.KeyDown(a.Key!, target); heldKeys.Add(a.Key!); break;
            case MacroActionType.KeyUp:
                RequireKey(a); backend.KeyUp(a.Key!, target); heldKeys.Remove(a.Key!); break;
            case MacroActionType.KeyPress:
            case MacroActionType.HoldKey:
                RequireKey(a); backend.KeyDown(a.Key!, target); heldKeys.Add(a.Key!);
                await DelayPausably(Math.Max(.01, a.Duration), token);
                backend.KeyUp(a.Key!, target); heldKeys.Remove(a.Key!); break;
            case MacroActionType.Wait:
                await DelayPausably(a.Duration, token); break;
            case MacroActionType.LeftClick:
            case MacroActionType.RightClick:
            case MacroActionType.MiddleClick:
                var clickButton = a.Type == MacroActionType.LeftClick ? MacroMouseButton.Left :
                    a.Type == MacroActionType.RightClick ? MacroMouseButton.Right : MacroMouseButton.Middle;
                for (var click = 0; click < Math.Max(1, a.ClickCount); click++)
                {
                    backend.MouseDown(clickButton, x, y, 1, target);
                    heldButtons.Add(clickButton);
                    await DelayPausably(Math.Max(.01, a.Duration), token);
                    backend.MouseUp(clickButton, x, y, 1, target);
                    heldButtons.Remove(clickButton);
                    if (click + 1 < Math.Max(1, a.ClickCount)) await DelayPausably(.04, token);
                }
                break;
            case MacroActionType.MouseDown:
                backend.MouseDown(a.MouseButton, x, y, Math.Max(1, a.ClickCount), target);
                heldButtons.Add(a.MouseButton); break;
            case MacroActionType.MouseUp:
                backend.MouseUp(a.MouseButton, x, y, Math.Max(1, a.ClickCount), target);
                heldButtons.Remove(a.MouseButton); break;
            case MacroActionType.Move: backend.MouseMove(x, y, target); break;
            case MacroActionType.Scroll:
                backend.Scroll((int)Math.Round(a.ScrollDeltaX), (int)Math.Round(a.ScrollDeltaY), x, y, target); break;
        }
    }

    private async Task DelayPausably(double seconds, CancellationToken token)
    {
        if (!double.IsFinite(seconds) || seconds <= 0) return;
        var remaining = TimeSpan.FromSeconds(seconds);
        var timer = Stopwatch.StartNew();
        while (remaining > TimeSpan.Zero)
        {
            token.ThrowIfCancellationRequested();
            if (State == RunState.Paused) { await Task.Delay(20, token); timer.Restart(); continue; }
            var slice = remaining < TimeSpan.FromMilliseconds(20) ? remaining : TimeSpan.FromMilliseconds(20);
            await Task.Delay(slice, token);
            remaining -= timer.Elapsed;
            timer.Restart();
        }
    }

    private static (int x, int y) ResolvePoint(MacroAction a, MacroDefinition macro, TargetWindow t)
    {
        var x = a.X ?? 0; var y = a.Y ?? 0;
        if (!a.UsesWindowCoordinates) return ((int)Math.Round(x), (int)Math.Round(y));
        if (macro.RecordedWindowWidth is > 0 && macro.RecordedWindowHeight is > 0)
        {
            x *= t.Width / macro.RecordedWindowWidth.Value;
            y *= t.Height / macro.RecordedWindowHeight.Value;
        }
        return (t.X + Math.Clamp((int)Math.Round(x), 0, Math.Max(0, t.Width - 1)),
            t.Y + Math.Clamp((int)Math.Round(y), 0, Math.Max(0, t.Height - 1)));
    }

    private static void RequireKey(MacroAction a)
    {
        if (string.IsNullOrWhiteSpace(a.Key)) throw new InvalidOperationException("The action has no key.");
    }

    private void ReleaseHeld()
    {
        if (activeBackend is not null && activeTarget is not null)
        {
            foreach (var key in heldKeys.ToArray()) try { activeBackend.KeyUp(key, activeTarget); } catch { }
            foreach (var button in heldButtons.ToArray())
                try { activeBackend.MouseUp(button, lastX, lastY, 1, activeTarget); } catch { }
        }
        heldKeys.Clear(); heldButtons.Clear();
    }

    private void SetState(RunState state) { State = state; StateChanged?.Invoke(state); }
    private void Log(string message, string level = "info") => Logged?.Invoke(message, level);
}

using System.Text.Json.Serialization;

namespace Macro.Core;

public enum MacroActionType
{
    KeyDown, KeyUp, KeyPress, HoldKey, Wait,
    LeftClick, RightClick, MiddleClick, MouseDown, MouseUp, Move, Scroll
}

public enum MacroMouseButton { Left, Right, Middle }

public enum LoopMode { Once, Count, Infinite }

public enum MousePlaybackMode { Background, Compatibility }

public sealed class MacroAction
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public MacroActionType Type { get; set; }
    public string? Key { get; set; }
    public double Duration { get; set; }
    public double Delay { get; set; }
    public double? X { get; set; }
    public double? Y { get; set; }
    public MacroMouseButton MouseButton { get; set; } = MacroMouseButton.Left;
    public int ClickCount { get; set; } = 1;
    public double ScrollDeltaX { get; set; }
    public double ScrollDeltaY { get; set; }
    public bool UsesWindowCoordinates { get; set; } = true;
    public bool IsEnabled { get; set; } = true;

    public MacroAction Clone() => (MacroAction)MemberwiseClone();

    public override string ToString() => Type switch
    {
        MacroActionType.Wait => $"Wait {Duration:0.###} s",
        MacroActionType.KeyDown or MacroActionType.KeyUp or MacroActionType.KeyPress or MacroActionType.HoldKey
            => $"{Title(Type)} {Key?.ToUpperInvariant() ?? "(key)"}",
        MacroActionType.Scroll => $"Scroll {ScrollDeltaX:0}, {ScrollDeltaY:0}",
        _ => $"{Title(Type)} at {X ?? 0:0}, {Y ?? 0:0}"
    };

    public static string Title(MacroActionType type) => type switch
    {
        MacroActionType.KeyDown => "Key Down", MacroActionType.KeyUp => "Key Up",
        MacroActionType.KeyPress => "Key Press", MacroActionType.HoldKey => "Hold Key",
        MacroActionType.LeftClick => "Left Click", MacroActionType.RightClick => "Right Click",
        MacroActionType.MiddleClick => "Middle Click", MacroActionType.MouseDown => "Mouse Down",
        MacroActionType.MouseUp => "Mouse Up", MacroActionType.Move => "Move Pointer",
        _ => type.ToString()
    };
}

public sealed class MacroDefinition
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "Untitled Macro";
    public string? TargetBundleIdentifier { get; set; }
    public List<MacroAction> Actions { get; set; } = [];
    public LoopMode LoopMode { get; set; } = LoopMode.Once;
    public int LoopCount { get; set; } = 2;
    public MousePlaybackMode MousePlaybackMode { get; set; } = MousePlaybackMode.Background;
    public double? RecordedWindowWidth { get; set; }
    public double? RecordedWindowHeight { get; set; }

    public MacroDefinition DeepClone() => new()
    {
        Id = Guid.NewGuid(), Name = Name + " Copy", TargetBundleIdentifier = TargetBundleIdentifier,
        Actions = Actions.Select(a => { var c = a.Clone(); c.Id = Guid.NewGuid(); return c; }).ToList(),
        LoopMode = LoopMode, LoopCount = LoopCount, MousePlaybackMode = MousePlaybackMode,
        RecordedWindowWidth = RecordedWindowWidth, RecordedWindowHeight = RecordedWindowHeight
    };

    public override string ToString() => Name;

    public static MacroDefinition Example() => new()
    {
        Name = "Roblox Travel Loop", LoopMode = LoopMode.Infinite,
        Actions =
        [
            new() { Type = MacroActionType.KeyDown, Key = "w" },
            new() { Type = MacroActionType.Wait, Duration = 10 },
            new() { Type = MacroActionType.KeyUp, Key = "w" },
            new() { Type = MacroActionType.Wait, Duration = 2 },
            new() { Type = MacroActionType.KeyPress, Key = "e", Duration = .1 },
            new() { Type = MacroActionType.Wait, Duration = 3 }
        ]
    };
}

public sealed record TargetWindow(
    nint Handle, string ApplicationName, string WindowTitle, int ProcessId,
    string? ProcessName, int X, int Y, int Width, int Height)
{
    public string Identity => ProcessName ?? ProcessId.ToString();
    public override string ToString() => $"{ApplicationName} — {WindowTitle} ({Width} × {Height})";
}

public enum RunState { Idle, Running, Paused }
public enum RunOutcome { Completed, Stopped, Failed }
public sealed record MacroRunResult(RunOutcome Outcome, string? Error = null);

public sealed record LogEntry(DateTime Timestamp, string Level, string Message);

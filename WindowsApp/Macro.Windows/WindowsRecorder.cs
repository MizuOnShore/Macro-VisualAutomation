using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using Macro.Core;

namespace Macro.Windows;

internal sealed class WindowsRecorder : IDisposable
{
    private sealed record Pending(DateTime Time, double Delay, int X, int Y);
    private readonly List<MacroAction> actions = [];
    private readonly Dictionary<MacroMouseButton, Pending> pending = [];
    private readonly HashSet<uint> heldKeys = [];
    private nint keyboardHook, mouseHook;
    private NativeMethods.HookProc? keyboardProc, mouseProc;
    private DateTime? lastEvent;
    private DateTime lastMove;
    private Point lastMovePoint = new(-10000, -10000);
    private TargetWindow? target;
    public bool IsRecording => keyboardHook != 0 || mouseHook != 0;
    public event Action<int>? ActionCountChanged;

    public void Start(TargetWindow? selectedTarget)
    {
        if (IsRecording) return;
        target = selectedTarget; actions.Clear(); pending.Clear(); heldKeys.Clear(); lastEvent = null;
        keyboardProc = KeyboardCallback; mouseProc = MouseCallback;
        var module = NativeMethods.GetModuleHandle(null);
        keyboardHook = NativeMethods.SetWindowsHookEx(NativeMethods.WH_KEYBOARD_LL, keyboardProc, module, 0);
        mouseHook = NativeMethods.SetWindowsHookEx(NativeMethods.WH_MOUSE_LL, mouseProc, module, 0);
        if (keyboardHook == 0 || mouseHook == 0)
        {
            DisposeHooks();
            throw new InvalidOperationException("Windows could not install the recording hooks.");
        }
    }

    public List<MacroAction> Stop()
    {
        DisposeHooks();
        foreach (var (button, p) in pending)
            Add(new() { Type = MacroActionType.MouseDown, MouseButton = button, X = p.X, Y = p.Y, Delay = p.Delay, UsesWindowCoordinates = target is not null });
        pending.Clear(); heldKeys.Clear();
        var result = actions.ToList(); actions.Clear(); ActionCountChanged?.Invoke(0);
        return result;
    }

    private nint KeyboardCallback(int code, nint wParam, nint lParam)
    {
        if (code >= 0)
        {
            var info = Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
            if ((info.Flags & NativeMethods.LLKHF_INJECTED) == 0 && info.VkCode is not (0x75 or 0x76 or 0x77))
            {
                var message = (uint)wParam;
                var isDown = message is 0x0100 or 0x0104;
                var isUp = message is 0x0101 or 0x0105;
                if ((isDown && heldKeys.Add(info.VkCode)) || (isUp && heldKeys.Remove(info.VkCode)))
                {
                    Add(new()
                    {
                        Type = isDown ? MacroActionType.KeyDown : MacroActionType.KeyUp,
                        Key = KeyName(info.VkCode), Delay = NextDelay()
                    });
                }
            }
        }
        return NativeMethods.CallNextHookEx(keyboardHook, code, wParam, lParam);
    }

    private nint MouseCallback(int code, nint wParam, nint lParam)
    {
        if (code >= 0)
        {
            var info = Marshal.PtrToStructure<NativeMethods.MSLLHOOKSTRUCT>(lParam);
            if ((info.Flags & NativeMethods.LLMHF_INJECTED) == 0)
            {
                var message = (uint)wParam;
                var (x, y) = Coordinates(info.Point.X, info.Point.Y);
                var button = message is 0x0201 or 0x0202 ? MacroMouseButton.Left :
                    message is 0x0204 or 0x0205 ? MacroMouseButton.Right : MacroMouseButton.Middle;
                if (message is 0x0201 or 0x0204 or 0x0207)
                {
                    pending[button] = new(DateTime.UtcNow, NextDelay(), x, y);
                }
                else if (message is 0x0202 or 0x0205 or 0x0208)
                {
                    if (pending.Remove(button, out var down))
                    {
                        Add(new()
                        {
                            Type = button switch { MacroMouseButton.Left => MacroActionType.LeftClick, MacroMouseButton.Right => MacroActionType.RightClick, _ => MacroActionType.MiddleClick },
                            MouseButton = button, X = down.X, Y = down.Y, Delay = down.Delay,
                            Duration = Math.Max(.01, (DateTime.UtcNow - down.Time).TotalSeconds), UsesWindowCoordinates = target is not null
                        });
                    }
                }
                else if (message == 0x0200)
                {
                    var now = DateTime.UtcNow;
                    if ((now - lastMove).TotalMilliseconds >= 50 && Math.Sqrt(Math.Pow(info.Point.X - lastMovePoint.X, 2) + Math.Pow(info.Point.Y - lastMovePoint.Y, 2)) >= 4)
                    {
                        foreach (var (held, down) in pending.ToArray())
                        {
                            Add(new() { Type = MacroActionType.MouseDown, MouseButton = held, X = down.X, Y = down.Y, Delay = down.Delay, UsesWindowCoordinates = target is not null });
                            pending.Remove(held);
                        }
                        Add(new() { Type = MacroActionType.Move, X = x, Y = y, Delay = NextDelay(), UsesWindowCoordinates = target is not null });
                        lastMove = now; lastMovePoint = new(info.Point.X, info.Point.Y);
                    }
                }
                else if (message is 0x020A or 0x020E)
                {
                    var wheel = unchecked((short)(info.MouseData >> 16));
                    Add(new()
                    {
                        Type = MacroActionType.Scroll, X = x, Y = y, Delay = NextDelay(),
                        ScrollDeltaY = message == 0x020A ? wheel : 0,
                        ScrollDeltaX = message == 0x020E ? wheel : 0, UsesWindowCoordinates = target is not null
                    });
                }
            }
        }
        return NativeMethods.CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    private (int, int) Coordinates(int x, int y) => target is null ? (x, y) : (x - target.X, y - target.Y);
    private double NextDelay()
    {
        var now = DateTime.UtcNow; var delay = lastEvent.HasValue ? (now - lastEvent.Value).TotalSeconds : 0;
        lastEvent = now; return Math.Max(0, delay);
    }
    private void Add(MacroAction action)
    {
        actions.Add(action); lastEvent = DateTime.UtcNow; ActionCountChanged?.Invoke(actions.Count);
    }

    private static string KeyName(uint vk)
    {
        if (vk is >= 0x70 and <= 0x87) return "f" + (vk - 0x6F);
        if (vk is >= 0x41 and <= 0x5A || vk is >= 0x30 and <= 0x39) return ((char)vk).ToString().ToLowerInvariant();
        return vk switch
        {
            0x08 => "delete", 0x09 => "tab", 0x0D => "return", 0x10 => "shift", 0x11 => "control",
            0x12 => "option", 0x14 => "capslock", 0x1B => "escape", 0x20 => "space", 0x21 => "pageup",
            0x22 => "pagedown", 0x23 => "end", 0x24 => "home", 0x25 => "left", 0x26 => "up",
            0x27 => "right", 0x28 => "down", 0x2E => "forwarddelete", 0x5B or 0x5C => "command",
            _ => "keyCode:" + vk
        };
    }

    private void DisposeHooks()
    {
        if (keyboardHook != 0) NativeMethods.UnhookWindowsHookEx(keyboardHook);
        if (mouseHook != 0) NativeMethods.UnhookWindowsHookEx(mouseHook);
        keyboardHook = mouseHook = 0; keyboardProc = mouseProc = null;
    }
    public void Dispose() => DisposeHooks();
}

using Macro.Core;

namespace Macro.Windows;

internal sealed class WindowsInputBackend(MousePlaybackMode mode) : IInputBackend
{
    public string DisplayName => mode == MousePlaybackMode.Background ? "Windows Background Messages" : "Windows Compatibility Input";

    public void KeyDown(string key, TargetWindow target) => Key(key, false, target);
    public void KeyUp(string key, TargetWindow target) => Key(key, true, target);

    public void MouseMove(int x, int y, TargetWindow target)
    {
        if (mode == MousePlaybackMode.Background) PostMouse(target, NativeMethods.WM_MOUSEMOVE, 0, x, y);
        else SendMouseMove(x, y, target);
    }

    public void MouseDown(MacroMouseButton button, int x, int y, int clickCount, TargetWindow target)
    {
        if (mode == MousePlaybackMode.Background)
        {
            var message = button switch { MacroMouseButton.Left => NativeMethods.WM_LBUTTONDOWN, MacroMouseButton.Right => NativeMethods.WM_RBUTTONDOWN, _ => NativeMethods.WM_MBUTTONDOWN };
            for (var i = 0; i < Math.Max(1, clickCount); i++) PostMouse(target, message, ButtonFlag(button), x, y);
        }
        else { SendMouseMove(x, y, target); SendMouse(button, false); }
    }

    public void MouseUp(MacroMouseButton button, int x, int y, int clickCount, TargetWindow target)
    {
        if (mode == MousePlaybackMode.Background)
        {
            var message = button switch { MacroMouseButton.Left => NativeMethods.WM_LBUTTONUP, MacroMouseButton.Right => NativeMethods.WM_RBUTTONUP, _ => NativeMethods.WM_MBUTTONUP };
            for (var i = 0; i < Math.Max(1, clickCount); i++) PostMouse(target, message, 0, x, y);
        }
        else SendMouse(button, true);
    }

    public void Scroll(int deltaX, int deltaY, int x, int y, TargetWindow target)
    {
        if (mode == MousePlaybackMode.Background)
        {
            if (deltaY != 0) NativeMethods.PostMessage(target.Handle, NativeMethods.WM_MOUSEWHEEL, NativeMethods.MakeWParam(0, deltaY), NativeMethods.MakeLParam(x, y));
            if (deltaX != 0) NativeMethods.PostMessage(target.Handle, NativeMethods.WM_MOUSEHWHEEL, NativeMethods.MakeWParam(0, deltaX), NativeMethods.MakeLParam(x, y));
        }
        else
        {
            Activate(target);
            var inputs = new List<NativeMethods.INPUT>();
            if (deltaY != 0) inputs.Add(MouseInput(NativeMethods.MOUSEEVENTF_WHEEL, unchecked((uint)deltaY)));
            if (deltaX != 0) inputs.Add(MouseInput(NativeMethods.MOUSEEVENTF_HWHEEL, unchecked((uint)deltaX)));
            Send(inputs);
        }
    }

    private void Key(string key, bool up, TargetWindow target)
    {
        var vk = KeyMapper.ToVirtualKey(key);
        if (mode == MousePlaybackMode.Background)
        {
            var scan = NativeMethods.MapVirtualKey(vk, 0);
            var lparam = 1 | ((int)scan << 16) | (up ? unchecked((int)0xC0000000) : 0);
            Ensure(NativeMethods.PostMessage(target.Handle, up ? NativeMethods.WM_KEYUP : NativeMethods.WM_KEYDOWN, (nint)vk, lparam));
        }
        else
        {
            Activate(target);
            Send([new() { Type = NativeMethods.INPUT_KEYBOARD, Data = new() { Keyboard = new() { Vk = (ushort)vk, Flags = up ? NativeMethods.KEYEVENTF_KEYUP : 0 } } }]);
        }
    }

    private static void PostMouse(TargetWindow target, uint message, int flags, int screenX, int screenY)
    {
        var p = new NativeMethods.POINT { X = screenX, Y = screenY };
        Ensure(NativeMethods.ScreenToClient(target.Handle, ref p));
        Ensure(NativeMethods.PostMessage(target.Handle, message, flags, NativeMethods.MakeLParam(p.X, p.Y)));
    }

    private static void SendMouseMove(int x, int y, TargetWindow target)
    {
        Activate(target);
        var left = NativeMethods.GetSystemMetrics(NativeMethods.SM_XVIRTUALSCREEN);
        var top = NativeMethods.GetSystemMetrics(NativeMethods.SM_YVIRTUALSCREEN);
        var width = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SM_CXVIRTUALSCREEN));
        var height = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SM_CYVIRTUALSCREEN));
        var absoluteX = (int)Math.Round((x - left) * 65535.0 / Math.Max(1, width - 1));
        var absoluteY = (int)Math.Round((y - top) * 65535.0 / Math.Max(1, height - 1));
        Send([new() { Type = NativeMethods.INPUT_MOUSE, Data = new() { Mouse = new()
        {
            Dx = Math.Clamp(absoluteX, 0, 65535), Dy = Math.Clamp(absoluteY, 0, 65535),
            Flags = NativeMethods.MOUSEEVENTF_MOVE | NativeMethods.MOUSEEVENTF_ABSOLUTE | NativeMethods.MOUSEEVENTF_VIRTUALDESK
        } } }]);
    }

    private static void SendMouse(MacroMouseButton button, bool up)
    {
        var flag = (button, up) switch
        {
            (MacroMouseButton.Left, false) => NativeMethods.MOUSEEVENTF_LEFTDOWN,
            (MacroMouseButton.Left, true) => NativeMethods.MOUSEEVENTF_LEFTUP,
            (MacroMouseButton.Right, false) => NativeMethods.MOUSEEVENTF_RIGHTDOWN,
            (MacroMouseButton.Right, true) => NativeMethods.MOUSEEVENTF_RIGHTUP,
            (MacroMouseButton.Middle, false) => NativeMethods.MOUSEEVENTF_MIDDLEDOWN,
            _ => NativeMethods.MOUSEEVENTF_MIDDLEUP
        };
        Send([MouseInput(flag, 0)]);
    }

    private static NativeMethods.INPUT MouseInput(uint flag, uint data) =>
        new() { Type = NativeMethods.INPUT_MOUSE, Data = new() { Mouse = new() { Flags = flag, MouseData = data } } };
    private static void Activate(TargetWindow target)
    {
        if (NativeMethods.IsIconic(target.Handle)) NativeMethods.ShowWindow(target.Handle, NativeMethods.SW_RESTORE);
        NativeMethods.SetForegroundWindow(target.Handle);
    }
    private static void Send(IReadOnlyCollection<NativeMethods.INPUT> inputs)
    {
        if (inputs.Count == 0) return;
        var array = inputs.ToArray();
        Ensure(NativeMethods.SendInput((uint)array.Length, array, System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.INPUT>()) == (uint)array.Length);
    }
    private static int ButtonFlag(MacroMouseButton b) => b switch { MacroMouseButton.Left => 1, MacroMouseButton.Right => 2, _ => 0x10 };
    private static void Ensure(bool success) { if (!success) throw new InvalidOperationException("Windows rejected the synthetic input."); }
}

internal static class KeyMapper
{
    private static readonly Dictionary<string, uint> Named = new(StringComparer.OrdinalIgnoreCase)
    {
        ["return"] = 0x0D, ["enter"] = 0x0D, ["tab"] = 0x09, ["space"] = 0x20,
        ["delete"] = 0x08, ["backspace"] = 0x08, ["forwarddelete"] = 0x2E,
        ["escape"] = 0x1B, ["esc"] = 0x1B, ["shift"] = 0x10, ["control"] = 0x11,
        ["ctrl"] = 0x11, ["option"] = 0x12, ["alt"] = 0x12, ["command"] = 0x5B,
        ["win"] = 0x5B, ["left"] = 0x25, ["up"] = 0x26, ["right"] = 0x27, ["down"] = 0x28,
        ["home"] = 0x24, ["end"] = 0x23, ["pageup"] = 0x21, ["pagedown"] = 0x22,
        ["capslock"] = 0x14, ["rightshift"] = 0xA1, ["rightcontrol"] = 0xA3, ["rightoption"] = 0xA5
    };
    internal static uint ToVirtualKey(string key)
    {
        var normalized = key.Replace(" ", "").Trim();
        if (Named.TryGetValue(normalized, out var named)) return named;
        if (normalized.StartsWith("keycode:", StringComparison.OrdinalIgnoreCase) && uint.TryParse(normalized[8..], out var raw)) return raw;
        if (normalized.StartsWith('f') && int.TryParse(normalized[1..], out var f) && f is >= 1 and <= 24) return (uint)(0x6F + f);
        if (normalized.Length == 1)
        {
            var vk = NativeMethods.VkKeyScan(normalized[0]);
            if (vk >= 0) return (uint)(vk & 0xff);
        }
        throw new InvalidOperationException("Unknown key: " + key);
    }
}

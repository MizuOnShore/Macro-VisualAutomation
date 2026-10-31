using System.Runtime.InteropServices;

namespace Macro.Windows;

internal static class NativeMethods
{
    internal delegate bool EnumWindowsProc(nint hWnd, nint lParam);
    internal delegate nint HookProc(int code, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)] internal struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] internal struct KBDLLHOOKSTRUCT { public uint VkCode, ScanCode, Flags, Time; public nint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] internal struct MSLLHOOKSTRUCT { public POINT Point; public uint MouseData, Flags, Time; public nint ExtraInfo; }

    [StructLayout(LayoutKind.Sequential)] internal struct INPUT
    {
        public uint Type; public InputUnion Data;
    }
    [StructLayout(LayoutKind.Explicit)] internal struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct MOUSEINPUT
    { public int Dx, Dy; public uint MouseData, Flags, Time; public nint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] internal struct KEYBDINPUT
    { public ushort Vk, Scan; public uint Flags, Time; public nint ExtraInfo; }

    internal const uint WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101;
    internal const uint WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
    internal const uint WM_RBUTTONDOWN = 0x0204, WM_RBUTTONUP = 0x0205, WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208;
    internal const uint WM_MOUSEWHEEL = 0x020A, WM_MOUSEHWHEEL = 0x020E;
    internal const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    internal const uint LLKHF_INJECTED = 0x10, LLMHF_INJECTED = 0x01;
    internal const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    internal const uint KEYEVENTF_KEYUP = 0x0002;
    internal const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    internal const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    internal const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040;
    internal const uint MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000;
    internal const uint MOUSEEVENTF_VIRTUALDESK = 0x4000, MOUSEEVENTF_ABSOLUTE = 0x8000;
    internal const int SW_RESTORE = 9;
    internal const int SM_CXSCREEN = 0, SM_CYSCREEN = 1;
    internal const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77, SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

    [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumWindowsProc callback, nint param);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(nint hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(nint hWnd, char[] text, int max);
    [DllImport("user32.dll")] internal static extern int GetWindowTextLength(nint hWnd);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hWnd, out uint pid);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(nint hWnd, out RECT rect);
    [DllImport("user32.dll")] internal static extern bool IsIconic(nint hWnd);
    [DllImport("user32.dll")] internal static extern bool ShowWindow(nint hWnd, int command);
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint hWnd);
    [DllImport("user32.dll")] internal static extern bool ScreenToClient(nint hWnd, ref POINT point);
    [DllImport("user32.dll")] internal static extern bool PostMessage(nint hWnd, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll")] internal static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] internal static extern short VkKeyScan(char character);
    [DllImport("user32.dll")] internal static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] internal static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] internal static extern bool RegisterHotKey(nint hWnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(nint hWnd, int id);
    [DllImport("user32.dll")] internal static extern nint SetWindowsHookEx(int id, HookProc callback, nint module, uint thread);
    [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint hook, int code, nint wParam, nint lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? module);

    internal static nint MakeLParam(int low, int high) => (nint)((high << 16) | (low & 0xffff));
    internal static nint MakeWParam(int low, int high) => (nint)((high << 16) | (low & 0xffff));
}

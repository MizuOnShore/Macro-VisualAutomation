using System.Diagnostics;
using Macro.Core;

namespace Macro.Windows;

internal sealed class TargetService
{
    public IReadOnlyList<TargetWindow> Discover()
    {
        var result = new List<TargetWindow>();
        var ownPid = Environment.ProcessId;
        NativeMethods.EnumWindows((handle, _) =>
        {
            try
            {
                if (!NativeMethods.IsWindowVisible(handle)) return true;
                var length = NativeMethods.GetWindowTextLength(handle);
                if (length <= 0) return true;
                var chars = new char[length + 1];
                NativeMethods.GetWindowText(handle, chars, chars.Length);
                var title = new string(chars, 0, Array.IndexOf(chars, '\0') is var end && end >= 0 ? end : length);
                NativeMethods.GetWindowThreadProcessId(handle, out var pid);
                if (pid == ownPid || pid == 0 || !NativeMethods.GetWindowRect(handle, out var rect)) return true;
                var width = rect.Right - rect.Left; var height = rect.Bottom - rect.Top;
                if (width < 80 || height < 60) return true;
                using var process = Process.GetProcessById((int)pid);
                result.Add(new(handle, process.ProcessName, title, (int)pid, process.ProcessName,
                    rect.Left, rect.Top, width, height));
            }
            catch { }
            return true;
        }, 0);
        return result.OrderBy(w => w.ApplicationName, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(w => w.WindowTitle, StringComparer.CurrentCultureIgnoreCase).ToList();
    }
}

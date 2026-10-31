using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Macro.Windows;

public sealed class ProcessIconConverter : IValueConverter
{
    private readonly Dictionary<int, ImageSource?> icons = [];

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconEx(string file, int index, out nint large, out nint small, uint count);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint icon);

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not int processId) return DependencyProperty.UnsetValue;
        if (!icons.TryGetValue(processId, out var source))
        {
            try
            {
                using var process = Process.GetProcessById(processId);
                var file = process.MainModule?.FileName;
                if (!string.IsNullOrWhiteSpace(file) && ExtractIconEx(file, 0, out var large, out var small, 1) > 0)
                {
                    try
                    {
                        var handle = small != 0 ? small : large;
                        var bitmap = Imaging.CreateBitmapSourceFromHIcon(
                            handle, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(32, 32));
                        bitmap.Freeze();
                        source = bitmap;
                    }
                    finally
                    {
                        if (small != 0) DestroyIcon(small);
                        if (large != 0) DestroyIcon(large);
                    }
                }
            }
            catch
            {
                source = null;
            }
            icons[processId] = source;
        }
        return source ?? DependencyProperty.UnsetValue;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

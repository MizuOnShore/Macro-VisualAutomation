using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Macro.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        var smokeTest = e.Args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase);
        var captureIndex = Array.FindIndex(e.Args, arg => arg.Equals("--capture-ui", StringComparison.OrdinalIgnoreCase));
        var captureUi = captureIndex >= 0;
        DispatcherUnhandledException += (_, args) =>
        {
            if (!smokeTest && !captureUi) MessageBox.Show(args.Exception.Message, "Macro", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
            if (smokeTest || captureUi) Shutdown(1);
        };
        base.OnStartup(e);
        if (captureUi)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
            {
                if (captureIndex + 1 >= e.Args.Length || Current.MainWindow is not MainWindow window)
                {
                    Shutdown(2);
                    return;
                }
                var directory = e.Args[captureIndex + 1];
                Directory.CreateDirectory(directory);
                foreach (var page in new[] { "Macros", "Recorder", "Target", "Logs", "Automation", "Settings" })
                {
                    window.ShowPageForCapture(page);
                    window.UpdateLayout();
                    var dpi = VisualTreeHelper.GetDpi(window);
                    var bitmap = new RenderTargetBitmap(
                        Math.Max(1, (int)Math.Ceiling(window.ActualWidth * dpi.DpiScaleX)),
                        Math.Max(1, (int)Math.Ceiling(window.ActualHeight * dpi.DpiScaleY)),
                        96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, PixelFormats.Pbgra32);
                    bitmap.Render(window);
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var stream = File.Create(Path.Combine(directory, page.ToLowerInvariant() + ".png"));
                    encoder.Save(stream);
                }
                window.Close();
                Shutdown(0);
            });
        }
        else if (smokeTest)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
            {
                var window = Current.MainWindow;
                var area = SystemParameters.WorkArea;
                var valid = window is MainWindow
                    && window.IsVisible
                    && window.ActualWidth >= 700 && window.ActualHeight >= 500
                    && window.Left >= area.Left - 2 && window.Top >= area.Top - 2
                    && window.Left + window.ActualWidth <= area.Right + 2
                    && window.Top + window.ActualHeight <= area.Bottom + 2;
                window?.Close();
                Shutdown(valid ? 0 : 2);
            });
        }
    }
}

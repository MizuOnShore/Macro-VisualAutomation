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
            Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, async () =>
            {
                if (captureIndex + 1 >= e.Args.Length || Current.MainWindow is not MainWindow window)
                {
                    Shutdown(2);
                    return;
                }
                var directory = e.Args[captureIndex + 1];
                Directory.CreateDirectory(directory);
                async Task CapturePage(string page, string suffix)
                {
                    window.ShowPageForCapture(page);
                    if (suffix == "-editor-wide") window.ShowSecondaryStateForCapture("macros-editor");
                    if (suffix == "-node-wide") window.ShowSecondaryStateForCapture("automation-node");
                    if (suffix == "-library-closed-wide") window.ShowSecondaryStateForCapture("automation-library-closed");
                    if (suffix == "-inspector-closed-wide") window.ShowSecondaryStateForCapture("automation-inspector-closed");
                    if (suffix == "-both-closed-wide") window.ShowSecondaryStateForCapture("automation-both-closed");
                    if (suffix == "-hotkeys-wide") window.ShowSecondaryStateForCapture("settings-hotkeys");
                    if (suffix == "-permissions-wide") window.ShowSecondaryStateForCapture("settings-permissions");
                    await Task.Delay(75);
                    Visual visual = window;
                    var width = window.ActualWidth;
                    var height = window.ActualHeight;
                    if (suffix.EndsWith("-wide", StringComparison.Ordinal) && window.Content is FrameworkElement root)
                    {
                        width = 1600;
                        height = 900;
                        window.ApplyCaptureLayout(width);
                        root.Measure(new Size(width, height));
                        root.Arrange(new Rect(0, 0, width, height));
                        window.FitCanvasForCapture(width, height);
                        visual = root;
                    }
                    else window.UpdateLayout();
                    var dpi = VisualTreeHelper.GetDpi(window);
                    var bitmap = new RenderTargetBitmap(
                        Math.Max(1, (int)Math.Ceiling(width * dpi.DpiScaleX)),
                        Math.Max(1, (int)Math.Ceiling(height * dpi.DpiScaleY)),
                        96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, PixelFormats.Pbgra32);
                    bitmap.Render(visual);
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var stream = File.Create(Path.Combine(directory, page.ToLowerInvariant() + suffix + ".png"));
                    encoder.Save(stream);
                }
                foreach (var page in new[] { "Macros", "Recorder", "Target", "Logs", "Automation", "Settings" })
                    await CapturePage(page, "");
                foreach (var page in new[] { "Macros", "Recorder", "Target", "Logs", "Automation", "Settings" })
                    await CapturePage(page, "-wide");
                await CapturePage("Macros", "-editor-wide");
                await CapturePage("Automation", "-node-wide");
                await CapturePage("Automation", "-library-closed-wide");
                await CapturePage("Automation", "-inspector-closed-wide");
                await CapturePage("Automation", "-both-closed-wide");
                await CapturePage("Settings", "-hotkeys-wide");
                await CapturePage("Settings", "-permissions-wide");
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
                var valid = window is MainWindow mainWindow
                    && window.IsVisible
                    && window.ActualWidth >= 700 && window.ActualHeight >= 500
                    && window.Left >= area.Left - 2 && window.Top >= area.Top - 2
                    && window.Left + window.ActualWidth <= area.Right + 2
                    && window.Top + window.ActualHeight <= area.Bottom + 2
                    && mainWindow.VerifyMacroSelectorForSmoke()
                    && mainWindow.VerifyAutomationPanelsForSmoke()
                    && mainWindow.VerifyRecordedLibraryForSmoke()
                    && mainWindow.VerifyNodeContextMenuForSmoke();
                window?.Close();
                Shutdown(valid ? 0 : 2);
            });
        }
    }
}

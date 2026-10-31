using System.Windows;
using System.Windows.Threading;

namespace Macro.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        var smokeTest = e.Args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase);
        DispatcherUnhandledException += (_, args) =>
        {
            if (!smokeTest) MessageBox.Show(args.Exception.Message, "Macro", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
            if (smokeTest) Shutdown(1);
        };
        base.OnStartup(e);
        if (smokeTest)
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

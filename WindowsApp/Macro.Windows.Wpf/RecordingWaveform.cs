using System.Windows;
using System.Windows.Media;

namespace Macro.Windows;

/// <summary>Decorative recording waveform, using the same deterministic pattern as macOS.</summary>
public sealed class RecordingWaveform : FrameworkElement
{
    public static readonly DependencyProperty ActionCountProperty = DependencyProperty.Register(
        nameof(ActionCount), typeof(int), typeof(RecordingWaveform),
        new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty TintProperty = DependencyProperty.Register(
        nameof(Tint), typeof(Color), typeof(RecordingWaveform),
        new FrameworkPropertyMetadata(Color.FromRgb(120, 133, 149), FrameworkPropertyMetadataOptions.AffectsRender));

    public int ActionCount
    {
        get => (int)GetValue(ActionCountProperty);
        set => SetValue(ActionCountProperty, value);
    }

    public Color Tint
    {
        get => (Color)GetValue(TintProperty);
        set => SetValue(TintProperty, value);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? 120 : availableSize.Width;
        var height = double.IsNaN(Height) ? 28 : Height;
        return new Size(Math.Max(0, width), Math.Max(0, height));
    }

    protected override void OnRender(DrawingContext context)
    {
        var width = ActualWidth;
        var fullHeight = ActualHeight;
        if (width <= 0 || fullHeight <= 0) return;

        var count = Math.Max(1, (int)(width / 4));
        var step = width / count;
        for (var index = 0; index < count; index++)
        {
            var seed = (index * 37 + ActionCount * 19) % 29;
            var variation = (double)((seed * seed + index * 11) % 23) / 23;
            var barHeight = Math.Max(3, fullHeight * (0.18 + variation * 0.82));
            var barWidth = Math.Max(1, step * 0.52);
            var bar = new Rect(index * step + step * 0.22, (fullHeight - barHeight) / 2, barWidth, barHeight);
            var brush = new SolidColorBrush(Tint) { Opacity = 0.35 + variation * 0.55 };
            brush.Freeze();
            context.DrawRoundedRectangle(brush, null, bar, Math.Min(2, barWidth / 2), Math.Min(2, barWidth / 2));
        }
    }
}

using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Macro.Core;

namespace Macro.Windows;

internal sealed class WorkflowCanvas : FrameworkElement
{
    private const double NodeWidth = 176, NodeHeight = 72;
    private readonly Typeface normal = new("Segoe UI"), semibold = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    private AutomationDefinition? workflow;
    private Guid? selectedNodeId, activeNodeId, draggingNodeId;
    private Point dragOrigin, panOrigin;
    private bool panning;
    private Vector pan = new(70, 50);
    private double zoom = 1;
    public event Action<AutomationNode?>? NodeSelected;
    public event Action? WorkflowChanged;

    public AutomationDefinition? Workflow { get => workflow; set { workflow = value; selectedNodeId = null; Fit(); InvalidateVisual(); } }
    public Guid? SelectedNodeId { get => selectedNodeId; set { selectedNodeId = value; InvalidateVisual(); } }
    public Guid? ActiveNodeId { get => activeNodeId; set { activeNodeId = value; InvalidateVisual(); } }

    public WorkflowCanvas() { Focusable = true; ClipToBounds = true; }

    public void Fit()
    {
        if (workflow is null || workflow.Nodes.Count == 0 || ActualWidth <= 0 || ActualHeight <= 0) { zoom = 1; pan = new(70, 50); return; }
        var minX = workflow.Nodes.Min(n => n.Position.X); var maxX = workflow.Nodes.Max(n => n.Position.X) + NodeWidth;
        var minY = workflow.Nodes.Min(n => n.Position.Y); var maxY = workflow.Nodes.Max(n => n.Position.Y) + NodeHeight;
        zoom = Math.Clamp(Math.Min((ActualWidth - 100) / Math.Max(1, maxX - minX), (ActualHeight - 100) / Math.Max(1, maxY - minY)), .45, 1.15);
        pan = new((ActualWidth - (minX + maxX) * zoom) / 2, (ActualHeight - (minY + maxY) * zoom) / 2);
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(new SolidColorBrush(C("07111C")), null, new Rect(RenderSize));
        DrawGrid(dc); if (workflow is null) { DrawEmpty(dc); return; }
        dc.PushTransform(new TranslateTransform(pan.X, pan.Y)); dc.PushTransform(new ScaleTransform(zoom, zoom));
        foreach (var section in workflow.Sections)
        {
            var r = new Rect(section.Frame.X, section.Frame.Y, section.Frame.Width, section.Frame.Height);
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(28, 42, 112, 196)), new Pen(new SolidColorBrush(Color.FromArgb(90, 63, 139, 230)), 1.2 / zoom), r, 14, 14);
            Text(dc, section.Title, new Point(r.X + 12, r.Y + 9), 12, Brushes.SlateGray, semibold);
        }
        foreach (var link in workflow.Connections) DrawConnection(dc, link);
        foreach (var node in workflow.Nodes) DrawNode(dc, node);
        dc.Pop(); dc.Pop();
    }

    private void DrawGrid(DrawingContext dc)
    {
        var brush = new SolidColorBrush(Color.FromArgb(38, 64, 99, 132));
        for (double x = pan.X % (28 * zoom); x < ActualWidth; x += 28 * zoom)
            for (double y = pan.Y % (28 * zoom); y < ActualHeight; y += 28 * zoom) dc.DrawEllipse(brush, null, new Point(x, y), 1, 1);
    }
    private void DrawEmpty(DrawingContext dc)
    { Text(dc, "Select or create a workflow", new Point(Math.Max(24, ActualWidth / 2 - 100), Math.Max(24, ActualHeight / 2)), 15, new SolidColorBrush(C("6F8498")), semibold); }
    private void DrawConnection(DrawingContext dc, AutomationConnection link)
    {
        var a = workflow!.Nodes.FirstOrDefault(n => n.Id == link.SourceNodeID); var b = workflow.Nodes.FirstOrDefault(n => n.Id == link.TargetNodeID); if (a is null || b is null) return;
        var start = new Point(a.Position.X + NodeWidth / 2, a.Position.Y + NodeHeight); var end = new Point(b.Position.X + NodeWidth / 2, b.Position.Y);
        if (link.Branch == AutomationBranch.Yes) start.X -= 38; if (link.Branch == AutomationBranch.No) start.X += 38;
        var color = link.Branch == AutomationBranch.Yes ? C("33C481") : link.Branch == AutomationBranch.No ? C("F06A79") : C("4C8DE8");
        var geometry = new StreamGeometry(); using (var ctx = geometry.Open()) { ctx.BeginFigure(start, false, false); var dy = Math.Max(44, Math.Abs(end.Y - start.Y) * .45); ctx.BezierTo(new(start.X, start.Y + dy), new(end.X, end.Y - dy), end, true, false); }
        dc.DrawGeometry(null, new Pen(new SolidColorBrush(color), 2.2 / zoom), geometry);
        dc.DrawEllipse(new SolidColorBrush(color), null, end, 4.2 / zoom, 4.2 / zoom);
        if (link.Branch is not null) Text(dc, link.Branch == AutomationBranch.Yes ? "YES" : "NO", new(start.X + 7, start.Y + 6), 9, new SolidColorBrush(color), semibold);
    }
    private void DrawNode(DrawingContext dc, AutomationNode node)
    {
        var r = Rect(node); var selected = node.Id == selectedNodeId; var active = node.Id == activeNodeId;
        var accent = KindColor(node.Kind); var fill = new SolidColorBrush(active ? C("0D392A") : selected ? C("102B48") : C("0E2133"));
        dc.DrawRoundedRectangle(fill, new Pen(new SolidColorBrush(active ? C("32D18B") : selected ? C("1785FF") : C("1E405C")), (selected || active ? 2 : 1) / zoom), r, 13, 13);
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(35, accent.R, accent.G, accent.B)), null, new Rect(r.X + 11, r.Y + 13, 36, 36), 9, 9);
        Text(dc, Glyph(node.Kind), new(r.X + 21, r.Y + 21), 15, new SolidColorBrush(accent), semibold);
        Text(dc, node.Title, new(r.X + 57, r.Y + 14), 13, Brushes.White, semibold);
        Text(dc, Detail(node), new(r.X + 57, r.Y + 38), 10.5, new SolidColorBrush(C("8CA1B5")), normal);
        dc.DrawEllipse(new SolidColorBrush(accent), null, new Point(r.X + NodeWidth / 2, r.Bottom), 5 / zoom, 5 / zoom);
        if (node.Kind != AutomationNodeKind.Start) dc.DrawEllipse(new SolidColorBrush(C("6F8498")), null, new Point(r.X + NodeWidth / 2, r.Top), 4 / zoom, 4 / zoom);
    }
    private string Detail(AutomationNode n) => n.Kind switch { AutomationNodeKind.Macro => n.MacroID is null ? "Choose a macro" : "Saved macro", AutomationNodeKind.Wait => $"{n.WaitDuration:0.##} seconds", AutomationNodeKind.RepeatFlow => n.RepeatInfinitely ? "Until stopped" : $"{n.RepeatCount} times", AutomationNodeKind.IfElse => n.ConditionKind.ToString(), _ => n.Kind.ToString() };
    private static string Glyph(AutomationNodeKind k) => k switch { AutomationNodeKind.Start => "▶", AutomationNodeKind.Stop => "■", AutomationNodeKind.Macro => "⚡", AutomationNodeKind.Wait => "◷", AutomationNodeKind.IfElse => "⑂", AutomationNodeKind.RepeatFlow => "↻", AutomationNodeKind.Schedule => "▣", _ => "◆" };
    private static Color KindColor(AutomationNodeKind k) => k switch { AutomationNodeKind.Start => C("35CB88"), AutomationNodeKind.Stop => C("F05C6B"), AutomationNodeKind.Macro => C("1785FF"), AutomationNodeKind.Wait or AutomationNodeKind.Schedule => C("F4A340"), AutomationNodeKind.IfElse => C("B16CFF"), _ => C("43BCD1") };
    private static Rect Rect(AutomationNode n) => new(n.Position.X, n.Position.Y, NodeWidth, NodeHeight);
    private Point Logical(Point p) => new((p.X - pan.X) / zoom, (p.Y - pan.Y) / zoom);

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        Focus(); CaptureMouse(); var p = e.GetPosition(this);
        if (e.ChangedButton is MouseButton.Middle or MouseButton.Right) { panning = true; panOrigin = p; e.Handled = true; return; }
        if (e.ChangedButton != MouseButton.Left || workflow is null) return;
        var logical = Logical(p); var node = workflow.Nodes.LastOrDefault(n => Rect(n).Contains(logical)); selectedNodeId = node?.Id; NodeSelected?.Invoke(node); InvalidateVisual();
        if (node is not null) { draggingNodeId = node.Id; dragOrigin = new(logical.X - node.Position.X, logical.Y - node.Position.Y); }
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        if (panning && e.MiddleButton == MouseButtonState.Pressed || panning && e.RightButton == MouseButtonState.Pressed) { pan += p - panOrigin; panOrigin = p; InvalidateVisual(); return; }
        if (draggingNodeId is null || e.LeftButton != MouseButtonState.Pressed || workflow is null) return;
        var q = Logical(p); var node = workflow.Nodes.First(n => n.Id == draggingNodeId); node.Position.X = Math.Max(0, q.X - dragOrigin.X); node.Position.Y = Math.Max(0, q.Y - dragOrigin.Y); InvalidateVisual();
    }
    protected override void OnMouseUp(MouseButtonEventArgs e) { if (draggingNodeId is not null) WorkflowChanged?.Invoke(); draggingNodeId = null; panning = false; ReleaseMouseCapture(); }
    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        var before = Logical(e.GetPosition(this)); zoom = Math.Clamp(zoom * (e.Delta > 0 ? 1.1 : .9), .4, 1.8); var p = e.GetPosition(this); pan = new(p.X - before.X * zoom, p.Y - before.Y * zoom); InvalidateVisual();
    }
    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo) { base.OnRenderSizeChanged(sizeInfo); if (sizeInfo.PreviousSize.Width == 0) Fit(); }
    private void Text(DrawingContext dc, string value, Point p, double size, Brush brush, Typeface face) => dc.DrawText(new FormattedText(value, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip), p);
    private static Color C(string hex) => (Color)ColorConverter.ConvertFromString("#" + hex);
}

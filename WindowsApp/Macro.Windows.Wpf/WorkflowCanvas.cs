using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Macro.Core;

namespace Macro.Windows;

internal sealed class WorkflowCanvas : FrameworkElement
{
    private const double NodeWidth = 220, NodeHeight = 76;
    private readonly Typeface normal = new("Segoe UI"), semibold = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    private AutomationDefinition? workflow;
    private Guid? selectedNodeId, activeNodeId, draggingNodeId;
    private AutomationNode? connectingSource;
    private AutomationBranch? connectingBranch;
    private Point connectionPointer;
    private Point dragOrigin, panOrigin;
    private bool panning;
    private Vector pan = new(70, 50);
    private double zoom = 1;
    public event Action<AutomationNode?>? NodeSelected;
    public event Action<AutomationNode, AutomationNode, AutomationBranch?>? ConnectionRequested;
    public event Action? WorkflowChanged;
    public Func<Guid?, string>? MacroDetailResolver { get; set; }
    public Func<Guid?, string>? MacroTitleResolver { get; set; }

    public AutomationDefinition? Workflow { get => workflow; set { workflow = value; selectedNodeId = null; Fit(); InvalidateVisual(); } }
    public Guid? SelectedNodeId { get => selectedNodeId; set { selectedNodeId = value; InvalidateVisual(); } }
    public Guid? ActiveNodeId { get => activeNodeId; set { activeNodeId = value; InvalidateVisual(); } }
    public double Zoom => zoom;

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

    public void ZoomBy(double factor)
    {
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        var before = Logical(center);
        zoom = Math.Clamp(zoom * factor, .4, 1.8);
        pan = new(center.X - before.X * zoom, center.Y - before.Y * zoom);
        InvalidateVisual();
    }

    public void ResetZoom()
    {
        zoom = 1;
        pan = new(70, 50);
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
        if (connectingSource is not null) DrawConnectionPreview(dc);
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
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(35, accent.R, accent.G, accent.B)), null, new Rect(r.X + 12, r.Y + 14, 38, 38), 9, 9);
        Text(dc, Glyph(node.Kind), new(r.X + 22, r.Y + 23), 15, new SolidColorBrush(accent), semibold);
        var title = node.Kind == AutomationNodeKind.Macro ? MacroTitleResolver?.Invoke(node.MacroID) ?? node.Title : node.Title;
        Text(dc, title, new(r.X + 62, r.Y + 15), 13, Brushes.White, semibold);
        Text(dc, Detail(node), new(r.X + 62, r.Y + 40), 10.5, new SolidColorBrush(C("8CA1B5")), normal);
        if (node.Kind == AutomationNodeKind.IfElse)
        {
            dc.DrawEllipse(new SolidColorBrush(C("33C481")), null, OutputPoint(node, AutomationBranch.Yes), 5 / zoom, 5 / zoom);
            dc.DrawEllipse(new SolidColorBrush(C("F06A79")), null, OutputPoint(node, AutomationBranch.No), 5 / zoom, 5 / zoom);
        }
        else if (node.Kind is not AutomationNodeKind.Stop and not AutomationNodeKind.Note)
            dc.DrawEllipse(new SolidColorBrush(accent), null, OutputPoint(node, null), 5 / zoom, 5 / zoom);
        if (node.Kind != AutomationNodeKind.Start) dc.DrawEllipse(new SolidColorBrush(C("6F8498")), null, new Point(r.X + NodeWidth / 2, r.Top), 4 / zoom, 4 / zoom);
    }
    private void DrawConnectionPreview(DrawingContext dc)
    {
        var start = OutputPoint(connectingSource!, connectingBranch);
        var color = connectingBranch == AutomationBranch.Yes ? C("33C481") : connectingBranch == AutomationBranch.No ? C("F06A79") : C("4C8DE8");
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(start, false, false);
            var distance = Math.Max(38, Math.Abs(connectionPointer.Y - start.Y) * .42);
            context.BezierTo(new Point(start.X, start.Y + distance), new Point(connectionPointer.X, connectionPointer.Y - distance), connectionPointer, true, false);
        }
        dc.DrawGeometry(null, new Pen(new SolidColorBrush(color), 2 / zoom) { DashStyle = DashStyles.Dash }, geometry);
        dc.DrawEllipse(new SolidColorBrush(color), null, connectionPointer, 5 / zoom, 5 / zoom);
    }
    private string Detail(AutomationNode n) => n.Kind switch { AutomationNodeKind.Macro => n.MacroID is null ? "Choose a macro" : MacroDetailResolver?.Invoke(n.MacroID) ?? "Saved macro", AutomationNodeKind.Wait => $"{n.WaitDuration:0.##} seconds", AutomationNodeKind.RepeatFlow => n.RepeatInfinitely ? "Until stopped" : $"{n.RepeatCount} times", AutomationNodeKind.IfElse => n.ConditionKind.ToString(), _ => n.Kind.ToString() };
    private static string Glyph(AutomationNodeKind k) => k switch { AutomationNodeKind.Start => "▶", AutomationNodeKind.Stop => "■", AutomationNodeKind.Macro => "⚡", AutomationNodeKind.Wait => "◷", AutomationNodeKind.IfElse => "⑂", AutomationNodeKind.RepeatFlow => "↻", AutomationNodeKind.Schedule => "▣", _ => "◆" };
    private static Color KindColor(AutomationNodeKind k) => k switch { AutomationNodeKind.Start => C("35CB88"), AutomationNodeKind.Stop => C("F05C6B"), AutomationNodeKind.Macro => C("1785FF"), AutomationNodeKind.Wait or AutomationNodeKind.Schedule => C("F4A340"), AutomationNodeKind.IfElse => C("B16CFF"), _ => C("43BCD1") };
    private static Rect Rect(AutomationNode n) => new(n.Position.X, n.Position.Y, NodeWidth, NodeHeight);
    private static Point OutputPoint(AutomationNode node, AutomationBranch? branch) => new(
        node.Position.X + NodeWidth / 2 + (branch == AutomationBranch.Yes ? -38 : branch == AutomationBranch.No ? 38 : 0),
        node.Position.Y + NodeHeight);
    private Point Logical(Point p) => new((p.X - pan.X) / zoom, (p.Y - pan.Y) / zoom);

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        Focus(); CaptureMouse(); var p = e.GetPosition(this);
        if (e.ChangedButton is MouseButton.Middle or MouseButton.Right) { panning = true; panOrigin = p; e.Handled = true; return; }
        if (e.ChangedButton != MouseButton.Left || workflow is null) return;
        var logical = Logical(p);
        foreach (var candidate in workflow.Nodes.AsEnumerable().Reverse())
        {
            if (!TryOutput(candidate, logical, out var branch)) continue;
            connectingSource = candidate; connectingBranch = branch; connectionPointer = logical;
            selectedNodeId = candidate.Id; NodeSelected?.Invoke(candidate); InvalidateVisual(); e.Handled = true; return;
        }
        var node = workflow.Nodes.LastOrDefault(n => Rect(n).Contains(logical)); selectedNodeId = node?.Id; NodeSelected?.Invoke(node); InvalidateVisual();
        if (node is not null) { draggingNodeId = node.Id; dragOrigin = new(logical.X - node.Position.X, logical.Y - node.Position.Y); }
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        if (panning && e.MiddleButton == MouseButtonState.Pressed || panning && e.RightButton == MouseButtonState.Pressed) { pan += p - panOrigin; panOrigin = p; InvalidateVisual(); return; }
        if (connectingSource is not null && e.LeftButton == MouseButtonState.Pressed) { connectionPointer = Logical(p); InvalidateVisual(); return; }
        if (draggingNodeId is null || e.LeftButton != MouseButtonState.Pressed || workflow is null) return;
        var q = Logical(p); var node = workflow.Nodes.First(n => n.Id == draggingNodeId); node.Position.X = Math.Max(0, q.X - dragOrigin.X); node.Position.Y = Math.Max(0, q.Y - dragOrigin.Y); InvalidateVisual();
    }
    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        if (connectingSource is not null && workflow is not null)
        {
            var target = workflow.Nodes.LastOrDefault(node => node.Id != connectingSource.Id && Rect(node).Contains(Logical(e.GetPosition(this))));
            if (target is not null) ConnectionRequested?.Invoke(connectingSource, target, connectingBranch);
            connectingSource = null; connectingBranch = null; InvalidateVisual();
        }
        if (draggingNodeId is not null) WorkflowChanged?.Invoke();
        draggingNodeId = null; panning = false; ReleaseMouseCapture();
    }
    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        var before = Logical(e.GetPosition(this)); zoom = Math.Clamp(zoom * (e.Delta > 0 ? 1.1 : .9), .4, 1.8); var p = e.GetPosition(this); pan = new(p.X - before.X * zoom, p.Y - before.Y * zoom); InvalidateVisual();
    }
    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo) { base.OnRenderSizeChanged(sizeInfo); if (sizeInfo.PreviousSize.Width == 0) Fit(); }
    private bool TryOutput(AutomationNode node, Point point, out AutomationBranch? branch)
    {
        branch = null;
        if (node.Kind is AutomationNodeKind.Stop or AutomationNodeKind.Note) return false;
        if (node.Kind == AutomationNodeKind.IfElse)
        {
            if ((point - OutputPoint(node, AutomationBranch.Yes)).Length <= 14) { branch = AutomationBranch.Yes; return true; }
            if ((point - OutputPoint(node, AutomationBranch.No)).Length <= 14) { branch = AutomationBranch.No; return true; }
            return false;
        }
        return (point - OutputPoint(node, null)).Length <= 14;
    }
    private void Text(DrawingContext dc, string value, Point p, double size, Brush brush, Typeface face) => dc.DrawText(new FormattedText(value, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip), p);
    private static Color C(string hex) => (Color)ColorConverter.ConvertFromString("#" + hex);
}

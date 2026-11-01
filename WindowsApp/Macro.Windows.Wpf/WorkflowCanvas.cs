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
    private readonly HashSet<Guid> selectedNodeIds = [];
    private readonly Dictionary<Guid, Point> dragNodeOrigins = [];
    private AutomationNode? connectingSource;
    private AutomationBranch? connectingBranch;
    private Point connectionPointer;
    private Point dragPointerOrigin, panOrigin, marqueeStart, marqueeCurrent;
    private double? alignmentGuideX, alignmentGuideY;
    private bool panning, marqueeSelecting;
    private bool fitOnResize = true;
    public bool PanToolActive { get; set; }
    private Vector pan = new(70, 50);
    private double zoom = 1;
    public event Action<AutomationNode?>? NodeSelected;
    public event Action<AutomationNode>? NodeContextRequested;
    public event Action<AutomationNode, AutomationNode, AutomationBranch?>? ConnectionRequested;
    public event Action? WorkflowChanged;
    public Func<Guid?, string>? MacroDetailResolver { get; set; }
    public Func<Guid?, string>? MacroTitleResolver { get; set; }
    public Color CanvasColor { get; set; } = C("07111C");
    public Color GridColor { get; set; } = C("406384");

    public AutomationDefinition? Workflow { get => workflow; set { workflow = value; selectedNodeId = null; selectedNodeIds.Clear(); alignmentGuideX = alignmentGuideY = null; Fit(); InvalidateVisual(); } }
    public Guid? SelectedNodeId
    {
        get => selectedNodeId;
        set
        {
            // NodeSelected is echoed through MainWindow.SelectNode. Preserve an
            // existing marquee selection when that echo names its active node.
            if (value == selectedNodeId && value is { } current && selectedNodeIds.Contains(current)) { InvalidateVisual(); return; }
            selectedNodeId = value; selectedNodeIds.Clear(); if (value is { } id) selectedNodeIds.Add(id); InvalidateVisual();
        }
    }
    public Guid? ActiveNodeId { get => activeNodeId; set { activeNodeId = value; InvalidateVisual(); } }
    public double Zoom => zoom;
    public Point GetLogicalPoint(Point point) => Logical(point);

    public WorkflowCanvas() { Focusable = true; ClipToBounds = true; }

    public void Fit(double? availableWidth = null, double? availableHeight = null)
    {
        fitOnResize = true;
        var width = availableWidth ?? ActualWidth;
        var height = availableHeight ?? ActualHeight;
        if (workflow is null || workflow.Nodes.Count == 0 || width <= 0 || height <= 0) { zoom = 1; pan = new(70, 50); return; }
        var minX = workflow.Nodes.Min(n => n.Position.X); var maxX = workflow.Nodes.Max(n => n.Position.X) + NodeWidth;
        var minY = workflow.Nodes.Min(n => n.Position.Y); var maxY = workflow.Nodes.Max(n => n.Position.Y) + NodeHeight;
        zoom = Math.Clamp(Math.Min((width - 100) / Math.Max(1, maxX - minX), (height - 100) / Math.Max(1, maxY - minY)), .45, 1.15);
        pan = new((width - (minX + maxX) * zoom) / 2, (height - (minY + maxY) * zoom) / 2);
        InvalidateVisual();
    }

    public void FitForCapture(double width, double height)
    {
        Fit(width, height);
        fitOnResize = false;
    }

    public void ZoomBy(double factor)
    {
        fitOnResize = false;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        var before = Logical(center);
        zoom = Math.Clamp(zoom * factor, .4, 1.8);
        pan = new(center.X - before.X * zoom, center.Y - before.Y * zoom);
        InvalidateVisual();
    }

    public void ResetZoom()
    {
        fitOnResize = false;
        zoom = 1;
        pan = new(70, 50);
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(new SolidColorBrush(CanvasColor), null, new Rect(RenderSize));
        DrawGrid(dc); if (workflow is null) { DrawEmpty(dc); return; }
        dc.PushTransform(new TranslateTransform(pan.X, pan.Y)); dc.PushTransform(new ScaleTransform(zoom, zoom));
        foreach (var section in workflow.Sections)
        {
            var r = new Rect(section.Frame.X, section.Frame.Y, section.Frame.Width, section.Frame.Height);
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(28, 42, 112, 196)), new Pen(new SolidColorBrush(Color.FromArgb(90, 63, 139, 230)), 1.2 / zoom), r, 14, 14);
            Text(dc, section.Title, new Point(r.X + 12, r.Y + 9), 12, Brushes.SlateGray, semibold);
        }
        foreach (var node in workflow.Nodes.Where(n => n.Kind == AutomationNodeKind.RepeatFlow && n.RepeatTargetNodeID is not null))
            DrawLoopReference(dc, node, node.RepeatTargetNodeID!.Value, C("B16CFF"));
        foreach (var node in workflow.Nodes.Where(n => n.Kind == AutomationNodeKind.LoopBack && n.JumpTargetNodeID is not null))
            DrawLoopReference(dc, node, node.JumpTargetNodeID!.Value, C("43BCD1"));
        foreach (var link in workflow.Connections) DrawConnection(dc, link);
        if (connectingSource is not null) DrawConnectionPreview(dc);
        foreach (var node in workflow.Nodes) DrawNode(dc, node);
        DrawAlignmentGuides(dc);
        DrawMarquee(dc);
        dc.Pop(); dc.Pop();
    }

    private void DrawGrid(DrawingContext dc)
    {
        var brush = new SolidColorBrush(Color.FromArgb(38, GridColor.R, GridColor.G, GridColor.B));
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
        DrawRoutedWire(dc, start, end, color, false);
        dc.DrawEllipse(new SolidColorBrush(color), null, end, 4.2 / zoom, 4.2 / zoom);
        if (link.Branch is not null) Text(dc, link.Branch == AutomationBranch.Yes ? "YES" : "NO", new(start.X + 7, start.Y + 6), 9, new SolidColorBrush(color), semibold);
    }

    private void DrawLoopReference(DrawingContext dc, AutomationNode source, Guid targetId, Color color)
    {
        var target = workflow!.Nodes.FirstOrDefault(n => n.Id == targetId);
        if (target is null) return;
        var start = new Point(source.Position.X + NodeWidth, source.Position.Y + NodeHeight / 2);
        var end = new Point(target.Position.X + NodeWidth, target.Position.Y + NodeHeight / 2);
        DrawRoutedWire(dc, start, end, color, true);
        dc.DrawEllipse(new SolidColorBrush(CanvasColor), new Pen(new SolidColorBrush(color), 2.2 / zoom), start, 5 / zoom, 5 / zoom);
        dc.DrawEllipse(new SolidColorBrush(CanvasColor), new Pen(new SolidColorBrush(color), 2.2 / zoom), end, 5 / zoom, 5 / zoom);
    }

    private void DrawRoutedWire(DrawingContext dc, Point start, Point end, Color color, bool sidePorts)
    {
        const double stub = 24;
        var startStub = sidePorts ? new Point(start.X + stub, start.Y) : new Point(start.X, start.Y + stub);
        var endStub = sidePorts ? new Point(end.X + stub, end.Y) : new Point(end.X, end.Y - stub);
        var points = new List<Point> { start };
        points.AddRange(RouteWire(startStub, endStub));
        points.Add(end);
        points = Simplify(points);

        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(points[0], false, false);
            context.PolyLineTo(points.Skip(1).ToList(), true, false);
        }
        dc.DrawGeometry(null, new Pen(new SolidColorBrush(color), 2.2 / zoom) { LineJoin = PenLineJoin.Round }, geometry);
    }

    private List<Point> RouteWire(Point start, Point end)
    {
        if (workflow is null) return [start, end];
        var obstacles = workflow.Nodes.Select(NodeObstacle).ToList();
        var xChannels = Unique([start.X, end.X, (start.X + end.X) / 2, .. obstacles.SelectMany(r => new[] { r.Left - 12, r.Right + 12 })]);
        var yChannels = Unique([start.Y, end.Y, (start.Y + end.Y) / 2, .. obstacles.SelectMany(r => new[] { r.Top - 12, r.Bottom + 12 })]);
        var candidates = new List<List<Point>>();
        foreach (var x in xChannels) candidates.Add([start, new(x, start.Y), new(x, end.Y), end]);
        foreach (var y in yChannels) candidates.Add([start, new(start.X, y), new(end.X, y), end]);
        foreach (var x in xChannels)
        foreach (var y in yChannels)
        {
            candidates.Add([start, new(x, start.Y), new(x, y), new(end.X, y), end]);
            candidates.Add([start, new(start.X, y), new(x, y), new(x, end.Y), end]);
        }

        var valid = candidates.Select(Simplify)
            .Where(points => points.Zip(points.Skip(1)).All(pair => !SegmentIntersects(pair.First, pair.Second, obstacles)))
            .OrderBy(RouteCost)
            .FirstOrDefault();
        if (valid is not null) return valid;

        var outerX = obstacles.Count == 0 ? Math.Max(start.X, end.X) + 40 : obstacles.Max(r => r.Right) + 40;
        return [start, new(outerX, start.Y), new(outerX, end.Y), end];
    }

    private static Rect NodeObstacle(AutomationNode node)
    {
        const double clearance = 6;
        return new Rect(node.Position.X - clearance, node.Position.Y - clearance, NodeWidth + clearance * 2, NodeHeight + clearance * 2);
    }

    private static List<double> Unique(IEnumerable<double> values)
    {
        var result = new List<double>();
        foreach (var value in values.OrderBy(value => value))
            if (result.Count == 0 || Math.Abs(result[^1] - value) > .5) result.Add(value);
        return result;
    }

    private static List<Point> Simplify(IEnumerable<Point> values)
    {
        var result = new List<Point>();
        foreach (var point in values)
        {
            if (result.Count == 0 || (result[^1] - point).Length > .5) result.Add(point);
            while (result.Count >= 3)
            {
                var a = result[^3]; var b = result[^2]; var c = result[^1];
                if (Math.Abs(a.X - b.X) < .5 && Math.Abs(b.X - c.X) < .5 || Math.Abs(a.Y - b.Y) < .5 && Math.Abs(b.Y - c.Y) < .5)
                    result.RemoveAt(result.Count - 2);
                else break;
            }
        }
        return result;
    }

    private static double RouteCost(IReadOnlyList<Point> points) =>
        points.Zip(points.Skip(1)).Sum(pair => Math.Abs(pair.Second.X - pair.First.X) + Math.Abs(pair.Second.Y - pair.First.Y)) + Math.Max(0, points.Count - 2) * 18;

    private static bool SegmentIntersects(Point start, Point end, IReadOnlyList<Rect> obstacles) => obstacles.Any(rect =>
        Math.Abs(start.Y - end.Y) < .5
            ? start.Y > rect.Top && start.Y < rect.Bottom && Math.Max(start.X, end.X) > rect.Left && Math.Min(start.X, end.X) < rect.Right
            : Math.Abs(start.X - end.X) < .5
                ? start.X > rect.Left && start.X < rect.Right && Math.Max(start.Y, end.Y) > rect.Top && Math.Min(start.Y, end.Y) < rect.Bottom
                : true);
    private void DrawNode(DrawingContext dc, AutomationNode node)
    {
        dc.PushOpacity(node.IsEnabled ? 1 : .45);
        var r = Rect(node); var selected = selectedNodeIds.Contains(node.Id) || node.Id == selectedNodeId; var active = node.Id == activeNodeId;
        var accent = KindColor(node.Kind);
        var baseColor = node.Kind switch { AutomationNodeKind.Start => C("102E29"), AutomationNodeKind.Stop => C("29202D"), AutomationNodeKind.RepeatFlow => C("1D2943"), _ => C("102B40") };
        var fill = new SolidColorBrush(active ? C("0D392A") : selected ? C("173C59") : baseColor);
        dc.DrawRoundedRectangle(fill, new Pen(new SolidColorBrush(active ? C("32D18B") : selected ? C("1785FF") : Color.FromArgb(62, accent.R, accent.G, accent.B)), (selected || active ? 2 : 1) / zoom), r, 13, 13);
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(35, accent.R, accent.G, accent.B)), null, new Rect(r.X + 12, r.Y + 14, 38, 38), 9, 9);
        Text(dc, Glyph(node.Kind), new(r.X + 22, r.Y + 23), 15, new SolidColorBrush(accent), semibold);
        var title = node.Kind == AutomationNodeKind.Macro ? MacroTitleResolver?.Invoke(node.MacroID) ?? node.Title : node.Title;
        Text(dc, ShortText(title, 22), new(r.X + 62, r.Y + 15), 13, Brushes.White, semibold);
        Text(dc, ShortText(Detail(node), 25), new(r.X + 62, r.Y + 40), 10.5, new SolidColorBrush(C("8CA1B5")), normal);
        if (node.Kind == AutomationNodeKind.IfElse)
        {
            dc.DrawEllipse(new SolidColorBrush(C("33C481")), null, OutputPoint(node, AutomationBranch.Yes), 5 / zoom, 5 / zoom);
            dc.DrawEllipse(new SolidColorBrush(C("F06A79")), null, OutputPoint(node, AutomationBranch.No), 5 / zoom, 5 / zoom);
        }
        else if (node.Kind is not AutomationNodeKind.Stop and not AutomationNodeKind.Note)
            dc.DrawEllipse(new SolidColorBrush(accent), null, OutputPoint(node, null), 5 / zoom, 5 / zoom);
        if (node.Kind != AutomationNodeKind.Start) dc.DrawEllipse(new SolidColorBrush(C("6F8498")), null, new Point(r.X + NodeWidth / 2, r.Top), 4 / zoom, 4 / zoom);
        if (node.Kind is AutomationNodeKind.RepeatFlow or AutomationNodeKind.LoopBack)
            dc.DrawEllipse(new SolidColorBrush(CanvasColor), new Pen(new SolidColorBrush(node.Kind == AutomationNodeKind.RepeatFlow ? C("B16CFF") : C("43BCD1")), 2.2 / zoom), new Point(r.Right, r.Top + NodeHeight / 2), 5 / zoom, 5 / zoom);
        dc.Pop();
    }

    private void DrawAlignmentGuides(DrawingContext dc)
    {
        if (draggingNodeId is null) return;
        var pen = new Pen(new SolidColorBrush(C("1785FF")), Math.Max(.75, 1 / zoom));
        var left = -pan.X / zoom; var right = (ActualWidth - pan.X) / zoom;
        var top = -pan.Y / zoom; var bottom = (ActualHeight - pan.Y) / zoom;
        if (alignmentGuideX is double x) dc.DrawLine(pen, new Point(x, top), new Point(x, bottom));
        if (alignmentGuideY is double y) dc.DrawLine(pen, new Point(left, y), new Point(right, y));
    }
    private void DrawMarquee(DrawingContext dc)
    {
        if (!marqueeSelecting) return;
        var rect = NormalizedRect(marqueeStart, marqueeCurrent);
        var pen = new Pen(new SolidColorBrush(C("4C9CFF")), 1.2 / zoom) { DashStyle = DashStyles.Dash };
        dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(35, 76, 156, 255)), pen, rect);
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
        Focus(); var p = e.GetPosition(this);
        if (e.ChangedButton == MouseButton.Right && workflow is not null)
        {
            var contextNode = workflow.Nodes.LastOrDefault(n => Rect(n).Contains(Logical(p)));
            if (contextNode is not null)
            {
                selectedNodeId = contextNode.Id;
                selectedNodeIds.Clear(); selectedNodeIds.Add(contextNode.Id);
                NodeSelected?.Invoke(contextNode);
                NodeContextRequested?.Invoke(contextNode);
                InvalidateVisual();
                e.Handled = true;
                return;
            }
        }
        CaptureMouse();
        if (e.ChangedButton is MouseButton.Middle or MouseButton.Right || e.ChangedButton == MouseButton.Left && PanToolActive) { fitOnResize = false; panning = true; panOrigin = p; e.Handled = true; return; }
        if (e.ChangedButton != MouseButton.Left || workflow is null) return;
        var logical = Logical(p);
        foreach (var candidate in workflow.Nodes.AsEnumerable().Reverse())
        {
            if (!TryOutput(candidate, logical, out var branch)) continue;
            connectingSource = candidate; connectingBranch = branch; connectionPointer = logical;
            selectedNodeId = candidate.Id; selectedNodeIds.Clear(); selectedNodeIds.Add(candidate.Id); NodeSelected?.Invoke(candidate); InvalidateVisual(); e.Handled = true; return;
        }
        var node = workflow.Nodes.LastOrDefault(n => Rect(n).Contains(logical));
        if (node is null)
        {
            selectedNodeId = null; selectedNodeIds.Clear(); NodeSelected?.Invoke(null);
            marqueeSelecting = true; marqueeStart = marqueeCurrent = logical;
            InvalidateVisual(); e.Handled = true; return;
        }
        var additive = Keyboard.Modifiers.HasFlag(ModifierKeys.Control) || Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (additive)
        {
            if (!selectedNodeIds.Add(node.Id)) selectedNodeIds.Remove(node.Id);
            if (!selectedNodeIds.Contains(node.Id)) { selectedNodeId = selectedNodeIds.Count > 0 ? selectedNodeIds.Last() : null; NodeSelected?.Invoke(workflow.Nodes.FirstOrDefault(n => n.Id == selectedNodeId)); InvalidateVisual(); return; }
        }
        else if (!selectedNodeIds.Contains(node.Id)) { selectedNodeIds.Clear(); selectedNodeIds.Add(node.Id); }
        selectedNodeId = node.Id; NodeSelected?.Invoke(node); InvalidateVisual();
        draggingNodeId = node.Id; dragPointerOrigin = logical;
        dragNodeOrigins.Clear();
        foreach (var selected in workflow.Nodes.Where(n => selectedNodeIds.Contains(n.Id))) dragNodeOrigins[selected.Id] = new Point(selected.Position.X, selected.Position.Y);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        if (panning && (e.MiddleButton == MouseButtonState.Pressed || e.RightButton == MouseButtonState.Pressed || PanToolActive && e.LeftButton == MouseButtonState.Pressed)) { pan += p - panOrigin; panOrigin = p; InvalidateVisual(); return; }
        if (connectingSource is not null && e.LeftButton == MouseButtonState.Pressed) { connectionPointer = Logical(p); InvalidateVisual(); return; }
        if (marqueeSelecting && e.LeftButton == MouseButtonState.Pressed && workflow is not null)
        {
            marqueeCurrent = Logical(p);
            var marquee = NormalizedRect(marqueeStart, marqueeCurrent);
            selectedNodeIds.Clear();
            foreach (var node in workflow.Nodes.Where(node => marquee.IntersectsWith(Rect(node)))) selectedNodeIds.Add(node.Id);
            InvalidateVisual(); return;
        }
        if (draggingNodeId is null || e.LeftButton != MouseButtonState.Pressed || workflow is null) return;
        var delta = Logical(p) - dragPointerOrigin;
        var snappedDelta = SnapSelection(delta);
        foreach (var node in workflow.Nodes.Where(n => dragNodeOrigins.ContainsKey(n.Id)))
        {
            var origin = dragNodeOrigins[node.Id];
            node.Position.X = origin.X + snappedDelta.X; node.Position.Y = origin.Y + snappedDelta.Y;
        }
        InvalidateVisual();
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
        if (marqueeSelecting && workflow is not null)
        {
            selectedNodeId = selectedNodeIds.Count > 0 ? selectedNodeIds.Last() : null;
            NodeSelected?.Invoke(workflow.Nodes.FirstOrDefault(node => node.Id == selectedNodeId));
        }
        alignmentGuideX = alignmentGuideY = null;
        draggingNodeId = null; dragNodeOrigins.Clear(); marqueeSelecting = false; panning = false; ReleaseMouseCapture(); InvalidateVisual();
    }
    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        fitOnResize = false; var before = Logical(e.GetPosition(this)); zoom = Math.Clamp(zoom * (e.Delta > 0 ? 1.1 : .9), .4, 1.8); var p = e.GetPosition(this); pan = new(p.X - before.X * zoom, p.Y - before.Y * zoom); InvalidateVisual();
    }
    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo) { base.OnRenderSizeChanged(sizeInfo); if (fitOnResize) Fit(); }
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

    private Vector SnapSelection(Vector proposedDelta)
    {
        alignmentGuideX = alignmentGuideY = null;
        if (workflow is null || dragNodeOrigins.Count == 0 || Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) return proposedDelta;
        var movingRects = workflow.Nodes.Where(node => dragNodeOrigins.ContainsKey(node.Id)).Select(node =>
        {
            var origin = dragNodeOrigins[node.Id];
            return new Rect(origin.X + proposedDelta.X, origin.Y + proposedDelta.Y, NodeWidth, NodeHeight);
        }).ToList();
        var others = workflow.Nodes.Where(node => !dragNodeOrigins.ContainsKey(node.Id)).Select(Rect).ToList();
        if (others.Count == 0) return proposedDelta;
        var threshold = 8 / Math.Max(.25, zoom);
        var movingX = movingRects.SelectMany(rect => new[] { rect.Left, rect.Left + rect.Width / 2, rect.Right });
        var movingY = movingRects.SelectMany(rect => new[] { rect.Top, rect.Top + rect.Height / 2, rect.Bottom });
        var xSnap = ClosestSnap(movingX, others.SelectMany(rect => new[] { rect.Left, rect.Left + rect.Width / 2, rect.Right }), threshold);
        var ySnap = ClosestSnap(movingY, others.SelectMany(rect => new[] { rect.Top, rect.Top + rect.Height / 2, rect.Bottom }), threshold);
        alignmentGuideX = xSnap?.Guide; alignmentGuideY = ySnap?.Guide;
        return new Vector(proposedDelta.X + (xSnap?.Adjustment ?? 0), proposedDelta.Y + (ySnap?.Adjustment ?? 0));
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key != Key.Delete && e.Key != Key.Back || workflow is null || selectedNodeIds.Count == 0) return;
        var removable = selectedNodeIds.Where(id => workflow.Nodes.Any(node => node.Id == id && node.Kind != AutomationNodeKind.Start)).ToHashSet();
        if (removable.Count == 0) return;
        workflow.Nodes.RemoveAll(node => removable.Contains(node.Id));
        workflow.Connections.RemoveAll(link => removable.Contains(link.SourceNodeID) || removable.Contains(link.TargetNodeID));
        foreach (var node in workflow.Nodes)
        {
            if (node.RepeatTargetNodeID is { } repeat && removable.Contains(repeat)) node.RepeatTargetNodeID = null;
            if (node.JumpTargetNodeID is { } jump && removable.Contains(jump)) node.JumpTargetNodeID = null;
        }
        selectedNodeIds.Clear(); selectedNodeId = null; NodeSelected?.Invoke(null); WorkflowChanged?.Invoke(); InvalidateVisual(); e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        alignmentGuideX = alignmentGuideY = null;
        if (Mouse.LeftButton != MouseButtonState.Pressed)
        {
            draggingNodeId = null; dragNodeOrigins.Clear(); marqueeSelecting = false; panning = false; InvalidateVisual();
        }
    }

    private static Rect NormalizedRect(Point a, Point b) => new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));

    private static (double Adjustment, double Guide)? ClosestSnap(IEnumerable<double> moving, IEnumerable<double> targets, double threshold)
    {
        (double Adjustment, double Guide)? best = null;
        foreach (var movingValue in moving)
        foreach (var target in targets)
        {
            var adjustment = target - movingValue;
            if (Math.Abs(adjustment) > threshold || best is not null && Math.Abs(adjustment) >= Math.Abs(best.Value.Adjustment)) continue;
            best = (adjustment, target);
        }
        return best;
    }
    private void Text(DrawingContext dc, string value, Point p, double size, Brush brush, Typeface face) => dc.DrawText(new FormattedText(value, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip), p);
    private static Color C(string hex) => (Color)ColorConverter.ConvertFromString("#" + hex);
    private static string ShortText(string value, int max) => value.Length <= max ? value : value[..Math.Max(1, max - 1)] + "…";
}

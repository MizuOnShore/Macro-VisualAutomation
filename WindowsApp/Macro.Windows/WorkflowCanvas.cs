using Macro.Core;

namespace Macro.Windows;

internal sealed class WorkflowCanvas : ScrollableControl
{
    private const int NodeWidth = 150, NodeHeight = 58;
    private AutomationDefinition? workflow;
    private Guid? selectedId, activeId, draggingId;
    private Point dragOffset;
    public event Action<Guid?>? NodeSelected;
    public event Action? WorkflowChanged;
    public AutomationDefinition? Workflow { get => workflow; set { workflow = value; Invalidate(); } }
    public Guid? SelectedNodeId { get => selectedId; set { selectedId = value; Invalidate(); } }
    public Guid? ActiveNodeId { get => activeId; set { activeId = value; Invalidate(); } }

    public WorkflowCanvas()
    {
        DoubleBuffered = true; AutoScroll = true; BackColor = Color.FromArgb(246, 247, 250);
        SetStyle(ControlStyles.ResizeRedraw, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e); if (workflow is null) return;
        e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var gridPen = new Pen(Color.FromArgb(225, 228, 234));
        for (var x = 0; x < Width; x += 24) for (var y = 0; y < Height; y += 24) e.Graphics.DrawEllipse(gridPen, x, y, 1, 1);
        foreach (var c in workflow.Connections)
        {
            var source = workflow.Nodes.FirstOrDefault(n => n.Id == c.SourceNodeID);
            var target = workflow.Nodes.FirstOrDefault(n => n.Id == c.TargetNodeID);
            if (source is null || target is null) continue;
            var a = Center(source); var b = Center(target);
            using var pen = new Pen(c.Branch == AutomationBranch.Yes ? Color.SeaGreen : c.Branch == AutomationBranch.No ? Color.IndianRed : Color.SlateGray, 2);
            var midY = (a.Y + b.Y) / 2;
            e.Graphics.DrawLines(pen, new Point[] { new(a.X, a.Y + NodeHeight / 2), new(a.X, midY), new(b.X, midY), new(b.X, b.Y - NodeHeight / 2) });
            if (c.Branch is not null) e.Graphics.DrawString(c.Branch.ToString(), Font, Brushes.DimGray, a.X + 5, a.Y + NodeHeight / 2 + 2);
        }
        foreach (var n in workflow.Nodes)
        {
            var rect = Rect(n);
            var fill = n.Id == activeId ? Color.FromArgb(209, 239, 220) : n.Id == selectedId ? Color.FromArgb(215, 229, 252) : Color.White;
            using var brush = new SolidBrush(fill); using var border = new Pen(n.Id == activeId ? Color.SeaGreen : n.Id == selectedId ? Color.RoyalBlue : Color.FromArgb(180, 185, 194), n.Id == selectedId ? 2 : 1);
            e.Graphics.FillRoundedRectangle(brush, rect, 8); e.Graphics.DrawRoundedRectangle(border, rect, 8);
            using var titleFont = new Font(Font, FontStyle.Bold);
            e.Graphics.DrawString(n.Title, titleFont, Brushes.Black, rect.X + 10, rect.Y + 8);
            var detail = n.Kind == AutomationNodeKind.Macro ? "Saved macro" : n.Kind == AutomationNodeKind.Wait ? $"{n.WaitDuration:0.##} seconds" : n.Kind.ToString();
            e.Graphics.DrawString(detail, Font, Brushes.DimGray, rect.X + 10, rect.Y + 32);
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e); if (workflow is null) return;
        var node = workflow.Nodes.LastOrDefault(n => Rect(n).Contains(e.Location));
        selectedId = node?.Id; NodeSelected?.Invoke(selectedId); Invalidate();
        if (node is not null && e.Button == MouseButtons.Left)
        { draggingId = node.Id; dragOffset = new(e.X - (int)node.Position.X, e.Y - (int)node.Position.Y); }
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e); if (workflow is null || draggingId is null || e.Button != MouseButtons.Left) return;
        var node = workflow.Nodes.First(n => n.Id == draggingId);
        node.Position.X = Math.Max(0, e.X - dragOffset.X); node.Position.Y = Math.Max(0, e.Y - dragOffset.Y); Invalidate();
    }
    protected override void OnMouseUp(MouseEventArgs e)
    { base.OnMouseUp(e); if (draggingId is not null) WorkflowChanged?.Invoke(); draggingId = null; }

    private static Rectangle Rect(AutomationNode n) => new((int)n.Position.X, (int)n.Position.Y, NodeWidth, NodeHeight);
    private static Point Center(AutomationNode n) => new((int)n.Position.X + NodeWidth / 2, (int)n.Position.Y + NodeHeight / 2);
}

internal static class GraphicsExtensions
{
    internal static void FillRoundedRectangle(this Graphics g, Brush brush, Rectangle r, int radius)
    { using var path = Rounded(r, radius); g.FillPath(brush, path); }
    internal static void DrawRoundedRectangle(this Graphics g, Pen pen, Rectangle r, int radius)
    { using var path = Rounded(r, radius); g.DrawPath(pen, path); }
    private static System.Drawing.Drawing2D.GraphicsPath Rounded(Rectangle r, int radius)
    {
        var d = radius * 2; var p = new System.Drawing.Drawing2D.GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 180, 90); p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
    }
}

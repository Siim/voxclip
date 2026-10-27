using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class TimelineIntervalIndex
{
    private sealed record Node(double Centre, TimedWord[] Starts, TimedWord[] Ends, Node? Left, Node? Right);
    private readonly Node? root;
    internal IReadOnlyList<TimedWord> Words { get; }
    internal int VisitedWords { get; private set; }
    internal TimelineIntervalIndex(IReadOnlyList<TimedWord> words)
    {
        Words = words.Where(word => word.Start < word.End).OrderBy(word => word.Start).ToArray();
        root = Build(Words);
    }
    private static Node? Build(IReadOnlyList<TimedWord> words)
    {
        if (words.Count == 0) return null;
        var centre = words[words.Count / 2].Start;
        var left = new List<TimedWord>();
        var right = new List<TimedWord>();
        var crossing = new List<TimedWord>();
        foreach (var word in words)
        {
            if (word.End <= centre) left.Add(word);
            else if (word.Start > centre) right.Add(word);
            else crossing.Add(word);
        }
        return new(centre, crossing.ToArray(), crossing.OrderByDescending(word => word.End).ToArray(), Build(left), Build(right));
    }
    internal void Query(double start, double end, Action<TimedWord> visit)
    {
        VisitedWords = 0;
        if (start < end) Query(root, start, end, visit);
    }
    private void Query(Node? node, double start, double end, Action<TimedWord> visit)
    {
        if (node is null) return;
        if (end <= node.Centre)
        {
            foreach (var word in node.Starts)
            {
                VisitedWords++;
                if (word.Start >= end) break;
                visit(word);
            }
            Query(node.Left, start, end, visit);
        }
        else if (start >= node.Centre)
        {
            foreach (var word in node.Ends)
            {
                VisitedWords++;
                if (word.End <= start) break;
                visit(word);
            }
            Query(node.Right, start, end, visit);
        }
        else
        {
            foreach (var word in node.Starts) { VisitedWords++; visit(word); }
            Query(node.Left, start, end, visit);
            Query(node.Right, start, end, visit);
        }
    }
}

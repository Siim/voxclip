using System.Text;

namespace VoxClip.Core.Domain.Clips;

internal sealed record ClipWindow(IReadOnlyList<NumberedLine> Lines, int WordCount, int EstimatedTokens, int Budget);

internal static class ClipWindowing
{
    internal static int Estimate(string? text, double bytesPerToken = 2.2) => (int)Math.Ceiling(Encoding.UTF8.GetByteCount(text ?? "") / bytesPerToken);
    internal static IReadOnlyList<ClipWindow> Pack(IReadOnlyList<NumberedLine> lines, int budget, int maxWords, double overlapSeconds, double bytesPerToken = 2.2)
    {
        if (budget < 600) throw new ArgumentOutOfRangeException(nameof(budget));
        var windows = new List<ClipWindow>();
        var first = 0;
        while (first < lines.Count)
        {
            var end = first;
            var cost = 0;
            var wordCount = 0;
            while (end < lines.Count)
            {
                var line = lines[end];
                var words = line.LastPosition - line.FirstPosition + 1;
                var tokens = Estimate(line.Line.Text + "\n", bytesPerToken) + (line.PauseAfter is null ? 0 : Estimate(line.PauseAfter + "\n", bytesPerToken));
                if (end > first && (cost + tokens > budget || wordCount + words > maxWords)) break;
                cost += tokens;
                wordCount += words;
                end++;
            }
            windows.Add(new(lines.Skip(first).Take(end - first).ToArray(), wordCount, cost, budget));
            if (end == lines.Count) break;
            if (overlapSeconds == 0) { first = end; continue; }
            var threshold = lines[end - 1].Line.End - overlapSeconds;
            var next = first + 1;
            while (next < end && lines[next].Line.Start < threshold) next++;
            first = next;
        }
        return windows;
    }
}

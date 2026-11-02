using System.Text;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The clip, Full take or inclusive transcript selection a Rewrite acts on. Scope planning refuses selections.</summary>
public sealed record RewriteScope(string? ClipId = null, int? First = null, int? Last = null)
{
    public static RewriteScope FullTake { get; } = new();
    public static RewriteScope Clip(string id) => new(id);
    public static RewriteScope Selection(int first, int last) => new(null, first, last);
}
public enum ScopeRewritePlanErrorCode { TooManyEntries, TooMuchText, Empty, InvalidInput }
public sealed class ScopeRewritePlanException(ScopeRewritePlanErrorCode code, int? count = null, int? bytes = null) : Exception(code.ToString())
{
    public ScopeRewritePlanErrorCode Code { get; } = code;
    public int? Count { get; } = count;
    public int? Bytes { get; } = bytes;
}
/// <summary>Pure Fix with AI scope request and line budgets; voice-lab §8.1 and §8.9.1.</summary>
public sealed record ScopeRewritePlan(RewriteScope Scope, IReadOnlyList<ScopeRewritePlan.Line> Lines, PatchRewriteRequest Request)
{
    public enum RangeSource { Window, LineSpan, NoSpeech }
    public sealed record Line(string Label, IReadOnlyList<TimedWord> Items, IReadOnlyList<ClipWord> Entries,
        IReadOnlyList<bool> RevoicedBefore, int MinChars, int MaxChars, RangeSource Source)
    {
        public IReadOnlyList<string> ItemIds => Items.Select(item => item.Id).ToArray();
    }
    public const int MaxEntries = 3000;
    public const int MaxBytes = 20000;
    public const int MaxWordTextLength = 100;
    public const int MaxChars = 5000;
    public IReadOnlyList<ClipWord> Entries => Request.Entries;

    public static ScopeRewritePlan Make(Project project, RewriteScope scope, string instruction, string language,
        AudioEnvelope? envelope, IReadOnlyList<VoiceLabRateCandidate>? candidates = null, Guid? id = null)
    {
        if (project.Transcript is not { } transcript || scope.First.HasValue || scope.Last.HasValue) throw Invalid();
        var items = transcript.Words;
        int start = 0, end = items.Count;
        var outputScope = new VoiceLabOutputScope(scope.ClipId);
        if (scope.ClipId is { } clipId)
        {
            var clip = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId);
            start = clip is null ? -1 : items.ToList().FindIndex(word => word.Id == clip.StartWordId);
            var last = clip is null ? -1 : items.ToList().FindIndex(word => word.Id == clip.EndWordId);
            if (start < 0 || last < start) throw Invalid();
            end = last + 1;
        }
        bool[] replaced;
        try { replaced = VoiceLabWindowPlanner.ReplacedItems(project, outputScope, envelope); }
        catch (VoiceLabGeometryException) { throw Invalid(); }
        var corrected = items.Select(item => item.Kind == WordKind.Word
            ? item with { Text = project.Edits.Corrections.GetValueOrDefault(item.Id) ?? item.Text } : item).ToArray();
        var cut = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var kept = Enumerable.Range(start, end - start).Where(index => !cut.Contains(items[index].Id) && !replaced[index]).ToArray();
        var entries = kept.Select(index => new ClipWord(index,
            ClipText.Limit(corrected[index].Kind == WordKind.UnlabeledSpeech ? "…" : corrected[index].Text, MaxWordTextLength),
            corrected[index].Start, corrected[index].End)).ToArray();
        if (entries.Length == 0) throw new ScopeRewritePlanException(ScopeRewritePlanErrorCode.Empty);
        if (entries.Length > MaxEntries) throw new ScopeRewritePlanException(ScopeRewritePlanErrorCode.TooManyEntries, count: entries.Length);
        var bytes = Encoding.UTF8.GetByteCount(string.Join(" ", entries.Select(entry => entry.Text)));
        if (bytes > MaxBytes) throw new ScopeRewritePlanException(ScopeRewritePlanErrorCode.TooMuchText, bytes: bytes);
        double? speechRate = null;
        var lines = new List<Line>();
        foreach (var line in ClipText.Lines(entries))
        {
            var positions = Enumerable.Range(line.FirstPosition, line.LastPosition - line.FirstPosition + 1).ToArray();
            var lineItems = positions.Select(index => corrected[kept[index]]).ToArray();
            var lineEntries = positions.Select(index => entries[index]).ToArray();
            var revoiced = positions.Select(index => index > 0 && Enumerable.Range(kept[index - 1] + 1,
                kept[index] - kept[index - 1] - 1).Any(at => replaced[at])).ToArray();
            var echoed = positions.Where(index => corrected[kept[index]].Kind != WordKind.Word).Sum(index => VoiceLabTextLength.Length(entries[index].Text));
            var label = $"[{line.Line.FirstIndex}-{line.Line.LastIndex}]";
            var first = lineItems.FirstOrDefault(item => item.Kind == WordKind.Word);
            var last = lineItems.LastOrDefault(item => item.Kind == WordKind.Word);
            if (first is null || last is null)
            {
                int chars = Math.Min(Math.Max(1, echoed), MaxChars);
                lines.Add(new(label, lineItems, lineEntries, revoiced, chars, chars, RangeSource.NoSpeech));
                continue;
            }
            try { speechRate ??= VoiceLabLengthBudget.Rate(corrected, project.Edits.PauseThresholdSeconds, candidates).CharactersPerSecond; }
            catch (VoiceLabLengthBudgetException) { throw Invalid(); }
            var budget = WindowBudget(project, outputScope, envelope, first.Id, last.Id, corrected, speechRate.Value);
            var source = budget is null ? RangeSource.LineSpan : RangeSource.Window;
            try { budget ??= VoiceLabLengthBudget.FullTake(lineItems, speechRate.Value); }
            catch (VoiceLabLengthBudgetException) { throw Invalid(); }
            lines.Add(new(label, lineItems, lineEntries, revoiced, Math.Min(budget.MinChars + echoed, MaxChars),
                Math.Min(budget.MaxChars + echoed, MaxChars), source));
        }
        return new(scope, lines, new(id ?? Guid.NewGuid(), entries,
            lines.Select(line => new PatchRewriteLineRange(line.Label, line.MinChars, line.MaxChars)).ToArray(), instruction, language));
    }
    static VoiceLabLengthRange? WindowBudget(Project project, VoiceLabOutputScope scope, AudioEnvelope? envelope,
        string first, string last, IReadOnlyList<TimedWord> transcript, double rate)
    {
        if (envelope is null) return null;
        try
        {
            var window = VoiceLabWindowPlanner.Place(project, scope, envelope, first, last);
            var silence = VoiceLabWindowPlanner.LendableSilence(project, scope, window);
            return VoiceLabLengthBudget.Passage(window, transcript, silence.Incoming, silence.Outgoing, rate);
        }
        catch (VoiceLabGeometryException failure)
        {
            if (failure.Code == VoiceLabGeometryErrorCode.InvalidInput && failure.SegmentId is not null) throw Invalid();
            return null;
        }
        catch (VoiceLabLengthBudgetException) { return null; }
    }
    static ScopeRewritePlanException Invalid() => new(ScopeRewritePlanErrorCode.InvalidInput);
}

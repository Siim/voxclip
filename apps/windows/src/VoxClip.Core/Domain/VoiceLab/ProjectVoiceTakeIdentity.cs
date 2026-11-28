using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>What a Rewrite reads and what its paid voice work is made from (voice-lab.md "What counts as an edit"), twin of the
/// Mac <c>Project.rewriteInputs</c> and <c>Project.voiceTakeIdentity</c> and replayed from
/// shared/fixtures/voice-lab/voice-take-identity-cases.json. <see cref="RewriteInputs"/> keeps the transcript, the media apart from
/// its relative path, the pause settings and the Voice Lab segments, and scopes the clip, cuts, cut edges, pauses and corrections: a
/// selection reads its enclosing clip's placement context and both edge pauses. <see cref="Of"/> adds back the clean-audio choice,
/// which changes the source a take is fitted to. Save metadata (modified time, writer, relative path, title), the active tab,
/// music, captions, the clip style, motion cues, clip controls and effects, export, share, the AI results, the Voice Lab asset and
/// voice catalogs and VoxClip's own speaking-rate samples are in neither: takes never read them. The chosen voice and model are
/// checked beside the identity, by the caller.</summary>
public static class ProjectVoiceTakeIdentity
{
    private static readonly JsonElement EmptyObject = JsonDocument.Parse("{}").RootElement.Clone();

    /// <summary>The scope's inputs as a text proposal reads them; <paramref name="enclosingClipId"/> is a selection's clip.</summary>
    public static Project RewriteInputs(Project project, RewriteScope scope, string? enclosingClipId)
    {
        IReadOnlyList<TimedWord> words = project.Transcript?.Words ?? [];
        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < words.Count; index++) positions.TryAdd(words[index].Id, index);
        var clipId = scope.ClipId ?? enclosingClipId;
        var clip = clipId is null ? null : project.Edits.Clips.FirstOrDefault(range => range.Id == clipId);
        (int Lower, int Upper)? bounds = clip is not null && positions.TryGetValue(clip.StartWordId, out var start) &&
            positions.TryGetValue(clip.EndWordId, out var end) && start <= end ? (start, end) : null;
        int lower, upper;
        var edges = false;
        if (scope.ClipId is not null) (lower, upper) = bounds ?? (0, 0);
        else if (scope.First is int first && scope.Last is int last)
        {
            (lower, upper) = bounds is { } clipBounds ? (Math.Min(first, clipBounds.Lower), Math.Max(last, clipBounds.Upper)) : (first, last);
            edges = true;
        }
        else (lower, upper) = (0, Math.Max(0, words.Count - 1));
        var threshold = project.Edits.PauseThresholdSeconds;
        IReadOnlyList<Pause> pauses = double.IsFinite(threshold) && threshold > 0 ? EditingAlgorithms.DetectPauses(words, threshold) : [];
        var pausePositions = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var pause in pauses) pausePositions.TryAdd(pause.Id, pause.AfterIndex);
        var pauseLower = edges ? Math.Max(0, lower - 1) : lower;
        var pauseUpper = edges ? upper : upper - 1;
        bool InScope(string id) => !positions.TryGetValue(id, out var at) || at >= lower && at <= upper;
        var corrections = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (id, text) in project.Edits.Corrections) if (InScope(id)) corrections[id] = text;
        // A cut edge (editing §5.10) sits between word i−1 and word i, so it counts when either is in scope.
        var cutEdges = new SortedDictionary<string, double>(StringComparer.Ordinal);
        foreach (var (id, edge) in project.Edits.CutEdges ?? new Dictionary<string, double>())
            if (!positions.TryGetValue(id, out var at) || at >= lower && at <= upper || at - 1 >= lower && at - 1 <= upper) cutEdges[id] = edge;
        return project with
        {
            SchemaVersion = 1,
            ModifiedAt = DateTimeOffset.MinValue,
            SavedBy = new("", "0.0.0", ""),
            Media = project.Media with { Source = project.Media.Source with { RelativePath = null } },
            Title = null,
            Extensions = null,
            ContextDemo = null,
            ClipStyle = null,
            MotionCues = [],
            Music = [],
            ClipEffects = [],
            ClipControls = [],
            CaptionTranslations = [],
            Edits = project.Edits with
            {
                ActiveClipId = null,
                Clips = clip is null ? [] : [new ClipRange(clip.Id, clip.StartWordId, clip.EndWordId, null, ClipOrigin.Manual, null, null, true)],
                CutWordIds = project.Edits.CutWordIds.Where(InScope).ToArray(),
                CutPauseIds = project.Edits.CutPauseIds.Where(id => !pausePositions.TryGetValue(id, out var at) || at >= pauseLower && at <= pauseUpper).ToArray(),
                Corrections = corrections,
                CutEdges = cutEdges.Count > 0 ? cutEdges : null,
            },
            Captions = new("", EmptyObject, null, new Dictionary<string, CaptionPosition>()),
            Export = new(ExportAspect.Source, ExportQuality.Standard, false, null),
            Share = new(new Dictionary<string, string>()),
            Ai = new([]),
            VoiceLab = project.VoiceLab with { Assets = null, SpeakingRateSamples = null, CleanAudio = null, Voices = null, VideoAssets = null },
        };
    }

    /// <summary>What the scope's paid voice work is made from: <see cref="RewriteInputs"/> with the clean-audio choice. A project from
    /// before schema v3 has no choice, which is clean audio off, as the upgrade an edit makes writes it.</summary>
    public static Project Of(Project project, RewriteScope scope, string? enclosingClipId)
    {
        var inputs = RewriteInputs(project, scope, enclosingClipId);
        return inputs with { VoiceLab = inputs.VoiceLab with { CleanAudio = project.VoiceLab.CleanAudio ?? new(VoiceLabCleanAudioMode.Off, null, null) } };
    }

    /// <summary>A normalized project's comparable form: two are the same inputs exactly when their keys are equal.</summary>
    public static string Key(Project normalized) => JsonSerializer.Serialize(normalized, ProjectJsonContext.Default.Project);

    /// <summary>The comparable form of <see cref="Of"/>.</summary>
    public static string IdentityKey(Project project, RewriteScope scope, string? enclosingClipId) => Key(Of(project, scope, enclosingClipId));
    /// <summary>The comparable form of <see cref="RewriteInputs"/>.</summary>
    public static string RewriteInputsKey(Project project, RewriteScope scope, string? enclosingClipId) => Key(RewriteInputs(project, scope, enclosingClipId));
}

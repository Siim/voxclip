using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Revoice the whole clip (ADR-R46, voice-lab §8.14): one AI voice for every word of a clip, fitted to the clip's length,
/// then lip synced, so a heavily rewritten clip has no seams between the real voice and patched phrases. This class holds the free,
/// deterministic parts both apps share, as the Mac <c>WholeClipRevoice.swift</c>.</summary>
public static partial class WholeClipRevoice
{
    /// <summary>The burned-in chip of an export holding a whole-clip revoice (voice-lab §11).</summary>
    public const string DisclosureChip = "Voice and lip movement generated with AI";
    /// <summary>The post text line of an export holding a whole-clip revoice (voice-lab §11).</summary>
    public const string DisclosureLine = "Voice and lip movement generated with AI.";
    /// <summary>The Estonian post text line.</summary>
    public const string DisclosureLineEstonian = "Hääl ja huulte liikumine on loodud tehisintellektiga.";
    /// <summary>The disclosure kind a revoiced segment adds to an export's label plan.</summary>
    public const string DisclosureKind = "revoice";
    /// <summary>The fit tolerance: the voice's length within this share of the clip's video length.</summary>
    public const double FitTolerance = 0.08;
    /// <summary>The longest stored script, in Unicode scalars.</summary>
    public const int MaximumScriptScalars = 20_000;

    /// <summary>The record's rules, checked with the rest of the Voice Lab data (<see cref="VoiceLabProject.Validate(Project)"/>):
    /// schema 3 or later; an id and clip id of the project's id shape, the clip existing; at least one segment, each an existing,
    /// distinct text-to-speech segment in no other record; a lip-sync model this feature uses; the retime within the fit tolerance;
    /// scores within −1…1 and a finite, non-negative price.</summary>
    public static void Validate(Project project)
    {
        ArgumentNullException.ThrowIfNull(project);
        if (project.VoiceLab.WholeClipRevoices is not { } records) return;
        if (project.SchemaVersion < 3 || records.Count == 0) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
        var segments = new Dictionary<string, VoiceLabSegment>(StringComparer.Ordinal);
        foreach (var segment in project.VoiceLab.Segments) segments.TryAdd(segment.Id, segment);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var record in records)
        {
            if (record is null || !IdShape(record.Id) || !ids.Add(record.Id) || !IdShape(record.ClipId) ||
                !project.Edits.Clips.Any(clip => clip.Id == record.ClipId) ||
                record.SegmentIds is not { Count: > 0 } || string.IsNullOrEmpty(record.Script) ||
                record.Script.EnumerateRunes().Count() > MaximumScriptScalars || string.IsNullOrEmpty(record.ConsentRecordId) ||
                WholeClipLipsyncValues.FromRawValue(record.LipsyncModel) is null ||
                !double.IsFinite(record.VideoRetime) || Math.Abs(record.VideoRetime - 1) > FitTolerance + 1e-9 ||
                record.Usd is { } usd && (!double.IsFinite(usd) || usd < 0))
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
            if (record.Match is { } match)
            {
                double?[] scores = [match.Take, match.AnchorBaseline, match.RealSpeech];
                if (scores.Any(score => score is { } value && (!double.IsFinite(value) || value < -1 || value > 1)))
                    throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
            }
            foreach (var id in record.SegmentIds)
                if (id is null || !used.Add(id) || !segments.TryGetValue(id, out var segment) || segment.Kind != VoiceLabSegmentKind.Tts)
                    throw new VoiceLabProjectException(VoiceLabProjectErrorCode.MissingSegment);
        }
    }

    /// <summary>Drops every record whose clip is gone or whose segments are no longer the project's own text-to-speech segments (Mac
    /// <c>WholeClipRevoice.pruneDangling</c>). Edits that remove a clip or a segment call it in the same step, so the project never stops
    /// validating, saving or rendering because of a record naming what was removed (ADR-R46). The segments stay as voiced patches; only the
    /// record that bound them to one clip goes. A file that arrives with such a record is still refused.</summary>
    public static Project PruneDangling(Project project)
    {
        ArgumentNullException.ThrowIfNull(project);
        if (project.VoiceLab.WholeClipRevoices is not { } records) return project;
        var clips = project.Edits.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        var tts = project.VoiceLab.Segments.Where(segment => segment.Kind == VoiceLabSegmentKind.Tts).Select(segment => segment.Id)
            .ToHashSet(StringComparer.Ordinal);
        var kept = records.Where(record => record is not null && clips.Contains(record.ClipId) && record.SegmentIds is { Count: > 0 } ids &&
            ids.All(id => id is not null && tts.Contains(id))).ToArray();
        if (kept.Length == records.Count) return project;
        return project with { VoiceLab = project.VoiceLab with { WholeClipRevoices = kept.Length == 0 ? null : kept } };
    }

    /// <summary>Whether <paramref name="clipId"/> plays a whole-clip revoice: a record for it with an enabled segment. The stage then
    /// shows its AI voice tag over the whole clip, the pauses between parts included.</summary>
    public static bool IsRevoiced(string clipId, Project project)
    {
        ArgumentNullException.ThrowIfNull(project);
        if (project.VoiceLab.WholeClipRevoices is not { } records) return false;
        var enabled = project.VoiceLab.Segments.Where(segment => segment.Enabled).Select(segment => segment.Id).ToHashSet(StringComparer.Ordinal);
        return records.Any(record => record.ClipId == clipId && record.SegmentIds.Any(enabled.Contains));
    }

    /// <summary>The record holding <paramref name="segmentId"/>, if a whole-clip revoice made it.</summary>
    public static WholeClipRevoiceRecord? RecordHolding(string segmentId, Project project)
    {
        ArgumentNullException.ThrowIfNull(project);
        return project.VoiceLab.WholeClipRevoices?.FirstOrDefault(record => record.SegmentIds.Contains(segmentId, StringComparer.Ordinal));
    }

    /// <summary>The chip's words: a whole-clip revoice, lip movement, or any other AI change (Mac <c>VoiceLabDisclosureOverlay.chipText</c>).</summary>
    public static string ChipText(IReadOnlyList<string> kinds)
    {
        ArgumentNullException.ThrowIfNull(kinds);
        if (kinds.Contains(DisclosureKind, StringComparer.Ordinal)) return DisclosureChip;
        return kinds.Contains("lipsync", StringComparer.Ordinal) ? "Lip movement generated with AI" : "AI MODIFIED";
    }

    private static bool IdShape(string? value) => value is not null && VoiceLabProject.Matches(value, "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}");
}

/// <summary>The lip-sync models a whole clip may use (the user's decision, 2026-11-07): lipsync-2 by default, sync-3 as the priced
/// upgrade on Review that re-runs only the lip sync. The raw value is the fal model id the record stores.</summary>
public enum WholeClipLipsync
{
    /// <summary><c>fal-ai/sync-lipsync/v2:lipsync-2</c>, the standard.</summary>
    Lipsync2,
    /// <summary><c>fal-ai/sync-lipsync/v3</c>, the upgrade.</summary>
    Sync3
}

/// <summary>The raw values and names of <see cref="WholeClipLipsync"/>.</summary>
public static class WholeClipLipsyncValues
{
    /// <summary>The standard model.</summary>
    public const WholeClipLipsync Standard = WholeClipLipsync.Lipsync2;
    /// <summary>Every model, in the Mac's <c>allCases</c> order.</summary>
    public static IReadOnlyList<WholeClipLipsync> All { get; } = [WholeClipLipsync.Lipsync2, WholeClipLipsync.Sync3];

    /// <summary>The stored fal model id.</summary>
    public static string RawValue(this WholeClipLipsync model) => model == WholeClipLipsync.Sync3 ? "fal-ai/sync-lipsync/v3" : "fal-ai/sync-lipsync/v2:lipsync-2";
    /// <summary>The fal endpoint, before the colon.</summary>
    public static string Endpoint(this WholeClipLipsync model) => model.RawValue().Split(':', 2)[0];
    /// <summary>The model after the colon, or null.</summary>
    public static string? Model(this WholeClipLipsync model) => model.RawValue().Split(':', 2) is { Length: 2 } parts ? parts[1] : null;
    /// <summary>"lipsync-2", "sync-3".</summary>
    public static string Name(this WholeClipLipsync model) => model == WholeClipLipsync.Lipsync2 ? "lipsync-2" : "sync-3";
    /// <summary>The model for a stored raw value, or null.</summary>
    public static WholeClipLipsync? FromRawValue(string? value) => value switch
    {
        "fal-ai/sync-lipsync/v2:lipsync-2" => WholeClipLipsync.Lipsync2,
        "fal-ai/sync-lipsync/v3" => WholeClipLipsync.Sync3,
        _ => null
    };
    /// <summary>The model as a fal lip-sync capability.</summary>
    public static Services.LLM.LipsyncModel LipsyncModel(this WholeClipLipsync model)
        => new("fal", model.RawValue(), model == WholeClipLipsync.Sync3 ? Services.LLM.LipsyncTier.Best : Services.LLM.LipsyncTier.Quality, true);
}

/// <summary>A used whole-clip revoice, saved in the project (<c>voiceLab.wholeClipRevoices</c>, schema v3 and v4). Its segments are
/// ordinary Voice Lab segments, one per part, whose recipes carry the matched video and the lip sync; this record ties them together
/// for the disclosure, the stage's tag, the review's match line and Undo. Every key is written, nulls included.</summary>
/// <param name="Id">The record id, of the project's id shape.</param>
/// <param name="ClipId">The revoiced clip.</param>
/// <param name="SegmentIds">The record's text-to-speech segments.</param>
/// <param name="Script">The script the voice said.</param>
/// <param name="ConsentRecordId">The voice's consent record.</param>
/// <param name="VideoRetime">The voice's length ÷ the clip's video length; the picture's uniform retime.</param>
/// <param name="LipsyncModel">A <see cref="WholeClipLipsync"/> raw value.</param>
/// <param name="Usd">What it cost, when known.</param>
/// <param name="Match">The review's match scores, when measured.</param>
/// <param name="CreatedAt">When it was used.</param>
public sealed record WholeClipRevoiceRecord(string Id, string ClipId, IReadOnlyList<string> SegmentIds, string Script, string ConsentRecordId,
    double VideoRetime, string LipsyncModel, double? Usd, WholeClipRevoiceMatch? Match, DateTimeOffset CreatedAt)
{
    /// <inheritdoc />
    public bool Equals(WholeClipRevoiceRecord? other) => other is not null && Id == other.Id && ClipId == other.ClipId &&
        SegmentIds.SequenceEqual(other.SegmentIds, StringComparer.Ordinal) && Script == other.Script && ConsentRecordId == other.ConsentRecordId &&
        VideoRetime.Equals(other.VideoRetime) && LipsyncModel == other.LipsyncModel && Nullable.Equals(Usd, other.Usd) && Equals(Match, other.Match) &&
        CreatedAt.Equals(other.CreatedAt);
    /// <inheritdoc />
    public override int GetHashCode() => HashCode.Combine(Id, ClipId, Script, VideoRetime, LipsyncModel, CreatedAt);
}

/// <summary>A whole-clip revoice's match scores; every key is written, nulls included.</summary>
/// <param name="Take">The whole-clip voice's take-match score against the speech beside it.</param>
/// <param name="AnchorBaseline">The anchor's earlier takes (voice-lab §6.13 item 9), when measured.</param>
/// <param name="RealSpeech">The real speech against the consent recording, when measured.</param>
public sealed record WholeClipRevoiceMatch(double Take, double? AnchorBaseline, double? RealSpeech);

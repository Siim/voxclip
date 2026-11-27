using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using ClipProject = VoxClip.Core.Domain.Shared.Project;

namespace VoxClip.Core.Services.Project;

/// <summary>Project-scoped harness operations.</summary>
public enum HarnessTool
{
    /// <summary>Read a page of corrected transcript items.</summary>
    ReadTranscript,
    /// <summary>List clips and their parts.</summary>
    ReadClips,
    /// <summary>Read matched lines across recordings.</summary>
    ReadTakes,
    /// <summary>Read the clip's saved edit decisions.</summary>
    ReadDecisions,
    /// <summary>Read frames from the validated source.</summary>
    ReadFrames,
    /// <summary>Preview a timeline proposal.</summary>
    ProposeTimeline,
    /// <summary>Run the live timeline checks.</summary>
    Check,
    /// <summary>Search the free library and local Music folder.</summary>
    FindMusic,
    /// <summary>Quote a paid action without executing it.</summary>
    Offer,
    /// <summary>Describe an in-app panel link.</summary>
    PointTo
}

/// <summary>A frame decoded at the nearest source time.</summary>
/// <param name="Requested">Requested source seconds.</param>
/// <param name="Actual">Decoded source seconds.</param>
/// <param name="Jpeg">Base64-encoded JPEG.</param>
public sealed record HarnessFrame(double Requested, double Actual, string Jpeg);

/// <summary>The public tool reply and host-only data needed to use it.</summary>
/// <param name="Fields">Wire response fields.</param>
/// <param name="Frames">JPEGs sent out of band in MCP.</param>
/// <param name="Proposal">A validated sidecar document for the saved-file host.</param>
/// <param name="PreparedMusic">Free tracks to supply when reviewing the live proposal.</param>
public sealed record HarnessResult(object Fields, IReadOnlyList<HarnessFrame>? Frames = null, JsonObject? Proposal = null,
    IReadOnlyList<ProjectMusic>? PreparedMusic = null);

/// <summary>Dispatches tools against a supplied project snapshot without writing the project or staging a sidecar.</summary>
public static class HarnessTools
{
    private static readonly JsonElement Empty = JsonElement.Parse("{}");

    /// <summary>Run one tool, using only the host-supplied services for frame decoding, checks and free music.</summary>
    public static async Task<HarnessResult> Call(HarnessTool tool, JsonElement arguments, ClipProject project, string? sharedRoot,
        string? projectPath = null, string? cache = null,
        Func<string, IReadOnlyList<double>, CancellationToken, IReadOnlyList<HarnessFrame>>? decodeFrames = null,
        HarnessMusicLibrary? musicLibrary = null, Func<ClipProject, string, IReadOnlyList<string>, JsonElement>? check = null,
        decimal? postableCap = null, bool chat = true, CancellationToken ct = default)
    {
        if (arguments.ValueKind == JsonValueKind.Undefined) arguments = Empty;
        switch (tool)
        {
            case HarnessTool.ReadTranscript:
                HarnessTimeline.RequireObject(arguments, ["offset", "limit", "recordingKey"]);
                if (arguments.TryGetProperty("recordingKey", out var requested))
                {
                    var key = requested.ValueKind == JsonValueKind.String ? requested.GetString()! :
                        throw new HarnessException("Choose a recording key from read_clips.");
                    var source = HarnessRecording.Source(key, project);
                    var transcript = HarnessRecording.CachedTranscript(key, cache ?? DataLocations.Resolve().Cache) ?? throw HarnessRecording.Refusal(source);
                    project = HarnessRecording.Add(key, transcript, project);
                }
                return Transcript(project, Integer(arguments, "offset", 0, 0, long.MaxValue), (int)Integer(arguments, "limit", 200, 1, 500));
            case HarnessTool.ReadClips:
                HarnessTimeline.RequireObject(arguments, []);
                return Clips(project);
            case HarnessTool.ReadTakes:
                HarnessTimeline.RequireObject(arguments, []);
                var clock = ProjectClock.Build(project);
                var matches = TakeMatch.Build(clock);
                return new(new { matches.Beats, matches.Solo, recordings = Recordings(project, clock) });
            case HarnessTool.ReadDecisions:
                HarnessTimeline.RequireObject(arguments, ["clipId"]);
                return Decisions(project, arguments.TryGetProperty("clipId", out var clip) && clip.ValueKind == JsonValueKind.String ? clip.GetString() : null);
            case HarnessTool.ReadFrames:
                HarnessTimeline.RequireObject(arguments, ["times"]);
                return await FramesAsync(project, arguments, projectPath, decodeFrames, ct).ConfigureAwait(false);
            case HarnessTool.ProposeTimeline:
                string? revises = null;
                IReadOnlyList<string?> labels = [];
                if (chat) (arguments, revises, labels) = HarnessChatTools.Timeline(arguments);
                var timelines = HarnessTimeline.ReadSeries(arguments).Select(timeline =>
                    timeline.RecordingKey is { } key && HarnessRecording.CachedTranscript(key, cache ?? DataLocations.Resolve().Cache) is { } cached
                        ? timeline.PinRecordingTranscript(cached) : timeline).ToArray();
                var shared = sharedRoot ?? SharedResources.ResolveRoot();
                var requestedTracks = timelines.Select(timeline => timeline.Proposal.Music?.TrackId).OfType<string>()
                    .Except(project.Music.Select(track => track.Id), StringComparer.Ordinal).Order(StringComparer.Ordinal);
                var imported = musicLibrary is null ? [] : await musicLibrary.PrepareAsync(requestedTracks, project.Id, ct).ConfigureAwait(false);
                var proposal = new HarnessProposal(timelines, project);
                var pricedActions = new List<object>();
                var freeActions = new List<object>();
                var refusals = new List<object>();
                const string approval = "In VoxClip only; the app confirms the price for the open clip.";
                for (var index = 0; index < timelines.Length; index++)
                {
                    (ClipProject Project, IReadOnlyList<ClipAutopilotOperation> Operations, IReadOnlyList<ClipAutopilotOperation> Pending) review;
                    var key = timelines[index].RecordingKey;
                    var transcript = key is null ? null : HarnessRecording.CachedTranscript(key, cache ?? DataLocations.Resolve().Cache);
                    try { review = proposal.Review(project, shared, index, transcript, preview: true, preparedMusic: imported); }
                    catch (HarnessTimelineEditException refusal)
                    {
                        refusals.Add(new { timelineIndex = index, reason = refusal.Message });
                        continue;
                    }
                    if (key is not null) freeActions.Add(new { kind = "useRecording", key, timelineIndex = index });
                    foreach (var operation in review.Pending.OrderBy(operation => operation.Decision == ClipAutopilotDecision.Music ? 0 : 1))
                    {
                        switch (operation.Action)
                        {
                            case ClipAutopilotAction.Music music:
                                pricedActions.Add(new { kind = "generateMusic", prompt = music.Cue.Picked.Prompt,
                                    price = proposal.EstimatedMusicPrice(review.Project, shared, index), approval, timelineIndex = index });
                                break;
                            case ClipAutopilotAction.Asset { Kind: "illustration" } asset:
                                pricedActions.Add(new { kind = "generateIllustration", prompt = asset.Text, price = ClipIllustrationQuote.Load(shared).Price,
                                    approval, timelineIndex = index });
                                break;
                            case ClipAutopilotAction.Asset asset:
                                freeActions.Add(new { kind = "findSound", query = asset.Text, timelineIndex = index });
                                break;
                            case ClipAutopilotAction.Rewrite rewrite:
                                var estimate = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsTextToSpeech, "eleven_multilingual_v2",
                                    VoiceLabTextLength.Length(rewrite.Text), 1, null, VoiceLabPrices.Load(shared));
                                pricedActions.Add(new { kind = "rewrite", text = rewrite.Text,
                                    price = estimate.Usd is { } usd ? VoiceLabCostPresentation.Format(usd) : null, approval, timelineIndex = index });
                                break;
                        }
                    }
                }
                var wire = proposal.ToJson();
                var response = new Dictionary<string, object> { ["proposal"] = wire, ["pricedActions"] = pricedActions, ["freeActions"] = freeActions };
                if (refusals.Count != 0) response["refusals"] = refusals;
                if (revises is not null) response["revises"] = revises;
                if (labels.Any(label => label is not null)) response["labels"] = labels;
                return new(response, Proposal: wire, PreparedMusic: imported);
            case HarnessTool.Check:
                HarnessTimeline.RequireObject(arguments, ["clipId", "targets"]);
                var clipId = HarnessChatTools.Text(arguments, "clipId", 200) ?? throw new HarnessException("Unexpected or invalid text argument.");
                var targets = HarnessChatTools.Strings(arguments, "targets", 8, 32);
                if (check is null) throw new HarnessException("Timeline checks aren’t available in this host.");
                return new(new { checks = check(project, clipId, targets) });
            case HarnessTool.FindMusic:
                HarnessTimeline.RequireObject(arguments, ["mood", "lengthSeconds"]);
                var mood = HarnessChatTools.Text(arguments, "mood", 200) ?? throw new HarnessException("Unexpected or invalid text argument.");
                if (!arguments.TryGetProperty("lengthSeconds", out var field) || field.ValueKind != JsonValueKind.Number ||
                    !double.IsFinite(field.GetDouble()) || field.GetDouble() <= 0)
                    throw new HarnessException("Give a positive music length in seconds.");
                var tracks = musicLibrary is null ? [] : await musicLibrary.SearchAsync(mood, field.GetDouble(), ct).ConfigureAwait(false);
                return new(new { tracks });
            case HarnessTool.Offer:
                HarnessTimeline.RequireObject(arguments, ["kind", "target", "brief", "words"]);
                return HarnessChatTools.Offer(arguments, project, sharedRoot ?? SharedResources.ResolveRoot(), postableCap);
            case HarnessTool.PointTo:
                HarnessTimeline.RequireObject(arguments, ["panel", "target"]);
                return HarnessChatTools.PointTo(arguments);
            default: throw new ArgumentOutOfRangeException(nameof(tool));
        }
    }

    private static HarnessResult Transcript(ClipProject project, long offset, int limit)
    {
        var clock = ProjectClock.Build(project);
        var words = clock.Words;
        var first = (int)Math.Min(offset, words.Count);
        var count = Math.Min(limit, words.Count - first);
        var cut = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var page = Enumerable.Range(first, count).Select(index =>
        {
            var word = words[index];
            var region = clock.RegionOf(word.Id);
            return new { index, word.Id, word.Kind, word.Start, word.End, recording = region?.Label, recordingKey = region?.Key,
                text = project.Edits.Corrections.GetValueOrDefault(word.Id, word.Text), cut = cut.Contains(word.Id) };
        }).ToArray();
        return new(new { words = page, total = words.Count, nextOffset = first + count < words.Count ? (int?)(first + count) : null,
            language = clock.Transcript?.Language, recordings = Recordings(project, clock) });
    }

    private static HarnessResult Clips(ClipProject project)
    {
        var clock = ProjectClock.Build(project);
        var indices = clock.Words.Select((word, index) => (word.Id, index))
            .ToDictionary(item => item.Id, item => (int?)item.index, StringComparer.Ordinal);
        var clips = project.Edits.Clips.Select(clip => new
        {
            clip.Id, clip.Title, clip.Selected, startWord = indices.GetValueOrDefault(clip.StartWordId), endWord = indices.GetValueOrDefault(clip.EndWordId),
            kind = clip.Kind == StoryClipKind.Showreel ? "showreel" : clip.Parts is null ? "stretch" : "story",
            parts = clip.PlayParts.Where(part => indices.ContainsKey(part.StartWordId) && indices.ContainsKey(part.EndWordId))
                .Select(part =>
                {
                    var region = clock.RegionOf(part.StartWordId);
                    return new { startWord = indices[part.StartWordId], endWord = indices[part.EndWordId],
                        recording = region?.Label, recordingKey = region?.Key };
                }),
            sourceSpan = ClipControlsProject.SourceSpan(clip.Id, project) is { } span ? new TimeRange(span.Start, span.End) : (TimeRange?)null
        }).ToArray();
        var footageSources = (project.Media.AdditionalSources ?? []).Where(source => source.Video is not null).Select(source => new
        {
            sourceKey = source.FootageKey, duration = source.DurationSeconds, name = Path.GetFileName(source.AbsolutePath)
        });
        return new(new { projectId = project.Id, clips, footageSources, recordings = Recordings(project, clock) });
    }

    private sealed record Recording(string Key, string Label, double DurationSeconds, int? FirstWord, int? LastWord, bool Transcribed, double GainDb);

    private static IReadOnlyList<Recording> Recordings(ClipProject project, ProjectClock clock)
    {
        var sources = project.Media.AdditionalSources ?? [];
        var spoken = project.Media.SpokenSources ?? [];
        var next = 0;
        var recordings = clock.Regions.Select(region =>
        {
            var primary = region.Prefix.Length == 0;
            var duration = primary ? project.Media.Source.DurationSeconds : sources.First(source => source.ContentKey == region.Key).DurationSeconds;
            var count = primary ? project.Transcript?.Words.Count : spoken.First(source => source.SourceKey == region.Key).Transcript.Words.Count;
            var first = next;
            next += count ?? 0;
            return new Recording(region.Key, region.Label, duration, next > first ? first : null, next > first ? next - 1 : null, count is not null, region.GainDb);
        }).ToList();
        var keys = clock.Regions.Select(region => region.Key).ToHashSet(StringComparer.Ordinal);
        recordings.AddRange(sources.Where(source => !keys.Contains(source.ContentKey)).Select(source =>
            new Recording(source.ContentKey, ProjectClock.Label(source), source.DurationSeconds, null, null, false, 0)));
        return recordings;
    }

    private static HarnessResult Decisions(ClipProject project, string? clipId)
    {
        var clip = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId)
            ?? throw new HarnessException("Choose a clip id from read_clips.");
        var result = project.Ai.Results.FirstOrDefault(item => item.Id == clip.AiResultId);
        var found = result is not null && clip.AiClipIndex is >= 0 and var index && index < result.Clips.Count ? result.Clips[index] : null;
        return new(new
        {
            clipId, clip.Title, findReason = found?.Reason, openingLeadInSeconds = clip.LeadInSeconds, timeline = TimelineDecisions.Read(project, clipId),
            controls = ClipControlsProject.Controls(clipId, project), captionStyle = project.CaptionsFor(clipId).StyleId,
            musicTracks = project.Music.Select(item => new { item.Id, item.Title, item.ClipId }).ToArray(),
            effects = project.ClipEffects.Select(ClipEffect.Parse).Where(effect => effect.ClipId == clipId).Select(effect => new
            {
                effect.Id, effect.Kind, effect.Start, effect.End, effect.Text, effect.Rect
            }).ToArray(),
            zooms = project.MotionCues.Where(cue => cue.ClipID == clipId).ToArray()
        });
    }

    private static async Task<HarnessResult> FramesAsync(ClipProject project, JsonElement arguments, string? projectPath,
        Func<string, IReadOnlyList<double>, CancellationToken, IReadOnlyList<HarnessFrame>>? decodeFrames, CancellationToken ct)
    {
        var source = project.Media.Source;
        if (!arguments.TryGetProperty("times", out var requested) || requested.ValueKind != JsonValueKind.Array ||
            requested.GetArrayLength() is < 1 or > 4 || requested.EnumerateArray().Any(time => time.ValueKind != JsonValueKind.Number ||
                !(time.GetDouble() >= 0 && time.GetDouble() < source.DurationSeconds)))
            throw new HarnessException("Give one to four source times inside the video.");
        var mediaPath = await ResolveSourceAsync(source, projectPath, ct).ConfigureAwait(false);
        var frames = (decodeFrames ?? throw new HarnessException("Preview frames aren’t available in this host."))(
            mediaPath, requested.EnumerateArray().Select(time => time.GetDouble()).ToArray(), ct);
        return new(new { frames = frames.Select(frame => new { frame.Requested, frame.Actual }).ToArray() }, frames);
    }

    private static async Task<string> ResolveSourceAsync(MediaReference source, string? projectPath, CancellationToken ct)
    {
        var candidates = new List<string> { source.AbsolutePath };
        if (projectPath is not null && source.RelativePath is { Length: > 0 } relative && !Path.IsPathRooted(relative) && !relative.Contains(':') && !relative.Contains('\\'))
            candidates.Add(Path.Join(Path.GetDirectoryName(projectPath), relative));
        var store = new ProjectStore();
        foreach (var candidate in candidates)
        {
            ct.ThrowIfCancellationRequested();
            if (!Path.IsPathFullyQualified(candidate) || source.SizeBytes <= 0 ||
                Path.GetExtension(candidate).ToLowerInvariant() is not (".mp4" or ".mov" or ".m4v")) continue;
            try
            {
                var full = HarnessInbox.CanonicalLocalPath(candidate, allowLinks: false);
                var info = new FileInfo(full);
                if (info.Exists && info.Length == source.SizeBytes &&
                    await store.ComputeContentKeyAsync(full, null, ct).ConfigureAwait(false) == source.ContentKey) return full;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or HarnessException) { }
        }
        throw new HarnessException("The project's source video is missing. Relink it in VoxClip.");
    }

    private static long Integer(JsonElement arguments, string name, long fallback, long minimum, long maximum)
    {
        if (!arguments.TryGetProperty(name, out var field)) return fallback;
        if (field.ValueKind == JsonValueKind.Number)
        {
            if (field.TryGetInt64(out var exact) && exact >= minimum && exact <= maximum) return exact;
            var number = field.GetDouble();
            if (double.IsInteger(number) && number >= minimum && number < 9223372036854775808d && number <= maximum) return (long)number;
        }
        throw new HarnessException("The page offset or size is out of range.");
    }
}

using System.Runtime.InteropServices;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Frames;
using VoxClip.Media.Pipeline;

namespace VoxClip.Cli;

internal enum HarnessTool { ReadTranscript, ReadClips, ReadDecisions, ReadFrames, ProposeTimeline }

internal sealed record HarnessFrame(double Requested, double Actual, string Jpeg);

internal sealed record HarnessResult(object Fields, IReadOnlyList<HarnessFrame>? Frames = null)
{
    internal object CliOutput => Frames is null ? Fields : new { frames = Frames };
}

internal sealed class HarnessProject
{
    private static readonly JsonElement Empty = JsonSerializer.SerializeToElement(new { });
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
    private readonly string path;
    private readonly string id;

    private HarnessProject(string path, string id) { this.path = path; this.id = id; }

    internal static async Task<HarnessProject> OpenAsync(string path, CancellationToken ct)
    {
        path = HarnessInbox.CanonicalLocalPath(path, allowLinks: true);
        return new(path, (await ReadAsync(path, ct).ConfigureAwait(false)).Id);
    }

    internal async Task<HarnessResult> CallAsync(HarnessTool tool, JsonElement arguments, CancellationToken ct)
    {
        if (arguments.ValueKind == JsonValueKind.Undefined) arguments = Empty;
        var project = await ReadAsync(path, ct).ConfigureAwait(false);
        if (project.Id != id) throw new HarnessException("The selected project changed. Restart the connection.");
        switch (tool)
        {
            case HarnessTool.ReadTranscript:
                HarnessTimeline.RequireObject(arguments, ["offset", "limit"]);
                return Transcript(project, Integer(arguments, "offset", 0, 0, long.MaxValue), (int)Integer(arguments, "limit", 200, 1, 500));
            case HarnessTool.ReadClips:
                HarnessTimeline.RequireObject(arguments, []);
                return Clips(project);
            case HarnessTool.ReadDecisions:
                HarnessTimeline.RequireObject(arguments, ["clipId"]);
                return Decisions(project, arguments.TryGetProperty("clipId", out var clip) && clip.ValueKind == JsonValueKind.String ? clip.GetString() : null);
            case HarnessTool.ReadFrames:
                HarnessTimeline.RequireObject(arguments, ["times"]);
                return await FramesAsync(project, arguments, ct).ConfigureAwait(false);
            case HarnessTool.ProposeTimeline:
                var timelines = HarnessTimeline.ReadSeries(arguments);
                var shared = SharedResources.ResolveRoot();
                var proposal = new HarnessProposal(timelines, project);
                var pricedActions = new List<object>();
                var freeActions = new List<object>();
                const string approval = "In VoxClip only; the app confirms the price for the open clip.";
                for (var index = 0; index < timelines.Count; index++)
                {
                    var review = proposal.Review(project, shared, index);
                    foreach (var operation in review.Pending.OrderBy(operation => operation.Decision == ClipAutopilotDecision.Music ? 0 : 1))
                    {
                        switch (operation.Action)
                        {
                            case ClipAutopilotAction.Music music:
                                pricedActions.Add(new { kind = "generateMusic", prompt = music.Cue.Picked.Prompt,
                                    price = proposal.EstimatedMusicPrice(review.Project, shared, index), approval, timelineIndex = index });
                                break;
                            case ClipAutopilotAction.Asset { Kind: "illustration" } asset:
                                var quote = ClipIllustrationQuote.Load(shared).UsdPerImage.ToString(CultureInfo.InvariantCulture);
                                pricedActions.Add(new { kind = "generateIllustration", prompt = asset.Text, price = "$" + quote, approval, timelineIndex = index });
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
                await StageAsync(wire, ct).ConfigureAwait(false);
                return new(new { proposal = wire, pricedActions, freeActions });
            default: throw new ArgumentOutOfRangeException(nameof(tool));
        }
    }

    private static async Task<Project> ReadAsync(string path, CancellationToken ct)
    {
        if (!string.Equals(Path.GetExtension(path), ".voxclip", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(path, HarnessInbox.CanonicalLocalPath(path, allowLinks: false), PathComparison) ||
            (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.Device)) != 0)
            throw new HarnessException("Choose a saved .voxclip project file.");
        return ProjectSerialization.Deserialize(await File.ReadAllTextAsync(path, new UTF8Encoding(false, true), ct).ConfigureAwait(false));
    }

    private static HarnessResult Transcript(Project project, long offset, int limit)
    {
        var words = project.Transcript?.Words ?? [];
        var first = (int)Math.Min(offset, words.Count);
        var count = Math.Min(limit, words.Count - first);
        var cut = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var page = Enumerable.Range(first, count).Select(index => new
        {
            index, words[index].Id, words[index].Kind, words[index].Start, words[index].End,
            text = project.Edits.Corrections.GetValueOrDefault(words[index].Id, words[index].Text), cut = cut.Contains(words[index].Id)
        }).ToArray();
        return new(new { words = page, total = words.Count, nextOffset = first + count < words.Count ? (int?)(first + count) : null, language = project.Transcript?.Language });
    }

    private static HarnessResult Clips(Project project)
    {
        var indices = (project.Transcript?.Words ?? []).Select((word, index) => (word.Id, index))
            .ToDictionary(item => item.Id, item => (int?)item.index, StringComparer.Ordinal);
        var clips = project.Edits.Clips.Select(clip => new
        {
            clip.Id, clip.Title, clip.Selected, startWord = indices.GetValueOrDefault(clip.StartWordId), endWord = indices.GetValueOrDefault(clip.EndWordId),
            kind = clip.Kind == StoryClipKind.Showreel ? "showreel" : clip.Parts is null ? "stretch" : "story",
            parts = clip.PlayParts.Where(part => indices.ContainsKey(part.StartWordId) && indices.ContainsKey(part.EndWordId))
                .Select(part => new { startWord = indices[part.StartWordId], endWord = indices[part.EndWordId] }),
            sourceSpan = ClipControlsProject.SourceSpan(clip.Id, project) is { } span ? new TimeRange(span.Start, span.End) : (TimeRange?)null
        }).ToArray();
        var footageSources = (project.Media.AdditionalSources ?? []).Where(source => source.Video is not null).Select(source => new
        {
            sourceKey = source.FootageKey, duration = source.DurationSeconds, name = Path.GetFileName(source.AbsolutePath)
        });
        return new(new { projectId = project.Id, clips, footageSources });
    }

    private static HarnessResult Decisions(Project project, string? clipId)
    {
        var clip = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId)
            ?? throw new HarnessException("Choose a clip id from read_clips.");
        var result = project.Ai.Results.FirstOrDefault(item => item.Id == clip.AiResultId);
        var found = result is not null && clip.AiClipIndex is >= 0 and var index && index < result.Clips.Count ? result.Clips[index] : null;
        return new(new
        {
            clipId, clip.Title, findReason = found?.Reason, openingLeadInSeconds = clip.LeadInSeconds,
            controls = ClipControlsProject.Controls(clipId, project), captionStyle = project.CaptionsFor(clipId).StyleId,
            musicTracks = project.Music.Select(item => new { item.Id, item.Title, item.ClipId }).ToArray(),
            effects = project.ClipEffects.Select(ClipEffect.Parse).Where(effect => effect.ClipId == clipId).Select(effect => new
            {
                effect.Id, effect.Kind, effect.Start, effect.End, effect.Text, effect.Rect
            }).ToArray(),
            zooms = project.MotionCues.Where(cue => cue.ClipID == clipId).ToArray()
        });
    }

    private async Task<HarnessResult> FramesAsync(Project project, JsonElement arguments, CancellationToken ct)
    {
        var source = project.Media.Source;
        if (!arguments.TryGetProperty("times", out var requested) || requested.ValueKind != JsonValueKind.Array ||
            requested.GetArrayLength() is < 1 or > 4 || requested.EnumerateArray().Any(time => time.ValueKind != JsonValueKind.Number ||
                !(time.GetDouble() >= 0 && time.GetDouble() < source.DurationSeconds)))
            throw new HarnessException("Give one to four source times inside the video.");
        var mediaPath = await ResolveSourceAsync(source, ct).ConfigureAwait(false);
        using var reader = FfmpegFrameDecoder.OpenLocalQuickTime(mediaPath, 480, ct);
        var frames = requested.EnumerateArray().Select(item =>
        {
            var time = item.GetDouble();
            var frame = reader.Read(time, ct);
            return new HarnessFrame(time, frame.Time, Convert.ToBase64String(FrameJpeg.Encode(frame.Pixels, 480, 72)));
        }).ToArray();
        return new(new { frames = frames.Select(frame => new { frame.Requested, frame.Actual }).ToArray() }, frames);
    }

    private async Task<string> ResolveSourceAsync(MediaReference source, CancellationToken ct)
    {
        var candidates = new List<string> { source.AbsolutePath };
        if (source.RelativePath is { Length: > 0 } relative && !Path.IsPathRooted(relative) && !relative.Contains(':') && !relative.Contains('\\'))
            candidates.Add(Path.Join(Path.GetDirectoryName(path), relative));
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

    private async Task StageAsync(JsonObject proposal, CancellationToken ct)
    {
        var destination = path + ".proposal.json";
        var bytes = JsonSerializer.SerializeToUtf8Bytes(proposal, HarnessCommands.JsonOptions);
        if (bytes.Length > HarnessProposal.MaximumBytes) throw new HarnessException("This timeline proposal is too large.");
        var temporary = Path.Join(Path.GetDirectoryName(path), $".voxclip-proposal-{Guid.NewGuid():N}");
        var options = new FileStreamOptions { Access = FileAccess.Write, Mode = FileMode.CreateNew, Options = FileOptions.Asynchronous };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        var stream = new FileStream(temporary, options);
        try
        {
            await using (stream.ConfigureAwait(false)) await stream.WriteAsync(bytes, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (OperatingSystem.IsWindows()) File.Move(temporary, destination, overwrite: false);
            else if (Link(temporary, destination) != 0)
                throw new IOException("Can't publish the proposal next to the project.");
        }
        catch (IOException) when (Path.Exists(destination))
        {
            throw new HarnessException("Review the pending timeline in VoxClip before sending another.");
        }
        finally { File.Delete(temporary); }
    }

    [DllImport("libc", EntryPoint = "link")]
    private static extern int Link([MarshalAs(UnmanagedType.LPUTF8Str)] string source, [MarshalAs(UnmanagedType.LPUTF8Str)] string destination);

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

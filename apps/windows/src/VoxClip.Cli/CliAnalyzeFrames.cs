using System.CommandLine;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Frames;

namespace VoxClip.Cli;

/// <summary>What the analyzer measures with in this CLI: the face source (null is faces unavailable), the text lines and the decoder.</summary>
internal sealed record CliFrameSources(IFrameFaces? Faces, IFrameTextLines? Text, IFrameDecoding Decoder)
{
    /// <summary>What this build installs: the bundled face models when they verify and the catalogue is enabled (or
    /// <see cref="OnnxFrameFaces.OverrideVariable"/> is set; otherwise faces are unavailable), no text recognizer (Windows OCR is the
    /// App's: the CLI is portable net10.0, W6), and the shipped FFmpeg.</summary>
    internal static CliFrameSources Installed() => new(OnnxFrameFaces.Installed(), null, new FfmpegFrameDecoder());

    /// <summary>The text lines the analyzer reads, and whether they are only <see cref="NoFrameText"/> (faces only).</summary>
    internal (IFrameTextLines Lines, bool FacesOnly) TextOrNone => Text is { } text ? (text, false) : (NoFrameText.Instance, true);

    /// <summary>The cache the analyzer may use: none for faces only, whose observations have no text (the App's cache would read them as
    /// frames without screens).</summary>
    internal FrameAnalysisCache? Cache(bool wanted) => wanted && Text is not null ? new FrameAnalysisCache() : null;
}

/// <summary>No text recognizer: every frame has no text line, so no screen is found and no quad is looked for (faces only, W6).</summary>
internal sealed class NoFrameText : IFrameTextLines
{
    internal static NoFrameText Instance { get; } = new();
    public Task<IReadOnlyList<VoxClip.Core.Domain.Effects.ClipEffectRect>> LinesAsync(VoxClip.Core.Domain.Captions.PixelBuffer frame, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<VoxClip.Core.Domain.Effects.ClipEffectRect>>([]);
}

/// <summary><c>voxclip-cli analyze-frames --open &lt;project&gt; --clip &lt;id&gt; --json</c> (ADR-R48), twin of the Mac command: the
/// on-device frame analysis of one clip, the decisions made from it and the timings, without changing the project, in the Mac's
/// JSON shape. Nothing is sent anywhere. With faces unavailable it measures nothing and fails with <c>modelMissing</c> (exit 7).</summary>
internal static class CliAnalyzeFrames
{
    /// <summary>The line printed when the CLI has no text recognizer for the frames and faces only weren't asked for.</summary>
    internal const string TextUnavailableMessage = "Text recognition isn't available to voxclip-cli on this PC, so text and screens in the video's frames can't be measured. Nothing was analyzed. Pass --faces-only to measure faces alone.";
    /// <summary>The Windows-only flag that measures faces with no text source (W6).</summary>
    internal const string FacesOnly = "--faces-only";

    internal static async Task<JsonObject> RunAsync(ParseResult arguments, CliFrameSources sources, CancellationToken ct)
    {
        var input = CliOperations.Required(arguments, "--open");
        var clipId = arguments.GetValue<string?>("--clip");
        var transcriptPath = arguments.GetValue<string?>("--transcript");
        var wordRange = arguments.GetValue<string?>("--words");
        if (UsageError(clipId, transcriptPath, wordRange) is { } usage) throw new CliUsageException(usage);
        // Nothing is measured without faces: never an invented "no face".
        var faces = FrameFaces.Require(sources.Faces);
        // Without a text recognizer, faces only, when asked for: never textless frames that read as "no screen" by accident.
        var facesOnly = arguments.GetValue<bool>(FacesOnly);
        if (!facesOnly && sources.Text is null) throw new VoxClipException(VoxClipErrorCode.ModelMissing, TextUnavailableMessage);
        IFrameTextLines text = facesOnly ? NoFrameText.Instance : sources.Text!;

        Project project;
        string source;
        ClipRange range;
        if (transcriptPath is not null)
        {
            var words = await CliOperations.ReadTranscriptAsync(transcriptPath, ct).ConfigureAwait(false);
            if (Bounds(wordRange) is not { } bounds || bounds.First < 0 || bounds.First > bounds.Last || bounds.Last >= words.Words.Count)
                throw new CliUsageException("--words must name two word indices of the transcript, first:last.");
            var media = await CliOperations.ProbeInputAsync(input, ct).ConfigureAwait(false);
            var key = await ServicesMergeAdapter.Projects().ComputeContentKeyAsync(media.Path, null, ct).ConfigureAwait(false);
            project = CliOperations.NewProject(media, words, key);
            source = media.Path;
            range = new ClipRange("words", words.Words[bounds.First].Id, words.Words[bounds.Last].Id, null, ClipOrigin.Manual, null, null, false);
        }
        else
        {
            var opened = await ServicesMergeAdapter.Projects().LoadAsync(input, ct).ConfigureAwait(false);
            project = opened.Project;
            range = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId) ?? throw new CliUsageException("The requested clip does not exist.");
            source = opened.ResolvedMediaPath
                ?? throw new VoxClipException(VoxClipErrorCode.MediaMissing, $"Can't find {Path.GetFileName(project.Media.Source.AbsolutePath)}. Edits are saved.");
        }
        if (project.Transcript is not { } transcript) throw new VoxClipException(VoxClipErrorCode.NoSpeech, "This project has no transcript.");
        var frameClip = FrameClip.Make(transcript, range, project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal))
            ?? throw new CliUsageException("The requested clip has no kept words.");
        var contentKey = project.Media.Source.ContentKey;
        var cache = facesOnly || arguments.GetValue<bool>("--no-cache") ? null : new FrameAnalysisCache();
        var analyzer = new FrameAnalyzer(faces, FrameAnalyzer.ScreensWith(text), sources.Decoder, cache);
        JsonObject? pass = null;
        double? passBaseline = null;
        if (arguments.GetValue<bool>("--video-pass"))
            (pass, passBaseline) = await TimedPassAsync(analyzer, source, contentKey, transcript.Words, frameClip, ct).ConfigureAwait(false);
        var result = await analyzer.AnalyzeAsync(source, contentKey, frameClip, ct).ConfigureAwait(false);
        if (arguments.GetValue<string?>("--sheet-out") is { } folder) Write(result.Sheet, folder);
        // Facing is judged against the whole video's typical pitch, or the clip's own without the pass.
        var baseline = pass is not null ? passBaseline : result.Analysis.PitchBaseline;
        return Report(result.Analysis, frameClip, project.Media.Source.Video, result.Sheet, baseline, pass);
    }

    /// <summary>The Mac's option rules, checked as the command line is parsed (exit 2): a project needs <c>--clip</c> and no
    /// <c>--words</c>; a media file needs <c>--transcript</c>, <c>--words first:last</c> and no <c>--clip</c>.</summary>
    internal static string? UsageError(string? clip, string? transcript, string? words) => transcript is null
        ? clip is null || words is not null ? "A project needs --clip; --words goes with --transcript." : null
        : clip is not null || Bounds(words) is null ? "A media file needs --transcript and --words first:last." : null;

    private static (int First, int Last)? Bounds(string? range)
    {
        var parts = (range ?? "").Split(':');
        return parts.Length == 2 && int.TryParse(parts[0], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var first)
            && int.TryParse(parts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var last) ? (first, last) : null;
    }

    /// <summary>The whole video's pass as Claude mode runs it (ADR-R48 part 2), then the clip's frames from it and its opening scan, each
    /// timed in wall seconds to the millisecond, and the recording's typical pitch from the pass.</summary>
    internal static async Task<(JsonObject Fields, double? PitchBaseline)> TimedPassAsync(FrameAnalyzer analyzer, string source, string contentKey,
        IReadOnlyList<TimedWord> words, FrameClip clip, CancellationToken ct)
    {
        static double Since(Stopwatch watch) => Math.Round(watch.Elapsed.TotalSeconds * 1000, MidpointRounding.AwayFromZero) / 1000;
        var pass = new VideoFramePass(analyzer, source, contentKey, words, line => Console.Error.WriteLine(line));
        var watch = Stopwatch.StartNew();
        var read = await pass.FinishAsync(ct).ConfigureAwait(false);
        var passSeconds = Since(watch);
        watch.Restart();
        var frames = await pass.FramesAsync(clip, ct).ConfigureAwait(false);
        var clipSeconds = Since(watch);
        watch.Restart();
        var opening = await pass.OpeningAsync(clip, ct).ConfigureAwait(false);
        var openingSeconds = Since(watch);
        var baseline = await pass.PitchBaselineAsync(ct).ConfigureAwait(false);
        var fields = new JsonObject
        {
            ["read"] = read, ["frames"] = pass.FrameCount, ["analyzed"] = pass.Analyzed, ["cached"] = pass.Cached, ["seconds"] = passSeconds,
            ["clipFrames"] = frames?.Sentences.Count ?? 0, ["clipSeconds"] = clipSeconds,
            ["openingFrames"] = opening?.Count ?? 0, ["openingSeconds"] = openingSeconds, ["pitchBaseline"] = baseline,
        };
        return (fields, baseline);
    }

    /// <summary>The command's fields in the Mac's shape (the CLI adds <c>ok</c>, <c>command</c> and <c>version</c>): the clip's span, its
    /// analysis, the decisions made from it with facing judged against <paramref name="pitchBaseline"/>, the sheet's sizes and summary,
    /// and the whole video's pass when it ran.</summary>
    internal static JsonObject Report(FrameAnalysis analysis, FrameClip clip, VideoTrackInfo? video, FrameSheet sheet, double? pitchBaseline,
        JsonObject? videoPass)
    {
        var aspect = SourceAspect(video);
        var samples = analysis.Sentences.Select(frame => new FaceFollowSample(frame.Time, frame.Face?.Rect)).ToArray();
        var scan = analysis.Opening.Concat(analysis.Sentences).ToArray();
        var decisions = new JsonObject
        {
            ["pitchBaseline"] = pitchBaseline,
            ["opening"] = OpeningFrame.Choose(clip, analysis.Opening, pitchBaseline) is { } opening ? FrameJson.Write(opening) : null,
            ["cover"] = CoverFrame.Pick(scan, pitchBaseline) is { } cover ? FrameJson.Write(cover) : null,
            ["blurSpans"] = FrameJson.Array(FrameBlurSpans.Merge(analysis.Sentences, ClipFrameCandidates.BlurMaxGap, ClipFrameCandidates.BlurPad).Select(FrameJson.Write)),
            // What the plan request names (ai.md §19.6): screens B1… and covers C1…C3.
            ["blurCandidates"] = FrameJson.Array(ClipFrameCandidates.Blur(analysis.Sentences, clip.Start, clip.End).Select(FrameJson.Write)),
            ["coverCandidates"] = FrameJson.Array(ClipFrameCandidates.Cover(sheet.Frames, pitchBaseline).Select(FrameJson.Write)),
            ["crop9x16"] = FaceFollowCrop.Plan(samples, aspect, 9.0 / 16.0) is { } portrait ? FrameJson.Write(portrait) : null,
            ["crop1x1"] = FaceFollowCrop.Plan(samples, aspect, 1) is { } square ? FrameJson.Write(square) : null,
        };
        var fields = new JsonObject
        {
            ["clipStart"] = clip.Start, ["clipEnd"] = clip.End, ["analysis"] = FrameJson.Write(analysis), ["decisions"] = decisions,
            ["sheet"] = new JsonObject
            {
                ["frames"] = sheet.Frames.Count, ["imageBytes"] = sheet.ImageBytes, ["estimatedImageTokens"] = sheet.EstimatedImageTokens,
                ["estimatedSummaryTokens"] = sheet.EstimatedSummaryTokens(pitchBaseline), ["summary"] = sheet.Summary(pitchBaseline),
            },
        };
        if (videoPass is not null) fields["videoPass"] = videoPass;
        return fields;
    }

    /// <summary>The source picture's display width over height, after its rotation; 16:9 without video facts.</summary>
    internal static double SourceAspect(VideoTrackInfo? video)
    {
        if (video is null || video.Width <= 0 || video.Height <= 0) return 16.0 / 9.0;
        double width = video.Width, height = video.Height;
        return video.RotationDegrees % 180 == 0 ? width / height : height / width;
    }

    /// <summary>The sheet's JPEGs as <c>frame-01.jpg</c>… in <paramref name="folder"/>.</summary>
    internal static void Write(FrameSheet sheet, string folder)
    {
        Directory.CreateDirectory(folder);
        foreach (var frame in sheet.Frames)
        {
            var path = Path.Combine(folder, "frame-" + frame.Index.ToString("00", CultureInfo.InvariantCulture) + ".jpg");
            var temporary = path + ".partial";
            File.WriteAllBytes(temporary, frame.Image.Data);
            File.Move(temporary, path, overwrite: true);
        }
    }
}

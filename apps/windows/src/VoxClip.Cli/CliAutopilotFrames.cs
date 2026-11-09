using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Frames;
using Picture = VoxClip.Core.Domain.Frames.ClipPicture;

namespace VoxClip.Cli;

/// <summary>The picture in <c>voxclip-cli autopilot</c> (ADR-R48 part 2), twin of the Mac command's frames: the whole video's sentence-frame
/// pass beside Find Clips, each plan request's frames from it (small images to a CLI or local AI that takes them, else the text summary),
/// the clip's opening scan beside its request, and then the same four decisions Make it postable's rows apply (<see cref="Picture"/>), with
/// the Mac's <c>frames</c> and <c>picture</c> JSON. This CLI reads no text (Windows OCR is the App's), so it measures faces only: no screen
/// is found, nothing is blurred, and nothing is cached.</summary>
internal static class CliAutopilotFrames
{
    /// <summary>The stderr line that says what the CLI's frames can't show.</summary>
    internal const string FacesOnlyLine = "Frames: faces only. voxclip-cli reads no text, so screens in the frames aren't looked for.";

    /// <summary>The whole video's pass on this PC; null without faces (no face models), video facts, a source or words.</summary>
    internal static VideoFramePass? Pass(Project project, string? source, CliFrameSources sources, Action<string> line)
    {
        if (sources.Faces is not { } faces || source is null || project.Media.Source.Video is null ||
            project.Transcript?.Words is not { } words || !words.Any(word => word.Kind == WordKind.Word)) return null;
        var (text, facesOnly) = sources.TextOrNone;
        if (facesOnly) line(FacesOnlyLine);
        var analyzer = new FrameAnalyzer(faces, FrameAnalyzer.ScreensWith(text), sources.Decoder, sources.Cache(wanted: true));
        return new VideoFramePass(analyzer, source, project.Media.Source.ContentKey, words, line);
    }

    /// <summary>The shape an <c>--aspect</c> exports in.</summary>
    internal static ExportAspect Shape(string aspect) => aspect switch
    {
        "16:9" => ExportAspect.Landscape,
        "1:1" => ExportAspect.Square,
        _ => ExportAspect.Portrait
    };

    /// <summary>What a clip's request carried: the frames as sent, its sentence frames and its opening scan.</summary>
    internal sealed record Record(ClipAutopilotFrames Frames, IReadOnlyList<FrameObservation> Sentences, Task Opening);

    /// <summary>The frames each clip's request carried, by clip index.</summary>
    internal sealed class Sent
    {
        private readonly ConcurrentDictionary<int, Record> records = new();
        internal void Add(int index, Record record) => records[index] = record;
        internal Record? Of(int index) => records.GetValueOrDefault(index);
    }

    /// <summary>Each clip's frames as its request is sent: from the pass (waiting for it while it runs), the opening scan started beside the
    /// request and timed as <c>opening</c> for that clip.</summary>
    internal static ClipAutopilotFrameSource Source(VideoFramePass pass, IReadOnlyList<TimedWord> words, IReadOnlySet<string> cuts, bool images,
        ClaudeModeClock clock, Sent sent) => async (index, span, ct) =>
    {
        if (FrameClip.Make(words, span.Start, span.End, cuts) is not { } clip) return null;
        if (await pass.FramesAsync(clip, ct).ConfigureAwait(false) is not { } found) return null;
        clock.Begin(ClaudeModeStage.Opening, index + 1);
        var opening = Task.Run(async () =>
        {
            try { await pass.OpeningAsync(clip, CancellationToken.None).ConfigureAwait(false); }
            finally { clock.End(ClaudeModeStage.Opening, index + 1); }
        }, CancellationToken.None);
        var frames = ClipAutopilotFrames.FromSheet(found.Sheet, clip.Start, clip.End, images, await pass.PitchBaselineAsync(ct).ConfigureAwait(false));
        sent.Add(index, new(frames, found.Sentences, opening));
        return frames;
    };

    /// <summary>What the clip's request carried and what the plan chose from it: <c>sent</c>, <c>images</c>, <c>imageTokens</c>, the
    /// screens it chose to blur and the cover's time (the Mac's <c>framesJSON</c>).</summary>
    internal static JsonObject FramesJson(ClipAutopilotFrames frames, ClipAutopilotPlan plan)
    {
        var blurred = (plan.Frames?.BlurChoices ?? []).Where(choice => choice.Blurred).Select(choice => frames.BlurCandidateFor(choice.Id))
            .OfType<ClipAutopilotFrames.BlurCandidate>().Select(candidate => (JsonNode)new JsonObject { ["id"] = candidate.Id, ["start"] = candidate.Start, ["end"] = candidate.End });
        var cover = (plan.Frames?.CoverChoice is { } choice ? frames.CoverCandidateFor(choice.Id) : null) ?? frames.Cover.FirstOrDefault();
        return new JsonObject
        {
            ["sent"] = frames.Frames.Count, ["images"] = frames.SendsImages, ["imageTokens"] = frames.SendsImages ? frames.EstimatedImageTokens : 0,
            ["blur"] = new JsonArray(blurred.ToArray()), ["cover"] = cover is null ? null : JsonValue.Create(cover.Time)
        };
    }

    /// <summary>What the picture decisions came to, with Claude's reasons from the reply (about the creator's own footage; they stay on this
    /// PC): the opening's shift and why, the crop's centre and whether a face was measured, each screen's span and whether it is blurred,
    /// and the cover's time. Reasons are null where the reply gave none (or the cover fell back). The Mac's <c>pictureJSON</c>.</summary>
    internal static JsonObject PictureJson(Picture.Decisions picture, IReadOnlyList<FrameObservation> sentences, IReadOnlyList<ExportAspect> shapes)
    {
        static JsonNode? Reason(string? text) => text is null ? null : JsonValue.Create(text);
        var opening = picture.Opening is { } moved
            ? new JsonObject { ["shift"] = -moved.Earlier, ["leadIn"] = moved.LeadIn, ["start"] = moved.Start, ["frame"] = moved.Chosen, ["reason"] = moved.Reason }
            : new JsonObject { ["shift"] = 0, ["reason"] = null };
        JsonObject? crop = null;
        if (shapes.Where(shape => shape is ExportAspect.Portrait or ExportAspect.Square).Cast<ExportAspect?>().FirstOrDefault() is { } shape)
            crop = new JsonObject
            {
                ["aspect"] = shape == ExportAspect.Portrait ? "9:16" : "1:1", ["faceFound"] = sentences.Any(frame => frame.Face is not null),
                ["center"] = picture.Crop is { } centred ? new JsonObject { ["x"] = centred.CenterX, ["y"] = centred.CenterY } : null
            };
        var blur = picture.Blurs.Select(screen => (JsonNode)new JsonObject
        {
            ["id"] = screen.Candidate.Id, ["start"] = screen.Candidate.Start, ["end"] = screen.Candidate.End, ["blurred"] = screen.Blurred, ["reason"] = Reason(screen.Reason)
        }).ToArray();
        var cover = picture.Cover is { } chosen
            ? new JsonObject { ["id"] = chosen.Candidate.Id, ["time"] = chosen.Candidate.Time, ["fallback"] = !chosen.Named, ["reason"] = Reason(chosen.Reason) }
            : null;
        return new JsonObject { ["opening"] = opening, ["crop"] = crop, ["blur"] = new JsonArray(blur), ["cover"] = cover };
    }
}

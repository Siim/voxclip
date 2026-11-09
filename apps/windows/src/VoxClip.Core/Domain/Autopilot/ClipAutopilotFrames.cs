using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>What a clip's plan request shows the AI of its picture (ADR-R48 part 2, ai.md §19.6): the frame sheet's text summary,
/// always, and its small JPEGs when the connector takes images and the run may send them; plus the candidates the local analysis
/// names, so the reply can pick among them by id. Blur candidates are <c>B1…</c>, cover candidates <c>C1…C3</c>. Twin of the Mac
/// <c>ClipAutopilotFrames</c>. The editor and the CLI build it with <see cref="FromSheet"/> where faces can be measured on this PC
/// (W6); without a face source they send none.</summary>
public sealed record ClipAutopilotFrames(string Summary, IReadOnlyList<LlmImage> Images, IReadOnlyList<ClipAutopilotFrames.BlurCandidate> Blur,
    IReadOnlyList<ClipAutopilotFrames.CoverCandidate> Cover, int EstimatedImageTokens)
{
    /// <summary>The sheet's frames, sent as images or described in the summary.</summary>
    public IReadOnlyList<FrameSheetFrame> Frames { get; init; } = [];

    /// <summary>The frames of <paramref name="sheet"/> for a clip that plays <paramref name="clipStart"/>…<paramref name="clipEnd"/>
    /// (source seconds), with the images when <paramref name="images"/>; facing is judged against <paramref name="pitchBaseline"/>, the
    /// recording's typical pitch. Twin of the Mac <c>init(sheet:clipStart:clipEnd:images:pitchBaseline:)</c>.</summary>
    public static ClipAutopilotFrames FromSheet(FrameSheet sheet, double clipStart, double clipEnd, bool images, double? pitchBaseline)
    {
        ArgumentNullException.ThrowIfNull(sheet);
        return new(sheet.Summary(pitchBaseline), images ? sheet.Images : [],
            ClipFrameCandidates.Blur(sheet.Frames.Select(frame => frame.Observation), clipStart, clipEnd),
            ClipFrameCandidates.Cover(sheet.Frames, pitchBaseline), images ? sheet.EstimatedImageTokens : 0) { Frames = sheet.Frames };
    }

    /// <summary>A screen with text the reply decides to blur or leave sharp: source seconds, padded and kept inside the clip; the
    /// union of the screen's rects in picture space (top-left origin); and the sentence frames it was seen in.</summary>
    public sealed record BlurCandidate(string Id, double Start, double End, ClipEffectRect Rect, int Frames);
    /// <summary>A frame the reply may pick as the cover: the sheet frame's number ("Frame 3") and its source second.</summary>
    public sealed record CoverCandidate(string Id, int Frame, double Time, double Score);

    /// <summary>The images go with the request.</summary>
    public bool SendsImages => Images.Count > 0;
    /// <summary>The same frames as a text-only send: the summary and the candidates, no images.</summary>
    public ClipAutopilotFrames TextOnly => this with { Images = [], EstimatedImageTokens = 0 };
    /// <summary>The candidate a reply's blur id names.</summary>
    public BlurCandidate? BlurCandidateFor(string id) => Blur.FirstOrDefault(candidate => candidate.Id == id);
    /// <summary>The candidate a reply's cover id names.</summary>
    public CoverCandidate? CoverCandidateFor(string id) => Cover.FirstOrDefault(candidate => candidate.Id == id);

    /// <summary>Seconds as the sheet writes them: two decimals, by the Mac's rule (<see cref="FrameSheetFrame.Fixed"/>).</summary>
    internal static string Seconds(double value) => FrameSheetFrame.Fixed(value);
    /// <summary>A rect as the sheet writes it: "x,y,w,h" with two decimals each.</summary>
    internal static string RectText(ClipEffectRect rect) => FrameSheetFrame.RectText(rect);
}

/// <summary>A clip's frames, given just before its plan is sent (ADR-R48, ai.md §19.6): <c>clip</c> indexes the spans (0 of 1 for a
/// single clip) and <c>span</c> is the clip's transcript span. Each clip asks on its own lane. Null sends the clip as text only, as
/// before prompt version 8.</summary>
public delegate Task<ClipAutopilotFrames?> ClipAutopilotFrameSource(int clip, WordSpan span, CancellationToken ct);

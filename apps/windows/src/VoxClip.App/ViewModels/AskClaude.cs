using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Where one change of an Ask Claude answer stands (design §6.8).</summary>
public enum AskClaudeRowStatus
{
    /// <summary>In the project: ▶ · Adjust · Undo.</summary>
    Applied,
    /// <summary>Taken out again with its Undo.</summary>
    Undone,
    /// <summary>Waits for one priced click: a voice rewrite.</summary>
    Paid,
    /// <summary>The editor cannot make it yet; the row says why and that nothing changed.</summary>
    Later,
    /// <summary>A speed for part of a clip: the row offers that speed for the whole clip.</summary>
    WholeClip
}

/// <summary>One row of an Ask Claude answer: the operation, what it shows, and whether it is in the project. Twin of the Mac
/// <c>AskClaudeRow</c>.</summary>
public sealed class AskClaudeRow(ClipAutopilotOperation operation, AskClaudeRowStatus status, string title, string detail, string? choice)
{
    /// <summary>The operation's id.</summary>
    public string Id => Operation.Id;
    /// <summary>What Claude asked for.</summary>
    public ClipAutopilotOperation Operation { get; } = operation;
    /// <summary>Where it stands.</summary>
    public AskClaudeRowStatus Status { get; set; } = status;
    /// <summary>"Bleep", "Blur, tracked", "Sound: Pop".</summary>
    public string Title { get; } = title;
    /// <summary>Its time range and text.</summary>
    public string Detail { get; set; } = detail;
    /// <summary>"the face at the left": the pre-picked answer to an ambiguous instruction.</summary>
    public string? Choice { get; } = choice;
    /// <summary>A paid row's button: "Voice it · about $0.04".</summary>
    public string Price { get; init; } = "";
    /// <summary>A later row's reason, ending "Nothing changed."</summary>
    public string Reason { get; init; } = "";
    /// <summary>A partial stretch's clip, which the whole-clip action sets.</summary>
    public string? WholeClipId { get; init; }
}

/// <summary>The last Ask Claude request in this editor and its answer.</summary>
public sealed class AskClaudeRun(string instruction, AskClaudeSelection selection, string label)
{
#pragma warning disable CS1591
    public string Instruction { get; } = instruction;
    public AskClaudeSelection Selection { get; } = selection;
    public string Label { get; } = label;
    public List<AskClaudeRow> Rows { get; } = [];
    public string Summary { get; set; } = "";
    public IReadOnlyList<string> Repairs { get; set; } = [];
#pragma warning restore CS1591
    /// <summary>The project before the answer applied: Undo reads previous corrections, cuts, ducking and speed from it.</summary>
    public Project? Base { get; set; }
    /// <summary>Rows in the project now.</summary>
    public int AppliedCount => Rows.Count(row => row.Status == AskClaudeRowStatus.Applied);
}

/// <summary>What the page sends for one Ask Claude request: the checked selection, the project as it was, the detections and the
/// export shape, with the selection's word count for the consent line.</summary>
public sealed record AskClaudeAsk(string Instruction, AskClaudeSelection Selection, Project Project, IReadOnlyList<AskClaudeDetection> Detections, string Aspect, int WordCount);

/// <summary>Ask Claude's seam (design §6.8): the page sends through the chosen AI after its inline confirmation, and Windows Vision
/// (<see cref="IAskClaudeVision"/>, FaceDetector and OcrEngine) looks at the picture; tests pass stubs.</summary>
public sealed class AskClaudeServices
{
    /// <summary>Sends one request and returns Claude's checked answer; throws on a failure, cancellation or a declined confirmation.</summary>
    public required Func<AskClaudeAsk, CancellationToken, Task<AskClaudeAnswer>> Ask { get; init; }
    /// <summary>Whether an AI is chosen: ✦ Ask Claude shows only then.</summary>
    public required Func<bool> Available { get; init; }
    /// <summary>The footer's cost: "Free on your Claude plan", "Billed to your Anthropic key", "Free on this PC".</summary>
    public required Func<string> CostLine { get; init; }
    /// <summary>On-screen faces and text over a stretch, and face tracks; null sends no detections and holds every box still.</summary>
    public IAskClaudeVision? Vision { get; init; }
    /// <summary>Text-to-speech prices for the "Voice it · about $x" row.</summary>
    public VoiceLabPriceCatalog? Prices { get; init; }
}

/// <summary>The editor's Ask Claude state (design §6.8): the inline field, the run, the timeline range and the open Adjust row.</summary>
public sealed class AskClaudeState
{
    /// <summary>The field's placeholder: it takes both kinds of request, and Claude decides.</summary>
    public const string Placeholder = "Say what to change: reword it, bleep it, blur, add a title…";

    /// <summary>"Edit the video here": each chip only fills the field.</summary>
    public static IReadOnlyList<(string Label, string Text)> Chips { get; } =
    [
        ("Bleep it", "Bleep these words"), ("Blur the screen", "Blur the screen"), ("Add a title “Day 1”", "Add a title “Day 1”"),
        ("Arrow at the button", "Put an arrow at the button"), ("Emoji reaction", "Add an emoji reaction"), ("Slow-mo this bit", "Slow this bit down"),
        ("Zoom in", "Zoom in on this")
    ];

    /// <summary>The field is open on this selection.</summary>
    public AskClaudeSelection? Selection { get; set; }
#pragma warning disable CS1591
    public string Label { get; set; } = "";
    public string Text { get; set; } = "";
    public bool Asking { get; set; }
    public string? Progress { get; set; }
    public string? Error { get; set; }
    public AskClaudeRun? Run { get; set; }
#pragma warning restore CS1591
    /// <summary>The last range dragged on the timeline, in source seconds; the toolbar's ✦ Ask Claude asks about it.</summary>
    public (double Start, double End)? TimeRange { get; set; }
    /// <summary>The row whose Adjust editor is open.</summary>
    public string? Adjusting { get; set; }
    /// <summary>"More…" in "Reword these words" shows every tone.</summary>
    public bool AllTones { get; set; }
    /// <summary>The request under way.</summary>
    public Task? Task { get; set; }
    internal CancellationTokenSource? Cancellation { get; set; }
    /// <summary>The field or the change list is showing.</summary>
    public bool IsOpen => Selection is not null || Run is not null;
}

/// <summary>Where Adjust draws an effect's box on the viewer (design §6.8): the rect as filmed, through the open clip's flip and quarter
/// turns (<see cref="ClipControlsRendering.MapRect"/>) and the export's centred crop of the turned picture, so it sits on the rendered
/// effect; a drag maps back (<see cref="ClipControlsRendering.UnmapRect"/>). Twin of the Mac <c>AskClaudeRectOverlay</c>.</summary>
public static class AskClaudeRectGeometry
{
    /// <summary>The open clip's controls, which flip and turn the picture; null on Full Take.</summary>
    public static ProjectClipControls? Controls(Project project) => ClipControlsRendering.Controls(project, project.Edits.ActiveClipId);

    /// <summary>Stage points per unit of picture space: the export crop of the oriented source, turned as the clip turns it.</summary>
    public static (double Width, double Height) PictureScale(Project project, double stageWidth, double stageHeight)
    {
        var video = project.Media.Source.Video;
        var oriented = video is null ? new PixelSize(1920, 1080) : video.RotationDegrees is 90 or 270 ? new PixelSize(video.Height, video.Width) : new PixelSize(video.Width, video.Height);
        var controls = Controls(project);
        var source = controls?.IsQuarterTurn() == true ? new PixelSize(oriented.Height, oriented.Width) : oriented;
        var frame = ClipControlsRendering.OutputSize(oriented, project.Export.Aspect, controls);
        var ratio = frame.Height > 0 ? (double)frame.Width / frame.Height : 16.0 / 9;
        double width = source.Width, height = source.Height;
        var cropWidth = width / height > ratio ? height * ratio : width;
        var cropHeight = width / height > ratio ? height : width / ratio;
        return (stageWidth * width / cropWidth, stageHeight * height / cropHeight);
    }

    /// <summary>The box on a stage of <paramref name="stageWidth"/> × <paramref name="stageHeight"/>, top-left origin; null outside it.</summary>
    public static (double X, double Y, double Width, double Height)? Frame(ClipEffectRect filmed, Project project, double stageWidth, double stageHeight)
    {
        if (stageWidth <= 0 || stageHeight <= 0) return null;
        var rect = Controls(project).MapRect(filmed);
        var scale = PictureScale(project, stageWidth, stageHeight);
        var x = stageWidth / 2 + (rect.X - 0.5) * scale.Width;
        var y = stageHeight / 2 + (rect.Y - 0.5) * scale.Height;
        var width = rect.Width * scale.Width;
        var height = rect.Height * scale.Height;
        return x < stageWidth && y < stageHeight && x + width > 0 && y + height > 0 ? (x, y, width, height) : null;
    }

    /// <summary>The rect as filmed after its box is dragged by (<paramref name="dx"/>, <paramref name="dy"/>) stage points, kept inside the frame.</summary>
    public static ClipEffectRect Dragged(ClipEffectRect filmed, double dx, double dy, Project project, double stageWidth, double stageHeight)
    {
        var controls = Controls(project);
        var scale = PictureScale(project, stageWidth, stageHeight);
        if (scale.Width <= 0 || scale.Height <= 0) return filmed;
        var shown = controls.MapRect(filmed);
        shown = AskClaudeValidator.Clamped(shown with { X = shown.X + dx / scale.Width, Y = shown.Y + dy / scale.Height });
        return AskClaudeValidator.Clamped(controls.UnmapRect(shown));
    }

    /// <summary>A box scaled about its centre by <paramref name="factor"/>, kept inside the frame.</summary>
    public static ClipEffectRect Scaled(ClipEffectRect rect, double factor) => AskClaudeVision.Grown(rect, factor - 1);
}

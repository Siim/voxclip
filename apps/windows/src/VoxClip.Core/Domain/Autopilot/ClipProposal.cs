using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.Autopilot;

public sealed record ClipProposal(ClipProposal.TargetChoice Target, string Reason)
{
    public sealed record Part(int StartWord, int EndWord);
    public sealed record NewClip(string Kind, string Title);
    public sealed record TargetChoice(string? ClipId = null, NewClip? New = null);
    public sealed record MusicChoice(string? TrackId = null, string? Brief = null);

    public IReadOnlyList<Part>? Parts { get; init; }
    public IReadOnlyList<ClipAutopilotPlan.Cut>? Cuts { get; init; }
    public IReadOnlyList<ClipAutopilotPlan.PauseCut>? PauseCuts { get; init; }
    public IReadOnlyList<ClipAutopilotPlan.Correction>? Corrections { get; init; }
    public string? CaptionStyle { get; init; }
    public ClipAutopilotFont? Font { get; init; }
    [JsonPropertyName("case")] public ClipAutopilotCaptionCase? TextCase { get; init; }
    public int? WordsPerCaption { get; init; }
    public ClipAutopilotPlan.Look? Look { get; init; }
    public ClipAutopilotPlan.Speed? Speed { get; init; }
    public string? Hook { get; init; }
    public string? Title { get; init; }
    public string? PostText { get; init; }
    public string? CoverTitle { get; init; }
    public MusicChoice? Music { get; init; }
    public IReadOnlyList<ClipPlanEffect>? Effects { get; init; }
    public IReadOnlyList<ClipAutopilotPlan.Rewrite>? Rewrites { get; init; }
}

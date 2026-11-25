using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>The common clip proposal for the planner and harness.</summary>
public sealed record ClipProposal(ClipProposal.TargetChoice Target, string Reason)
{
    /// <summary>An inclusive range of source words.</summary>
    public sealed record Part(int StartWord, int EndWord);
    /// <summary>The shape and title for a new clip.</summary>
    public sealed record NewClip(string Kind, string Title);
    /// <summary>Either a new clip or the ID of an existing clip.</summary>
    public sealed record TargetChoice(string? ClipId = null, NewClip? New = null);
    /// <summary>Either a saved track or a brief for pending music.</summary>
    public sealed record MusicChoice(string? TrackId = null, string? Brief = null);

    /// <summary>The ordered source ranges, including the legacy single-span fallback.</summary>
    public IReadOnlyList<Part>? Parts { get; init; }
    /// <summary>Word cuts requested by the proposal.</summary>
    public IReadOnlyList<ClipAutopilotPlan.Cut>? Cuts { get; init; }
    /// <summary>Pauses to tighten.</summary>
    public IReadOnlyList<ClipAutopilotPlan.PauseCut>? PauseCuts { get; init; }
    /// <summary>Transcript corrections that do not change the audio.</summary>
    public IReadOnlyList<ClipAutopilotPlan.Correction>? Corrections { get; init; }
    /// <summary>The caption style ID.</summary>
    public string? CaptionStyle { get; init; }
    /// <summary>A caption font override.</summary>
    public ClipAutopilotFont? Font { get; init; }
    /// <summary>A caption text-case override.</summary>
    [JsonPropertyName("case")] public ClipAutopilotCaptionCase? TextCase { get; init; }
    /// <summary>An override of the caption page size.</summary>
    public int? WordsPerCaption { get; init; }
    /// <summary>A clip-wide colour look.</summary>
    public ClipAutopilotPlan.Look? Look { get; init; }
    /// <summary>A clip-wide playback rate.</summary>
    public ClipAutopilotPlan.Speed? Speed { get; init; }
    /// <summary>The opening title card text.</summary>
    public string? Hook { get; init; }
    /// <summary>The proposed clip title.</summary>
    public string? Title { get; init; }
    /// <summary>The proposed share text.</summary>
    public string? PostText { get; init; }
    /// <summary>The optional short title for the cover.</summary>
    public string? CoverTitle { get; init; }
    /// <summary>The proposed music choice.</summary>
    public MusicChoice? Music { get; init; }
    /// <summary>Canonical timed effects.</summary>
    public IReadOnlyList<ClipPlanEffect>? Effects { get; init; }
    /// <summary>Pending revoice requests.</summary>
    public IReadOnlyList<ClipAutopilotPlan.Rewrite>? Rewrites { get; init; }
}

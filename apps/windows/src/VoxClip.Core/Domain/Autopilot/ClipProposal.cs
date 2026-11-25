using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Autopilot;

#pragma warning disable CS1591
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

    public static ClipProposal FromPlan(ClipAutopilotPlan plan, string clipId, Project project)
    {
        var existing = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId);
        return new(existing is null ? new(New: new("stretch", plan.Title)) : new(ClipId: clipId), "")
        {
            Parts = existing?.Parts is null ? [new(plan.StartWord, plan.EndWord)] : null,
            Cuts = plan.Cuts, PauseCuts = plan.PauseCuts, Corrections = plan.Corrections, Rewrites = plan.Rewrites,
            CaptionStyle = plan.CaptionChoice.StyleId, Font = plan.CaptionChoice.Font, TextCase = plan.CaptionChoice.TextCase,
            WordsPerCaption = plan.CaptionChoice.WordsPerCaption, Look = plan.ClipLookChoice, Speed = plan.SpeedChoice,
            Effects = plan.Effects, Hook = plan.Hook, Title = plan.Title, PostText = plan.PostText,
            CoverTitle = plan.Frames?.CoverChoice?.Title, Music = plan.PickedMusic is { } picked ? new(Brief: picked.Prompt) : null,
        };
    }
}
#pragma warning restore CS1591

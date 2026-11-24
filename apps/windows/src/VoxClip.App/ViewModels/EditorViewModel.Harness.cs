using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.ViewModels;

internal sealed record HarnessReviewDetails(string ClipTitle, string Reason, IReadOnlyList<string> Changes, string? MusicPrompt,
    string? MusicEstimate, string? Blocked);

internal sealed record HarnessMusicAction(string ClipId, string SourceKey, string Prompt);

public sealed partial class EditorViewModel
{
    internal HarnessProposal? ReadHarnessProposal(string projectPath) => HarnessInbox.Read(projectPath);

    internal string? HarnessKeepBlocked => IsReadOnly || state is null
        ? "Open a writable project with its source video to keep this timeline."
        : IsLeaving || Busy || undoGroup is { OwnsEdits: true } || Music.Phase is MusicPanelPhase.Searching or MusicPanelPhase.Using
            ? "Finish the current action before keeping this timeline." : null;

    internal HarnessReviewDetails DescribeHarnessProposal(HarnessProposal proposal, string? sharedRoot)
    {
        var timeline = proposal.Timeline;
        var clipId = timeline.GetProperty("clipId").GetString();
        var clipTitle = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId)?.Title ?? "Clip";
        var changes = new List<string>();
        if (timeline.TryGetProperty("title", out var title)) changes.Add($"Title: {title.GetString()}");
        if (timeline.TryGetProperty("captionStyle", out var caption)) changes.Add($"Captions: {caption.GetString()}");
        if (timeline.TryGetProperty("musicTrackId", out var track))
        {
            var trackId = track.GetString();
            changes.Add($"Reuse music: {project.Music.FirstOrDefault(item => item.Id == trackId)?.Title ?? trackId}");
        }
        if (timeline.TryGetProperty("cuts", out var cuts))
            changes.AddRange(cuts.EnumerateArray().Select(change => DescribeCut(change)));
        if (timeline.TryGetProperty("effects", out var effects))
            changes.AddRange(effects.EnumerateArray().Select(effect => $"{EffectLabel(effect)}: {effect.GetProperty("reason").GetString()}"));
        var prompt = timeline.TryGetProperty("generateMusic", out var music) ? music.GetString() : null;
        string? estimate = null;
        string? blocked = null;
        if (sharedRoot is null) blocked = "VoxClip can't read its timeline resources.";
        else
        {
            try { estimate = proposal.EstimatedMusicPrice(proposal.Applying(project, sharedRoot), sharedRoot); }
            catch (HarnessException exception) { blocked = exception.Message; }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or VoxClipException)
            { blocked = "VoxClip can't validate this timeline. Your project is unchanged."; }
        }
        return new(clipTitle, timeline.GetProperty("reason").GetString()!, changes, prompt, estimate, blocked);
    }

    internal HarnessMusicAction? KeepHarnessProposal(HarnessProposal proposal, string projectPath, string sharedRoot)
    {
        if (HarnessKeepBlocked is { } blocked) throw new HarnessException(blocked);
        var next = proposal.Applying(project, sharedRoot);
        DismissHarnessProposal(proposal, projectPath);
        ReplaceProject(next, "Keep timeline proposal");
        return proposal.Timeline.TryGetProperty("generateMusic", out var prompt)
            ? new(proposal.Timeline.GetProperty("clipId").GetString()!, next.Media.Source.ContentKey, prompt.GetString()!) : null;
    }

    internal void DismissHarnessProposal(HarnessProposal proposal, string projectPath)
    {
        if (IsLeaving) throw new HarnessException("The pending timeline changed. Review it again.");
        HarnessInbox.Dismiss(proposal, projectPath);
    }

    private string DescribeCut(JsonElement change)
    {
        var start = change.GetProperty("startWord").GetDouble();
        var end = change.GetProperty("endWord").GetDouble();
        var label = $"Cut words {start}–{end}";
        if (start <= end && end < Words.Count)
        {
            var words = Words.Skip((int)start).Take((int)(end - start + 1)).Where(word => word.Kind == WordKind.Word).Take(13).ToArray();
            if (words.Length > 0) label = $"Cut “{string.Join(" ", words.Take(12).Select(DisplayText))}{(words.Length > 12 ? "…" : "")}”";
        }
        return $"{label}: {change.GetProperty("reason").GetString()}";
    }

    private static string EffectLabel(JsonElement effect)
    {
        var label = effect.GetProperty("kind").GetString() switch
        {
            "zoom" => "Zoom", "punchIn" => "Punch in", "motionTitle" => "Animated title",
            "lowerThird" => "Lower third", "emojiPop" => "Emoji pop", _ => "Motion template"
        };
        if (effect.TryGetProperty("template", out var template))
        {
            label = template.GetProperty("name").GetString() switch
            {
                "titleCard" => "Title card", "kineticCaption" => "Kinetic caption", "logoSting" => "Logo sting", _ => "Counter"
            };
            if (template.TryGetProperty("text", out var text)) return $"{label} “{text.GetString()}”";
            return $"{label} {template.GetProperty("from")} to {template.GetProperty("to")}";
        }
        return effect.TryGetProperty("text", out var value) ? $"{label} “{value.GetString()}”" : label;
    }
}

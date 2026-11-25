using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record ClipPartRow(ClipPart Part, int Number, int First, int Last, string Excerpt, double Start, double End)
{
    internal string Id => Part.Id;
    internal string TakeTime => $"{EditorViewModel.Duration(Start)}–{EditorViewModel.Duration(End)}";
}

internal sealed record StoryVoiceActions(string RewriteReason, string LipSyncReason, string MakeSelected, string MakeAll,
    decimal? VoiceAndLipSync, decimal? LipSync);

public sealed partial class EditorViewModel
{
    private string? selectedPartId;
    internal ClipRange? ActiveClip => state?.Clips.FirstOrDefault(clip => clip.Id == state.ActiveClipId);
    internal bool IsStoryClip => ActiveClip?.Parts is not null;
    internal IReadOnlyList<ClipPartRow> ClipParts { get; private set; } = [];
    internal ClipPartRow? SelectedPart => ClipParts.FirstOrDefault(part => part.Id == selectedPartId) ?? ClipParts.FirstOrDefault();
    internal bool CanEditParts => ActiveClip is not null && !IsReadOnly && !isLeaving && !Busy;
    internal const string AddPartReason = "Select words outside the clip's parts to add them.";
    internal const string LastPartReason = "A clip needs one part. Remove Clip instead.";
    internal const string StoryRewriteReason = "Voice changes work on one part at a time. Make a clip of the part first.";
    internal bool CanAddPart => CanEditParts && ClipParts.Count < 12 && HasSelection &&
        ClipParts.All(part => SelectionEnd < part.First || SelectionStart > part.Last) &&
        Words.Skip(SelectionStart).Take(SelectionEnd - SelectionStart + 1).Any(word => state?.CutWordIds.Contains(word.Id) != true);
    internal string AddPartHelp => ClipParts.Count == 12 ? "A clip can have up to 12 parts." : CanAddPart ? "" : AddPartReason;
    internal bool CanRemovePart => CanEditParts && ClipParts.Count > 1;
    internal string? RemovePartHelp => ClipParts.Count == 1 ? LastPartReason : null;

    internal StoryVoiceActions? StoryVoice(string? clipId = null, VoiceLabPriceCatalog? prices = null)
    {
        var clip = clipId is null ? ActiveClip : state?.Clips.FirstOrDefault(clip => clip.Id == clipId);
        if (clip?.Parts is not { } parts) return null;
        var number = clip.Id == ActiveClip?.Id ? SelectedPart?.Number ?? 1 : 1;
        WholeClipRevoice.Price? estimate = null;
        if (prices is not null && state is not null && clip.PlayPartIndices(Words) is { } spans)
        {
            var length = Clips.FirstOrDefault(row => row.Id == clip.Id)?.DurationSeconds ?? 0;
            var script = string.Join(" ", spans.SelectMany(span => Words.Skip(span.Start).Take(span.End - span.Start + 1))
                .Where(word => !state.CutWordIds.Contains(word.Id)).Select(DisplayText));
            estimate = WholeClipRevoice.PriceFor(VoiceLabTextLength.Length(script), VoiceLabWordingFit.ModelId,
                length, WholeClipLipsyncValues.Standard, prices);
        }
        return new(StoryRewriteReason, $"Lip sync can't run across the {parts.Count - 1} seams of a story clip yet. Make a clip of the part first.",
            $"Make Clip of Part {number}", $"Make Clips of All {parts.Count} Parts", estimate?.Usd, estimate?.Lipsync.Usd);
    }

    internal static string StoryVoicePrice(string label, decimal? usd) =>
        $"{label} · {(usd is { } price ? VoiceLabCostPresentation.Format(price) : "Price unavailable")}";

    private void RefreshClipParts()
    {
        ClipParts = ActiveClip?.PlayParts.Select((part, index) =>
        {
            var first = Index(part.StartWordId);
            var last = Index(part.EndWordId);
            return first < 0 || last < first ? null : new ClipPartRow(part, index + 1, first, last,
                string.Join(" ", Words.Skip(first).Take(Math.Min(8, last - first + 1)).Select(DisplayText)), Words[first].Start, Words[last].End);
        }).OfType<ClipPartRow>().ToArray() ?? [];
        selectedPartId = SelectedPart?.Id;
    }

    internal bool SelectPart(string id)
    {
        if (ClipParts.FirstOrDefault(part => part.Id == id) is not { } selected) return false;
        selectedPartId = id;
        Select(selected.First);
        return true;
    }

    internal bool MovePart(string id, int destination)
    {
        if (!CanEditParts || ClipParts.FirstOrDefault(part => part.Id == id) is not { } moving ||
            destination < 0 || destination >= ClipParts.Count || destination == moving.Number - 1) return false;
        var parts = ClipParts.Select(part => part.Part).ToList();
        parts.RemoveAt(moving.Number - 1);
        parts.Insert(destination, moving.Part);
        return ChangeParts(parts, id, "Move part", $"Part {moving.Number} moved to {destination + 1} of {parts.Count}");
    }

    internal int? PartDropIndex(string movingId, string targetId, bool after)
    {
        if (!CanEditParts || movingId == targetId ||
            ClipParts.FirstOrDefault(part => part.Id == movingId) is not { } moving ||
            ClipParts.FirstOrDefault(part => part.Id == targetId) is not { } target) return null;
        var destination = target.Number - 1 + (after ? 1 : 0) - (moving.Number < target.Number ? 1 : 0);
        return destination == moving.Number - 1 ? null : destination;
    }

    internal bool AddSelectionAsPart()
    {
        if (!CanAddPart) return false;
        var part = new ClipPart($"part-{Guid.NewGuid():N}", Words[SelectionStart].Id, Words[SelectionEnd].Id);
        return ChangeParts([.. ClipParts.Select(row => row.Part), part], part.Id, "Add part", $"Added part {ClipParts.Count + 1}");
    }

    internal bool RemovePart(string id)
    {
        if (!CanRemovePart || ClipParts.FirstOrDefault(part => part.Id == id) is not { } removed) return false;
        var parts = ClipParts.Where(part => part.Id != id).Select(part => part.Part).ToArray();
        var select = SelectedPart?.Id == id ? parts[Math.Min(removed.Number - 1, parts.Length - 1)].Id : SelectedPart?.Id;
        return ChangeParts(parts, select, "Remove part", $"Removed part {removed.Number}");
    }

    private bool TrimPart(ClipPartRow part, bool start, int target)
    {
        if (!CanEditParts || target < 0 || target >= Words.Count) return false;
        var first = start ? target : part.First;
        var last = start ? part.Last : target;
        if (first > last || ClipParts.Any(other => other.Id != part.Id && first <= other.Last && other.First <= last)) return false;
        var trimmed = part.Part with { StartWordId = Words[first].Id, EndWordId = Words[last].Id };
        return ChangeParts(ClipParts.Select(row => row.Id == part.Id ? trimmed : row.Part).ToArray(), part.Id,
            "Trim part", $"Trimmed part {part.Number}");
    }

    private bool ChangeParts(IReadOnlyList<ClipPart> parts, string? select, string action, string announcement)
    {
        if (ActiveClip is not { } clip) return false;
        var previous = selectedPartId;
        selectedPartId = select;
        if (!ApplyBatch([new EditOperation.SetClipParts(clip.Id, parts)], action))
        {
            selectedPartId = previous;
            return false;
        }
        Announce(ActiveClip?.Id == clip.Id ? announcement : $"{announcement}. Made a copy to keep the paid voice edits.");
        return true;
    }

    internal bool MakeClipsOfParts(string? partId = null)
    {
        if (!CanEditParts || !IsStoryClip || ActiveClip is not { } clip) return false;
        var parts = ClipParts.Where(part => partId is null || part.Id == partId).ToArray();
        if (parts.Length == 0) return false;
        return Announce(ApplyBatch(parts.Select(part => new EditOperation.MakeClipOfPart(clip.Id, part.Id)),
            partId is null ? "Make clips of all parts" : "Make clip of part"),
            () => partId is null ? $"Made clips of all {parts.Length} parts" : $"Made a clip of part {parts[0].Number}");
    }
}

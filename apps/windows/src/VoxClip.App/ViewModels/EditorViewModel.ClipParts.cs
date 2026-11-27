using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record ClipPartRow(ClipPart Part, int Number, int First, int Last, string Excerpt, double Start, double End,
    ProjectClock.Region? Recording = null, double RecordingOffset = 0, bool RecordingShade = false, bool UsesLocalClock = false)
{
    internal string Id => Part.Id;
    internal string TakeTime => $"{LocalTime(Start)}–{LocalTime(End)}";
    internal string LocalTime(double seconds) => UsesLocalClock ? EditorViewModel.RecordingTime(seconds - RecordingOffset) : EditorViewModel.Duration(seconds);
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
        PartSelectionReason is null &&
        ClipParts.All(part => SelectionEnd < part.First || SelectionStart > part.Last) &&
        Words.Skip(SelectionStart).Take(SelectionEnd - SelectionStart + 1).Any(word => state?.CutWordIds.Contains(word.Id) != true);
    internal string AddPartHelp => ClipParts.Count == 12 ? "A clip can have up to 12 parts." : PartSelectionReason ?? (CanAddPart ? "" : AddPartReason);
    private string? PartSelectionReason
    {
        get
        {
            if (!HasSeveralRecordings || !HasSelection || RecordingOf(SelectionStart) is not { } first) return null;
            var expected = PartPickRecording ?? first;
            if (first != expected || RecordingOf(SelectionEnd) != expected)
                return $"A part comes from one recording. Select words in {expected.Label} only.";
            return RecordingUnavailable(expected.Key);
        }
    }
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
        var recordingReason = RecordingVoiceReason(clip.Id, wholeScope: true);
        return new(recordingReason ?? StoryRewriteReason, recordingReason ?? $"Lip sync can't run across the {parts.Count - 1} seams of a story clip yet. Make a clip of the part first.",
            $"Make Clip of Part {number}", $"Make Clips of All {parts.Count} Parts", estimate?.Usd, estimate?.Lipsync.Usd);
    }

    internal static string StoryVoicePrice(string label, decimal? usd) =>
        $"{label} · {(usd is { } price ? VoiceLabCostPresentation.Format(price) : "Price unavailable")}";

    private void RefreshClipParts()
    {
        ProjectClock.Region? previous = null;
        var shade = false;
        ClipParts = ActiveClip?.PlayParts.Select((part, index) =>
        {
            var first = Index(part.StartWordId);
            var last = Index(part.EndWordId);
            var recording = RecordingOf(first);
            shade = recording == previous && !shade;
            previous = recording;
            return first < 0 || last < first ? null : new ClipPartRow(part, index + 1, first, last,
                string.Join(" ", Words.Skip(first).Take(Math.Min(8, last - first + 1)).Select(DisplayText)), Words[first].Start, Words[last].End,
                recording, recording is null ? 0 : (double)recording.OffsetSamples / RecordingClock!.SampleRate, shade, HasSeveralRecordings);
        }).OfType<ClipPartRow>().ToArray() ?? [];
        if (ClipParts.All(part => part.Id != selectedPartId)) selectedPartId = null;
    }

    internal bool SelectPart(string id)
    {
        if (ClipParts.FirstOrDefault(part => part.Id == id) is not { } selected) return false;
        selectedPartId = id;
        FollowRecording(selected.First);
        Select(selected.First);
        return true;
    }

    internal bool MovePart(string id, int destination)
    {
        if (!CanEditParts || ClipParts.FirstOrDefault(part => part.Id == id) is not { } moving ||
            destination < 0 || destination >= ClipParts.Count || destination == moving.Number - 1) return false;
        var remaining = ClipParts.Where(part => part.Id != id).ToArray();
        return ApplyRecordingEdit(new RecordingEdit.MovePart(ActiveClip!.Id, id, destination == 0 ? null : remaining[destination - 1].Id),
            id, $"Part {moving.Number} moved to {destination + 1} of {ClipParts.Count}");
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
        return AddRecordingPart(SelectionStart, SelectionEnd);
    }

    private bool AddRecordingPart(int first, int last)
    {
        var part = new ClipPart($"part-{Guid.NewGuid():N}", Words[first].Id, Words[last].Id);
        var anchor = PartInsertionAnchor;
        var announcement = HasSeveralRecordings && RecordingOf(first) is { } recording
            ? $"Part {RecordingPartNumber} added from {recording.Label}" + (anchor is null ? "" : $", after part {anchor.Number}")
            : $"Added part {ClipParts.Count + 1}";
        return ApplyRecordingEdit(new RecordingEdit.AddPart(ActiveClip!.Id, part, anchor?.Id), part.Id, announcement);
    }

    internal bool RemovePart(string id)
    {
        if (!CanRemovePart || ClipParts.FirstOrDefault(part => part.Id == id) is not { } removed) return false;
        var parts = ClipParts.Where(part => part.Id != id).Select(part => part.Part).ToArray();
        var select = SelectedPart?.Id == id ? parts[Math.Min(removed.Number - 1, parts.Length - 1)].Id : SelectedPart?.Id;
        return ApplyRecordingEdit(new RecordingEdit.RemovePart(ActiveClip!.Id, id), select, $"Removed part {removed.Number}");
    }

    private bool TrimPart(ClipPartRow part, bool start, int target)
    {
        if (!CanEditParts || target < 0 || target >= Words.Count) return false;
        var first = start ? target : part.First;
        var last = start ? part.Last : target;
        if (first > last || ClipParts.Any(other => other.Id != part.Id && first <= other.Last && other.First <= last)) return false;
        return ApplyRecordingEdit(new RecordingEdit.TrimPart(ActiveClip!.Id, part.Id, Words[first].Id, Words[last].Id),
            part.Id, $"Trimmed part {part.Number}");
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

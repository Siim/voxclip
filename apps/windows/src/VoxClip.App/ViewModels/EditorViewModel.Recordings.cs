using VoxClip.Core.Domain.Editing;

namespace VoxClip.App.ViewModels;

internal enum RecordingViewKind { All, Recording, PlayOrder }

internal readonly record struct RecordingView(RecordingViewKind Kind, string? Key = null);
internal sealed record RecordingSection(int First, int Last, string? Heading);

public sealed partial class EditorViewModel
{
    private RecordingView? recordingView;
    private string? partPickKey;
    private ProjectClock? matchedRecordingClock;
    private TakeMatch.Result? recordingMatches;

    internal ProjectClock? RecordingClock => state?.ProjectClock;
    internal IReadOnlyList<ProjectClock.Region> RecordingRegions => RecordingClock?.Regions ?? [];
    internal bool HasSeveralRecordings => RecordingRegions.Count > 1;
    internal ProjectClock.Region? RecordingOf(int index) => index >= 0 && index < Words.Count ? RecordingClock?.RegionOf(Words[index].Id) : null;
    internal ProjectClock.Region? PartPickRecording => RecordingRegions.FirstOrDefault(region => region.Key == partPickKey);
    private ClipPartRow? PartInsertionAnchor => HasSeveralRecordings ? ClipParts.FirstOrDefault(part => part.Id == selectedPartId) : null;
    internal string ActiveClipLabel => ActiveClip is { } clip ? $"Clip {Number(clip.Id)}" : "";
    internal int RecordingPartNumber => (PartInsertionAnchor?.Number ?? ClipParts.Count) + 1;
    internal string? PartPickPrompt => PartPickRecording is { } region ? $"Select words in {region.Label} to add them to {ActiveClipLabel}" +
        (PartInsertionAnchor is { } anchor ? $" · after part {anchor.Number}" : "") : null;
    internal string? RecordingPartSelectionTitle => PartPickRecording is null && HasSeveralRecordings && ActiveClip is not null &&
        HasSelection && ClipParts.Count > 0 && RecordingOf(SelectionStart) is { } region &&
        (region != RecordingOf(ClipParts[0].First) || TranscriptRecordingView == new RecordingView(RecordingViewKind.Recording, region.Key) && StoryRecordingRegions.Count > 1)
        ? $"Add to {ActiveClipLabel} as Part" : null;

    internal IReadOnlyList<ProjectClock.Region> StoryRecordingRegions => RecordingRegions.Where(region =>
        ClipParts.Any(part => part.Recording == region)).ToArray();

    internal string? StoryRecordingHeading => StoryRecordingRegions.Select(region => region.Label).ToArray() is { Length: > 1 } labels
        ? $"{ActiveClipLabel} · {ClipParts.Count} parts · from {string.Join(", ", labels[..^1])} and {labels[^1]}" : null;

    internal RecordingView TranscriptRecordingView => recordingView switch
    {
        { Kind: RecordingViewKind.All } chosen => chosen,
        { Kind: RecordingViewKind.Recording } chosen when RecordingRegions.Any(region => region.Key == chosen.Key) => chosen,
        { Kind: RecordingViewKind.PlayOrder } chosen when StoryRecordingRegions.Count > 1 => chosen,
        _ when StoryRecordingRegions.Count > 1 => new(RecordingViewKind.PlayOrder),
        _ when StoryRecordingRegions.FirstOrDefault() is { } region => new(RecordingViewKind.Recording, region.Key),
        _ => new(RecordingViewKind.All),
    };

    internal bool ChooseRecordingShortcut(int number) => HasSeveralRecordings && (number == 0
        ? ChooseRecordingView(new(RecordingViewKind.All))
        : number is >= 1 and <= 6 && number <= RecordingRegions.Count &&
            ChooseRecordingView(new(RecordingViewKind.Recording, RecordingRegions[number - 1].Key)));

    internal bool ChooseRecordingView(RecordingView choice, bool announce = true, bool clearSelection = true)
    {
        var index = RecordingRegions.ToList().FindIndex(region => region.Key == choice.Key);
        if (choice.Kind == RecordingViewKind.Recording && index < 0 ||
            choice.Kind == RecordingViewKind.PlayOrder && StoryRecordingRegions.Count < 2) return false;
        recordingView = choice;
        if (partPickKey is not null && (choice.Kind != RecordingViewKind.Recording || partPickKey != choice.Key)) partPickKey = null;
        if (clearSelection) ClearSelection();
        OnPropertyChanged(nameof(TranscriptRecordingView));
        if (announce && index >= 0) Announce($"Showing recording {RecordingRegions[index].Label}, {index + 1} of {RecordingRegions.Count}");
        return true;
    }

    internal void FollowRecording(int index)
    {
        if (HasSeveralRecordings && RecordingOf(index) is { } region && TranscriptRecordingView != new RecordingView(RecordingViewKind.Recording, region.Key))
            ChooseRecordingView(new(RecordingViewKind.Recording, region.Key), clearSelection: false);
    }

    internal bool PickPartFrom(string key)
    {
        if (!CanEditParts || !RecordingRegions.Any(region => region.Key == key) || RecordingUnavailable(key) is not null) return false;
        partPickKey = key;
        return ChooseRecordingView(new(RecordingViewKind.Recording, key));
    }

    internal bool FinishPartPick()
    {
        if (partPickKey is null) return false;
        partPickKey = null;
        OnPropertyChanged(nameof(TranscriptRecordingView));
        return true;
    }

    internal string? RecordingUnavailable(string key)
    {
        var source = RecordingReference(key);
        if (source is null) return null;
        var label = RecordingRegions.FirstOrDefault(region => region.Key == key)?.Label ?? ProjectClock.Label(source);
        if (IsRecordingMissing?.Invoke(source) == true) return $"{label} is missing. Locate it to use its words.";
        return RecordingRegions.Any(region => region.Key == key) ? null : $"{label} isn't transcribed yet.";
    }

    internal Func<VoxClip.Core.Domain.Shared.MediaReference, bool>? IsRecordingMissing { get; set; }

    internal VoxClip.Core.Domain.Shared.MediaReference? RecordingReference(string key) => project.Media.Source.ContentKey == key
        ? project.Media.Source : project.Media.AdditionalSources?.FirstOrDefault(reference => reference.ContentKey == key);

    private bool ApplyRecordingEdit(RecordingEdit edit, string? select = null, string? announcement = null)
    {
        var result = RecordingEdits.Apply(edit, project);
        if (result is RecordingEditResult.Refused refused) { Notice = refused.Message; return false; }
        if (result is not RecordingEditResult.Applied { UndoStep: not null } applied) return false;
        var previous = selectedPartId;
        selectedPartId = select ?? previous;
        if (!ReplaceProject(applied.Project, applied.UndoName)) { selectedPartId = previous; return false; }
        if ((applied.Announcement ?? announcement) is { } feedback) Announce(feedback);
        return true;
    }

    private TakeMatch.Result? RecordingMatches()
    {
        if (!HasSeveralRecordings || RecordingClock is not { } clock) return null;
        if (matchedRecordingClock != clock)
        {
            recordingMatches = TakeMatch.Build(clock);
            matchedRecordingClock = clock;
        }
        return recordingMatches;
    }
}

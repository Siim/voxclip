using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal enum RecordingViewKind { All, Recording, PlayOrder }

internal readonly record struct RecordingView(RecordingViewKind Kind, string? Key = null);
internal sealed record RecordingSection(int First, int Last, string? Heading);
internal sealed record RecordingVersion(ProjectClock.Region Recording, string FirstId, string LastId,
    IReadOnlySet<string> ChangedWordIds, int Fillers, double Pause, double Start, double End)
{
    internal string Time => $"{EditorViewModel.Duration(Start)}–{EditorViewModel.Duration(End)}";
    internal string Delivery => FormattableString.Invariant($"{Fillers} {(Fillers == 1 ? "filler" : "fillers")} · {Pause:0.0} s pause · {End - Start:0.0} s");
}

public sealed partial class EditorViewModel
{
    private RecordingView? recordingView;
    private string? partPickKey;
    private ProjectClock? matchedRecordingClock;
    private TakeMatch.Result? recordingMatches;
    internal bool ShowsRecordingContext { get; private set; }

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
        RefreshTranscriptParagraphs();
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

    internal void ToggleRecordingContext()
    {
        ShowsRecordingContext = !ShowsRecordingContext;
        RefreshTranscriptParagraphs();
        OnPropertyChanged(nameof(TranscriptRecordingView));
    }

    internal IReadOnlyList<RecordingSection> RecordingSections()
    {
        if (Words.Count == 0) return [];
        if (!HasSeveralRecordings || RecordingClock is not { } clock) return [new(0, Words.Count - 1, null)];
        var bounds = new Dictionary<string, (int First, int Last)>();
        for (var index = 0; index < Words.Count; index++)
            if (RecordingOf(index) is { } region)
                bounds[region.Key] = bounds.TryGetValue(region.Key, out var span) ? (span.First, index) : (index, index);
        var choice = TranscriptRecordingView;
        if (choice.Kind == RecordingViewKind.PlayOrder)
            return ClipParts.Where(part => part.Recording is not null).Select(part =>
            {
                var recording = part.Recording!;
                var (first, last) = (part.First, part.Last);
                if (ShowsRecordingContext && bounds.TryGetValue(recording.Key, out var span))
                {
                    var previous = ClipParts.Where(other => other.Recording == recording && other.Last < first).Select(other => other.Last).DefaultIfEmpty(-1).Max();
                    var next = ClipParts.Where(other => other.Recording == recording && other.First > last).Select(other => other.First).DefaultIfEmpty(-1).Min();
                    first = Math.Max(first - 16, previous < 0 ? span.First : (previous + first) / 2 + 1);
                    last = Math.Min(last + 16, next < 0 ? span.Last : (last + next) / 2);
                }
                return new RecordingSection(first, last, $"{part.Number} · {recording.Label} · {part.TakeTime}");
            }).ToArray();
        return clock.Regions.Where(region => bounds.ContainsKey(region.Key) && (choice.Kind == RecordingViewKind.All || region.Key == choice.Key))
            .Select(region => new RecordingSection(bounds[region.Key].First, bounds[region.Key].Last, choice.Kind == RecordingViewKind.All
                ? $"{region.Label} · {Duration((double)region.DurationSamples / clock.SampleRate)}" : null)).ToArray();
    }

    private void RefreshTranscriptParagraphs()
    {
        Paragraphs.Clear();
        foreach (var section in RecordingSections())
        {
            var start = section.First;
            var length = section.Last - section.First + 1;
            var words = section.First == 0 && length == Words.Count ? Words : Words.Skip(section.First).Take(length).ToArray();
            foreach (var range in TranscriptParagraphs.Split(words))
            {
                var end = section.First + range.End.Value;
                if (end <= section.Last && !PresentedWord(end).Visible) continue;
                var offset = HasSeveralRecordings && RecordingOf(start) is { } region ? (double)region.OffsetSamples / RecordingClock!.SampleRate : 0;
                Paragraphs.Add(new(start, end - start, Timecode(Words[start].Start - offset), Words[start].Speaker,
                    start == section.First ? section.Heading : null));
                start = end;
            }
        }
    }

    internal string? RecordingUnavailable(string key)
    {
        var source = RecordingReference(key);
        if (source is null) return null;
        var label = RecordingRegions.FirstOrDefault(region => region.Key == key)?.Label ?? ProjectClock.Label(source);
        if (IsRecordingMissing?.Invoke(source) == true) return $"{label} is missing. Locate it to use its words.";
        return RecordingRegions.Any(region => region.Key == key) ? null : $"{label} isn't transcribed yet.";
    }

    internal Func<MediaReference, bool>? IsRecordingMissing { get; set; }

    internal MediaReference? RecordingReference(string key) => project.Media.Source.ContentKey == key
        ? project.Media.Source : project.Media.AdditionalSources?.FirstOrDefault(reference => reference.ContentKey == key);

    private bool ApplyRecordingEdit(RecordingEdit edit, string? select = null, string? announcement = null, Project? prepared = null)
    {
        var result = RecordingEdits.Apply(edit, prepared ?? project);
        if (result is RecordingEditResult.Refused refused) { Notice = refused.Message; return false; }
        if (result is not RecordingEditResult.Applied { UndoStep: not null } applied) return false;
        var previous = selectedPartId;
        selectedPartId = select ?? previous;
        if (!ReplaceProject(applied.Project, applied.UndoName)) { selectedPartId = previous; return false; }
        if (edit is RecordingEdit.SwapTake && applied.Announcement is not null && ActiveClip is { } copy)
            Announce($"Made {copy.Title ?? ActiveClipLabel} to keep the lip sync");
        else if ((applied.Announcement ?? announcement) is { } feedback) Announce(feedback);
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

    internal IReadOnlyList<RecordingVersion> RecordingVersions(ClipPartRow part)
    {
        if (part.Recording is not { } region || RecordingMatches() is not { } matches) return [];
        var beats = matches.Beats.Select(beat => (Beat: beat, Take: beat.Takes.FirstOrDefault(take => take.Key == region.Key)))
            .Where(entry => entry.Take is not null).Select(entry => (entry.Beat, First: Index(entry.Take!.StartWordId), Last: Index(entry.Take.EndWordId)))
            .Where(entry => entry.First <= part.Last && entry.Last >= part.First).OrderBy(entry => entry.First).ToArray();
        if (beats.Length == 0 || !(beats[0].First == part.First && beats[^1].Last == part.Last) &&
            !(beats.Length == 1 && beats[0].Beat.Spans.Any(span => span.ToKey == region.Key && span.StartWordId == part.Part.StartWordId && span.EndWordId == part.Part.EndWordId))) return [];
        var versions = new List<RecordingVersion>();
        foreach (var candidate in RecordingRegions.Where(other => other != region))
        {
            var mapped = beats.Select(entry => (Span: entry.Beat.Spans.FirstOrDefault(span => span.FromKey == region.Key && span.ToKey == candidate.Key),
                Take: entry.Beat.Takes.FirstOrDefault(take => take.Key == candidate.Key))).ToArray();
            if (mapped.Any(entry => entry.Span is null || entry.Take is null) || !mapped.Zip(mapped.Skip(1)).All(pair =>
                Index(pair.First.Take!.EndWordId) + 1 == Index(pair.Second.Take!.StartWordId))) continue;
            var first = mapped[0].Span!.StartWordId;
            var last = mapped[^1].Span!.EndWordId;
            var offset = (double)candidate.OffsetSamples / RecordingClock!.SampleRate;
            versions.Add(new(candidate, first, last, mapped.SelectMany(entry => entry.Span!.ChangedWordIds).ToHashSet(),
                mapped.Sum(entry => entry.Take!.Signals.Fillers), mapped.Max(entry => entry.Take!.Signals.LongestPause),
                Words[Index(first)].Start - offset, Words[Index(last)].End - offset));
        }
        return versions;
    }

    private static RecordingEdit.SwapTake VersionEdit(string clipId, string partId, RecordingVersion version) =>
        new(clipId, partId, version.FirstId, version.LastId);

    internal Project? RecordingVersionPreview(string partId, RecordingVersion version) => ActiveClip is { } clip &&
        RecordingUnavailable(version.Recording.Key) is null &&
        RecordingEdits.Apply(VersionEdit(clip.Id, partId, version), project) is RecordingEditResult.Applied applied ? applied.Project : null;

    internal string? RecordingVersionDisabledReason(string partId, RecordingVersion version) => RecordingUnavailable(version.Recording.Key) ??
        (ActiveClip is { } clip && RecordingEdits.Apply(VersionEdit(clip.Id, partId, version), project) is RecordingEditResult.Refused refused ? refused.Message : null);

    internal string? RecordingVersionCopyReason(ClipPartRow part, RecordingVersion version)
    {
        if (ActiveClip is not { } clip || RecordingEdits.Apply(VersionEdit(clip.Id, part.Id, version), project) is not RecordingEditResult.Applied applied ||
            applied.Project.Edits.ActiveClipId == clip.Id) return null;
        var copy = applied.Project.Edits.Clips.FirstOrDefault(row => row.Id == applied.Project.Edits.ActiveClipId);
        var name = $"{ActiveClipLabel} copy";
        var rate = (double)(RecordingClock?.SampleRate ?? 48000);
        var window = project.VoiceLab.Segments.SelectMany(segment => segment.Candidates).Select(candidate => candidate.Recipe?.Video)
            .FirstOrDefault(video => video is { Mode: VoiceLabVideoMode.Lipsync, WindowStartSample: { } start, WindowEndSample: { } end } &&
                start / rate < part.End && end / rate > part.Start);
        var lower = window?.WindowStartSample is { } startSample ? startSample / rate : part.Start;
        var upper = window?.WindowEndSample is { } endSample ? endSample / rate : part.End;
        return $"Part {part.Number} is lip-synced at {Duration(lower)}–{Duration(upper)}. Using another version makes a copy, “{copy?.Title ?? name}”, and keeps the paid lip sync in {ActiveClipLabel}.";
    }

    internal bool UseRecordingVersion(string partId, RecordingVersion version)
    {
        if (!CanEditParts || ActiveClip is not { } clip || RecordingUnavailable(version.Recording.Key) is not null ||
            !ApplyRecordingEdit(VersionEdit(clip.Id, partId, version), partId, $"Used version from {version.Recording.Label}")) return false;
        ChooseRecordingView(new(RecordingViewKind.Recording, version.Recording.Key), announce: false);
        Select(Index(version.FirstId));
        return true;
    }

    internal bool UseWholeRecordingAsPart(string key)
    {
        if (!CanEditParts || RecordingUnavailable(key) is not null) return false;
        var indices = Enumerable.Range(0, Words.Count).Where(index => RecordingOf(index)?.Key == key).ToArray();
        return indices.Length > 0 && ClipParts.Count < 12 && ClipParts.All(part => part.Last < indices[0] || part.First > indices[^1]) &&
            AddRecordingPart(indices[0], indices[^1]);
    }

    internal IReadOnlyList<MediaReference> RecordingCompanions => (project.Media.AdditionalSources ?? [])
        .Where(reference => RecordingRegions.All(region => region.Key != reference.ContentKey)).ToArray();

    internal string? AddRecordingReason => IsReadOnly || isLeaving ? "This project is read-only."
        : !HasTranscript ? "Transcribe the first recording before adding another."
        : RecordingRegions.Count >= 6 ? "A project can have up to six spoken recordings."
        : Busy ? "Finish the current job before adding a recording." : null;

    internal string? RemoveRecordingReason(string key) => RecordingEdits.Apply(new RecordingEdit.RemoveSpokenSource(key), project) is RecordingEditResult.Refused refused
        ? refused.Message : null;

    internal bool RemoveRecording(string key) => AddRecordingReason is null || RecordingRegions.Count >= 6
        ? ApplyRecordingEdit(new RecordingEdit.RemoveSpokenSource(key)) : false;

    internal string[] ProposalRecordingReasons(ClipRange clip)
    {
        var suggestions = project.Ai.Results.FirstOrDefault(result => result.Id == clip.AiResultId)?.Clips;
        var proposal = clip.AiClipIndex is { } index && suggestions is not null && index >= 0 && index < suggestions.Count ? suggestions[index] : null;
        return clip.PlayParts.Select((part, partIndex) =>
        {
            var reason = part.TakeReason ?? proposal?.Parts?.FirstOrDefault(candidate => candidate.StartWordId == part.StartWordId && candidate.EndWordId == part.EndWordId)?.TakeReason;
            var label = RecordingClock?.RegionOf(part.StartWordId)?.Label;
            return string.IsNullOrWhiteSpace(reason) ? null : string.Join(" · ", new[] { $"Part {partIndex + 1}", label, reason }.OfType<string>());
        }).OfType<string>().ToArray();
    }

    internal bool AddSpokenRecording(MediaReference source, Transcript transcript)
    {
        if (IsReadOnly || isLeaving || !HasTranscript || RecordingRegions.Any(region => region.Key == source.ContentKey)) return false;
        var references = (project.Media.AdditionalSources ?? []).ToList();
        var existing = references.FindIndex(reference => reference.ContentKey == source.ContentKey);
        if (existing < 0) references.Add(source); else references[existing] = source;
        var prepared = project with { Media = project.Media with { AdditionalSources = references } };
        if (!ApplyRecordingEdit(new RecordingEdit.AddSpokenSource(source.ContentKey, transcript),
            announcement: $"Added recording {ProjectClock.Label(source)}", prepared: prepared)) return false;
        ChooseRecordingView(new(RecordingViewKind.Recording, source.ContentKey), announce: false);
        return true;
    }

    internal bool LocateSpokenRecording(MediaReference previous, string path)
    {
        if (previous.ContentKey == project.Media.Source.ContentKey) return false;
        var references = project.Media.AdditionalSources?.Select(reference => reference.ContentKey == previous.ContentKey
            ? reference with { AbsolutePath = path, RelativePath = null } : reference).ToArray();
        return references is not null && ReplaceProject(project with { Media = project.Media with { AdditionalSources = references } }, "Locate recording");
    }
}

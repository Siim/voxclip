#if WIN_UI_TESTS
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Clip semantics for the clips-first pane (ADR-R29): numbering, suggestions, one-step AI results and the summary
/// line; design §2, §3.5 and §6.2. The core reducer is unchanged.</summary>
public sealed class ClipSemanticsTests
{
    private static Project Fixture(string name, string group = "projects")
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared", "fixtures", group, name);
            if (File.Exists(path)) return ProjectSerialization.Deserialize(File.ReadAllText(path));
        }
        throw new FileNotFoundException("Shared project fixture not found.", name);
    }

    internal static EditorViewModel Story() => new(Fixture("story-project.voxclip", "story-clips"));
    internal static EditorViewModel RecordingStory() => new(Fixture("two-recordings.voxclip", "recordings"));
    internal static EditorViewModel RecordingReference() => new(Fixture("reference-recordings.voxclip", "recordings"));

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task LevelMatchingDoesNotCommitAfterCancellationOrAProjectEdit(bool cancel)
    {
        var project = RecordingReference().Project;
        var spoken = Assert.Single(project.Media.SpokenSources!);
        var source = project.Media.AdditionalSources!.Single(reference => reference.ContentKey == spoken.SourceKey);
        var model = new EditorViewModel(project with { Media = project.Media with { SpokenSources = null } });
        using var job = new CancellationTokenSource();
        var measured = new TaskCompletionSource<RecordingEdit.AddSpokenSource>(TaskCreationOptions.RunContinuationsAsynchronously);
        var adding = model.AddSpokenRecordingAsync(source, spoken.Transcript, (_, _, token) =>
        {
            Assert.Equal(job.Token, token);
            return measured.Task;
        }, job.Token);
        if (cancel) job.Cancel();
        else model.Apply(new EditOperation.SetWordCuts(["w1"], true));
        var before = model.Project;
        measured.SetResult(new(source.ContentKey, spoken.Transcript, GainDb: -3));
        if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => adding);
        else Assert.False(await adding);
        Assert.Same(before, model.Project);
        Assert.Null(model.Project.Media.SpokenSources);
    }

    [Fact]
    public void StartFromAndPutBackUseSeparateUndoSteps()
    {
        var model = RecordingReference();
        var original = model.ActiveClip;
        var primary = model.RecordingRegions[0];
        Assert.True(model.StartFromRecording(primary.Key));
        Assert.Equal("Start from recording", model.UndoActionName);
        Assert.Equal(RecordingViewKind.PlayOrder, model.TranscriptRecordingView.Kind);
        var starter = model.ActiveClip;
        var omitted = Assert.Single(model.OmittedRecordingLines);
        Assert.Equal("restart", omitted.Label);
        Assert.True(model.PutBackRecordingLine(omitted));
        Assert.Equal("Add part", model.UndoActionName);
        Assert.Empty(model.OmittedRecordingLines);
        model.Undo();
        Assert.Equal(starter, model.ActiveClip);
        model.Undo();
        Assert.Equal(original, model.ActiveClip);
    }

    [Fact]
    public void PutBackRestoresConsecutiveLeadingRestartsInRecordingOrder()
    {
        var project = RecordingReference().Project;
        var transcript = project.Transcript!;
        var template = transcript.Words[0];
        string[] text = ["One", "more", "time.", "Let", "me", "start", "again.", "We", "can", "ship", "it."];
        var words = text.Select((word, index) => template with
        {
            Id = $"lead{index}", Text = word, Start = index * .2, End = index * .2 + .15, RawStart = null, RawEnd = null,
        }).ToArray();
        var model = new EditorViewModel(project with { Transcript = transcript with { Words = words } });
        Assert.True(model.StartFromRecording(model.RecordingRegions[0].Key));
        Assert.Equal("lead7", Assert.Single(model.ClipParts).Part.StartWordId);
        var original = model.Project;
        Assert.Equal(["lead0", "lead3"], model.OmittedRecordingLines.Select(line => line.Take.StartWordId));
        var shell = new ShellViewModel();
        shell.Update(model, showingHome: false, [], null);
        Assert.Equal([SidebarKind.OmittedRecordingLine, SidebarKind.OmittedRecordingLine, SidebarKind.Outline],
            shell.Rows.Where(row => row.Kind is SidebarKind.OmittedRecordingLine or SidebarKind.Outline).Take(3).Select(row => row.Kind));
        Assert.True(model.PutBackRecordingLine(model.OmittedRecordingLines[0]));
        Assert.Equal(["lead0", "lead7"], model.ClipParts.Select(part => part.Part.StartWordId));
        var firstRestored = model.Project;
        Assert.True(model.PutBackRecordingLine(Assert.Single(model.OmittedRecordingLines)));
        Assert.Equal(("lead0", "lead10"), (Assert.Single(model.ClipParts).Part.StartWordId, model.ClipParts[0].Part.EndWordId));
        Assert.Empty(model.OmittedRecordingLines);
        Assert.Equal("Add part", model.UndoActionName);
        model.Undo();
        Assert.Equal(ProjectSerialization.Serialize(firstRestored), ProjectSerialization.Serialize(model.Project with { ModifiedAt = firstRestored.ModifiedAt }));
        model.Undo();
        Assert.Equal(ProjectSerialization.Serialize(original), ProjectSerialization.Serialize(model.Project with { ModifiedAt = original.ModifiedAt }));
    }

    [Fact]
    public void SevenRecordingActionsMakeTheSharedFivePartClip()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/command-cases.json"))!;
        var model = RecordingReference();
        var primary = model.RecordingRegions[0];
        var alternate = model.RecordingRegions[1];
        Assert.True(model.StartFromRecording(primary.Key));
        Assert.Equal("Start from recording", model.UndoActionName);
        var starter = model.ActiveClip;
        var started = ProjectSerialization.Serialize(model.Project);
        var line = Assert.Single(model.RecordingClipLines, line => line.FirstId == "w1");
        Assert.True(model.OpenRecordingVersions(line));
        Assert.NotNull(model.RecordingLineAudition(line, alternate.Key));
        Assert.Same(starter, model.ActiveClip);
        Assert.True(model.UseRecordingLineVersion(line, alternate.Key));
        Assert.Equal("Use version", model.UndoActionName);
        var swapped = model.ActiveClip;
        var swappedProject = ProjectSerialization.Serialize(model.Project);
        model.SetOtherRecordingLinesExpanded(true);
        var solo = Assert.Single(model.OtherRecordingLines, run => run.StartWordId == "r2.w18");
        Assert.Equal(vectors["placement"]!.GetValue<string>(), model.RecordingPlacement(solo));
        Assert.NotNull(model.RecordingSoloAudition(solo));
        Assert.Same(swapped, model.ActiveClip);
        Assert.True(model.InsertRecordingLine(solo));
        Assert.Equal("Add part", model.UndoActionName);
        Assert.Equal(vectors["final"]!["ranges"]!.AsArray().Select(pair => (pair![0]!.GetValue<string>(), pair[1]!.GetValue<string>())),
            model.ClipParts.Select(part => (part.Part.StartWordId, part.Part.EndWordId)));
        var final = ProjectSerialization.Serialize(model.Project);
        model.Undo();
        Assert.Equal(swappedProject, ProjectSerialization.Serialize(model.Project));
        Assert.Equal("Use version", model.UndoActionName);
        model.Undo();
        Assert.Equal(started, ProjectSerialization.Serialize(model.Project));
        Assert.Equal("Use version", model.RedoActionName);
        model.Redo();
        Assert.Equal(swappedProject, ProjectSerialization.Serialize(model.Project));
        Assert.Equal("Add part", model.RedoActionName);
        model.Redo();
        Assert.Equal(final, ProjectSerialization.Serialize(model.Project));
    }

    [Fact]
    public void UniqueLineCanGoAtTheEndWhenItsNeighbourIsOutsideTheClip()
    {
        var model = RecordingOpening();
        var solo = Assert.Single(model.OtherRecordingLines, run => run.StartWordId == "r2.w18");
        var before = ProjectSerialization.Serialize(model.Project);
        Assert.EndsWith("isn't in Clip 1. Insert it at the end, then move it.", model.RecordingSoloDisabledReason(solo));
        Assert.Null(model.RecordingSoloAudition(solo));
        Assert.False(model.InsertRecordingLine(solo));
        Assert.Null(model.RecordingSoloDisabledReason(solo, atEnd: true));
        Assert.True(model.InsertRecordingLine(solo, atEnd: true));
        Assert.Equal("Add part", model.UndoActionName);
        Assert.Equal(("r2.w18", "r2.w21"), (model.ClipParts[^1].Part.StartWordId, model.ClipParts[^1].Part.EndWordId));
        model.Undo();
        Assert.Equal(before, ProjectSerialization.Serialize(model.Project));
    }

    [Fact]
    public void LineVersionKeepsPaidLipSyncInTheOriginalAndSelectsOnlyOneCopy()
    {
        var starter = RecordingReference();
        Assert.True(starter.StartFromRecording(starter.RecordingRegions[0].Key));
        var opening = Assert.Single(starter.RecordingClipLines, line => line.FirstId == "w1");
        var voice = Fixture("lipsync-render-v3.voxclip", "voice-lab").VoiceLab;
        var segment = voice.Segments.First(segment => segment.Candidates.Any(candidate => candidate.Recipe?.Video.Mode == VoiceLabVideoMode.Lipsync));
        var candidate = segment.Candidates.First(candidate => candidate.Recipe?.Video.Mode == VoiceLabVideoMode.Lipsync);
        var recipe = candidate.Recipe!;
        var window = recipe.Video with { WindowStartSample = (long)(starter.Words[starter.Index(opening.FirstId)].Start * 48_000) + 480,
            WindowEndSample = (long)(starter.Words[starter.Index(opening.LastId)].End * 48_000) - 480 };
        var paid = voice with { Segments = [segment with { Candidates = [candidate with { Recipe = recipe with { Video = window } }], SelectedCandidateIndex = 0 }] };
        var model = new EditorViewModel(starter.Project with { VoiceLab = paid });
        var line = Assert.Single(model.RecordingClipLines, line => line.FirstId == "w1");
        var alternate = Assert.Single(line.Alternatives);
        var announcements = new List<string>();
        model.Announcement += (_, message) => announcements.Add(message);
        model.IsRecordingMissing = media => media.ContentKey == alternate.Key;
        Assert.Equal("0010 is missing. Locate it to use its words.", model.RecordingLineDisabledReason(line, alternate.Key));
        Assert.Null(model.RecordingLineAudition(line, alternate.Key));
        Assert.False(model.UseRecordingLineVersion(line, alternate.Key));
        model.IsRecordingMissing = null;
        Assert.Contains("keeps the paid lip sync in Clip 1", model.RecordingLineCopyReason(line, alternate.Key));
        Assert.True(model.UseRecordingLineVersion(line, alternate.Key));
        var copyTitle = $"{starter.ActiveClip?.Title ?? "Clip 1"} copy";
        Assert.Equal($"Made {copyTitle} to keep the lip sync", Assert.Single(announcements));
        Assert.Equal(announcements[0], model.Notice);
        Assert.Equal(copyTitle, model.ActiveClip?.Title);
        Assert.Equal(starter.ActiveClip, model.Project.Edits.Clips[0]);
        Assert.Equal("Use version", model.UndoActionName);

        var copiedOpening = Assert.Single(model.RecordingClipLines, line => line.FirstId == "r2.w1");
        Assert.True(model.UseRecordingLineVersion(copiedOpening, starter.RecordingRegions[0].Key));
        Assert.Equal(2, model.Project.Edits.Clips.Count);
        model.Undo();
        model.Undo();
        Assert.Equal(starter.ActiveClip, Assert.Single(model.Project.Edits.Clips));
        Assert.Equal(paid.Segments, model.Project.VoiceLab.Segments);
    }

    internal static EditorViewModel RecordingOpening()
    {
        var project = Fixture("reference-recordings.voxclip", "recordings");
        var clip = new ClipRange("clip-opening", "w1", "w7", null, ClipOrigin.Manual, null, null, true);
        return new(project with { Edits = project.Edits with { ActiveClipId = clip.Id, Clips = [clip] } });
    }

    [Fact]
    public void RecordingPartPickAddsAfterTheSelectedPartAndUndoRestoresTheClip()
    {
        var model = RecordingOpening();
        model.Select(model.Index("w18"));
        model.Select(model.Index("w23"), extend: true);
        Assert.True(model.AddSelectionAsPart());
        var opening = model.ClipParts[0].Id;
        Assert.True(model.SelectPart(opening));
        Assert.True(model.PickPartFrom(model.RecordingRegions[1].Key));
        Assert.Equal("Select words in 0010 to add them to Clip 1 · after part 1", model.PartPickPrompt);
        Assert.Equal(2, model.RecordingPartNumber);
        Assert.False(model.CanAddPart);
        model.Select(model.Index("r2.w18"));
        model.Select(model.Index("r2.w21"), extend: true);
        Assert.True(model.AddSelectionAsPart());
        Assert.Equal("Add part", model.UndoActionName);
        Assert.Equal(["w1", "r2.w18", "w18"], model.ClipParts.Select(part => part.Part.StartWordId));
        Assert.Equal("Clip 1 · 3 parts · from 0007 and 0010", model.StoryRecordingHeading);
        Assert.NotNull(model.PartPickRecording);
        model.Undo();
        Assert.Equal(["w1", "w18"], model.ClipParts.Select(part => part.Part.StartWordId));
        Assert.Equal("Add part", model.RedoActionName);
    }

    [Fact]
    public void RecordingSelectionCannotCrossAGuardGapAndShowsTheInlineReason()
    {
        var model = RecordingOpening();
        Assert.True(model.ChooseRecordingShortcut(0));
        model.Select(model.Index("w27"));
        model.Select(model.Index("r2.w1"), extend: true);
        Assert.False(model.CanAddPart);
        Assert.False(model.AddSelectionAsPart());
        Assert.Equal("A part comes from one recording. Select words in 0007 only.", model.AddPartHelp);
        Assert.Null(model.UndoActionName);
    }

    [Fact]
    public void WholePartVersionUsesTheMatchedRecordingAndUndoesInOneStep()
    {
        var model = RecordingOpening();
        var opening = Assert.Single(model.ClipParts);
        var version = Assert.Single(model.RecordingVersions(opening));
        Assert.Equal("0010", version.Recording.Label);
        Assert.Null(model.RecordingVersionCopyReason(opening, version));
        Assert.True(model.UseRecordingVersion(opening.Id, version));
        var updated = Assert.Single(model.ClipParts);
        Assert.Equal(opening.Id, updated.Id);
        Assert.Equal(("r2.w1", "r2.w11"), (updated.Part.StartWordId, updated.Part.EndWordId));
        Assert.Equal("Use version", model.UndoActionName);
        model.Undo();
        Assert.Equal("w1", Assert.Single(model.ClipParts).Part.StartWordId);
        Assert.Equal("Use version", model.RedoActionName);
    }

    [Fact]
    public void ProposalReasonIncludesThePartNumberAndItsRecording()
    {
        var model = RecordingStory();
        Assert.Equal(["Part 1 · 0010 · A clearer opening"], model.ProposalRecordingReasons(model.ActiveClip!));
    }

    [Fact]
    public void MissingVersionStaysVisibleButCannotBeUsedOrAuditioned()
    {
        var model = RecordingOpening();
        var part = Assert.Single(model.ClipParts);
        var version = Assert.Single(model.RecordingVersions(part));
        model.IsRecordingMissing = source => source.ContentKey == version.Recording.Key;
        Assert.Equal("0010 is missing. Locate it to use its words.", model.RecordingVersionDisabledReason(part.Id, version));
        Assert.False(model.UseRecordingVersion(part.Id, version));
        Assert.Null(model.RecordingVersionPreview(part.Id, version));
        Assert.Null(model.UndoActionName);
    }

    [Fact]
    public void RemoveRecordingExplainsThePartThatUsesIt()
    {
        var model = RecordingStory();
        var key = model.RecordingRegions[1].Key;
        Assert.Equal("Clip 1 uses 1 part from 0010. Remove that part first.", model.RemoveRecordingReason(key));
        Assert.False(model.RemoveRecording(key));
        Assert.Null(model.UndoActionName);
    }

    [Fact]
    public void StoryOutlineFollowsPlayOrderAndMovesOnePartInAnUndoStep()
    {
        var model = Story();
        var shell = new ShellViewModel();
        shell.Update(model, false, [], null);
        Assert.Equal("2 parts", Assert.Single(model.Clips).PartsBadge);
        Assert.Equal("0:01", Assert.Single(model.Clips).Duration);
        Assert.Equal(["uh the", "So um,"], shell.Rows.Where(row => row.PartId is not null).Select(row => row.Title));
        Assert.Equal("0:03–0:04", model.ClipParts[0].TakeTime);
        Assert.Equal("Select words outside the clip's parts to add them.", shell.Rows.Single(row => row.Key == "action:add-part").Detail);
        Assert.False(shell.Rows.Single(row => row.Key == "action:add-part").IsEnabled);

        string? announcement = null;
        model.Announcement += (_, text) => announcement = text;
        Assert.True(model.MovePart("first", 1));
        Assert.Equal("Part 1 moved to 2 of 2", announcement);
        Assert.Equal("Move part", model.UndoActionName);
        Assert.Equal(["second", "first"], model.ClipParts.Select(part => part.Id));
        model.Undo();
        Assert.Equal(["first", "second"], model.ClipParts.Select(part => part.Id));
    }

    [Fact]
    public void StoryOutlineDropTargetsTheSpaceBeforeOrAfterAPart()
    {
        var model = Story();
        model.Select(8);
        Assert.True(model.AddSelectionAsPart());
        var added = model.SelectedPart!.Id;

        Assert.Null(model.PartDropIndex("first", "second", after: false));
        var destination = model.PartDropIndex("first", "second", after: true);
        Assert.Equal(1, destination);
        Assert.True(model.MovePart("first", destination!.Value));
        Assert.Equal(["second", "first", added], model.ClipParts.Select(part => part.Id));

        destination = model.PartDropIndex(added, "second", after: false);
        Assert.Equal(0, destination);
        Assert.True(model.MovePart(added, destination!.Value));
        Assert.Equal([added, "second", "first"], model.ClipParts.Select(part => part.Id));
    }

    [Fact]
    public void StoryVoiceExplainsBothBlocksAndOffersFreeOrdinaryClips()
    {
        var model = Story();
        Assert.True(model.SelectPart("second"));
        var voice = model.StoryVoice(prices: VoiceLabPrices.Load())!;
        Assert.Equal("Voice changes work on one part at a time. Make a clip of the part first.", voice.RewriteReason);
        Assert.Equal("Lip sync can't run across the 1 seams of a story clip yet. Make a clip of the part first.", voice.LipSyncReason);
        Assert.Equal("Make Clip of Part 2", voice.MakeSelected);
        Assert.Equal("Make Clips of All 2 Parts", voice.MakeAll);
        Assert.True(voice.VoiceAndLipSync > 0);
        Assert.True(voice.LipSync > 0);
        Assert.True(model.MakeClipsOfParts(model.SelectedPart!.Id));
        var ordinary = Assert.Single(model.Clips, clip => clip.Id != "clip-main");
        Assert.Null(ordinary.Clip.Parts);
        Assert.Equal(("w1", "w2"), (ordinary.Clip.StartWordId, ordinary.Clip.EndWordId));
        Assert.Equal("Make clip of part", model.UndoActionName);
        model.Undo();
        Assert.True(model.Apply(new EditOperation.Toggle("w2")));
        Assert.True(model.MakeClipsOfParts());
        Assert.Equal("Make clips of all parts", model.UndoActionName);
        var parts = model.Clips.Where(clip => clip.Id != "clip-main").ToArray();
        Assert.Equal(2, parts.Length);
        Assert.All(parts, part => Assert.Null(part.Clip.Parts));
        Assert.Contains("w2", model.Project.Edits.CutWordIds);
        Assert.Null(model.StoryVoice());
        model.Undo();
        Assert.Single(model.Clips);
    }

    [Fact]
    public void ShowreelBadgeKeepsTheEditedLength()
    {
        var project = Story().Project;
        var clip = Assert.Single(project.Edits.Clips) with { Kind = StoryClipKind.Showreel };
        var model = new EditorViewModel(project with { Edits = project.Edits with { Clips = [clip] } });
        var row = Assert.Single(model.Clips);
        Assert.Equal("reel", row.PartsBadge);
        Assert.Equal("0:01", row.Duration);
    }

    [Fact]
    public void StoryAddsOnlyAnOutsideSelectionAndTrimsTheSelectedPart()
    {
        var model = Story();
        model.Select(1);
        Assert.False(model.AddSelectionAsPart());
        Assert.Equal("Select words outside the clip's parts to add them.", model.AddPartHelp);
        model.Select(8);
        Assert.True(model.AddSelectionAsPart());
        Assert.Equal("Add part", model.UndoActionName);
        Assert.Equal(8, model.SelectedPart!.First);
        Assert.True(model.SelectPart("second"));
        model.Select(2);
        model.SetClipEdgeAtCaret(false);
        Assert.Equal("Trim part", model.UndoActionName);
        Assert.Equal(["w7", "w3", "w9"], model.ClipParts.Select(part => part.Part.EndWordId));
        Assert.True(model.RemovePart(model.ClipParts[2].Id));
        Assert.Equal("Remove part", model.UndoActionName);
        Assert.True(model.RemovePart("first"));
        Assert.False(model.IsStoryClip);
        Assert.False(model.RemovePart(model.SelectedPart!.Id));
        Assert.Equal("A clip needs one part. Remove Clip instead.", model.RemovePartHelp);
    }

    /// <summary>The long take with no clips, no cuts and no earlier clip-finding runs.</summary>
    private static EditorViewModel Clean()
    {
        var project = Fixture("clip-from-long-take.voxclip");
        return new EditorViewModel(project with { Edits = project.Edits with { Clips = [], CutWordIds = [], CutPauseIds = [], ActiveClipId = null }, Ai = project.Ai with { Results = [] } });
    }

    private static string Clip(EditorViewModel model, int first, int last)
    {
        model.Select(first); model.Select(last, true);
        return model.MakeClip()!;
    }

    private static AiResult Result(EditorViewModel model, params (int First, int Last)[] ranges) => new("run-1", DateTimeOffset.UtcNow, "anthropic", "test-model",
        ClipPreset.Best, null, "en", new string('0', 64),
        ranges.Select((range, index) => new AiClip($"Idea {index + 1}", $"Reason {index + 1}", 8 - index, model.Words[range.First].Id, model.Words[range.Last].Id)).ToArray());

    [Fact]
    public void FindClipsAddsSuggestionsAsOneUndoStep()
    {
        var model = Clean();
        var added = model.AddAiResult(Result(model, (0, 3), (5, 8), (10, 14)));
        Assert.Equal(model.SuggestedClips.Select(clip => clip.Id), added);
        Assert.Equal(3, model.SuggestedClips.Count);
        Assert.Empty(model.KeptClips);
        Assert.All(model.Clips, clip => Assert.True(clip.IsSuggested && !clip.Selected));
        Assert.Single(model.Project.Ai.Results);
        Assert.Equal("8/10 · Reason 1", model.Clips[0].ToolTip);

        model.Undo();
        Assert.Empty(model.Clips);
        Assert.False(model.CanUndo);

        model.Redo();
        Assert.Equal(3, model.SuggestedClips.Count);
        Assert.True(model.KeepAll());
        Assert.Equal(3, model.KeptClips.Count);
        Assert.Empty(model.SuggestedClips);
        model.Undo();
        Assert.Equal(3, model.SuggestedClips.Count);
    }

    [Fact]
    public void KeptClipsAreNumberedBeforeSuggestions()
    {
        var model = Clean();
        var late = Clip(model, 20, 22);
        Clip(model, 0, 2);
        Clip(model, 4, 6);
        Clip(model, 12, 14);
        model.AddAiResult(Result(model, (8, 10)));
        Assert.Equal([1, 2, 3, 4, 5], model.Clips.Select(clip => clip.Number));
        Assert.Equal(late, model.KeptClips[3].Id);
        var suggestion = Assert.Single(model.SuggestedClips);
        Assert.Equal(5, suggestion.Number);
        Assert.Equal("Idea 1", suggestion.Title);

        Assert.True(model.Keep(suggestion.Id));
        Assert.Equal(3, model.Clips.Single(clip => clip.Id == suggestion.Id).Number);
        Assert.True(model.Rename(suggestion.Id, "  Third idea "));
        Assert.Equal("Third idea", model.Clips.Single(clip => clip.Id == suggestion.Id).Title);
        Assert.True(model.Remove(late));
        Assert.Equal(4, model.Clips.Count);
    }

    /// <summary>Export's "Selected clips" exports the kept clips (ADR-R29): every manual clip, whatever its stored selected
    /// flag, and the AI clips the user kept, never a suggestion.</summary>
    [Fact]
    public void ExportedClipsAreTheKeptClipsWithEveryManualClip()
    {
        var model = Clean();
        var manual = Clip(model, 20, 24);
        Assert.True(model.Apply(new EditOperation.SetClipSelected(manual, false)));
        var suggestions = model.AddAiResult(Result(model, (0, 3), (5, 8)));
        Assert.True(model.Apply(new EditOperation.SetClipSelected(suggestions[1], true)));
        Assert.Equal([suggestions[1], manual], model.KeptClips.Select(clip => clip.Id));
        Assert.Equal([suggestions[0]], model.SuggestedClips.Select(clip => clip.Id));
        Assert.False(model.Clips.Single(clip => clip.Id == manual).Selected);
    }

    /// <summary>Design §6.2: from the Full take row, ] selects clip 1; the window cycles by the row's step.</summary>
    [Fact]
    public void RightBracketFromFullTakeSelectsClipOne()
    {
        var model = Clean();
        var first = Clip(model, 0, 3);
        Clip(model, 10, 14);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        Assert.Equal(1, ShortcutPolicy.RowClipStep(']', SidebarKind.FullTake, false));
        model.CycleClip(ShortcutPolicy.RowClipStep(']', SidebarKind.FullTake, false));
        Assert.Equal(first, model.State!.ActiveClipId);
    }

    /// <summary>Rename takes at most 120 code points once trimmed; the dialog explains a longer title instead of the reducer
    /// dropping it.</summary>
    [Fact]
    public void RenameExplainsATitleOverTheLimit()
    {
        var model = Clean();
        var id = Clip(model, 0, 3);
        var longest = string.Concat(Enumerable.Repeat("👩🏽‍💻", 30));
        Assert.Equal(120, longest.EnumerateRunes().Count());
        Assert.True(longest.Length > 120);
        Assert.Null(EditorViewModel.ClipTitleProblem(longest));
        Assert.Null(EditorViewModel.ClipTitleProblem("  " + new string('a', 120) + "  "));
        Assert.Null(EditorViewModel.ClipTitleProblem(""));
        Assert.Equal("Use 120 characters or fewer.", EditorViewModel.ClipTitleProblem(new string('a', 121)));
        Assert.Equal("Use 120 characters or fewer.", EditorViewModel.ClipTitleProblem(longest + "!"));
        Assert.True(model.Rename(id, longest));
        Assert.Equal(longest, model.Project.Edits.Clips.Single(clip => clip.Id == id).Title);
        // What the dialog refuses, the reducer would have dropped without a word.
        Assert.False(model.Rename(id, new string('a', 121)));
        Assert.Equal(longest, model.Project.Edits.Clips.Single(clip => clip.Id == id).Title);
    }

    /// <summary>A clip row's Export clip… is judged on its own clip, not on the active scope: a clip with kept words exports
    /// while another clip with every word cut is active, and a clip with every word cut is refused from Full take.</summary>
    [Fact]
    public void ExportIsJudgedOnTheRequestedClip()
    {
        var model = Clean();
        var first = Clip(model, 0, 3);
        var second = Clip(model, 10, 14);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(first)));
        model.Select(0); model.Select(3, true);
        model.CutSelection(false);
        const string NoWords = "Keep at least one word before exporting.";
        Assert.Equal(NoWords, model.ExportBlocked(false, false, first));
        Assert.Null(model.ExportBlocked(false, false, second));
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        Assert.Equal(NoWords, model.ExportBlocked(false, false, first));
        Assert.Null(model.ExportBlocked(false, false, second));
        Assert.Null(model.ExportBlocked(false, false, null));
    }

    /// <summary>Ctrl+E, the Export button and a clip row's Export clip… share one reason (delta §3.5).</summary>
    [Fact]
    public void ExportSaysWhyItCannotRunForTheScope()
    {
        var model = Clean();
        Assert.Null(model.ExportBlocked(false, false, null));
        var suggestion = model.AddAiResult(Result(model, (0, 3)))[0];
        Assert.Equal("Keep this clip to export it.", model.ExportBlocked(false, false, suggestion));
        Assert.Equal("Locate the video to export.", model.ExportBlocked(false, true, suggestion));
        Assert.Equal("Demo projects have no video to export.", model.ExportBlocked(true, true, null));
        model.Busy = true;
        Assert.Equal("Finish the current task first.", model.ExportBlocked(false, false, null));
        model.Busy = false;
        model.Select(0); model.Select(model.Words.Count - 1, true);
        model.CutSelection(false);
        Assert.Equal("Keep at least one word before exporting.", model.ExportBlocked(false, false, null));
    }

    [Fact]
    public void DismissRemovesOnlyTheSuggestion()
    {
        var model = Clean();
        var kept = Clip(model, 0, 2);
        model.AddAiResult(Result(model, (5, 8), (10, 14)));
        var dismissed = model.SuggestedClips[0].Id;
        Assert.True(model.Dismiss(dismissed));
        Assert.DoesNotContain(model.Clips, clip => clip.Id == dismissed);
        Assert.Equal(kept, Assert.Single(model.KeptClips).Id);
        Assert.Single(model.SuggestedClips);
        Assert.Single(model.Project.Ai.Results);
    }

    [Fact]
    public void MakeClipReturnsTheClipThatAlreadyCoversTheSelection()
    {
        var model = Clean();
        var first = Clip(model, 4, 9);
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        model.Notice = "stale";
        model.Select(4); model.Select(9, true);
        Assert.Equal(first, model.MakeClip());
        Assert.Single(model.Clips);
        Assert.Equal("", model.Notice);
        Assert.Equal(["Clip 1 already covers these words."], announced);
    }

    /// <summary>Delta §6.2: making a clip is one addClip undo step that selects it, so revealing its row (MainWindow.RevealClip
    /// → EditorPage.SelectScope, which applies setActiveClip) adds no second step and Narrator hears "Clip 1 made.".</summary>
    [Fact]
    public void MakeClipIsOneUndoStepAndRevealingItAddsNone()
    {
        var model = Clean();
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        var id = Clip(model, 4, 9);
        Assert.Equal(id, model.State!.ActiveClipId);
        Assert.False(model.Apply(new EditOperation.SetActiveClip(id)));
        Assert.Equal(["Clip 1 made."], announced);
        model.Undo();
        Assert.Empty(model.Clips);
        Assert.Null(model.State!.ActiveClipId);
        Assert.False(model.CanUndo);
    }

    [Fact]
    public void MakingAnExistingClipSelectsItAndSaysSoOnce()
    {
        var model = Clean();
        var first = Clip(model, 0, 2);
        var second = Clip(model, 4, 6);
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        model.Select(0); model.Select(2, true);
        Assert.Equal(first, model.MakeClip());
        Assert.Equal(first, model.State!.ActiveClipId);
        // Revealing the row changes nothing more, and the edit summary never replaces the message.
        Assert.False(model.Apply(new EditOperation.SetActiveClip(first)));
        Assert.Equal(["Clip 1 already covers these words."], announced);
        model.Undo();
        Assert.Equal((first, 1), (model.State!.ActiveClipId, model.Clips.Count));
        Assert.DoesNotContain(model.Clips, clip => clip.Id == second);
    }

    /// <summary>Design §6.2: a manual clip is titled with the first seven words of the selection, as shown.</summary>
    [Fact]
    public void ManualClipsTakeTheFirstSevenWordsAsTheirTitle()
    {
        var model = Clean();
        var whole = Clip(model, 0, 9);
        Assert.Equal("Tere! Täna näitan, kuidas lõigata videot sõnade", model.Clips.Single(clip => clip.Id == whole).Title);
        model.Select(2);
        model.BeginCorrection(); model.CorrectionText = "näitasin,"; model.EndCorrection();
        var corrected = Clip(model, 1, 3);
        Assert.Equal("Täna näitasin, kuidas", model.Clips.Single(clip => clip.Id == corrected).Title);
        Assert.Equal("Täna näitasin, kuidas", model.Project.Edits.Clips.Single(clip => clip.Id == corrected).Title);
    }

    [Fact]
    public void RemovingAnEarlierClipKeepsALaterClipsTitle()
    {
        var model = Clean();
        var early = Clip(model, 0, 2);
        var later = Clip(model, 12, 20);
        Assert.Equal(("Tere! Täna näitan,", 1), (model.Clips.Single(clip => clip.Id == early).Title, model.Clips.Single(clip => clip.Id == early).Number));
        Assert.True(model.Remove(early));
        var row = model.Clips.Single(clip => clip.Id == later);
        Assert.Equal(("palju kiirem kui ajateljel kerimine. Iga sõna", 1), (row.Title, row.Number));
    }

    [Fact]
    public void ClipCommandsAnnounceWhatTheyDid()
    {
        var model = Clean();
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        var first = Clip(model, 0, 2);
        model.AddAiResult(Result(model, (5, 8), (10, 14)));
        Assert.True(model.Keep(model.SuggestedClips[0].Id));
        Assert.True(model.Dismiss(model.SuggestedClips[0].Id));
        Assert.True(model.Remove(first));
        Assert.True(model.Rename(model.KeptClips[0].Id, "Renamed"));
        Assert.Equal(["Clip 1 made.", "Clip 2 kept.", "Suggestion dismissed.", "Clip 1 removed."], announced);
    }

    [Fact]
    public void CycleClipWalksKeptClipsOnly()
    {
        var model = Clean();
        var one = Clip(model, 0, 2);
        var two = Clip(model, 12, 14);
        model.AddAiResult(Result(model, (5, 8)));
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        model.CycleClip(1);
        Assert.Equal(one, model.State!.ActiveClipId);
        model.CycleClip(1);
        Assert.Equal(two, model.State!.ActiveClipId);
        model.CycleClip(1);
        Assert.Equal(two, model.State!.ActiveClipId);
        model.CycleClip(-1);
        Assert.Equal(one, model.State!.ActiveClipId);
    }

    [Fact]
    public void SummaryLineCountsCutRunsAndPausesInScope()
    {
        var model = Clean();
        // The length export renders for a scope, worked out without the view model: ExportSelection's frozen state, then
        // the edit plan.
        double Planned(ExportTarget target)
        {
            var state = ExportSelection.Scope(model.State, target)!;
            var source = model.Project.Media.Source;
            var sampleRate = source.Audio?.SampleRate is > 0 ? source.Audio.SampleRate : 48000;
            return EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, source.DurationSeconds), source.DurationSeconds, sampleRate, state.PauseKeepSeconds).Duration;
        }
        Assert.Equal("0:16 · No cuts yet", model.SummaryLine);
        Assert.Equal(Planned(new ExportTarget.FullEdit()), model.FullTakeDuration, 9);

        // The long take has pauses after words 16 and 22; clip A spans 12–20 and clip B 21–25.
        var a = Clip(model, 12, 20);
        var b = Clip(model, 21, 25);
        string[] Words(params int[] indexes) => indexes.Select(index => model.Words[index].Id).ToArray();
        // Making a clip makes it the scope (design §6.2); go back to Full take.
        Assert.Equal(b, model.State!.ActiveClipId);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        // Three cut runs: words 2–3, 14 and 18–19.
        Assert.True(model.Apply(new EditOperation.SetWordCuts(Words(2, 3, 14, 18, 19), true)));
        Assert.Equal("0:14 after cuts · 3 cuts", model.SummaryLine);
        Assert.Equal("0:16 source · 5 words cut in 3 places · 0 pauses cut", model.SummaryTooltip);
        Assert.Equal(Planned(new ExportTarget.FullEdit()), model.FullTakeDuration, 9);

        // Clip A holds the runs at 14 and 18–19; clip B holds none until its pause is cut.
        Assert.True(model.Apply(new EditOperation.SetActiveClip(a)));
        Assert.Equal("Clip 1 · 0:04 after cuts · 2 cuts", model.SummaryLine);
        Assert.Equal(EditorViewModel.Duration(Planned(new ExportTarget.Clip(a))), model.Clips.Single(clip => clip.Id == a).Duration);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(b)));
        Assert.Equal("Clip 2 · 0:04 · No cuts yet", model.SummaryLine);

        var pause = model.State!.Pauses.Single(item => item.AfterIndex == 22).Id;
        Assert.True(model.Apply(new EditOperation.SetPauseCuts([pause], true)));
        Assert.Equal("Clip 2 · 0:03 after cuts · 1 cut", model.SummaryLine);
        Assert.Equal(EditorViewModel.Duration(Planned(new ExportTarget.Clip(b))), model.Clips.Single(clip => clip.Id == b).Duration);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        Assert.Equal("0:13 after cuts · 4 cuts", model.SummaryLine);
        Assert.Equal("0:16 source · 5 words cut in 3 places · 1 pause cut", model.SummaryTooltip);
        // A clip in scope never changes the Full take length.
        Assert.Equal(Planned(new ExportTarget.FullEdit()), model.FullTakeDuration, 9);
    }
}
#endif

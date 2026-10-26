#if WIN_UI_TESTS
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class ViewModelTests
{
    private static Project Fixture()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared", "fixtures", "projects", "interview-take.voxclip");
            if (File.Exists(path)) return ProjectSerialization.Deserialize(File.ReadAllText(path));
        }
        throw new FileNotFoundException("Shared project fixture not found.");
    }
    private static EditorViewModel Demo() => new(Fixture(), DemoProject.Reduce, DemoProject.Summarize);

    [Fact]
    public void SnapshotCapabilityHonorsFullAndClipScopeWithoutDroppingSynth()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "shared"))) root = root.Parent;
        Assert.NotNull(root);
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(root.FullName,
            "shared", "fixtures", "voice-lab", "passage-project.voxclip")));
        var model = new EditorViewModel(project);
        Assert.Throws<VoxClip.Core.Domain.VoiceLab.VoiceLabProjectException>(() => model.RequireLegacyRendering(model.State));
        var outside = new VoxClip.Core.Domain.Editing.ClipRange("outside", "w1", "w2", "Source only", VoxClip.Core.Domain.Editing.ClipOrigin.Manual, null, null, true);
        var state = model.State! with { Clips = model.State!.Clips.Append(outside).ToArray(), ActiveClipId = outside.Id };
        model.RequireLegacyRendering(state);
        Assert.Throws<VoxClip.Core.Domain.VoiceLab.VoiceLabProjectException>(() => model.RequireLegacyRendering(state with { ActiveClipId = null }));
        Assert.True(model.Project.VoiceLab.Segments[0].Enabled);
        var disabled = VoxClip.Core.Domain.VoiceLab.VoiceLabProject.SetEnabled(project, "vl-passage", false);
        var restored = new EditorViewModel(disabled);
        restored.RequireLegacyRendering(restored.State);
    }

    [Fact]
    public void FixtureCreatesParagraphsWithoutWordViews()
    {
        var model = Demo();
        Assert.NotEmpty(model.Paragraphs); Assert.Equal(model.Words.Count, model.Paragraphs.Sum(item => item.Count));
        Assert.All(model.Paragraphs, item => Assert.InRange(item.Count, 1, 100));
    }
    [Fact]
    public void SelectionDoesNotSchedulePersistenceOrRecompose()
    {
        var model = Demo(); var changed = 0; var selection = 0;
        model.Changed += (_, _) => changed++; model.SelectionChanged += (_, _) => selection++;
        model.Select(2); model.Select(5, true);
        Assert.Equal(0, changed); Assert.Equal(2, selection); Assert.Equal(2, model.SelectionStart); Assert.Equal(5, model.SelectionEnd);
    }
    [Fact]
    public void ReverseSelectionSnapsToWords()
    {
        var model = Demo(); model.Select(5); model.Select(2, true);
        Assert.Equal(2, model.SelectionStart); Assert.Equal(5, model.SelectionEnd); Assert.NotEmpty(model.SelectionText);
    }
    [Fact]
    public void ManualClipWorksWithoutAConnectorOrKey()
    {
        var model = Demo(); model.Select(0); model.Select(3, true);
        var before = model.Clips.Count;
        Assert.True(model.MakeClip()); Assert.Equal(before + 1, model.Clips.Count);
        Assert.Equal(ClipOrigin.Manual, model.Clips.Last().Clip.Origin); Assert.True(model.Clips.Last().Selected);
    }
    [Fact]
    public void ClipRowDurationMatchesItsPreviewAndExportPlan()
    {
        var model = new EditorViewModel(Fixture());
        model.Select(3); model.Select(8, true);
        Assert.True(model.MakeClip());
        var row = model.Clips.Last();
        var scoped = ExportSelection.Scope(model.State, new ExportTarget.Clip(row.Id))!;
        var source = model.Project.Media.Source;
        var rate = source.Audio?.SampleRate is > 0 ? source.Audio.SampleRate : 48000;
        var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(scoped, source.DurationSeconds),
            source.DurationSeconds, rate, scoped.PauseKeepSeconds);
        Assert.StartsWith(EditorViewModel.Timecode(plan.Duration) + " · ", row.Detail);
        var wordSpan = model.Words[8].End - model.Words[3].Start;
        Assert.True(plan.Duration > wordSpan);
    }
    [Fact]
    public void MissingSelectionDoesNotCreateClip()
    {
        var model = Demo(); Assert.False(model.MakeClip()); Assert.Contains("No key", model.Notice);
    }
    [Fact]
    public void CutUndoRedoNeverChangesSourceTimings()
    {
        var model = Demo(); var source = model.Words.ToArray(); model.Select(1); model.Select(3, true); model.CutSelection();
        Assert.All(source.Skip(1).Take(3), word => Assert.Contains(word.Id, model.State!.CutWordIds));
        model.Undo(); Assert.False(model.CanUndo); Assert.True(model.CanRedo);
        model.Redo(); Assert.True(model.CanUndo); Assert.Equal(source, model.Words);
    }
    [Fact]
    public void NewEditClearsRedoHistory()
    {
        var model = Demo(); model.Select(0); model.CutSelection(); model.Undo(); model.Select(2); model.CutSelection(); Assert.False(model.CanRedo);
    }
    [Fact]
    public void RestoreCutsRetainsCorrections()
    {
        var model = Demo(); model.Select(1); model.Correct("corrected"); model.CutSelection(); model.Apply(new EditOperation.RestoreCuts());
        Assert.Equal("corrected", model.DisplayText(model.Words[1])); Assert.Empty(model.State!.CutWordIds);
    }
    [Fact]
    public void PauseIdsMatchPersistedContract()
    {
        var model = Demo(); Assert.All(model.State!.Pauses, pause => Assert.Equal("pause-after-" + model.Words[pause.AfterIndex].Id, pause.Id));
    }
    [Fact]
    public void ProductionEditingUsesLandedCoreReducer()
    {
        var source = Fixture(); var model = new EditorViewModel(source);
        model.Select(0); model.CutSelection();
        Assert.Contains(model.Words[0].Id, model.Project.Edits.CutWordIds);
        Assert.Equal(source.Transcript!.Words[0].Start, model.Project.Transcript!.Words[0].Start);
    }
    [Fact]
    public void FullAndClipExportsUseOneExplicitScopeForPlanAndCaptions()
    {
        var model = new EditorViewModel(Fixture());
        model.Select(3); model.Select(8, true);
        Assert.True(model.MakeClip());
        var clip = model.Clips.Last();
        model.Apply(new EditOperation.SetActiveClip(clip.Id));
        var source = model.State!;
        var full = ExportSelection.Scope(source, new ExportTarget.FullEdit())!;
        var chosen = ExportSelection.Scope(source, new ExportTarget.Clip(clip.Id))!;
        Assert.Null(full.ActiveClipId);
        Assert.Equal(clip.Id, chosen.ActiveClipId);
        Assert.Equal(clip.Id, model.State!.ActiveClipId);
        var duration = model.Project.Media.Source.DurationSeconds;
        var fullPlan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(full, duration), duration, 48000);
        var clipPlan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(chosen, duration), duration, 48000);
        Assert.True(fullPlan.Duration > clipPlan.Duration);
        var fullWords = EditingEngine.CaptionWords(full, fullPlan);
        var clipWords = EditingEngine.CaptionWords(chosen, clipPlan);
        Assert.True(fullWords.Count > clipWords.Count);
        Assert.All(clipWords, word => Assert.Contains(word.Id, model.Words.Skip(3).Take(6).Select(item => item.Id)));
        Assert.Throws<ArgumentException>(() => ExportSelection.Scope(source, new ExportTarget.Clip("missing")));
    }
    [Fact]
    public void UnexpectedErrorDoesNotExposeExceptionContents()
    {
        var message = UiError.Message(new InvalidOperationException("sensitive provider response"), "Export");
        Assert.DoesNotContain("sensitive", message); Assert.Contains("edits are still here", message);
    }
    [Fact]
    public void CancellationIsSilent() => Assert.Empty(UiError.Message(new OperationCanceledException(), "Export"));
    [Fact]
    public void ShareCaptionPersistsWithoutRecomposingPreview()
    {
        var model = Demo(); var changed = 0; var saves = 0;
        model.Changed += (_, _) => changed++; model.SaveRequested += (_, _) => saves++;
        model.SetShareCaption("full", "Share this take.");
        Assert.Equal("Share this take.", model.Project.Share.Captions["full"]); Assert.Equal(1, saves); Assert.Equal(0, changed);
    }
    [Fact]
    public void DemoPauseToggleIsOneUndoStep()
    {
        var model = Demo(); var pause = model.State!.Pauses.First(); var previous = model.State.CutPauseIds.Contains(pause.Id);
        model.Apply(new EditOperation.Toggle(pause.Id)); Assert.Equal(!previous, model.State!.CutPauseIds.Contains(pause.Id));
        model.Undo(); Assert.Equal(previous, model.State!.CutPauseIds.Contains(pause.Id));
    }
    [Fact]
    public void DemoSearchCanSetWordCutsExplicitly()
    {
        var model = Demo(); var word = model.Words[0];
        model.Apply(new EditOperation.SetWordCuts([word.Id], true)); Assert.Contains(word.Id, model.State!.CutWordIds);
        model.Apply(new EditOperation.SetWordCuts([word.Id], false)); Assert.DoesNotContain(word.Id, model.State!.CutWordIds);
    }
    [Fact]
    public void TranscriptionReplacementClearsEditsAndHistory()
    {
        var model = Demo(); model.Select(1); model.CutSelection(); model.SetTranscript(model.Project.Transcript!);
        Assert.Empty(model.State!.CutWordIds); Assert.Empty(model.Clips); Assert.False(model.CanUndo); Assert.False(model.HasSelection);
    }
    [Fact]
    public async Task LeavingHoldsOneSavedSnapshotAcrossDelayedReplacement()
    {
        var model = new EditorViewModel(Fixture());
        model.Select(0); model.Select(2, true); Assert.True(model.MakeClip());
        var acceptedClip = Assert.Single(model.Clips).Id;
        var acceptedProject = model.Project;
        var boundary = new ProjectLeaveBoundary(model);
        var saveStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finishSave = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var folder = Path.Combine(Path.GetTempPath(), "voxclip-win-ui-leave-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var path = Path.Combine(folder, "take.voxclip");
            var leaving = boundary.BeginAsync(async () =>
            {
                saveStarted.SetResult();
                await finishSave.Task;
                await new VoxClip.Core.Services.Project.ProjectStore().SaveAsync(model.Project, path, TestContext.Current.CancellationToken);
            });
            await saveStarted.Task;
            Assert.False(model.CanExport);
            Assert.Equal("Saving this project before leaving. Editing is paused.", model.Notice);
            model.Select(4); model.Select(6, true);
            Assert.False(model.MakeClip());
            model.SetTranscript(model.Project.Transcript!); // a late transcription result must be refused too
            model.SetShareCaption("full", "late caption");
            model.SetCaptionStyle("off");
            model.Undo();
            Assert.Same(acceptedProject, model.Project);
            finishSave.SetResult();
            await leaving;
            Assert.True(boundary.IsLeaving);
            Assert.False(model.Apply(new EditOperation.CutFillers())); // delayed load/probe after save
            var saved = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
            Assert.Equal(acceptedClip, Assert.Single(saved.Edits.Clips).Id);
            Assert.Equal(acceptedClip, Assert.Single(model.Clips).Id);
            boundary.Resume(); // replacement load failed; the old editor remains usable
            Assert.True(model.CanExport);
            Assert.True(model.MakeClip());
            Assert.Equal(2, model.Clips.Count);
        }
        finally { Directory.Delete(folder, true); }
    }
    [Fact]
    public async Task FailedLeaveSaveRestoresEditing()
    {
        var model = new EditorViewModel(Fixture());
        var boundary = new ProjectLeaveBoundary(model);
        await Assert.ThrowsAsync<IOException>(() => boundary.BeginAsync(() => throw new IOException("controlled save failure")));
        Assert.False(boundary.IsLeaving);
        model.Select(1); model.Select(3, true);
        Assert.True(model.MakeClip());
    }
    [Theory]
    [InlineData(true, false, false, false, true, false)]
    [InlineData(false, true, false, false, true, false)]
    [InlineData(false, false, true, true, true, false)]
    [InlineData(false, false, false, true, true, false)]
    [InlineData(false, false, false, false, false, false)]
    [InlineData(false, false, false, false, true, true)]
    [InlineData(false, false, true, false, true, true)]
    public void ShortcutsRespectTextFocusAndAltGr(bool text, bool correction, bool control, bool alt, bool editor, bool expected)
        => Assert.Equal(expected, ShortcutPolicy.EditorMayHandle(text, correction, control, alt, editor));
    [Theory]
    [InlineData(0, "00:00.0")]
    [InlineData(-10, "00:00.0")]
    [InlineData(16.4, "00:16.4")]
    [InlineData(3601.2, "1:00:01.2")]
    public void TimecodesUseStablePrecision(double value, string expected) => Assert.Equal(expected, EditorViewModel.Timecode(value));
    [Fact]
    public async Task PausedDemoDoesNotStartWhenSeekingIntoCut()
    {
        var model = Demo(); model.Select(0); model.CutSelection();
        await using var engine = new DemoPreviewEngine();
        var snapshot = Snapshot(model);
        await engine.LoadAsync(snapshot, null, CancellationToken.None);
        await engine.SeekAsync(snapshot.Plan.MapTime(model.Words[0].Start), true, CancellationToken.None);
        Assert.False(engine.Position.IsPlaying);
    }

    [Fact]
    public async Task SyntheticClipPreviewUsesScopedDurationAndStopsAtItsBoundary()
    {
        var model = Demo();
        model.Select(1); model.Select(3, true);
        Assert.True(model.MakeClip());
        var clip = Assert.Single(model.Clips);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(clip.Id)));
        var snapshot = Snapshot(model);
        Assert.InRange(snapshot.Plan.Duration, 0.5, 3.0);
        await using var engine = new DemoPreviewEngine();
        await engine.LoadAsync(snapshot, null, CancellationToken.None);
        await engine.SeekAsync(snapshot.Plan.Duration + 10, true, CancellationToken.None);
        Assert.Equal(snapshot.Plan.Duration, engine.Position.EditedTime, 3);
        Assert.InRange(engine.Position.SourceTime, model.Words[1].Start, snapshot.Plan.Kept[^1].EndSample / snapshot.Plan.SampleRate);
        await engine.PlayAsync(CancellationToken.None);
        Assert.InRange(engine.Position.EditedTime, 0, 0.5);
    }

    [Fact]
    public void HighlightOffsetsFollowRenderedUtf16TextIncludingPausesAndCollapsedCuts()
    {
        var words = new[] { "Tere! ", "asukoht ", "⋯ 2 cut ", "", "👩🏽‍💻 " };
        string?[] pauses = [null, " ‖ pause 1.2s ", null, null, null];
        var starts = TranscriptTextRanges.Starts(words, pauses);
        var rendered = string.Concat(words.Select((word, index) => word + pauses[index]));
        Assert.Equal(0, starts[0]);
        Assert.Equal(words[0].Length + words[1].Length + pauses[1]!.Length, starts[2]);
        for (var index = 0; index < words.Length; index++)
            Assert.Equal(words[index].TrimEnd(), rendered.Substring(starts[index], words[index].TrimEnd().Length));
        Assert.Equal(starts[3], starts[4]);
    }

    [Theory]
    [InlineData(0, 3, true, "Clip 00:00.0 / 00:03.0")]
    [InlineData(4, 3, true, "Clip 00:03.0 / 00:03.0")]
    [InlineData(7, 16, false, "Edit 00:07.0 / 00:16.0")]
    public void PreviewClockNamesItsScope(double position, double duration, bool clip, string expected)
        => Assert.Equal(expected, PreviewClockLabel.Format(position, duration, clip));

    private static ComposeSnapshot Snapshot(EditorViewModel model)
    {
        var duration = model.Project.Media.Source.DurationSeconds;
        const int rate = 48_000;
        var state = model.State!;
        var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, duration), duration, rate, state.PauseKeepSeconds);
        var size = new PixelSize(640, 360);
        return new(new("synthetic", duration, null, null, size, null, null, false, 0, -1, 0), plan, null, new(size, 30, 1_000_000));
    }
}
#endif

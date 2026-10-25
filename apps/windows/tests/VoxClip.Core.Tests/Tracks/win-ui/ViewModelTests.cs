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
    [Theory]
    [InlineData(true, false, false, false, true, false)]
    [InlineData(false, true, false, false, true, false)]
    [InlineData(false, false, true, true, true, false)]
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
        engine.SetEdit(model.State); await engine.SeekAsync(model.Words[0].Start, true, CancellationToken.None);
        Assert.False(engine.Position.IsPlaying);
    }
}
#endif

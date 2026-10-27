#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class ExportWorkflowTests
{
    [Fact]
    public void ScopeChoicesKeepTargetRoutingAndTranscriptOrder()
    {
        Assert.IsType<ExportTarget.FullEdit>(Assert.Single(ExportSelection.Targets(ExportScopeKind.FullVideo, "later", ["earlier", "later"])));
        Assert.Equal("later", Assert.IsType<ExportTarget.Clip>(Assert.Single(ExportSelection.Targets(ExportScopeKind.ThisClip, "later", ["earlier", "later"]))).Id);
        Assert.Equal(new[] { "earlier", "later" }, ExportSelection.Targets(ExportScopeKind.AllClips, "later", ["earlier", "later"]).Cast<ExportTarget.Clip>().Select(clip => clip.Id));
        Assert.Empty(ExportSelection.Targets(ExportScopeKind.AllClips, null, []));
        Assert.Throws<ArgumentException>(() => ExportSelection.Targets(ExportScopeKind.ThisClip, "suggestion", ["kept"]));
    }
    [Theory]
    [InlineData(ExportAspect.Source, "source")]
    [InlineData(ExportAspect.Landscape, "16x9")]
    [InlineData(ExportAspect.Portrait, "9x16")]
    [InlineData(ExportAspect.Square, "1x1")]
    public void FullFixtureExportKeepsLegacyFileNamesAndMp4SrtRouting(ExportAspect aspect, string legacySuffix)
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        var folder = Path.Combine(Path.GetTempPath(), "voxclip-routing-" + Guid.NewGuid().ToString("N"));
        var result = ExportSelection.Paths(model.Title, null, aspect, true, folder, "{project}-{clip}-{aspect}");
        Assert.Equal(Path.Combine(folder, model.Title + "-full-" + legacySuffix + ".mp4"), result.Mp4);
        Assert.Equal(Path.ChangeExtension(result.Mp4, ".srt"), result.Srt);
        Assert.Null(ExportSelection.Paths(model.Title, null, aspect, false, folder, "{project}-{clip}-{aspect}").Srt);
        var full = ExportSelection.Scope(model.State, new ExportTarget.FullEdit());
        Assert.Equal(model.State! with { ActiveClipId = null }, full);
    }
    [Fact]
    public async Task ExportLedgerPersistsAndUndoRestoresExportedState()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        model.Select(0); model.Select(3, true); var clip = model.MakeClip()!;
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-ledger-" + Guid.NewGuid().ToString("N"));
        try
        {
            var ledger = new ExportLedger(Path.Combine(directory, "exports.json"));
            var target = new ExportTarget.Clip(clip);
            await ledger.RecordAsync(model.Project, target, Path.Combine(directory, "clip.mp4"), TestContext.Current.CancellationToken);
            model.SetExportRecords(ledger.Records);
            Assert.Equal(ClipExportState.Exported, model.ExportStatus(clip).State);
            model.Select(2); model.CutSelection();
            Assert.Equal(ClipExportState.ChangedSinceExport, model.ExportStatus(clip).State);
            var shell = new ShellViewModel(); shell.Update(model, false, [], null);
            Assert.Equal(76, shell.Rows.Single(row => row.ClipId == clip).RowHeight);
            model.Undo(); Assert.Equal(ClipExportState.Exported, model.ExportStatus(clip).State);
            model.SetExportActivity(target, ClipExportState.Exporting, 0.42);
            Assert.Equal("Exporting 42%", model.ExportStatus(clip).Label);
            model.SetExportActivity(target, ClipExportState.Failed);
            shell.Update(model, false, [], null);
            Assert.True(shell.Rows.Single(row => row.ClipId == clip).ShowsRetry);
            var events = 0; ledger.Changed += (_, _) => events++;
            await ledger.RecordAsync(model.Project, target, Path.Combine(directory, "clip 2.mp4"), TestContext.Current.CancellationToken);
            Assert.Equal(1, events); Assert.Single(ledger.Records);
            var reopened = new ExportLedger(Path.Combine(directory, "exports.json"));
            await reopened.LoadAsync(TestContext.Current.CancellationToken);
            Assert.Equal(ledger.Records, reopened.Records);
            Assert.Single(reopened.Records);
            Assert.EndsWith("clip 2.mp4", reopened.Records.Single().OutputPath);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    [Fact]
    public async Task LedgerRecordsTheExportedSnapshotWhenTheEditorChangesBeforeSuccess()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        model.Select(0); model.Select(3, true); var clip = model.MakeClip()!;
        var exportedProject = model.Project;
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-ledger-snapshot-" + Guid.NewGuid().ToString("N"));
        try
        {
            var ledger = new ExportLedger(Path.Combine(directory, "exports.json"));
            var target = new ExportTarget.Clip(clip);
            model.Select(2); model.CutSelection();
            await ledger.RecordAsync(exportedProject, target, Path.Combine(directory, "clip.mp4"), TestContext.Current.CancellationToken);
            model.SetExportRecords(ledger.Records);
            Assert.Equal(ExportFingerprint.For(exportedProject, target), ledger.Records.Single().PlanFingerprint);
            Assert.Equal(ClipExportState.ChangedSinceExport, model.ExportStatus(clip).State);
            model.Undo(); Assert.Equal(ClipExportState.Exported, model.ExportStatus(clip).State);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    [Fact]
    public void FingerprintIgnoresSelectionAndPropertyOrderButTracksOutputChanges()
    {
        var project = RoundThreeTests.Fixture();
        var first = project with { Captions = project.Captions with { Overrides = JsonSerializer.SerializeToElement(new { text = new { transform = "none" }, layout = new { maxWords = 3 } }) } };
        var second = first with { ModifiedAt = first.ModifiedAt.AddHours(1), Captions = first.Captions with { Overrides = JsonSerializer.SerializeToElement(new { layout = new { maxWords = 3 }, text = new { transform = "none" } }) } };
        var target = new ExportTarget.FullEdit();
        Assert.Equal(ExportFingerprint.For(first, target), ExportFingerprint.For(second, target));
        Assert.NotEqual(ExportFingerprint.For(first, target), ExportFingerprint.For(first with { Export = first.Export with { Aspect = ExportAspect.Square } }, target));
        Assert.Equal(64, ExportFingerprint.For(first, target).Length);
    }
    [Fact]
    public void ClipFingerprintDoesNotChangeForACutOutsideItsRange()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        model.Select(0); model.Select(2, true); var clip = model.MakeClip()!;
        var target = new ExportTarget.Clip(clip);
        var before = ExportFingerprint.For(model.Project, target);
        model.Apply(new EditOperation.SetActiveClip(null)); model.Select(8); model.CutSelection();
        Assert.Equal(before, ExportFingerprint.For(model.Project, target));
        Assert.Equal("Rendering 1 of 2 · 50% · about 1 min left", ExportProgressText.Format(1, 2, 0.5, 45));
        Assert.Equal("Rendering 1 of 2…", ExportProgressText.Format(1, 2, null, 0));
        var original = RoundThreeTests.Fixture();
        Assert.Equal(original.Media.Source.DurationSeconds, new EditorViewModel(original with { Transcript = null }).FullTakeDuration);
    }
}
#endif

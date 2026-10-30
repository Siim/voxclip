#if WIN_UI_TESTS
using System.Text;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class EditorVoiceLabHistoryTests
{
    private static string Shared => Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
    private static Project Fixture() => ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures/voice-lab/passage-render-v3.voxclip")));
    private static byte[] Canonical(Project project) => Encoding.UTF8.GetBytes(ProjectSerialization.Serialize(project));
    private static Project Empty(Project project) => project with { SchemaVersion = 1, VoiceLab = new([]) };
    private static VoiceLabEditCommand.Accept Accept(Project project) => new(project.VoiceLab.Segments[0], project.VoiceLab.Assets!, project.VoiceLab.Voices![0] with { Status = VoiceLabVoiceStatus.Active });
    private static EditorViewModel Editor(Project project) => new(project, now: () => project.ModifiedAt);
    private static void Ai(EditorViewModel editor, bool expected)
    {
        Assert.Equal(expected, editor.ContainsAiSpeech());
        Assert.Equal(expected, Enumerable.Range(0, editor.Words.Count).Any(index => editor.PresentedWord(index).AiModified));
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        Assert.Equal(expected, shell.Rows.Single(row => row.Kind == SidebarKind.FullTake).MetaStatus.Contains("AI modified", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("accept", false, true)]
    [InlineData("off", true, false)]
    [InlineData("on", false, true)]
    [InlineData("delete", true, false)]
    [InlineData("candidate", true, true)]
    public async Task EveryCommandIsOneByteExactHistoryStep(string action, bool beforeAi, bool afterAi)
    {
        var fixture = Fixture();
        var initial = action == "accept" ? Empty(fixture) : action == "on" ? VoiceLabProject.SetEnabled(fixture, "vl-passage", false) : fixture;
        VoiceLabEditCommand command = action switch
        {
            "accept" => Accept(fixture),
            "off" => new VoiceLabEditCommand.SetEnabled("vl-passage", false),
            "on" => new VoiceLabEditCommand.SetEnabled("vl-passage", true),
            "delete" => new VoiceLabEditCommand.Delete("vl-passage"),
            _ => new VoiceLabEditCommand.ChooseCandidate("vl-passage", 1)
        };
        var editor = Editor(initial);
        var before = Canonical(initial);
        var changed = 0;
        editor.Changed += (_, _) => changed++;
        Ai(editor, beforeAi);
        Assert.False(editor.IsDirty);
        Assert.True(editor.ApplyVoiceLab(command));
        Assert.Equal(1, changed);
        Assert.True(editor.Project.ModifiedAt > initial.ModifiedAt);
        var after = Canonical(editor.Project);
        Assert.Equal(Canonical(new VoiceLabEditHistory(initial).Apply(command, initial.ModifiedAt.AddTicks(1)).Present), after);
        Assert.True(editor.IsDirty);
        Assert.Same(initial.Transcript, editor.Project.Transcript);
        Assert.Same(initial.Edits, editor.Project.Edits);
        Ai(editor, afterAi);
        editor.Undo();
        Assert.Equal(before, Canonical(editor.Project));
        Assert.False(editor.IsDirty);
        Assert.False(editor.CanUndo);
        Assert.True(editor.CanRedo);
        Ai(editor, beforeAi);
        editor.Redo();
        Assert.Equal(after, Canonical(editor.Project));
        Assert.True(editor.IsDirty);
        Assert.False(editor.CanRedo);
        Ai(editor, afterAi);
        Assert.Equal(after, Canonical(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(editor.Project))));
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-voice-history-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "take.voxclip");
            var store = new ProjectStore();
            await store.SaveAsync(editor.Project, path, TestContext.Current.CancellationToken);
            var written = await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken);
            var reopened = await store.LoadAsync(path, TestContext.Current.CancellationToken);
            Assert.Equal(written, Canonical(reopened.Project));
            Ai(Editor(reopened.Project), afterAi);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void CapabilitiesAndChangesDuringCaptionCancellationRefuseVoiceLabEdits()
    {
        var editor = Editor(Fixture());
        var snapshot = editor.Project;
        var command = new VoiceLabEditCommand.SetEnabled("vl-passage", false);
        editor.Busy = true;
        Assert.False(editor.ApplyVoiceLab(command));
        editor.Busy = false;
        editor.SetMediaUnavailable(true);
        Assert.False(editor.ApplyVoiceLab(command));
        editor.SetMediaUnavailable(false);
        editor.CaptionDrag.Begin(editor.Project.Export.Aspect);
        editor.CaptionDrag.Cancelled += (_, _) => editor.SetExport(editor.Project.Export with { Aspect = ExportAspect.Square });
        Assert.False(editor.ApplyVoiceLab(command, snapshot));
        Assert.False(editor.CanUndo);
        Assert.True(editor.Project.VoiceLab.Segments[0].Enabled);
    }

    [Fact]
    public void NoOpsPreserveRedoTimestampDirtyAndNotifications()
    {
        var editor = Editor(Fixture());
        Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled("vl-passage", false)));
        editor.Undo();
        var before = editor.Project;
        var changed = 0;
        editor.Changed += (_, _) => changed++;
        Assert.False(editor.ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled("vl-passage", true)));
        Assert.False(editor.ApplyVoiceLab(new VoiceLabEditCommand.ChooseCandidate("vl-passage", 0)));
        Assert.Same(before, editor.Project);
        Assert.True(editor.CanRedo);
        Assert.False(editor.CanUndo);
        Assert.False(editor.IsDirty);
        Assert.Equal(0, changed);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("candidate")]
    [InlineData("duplicate")]
    [InlineData("stale")]
    public void InvalidAndStaleCommandsCannotMutateProjectOrHistory(string reason)
    {
        var fixture = Fixture();
        var editor = Editor(reason == "duplicate" ? Empty(fixture) : fixture);
        var snapshot = editor.Project;
        var command = reason switch
        {
            "missing" => (VoiceLabEditCommand)new VoiceLabEditCommand.Delete("missing"),
            "candidate" => new VoiceLabEditCommand.ChooseCandidate("vl-passage", 99),
            "duplicate" => Accept(fixture) with { Assets = [.. fixture.VoiceLab.Assets!, fixture.VoiceLab.Assets![0]] },
            _ => new VoiceLabEditCommand.Delete("vl-passage")
        };
        if (reason == "stale") Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled("vl-passage", false)));
        var before = Canonical(editor.Project);
        var history = (editor.CanUndo, editor.CanRedo, editor.IsDirty);
        Assert.False(editor.ApplyVoiceLab(command, snapshot));
        Assert.Equal(before, Canonical(editor.Project));
        Assert.Equal(history, (editor.CanUndo, editor.CanRedo, editor.IsDirty));
    }

    [Fact]
    public async Task ConcurrentCommandsWithOneSnapshotCommitAtMostOnce()
    {
        var editor = Editor(Fixture());
        var snapshot = editor.Project;
        using var barrier = new Barrier(3);
        Task<bool> Start(VoiceLabEditCommand command) => Task.Run(() => { barrier.SignalAndWait(TestContext.Current.CancellationToken); return editor.ApplyVoiceLab(command, snapshot); }, TestContext.Current.CancellationToken);
        var first = Start(new VoiceLabEditCommand.SetEnabled("vl-passage", false));
        var second = Start(new VoiceLabEditCommand.Delete("vl-passage"));
        barrier.SignalAndWait(TestContext.Current.CancellationToken);
        var results = await Task.WhenAll(first, second);
        Assert.Single(results, result => result);
        editor.Undo();
        Assert.Equal(Canonical(snapshot), Canonical(editor.Project));
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public void ReentrantVoiceLabActionCannotReplaceTheCommittingAction()
    {
        var editor = Editor(Fixture());
        var reentered = true;
        EventHandler handler = (_, _) => reentered = editor.ApplyVoiceLab(new VoiceLabEditCommand.Delete("vl-passage"));
        editor.Changed += handler;
        Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled("vl-passage", false)));
        Assert.False(reentered);
        Assert.Single(editor.Project.VoiceLab.Segments);
        editor.Changed -= handler;
        editor.Undo();
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public async Task EditDuringPendingSaveRemainsDirtyUntilItsOwnSnapshotSaves()
    {
        var editor = Editor(Fixture());
        var pending = new PendingProjectSave(editor.Project, editor.MarkSaved);
        editor.Changed += (_, _) => pending.Mark(editor.Project);
        Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled("vl-passage", false)));
        var firstSnapshot = editor.Project;
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var saving = pending.FlushAsync(async (_, _) => await release.Task, TestContext.Current.CancellationToken);
        Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.ChooseCandidate("vl-passage", 1)));
        release.SetResult();
        await saving;
        Assert.True(editor.IsDirty);
        Assert.True(pending.HasChanges);
        Assert.Equal(1, editor.Project.VoiceLab.Segments[0].SelectedCandidateIndex);
        await pending.FlushAsync((snapshot, _) => { Assert.Same(editor.Project, snapshot); return Task.CompletedTask; }, TestContext.Current.CancellationToken);
        Assert.False(editor.IsDirty);
        Assert.False(pending.HasChanges);
        editor.Undo();
        Assert.Equal(Canonical(firstSnapshot), Canonical(editor.Project));
        Assert.True(editor.IsDirty);
        Assert.True(pending.HasChanges);
        editor.Redo();
        Assert.False(editor.IsDirty);
        Ai(editor, false);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LeaveFreezesUnsavedVoiceLabStateAndResumesOnlyOnFailure(bool fail)
    {
        var editor = Editor(Fixture());
        var pending = new PendingProjectSave(editor.Project, editor.MarkSaved);
        editor.Changed += (_, _) => pending.Mark(editor.Project);
        Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.Delete("vl-passage")));
        var snapshot = editor.Project;
        var leave = new ProjectLeaveBoundary(editor);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var leaving = leave.BeginAsync(() => pending.FlushAsync(async (saved, _) =>
        {
            Assert.Same(snapshot, saved);
            await release.Task;
            if (fail) throw new IOException("fixture save failure");
        }, TestContext.Current.CancellationToken));
        Assert.False(editor.ApplyVoiceLab(Accept(Fixture())));
        editor.Undo();
        Assert.Same(snapshot, editor.Project);
        release.SetResult();
        if (fail) await Assert.ThrowsAsync<IOException>(() => leaving); else await leaving;
        Assert.Equal(!fail, leave.IsLeaving);
        Assert.Equal(fail, editor.IsDirty);
        Assert.Equal(fail, pending.HasChanges);
        Ai(editor, false);
        if (!fail) leave.Resume();
        editor.Undo();
        Ai(editor, true);
        Assert.Equal(!fail, editor.IsDirty);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void NewVoiceOrOrdinaryEditInvalidatesRedoWithoutSplittingTheStep(bool ordinary)
    {
        var editor = Editor(Fixture());
        var original = Canonical(editor.Project);
        Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled("vl-passage", false)));
        editor.Undo();
        if (ordinary) Assert.True(editor.Apply(new EditOperation.Correct("w1", "changed")));
        else Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.Delete("vl-passage")));
        var changed = Canonical(editor.Project);
        Assert.False(editor.CanRedo);
        editor.Redo();
        Assert.Equal(changed, Canonical(editor.Project));
        editor.Undo();
        Assert.Equal(original, Canonical(editor.Project));
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public void MixedCaptionEditAndVoiceHistoryRestoresBothLayersExactly()
    {
        var editor = Editor(Fixture());
        editor.MoveCaptionAnchor(new(0.2, 0.3));
        var caption = Canonical(editor.Project);
        Assert.True(editor.ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled("vl-passage", false)));
        var voice = Canonical(editor.Project);
        editor.MoveCaptionAnchor(new(0.3, 0.4));
        editor.Undo();
        Assert.Equal(voice, Canonical(editor.Project));
        editor.Undo();
        Assert.Equal(caption, Canonical(editor.Project));
        editor.Redo();
        Assert.Equal(voice, Canonical(editor.Project));
        Ai(editor, false);
    }

    [Fact]
    public void HistoryAndOtherDocumentsProtectCompleteAssetIdentities()
    {
        var fixture = Fixture();
        var editor = Editor(Empty(fixture));
        Assert.True(editor.ApplyVoiceLab(Accept(fixture)));
        editor.Undo();
        Assert.Empty(VoiceLabAssetRetention.References(editor.Project));
        var asset = fixture.VoiceLab.Assets![0];
        var file = new VoiceLabRetainedFile(asset.File, "fixture:identity", 42, 100);
        var start = fixture.ModifiedAt;
        var first = VoiceLabAssetRetention.Observe(VoiceLabRetentionLedger.Empty, fixture.Id, [file], new HashSet<string>(), start, new("test", 0));
        var eligible = VoiceLabAssetRetention.Observe(first.Ledger, fixture.Id, [file], new HashSet<string>(), start.AddDays(7), new("test", 7 * 86400));
        Assert.True(eligible.CanDelete(file, new HashSet<string>()));
        Assert.False(eligible.CanDelete(file, editor.VoiceLabAssetReferences()));
        Assert.False(eligible.CanDelete(file with { Identity = "replaced" }, new HashSet<string>()));
        editor.Redo();
        Assert.False(eligible.CanDelete(file, editor.VoiceLabAssetReferences()));
        editor.Undo();
        Assert.True(editor.Apply(new EditOperation.Correct("w1", "changed")));
        Assert.DoesNotContain(asset.File, editor.VoiceLabAssetReferences());
        Assert.False(eligible.CanDelete(file, editor.VoiceLabAssetReferences([fixture])));
        Assert.True(eligible.CanDelete(file, editor.VoiceLabAssetReferences()));
    }

    [Fact]
    public void RedoAssetsCannotBeReintroducedWithADifferentIdentity()
    {
        var fixture = Fixture();
        var initial = Empty(fixture);
        var editor = Editor(initial);
        Assert.True(editor.ApplyVoiceLab(Accept(fixture)));
        editor.Undo();
        var command = Accept(fixture) with { Assets = fixture.VoiceLab.Assets!.Select(asset => asset with { CreatedAt = asset.CreatedAt.AddSeconds(1) }).ToArray() };
        Assert.NotNull(command.ApplyingTo(initial));
        Assert.False(editor.ApplyVoiceLab(command));
        Assert.True(editor.CanRedo);
        Assert.Equal(Canonical(initial), Canonical(editor.Project));
    }

    [Fact]
    public async Task PendingWriterProtectsItsSnapshotEvenAfterCurrentChanges()
    {
        var fixture = Fixture();
        var pending = new PendingProjectSave(Empty(fixture));
        pending.Mark(fixture);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var saving = pending.FlushAsync(async (_, _) => await release.Task, TestContext.Current.CancellationToken);
        pending.Mark(Empty(fixture));
        var editor = Editor(Empty(fixture));
        Assert.Subset(editor.VoiceLabAssetReferences(pending.RetainedProjects).ToHashSet(), VoiceLabAssetRetention.References(fixture).ToHashSet());
        release.SetResult();
        await saving;
        Assert.Empty(editor.VoiceLabAssetReferences(pending.RetainedProjects));
    }

    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeSavedVoiceLabProjectReopensByteForByte()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The App save/reopen evidence is owed on Windows.");
        var path = Environment.GetEnvironmentVariable("VOXCLIP_VOICELAB_SAVED_PROJECT");
        if (string.IsNullOrEmpty(path)) Assert.Skip("Set VOXCLIP_VOICELAB_SAVED_PROJECT to the owned App-saved passage fixture.");
        Assert.Equal(".voxclip", Path.GetExtension(path));
        var before = await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken);
        var reopened = await new ProjectStore().LoadAsync(path, TestContext.Current.CancellationToken);
        var editor = Editor(reopened.Project);
        var after = Canonical(editor.Project);
        Assert.Equal(before, after);
        await File.WriteAllBytesAsync(path + ".before.canonical", before, TestContext.Current.CancellationToken);
        await File.WriteAllBytesAsync(path + ".reopened.canonical", after, TestContext.Current.CancellationToken);
    }

    [Fact]
    public void DebugTranscriptActionsAreAbsentFromRelease()
    {
        var assembly = typeof(EditorViewModel).Assembly;
#if DEBUG
        Assert.NotNull(assembly.GetType("VoxClip.App.ViewModels.DebugVoiceLabActions"));
#else
        Assert.DoesNotContain(assembly.GetTypes(), type => type.Name.StartsWith("DebugVoiceLabAction", StringComparison.Ordinal));
#endif
        var source = File.ReadAllText(Path.Combine(Path.GetDirectoryName(Shared)!, "apps/windows/src/VoxClip.App/Controls/TranscriptView.cs"));
        var action = source.IndexOf("DebugVoiceLabActions.For", StringComparison.Ordinal);
        Assert.True(action >= 0);
        var start = source.LastIndexOf("#if DEBUG", action, StringComparison.Ordinal);
        Assert.True(start >= 0 && start < action);
        Assert.True(source.IndexOf("#endif", start, StringComparison.Ordinal) > action);
    }

#if DEBUG
    [Fact]
    public void DebugMenuFollowsSelectionBetaAndStaleSnapshots()
    {
        var editor = Editor(Fixture());
        Assert.Empty(DebugVoiceLabActions.For(editor, true).Actions);
        editor.Select(editor.Index("w4"));
        Assert.Empty(DebugVoiceLabActions.For(editor, false).Actions);
        var menu = DebugVoiceLabActions.For(editor, true);
        Assert.Equal(["VoiceLab.Off", "VoiceLab.Delete", "VoiceLab.Candidate.1", "VoiceLab.Candidate.2"], menu.Actions.Select(action => action.Id));
        Assert.True(menu.Actions.Single(action => action.Id == "VoiceLab.Candidate.1").Selected);
        Assert.False(menu.Apply(editor, menu.Actions[0], false));
        Assert.True(menu.Apply(editor, menu.Actions[0], true));
        Assert.False(menu.Apply(editor, menu.Actions[1], true));
        Ai(editor, false);
        menu = DebugVoiceLabActions.For(editor, true);
        Assert.Equal("VoiceLab.On", menu.Actions[0].Id);
        Assert.True(menu.Apply(editor, menu.Actions[0], true));
        Ai(editor, true);
        editor.SetMediaUnavailable(true);
        Assert.Empty(DebugVoiceLabActions.For(editor, true).Actions);
    }
#endif
}
#endif

#if WIN_UI_TESTS
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class UpdateRestartTests
{
    private sealed class TestSettings(Func<CancellationToken, Task>? flush = null) : IUpdateRestartSettings
    {
        public bool Frozen { get; private set; }
        public RestartPreparation Freeze() { Frozen = true; return RestartPreparation.Ready; }
        public Task DrainAsync(CancellationToken ct) => Task.CompletedTask;
        public Task FlushAsync(CancellationToken ct) => flush?.Invoke(ct) ?? Task.CompletedTask;
        public void Resume() => Frozen = false;
    }

    private sealed class QueueSettings(SettingsWriteQueue queue) : IUpdateRestartSettings
    {
        public RestartPreparation Freeze() { queue.Freeze(); return RestartPreparation.Ready; }
        public Task DrainAsync(CancellationToken ct) => queue.DrainAsync(ct);
        public Task FlushAsync(CancellationToken ct) => queue.FlushAsync(ct);
        public void Resume() => queue.Resume();
    }

    private sealed class DelayedSettingsStore(string path) : ISettingsStore
    {
        private readonly SettingsStore inner = new(path);
        private readonly TaskCompletionSource releaseSave = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource releaseFlush = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource SaveStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource FlushStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool FailSave { get; set; }
        public bool FailFlush { get; set; }
        public Task<AppSettings> LoadAsync(CancellationToken ct) => inner.LoadAsync(ct);
        public async Task SaveAsync(AppSettings settings, CancellationToken ct)
        {
            SaveStarted.TrySetResult();
            await releaseSave.Task.WaitAsync(ct);
            if (FailSave) throw new IOException("controlled settings save failure");
            await inner.SaveAsync(settings, ct);
        }
        public async Task FlushAsync(CancellationToken ct)
        {
            FlushStarted.TrySetResult();
            await releaseFlush.Task.WaitAsync(ct);
            if (FailFlush) throw new IOException("controlled settings flush failure");
            await inner.FlushAsync(ct);
        }
        public void ReleaseSave() => releaseSave.TrySetResult();
        public void ReleaseFlush() => releaseFlush.TrySetResult();
    }

    private static Project Fixture()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared", "fixtures", "projects", "interview-take.voxclip");
            if (File.Exists(path)) return ProjectSerialization.Deserialize(File.ReadAllText(path));
        }
        throw new FileNotFoundException("Shared project fixture not found.");
    }

    private sealed class DiskWindow : IUpdateRestartWindow
    {
        private readonly string path;
        private readonly ProjectLeaveBoundary leave;
        private readonly ProjectStore store = new();
        private Task pendingSave = Task.CompletedTask;
        private TaskCompletionSource? releasePending;
        public EditorViewModel Model { get; } = new(Fixture());
        public DiskWindow(string path) { this.path = path; leave = new(Model); }
        public bool Busy { get; set; }
        public bool TransitionActive { get; set; }
        public bool FailSave { get; set; }
        public bool IsBusyForRestart => Busy;
        public int FinalWrites { get; private set; }
        public bool Frozen => leave.IsLeaving;
        public TaskCompletionSource SaveStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void DelayPendingSave()
        {
            releasePending = new(TaskCreationOptions.RunContinuationsAsynchronously);
            pendingSave = PendingAsync();
        }
        private async Task PendingAsync()
        {
            SaveStarted.TrySetResult();
            await releasePending!.Task;
            await store.SaveAsync(Model.Project, path, CancellationToken.None);
        }
        public void ReleasePendingSave() => releasePending!.TrySetResult();
        public async Task<RestartPreparation> PrepareForRestartAsync()
        {
            if (TransitionActive) return RestartPreparation.TransitionActive;
            if (Busy) return RestartPreparation.Busy;
            try
            {
                await leave.BeginAsync(async () =>
                {
                    await pendingSave;
                    if (FailSave) throw new IOException("controlled save failure");
                    await store.SaveAsync(Model.Project, path, CancellationToken.None);
                    FinalWrites++;
                });
                return RestartPreparation.Ready;
            }
            catch (IOException) { return RestartPreparation.SaveFailed; }
        }
        public void ResumeAfterRestart() => leave.Resume();
        public async Task<Project> ReadAsync() => ProjectSerialization.Deserialize(await File.ReadAllTextAsync(path));
    }

    private static string Folder() { var path = Path.Combine(Path.GetTempPath(), "voxclip-restart-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path); return path; }
    private static void AddClip(DiskWindow window, int first)
    {
        window.Model.Select(first); window.Model.Select(first + 2, true);
        Assert.NotNull(window.Model.MakeClip());
    }

    [Fact]
    public async Task MultiplePendingEditsAreOnDiskBeforeOneDispatch()
    {
        var folder = Folder();
        try
        {
            var first = new DiskWindow(Path.Combine(folder, "first.voxclip"));
            var second = new DiskWindow(Path.Combine(folder, "second.voxclip"));
            AddClip(first, 0); AddClip(second, 3);
            first.DelayPendingSave(); second.DelayPendingSave();
            var coordinator = new UpdateRestartCoordinator(() => [first, second]);
            var flushes = 0; var dispatches = 0;
            var run = coordinator.RunAsync(new TestSettings(_ => { flushes++; return Task.CompletedTask; }), async _ =>
            {
                dispatches++;
                Assert.Equal(1, first.FinalWrites); Assert.Equal(1, second.FinalWrites);
                Assert.Single((await first.ReadAsync()).Edits.Clips);
                Assert.Single((await second.ReadAsync()).Edits.Clips);
            }, CancellationToken.None);
            await first.SaveStarted.Task;
            Assert.True(coordinator.IsPreparing);
            Assert.True(first.Frozen);
            Assert.Equal(RestartResult.AlreadyPreparing, await coordinator.RunAsync(new TestSettings(), _ => Task.CompletedTask, CancellationToken.None));
            Assert.Equal(0, dispatches);
            first.ReleasePendingSave();
            await second.SaveStarted.Task;
            second.ReleasePendingSave();
            Assert.Equal(RestartResult.Dispatched, await run);
            Assert.Equal(1, flushes); Assert.Equal(1, dispatches);
            Assert.False(first.Frozen); Assert.False(second.Frozen); Assert.False(coordinator.IsPreparing);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task DelayedFinalSaveRejectsLateMutationAndPersistsAcceptedEdit()
    {
        var folder = Folder();
        try
        {
            var window = new DiskWindow(Path.Combine(folder, "take.voxclip"));
            AddClip(window, 0);
            var accepted = Assert.Single(window.Model.Clips).Id;
            var originalCaption = window.Model.Project.Share.Captions.GetValueOrDefault("full");
            window.DelayPendingSave();
            var coordinator = new UpdateRestartCoordinator(() => [window]);
            var run = coordinator.RunAsync(new TestSettings(), _ => Task.CompletedTask, CancellationToken.None);
            await window.SaveStarted.Task;
            window.Model.Select(4); window.Model.Select(6, true);
            Assert.Null(window.Model.MakeClip());
            window.Model.SetShareCaption("full", "late");
            window.Model.SetTranscript(window.Model.Project.Transcript!);
            window.ReleasePendingSave();
            Assert.Equal(RestartResult.Dispatched, await run);
            var stored = await window.ReadAsync();
            Assert.Equal(accepted, Assert.Single(stored.Edits.Clips).Id);
            Assert.Equal(originalCaption, stored.Share.Captions.GetValueOrDefault("full"));
            Assert.NotNull(window.Model.MakeClip()); // A fake dispatch returns without ending the process.
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task LaterSaveFailureVetoesDispatchAndRestoresEarlierWindow()
    {
        var folder = Folder();
        try
        {
            var first = new DiskWindow(Path.Combine(folder, "first.voxclip"));
            var second = new DiskWindow(Path.Combine(folder, "second.voxclip")) { FailSave = true };
            AddClip(first, 0); AddClip(second, 3);
            var dispatches = 0;
            var result = await new UpdateRestartCoordinator(() => [first, second]).RunAsync(new TestSettings(),
                _ => { dispatches++; return Task.CompletedTask; }, CancellationToken.None);
            Assert.Equal(RestartResult.SaveFailed, result); Assert.Equal(0, dispatches);
            Assert.Equal(1, first.FinalWrites); Assert.False(first.Frozen); Assert.False(second.Frozen);
            Assert.Single((await first.ReadAsync()).Edits.Clips);
            AddClip(first, 6); AddClip(second, 6);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task BusyOrOwnedTransitionBlocksWithoutSavingOrDispatching()
    {
        var folder = Folder();
        try
        {
            var first = new DiskWindow(Path.Combine(folder, "first.voxclip"));
            var second = new DiskWindow(Path.Combine(folder, "second.voxclip")) { Busy = true };
            var dispatches = 0;
            var coordinator = new UpdateRestartCoordinator(() => [first, second]);
            Task Dispatch(CancellationToken _) { dispatches++; return Task.CompletedTask; }
            Assert.Equal(RestartResult.Busy, await coordinator.RunAsync(new TestSettings(), Dispatch, CancellationToken.None));
            second.Busy = false; second.TransitionActive = true;
            Assert.Equal(RestartResult.TransitionActive, await coordinator.RunAsync(new TestSettings(), Dispatch, CancellationToken.None));
            Assert.Equal(0, dispatches); Assert.False(first.Frozen); Assert.Equal(1, first.FinalWrites);
            AddClip(first, 0); AddClip(second, 3);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task CancellationBeforeDispatchRestoresEveryFrozenEditor()
    {
        var folder = Folder();
        try
        {
            var first = new DiskWindow(Path.Combine(folder, "first.voxclip"));
            var second = new DiskWindow(Path.Combine(folder, "second.voxclip"));
            using var cancel = new CancellationTokenSource();
            var dispatches = 0;
            var result = await new UpdateRestartCoordinator(() => [first, second]).RunAsync(new TestSettings(_ => { cancel.Cancel(); return Task.CompletedTask; }),
                _ => { dispatches++; return Task.CompletedTask; }, cancel.Token);
            Assert.Equal(RestartResult.Cancelled, result); Assert.Equal(0, dispatches);
            Assert.False(first.Frozen); Assert.False(second.Frozen);
            AddClip(first, 0); AddClip(second, 3);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task CancellationDuringPendingSaveWaitsForWriteButNeverDispatches()
    {
        var folder = Folder();
        try
        {
            var window = new DiskWindow(Path.Combine(folder, "take.voxclip"));
            AddClip(window, 0);
            window.DelayPendingSave();
            using var cancel = new CancellationTokenSource();
            var dispatches = 0;
            var run = new UpdateRestartCoordinator(() => [window]).RunAsync(new TestSettings(),
                _ => { dispatches++; return Task.CompletedTask; }, cancel.Token);
            await window.SaveStarted.Task;
            cancel.Cancel();
            window.ReleasePendingSave();
            Assert.Equal(RestartResult.Cancelled, await run);
            Assert.Equal(0, dispatches); Assert.False(window.Frozen);
            Assert.Single((await window.ReadAsync()).Edits.Clips);
            AddClip(window, 6);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task SettingsFlushFailureVetoesUpdaterAndRestoresEditors()
    {
        var folder = Folder();
        try
        {
            var window = new DiskWindow(Path.Combine(folder, "take.voxclip"));
            AddClip(window, 0);
            var dispatches = 0;
            var result = await new UpdateRestartCoordinator(() => [window]).RunAsync(
                new TestSettings(_ => throw new IOException("settings write failed")),
                _ => { dispatches++; return Task.CompletedTask; }, CancellationToken.None);
            Assert.Equal(RestartResult.SettingsFailed, result);
            Assert.Equal(0, dispatches); Assert.False(window.Frozen);
            Assert.Single((await window.ReadAsync()).Edits.Clips);
            AddClip(window, 6);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task UpdaterFailureDoesNotCloseOrFreezeSavedDocuments()
    {
        var folder = Folder();
        try
        {
            var first = new DiskWindow(Path.Combine(folder, "first.voxclip"));
            var second = new DiskWindow(Path.Combine(folder, "second.voxclip"));
            AddClip(first, 0); AddClip(second, 3);
            var dispatches = 0;
            var result = await new UpdateRestartCoordinator(() => [first, second]).RunAsync(new TestSettings(),
                _ => { dispatches++; throw new InvalidOperationException("private updater detail"); }, CancellationToken.None);
            Assert.Equal(RestartResult.UpdateFailed, result); Assert.Equal(1, dispatches);
            Assert.Single((await first.ReadAsync()).Edits.Clips); Assert.Single((await second.ReadAsync()).Edits.Clips);
            Assert.False(first.Frozen); Assert.False(second.Frozen);
            AddClip(first, 6); AddClip(second, 6);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task AcceptedSettingsDrainBeforeProjectSaveAndLateWriteCannotPassDelayedFlush()
    {
        var folder = Folder();
        try
        {
            var settingsPath = Path.Combine(folder, "settings.json");
            var store = new DelayedSettingsStore(settingsPath);
            var queue = new SettingsWriteQueue(store);
            queue.Initialize(await store.LoadAsync(CancellationToken.None));
            var window = new DiskWindow(Path.Combine(folder, "take.voxclip"));
            queue.Changed += key =>
            {
                if (key == "editing.pauseBreath" && !window.Model.IsLeaving)
                    window.Model.Apply(new EditOperation.SetPauseKeep(0.30));
            };
            var accepted = queue.SetAsync("editing.pauseBreath", "relaxed", TestContext.Current.CancellationToken);
            await store.SaveStarted.Task;
            var dispatches = 0;
            var coordinator = new UpdateRestartCoordinator(() => [window]);
            var run = coordinator.RunAsync(new QueueSettings(queue), async _ =>
            {
                dispatches++;
                Assert.Equal(0.30, (await window.ReadAsync()).Edits.PauseKeepSeconds);
                Assert.Equal("relaxed", (await new SettingsStore(settingsPath).LoadAsync(CancellationToken.None)).GetString("editing.pauseBreath"));
            }, CancellationToken.None);
            Assert.True(queue.IsFrozen);
            Assert.False(window.Frozen); // Accepted settings must change the project before its leave boundary.
            Assert.Equal(RestartResult.AlreadyPreparing, await coordinator.RunAsync(new QueueSettings(queue), _ => Task.CompletedTask, CancellationToken.None));
            store.ReleaseSave();
            await accepted;
            await store.FlushStarted.Task;
            Assert.True(window.Frozen);
            Assert.Equal(1, window.FinalWrites);
            await Assert.ThrowsAsync<InvalidOperationException>(() => queue.SetAsync("editing.pauseBreath", "tight", TestContext.Current.CancellationToken));
            store.ReleaseFlush();
            Assert.Equal(RestartResult.Dispatched, await run);
            Assert.Equal(1, dispatches);
            Assert.False(queue.IsFrozen);
            Assert.False(window.Frozen);
            await queue.SetAsync("general.appearance", "dark", TestContext.Current.CancellationToken);
            await queue.FlushAsync(CancellationToken.None);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task CancellationDuringSettingsDrainResumesSettingsAndProject()
    {
        var folder = Folder();
        try
        {
            var store = new DelayedSettingsStore(Path.Combine(folder, "settings.json"));
            var queue = new SettingsWriteQueue(store);
            queue.Initialize(await store.LoadAsync(CancellationToken.None));
            var accepted = queue.SetAsync("general.appearance", "light", TestContext.Current.CancellationToken);
            await store.SaveStarted.Task;
            var window = new DiskWindow(Path.Combine(folder, "take.voxclip"));
            using var cancel = new CancellationTokenSource();
            var dispatches = 0;
            var run = new UpdateRestartCoordinator(() => [window]).RunAsync(new QueueSettings(queue),
                _ => { dispatches++; return Task.CompletedTask; }, cancel.Token);
            Assert.True(queue.IsFrozen);
            cancel.Cancel();
            Assert.Equal(RestartResult.Cancelled, await run);
            Assert.False(queue.IsFrozen);
            Assert.False(window.Frozen);
            Assert.Equal(0, dispatches);
            store.ReleaseSave();
            await accepted;
            await queue.SetAsync("general.appearance", "dark", TestContext.Current.CancellationToken);
            store.ReleaseFlush();
            await queue.FlushAsync(CancellationToken.None);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task FailedRealSettingsFlushResumesBothBoundaries()
    {
        var folder = Folder();
        try
        {
            var store = new DelayedSettingsStore(Path.Combine(folder, "settings.json")) { FailFlush = true };
            store.ReleaseSave();
            var queue = new SettingsWriteQueue(store);
            queue.Initialize(await store.LoadAsync(CancellationToken.None));
            await queue.SetAsync("general.appearance", "light", TestContext.Current.CancellationToken);
            var window = new DiskWindow(Path.Combine(folder, "take.voxclip"));
            var dispatches = 0;
            var run = new UpdateRestartCoordinator(() => [window]).RunAsync(new QueueSettings(queue),
                _ => { dispatches++; return Task.CompletedTask; }, CancellationToken.None);
            await store.FlushStarted.Task;
            Assert.True(queue.IsFrozen);
            Assert.True(window.Frozen);
            store.ReleaseFlush();
            Assert.Equal(RestartResult.SettingsFailed, await run);
            Assert.Equal(0, dispatches);
            Assert.False(queue.IsFrozen);
            Assert.False(window.Frozen);
            store.FailFlush = false;
            await queue.SetAsync("general.appearance", "dark", TestContext.Current.CancellationToken);
            await queue.FlushAsync(CancellationToken.None);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task FailedAcceptedSettingCannotBeHiddenByAnotherSuccessfulWrite()
    {
        var folder = Folder();
        try
        {
            var path = Path.Combine(folder, "settings.json");
            var store = new DelayedSettingsStore(path) { FailSave = true };
            store.ReleaseSave(); store.ReleaseFlush();
            var queue = new SettingsWriteQueue(store);
            queue.Initialize(await store.LoadAsync(CancellationToken.None));
            await Assert.ThrowsAsync<IOException>(() => queue.SetAsync("general.appearance", "dark", TestContext.Current.CancellationToken));
            store.FailSave = false;
            await queue.SetAsync("cache.limitGB", 10, TestContext.Current.CancellationToken);
            var window = new DiskWindow(Path.Combine(folder, "take.voxclip"));
            var dispatches = 0;
            var coordinator = new UpdateRestartCoordinator(() => [window]);
            Task Dispatch(CancellationToken _) { dispatches++; return Task.CompletedTask; }
            Assert.Equal(RestartResult.SettingsFailed, await coordinator.RunAsync(new QueueSettings(queue), Dispatch, CancellationToken.None));
            Assert.Equal(0, dispatches);
            Assert.Equal(0, window.FinalWrites);
            Assert.False(queue.IsFrozen);
            await queue.SetAsync("general.appearance", "dark", TestContext.Current.CancellationToken);
            Assert.Equal(RestartResult.Dispatched, await coordinator.RunAsync(new QueueSettings(queue), Dispatch, CancellationToken.None));
            Assert.Equal(1, dispatches);
            Assert.False(queue.IsFrozen);
            Assert.False(window.Frozen);
            var saved = await new SettingsStore(path).LoadAsync(CancellationToken.None);
            Assert.Equal("dark", saved.GetString("general.appearance"));
            Assert.Equal(10, saved.GetDouble("cache.limitGB"));
        }
        finally { Directory.Delete(folder, true); }
    }
}
#endif

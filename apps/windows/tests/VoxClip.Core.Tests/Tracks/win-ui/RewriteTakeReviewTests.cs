#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using Xunit;
#if DEBUG
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;
#endif

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class RewriteTakeReviewTests
{
    private static string AppSource(string path) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App", path));
    [Fact]
    public void NativeRowsUseSharedNamesSingleSelectionAndFortyEpxAtThreeHundred()
    {
        var source = AppSource("Controls/RewritePanel.Takes.cs");
        Assert.StartsWith("#if DEBUG", source);
        Assert.Contains("SelectionMode = ListViewSelectionMode.Single", source);
        Assert.Contains("ContainerContentChanging += TakeContainerChanging", source);
        Assert.Contains("SetName(args.ItemContainer, content.AutomationName)", source);
        Assert.Contains("TakeRowPresentation.From(row", source);
        Assert.Contains("SetVerticalScrollMode(takeList, ScrollMode.Disabled)", source);
        Assert.Contains("FrameworkElement.HeightProperty, 40d", source);
        Assert.Contains("FrameworkElement.MinHeightProperty, 40d", source);
        Assert.Contains("Control.PaddingProperty, new Thickness(0)", source);
        Assert.Contains("new Grid { Height = 40, ColumnSpacing = 4, Padding = new(0)", source);
        Assert.Contains("Width = 32, Height = 32", source);
        Assert.Contains("VcMonoFontFamily", source);
        Assert.Contains("content.RejectName", source);
        Assert.Contains("content.Note", source);
        Assert.Contains("TextTrimming.CharacterEllipsis", source);
        Assert.DoesNotContain("Try Another", source);
        Assert.True(32 + 40 + 42 + 32 + 4 * 4 + 80 <= 300 - 32);
    }
    [Fact]
    public void LengthChoicesWrapStartUnselectedAndExplainBothUnavailableModes()
    {
        var source = AppSource("Controls/RewritePanel.Takes.cs");
        Assert.Contains("RadioButtons", source); Assert.Contains("SelectedIndex = -1", source);
        Assert.Contains("Text = \"Lip sync\", TextWrapping = TextWrapping.Wrap }, IsEnabled = false", source);
        Assert.Contains("Text = \"Retimed source video\", TextWrapping = TextWrapping.Wrap }, IsEnabled = false", source);
        Assert.Contains("Lip sync is not available in this build.", source);
        Assert.Contains("retimeCopy.Text = generation.RetimeCopy", source);
    }
    [Fact]
    public void FooterIsScopedEnabledDefaultAndFocusReturnsOnlyAfterTakeSuccess()
    {
        var panel = AppSource("Controls/RewritePanel.cs");
        var takes = AppSource("Controls/RewritePanel.Takes.cs");
        Assert.Contains("Rewrite.UseTake", takes); Assert.Contains("AccentButtonStyle", takes);
        Assert.Contains("apply.IsEnabled = generation.ReadyToAccept", takes);
        Assert.Contains("apply.IsEnabled && ShortcutPolicy.EditorMayHandle", panel);
        Assert.Contains("InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)), correctionOpen()", panel);
        Assert.Contains("!NativeReturnTarget(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject)", panel);
        Assert.Contains("Controls.Primitives.ButtonBase or ComboBox", panel);
        Assert.Contains("ReturnFocusOnClose = await session.ApplyTakeAsync()", panel);
        Assert.Contains("if (applyingTake) return", panel);
        Assert.Contains("private void Close() { session.Dispose(); }", panel);
        Assert.DoesNotContain("KeyboardAccelerator", takes);
    }
    [Fact]
    public void EditorConnectsRealPreviewDeviceEventsAndUnsubscribesOnClose()
    {
        var page = AppSource("Pages/EditorPage.xaml.cs");
        Assert.Contains("RewriteGeneration.PausePreviewAsync(preview, ct)", page);
        Assert.Contains("MediaDevice.DefaultAudioRenderDeviceChanged += OutputChanged", page);
        Assert.Contains("MediaDevice.DefaultAudioRenderDeviceChanged -= OutputChanged", page);
        Assert.Contains("generation!.RefreshOutputAsync()", page);
        var session = AppSource("ViewModels/RewriteSession.cs");
        Assert.Contains("Editor.SelectionChanged += GenerationSelectionChanged", session);
        Assert.Contains("Editor.SelectionChanged -= GenerationSelectionChanged", session);
    }
#if DEBUG
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private sealed class Harness : IAsyncDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-r11-" + Guid.NewGuid().ToString("N"));
        internal readonly EditorViewModel Editor;
        internal readonly QuoteClock Clock = new();
        internal readonly RewriteSession Session;
        internal readonly DebugRewriteTakeRunner Runner;
        internal readonly RewriteGeneration Generation;
        internal readonly Preview Preview = new();
        internal readonly VoiceLabAudition Audition;
        internal readonly List<Render> Endpoints = [];
        internal readonly List<string> Announcements = [];
        internal string? OutputReason;
        internal bool Current = true;
        internal int PublishCalls;
        internal bool OnUi;
        internal Func<CancellationToken, Task>? BeforePublish;
        internal Harness(string state = "ready", bool mixedLocal = false)
        {
            var fixture = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures/projects/interview-take.voxclip")));
            var words = Enumerable.Range(0, 8).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word, index + 1, index + 1.4,
                null, null, 1, null, TimingSource.Native)).ToArray();
            Editor = new(fixture with { Media = fixture.Media with { Source = fixture.Media.Source with { DurationSeconds = 10, Audio = new(48_000, 1) } },
                Transcript = fixture.Transcript! with { Words = words }, Edits = fixture.Edits with { CutWordIds = [], CutPauseIds = [],
                    Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null }, VoiceLab = new([]), SchemaVersion = 1 });
            Session = new(Editor, 1, mixedLocal ? 5 : 3, new(48_000, .01, Enumerable.Repeat(.01f, 1000).ToArray()), null);
            Session.Edit(mixedLocal ? "clearer word2 WORD3 word4" : "clearer word2 word3");
            Runner = new(Path.Combine(SharedResources.ResolveRoot(), "fixtures/voice-lab/take-run-cases.json"), Clock,
                storage: new(Editor.Project.Id, Path.Combine(root, "paid"), Path.Combine(root, "scratch"))) { State = state };
            Task Ui(Action action) { OnUi = true; try { action(); } finally { OnUi = false; } return Task.CompletedTask; }
            Generation = new(Runner, Runner.DiscoverAsync,
                (voice, model, seed, ct) => Session.GenerationInputAsync(voice, model, seed, true, _ => Task.FromResult(new float[480_000]), ct),
                _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => Current && Session.GenerationIsCurrent, Ui, timeProvider: Clock);
            Session.ConfigureGeneration(Generation);
            Audition = new(() => { var render = new Render(Preview, () => OutputReason); Endpoints.Add(render); return render; },
                ct => RewriteGeneration.PausePreviewAsync(Preview, ct), new SilentClock());
            Generation.Changed += (_, _) =>
            {
                if (Generation.Announcement.Length > 0 && Announcements.LastOrDefault() != Generation.Announcement) Announcements.Add(Generation.Announcement);
            };
        }
        internal async Task GenerateAsync(bool configure = true)
        {
            if (configure) await Generation.ConfigureTakesAsync(new(Audition, Runner.Scratch, Runner.RejectAsync, async (id, date, ct) =>
            {
                PublishCalls++; if (BeforePublish is { } pause) await pause(ct);
                return await Runner.PublishAsync(id, date, ct);
            }));
            await Generation.DiscoverAsync();
            Generation.MarkEstimateShown(Generation.Quote!);
            await Generation.GenerateAsync((_, _) => Task.FromResult(true));
        }
        public async ValueTask DisposeAsync()
        {
            Session.Dispose(); await Generation.Cleanup; await Audition.DisposeAsync(); Runner.Dispose();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }
    private sealed class SilentClock : TimeProvider
    {
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) => new Timer();
        private sealed class Timer : ITimer
        {
            public bool Change(TimeSpan dueTime, TimeSpan period) => true;
            public void Dispose() { }
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }
    private sealed class QuoteClock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 10, 30, 12, 0, 0, TimeSpan.Zero);
        private readonly List<Timer> timers = [];
        public override DateTimeOffset GetUtcNow() => now;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new Timer(this, callback, state); timer.Change(dueTime, period); timers.Add(timer); return timer;
        }
        internal void AdvanceTo(DateTimeOffset date)
        {
            now = date;
            foreach (var timer in timers.ToArray()) timer.Fire();
        }
        private sealed class Timer(QuoteClock clock, TimerCallback callback, object? state) : ITimer
        {
            private DateTimeOffset? due;
            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                Assert.Equal(Timeout.InfiniteTimeSpan, period);
                due = dueTime == Timeout.InfiniteTimeSpan ? null : clock.now + dueTime; return true;
            }
            internal void Fire() { if (due is { } date && date <= clock.now) { due = null; callback(state); } }
            public void Dispose() => due = null;
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
    private sealed class Render(Preview preview, Func<string?> reason) : IVoiceLabRenderEndpoint
    {
        internal readonly TaskCompletionSource Done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Plays;
        internal int Disposals;
        public Task<string?> CheckAvailabilityAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.FromResult(reason()); }
        public Task OpenAsync(string path, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Assert.True(File.Exists(path)); return Task.CompletedTask; }
        public Task PlayAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); Assert.False(preview.Position.IsPlaying); Plays++; return Task.CompletedTask; }
        public Task Completion => Done.Task;
        public TimeSpan Position => TimeSpan.Zero;
        public ValueTask DisposeAsync() { Disposals++; Done.TrySetResult(); return ValueTask.CompletedTask; }
    }
    private sealed class Preview : IPreviewEngine
    {
        internal int Pauses;
        public PreviewPosition Position { get; private set; } = new(0, 0, true);
        public Task PauseAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); Pauses++; Position = Position with { IsPlaying = false }; return Task.CompletedTask; }
        public Task PlayAsync(CancellationToken ct) { Position = Position with { IsPlaying = true }; return Task.CompletedTask; }
        public Task LoadAsync(ComposeSnapshot snapshot, IProgress<MediaProgress>? progress, CancellationToken ct) => Task.CompletedTask;
        public Task SeekAsync(double editedTime, bool exact, CancellationToken ct) => Task.CompletedTask;
        public Task UpdateSnapshotAsync(ComposeSnapshot snapshot, CancellationToken ct) => Task.CompletedTask;
        public Task UpdateCaptionsAsync(CaptionTrack? captions, CancellationToken ct) => Task.CompletedTask;
        public IAsyncEnumerable<PreviewFrame> ReadFramesAsync(CancellationToken ct) => Empty();
        private static async IAsyncEnumerable<PreviewFrame> Empty() { await Task.CompletedTask; yield break; }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    [Fact]
    public async Task BestIsPreselectedAndAutoplayPausesTheActualEditorPreviewOnce()
    {
        await using var test = new Harness("ranked"); await test.GenerateAsync();
        var expected = TakeRowPresentation.Preselect(new(test.Generation.Rows, VoiceLabTakeRunEnd.Completed));
        Assert.Equal(expected, test.Generation.SelectedTakeId); Assert.Equal(expected, test.Audition.Snapshot.TakeId);
        Assert.True(test.Audition.Snapshot.IsPlaying); Assert.Equal(1, test.Preview.Pauses);
        Assert.Equal(1, test.Endpoints.Sum(endpoint => endpoint.Plays));
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        Assert.Equal(1, test.Endpoints.Sum(endpoint => endpoint.Plays));
        Assert.True(test.Generation.ReadyToAccept);
        Assert.Equal("Use Take 2", test.Generation.AcceptTitle);
    }
    [Fact]
    public async Task ExactRankedBestIsSelectedEvenWithoutAnAuditionEndpoint()
    {
        await using var test = new Harness("ranked"); await test.GenerateAsync(configure: false);
        Assert.Equal(test.Generation.Rows[1].Id, test.Generation.SelectedTakeId);
        Assert.Equal(test.Generation.Rows[1].Id, test.Generation.BestTakeId);
        Assert.NotEqual(test.Generation.Rows[0].Id, test.Generation.SelectedTakeId);
        Assert.True(test.Generation.Selected!.Fits);
    }
    [Fact]
    public async Task RejectNeverReselectsRejectedRowsAndMovesToTheNextRankedTake()
    {
        await using var test = new Harness("three-ready"); await test.GenerateAsync();
        var rejected = test.Generation.SelectedTakeId!.Value;
        await test.Generation.RejectTakeAsync(rejected);
        Assert.DoesNotContain(test.Generation.Rows, row => row.Id == rejected);
        Assert.Equal(test.Generation.BestTakeId, test.Generation.SelectedTakeId);
        Assert.False(await test.Generation.SelectTakeAsync(rejected));
        Assert.False(test.Audition.Snapshot.IsPlaying); Assert.Null(test.Runner.Scratch(rejected));
        Assert.Contains("Take 2 selected.", test.Generation.Announcement);
    }
    [Fact]
    public async Task FailedRowsStayPresentButNeverSelectOrPlay()
    {
        await using var test = new Harness("mixed"); await test.GenerateAsync();
        Assert.Equal(3, test.Generation.Rows.Count);
        var failed = test.Generation.Rows[0];
        Assert.False(await test.Generation.SelectTakeAsync(failed.Id));
        await test.Generation.PlayTakeAsync(failed.Id);
        Assert.Equal(test.Generation.Rows[1].Id, test.Generation.SelectedTakeId);
        Assert.Equal("Take 1, didn't pass the speech check", TakeRowPresentation.From(failed, test.Generation.BestTakeId).AutomationName);
        Assert.Equal("Take 2 fits. One failed the speech check.", test.Generation.Announcement);
    }
    [Fact]
    public async Task DeviceDisappearingWhileSelectedStopsAndDisablesPlayUntilRefreshed()
    {
        await using var test = new Harness(); await test.GenerateAsync();
        var selected = test.Generation.SelectedTakeId;
        test.OutputReason = VoiceLabAudition.NoOutputDevice;
        await test.Generation.RefreshOutputAsync();
        Assert.Equal(selected, test.Generation.SelectedTakeId); Assert.False(test.Audition.Snapshot.IsPlaying);
        Assert.False(test.Generation.CanPlay); Assert.Equal(VoiceLabAudition.NoOutputDevice, test.Generation.Audition!.UnavailableReason);
        await test.Generation.PlayTakeAsync(selected!.Value);
        Assert.Equal(1, test.Endpoints.Sum(endpoint => endpoint.Plays));
        test.OutputReason = null; await test.Generation.RefreshOutputAsync();
        Assert.True(test.Generation.CanPlay); Assert.Null(test.Generation.Audition!.UnavailableReason);
    }
    [Theory]
    [InlineData("take")]
    [InlineData("source")]
    [InlineData("reject")]
    [InlineData("invalidate")]
    [InlineData("close")]
    public async Task RealLifecycleHooksStopAndRetiredScratchNeverPlays(string hook)
    {
        await using var test = new Harness("three-ready"); await test.GenerateAsync();
        var id = test.Generation.SelectedTakeId!.Value;
        var scratch = test.Runner.Scratch(id)!;
        switch (hook)
        {
            case "take": await test.Generation.SelectTakeAsync(test.Generation.Rows[1].Id); break;
            case "source": test.Editor.Select(0); await test.Generation.PendingSelectionChange; break;
            case "reject": await test.Generation.RejectTakeAsync(id); break;
            case "invalidate": await scratch.InvalidateAsync(); break;
            default: test.Session.Dispose(); await test.Generation.Cleanup; break;
        }
        Assert.False(test.Audition.Snapshot.IsPlaying);
        if (hook is "reject" or "invalidate" or "close") Assert.False(scratch.IsValid);
        if (hook is "invalidate" or "close") Assert.False(test.Generation.ReadyToAccept);
        if (hook == "invalidate") await test.Generation.PlayTakeAsync(id);
        Assert.Equal(1, test.Endpoints.Sum(endpoint => endpoint.Plays));
    }
    [Fact]
    public async Task OffThreadAuditionCompletionAlwaysMarshalsItsChangedNotification()
    {
        await using var test = new Harness(); await test.GenerateAsync();
        var delivered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Generation.Changed += (_, _) =>
        {
            if (test.Audition.Snapshot.Completed) delivered.TrySetResult(test.OnUi);
        };
        await Task.Run(() => test.Endpoints.Single(endpoint => endpoint.Plays > 0).Done.SetResult(), Token);
        Assert.True(await delivered.Task.WaitAsync(Token));
        Assert.False(test.Audition.Snapshot.IsPlaying);
    }
    [Theory]
    [InlineData("none-passed")]
    [InlineData("fatal")]
    [InlineData("cancelled")]
    [InlineData("stale")]
    public async Task NonReviewTerminalAndStaleStatesCannotAccept(string state)
    {
        await using var test = new Harness(state == "stale" ? "ready" : state); await test.GenerateAsync();
        if (state == "stale") test.Current = false;
        Assert.False(test.Generation.ReadyToAccept); Assert.False(await test.Session.ApplyTakeAsync());
        Assert.Equal(0, test.PublishCalls); Assert.False(test.Editor.CanUndo);
    }
    [Fact]
    public async Task ChangedLengthNeedsARealAvailableVideoChoiceAndLipSyncRefuses()
    {
        await using var test = new Harness("length-changed"); await test.GenerateAsync();
        Assert.NotNull(test.Generation.SelectedTakeId); Assert.Null(test.Generation.VideoChoice);
        Assert.Equal(RewriteGenerationPhase.LengthChanged, test.Generation.Phase);
        Assert.Contains("0.2 s longer", test.Generation.LengthCopy);
        Assert.False(test.Generation.ReadyToAccept);
        Assert.False(test.Generation.ChooseVideo(VoiceLabVideoMode.Lipsync));
        Assert.False(test.Generation.ChooseVideo(VoiceLabVideoMode.Retimed));
        Assert.Contains("not available in this build", test.Generation.RetimeCopy);
        Assert.False(await test.Session.ApplyTakeAsync()); Assert.Equal(0, test.PublishCalls);
    }
    [Fact]
    public async Task AcceptUsesRecipePublicationAndOneByteExactUndoRedoStep()
    {
        await using var test = new Harness("three-ready"); await test.GenerateAsync();
        var before = ProjectSerialization.Serialize(test.Editor.Project);
        Assert.True(await test.Session.ApplyTakeAsync(), test.Generation.Problem + " / " + test.Editor.Notice);
        var after = ProjectSerialization.Serialize(test.Editor.Project);
        Assert.Equal(3, test.PublishCalls); Assert.Single(test.Editor.Project.VoiceLab.Segments);
        Assert.Equal(3, test.Editor.Project.VoiceLab.Segments[0].Candidates.Count);
        Assert.True(test.Editor.ContainsAiSpeech()); Assert.False(test.Session.IsOpen);
        test.Editor.Undo(); Assert.Equal(before, ProjectSerialization.Serialize(test.Editor.Project)); Assert.False(test.Editor.CanUndo);
        test.Editor.Redo(); Assert.Equal(after, ProjectSerialization.Serialize(test.Editor.Project)); Assert.False(test.Editor.CanRedo);
    }
    [Fact]
    public async Task StalePublicationAndRepeatedAcceptCannotWrite()
    {
        await using var test = new Harness(); await test.GenerateAsync();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforePublish = async ct => { entered.SetResult(); await resume.Task.WaitAsync(ct); };
        var pending = test.Session.ApplyTakeAsync(); await entered.Task;
        Assert.False(await test.Session.ApplyTakeAsync());
        test.Current = false; resume.SetResult();
        Assert.False(await pending); Assert.False(test.Editor.CanUndo); Assert.Equal(1, test.PublishCalls);
    }
    [Fact]
    public async Task VoiceTakeWithLocalCutAndCorrectionIsStillOneUndoStep()
    {
        await using var test = new Harness(mixedLocal: true); await test.GenerateAsync();
        var before = ProjectSerialization.Serialize(test.Editor.Project);
        Assert.True(await test.Session.ApplyTakeAsync(), test.Generation.Problem + " / " + test.Editor.Notice);
        var after = ProjectSerialization.Serialize(test.Editor.Project);
        Assert.Contains("w5", test.Editor.Project.Edits.CutWordIds);
        Assert.Equal("WORD3", test.Editor.Project.Edits.Corrections["w3"]);
        Assert.True(test.Editor.ContainsAiSpeech());
        test.Editor.Undo(); Assert.Equal(before, ProjectSerialization.Serialize(test.Editor.Project)); Assert.False(test.Editor.CanUndo);
        test.Editor.Redo(); Assert.Equal(after, ProjectSerialization.Serialize(test.Editor.Project));
    }
    [Fact]
    public async Task NoOutputIsRefreshedBeforeAnyPlayCanBecomeEnabled()
    {
        await using var test = new Harness();
        Assert.False(test.Generation.CanPlay);
        test.OutputReason = VoiceLabAudition.NoOutputDevice; await test.GenerateAsync();
        Assert.False(test.Generation.CanPlay); Assert.Equal(0, test.Endpoints.Sum(endpoint => endpoint.Plays));
        Assert.Equal(0, test.Preview.Pauses);
        Assert.Equal(VoiceLabAudition.NoOutputDevice, test.Generation.Audition!.UnavailableReason);
    }
    [Fact]
    public async Task PreparingAndCancellingBeforePaidTransportKeepTheActualPriorAudition()
    {
        await using var test = new Harness(); await test.GenerateAsync();
        var selected = test.Generation.SelectedTakeId!.Value; var scratch = test.Runner.Scratch(selected)!;
        await test.Generation.InputsChangedAsync();
        Assert.True(test.Audition.Snapshot.IsPlaying);
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Runner.BeforeTransport = async ct => { entered.SetResult(); await new TaskCompletionSource().Task.WaitAsync(ct); };
        var pending = test.Generation.GenerateAsync((_, _) => Task.FromResult(true)); await entered.Task.WaitAsync(Token);
        Assert.True(test.Audition.Snapshot.IsPlaying); Assert.True(scratch.IsValid);
        await test.Generation.CancelAsync(); await pending;
        Assert.Equal(selected, test.Generation.SelectedTakeId); Assert.True(test.Audition.Snapshot.IsPlaying);
        Assert.Equal(1, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task FirstPaidTransportStopsAndInvalidatesPriorAuditionBeforeNewRows()
    {
        await using var test = new Harness(); await test.GenerateAsync();
        var scratch = test.Runner.Scratch(test.Generation.SelectedTakeId!.Value)!;
        test.Generation.MarkEstimateShown(test.Generation.Quote!); test.Runner.State = "generating";
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Generation.Changed += (_, _) => { if (test.Generation.Phase == RewriteGenerationPhase.Generating) entered.TrySetResult(); };
        var pending = test.Generation.GenerateAsync((_, _) => Task.FromResult(true)); await entered.Task.WaitAsync(Token);
        Assert.False(test.Audition.Snapshot.IsPlaying); Assert.False(scratch.IsValid);
        Assert.Null(test.Generation.SelectedTakeId); Assert.Empty(test.Generation.Rows);
        await test.Generation.CancelAsync(); await pending;
        Assert.False(test.Generation.ReadyToAccept);
    }
    [Fact]
    public async Task ExpiringTheNextRunQuoteDoesNotDisableTheAlreadyReviewedPaidTake()
    {
        await using var test = new Harness(); await test.GenerateAsync();
        var selected = test.Generation.SelectedTakeId; var previous = test.Generation.Quote!;
        Assert.True(test.Generation.ReadyToAccept);
        test.Clock.AdvanceTo(previous.ExpiresAt); await test.Generation.PendingUpdate;
        Assert.NotSame(previous, test.Generation.Quote); Assert.Equal(selected, test.Generation.SelectedTakeId);
        Assert.True(test.Generation.ReadyToAccept); Assert.True(test.Audition.Snapshot.IsPlaying);
        Assert.True(await test.Session.ApplyTakeAsync(), test.Generation.Problem + " / " + test.Editor.Notice);
        Assert.Equal(1, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task FailedPublicationKeepsThePanelOpenAndDoesNotCreateHistory()
    {
        await using var test = new Harness(); await test.GenerateAsync();
        test.BeforePublish = _ => throw new IOException("Synthetic publication failure");
        Assert.False(await test.Session.ApplyTakeAsync());
        Assert.True(test.Session.IsOpen); Assert.False(test.Editor.CanUndo); Assert.Empty(test.Editor.Project.VoiceLab.Segments);
        Assert.NotEmpty(test.Generation.Problem);
    }
    [Theory]
    [InlineData("instruction", true, false, true, false)]
    [InlineData("proposed words", true, false, true, false)]
    [InlineData("correction", false, true, true, false)]
    [InlineData("takes list", false, false, true, true)]
    [InlineData("panel", false, false, true, true)]
    [InlineData("disabled footer", false, false, false, false)]
    public async Task UseTakeReturnBelongsOnlyToAnEnabledFooterOutsideEditors(string focus, bool textFocus, bool correctionOpen, bool enabled, bool expected)
    {
        await using var test = new Harness(); await test.GenerateAsync(); Assert.NotEmpty(focus);
        Assert.Equal("Use Take 1", test.Generation.AcceptTitle);
        var handled = enabled && test.Generation.ReadyToAccept && ShortcutPolicy.EditorMayHandle(textFocus, correctionOpen, false, false, true);
        Assert.Equal(expected, handled);
        if (handled) Assert.True(await test.Session.ApplyTakeAsync());
        Assert.Equal(expected, test.Editor.CanUndo);
    }
    [Fact]
    public async Task AnnouncementsUseSharedPerRowAndCombinedTerminalCopy()
    {
        await using var test = new Harness("mixed"); await test.GenerateAsync();
        Assert.Equal(new[] { TakeRowPresentation.Ready(1), TakeRowPresentation.Ready(2), TakeRowPresentation.Completion(3, 2, 1) }, test.Announcements);
        var content = TakeRowPresentation.From(test.Generation.Rows[1], test.Generation.BestTakeId);
        Assert.Equal("Take 2", content.Title); Assert.EndsWith(" s", content.Duration);
        Assert.Equal("Best match", content.Note); Assert.Equal("Take 2, " + content.Duration + ", Best match", content.AutomationName);
        Assert.Equal("Play take 2", content.PlayName); Assert.Equal("Pause take 2", content.PauseName); Assert.Equal("Reject take 2", content.RejectName);
    }
#endif
}
#endif

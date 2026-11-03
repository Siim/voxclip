#if WIN_UI_TESTS
using System.Reflection;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class PaidTakePlaybackTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UseAnywayDoesNotClaimPlaybackAndPreservesTheDurationGate(bool changedDuration)
    {
        await using var test = new Harness(false, true, VoiceLabTakeRunEnd.Completed);
        test.Runner.Advisory = true;
        test.Runner.ChangedDuration = changedDuration;
        test.NoOutput = true;
        await test.GenerateAsync();
        var row = Assert.Single(test.Generation.Rows);
        Assert.False(test.Generation.CanPlayTake(row.Id));
        Assert.True(test.Generation.CanUseTakeAnyway(row.Id));
        Assert.False(test.Audition.Snapshot.Completed);
        Assert.True(await test.Generation.UseTakeAnywayAsync(row.Id));
        Assert.False(test.Audition.Snapshot.Completed);
        Assert.Empty(test.OpenedPaths);
        Assert.Equal(changedDuration ? RewriteGenerationPhase.LengthChanged : RewriteGenerationPhase.ReadyToAccept, test.Generation.Phase);
        Assert.Equal(!changedDuration, test.Session.CanAcceptAll);
        Assert.Null(test.Generation.VideoChoice);
    }

    [Fact]
    public async Task UseAllNeverPublishesAnUnacceptedAdvisoryAlternative()
    {
        await using var test = new Harness(false, false, VoiceLabTakeRunEnd.Completed);
        test.Runner.Advisory = true;
        await test.GenerateAsync();
        var advisory = test.Generation.Rows[0];
        var clean = test.Generation.Rows[1];
        Assert.Equal(clean.Id, test.Generation.SelectedTakeId);
        Assert.False(await test.Session.ApplyTakeAsync());
        Assert.Equal(new[] { clean.Id }, test.PublishedIds);
        Assert.Null(test.Generation.Rows[0].AcceptedJoinAdvisory);
        Assert.True(await test.Generation.UseTakeAnywayAsync(advisory.Id));
        Assert.False(await test.Session.ApplyTakeAsync());
        Assert.Equal(new[] { clean.Id, advisory.Id }, test.PublishedIds);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task JoinAdvisoryPlaybackNeverSelectsOrEnablesUse(bool advisoryOnly)
    {
        await using var test = new Harness(false, advisoryOnly, VoiceLabTakeRunEnd.Completed);
        test.Runner.Advisory = true;
        await test.GenerateAsync();
        var row = test.Generation.Rows[0];
        Assert.True(row.Selectable);
        var selected = test.Generation.SelectedTakeId;
        Assert.NotEqual(row.Id, selected);
        Assert.False(await test.Generation.SelectTakeAsync(row.Id));
        await test.Generation.PlayTakeAsync(row.Id);
        Assert.Equal(row.Id, test.Audition.Snapshot.TakeId);
        Assert.Equal(selected, test.Generation.SelectedTakeId);
        Assert.Equal(!advisoryOnly, test.Session.CanAcceptAll);
        Assert.Equal(0, test.PublishCalls);
        Assert.True(await test.Generation.UseTakeAnywayAsync(row.Id));
        var accepted = test.Generation.Selected!;
        Assert.Equal(row.Id, accepted.Id);
        Assert.False(accepted.RequiresJoinAdvisoryAcceptance);
        Assert.True(test.Session.CanAcceptAll);
        Assert.False(test.Editor.CanUndo);
        Assert.Equal(0, test.PublishCalls);
        Assert.Equal(row.Qa!.JoinSeams, accepted.AcceptedJoinAdvisory!.Seams);
        Assert.True(await test.Generation.SelectTakeAsync(row.Id));
        await test.Generation.PlayTakeAsync(row.Id);
        Assert.Equal(accepted.AcceptedJoinAdvisory, test.Generation.Selected!.AcceptedJoinAdvisory);
        Assert.Contains("Listen before using.", TakeRowPresentation.From(test.Generation.Selected, test.Generation.BestTakeId).Copy);
        await test.Generation.RejectTakeAsync(row.Id);
        Assert.NotEqual(row.Id, test.Generation.SelectedTakeId);
        Assert.Equal(!advisoryOnly, test.Session.CanAcceptAll);
    }

    [Theory]
    [InlineData(false, false, VoiceLabTakeRunEnd.Completed)]
    [InlineData(false, true, VoiceLabTakeRunEnd.Completed)]
    [InlineData(true, false, VoiceLabTakeRunEnd.Completed)]
    [InlineData(true, true, VoiceLabTakeRunEnd.Completed)]
    [InlineData(true, true, VoiceLabTakeRunEnd.Fatal)]
    public async Task FailedPaidAudioPlaysWithoutSelectingPublishingOrChangingUse(bool uncheckedAudio, bool allFailed, VoiceLabTakeRunEnd end)
    {
        await using var test = new Harness(uncheckedAudio, allFailed, end);
        await test.GenerateAsync();
        var generation = test.Generation;
        var row = generation.Rows[0];
        var selected = generation.SelectedTakeId; var best = generation.BestTakeId;
        var ready = generation.ReadyToAccept; var title = generation.AcceptTitle;
        var project = ProjectSerialization.Serialize(test.Editor.Project);
        Assert.Equal(!allFailed, ready);
        Assert.True(generation.CanPlayTake(row.Id));
        await generation.PlayTakeAsync(row.Id);
        Assert.True(test.Audition.Snapshot.IsPlaying);
        Assert.Equal(row.Id, test.Audition.Snapshot.TakeId);
        var path = test.OpenedPaths.Last();
        if (uncheckedAudio)
        {
            Assert.NotEqual(test.Runner.Scratch(row.Id)?.MixedAudioPath, path);
            Assert.Equal(test.Runner.PaidBytes, await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken));
            Assert.Null(row.Audio); Assert.Null(row.Qa); Assert.Null(row.Generated!.Alignment);
        }
        else Assert.Equal(test.Runner.Scratch(row.Id)!.MixedAudioPath, path);
        Assert.False(await generation.SelectTakeAsync(row.Id));
        Assert.Equal(selected, generation.SelectedTakeId); Assert.Equal(best, generation.BestTakeId);
        Assert.Equal(ready, generation.ReadyToAccept); Assert.Equal(title, generation.AcceptTitle);
        Assert.Equal(project, ProjectSerialization.Serialize(test.Editor.Project)); Assert.False(test.Editor.CanUndo);
        Assert.Equal(0, test.PublishCalls);
        if (allFailed) Assert.False(await test.Session.ApplyTakeAsync());
        Assert.Equal(0, test.PublishCalls);
        await generation.PlayTakeAsync(row.Id);
        Assert.False(test.Audition.Snapshot.IsPlaying);
        if (uncheckedAudio) Assert.False(File.Exists(path));
        else Assert.True(test.Runner.Scratch(row.Id)!.IsValid);
        Assert.True(File.Exists(test.Runner.PaidPath));
        Assert.Equal(selected, generation.SelectedTakeId); Assert.Equal(best, generation.BestTakeId);
    }

    [Fact]
    public async Task PassedTakeKeepsItsExistingSelectionMixAndUseBehavior()
    {
        await using var test = new Harness(true, false, VoiceLabTakeRunEnd.Completed);
        await test.GenerateAsync();
        var passed = test.Generation.Rows.Single(row => row.Selectable);
        Assert.Equal(passed.Id, test.Generation.SelectedTakeId); Assert.True(test.Generation.ReadyToAccept);
        await test.Generation.PlayTakeAsync(passed.Id);
        Assert.Equal(passed.Id, test.Audition.Snapshot.TakeId); Assert.True(test.Audition.Snapshot.IsPlaying);
        Assert.Equal(test.Runner.Scratch(passed.Id)!.MixedAudioPath, test.OpenedPaths.Last());
        Assert.Equal(passed.Id, test.Generation.BestTakeId); Assert.True(test.Generation.ReadyToAccept);
    }

    [Theory]
    [InlineData("source")]
    [InlineData("selection")]
    [InlineData("close")]
    public async Task PendingUncheckedSnapshotCannotStartAfterItsContextChanges(string change)
    {
        await using var test = new Harness(true, false, VoiceLabTakeRunEnd.Completed);
        await test.GenerateAsync();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforePaid = async () => { entered.SetResult(); await release.Task.WaitAsync(TestContext.Current.CancellationToken); };
        var playing = test.Generation.PlayTakeAsync(test.Generation.Rows[0].Id);
        await entered.Task.WaitAsync(TestContext.Current.CancellationToken);
        if (change == "source") await test.Generation.StopForSourceAsync();
        else if (change == "selection")
        {
            await test.Generation.PlayTakeAsync(test.Generation.Rows.Single(row => row.Selectable).Id);
            await test.Generation.StopForSourceAsync();
        }
        else test.Session.Dispose();
        var count = test.OpenedPaths.Count;
        release.SetResult(); await playing;
        Assert.False(test.Audition.Snapshot.IsPlaying); Assert.Equal(count, test.OpenedPaths.Count);
        Assert.False(test.LastPaid?.IsValid ?? false);
        Assert.True(File.Exists(test.Runner.PaidPath));
    }

    [Fact]
    public void FailureAccessibilityNamesUseTheActualPhraseAndExactMacHelp()
    {
        var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", "eleven_v4", "voice", Guid.NewGuid(), null, null);
        var row = new VoiceLabTakeRow(Guid.NewGuid(), 2, 1, Generated: new([1, 0], 24000, null, receipt),
            Failure: new VoiceLabException(VoiceLabErrorKind.MalformedResponse));
        var content = TakeRowPresentation.From(row, null, 4);
        Assert.Equal("Play phrase 4, take 3, not checked", content.PlayName);
        Assert.Equal("Pause phrase 4, take 3, not checked", content.PauseName);
        Assert.Equal("Listen to this take as ElevenLabs returned it. It was not checked and stays left out.", content.PlayHelp);
        Assert.Equal("Take 3 · not checked: The provider returned an unreadable response. Checks may be incomplete. Left out.", content.FailureText);
    }

    private sealed class Harness : IAsyncDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-paid-review-" + Guid.NewGuid().ToString("N"));
        internal readonly EditorViewModel Editor;
        internal readonly RewriteSession Session;
        internal readonly Runner Runner;
        internal readonly RewriteGeneration Generation;
        internal readonly VoiceLabAudition Audition;
        internal readonly List<string> OpenedPaths = [];
        internal Func<Task>? BeforePaid;
        internal PreparedVoiceLabAsset? LastPaid;
        internal int PublishCalls;
        internal readonly List<Guid> PublishedIds = [];
        internal bool NoOutput;
        internal Harness(bool uncheckedAudio, bool allFailed, VoiceLabTakeRunEnd end)
        {
            var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures/projects/interview-take.voxclip")));
            var words = Enumerable.Range(0, 8).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word,
                index + 1, index + 1.4, null, null, 1, null, TimingSource.Native)).ToArray();
            Editor = new(project with { SchemaVersion = 1, VoiceLab = new([]),
                Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 10, Audio = new(48000, 1) } },
                Transcript = project.Transcript! with { Words = words },
                Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() } });
            Session = new(Editor, 1, 3, new(48000, .01, Enumerable.Repeat(.01f, 1000).ToArray()), null);
            Session.Edit("clearer word2 word3");
            Runner = new(new(Editor.Project.Id, Path.Combine(root, "paid"), Path.Combine(root, "scratch")), uncheckedAudio, allFailed, end);
            Generation = new(Runner, _ => Task.FromResult(new RewriteGenerationChoices([new("voice", "My voice")],
                    [new("eleven_multilingual_v2", "Multilingual v2", ["en"], true, false, 5000, 1)])),
                (voice, model, seed, ct) => Session.GenerationInputAsync(voice, model, seed, true, (request, _) =>
                {
                    var samples = new float[checked((int)request.Frames)];
                    return Task.FromResult((VoiceLabSourceExcerpt.Whole(samples), VoiceLabTakeProcessing.Envelope(samples, request.SampleRate)));
                }, ct), _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => Session.GenerationIsCurrent,
                action => { action(); return Task.CompletedTask; });
            Session.ConfigureGeneration(Generation);
            Audition = new(() => new Endpoint(OpenedPaths, () => NoOutput ? VoiceLabAudition.NoOutputDevice : null), _ => Task.CompletedTask, new SilentClock());
        }
        internal async Task GenerateAsync()
        {
            await Generation.ConfigureTakesAsync(new(Audition, Runner.Scratch, _ => Task.CompletedTask,
                (id, _, _) => { PublishCalls++; PublishedIds.Add(id); throw new InvalidOperationException("Playback must not publish a take."); }, async (id, ct) =>
                {
                    if (BeforePaid is { } before) await before();
                    return LastPaid = await Runner.PaidAudioAsync(id, ct);
                }));
            await Generation.DiscoverAsync();
            Generation.MarkEstimateShown(Generation.Quote!);
            await Generation.GenerateAsync((_, _) => Task.FromResult(true));
            Assert.True(Generation.Rows.Count > 0, Generation.Phase + ": " + Generation.Problem + " / " + Runner.Error);
            await Audition.StopAsync();
        }
        public async ValueTask DisposeAsync()
        {
            Session.Dispose(); await Generation.Cleanup; await Audition.DisposeAsync(); await Runner.InvalidateAsync();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private sealed class Runner(VoiceLabTakeStorage storage, bool uncheckedAudio, bool allFailed, VoiceLabTakeRunEnd end) : IVoiceLabTakeRunner
    {
        internal bool Advisory;
        internal bool ChangedDuration;
        private readonly Dictionary<Guid, VoiceLabTakeScratch> scratches = [];
        private VoiceLabTakeInput? input;
        private VoiceLabTakeRunQuote? pending;
        private VoiceLabAsset? paid;
        internal Exception? Error;
        internal string PaidPath => Path.Combine(storage.PaidRoot, storage.ProjectId, Path.GetFileName(paid!.File));
        internal byte[] PaidBytes => File.ReadAllBytes(PaidPath);
        internal VoiceLabTakeScratch? Scratch(Guid id) => scratches.GetValueOrDefault(id);
        internal async Task<PreparedVoiceLabAsset?> PaidAudioAsync(Guid id, CancellationToken ct) =>
            await VoiceLabAssets.PreparePaidAsync(paid!, storage.ProjectId, storage.PaidRoot, storage.ScratchRoot, ct);
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput value, CancellationToken ct = default)
        {
            input = value;
            VoiceLabPreparedAction Action(VoiceLabOperation operation) => (VoiceLabPreparedAction)typeof(VoiceLabPreparedAction)
                .GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single(constructor => constructor.GetParameters().Length == 5).Invoke([Guid.NewGuid(), "fixture", DateTimeOffset.UtcNow.AddHours(1),
                    new VoiceLabEstimate("elevenlabs", operation, 1, "fixture", .01m, null, "fixture"),
                    new VoiceLabReview(operation, Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, "fixture", value.ModelId, "voice", null, null, value.RecordId)]);
            pending = new(Guid.NewGuid(), Enumerable.Range(0, 3).Select(index => new VoiceLabTakeQuote(index, (uint)index,
                Action(VoiceLabOperation.TextToSpeech), Action(VoiceLabOperation.SpeechToText))).ToArray());
            return Task.FromResult(pending);
        }
        public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default) =>
            throw new InvalidOperationException("Use the stub dispatch boundary.");
        public async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
        {
            try { return await RunAsync(quote, dispatch, progress, ct); }
            catch (Exception error) { Error = error; throw; }
        }
        private async Task<VoiceLabTakeRunResult> RunAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress, CancellationToken ct)
        {
            await dispatch.AuthorizeAsync(quote.Takes[0].Synthesis.Review.RequestId, ct);
            await dispatch.Start(() => Task.FromResult(true), ct);
            if (progress is not null) await progress([]);
            Directory.CreateDirectory(storage.PaidRoot); Directory.CreateDirectory(storage.ScratchRoot);
            var samples = Enumerable.Range(0, 96000).Select(index => (float)(.05 * Math.Sin(index * .1))).ToArray();
            paid = VoiceLabAssetStore.Write(VoiceTrainingAudio.Wav(samples)[44..], 24000, storage.ProjectId,
                Guid.NewGuid().ToString("D"), storage.PaidRoot, DateTimeOffset.UtcNow, ct);
            List<VoiceLabTakeRow> rows = [];
            foreach (var take in quote.Takes.Take(allFailed ? 1 : 2))
            {
                var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", input!.ModelId, "voice", take.Synthesis.Review.RequestId, null, null);
                var generated = new VoiceLabAudioResult(PaidBytes[44..], 24000, null, receipt);
                VoiceLabTakeAudio? audio = null;
                if (!uncheckedAudio || take.Index > 0)
                {
                    var snapshot = await PaidAudioAsync(take.Synthesis.Review.RequestId, ct);
                    var frames = (long)Math.Floor((input.Window.End - input.Window.Start) * 24000 + .5);
                    if (ChangedDuration) frames += 4800;
                    var incoming = (long)Math.Ceiling(input.Window.LeftSeam.FadeSamples / 2 * 24000d / input.SourceSampleRate);
                    var plan = new VoiceLabFitPlan([], new(0, 0), new(0, 0), incoming, incoming + frames, input.Window.Start, input.Window.End,
                        input.Window.StartSample, input.Window.EndSample, frames, [new(input.Text, .01, frames / 24000d - .01, true)]);
                    VoiceLabFitResult fit = ChangedDuration ? new VoiceLabFitResult.ChangedDuration(plan, frames / 24000d, .2) : new VoiceLabFitResult.Exact(plan);
                    var fitted = VoiceLabSilenceFit.Prepare(snapshot!, paid, fit, input.Window, input.SourceSampleRate, ct);
                    var source = new float[checked((int)Math.Floor(input.Source.TotalFrames * 24000d / input.SourceSampleRate + .5))];
                    var scratch = VoiceLabTakeRenderer.Stage(fitted, new(24000, samples, 0, null, fit), input, VoiceLabSourceExcerpt.Whole(source), storage.ScratchRoot, ct);
                    scratches.Add(take.Synthesis.Review.RequestId, scratch); audio = scratch.Audio;
                }
                rows.Add(new(take.Synthesis.Review.RequestId, take.Index, take.Seed, receipt, Generated: generated, Quote: take, Audio: audio,
                    Qa: audio is null ? null : new(take.Index == 0 && !Advisory ? .5 : 1, take.Index == 0 && Advisory ? 4 : 0, -3, .8,
                        take.Index == 0 ? [Advisory ? VoiceLabTakeQaFailure.Loudness : VoiceLabTakeQaFailure.Transcript] : [])
                        { JoinSeams = take.Index == 0 && Advisory ? [new("left", 4)] : [] },
                    Score: take.Index > 0 ? 1 : null, Failure: audio is null ? new VoiceLabException(VoiceLabErrorKind.InvalidAlignment) : null));
            }
            if (progress is not null) await progress(rows);
            return new(rows, end);
        }
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => ReferenceEquals(pending, quote);
        public Task DiscardPendingAsync() { pending = null; return Task.CompletedTask; }
        public void InvalidatePreparation() => pending = null;
        public async Task InvalidateAsync()
        {
            pending = null;
            foreach (var scratch in scratches.Values) await scratch.InvalidateAsync();
            scratches.Clear();
        }
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => Task.FromResult(cap);
    }

    private sealed class Endpoint(List<string> paths, Func<string?> unavailable) : IVoiceLabRenderEndpoint
    {
        private readonly TaskCompletionSource done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<string?> CheckAvailabilityAsync(CancellationToken ct) => Task.FromResult(unavailable());
        public Task OpenAsync(string path, CancellationToken ct) { paths.Add(path); Assert.True(File.Exists(path)); return Task.CompletedTask; }
        public Task PlayAsync(CancellationToken ct) => Task.CompletedTask;
        public Task Completion => done.Task;
        public TimeSpan Position => TimeSpan.Zero;
        public ValueTask DisposeAsync() { done.TrySetResult(); return ValueTask.CompletedTask; }
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
}
#endif

#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Xunit;
#if DEBUG
using VoxClip.App.Services;
#endif

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class RewriteGenerationTests
{
    private static string Source(string path) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps", "windows", "src", "VoxClip.App", path));
    [Fact]
    public void ProductGenerationShipsWhileFixturesStayDebugOnlyAndUseNativeErrorAndCostControls()
    {
        Assert.DoesNotContain("#if DEBUG", Source("ViewModels/RewriteGeneration.cs"));
        Assert.StartsWith("#if DEBUG", Source("ViewModels/DebugRewriteTakeRunner.cs"));
        Assert.DoesNotContain("#if DEBUG", Source("Services/RewriteGenerationBackend.cs"));
        var panel = Source("Controls/RewritePanel.cs");
        Assert.Contains("Severity = InfoBarSeverity.Error, IsClosable = false", panel);
        Assert.Contains("generationError.ActionButton = settings; generationError.Content = retry", panel);
        Assert.Contains("generation.MarkEstimateShown(quote)", panel);
        Assert.Contains("Ui.ConfirmAsync(XamlRoot, \"Generate Takes\", copy, \"Continue\", token)", panel);
        // The sheet offers this editor's project, not the first window's (voice-lab.md §6.5.2).
        Assert.Contains("App.Settings?.ShowCreateVoice(window)", panel);
        Assert.Contains("new RewritePanel(rewrite, () => Transcript.CorrectionOpen, owner)", Source("Pages/EditorPage.xaml.cs"));
        Assert.Contains("Ui.Button(\"Create Your Voice…\", () =>", panel);
        Assert.DoesNotContain("(2 min)", panel);
        Assert.DoesNotContain("Clean Audio", panel);
        Assert.Contains("prices: VoiceLabPrices.Load(), synthesisModel: \"eleven_multilingual_v2\"", Source("Pages/EditorPage.xaml.cs"));
        Assert.Contains("panel.DebugFitStatesAsync", Source("Pages/EditorPage.NativeProbe.cs"));
    }
    [Fact]
    public void Provider401AndRefusalsUseSafeExactCopy()
    {
        Assert.Equal("ElevenLabs rejected the key (401). Your edits are saved.", UiError.Message(new VoiceLabException(VoiceLabErrorKind.Unauthorized, "untrusted detail"), "Generate"));
        Assert.DoesNotContain("untrusted", UiError.Message(new VoiceLabException(VoiceLabErrorKind.ProviderFailure, "untrusted"), "Generate"));
        Assert.Equal("This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in. Clean audio is not available in this build. Re-record this sentence instead.",
            RewriteSession.Refusal(new VoiceLabGeometryException(VoiceLabGeometryErrorCode.RoomToneUnavailable)));
        foreach (var error in new Exception[] { new VoiceLabGeometryException(VoiceLabGeometryErrorCode.NoVoicedAudio), new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.NoVoicedAudio) })
            Assert.Equal("There isn't enough timed speech to estimate this change. Your edits are saved.", RewriteSession.Refusal(error));
    }
    [Fact]
    public void SourceAudioRefusalsSayWhatWentWrong()
    {
        // As on the Mac (RewriteSession.refusal): the source-audio error's own text, not "Rewrite stopped…".
        Assert.Equal("The audio cannot be read. Check that the file is still available. Your edits are saved.",
            RewriteSession.Refusal(new VoxClip.Media.VoiceLab.VoiceLabSourceAudioException(VoxClip.Media.VoiceLab.VoiceLabSourceAudioErrorCode.Unreadable)));
        Assert.Equal("The source audio's sample rate differs from the project. Reopen the original source. Your edits are saved.",
            RewriteSession.Refusal(new VoxClip.Media.VoiceLab.VoiceLabSourceAudioException(VoxClip.Media.VoiceLab.VoiceLabSourceAudioErrorCode.RateMismatch)));
        Assert.Equal("This audio's sample rate is outside the range Voice Lab supports. Your edits are saved.",
            RewriteSession.Refusal(new VoxClip.Media.VoiceLab.VoiceLabSourceAudioException(VoxClip.Media.VoiceLab.VoiceLabSourceAudioErrorCode.UnsupportedRate)));
    }
    /// <summary>The Editor's reader hands each request field to Media's decode in its place. A long incoming silence the decode
    /// did not reach would leave staging nothing to read before the widened window, and the take would be refused after it was
    /// paid for (Mac d4dfef26).</summary>
    [Fact]
    public async Task SourceReaderHandsEachRequestFieldToTheDecodeInItsPlace()
    {
        var window = new VoiceLabWindow("w10", "w12", [], [], 11, 13.4, 528_000, 643_200,
            new(VoiceLabSeamKind.Gap, 11, 528_000, 960), new(VoiceLabSeamKind.Gap, 13.4, 643_200, 960));
        TimedWord[] items = [new("w10", "word10", WordKind.Word, 11, 11.4, null, null, 1, null, TimingSource.Native)];
        var request = new RewriteSourceRequest(4_800_000, 48_000, window, 7.5, 0.25, items);
        var read = (VoiceLabSourceExcerpt.Whole([0.1f]), new AudioEnvelope(48_000, 0.01, []));
        var path = "first.mov";
        var seen = new List<object?>();
        var reader = RewriteSourceRequest.Reader(() => path, (source, frames, rate, decoded, incoming, outgoing, words, ct) =>
        {
            seen.AddRange([source, frames, rate, decoded, incoming, outgoing, words, ct]);
            return Task.FromResult(read);
        });
        // The path is read with the request, so a relinked source is the one decoded.
        path = "relinked.mov";
        using var cancel = new CancellationTokenSource();
        var result = await reader(request, cancel.Token);
        Assert.Same(read.Item1, result.Excerpt); Assert.Same(read.Item2, result.Envelope);
        Assert.Equal(new object?[] { "relinked.mov", 4_800_000L, 48_000, window, 7.5, 0.25, items, cancel.Token }, seen);
        Assert.Same(window, seen[3]); Assert.Same(items, seen[6]);
        // The Editor passes Media's decode as a method group, which binds by position. The decoder's parameters are
        // RewriteSourceAsync's, by name and type in order, so the two silences cannot change places on the way.
        static (string?, Type)[] Parameters(System.Reflection.MethodInfo method) =>
            method.GetParameters().Select(parameter => (parameter.Name, parameter.ParameterType)).ToArray();
        Assert.Equal(Parameters(typeof(VoxClip.Media.VoiceLab.VoiceLabSourceAudio).GetMethod(nameof(VoxClip.Media.VoiceLab.VoiceLabSourceAudio.RewriteSourceAsync))!),
            Parameters(typeof(RewriteSourceDecoder).GetMethod(nameof(RewriteSourceDecoder.Invoke))!));
        Assert.Contains("var readSource = RewriteSourceRequest.Reader(() => media?.Path ?? \"\", VoiceLabSourceAudio.RewriteSourceAsync);",
            Source("Pages/EditorPage.xaml.cs"));
    }
#if DEBUG
    private static string Fixture => Path.Combine(SharedResources.ResolveRoot(), "fixtures", "voice-lab", "take-run-cases.json");
    private static VoiceLabTakeInput Input(string voice = "voice-a", string model = "model-a", uint seed = uint.MaxValue) =>
        new("clearer words", model, voice, "en", seed, "content-key", [0.1f, 0.2f], 48_000, [], new HashSet<string>(),
            new("first", "last", [], [], 1, 2, 48_000, 96_000, new(VoiceLabSeamKind.Hard, 1, 48_000, 100), new(VoiceLabSeamKind.Hard, 2, 96_000, 100)),
            null, null, false, true);
    private sealed class Clock : TimeProvider
    {
        internal DateTimeOffset Now = new(2026, 10, 30, 12, 0, 0, TimeSpan.Zero);
        private DateTimeOffset? timerNow;
        private DateTimeOffset TimerNow => timerNow ?? Now;
        private readonly List<Timer> timers = [];
        public override DateTimeOffset GetUtcNow() => Now;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new Timer(this, callback, state);
            timer.Change(dueTime, period); timers.Add(timer); return timer;
        }
        internal void FireDueTimers()
        {
            foreach (var timer in timers.ToArray()) timer.Fire();
        }
        internal int ActiveTimers => timers.Count(timer => timer.Due is not null);
        internal void SeparateTimerClock() => timerNow = Now;
        internal void AdvanceTimers(TimeSpan elapsed)
        {
            timerNow = TimerNow + elapsed;
            FireDueTimers();
        }
        private sealed class Timer(Clock clock, TimerCallback callback, object? state) : ITimer
        {
            internal DateTimeOffset? Due { get; private set; }
            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                Assert.Equal(Timeout.InfiniteTimeSpan, period);
                Due = dueTime == Timeout.InfiniteTimeSpan ? null : clock.TimerNow + dueTime; return true;
            }
            internal void Fire()
            {
                if (Due is not { } due || due > clock.TimerNow) return;
                Due = null; callback(state);
            }
            public void Dispose() => Due = null;
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
    private sealed class Harness : IAsyncDisposable
    {
        internal readonly Clock Clock = new();
        internal readonly DebugRewriteTakeRunner Runner;
        internal readonly RewriteGeneration Generation;
        internal decimal? Cap;
        internal bool Current = true;
        internal bool Consented = true;
        internal int ConsentCalls;
        internal int DiscoveryCalls;
        internal Func<CancellationToken, Task>? BeforeDiscovery;
        internal Func<string>? ReadText;
        internal string DiscoveryLabel = "initial";
        internal string Text = "clearer words";
        internal Harness()
        {
            Runner = new(Fixture, Clock);
            Generation = new(Runner, async ct =>
                {
                    DiscoveryCalls++;
                    var label = DiscoveryLabel;
                    if (BeforeDiscovery is { } pause) await pause(ct);
                    return new RewriteGenerationChoices([new("voice-a", label), new("voice-b", "B")],
                        [new("model-a", "A", ["en"], true, false, 5000, 1), new("model-b", "B", ["en"], true, false, 5000, 1)]);
                },
                (voice, model, seed, _) => Task.FromResult<VoiceLabTakeInput?>(Input(voice, model, seed) with { Text = ReadText?.Invoke() ?? Text, ProviderConsent = Consented }),
                _ => { ConsentCalls++; return Task.FromResult(Consented); }, _ => Task.FromResult(Cap), () => Current, timeProvider: Clock);
        }
        internal async Task ReadyAsync()
        {
            await Generation.DiscoverAsync();
            Generation.MarkEstimateShown(Assert.IsType<VoiceLabTakeRunQuote>(Generation.Quote));
        }
        internal Task GenerateAsync(bool approved = true) => Generation.GenerateAsync((_, _) => Task.FromResult(approved));
        public async ValueTask DisposeAsync() { Generation.Dispose(); await Generation.Cleanup; }
    }
    [Fact]
    public async Task NothingIsSentUntilThisExactEstimateHasRendered()
    {
        await using var test = new Harness();
        await test.Generation.DiscoverAsync();
        Assert.NotNull(test.Generation.Quote);
        Assert.False(test.Generation.CanExecute);
        await test.GenerateAsync();
        Assert.Equal(0, test.Runner.PaidRequests);
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        Assert.True(test.Generation.CanExecute);
        await test.GenerateAsync();
        Assert.Equal(1, test.Runner.PaidRequests);
        Assert.Equal(0, test.Runner.HttpCalls);
        Assert.NotNull(test.Generation.Quote);
        Assert.False(test.Generation.CanExecute);
    }
    [Theory]
    [InlineData(0, "Generate Takes", "Generate Again")]
    [InlineData(0.02, "Generate Takes · ≈ $0.02", "Generate Again · ≈ $0.02")]
    [InlineData(1.2, "Generate Takes · ≈ $1.20", "Generate Again · ≈ $1.20")]
    public async Task WholeRunButtonUsesTheFreshQuoteAmount(decimal price, string before, string after)
    {
        await using var test = new Harness(); test.Runner.Price = price;
        await test.ReadyAsync();
        Assert.Equal(before, test.Generation.ButtonTitle);
        Assert.Contains("Generate up to 3 new takes, about ", test.Generation.ButtonName);
        await test.GenerateAsync();
        Assert.Equal(after, test.Generation.ButtonTitle);
        Assert.Equal(3, test.Generation.Quote!.Takes.Count);
        Assert.Equal(new[] { 0, 1, 2 }, test.Generation.Quote.Takes.Select(take => take.Index));
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DeclineKeepsQuotePriceRowsSelectionAndAuditionAndAsksAgain(bool unknown)
    {
        await using var test = new Harness(); await test.ReadyAsync(); await test.GenerateAsync();
        var selected = test.Generation.SelectedTakeId!.Value;
        test.Generation.AuditionTake(selected);
        test.Runner.Price = unknown ? null : 1m;
        await test.Generation.InputsChangedAsync();
        var quote = test.Generation.Quote!; test.Generation.MarkEstimateShown(quote);
        var title = test.Generation.ButtonTitle;
        var prompts = new List<string>();
        Task<bool> Decline(string copy, CancellationToken ct) { prompts.Add(copy); return Task.FromResult(false); }
        await test.Generation.GenerateAsync(Decline);
        await test.Generation.GenerateAsync(Decline);
        Assert.Equal(2, prompts.Count); Assert.Equal(prompts[0], prompts[1]);
        if (unknown) Assert.Equal("VoxClip can't tell what this costs. Check ElevenLabs's pricing.", prompts[0]);
        Assert.Same(quote, test.Generation.Quote); Assert.Equal(title, test.Generation.ButtonTitle);
        Assert.Equal(selected, test.Generation.SelectedTakeId); Assert.Equal(selected, test.Generation.AuditionedTakeId);
        Assert.Single(test.Generation.Rows); Assert.Equal(1, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task SubFiftyCentCapCrossingConfirmsUsingTheLiveCap()
    {
        await using var test = new Harness(); await test.ReadyAsync();
        test.Runner.Spend = 0.99m; test.Cap = 1m;
        var prompts = new List<string>();
        await test.Generation.GenerateAsync((copy, _) => { prompts.Add(copy); return Task.FromResult(true); });
        Assert.Contains("This takes you past your $1 limit for ElevenLabs this month.", Assert.Single(prompts));
        Assert.Equal(1, test.Runner.PaidRequests);
    }
    [Theory]
    [InlineData("words")]
    [InlineData("instruction")]
    public async Task EditingDuringInitialDiscoveryQuotesTheLatestInputWithoutAnotherConsentPrompt(string field)
    {
        using var owner = new RewriteSession(Editor(), 10, 12, Envelope(), null);
        await using var test = new Harness(); owner.ConfigureGeneration(test.Generation);
        test.ReadText = () => owner.NewWords;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeDiscovery = async ct => { entered.SetResult(); await finish.Task.WaitAsync(ct); };
        var pending = test.Generation.DiscoverAsync(); await entered.Task;
        if (field == "words") owner.Edit("the latest proposed words");
        else await owner.SetInstructionAsync("the latest instruction");
        await test.Generation.PendingUpdate;
        Assert.Equal(0, test.Runner.Preparations);
        finish.SetResult(); await pending; await test.Generation.PendingUpdate;
        Assert.True(test.Generation.HasDiscovered); Assert.NotNull(test.Generation.Quote);
        Assert.Equal(owner.NewWords, Assert.Single(test.Runner.PreparedInputs).Text);
        Assert.Equal(1, test.DiscoveryCalls); Assert.Equal(1, test.ConsentCalls);
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        Assert.True(test.Generation.CanExecute); Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Theory]
    [InlineData("language")]
    [InlineData("region")]
    [InlineData("key")]
    public async Task InvalidatedDiscoveryRestartsAndIgnoresAnUncancellableStaleResult(string dependency)
    {
        await using var test = new Harness();
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeDiscovery = _ => test.DiscoveryCalls == 1 ? finish.Task : Task.CompletedTask;
        var pending = test.Generation.DiscoverAsync();
        Assert.Equal(1, test.DiscoveryCalls);
        test.DiscoveryLabel = dependency + "-latest";
        var restarted = test.Generation.DiscoveryInputsChangedAsync();
        test.Text = "latest text after " + dependency;
        await test.Generation.InputsChangedAsync();
        finish.SetResult(); await pending; await restarted;
        Assert.Equal(2, test.DiscoveryCalls); Assert.Equal(1, test.ConsentCalls);
        Assert.Equal(dependency + "-latest", test.Generation.Voices[0].Label);
        Assert.Equal(test.Text, Assert.Single(test.Runner.PreparedInputs).Text);
        Assert.True(test.Generation.HasDiscovered); Assert.NotNull(test.Generation.Quote);
        Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task DiscoveryChangesDoNotStartProviderAccessBeforeTheUserChoosesVoice()
    {
        await using var test = new Harness();
        await test.Generation.DiscoveryInputsChangedAsync();
        Assert.Equal(0, test.ConsentCalls); Assert.Equal(0, test.DiscoveryCalls);
        await test.ReadyAsync();
        await test.Generation.DiscoveryInputsChangedAsync();
        Assert.Equal(2, test.DiscoveryCalls); Assert.NotNull(test.Generation.Quote);
        Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task ClosingDuringDiscoveryCannotRestartOrQuoteItsLateResult()
    {
        await using var test = new Harness();
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeDiscovery = _ => finish.Task;
        var pending = test.Generation.DiscoverAsync();
        test.Generation.Dispose(); finish.SetResult(); await pending; await test.Generation.Cleanup;
        Assert.False(test.Generation.HasDiscovered); Assert.Equal(0, test.Runner.Preparations);
        Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public void ProviderIdentityChangesRestartDiscoveryWithoutReadingKeyBytes()
    {
        var page = Source("Pages/EditorPage.xaml.cs");
        Assert.Contains("var rediscover = previous.HasStartedDiscovery", page);
        Assert.Contains("if (rediscover) _ = RediscoverRewriteAsync(session, previous, session.Generation!)", page);
        Assert.Contains("await previous.Cleanup", page);
        Assert.Contains("keyChanges.Renamed += KeyChanged", page);
        Assert.Contains("keyChanges?.Dispose()", page);
        Assert.Contains("generation!.DiscoveryInputsChangedAsync()", page);
        Assert.DoesNotContain("GetKeyAsync", page[page.IndexOf("private void ConfigureRewriteGeneration", StringComparison.Ordinal)..page.IndexOf("private void CutSelectionClicked", StringComparison.Ordinal)]);
    }
    [Theory]
    [InlineData(0.49, 0)]
    [InlineData(0.5, 1)]
    public async Task S14ThresholdIsComparedBeforeRounding(decimal price, int expectedPrompts)
    {
        await using var test = new Harness(); test.Runner.Price = price;
        await test.ReadyAsync();
        var prompts = 0;
        await test.Generation.GenerateAsync((_, _) => { prompts++; return Task.FromResult(true); });
        Assert.Equal(expectedPrompts, prompts); Assert.Equal(1, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task ConsentDeclineAndNoVoiceMakeNoQuoteOrPaidRequest()
    {
        await using var test = new Harness(); test.Consented = false;
        await test.Generation.DiscoverAsync(); await test.GenerateAsync();
        Assert.False(test.Generation.HasDiscovered); Assert.Null(test.Generation.Quote); Assert.Equal(0, test.Runner.Preparations);
        var runner = new DebugRewriteTakeRunner(Fixture) { State = "no-voice" };
        using var generation = new RewriteGeneration(runner, runner.DiscoverAsync,
            (_, _, _, _) => throw new InvalidOperationException("No voice must not prepare."), _ => Task.FromResult(true),
            _ => Task.FromResult<decimal?>(null), () => true);
        await generation.DiscoverAsync();
        Assert.Empty(generation.Voices); Assert.True(generation.HasDiscovered); Assert.False(generation.CanExecute);
        Assert.Equal(0, runner.PaidRequests); Assert.Equal(0, runner.HttpCalls);
    }
    [Fact]
    public async Task CapIsReadAgainAtTheFirstTransportAndDeclineRetainsReview()
    {
        await using var test = new Harness(); await test.ReadyAsync(); await test.GenerateAsync();
        var selected = test.Generation.SelectedTakeId;
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        test.Runner.BeforeTransport = _ => { test.Cap = 0.01m; return Task.CompletedTask; };
        var prompts = 0;
        await test.Generation.GenerateAsync((_, _) => { prompts++; return Task.FromResult(false); });
        Assert.Equal(1, prompts); Assert.Equal(1, test.Runner.PaidRequests);
        Assert.Equal(selected, test.Generation.SelectedTakeId); Assert.Single(test.Generation.Rows);
        Assert.NotNull(test.Generation.Quote); Assert.True(test.Generation.CanExecute);
    }
    [Theory]
    [InlineData("close")]
    [InlineData("input")]
    [InlineData("cancel")]
    public async Task SuspendingConfirmationCannotOutliveItsOwner(string change)
    {
        await using var test = new Harness(); test.Runner.Price = 1;
        await test.ReadyAsync();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var approval = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken observed = default;
        var pending = test.Generation.GenerateAsync((_, token) => { observed = token; entered.SetResult(); return approval.Task; });
        await entered.Task;
        await test.GenerateAsync();
        if (change == "close") test.Generation.Dispose();
        else if (change == "input") await test.Generation.InputsChangedAsync();
        else await test.Generation.CancelAsync();
        Assert.True(observed.IsCancellationRequested);
        approval.SetResult(true); await pending;
        Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task FiveMinuteExpiryRequotesButDoesNotDispatchOrReuseRenderAcknowledgement()
    {
        await using var test = new Harness(); await test.ReadyAsync();
        var old = test.Generation.Quote!;
        test.Clock.Now = test.Clock.Now.AddMinutes(5);
        await test.GenerateAsync();
        Assert.NotSame(old, test.Generation.Quote); Assert.Equal(2, test.Runner.Preparations);
        Assert.Equal(0, test.Runner.PaidRequests); Assert.False(test.Generation.CanExecute);
        test.Generation.MarkEstimateShown(old); Assert.False(test.Generation.CanExecute);
        test.Generation.MarkEstimateShown(test.Generation.Quote!); await test.GenerateAsync();
        Assert.Equal(1, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task ExpiryDuringConfirmationRequotesWithoutAutomaticallySending()
    {
        await using var test = new Harness(); test.Runner.Price = 1;
        await test.ReadyAsync();
        await test.Generation.GenerateAsync((_, _) => { test.Clock.Now = test.Clock.Now.AddMinutes(5); return Task.FromResult(true); });
        Assert.Equal(0, test.Runner.PaidRequests); Assert.Equal(2, test.Runner.Preparations);
        Assert.NotNull(test.Generation.Quote); Assert.False(test.Generation.CanExecute);
    }
    [Fact]
    public async Task RenderingAfterExpiryPreparesAndReenablesTheDisplayedButtonWithoutDispatch()
    {
        Assert.Contains("generate.Content = generation.ButtonTitle", Source("Controls/RewritePanel.cs"));
        Assert.Contains("generate.IsEnabled = generation.CanExecute", Source("Controls/RewritePanel.cs"));
        await using var test = new Harness(); await test.ReadyAsync();
        var expired = test.Generation.Quote!;
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Runner.BeforePrepare = ct => finish.Task.WaitAsync(ct);
        test.Clock.Now = expired.ExpiresAt;
        Assert.Null(test.Generation.Quote);
        Assert.Equal("Generate Takes", test.Generation.ButtonTitle);
        Assert.False(test.Generation.CanExecute); Assert.True(test.Generation.IsPreparing);
        Assert.Equal(2, test.Runner.Preparations);
        finish.SetResult(); await test.Generation.PendingUpdate;
        Assert.Equal("Generate Takes · ≈ $0.02", test.Generation.ButtonTitle);
        Assert.False(test.Generation.CanExecute);
        test.Generation.MarkEstimateShown(expired); Assert.False(test.Generation.CanExecute);
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        Assert.True(test.Generation.CanExecute); Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task QuoteTimerRepreparesWithoutRenderingAndPreparationFailureRemainsRetryable(bool fail)
    {
        await using var test = new Harness(); await test.ReadyAsync();
        Assert.Equal(1, test.Clock.ActiveTimers);
        test.Runner.PreparationError = fail ? new VoiceLabException(VoiceLabErrorKind.Unauthorized) : null;
        test.Clock.Now = test.Generation.Quote!.ExpiresAt;
        test.Clock.FireDueTimers(); await test.Generation.PendingUpdate;
        Assert.Equal(2, test.Runner.Preparations); Assert.Equal(0, test.Runner.PaidRequests);
        Assert.False(test.Generation.CanExecute);
        if (fail)
        {
            Assert.Equal("Generate Takes", test.Generation.ButtonTitle);
            Assert.Equal("ElevenLabs rejected the key (401). Your edits are saved.", test.Generation.Problem);
            test.Clock.FireDueTimers(); Assert.Equal(2, test.Runner.Preparations);
            test.Runner.PreparationError = null; await test.Generation.DiscoverAsync();
        }
        test.Generation.MarkEstimateShown(test.Generation.Quote!); Assert.True(test.Generation.CanExecute);
        test.Generation.Dispose(); await test.Generation.Cleanup;
        Assert.Equal(0, test.Clock.ActiveTimers);
        test.Clock.Now = test.Clock.Now.AddMinutes(10); test.Clock.FireDueTimers();
        Assert.Equal(fail ? 3 : 2, test.Runner.Preparations);
    }
    [Fact]
    public async Task BackwardWallClockAdjustmentRearmsEarlyExpiryWithoutRendering()
    {
        await using var test = new Harness(); await test.ReadyAsync();
        test.Clock.SeparateTimerClock();
        var quote = test.Generation.Quote!;
        test.Clock.Now = test.Clock.Now.AddHours(-1);
        test.Clock.AdvanceTimers(TimeSpan.FromMinutes(5));
        Assert.Equal(1, test.Runner.Preparations);
        Assert.Equal(1, test.Clock.ActiveTimers);
        test.Clock.Now = quote.ExpiresAt;
        test.Clock.AdvanceTimers(TimeSpan.FromSeconds(30));
        await test.Generation.PendingUpdate;
        Assert.Equal(2, test.Runner.Preparations);
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        Assert.True(test.Generation.CanExecute);
        Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task ForwardWallClockAdjustmentRecoversWithinThirtyTimerSecondsWithoutRendering()
    {
        await using var test = new Harness(); await test.ReadyAsync();
        test.Clock.SeparateTimerClock();
        test.Clock.Now = test.Generation.Quote!.ExpiresAt.AddHours(1);
        test.Clock.AdvanceTimers(TimeSpan.FromSeconds(30));
        await test.Generation.PendingUpdate;
        Assert.Equal(2, test.Runner.Preparations);
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        Assert.True(test.Generation.CanExecute);
        Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task EarlyTimerDuringDeclinedConfirmationResumesBoundedFreshnessChecks()
    {
        await using var test = new Harness(); test.Runner.Price = 1; await test.ReadyAsync();
        test.Clock.SeparateTimerClock();
        var quote = test.Generation.Quote!;
        var approval = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = test.Generation.GenerateAsync((_, _) => approval.Task);
        test.Clock.Now = test.Clock.Now.AddHours(-1);
        test.Clock.AdvanceTimers(TimeSpan.FromMinutes(5));
        approval.SetResult(false); await pending;
        Assert.Equal(1, test.Clock.ActiveTimers);
        test.Clock.Now = quote.ExpiresAt;
        test.Clock.AdvanceTimers(TimeSpan.FromSeconds(30));
        await test.Generation.PendingUpdate;
        Assert.Equal(2, test.Runner.Preparations);
        Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task ExpiryWhileDecliningAnOpenConfirmationStillAutomaticallyRequotes()
    {
        await using var test = new Harness(); test.Runner.Price = 1; await test.ReadyAsync();
        var approval = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = test.Generation.GenerateAsync((_, _) => approval.Task);
        test.Clock.Now = test.Generation.Quote!.ExpiresAt;
        test.Clock.FireDueTimers(); Assert.Equal(1, test.Runner.Preparations);
        approval.SetResult(false); await pending; await test.Generation.PendingUpdate;
        Assert.Equal(2, test.Runner.Preparations); Assert.NotNull(test.Generation.Quote);
        Assert.False(test.Generation.CanExecute); Assert.Equal(0, test.Runner.PaidRequests);
        test.Generation.MarkEstimateShown(test.Generation.Quote!); Assert.True(test.Generation.CanExecute);
    }
    [Fact]
    public async Task PriorReviewIsReplacedOnlyAtTheFakeFirstPaidTransport()
    {
        await using var test = new Harness(); await test.ReadyAsync(); await test.GenerateAsync();
        var selected = test.Generation.SelectedTakeId!.Value; test.Generation.AuditionTake(selected);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Runner.BeforeTransport = async ct => { entered.SetResult(); await resume.Task.WaitAsync(ct); };
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        var pending = test.GenerateAsync(); await entered.Task;
        Assert.Single(test.Generation.Rows); Assert.Equal(selected, test.Generation.SelectedTakeId);
        Assert.Equal(selected, test.Generation.AuditionedTakeId);
        var atTransport = false;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Generation.Changed += (_, _) =>
        {
            if (test.Generation.Phase != RewriteGenerationPhase.Generating) return;
            atTransport = true; Assert.Empty(test.Generation.Rows); Assert.Null(test.Generation.SelectedTakeId); Assert.Null(test.Generation.AuditionedTakeId);
            started.TrySetResult();
        };
        test.Runner.State = "generating";
        resume.SetResult();
        await started.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.True(atTransport);
        await test.Generation.CancelAsync(); await pending;
        Assert.Equal(2, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task CancellingBeforeFirstTransportKeepsPriorTakesSelectionAndAudition()
    {
        await using var test = new Harness(); await test.ReadyAsync(); await test.GenerateAsync();
        var selected = test.Generation.SelectedTakeId!.Value; test.Generation.AuditionTake(selected);
        test.Generation.MarkEstimateShown(test.Generation.Quote!);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Runner.BeforeTransport = async ct => { entered.SetResult(); await new TaskCompletionSource().Task.WaitAsync(ct); };
        var pending = test.GenerateAsync(); await entered.Task;
        await test.Generation.CancelAsync(); await pending;
        Assert.Equal(1, test.Runner.PaidRequests); Assert.Single(test.Generation.Rows);
        Assert.Equal(selected, test.Generation.SelectedTakeId); Assert.Equal(selected, test.Generation.AuditionedTakeId);
        Assert.NotNull(test.Generation.Quote);
    }
    [Theory]
    [InlineData("voice")]
    [InlineData("model")]
    [InlineData("text")]
    [InlineData("instruction")]
    [InlineData("consent")]
    [InlineData("settings")]
    public async Task EachInputChangeAutomaticallyRequotesWithoutPayingAndKeepsTakes(string field)
    {
        await using var test = new Harness(); await test.ReadyAsync(); await test.GenerateAsync();
        var quote = test.Generation.Quote; var selected = test.Generation.SelectedTakeId!.Value;
        test.Generation.AuditionTake(selected);
        var count = test.Runner.Preparations;
        switch (field)
        {
            case "voice": await test.Generation.ChooseVoiceAsync("voice-b"); break;
            case "model": await test.Generation.ChooseModelAsync("model-b"); break;
            case "text": test.Text = "new bound words"; await test.Generation.InputsChangedAsync(); break;
            case "consent": test.Consented = false; await test.Generation.InputsChangedAsync(); break;
            default: await test.Generation.InputsChangedAsync(); break;
        }
        Assert.NotSame(quote, test.Generation.Quote);
        Assert.Equal(field == "consent" ? count : count + 1, test.Runner.Preparations);
        Assert.Single(test.Generation.Rows); Assert.Equal(selected, test.Generation.SelectedTakeId); Assert.Equal(selected, test.Generation.AuditionedTakeId);
        Assert.Equal(1, test.Runner.PaidRequests); Assert.False(test.Generation.CanExecute);
    }
    [Fact]
    public async Task PreparingHasPlainDisabledTitleAndFailuresAreInlineAndRetryable()
    {
        await using var test = new Harness();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Runner.BeforePrepare = async ct => { entered.SetResult(); await resume.Task.WaitAsync(ct); };
        var pending = test.Generation.DiscoverAsync(); await entered.Task;
        Assert.Equal("Generate Takes", test.Generation.ButtonTitle); Assert.True(test.Generation.IsPreparing); Assert.False(test.Generation.CanExecute);
        test.Runner.PreparationError = new VoiceLabException(VoiceLabErrorKind.Unauthorized);
        resume.SetResult(); await pending;
        Assert.Equal("ElevenLabs rejected the key (401). Your edits are saved.", test.Generation.Problem);
        Assert.Equal(RewriteGenerationPhase.Failed, test.Generation.Phase); Assert.Equal(0, test.Runner.PaidRequests);
        test.Runner.BeforePrepare = null; test.Runner.PreparationError = null;
        await test.Generation.InputsChangedAsync(); Assert.Equal("", test.Generation.Problem); Assert.NotNull(test.Generation.Quote);
    }
    [Fact]
    public async Task ThreeFailedChecksProduceNonePassedAndAWholeFreshQuote()
    {
        await using var test = new Harness(); test.Runner.State = "none-passed";
        await test.ReadyAsync(); await test.GenerateAsync();
        Assert.Equal(3, test.Generation.Rows.Count); Assert.Equal(RewriteGenerationPhase.NonePassed, test.Generation.Phase);
        Assert.Equal(RewriteGeneration.NonePassed, test.Generation.Announcement); Assert.Null(test.Generation.SelectedTakeId);
        Assert.Equal(3, test.Generation.Quote!.Takes.Count); Assert.Equal(0, test.Runner.HttpCalls);
        Assert.Equal(new uint[] { uint.MaxValue, 0, 1 }, (await new DebugRewriteTakeRunner(Fixture).PrepareAsync(Input(), TestContext.Current.CancellationToken)).Takes.Select(take => take.Seed));
    }
    [Fact]
    public async Task FatalProviderResultIsNotMistakenForNonePassed()
    {
        await using var test = new Harness(); test.Runner.State = "provider-error";
        await test.ReadyAsync(); await test.GenerateAsync();
        Assert.Equal("ElevenLabs rejected the key (401). Your edits are saved.", test.Generation.Problem);
        Assert.NotEqual(RewriteGenerationPhase.NonePassed, test.Generation.Phase);
        Assert.NotNull(test.Generation.Quote);
    }
    [Theory]
    [InlineData("edit")]
    [InlineData("readonly")]
    [InlineData("leaving")]
    [InlineData("settings")]
    [InlineData("region")]
    [InlineData("close")]
    public async Task RewriteOwnerRetiresGenerationOnEveryHardInvalidation(string reason)
    {
        var editor = Editor(); var current = true;
        using var owner = new RewriteSession(editor, 10, 12, Envelope(), null, connectorIsCurrent: () => current);
        await using var test = new Harness(); owner.ConfigureGeneration(test.Generation); await test.ReadyAsync(); await test.GenerateAsync();
        switch (reason)
        {
            case "edit": editor.Apply(new EditOperation.Correct("w10", "changed")); break;
            case "readonly": editor.SetMediaUnavailable(true); break;
            case "leaving": editor.BeginLeaving(); break;
            case "settings": owner.SettingsChanged(false); break;
            case "region": current = false; owner.SettingsChanged(true); break;
            default: owner.Dispose(); break;
        }
        await test.Generation.Cleanup;
        Assert.False(test.Generation.CanExecute); Assert.Null(test.Generation.Quote); Assert.Empty(test.Generation.Rows);
        await test.GenerateAsync(); Assert.Equal(1, test.Runner.PaidRequests);
    }
    [Fact]
    public async Task OwnerInstructionWordsAndSettingsChangesCallTheAutomaticQuotePath()
    {
        using var owner = new RewriteSession(Editor(), 10, 12, Envelope(), null);
        await using var test = new Harness(); owner.ConfigureGeneration(test.Generation); await test.ReadyAsync();
        var count = test.Runner.Preparations;
        await owner.SetInstructionAsync("clearer"); await test.Generation.PendingUpdate;
        owner.Edit("better words"); await test.Generation.PendingUpdate;
        owner.SettingsChanged(true); await test.Generation.PendingUpdate;
        Assert.Equal(count + 3, test.Runner.Preparations); Assert.Equal(0, test.Runner.PaidRequests);
    }
    [Fact]
    public void VoiceLabelNamesTheVoiceAndItsConsentDate() =>
        Assert.Equal("My voice · consent Oct 12", RewriteGenerationBackend.VoiceLabel("My voice", new(2026, 10, 12, 0, 0, 0, TimeSpan.Zero)));
#endif
    /// <summary>The take run's input comes from the one reviewed hunk, and the source reader gets what the run reads around: the
    /// window, its two lendable silences, each in its place, and the transcript, on the whole track. Not DEBUG-only: CI runs these
    /// tests in Release.</summary>
    [Fact]
    public async Task InputBindingUsesOneReviewedHunkBridgesSourceClockAndSelectedVoiceModel()
    {
        // A longer pause after the passage than before it, so the two silences differ and a swap shows.
        using var owner = new RewriteSession(Editor(pauseAfterWord12: 1.5), 10, 12, Envelope(), null);
        owner.Edit("much clearer words");
        var hunk = Assert.Single(owner.Review!.VoiceHunks);
        RewriteSourceRequest? request = null;
        var read = (VoiceLabSourceExcerpt.Whole(new float[] { 0.1f, 0.2f }), VoiceLabTakeProcessing.Envelope([0.1f, 0.2f], 48_000));
        var input = await owner.GenerationInputAsync("voice", "model", 42, true, (value, _) => { request = value; return Task.FromResult(read); }, CancellationToken.None);
        Assert.NotNull(input); Assert.Equal(hunk.PatchText, input.Text); Assert.Equal(hunk.Window, input.Window);
        Assert.NotNull(request); Assert.Equal(4_800_000, request.Frames); Assert.Equal(48_000, request.SampleRate); Assert.Equal(hunk.Window, request.Window);
        // Both seams sit in pauses, of 0.6 s before the passage and 2.1 s after it, so each lends a different silence (§8.9.2).
        Assert.Equal(0.295, request.IncomingSilence!.Value, 9); Assert.Equal(1.055, request.OutgoingSilence!.Value, 9);
        Assert.Equal((request.IncomingSilence, request.OutgoingSilence), (input.IncomingSilence, input.OutgoingSilence)); Assert.Same(owner.Transcript, request.Items);
        Assert.Same(read.Item1, input.Source); Assert.Same(read.Item2, input.SourceEnvelope);
        Assert.Equal("voice", input.RecordId); Assert.Equal("model", input.ModelId); Assert.Equal(42u, input.Seed);
        Assert.Equal(48_000, input.SourceSampleRate); Assert.Equal(owner.Transcript, input.Items); Assert.False(input.CleanAudioOn); Assert.True(input.ProviderConsent);
        using var multiple = new RewriteSession(Editor(), 10, 18, Envelope(), null);
        multiple.Edit("Sunday word11 word12 word13 word14 word15 word16 word17 five");
        Assert.Equal(2, multiple.Review!.VoiceHunks.Count);
        var error = await Assert.ThrowsAsync<RewriteGenerationException>(() => multiple.GenerationInputAsync("voice", "model", 1, true,
            (_, _) => throw new InvalidOperationException("Must refuse before decoding."), CancellationToken.None));
        Assert.Equal("Rewrite one passage at a time. Keep one changed passage, then generate takes.", error.Message);
    }
    private static EditorViewModel Editor(double pauseAfterWord12 = 0)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
        double Later(int index) => index > 12 ? pauseAfterWord12 : 0;
        var words = Enumerable.Range(0, 80).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word, index + 1 + Later(index), index + 1.4 + Later(index), null, null, 1, null, TimingSource.Native)).ToArray();
        return new(project with { Transcript = project.Transcript! with { Words = words }, Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48_000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } });
    }
    private static AudioEnvelope Envelope() => new(48_000, 0.01, Enumerable.Repeat(0.01f, 10_000).ToArray());
}
#endif

#if WIN_UI_TESTS
using System.Reflection;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class RewritePaceMatchingTests
{
    [Fact]
    public void SentenceReplacementKeepsSelectedTextOnlyCorrectionsWithoutDuplicatingReviewHunks()
    {
        using var session = SentenceSession(5);
        session.Edit(session.NewWords.Replace("sample000", "Sample000", StringComparison.Ordinal));
        var target = Assert.Single(session.Review!.VoiceHunks);
        Assert.True(session.ReviewSurroundingSentence(target.Ordinals[0]), session.SentenceProblem);
        var reviewed = session.SentenceReview!;
        Assert.StartsWith("Sample000 ", reviewed.Text);
        var words = session.NewWords;
        var changes = session.Review.Diff.Hunks;
        Assert.True(session.AcceptSurroundingSentence(reviewed));
        Assert.Equal(words, session.NewWords);
        Assert.Equal(System.Text.Json.JsonSerializer.Serialize(changes), System.Text.Json.JsonSerializer.Serialize(session.Review!.Diff.Hunks));
        Assert.Equal(reviewed.Text, Assert.Single(session.Review.VoiceHunks).PatchText);
        Assert.False(session.Editor.CanUndo);
    }

    [Fact]
    public async Task ModelChangesInvalidateAReviewedSentenceWithoutAcceptingItsExpansion()
    {
        using var session = SentenceSession(5);
        Configure(session);
        await session.DiscoverWindowsAsync();
        Assert.True(session.ReviewSurroundingSentence(1), session.SentenceProblem);
        var captured = session.SentenceReview!;
        await session.ChooseModelForWindowsAsync("eleven_v4");
        Assert.False(session.AcceptSurroundingSentence(captured));
        Assert.Equal(RewriteSession.SentenceStale, session.SentenceProblem);
        Assert.NotEqual(captured.Text, Assert.Single(session.Review!.VoiceHunks).PatchText);
        Assert.False(session.Editor.CanUndo);
    }

    [Fact]
    public async Task CompleteSentenceIsReviewedInlineAndNeedsAFreshSeparateQuote()
    {
        using var session = SentenceSession(5);
        Configure(session);
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        var oldQuote = generation.Quote!;
        var before = ProjectSerialization.Serialize(session.Editor.Project);
        Assert.True(session.ReviewSurroundingSentence(1), session.SentenceProblem);
        var reviewed = session.SentenceReview!;
        Assert.Equal("w0", reviewed.Window.FirstWordId);
        Assert.Equal("w15", reviewed.Window.LastWordId);
        Assert.Equal(16, reviewed.Hunk.SourceWordIds.Count);
        Assert.Contains("x", reviewed.Text);
        Assert.True(session.AcceptSurroundingSentence(reviewed), session.SentenceProblem);
        Assert.Null(session.SentenceReview);
        Assert.NotSame(generation, session.Generation);
        Assert.Equal(before, ProjectSerialization.Serialize(session.Editor.Project));
        Assert.False(session.Editor.CanUndo);
        await session.DiscoverWindowsAsync();
        var fresh = session.Generation!;
        Assert.NotSame(oldQuote, fresh.Quote);
        Assert.Equal(reviewed.Text, Assert.Single(session.PricedVoiceHunks).PatchText);
        Assert.False(fresh.CanExecute);
        fresh.MarkEstimateShown(fresh.Quote!);
        Assert.True(fresh.CanExecute);
        Assert.Contains("Phrase 1 at ", session.TakeSendLine);
        await generation.GenerateAsync((_, _) => throw new InvalidOperationException("Stale approval must not be shown."), oldQuote, autoplay: false);
        Assert.Empty(generation.Rows);
        Assert.Empty(fresh.Rows);
    }

    [Fact]
    public void SentenceReviewRejectsStaleApprovalAndCanBeCancelledWithoutChangingThePhrase()
    {
        using var session = SentenceSession(5);
        Assert.True(session.ReviewSurroundingSentence(1), session.SentenceProblem);
        var original = session.NewWords;
        session.CancelSurroundingSentence();
        Assert.Null(session.SentenceReview);
        Assert.Equal(original, session.NewWords);
        Assert.True(session.ReviewSurroundingSentence(1));
        var captured = session.SentenceReview!;
        session.Edit(original.Replace("x", "changed", StringComparison.Ordinal));
        var current = session.NewWords;
        Assert.False(session.AcceptSurroundingSentence(captured));
        Assert.Equal(RewriteSession.SentenceStale, session.SentenceProblem);
        Assert.Equal(current, session.NewWords);
    }

    [Fact]
    public void SentenceExpansionRefusesExcludedChangesOtherSelectedChangesAndNarrowScopes()
    {
        using var session = SentenceSession(2, 12);
        Assert.Equal(2, session.Review!.Diff.Hunks.Count);
        Assert.False(session.ReviewSurroundingSentence(1));
        Assert.Equal(RewriteSession.SentenceOverlap, session.SentenceProblem);
        Assert.True(session.SetChangeIncluded(2, false));
        Assert.False(session.ReviewSurroundingSentence(1));
        Assert.Equal(RewriteSession.SentenceUnavailable, session.SentenceProblem);
        using var narrow = new RewriteSession(session.Editor, 2, 2, session.Envelope, null);
        narrow.Edit("x");
        Assert.False(narrow.ReviewSurroundingSentence(1));
        Assert.Equal(RewriteSession.SentenceUnavailable, narrow.SentenceProblem);
        Assert.False(session.Editor.CanUndo);
    }

    [Fact]
    public async Task SentenceExpansionPreservesTheOtherPhrasesPaidTakeAndModelChangesKeepThePaidInclusionSet()
    {
        using var session = SentenceSession(5, 37);
        Configure(session);
        await session.DiscoverWindowsAsync();
        Assert.Equal(2, session.GenerationWindows.Count);
        var other = session.GenerationWindows[1];
        other.MarkEstimateShown(other.Quote!);
        await other.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        var paid = other.Selected;
        Assert.NotNull(paid);
        Assert.True(session.ReviewSurroundingSentence(1), session.SentenceProblem);
        Assert.True(session.AcceptSurroundingSentence(session.SentenceReview!), session.SentenceProblem);
        Assert.Same(other, session.GenerationWindows[1]);
        Assert.Same(paid, other.Selected);
        Assert.True(other.ReviewedInputsCurrent);
        await session.DiscoverWindowsAsync();
        var included = session.PricedVoiceHunks.ToArray();
        await session.ChooseModelForWindowsAsync("eleven_v4");
        Assert.Equal(included, session.PricedVoiceHunks);
        Assert.Same(paid, other.Selected);
        Assert.Equal(1, other.NextPace);
        Assert.NotEqual(1, paid.Receipt!.Pace);
    }

    [Fact]
    public async Task PrepayTimingTracksTheSelectedModelWithoutSending()
    {
        using var session = SentenceSession(5);
        Configure(session);
        await session.DiscoverWindowsAsync();
        var timing = Assert.Single(session.Review!.VoiceHunks).Fit!;
        Assert.NotEqual(1, timing.Pace);
        Assert.Contains("× pace", timing.Copy);
        await session.ChooseModelForWindowsAsync("eleven_v4");
        var dialogue = Assert.Single(session.Review.VoiceHunks).Fit!;
        Assert.Equal(1, dialogue.Pace);
        Assert.DoesNotContain("pace", dialogue.Copy);
        await session.ChooseModelForWindowsAsync("eleven_multilingual_v2");
        Assert.Equal(timing, Assert.Single(session.Review.VoiceHunks).Fit);
        Assert.All(session.GenerationWindows, generation => Assert.Empty(generation.Rows));
    }

    private static RewriteSession SentenceSession(params int[] changes)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures/projects/interview-take.voxclip")));
        double Start(int index) => index < 48 ? 1 + index * .45 : 22.6 + (index - 48) * .85;
        var words = Enumerable.Range(0, 200).Select(index => new TimedWord("w" + index, "sample" + index.ToString("D3") + (index % 16 == 15 ? "." : ""),
            WordKind.Word, Start(index), Start(index) + (index < 48 ? .4 : .8), null, null, 1, null, TimingSource.Native)).ToArray();
        var editor = new EditorViewModel(project with { SchemaVersion = 1, VoiceLab = new([]),
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 160, Audio = new(48_000, 1) } },
            Transcript = project.Transcript! with { Words = words }, Edits = project.Edits with
                { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() } });
        var session = new RewriteSession(editor, 0, 199, new(48_000, .01, Enumerable.Repeat(.01f, 16_000).ToArray()), null,
            synthesisModel: "eleven_multilingual_v2");
        session.Edit(string.Join(" ", words.Select((word, index) => changes.Contains(index) ? "x" : word.Text)));
        return session;
    }

    private static void Configure(RewriteSession session)
    {
        foreach (var hunk in session.BlockedVoiceHunks.ToArray()) Assert.True(session.PriceItAnyway(hunk.Ordinals[0]));
        session.ConfigureGenerationFactory(index => new(new Runner(),
        _ => Task.FromResult(new RewriteGenerationChoices([new("record", "My voice")],
            [new("eleven_multilingual_v2", "Multilingual v2", ["en"], true, false, 5000, 1),
             new("eleven_v4", "Dialogue", ["en"], true, false, 5000, 1)])),
        (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed, true,
            (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), ct, index),
        _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent));
    }

    [Fact]
    public void ShortFitRecoveryUsesAnInlineSentenceReviewInsteadOfAskingAgain()
    {
        var root = Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App");
        foreach (var file in new[] { "Controls/RewritePanel.Review.cs", "Controls/RewritePanel.Takes.cs" })
        {
            var source = File.ReadAllText(Path.Combine(root, file));
            Assert.Contains("Use surrounding sentence", source);
            Assert.Contains("ReviewSurroundingSentence", source);
            Assert.DoesNotContain("new ContentDialog", source);
            Assert.DoesNotContain("\"Ask again\"", source);
        }
    }
    private static VoiceLabTakeInput Input(string model = "eleven_multilingual_v2", double pace = 0.7) =>
        new("clearer words", model, "record", "en", 42, "source", new float[48_000], 48_000, [], new HashSet<string>(),
            new("w", "w", [], [], 10, 15.12, 480_000, 725_760,
                new(VoiceLabSeamKind.Hard, 10, 480_000, 240), new(VoiceLabSeamKind.Hard, 15.12, 725_760, 240)), null, null, false, true, pace);

    [Fact]
    public async Task RetryUsesMeasuredTrimmedAudioAndReceiptPaceWithoutCompoundingOrSpendingStaleQuotes()
    {
        var runner = new Runner();
        using var generation = Generation(runner);
        await generation.DiscoverAsync();
        var initial = generation.Quote!;
        generation.MarkEstimateShown(initial);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), initial, autoplay: false);
        var selected = Assert.IsType<VoiceLabTakeRow>(generation.Selected);
        Assert.Equal(0.7, selected.Receipt!.Pace);
        var expected = VoiceLabPaceMatching.Match(selected.Audio!.Trimmed.Length / (double)selected.Audio.SampleRate,
            Input().Window, null, null, 48_000, oldPace: selected.Receipt.Pace!.Value).Pace;
        await generation.InputsChangedAsync(preserveReview: true);
        Assert.Equal(expected, runner.Input!.Pace);
        Assert.NotEqual(0.7, runner.Input.Pace);
        var unused = generation.Quote!;
        await generation.InputsChangedAsync(preserveReview: true);
        Assert.Equal(expected, runner.Input.Pace);
        Assert.NotSame(unused, generation.Quote);
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), unused, autoplay: false);
        Assert.Equal(1, runner.Sends);
        Assert.Same(selected, generation.Selected);
        Assert.Equal(expected, generation.NextPace);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), generation.Quote, autoplay: false);
        Assert.Equal(2, runner.Sends);
        Assert.Equal(expected, generation.Selected!.Receipt!.Pace);
    }

    [Fact]
    public async Task ChangingModelKeepsPaidReviewAndDialogueQuotesUseDefaultPace()
    {
        var runner = new Runner();
        using var generation = Generation(runner);
        await generation.DiscoverAsync();
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        var row = generation.Selected;
        var input = generation.ReviewedInput;
        await generation.ChooseModelAsync("eleven_v4");
        Assert.True(generation.ReviewedInputsCurrent);
        Assert.Same(row, generation.Selected);
        Assert.Same(input, generation.ReviewedInput);
        Assert.Equal(1, runner.Input!.Pace);
        Assert.Equal(0.7, row!.Receipt!.Pace);
        Assert.Equal("eleven_multilingual_v2", row.Receipt.ModelId);
        Assert.Equal(1, runner.Sends);
    }

    private static RewriteGeneration Generation(Runner runner) => new(runner,
        _ => Task.FromResult(new RewriteGenerationChoices([new("record", "My voice")],
            [new("eleven_multilingual_v2", "Multilingual v2", ["en"], true, false, 5000, 1),
             new("eleven_v4", "Dialogue", ["en"], true, false, 5000, 1)])),
        (_, model, _, _) => Task.FromResult<VoiceLabTakeInput?>(Input(model)), _ => Task.FromResult(true),
        _ => Task.FromResult<decimal?>(null), () => true);

    private sealed class Runner : IVoiceLabTakeRunner
    {
        internal VoiceLabTakeInput? Input;
        internal int Sends;
        private VoiceLabTakeRunQuote? pending;
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
        {
            Input = input;
            VoiceLabPreparedAction Action(VoiceLabOperation operation) => (VoiceLabPreparedAction)typeof(VoiceLabPreparedAction)
                .GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single(constructor => constructor.GetParameters().Length == 5)
                .Invoke([Guid.NewGuid(), "fixture", DateTimeOffset.UtcNow.AddHours(1),
                    new VoiceLabEstimate("elevenlabs", operation, 1, "fixture", .01m, null, "fixture"),
                    new VoiceLabReview(operation, Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, "fixture", input.ModelId,
                        "voice", null, null, input.RecordId, Pace: input.Pace)]);
            pending = new(Guid.NewGuid(), Enumerable.Range(0, 3).Select(index => new VoiceLabTakeQuote(index, (uint)index,
                Action(VoiceLabOperation.TextToSpeech), Action(VoiceLabOperation.SpeechToText))).ToArray());
            return Task.FromResult(pending);
        }
        public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default) => throw new InvalidOperationException();
        public async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
        {
            await dispatch.AuthorizeAsync(quote.Takes[0].Synthesis.Review.RequestId, ct);
            await dispatch.Start(() => Task.FromResult(true), ct);
            Sends++;
            var input = Input!;
            if (progress is not null) await progress([]);
            var trimmed = new float[278_400];
            var fit = VoiceLabRewriteFit.Hypothetical(input.Window, input.IncomingSilence, input.OutgoingSilence, 5.8, 48_000);
            var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", input.ModelId, "voice",
                quote.Takes[0].Synthesis.Review.RequestId, null, null, input.Pace);
            var row = new VoiceLabTakeRow(receipt.ActionId, 0, 42, receipt, Quote: quote.Takes[0],
                Audio: new(48_000, trimmed, [], 0, trimmed.Length, [], 0, null, fit), Qa: new(1, 0, -3, .8, []), Score: 1);
            if (progress is not null) await progress([row]);
            return new([row], VoiceLabTakeRunEnd.Completed);
        }
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => ReferenceEquals(quote, pending);
        public Task DiscardPendingAsync() { pending = null; return Task.CompletedTask; }
        public void InvalidatePreparation() => pending = null;
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => Task.FromResult(cap);
    }
}
#endif

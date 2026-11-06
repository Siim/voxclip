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
    public async Task PaidShorterFeedbackUsesMeasuredOutputAndWaitsForDiscardConfirmation()
    {
        using var session = SentenceSession(5, 7);
        Configure(session);
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        var paid = generation.Selected!;
        var feedback = Assert.Single(session.ShorterFeedback(1));
        Assert.Equal(paid.Audio!.Fit.Plan.OutputFrames / (double)paid.Audio.SampleRate, feedback.MeasuredSeconds);
        Assert.Equal(session.Review!.VoiceHunks[0].Fit!.EstimateSeconds, feedback.EstimateSeconds);
        Assert.Equal(session.Review.VoiceHunks[0].PatchText, feedback.Proposed);
        Assert.Contains("sample005", feedback.Original);
        Assert.Contains("sample007", feedback.Original);
        Assert.Equal("x sample006 x", feedback.Proposed);
        Assert.False(await session.PrepareShorterAsync(1));
        Assert.True(session.PendingPaidReviewChange!.Shorter);
        session.CancelPaidReviewChange();
        Assert.Same(paid, generation.Selected);
        Assert.True(generation.ReviewedInputsCurrent);
    }

    [Fact]
    public async Task PaidKeepOriginalDiscardsAllRequestedOrdinalsOnlyAfterConfirmation()
    {
        using var session = SentenceSession(5, 37);
        Configure(session);
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        var ordinals = session.Review!.Diff.Hunks.Select((_, index) => index + 1).ToArray();
        Assert.Equal(2, ordinals.Length);
        Assert.False(session.SetChangesIncluded(ordinals, false));
        Assert.Empty(session.ChangeStates);
        Assert.True(await session.ConfirmPaidReviewChangeAsync(session.PendingPaidReviewChange!));
        Assert.All(ordinals, ordinal => Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[ordinal]));
        Assert.False(session.HasPaidTakes);
    }

    [Fact]
    public async Task SentenceRequoteRecomputesPaceForTheCurrentInputModel()
    {
        using var session = SentenceSession(5);
        Configure(session);
        await session.DiscoverWindowsAsync();
        Assert.True(session.ReviewSurroundingSentence(1));
        Assert.True(session.AcceptSurroundingSentence(session.SentenceReview!));
        await session.DiscoverWindowsAsync();
        async Task<VoiceLabTakeInput> InputFor(string model) => (await session.GenerationInputAsync("record", model, 1, true,
            (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), CancellationToken.None))!;
        var dialogue = await InputFor("eleven_v4");
        var paced = await InputFor("eleven_multilingual_v2");
        Assert.Equal(1, dialogue.Pace);
        Assert.Equal(1, paced.Pace);
        Assert.Equal(VoiceLabPaceMatching.Measure(paced.Text, VoiceLabRewriteFit.SpeakingRate(session.Transcript), paced.Window,
            paced.IncomingSilence, paced.OutgoingSilence, paced.SourceSampleRate, hardJoinSmoothing: true,
            sourceItems: session.Transcript, sourceEnvelope: session.Envelope).Pace, paced.Pace);
    }

    [Fact]
    public async Task QuotedNextPaceIsExactlyThePaceShownInTheSendDisclosure()
    {
        var runner = new Runner();
        using var generation = Generation(runner);
        await generation.DiscoverAsync();
        Assert.Equal(generation.Quote!.Takes[0].Synthesis.Review.Pace, generation.NextPace);
        generation.MarkEstimateShown(generation.Quote);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        Assert.Equal(generation.Quote!.Takes[0].Synthesis.Review.Pace, generation.NextPace);
        Assert.Equal(runner.Input!.Pace, generation.NextPace);
    }

    [Fact]
    public async Task NextPaceIsHiddenUntilTheNewQuoteIsHeld()
    {
        var runner = new Runner();
        using var generation = Generation(runner);
        await generation.DiscoverAsync();
        runner.HoldPreparation = new(TaskCreationOptions.RunContinuationsAsynchronously);
        runner.PreparationStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var preparing = generation.InputsChangedAsync(preserveReview: true);
        await runner.PreparationStarted.Task;
        Assert.Null(generation.Quote);
        Assert.Null(generation.NextPace);
        runner.HoldPreparation.SetResult();
        await preparing;
        Assert.Equal(generation.Quote!.Takes[0].Synthesis.Review.Pace, generation.NextPace);
    }

    [Fact]
    public void FittingRowsSpeakTheirTimingAndInlineEditsUseTheSelectedModelsFit()
    {
        using var session = SentenceSession(5);
        var hunk = Assert.Single(session.Review!.VoiceHunks);
        var fitting = hunk with { Fit = new(4, 6, true, .85) };
        Assert.Equal(fitting.Fit.Copy, fitting.SpokenTiming);
        Assert.Contains("fits", fitting.SpokenTiming);
        Assert.Contains("at 0.85× pace", fitting.SpokenTiming);
        var root = Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App");
        var rows = File.ReadAllText(Path.Combine(root, "Controls/RewritePanel.Review.cs"));
        Assert.Contains("voiceHunk?.SpokenTiming", rows);
        Assert.Contains("SetName(row,", rows);
        Assert.Contains("Discard takes and continue", rows);
        Assert.DoesNotContain("new ContentDialog", rows);
        var editor = File.ReadAllText(Path.Combine(root, "Controls/TranscriptView.InlineEditing.cs"));
        Assert.Contains("review.Ordinals.Contains(hunk.Ordinal))?.Fit", editor);
        Assert.Contains("timing.Copy", editor);
    }

    [Theory]
    [InlineData("exclude")]
    [InlineData("include")]
    [InlineData("price")]
    [InlineData("edit")]
    [InlineData("outside")]
    [InlineData("add-tag")]
    [InlineData("remove-tag")]
    public async Task PaidReviewChangesWaitForDiscardApproval(string action)
    {
        using var session = SentenceSession(53, 85);
        if (action == "remove-tag") Assert.True(session.AddExpression(1, "laughs"));
        if (action == "outside") Assert.True(session.SetChangeIncluded(1, false));
        Configure(session);
        await session.DiscoverWindowsAsync();
        var generation = session.GenerationWindows[^1];
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        var paid = Assert.Single(generation.Rows);
        var identity = session.ReviewIdentity;
        var review = session.Review;
        var changed = action switch
        {
            "exclude" => session.SetChangeIncluded(1, false),
            "include" => session.SetChangeIncluded(1, true),
            "outside" => session.SetChangeIncluded(1, true),
            "price" => session.PriceItAnyway(1),
            "add-tag" => session.AddExpression(1, "laughs"),
            "remove-tag" => session.RemoveExpression(1, 0),
            _ => session.EditChange(1, "different")
        };
        if (action is "add-tag" or "remove-tag")
        {
            // An expression changes only its own phrase (design.md R2 "Expressions"): no discard prompt, the paid take stays
            // listed as "Before expression" and a fresh quote is prepared for that phrase.
            Assert.True(changed);
            Assert.Null(session.PendingPaidReviewChange);
            Assert.Same(paid, Assert.Single(generation.Rows));
            // Only the phrase that holds change 1 marks its takes; another phrase's paid take is untouched.
            var owner = session.PricedVoiceHunks.ToList().FindIndex(hunk => hunk.Ordinals.Contains(1));
            Assert.Equal(ReferenceEquals(session.GenerationWindows.ElementAtOrDefault(owner), generation), generation.IsBeforeExpression(paid.Id));
            Assert.Equal(action == "add-tag" ? 1 : 0, session.Review!.Diff.Hunks[0].AudioTags.Count);
            Assert.True(session.HasPaidTakes);
            return;
        }
        Assert.False(changed);
        Assert.Same(review, session.Review);
        Assert.Equal(identity, session.ReviewIdentity);
        Assert.Same(paid, Assert.Single(generation.Rows));
        Assert.Contains(generation, session.GenerationWindows);
        Assert.NotNull(session.PendingPaidReviewChange);
        session.CancelPaidReviewChange();
        Assert.Null(session.PendingPaidReviewChange);
        Assert.Same(review, session.Review);
        Assert.Equal(identity, session.ReviewIdentity);
        Assert.Same(paid, Assert.Single(generation.Rows));
        Assert.False(session.SetChangeIncluded(1, false));
        var pending = session.PendingPaidReviewChange!;
        Assert.True(await session.ConfirmPaidReviewChangeAsync(pending));
        Assert.False(await session.ConfirmPaidReviewChangeAsync(pending));
        Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[1]);
        Assert.False(session.HasPaidTakes);
    }

    [Fact]
    public async Task ExpressionMutationRetiresTheUnpaidQuoteAndRequotesWithoutSynthesis()
    {
        using var session = SentenceSession(53);
        Configure(session);
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        var previous = generation.Quote;
        Assert.NotNull(previous);
        var before = Assert.Single(session.Review!.VoiceHunks);
        var words = session.NewWords;
        Assert.True(session.AddExpression(1, "laughs"));
        await generation.PendingUpdate;
        Assert.Same(generation, session.Generation);
        Assert.NotSame(previous, generation.Quote);
        Assert.Empty(generation.Rows);
        Assert.Equal(words, session.NewWords);
        var phrase = Assert.Single(session.Review!.VoiceHunks);
        Assert.Equal(.8, phrase.Fit!.EstimateSeconds - before.Fit!.EstimateSeconds, 9);
        Assert.Contains("≈", phrase.SpokenTiming);
        var input = await session.GenerationInputAsync("record", "eleven_v4", 42, true,
            (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), CancellationToken.None);
        Assert.NotNull(input);
        Assert.Contains("[laughs]", input.RequestText);
        var tag = Assert.Single(phrase.Hunk.AudioTags);
        // The default place is before the first changed word (design.md R2 "Expressions").
        Assert.Equal(0, tag.BeforeToken);
        Assert.True(session.RemoveExpression(1, 0));
        await generation.PendingUpdate;
        Assert.Empty(session.Review!.Diff.Hunks[0].AudioTags);
        Assert.Empty(generation.Rows);
    }

    [Fact]
    public async Task PaidReviewTimingStaysOnElevenV4WhateverTheAccountOffers()
    {
        using var session = SentenceSession(5);
        Configure(session);
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        var paid = Assert.Single(generation.Rows);
        Assert.Equal("eleven_v4", paid.Receipt!.ModelId);
        Assert.Equal(1, Assert.Single(session.Review!.VoiceHunks).Fit!.Pace);
        Assert.Same(paid, Assert.Single(session.Generation!.Rows));
        await generation.ChooseModelAsync("eleven_multilingual_v2");
        Assert.Equal("eleven_v4", generation.ModelId);
        Assert.Equal(1, Assert.Single(session.Review.VoiceHunks).Fit!.Pace);
        Assert.Same(paid, Assert.Single(session.Generation.Rows));
    }

    [Fact]
    public async Task FailedOrCancelledSentenceRecoveryDoesNotRedirectPricing()
    {
        using var session = SentenceSession(2, 12);
        Configure(session);
        await session.DiscoverWindowsAsync();
        Assert.False(session.ReviewSurroundingSentence(1));
        Assert.Null(session.SentenceReview);
        Assert.NotEmpty(session.SentenceProblem);
        await session.Generation!.InputsChangedAsync();
        Assert.NotNull(session.Generation.Quote);
        session.CancelSurroundingSentence();
        await session.Generation.InputsChangedAsync();
        Assert.NotNull(session.Generation.Quote);
    }

    [Fact]
    public async Task PriceOverrideAbandonsSentenceReviewWithoutRedirectingTheNextQuote()
    {
        using var session = SentenceSession(53);
        Configure(session);
        await session.DiscoverWindowsAsync();
        Assert.True(session.ReviewSurroundingSentence(1));
        var captured = session.SentenceReview!;
        Assert.True(session.PriceItAnyway(1));
        Assert.Null(session.SentenceReview);
        Assert.False(session.AcceptSurroundingSentence(captured));
        await session.Generation!.InputsChangedAsync();
        Assert.NotNull(session.Generation.Quote);
        Assert.Equal("x", Assert.Single(session.PricedVoiceHunks).PatchText);
    }

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
        Assert.DoesNotContain("Phrase 1 at ", session.TakeSendLine);
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
        Assert.Equal(included.SelectMany(hunk => hunk.Ordinals), session.PricedVoiceHunks.SelectMany(hunk => hunk.Ordinals));
        Assert.All(session.Review!.VoiceHunks, hunk => Assert.Equal(1, hunk.Fit!.Pace));
        Assert.Same(paid, other.Selected);
        Assert.Equal(1, other.NextPace);
        Assert.Equal(1, paid.Receipt!.Pace);
    }

    [Fact]
    public async Task PrepayTimingIsAlwaysElevenV4AndTheModelCannotBeChanged()
    {
        using var session = SentenceSession(5);
        Configure(session);
        await session.DiscoverWindowsAsync();
        var timing = Assert.Single(session.Review!.VoiceHunks).Fit!;
        Assert.Equal(1, timing.Pace);
        Assert.DoesNotContain("pace", timing.Copy);
        Assert.All(session.GenerationWindows, generation => Assert.Equal("eleven_v4", generation.ModelId));
        await session.Generation!.ChooseModelAsync("eleven_multilingual_v2");
        Assert.All(session.GenerationWindows, generation => Assert.Equal("eleven_v4", generation.ModelId));
        Assert.Equal(timing, Assert.Single(session.Review.VoiceHunks).Fit);
        Assert.All(session.GenerationWindows, generation => Assert.Empty(generation.Rows));
    }

    private static RewriteSession SentenceSession(params int[] changes)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures/projects/interview-take.voxclip")));
        // Every take carries the provider's onset (ADR-R43): a one-letter change is too short only for a word over a second long.
        double Start(int index) => index < 48 ? 1 + index * 1.25 : 61.05 + (index - 48) * 1.3;
        var words = Enumerable.Range(0, 200).Select(index => new TimedWord("w" + index, "sample" + index.ToString("D3") + (index % 16 == 15 ? "." : ""),
            WordKind.Word, Start(index), Start(index) + (index < 48 ? 1.2 : 1.25), null, null, 1, null, TimingSource.Native)).ToArray();
        var editor = new EditorViewModel(project with { SchemaVersion = 1, VoiceLab = new([]),
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 270, Audio = new(48_000, 1) } },
            Transcript = project.Transcript! with { Words = words }, Edits = project.Edits with
                { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() } });
        var session = new RewriteSession(editor, 0, 199, new(48_000, .01, Enumerable.Repeat(.01f, 27_000).ToArray()), null);
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
            Input().Window, null, null, 48_000, oldPace: selected.Receipt.Pace!.Value, hardJoinSmoothing: true).Pace;
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
        internal TaskCompletionSource? HoldPreparation;
        internal TaskCompletionSource? PreparationStarted;
        private VoiceLabTakeRunQuote? pending;
        public async Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
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
            if (HoldPreparation is { } gate)
            {
                PreparationStarted?.TrySetResult();
                await gate.Task.WaitAsync(ct);
            }
            return pending;
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
            var fit = VoiceLabRewriteFit.Hypothetical(input.Window, input.IncomingSilence, input.OutgoingSilence, 5.8, 48_000, hardJoinSmoothing: false);
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

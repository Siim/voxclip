#if WIN_UI_TESTS
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class RewritePanelTests
{
    private static string Shared => Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
    private static EditorViewModel Editor(params TimedWord[] words)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "projects", "interview-take.voxclip")));
        if (words.Length == 0) words = Enumerable.Range(0, 80).Select(index => Word(index, "word" + index)).ToArray();
        project = project with { Transcript = project.Transcript! with { Words = words },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } };
        return new(project);
    }
    private static TimedWord Word(int index, string text, WordKind kind = WordKind.Word) =>
        new("w" + index, text, kind, index + 1, index + 1.4, null, null, 1, null, TimingSource.Native);
    private static AudioEnvelope Envelope() => new(48000, 0.01, Enumerable.Repeat(0.01f, 10000).ToArray());

    [Fact]
    public void LiveReviewUsesCoreMetersAndCompletePatchPricingForEachHunk()
    {
        var prices = VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(Shared, "catalog", "voice-lab.json")));
        using var session = new RewriteSession(Editor(), 10, 18, Envelope(), null, prices: prices, synthesisModel: "eleven_multilingual_v2");
        session.Edit("Sunday word11 word12 word13 word14 word15 word16 word17 five");
        var review = Assert.IsType<RewriteReview>(session.Review);
        Assert.Equal(2, review.VoiceHunks.Count);
        foreach (var hunk in review.VoiceHunks)
        {
            var window = Assert.IsType<VoiceLabWindow>(hunk.Window);
            var silence = VoiceLabWindowPlanner.LendableSilence(session.Project, session.Scope, window);
            var expected = VoiceLabFitMeter.Measure(hunk.PatchText!, window, silence.Incoming, silence.Outgoing,
                VoiceLabLengthBudget.Rate(session.Transcript).CharactersPerSecond, string.Join(" ", hunk.Hunk.NewTokens), true);
            Assert.Equal(expected, hunk.Meter);
            Assert.StartsWith("“" + string.Join(" ", hunk.Hunk.NewTokens) + "” · about ", hunk.Meter!.Copy);
        }
        var summary = VoiceLabDiffSummary.Make(review.Diff, review.VoiceHunks.Select(hunk => hunk.Meter!).ToArray(), prices,
            "eleven_multilingual_v2", patchTexts: review.VoiceHunks.Select(hunk => hunk.PatchText).ToArray());
        Assert.Equal(summary, review.Summary);
        Assert.NotNull(review.Summary!.CostEstimate!.Usd);
        session.Edit("Sunday word11 word12 word13 word14 word15 word16 word17 word18");
        Assert.Single(session.Review!.VoiceHunks);
        Assert.StartsWith("about ", session.Review.VoiceHunks[0].Meter!.Copy);
    }

    [Fact]
    public void MissingWindowsAndUnknownModelNeverInventAHeaderPrice()
    {
        var prices = VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(Shared, "catalog", "voice-lab.json")));
        using var unavailable = new RewriteSession(Editor(), 10, 12, null, null, prices: prices, synthesisModel: "eleven_multilingual_v2");
        unavailable.Edit("Sunday word11 word12");
        Assert.Null(unavailable.Review!.Summary);
        Assert.All(unavailable.Review.VoiceHunks, hunk => { Assert.Null(hunk.Window); Assert.Null(hunk.PatchText); Assert.NotNull(hunk.Refusal); });
        using var unknown = new RewriteSession(Editor(), 10, 12, Envelope(), null, prices: prices, synthesisModel: "unknown-model");
        unknown.Edit("Sunday word11 word12");
        Assert.Null(unknown.Review!.Summary!.CostEstimate!.Usd);
        Assert.DoesNotContain("$", unknown.Review.Summary.Copy);
        Assert.Equal("This change is too close to the end of the take to blend in. Re-record this sentence instead.",
            RewriteSession.Refusal(new VoiceLabGeometryException(VoiceLabGeometryErrorCode.SeamFadeOutsideTake, incoming: false)));
    }

    [Fact]
    public void DiffLineIncludesAbsorbedLabelsBridgesAndTheSpokenDescription()
    {
        var words = Enumerable.Range(0, 80).Select(index => Word(index, "word" + index)).ToArray();
        words[10] = Word(10, "one"); words[18] = Word(18, "seven");
        using var session = new RewriteSession(Editor(words), 10, 18, Envelope(), null);
        session.Edit("on Sunday word11 word12 word13 word14 word15 word16 word17 five");
        Assert.Equal("one becomes on Sunday, seven becomes five", session.Review!.AccessibleDescription);
        Assert.Contains(session.Review.Runs, run => run.Text == "one" && run.Kind == RewriteDiffKind.Removed);
        Assert.Contains(session.Review.Runs, run => run.Text == "Sunday" && run.Kind == RewriteDiffKind.Inserted);
        session.Edit("on Sunday word11 word12 five word14 word15 word16 word17 seven");
        Assert.Contains(session.Review!.Runs, run => run.SourceId == "w11" && run.Kind == RewriteDiffKind.Bridge);
        words[11] = Word(11, "[laughter]", WordKind.Event);
        words[12] = Word(12, "[unlabeled speech]", WordKind.UnlabeledSpeech);
        using var absorbed = new RewriteSession(Editor(words), 10, 13, Envelope(), null);
        absorbed.Edit("Sunday");
        Assert.Contains(absorbed.Review!.Runs, run => run.Text == "[laughter]" && run.Kind == RewriteDiffKind.Removed);
        Assert.Contains(absorbed.Review.Runs, run => run.Text == "[unlabeled speech]" && run.Kind == RewriteDiffKind.Removed);
        Assert.Contains("[laughter] removed", absorbed.Review.AccessibleDescription);
        Assert.Contains("[unlabeled speech] removed", absorbed.Review.AccessibleDescription);
    }

    [Fact]
    public void PatchBudgetUsesTheWholeTranscriptAndUpdatesWithoutCalls()
    {
        var fake = new RecordingConnector();
        using var session = new RewriteSession(Editor(), 10, 29, Envelope(), new(fake, "chosen", "Test", "local", ""));
        session.Edit(string.Join(" ", Enumerable.Repeat("replacement", 20)));
        Assert.Equal(VoiceLabPatchBudgetFlag.ReRecordInstead, session.Review!.Budget.Flag);
        Assert.Equal(VoiceLabPatchBudget.DisabledCopy, session.Review.Budget.Copy);
        Assert.Equal(VoiceLabPatchBudget.Evaluate(session.Review.Diff, session.Transcript), session.Review.Budget);
        session.Edit("");
        Assert.Equal(VoiceLabPatchBudgetFlag.Allowed, session.Review!.Budget.Flag);
        Assert.Empty(fake.Calls);
    }

    [Fact]
    public async Task PanelProposalIsInertUntilTheDisplayedEstimateIsApproved()
    {
        var editor = Editor();
        var fake = new RecordingConnector();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test connector", "apiKey", ""));
        Assert.Equal(editor.SelectionText, "");
        Assert.Equal("3 words at 0:11.0", session.Header);
        Assert.Equal("word10 word11 word12", session.NewWords);
        await session.SetInstructionAsync("Say it plainly");
        Assert.Equal("", session.Problem);
        var action = Assert.IsType<VoxClip.Core.Domain.VoiceLab.VoiceLabPreparedAction>(session.Prepared);
        Assert.False(session.CanPropose);
        Assert.False(await session.ProposeAsync(action, true));
        Assert.Empty(fake.Calls);
        session.MarkEstimateShown(action);
        Assert.True(session.CanPropose);
        Assert.False(await session.ProposeAsync(action, false));
        Assert.Empty(fake.Calls);
        Assert.True(await session.ProposeAsync(action, true));
        Assert.Equal("Better passage", session.NewWords);
        Assert.Equal(1, fake.Calls.Count(call => call == "send"));
        Assert.Equal("word10", editor.Words[10].Text);
        session.Edit("My own words");
        Assert.Equal("My own words", session.NewWords);
        session.Dispose();
        Assert.False(session.IsOpen);
        Assert.Equal(-1, editor.RewriteStart);
        Assert.False(await session.ProposeAsync(action, true));
    }

    [Fact]
    public async Task ChangedInstructionInvalidatesTheDisplayedAuthorizationWithoutDiscovery()
    {
        var fake = new RecordingConnector();
        using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(fake, "chosen", "Test", "local", ""));
        await session.SetInstructionAsync("First");
        var first = session.Prepared!;
        session.MarkEstimateShown(first);
        await session.SetInstructionAsync("Second");
        Assert.False(await session.ProposeAsync(first, true));
        Assert.Empty(fake.Calls);
        Assert.Equal("Runs on this PC. Nothing leaves it.", session.SendLine);
    }

    private sealed class RecordingConnector : ILlmConnector
    {
        internal List<string> Calls { get; } = [];
        public ConnectorId Id => ConnectorId.OpenAI;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) { Calls.Add("status"); return Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready()); }
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct)
        { Calls.Add("models"); return Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]); }
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) { Calls.Add("context"); return Task.FromResult<int?>(32768); }
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        { Calls.Add("send"); return Task.FromResult(new RawCompletion(null, new JsonObject { ["rewrite"] = "Better passage" }, model, new StopKind.Complete(), null, "fake")); }
    }
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void EveryEntryRespectsTheReleaseGate(int entryIndex)
    {
        var entry = (RewriteEntry)entryIndex;
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(entry, true, true, true, true, false));
        Assert.Equal(entry == RewriteEntry.InsertWords ? RewriteEntryAction.OpenInsertion : RewriteEntryAction.OpenPassage,
            RewriteEntryPolicy.Resolve(entry, true, true, true, true, true));
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(entry, true, false, true, true, true));
    }

    [Fact]
    public void DisabledVoiceLabOnlyOffersTheOneTimeOverflowFlow()
    {
        foreach (var entry in Enum.GetValues<RewriteEntry>())
            Assert.Equal(entry == RewriteEntry.Overflow ? RewriteEntryAction.TurnOnVoiceLab : RewriteEntryAction.Unavailable,
                RewriteEntryPolicy.Resolve(entry, false, true, true, true, true));
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(RewriteEntry.InsertWords, true, true, true, false, true));
#if !DEBUG
        Assert.False(RewriteEntryPolicy.BuildEnabled);
#endif
    }
}
#endif

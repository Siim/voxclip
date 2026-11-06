#if WIN_UI_TESTS
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.LLM;
using Xunit;
#if DEBUG || VOXCLIP_REWRITE_FIXTURE_RUNNER
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;
#endif

namespace VoxClip.Ui.Tests;

public sealed class IntegratedRewriteTests
{
    [Fact]
    public async Task FullTakeProposalStitchesRealScopedHunksPastThePassageTokenLimit()
    {
        var fixture = HomeViewModelTests.Fixture("clip-from-long-take.voxclip");
        var words = Enumerable.Range(0, 2200).Select(index => new TimedWord("w" + index, "word" + index + (index % 20 == 19 ? "." : ""), WordKind.Word,
            index + 1, index + 1.4, null, null, 1, null, TimingSource.Native)).ToArray();
        var editor = new EditorViewModel(fixture with { SchemaVersion = 1, VoiceLab = new([]), Transcript = fixture.Transcript! with { Words = words },
            Media = fixture.Media with { Source = fixture.Media.Source with { DurationSeconds = 2205, Audio = new(48_000, 1) } },
            Edits = fixture.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() } });
        var plan = ScopeRewritePlan.Make(editor.Project, RewriteScope.FullTake, "Fix clarity", "en", null);
        var changedLines = new[] { plan.Lines[1], plan.Lines[^2] };
        var connector = new ScopedConnector(new JsonArray(changedLines.Select((line, index) => (JsonNode)new JsonObject
        {
            ["line"] = line.Label, ["text"] = string.Join(" ", line.Items.Select((word, position) => position == 2 ? "clearer900" + index : word.Text)),
            ["reason"] = "Clear wording"
        }).ToArray()));
        using var session = new RewriteSession(editor, 0, words.Length - 1, null, new(connector, "chosen", "Test", "local", ""), scope: RewriteScope.FullTake);
        var before = ProjectSerialization.Serialize(editor.Project);
        await session.SetInstructionAsync("Fix clarity");
        var quote = Assert.IsType<VoiceLabPreparedAction>(session.Prepared); session.MarkEstimateShown(quote);
        Assert.True(await session.ProposeAsync(quote, true), session.Problem);
        Assert.Equal(1, connector.Sends);
        Assert.Equal(2, session.ScopeHunks!.Count);
        Assert.Equal(2, session.Review!.Diff.Hunks.Count);
        Assert.All(session.ScopeHunks, hunk => { Assert.Equal(["Clear wording"], hunk.Reasons); Assert.True(hunk.CheckThis); });
        Assert.True(session.Review.Diff.Ops.Count > VoiceLabWordDiff.MaximumTokens);
        Assert.Equal(before, ProjectSerialization.Serialize(editor.Project)); Assert.False(editor.CanUndo);
        Assert.True(session.SetChangeIncluded(2, false));
        Assert.True(session.EditChange(1, "plainly"));
        Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[2]);
        Assert.Equal(changedLines[1].Label, Assert.Single(session.ScopeHunks[1].Lines));
        Assert.Equal("plainly", Assert.Single(session.Review!.Diff.Hunks[0].NewTokens));
        Assert.Equal(before, ProjectSerialization.Serialize(editor.Project)); Assert.False(editor.CanUndo);
    }

    private sealed class ScopedConnector(JsonArray edits) : ILlmConnector
    {
        internal int Sends { get; private set; }
        public ConnectorId Id => ConnectorId.OpenAI;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(32768);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested(); Sends++;
            return Task.FromResult(new RawCompletion(null, new JsonObject { ["edits"] = edits.DeepClone() }, model, new StopKind.Complete(), null, "scoped-request"));
        }
    }

    [Fact]
    public void DurableTranscriptionLedgerSurvivesRestartAndDeduplicatesLateRequestEvidence()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-spend-" + Guid.NewGuid().ToString("N"));
        try
        {
            var path = Path.Combine(root, "ledger.json");
            var day = DateOnly.FromDateTime(DateTime.Now);
            var first = Guid.NewGuid(); var duplicate = Guid.NewGuid(); var unfinished = Guid.NewGuid();
            var ledger = new TranscriptionSpendState(); ledger.ConfigurePersistence(path);
            ledger.Begin(first, .14m); ledger.Accepted(first, "actual-request", day, .14m);
            ledger.Begin(duplicate, .14m); ledger.Accepted(duplicate, "", day, .14m);
            ledger.Accepted(duplicate, "actual-request", day, .14m);
            ledger.Begin(unfinished, .21m);
            ledger.Observe(unfinished, day, .21m, new(TranscriptionEvidenceKind.UploadStarted));
            var reopened = new TranscriptionSpendState(); reopened.ConfigurePersistence(path);
            Assert.Equal(1, reopened.UnconfirmedCount);
            Assert.Contains("$0.14 estimated today (local ledger)", reopened.Copy(day));
            Assert.Contains("up to $0.21 billing unconfirmed", reopened.Copy(day));
            Assert.Equal(2, JsonSerializer.Deserialize<TranscriptionSpendState.Entry[]>(File.ReadAllText(path))!.Length);
            reopened.Completed(unfinished, day, .21m, true);
            Assert.Equal(0, reopened.UnconfirmedCount);
            Assert.DoesNotContain("$0.35", reopened.Copy(day));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public void CorruptLedgerFailsClosedWithoutReplacingItsEvidence()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-spend-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "ledger.json");
            File.WriteAllText(path, "invalid ledger");
            var ledger = new TranscriptionSpendState(); ledger.ConfigurePersistence(path);
            Assert.Throws<IOException>(() => ledger.Begin(Guid.NewGuid(), .14m));
            Assert.Equal("invalid ledger", File.ReadAllText(path));
            Assert.Contains("accounting unavailable", ledger.Copy(DateOnly.FromDateTime(DateTime.Now)));
        }
        finally { Directory.Delete(root, true); }
    }

#if DEBUG || VOXCLIP_REWRITE_FIXTURE_RUNNER
    [Theory]
    [InlineData("full")]
    [InlineData("clip")]
    public async Task ScopedMultiWindowAcceptanceUsesOneNamedUndoAndExactProjectRestore(string scope)
    {
        await using var test = new Harness(scope); await test.PrepareAsync();
        Assert.Equal(scope == "clip" ? "Rewrite clip 1" : "Rewrite full take", test.Session.RewriteActionName);
        var before = ProjectSerialization.Serialize(test.Editor.Project);
        await test.Session.GenerateWindowsAsync((_, _, current, _) => Task.FromResult(current()), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.True(await test.Session.ApplyTakeAsync(), test.Editor.Notice);
        Assert.Equal(2, test.Editor.Project.VoiceLab.Segments.Count);
        Assert.All(test.Editor.Project.VoiceLab.Segments, segment => Assert.Equal(VoiceLabSegmentScope.Passage, segment.Scope));
        Assert.Equal(test.Session.Scope.ClipId, test.Editor.Project.Edits.ActiveClipId);
        var after = ProjectSerialization.Serialize(test.Editor.Project);
        test.Editor.Undo(); Assert.Equal(before, ProjectSerialization.Serialize(test.Editor.Project)); Assert.False(test.Editor.CanUndo);
        test.Editor.Redo(); Assert.Equal(after, ProjectSerialization.Serialize(test.Editor.Project));
    }

    [Fact]
    public async Task AllWindowsUseOneUnionApprovalAndCommitWithLocalEditsInOneUndo()
    {
        await using var test = new Harness();
        await test.PrepareAsync();
        Assert.Equal(2, test.Session.GenerationWindows.Count);
        var batch = Assert.IsType<VoiceLabTakeRunParts>(test.Session.PreparedBatch);
        Assert.Equal(6, batch.TakeCount);
        var before = ProjectSerialization.Serialize(test.Editor.Project);
        var approvals = 0;
        await test.Session.GenerateWindowsAsync((snapshot, text, current, token) =>
        {
            token.ThrowIfCancellationRequested(); Assert.True(current());
            Assert.Equal(6, Assert.IsType<VoiceLabTakeRunParts>(snapshot).TakeCount);
            Assert.Contains("2 passages", text); Assert.Equal(before, ProjectSerialization.Serialize(test.Editor.Project));
            approvals++; return Task.FromResult(true);
        }, _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.Equal(1, approvals);
        Assert.All(test.Runners, runner => Assert.True(runner.PaidRequests > 0));
        Assert.True(test.Session.CanAcceptAll);
        Assert.True(await test.Session.ApplyTakeAsync(), string.Join(" / ", test.Session.GenerationWindows.Select(window => window.Problem)) + test.Editor.Notice);
        Assert.Equal(2, test.Editor.Project.VoiceLab.Segments.Count);
        Assert.Contains("w18", test.Editor.Project.Edits.CutWordIds);
        Assert.Equal("WORD15", test.Editor.Project.Edits.Corrections["w15"]);
        var after = ProjectSerialization.Serialize(test.Editor.Project);
        test.Editor.Undo(); Assert.Equal(before, ProjectSerialization.Serialize(test.Editor.Project)); Assert.False(test.Editor.CanUndo);
        test.Editor.Redo(); Assert.Equal(after, ProjectSerialization.Serialize(test.Editor.Project)); Assert.False(test.Editor.CanRedo);
    }

    /// <summary>Mac <c>whenNoTakeCanRenderTheFooterEndsTheRewrite</c> and smoke S-render-recipe: when no take can go into the video, Use keeps
    /// every phrase as recorded, announces each once and still applies the text fixes; it never repeats the failure.</summary>
    [Fact]
    public async Task WhenNoTakeCanGoIntoTheVideoUseKeepsEveryPhraseAndAppliesTheTextFixes()
    {
        await using var test = new Harness(unusable: _ => true);
        await test.PrepareAsync();
        await test.Session.GenerateWindowsAsync((_, _, current, _) => Task.FromResult(current()), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        List<string> announced = [];
        test.Session.Changed += (_, _) => { if (test.Session.AutoFix.Announcement is { Length: > 0 } line && !announced.Contains(line)) announced.Add(line); };
        var log = new LinesLog();
        test.Session.Log = log;
        Assert.True(test.Session.CanAcceptAll);
        Assert.True(await test.Session.ApplyTakeAsync());
        Assert.Empty(test.Editor.Project.VoiceLab.Segments);
        Assert.Equal("WORD15", test.Editor.Project.Edits.Corrections["w15"]);
        Assert.Equal([RewriteSession.UnusableNote(1), RewriteSession.UnusableNote(2)], announced);
        // Mac logFailure(stage: "use"): each refusal is in the log by type and case, with no provider text.
        Assert.Equal(["rewrite failure stage=use type=VoiceLabProjectException case=QaRejected", "rewrite failure stage=use type=VoiceLabProjectException case=QaRejected"],
            log.Lines);
    }

    /// <summary>Mac <c>blockedUseLine</c> (ADR-R40): a phrase the guard blocked doesn't hold up Use. One click on Use keeps its original
    /// audio, with no Keep Original Audio first, applies the other phrase's take and the text fixes, and says so beside Use.</summary>
    [Fact]
    public async Task UseKeepsABlockedPhrasesOriginalAudioWithOneClick()
    {
        await using var test = new Harness(blocked: index => index == 0);
        await test.PrepareAsync();
        await test.Session.GenerateWindowsAsync((_, _, current, _) => Task.FromResult(current()), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        var windows = test.Session.GenerationWindows;
        Assert.True(windows[0].WaitsOnBlock);
        Assert.Equal(0, test.Runners[0].PaidRequests);
        Assert.True(test.Session.CanAcceptAll);
        var footer = test.Session.FooterStep;
        Assert.Equal(RewriteFooterAction.UseTakes, footer.Action);
        Assert.Equal("Use the reviewed takes.\nUse keeps phrase 1's original audio.", footer.Line);
        Assert.Equal("Use keeps phrase 1's original audio.", test.Session.BlockedUseLine);
        Assert.True(await test.Session.ApplyTakeAsync(), test.Editor.Notice);
        var segment = Assert.Single(test.Editor.Project.VoiceLab.Segments);
        Assert.Contains("better", segment.Text!.New);
        Assert.Equal("WORD15", test.Editor.Project.Edits.Corrections["w15"]);
        Assert.Contains("w18", test.Editor.Project.Edits.CutWordIds);
    }

    [Fact]
    public async Task RevisionDuringUnionApprovalSendsNothingAndCannotApply()
    {
        await using var test = new Harness(); await test.PrepareAsync();
        await test.Session.GenerateWindowsAsync((_, _, current, _) =>
        {
            test.Session.Edit("Changed while approving");
            Assert.False(current());
            return Task.FromResult(true);
        }, _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.All(test.Runners, runner => Assert.Equal(0, runner.PaidRequests));
        Assert.False(await test.Session.ApplyTakeAsync()); Assert.False(test.Editor.CanUndo);
    }

    [Fact]
    public async Task ExcludedChangeIsNotInTheQuotedWindowsOrAcceptedProject()
    {
        await using var test = new Harness();
        var diff = test.Session.Review!.Diff;
        var excluded = diff.Hunks.Select((hunk, index) => (hunk, ordinal: index + 1))
            .Last(pair => pair.hunk.Kind == VoiceLabDiffHunkKind.Voice);
        Assert.True(test.Session.SetChangeIncluded(excluded.ordinal, false));
        var edited = diff.Hunks.Select((hunk, index) => (hunk, ordinal: index + 1))
            .First(pair => pair.hunk.Kind == VoiceLabDiffHunkKind.Voice);
        Assert.True(test.Session.EditChange(edited.ordinal, "plainly"));
        Assert.Equal(TranscriptChangeState.Excluded, test.Session.ChangeStates[excluded.ordinal]);
        await test.PrepareAsync();
        Assert.Single(test.Session.GenerationWindows);
        Assert.Equal(3, test.Session.PreparedBatch!.TakeCount);
        await test.Session.GenerateWindowsAsync((_, _, current, _) => Task.FromResult(current()), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.True(await test.Session.ApplyTakeAsync());
        var segment = Assert.Single(test.Editor.Project.VoiceLab.Segments);
        Assert.DoesNotContain("better", segment.Text!.New);
        Assert.Contains("plainly", segment.Text.New);
    }

    [Fact]
    public async Task RemovingAnEarlierPassageHunkRemapsUnchangedExclusionsWithoutMutatingTheProject()
    {
        await using var test = new Harness();
        var before = ProjectSerialization.Serialize(test.Editor.Project);
        var changes = test.Session.Review!.Diff.Hunks.Select((hunk, index) => (hunk, ordinal: index + 1))
            .Where(pair => pair.hunk.Kind == VoiceLabDiffHunkKind.Voice).ToArray();
        var first = changes[0]; var last = changes[^1];
        Assert.True(test.Session.SetChangeIncluded(last.ordinal, false));
        var original = string.Join(" ", first.hunk.SourceWordIds.Select(id => test.Editor.DisplayText(test.Editor.Words[test.Editor.Index(id)])));
        Assert.True(test.Session.EditChange(first.ordinal, original));
        Assert.Equal(TranscriptChangeState.Excluded, test.Session.ChangeStates[last.ordinal - 1]);
        Assert.DoesNotContain(test.Session.IncludedHunks, hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice);
        Assert.Equal(before, ProjectSerialization.Serialize(test.Editor.Project));
        Assert.False(test.Editor.CanUndo);
    }

    private sealed class Harness : IAsyncDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-rewrite-batch-" + Guid.NewGuid().ToString("N"));
        internal EditorViewModel Editor { get; }
        internal RewriteSession Session { get; }
        internal List<DebugRewriteTakeRunner> Runners { get; } = [];
        /// <param name="unusable">Phrases whose take the recipe refuses at Use (Mac S-render-recipe): publishing it throws.</param>
        /// <param name="blocked">Phrases the use-time guard refuses before anything is sent (ADR-R40).</param>
        internal Harness(string scope = "passage", Func<int, bool>? unusable = null, Func<int, bool>? blocked = null)
        {
            var fixture = HomeViewModelTests.Fixture("clip-from-long-take.voxclip");
            var words = Enumerable.Range(0, 100).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word,
                index + 1, index + 1.4, null, null, 1, null, TimingSource.Native)).ToArray();
            // The fixture's clips are removed, so their share text goes too: the editor drops text for a clip that doesn't exist.
            Editor = new(fixture with { SchemaVersion = 1, VoiceLab = new([]), Transcript = fixture.Transcript! with { Words = words },
                Media = fixture.Media with { Source = fixture.Media.Source with { DurationSeconds = 105, Audio = new(48_000, 1) } },
                Edits = fixture.Edits with { ActiveClipId = null, Clips = [], CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() },
                Share = new(new Dictionary<string, string>()) });
            if (scope == "clip")
            {
                Editor.Select(8); Editor.Select(26, true); Assert.NotNull(Editor.MakeClip());
                Editor = new(Editor.Project);
            }
            var first = scope == "full" ? 0 : 8;
            var last = scope == "full" ? 99 : 26;
            Session = new(Editor, first, last, new(48_000, .01, Enumerable.Repeat(.01f, 10_500).ToArray()), null,
                scope: scope == "full" ? RewriteScope.FullTake : scope == "clip" ? RewriteScope.Clip(Editor.Project.Edits.ActiveClipId!) : null);
            Session.Edit(string.Join(" ", words.Skip(first).Take(last - first + 1).Where(word => word.Id != "w18").Select(word => word.Id switch
            { "w9" => "clearer", "w15" => "WORD15", "w23" => "better", _ => word.Text })));
            Session.ConfigureGenerationFactory(index =>
            {
                var runner = new DebugRewriteTakeRunner(Path.Combine(SharedResources.ResolveRoot(), "fixtures/voice-lab/take-run-cases.json"),
                    storage: new(Editor.Project.Id, Path.Combine(root, "paid"), Path.Combine(root, "scratch"))) { State = blocked?.Invoke(index) == true ? "blocked" : "three-ready" };
                Runners.Add(runner);
                var generation = new RewriteGeneration(runner, runner.DiscoverAsync,
                    (voice, model, seed, token) => Session.GenerationInputAsync(voice, model, seed, true,
                        (request, _) => Task.FromResult(RewriteSourceFixture.Silent(request)), token, index),
                    _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => Session.GenerationIsCurrent);
                var audition = new VoiceLabAudition(() => new SilentEndpoint(), _ => Task.CompletedTask);
                _ = generation.ConfigureTakesAsync(new(audition, runner.Scratch, runner.RejectAsync, unusable?.Invoke(index) == true
                    ? (_, _, _) => throw new VoiceLabProjectException(VoiceLabProjectErrorCode.QaRejected) : runner.PublishAsync));
                return generation;
            });
        }
        internal async Task PrepareAsync()
        {
            await Session.DiscoverWindowsAsync();
            var batch = Assert.IsType<VoiceLabTakeRunParts>(Session.PreparedBatch);
            Session.MarkBatchEstimateShown(batch);
            Assert.True(Session.CanGenerateAll);
        }
        public async ValueTask DisposeAsync()
        {
            Session.Dispose(); await Session.GenerationCleanup;
            foreach (var runner in Runners) runner.Dispose();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    /// <summary>The session's log, kept in memory.</summary>
    private sealed class LinesLog : VoxClip.Core.Services.Logging.ILog
    {
        internal List<string> Lines { get; } = [];
        public void RegisterSecret(string secret) { }
        public void Write(VoxClip.Core.Services.Logging.LogLevel level, string category, string message) { if (category == "rewrite") Lines.Add(message); }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>(Lines);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class SilentEndpoint : IVoiceLabRenderEndpoint
    {
        public Task<string?> CheckAvailabilityAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.FromResult<string?>(null); }
        public Task OpenAsync(string path, CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; }
        public Task PlayAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; }
        public Task Completion => Task.CompletedTask;
        public TimeSpan Position => TimeSpan.Zero;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
#endif
}
#endif

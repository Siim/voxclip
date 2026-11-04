#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The Windows Rewrite smoke, a headless twin of Mac <c>-rewriteSmoke</c> (DebugRewriteSmoke.swift): each scenario
/// drives the real <see cref="RewriteSession"/> and its take windows through a stuck state with stub connectors and runners
/// (nothing is paid or sent), clicking only what the panel offers, and checks the invariants after every step:
/// I1 something acts, I2 no shown action that can't act, I3 one free-text field, I4 the footer never prices or says phrases
/// fit while one is blocked and names only phrases that exist, I6 no paid take dropped without a confirm, I7 an added
/// expression shows in its phrase. At the end: I5 the Rewrite completes (or ends with Done, original words kept), I8 the video
/// duration Use applies, I9 every voice change is voiced. Use itself publishes takes through Media's scratch audio, which
/// this headless twin has none of; I5, I8 and I9 read what Use would apply. Native acceptance stays owed to the VM.</summary>
public sealed class RewriteSmokeTests
{
    private const string Long = "a much much longer phrasing than this slot could hold";
    /// <summary>S2's reply: words 10 and 13 change, word 11 stays (scope words 10–13 of <see cref="CloseTogether"/>).</summary>
    internal const string Close = "much better word11 nicer";
    private const string Fifteen = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen";

    public static TheoryData<string> Scenarios => new(["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11", "S12", "S13", "S14"]);

    [Theory]
    [MemberData(nameof(Scenarios))]
    public async Task EveryScenarioKeepsTheInvariants(string id)
    {
        var smoke = await RunAsync(id);
        Assert.True(smoke.Failures.Count == 0, id + ":\n" + string.Join("\n", smoke.Failures) + "\n--- log ---\n" + string.Join("\n", smoke.Log));
        Assert.NotEmpty(smoke.Log);
    }

    private static async Task<Smoke> RunAsync(string id)
    {
        var tag = VoiceLabAudioTags.Definitions[0].Tag;
        switch (id)
        {
            case "S1":
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S2":
            {
                // Mac S2: placement merges nearby changes when it can; here a sound between them keeps the pair apart, so change 2
                // is refused as too close to change 1 (Mac scripts this refusal; Windows reaches it from the transcript).
                using var smoke = new Smoke(id, new(Close, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)), last: 13, editor: CloseTogether());
                await smoke.ProposeAsync();
                if (smoke.Session.Collision != (2, 1)) smoke.Failures.Add($"{id}: change 2 isn't refused as too close to change 1");
                var collision = smoke.Session.NextStepCards.SingleOrDefault(card => card.Id == "Rewrite.Steps.Collision2");
                if (collision?.Sentence != "Change 2 is too close to change 1 to voice separately." ||
                    !collision.Chips.Select(chip => chip.Label).SequenceEqual(["Keep original words for 2", "✦ Merge with change 1"]) ||
                    smoke.Session.FooterStep.Line != "Change 2 needs a fix above.")
                    smoke.Failures.Add($"{id}: the collision card or footer differs: {collision?.Sentence} {string.Join(", ", collision?.Chips.Select(chip => chip.Label) ?? [])} / {smoke.Session.FooterStep.Line}");
                await smoke.ClickAsync("Rewrite.Chip.CollisionKeep2");
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S3":
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "said briefly")), new((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S4":
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((run, _) => run == 1 ? (Fit, WordsFailed) : (Fit, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S5":
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)));
                await smoke.ProposeAsync();
                smoke.Session.ReviewSurroundingSentence(1);
                smoke.Observe("Use surrounding sentence: refused");
                await smoke.ClickAsync("Rewrite.Chip.ChangedWords1");
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S6":
            {
                using var smoke = new Smoke(id, new(Fifteen + " word11 word12", (_, ordinals) => Rows(ordinals, Fifteen)), new((_, _) => (Fit, Passed)));
                await smoke.ProposeAsync();
                // Over the voice budget Rewrite goes on: a note, and the batch is priced with no click.
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S7":
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                Assert.True(smoke.Session.AddExpression(1, tag));
                smoke.Observe("+ Expression: " + tag, tag: (1, tag));
                await smoke.SettleAsync("the expression's take", tag: (1, tag));
                Assert.True(smoke.Session.RemoveExpression(1, 0));
                await smoke.SettleAsync("remove the expression");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S8":
            {
                var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x")) { FailRewrites = 1, Reask = Reply, HoldReasks = true };
                using var smoke = new Smoke(id, connector, new((_, _) => (Fit, Passed)));
                await smoke.ProposeAsync(expectReply: false);
                await smoke.ClickAsync(RewriteSession.AskAgainChip);
                var asking = smoke.Session.TellTheAiAsync("Keep it short");
                await connector.ReaskSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
                smoke.Observe("Tell the AI: Keep it short");
                smoke.Session.Edit(smoke.Session.NewWords);
                connector.ReaskRelease.SetResult();
                await asking;
                smoke.Observe("the reply arrives after an edit");
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S9":
            {
                var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "said briefly")) { HoldFits = true };
                using var smoke = new Smoke(id, connector, new((_, _) => (5.8, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync(settle: false);
                await connector.FitSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
                smoke.Observe("an automatic fix is running");
                await smoke.ClickAsync("Rewrite.FooterStop");
                connector.Release.SetResult();
                await smoke.Session.MeasuredWork;
                await smoke.SettleAsync("Stop");
                await smoke.ClickAsync("Rewrite.Chip.KeepPhrase1");
                smoke.End(null, voiced: 0, mayEndUnchanged: true);
                return smoke;
            }
            case "S10":
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (0.3, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Retimed, voiced: 1);
                return smoke;
            }
            case "S11":
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (1.5, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Retimed, voiced: 1);
                return smoke;
            }
            case "S14":
            {
                // A collision found after paid takes (Mac's refused takes plan): Get Price voices change 1 while change 2 waits;
                // after the takes the resolver keeps change 2's original words, with no discard and no extra spend.
                using var smoke = new Smoke(id, new(Close, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)), last: 13, editor: CloseTogether());
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                if (smoke.Session.Collision is not null || smoke.Session.ChangeStates.GetValueOrDefault(2) != TranscriptChangeState.Excluded)
                    smoke.Failures.Add($"{id}: the collision after paid takes isn't resolved");
                if (!smoke.Session.AutoFix.Notes.Contains("Change 2 keeps its original words: it's too close to change 1 to voice separately."))
                    smoke.Failures.Add($"{id}: no note says change 2 keeps its original words");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S12":
            {
                using var smoke = new Smoke(id, new(Long + " word11 word12", (round, ordinals) => Rows(ordinals, round <= 3 ? Long : "said briefly")),
                    new((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed)));
                await smoke.ProposeAsync();
                Assert.Single(smoke.Session.PricedVoiceHunks);
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            default:
            {
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
        }
    }

    /// <summary>Words 10–13 within half a second, with a sound (word 12, an event) between the two changes: the diff keeps
    /// them apart and placement cannot merge across the sound (shared window-all `all-event-prevents-merge`).</summary>
    internal static EditorViewModel CloseTogether()
    {
        var project = Editor().Project;
        var words = project.Transcript!.Words.ToArray();
        words[10] = words[10] with { Start = 11.0, End = 11.4 };
        words[11] = words[11] with { Start = 11.401, End = 11.402 };
        words[12] = words[12] with { Kind = WordKind.Event, Text = "[laughs]", Start = 11.403, End = 11.404 };
        words[13] = words[13] with { Start = 11.405, End = 11.805 };
        return new(project with { Transcript = project.Transcript with { Words = words } }, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
    }

    private sealed class Smoke : IDisposable
    {
        private readonly string id;
        private readonly Runner runner;
        private HashSet<Guid> paid = [];
        internal RewriteSession Session { get; }
        internal List<string> Failures { get; } = [];
        internal List<string> Log { get; } = [];
        private int step;

        internal Smoke(string id, Connector connector, Runner runner, int last = 12, EditorViewModel? editor = null)
        {
            this.id = id; this.runner = runner;
            Session = RewriteAutoFixTests.Session(connector, last: last, editor: editor);
            Configure(Session, runner);
        }

        internal async Task ProposeAsync(bool expectReply = true)
        {
            var proposed = await RewriteAutoFixTests.ProposeAsync(Session);
            if (proposed != expectReply) Failures.Add($"{id} propose: expected the reply {(expectReply ? "to land" : "to fail")}");
            await Session.WordingFitWork;
            Observe("open Rewrite and wait for the reply");
        }

        internal async Task GetPriceAsync(bool settle = true)
        {
            await Session.DiscoverWindowsAsync();
            foreach (var window in Session.GenerationWindows) await window.PendingUpdate;
            Observe("Get Price");
            if (Session.PreparedBatch is not { } batch) { Failures.Add($"{id} step {step}: no price to approve"); return; }
            Session.MarkBatchEstimateShown(batch);
            var running = Session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
            if (!settle) return;
            await running;
            await SettleAsync("approve the price and make takes");
        }

        internal async Task SettleAsync(string label, (int Ordinal, string Tag)? tag = null)
        {
            for (var round = 0; round < 64; round++)
            {
                if (Session.AutoFix.Work is { } work) { await work; continue; }
                if (Session.AutoFix.Capped is not null) { Observe("past the cap"); Session.KeepFixing(); continue; }
                break;
            }
            Observe(label, tag: tag);
        }

        /// <summary>Clicks a chip or footer action the panel shows, as a user would; clicking one that isn't shown fails.</summary>
        internal async Task ClickAsync(string control)
        {
            var footer = Session.FooterStep;
            if (control == "Rewrite.FooterStop" && footer.Action is RewriteFooterAction.StopAutoFix or RewriteFooterAction.StopReask)
            {
                if (footer.Action == RewriteFooterAction.StopAutoFix) Session.StopAutoFix(); else Session.StopReask();
                Observe("click " + footer.Title);
                return;
            }
            if (Session.NextStepCards.SelectMany(card => card.Chips).FirstOrDefault(chip => chip.Id == control) is not { } chip)
            {
                Failures.Add($"{id} step {step}: '{control}' isn't shown (footer '{footer.Line}')");
                return;
            }
            if (chip.Id == RewriteSession.AskAgainChip) await RewriteAutoFixTests.ProposeAsync(Session);
            else await chip.Invoke!();
            await Session.WordingFitWork;
            Observe("click " + chip.Label);
        }

        private HashSet<Guid> PaidTakes() => Session.GenerationWindows.SelectMany(window => window.Rows)
            .Where(row => row.Receipt is not null || row.AcceptedRequestIds.Count > 0).Select(row => row.Id).ToHashSet();

        internal void Observe(string label, bool confirmedDiscard = false, (int Ordinal, string Tag)? tag = null)
        {
            step++;
            var name = $"{id} step {step} ({label})";
            var footer = Session.FooterStep;
            var cards = Session.NextStepCards;
            Log.Add($"{name}: footer '{footer.Line}'{(footer.Title is { } title ? " [" + title + "]" : "")}; cards " +
                string.Join(" / ", cards.Select(card => card.Sentence + " " + string.Join(", ", card.Chips.Select(chip => "[" + chip.Label + "]")))));
            if (Session.IsOpen)
            {
                var running = Session.AutoFix.Running || Session.Reasking is not null || Session.IsProposing || Session.WordingIsLocked ||
                    Session.IsGeneratingBatch || Session.GenerationWindows.Any(window => window.IsRunning || window.IsPreparing);
                // The panel's Get Price (before discovery) and its priced Make take (marked shown when drawn) act too.
                var getPrice = Session.PricedVoiceHunks.Count > 0 && Session.GenerationWindows.Any(window => !window.HasDiscovered) && !Session.HasPaidTakes;
                var acts = footer.Title is not null || cards.Any(card => card.Chips.Count > 0) || getPrice || Session.PreparedBatch is not null ||
                    Session.KeepFixingTitle is not null || Session.LeftOutPhrases.Count > 0 || Session.MeasuredGeneration is not null;
                if (!acts && !running) Failures.Add($"{name} I1: nothing acts; footer '{footer.Line}'");
                var inert = footer.Action switch
                {
                    RewriteFooterAction.UseTakes => !Session.CanAcceptAll,
                    RewriteFooterAction.ApplyLocal or RewriteFooterAction.ApplyTextFixes => Session.Editor.Busy || Session.Editor.IsReadOnly,
                    _ => false
                };
                if (inert) Failures.Add($"{name} I2: the footer shows '{footer.Title}', which can't act");
                if (cards.SelectMany(card => card.Chips).FirstOrDefault(chip => chip.Invoke is null && chip.Id != RewriteSession.AskAgainChip) is { } dead)
                    Failures.Add($"{name} I2: chip '{dead.Label}' does nothing");
                if (cards.Select(card => card.Id).Distinct().Count() != cards.Count) Failures.Add($"{name} I3: a card is shown twice");
                var blocked = Session.BlockedVoiceHunks.Count > 0;
                if (blocked && (footer.Line.Contains('$') || System.Text.RegularExpressions.Regex.IsMatch(footer.Line, @"\d+ phrases? fits?")))
                    Failures.Add($"{name} I4: footer '{footer.Line}' while a phrase is still blocked");
                if (System.Text.RegularExpressions.Regex.Match(footer.Line, @"[Pp]hrase (\d+)") is { Success: true } named &&
                    int.Parse(named.Groups[1].Value) > Session.GenerationWindows.Count)
                    Failures.Add($"{name} I4: footer '{footer.Line}' names a phrase the panel doesn't show");
            }
            var current = PaidTakes();
            if (!confirmedDiscard && paid.Except(current).Any()) Failures.Add($"{name} I6: {paid.Except(current).Count()} paid takes dropped without a confirm");
            paid = current;
            if (tag is { } expression && !Session.ShownAudioTags(expression.Ordinal).Any(shown => shown.Tag == expression.Tag))
                Failures.Add($"{name} I7: [{expression.Tag}] isn't in change {expression.Ordinal}'s quote");
        }

        /// <summary>I5, I8 and I9 on what Use would apply: each phrase keeps its words or has a passing take with a valid duration.</summary>
        internal void End(VoiceLabVideoMode? video, int voiced, bool mayEndUnchanged = false)
        {
            var windows = Session.GenerationWindows;
            bool Applies(RewriteGeneration window) => !window.LeftOut && window.Selected is { Selectable: true, RequiresJoinAdvisoryAcceptance: false } selected &&
                (selected.Fits || window.VideoChoice is not null);
            var applying = windows.Where(Applies).ToArray();
            var complete = windows.Count > 0 && windows.All(window => window.LeftOut || Applies(window)) && (applying.Length > 0 || Session.TextFixCount > 0);
            var unchanged = mayEndUnchanged && Session.FooterStep.Action == RewriteFooterAction.Done;
            if (!complete && !unchanged) Failures.Add($"{id} I5: the Rewrite can't complete; footer '{Session.FooterStep.Line}'");
            if (video is { } mode && applying.Any(window => (window.Selected!.Fits ? VoiceLabVideoMode.Source : window.VideoChoice) != mode))
                Failures.Add($"{id} I8: Use would apply {string.Join(", ", applying.Select(window => window.Selected!.Fits ? VoiceLabVideoMode.Source : window.VideoChoice))}, expected {mode}");
            if (applying.Length != voiced) Failures.Add($"{id} I9: {applying.Length} voice changes applied, expected {voiced}");
            // I9 also: an included voice change with no phrase would be dropped unvoiced by Use.
            foreach (var hunk in Session.Review?.VoiceHunks.Except(Session.PricedVoiceHunks) ?? [])
                Failures.Add($"{id} I9: change {hunk.Ordinals[0]} is included but has no phrase to voice it");
            Log.Add($"{id} end: {applying.Length} voiced, {runner.Sends} take runs, spent {RewriteSession.Dollars(Session.AutoFix.Spent)}");
        }

        public void Dispose() => Session.Dispose();
    }
}
#endif

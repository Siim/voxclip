#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
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

    /// <summary>S15 twins Mac S15 (bridge words); S16 twins Mac S14 (Eleven v4 timing quirks), renumbered because Windows S14 is the
    /// collision after paid takes; S17 twins Mac S16 (a long run voiced in parts); the own-take scenarios keep Mac's names.</summary>
    public static TheoryData<string> Scenarios => new(["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11", "S12", "S13", "S14",
        "S15", "S16", "S17", "S-own-typed", "S-own-mic", "S-own-mic-misfit", "S-viral-fit", "S-guard-blocked",
        "S-duration-short", "S-guard-learns", "S-guard-guest", "S-voice-per-video", "S-voice-per-video-short"]);
    /// <summary>S17's take: words 10–79 with every fifth word from 12 to 67 changed, twelve phrases in three parts.</summary>
    internal static readonly int[] LongRunWords = Enumerable.Range(0, 12).Select(index => 12 + 5 * index).ToArray();
    internal static string LongRunReply => string.Join(" ", Enumerable.Range(10, 70).Select(index => LongRunWords.Contains(index) ? "a much clearer phrasing" : "word" + index));
    /// <summary>S16's reply: words 10 and 14 change, words 11–13 stay, so two phrases are voiced.</summary>
    private const string TwoChanges = "a much clearer phrasing word11 word12 word13 a brighter phrasing word15 word16";

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
                // A fifteen-word change can't fit a one-word slot and would keep the speaker's words after its fit (ADR-R42): the fit is
                // stopped and the change priced by the user's own click, and over the voice budget Rewrite goes on with a note.
                var connector = new Connector(Fifteen + " word11 word12", (_, ordinals) => Rows(ordinals, Fifteen)) { HoldFits = true };
                using var smoke = new Smoke(id, connector, new((_, _) => (Fit, Passed)));
                var proposing = RewriteAutoFixTests.ProposeAsync(smoke.Session);
                await connector.FitSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
                smoke.Session.StopWordingFit();
                connector.Release.SetResult();
                if (!await proposing) smoke.Failures.Add($"{id}: the reply didn't land");
                await smoke.Session.WordingFitWork;
                smoke.Observe("stop the fit");
                if (!smoke.Session.PriceItAnyway(1)) smoke.Failures.Add($"{id}: the stopped change couldn't be priced");
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S-viral-fit":
            {
                // Mac S-viral-fit (MVP32, ADR-R42): a padded line longer than its slot is repaired once, then keeps the speaker's words
                // with one line; the other change is voiced (VF1). The request carried each slot and why (VF2).
                const string padded = "Here's the truth, and honestly this is the most amazing software you will ever see";
                var connector = new Connector("a much clearer phrasing word11 word12 word13 " + padded + " word15 word16",
                    (_, ordinals) => Rows(ordinals, padded + " today"));
                using var smoke = new Smoke(id, connector, new((_, _) => (Fit, Passed)), last: 16);
                await smoke.ProposeAsync();
                if (connector.FitRequests.Count != 1) smoke.Failures.Add($"{id} VF1: {connector.FitRequests.Count} fit requests, expected one");
                if (smoke.Session.ChangeStates.GetValueOrDefault(2) != TranscriptChangeState.Excluded ||
                    !smoke.Session.AutoFix.Notes.Contains("Change 2 keeps your original words: still longer than its time in the video after a fit."))
                    smoke.Failures.Add($"{id} VF1: the padded line wasn't kept as recorded with its line");
                if (connector.Rewrites.FirstOrDefault()?.Instruction is not { } asked || !asked.Contains("TIME IN THE VIDEO (the picture keeps running", StringComparison.Ordinal) ||
                    !asked.Contains("1. “word10”: 0.4 s, at most 1 words", StringComparison.Ordinal) || !asked.Contains("7. “word16”: 0.4 s", StringComparison.Ordinal))
                    smoke.Failures.Add($"{id} VF2: the request didn't carry the slots and the why: {connector.Rewrites.Count} sent; " + connector.Rewrites.FirstOrDefault()?.Instruction);
                await smoke.GetPriceAsync();
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S-guard-blocked":
            {
                // Mac S-guard-blocked (G1, G2; ADR-R40): the guard refuses phrase 1's speech before anything is sent. It is settled: the
                // run goes on and voices phrase 2, the stop is said once with its two ways on, and nothing prices phrase 1 again.
                Runner[] runners = [new((_, _) => (Fit, Passed)) { Blocks = _ => new VoiceConsentException(VoiceConsentError.VoiceOwnerMismatch) },
                    new((_, _) => (Fit, Passed))];
                using var smoke = new Smoke(id, new(TwoChanges, (_, ordinals) => Rows(ordinals, "x")), runners[0], last: 16, runners: index => runners[index]);
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                var windows = smoke.Session.GenerationWindows;
                var card = smoke.Session.NextStepCards.FirstOrDefault(card => card.Id == "Rewrite.Steps.Phrase1");
                if (windows[0].Blocked is null || runners[1].Sends != 1 || windows[1].Selected is null)
                    smoke.Failures.Add($"{id} G1: phrase 1 {(windows[0].Blocked is null ? "wasn't settled" : "settled")}, phrase 2 ran {runners[1].Sends} time(s)");
                if (card is null || !card.Chips.Select(chip => chip.Label).SequenceEqual(["● Say it myself", "Keep as recorded"]) ||
                    smoke.Session.FooterStep.Title != "Keep Original Audio for Phrase 1")
                    smoke.Failures.Add($"{id} G1: the stop and its two ways on aren't shown; footer '{smoke.Session.FooterStep.Title}'");
                await smoke.ClickAsync("Rewrite.Chip.KeepAsRecorded1");
                if (runners[0].Sends != 0 || runners[0].Executions != 1 || windows[0].CanExecute ||
                    smoke.Session.NextStepCards.SelectMany(card => card.Chips).Any(chip => chip.Label.Contains('$')) ||
                    smoke.Session.FooterStep.Phrase == 0 || smoke.Session.FooterStep.Title?.Contains('$') == true)
                    // The headless stub has no scratch audio, so its takes never read ready for Use; End checks what Use would apply.
                    smoke.Failures.Add($"{id} G2: phrase 1 was offered or sent again ({runners[0].Executions} runs): footer '{smoke.Session.FooterStep.Title}'");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S-guard-learns":
            {
                // Mac S-guard-learns (G5, G6; ADR-R41): phrase 1's speech is below τ on its own, phrase 2's passes. Get Price screens both
                // first: phrase 2 teaches this video's reference, phrase 1 passes through it, both are priced and voiced, and the spend
                // line says the voice was matched from this video.
                var screen = new ScriptedScreen(new Dictionary<string, float[]> { ["w10"] = ScriptedScreen.Beside, ["w14"] = ScriptedScreen.Near });
                Runner[] runners = [new((_, _) => (Fit, Passed)) { Screen = screen.Screen }, new((_, _) => (Fit, Passed))];
                using var smoke = new Smoke(id, new(TwoChanges, (_, ordinals) => Rows(ordinals, "x")), runners[0], last: 16, runners: index => runners[index]);
                await smoke.ProposeAsync();
                await smoke.Session.DiscoverWindowsAsync();
                foreach (var window in smoke.Session.GenerationWindows) await window.PendingUpdate;
                smoke.Observe("Get Price screens first");
                if (smoke.Session.GenerationWindows.Any(window => window.Blocked is not null) || smoke.Session.PricedWindows.Count != 2 ||
                    VoiceSpeakerReferences.LearnedCount(screen.Speaker) != 1)
                    smoke.Failures.Add($"{id} G5: {smoke.Session.PricedWindows.Count} phrases priced, {VoiceSpeakerReferences.LearnedCount(screen.Speaker)} learned");
                if (!smoke.Session.LearnedFromThisVideo || smoke.Session.ReviewFooter != "Nothing paid yet. Matched your voice from this video.")
                    smoke.Failures.Add($"{id} G6: the spend line reads '{smoke.Session.ReviewFooter}'");
                await smoke.GetPriceAsync();
                if (runners[0].Sends != 1 || runners[1].Sends != 1) smoke.Failures.Add($"{id} G5: phrases sent {runners[0].Sends} and {runners[1].Sends} time(s)");
                smoke.End(VoiceLabVideoMode.Source, voiced: 2);
                return smoke;
            }
            case "S-guard-guest":
            {
                // Mac S-guard-guest (G7): in a video that teaches a reference, a guest's phrase stays blocked before any price; the owner's
                // phrase is voiced, and the guest's sends nothing.
                var screen = new ScriptedScreen(new Dictionary<string, float[]> { ["w10"] = ScriptedScreen.Guest, ["w14"] = ScriptedScreen.Near });
                Runner[] runners = [new((_, _) => (Fit, Passed)) { Screen = screen.Screen }, new((_, _) => (Fit, Passed))];
                using var smoke = new Smoke(id, new(TwoChanges, (_, ordinals) => Rows(ordinals, "x")), runners[0], last: 16, runners: index => runners[index]);
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                var windows = smoke.Session.GenerationWindows;
                if (windows[0].Blocked is null || runners[0].Executions != 0 || runners[1].Sends != 1 || VoiceSpeakerReferences.LearnedCount(screen.Speaker) != 1)
                    smoke.Failures.Add($"{id} G7: the guest's phrase {(windows[0].Blocked is null ? "wasn't blocked" : "was blocked")}, ran {runners[0].Executions} time(s); phrase 2 sent {runners[1].Sends}");
                await smoke.ClickAsync("Rewrite.Chip.KeepAsRecorded1");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S-voice-per-video":
            {
                // Mac S-voice-per-video (PV1–PV3; ADR-R45), with the gate opened only in this harness (a stub Voice Lab whose speaker check is
                // ready). PV1: video 1's first Rewrite asks once, inline, and nothing is sent. PV2: Match this video makes video 1's voice
                // under the anchor's consent before any price, and every take uses it. PV3: video 2 by ✦ Make it postable with the stored
                // answer is never asked, makes its own voice, removes video 1's through the deletion, keeps the anchor and uses its own.
                using var voices = new VideoVoiceFlowTests.Harness();
                await voices.LoadAsync();
                var takes = new Runner((_, _) => (Fit, Passed));
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), takes, editor: new(VideoVoiceFlowTests.Video("car"), now: () => DateTimeOffset.UnixEpoch));
                VideoVoiceFlowTests.ConfigureVoices(smoke.Session, voices, takes);
                await smoke.ProposeAsync();
                var question = smoke.Session.NextStepCards.FirstOrDefault(card => card.Id == RewriteSession.VideoVoiceCardId);
                if (question is null || !question.Sentence.StartsWith(VoiceLabSession.VideoVoiceQuestion, StringComparison.Ordinal) ||
                    !question.Chips.Select(chip => chip.Label).SequenceEqual(["Match this video · free", "Use siim"]) || voices.Backend.Calls.Count > 0)
                    smoke.Failures.Add($"{id} PV1: {question?.Sentence ?? "no question"} [{string.Join("] [", question?.Chips.Select(chip => chip.Label) ?? [])}], {voices.Backend.Calls.Count} calls");
                await smoke.ClickAsync(RewriteSession.VideoVoiceMatchChip);
                await smoke.GetPriceAsync();
                var first = voices.Session.PerVideoBook.VideoFor("car-key");
                if (first is null || voices.Backend.Created.Count != 1 || takes.Input?.RecordId != first.RecordId || first.AnchorId != voices.Anchor.RecordId ||
                    voices.Session.VideoVoiceMode != VoicePerVideo.Mode.Match)
                    smoke.Failures.Add($"{id} PV2: {voices.Backend.Created.Count} voices made, takes with {takes.Input?.RecordId}, video 1's {first?.RecordId}");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                // PV3: a second video, by ✦ Make it postable.
                var kitchen = new EditorViewModel(VideoVoiceFlowTests.Video("kitchen"), now: () => DateTimeOffset.UnixEpoch);
                var second = new Runner((_, _) => (Fit, Passed));
                RewriteSession? opened = null;
                var driver = new MakeItRewriteDriver(kitchen, new(10, 12, Reply, "c1", 5m), request =>
                {
                    opened = RewriteAutoFixTests.Session(new(Reply, (_, ordinals) => Rows(ordinals, "x")), request.First, request.Last, editor: kitchen);
                    VideoVoiceFlowTests.ConfigureVoices(opened, voices, second);
                    return Task.FromResult<RewriteSession?>(opened);
                }, _ => Task.FromResult<VoiceLabMonthlyCap?>(null), session => session.Dispose());
                smoke.Session.Dispose();
                var outcome = await driver.RunAsync(CancellationToken.None);
                opened?.Dispose();
                smoke.Log.Add($"{id} PV3: ✦ Make it postable pressed {string.Join(" → ", driver.Pressed)}");
                var made = voices.Session.PerVideoBook.VideoFor("kitchen-key");
                var asked = driver.Pressed.Any(step => step.Contains("Match this video", StringComparison.Ordinal) || step.Contains("Use siim", StringComparison.Ordinal));
                var old = voices.Backend.Records.Single(record => record.RecordId == first?.RecordId);
                var anchor = voices.Backend.Records.Single(record => record.RecordId == voices.Anchor.RecordId);
                if (asked || made is null || second.Input?.RecordId != made.RecordId || old.Status != VoiceConsentStatus.Deleted ||
                    anchor.Status != VoiceConsentStatus.Active || !voices.Backend.Deleted.SequenceEqual([first!.RecordId]) ||
                    !voices.Session.PerVideoBook.Videos.Select(video => video.ContentKey).SequenceEqual(["kitchen-key"]) || voices.Session.PerVideoBook.Removals.Count > 0 ||
                    voices.Backend.Created.Count != 2 || outcome.Result is MakeItRewriteResult.NeedsYou { Reason: var reason } && reason.Contains("voice", StringComparison.OrdinalIgnoreCase))
                    smoke.Failures.Add($"{id} PV3: {(asked ? "asked again" : "not asked")}, video 2's voice {made?.RecordId}, takes with {second.Input?.RecordId}, video 1's {old.Status}, anchor {anchor.Status}, {voices.Backend.Created.Count} made");
                return smoke;
            }
            case "S-voice-per-video-short":
            {
                // Mac S-voice-per-video-short (PV4): too little of the video's own clear speech keeps the anchor; nothing is made, the takes
                // use siim, and it says so once: a later Rewrite of the same video doesn't say it again.
                using var voices = new VideoVoiceFlowTests.Harness();
                await voices.LoadAsync();
                voices.Backend.Match = true;
                voices.Backend.NotEnough["short-key"] = 29_000;
                var takes = new Runner((_, _) => (Fit, Passed));
                var video = VideoVoiceFlowTests.Video("short");
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), takes, editor: new(video, now: () => DateTimeOffset.UnixEpoch));
                VideoVoiceFlowTests.ConfigureVoices(smoke.Session, voices, takes);
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                const string line = "This video has only 29 s of your own clear speech, so takes use siim. A matching voice needs 30 s.";
                var shown = smoke.Log.Count(entry => entry.Contains(line, StringComparison.Ordinal));
                if (voices.Backend.Created.Count > 0 || takes.Input?.RecordId != voices.Anchor.RecordId || shown < 1 ||
                    !voices.Session.PerVideoBook.ShortNoted.SequenceEqual(["short-key"]))
                    smoke.Failures.Add($"{id} PV4: shown in {shown} step(s), {voices.Backend.Created.Count} made, takes with {takes.Input?.RecordId}");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                using var again = VideoVoiceFlowTests.Rewrite(voices, video, new Runner((_, _) => (Fit, Passed)));
                await RewriteAutoFixTests.ProposeAsync(again);
                await again.DiscoverWindowsAsync();
                if (again.NextStepCards.Any(card => card.Sentence == line)) smoke.Failures.Add($"{id} PV4: said again in a later Rewrite");
                return smoke;
            }
            case "S-duration-short":
            {
                // Mac S-duration-short (DS1): phrase 1's take is far shorter than its slot and no video duration can carry it. Rewrite keeps
                // phrase 1's recorded audio with one line and no click, no footer asks for a duration no control makes, and Use applies
                // phrase 2.
                Runner[] runners = [new((_, _) => (RewriteDurationSettleTests.TooShort, Passed)), new((_, _) => (Fit, Passed))];
                using var smoke = new Smoke(id, new(TwoChanges, (_, ordinals) => Rows(ordinals, "x")), runners[0], last: 16, runners: index => runners[index]);
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                const string line = "Phrase 1's take can't fit its place in the video, so it keeps your original audio.";
                var said = smoke.Session.AutoFix.Notes.Count(note => note == line);
                var asked = smoke.Log.Any(entry => entry.Contains("Choose the video duration", StringComparison.Ordinal));
                if (!smoke.Session.GenerationWindows[0].LeftOut || said != 1 || smoke.Session.AutoFix.Announcement != line || asked ||
                    smoke.Session.FooterStep.Phrase == 0 || runners[0].Sends != 1)
                    smoke.Failures.Add($"{id} DS1: phrase 1 {(smoke.Session.GenerationWindows[0].LeftOut ? "kept" : "not kept")}, said {said}×" +
                        (asked ? ", a footer asked for a duration" : "") + $", phrase 1 made {runners[0].Sends} take(s); footer '{smoke.Session.FooterStep.Title}'");
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
            case "S15":
            {
                // Mac S15: the measured round's first reply drops the words joining phrase 1 to the recording (word10), so it can't be
                // placed or priced. The free re-ask in the same round names them; its shorter wording keeps them and is voiced.
                var connector = RewriteLearningLoopTests.Measured(RewriteLearningLoopTests.BridgedReply, request => request == 1 ? "brief words" : "word10 brief words");
                using var smoke = new Smoke(id, connector, new((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed)), editor: RewriteLearningLoopTests.BridgedEditor());
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                var measured = connector.FitRequests.Where(request => request.CachedBlock!.Contains("Measured take:", StringComparison.Ordinal)).ToArray();
                if (measured.Length != 2 || !measured[0].CachedBlock!.Contains("Required: the text must begin with “word10”", StringComparison.Ordinal) ||
                    !measured[1].CachedBlock!.Contains("- “brief words”: dropped the joining words, not used", StringComparison.Ordinal))
                    smoke.Failures.Add($"{id}: the round didn't name the bridge words and ask again once ({measured.Length} measured requests)");
                if (smoke.Session.AutoFix.Rounds.GetValueOrDefault(0) != 1) smoke.Failures.Add($"{id}: the re-ask counted as another round");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S16":
            {
                // Mac S14 (MVP18): phrase 1's reply timing is tolerated (its take arrives timed); phrase 2's take has no word timing even
                // after recovery. Its run is not fatal, so the batch goes on, and the resolver makes one more take of it: both phrases
                // are voiced, never stopped for timing or retried into the same failure.
                var second = new Runner((_, _) => (Fit, Passed)) { Fails = (run, _) => run == 1 ? (new VoiceLabException(VoiceLabErrorKind.InvalidAlignment), false) : null };
                Runner[] runners = [new((_, _) => (Fit, Passed)), second];
                using var smoke = new Smoke(id, new(TwoChanges, (_, ordinals) => Rows(ordinals, "x")), runners[0], last: 16, runners: index => runners[index]);
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                if (smoke.Session.AutoFix.Stopped) smoke.Failures.Add($"{id}: the fixes stopped: {smoke.Session.AutoFix.StopReason}");
                if (second.Sends != 2 || !smoke.Session.AutoFix.TriedAnother.Contains(1)) smoke.Failures.Add($"{id}: phrase 2 wasn't retimed by one more take ({second.Sends} runs)");
                smoke.End(VoiceLabVideoMode.Source, voiced: 2);
                return smoke;
            }
            case "S17":
            {
                // Mac S16 (MVP23): a long take whose Rewrite changes more phrases than one batch holds is priced and approved once,
                // then voiced part by part; each later part is quoted again just before it runs, at the price approved.
                var runners = LongRunWords.Select(_ => new Runner((_, _) => (Fit, Passed))).ToArray();
                using var smoke = new Smoke(id, new(LongRunReply, (_, ordinals) => Rows(ordinals, "x")), runners[0], last: 79, runners: index => runners[index]);
                await smoke.ProposeAsync();
                await smoke.Session.DiscoverWindowsAsync();
                foreach (var window in smoke.Session.GenerationWindows) await window.PendingUpdate;
                smoke.Observe("Get Price");
                if (smoke.Session.PreparedBatch is not { } run) { smoke.Failures.Add($"{id}: no price to approve"); return smoke; }
                if (smoke.Session.GenerationWindows.Count != LongRunWords.Length || run.Parts.Count != 3 || run.TakeCount != 3 * LongRunWords.Length)
                    smoke.Failures.Add($"{id}: {smoke.Session.GenerationWindows.Count} phrases in {run.Parts.Count} parts, {run.TakeCount} takes priced");
                smoke.Session.MarkBatchEstimateShown(run);
                var priced = runners.Select(runner => runner.Prepares).ToArray();
                var approvals = 0;
                await smoke.Session.GenerateWindowsAsync((_, text, _, _) =>
                {
                    approvals++;
                    if (!text.Contains($"across {LongRunWords.Length} passages", StringComparison.Ordinal)) smoke.Failures.Add($"{id}: the price reads '{text}'");
                    return Task.FromResult(true);
                }, _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
                await smoke.SettleAsync("approve the price once and make takes");
                if (approvals != 1) smoke.Failures.Add($"{id}: {approvals} approvals for one run");
                // Every phrase prices its next take after its run; a later part's phrases were also quoted again before theirs.
                var after = runners[0].Prepares - priced[0];
                for (var index = 0; index < runners.Length; index++)
                    if (runners[index].Sends != 1 || runners[index].Prepares - priced[index] != after + (index < VoiceLabTakeBatch.MaximumWindows ? 0 : 1))
                        smoke.Failures.Add($"{id}: phrase {index + 1} was quoted {runners[index].Prepares - priced[index]} more times and run {runners[index].Sends} times");
                if (smoke.Session.Problem.Length > 0) smoke.Failures.Add($"{id}: {smoke.Session.Problem}");
                smoke.End(VoiceLabVideoMode.Source, voiced: LongRunWords.Length);
                return smoke;
            }
            case "S-own-typed":
            {
                // Mac S-own-typed: the user types the wording, the cloned voice reads it, Use.
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)));
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                await smoke.Session.ChooseWordingAsync(PhraseWording.OwnWords, 0);
                smoke.Observe("choose [My words] on phrase 1");
                smoke.Session.EditOwnWords("shoot the clip in one go", 0);
                await smoke.Session.PriceOwnWordsAsync(0);
                smoke.Observe("type 'shoot the clip in one go' in My words");
                if (smoke.Session.OwnWordsTakeTitle(0) is not { } title) { smoke.Failures.Add($"{id}: My words has no priced take"); return smoke; }
                await smoke.Session.MakeOwnWordsTakeAsync(0, (_, _) => Task.FromResult(true));
                smoke.Observe("click [" + title + "]");
                var window = smoke.Session.Generation!;
                if (window.Selected is not { } used || window.InputFor(used.Id)?.Text != "shoot the clip in one go")
                    smoke.Failures.Add($"{id}: Use would apply another wording than the user's");
                smoke.End(VoiceLabVideoMode.Source, voiced: 1);
                return smoke;
            }
            case "S-own-mic":
            {
                // Mac S-own-mic: the user records the phrase, it is checked on this PC, Use.
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)), source: true);
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                await smoke.RecordAsync(1.3, "click [● Record]");
                await smoke.UseOwnTakeAsync();
                if (smoke.Session.DisclosureLine != RewriteSession.OwnTakeDisclosureLine) smoke.Failures.Add($"{id}: the footer labels the own take as AI");
                smoke.End(null, voiced: 1);
                return smoke;
            }
            case "S-own-mic-misfit":
            {
                // Mac S-own-mic-misfit: the first take runs too long for the gap; Record again replaces it and fits; Use.
                using var smoke = new Smoke(id, new(Reply, (_, ordinals) => Rows(ordinals, "x")), new((_, _) => (Fit, Passed)), source: true);
                await smoke.ProposeAsync();
                await smoke.GetPriceAsync();
                await smoke.RecordAsync(3.3, "click [● Record]");
                var window = smoke.Session.Generation!;
                var first = window.Rows[^1];
                var line = RewritePhraseMicrophone.TakeLine(first, window.RecordedTake(first.Id)?.Text ?? "", window.Slot(first) ?? 0, window.LengthFits(first), window.DurationAvailable(first));
                if (!line.Contains("long", StringComparison.Ordinal)) smoke.Failures.Add($"{id}: the misfit's line doesn't say it runs long: {line}");
                await smoke.RecordAsync(1.3, "click [Record again]");
                if (window.Rows.Any(row => row.Id == first.Id) || window.Rows.Count(row => window.IsRecorded(row.Id)) != 1)
                    smoke.Failures.Add($"{id}: Record again didn't replace the unused misfit");
                await smoke.UseOwnTakeAsync();
                smoke.End(null, voiced: 1);
                return smoke;
            }
            case "S12":
            {
                // A long line would keep the speaker's words after its one fit (ADR-R42); stopped and priced by the user's own click, its
                // too-long take is reworded from its measured length.
                var connector = new Connector(Long + " word11 word12", (round, ordinals) => Rows(ordinals, round <= 1 ? Long : "said briefly")) { HoldFits = true };
                using var smoke = new Smoke(id, connector, new((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed)));
                var proposing = RewriteAutoFixTests.ProposeAsync(smoke.Session);
                await connector.FitSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
                smoke.Session.StopWordingFit();
                connector.Release.SetResult();
                if (!await proposing) smoke.Failures.Add($"{id}: the reply didn't land");
                await smoke.Session.WordingFitWork;
                if (!smoke.Session.PriceItAnyway(1)) smoke.Failures.Add($"{id}: the stopped change couldn't be priced");
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
        private readonly Func<int, Runner>? runners;
        private readonly RewriteOwnTakeTests.FakeMicrophone microphone = new();
        private readonly RewriteOwnTakeTests.FakeHeard heard = new() { Words = RewriteOwnTakeTests.Words };
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-smoke-" + Guid.NewGuid().ToString("N"));
        private HashSet<Guid> paid = [];
        internal RewriteSession Session { get; }
        internal List<string> Failures { get; } = [];
        internal List<string> Log { get; } = [];
        private int step;

        internal Smoke(string id, Connector connector, Runner runner, int last = 12, EditorViewModel? editor = null, Func<int, Runner>? runners = null,
            bool source = false)
        {
            this.id = id; this.runner = runner; this.runners = runners;
            Session = RewriteAutoFixTests.Session(connector, last: last, editor: editor);
            // Say it myself needs the decoded source; several phrases need a runner each (a stub runner holds one quote).
            if (source || runners is not null) RewriteOwnTakeTests.ConfigureWithSource(Session, runners ?? (_ => runner));
            else Configure(Session, runner);
            if (source)
                Session.ConfigureMicrophone(new RewritePhraseMicrophone(microphone, new RewriteOwnTakeTests.FakeCue(),
                    heard, () => PhraseMicrophoneAccess.Allowed, () => false, meters: false),
                    new(Session.Project.Id, Path.Combine(root, "VoiceLab"), Path.Combine(root, "VoiceLabScratch")));
        }

        /// <summary>[● Record] (or [Record again]) on phrase 1, speaking for <paramref name="seconds"/>, then [Stop] or the limit.</summary>
        internal async Task RecordAsync(double seconds, string label)
        {
            if (Session.PhraseMicrophone is not { } phrase) { Failures.Add($"{id}: no microphone"); return; }
            await Session.RecordPhraseAsync(0);
            Observe(label);
            microphone.Seconds = Math.Min(seconds, phrase.Limit);
            // The recognizer hears the three words across the whole recording, so the take is as long as the user spoke.
            var span = (microphone.Seconds - 0.35) / 3;
            heard.Words = new[] { "much", "clearer", "words" }.Select((word, index) => new VoiceLabSpokenWord(word, 0.15 + index * span, 0.15 + index * span + span * 0.85)).ToArray();
            if (seconds >= phrase.Limit) await phrase.TickAsync(Session); else await Session.StopPhraseRecordingAsync();
            Observe(seconds >= phrase.Limit ? "it stops at the gap + 1.5 s" : "click [Stop]");
            if (phrase.Problem.Length > 0) Failures.Add($"{id}: the take could not be checked: {phrase.Problem}");
        }

        /// <summary>[Use your take], or [Use anyway] for a take a changed video duration carries (ADR-R39: a join advisory alone
        /// needs no Use anyway).</summary>
        internal async Task UseOwnTakeAsync()
        {
            var window = Session.Generation!;
            if (window.Rows.LastOrDefault(row => window.IsRecorded(row.Id)) is not { } take) { Failures.Add($"{id}: no own take"); return; }
            var anyway = !window.LengthFits(take);
            if (!await window.SelectTakeAsync(take.Id)) Failures.Add($"{id}: Use your take didn't act");
            Observe(anyway ? "click [Use anyway]" : "click [Use your take]");
            if (window.SelectedTakeId != take.Id) Failures.Add($"{id}: the own take isn't the one used");
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
                // I10 (Mac, ADR-R42): a Rewrite waiting on nothing has a footer primary, unless the panel's own Get Price or priced Make
                // take, drawn right above, is the step.
                if (!running && footer.Title is null && !getPrice && Session.PreparedBatch is null && Session.MeasuredGeneration is null &&
                    Session.Review is { Diff.Hunks.Count: > 0 })
                    Failures.Add($"{name} I10: no step forward in the footer '{footer.Line}'");
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
            var runs = runners is null ? runner.Sends : Enumerable.Range(0, windows.Count).Sum(index => runners(index).Sends);
            Log.Add($"{id} end: {applying.Length} voiced, {runs} take runs, spent {RewriteSession.Dollars(Session.AutoFix.Spent)}");
        }

        public void Dispose()
        {
            Session.Dispose();
            try { Directory.Delete(root, true); } catch (DirectoryNotFoundException) { }
        }
    }
}
#endif

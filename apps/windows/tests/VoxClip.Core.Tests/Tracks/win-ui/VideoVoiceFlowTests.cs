#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>A matching voice for each video (voice-lab.md §6.13, ADR-R45; Mac <c>VideoVoiceFlowTests</c>): the answer's states and memory;
/// make, use and remove with a stub backend (the attested creation's own journal, creator and tombstone are the Media tests'); pending takes
/// and a failed removal with its note and backed-off retry; too little speech said once; the take match; and the closed parity gate, behind
/// which nothing is offered, made, used, removed or paid for. Nothing is sent: the backend is a stub, the gate is opened only here.</summary>
public sealed class VideoVoiceFlowTests
{
    internal static Task Dispatch(Action action) { action(); return Task.CompletedTask; }

    /// <summary>The anchor: the attested fixture voice "siim (VoxClip)" (a <c>/2</c> record with project consent).</summary>
    internal static VoiceConsentRecord Anchor() => VoiceLabLearningTests.Record() with { VoiceName = "siim (VoxClip)" };

    /// <summary>A transcribed English video with its own content key and file name.</summary>
    internal static Project Video(string name)
    {
        var project = RewriteAutoFixTests.Editor().Project;
        return project with { Media = project.Media with { Source = project.Media.Source with { ContentKey = name + "-key", AbsolutePath = $"/videos/{name}.mp4" } } };
    }

    [Fact]
    public async Task TheAnswerIsAskedUntilChosenRememberedAndShownInSettings()
    {
        using var h = new Harness();
        var car = Video("car");
        await h.LoadAsync();
        Assert.Equal(VoicePerVideo.Mode.Ask, h.Session.VideoVoiceMode);
        Assert.True(h.Session.OffersVideoVoice(car));
        Assert.Equal(h.Anchor.RecordId, h.Session.AnchorVoice("en")?.RecordId);
        Assert.Equal("free", h.Session.VideoVoicePrice);
        // Unset: nothing is made without the answer, and takes start with the anchor.
        var waiting = h.Session.MakeVideoVoice(car, "/videos/car.mp4");
        Assert.Equal(VideoVoicePhase.Idle, waiting.Phase);
        Assert.Empty(h.Backend.Calls);
        Assert.Equal(h.Anchor.RecordId, h.Session.RewriteVoicePreference(car.Media.Source.ContentKey, "en"));
        // "Use siim" is remembered; Settings › Voices shows it and can change it back to asking.
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Anchor);
        Assert.False(h.Backend.Match);
        Assert.Equal(VoicePerVideo.Mode.Anchor, h.Session.VideoVoiceMode);
        Assert.Equal("Every video uses siim.", VoiceLabSession.ModeLine(VoicePerVideo.Mode.Anchor, h.Session.AnchorName(null)));
        Assert.Equal(VideoVoicePhase.Idle, h.Session.MakeVideoVoice(car, "/videos/car.mp4").Phase);
        Assert.Empty(h.Backend.Calls);
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Ask);
        Assert.Null(h.Backend.Match);
        Assert.Equal(VoicePerVideo.Mode.Ask, h.Session.VideoVoiceMode);
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);
        Assert.True(h.Backend.Match);
        Assert.Equal(["Make a matching voice", "Use siim", "Ask in Rewrite"], VoiceLabSession.ModeChoices("siim").Select(choice => choice.Title));
        Assert.Equal("Rewrite asks once, on the next video that needs your voice.", VoiceLabSession.ModeLine(VoicePerVideo.Mode.Ask, "siim"));
        Assert.Equal("Each video gets a voice made from its own speech, so takes sound like that recording. The previous video's voice is removed; siim stays.",
            VoiceLabSession.ModeLine(VoicePerVideo.Mode.Match, "siim"));
        Assert.Equal("Make a matching voice from this video? Your takes will sound like this recording. The previous video's voice is removed.", VoiceLabSession.VideoVoiceQuestion);
        Assert.True(h.Session.ShowsVideoVoiceRows);
    }

    [Fact]
    public async Task EachVideoGetsItsOwnVoiceAndThePreviousOneIsRemovedThroughTheDeletion()
    {
        using var h = new Harness();
        var car = Video("car");
        var kitchen = Video("kitchen");
        h.Backend.Finds["car-key"] = new("41 s from 1 video and your consent clip", [27.72, 15.4, 12.3, 13.3], new object(), RemovesBackgroundNoise: true, VideoMilliseconds: 41_000);
        h.Backend.Finds["kitchen-key"] = new("40 s from 1 video and your consent clip", [27.72, 20, 20], new object(), VideoMilliseconds: 40_000);
        h.Calibrations.Record(h.Anchor.RecordId, "eleven_v4", "t1", 2.8, 2.0);
        await h.LoadAsync();
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);

        // Video 1: its own verified speech under the anchor's consent, noise removal on (a piece is under 20 dB).
        var first = h.Session.MakeVideoVoice(car, "/videos/car.mp4");
        Assert.Equal(VideoVoicePhase.Making, first.Phase);
        Assert.Equal("Finding your clearest speech in this video… Nothing is sent yet.", first.Line);
        await first.Work;
        Assert.Equal(VideoVoicePhase.Ready, first.Phase);
        var carVoice = first.RecordId!;
        var made = Assert.Single(h.Backend.Created);
        Assert.Equal(h.Anchor.RecordId, made.Anchor.RecordId);
        Assert.Equal("siim · car", made.Name);
        Assert.True(made.Found.RemovesBackgroundNoise);
        Assert.Equal(["find car-key", "create siim · car"], h.Backend.Calls);
        Assert.Equal("Takes in this video use siim · car (VoxClip), made from this video.", first.Line);
        var video = h.Session.PerVideoBook.VideoFor("car-key")!;
        Assert.Equal((carVoice, h.Anchor.RecordId, h.Anchor.ReferenceAudioSha256, 41.0, true),
            (video.RecordId, video.AnchorId, video.AnchorReferenceSha256, video.VideoSeconds, video.RemovesBackgroundNoise));
        // Kept in app data, not in the project file.
        Assert.Equal(h.Session.PerVideoBook, await new VoicePerVideoStore(h.Backend.PerVideoStore!.FilePath).LoadAsync(TestContext.Current.CancellationToken));
        // Every take in that video uses it; another video starts with the anchor; a video's voice is never the anchor.
        Assert.Equal(carVoice, h.Session.RewriteVoicePreference("car-key", "en"));
        Assert.Equal(h.Anchor.RecordId, h.Session.RewriteVoicePreference("kitchen-key", "en"));
        Assert.Equal(h.Anchor.RecordId, h.Session.AnchorVoice("en")?.RecordId);
        // The new voice's calibration is seeded from the anchor's.
        Assert.True(h.Calibrations.For(carVoice) is { Seeded: true } seeded && seeded.Models.Keys.SequenceEqual(h.Calibrations.For(h.Anchor.RecordId)!.Models.Keys));
        // A second ask for the same video keeps its voice: nothing is made again.
        Assert.True(h.Session.MakeVideoVoice(car, "/videos/car.mp4").Work.IsCompleted);
        Assert.Single(h.Backend.Created);

        // Video 2: its voice is made, then video 1's is deleted through the existing deletion; the anchor stays.
        var second = h.Session.MakeVideoVoice(kitchen, "/videos/kitchen.mp4");
        await second.Work;
        var kitchenVoice = second.RecordId!;
        Assert.False(h.Backend.Created[1].Found.RemovesBackgroundNoise);
        Assert.Equal([carVoice], h.Backend.Deleted);
        Assert.Equal(VoiceConsentStatus.Deleted, h.Backend.Records.Single(record => record.RecordId == carVoice).Status);
        Assert.Equal(VoiceConsentStatus.Active, h.Backend.Records.Single(record => record.RecordId == h.Anchor.RecordId).Status);
        Assert.Equal([kitchenVoice], h.Session.PerVideoBook.Videos.Select(item => item.RecordId));
        Assert.Empty(h.Session.PerVideoBook.Removals);
        Assert.Null(h.Session.PerVideoNote);
        Assert.Equal(h.Anchor.RecordId, h.Session.RewriteVoicePreference("car-key", "en"));
        Assert.Equal(kitchenVoice, h.Session.RewriteVoicePreference("kitchen-key", "en"));
        Assert.Null(h.Session.Confirmation);
        Assert.Contains(h.Backend.Logged, line => line.StartsWith("per-video voice made video=car-key speech_ms=41000 files=4 noise_removal=true", StringComparison.Ordinal));
        Assert.Contains("per-video voice removed attempts=1", h.Backend.Logged);
    }

    [Fact]
    public async Task NeverRemovesAVoiceWithPendingTakesAndAFailedRemovalRetriesWithANote()
    {
        var clock = new VoiceSessionClock();
        using var h = new Harness(clock);
        var car = Video("car");
        var kitchen = Video("kitchen");
        await h.LoadAsync();
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);
        var first = h.Session.MakeVideoVoice(car, "/videos/car.mp4");
        await first.Work;
        var carVoice = first.RecordId!;
        // Video 1's Rewrite still holds paid takes nobody used: its voice stays until they are.
        h.Session.PendingTakeVoices = () => new HashSet<string> { carVoice };
        await h.Session.MakeVideoVoice(kitchen, "/videos/kitchen.mp4").Work;
        Assert.Empty(h.Backend.Deleted);
        var waiting = Assert.Single(h.Session.PerVideoBook.Removals);
        Assert.Equal((carVoice, null), (waiting.RecordId, waiting.LastError));
        Assert.Equal("The voice for car is removed once its unused takes are used or discarded.", h.Session.PerVideoNote);
        // The takes are used: the next pass removes it, but ElevenLabs fails, so it stays owed with a note.
        h.Session.PendingTakeVoices = () => new HashSet<string>();
        h.Backend.FailDeletes = true;
        await h.Session.RemovePreviousVideoVoicesAsync(new DateTimeOffset(2027, 1, 15, 8, 0, 0, TimeSpan.Zero));
        var owed = Assert.Single(h.Session.PerVideoBook.Removals);
        Assert.Equal((carVoice, 1), (owed.RecordId, owed.Attempts));
        Assert.NotNull(owed.LastError);
        Assert.Equal("2027-01-15T08:00:30Z", owed.NextAttemptAt);
        Assert.Equal("Couldn't remove the voice for car yet. VoxClip retries in the background.", h.Session.PerVideoNote);
        Assert.Equal(VoiceConsentStatus.Active, h.Backend.Records.Single(record => record.RecordId == h.Anchor.RecordId).Status);
        // The second failure backs off to a minute.
        await h.Session.RemovePreviousVideoVoicesAsync(new DateTimeOffset(2027, 1, 15, 8, 1, 0, TimeSpan.Zero));
        Assert.Equal(("2027-01-15T08:02:00Z", 2), (h.Session.PerVideoBook.Removals[0].NextAttemptAt, h.Session.PerVideoBook.Removals[0].Attempts));
        Assert.True(h.Session.RemovalRetryScheduled);
        // The background retry finishes it once it is due.
        h.Backend.FailDeletes = false;
        var retry = h.Session.RemovalRetryWork;
        Assert.False(retry.IsCompleted);
        clock.Advance(TimeSpan.FromHours(1));
        await retry.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
        Assert.Empty(h.Session.PerVideoBook.Removals);
        Assert.Equal([carVoice], h.Backend.Deleted);
        Assert.Null(h.Session.PerVideoNote);
    }

    [Fact]
    public async Task TooLittleOfTheVideosOwnSpeechKeepsTheAnchorAndSaysSoOnce()
    {
        using var h = new Harness();
        var shortVideo = Video("short");
        h.Backend.NotEnough["short-key"] = 29_000;
        await h.LoadAsync();
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);
        var state = h.Session.MakeVideoVoice(shortVideo, "/videos/short.mp4");
        await state.Work;
        Assert.Equal(VideoVoicePhase.Anchor, state.Phase);
        Assert.Equal("This video has only 29 s of your own clear speech, so takes use siim. A matching voice needs 30 s.", state.Line);
        Assert.Empty(h.Backend.Created);
        Assert.Equal(["short-key"], h.Session.PerVideoBook.ShortNoted);
        Assert.Equal(h.Anchor.RecordId, h.Session.RewriteVoicePreference("short-key", "en"));
        // A later run of the app: the anchor again, and no note.
        using var later = new VoiceLabSession(h.Backend, Dispatch);
        await later.RefreshEnabledStateAsync();
        var again = later.MakeVideoVoice(shortVideo, "/videos/short.mp4");
        Assert.Equal((VideoVoicePhase.Anchor, ""), (again.Phase, again.Line));
        Assert.Single(h.Backend.Calls);
    }

    [Fact]
    public async Task ATakesMatchIsRecordedForTheVideoAndTheAnchor()
    {
        using var h = new Harness();
        var car = Video("car");
        await h.LoadAsync();
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);
        var state = h.Session.MakeVideoVoice(car, "/videos/car.mp4");
        await state.Work;
        var voice = state.RecordId!;
        await h.Session.RecordTakeMatchAsync("car-key", "car", h.Anchor.RecordId, 0.50);
        await h.Session.RecordTakeMatchAsync("car-key", "car", h.Anchor.RecordId, 0.58);
        await h.Session.RecordTakeMatchAsync("car-key", "car", voice, 0.81);
        await h.Session.RecordTakeMatchAsync("car-key", "car", voice, 0.20);
        var measurement = Assert.Single(h.Session.PerVideoBook.Measurements);
        Assert.Equal(0.81, measurement.VideoVoice);
        Assert.Equal(0.54, measurement.Anchor!.Value, 10);
        Assert.Equal("car: its own voice 0.81 · siim 0.54", VoiceLabSession.MatchLine(measurement, "siim"));
        Assert.Equal(h.Session.PerVideoBook.Measurements, (await h.Backend.PerVideoStore!.LoadAsync(TestContext.Current.CancellationToken)).Measurements);
        Assert.Contains(h.Backend.Logged, line => line == "per-video take match video=car-key voice=video score=0.810");
    }

    /// <summary>The closed gate: no speaker check on this PC. Nothing is offered or made, no stored answer is acted on, no removal runs, Settings
    /// shows no "Each video" rows and Rewrite keeps the setting's voice.</summary>
    [Fact]
    public async Task BehindTheClosedGateNothingIsOfferedMadeUsedOrRemoved()
    {
        using var h = new Harness();
        h.Backend.Available = false;
        var car = Video("car");
        await h.LoadAsync();
        h.Backend.Match = true;
        Assert.False(h.Session.OffersVideoVoice(car));
        Assert.False(h.Session.ShowsVideoVoiceRows);
        var state = h.Session.MakeVideoVoice(car, "/videos/car.mp4");
        await state.Work;
        Assert.Equal(VideoVoicePhase.Idle, state.Phase);
        Assert.Empty(h.Backend.Calls);
        Assert.Equal(h.Anchor.RecordId, h.Session.RewriteVoicePreference("car-key", "en"));
        Assert.False(VoiceSpeakerCheck.WindowsNativeParityVerified);
    }

    /// <summary>Settings › Voices "Each video" (Mac <c>VideoVoiceRows</c>): the answer and its line, the video's voice, the owed removal with
    /// Retry now, and the match lines; the pane keeps its one live region and says changed lines once.</summary>
    [Fact]
    public async Task SettingsEachVideoShowsTheAnswerTheVoiceTheNoteAndTheMatch()
    {
        using var h = new Harness();
        h.Backend.Finds["car-key"] = new("41 s from 1 video and your consent clip", [27.72, 15.4, 12.3, 13.3], new object(), RemovesBackgroundNoise: true, VideoMilliseconds: 41_000);
        await h.LoadAsync();
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);
        await h.Session.MakeVideoVoice(Video("car"), "/videos/car.mp4").Work;
        Assert.True(h.Session.ShowsVideoVoiceRows);
        Assert.Equal("siim", h.Session.AnchorName(null));
        Assert.Equal("siim · car (VoxClip) · 41 s of car, background noise removed", h.Session.VideoLine(Assert.Single(h.Session.PerVideoBook.Videos)));
        var app = Path.Combine(Directory.GetParent(SharedResources.ResolveRoot())!.FullName, "apps", "windows", "src", "VoxClip.App");
        var pane = File.ReadAllText(Path.Combine(app, "Controls", "VoiceLabSettingsPane.cs"));
        Assert.Equal(1, pane.Split("SetLiveSetting").Length - 1);
        Assert.Contains("if (session.ShowsVideoVoiceRows) AddVideoVoiceRows();", pane);
        Assert.Contains("Header = \"Each video\"", pane);
        Assert.Contains("session.SetVideoVoiceModeAsync(chosen)", pane);
        Assert.Contains("SessionButton(\"Retry now\"", pane);
        Assert.Contains("session.RemovePreviousVideoVoicesAsync()", pane);
        Assert.Contains("AnnounceLine(modeText, modeLine, \"voice-per-video-mode\", announceFirst: initialLoadComplete)", pane);
        Assert.Contains("AnnounceLine(noteText, note, \"voice-per-video-note\", announceFirst: initialLoadComplete)", pane);
        Assert.Contains("VoiceLabSession.MatchLine(measurement, anchor)", pane);
    }

    /// <summary>A Rewrite of <paramref name="project"/> connected to the harness's Voice Lab: its voices are the backend's active records, the
    /// media is found, and each phrase runs on <paramref name="runner"/>.</summary>
    internal static RewriteSession Rewrite(Harness h, Project project, RewriteAutoFixTests.Runner runner, string reply = RewriteAutoFixTests.Reply)
    {
        var editor = new EditorViewModel(project, now: () => new DateTimeOffset(2026, 11, 6, 0, 0, 0, TimeSpan.Zero));
        var session = RewriteAutoFixTests.Session(new(reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "x")), editor: editor);
        ConfigureVoices(session, h, runner);
        return session;
    }

    /// <summary>Connects <paramref name="session"/> to the harness's Voice Lab, as the Editor does.</summary>
    internal static void ConfigureVoices(RewriteSession session, Harness h, RewriteAutoFixTests.Runner runner)
    {
        session.ConfigureVideoVoice(h.Session, () => session.Project.Media.Source.AbsolutePath);
        session.ConfigureGenerationFactory(index => new(runner,
            _ => Task.FromResult(new RewriteGenerationChoices(h.Backend.Records.Where(record => record.Status == VoiceConsentStatus.Active)
                .Select(record => new RewriteVoice(record.RecordId, record.VoiceName)).ToArray(), [new("eleven_v4", "Eleven v4", ["en"], true, false, 5000, 1)])),
            (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed, true,
                (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), ct, index),
            _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent));
    }

    private static RewriteAutoFixTests.Runner Takes() => new((_, _) => (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed));

    private static async Task PriceAsync(RewriteSession session)
    {
        await session.DiscoverWindowsAsync();
        foreach (var window in session.GenerationWindows) await window.PendingUpdate;
    }

    private static async Task MakeTakesAsync(RewriteSession session)
    {
        await PriceAsync(session);
        var batch = session.PreparedBatch!;
        session.MarkBatchEstimateShown(batch);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
    }

    /// <summary>design.md R2: the question once, inline, with its two answers and what is sent; Match this video is the approval, and the
    /// video's voice is made before any phrase is priced, so the takes use it.</summary>
    [Fact]
    public async Task TheCardAsksThenMatchThisVideoMakesTheVoiceAndEveryTakeUsesIt()
    {
        using var h = new Harness();
        await h.LoadAsync();
        var runner = Takes();
        using var session = Rewrite(h, Video("car"), runner);
        Assert.True(await RewriteAutoFixTests.ProposeAsync(session));
        await session.WordingFitWork;
        var card = session.NextStepCards[0];
        Assert.Equal(RewriteSession.VideoVoiceCardId, card.Id);
        Assert.Equal("Make a matching voice from this video? Your takes will sound like this recording. The previous video's voice is removed. Only your clearest speech from this video is sent to ElevenLabs; no video.", card.Sentence);
        Assert.Equal(["Match this video · free", "Use siim"], card.Chips.Select(chip => chip.Label));
        Assert.False(card.Asks);
        Assert.All(card.Chips, chip => Assert.NotNull(chip.Invoke));
        Assert.Empty(h.Backend.Calls);
        await card.Chips[0].Invoke!();
        Assert.True(h.Backend.Match);
        Assert.Equal("Matching voice on. Making a voice from this video.", session.AutoFix.Announcement);
        var voice = Assert.Single(h.Session.PerVideoBook.Videos).RecordId;
        await PriceAsync(session);
        // The price shown, and approved, is for takes in the video's own voice.
        Assert.Equal(voice, Assert.Single(session.PreparedBatch!.Windows).Input.RecordId);
        await MakeTakesAsync(session);
        Assert.Equal(voice, session.GenerationWindows.Single().VoiceId);
        Assert.Equal(voice, runner.Input!.RecordId);
        Assert.DoesNotContain(session.NextStepCards, step => step.Id == RewriteSession.VideoVoiceCardId);
        Assert.Single(h.Backend.Created);
    }

    /// <summary>Get Price with the stored answer "match": the voice is made first, so the only quote is with it; the next video makes its own
    /// and removes the first; a video with paid takes keeps its voice.</summary>
    [Fact]
    public async Task GetPriceMakesTheVoiceFirstAndTheNextVideoRemovesThePreviousOne()
    {
        using var h = new Harness();
        await h.LoadAsync();
        h.Backend.Match = true;
        var car = Takes();
        using (var session = Rewrite(h, Video("car"), car))
        {
            Assert.True(await RewriteAutoFixTests.ProposeAsync(session));
            Assert.DoesNotContain(session.NextStepCards, step => step.Id == RewriteSession.VideoVoiceCardId);
            await PriceAsync(session);
            var made = h.Session.PerVideoBook.VideoFor("car-key")!.RecordId;
            Assert.Equal((made, 1), (car.Input!.RecordId, car.Prepares));
            Assert.NotNull(session.PreparedBatch);
        }
        var carVoice = h.Session.PerVideoBook.VideoFor("car-key")!.RecordId;
        var kitchen = Takes();
        using var next = Rewrite(h, Video("kitchen"), kitchen);
        Assert.True(await RewriteAutoFixTests.ProposeAsync(next));
        await PriceAsync(next);
        var kitchenVoice = h.Session.PerVideoBook.VideoFor("kitchen-key")!.RecordId;
        Assert.Equal(kitchenVoice, kitchen.Input!.RecordId);
        Assert.Equal([carVoice], h.Backend.Deleted);
        Assert.Equal(2, h.Backend.Created.Count);
    }

    [Fact]
    public async Task UseTheAnchorIsRememberedAndTheTakesUseIt()
    {
        using var h = new Harness();
        await h.LoadAsync();
        var runner = Takes();
        using var session = Rewrite(h, Video("car"), runner);
        Assert.True(await RewriteAutoFixTests.ProposeAsync(session));
        await session.NextStepCards[0].Chips.Single(chip => chip.Id == RewriteSession.VideoVoiceAnchorChip).Invoke!();
        Assert.False(h.Backend.Match);
        Assert.DoesNotContain(session.NextStepCards, step => step.Id == RewriteSession.VideoVoiceCardId);
        await PriceAsync(session);
        Assert.Equal(h.Anchor.RecordId, runner.Input!.RecordId);
        Assert.Empty(h.Backend.Calls);
    }

    /// <summary>✦ Make it postable (and so ✦ Claude does it all) never presses the card: unset, it goes on with the anchor; with the stored
    /// answer it makes the video's voice first, as a manual Get Price does, and is never asked.</summary>
    [Fact]
    public async Task MakeItPostableNeverPressesTheCardAndHonoursTheStoredAnswer()
    {
        using var h = new Harness();
        await h.LoadAsync();
        async Task<(MakeItRewriteOutcome Outcome, MakeItRewriteDriver Driver, RewriteAutoFixTests.Runner Runner)> RunAsync(string name)
        {
            var editor = new EditorViewModel(Video(name), now: () => new DateTimeOffset(2026, 11, 6, 0, 0, 0, TimeSpan.Zero));
            var runner = Takes();
            RewriteSession? opened = null;
            var driver = new MakeItRewriteDriver(editor, new(10, 12, RewriteAutoFixTests.Reply, "c1", 5m), request =>
            {
                opened = RewriteAutoFixTests.Session(new(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "x")), request.First, request.Last, editor: editor);
                ConfigureVoices(opened, h, runner);
                return Task.FromResult<RewriteSession?>(opened);
            }, _ => Task.FromResult<VoiceLabMonthlyCap?>(null), session => session.Dispose());
            var outcome = await driver.RunAsync(CancellationToken.None);
            opened?.Dispose();
            return (outcome, driver, runner);
        }
        var unset = await RunAsync("car");
        Assert.Contains(unset.Driver.Pressed, step => step.StartsWith("Make takes", StringComparison.Ordinal));
        Assert.DoesNotContain(unset.Driver.Pressed, step => step.Contains("Match this video", StringComparison.Ordinal) || step.Contains("Use siim", StringComparison.Ordinal));
        Assert.Equal(h.Anchor.RecordId, unset.Runner.Input!.RecordId);
        Assert.Null(h.Backend.Match);
        Assert.Empty(h.Backend.Calls);
        h.Backend.Match = true;
        var matched = await RunAsync("kitchen");
        Assert.DoesNotContain(matched.Driver.Pressed, step => step.Contains("Match this video", StringComparison.Ordinal));
        Assert.Equal(h.Session.PerVideoBook.VideoFor("kitchen-key")!.RecordId, matched.Runner.Input!.RecordId);
        Assert.Single(h.Backend.Created);
    }

    [Fact]
    public async Task AFailedMakingSaysWhyKeepsTheAnchorAndTryAgainActs()
    {
        using var h = new Harness();
        await h.LoadAsync();
        h.Backend.Match = true;
        h.Backend.FailCreates = 1;
        var runner = Takes();
        using var session = Rewrite(h, Video("car"), runner);
        Assert.True(await RewriteAutoFixTests.ProposeAsync(session));
        await PriceAsync(session);
        Assert.Equal(h.Anchor.RecordId, runner.Input!.RecordId);
        var card = session.NextStepCards[0];
        Assert.Equal("Couldn't make this video's voice. Your ElevenLabs account has no free voice slot. Free one on elevenlabs.io, then try again. Takes use siim.", card.Sentence);
        Assert.Equal(["Try Again"], card.Chips.Select(chip => chip.Label));
        await card.Chips[0].Invoke!();
        var voice = h.Session.PerVideoBook.VideoFor("car-key")!.RecordId;
        Assert.Equal(voice, session.GenerationWindows[0].VoiceId);
        Assert.DoesNotContain(session.NextStepCards, step => step.Id == RewriteSession.VideoVoiceCardId);
    }

    /// <summary>The take-match diagnostic: the first paid take with the video's voice is scored against the speech beside it and kept.</summary>
    [Fact]
    public async Task TheFirstTakeIsScoredAndRecordedForTheVideo()
    {
        using var h = new Harness();
        await h.LoadAsync();
        h.Backend.Match = true;
        h.Backend.Score = 0.71;
        using var session = Rewrite(h, Video("car"), Takes());
        Assert.True(await RewriteAutoFixTests.ProposeAsync(session));
        await MakeTakesAsync(session);
        await session.VideoVoiceMatchWork;
        var measurement = Assert.Single(h.Session.PerVideoBook.Measurements);
        Assert.Equal(("car-key", "car", 0.71, (double?)null), (measurement.ContentKey, measurement.Title, measurement.VideoVoice, measurement.Anchor));
        Assert.Equal(1, h.Backend.Scored);
        Assert.Equal("car: its own voice 0.71", VoiceLabSession.MatchLine(measurement, "siim"));
    }

    /// <summary>The closed gate in Rewrite: with the stored answer "match" nothing is asked, found, made, scored or removed, and the takes
    /// use the voice they used before.</summary>
    [Fact]
    public async Task BehindTheClosedGateRewriteIsUnchanged()
    {
        using var h = new Harness();
        h.Backend.Available = false;
        await h.LoadAsync();
        h.Backend.Match = true;
        h.Backend.Score = 0.71;
        var runner = Takes();
        using var session = Rewrite(h, Video("car"), runner);
        Assert.True(await RewriteAutoFixTests.ProposeAsync(session));
        Assert.DoesNotContain(session.NextStepCards, step => step.Id == RewriteSession.VideoVoiceCardId);
        Assert.Null(session.PreferredVoiceForVideo);
        await MakeTakesAsync(session);
        await session.VideoVoiceMatchWork;
        Assert.Equal(h.Anchor.RecordId, runner.Input!.RecordId);
        Assert.Empty(h.Backend.Calls);
        Assert.Equal(0, h.Backend.Scored);
        Assert.Empty(h.Session.PerVideoBook.Measurements);
    }

    /// <summary>A Voice Lab backend for per-video voices: an attested anchor, the setting, a temporary book, scripted finds, creations that
    /// hand out a new record each, and deletions that tombstone or fail. The gate is <see cref="Available"/>.</summary>
    internal sealed class Backend : IVoiceLabBackend
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-per-video-" + Guid.NewGuid().ToString("N"));
        internal Backend(RateCalibrations calibrations, VoiceConsentRecord anchor)
        {
            Calibrations = calibrations;
            Records = [anchor];
            PerVideoStore = new(Path.Combine(root, "VoiceLab", "per-video.json"));
        }
        internal RateCalibrations Calibrations { get; }
        public bool Enabled { get; set; } = true;
        internal List<VoiceConsentRecord> Records;
        internal bool Available = true;
        internal bool? Match;
        internal bool FailDeletes;
        internal int FailCreates;
        internal double? Score;
        internal int Scored;
        internal readonly Dictionary<string, VoiceRebuildFind> Finds = [];
        internal readonly Dictionary<string, long> NotEnough = [];
        internal readonly List<string> Calls = [];
        internal readonly List<(VoiceConsentRecord Anchor, VoiceRebuildFind Found, string Name)> Created = [];
        internal readonly List<string> Deleted = [];
        internal readonly List<string> Logged = [];
        public VoicePerVideoStore? PerVideoStore { get; }
        public Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct) => Task.FromResult(new VoiceLabSnapshot(Records.ToArray(), []));
        public Task ReconcileAsync(bool force, CancellationToken ct) => Task.CompletedTask;
        public Task PersistProviderConsentAsync(CancellationToken ct) => Task.CompletedTask;
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct) => throw new InvalidOperationException();
        public Task DeleteAsync(string recordId, CancellationToken ct)
        {
            Calls.Add("delete " + recordId);
            if (FailDeletes) throw new VoiceLabException(VoiceLabErrorKind.ProviderFailure);
            Deleted.Add(recordId);
            Records = Records.Select(record => record.RecordId == recordId ? record with { Status = VoiceConsentStatus.Deleted, DeletedAt = DateTimeOffset.UtcNow } : record).ToList();
            return Task.CompletedTask;
        }
        public Task RemoveLocalAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task WithdrawAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task SaveAsync(VoiceConsentRecord record, CancellationToken ct) => throw new InvalidOperationException();
        public Task RemoveSpeakerAsync(CancellationToken ct) => throw new InvalidOperationException();
        public Task StopLookingAsync(Guid operationId, CancellationToken ct) => throw new InvalidOperationException();
        public bool LearningAvailable(string language) => Enabled && Available;
        public string? RewriteVoice() => null;
        public bool? MatchEachVideo() => Match;
        public Task SetMatchEachVideoAsync(bool? value, CancellationToken ct) { Match = value; return Task.CompletedTask; }
        public string? VideoVoicePrice() => "free";
        public Task<VoiceRebuildFind> FindVideoVoiceAsync(string anchorId, VoiceLabProjectSource source, CancellationToken ct)
        {
            var key = source.Project.Media.Source.ContentKey;
            Calls.Add("find " + key);
            if (!Available) throw new VoiceRebuildFailedException(VoiceRebuildFailureKind.Unavailable);
            if (NotEnough.TryGetValue(key, out var little)) throw new VoiceRebuildNotEnoughException(little, 0);
            return Task.FromResult(Finds.GetValueOrDefault(key) ?? new($"40 s from 1 video and your consent clip", [27.72, 20, 20], new object(), VideoMilliseconds: 40_000));
        }
        public Task<VoiceRebuildCreated> CreateVideoVoiceAsync(VoiceConsentRecord anchor, VoiceRebuildFind found, string displayName, CancellationToken ct)
        {
            Calls.Add("create " + displayName);
            if (!Available) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            if (FailCreates > 0) { FailCreates--; throw new VoiceLabException(VoiceLabErrorKind.NoVoiceSlots); }
            Created.Add((anchor, found, displayName));
            var record = anchor with { RecordId = Guid.NewGuid().ToString("D"), VoiceId = "videoVoice" + Created.Count, VoiceName = displayName + " (VoxClip)" };
            Records.Add(record);
            return Task.FromResult(new VoiceRebuildCreated(record, 0));
        }
        public void SeedRateCalibration(string fromRecordId, string toRecordId) => Calibrations.Seed(fromRecordId, toRecordId);
        public void Log(string message) => Logged.Add(message);
        public Task<double?> ScoreTakeMatchAsync(VoiceLabTakeAudio take, VoiceLabTakeInput input, CancellationToken ct)
        {
            if (!Available) return Task.FromResult<double?>(null);
            Scored++;
            return Task.FromResult(Score);
        }
        internal void Clean() { try { Directory.Delete(root, true); } catch (DirectoryNotFoundException) { } }
    }

    internal sealed class Harness : IDisposable
    {
        internal Harness(TimeProvider? clock = null)
        {
            Anchor = VideoVoiceFlowTests.Anchor();
            Calibrations = new(null);
            Backend = new(Calibrations, Anchor);
            Session = new(Backend, Dispatch, clock);
        }
        internal VoiceConsentRecord Anchor { get; }
        internal RateCalibrations Calibrations { get; }
        internal Backend Backend { get; }
        internal VoiceLabSession Session { get; }
        internal Task LoadAsync() => Session.RefreshEnabledStateAsync();
        public void Dispose() { Session.Dispose(); Backend.Clean(); }
    }
}
#endif

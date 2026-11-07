#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Media.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.VideoVoiceFlowTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The anchor's baseline from its earlier takes in the App (voice-lab.md §6.13 item 9; Mac <c>VideoVoiceFlowTests</c>' +4 and
/// <c>VoiceLabSession+AnchorBaseline</c>): measured once per anchor and speaker model, kept in the book, shown in Settings › Voices, dropped on a
/// model change, started by the first take with a video's own voice and not by an anchor take, one measurement at a time, and inert behind the
/// closed parity gate. The Media tests read the projects, the media and the paid files; here the backend is a stub and nothing is sent.</summary>
public sealed class AnchorBaselineFlowTests
{
    private static Harness Ready(out string anchorId)
    {
        var h = new Harness();
        anchorId = h.Anchor.RecordId;
        h.Session.AnchorBaselineProjects = () => ["/projects/one.voxclip", "/projects/two.voxclip"];
        return h;
    }

    [Fact]
    public async Task TheBaselineIsMeasuredOnceKeptInTheBookAndShownInSettings()
    {
        using var h = Ready(out var anchor);
        await h.LoadAsync();
        var release = new TaskCompletionSource<VoiceAnchorBaseline.Result?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var asked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        h.Backend.Baseline = (_, _) => { asked.TrySetResult(); return release.Task; };
        Assert.Null(h.Session.AnchorBaselineLine);
        var measuring = h.Session.MeasureAnchorBaselineAsync();
        await asked.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        // One measurement at a time: a second ask while it runs is the same measurement.
        Assert.Same(measuring, h.Session.MeasureAnchorBaselineAsync());
        Assert.True(h.Session.MeasuringAnchorBaseline);
        Assert.Equal("Measuring siim's earlier takes…", h.Session.AnchorBaselineLine);
        release.SetResult(new([0.50, 0.58]));
        await measuring;
        var (projects, measuredAnchor, language) = Assert.Single(h.Backend.BaselineMeasured);
        Assert.Equal(["/projects/one.voxclip", "/projects/two.voxclip"], projects);
        Assert.Equal((anchor, "en"), (measuredAnchor, language));
        var stored = h.Session.PerVideoBook.AnchorBaseline!;
        Assert.Equal((anchor, "speaker-model-1", 2), (stored.AnchorId, stored.Model, stored.Takes));
        Assert.Equal(0.54, stored.Score!.Value, 10);
        Assert.False(h.Session.MeasuringAnchorBaseline);
        Assert.Equal("siim · 0.54 across 2 earlier takes", h.Session.AnchorBaselineLine);
        Assert.Equal(h.Session.PerVideoBook, await h.Backend.PerVideoStore!.LoadAsync(TestContext.Current.CancellationToken));
        Assert.Contains("per-video anchor baseline takes=2 score=0.540 model=speaker-model-1 projects=2", h.Backend.Logged);
        // Kept: the same anchor and model are not measured again.
        await h.Session.MeasureAnchorBaselineAsync();
        Assert.Single(h.Backend.BaselineMeasured);
        // The copy: one take, none, and another anchor's numbers.
        Assert.Equal("siim · 0.81 across 1 earlier take", VoiceLabSession.BaselineLine(new(anchor, "m", 0.81, 1, ""), false, anchor, "siim"));
        Assert.Equal("No earlier takes of siim on this PC to compare with.", VoiceLabSession.BaselineLine(new(anchor, "m", null, 0, ""), false, anchor, "siim"));
        Assert.Null(VoiceLabSession.BaselineLine(new(anchor, "m", 0.81, 1, ""), false, "another", "siim"));
        Assert.Null(VoiceLabSession.BaselineLine(null, false, anchor, "siim"));
    }

    [Fact]
    public async Task ABaselineFromAnotherModelIsDroppedAndMeasuredAgain()
    {
        using var h = Ready(out var anchor);
        await h.Backend.PerVideoStore!.UpdateAsync(book => book with { AnchorBaseline = new(anchor, "older-model", 0.3, 4, "2026-11-01T10:00:00Z") },
            TestContext.Current.CancellationToken);
        await h.LoadAsync();
        Assert.Equal("older-model", h.Session.PerVideoBook.AnchorBaseline?.Model);
        var release = new TaskCompletionSource<VoiceAnchorBaseline.Result?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var asked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        h.Backend.Baseline = (_, _) => { asked.TrySetResult(); return release.Task; };
        var measuring = h.Session.MeasureAnchorBaselineAsync();
        await asked.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        // Dropped before it is measured again: another model's numbers don't compare.
        Assert.Null(h.Session.PerVideoBook.AnchorBaseline);
        Assert.Null((await h.Backend.PerVideoStore.LoadAsync(TestContext.Current.CancellationToken)).AnchorBaseline);
        release.SetResult(new([]));
        await measuring;
        Assert.Equal((anchor, "speaker-model-1", (double?)null, 0), (h.Session.PerVideoBook.AnchorBaseline!.AnchorId, h.Session.PerVideoBook.AnchorBaseline.Model,
            h.Session.PerVideoBook.AnchorBaseline.Score, h.Session.PerVideoBook.AnchorBaseline.Takes));
        Assert.Equal("No earlier takes of siim on this PC to compare with.", h.Session.AnchorBaselineLine);
        Assert.Contains("per-video anchor baseline takes=0 score=none model=speaker-model-1 projects=2", h.Backend.Logged);
    }

    [Fact]
    public async Task TheFirstTakeWithAVideosOwnVoiceStartsItAndAnAnchorTakeDoesNot()
    {
        using var h = Ready(out _);
        h.Backend.Baseline = (_, _) => Task.FromResult<VoiceAnchorBaseline.Result?>(new([0.54]));
        await h.LoadAsync();
        await h.Session.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);
        var state = h.Session.MakeVideoVoice(Video("car"), "/videos/car.mp4");
        await state.Work;
        await h.Session.RecordTakeMatchAsync("car-key", "car", h.Anchor.RecordId, 0.50);
        Assert.Empty(h.Backend.BaselineMeasured);
        await h.Session.RecordTakeMatchAsync("car-key", "car", state.RecordId!, 0.71);
        // The take started it; awaiting returns that same measurement, which asks nothing more.
        Assert.Single(h.Backend.BaselineMeasured);
        await h.Session.MeasureAnchorBaselineAsync();
        Assert.Single(h.Backend.BaselineMeasured);
        Assert.Contains("per-video match compared video=car-key own=0.710 anchor_baseline=0.540 earlier_takes=1", h.Backend.Logged);
        Assert.True(VoiceLabSession.ShowsComparison(h.Session.PerVideoBook));
        Assert.Equal("siim · 0.54 across 1 earlier take", h.Session.AnchorBaselineLine);
    }

    [Fact]
    public async Task AnEmptyMeasurementIsNotAskedAgainForTheSameAnchorAndModel()
    {
        using var h = Ready(out _);
        await h.LoadAsync();
        // The backend read nothing (no projects could be opened): Settings rebuilds on every change, so it isn't asked again.
        await h.Session.MeasureAnchorBaselineAsync();
        await h.Session.MeasureAnchorBaselineAsync();
        Assert.Single(h.Backend.BaselineMeasured);
        Assert.Null(h.Session.PerVideoBook.AnchorBaseline);
        Assert.Null(h.Session.AnchorBaselineLine);
        // A new speaker model is asked again.
        h.Backend.SpeakerModelId = "speaker-model-2";
        await h.Session.MeasureAnchorBaselineAsync();
        Assert.Equal(2, h.Backend.BaselineMeasured.Count);
    }

    [Fact]
    public async Task BehindTheClosedGateNothingIsMeasuredOrShown()
    {
        using var h = Ready(out _);
        h.Backend.Available = false;
        h.Backend.Baseline = (_, _) => throw new InvalidOperationException("nothing is read behind the gate");
        await h.LoadAsync();
        await h.Session.MeasureAnchorBaselineAsync();
        Assert.Empty(h.Backend.BaselineMeasured);
        Assert.False(h.Session.MeasuringAnchorBaseline);
        Assert.Null(h.Session.AnchorBaselineLine);
        Assert.Null(h.Session.PerVideoBook.AnchorBaseline);
        // The shipping backend: no speaker model, and the measurement returns before any project is read.
        var root = Path.Combine(Path.GetTempPath(), "voxclip-anchor-baseline-backend-" + Guid.NewGuid().ToString("N"));
        try
        {
            var locations = new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "Models"), Path.Combine(root, "cache"),
                Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs"));
            var reads = 0;
            using var backend = new VoxClip.App.Services.VoiceLabBackend(locations, new BaselineNoKeys(), new BaselineQuietLog(), () => true,
                () => VoxClip.Core.Services.Speech.ElevenLabsRegion.Default, _ => Task.CompletedTask,
                readProject: (_, _) => { reads++; return Task.FromResult<VoiceLabProjectSource?>(null); });
            IVoiceLabBackend shipping = backend;
            Assert.Null(shipping.SpeakerModel("en"));
            Assert.Null(await shipping.MeasureAnchorBaselineAsync(["/projects/one.voxclip"], h.Anchor.RecordId, "en", CancellationToken.None));
            Assert.Equal(0, reads);
            Assert.False(Directory.Exists(Path.Combine(root, "VoiceLab")) && Directory.EnumerateFileSystemEntries(Path.Combine(root, "VoiceLab")).Any());
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private sealed class BaselineNoKeys : VoxClip.Core.Services.LLM.IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => throw new InvalidOperationException("No key reads allowed");
    }

    private sealed class BaselineQuietLog : VoxClip.Core.Services.Logging.ILog
    {
        public void RegisterSecret(string secret) { }
        public void Write(VoxClip.Core.Services.Logging.LogLevel level, string category, string message) { }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
#endif

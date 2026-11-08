using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.Captions;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>A local engine stand-in: it hears <see cref="Words"/> (output seconds) and keeps what it was handed, read back as Whisper
/// reads it.</summary>
internal sealed class StubHearing(IReadOnlyList<ExportCheckHeard> words, Exception? failure = null) : ITranscriber
{
    internal IReadOnlyList<ExportCheckHeard> Words { get; } = words;
    internal List<(ExtractedAudio Audio, float[] Samples)> Received { get; } = [];
    public TranscriptEngine Engine => TranscriptEngine.Whispercpp;
    public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.TokenGrouped, false, true, null, null, true);
    public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromResult(true);
    public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(new Readiness.Ready());
    public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
    public async Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
    {
        Received.Add((request.Audio, await WhisperAudio.ReadAsync(request.Audio, ct)));
        if (failure is not null) throw failure;
        var tokens = Words.Select((word, index) => new RawToken(word.Text, false, word.Start, word.End, 0.9, null, null, index)).ToArray();
        return new(new(TranscriptEngine.Whispercpp, "stub", null, "stub", null), 1, new(GroupingEnd.LastToken, GroupingConfidence.Mean, true),
            tokens, "en", null, false, TimingSource.TokenGrouped, null);
    }

    internal static (StubHearing Stub, ExportChecker.Hearing Hearing) Make(IReadOnlyList<ExportCheckHeard> words, Exception? failure = null)
    {
        var stub = new StubHearing(words, failure);
        return (stub, new(stub, new(TranscriptEngine.Whispercpp, "stub", new LanguageChoice.Forced("en"), new())));
    }
}

/// <summary>An exported file in memory: its tracks' ranges, its frame and its interleaved audio. Like the FFmpeg decoder, it pads
/// with silence past the end and never returns 0.</summary>
internal sealed class SyntheticExport(ExportCheckTrack? video, ExportCheckTrack? audio, float[] interleaved, int rate = 48_000, int channels = 2,
    double? frameRate = 30, PixelSize? frame = null) : IExportFile
{
    private long position;
    public ExportCheckTrack? Video => video;
    public ExportCheckTrack? Audio => audio;
    public double? FrameRate => video is null ? null : frameRate;
    public PixelSize? Frame => video is null ? null : frame ?? new PixelSize(1920, 1080);
    public int SampleRate => rate;
    public int Channels => channels;
    internal bool Disposed { get; private set; }

    public int Read(Span<float> target, int frames, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var start = (int)Math.Min(interleaved.Length, position * channels);
        var count = Math.Min(frames * channels, interleaved.Length - start);
        interleaved.AsSpan(start, count).CopyTo(target);
        target[count..(frames * channels)].Clear();
        position += frames;
        return frames;
    }

    public void Dispose() => Disposed = true;

    /// <summary>Speech-like stereo bursts, <paramref name="seconds"/> long, gained to <paramref name="lufs"/> by the ADR-R47 meter.</summary>
    internal static float[] Speech(double seconds, double lufs, int rate = 48_000)
    {
        var frames = (int)Math.Round(seconds * rate);
        var samples = new float[frames * 2];
        for (var index = 0; index < frames; index++)
        {
            var time = index / (double)rate;
            var envelope = 0.5 + 0.5 * Math.Sin(2 * Math.PI * 3 * time);
            var value = (float)(envelope * (0.3 * Math.Sin(2 * Math.PI * 220 * time) + 0.15 * Math.Sin(2 * Math.PI * 660 * time)));
            samples[index * 2] = value; samples[index * 2 + 1] = value;
        }
        var meter = new SocialLoudnessMeter(rate, 2);
        meter.Append(samples);
        var gain = (float)Math.Pow(10, (lufs - meter.Finish().IntegratedLufs()!.Value) / 20);
        for (var index = 0; index < samples.Length; index++) samples[index] *= gain;
        return samples;
    }
}

/// <summary>The export self-check (ADR-R49) on a synthetic export with a stub engine in place of the local model, and the caption and
/// title boxes from the renderer's own layout. Twin of the Mac ExportCheckerTests and ExportCheckPlacementTests.</summary>
public sealed class ExportCheckerTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("voxclip-export-check-").FullName;

    public void Dispose() { try { Directory.Delete(directory, true); } catch (IOException) { } }

    /// <summary>"We ship clipper today, and it shows you." in output seconds, with one cut between "ship" and "clipper".</summary>
    private static ExportCheckExpectation.Edit Edit() => new(
        new[] { "We", "ship", "clipper", "today,", "and", "it", "shows", "you." }
            .Select((text, index) => new ExportCheckWord(text, 0.8 + index * 0.42, 1.1 + index * 0.42)).ToArray(), [], [1.6], 6);

    private static ComposeSnapshot Snapshot(PixelSize size, CaptionTrack? captions = null, ClipEffectsRenderInput? effects = null)
    {
        const long total = 288_000;
        var media = new MediaInfo("/dev/null", 6, new(size.Width, size.Height, 30, 0), new(48_000, 2), size, "h264", "aac", false, 0, 1, 0);
        var plan = new EditPlan(48_000, total, [], [new(0, total)], total, []);
        return new ComposeSnapshot(media, plan, captions, new OutputSpec(size, 30, 4_000_000))
        { Clip = effects is null ? null : new ClipRenderInput(null, effects) };
    }

    private ExportChecker Checker(ExportChecker.Hearing? hearing, IExportFile file) => new(hearing, directory, FixtureLoader.SharedRoot, (_, _) => file);

    private static IReadOnlyList<ExportCheckHeard> AsHeard(IEnumerable<ExportCheckWord> words) => words.Select(word => new ExportCheckHeard(word.Text, word.Start, word.End)).ToArray();

    [Fact]
    public async Task TheCheckerMeasuresTheExportAndComparesWhatItHears()
    {
        var ct = TestContext.Current.CancellationToken;
        var edit = Edit();
        var file = new SyntheticExport(new(0, 6), new(0, 6), SyntheticExport.Speech(6, -14));
        var (stub, hearing) = StubHearing.Make(AsHeard(edit.Words));
        var outcome = await Checker(hearing, file).CheckAsync("clip.mp4", Snapshot(new(1920, 1080)), edit, ExportLoudness.Social, ct);
        var report = outcome.Report;
        Assert.True(report.Passed, string.Join("; ", report.Results));
        var words = report[ExportCheckKind.Words]!;
        Assert.Equal((ExportCheckStatus.Ok, 8, 8), (words.Status, words.Matched, words.Total));
        var sync = report[ExportCheckKind.Sync]!;
        Assert.Equal((ExportCheckStatus.Ok, 0.0, 0.0), (sync.Status, sync.StartOffset, sync.EndOffset));
        var loudness = report[ExportCheckKind.Loudness]!;
        Assert.Equal(ExportCheckStatus.Ok, loudness.Status);
        Assert.InRange(loudness.IntegratedLufs!.Value, -14.05, -13.95);
        Assert.Equal(ExportCheckStatus.Skipped, report[ExportCheckKind.Captions]!.Status);
        // The engine was handed the export's own audio as 16 kHz mono PCM16 that Whisper reads, its length; the copy is removed.
        var (audio, samples) = Assert.Single(stub.Received);
        Assert.Equal(96_000, audio.SampleCount);
        Assert.Equal(6, audio.DurationSeconds, 9);
        Assert.Equal(96_000, samples.Length);
        Assert.InRange(samples.Max(Math.Abs), 0.05f, 1f);
        Assert.False(File.Exists(audio.Wav16kPath));
        Assert.Empty(Directory.GetFiles(directory));
        Assert.Equal((TranscriptEngine.Whispercpp, "stub"), (outcome.Engine!.Value, outcome.Model));
        Assert.True(file.Disposed);
    }

    [Fact]
    public async Task AMisheardWordIsAMismatchAndAMissingLastWordIsCutOff()
    {
        var ct = TestContext.Current.CancellationToken;
        var edit = Edit();
        var heard = AsHeard(edit.Words.SkipLast(1)).ToArray();
        heard[1] = heard[1] with { Text = "chip" };
        var (_, hearing) = StubHearing.Make(heard);
        var outcome = await Checker(hearing, new SyntheticExport(new(0, 6), new(0, 6), SyntheticExport.Speech(6, -14)))
            .CheckAsync("clip.mp4", Snapshot(new(1920, 1080)), edit, ExportLoudness.Social, ct);
        var words = outcome.Report[ExportCheckKind.Words]!;
        Assert.False(outcome.Report.Passed);
        Assert.Equal(ExportCheckStatus.Warning, words.Status);
        Assert.Equal([ExportCheckItemKind.Mismatch, ExportCheckItemKind.CutOff], words.Items.Select(item => item.Kind));
        Assert.Equal(["ship", "you."], words.Items.Select(item => item.Expected));
        Assert.Equal("chip", words.Items[0].Heard);
        Assert.Equal(edit.Words[1].Start, words.Items[0].Time, 9);
    }

    [Fact]
    public async Task AudioOverhangingThePictureByHalfASecondFailsSync()
    {
        var file = new SyntheticExport(new(0, 2), new(0, 2.5), SyntheticExport.Speech(2.5, -14));
        var outcome = await Checker(null, file).CheckAsync("overhang.mp4", Snapshot(new(320, 180)), new([], [], [], 2), ExportLoudness.Off,
            TestContext.Current.CancellationToken);
        var sync = outcome.Report[ExportCheckKind.Sync]!;
        Assert.Equal(ExportCheckStatus.Warning, sync.Status);
        Assert.Equal([ExportCheckItemKind.TrackEnd], sync.Items.Select(item => item.Kind));
        Assert.Equal(0.5, sync.EndOffset!.Value, 9);
        Assert.Equal(1 / 30.0, sync.Items[0].Limit!.Value, 12);
    }

    [Fact]
    public async Task WithoutAnEngineTheWordsAreSkippedAndLoudnessOffIsSkipped()
    {
        var outcome = await Checker(null, new SyntheticExport(new(0, 6), new(0, 6), SyntheticExport.Speech(6, -20)))
            .CheckAsync("clip.mp4", Snapshot(new(1920, 1080)), Edit(), ExportLoudness.Off, TestContext.Current.CancellationToken);
        var report = outcome.Report;
        Assert.Equal((ExportCheckStatus.Skipped, "No local transcription model"), (report[ExportCheckKind.Words]!.Status, report[ExportCheckKind.Words]!.Reason));
        Assert.Equal((ExportCheckStatus.Skipped, "Loudness is off for this export"), (report[ExportCheckKind.Loudness]!.Status, report[ExportCheckKind.Loudness]!.Reason));
        Assert.True(report.Passed);
        Assert.Equal((0.0, (TranscriptEngine?)null, (string?)null), (outcome.HearSeconds, outcome.Engine, outcome.Model));
    }

    [Fact]
    public async Task SocialLoudnessOffTargetWarns()
    {
        var outcome = await Checker(null, new SyntheticExport(new(0, 6), new(0, 6), SyntheticExport.Speech(6, -20)))
            .CheckAsync("clip.mp4", Snapshot(new(1920, 1080)), Edit(), ExportLoudness.Social, TestContext.Current.CancellationToken);
        var loudness = outcome.Report[ExportCheckKind.Loudness]!;
        Assert.Equal(ExportCheckStatus.Warning, loudness.Status);
        Assert.Equal([ExportCheckItemKind.IntegratedLoudness], loudness.Items.Select(item => item.Kind));
        Assert.InRange(loudness.IntegratedLufs!.Value, -20.05, -19.95);
    }

    [Fact]
    public async Task AFailingEngineSkipsTheWordsOnlyAndNoAudioSkipsHearing()
    {
        var ct = TestContext.Current.CancellationToken;
        var (_, failing) = StubHearing.Make([], new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Could not load the whisper model"));
        var failed = await Checker(failing, new SyntheticExport(new(0, 6), new(0, 6), SyntheticExport.Speech(6, -14)))
            .CheckAsync("clip.mp4", Snapshot(new(1920, 1080)), Edit(), ExportLoudness.Off, ct);
        Assert.Equal((ExportCheckStatus.Skipped, "The local transcription failed"), (failed.Report[ExportCheckKind.Words]!.Status, failed.Report[ExportCheckKind.Words]!.Reason));
        Assert.Equal(ExportCheckStatus.Ok, failed.Report[ExportCheckKind.Sync]!.Status);
        Assert.Null(failed.Engine);
        // A cancelled engine cancels the check.
        var (_, cancelled) = StubHearing.Make([], new OperationCanceledException());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Checker(cancelled, new SyntheticExport(new(0, 6), new(0, 6), SyntheticExport.Speech(6, -14)))
            .CheckAsync("clip.mp4", Snapshot(new(1920, 1080)), Edit(), ExportLoudness.Off, ct));
        // A picture-only export: nothing to hear, nothing to meter.
        var (stub, hearing) = StubHearing.Make([]);
        var silent = await Checker(hearing, new SyntheticExport(new(0, 6), null, []))
            .CheckAsync("clip.mp4", Snapshot(new(1920, 1080)), Edit(), ExportLoudness.Social, ct);
        Assert.Equal("No audio track", silent.Report[ExportCheckKind.Words]!.Reason);
        Assert.Equal("No audio track", silent.Report[ExportCheckKind.Loudness]!.Reason);
        Assert.Equal("No audio track", silent.Report[ExportCheckKind.Sync]!.Reason);
        Assert.Empty(stub.Received);
    }

    [Fact]
    public async Task TheFramesOwnSizePicksTheBands()
    {
        // A 9:16 render whose file reports 9:16 checks against 9:16's bands even when the snapshot was another shape.
        var file = new SyntheticExport(new(0, 6), new(0, 6), SyntheticExport.Speech(6, -14), frame: new PixelSize(1080, 1920), frameRate: 25);
        var title = new ClipEffect("fx-hook-1", "clip", "title", 0, 2) { Text = "We ship every week", Position = "top" };
        var snapshot = Snapshot(new(1080, 1920), effects: new([title], new Dictionary<string, string>()));
        var outcome = await Checker(null, file).CheckAsync("clip.mp4", snapshot, new([], [], [], 6), ExportLoudness.Off, TestContext.Current.CancellationToken);
        Assert.Equal(ExportCheckStatus.Ok, outcome.Report[ExportCheckKind.Captions]!.Status);
        Assert.Equal(ExportCheckStatus.Ok, outcome.Report[ExportCheckKind.Sync]!.Status);
    }

    // Caption and title boxes on the renderer's own layout.

    private static readonly string[] Hooks = ["We ship every week", "This is the one change that made our whole team ship a clipper every single week"];

    private static CaptionStyle Style(string id) => JsonSerializer.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "caption-styles", "styles", id + ".json")),
        ProjectJsonContext.Default.CaptionStyle)!;

    /// <summary>Each caption card of <paramref name="id"/> on <paramref name="size"/>, laid out as the export lays it out: at the
    /// style's default position for the shape, or at a dragged <paramref name="position"/>.</summary>
    private static async Task<IReadOnlyList<ExportCheckBox>> CaptionBoxes(string id, PixelSize size, CaptionPosition? position = null)
    {
        var words = "so this is how we ship the clipper every single week".Split(' ')
            .Select((text, index) => new CaptionWord("w" + index, text, index * 0.4, index * 0.4 + 0.35)).ToArray();
        var captions = new ProjectCaptions(id, JsonDocument.Parse("{}").RootElement.Clone(), position, new Dictionary<string, CaptionPosition>());
        var track = await CaptionEngine.BuildAsync(new(Style(id), captions, size, words, "en", words.Length * 0.4 + 1),
            new HarfBuzzGlyphShaper(FixtureLoader.SharedRoot), null, TestContext.Current.CancellationToken);
        var boxes = ExportCheckExpectation.CaptionBoxes(track, size, new ClipSpeedTiming(1));
        Assert.Equal(track.Pages.Count, boxes.Count);
        Assert.NotEmpty(boxes);
        return boxes;
    }

    private static ExportCheckResult Captions(IReadOnlyList<ExportCheckBox> boxes, PixelSize size) =>
        ExportCheck.Run(new([], null, null, null, 1 / 30.0, null, size) { Boxes = boxes })[ExportCheckKind.Captions]!;

    [Fact]
    public async Task ThePortraitDefaultCaptionAndTitleClearTheBands()
    {
        var portrait = new PixelSize(1080, 1920);
        var caption = Captions(await CaptionBoxes("vox-highlight", portrait), portrait);
        Assert.True(caption.Status == ExportCheckStatus.Ok, string.Join("; ", caption.Items));
        foreach (var hook in Hooks)
        {
            var title = new ClipEffect("fx-hook-1", "clip", "title", 0, 2) { Text = hook, Position = "top" };
            var boxes = ExportChecker.TitleBoxes(Snapshot(portrait, effects: new([title], new Dictionary<string, string>())), FixtureLoader.SharedRoot);
            var box = Assert.Single(boxes);
            Assert.Equal(ExportCheckBoxKind.Title, box.Kind);
            Assert.Equal(250.0 / 1920, box.Rect.Y, 9);
            Assert.True(Captions(boxes, portrait).Status == ExportCheckStatus.Ok, $"{hook}: {box.Rect}");
        }
    }

    [Fact]
    public async Task ACaptionDraggedIntoTheBottomBandWarnsOnceForItsCards()
    {
        var portrait = new PixelSize(1080, 1920);
        var boxes = await CaptionBoxes("vox-highlight", portrait, new CaptionPosition(0.5, 0.9));
        var result = Captions(boxes, portrait);
        Assert.Equal(ExportCheckStatus.Warning, result.Status);
        Assert.All(result.Items, item => Assert.Equal((ExportCheckItemKind.CaptionBand, CaptionSafeZones.Edge.Bottom), (item.Kind, item.Band!.Value)));
        // Cards at one place make one finding with their count.
        Assert.Equal(boxes.Count, result.Items.Sum(item => item.Count ?? 1));
        Assert.True(result.Items.Count < boxes.Count);
        Assert.Equal(boxes[0].Time, result.Items[0].Time);
    }

    [Fact]
    public void ATitleAtTheTopOfASquareFrameMapsItsSourceTimeThroughTheTimeline()
    {
        var title = new ClipEffect("fx-hook-1", "clip", "title", 1.5, 3) { Text = "We ship every week", Position = "top" };
        var snapshot = Snapshot(new(1080, 1080), effects: new([title], new Dictionary<string, string>()));
        snapshot = snapshot with { Clip = snapshot.Clip! with { Controls = new ProjectClipControls("clip", 1.5, null, ClipLook.Original, 0, 0, 0, false, false, 0) } };
        var box = Assert.Single(ExportChecker.TitleBoxes(snapshot, FixtureLoader.SharedRoot));
        Assert.Equal(1, box.Time, 9);
        Assert.Empty(ExportChecker.TitleBoxes(Snapshot(new(1080, 1080), effects: new([title with { Text = "" }], new Dictionary<string, string>())), FixtureLoader.SharedRoot));
        Assert.Empty(ExportChecker.TitleBoxes(snapshot, null));
    }
}

/// <summary>The FFmpeg reader on a real file (VM): unequal-duration.mp4 has 4.1 s of 30 fps picture and 4.01 s of AAC sine.</summary>
[Trait("Category", "RequiresFFmpeg")]
public sealed class NativeExportCheckerTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync();
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Fact]
    public async Task TheFfmpegReaderMeasuresARealFilesTracksAndHearsItsAudio()
    {
        var ct = TestContext.Current.CancellationToken;
        var path = NativeTest.Fixture("unequal-duration.mp4");
        using (var file = FfmpegExportFile.Open(path, ct))
        {
            Assert.InRange(file.Video!.End - file.Video.Start, 4.06, 4.14);
            Assert.InRange(file.Audio!.End - file.Audio.Start, 3.98, 4.04);
            Assert.InRange(file.Video.Start, -0.001, 0.05);
            Assert.Equal((30.0, new PixelSize(160, 90), 48_000), (Math.Round(file.FrameRate!.Value, 3), file.Frame!.Value, file.SampleRate));
        }
        var directory = Directory.CreateTempSubdirectory("voxclip-export-check-native-").FullName;
        try
        {
            var (stub, hearing) = StubHearing.Make([]);
            var media = new MediaInfo(path, 4.1, new(160, 90, 30, 0), new(48_000, 1), new(160, 90), "mpeg4", "aac", false, 0, 1, 0);
            var plan = new EditPlan(48_000, 196_800, [], [new(0, 196_800)], 196_800, []);
            var snapshot = new ComposeSnapshot(media, plan, null, new OutputSpec(new(160, 90), 30, 1_000_000));
            var outcome = await new ExportChecker(hearing, directory, null).CheckAsync(path, snapshot, new([], [], [], 4.1), ExportLoudness.Social, ct);
            var sync = outcome.Report[ExportCheckKind.Sync]!;
            Assert.Equal(ExportCheckStatus.Warning, sync.Status);
            Assert.Equal([ExportCheckItemKind.TrackEnd], sync.Items.Select(item => item.Kind));
            Assert.InRange(sync.EndOffset!.Value, -0.12, -0.06);
            Assert.True(double.IsFinite(outcome.Report[ExportCheckKind.Loudness]!.IntegratedLufs!.Value));
            var (audio, samples) = Assert.Single(stub.Received);
            Assert.InRange(audio.DurationSeconds, 3.98, 4.04);
            Assert.InRange(samples.Max(Math.Abs), 0.05f, 1f);
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }
}

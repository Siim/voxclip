using VoxClip.Cli;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The preview is never a silent black box (design.md §5.4.4 g; Mac <c>PreviewFramesTests</c>' failure cases). The composer's
/// after-scale stages and the engine run without FFmpeg: a caption or title that can't be drawn is left out of a preview frame and reported
/// once, an export still fails, the disclosure and a missing source frame fail the preview frame with their reason, and each loaded preview
/// reports its first reason once.</summary>
public sealed class PreviewFailureTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    private static ComposeSnapshot Snapshot(CaptionTrack? captions = null, ClipRenderInput? clip = null) => new(
        new("synthetic.mp4", 2, new(64, 36, 30, 0), null, new(64, 36), "h264", null, false, 0, -1, 0),
        TestPlan.FromKept(48_000, 96_000, [new(0, 96_000)]), captions, new(new(64, 36), 30, 1_000_000)) { Clip = clip };

    private static CaptionTrack Captions()
    {
        MeasuredCaptionWord Word(string raw) => new(0, raw, raw, raw, 0, 1, 0, 0, [], 0, false, null, null, null);
        var page = new CaptionPage(0, [0, 1], 0, 2, 64, 1, false, [new CaptionLine([0, 1], 0, 0, 0, 0, 0)], [], new(0, 0, 0, 0), new(0, 0, 0, 0),
            [], [], null, new(0, 0));
        return new(CaptionRendering.LoadStyle("vox-bold"), new(64, 36), [Word("Hello"), Word("there")], [page], 2);
    }

    private static PixelBuffer Frame(byte value = 90)
    {
        var pixels = new byte[64 * 36 * 4];
        pixels.AsSpan().Fill(value);
        return new(pixels, 64, 36, 64 * 4);
    }

    private sealed class FailingRasterizer(Exception failure) : ICaptionRasterizer
    {
        public void Draw(CaptionRenderRequest request, PixelBuffer target, CancellationToken ct) => throw failure;
        public Task<PixelBuffer> RenderAsync(CaptionRenderRequest request, CancellationToken ct) => throw failure;
    }

    private static (PreviewFrameFailures Failures, List<PreviewFailureReason> First) Sink()
    {
        var first = new List<PreviewFailureReason>();
        return (new(first.Add), first);
    }

    [Fact]
    public void ACaptionThatCantBeDrawnIsLeftOutOfThePreviewAndReportedOnce()
    {
        var composer = new FrameComposer(new FailingRasterizer(new InvalidOperationException("layout")), FixtureLoader.SharedRoot);
        var (failures, first) = Sink();
        var snapshot = Snapshot(Captions());
        foreach (var time in new[] { 0.4, 1.2 })
        {
            var frame = Frame();
            composer.DrawOverlays(frame, snapshot, time, true, failures, CancellationToken.None);
            Assert.True(frame.Pixels.Span.IndexOfAnyExcept((byte)90) < 0, "the picture is kept");
        }
        Assert.Equal([PreviewFailureReason.CaptionLayout], failures.Reasons);
        Assert.Equal([PreviewFailureReason.CaptionLayout], first);
        Assert.True(PreviewFailureReason.CaptionLayout.KeepsPicture());
    }

    [Fact]
    public void OnlyAPreviewsFirstReasonReachesItsOwnerAndLaterReasonsAreKept()
    {
        var (failures, first) = Sink();
        failures.Report(PreviewFailureReason.Title);
        failures.Report(PreviewFailureReason.CaptionLayout);
        failures.Report(PreviewFailureReason.Title);
        Assert.Equal([PreviewFailureReason.Title], first);
        Assert.Equal([PreviewFailureReason.Title, PreviewFailureReason.CaptionLayout], failures.Reasons);
    }

    [Fact]
    public void MissingCaptionFilesAreReportedAsResources()
    {
        var composer = new FrameComposer(new FailingRasterizer(new FileNotFoundException("font")), FixtureLoader.SharedRoot);
        var (failures, first) = Sink();
        composer.DrawOverlays(Frame(), Snapshot(Captions()), 0.4, true, failures, CancellationToken.None);
        Assert.Equal([PreviewFailureReason.Resources], first);
    }

    [Fact]
    public void TheSameCaptionFailureStillFailsAnExport()
    {
        var failure = new InvalidOperationException("layout");
        var composer = new FrameComposer(new FailingRasterizer(failure), FixtureLoader.SharedRoot);
        var (failures, first) = Sink();
        Assert.Same(failure, Assert.Throws<InvalidOperationException>(() => composer.DrawOverlays(Frame(), Snapshot(Captions()), 0.4, false, failures, CancellationToken.None)));
        // A preview with nobody to tell fails as before too.
        Assert.Throws<InvalidOperationException>(() => composer.DrawOverlays(Frame(), Snapshot(Captions()), 0.4, true, null, CancellationToken.None));
        Assert.Empty(first);
        Assert.Null(PreviewFailureReasons.Of(failure));
    }

    [Fact]
    public void ATitleThatCantBeDrawnIsReportedInPreviewOnly()
    {
        // Without the shared folder the title's font is missing, so the title can't be drawn.
        var composer = new FrameComposer(new TestRasterizer(), null);
        var title = new ClipEffect("fx-title-1", null, "title", 0, 4) { Text = "My first sale", Position = "top" };
        var clip = new ClipRenderInput(null, new(new[] { title }, new Dictionary<string, string>()));
        var (failures, first) = Sink();
        var frame = Frame();
        composer.FinishClipFrame(frame, Snapshot(clip: clip), 1, 64, 36, new(0, 0, 64, 36), CancellationToken.None, true, failures);
        Assert.True(frame.Pixels.Span.IndexOfAnyExcept((byte)90) < 0, "the picture is kept");
        Assert.Equal([PreviewFailureReason.Title], first);
        var (exported, exportFirst) = Sink();
        composer.FinishClipFrame(Frame(), Snapshot(clip: clip), 1, 64, 36, new(0, 0, 64, 36), CancellationToken.None, false, exported);
        Assert.Empty(exportFirst);
    }

    [Fact]
    public void ADisclosureThatCantBeDrawnStopsThePreviewFrameWithItsReason()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.True(prepared.OutputPlan.RequiresSyntheticRendering);
        var snapshot = Snapshot() with { VoiceLab = VoiceLabRenderInput.Capture(project, prepared, "/not-opened") };
        var composer = new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot);
        var (failures, first) = Sink();
        // Never prepared, so the frame can't carry its label: preview fails it, marked, and says why.
        var preview = Assert.Throws<InvalidOperationException>(() => composer.DrawOverlays(Frame(), snapshot, 0.4, true, failures, CancellationToken.None));
        Assert.Equal(PreviewFailureReason.Disclosure, PreviewFailureReasons.Of(preview));
        Assert.Equal([PreviewFailureReason.Disclosure], first);
        Assert.False(PreviewFailureReason.Disclosure.KeepsPicture());
        var export = Assert.Throws<InvalidOperationException>(() => composer.DrawOverlays(Frame(), snapshot, 0.4, false, null, CancellationToken.None));
        Assert.Null(PreviewFailureReasons.Of(export));
    }

    private sealed class Worker : IPreviewVideoWorker
    {
        public Exception? DecodeFailure { get; set; }
        public Task Ready => Task.CompletedTask;
        public double Position { get; private set; }
        public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
        {
            Position = source;
            return DecodeFailure is { } exception ? Task.FromException<PixelBuffer>(exception) : Task.FromResult(new PixelBuffer(new byte[16], 2, 2, 8));
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class Composer : IFrameComposer
    {
        public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
            => output.Pixels.Span.Clear();
    }

    [Fact]
    public async Task EachLoadedPreviewReportsItsFirstFailureOnceAndCaptionSwapsKeepTheCount()
    {
        var ct = TestContext.Current.CancellationToken;
        var worker = new Worker();
        var reported = new List<PreviewFailureReason>();
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { }, createWorker: (_, _) => worker);
        IPreviewEngine contract = preview;
        contract.CompositorFailed += (_, reason) => { lock (reported) reported.Add(reason); };
        preview.CompositorFailed += (_, _) => throw new InvalidOperationException("consumer failed");
        var snapshot = Snapshot();
        await preview.LoadAsync(snapshot, null, ct).WaitAsync(Timeout, ct);
        var error = new IOException("decode failed");
        worker.DecodeFailure = error;
        // Paused: the seek itself fails with the source frame's reason, and the preview hears it once.
        Assert.Same(error, await Assert.ThrowsAsync<IOException>(() => preview.SeekAsync(1, true, ct).WaitAsync(Timeout, ct)));
        Assert.Equal(PreviewFailureReason.SourceFrame, PreviewFailureReasons.Of(error));
        await Assert.ThrowsAsync<IOException>(() => preview.SeekAsync(1.5, true, ct).WaitAsync(Timeout, ct));
        await Assert.ThrowsAsync<IOException>(() => preview.UpdateCaptionsAsync(null, ct).WaitAsync(Timeout, ct));
        Assert.Equal([PreviewFailureReason.SourceFrame], reported);
        // A plan swap is a new preview: it reports again.
        await Assert.ThrowsAsync<IOException>(() => preview.UpdateSnapshotAsync(snapshot, ct).WaitAsync(Timeout, ct));
        Assert.Equal([PreviewFailureReason.SourceFrame, PreviewFailureReason.SourceFrame], reported);
        // Reload Preview's load: frames draw again and nothing new is reported.
        worker.DecodeFailure = null;
        await preview.LoadAsync(snapshot, null, ct).WaitAsync(Timeout, ct);
        await preview.SeekAsync(0.5, true, ct).WaitAsync(Timeout, ct);
        Assert.Equal(2, reported.Count);
        // A failure after that load is that load's own first.
        worker.DecodeFailure = new IOException("decode failed again");
        await Assert.ThrowsAsync<IOException>(() => preview.SeekAsync(1, true, ct).WaitAsync(Timeout, ct));
        Assert.Equal(3, reported.Count);
    }

    [Fact]
    public async Task APlaybackFailureCarriesItsReason()
    {
        var ct = TestContext.Current.CancellationToken;
        var worker = new Worker();
        var enabled = 0;
        var error = new IOException("decode failed");
        var fault = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
        var reason = new TaskCompletionSource<PreviewFailureReason>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { }, createWorker: (_, _) => worker, clockOverride: () =>
        {
            if (Volatile.Read(ref enabled) == 0) return 0;
            worker.DecodeFailure = error;
            return 1;
        });
        preview.PlaybackFaulted += (_, exception) => fault.TrySetResult(exception);
        preview.CompositorFailed += (_, value) => reason.TrySetResult(value);
        await preview.LoadAsync(Snapshot(), null, ct).WaitAsync(Timeout, ct);
        Volatile.Write(ref enabled, 1);
        await preview.PlayAsync(ct).WaitAsync(Timeout, ct);
        Assert.Equal(PreviewFailureReason.SourceFrame, await reason.Task.WaitAsync(Timeout, ct));
        var failed = await fault.Task.WaitAsync(Timeout, ct);
        Assert.Same(error, failed);
        Assert.Equal(PreviewFailureReason.SourceFrame, PreviewFailureReasons.Of(failed));
    }
}

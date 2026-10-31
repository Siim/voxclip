using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed class VoiceLabSilenceFitTests
{
    private const string Project = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11";
    private sealed class Storage : IDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "voxclip-fit-" + Guid.NewGuid().ToString("N"));
        internal Storage() => Directory.CreateDirectory(Root);
        public void Dispose() => Directory.Delete(Root, true);
    }
    private static JsonDocument Cases() => JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/fitted-asset-cases.json"));
    private static int Number(JsonElement row, string key) => row.GetProperty(key).GetInt32();
    private static VoiceLabWindow Window(JsonElement row, bool hard = false)
    {
        var start = row.GetProperty("windowStart").GetDouble();
        var end = row.GetProperty("windowEnd").GetDouble();
        var lower = (long)Math.Floor(start * 48000 + 0.5);
        var upper = (long)Math.Floor(end * 48000 + 0.5);
        var kind = hard ? VoiceLabSeamKind.Hard : VoiceLabSeamKind.Gap;
        return new("w4", "w5", [], [], start, end, lower, upper, new(kind, start, lower, hard ? 576 : 960), new(kind, end, upper, hard ? 576 : 960));
    }
    private static VoiceLabFitResult Fit(JsonElement row)
    {
        var window = Window(row);
        var edits = row.GetProperty("edits").EnumerateArray().Select(edit => new VoiceLabFitEdit(
            edit.GetProperty("kind").GetString() == "insert" ? VoiceLabFitEditKind.Insert : VoiceLabFitEditKind.Remove,
            Number(edit, "start"), Number(edit, "count"))).ToArray();
        var incoming = Number(row, "incomingPadFrames");
        var rate = Number(row, "rate");
        long Mapped(long frame) => incoming + frame - 2400 + edits.Where(edit => edit.Start + edit.Count <= frame)
            .Sum(edit => edit.Kind == VoiceLabFitEditKind.Insert ? edit.Count : -edit.Count);
        VoiceLabWord Word(string text, long lower, long upper) => new(text, Mapped(lower) / (double)rate, Mapped(upper) / (double)rate, true);
        var plan = new VoiceLabFitPlan(edits, new(incoming, window.Start == 2.48 ? 960 : 0), new(Number(row, "outgoingPadFrames"), 0), 2400, 19200,
            window.Start, window.End, window.StartSample, window.EndSample, Number(row.GetProperty("expected"), "outputFrames"), [Word("new", 4800, 6000), Word("words", 14400, 15600)]);
        var residual = row.GetProperty("residualSeconds").GetDouble();
        return residual == 0 ? new VoiceLabFitResult.Exact(plan) : new VoiceLabFitResult.ChangedDuration(plan, 0.7, residual);
    }
    private static VoiceLabWavePcm Paid(JsonElement row)
    {
        var channels = Number(row, "channels");
        var bits = Number(row, "bits");
        var wave = new VoiceLabWavePcm(Number(row, "rate"), channels, bits, row.GetProperty("floating").GetBoolean(), new byte[21600 * channels * (bits / 8)]);
        for (var frame = 0; frame < 21600; frame++)
            for (var channel = 0; channel < channels; channel++)
            {
                var value = (frame * 17 + channel * 13) % 127 - 63;
                if (frame is >= 2300 and < 2600 or >= 4800 and < 6000 or >= 14400 and < 15600 or >= 19000 and < 19300) value += 18000;
                wave.SetSample(value / 32768.0, frame, channel);
            }
        return wave;
    }
    private static async Task<VoiceLabFittedAudio> Prepare(JsonElement row, string root, bool hard = false)
    {
        var wave = Paid(row);
        var asset = VoiceLabAssetStore.WriteWave(wave.Pcm, wave.Rate, wave.Channels, wave.Bits, wave.Floating, Project,
            "paid-" + row.GetProperty("name").GetString(), root, DateTimeOffset.UnixEpoch, TestContext.Current.CancellationToken);
        var snapshot = await VoiceLabAssets.PreparePaidAsync(asset, Project, root, root, TestContext.Current.CancellationToken);
        return VoiceLabSilenceFit.Prepare(snapshot, asset, Fit(row), Window(row, hard), 48000, TestContext.Current.CancellationToken);
    }
    [Fact]
    public async Task Test19ReplaysEveryFittedAssetByteAndPublishedRecipe()
    {
        using var cases = Cases();
        Assert.Equal("voxclip-fitted-asset-cases/1", cases.RootElement.GetProperty("schema").GetString());
        foreach (var row in cases.RootElement.GetProperty("cases").EnumerateArray())
        {
            using var storage = new Storage();
            var fitted = await Prepare(row, storage.Root);
            await using var snapshot = fitted.Snapshot;
            var expected = row.GetProperty("expected");
            Assert.Equal(expected.GetProperty("paidSHA256").GetString(), fitted.PaidAsset.Sha256);
            Assert.Equal(expected.GetProperty("fittedSHA256").GetString(), Convert.ToHexStringLower(SHA256.HashData(fitted.Wave.Bytes())));
            Assert.Equal(Number(expected, "trimStartFrame"), fitted.TrimStartFrame);
            Assert.Equal(Number(expected, "trimEndFrame"), fitted.TrimEndFrame);
            var publication = fitted.Publish(Project, "fitted-output", storage.Root, DateTimeOffset.UnixEpoch, "request", 7, -3, TestContext.Current.CancellationToken);
            Assert.Equal(expected.GetProperty("fittedSHA256").GetString(), publication.Assets[^1].Sha256);
            Assert.Equal(1, publication.Audio.Stretch);
            Assert.Equal(-3, publication.Audio.GainDb);
            Assert.Equal(fitted.Fit.Plan.Words, publication.Words);
            Assert.Equal(fitted.PaidAsset.Id, Assert.Single(publication.Chunks).AssetId);
            Assert.Equal(fitted.PaidAsset.Sha256, publication.Chunks[0].AssetSha256);
            Assert.Equal(fitted.IsDerived ? 2 : 1, publication.Assets.Count);
            Assert.Equal(fitted.OutDuration, publication.OutDuration);
        }
    }
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task ScratchMixUsesGainRoomLoopAndBothSeamLengths(bool hard, bool room)
    {
        using var cases = Cases();
        using var storage = new Storage();
        var row = cases.RootElement.GetProperty("cases")[1];
        var fitted = await Prepare(row, storage.Root, hard);
        var source = Enumerable.Repeat(0.1f, 24000 * 6).ToArray();
        if (room) for (var frame = 0; frame < 12000; frame++) source[frame] = frame / 12000f * 0.01f;
        var tone = room ? new VoiceLabRoomTone(0, 24000, -6) : null;
        var input = new VoiceLabTakeInput("new words", "fixture", "fixture", "en", 7, "fixture", [], 48000, [], new HashSet<string>(), Window(row, hard), null, null, false, true);
        var analysis = new VoiceLabTakeAnalysis(24000, [], room ? -3 : 0, tone, fitted.Fit);
        await using var scratch = VoiceLabTakeRenderer.Stage(fitted, analysis, input, VoiceLabSourceExcerpt.Whole(source), storage.Root, TestContext.Current.CancellationToken);
        Assert.Equal(12000, scratch.Audio.PatchStart);
        Assert.Equal(16800, scratch.Audio.PatchEnd - scratch.Audio.PatchStart);
        Assert.Equal(2, scratch.Audio.Seams.Count);
        var fade = hard ? 288 : 480;
        Assert.Equal(0.1f, scratch.Audio.Mixed[scratch.Audio.PatchStart - fade / 2]);
        var relative = room ? 11400 : 3000;
        var expected = (float)fitted.Wave.Sample(fitted.TrimStartFrame + relative, 0) * (float)Math.Pow(10, analysis.GainDb / 20);
        if (room)
        {
            var index = relative % 10800;
            var weight = (index + 1) / 1201f;
            var background = source[10800 + index] * (1 - weight) + source[index] * weight;
            expected += background * (float)Math.Pow(10, -6.0 / 20);
        }
        Assert.Equal(expected, scratch.Audio.Mixed[scratch.Audio.PatchStart + relative], 7);
    }
    /// <summary>6 s of source at the asset rate, as ScratchMixUsesGainRoomLoopAndBothSeamLengths stages it. With regions, only the
    /// room-tone run and 1 s around the window are held, as VoiceLabSourceAudio.RewriteSourceAsync keeps them.</summary>
    private static VoiceLabSourceExcerpt StagingSource(VoiceLabWindow window, bool room, bool regions)
    {
        var source = Enumerable.Repeat(0.1f, 24000 * 6).ToArray();
        if (room) for (var frame = 0; frame < 12000; frame++) source[frame] = frame / 12000f * 0.01f;
        if (!regions) return VoiceLabSourceExcerpt.Whole(source);
        var lower = (int)Math.Floor(window.Start * 24000 + 0.5) - 24000;
        var upper = (int)Math.Floor(window.End * 24000 + 0.5) + 24000;
        var run = new VoiceLabSourceExcerpt.Region(0, source.AsSpan(0, 12000));
        var around = new VoiceLabSourceExcerpt.Region(lower, source.AsSpan(lower, upper - lower));
        return new(source.Length, [around, run]);
    }
    private static async Task<VoiceLabTakeAudio> StagedAudio(JsonElement row, bool hard, bool room, bool regions)
    {
        using var storage = new Storage();
        var fitted = await Prepare(row, storage.Root, hard);
        var window = Window(row, hard);
        var input = new VoiceLabTakeInput("new words", "fixture", "fixture", "en", 7, "fixture", [], 48000, [], new HashSet<string>(), window, null, null, false, true);
        var analysis = new VoiceLabTakeAnalysis(24000, [], room ? -3 : 0, room ? new VoiceLabRoomTone(0, 24000, -6) : null, fitted.Fit);
        await using var scratch = VoiceLabTakeRenderer.Stage(fitted, analysis, input, StagingSource(window, room, regions), storage.Root, TestContext.Current.CancellationToken);
        return scratch.Audio;
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ScratchFromSourceRegionsMatchesTheWholeSource(bool hard)
    {
        using var cases = Cases();
        var row = cases.RootElement.GetProperty("cases")[1];
        foreach (var room in new[] { false, true })
        {
            var expected = await StagedAudio(row, hard, room, regions: false);
            var actual = await StagedAudio(row, hard, room, regions: true);
            Assert.Equal(expected.Mixed, actual.Mixed);
            Assert.Equal(expected.Seams, actual.Seams);
            Assert.Equal((expected.PatchStart, expected.PatchEnd), (actual.PatchStart, actual.PatchEnd));
        }
    }
    [Fact]
    public async Task ScratchRefusesASourceExcerptWithoutTheWindow()
    {
        using var cases = Cases();
        using var storage = new Storage();
        var row = cases.RootElement.GetProperty("cases")[1];
        var fitted = await Prepare(row, storage.Root);
        await using var snapshot = fitted.Snapshot;
        var input = new VoiceLabTakeInput("new words", "fixture", "fixture", "en", 7, "fixture", [], 48000, [], new HashSet<string>(), Window(row), null, null, true, true);
        var excerpt = new VoiceLabSourceExcerpt(24000 * 6, [new VoiceLabSourceExcerpt.Region(0, Enumerable.Repeat(0.1f, 24000).ToArray())]);
        Assert.Equal(VoiceLabErrorKind.InvalidAudio, Assert.Throws<VoiceLabException>(() => VoiceLabTakeRenderer.Stage(fitted,
            new(24000, [], 0, null, fitted.Fit), input, excerpt, storage.Root, TestContext.Current.CancellationToken)).Kind);
    }
    [Fact]
    public async Task ConcurrentScratchAndSnapshotStopsAwaitTheSameConsumerTask()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var stop = VoiceLabLifetime.Once(async () => { calls++; await release.Task; });
        var scratch = stop();
        var snapshot = stop();
        Assert.Same(scratch, snapshot);
        Assert.False(snapshot.IsCompleted);
        Assert.Equal(1, calls);
        release.SetResult();
        await Task.WhenAll(scratch, snapshot);
        Assert.Same(scratch, stop());
    }
    [Fact]
    public async Task SnapshotAndScratchInvalidationStopAllConsumersBeforeRemovingBytes()
    {
        using var cases = Cases();
        using var storage = new Storage();
        var row = cases.RootElement.GetProperty("cases")[1];
        var fitted = await Prepare(row, storage.Root);
        var input = new VoiceLabTakeInput("new words", "fixture", "fixture", "en", 7, "fixture", [], 48000, [], new HashSet<string>(), Window(row), null, null, true, true);
        var scratch = VoiceLabTakeRenderer.Stage(fitted, new(24000, [], 0, null, fitted.Fit), input,
            VoiceLabSourceExcerpt.Whole(Enumerable.Repeat(0.1f, 24000 * 6).ToArray()), storage.Root, TestContext.Current.CancellationToken);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stops = 0;
        using var firstLease = scratch.AttachConsumer(async () => { Interlocked.Increment(ref stops); entered.SetResult(); await release.Task; });
        using var secondLease = scratch.AttachConsumer(() => { Interlocked.Increment(ref stops); second.SetResult(); return Task.CompletedTask; });
        var invalidation = fitted.Snapshot.InvalidateAsync();
        await Task.WhenAll(entered.Task, second.Task);
        Assert.False(scratch.IsValid);
        Assert.True(File.Exists(fitted.Snapshot.Path));
        Assert.Throws<VoiceLabException>(() => scratch.AttachConsumer(() => Task.CompletedTask));
        release.SetResult();
        await invalidation;
        await scratch.InvalidateAsync();
        await scratch.InvalidateAsync();
        Assert.Equal(2, stops);
        Assert.False(File.Exists(scratch.MixedAudioPath));
        Assert.False(File.Exists(fitted.Snapshot.Path));
        Assert.True(File.Exists(Path.Combine(storage.Root, fitted.PaidAsset.File)));
    }
    [Fact]
    public async Task AlteredSnapshotIsRefusedAndCompletePaidAssetsAreNeverLaunchOrphans()
    {
        using var cases = Cases();
        using var storage = new Storage();
        var row = cases.RootElement.GetProperty("cases")[1];
        var fitted = await Prepare(row, storage.Root);
        await using var snapshot = fitted.Snapshot;
        var bytes = File.ReadAllBytes(snapshot.Path);
        bytes[^1] ^= 1;
        File.WriteAllBytes(snapshot.Path, bytes);
        Assert.Equal(VoiceLabAssetErrorCode.Altered, Assert.Throws<VoiceLabAssetException>(() => VoiceLabSilenceFit.Prepare(snapshot, fitted.PaidAsset, Fit(row), Window(row), 48000, TestContext.Current.CancellationToken)).Code);
        var directory = Path.Combine(storage.Root, Project);
        var stale = Path.Combine(directory, ".old.wav." + Guid.NewGuid().ToString("N") + ".partial");
        var current = Path.Combine(directory, ".new.wav." + Guid.NewGuid().ToString("N") + ".partial");
        var foreign = Path.Combine(directory, "foreign.partial");
        foreach (var path in new[] { stale, current, foreign }) File.WriteAllText(path, "synthetic");
        File.SetLastWriteTimeUtc(stale, DateTime.UnixEpoch);
        File.SetLastWriteTimeUtc(foreign, DateTime.UnixEpoch);
        Assert.Equal(0, VoiceLabAssetStore.CleanupStalePartials(storage.Root, Project, DateTimeOffset.UtcNow.AddMinutes(-1)));
        Assert.True(File.Exists(stale));
        Assert.True(File.Exists(current));
        Assert.True(File.Exists(foreign));
        Assert.True(File.Exists(Path.Combine(storage.Root, fitted.PaidAsset.File)));
    }
}

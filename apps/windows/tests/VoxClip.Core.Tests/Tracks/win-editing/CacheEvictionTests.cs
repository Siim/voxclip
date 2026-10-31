using System.Buffers.Binary;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>The cache size limit is enforced (architecture §8.2), as the Mac's CacheEvictionTests: the scheduler's launch delay,
/// requested and joined passes, the two passes at a limit, leases held by editors, transcription and extraction, one pass at a
/// time per cache folder, the one-hour rule for every pass, Clear cache keeping root files, marking an entry used and decimal
/// gigabytes. Small files stand in for gigabytes (the limit is injected in bytes), and the launch delay and clock are
/// injected, so nothing here waits for real time.</summary>
public sealed class CacheEvictionTests
{
    private const string Audio = "audio-16k.wav";
    private const string Envelope = "envelope-10ms.f32";
    private static readonly DateTimeOffset Start = new(2026, 10, 31, 9, 0, 0, TimeSpan.Zero);
    private static readonly IReadOnlySet<string> Nothing = new HashSet<string>();
    private static string Key(char letter) => new(letter, 64);
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task TheLaunchPassWaitsThirtySecondsAndNothingGoesBefore()
    {
        using var storage = new TestStorage();
        var clock = new Clock(Start);
        var index = new CacheIndex(storage.Root, clock);
        var key = Key('a');
        await SeedAsync(index, key, audio: 100_000);
        var delays = new Delays();
        var scheduler = new CacheEvictionScheduler(index, () => 50_000, delay: delays.Delay);
        Assert.False(scheduler.LaunchScheduled);
        var launch = scheduler.ScheduleAfterLaunch();
        Assert.Same(launch, scheduler.ScheduleAfterLaunch());
        Assert.True(scheduler.LaunchScheduled);
        Assert.Equal(TimeSpan.FromSeconds(30), await delays.NextAsync());
        Assert.Equal(TimeSpan.FromSeconds(30), CacheEvictionScheduler.LaunchDelay);
        await scheduler.WaitUntilIdleAsync();
        Assert.True(File.Exists(Path.Combine(storage.Root, key, Audio)));
        Assert.Equal(0, scheduler.CompletedRuns);
        delays.ReleaseAll();
        await launch;
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(1, scheduler.CompletedRuns);
        Assert.False(File.Exists(Path.Combine(storage.Root, key, Audio)));
        Assert.True(File.Exists(Path.Combine(storage.Root, key, Envelope)));
        Assert.Single(delays.Requested);
    }

    [Fact]
    public async Task ARequestedPassRunsAtOnce()
    {
        using var storage = new TestStorage();
        var clock = new Clock(Start);
        var index = new CacheIndex(storage.Root, clock);
        var key = Key('a');
        await SeedAsync(index, key, audio: 100_000);
        var delays = new Delays();
        var scheduler = new CacheEvictionScheduler(index, () => 50_000, delay: delays.Delay);
        scheduler.RequestRun();
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(1, scheduler.CompletedRuns);
        Assert.False(File.Exists(Path.Combine(storage.Root, key, Audio)));
        Assert.Empty(delays.Requested);
    }

    [Fact]
    public async Task AtTheLimitTheLeastRecentlyUsedLoseAudioThumbnailsAndFacesFirstAndWholeEntriesGoLast()
    {
        using var storage = new TestStorage();
        var clock = new Clock(Start);
        var index = new CacheIndex(storage.Root, clock);
        var (leased, b, c, d) = (Key('a'), Key('b'), Key('c'), Key('d'));
        foreach (var key in new[] { leased, b, c, d })
        {
            await SeedAsync(index, key, audio: 10_000, transcript: true, thumbs: true, faces: true);
            clock.Advance(TimeSpan.FromMinutes(1));
        }
        using var open = index.Keys.LeaseNow(leased);
        var limit = 30_000L;
        var scheduler = new CacheEvictionScheduler(index, () => limit);
        scheduler.RequestRun();
        await scheduler.WaitUntilIdleAsync();
        // The oldest is in use: untouched, but counted. The next two lose what can be made again; the newest is untouched.
        Assert.Equal(Full, Names(storage, leased));
        Assert.Equal(Stripped, Names(storage, b));
        Assert.Equal(Stripped, Names(storage, c));
        Assert.Equal(Full, Names(storage, d));
        Assert.Equal(["raw.json"], Directory.EnumerateFiles(Path.Combine(storage.Root, b, "transcripts")).Select(path => Path.GetFileName(path)));
        var stripped = Bytes(storage, c);
        Assert.Equal(stripped - new FileInfo(Path.Combine(storage.Root, c, "meta.json")).Length,
            Assert.Single(await index.ReadAsync(Ct), entry => entry.ContentKey == c).Bytes);
        // A lower limit: whole entries go only once every unused entry has lost its audio, oldest first.
        limit = Bytes(storage, leased) + 2 * stripped + 50;
        scheduler.RequestRun();
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(Full, Names(storage, leased));
        Assert.False(Directory.Exists(Path.Combine(storage.Root, b)));
        Assert.Equal(Stripped, Names(storage, c));
        Assert.Equal(Stripped, Names(storage, d));
        Assert.Equal(2, scheduler.CompletedRuns);
    }

    [Fact]
    public async Task LeasesFromTwoWindowsSurviveClearEverything()
    {
        using var storage = new TestStorage();
        var clock = new Clock(Start);
        var index = new CacheIndex(storage.Root, clock);
        var (shared, own, unused) = (Key('a'), Key('b'), Key('c'));
        foreach (var key in new[] { shared, own, unused }) await SeedAsync(index, key, audio: 1_000);
        // Two projects of one source in two windows, and a third window with another source.
        var first = index.Keys.LeaseNow(shared);
        var second = index.Keys.LeaseNow(shared);
        using var third = index.Keys.LeaseNow(own);
        var scheduler = new CacheEvictionScheduler(index, () => 0);
        await scheduler.ClearEverythingAsync();
        Assert.Equal(Plain, Names(storage, shared));
        Assert.Equal(Plain, Names(storage, own));
        Assert.False(Directory.Exists(Path.Combine(storage.Root, unused)));
        first.Dispose();
        first.Dispose();
        Assert.True(index.Keys.IsLeased(shared));
        await scheduler.ClearEverythingAsync();
        Assert.Equal(Plain, Names(storage, shared));
        second.Dispose();
        Assert.Equal(own, Assert.Single(index.Keys.LeasedKeys));
        await scheduler.ClearEverythingAsync();
        Assert.False(Directory.Exists(Path.Combine(storage.Root, shared)));
        Assert.Equal(Plain, Names(storage, own));
    }

    [Fact]
    public async Task ARunningTranscriptionKeepsItsEntry()
    {
        using var storage = new TestStorage();
        var cache = storage.PathFor("Cache");
        var clock = new Clock(Start);
        var index = new CacheIndex(cache, clock);
        var key = Key('a');
        await SeedAsync(index, key, audio: 1_000, transcript: true);
        var engine = new HeldTranscriber();
        var service = new TranscriptionService([engine], new SpeechJobQueues(), dataRoot: storage.Root);
        var plan = new TranscriptionPlan(TranscriptEngine.Elevenlabs, null, new LanguageChoice.Auto(), new());
        var audio = new ExtractedAudio(Path.Combine(cache, key, Audio), 16_000, 1, 0, 0);
        var job = service.TranscribeAsync(new(plan, audio, key), new Progress<TranscriptionProgress>(), Ct);
        await engine.Started.Task.WaitAsync(Ct);
        Assert.True(index.Keys.IsLeased(key));
        var scheduler = new CacheEvictionScheduler(index, () => 0);
        await scheduler.ClearEverythingAsync();
        Assert.Equal(["audio-16k.wav", "envelope-10ms.f32", "meta.json", "transcripts"], Names(storage, Path.Combine("Cache", key)));
        engine.Release.SetResult();
        await job;
        Assert.False(index.Keys.IsLeased(key));
        await scheduler.ClearEverythingAsync();
        Assert.False(Directory.Exists(Path.Combine(cache, key)));
    }

    [Fact]
    public async Task AnExtractionUnderWayKeepsItsHalfWrittenEntryAndMarksItUsedAsItStarts()
    {
        using var storage = new TestStorage();
        var clock = new Clock(WholeSecondNow());
        var index = new CacheIndex(storage.Root, clock);
        var (extracting, newer) = (Key('a'), Key('b'));
        await SeedAsync(index, extracting, audio: 1_000);
        clock.Advance(TimeSpan.FromMinutes(1));
        await SeedAsync(index, newer, audio: 1_000);
        clock.Advance(TimeSpan.FromMinutes(1));
        var started = clock.GetUtcNow();
        var extractor = new HeldExtractor();
        var extraction = index.ExtractAudioAsync(extractor, Media(storage), extracting, null, Ct);
        await extractor.Started.Task.WaitAsync(Ct);
        // The entry is the most recently used from the moment its extraction starts.
        var entries = await index.ReadAsync(Ct);
        Assert.Equal(started, Assert.Single(entries, entry => entry.ContentKey == extracting).LastAccessAt);
        Assert.True(index.Keys.IsLeased(extracting));
        // It has metadata, so the hour rule does not spare it: only the lease keeps its half-written files.
        clock.Advance(TimeSpan.FromHours(2));
        await new CacheEvictionScheduler(index, () => 0).ClearEverythingAsync();
        Assert.True(File.Exists(Path.Combine(storage.Root, extracting, HeldExtractor.Partial)));
        Assert.False(Directory.Exists(Path.Combine(storage.Root, newer)));
        extractor.Release.SetResult();
        await extraction;
        Assert.False(index.Keys.IsLeased(extracting));
        Assert.Equal(clock.GetUtcNow(), Assert.Single(await index.ReadAsync(Ct)).LastAccessAt);
    }

    [Fact]
    public async Task PassesNeverOverlapAndAQueuedRequestIsJoined()
    {
        using var storage = new TestStorage();
        var clock = new Clock(Start);
        var index = new CacheIndex(storage.Root, clock);
        var key = Key('a');
        await SeedAsync(index, key, audio: 1_000);
        // Another index of the same folder holds the turn, as a pass that is running: one turn per folder, whichever index runs it.
        var keys = new CacheIndex(storage.Root).Keys;
        Assert.Same(index.Keys, keys);
        await keys.BeginEvictionAsync(Ct);
        var scheduler = new CacheEvictionScheduler(index, () => long.MaxValue);
        scheduler.RequestRun();
        Assert.True(SpinWait.SpinUntil(() => keys.WaitingEvictions == 1, TimeSpan.FromSeconds(30)));
        // The first request waits for the turn; the next queues behind it and the last joins that one.
        scheduler.RequestRun();
        scheduler.RequestRun();
        var clear = scheduler.ClearCacheAsync();
        Assert.True(SpinWait.SpinUntil(() => keys.WaitingEvictions == 2, TimeSpan.FromSeconds(30)));
        Assert.False(clear.IsCompleted);
        Assert.Equal(0, scheduler.CompletedRuns);
        Assert.Equal(Plain, Names(storage, key));
        keys.EndEviction();
        await clear;
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(2, scheduler.CompletedRuns);
        Assert.Equal([Envelope, "meta.json"], Names(storage, key));
        Assert.Equal(0, keys.WaitingEvictions);
        // The turn is free again.
        await keys.BeginEvictionAsync(Ct);
        keys.EndEviction();
    }

    [Fact]
    public async Task EntriesWithoutMetadataAreSparedForAnHourByEveryPass()
    {
        using var storage = new TestStorage();
        var clock = new Clock(WholeSecondNow());
        var index = new CacheIndex(storage.Root, clock);
        var orphan = Key('a');
        var directory = Directory.CreateDirectory(storage.PathFor(orphan)).FullName;
        await File.WriteAllBytesAsync(Path.Combine(directory, Audio), new byte[1_000], Ct);
        Directory.CreateDirectory(Path.Combine(directory, "transcripts"));
        await File.WriteAllTextAsync(Path.Combine(directory, "transcripts", "raw.json"), "{}", Ct);
        var scheduler = new CacheEvictionScheduler(index, () => 0);
        scheduler.RequestRun();
        await scheduler.WaitUntilIdleAsync();
        await scheduler.ClearCacheAsync();
        await scheduler.ClearEverythingAsync();
        Assert.Equal([Audio, "transcripts"], Names(storage, orphan));
        clock.Advance(TimeSpan.FromHours(1) + TimeSpan.FromMinutes(1));
        var written = Directory.GetLastWriteTimeUtc(directory);
        await scheduler.ClearCacheAsync();
        Assert.Equal(["transcripts"], Names(storage, orphan));
        // Stripping keeps the folder's time, so the entry never looks freshly written.
        Assert.Equal(written, Directory.GetLastWriteTimeUtc(directory));
        await scheduler.ClearEverythingAsync();
        Assert.False(Directory.Exists(directory));
    }

    [Fact]
    public async Task ClearCacheIsStillThePassAtZeroAndKeepsTheFilesAtTheCacheRoot()
    {
        using var storage = new TestStorage();
        var clock = new Clock(Start);
        var index = new CacheIndex(storage.Root, clock);
        var (withTranscript, plain, thumbsOnly) = (Key('a'), Key('b'), Key('c'));
        await SeedAsync(index, withTranscript, audio: 1_000, transcript: true);
        await SeedAsync(index, plain, audio: 1_000);
        Directory.CreateDirectory(Path.Combine(storage.Root, thumbsOnly, "thumbs"));
        await File.WriteAllBytesAsync(Path.Combine(storage.Root, thumbsOnly, "thumbs", "poster.jpg"), new byte[500], Ct);
        await index.TouchAsync(thumbsOnly, 500, null, Ct);
        // What the app and Voice Lab keep at the cache root, including temporaries of writes under way, and folders that are not entries.
        var kept = new[]
        {
            "encoders.json", $"encoders.json.{Guid.NewGuid():N}.partial", "llm-models.json", $"llm-models.json.{Guid.NewGuid():N}.tmp",
            "microphone-settings-uri.txt", "consent-scribe-result.json", "training-result.json", "creation-result.json"
        };
        foreach (var name in kept) await File.WriteAllTextAsync(storage.PathFor(name), "{}", Ct);
        var consent = Directory.CreateDirectory(Path.Combine(storage.Root, "voice-consent", Guid.NewGuid().ToString("D"))).FullName;
        await File.WriteAllBytesAsync(Path.Combine(consent, "statement.wav"), new byte[2_000], Ct);
        var upper = Directory.CreateDirectory(storage.PathFor(new string('f', 63))).FullName;
        await File.WriteAllBytesAsync(Path.Combine(upper, Audio), new byte[2_000], Ct);
        foreach (var legacy in new[] { Audio, "apple-16000-1.caf", "meta.json.0123abcd.partial" }) await File.WriteAllTextAsync(storage.PathFor(legacy), "stray", Ct);
        var scheduler = new CacheEvictionScheduler(index, () => long.MaxValue);
        await scheduler.ClearCacheAsync();
        Assert.Equal([Envelope, "meta.json", "transcripts"], Names(storage, withTranscript));
        Assert.Equal([Envelope, "meta.json"], Names(storage, plain));
        Assert.False(Directory.Exists(Path.Combine(storage.Root, thumbsOnly)));
        var rootFiles = kept.Append("voice-consent").Append(new string('f', 63)).Order(StringComparer.Ordinal).ToArray();
        Assert.Equal(rootFiles.Append(withTranscript).Append(plain).Order(StringComparer.Ordinal), Root(storage));
        await scheduler.ClearEverythingAsync();
        Assert.Equal(rootFiles, Root(storage));
        Assert.True(File.Exists(Path.Combine(consent, "statement.wav")));
        Assert.True(File.Exists(Path.Combine(upper, Audio)));
    }

    [Fact]
    public async Task AnEntryMarkedUsedIsTheMostRecentlyUsed()
    {
        using var storage = new TestStorage();
        var clock = new Clock(Start);
        var index = new CacheIndex(storage.Root, clock);
        var (older, newer, orphan) = (Key('a'), Key('b'), Key('c'));
        await SeedAsync(index, older, audio: 1_000, envelope: false);
        var created = clock.GetUtcNow();
        clock.Advance(TimeSpan.FromMinutes(1));
        await SeedAsync(index, newer, audio: 1_000, envelope: false);
        clock.Advance(TimeSpan.FromMinutes(1));
        await index.MarkUsedAsync(older, Ct);
        var entry = Assert.Single(await index.ReadAsync(Ct), item => item.ContentKey == older);
        Assert.Equal(clock.GetUtcNow(), entry.LastAccessAt);
        Assert.Equal(created, entry.CreatedAt);
        Assert.Equal(1_000, entry.Bytes);
        // An entry without metadata, and a key that names none, are left as they are.
        Directory.CreateDirectory(storage.PathFor(orphan));
        await index.MarkUsedAsync(orphan, Ct);
        await index.MarkUsedAsync("../Models", Ct);
        Assert.Empty(Directory.EnumerateFileSystemEntries(storage.PathFor(orphan)));
        Assert.False(index.Keys.IsLeased(older));
        // One entry has to go: the one used least recently. Without an envelope or transcripts it goes whole in the first pass.
        var limit = Bytes(storage, older) + 10;
        Assert.Equal([newer], await index.EvictAsync(limit, Nothing, Ct));
        Assert.Equal([Audio, "meta.json"], Names(storage, older));
    }

    [Fact]
    public async Task ALeaseWaitsWhileEvictionWorksOnItsEntry()
    {
        using var storage = new TestStorage();
        var keys = CacheKeyRegistry.Shared(storage.Root);
        Assert.Same(keys, CacheKeyRegistry.Shared(storage.Root + Path.DirectorySeparatorChar));
        Assert.NotSame(keys, CacheKeyRegistry.Shared(storage.PathFor("other")));
        var key = Key('a');
        Assert.True(keys.TryClaim(key, Nothing));
        var waiting = keys.LeaseAsync(key, Ct);
        Assert.False(waiting.IsCompleted);
        using (var cancel = CancellationTokenSource.CreateLinkedTokenSource(Ct))
        {
            var cancelled = keys.LeaseAsync(key, cancel.Token);
            await cancel.CancelAsync();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelled);
        }
        using (var other = await keys.LeaseAsync(Key('b'), Ct)) Assert.Equal(Key('b'), other.Key);
        keys.EndClaim();
        using var lease = await waiting.WaitAsync(Ct);
        Assert.Equal(key, lease.Key);
        Assert.False(keys.TryClaim(key, Nothing));
        Assert.False(keys.TryClaim(Key('c'), new HashSet<string> { Key('c') }));
        lease.Dispose();
        Assert.Empty(keys.LeasedKeys);
        Assert.True(keys.TryClaim(key, Nothing));
        keys.EndClaim();
    }

    [Fact]
    public void TheLimitIsInDecimalGigabytes()
    {
        Assert.Equal(2_000_000_000L, CacheEvictionScheduler.LimitBytes(2));
        Assert.Equal(20_000_000_000L, CacheEvictionScheduler.LimitBytes(20));
        Assert.Equal(2_500_000_000L, CacheEvictionScheduler.LimitBytes(2.5));
        Assert.Equal(5_000_000_000L, CacheEvictionScheduler.DefaultLimitBytes);
        foreach (var unusable in new double?[] { null, 0, -1, double.NaN, double.PositiveInfinity, 1_001 })
            Assert.Equal(CacheEvictionScheduler.DefaultLimitBytes, CacheEvictionScheduler.LimitBytes(unusable));
    }

    [Fact]
    public async Task AFailedPassIsOnlyLogged()
    {
        using var storage = new TestStorage();
        var warnings = new List<string>();
        var scheduler = new CacheEvictionScheduler(new CacheIndex(storage.Root), () => throw new InvalidOperationException(), warnings.Add);
        scheduler.RequestRun();
        await scheduler.WaitUntilIdleAsync();
        // The next pass still runs.
        scheduler.RequestRun();
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(2, scheduler.CompletedRuns);
        Assert.Equal(["eviction=failed pass=background code=InvalidOperationException", "eviction=failed pass=background code=InvalidOperationException"], warnings);
    }

    private static readonly string[] Full = [Audio, Envelope, "faces", "meta.json", "thumbs", "transcripts"];
    private static readonly string[] Stripped = [Envelope, "meta.json", "transcripts"];
    private static readonly string[] Plain = [Audio, Envelope, "meta.json"];

    /// <summary>An extracted entry recorded at the clock's time: its audio, a 64-byte envelope and meta.json, with optional raw
    /// transcripts, poster thumbnails and faces.</summary>
    private static async Task SeedAsync(CacheIndex index, string key, int audio, bool envelope = true, bool transcript = false, bool thumbs = false, bool faces = false)
    {
        var directory = Directory.CreateDirectory(index.EntryDirectory(key)).FullName;
        await File.WriteAllBytesAsync(Path.Combine(directory, Audio), new byte[audio], Ct);
        long bytes = audio;
        if (envelope)
        {
            var levels = new byte[64];
            for (var offset = 0; offset < levels.Length; offset += 4) BinaryPrimitives.WriteSingleLittleEndian(levels.AsSpan(offset), 0.1f);
            await File.WriteAllBytesAsync(Path.Combine(directory, Envelope), levels, Ct);
            bytes += levels.Length;
        }
        if (transcript) bytes += await WriteAsync(Path.Combine(directory, "transcripts", "raw.json"), 100);
        if (thumbs) bytes += await WriteAsync(Path.Combine(directory, "thumbs", "poster-1.0-480x270.jpg"), 1_000);
        if (faces) bytes += await WriteAsync(Path.Combine(directory, "faces", "detections.json"), 500);
        // The index's clock stamps lastAccessAt.
        await index.TouchAsync(key, bytes, envelope ? new CacheEnvelope(48_000, 0.01, 16) : null, Ct);
    }

    private static async Task<long> WriteAsync(string path, int bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllBytesAsync(path, new byte[bytes], Ct);
        return bytes;
    }

    private static IEnumerable<string> Names(TestStorage storage, string entry) =>
        new DirectoryInfo(storage.PathFor(entry)).EnumerateFileSystemInfos().Select(item => item.Name).Order(StringComparer.Ordinal).ToList();

    private static IEnumerable<string> Root(TestStorage storage) =>
        Directory.EnumerateFileSystemEntries(storage.Root).Select(path => Path.GetFileName(path)).Order(StringComparer.Ordinal).ToList();

    private static long Bytes(TestStorage storage, string entry) =>
        Directory.EnumerateFiles(storage.PathFor(entry), "*", SearchOption.AllDirectories).Sum(path => new FileInfo(path).Length);

    private static MediaInfo Media(TestStorage storage) => new(storage.PathFor("take.mov"), 1, null, null, new(1920, 1080), null, null, false, 0, 0, 0);

    // Cache timestamps keep milliseconds, so a clock that starts now starts on a whole second.
    private static DateTimeOffset WholeSecondNow()
    {
        var now = DateTimeOffset.UtcNow;
        return new(now.Ticks - now.Ticks % TimeSpan.TicksPerSecond, TimeSpan.Zero);
    }

    private sealed class Clock(DateTimeOffset start) : TimeProvider
    {
        private readonly object sync = new();
        private DateTimeOffset now = start;
        public override DateTimeOffset GetUtcNow() { lock (sync) return now; }
        internal void Advance(TimeSpan span) { lock (sync) now += span; }
    }

    /// <summary>A launch delay that waits until the test releases it, and records what was asked for.</summary>
    private sealed class Delays
    {
        private readonly TaskCompletionSource release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<TimeSpan> first = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal List<TimeSpan> Requested { get; } = [];
        internal Task Delay(TimeSpan span, CancellationToken ct)
        {
            lock (Requested) Requested.Add(span);
            first.TrySetResult(span);
            return release.Task.WaitAsync(ct);
        }
        internal Task<TimeSpan> NextAsync() => first.Task.WaitAsync(Ct);
        internal void ReleaseAll() => release.TrySetResult();
    }

    /// <summary>Writes a partial WAV into the entry, then waits until the test lets it finish as FfmpegAudioExtractor would.</summary>
    private sealed class HeldExtractor : IAudioExtractor
    {
        internal const string Partial = "audio-16k.wav.0123abcd.partial";
        internal TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<AudioExtractionResult> ExtractAsync(AudioExtractionRequest request, IProgress<MediaProgress>? progress, CancellationToken ct)
        {
            Directory.CreateDirectory(request.CacheDirectory);
            var partial = Path.Combine(request.CacheDirectory, Partial);
            await File.WriteAllBytesAsync(partial, new byte[2_000], ct);
            File.SetLastWriteTimeUtc(partial, DateTime.UtcNow.AddMinutes(-5));
            Started.SetResult();
            await Release.Task.WaitAsync(ct);
            var wav = Path.Combine(request.CacheDirectory, Audio);
            File.Move(partial, wav, true);
            await File.WriteAllBytesAsync(Path.Combine(request.CacheDirectory, Envelope), new byte[64], ct);
            return new(new(wav, 16_000, 1, 0, 0), new(48_000, 0.01, new float[16]));
        }
    }

    /// <summary>A transcriber that runs until the test lets it finish.</summary>
    private sealed class HeldTranscriber : ITranscriber
    {
        internal TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TranscriptEngine Engine => TranscriptEngine.Elevenlabs;
        public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, null, null, false);
        public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromResult(true);
        public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(new Readiness.Ready());
        public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
        public async Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
        {
            Started.SetResult();
            await Release.Task.WaitAsync(ct);
            return new RawTranscript(new(Engine, "scribe_v2", null, "scribe_v2", null), 1,
                new(GroupingEnd.LastToken, GroupingConfidence.Single, false), [new("hello", false, 0.1, 0.4, 0.9, null, null, 0)],
                "en", null, true, TimingSource.Native, null);
        }
    }
}

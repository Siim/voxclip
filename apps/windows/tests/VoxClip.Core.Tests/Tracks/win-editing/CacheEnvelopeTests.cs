using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class CacheEnvelopeTests
{
    private const string Audio = "audio-16k.wav";
    private const string Envelope = "envelope-10ms.f32";

    [Fact]
    public async Task TwoTranscriptionsNoLongerOverwriteEachOther()
    {
        using var storage = new TestStorage();
        var cache = storage.PathFor("Cache");
        Directory.CreateDirectory(cache);
        foreach (var name in new[] { Audio, Envelope, "meta.json" }) await File.WriteAllTextAsync(Path.Combine(cache, name), "stray", TestContext.Current.CancellationToken);
        var index = new CacheIndex(cache);
        var first = new string('a', 64);
        var second = new string('b', 64);
        var audio = new Dictionary<string, ExtractedAudio>();
        foreach (var key in new[] { first, second })
            audio[key] = (await index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), key, null, TestContext.Current.CancellationToken)).Audio;
        foreach (var name in new[] { Audio, Envelope, "meta.json" }) Assert.False(File.Exists(Path.Combine(cache, name)), name);
        var service = new TranscriptionService([new StubTranscriber()], dataRoot: storage.Root);
        foreach (var key in new[] { first, second })
        {
            Assert.Equal(Path.Combine(cache, key, Audio), audio[key].Wav16kPath);
            Assert.Equal(Enumerable.Repeat((byte)key[0], 4000), await File.ReadAllBytesAsync(audio[key].Wav16kPath, TestContext.Current.CancellationToken));
            Assert.Equal(RecordingExtractor.Levels(key), await File.ReadAllBytesAsync(Path.Combine(cache, key, Envelope), TestContext.Current.CancellationToken));
            var entry = Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken), item => item.ContentKey == key);
            Assert.Equal(new CacheEnvelope(44100, 0.01, 16), entry.Envelope);
            Assert.Equal(4064L, entry.Bytes);
            using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(cache, key, "meta.json"), TestContext.Current.CancellationToken));
            Assert.EndsWith("Z", meta.RootElement.GetProperty("createdAt").GetString());
            var plan = new TranscriptionPlan(TranscriptEngine.Elevenlabs, null, new LanguageChoice.Auto(), new());
            var transcript = await service.TranscribeAsync(new(plan, audio[key], key), new Progress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
            Assert.True(transcript.Refined);
        }
        var created = Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken), item => item.ContentKey == first).CreatedAt;
        await Task.Delay(20, TestContext.Current.CancellationToken);
        await index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), first, null, TestContext.Current.CancellationToken);
        var again = Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken), item => item.ContentKey == first);
        Assert.Equal(created, again.CreatedAt);
        Assert.True(again.LastAccessAt > created);
        await Assert.ThrowsAsync<ArgumentException>(() => index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), "../Models", null, TestContext.Current.CancellationToken));
        Assert.False(Directory.Exists(storage.PathFor("Models")));
    }

    [Fact]
    public async Task EntriesTheExtractorRecordedBeforeAreReadable()
    {
        using var storage = new TestStorage();
        var key = new string('a', 64);
        var directory = Directory.CreateDirectory(storage.PathFor(key)).FullName;
        var createdAt = new DateTimeOffset(2026, 10, 20, 8, 30, 0, TimeSpan.Zero);
        await File.WriteAllBytesAsync(Path.Combine(directory, "meta.json"), RecordingExtractor.Metadata(key, 4064, createdAt), TestContext.Current.CancellationToken);
        Assert.Contains("+00:00", await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), TestContext.Current.CancellationToken));
        var entry = Assert.Single(await new CacheIndex(storage.Root).ReadAsync(TestContext.Current.CancellationToken));
        Assert.Equal(createdAt, entry.CreatedAt);
        Assert.Equal(new CacheEnvelope(44100, 0.01, 16), entry.Envelope);
    }

    [Theory]
    [InlineData("createdAt", "9999-12-31T23:59:59.9995Z")]
    [InlineData("lastAccessAt", "9999-12-31T23:59:59.9999999+00:00")]
    public async Task MetadataPastTheLastMillisecondIsAMissNotACrash(string field, string text)
    {
        using var storage = new TestStorage();
        var index = new CacheIndex(storage.Root);
        var key = new string('d', 64);
        var directory = storage.PathFor(key);
        async Task Seed()
        {
            var meta = JsonNode.Parse(RecordingExtractor.Metadata(key, 4064, DateTimeOffset.UtcNow))!;
            meta[field] = text;
            Directory.CreateDirectory(directory);
            await File.WriteAllTextAsync(Path.Combine(directory, "meta.json"), meta.ToJsonString(), TestContext.Current.CancellationToken);
        }
        await Seed();
        Assert.Empty(await index.ReadAsync(TestContext.Current.CancellationToken));
        await index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), key, null, TestContext.Current.CancellationToken);
        Assert.True(Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken)).CreatedAt > DateTimeOffset.UtcNow.AddMinutes(-1));
        await Seed();
        await index.TouchAsync(key, 4064, null, TestContext.Current.CancellationToken);
        Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken));
        await Seed();
        foreach (var path in Directory.EnumerateFiles(directory)) File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddHours(-2));
        Directory.SetLastWriteTimeUtc(directory, DateTime.UtcNow.AddHours(-2));
        Assert.Equal([key], await index.EvictAsync(0, new HashSet<string>(), TestContext.Current.CancellationToken));
        Assert.False(Directory.Exists(directory));
    }

    [Fact]
    public void LegacyRootFilesGoButNothingElse()
    {
        using var storage = new TestStorage();
        using var other = new TestStorage();
        var stray = new[] { Audio, Envelope, "meta.json", "apple-16000-1.caf", $"apple-{Guid.NewGuid():N}.caf", $"audio-16k-{Guid.NewGuid():N}.partial",
            "audio-16k.wav.0123abcd.partial", "envelope-10ms.f32.0123abcd.partial", "meta.json.0123abcd.partial" };
        var kept = new[] { "encoders.json", "llm-models.json", "notes.caf", "audio-16k.wav.bak", "apple-.caf" };
        foreach (var name in stray.Concat(kept)) File.WriteAllText(storage.PathFor(name), "x");
        var entry = Directory.CreateDirectory(storage.PathFor(new string('a', 64))).FullName;
        File.WriteAllText(Path.Combine(entry, Audio), "x");
        Directory.CreateDirectory(storage.PathFor("apple-folder.caf"));
        var expected = kept.Append("apple-folder.caf").Append(new string('a', 64)).ToList();
        var outside = other.PathFor("outside.caf");
        File.WriteAllText(outside, "x");
        if (!OperatingSystem.IsWindows())
        {
            File.CreateSymbolicLink(storage.PathFor("apple-link.caf"), outside);
            expected.Add("apple-link.caf");
        }
        new CacheIndex(storage.Root).RemoveLegacyRootFiles();
        Assert.Equal(expected.Order(StringComparer.Ordinal), Directory.EnumerateFileSystemEntries(storage.Root).Select(path => Path.GetFileName(path)).Order(StringComparer.Ordinal));
        Assert.True(File.Exists(Path.Combine(entry, Audio)));
        Assert.True(File.Exists(outside));
    }

    [Fact]
    public async Task ExtractionNeverWritesThroughALinkedEntry()
    {
        using var storage = new TestStorage();
        using var other = new TestStorage();
        var index = new CacheIndex(storage.Root);
        var file = new string('b', 64);
        await File.WriteAllTextAsync(storage.PathFor(file), "x", TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<IOException>(() => index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), file, null, TestContext.Current.CancellationToken));
        if (OperatingSystem.IsWindows()) return;
        var linked = new string('a', 64);
        Directory.CreateSymbolicLink(storage.PathFor(linked), other.Root);
        await Assert.ThrowsAsync<IOException>(() => index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), linked, null, TestContext.Current.CancellationToken));
        Assert.Empty(Directory.EnumerateFileSystemEntries(other.Root));
        var dangling = new string('c', 64);
        Directory.CreateSymbolicLink(storage.PathFor(dangling), other.PathFor("gone"));
        await Assert.ThrowsAsync<IOException>(() => index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), dangling, null, TestContext.Current.CancellationToken));
        Assert.False(Directory.Exists(other.PathFor("gone")));
    }

    [Fact]
    public async Task EvictionDropsAudioBeforeEnvelopes()
    {
        using var storage = new TestStorage();
        var index = new CacheIndex(storage.Root);
        var keys = new[] { 'a', 'b', 'c' }.Select(letter => new string(letter, 64)).ToArray();
        foreach (var key in keys) await index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), key, null, TestContext.Current.CancellationToken);
        var total = Directory.GetFiles(storage.Root, "*", SearchOption.AllDirectories).Sum(path => new FileInfo(path).Length);
        Assert.Empty(await index.EvictAsync(total - 1000, new HashSet<string>(), TestContext.Current.CancellationToken));
        var oldest = Path.Combine(storage.Root, keys[0]);
        Assert.False(File.Exists(Path.Combine(oldest, Audio)));
        Assert.Equal(RecordingExtractor.Levels(keys[0]), await File.ReadAllBytesAsync(Path.Combine(oldest, Envelope), TestContext.Current.CancellationToken));
        Assert.Equal(64L, Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken), entry => entry.ContentKey == keys[0]).Bytes);
        Assert.True(File.Exists(Path.Combine(storage.Root, keys[1], Audio)));
        Assert.Equal(keys[..2], await index.EvictAsync(1, new HashSet<string> { keys[2] }, TestContext.Current.CancellationToken));
        Assert.True(File.Exists(Path.Combine(storage.Root, keys[2], Audio)));
    }

    [Fact]
    public async Task ClearCacheKeepsEnvelopesAndTranscriptsUnlessClearingEverything()
    {
        using var storage = new TestStorage();
        var index = new CacheIndex(storage.Root);
        var keys = new[] { 'a', 'b' }.Select(letter => new string(letter, 64)).ToArray();
        foreach (var key in keys) await index.ExtractAudioAsync(new RecordingExtractor(), Media(storage), key, null, TestContext.Current.CancellationToken);
        var transcripts = Path.Combine(storage.Root, keys[0], "transcripts");
        Directory.CreateDirectory(transcripts);
        await File.WriteAllTextAsync(Path.Combine(transcripts, "raw.json"), "{}", TestContext.Current.CancellationToken);
        var bare = new string('c', 64);
        Directory.CreateDirectory(Path.Combine(storage.Root, bare, "thumbs"));
        await File.WriteAllBytesAsync(Path.Combine(storage.Root, bare, "thumbs", "poster.jpg"), new byte[500], TestContext.Current.CancellationToken);
        await index.TouchAsync(bare, 500, null, TestContext.Current.CancellationToken);
        // An entry from before this fix: paid raw transcripts and a filmstrip, but no envelope and no meta.json, written days ago.
        var paid = new string('d', 64);
        Directory.CreateDirectory(Path.Combine(storage.Root, paid, "transcripts"));
        Directory.CreateDirectory(Path.Combine(storage.Root, paid, "thumbs"));
        await File.WriteAllTextAsync(Path.Combine(storage.Root, paid, "transcripts", "elevenlabs-scribe_v2-auto-00000000.json"), "{}", TestContext.Current.CancellationToken);
        await File.WriteAllBytesAsync(Path.Combine(storage.Root, paid, "thumbs", "strip-160.jpg"), new byte[500], TestContext.Current.CancellationToken);
        var paidDirectory = Path.Combine(storage.Root, paid);
        foreach (var path in Directory.EnumerateFiles(paidDirectory, "*", SearchOption.AllDirectories)) File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(-3));
        foreach (var path in Directory.EnumerateDirectories(paidDirectory, "*", SearchOption.AllDirectories).Append(paidDirectory))
            Directory.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(-3));
        await File.WriteAllTextAsync(Path.Combine(storage.Root, Audio), "stray", TestContext.Current.CancellationToken);
        Assert.Equal([bare], await index.EvictAsync(0, new HashSet<string>(), true, TestContext.Current.CancellationToken));
        static IEnumerable<string> Names(string directory) => new DirectoryInfo(directory).EnumerateFileSystemInfos().Select(item => item.Name).Order(StringComparer.Ordinal);
        Assert.Equal([Envelope, "meta.json", "transcripts"], Names(Path.Combine(storage.Root, keys[0])));
        Assert.Equal(["raw.json"], Names(transcripts));
        Assert.Equal([Envelope, "meta.json"], Names(Path.Combine(storage.Root, keys[1])));
        Assert.Equal(66L, Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken), entry => entry.ContentKey == keys[0]).Bytes);
        Assert.Equal(["transcripts"], Names(Path.Combine(storage.Root, paid)));
        Assert.False(File.Exists(Path.Combine(storage.Root, Audio)));
        Assert.Equal(new[] { keys[0], keys[1], paid }.Order(StringComparer.Ordinal),
            (await index.EvictAsync(0, new HashSet<string>(), TestContext.Current.CancellationToken)).Order(StringComparer.Ordinal));
        Assert.Empty(Directory.EnumerateFileSystemEntries(storage.Root));
    }

    private static MediaInfo Media(TestStorage storage) => new(storage.PathFor("take.mov"), 1, null, null, new(1920, 1080), null, null, false, 0, 0, 0);

    /// <summary>Writes what FfmpegAudioExtractor writes into the request's directory, with bytes that name the source: the
    /// WAV, the envelope and its own meta.json, with default DateTimeOffset text ("+00:00") and createdAt now.</summary>
    private sealed class RecordingExtractor : IAudioExtractor
    {
        internal static byte[] Levels(string key)
        {
            var bytes = new byte[16 * 4];
            for (var index = 0; index < 16; index++) BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(index * 4), (key[0] - 'a' + 1) / 10f);
            return bytes;
        }

        internal static byte[] Metadata(string key, long bytes, DateTimeOffset now)
        {
            using var stream = new MemoryStream();
            using (var json = new Utf8JsonWriter(stream))
            {
                json.WriteStartObject();
                json.WriteString("schema", "voxclip-cache/1");
                json.WriteString("contentKey", key);
                json.WriteString("createdAt", now);
                json.WriteString("lastAccessAt", now);
                json.WriteNumber("bytes", bytes);
                json.WriteStartObject("envelope");
                json.WriteNumber("sampleRate", 44100);
                json.WriteNumber("frameSeconds", 0.01);
                json.WriteNumber("count", 16);
                json.WriteEndObject();
                json.WriteEndObject();
            }
            return stream.ToArray();
        }

        public async Task<AudioExtractionResult> ExtractAsync(AudioExtractionRequest request, IProgress<MediaProgress>? progress, CancellationToken ct)
        {
            Directory.CreateDirectory(request.CacheDirectory);
            var wav = Path.Combine(request.CacheDirectory, Audio);
            await File.WriteAllBytesAsync(wav, Enumerable.Repeat((byte)request.ContentKey[0], 4000).ToArray(), ct);
            var levels = Levels(request.ContentKey);
            await File.WriteAllBytesAsync(Path.Combine(request.CacheDirectory, Envelope), levels, ct);
            await File.WriteAllBytesAsync(Path.Combine(request.CacheDirectory, "meta.json"), Metadata(request.ContentKey, 4000 + levels.Length, DateTimeOffset.UtcNow), ct);
            var rms = Enumerable.Range(0, 16).Select(index => BinaryPrimitives.ReadSingleLittleEndian(levels.AsSpan(index * 4))).ToArray();
            return new(new(wav, 16000, 1, 0, 0), new(44100, 0.01, rms));
        }
    }

    private sealed class StubTranscriber : ITranscriber
    {
        public TranscriptEngine Engine => TranscriptEngine.Elevenlabs;
        public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, null, null, false);
        public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromResult(true);
        public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(new Readiness.Ready());
        public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
        public Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
            => Task.FromResult(new RawTranscript(new(Engine, "scribe_v2", null, "scribe_v2", null), 1,
                new(GroupingEnd.LastToken, GroupingConfidence.Single, false), [new("hello", false, 0.1, 0.4, 0.9, null, null, 0)],
                "en", null, true, TimingSource.Native, null));
    }
}

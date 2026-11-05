using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Music;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>The music sources on Windows (doc/spec/music.md §3, §5), the twin of the Mac's OpenverseMusicClientTests,
/// ElevenMusicClientTests and MusicSuggestionServiceTests. Every reply is hand-written; nothing reaches the network.</summary>
public sealed class MusicSourcesTests
{
    private sealed class Http(params MusicHttpReply[] replies) : IMusicHttp
    {
        private readonly Queue<MusicHttpReply> queue = new(replies);
        internal List<(HttpMethod Method, Uri Uri, Dictionary<string, string> Headers, string? Body)> Sent { get; } = [];
        public async Task<MusicHttpReply> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var headers = request.Headers.ToDictionary(header => header.Key, header => string.Join(",", header.Value), StringComparer.OrdinalIgnoreCase);
            Sent.Add((request.Method, request.RequestUri!, headers, request.Content is null ? null : await request.Content.ReadAsStringAsync(ct)));
            return queue.Count > 0 ? queue.Dequeue() : throw new InvalidOperationException("no reply");
        }
    }

    private sealed class Keys(string? key) : IKeyProvider
    {
        internal List<string> Asked { get; } = [];
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) { Asked.Add(account); return Task.FromResult(key); }
    }

    private static JsonObject Row(string id, string license, string title = "Track", string filetype = "mp3", int milliseconds = 120_000, string[]? tags = null,
        string? attribution = "“Track” by Someone, CC BY 4.0", bool mature = false, string url = "https://cdn.example/track.mp3") => new()
    {
        ["id"] = id, ["title"] = title, ["creator"] = "Someone", ["license"] = license, ["url"] = url, ["foreign_landing_url"] = "https://www.jamendo.com/track/" + id,
        ["filetype"] = filetype, ["duration"] = milliseconds, ["attribution"] = attribution, ["mature"] = mature, ["category"] = "music",
        ["tags"] = new JsonArray((tags ?? []).Select(tag => (JsonNode)new JsonObject { ["name"] = tag }).ToArray()), ["genres"] = new JsonArray()
    };

    private static MusicHttpReply Results(params JsonObject[] rows) =>
        new(200, System.Text.Encoding.UTF8.GetBytes(new JsonObject { ["results"] = new JsonArray(rows.Select(row => (JsonNode)row).ToArray()) }.ToJsonString()), "application/json");

    private static readonly IReadOnlySet<string> NoWords = new HashSet<string>();

    [Fact]
    public async Task OpenverseAsksForFreeMusicKeepsOnlyCcZeroByAndPdmAndRanksInstrumentalsFirst()
    {
        var http = new Http(Results(
            Row("1", "by-nc"), Row("2", "by-sa"), Row("3", "by-nd"), Row("4", "cc0", "Calm vocals song", tags: ["vocals"]),
            Row("5", "by", "Calm piano", tags: ["instrumental", "calm"]), Row("6", "pdm", "Old march"), Row("7", "by", attribution: null),
            Row("8", "cc0", mature: true), Row("9", "cc0", url: "http://insecure.example/a.mp3"), Row("10", "cc0", filetype: "ogg"), Row("11", "cc0", milliseconds: 4_000)));
        var client = new OpenverseMusicClient(http);
        var found = await client.SearchAsync("calm piano", new HashSet<string> { "calm", "piano" }, 30, TestContext.Current.CancellationToken);
        Assert.Equal(["openverse-5", "openverse-6", "openverse-4"], found.Select(item => item.Id));
        Assert.Equal((MusicLicense.By, "“Track” by Someone, CC BY 4.0", "https://www.jamendo.com/track/5", "mp3"),
            (found[0].License, found[0].Attribution, found[0].SourceUrl, found[0].FileExtension));
        var (method, uri, headers, _) = Assert.Single(http.Sent);
        Assert.Equal((HttpMethod.Get, "https://api.openverse.org/v1/audio/?q=calm%20piano&license=cc0%2Cby%2Cpdm&category=music&page_size=20"), (method, uri.AbsoluteUri));
        Assert.DoesNotContain(headers.Keys, key => key.Equals("Cookie", StringComparison.OrdinalIgnoreCase) || key.Equals("Authorization", StringComparison.OrdinalIgnoreCase));
        // One search per query: the second ask is answered from the cache.
        await client.SearchAsync("Calm Piano", NoWords, 30, TestContext.Current.CancellationToken);
        Assert.Single(http.Sent);
        Assert.Throws<VoxClipException>(() => OpenverseMusicClient.Parse("{\"oops\":1}"u8.ToArray()));
    }

    [Fact]
    public async Task ARateLimitBlocksSearchesUntilRetryAfterThenTheBackOffDoubles()
    {
        var now = new DateTimeOffset(2026, 11, 5, 12, 0, 0, TimeSpan.Zero);
        var http = new Http(new(429, [], RetryAfter: TimeSpan.FromSeconds(40)), new(429, []), Results(Row("1", "cc0")));
        var client = new OpenverseMusicClient(http, () => now);
        var ct = TestContext.Current.CancellationToken;
        Assert.Equal(VoxClipErrorCode.RateLimited, (await Assert.ThrowsAsync<VoxClipException>(() => client.SearchAsync("a", NoWords, 0, ct))).Code);
        now += TimeSpan.FromSeconds(39);
        await Assert.ThrowsAsync<VoxClipException>(() => client.SearchAsync("b", NoWords, 0, ct));
        Assert.Single(http.Sent);
        now += TimeSpan.FromSeconds(2);
        // No Retry-After: the back-off, doubled from 15 s by the first 429, is 30 s.
        await Assert.ThrowsAsync<VoxClipException>(() => client.SearchAsync("b", NoWords, 0, ct));
        now += TimeSpan.FromSeconds(29);
        await Assert.ThrowsAsync<VoxClipException>(() => client.SearchAsync("c", NoWords, 0, ct));
        Assert.Equal(2, http.Sent.Count);
        now += TimeSpan.FromSeconds(2);
        Assert.Single(await client.SearchAsync("c", NoWords, 0, ct));
    }

    [Fact]
    public async Task ADownloadHappensOnlyOnUseAndRefusesTextOrEmptyReplies()
    {
        var track = new MusicCandidate("openverse-1", MusicSource.Library, "T", MusicLicense.Cc0, "mp3") { Audio = "https://cdn.example/t.mp3" };
        var ct = TestContext.Current.CancellationToken;
        var http = new Http(new(200, [1, 2, 3], "audio/mpeg"), new(200, "<html>"u8.ToArray(), "text/html"), new(200, [], "audio/mpeg"), new(404, []));
        var client = new OpenverseMusicClient(http);
        Assert.Equal([1, 2, 3], await client.DownloadAsync(track, ct));
        await Assert.ThrowsAsync<VoxClipException>(() => client.DownloadAsync(track, ct));
        await Assert.ThrowsAsync<VoxClipException>(() => client.DownloadAsync(track, ct));
        await Assert.ThrowsAsync<VoxClipException>(() => client.DownloadAsync(track, ct));
        await Assert.ThrowsAsync<VoxClipException>(() => client.DownloadAsync(track with { Audio = "http://cdn.example/t.mp3" }, ct));
        Assert.Equal(4, http.Sent.Count);
    }

    [Fact]
    public async Task ElevenMusicIsPricedFromTheCatalogueSentOnceAndRecordedWhenAccepted()
    {
        var ct = TestContext.Current.CancellationToken;
        var catalog = VoiceLabPrices.Load(FixtureLoader.SharedRoot);
        var directory = Directory.CreateTempSubdirectory("voxclip-music-ledger-").FullName;
        try
        {
            var ledger = new VoiceLabSpendLedger(Path.Combine(directory, "spend.json"));
            byte[] mp3 = [0x49, 0x44, 0x33, .. new byte[200]];
            var http = new Http(new(200, mp3, "audio/mpeg"), new(422, "{\"detail\":[{\"msg\":\"prompt too vague\"}]}"u8.ToArray()));
            var keys = new Keys("test-key");
            var client = new ElevenMusicClient(keys, catalog, ledger, ElevenLabsRegion.Default, http);
            // 41.2 s rounds up to 42 s: $0.15 per minute is $0.105, labelled $0.11.
            var quote = client.Quote("Instrumental calm piano", 41.2);
            Assert.Equal((42, "$0.11"), (quote.LengthSeconds, MusicPricing.Label(quote.Estimate)));
            Assert.Equal(0.105m, quote.Estimate.Usd);
            Assert.Equal((3, 300), (MusicPricing.LengthSeconds(0.4), MusicPricing.LengthSeconds(900)));
            Assert.Equal(mp3, await client.ComposeAsync(quote, ct));
            var (method, uri, headers, body) = Assert.Single(http.Sent);
            Assert.Equal((HttpMethod.Post, "https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128"), (method, uri.AbsoluteUri));
            Assert.Equal(("test-key", "audio/mpeg"), (headers["xi-api-key"], headers["Accept"]));
            Assert.Equal("{\"force_instrumental\":true,\"model_id\":\"music_v1\",\"music_length_ms\":42000,\"prompt\":\"Instrumental calm piano\"}", body);
            Assert.Equal([ElevenMusicClient.KeyAccount], keys.Asked);
            Assert.Equal(0.105m, (await ledger.TotalAsync("elevenlabs", DateTimeOffset.UtcNow, ct))?.Usd);
            // A quote is used once; a failure is reported, never retried, and nothing is charged.
            await Assert.ThrowsAsync<VoxClipException>(() => client.ComposeAsync(quote, ct));
            Assert.Single(http.Sent);
            var second = client.Quote("Vague", 10);
            Assert.Equal("Eleven Music: prompt too vague", (await Assert.ThrowsAsync<VoxClipException>(() => client.ComposeAsync(second, ct))).Message);
            Assert.Equal(2, http.Sent.Count);
            Assert.Equal(0.105m, (await ledger.TotalAsync("elevenlabs", DateTimeOffset.UtcNow, ct))?.Usd);
            // Stale after ten minutes; no key, nothing sent.
            var clock = DateTimeOffset.UtcNow;
            var timed = new ElevenMusicClient(keys, catalog, null, ElevenLabsRegion.Default, http, () => clock);
            var old = timed.Quote("Piano", 10);
            clock += TimeSpan.FromMinutes(11);
            await Assert.ThrowsAsync<VoxClipException>(() => timed.ComposeAsync(old, ct));
            var keyless = new ElevenMusicClient(new Keys(null), catalog, null, ElevenLabsRegion.Default, http);
            Assert.Equal(VoxClipErrorCode.KeyMissing, (await Assert.ThrowsAsync<VoxClipException>(() => keyless.ComposeAsync(keyless.Quote("Piano", 10), ct))).Code);
            Assert.Equal(2, http.Sent.Count);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task SuggestionsOfferOnePerSourceAndNotesNeverHideTheOthers()
    {
        var ct = TestContext.Current.CancellationToken;
        var folder = Directory.CreateTempSubdirectory("voxclip-music-folder-").FullName;
        try
        {
            File.WriteAllBytes(Path.Combine(folder, "Calm morning.mp3"), [1]);
            File.WriteAllBytes(Path.Combine(folder, "Upbeat.wav"), [1]);
            File.WriteAllBytes(Path.Combine(folder, "notes.txt"), [1]);
            Assert.Equal(["Calm morning", "Upbeat"], MusicLibraryFolder.Files(folder).Select(file => file.Title));
            var catalog = VoiceLabPrices.Load(FixtureLoader.SharedRoot);
            var eleven = new ElevenMusicClient(new Keys("k"), catalog, null, ElevenLabsRegion.Default, new Http());
            var service = new MusicSuggestionService(new OpenverseMusicClient(new Http(Results(Row("5", "cc0", "Calm piano")))), eleven, _ => Task.FromResult(true), () => folder);
            var brief = new MusicBrief("calm", "calm piano", "", "Warm under the voice");
            var result = await service.CandidatesAsync(brief, 20, ct);
            Assert.Equal([MusicSource.Library, MusicSource.Generated, MusicSource.File], result.Candidates.Select(item => item.Source));
            Assert.Equal(("Calm", "Instrumental background music, calm mood, steady, sits under a voice", 20.0), (result.Candidates[1].Title, result.Candidates[1].Prompt, result.Candidates[1].DurationSeconds));
            Assert.Equal(("Calm morning", "From your Music folder"), (result.Candidates[2].Title, result.Candidates[2].Reason));
            Assert.NotNull(service.Quote(result.Candidates[1]));
            Assert.Null(service.Quote(result.Candidates[1]));
            // Offline and keyless: the folder still answers, with a note per missing source.
            var offline = new MusicSuggestionService(new OpenverseMusicClient(new FailingHttp()), eleven, _ => Task.FromResult(false), () => folder);
            var notes = await offline.CandidatesAsync(brief, 20, ct);
            Assert.Equal([MusicSource.File], notes.Candidates.Select(item => item.Source));
            Assert.Equal("You're offline, so only your own files are shown.", notes.Notes[MusicSource.Library]);
            Assert.Equal("Add an ElevenLabs key in Settings to make music for this clip.", notes.Notes[MusicSource.Generated]);
        }
        finally { Directory.Delete(folder, true); }
    }

    private sealed class FailingHttp : IMusicHttp
    {
        public Task<MusicHttpReply> SendAsync(HttpRequestMessage request, CancellationToken ct) => throw new VoxClipException(VoxClipErrorCode.Offline, "You're offline.");
    }

    [Fact]
    public void StoredTracksAreNamedByContentAndCreditedInThePostText()
    {
        var data = Directory.CreateTempSubdirectory("voxclip-music-store-").FullName;
        try
        {
            var project = "00000000-0000-4000-8000-000000000001";
            var stored = MusicAssetStore.Store([1, 2, 3, 4], "Café — Calm Piano!", "mp3", project, data);
            Assert.Matches("^00000000-0000-4000-8000-000000000001/music-cafe-calm-piano-[0-9a-f]{8}\\.mp3$", stored.File);
            Assert.Equal(stored, MusicAssetStore.Store([1, 2, 3, 4], "Café — Calm Piano!", "mp3", project, data));
            Assert.Equal("track", MusicAssetStore.Slug("!!!"));
            var candidate = new MusicCandidate("openverse-5", MusicSource.Library, "Calm piano", MusicLicense.By, "mp3")
            { Creator = "Someone", Attribution = "“Calm piano” by Someone, CC BY 4.0", SourceUrl = "https://www.jamendo.com/track/5" };
            var entry = MusicAssetStore.Entry(candidate, stored, 95, "clip-a");
            Assert.Equal((-20.0, true, 0.5, 1.5, 0.0, "clip-a"), (entry.GainDb, entry.Ducking, entry.FadeInSeconds, entry.FadeOutSeconds, entry.StartOffsetSeconds, entry.ClipId));
            Assert.Equal("Sleep first.\n\nMusic: “Calm piano” by Someone, CC BY 4.0", MusicCredits.PostText("Sleep first. ", entry));
            Assert.Equal("Sleep first.\n\nMusic: “Calm piano” by Someone, CC BY 4.0", MusicCredits.PostText("Sleep first.\n\nMusic: “Calm piano” by Someone, CC BY 4.0", entry));
            Assert.Equal("Music: “Calm piano” by Someone (CC0) https://www.jamendo.com/track/5", MusicCredits.Line(entry with { License = MusicLicense.Cc0, Attribution = null }));
            Assert.Equal("Music: “Calm piano”, made with Eleven Music.", MusicCredits.Line(entry with { Source = MusicSource.Generated, License = MusicLicense.Generated }));
            Assert.Null(MusicCredits.Line(entry with { Source = MusicSource.File, License = MusicLicense.Own }));
            Assert.Throws<VoxClipException>(() => MusicAssetStore.Entry(candidate, stored, 1900, null));
        }
        finally { Directory.Delete(data, true); }
    }
}

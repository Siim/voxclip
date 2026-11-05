using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Core.Services.Music;

/// <summary>A reply from a music source: status, body (bounded), content type and Retry-After.</summary>
public sealed record MusicHttpReply(int Status, byte[] Body, string? ContentType = null, TimeSpan? RetryAfter = null);

/// <summary>The one network seam the music sources use; tests pass hand-written replies, never a live call.</summary>
public interface IMusicHttp
{
    /// <summary>Sends <paramref name="request"/> over HTTPS; offline is <see cref="VoxClipErrorCode.Offline"/>.</summary>
    Task<MusicHttpReply> SendAsync(HttpRequestMessage request, CancellationToken ct);
}

/// <summary>Cookie-less HTTPS transport with no redirects and a reply size limit (twin of Mac URLSessionMusicHTTP).</summary>
public sealed class HttpClientMusicHttp(TimeSpan timeout, long maximumBytes = 64L * 1024 * 1024) : IMusicHttp
{
    private readonly HttpClient client = new(new SocketsHttpHandler { ConnectTimeout = TimeSpan.FromSeconds(30), UseCookies = false, AllowAutoRedirect = true, MaxAutomaticRedirections = 5 })
    { Timeout = timeout };

    /// <inheritdoc />
    public async Task<MusicHttpReply> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        if (request.RequestUri?.Scheme != Uri.UriSchemeHttps) throw new VoxClipException(VoxClipErrorCode.ProviderError, "Music sources use HTTPS only.");
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri?.Scheme != Uri.UriSchemeHttps)
                throw new VoxClipException(VoxClipErrorCode.ProviderError, "The music source replied without HTTPS.");
            await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            using var buffer = new MemoryStream();
            var chunk = new byte[81920];
            int read;
            while ((read = await stream.ReadAsync(chunk, ct).ConfigureAwait(false)) > 0)
            {
                if (buffer.Length + read > maximumBytes) throw new VoxClipException(VoxClipErrorCode.ProviderError, "The music file is too large.");
                buffer.Write(chunk, 0, read);
            }
            var retry = response.Headers.RetryAfter;
            return new((int)response.StatusCode, buffer.ToArray(), response.Content.Headers.ContentType?.MediaType,
                retry?.Delta ?? (retry?.Date is { } date ? date - DateTimeOffset.UtcNow : null));
        }
        catch (HttpRequestException) { throw new VoxClipException(VoxClipErrorCode.Offline, "You're offline."); }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new VoxClipException(VoxClipErrorCode.Offline, "The music source timed out."); }
    }
}

/// <summary>Openverse audio search for free library music (doc/spec/music.md §3.1), the twin of Mac OpenverseMusicClient:
/// <c>GET https://api.openverse.org/v1/audio/?q=…&amp;license=cc0,by,pdm&amp;category=music&amp;page_size=20</c>, anonymous. Only CC0,
/// CC BY and Public Domain Mark results are kept (never nc, nd or sa); each query is cached, so a suggestion sends one search; a
/// 429 blocks searches until its Retry-After (else 15 s, doubling to 10 min). Nothing is retried on its own.</summary>
public sealed class OpenverseMusicClient(IMusicHttp http, Func<DateTimeOffset>? clock = null)
{
    /// <summary>The search endpoint.</summary>
    public const string Endpoint = "https://api.openverse.org/v1/audio/";
    /// <summary>A download is at most 60 MB.</summary>
    public const int MaximumDownloadBytes = 60 * 1024 * 1024;
    private static readonly string[] Allowed = ["cc0", "by", "pdm"];
    private static readonly TimeSpan MinimumBackoff = TimeSpan.FromSeconds(15), MaximumBackoff = TimeSpan.FromMinutes(10);
    private const string WaitMessage = "The free music library asked VoxClip to wait. Try again in a minute.";
    private readonly Func<DateTimeOffset> now = clock ?? (() => DateTimeOffset.UtcNow);
    private readonly Lock gate = new();
    private readonly Dictionary<string, IReadOnlyList<MusicCandidate>> cache = new(StringComparer.Ordinal);
    private DateTimeOffset? blockedUntil;
    private TimeSpan backoff = MinimumBackoff;

    /// <summary>The search URL for <paramref name="query"/>.</summary>
    public static Uri SearchUri(string query, int pageSize = 20) =>
        new($"{Endpoint}?q={Uri.EscapeDataString(query)}&license=cc0%2Cby%2Cpdm&category=music&page_size={pageSize}");

    /// <summary>Playable library candidates for <paramref name="query"/>, best first for the brief's keywords and the clip's length.</summary>
    public async Task<IReadOnlyList<MusicCandidate>> SearchAsync(string query, IReadOnlySet<string> keywords, double clipSeconds, CancellationToken ct)
    {
        var key = query.ToLowerInvariant();
        lock (gate)
        {
            if (cache.TryGetValue(key, out var found)) return Ranked(found, keywords, clipSeconds);
            if (blockedUntil is { } until && now() < until) throw new VoxClipException(VoxClipErrorCode.RateLimited, WaitMessage);
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, SearchUri(query));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        var reply = await http.SendAsync(request, ct).ConfigureAwait(false);
        if (reply.Status == 429)
        {
            lock (gate)
            {
                var wait = reply.RetryAfter is { } retry && retry >= TimeSpan.Zero ? (retry > TimeSpan.FromHours(1) ? TimeSpan.FromHours(1) : retry) : backoff;
                blockedUntil = now() + wait;
                backoff = backoff * 2 > MaximumBackoff ? MaximumBackoff : backoff * 2;
            }
            throw new VoxClipException(VoxClipErrorCode.RateLimited, WaitMessage);
        }
        if (reply.Status is < 200 or >= 300) throw new VoxClipException(VoxClipErrorCode.ProviderError, $"The free music library replied {reply.Status}.");
        var candidates = Parse(reply.Body);
        lock (gate) { cache[key] = candidates; backoff = MinimumBackoff; blockedUntil = null; }
        return Ranked(candidates, keywords, clipSeconds);
    }

    /// <summary>Keeps only CC0, CC BY and PDM music with an HTTPS file and landing page, a known audio type and 10 s–30 min.</summary>
    public static IReadOnlyList<MusicCandidate> Parse(byte[] json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); }
        catch (JsonException) { root = null; }
        if (root?["results"] is not JsonArray results) throw new VoxClipException(VoxClipErrorCode.ProviderError, "The free music library sent an unreadable reply.");
        return results.Select(row => row is JsonObject item ? Candidate(item) : null).OfType<MusicCandidate>().ToArray();
    }

    private static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static MusicCandidate? Candidate(JsonObject row)
    {
        var id = Text(row["id"]);
        var license = Text(row["license"])?.ToLowerInvariant();
        var file = Text(row["url"]);
        var landing = Text(row["foreign_landing_url"]);
        if (id is not { Length: > 0 and <= 64 } || license is null || !Allowed.Contains(license)) return null;
        if (row["mature"] is JsonValue mature && mature.TryGetValue<bool>(out var isMature) && isMature) return null;
        if (file is null || !Uri.TryCreate(file, UriKind.Absolute, out var fileUri) || fileUri.Scheme != Uri.UriSchemeHttps) return null;
        if (landing is null || !landing.StartsWith("https://", StringComparison.Ordinal) || landing.Length > 2048 || landing.Any(char.IsWhiteSpace)) return null;
        if (Text(row["category"]) is { } category && category != "music") return null;
        if (Extension(Text(row["filetype"]), fileUri) is not { } extension) return null;
        double? duration = row["duration"] is JsonValue length && length.TryGetValue<double>(out var milliseconds) ? milliseconds / 1000 : null;
        if (duration is { } seconds && (seconds < 10 || seconds > 1800)) return null;
        var attribution = Clipped(Text(row["attribution"]), 1000);
        var licensed = license switch { "cc0" => MusicLicense.Cc0, "by" => MusicLicense.By, _ => MusicLicense.Pdm };
        if (licensed == MusicLicense.By && attribution is null) return null;
        var tags = (row["genres"] as JsonArray ?? []).Select(Text).Concat((row["tags"] as JsonArray ?? []).Select(tag => Text(tag?["name"])))
            .OfType<string>().Take(24).ToArray();
        return new("openverse-" + id, MusicSource.Library, Clipped(Text(row["title"]), 200) ?? "Untitled", licensed, extension)
        {
            Creator = Clipped(Text(row["creator"]), 200), Attribution = attribution, SourceUrl = landing, Audio = file, DurationSeconds = duration, Tags = tags
        };
    }

    private static string? Clipped(string? text, int limit)
    {
        var visible = new string((text ?? "").Trim().Where(character => !char.IsControl(character)).ToArray());
        return visible.Length == 0 ? null : visible.Length <= limit ? visible : visible[..limit];
    }

    private static string? Extension(string? filetype, Uri file) =>
        (filetype ?? Path.GetExtension(file.AbsolutePath).TrimStart('.')).ToLowerInvariant() switch
        {
            "mp3" or "mp32" or "mpeg" => "mp3", "wav" or "wave" => "wav", "flac" => "flac", "m4a" or "aac" or "mp4" => "m4a", "aif" or "aiff" => "aiff", _ => null
        };

    /// <summary>Best first: instrumental tags, matching words, long enough not to loop; vocals last. Ties keep Openverse order.</summary>
    public static IReadOnlyList<MusicCandidate> Ranked(IReadOnlyList<MusicCandidate> candidates, IReadOnlySet<string> keywords, double clipSeconds)
    {
        int Score(MusicCandidate candidate)
        {
            var words = MusicWords.Split(string.Join(" ", candidate.Tags.Prepend(candidate.Title))).ToHashSet(StringComparer.Ordinal);
            var value = words.Count(keywords.Contains) * 2;
            if (words.Contains("instrumental")) value += 3;
            if (words.Overlaps(["vocal", "vocals", "singer", "lyrics", "song", "rap"])) value -= 3;
            if (candidate.DurationSeconds is { } duration && duration >= clipSeconds) value += 1;
            return value;
        }
        return candidates.Select((candidate, index) => (candidate, index, score: Score(candidate)))
            .OrderByDescending(item => item.score).ThenBy(item => item.index).Select(item => item.candidate).ToArray();
    }

    /// <summary>Downloads a chosen track: only when the user, or the one-click plan, uses it.</summary>
    public async Task<byte[]> DownloadAsync(MusicCandidate candidate, CancellationToken ct)
    {
        if (candidate.Source != MusicSource.Library || candidate.Audio is not { } audio || !audio.StartsWith("https://", StringComparison.Ordinal))
            throw new VoxClipException(VoxClipErrorCode.ProviderError, "This track has no download.");
        using var request = new HttpRequestMessage(HttpMethod.Get, audio);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("audio/*"));
        var reply = await http.SendAsync(request, ct).ConfigureAwait(false);
        if (reply.Status is < 200 or >= 300) throw new VoxClipException(VoxClipErrorCode.ProviderError, $"The track's host replied {reply.Status}.");
        if (reply.Body.Length == 0 || reply.Body.Length > MaximumDownloadBytes) throw new VoxClipException(VoxClipErrorCode.ProviderError, "The track is empty or larger than 60 MB.");
        if (reply.ContentType?.ToLowerInvariant() is { } type && (type.StartsWith("text/", StringComparison.Ordinal) || type.Contains("json", StringComparison.Ordinal)))
            throw new VoxClipException(VoxClipErrorCode.ProviderError, "The track's host did not send audio.");
        return reply.Body;
    }
}

/// <summary>A priced, not yet sent Eleven Music request. The inline "Make · $0.11" click that shows it is the approval; it is used
/// once and goes stale after ten minutes.</summary>
public sealed record MusicQuote(Guid Id, string Prompt, int LengthSeconds, CostEstimate Estimate, DateTimeOffset CreatedAt);

/// <summary>Eleven Music compose (doc/spec/music.md §3.2), the twin of Mac ElevenMusicClient: <c>POST {region}/v1/music?output_format=
/// mp3_44100_128</c> with <c>xi-api-key</c> and <c>{prompt, music_length_ms, model_id "music_v1", force_instrumental true}</c>; the reply
/// body is the MP3. Priced from the catalogue's <c>musicCompose</c> row; sent once, never retried; the spend ledger records the
/// estimate when the provider accepts it (a 2xx), as Voice Lab does.</summary>
public sealed class ElevenMusicClient(IKeyProvider keys, VoiceLabPriceCatalog catalog, VoiceLabSpendLedger? spend, ElevenLabsRegion region, IMusicHttp http,
    Func<DateTimeOffset>? clock = null)
{
    /// <summary>The key's account, shared with transcription and Voice Lab.</summary>
    public const string KeyAccount = "elevenlabs-api-key";
    /// <summary>The compose path.</summary>
    public const string PathName = "/v1/music";
    /// <summary>The audio format asked for.</summary>
    public const string OutputFormat = "mp3_44100_128";
    /// <summary>A quote is good for ten minutes.</summary>
    public static readonly TimeSpan QuoteLifetime = TimeSpan.FromMinutes(10);
    private readonly Func<DateTimeOffset> now = clock ?? (() => DateTimeOffset.UtcNow);
    private readonly Lock gate = new();
    private readonly Dictionary<Guid, MusicQuote> quotes = [];

    /// <summary>Prices a track as long as the clip, without sending anything.</summary>
    public MusicQuote Quote(string prompt, double clipSeconds)
    {
        var text = prompt.Trim();
        if (text.Length is 0 or > 2000) throw new VoxClipException(VoxClipErrorCode.ProviderError, "The music prompt is empty or too long.");
        var seconds = MusicPricing.LengthSeconds(clipSeconds);
        var quote = new MusicQuote(Guid.NewGuid(), text, seconds, MusicPricing.Estimate(seconds, catalog), now());
        lock (gate) quotes[quote.Id] = quote;
        return quote;
    }

    /// <summary>The request exactly as sent; the key goes only in <c>xi-api-key</c>.</summary>
    public HttpRequestMessage Request(MusicQuote quote, string key)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, new Uri(region.BaseUri(), PathName + "?output_format=" + OutputFormat));
        request.Headers.TryAddWithoutValidation("xi-api-key", key);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("audio/mpeg"));
        var body = new JsonObject { ["force_instrumental"] = true, ["model_id"] = MusicPricing.Model, ["music_length_ms"] = quote.LengthSeconds * 1000, ["prompt"] = quote.Prompt };
        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        return request;
    }

    /// <summary>Sends the approved quote once and returns MP3 bytes. A stale, unknown or used quote is refused before anything is sent.</summary>
    public async Task<byte[]> ComposeAsync(MusicQuote quote, CancellationToken ct)
    {
        bool fresh;
        lock (gate) { fresh = quotes.Remove(quote.Id, out var stored) && stored == quote && now() - quote.CreatedAt <= QuoteLifetime; }
        if (!fresh) throw new VoxClipException(VoxClipErrorCode.ProviderError, "This price is out of date. Make it again to see the current price.");
        if (await keys.GetKeyAsync(KeyAccount, ct).ConfigureAwait(false) is not { Length: > 0 } key)
            throw new VoxClipException(VoxClipErrorCode.KeyMissing, "Add an ElevenLabs key in Settings to make music for this clip.");
        using var request = Request(quote, key);
        var start = now();
        var reply = await http.SendAsync(request, ct).ConfigureAwait(false);
        if (reply.Status is >= 200 and < 300 && spend is not null) await spend.RecordAsync(quote.Estimate, start, CancellationToken.None).ConfigureAwait(false);
        return reply.Status switch
        {
            >= 200 and < 300 when reply.Body.Length >= 128 && reply.Body.Length <= 40 * 1024 * 1024 && LooksLikeMp3(reply.Body) => reply.Body,
            >= 200 and < 300 => throw new VoxClipException(VoxClipErrorCode.ProviderError, "Eleven Music sent audio VoxClip could not read."),
            401 or 403 => throw new VoxClipException(VoxClipErrorCode.KeyRejected, "ElevenLabs didn't accept the key. Check it in Settings."),
            402 => throw new VoxClipException(VoxClipErrorCode.QuotaExceeded, "Your ElevenLabs quota is used up."),
            429 => throw new VoxClipException(VoxClipErrorCode.RateLimited, "ElevenLabs asked VoxClip to wait. Try again in a minute."),
            _ => throw new VoxClipException(VoxClipErrorCode.ProviderError, Detail(reply.Body) ?? $"Eleven Music replied {reply.Status}.")
        };
    }

    private static bool LooksLikeMp3(byte[] data) =>
        data.Length >= 3 && (data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 || data[0] == 0xFF && (data[1] & 0xE0) == 0xE0);

    private static string? Detail(byte[] data)
    {
        try
        {
            var root = JsonNode.Parse(data);
            var message = (root?["detail"] as JsonArray)?.FirstOrDefault()?["msg"]?.GetValue<string>() ?? root?["detail"]?["message"]?.GetValue<string>();
            return message is null ? null : "Eleven Music: " + (message.Length <= 200 ? message : message[..200]);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException) { return null; }
    }
}

/// <summary>The user's own music (doc/spec/music.md §3.3): the Music folder (default <c>Music\VoxClip</c> under the user's profile
/// when it exists) and "Add a file…" for MP3, M4A, WAV and AIFF.</summary>
public static class MusicLibraryFolder
{
    /// <summary>The types offered.</summary>
    public static readonly IReadOnlySet<string> Extensions = new HashSet<string>(["mp3", "m4a", "wav", "aif", "aiff"], StringComparer.Ordinal);

    /// <summary><c>Music\VoxClip</c> when that folder exists, else null.</summary>
    public static string? DefaultFolder(string? music = null)
    {
        var folder = Path.Combine(music ?? Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "VoxClip");
        return Directory.Exists(folder) ? folder : null;
    }

    /// <summary>The folder's music files (not its subfolders), by name, at most 200.</summary>
    public static IReadOnlyList<MusicCandidate> Files(string? folder)
    {
        if (folder is null || !Directory.Exists(folder)) return [];
        try
        {
            return Directory.EnumerateFiles(folder).Where(path => !Path.GetFileName(path).StartsWith('.')).Select(Candidate).OfType<MusicCandidate>()
                .OrderBy(file => file.Title, StringComparer.CurrentCultureIgnoreCase).Take(200).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return []; }
    }

    /// <summary>A candidate for one of the user's files, or null for another type.</summary>
    public static MusicCandidate? Candidate(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!Extensions.Contains(extension)) return null;
        var title = Path.GetFileNameWithoutExtension(path);
        title = title.Length <= 200 ? title : title[..200];
        return new("file-" + path, MusicSource.File, title.Length == 0 ? "Untitled" : title, MusicLicense.Own, extension == "aif" ? "aiff" : extension)
        { Audio = path, Tags = MusicWords.Split(title).ToArray() };
    }

    /// <summary>The file whose name shares the most words with the brief; null when none shares any.</summary>
    public static MusicCandidate? Best(IReadOnlyList<MusicCandidate> files, IReadOnlySet<string> keywords) =>
        files.Select(file => (file, score: file.Tags.Distinct().Count(keywords.Contains))).Where(item => item.score > 0)
            .OrderByDescending(item => item.score).Select(item => item.file).FirstOrDefault();
}

/// <summary>Stores a used track as <c>&lt;data&gt;/Music/&lt;projectId&gt;/music-&lt;slug&gt;-&lt;hash8&gt;.&lt;ext&gt;</c> (music.md §2). The name carries
/// the content hash, so a track is stored once and an existing file is never overwritten.</summary>
public static class MusicAssetStore
{
    /// <summary>Stores <paramref name="data"/>; returns the project-relative file, its SHA-256 and its full path.</summary>
    public static (string File, string Sha256, string Path) Store(byte[] data, string title, string extension, string projectId, string dataRoot)
    {
        if (data.Length == 0 || data.Length > 200 * 1024 * 1024 || extension is not ("mp3" or "m4a" or "wav" or "aif" or "aiff" or "flac"))
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The music file is empty, too large or of an unknown type.");
        var hash = Convert.ToHexStringLower(SHA256.HashData(data));
        var name = "music-" + Slug(title) + "-" + hash[..8] + "." + extension;
        var folder = System.IO.Path.Combine(MusicRenderInput.Root(dataRoot), projectId);
        Directory.CreateDirectory(folder);
        var path = System.IO.Path.Combine(folder, name);
        if (File.Exists(path))
        {
            if (Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path))) != hash)
                throw new VoxClipException(VoxClipErrorCode.ProviderError, "A different music file already has this name; it was kept.");
            return (projectId + "/" + name, hash, path);
        }
        var partial = System.IO.Path.Combine(folder, "." + name + "." + Guid.NewGuid().ToString("N") + ".partial");
        try
        {
            File.WriteAllBytes(partial, data);
            try { File.Move(partial, path, overwrite: false); }
            catch (IOException) when (File.Exists(path)) { return Store(data, title, extension, projectId, dataRoot); }
        }
        finally { if (File.Exists(partial)) File.Delete(partial); }
        return (projectId + "/" + name, hash, path);
    }

    /// <summary>Lower-case letters, digits and dashes, at most 40 characters; "track" when nothing is left.</summary>
    public static string Slug(string title)
    {
        var folded = new string(title.Normalize(NormalizationForm.FormD).Where(character => System.Globalization.CharUnicodeInfo.GetUnicodeCategory(character)
            != System.Globalization.UnicodeCategory.NonSpacingMark).ToArray()).ToLowerInvariant();
        var result = new StringBuilder();
        foreach (var character in folded)
        {
            if (character is >= 'a' and <= 'z' or >= '0' and <= '9') result.Append(character);
            else if (result.Length > 0 && result[^1] != '-') result.Append('-');
            if (result.Length >= 40) break;
        }
        var slug = result.ToString().TrimEnd('-');
        return slug.Length == 0 ? "track" : slug;
    }

    /// <summary>The project entry for a stored candidate, with the default level (−20 dB), ducking and fades (0.5 s, 1.5 s).</summary>
    public static ProjectMusic Entry(MusicCandidate candidate, (string File, string Sha256, string Path) stored, double durationSeconds, string? clipId)
    {
        if (!double.IsFinite(durationSeconds) || durationSeconds <= 0 || durationSeconds > 1800)
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The music file is longer than 30 minutes or has no length.");
        return new("music-" + stored.Sha256[..12], clipId, new(stored.File, stored.Sha256, durationSeconds), candidate.Source, candidate.Title, candidate.Creator,
            candidate.License, candidate.Attribution, candidate.SourceUrl, candidate.Source == MusicSource.Generated ? candidate.Prompt : null,
            -20, true, 0.5, 1.5, 0);
    }
}

/// <summary>Claude's best three across sources for one brief (music.md §3.4), the twin of Mac MusicSuggestionService: one free library
/// match, one Eleven Music track priced but not yet made, and the user's own file when one fits by name. A source that cannot
/// answer adds a note and never hides the others.</summary>
public sealed class MusicSuggestionService(OpenverseMusicClient? library, ElevenMusicClient? eleven, Func<CancellationToken, Task<bool>> hasElevenKey,
    Func<string?> folder)
{
    private readonly Lock gate = new();
    private readonly Dictionary<string, MusicQuote> quotes = new(StringComparer.Ordinal);

    /// <summary>The candidates for <paramref name="brief"/> under a clip of <paramref name="clipSeconds"/>.</summary>
    public async Task<MusicSuggestionResult> CandidatesAsync(MusicBrief brief, double clipSeconds, CancellationToken ct)
    {
        var candidates = new List<MusicCandidate>();
        var notes = new Dictionary<MusicSource, string>();
        if (library is not null)
        {
            try
            {
                var found = await library.SearchAsync(brief.SearchText, brief.Keywords, clipSeconds, ct).ConfigureAwait(false);
                if (found.FirstOrDefault() is { } match)
                    candidates.Add(match with { Reason = brief.Reason ?? (match.Tags.Count == 0 ? null : string.Join(", ", match.Tags.Take(3))) });
                else notes[MusicSource.Library] = $"No free track matched “{brief.SearchText}”. Search other words.";
            }
            catch (VoxClipException exception) { notes[MusicSource.Library] = Note(exception); }
        }
        if (eleven is not null)
        {
            if (await hasElevenKey(ct).ConfigureAwait(false))
            {
                try
                {
                    var quote = eleven.Quote(brief.CompositionPrompt, clipSeconds);
                    var title = brief.Mood.Trim();
                    title = title.Length == 0 ? "Made for this clip" : char.ToUpperInvariant(title[0]) + title[1..];
                    var candidate = new MusicCandidate("eleven-" + quote.Id.ToString("D"), MusicSource.Generated, title.Length <= 200 ? title : title[..200],
                        MusicLicense.Generated, "mp3") { Prompt = quote.Prompt, DurationSeconds = quote.LengthSeconds, Estimate = quote.Estimate, Reason = brief.Reason ?? "Made to the clip's length" };
                    lock (gate) quotes[candidate.Id] = quote;
                    candidates.Add(candidate);
                }
                catch (VoxClipException exception) { notes[MusicSource.Generated] = Note(exception); }
            }
            else notes[MusicSource.Generated] = "Add an ElevenLabs key in Settings to make music for this clip.";
        }
        if (MusicLibraryFolder.Best(MusicLibraryFolder.Files(folder()), brief.Keywords) is { } own) candidates.Add(own with { Reason = "From your Music folder" });
        return new(candidates, notes);
    }

    /// <summary>The approved quote behind a generated candidate, used once.</summary>
    public MusicQuote? Quote(MusicCandidate candidate)
    {
        lock (gate) return quotes.Remove(candidate.Id, out var quote) ? quote : null;
    }

    private static string Note(VoxClipException exception) => exception.Code switch
    {
        VoxClipErrorCode.Offline => "You're offline, so only your own files are shown.",
        VoxClipErrorCode.RateLimited => "The free library asked VoxClip to wait. Try again in a minute.",
        _ => exception.Message.Length > 0 ? exception.Message : "This source is not available right now."
    };
}

using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Settings;

namespace VoxClip.Core.Services.Speech;

/// <summary>File-streamed Scribe v2 batch requests with explicit cloud selection; transcription §8.</summary>
public sealed class ElevenLabsTranscriber : ITranscriber, IDisposable
{
    private static readonly string UserAgent = BuildUserAgent();
    private readonly HttpClient http;
    private readonly IKeyProvider keys;
    private readonly ElevenLabsRegion region;
    private readonly ModelCatalog catalog;
    private readonly Uri endpoint;
    private readonly Uri subscriptionEndpoint;
    private readonly ILog log;
    private readonly ConditionalWeakTable<RawTranscript, ProviderJson> responses = new();
    internal SocketsHttpHandler? OwnedHandler { get; }

    /// <summary>Use no implicit secret source; the app must inject its IKeyProvider.</summary>
    public ElevenLabsTranscriber() : this(new MissingKeys()) { }

    /// <summary>Explicit env provider for the CLI or VOXCLIP_NO_KEYCHAIN debug host only; architecture §9.4.</summary>
    public static IKeyProvider CreateEnvironmentKeyProvider() => new EnvironmentKeys();

    /// <summary>Compose key storage, a closed residency region, catalogue and redacted logging.</summary>
    public ElevenLabsTranscriber(IKeyProvider keys, ElevenLabsRegion region = ElevenLabsRegion.Default,
        ModelCatalog? modelCatalog = null, ILog? logger = null) : this(keys, null, region, modelCatalog, logger) { }

    /// <summary>Use the same stored region for imports and key tests; the CLI uses Default without settings.</summary>
    public static ElevenLabsTranscriber FromSettings(IKeyProvider keys, AppSettings settings,
        ILog? logger = null, ModelCatalog? modelCatalog = null) =>
        new(keys, ElevenLabsRegions.FromSettings(settings, logger), modelCatalog, logger);

    internal static ElevenLabsTranscriber ForTesting(IKeyProvider keys, HttpMessageHandler handler, ElevenLabsRegion region,
        ModelCatalog? modelCatalog = null, ILog? logger = null)
    {
        ArgumentNullException.ThrowIfNull(handler);
        return new(keys, new HttpClient(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan }, region, modelCatalog, logger);
    }

    private ElevenLabsTranscriber(IKeyProvider keyProvider, HttpClient? httpClient, ElevenLabsRegion region,
        ModelCatalog? modelCatalog = null, ILog? logger = null)
    {
        var origin = region.BaseUri();
        this.region = region;
        keys = keyProvider;
        if (httpClient is null)
        {
            OwnedHandler = SpeechTransport.CreateCloudHandler();
            http = new HttpClient(OwnedHandler) { Timeout = Timeout.InfiniteTimeSpan };
        }
        else http = httpClient;
        endpoint = new Uri(origin, "/v1/speech-to-text");
        subscriptionEndpoint = new Uri(origin, "/v1/user/subscription");
        catalog = modelCatalog ?? new ModelCatalog();
        log = logger ?? new Log();
    }

    /// <summary>Dispose the owned client without disposing a handler supplied by the test factory.</summary>
    public void Dispose() => http.Dispose();

    /// <summary>Test the stored key without uploading audio or making a paid call; transcription §8.5.</summary>
    public async Task<ElevenLabsKeyTestResult> TestKeyAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var key = await keys.GetKeyAsync("elevenlabs-api-key", ct).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(key))
            throw new VoxClipException(VoxClipErrorCode.KeyMissing, "Add your ElevenLabs key in Settings to use it.");
        log.RegisterSecret(key);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using var message = new HttpRequestMessage(HttpMethod.Get, subscriptionEndpoint);
            message.Headers.Add("xi-api-key", key);
            message.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            message.Headers.UserAgent.ParseAdd(UserAgent);
            using var response = await http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
            log.Write(LogLevel.Info, "transcribe", $"elevenlabs key test HTTP {(int)response.StatusCode}");
            if (response.StatusCode == HttpStatusCode.OK) return new(true, "Works.");
            await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
            var body = await ReadErrorBodyAsync(stream, deadline.Token).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden && ReportsMissingPermission(body))
                return new(false, "The key works. It can't read account details (user_read), and that is fine for transcription.");
            // Same mapping as transcription: only a 401 or a key error is a rejected key.
            throw MapError(response.StatusCode, body, key, region);
        }
        catch (Exception error) when ((error is HttpRequestException or IOException or OperationCanceledException) && !ct.IsCancellationRequested)
        {
            throw new VoxClipException(VoxClipErrorCode.Offline, "You're offline. On-device transcription and editing still work.");
        }
    }

    /// <inheritdoc />
    public TranscriptEngine Engine => TranscriptEngine.Elevenlabs;
    /// <inheritdoc />
    public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, 36_000, 3_000_000_000, false);
    /// <inheritdoc />
    public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(language is LanguageChoice.Auto || language is LanguageChoice.Forced forced && ValidLanguage(forced.Code));
    }
    /// <inheritdoc />
    public async Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct)
    {
        if (!await SupportsAsync(plan.Language, plan.Model, ct).ConfigureAwait(false)) return new Readiness.UnsupportedLanguage(((LanguageChoice.Forced)plan.Language).Code);
        return string.IsNullOrWhiteSpace(await keys.GetKeyAsync("elevenlabs-api-key", ct).ConfigureAwait(false))
            ? new Readiness.NeedsKey("elevenlabs") : new Readiness.Ready();
    }
    /// <inheritdoc />
    public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct) =>
        TranscribeAndCacheAsync(request, progress, null, ct);

    internal async Task<RawTranscript> TranscribeAndCacheAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress,
        Func<JsonElement, Task>? cachePaidResponse, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ValidatePlan(request.Plan);
        if (!await SupportsAsync(request.Plan.Language, request.Plan.Model, ct).ConfigureAwait(false))
            throw SpeechCopy.Unsupported(Engine, ((LanguageChoice.Forced)request.Plan.Language).Code);
        var data = await catalog.RootAsync(ct).ConfigureAwait(false);
        var limits = data.GetProperty("engines").EnumerateArray().Single(engine => engine.GetProperty("id").GetString() == "elevenlabs").GetProperty("limits");
        var bytes = new FileInfo(request.Audio.Wav16kPath).Length;
        if (!double.IsFinite(request.Audio.DurationSeconds) || request.Audio.DurationSeconds < limits.GetProperty("minDurationSeconds").GetDouble())
            throw new VoxClipException(VoxClipErrorCode.NoSpeech, "We didn't hear any words. Check the audio track or choose the language.");
        if (request.Audio.DurationSeconds > limits.GetProperty("maxDurationSeconds").GetDouble() || bytes > limits.GetProperty("maxUploadBytes").GetDouble())
            throw new VoxClipException(VoxClipErrorCode.MediaTooLong,
                $"ElevenLabs accepts up to 10 hours. This take is {SpeechCopy.Duration(request.Audio.DurationSeconds)}.");
        var forcedLanguage = request.Plan.Language is LanguageChoice.Forced chosen
            ? await catalog.NormalizeLanguageAsync(chosen.Code, ct).ConfigureAwait(false) : null;
        var key = await keys.GetKeyAsync("elevenlabs-api-key", ct).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(key)) throw new VoxClipException(VoxClipErrorCode.KeyMissing, "Add your ElevenLabs key in Settings to use it.");
        log.RegisterSecret(key);
        var reporting = new SpeechProgress<TranscriptionProgress>(progress);
        using var whole = CancellationTokenSource.CreateLinkedTokenSource(ct);
        whole.CancelAfter(TimeSpan.FromHours(2));
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var paidResponseReceived = false;
            try
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(whole.Token);
                idle.CancelAfter(TimeSpan.FromSeconds(300));
                using var message = new HttpRequestMessage(HttpMethod.Post, endpoint);
                message.Headers.Add("xi-api-key", key);
                message.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                message.Headers.UserAgent.ParseAdd(UserAgent);
                using var multipart = new SpeechMultipartContent(Guid.NewGuid().ToString("N"), () =>
                {
                    reporting.Report(new(TranscriptionStage.Uploading, 1));
                    reporting.Report(new(TranscriptionStage.Transcribing, null));
                });
                multipart.Add(new StringContent("scribe_v2"), "model_id");
                if (forcedLanguage is not null) multipart.Add(new StringContent(forcedLanguage), "language_code");
                multipart.Add(new StringContent("word"), "timestamps_granularity");
                multipart.Add(new StringContent("true"), "tag_audio_events");
                multipart.Add(new StringContent(request.Plan.Options.Diarize ? "true" : "false"), "diarize");
                if (request.Plan.Options.Diarize && request.Plan.Options.NumSpeakers is { } count)
                    multipart.Add(new StringContent(count.ToString(CultureInfo.InvariantCulture)), "num_speakers");
                foreach (var term in request.Plan.Options.Keyterms ?? []) multipart.Add(new StringContent(term), "keyterms");
                var file = new StreamContent(new ActivityStream(File.OpenRead(request.Audio.Wav16kPath), received =>
                {
                    idle.CancelAfter(TimeSpan.FromSeconds(300));
                    reporting.Report(new(TranscriptionStage.Uploading, bytes == 0 ? 1 : (double)received / bytes));
                }));
                file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
                multipart.Add(file, "file", "audio.wav");
                message.Content = multipart;
                reporting.Report(new(TranscriptionStage.Uploading, 0));
                using var response = await http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, idle.Token).ConfigureAwait(false);
                log.Write(LogLevel.Info, "transcribe", $"elevenlabs HTTP {(int)response.StatusCode}; attempt {attempt + 1}");
                if (SpeechTransport.Retryable(response.StatusCode) && attempt < 2)
                {
                    await Task.Delay(SpeechTransport.Backoff(response, attempt), whole.Token).ConfigureAwait(false);
                    continue;
                }
                reporting.Report(new(TranscriptionStage.Transcribing, null));
                await using var incoming = await response.Content.ReadAsStreamAsync(idle.Token).ConfigureAwait(false);
                await using var activity = new ActivityStream(incoming, _ => idle.CancelAfter(TimeSpan.FromSeconds(300)));
                if (!response.IsSuccessStatusCode)
                {
                    throw MapError(response.StatusCode, await ReadErrorBodyAsync(activity, idle.Token).ConfigureAwait(false), key, region);
                }
                JsonDocument document;
                try { document = await JsonDocument.ParseAsync(activity, cancellationToken: idle.Token).ConfigureAwait(false); }
                catch (JsonException) { throw UnexpectedResponse(); }
                using (document)
                {
                    paidResponseReceived = true;
                    if (cachePaidResponse is not null && !await SpeechTransport.TryCacheWriteAsync(
                        () => cachePaidResponse(document.RootElement.Clone()), CancellationToken.None).ConfigureAwait(false))
                        WarnCacheUnavailable();
                    var raw = await MapResponseAsync(document.RootElement, request.Plan.Options.Diarize, request.Plan.Language, CancellationToken.None).ConfigureAwait(false);
                    responses.Add(raw, new(document.RootElement.Clone()));
                    var requestId = raw.ProviderRequestId is { } identifier && Regex.IsMatch(identifier, "^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant)
                        ? identifier : "unavailable";
                    log.Write(LogLevel.Info, "transcribe", FormattableString.Invariant($"elevenlabs scribe_v2; bytes {bytes}; duration {request.Audio.DurationSeconds:F3}; request {requestId}"));
                    return raw;
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                log.Write(LogLevel.Info, "transcribe", "elevenlabs transcription cancelled.");
                throw;
            }
            catch (Exception error) when (!paidResponseReceived && (error is HttpRequestException or IOException or OperationCanceledException) && !ct.IsCancellationRequested)
            {
                if (attempt == 2 || whole.IsCancellationRequested)
                    throw new VoxClipException(VoxClipErrorCode.Offline, "You're offline. On-device transcription and editing still work.");
                await Task.Delay(SpeechTransport.Backoff(null, attempt), ct).ConfigureAwait(false);
            }
        }
        throw new VoxClipException(VoxClipErrorCode.ProviderError, "ElevenLabs answered an unknown status: The request could not be completed.");
    }

    internal JsonElement? ProviderResponse(RawTranscript raw) => responses.TryGetValue(raw, out var response) ? response.Json : null;

    internal async Task<RawTranscript> MapResponseAsync(JsonElement body, bool diarize, LanguageChoice choice, CancellationToken ct)
    {
        try { return await MapAsync(body, diarize, choice, ct).ConfigureAwait(false); }
        catch (Exception error) when (error is InvalidOperationException or KeyNotFoundException or FormatException)
        {
            throw UnexpectedResponse();
        }
    }

    internal void WarnCacheUnavailable() => log.Write(LogLevel.Warn, "transcribe",
        "The paid transcript cache could not be written; the completed transcript is still returned for project storage.");

    private async Task<RawTranscript> MapAsync(JsonElement body, bool diarize, LanguageChoice choice, CancellationToken ct)
    {
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty("words", out var words) || words.ValueKind != JsonValueKind.Array ||
            !body.TryGetProperty("language_code", out var language) || language.ValueKind != JsonValueKind.String || body.TryGetProperty("transcripts", out _))
            throw UnexpectedResponse();
        var tokens = new List<RawToken>();
        var unknown = new HashSet<string>(StringComparer.Ordinal);
        foreach (var word in words.EnumerateArray())
        {
            ct.ThrowIfCancellationRequested();
            if (!word.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String) continue;
            var kind = type.GetString();
            if (kind == "spacing") continue;
            if (kind is not ("word" or "audio_event"))
            {
                if (unknown.Add(kind!) && Regex.IsMatch(kind!, "^[a-zA-Z_]{1,64}$", RegexOptions.CultureInvariant)) log.Write(LogLevel.Warn, "transcribe", "Unknown ElevenLabs item type: " + kind);
                continue;
            }
            if (!word.TryGetProperty("text", out var text) || text.ValueKind != JsonValueKind.String) continue;
            var logProbability = Number(word, "logprob");
            tokens.Add(new(TextRules.Trim(text.GetString()!), false, Number(word, "start"), Number(word, "end"),
                kind == "word" && logProbability is { } probability ? Math.Clamp(Math.Exp(probability), 0, 1) : null,
                diarize && word.TryGetProperty("speaker_id", out var speaker) && speaker.ValueKind == JsonValueKind.String ? speaker.GetString() : null,
                kind == "audio_event" ? WordKind.Event : null, 0));
        }
        var code = choice is LanguageChoice.Forced forced ? forced.Code : language.GetString()!;
        return new(new(Engine, "scribe_v2", null, "scribe_v2", null), 1,
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), tokens,
            await catalog.NormalizeLanguageAsync(code, ct).ConfigureAwait(false), Number(body, "language_probability"), true, TimingSource.Native,
            body.TryGetProperty("transcription_id", out var identifier) && identifier.ValueKind == JsonValueKind.String ? identifier.GetString() : null);
    }

    private static VoxClipException UnexpectedResponse() => new(VoxClipErrorCode.ProviderError, "ElevenLabs answered 200: unexpected response shape");

    private static double? Number(JsonElement data, string name) => data.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number) ? number : null;

    private static async Task<string> ReadErrorBodyAsync(Stream stream, CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var length = 0;
        while (length < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(length), ct).ConfigureAwait(false);
            if (read == 0) break;
            length += read;
        }
        return Encoding.UTF8.GetString(buffer, 0, length);
    }

    private static bool ReportsMissingPermission(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            return PermissionDetail(document.RootElement);
        }
        catch (JsonException) { return MissingPermissionMessage(body); }
    }

    private static bool PermissionDetail(JsonElement detail)
    {
        if (detail.ValueKind == JsonValueKind.String) return MissingPermissionMessage(detail.GetString()!);
        if (detail.ValueKind != JsonValueKind.Object) return false;
        if (detail.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.String &&
            status.GetString() is "missing_permissions" or "missing_permission") return true;
        foreach (var field in new[] { "detail", "message", "error" })
            if (detail.TryGetProperty(field, out var value) && PermissionDetail(value)) return true;
        return false;
    }

    private static bool MissingPermissionMessage(string message) =>
        message.Contains("permission", StringComparison.OrdinalIgnoreCase) &&
        (message.Contains("missing", StringComparison.OrdinalIgnoreCase) || message.Contains("lacks", StringComparison.OrdinalIgnoreCase) ||
         message.Contains("does not have", StringComparison.OrdinalIgnoreCase) || message.Contains("doesn't have", StringComparison.OrdinalIgnoreCase) ||
         message.Contains("required", StringComparison.OrdinalIgnoreCase));

    internal static VoxClipException MapError(HttpStatusCode status, string body, string key, ElevenLabsRegion region = ElevenLabsRegion.Default)
    {
        if (body.Contains("quota", StringComparison.OrdinalIgnoreCase) || body.Contains("credit", StringComparison.OrdinalIgnoreCase))
            return new(VoxClipErrorCode.QuotaExceeded, "Your ElevenLabs credits or key quota are used up.");
        if (status == HttpStatusCode.Forbidden || status == HttpStatusCode.Unauthorized && body.Contains("permission", StringComparison.OrdinalIgnoreCase))
            return new(VoxClipErrorCode.KeyPermissionMissing, "This ElevenLabs key can't use speech to text. Allow the speech_to_text permission for the key on elevenlabs.io.");
        if (status == HttpStatusCode.TooManyRequests) return new(VoxClipErrorCode.RateLimited, "ElevenLabs is busy. Try again in a minute.");
        var detail = "The request could not be completed.";
        var authentication = status == HttpStatusCode.Unauthorized;
        try
        {
            using var json = JsonDocument.Parse(body);
            if (json.RootElement.TryGetProperty("detail", out var value))
            {
                if (value.ValueKind == JsonValueKind.Array && value.GetArrayLength() > 0 && value[0].TryGetProperty("msg", out var message)) detail = message.GetString() ?? detail;
                else if (value.ValueKind == JsonValueKind.String) detail = value.GetString()!;
                // ElevenLabs also answers {"detail": {"status": "...", "message": "..."}}.
                else if (value.ValueKind == JsonValueKind.Object)
                {
                    if (value.TryGetProperty("message", out var text) && text.ValueKind == JsonValueKind.String) detail = text.GetString()!;
                    else if (value.TryGetProperty("status", out var code) && code.ValueKind == JsonValueKind.String) detail = code.GetString()!;
                    authentication = authentication || value.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String && type.GetString() == "authentication_error"
                        || new[] { "code", "status" }.Any(name => value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String && field.GetString() == "invalid_api_key");
                }
            }
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException) { }
        // A residency host only knows keys from its own Enterprise workspace; ordinary keys fail there.
        var residency = region is ElevenLabsRegion.Eu or ElevenLabsRegion.In or ElevenLabsRegion.Sg;
        var hint = "";
        if (residency && (authentication || status == HttpStatusCode.BadRequest))
            hint = $" ElevenLabs {region.ToString().ToUpperInvariant()} residency needs a key from a data-residency workspace; most accounts use Region: Default";
        else if (authentication) return new(VoxClipErrorCode.KeyRejected, $"ElevenLabs rejected the key ({(int)status}). Your video is still here.");
        detail = new Redactor([key]).Redact(detail);
        // Error copy keeps 200 characters; shorten the reason so the hint stays whole.
        if (detail.Length > 200 - hint.Length) detail = detail[..(200 - hint.Length)];
        return new(VoxClipErrorCode.ProviderError, $"ElevenLabs answered {(int)status}: {detail}{hint}");
    }

    internal static bool ValidLanguage(string code) => Regex.IsMatch(code, "\\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\\z", RegexOptions.CultureInvariant);

    internal static void ValidatePlan(TranscriptionPlan plan)
    {
        SpeechCopy.ValidateIdentifiers(plan);
        if (plan.Engine != TranscriptEngine.Elevenlabs)
            throw SpeechCopy.Unsupported(TranscriptEngine.Elevenlabs, plan.Language is LanguageChoice.Forced language ? language.Code : "auto");
        if (plan.Model is not (null or "scribe_v2")) throw SpeechCopy.Failed("ElevenLabs requires the scribe_v2 model");
        ValidateOptions(plan.Options);
    }

    private static string BuildUserAgent()
    {
        var version = typeof(ElevenLabsTranscriber).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
            ?? typeof(ElevenLabsTranscriber).Assembly.GetName().Version!.ToString(3);
        return $"VoxClip/{version} ({(OperatingSystem.IsWindows() ? "Windows" : "macOS")} {Environment.OSVersion.Version.ToString(3)}; {RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()})";
    }

    private static void ValidateOptions(TranscriptionOptions options)
    {
        if (options.NumSpeakers is < 1 or > 32 || options.NumSpeakers.HasValue && !options.Diarize)
            throw SpeechCopy.Failed("Speaker count needs diarization and a value from 1 to 32");
        if (options.Keyterms is not { } terms) return;
        if (terms.Count > 1000) throw SpeechCopy.Failed("At most 1000 keyterms are allowed");
        foreach (var term in terms)
            if (string.IsNullOrWhiteSpace(term) || term.EnumerateRunes().Count() >= 50 ||
                term.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length > 5 || term.IndexOfAny(['<', '>', '{', '}', '[', ']', '\\', '\r', '\n']) >= 0)
                throw SpeechCopy.Failed($"Invalid keyterm: {term}");
    }

    private sealed record ProviderJson(JsonElement Json);
    private sealed class MissingKeys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult<string?>(null);
        }
    }
    private sealed class EnvironmentKeys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(account == "elevenlabs-api-key" ? Environment.GetEnvironmentVariable("VOXCLIP_ELEVENLABS_API_KEY") : null);
        }
    }
}

internal sealed class SpeechMultipartContent(string boundary, Action sent) : MultipartFormDataContent(boundary)
{
    private int completed;
    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
    {
        await base.SerializeToStreamAsync(stream, context).ConfigureAwait(false);
        Complete();
    }
    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken cancellationToken)
    {
        await base.SerializeToStreamAsync(stream, context, cancellationToken).ConfigureAwait(false);
        Complete();
    }
    private void Complete() { if (Interlocked.Exchange(ref completed, 1) == 0) sent(); }
}

internal sealed class ActivityStream(Stream inner, Action<long> activity) : Stream
{
    private long received;
    public override bool CanRead => inner.CanRead;
    public override bool CanSeek => inner.CanSeek;
    public override bool CanWrite => false;
    public override long Length => inner.Length;
    public override long Position { get => inner.Position; set => inner.Position = value; }
    public override int Read(byte[] buffer, int offset, int count)
    {
        var read = inner.Read(buffer, offset, count); received += read; activity(received); return read;
    }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        var read = await inner.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
        received += read; activity(received); return read;
    }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) => ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
    public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
    public override void Flush() => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
    public override async ValueTask DisposeAsync() { await inner.DisposeAsync().ConfigureAwait(false); GC.SuppressFinalize(this); }
}

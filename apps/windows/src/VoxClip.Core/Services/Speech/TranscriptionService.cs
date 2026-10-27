using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.Speech;

/// <summary>Queued import orchestration and raw-result reuse; transcription §5, §13 and §14.</summary>
public sealed class TranscriptionService : ITranscriptionService
{
    private static readonly SemaphoreSlim LocalJobs = new(1, 1);
    private static readonly SemaphoreSlim CloudJobs = new(2, 2);
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> ContentJobs = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, PaidRecovery> PendingPaidResponses = new(StringComparer.Ordinal);
    private sealed record PaidRecovery(byte[] Key, JsonElement Response);
    private readonly SemaphoreSlim projectJob = new(1, 1);
    private readonly IReadOnlyDictionary<TranscriptEngine, ITranscriber> engines;
    private readonly IModelCatalog catalog;
    private readonly string root;
    private readonly Func<TranscriptionRequest, CancellationToken, Task<AudioEnvelope?>>? envelopeProvider;

    /// <summary>Cloud-only convenience construction; native hosts inject their local adapter.</summary>
    public TranscriptionService() : this([new ElevenLabsTranscriber()]) { }

    /// <summary>Compose project engines with explicit application data locations; plan W5.</summary>
    public TranscriptionService(IReadOnlyList<ITranscriber> engines, DataLocations locations)
        : this(engines, dataRoot: locations.Root) { }

    /// <summary>One service belongs to one project; engine queues are shared app-wide.</summary>
    public TranscriptionService(IEnumerable<ITranscriber> transcribers, IModelCatalog? modelCatalog = null, string? dataRoot = null,
        Func<TranscriptionRequest, CancellationToken, Task<AudioEnvelope?>>? analysisEnvelope = null)
    {
        engines = transcribers.ToDictionary(engine => engine.Engine);
        catalog = modelCatalog ?? new ModelCatalog();
        root = Path.GetFullPath(dataRoot ?? DataLocations.Resolve().Root);
        envelopeProvider = analysisEnvelope;
    }

    /// <inheritdoc />
    public Task<Transcript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct) =>
        TranscribeCoreAsync(request, null, true, progress, ct);

    /// <inheritdoc />
    public Task<Transcript> TranscribeAsync(TranscriptionRequest request, AudioEnvelope? envelope, IProgress<TranscriptionProgress>? progress, CancellationToken ct) =>
        TranscribeCoreAsync(request, envelope, false, progress, ct);

    private async Task<Transcript> TranscribeCoreAsync(TranscriptionRequest request, AudioEnvelope? envelope, bool resolveEnvelope,
        IProgress<TranscriptionProgress>? progress, CancellationToken ct)
    {
        if (request.ContentKey.Length != 64 || request.ContentKey.Any(character => !char.IsAsciiHexDigitLower(character)))
            throw new ArgumentException("A source SHA-256 content key is required.", nameof(request));
        if (!engines.TryGetValue(request.Plan.Engine, out var engine))
            throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Transcription stopped: this transcription engine is unavailable. Your video is still here.");
        SpeechCopy.ValidateIdentifiers(request.Plan);
        if (engine is ElevenLabsTranscriber) ElevenLabsTranscriber.ValidatePlan(request.Plan);
        await catalog.GetModelsAsync(ct).ConfigureAwait(false);
        if (request.Plan.Language is LanguageChoice.Forced languageChoice && catalog is ModelCatalog bundled)
            request = request with { Plan = request.Plan with { Language = new LanguageChoice.Forced(await bundled.NormalizeLanguageAsync(languageChoice.Code, ct).ConfigureAwait(false)) } };
        var reporting = new SpeechProgress<TranscriptionProgress>(progress);
        await projectJob.WaitAsync(ct).ConfigureAwait(false);
        var contentGate = ContentJobs.GetOrAdd(Path.Combine(root, request.ContentKey), _ => new SemaphoreSlim(1, 1));
        try
        {
            await contentGate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                reporting.Report(new(TranscriptionStage.Preparing, 0));
                var model = request.Plan.Model is { } id ? await catalog.GetModelAsync(id, ct).ConfigureAwait(false) : null;
                var key = CacheKey(request, model);
                var rawKey = Convert.ToHexStringLower(SHA256.HashData(key));
                var language = request.Plan.Language is LanguageChoice.Forced forced ? forced.Code.ToLowerInvariant().Split('-')[0] : "auto";
                if (language.Any(character => !char.IsAsciiLetterLower(character))) throw SpeechCopy.InvalidIdentifier(request.Plan.Engine);
                var directory = Path.Combine(root, "Cache", request.ContentKey, "transcripts");
                var modelId = request.Plan.Engine == TranscriptEngine.Elevenlabs ? "scribe_v2" : request.Plan.Model ?? "none";
                ModelPaths.ValidateId(modelId);
                var cachePath = Path.Combine(directory, $"{EngineName(request.Plan.Engine)}-{modelId}-{language}-{rawKey[..8]}.json");
                var raw = await ReadCacheAsync(cachePath, key, engine, request.Plan, ct).ConfigureAwait(false);
                if (raw is null && engine is ElevenLabsTranscriber) SetAsideUnreadableCache(cachePath);
                if (raw is null && engine is ElevenLabsTranscriber recoveryEngine && PendingPaidResponses.TryGetValue(cachePath, out var recovery) &&
                    recovery.Key.AsSpan().SequenceEqual(key))
                {
                    raw = await recoveryEngine.MapResponseAsync(recovery.Response, request.Plan.Options.Diarize, request.Plan.Language, ct).ConfigureAwait(false);
                    if (!await WriteCacheAsync(cachePath, key, raw, recovery.Response, CancellationToken.None).ConfigureAwait(false))
                        recoveryEngine.WarnCacheUnavailable();
                }
                var fromCache = raw is not null && request.Plan.Engine == TranscriptEngine.Elevenlabs;
                if (raw is null)
                {
                    if (engine is ElevenLabsTranscriber)
                    {
                        await PreflightCacheAsync(cachePath, request.Audio.DurationSeconds, ct).ConfigureAwait(false);
                    }
                    var queue = engine.Capabilities(request.Plan.Model).OnDevice ? LocalJobs : CloudJobs;
                    await queue.WaitAsync(ct).ConfigureAwait(false);
                    try
                    {
                        var readiness = await engine.ReadinessAsync(request.Plan, ct).ConfigureAwait(false);
                        RequireReady(readiness, request.Plan, model);
                        if (!await engine.SupportsAsync(request.Plan.Language, request.Plan.Model, ct).ConfigureAwait(false))
                            throw SpeechCopy.Unsupported(request.Plan.Engine, language);
                        await engine.PrepareAsync(request.Plan, null, ct).ConfigureAwait(false);
                        raw = engine is ElevenLabsTranscriber paid
                            ? await paid.TranscribeAndCacheAsync(request, reporting,
                                response =>
                                {
                                    PendingPaidResponses[cachePath] = new(key, response);
                                    return WriteCacheAsync(cachePath, key, null, response, CancellationToken.None, required: true);
                                }, ct).ConfigureAwait(false)
                            : await engine.TranscribeAsync(request, reporting, ct).ConfigureAwait(false);
                        if (engine.Engine != TranscriptEngine.Elevenlabs) ct.ThrowIfCancellationRequested();
                        var provider = engine is ElevenLabsTranscriber elevenlabs ? elevenlabs.ProviderResponse(raw) : null;
                        if (!await WriteCacheAsync(cachePath, key, raw, provider,
                            engine.Engine == TranscriptEngine.Elevenlabs ? CancellationToken.None : ct).ConfigureAwait(false) && engine is ElevenLabsTranscriber cacheEngine)
                            cacheEngine.WarnCacheUnavailable();
                    }
                    finally { queue.Release(); }
                }
                ct.ThrowIfCancellationRequested();
                reporting.Report(new(TranscriptionStage.Aligning, 0));
                if (resolveEnvelope)
                    envelope = envelopeProvider is null ? await ReadEnvelopeAsync(request.ContentKey, ct).ConfigureAwait(false)
                        : await envelopeProvider(request, ct).ConfigureAwait(false);
                var shifted = raw with
                {
                    Tokens = raw.Tokens.Select(token => token with
                    {
                        Start = token.Start + request.Audio.TimelineStart, End = token.End + request.Audio.TimelineStart
                    }).ToArray()
                };
                var result = await Task.Run(() => TranscriptPostProcessor.Process(shifted, request.Audio.DurationSeconds,
                    envelope, rawKey, DateTimeOffset.UtcNow), ct).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                if (!result.Words.Any(word => word.Kind == WordKind.Word))
                    throw new VoxClipException(VoxClipErrorCode.NoSpeech, "We didn't hear any words. Check the audio track or choose the language.");
                await reporting.CompleteAsync(new(TranscriptionStage.Aligning, 1), ct).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                return result with { FromCache = fromCache };
            }
            finally { contentGate.Release(); }
        }
        finally { projectJob.Release(); }
    }

    internal static byte[] CacheKey(TranscriptionRequest request, TranscriptionModel? model)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, JsonFormatting.CreateWriterOptions(new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping })))
        {
            writer.WriteStartObject();
            writer.WriteNumber("adapterVersion", 1);
            writer.WriteNumber("audioTrackIndex", request.Audio.AudioTrackIndex);
            writer.WriteBoolean("diarize", request.Plan.Options.Diarize);
            writer.WriteBoolean("dtw", request.Plan.Options.Dtw);
            writer.WriteString("engine", EngineName(request.Plan.Engine));
            writer.WriteStartArray("keyterms");
            foreach (var term in (request.Plan.Options.Keyterms ?? []).Order(StringComparer.Ordinal)) writer.WriteStringValue(term);
            writer.WriteEndArray();
            writer.WriteString("language", request.Plan.Language is LanguageChoice.Forced forced ? forced.Code.ToLowerInvariant().Split('-')[0] : null);
            writer.WriteNull("locale");
            writer.WriteString("model", request.Plan.Engine == TranscriptEngine.Elevenlabs ? "scribe_v2" : request.Plan.Model);
            writer.WriteString("modelSha256", model?.Files.FirstOrDefault(file => file.Role == "model")?.Sha256);
            if (request.Plan.Options.NumSpeakers is { } speakers) writer.WriteNumber("numSpeakers", speakers); else writer.WriteNull("numSpeakers");
            writer.WriteEndObject();
        }
        return buffer.ToArray();
    }

    internal static string EngineName(TranscriptEngine engine) => engine switch
    {
        TranscriptEngine.Elevenlabs => "elevenlabs", TranscriptEngine.Whispercpp => "whispercpp", _ => "apple-speech"
    };

    private static void RequireReady(Readiness readiness, TranscriptionPlan plan, TranscriptionModel? model)
    {
        switch (readiness)
        {
            case Readiness.Ready: return;
            case Readiness.NeedsKey: throw new VoxClipException(VoxClipErrorCode.KeyMissing, "Add your ElevenLabs key in Settings to use it.");
            case Readiness.NeedsModels missing: throw SpeechCopy.ModelMissing(model, plan.Model, missing.Bytes);
            case Readiness.UnsupportedLanguage when plan.Language is LanguageChoice.Auto: throw SpeechCopy.ChooseLanguage();
            case Readiness.UnsupportedLanguage unsupported: throw SpeechCopy.Unsupported(plan.Engine, unsupported.Code);
            default: throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Transcription stopped: this transcription engine is unavailable. Your video is still here.");
        }
    }

    private static async Task<RawTranscript?> ReadCacheAsync(string path, byte[] key, ITranscriber engine, TranscriptionPlan plan, CancellationToken ct)
    {
        try
        {
            await using var stream = File.OpenRead(path);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);
            var entry = document.RootElement;
            if (entry.GetProperty("schema").GetString() != "voxclip-raw-transcript/1" || !Canonical(entry.GetProperty("key")).AsSpan().SequenceEqual(key)) return null;
            if (engine is ElevenLabsTranscriber paid && entry.TryGetProperty("providerResponse", out var response) && response.ValueKind != JsonValueKind.Null)
                return await paid.MapResponseAsync(response, plan.Options.Diarize, plan.Language, ct).ConfigureAwait(false);
            var raw = entry.GetProperty("raw").Deserialize(TranscriptJsonContext.Default.RawTranscript);
            if (raw is null || raw.Tokens is null || raw.Engine is null || raw.Grouping is null || raw.AdapterVersion != 1 ||
                raw.Engine.Id != plan.Engine || plan.Engine != TranscriptEngine.Elevenlabs && !raw.Tokens.Any(token => token.Start.HasValue && token.End > token.Start)) return null;
            return raw;
        }
        catch (Exception error) when (error is IOException or JsonException or KeyNotFoundException or InvalidOperationException or UnauthorizedAccessException) { return null; }
    }

    private static byte[] Canonical(JsonElement key)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, JsonFormatting.CreateWriterOptions(new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping })))
        {
            writer.WriteStartObject();
            foreach (var property in key.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
            {
                writer.WritePropertyName(property.Name);
                if (property.Name == "keyterms")
                {
                    writer.WriteStartArray();
                    foreach (var term in property.Value.EnumerateArray().Select(term => term.GetString()).Order(StringComparer.Ordinal)) writer.WriteStringValue(term);
                    writer.WriteEndArray();
                }
                else property.Value.WriteTo(writer);
            }
            writer.WriteEndObject();
        }
        return buffer.ToArray();
    }

    /// <summary>Moves a paid cache file that did not read as this request's entry to <c>&lt;name&gt;.unreadable-&lt;unix ms&gt;</c>,
    /// so the next write never overwrites a paid response. The move never replaces an existing file.</summary>
    internal static void SetAsideUnreadableCache(string path)
    {
        try
        {
            if (!File.Exists(path)) return;
            var milliseconds = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            while (File.Exists($"{path}.unreadable-{milliseconds}")) milliseconds++;
            File.Move(path, $"{path}.unreadable-{milliseconds}");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Transcription stopped: the transcript cache is unavailable. Your video is still here.");
        }
    }

    internal static long EstimatedResponseBytes(double durationSeconds) =>
        (long)Math.Max(4 * 1024 * 1024, Math.Ceiling(Math.Clamp(double.IsFinite(durationSeconds) ? durationSeconds : 36_000, 0, 36_000) * 1024));

    internal static void RequireCacheSpace(string root, long required, long available)
    {
        if (available < required) throw SpeechCopy.DiskFull(root, required - available);
    }

    private async Task PreflightCacheAsync(string path, double durationSeconds, CancellationToken ct)
    {
        var required = EstimatedResponseBytes(durationSeconds);
        var probe = path + ".preflight";
        try
        {
            RequireCacheSpace(root, required, new DriveInfo(Path.GetPathRoot(root)!).AvailableFreeSpace);
            await SpeechTransport.AtomicWriteAsync(probe, writer => writer.WriteNullValue(), ct).ConfigureAwait(false);
        }
        catch (IOException error) when ((error.HResult & 0xffff) is 0x70 or 0x27 or 28)
        {
            throw SpeechCopy.DiskFull(root, Math.Max(1, required - new DriveInfo(Path.GetPathRoot(root)!).AvailableFreeSpace));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Transcription stopped: the transcript cache is unavailable. Your video is still here.");
        }
        finally
        {
            try { if (File.Exists(probe)) File.Delete(probe); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    private static async Task<bool> WriteCacheAsync(string path, byte[] key, RawTranscript? raw, JsonElement? provider, CancellationToken ct, bool required = false)
    {
        Task Write() => SpeechTransport.AtomicWriteAsync(path, writer =>
            {
                writer.WriteStartObject(); writer.WriteString("schema", "voxclip-raw-transcript/1");
                writer.WritePropertyName("key"); writer.WriteRawValue(key);
                writer.WriteString("createdAt", UtcTimestamp.Format(DateTimeOffset.UtcNow));
                writer.WritePropertyName("raw"); JsonSerializer.Serialize(writer, raw, TranscriptJsonContext.Default.RawTranscript);
                writer.WritePropertyName("providerResponse");
                if (provider is { } json) json.WriteTo(writer); else writer.WriteNullValue();
                writer.WriteEndObject();
            }, ct);
        if (required) await Write().ConfigureAwait(false);
        else if (!await SpeechTransport.TryCacheWriteAsync(Write, ct).ConfigureAwait(false)) return false;
        if (provider is not null) PendingPaidResponses.TryRemove(path, out _);
        return true;
    }

    private async Task<AudioEnvelope?> ReadEnvelopeAsync(string contentKey, CancellationToken ct)
    {
        try
        {
            var directory = Path.Combine(root, "Cache", contentKey);
            var bytes = await File.ReadAllBytesAsync(Path.Combine(directory, "envelope-10ms.f32"), ct).ConfigureAwait(false);
            if (bytes.Length % 4 != 0) return null;
            var levels = new float[bytes.Length / 4];
            for (var index = 0; index < levels.Length; index++)
            {
                levels[index] = BinaryPrimitives.ReadSingleLittleEndian(bytes.AsSpan(index * 4, 4));
                if (!float.IsFinite(levels[index]) || levels[index] < 0) return null;
            }
            var rate = 16000;
            if (File.Exists(Path.Combine(directory, "meta.json")))
            {
                using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), ct).ConfigureAwait(false));
                if (meta.RootElement.TryGetProperty("envelope", out var envelope) && envelope.TryGetProperty("sampleRate", out var sampleRate)) rate = sampleRate.GetInt32();
            }
            return rate > 0 ? new(rate, Math.Max(1, Math.Floor(rate * 0.01 + 0.5)) / rate, levels) : null;
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or UnauthorizedAccessException) { return null; }
    }
}

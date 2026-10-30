using System.Globalization;
using System.Buffers.Binary;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
#pragma warning disable CS1591

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>Explicit regional discovery and single-dispatch Voice Lab operations. Core does not capture consent or speaker embeddings.</summary>
public sealed class ElevenLabsVoiceLab : IDisposable
{
    private const int MaxUpload = 16 * 1024 * 1024;
    private const int MaxPcm = 32 * 1024 * 1024;
    private const int MaxJsonAudio = 44 * 1024 * 1024;
    // \A…\z, not ^…$: .NET lets $ match before a final line break, which would put "voice\n" into a path.
    private static readonly Regex SafeId = new(@"\A[A-Za-z0-9_-]{1,128}\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex LanguageCode = new(@"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex CloneLanguage = new(@"\A[a-z]{2,3}\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private readonly IKeyProvider keys;
    private readonly ILog log;
    private readonly HttpClient http;
    private readonly VoiceLabActionGate actions;
    private readonly TimeProvider clock;
    private readonly VoiceLabSpendLedger? spend;
    private readonly string? fixedBoundary;
    private readonly object discoveredGate = new();
    private Dictionary<string, VoiceLabModel> models = new(StringComparer.Ordinal);
    private Dictionary<string, VoiceLabVoice> voices = new(StringComparer.Ordinal);
    private VoiceLabSubscription? subscription;
    private VoiceLabPriceCatalog? prices;
    public ElevenLabsRegion Region { get; }

    /// <summary><paramref name="prices"/> defaults to <c>shared/catalog/voice-lab.json</c>, read on the first estimate. Each action the
    /// provider accepts is recorded in <paramref name="spend"/>, <c>&lt;data&gt;/VoiceLab/spend.json</c> by default; Voice Lab §3.1.</summary>
    public ElevenLabsVoiceLab(IKeyProvider keys, ElevenLabsRegion region = ElevenLabsRegion.Default, ILog? logger = null,
        VoiceLabPriceCatalog? prices = null, VoiceLabSpendLedger? spend = null)
        : this(keys, new HttpClient(SpeechTransport.CreateCloudHandler()) { Timeout = Timeout.InfiniteTimeSpan }, region, logger, null, prices: prices,
            spend: spend ?? new VoiceLabSpendLedger(DataLocations.Resolve())) { }

    private ElevenLabsVoiceLab(IKeyProvider keys, HttpClient http, ElevenLabsRegion region, ILog? logger, TimeProvider? clock,
        string? boundary = null, VoiceLabPriceCatalog? prices = null, VoiceLabSpendLedger? spend = null)
    {
        this.keys = keys ?? throw new ArgumentNullException(nameof(keys));
        this.http = http;
        Region = region;
        _ = region.BaseUri();
        log = logger ?? new Log();
        this.clock = clock ?? TimeProvider.System;
        actions = new VoiceLabActionGate(this.clock);
        fixedBoundary = boundary;
        this.prices = prices;
        this.spend = spend;
    }

    /// <summary>Only Core tests can inject a handler or fix the multipart boundary, so whole bodies compare with the shared
    /// goldens; production always owns a nonredirecting, cookieless transport. Nothing is recorded unless <paramref name="spend"/> is
    /// given.</summary>
    internal static ElevenLabsVoiceLab ForTesting(IKeyProvider keys, HttpMessageHandler handler, ElevenLabsRegion region,
        ILog? logger = null, TimeProvider? clock = null, string? boundary = null, VoiceLabPriceCatalog? prices = null,
        VoiceLabSpendLedger? spend = null)
    {
        ArgumentNullException.ThrowIfNull(handler);
        var client = new ElevenLabsVoiceLab(keys, new HttpClient(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan }, region, logger, clock, boundary, prices, spend);
        client.allowTestPolicy = true;
        return client;
    }

    public void Dispose() => http.Dispose();
    private bool allowTestPolicy;

    public async Task<IReadOnlyList<VoiceLabModel>> DiscoverModelsAsync(CancellationToken ct)
    {
        using var reply = await SendAsync(HttpMethod.Get, "/v1/models", null, 1024 * 1024, ct).ConfigureAwait(false);
        using var json = Parse(reply.Bytes);
        if (json.RootElement.ValueKind != JsonValueKind.Array) throw Malformed();
        var found = new Dictionary<string, VoiceLabModel>(StringComparer.Ordinal);
        foreach (var row in json.RootElement.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object) throw Malformed();
            var id = RequiredString(row, "model_id");
            if (!IsSafeId(id) || found.ContainsKey(id)) throw Malformed();
            var languages = new List<string>();
            if (row.TryGetProperty("languages", out var lang))
            {
                if (lang.ValueKind != JsonValueKind.Array) throw Malformed();
                foreach (var item in lang.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object) throw Malformed();
                    var code = RequiredString(item, "language_id");
                    if (!LanguageCode.IsMatch(code)) throw Malformed();
                    if (!languages.Contains(code, StringComparer.Ordinal)) languages.Add(code);
                }
            }
            int? maximum = OptionalInt(row, "maximum_text_length_per_request");
            if (maximum is < 1 or > 1000000) throw Malformed();
            double? multiplier = null;
            if (row.TryGetProperty("model_rates", out var rates) && rates.ValueKind != JsonValueKind.Null)
            {
                if (rates.ValueKind != JsonValueKind.Object) throw Malformed();
                if (rates.TryGetProperty("character_cost_multiplier", out var cost))
                {
                    if (cost.ValueKind != JsonValueKind.Number || !cost.TryGetDouble(out var value) || !VoiceLabPricing.IsCharacterMultiplier(value)) throw Malformed();
                    multiplier = value;
                }
            }
            found.Add(id, new(id, OptionalString(row, "name") ?? id, languages.ToArray(),
                OptionalBool(row, "can_do_text_to_speech") ?? false,
                OptionalBool(row, "can_do_voice_conversion") ?? false, maximum, multiplier));
        }
        if (found.Count == 0) throw Malformed();
        lock (discoveredGate) models = found;
        return found.Values.ToArray();
    }

    public async Task<VoiceLabSubscription> DiscoverSubscriptionAsync(CancellationToken ct)
    {
        using var reply = await SendAsync(HttpMethod.Get, "/v1/user/subscription", null, 128 * 1024, ct).ConfigureAwait(false);
        using var json = Parse(reply.Bytes);
        var row = json.RootElement;
        if (row.ValueKind != JsonValueKind.Object) throw Malformed();
        var result = new VoiceLabSubscription(RequiredString(row, "tier"), RequiredString(row, "status"),
            RequiredInt(row, "character_count"), RequiredInt(row, "character_limit"), OptionalLong(row, "next_character_count_reset_unix"),
            RequiredBool(row, "can_use_instant_voice_cloning"), RequiredInt(row, "voice_slots_used"), RequiredInt(row, "voice_limit"));
        if (result.CharacterCount < 0 || result.CharacterLimit < 0 || result.VoiceSlotsUsed < 0 || result.VoiceLimit < 0 || result.NextResetUnix is < 0) throw Malformed();
        lock (discoveredGate) subscription = result;
        return result;
    }

    public async Task<IReadOnlyList<VoiceLabVoice>> DiscoverVoicesAsync(CancellationToken ct)
    {
        var found = new Dictionary<string, VoiceLabVoice>(StringComparer.Ordinal);
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null;
        for (var page = 0; page < 20; page++)
        {
            ct.ThrowIfCancellationRequested();
            var path = "/v2/voices" + (cursor is null ? "?page_size=100" : "?page_size=100&next_page_token=" + Uri.EscapeDataString(cursor));
            using var reply = await SendAsync(HttpMethod.Get, path, null, 4 * 1024 * 1024, ct).ConfigureAwait(false);
            using var json = Parse(reply.Bytes);
            var row = json.RootElement;
            if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("voices", out var items) || items.ValueKind != JsonValueKind.Array) throw Malformed();
            foreach (var item in items.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) throw Malformed();
                var name = OptionalString(item, "name");
                var category = OptionalString(item, "category");
                if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(category)) continue;
                var id = RequiredString(item, "voice_id");
                if (!IsSafeId(id) || found.ContainsKey(id)) throw Malformed();
                if (found.Count >= 2000) throw new VoiceLabException(VoiceLabErrorKind.ResponseTooLarge);
                bool required = false, verified = false;
                if (item.TryGetProperty("voice_verification", out var verification) && verification.ValueKind != JsonValueKind.Null)
                {
                    if (verification.ValueKind != JsonValueKind.Object) throw Malformed();
                    required = OptionalBool(verification, "requires_verification") ?? false;
                    verified = OptionalBool(verification, "is_verified") ?? false;
                }
                var created = OptionalLong(item, "created_at_unix");
                if (created is < 0 or > 253402300799) throw Malformed();
                found.Add(id, new(id, name, category,
                    OptionalBool(item, "is_owner") ?? false, required, verified,
                    item.TryGetProperty("labels", out var labels) && labels.ValueKind == JsonValueKind.Object
                        ? OptionalString(labels, "voxclip_record_id") : null,
                    created is { } seconds ? DateTimeOffset.FromUnixTimeSeconds(seconds) : null));
            }
            var more = RequiredBool(row, "has_more");
            if (!more)
            {
                lock (discoveredGate) voices = found;
                return found.Values.ToArray();
            }
            cursor = RequiredString(row, "next_page_token");
            if (cursor.Length is < 1 or > 256 || !cursors.Add(cursor)) throw Malformed();
        }
        throw new VoiceLabException(VoiceLabErrorKind.ResponseTooLarge);
    }

    public async Task<IReadOnlyList<VoiceLabVoice>> ListOwnClonesAsync(CancellationToken ct = default) =>
        (await DiscoverVoicesAsync(ct).ConfigureAwait(false)).Where(voice => voice.IsOwner && voice.Category == "cloned").ToArray();

    public VoiceLabAuthorization Approve(VoiceLabPreparedAction action, bool affirmative) => actions.Approve(action, affirmative);

    public VoiceLabPreparedAction PrepareSynthesis(string text, string modelId, VoiceLabVoiceChoice voice, string language,
        VoiceLabSpeechOptions options, Guid requestId)
    {
        var model = SelectedModel(modelId, language, true);
        SelectedVoice(voice);
        if (options is null || string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > 20000 ||
            text.EnumerateRunes().Count() > Math.Min(model.MaximumTextLength ?? 5000, 5000)) throw Invalid();
        var fingerprint = SynthesisFingerprint(text, modelId, voice, language, options);
        return actions.Prepare(fingerprint, Quoted(VoiceLabOperation.TextToSpeech, modelId, text.EnumerateRunes().Count()),
            Review(VoiceLabOperation.TextToSpeech, requestId, "/v1/text-to-speech/" + voice.Id + "/with-timestamps?output_format=pcm_24000",
                modelId, voice.Id, modelId == "eleven_multilingual_v2" ? Auto(language) : Explicit(language),
                VoiceLabActionGate.ContentHash(Encoding.UTF8.GetBytes(text)), voice.Policy));
    }

    public VoiceLabPreparedAction PrepareClone(VoiceLabCloneRequest request, OwnVoicePolicy policy, Guid requestId)
    {
        policy.Validate();
        var upload = ValidatedClone(request);
        return actions.Prepare(CloneFingerprint(upload, policy), Quoted(VoiceLabOperation.CreateClone, null, 1),
            Review(VoiceLabOperation.CreateClone, requestId, "/v1/voices/add", null, null, null,
                upload.ConsentSha256, policy) with { DisplayName = upload.DisplayName, MimeType = "audio/wav" });
    }

    public VoiceLabPreparedAction PrepareDeletion(string voiceId, OwnVoicePolicy policy, Guid requestId)
    {
        policy.Validate(voiceId);
        SelectedOwnForDeletion(voiceId);
        return actions.Prepare(DeleteFingerprint(voiceId, policy), Quoted(VoiceLabOperation.DeleteClone, null, 1),
            Review(VoiceLabOperation.DeleteClone, requestId, "/v1/voices/" + voiceId, null, voiceId, null, null, policy));
    }

    public VoiceLabPreparedAction PrepareConversion(byte[] sourceWav, string modelId, VoiceLabVoiceChoice voice, string language,
        uint seed, bool cleanAudioOn, Guid requestId)
    {
        SelectedModel(modelId, language, false);
        SelectedVoice(voice);
        if (sourceWav is null) throw Invalid();
        var snapshot = sourceWav.ToArray();
        if (snapshot.Length > MaxUpload || !TryParseWav(snapshot, out var wav)) throw Invalid();
        return actions.Prepare(ConversionFingerprint(snapshot, modelId, voice, language, seed, cleanAudioOn),
            Quoted(VoiceLabOperation.VoiceChange, modelId, wav.Seconds),
            Review(VoiceLabOperation.VoiceChange, requestId, "/v1/voice-changer/" + voice.Id + "?output_format=pcm_24000",
                modelId, voice.Id, Auto(language), VoiceLabActionGate.ContentHash(snapshot), voice.Policy));
    }

    public async Task<VoiceLabCloneResult> CreateOwnCloneAsync(VoiceLabCloneRequest request, OwnVoicePolicy policy,
        VoiceLabAuthorization authorization, CancellationToken ct, Guid requestId)
    {
        policy.Validate();
        var upload = ValidatedClone(request);
        lock (discoveredGate)
        {
            if (subscription is null || !subscription.CanClone) throw new VoiceLabException(VoiceLabErrorKind.PlanUnavailable);
            if (subscription.VoiceSlotsUsed >= subscription.VoiceLimit) throw new VoiceLabException(VoiceLabErrorKind.NoVoiceSlots);
        }
        var boundary = NewBoundary();
        using var body = Multipart(boundary, CloneParts(upload));
        var id = actions.Claim(authorization, CloneFingerprint(upload, policy), VoiceLabOperation.CreateClone, requestId);
        using var reply = await SendAsync(HttpMethod.Post, "/v1/voices/add", body, 128 * 1024, ct, billing: authorization, policy: policy).ConfigureAwait(false);
        using var json = Parse(reply.Bytes);
        if (json.RootElement.ValueKind != JsonValueKind.Object) throw Malformed();
        var voiceId = RequiredString(json.RootElement, "voice_id");
        if (!IsSafeId(voiceId)) throw Malformed();
        var requires = RequiredBool(json.RootElement, "requires_verification");
        lock (discoveredGate) voices[voiceId] = new(voiceId, upload.DisplayName + " (VoxClip)", "cloned", true, requires, !requires);
        return new(voiceId, requires, policy.RecordId, Receipt("/v1/voices/add", null, voiceId, id, reply));
    }

    public async Task<VoiceLabReceipt> DeleteOwnCloneAsync(string voiceId, OwnVoicePolicy policy,
        VoiceLabAuthorization authorization, CancellationToken ct, Guid requestId)
    {
        policy.Validate(voiceId);
        SelectedOwnForDeletion(voiceId);
        var id = actions.Claim(authorization, DeleteFingerprint(voiceId, policy), VoiceLabOperation.DeleteClone, requestId);
        var path = "/v1/voices/" + voiceId;
        using var reply = await SendAsync(HttpMethod.Delete, path, null, 128 * 1024, ct, allowNotFound: true, billing: authorization).ConfigureAwait(false);
        if (reply.Status != HttpStatusCode.NotFound)
        {
            using var json = Parse(reply.Bytes);
            if (json.RootElement.ValueKind != JsonValueKind.Object || RequiredString(json.RootElement, "status") != "ok") throw Malformed();
        }
        lock (discoveredGate) voices.Remove(voiceId);
        return Receipt(path, null, voiceId, id, reply);
    }

    public async Task<VoiceLabAudioResult> SynthesizeAsync(string text, string modelId, VoiceLabVoiceChoice voice,
        string language, VoiceLabSpeechOptions options, VoiceLabAuthorization authorization, CancellationToken ct, Guid requestId)
    {
        var model = SelectedModel(modelId, language, true);
        SelectedVoice(voice);
        if (options is null || string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > 20000 ||
            text.EnumerateRunes().Count() > Math.Min(model.MaximumTextLength ?? 5000, 5000)) throw Invalid();
        var path = "/v1/text-to-speech/" + voice.Id + "/with-timestamps?output_format=pcm_24000";
        // Voice settings are spec constants (§8.5), not caller choices.
        var payload = new JsonObject
        {
            ["text"] = text, ["model_id"] = modelId,
            ["voice_settings"] = new JsonObject { ["stability"] = 0.5, ["similarity_boost"] = 0.8 },
            ["seed"] = options.Seed, ["apply_text_normalization"] = "auto"
        };
        if (modelId != "eleven_multilingual_v2") payload["language_code"] = language;
        if (modelId != "eleven_v3" && SpeechContext(options.PreviousText, true) is { } previous) payload["previous_text"] = previous;
        if (modelId != "eleven_v3" && SpeechContext(options.NextText, false) is { } next) payload["next_text"] = next;
        var jsonBody = Encoding.UTF8.GetBytes(payload.ToJsonString());
        var id = actions.Claim(authorization, SynthesisFingerprint(text, modelId, voice, language, options), VoiceLabOperation.TextToSpeech, requestId);
        using var reply = await SendAsync(HttpMethod.Post, path, new ByteArrayContent(jsonBody) { Headers = { ContentType = new MediaTypeHeaderValue("application/json") } }, MaxJsonAudio, ct,
            billing: authorization, policy: voice.Policy).ConfigureAwait(false);
        if (reply.ContentType is { } contentType && !contentType.Equals("application/json", StringComparison.OrdinalIgnoreCase)) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        using var json = Parse(reply.Bytes);
        if (json.RootElement.ValueKind != JsonValueKind.Object || !json.RootElement.TryGetProperty("audio_base64", out var audio) || audio.ValueKind != JsonValueKind.String) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        byte[] pcm;
        try { pcm = Convert.FromBase64String(audio.GetString()!); }
        catch (FormatException) { throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio); }
        ValidatePcm(pcm);
        var timing = Alignment(json.RootElement, text, pcm.Length / 48000.0);
        return new(pcm, 24000, timing, Receipt("/v1/text-to-speech/" + voice.Id + "/with-timestamps", modelId, voice.Id, id, reply));
    }

    public async Task<VoiceLabAudioResult> ConvertAsync(byte[] sourceWav, string modelId, VoiceLabVoiceChoice voice,
        string language, uint seed, bool cleanAudioOn, VoiceLabAuthorization authorization, CancellationToken ct, Guid requestId)
    {
        SelectedModel(modelId, language, false);
        SelectedVoice(voice);
        if (sourceWav is null) throw Invalid();
        var snapshot = sourceWav.ToArray();
        if (snapshot.Length > MaxUpload || !TryParseWav(snapshot, out _)) throw Invalid();
        var boundary = NewBoundary();
        // Voice settings are spec constants (§7.3). Clean audio already removed the noise, so it is not removed twice.
        using var body = Multipart(boundary, [new("audio", null, "audio.wav", snapshot), new("model_id", modelId),
            new("voice_settings", "{\"stability\":0.5,\"similarity_boost\":0.75}"), new("seed", seed.ToString(CultureInfo.InvariantCulture)),
            new("remove_background_noise", cleanAudioOn ? "false" : "true")]);
        var id = actions.Claim(authorization, ConversionFingerprint(snapshot, modelId, voice, language, seed, cleanAudioOn), VoiceLabOperation.VoiceChange, requestId);
        var path = "/v1/voice-changer/" + voice.Id + "?output_format=pcm_24000";
        using var reply = await SendAsync(HttpMethod.Post, path, body, MaxPcm, ct, billing: authorization, policy: voice.Policy).ConfigureAwait(false);
        if (reply.ContentType is { } type && !new[] { "application/octet-stream", "audio/pcm", "audio/l16" }.Contains(type, StringComparer.OrdinalIgnoreCase))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        ValidatePcm(reply.Bytes);
        return new(reply.Bytes, 24000, null, Receipt("/v1/voice-changer/" + voice.Id, modelId, voice.Id, id, reply));
    }

    private VoiceLabModel SelectedModel(string id, string language, bool tts)
    {
        if (!IsSafeId(id) || !LanguageCode.IsMatch(language)) throw Invalid();
        VoiceLabModel? model;
        lock (discoveredGate) models.TryGetValue(id, out model);
        if (model is null || !model.Languages.Contains(language, StringComparer.Ordinal) || (tts ? !model.CanSpeak : !model.CanConvert))
            throw new VoiceLabException(VoiceLabErrorKind.UnsupportedModel);
        if (tts && !model.SupportsTimestampedTts) throw new VoiceLabException(VoiceLabErrorKind.UnsupportedEndpoint);
        return model;
    }
    private void SelectedVoice(VoiceLabVoiceChoice choice)
    {
        if (!IsSafeId(choice.Id)) throw Invalid();
        VoiceLabVoice? voice;
        lock (discoveredGate) voices.TryGetValue(choice.Id, out voice);
        if (voice is null) throw Invalid();
        if (choice.Kind == VoiceLabVoiceKind.Own)
        {
            if (choice.Policy is null) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            choice.Policy.Validate(choice.Id);
            if (!voice.IsOwner || voice.Category != "cloned" || voice.RequiresVerification && !voice.IsVerified)
                throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        }
        else if (choice.Policy is not null || !(voice.Category == "premade" || voice.Category == "generated" && voice.IsOwner) || voice.RequiresVerification && !voice.IsVerified)
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
    private void SelectedOwnForDeletion(string id)
    {
        if (!IsSafeId(id)) throw Invalid();
        VoiceLabVoice? voice;
        lock (discoveredGate) voices.TryGetValue(id, out voice);
        if (voice is null || !voice.IsOwner || voice.Category != "cloned")
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }

    private string SynthesisFingerprint(string text, string model, VoiceLabVoiceChoice voice, string language, VoiceLabSpeechOptions options) =>
        Fingerprint(VoiceLabOperation.TextToSpeech, "/v1/text-to-speech/" + voice.Id + "/with-timestamps?output_format=pcm_24000", model, voice, language,
            VoiceLabActionGate.ContentHash(Encoding.UTF8.GetBytes(text)), options.Seed.ToString(CultureInfo.InvariantCulture),
            model == "eleven_v3" ? null : ContextHash(SpeechContext(options.PreviousText, true)),
            model == "eleven_v3" ? null : ContextHash(SpeechContext(options.NextText, false)));
    private static string? ContextHash(string? context) => context is null ? null : VoiceLabActionGate.ContentHash(Encoding.UTF8.GetBytes(context));
    /// <summary>Voice-lab §8.5 context: Unicode White_Space is removed at both ends, then the last (previous) or first (next)
    /// 300 Unicode scalars are kept. If they hold White_Space, a word split by the cut is dropped first. Then the cut
    /// moves until it splits no cluster: previous text drops orphaned marks and joiners, next text drops a partial
    /// cluster back to its base. Null means the field is omitted.</summary>
    private static string? SpeechContext(string? text, bool previous)
    {
        if (text is null) return null;
        var runes = text.EnumerateRunes().ToArray();
        int start = 0, end = runes.Length;
        while (start < end && Rune.IsWhiteSpace(runes[start])) start++;
        while (end > start && Rune.IsWhiteSpace(runes[end - 1])) end--;
        if (end - start > 300)
        {
            if (previous) start = end - 300;
            else end = start + 300;
            if (runes[start..end].Any(Rune.IsWhiteSpace))
            {
                if (previous && !Rune.IsWhiteSpace(runes[start - 1])) while (start < end && !Rune.IsWhiteSpace(runes[start])) start++;
                if (!previous && !Rune.IsWhiteSpace(runes[end])) while (end > start && !Rune.IsWhiteSpace(runes[end - 1])) end--;
            }
            if (previous) while (start < end && Splits(runes, start)) start++;
            else while (end > start && Splits(runes, end)) end--;
        }
        return start == end ? null : string.Concat(runes[start..end].Select(rune => rune.ToString()));
    }
    /// <summary>A cut before <paramref name="index"/> splits a cluster when that scalar extends one or follows a ZWJ.</summary>
    private static bool Splits(Rune[] runes, int index) => Extends(runes[index]) || runes[index - 1].Value == 0x200D;
    /// <summary>Combining marks (General Category M), ZWJ and variation selectors extend the cluster before them.</summary>
    private static bool Extends(Rune rune) =>
        Rune.GetUnicodeCategory(rune) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark ||
        rune.Value == 0x200D || rune.Value is >= 0xFE00 and <= 0xFE0F || rune.Value is >= 0xE0100 and <= 0xE01EF;
    private string CloneFingerprint(CloneUpload upload, OwnVoicePolicy policy) =>
        VoiceLabActionGate.Fingerprint(["elevenlabs", Region.ToString(), VoiceLabOperation.CreateClone.ToString(), "/v1/voices/add", upload.DisplayName,
            upload.Language, upload.CreatedAt, upload.RemoveBackgroundNoise.ToString(), upload.Samples.Count.ToString(CultureInfo.InvariantCulture),
            .. upload.Samples.SelectMany((sample, index) => new[] { index.ToString(CultureInfo.InvariantCulture), sample.Role.ToString(), sample.Sha256 }),
            PolicyIdentity(policy), .. upload.RecoveryNonce is null ? Array.Empty<string>() : new[] { upload.RecoveryNonce }]);
    private string DeleteFingerprint(string id, OwnVoicePolicy policy) =>
        VoiceLabActionGate.Fingerprint("elevenlabs", Region.ToString(), VoiceLabOperation.DeleteClone.ToString(), "/v1/voices/" + id, PolicyIdentity(policy));
    private string ConversionFingerprint(byte[] audio, string model, VoiceLabVoiceChoice voice, string language, uint seed, bool cleanAudioOn) =>
        Fingerprint(VoiceLabOperation.VoiceChange, "/v1/voice-changer/" + voice.Id + "?output_format=pcm_24000", model, voice, language,
            VoiceLabActionGate.ContentHash(audio), seed.ToString(CultureInfo.InvariantCulture), cleanAudioOn.ToString());
    private string Fingerprint(VoiceLabOperation operation, string path, string model, VoiceLabVoiceChoice voice, string language, string content,
        params string?[] options) =>
        VoiceLabActionGate.Fingerprint(["elevenlabs", Region.ToString(), operation.ToString(), path, model, voice.Id,
            voice.Kind.ToString(), voice.Policy is null ? null : PolicyIdentity(voice.Policy), language, content, .. options]);
    private static string PolicyIdentity(OwnVoicePolicy policy) => VoiceLabActionGate.Fingerprint(policy.RecordId, policy.CloneVoiceId,
        policy.RecordActive.ToString(), policy.ProviderConsentGranted.ToString(), policy.StatementVerified.ToString(), policy.SpeakerMatched.ToString(), policy.OwnerConfirmed.ToString());
    private VoiceLabReview Review(VoiceLabOperation operation, Guid requestId, string endpoint, string? model, string? voice,
        VoiceLabLanguageMode? language, string? contentHash, OwnVoicePolicy? consent) =>
        new(operation, requestId, "elevenlabs", Region, endpoint, model, voice, language, contentHash,
            consent?.RecordId, ConsentPolicy: consent);
    private static VoiceLabLanguageMode Explicit(string language) => new(VoiceLabLanguageModeKind.Explicit, language);
    private static VoiceLabLanguageMode Auto(string language) => new(VoiceLabLanguageModeKind.AutoDetected, language);
    private sealed record CloneFile(VoiceLabCloneSampleRole Role, byte[] Wav, string Sha256);
    private sealed record CloneUpload(string DisplayName, string Language, string CreatedAt, bool RemoveBackgroundNoise,
        IReadOnlyList<CloneFile> Samples, string ConsentSha256, string? RecoveryNonce);
    /// <summary>WAV only until spike S5: 1–25 complete mono PCM16 files of 5–30 s, 10–240 s in total, with exactly one consent statement.</summary>
    private static CloneUpload ValidatedClone(VoiceLabCloneRequest request)
    {
        if (request?.DisplayName is null || request.Language is null || request.Samples is null) throw Invalid();
        var items = request.Samples.ToArray();
        // Trim() follows char.IsWhiteSpace, which is exactly Unicode White_Space (all of it in the BMP).
        var name = request.DisplayName.Trim();
        var seconds = request.CreatedAt.ToUnixTimeSeconds();
        // §6.1 display name: 1 to 60 Unicode scalars after trimming Unicode White_Space, with no control character left in
        // it (char.IsControl is exactly General Category Cc, all of it in the BMP); the trimmed name is sent and bound.
        if (name.EnumerateRunes().Count() is < 1 or > 60 || name.Any(char.IsControl) ||
            !CloneLanguage.IsMatch(request.Language) || seconds is < 0 or > 253402300799 || items.Length is < 1 or > 25 ||
            items.Any(sample => sample?.Wav is null || !Enum.IsDefined(sample.Role)) ||
            items.Count(sample => sample.Role == VoiceLabCloneSampleRole.ConsentStatement) != 1) throw Invalid();
        var samples = new List<CloneFile>();
        var total = 0.0;
        foreach (var sample in items)
        {
            var snapshot = sample.Wav.ToArray();
            if (snapshot.Length > MaxUpload || !TryParseWav(snapshot, out var wav) ||
                wav.DataBytes / 2 < 5UL * wav.SampleRate || wav.DataBytes / 2 > 30UL * wav.SampleRate) throw Invalid();
            total += wav.DataBytes / 2 / (double)wav.SampleRate;
            samples.Add(new(sample.Role, snapshot, VoiceLabActionGate.ContentHash(snapshot)));
        }
        if (total is < 10 or > 240 || request.RecoveryNonce is not null && !Guid.TryParseExact(request.RecoveryNonce, "D", out _)) throw Invalid();
        return new(name, request.Language, DateTimeOffset.FromUnixTimeSeconds(seconds).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            request.RemoveBackgroundNoise, samples, samples.Single(sample => sample.Role == VoiceLabCloneSampleRole.ConsentStatement).Sha256, request.RecoveryNonce);
    }
    private static IEnumerable<Part> CloneParts(CloneUpload upload)
    {
        yield return new("name", upload.DisplayName + " (VoxClip)");
        yield return new("files", null, "consent-statement.wav", upload.Samples.Single(sample => sample.Role == VoiceLabCloneSampleRole.ConsentStatement).Wav);
        var number = 2;
        foreach (var sample in upload.Samples.Where(sample => sample.Role == VoiceLabCloneSampleRole.Training))
            yield return new("files", null, "sample-" + (number++).ToString("00", CultureInfo.InvariantCulture) + ".wav", sample.Wav);
        yield return new("remove_background_noise", upload.RemoveBackgroundNoise ? "true" : "false");
        yield return new("description", "VoxClip own-voice clone. Consent sha256:" + upload.ConsentSha256 + ". Created " + upload.CreatedAt + "." +
            (upload.RecoveryNonce is null ? "" : " VoxClip request " + upload.RecoveryNonce + "."));
        yield return new("labels", "{\"language\":\"" + upload.Language + "\"" +
            (upload.RecoveryNonce is null ? "" : ",\"voxclip_record_id\":\"" + upload.RecoveryNonce + "\"") + "}");
    }
    /// <summary>The catalog estimate (Voice Lab §3.2) for <paramref name="units"/> of an ElevenLabs operation: seconds of audio, characters
    /// (Unicode scalars) of text or one call. TTS uses the selected model's discovered character multiplier, so discover models first;
    /// <paramref name="candidates"/> prices a run of takes (§8.6), although each take is still quoted on its own.</summary>
    public CostEstimate Estimate(VoiceLabOperation operation, string? modelId, double units, int candidates = 1)
    {
        var priced = operation switch
        {
            VoiceLabOperation.CreateClone => VoiceLabPricedOperation.ElevenLabsCreateClone,
            VoiceLabOperation.DeleteClone => VoiceLabPricedOperation.ElevenLabsDeleteClone,
            VoiceLabOperation.TextToSpeech => VoiceLabPricedOperation.ElevenLabsTextToSpeech,
            VoiceLabOperation.VoiceChange => VoiceLabPricedOperation.ElevenLabsVoiceChange,
            _ => throw Invalid()
        };
        double? multiplier;
        lock (discoveredGate) multiplier = modelId is not null && models.TryGetValue(modelId, out var model) ? model.CharacterCostMultiplier : null;
        return VoiceLabPricing.Estimate(priced, modelId, units, candidates, multiplier, prices ??= VoiceLabPrices.Load());
    }
    private VoiceLabEstimate Quoted(VoiceLabOperation operation, string? modelId, double units)
    {
        var estimate = Estimate(operation, modelId, units);
        return new(estimate.Provider, operation, estimate.Units, estimate.Unit, estimate.Usd, estimate.Credits, estimate.Basis);
    }
    private VoiceLabReceipt Receipt(string path, string? model, string? voice, Guid id, Reply reply) =>
        new("elevenlabs", Region, path, model, voice, id, reply.RequestId, reply.SpendWarning);

    /// <summary>Starts recording the approved quote's estimate; Voice Lab §3.1. The record runs on the thread pool, never on the caller's
    /// context, and ignores the caller's token. Its warning is logged and never fails the action. Null without a ledger.</summary>
    private Task<VoiceLabSpendWarning?>? Record(VoiceLabAuthorization authorization, DateTimeOffset start)
    {
        if (spend is not { } ledger) return null;
        var estimate = authorization.Estimate.ToCostEstimate();
        return Task.Run(async () =>
        {
            var warning = await ledger.RecordAsync(estimate, start, CancellationToken.None).ConfigureAwait(false);
            if (warning is not null) log.Write(LogLevel.Warn, "voice-lab", "Spend ledger: " + warning.Kind);
            return warning;
        }, CancellationToken.None);
    }

    private sealed class Reply(byte[] bytes, HttpStatusCode status, string? contentType, string? requestId, VoiceLabSpendWarning? spendWarning) : IDisposable
    {
        public byte[] Bytes { get; } = bytes;
        public HttpStatusCode Status { get; } = status;
        public string? ContentType { get; } = contentType;
        public string? RequestId { get; } = requestId;
        public VoiceLabSpendWarning? SpendWarning { get; } = spendWarning;
        public void Dispose() { }
    }
    /// <summary><paramref name="billing"/> is the approved action the request runs. Its 2xx status line is the provider's acceptance, so the
    /// estimate is recorded once from then on however the body ends, and the record finishes before this returns or throws; Voice Lab
    /// §3.1.</summary>
    private async Task<Reply> SendAsync(HttpMethod method, string path, HttpContent? body, int limit, CancellationToken ct, bool allowNotFound = false,
        VoiceLabAuthorization? billing = null, OwnVoicePolicy? policy = null)
    {
        ct.ThrowIfCancellationRequested();
        var origin = Region.BaseUri();
        var url = new Uri(origin, path);
        if (url.Scheme != Uri.UriSchemeHttps || url.Host != origin.Host || url.Port != origin.Port) throw Invalid();
        string? key;
        try { key = await keys.GetKeyAsync("elevenlabs-api-key", ct).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw new VoiceLabException(VoiceLabErrorKind.Cancelled); }
        catch (Exception) { throw new VoiceLabException(VoiceLabErrorKind.MissingKey); }
        if (string.IsNullOrWhiteSpace(key)) throw new VoiceLabException(VoiceLabErrorKind.MissingKey);
        log.RegisterSecret(key);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(5));
        var start = clock.GetUtcNow();
        Task<VoiceLabSpendWarning?>? recording = null;
        try
        {
            using var request = new HttpRequestMessage(method, url) { Content = body };
            request.Headers.TryAddWithoutValidation("xi-api-key", key);
            request.Headers.UserAgent.ParseAdd($"VoxClip/{LlmRuntime.Version}");
            if (policy?.ValidateDispatch is { } validate) await validate(deadline.Token).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (policy is not null) RequirePermit(policy);
            if (policy?.DispatchPermit is { } bound && bound.RequestId != billing?.Review.RequestId) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            var sending = policy?.DispatchPermit is { } permit
                ? permit.Start(() => http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token), deadline.Token)
                : http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            using var response = await sending.ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri is { } final && (final.Scheme != url.Scheme || final.Host != url.Host || final.Port != url.Port || final.AbsolutePath != url.AbsolutePath))
                throw new VoiceLabException(VoiceLabErrorKind.ProviderFailure);
            // The provider has billed once it answers 2xx: a cancelled, broken or oversized body is still recorded.
            if (billing is not null && response.IsSuccessStatusCode) recording = Record(billing, start);
            if (response.Content.Headers.ContentLength is { } length && length > limit) throw new VoiceLabException(VoiceLabErrorKind.ResponseTooLarge);
            await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
            using var output = new MemoryStream();
            var buffer = new byte[8192];
            while (true)
            {
                var read = await stream.ReadAsync(buffer, deadline.Token).ConfigureAwait(false);
                if (read == 0) break;
                if (output.Length + read > limit) throw new VoiceLabException(VoiceLabErrorKind.ResponseTooLarge);
                output.Write(buffer, 0, read);
            }
            var bytes = output.ToArray();
            if (!response.IsSuccessStatusCode && !(allowNotFound && response.StatusCode == HttpStatusCode.NotFound))
                throw Error(response.StatusCode, bytes, url.AbsolutePath, method);
            var requestId = response.Headers.TryGetValues("request-id", out var values) ? values.FirstOrDefault() :
                response.Headers.TryGetValues("x-request-id", out var alternate) ? alternate.FirstOrDefault() : null;
            var warning = recording is null ? null : await recording.ConfigureAwait(false);
            return new(bytes, response.StatusCode, response.Content.Headers.ContentType?.MediaType, requestId, warning);
        }
        catch (OperationCanceledException) { throw new VoiceLabException(ct.IsCancellationRequested ? VoiceLabErrorKind.Cancelled : VoiceLabErrorKind.Network); }
        catch (VoiceLabException) { throw; }
        catch (Exception error) when (error is HttpRequestException or IOException) { throw new VoiceLabException(VoiceLabErrorKind.Network); }
        finally
        {
            policy?.DispatchPermit?.Finish();
            // An accepted action is counted before its error reaches the caller.
            if (recording is not null) await recording.ConfigureAwait(false);
        }
    }
    private void RequirePermit(OwnVoicePolicy policy)
    {
        if (!allowTestPolicy && policy.DispatchPermit is null) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }

    internal async Task DeleteOperationAsync(VoiceOperation operation, CancellationToken ct)
    {
        if (operation.Region != Region || operation.RemoteVoiceId is not { } voiceId || !IsSafeId(voiceId)) throw Invalid();
        var policy = new OwnVoicePolicy(operation.RecordId, voiceId, true, true, true, true, true);
        var requestId = Guid.NewGuid();
        var prepared = actions.Prepare(DeleteFingerprint(voiceId, policy), Quoted(VoiceLabOperation.DeleteClone, null, 1),
            Review(VoiceLabOperation.DeleteClone, requestId, "/v1/voices/" + voiceId, null, voiceId, null, null, policy));
        var authorization = Approve(prepared, true);
        actions.Claim(authorization, DeleteFingerprint(voiceId, policy), VoiceLabOperation.DeleteClone, requestId);
        using var reply = await SendAsync(HttpMethod.Delete, "/v1/voices/" + voiceId, null, 128 * 1024, ct,
            allowNotFound: true, billing: authorization).ConfigureAwait(false);
        if (reply.Status != HttpStatusCode.NotFound)
        {
            using var json = Parse(reply.Bytes);
            if (RequiredString(json.RootElement, "status") != "ok") throw Malformed();
        }
        lock (discoveredGate) voices.Remove(voiceId);
    }
    private static VoiceLabException Error(HttpStatusCode statusCode, byte[] body, string path, HttpMethod method)
    {
        var status = (int)statusCode;
        var text = Encoding.UTF8.GetString(body.AsSpan(0, Math.Min(body.Length, 16384))).ToLowerInvariant();
        string? code = null;
        try
        {
            using var error = JsonDocument.Parse(body);
            if (error.RootElement.TryGetProperty("detail", out var detail) && detail.ValueKind == JsonValueKind.Object)
                code = OptionalString(detail, "code") ?? OptionalString(detail, "status");
        }
        catch (JsonException) { }
        if (status == 402) return new(VoiceLabErrorKind.QuotaExceeded);
        if (status == 403 && code is "subscription_required") return new(VoiceLabErrorKind.PlanUnavailable);
        if (status == 403 && code is "feature_not_available") return new(VoiceLabErrorKind.FeatureUnavailable);
        if (status == 403 && code is "voice_access_denied") return new(VoiceLabErrorKind.VoiceAccessDenied);
        if (status == 403 && code is "model_access_denied") return new(VoiceLabErrorKind.ModelAccessDenied);
        if (text.Contains("quota") || text.Contains("credit")) return new(VoiceLabErrorKind.QuotaExceeded);
        if (status == 403 && code is "insufficient_permissions" or "missing_permissions" || status == 401 && text.Contains("permission"))
        {
            var permission = path switch
            {
                "/v1/models" => "models_read", "/v1/user/subscription" => "user_read", "/v2/voices" => "voices_read",
                "/v1/voices/add" => "create_instant_voice_clone", _ when method == HttpMethod.Delete && path.StartsWith("/v1/voices/", StringComparison.Ordinal) => "voices_write",
                _ when path.StartsWith("/v1/text-to-speech/", StringComparison.Ordinal) => "text_to_speech",
                _ when path.StartsWith("/v1/voice-changer/", StringComparison.Ordinal) => "speech_to_speech", _ => "unknown"
            };
            return new(VoiceLabErrorKind.PermissionMissing, permission);
        }
        if (status == 401) return new(VoiceLabErrorKind.Unauthorized);
        if (status == 429) return new(VoiceLabErrorKind.RateLimited);
        if (status == 422 && text.Contains("output_format")) return new(VoiceLabErrorKind.UnsupportedFormat);
        return new(VoiceLabErrorKind.ProviderFailure, status.ToString(CultureInfo.InvariantCulture));
    }

    /// <summary>Mac Core uses the same form; .NET quotes it in the Content-Type header, as Mac Core does.</summary>
    private string NewBoundary() => fixedBoundary ?? "voxclip-" + Guid.NewGuid().ToString("N");
    /// <summary>A text part has a value; a file part has a filename and WAV bytes.</summary>
    private sealed record Part(string Field, string? Value, string? Filename = null, byte[]? File = null);
    /// <summary>Parts in send order with quoted names and no filename* parameter. Text parts carry no Content-Type.
    /// Headers are written in insertion order, so a file part has Content-Disposition, then Content-Type, as on Mac.</summary>
    private static MultipartFormDataContent Multipart(string boundary, IEnumerable<Part> parts)
    {
        var body = new MultipartFormDataContent(boundary);
        foreach (var part in parts)
        {
            HttpContent content;
            if (part.File is { } file) content = new ByteArrayContent(file);
            else
            {
                var value = part.Value!;
                if (value.Contains('\r') || value.Contains('\n') || Encoding.UTF8.GetByteCount(value) > 256) throw Invalid();
                content = new StringContent(value, Encoding.UTF8);
                content.Headers.ContentType = null;
            }
            content.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data")
                { Name = "\"" + part.Field + "\"", FileName = part.Filename is null ? null : "\"" + part.Filename + "\"" };
            if (part.File is not null) content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            body.Add(content);
        }
        return body;
    }

    private static void ValidatePcm(byte[] pcm)
    {
        if (pcm.Length is < 960 or > MaxPcm || (pcm.Length & 1) != 0 || IsWavContainer(pcm) || ValidId3(pcm) ||
            IsFlacContainer(pcm) || IsMp4Container(pcm) || IsOggContainer(pcm) || HasTwoMp3Frames(pcm))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
    }
    private static bool IsWavContainer(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 44 || !bytes[..4].SequenceEqual("RIFF"u8) || !bytes[8..12].SequenceEqual("WAVE"u8)) return false;
        var declared = BitConverter.ToUInt32(bytes[4..8]);
        if ((ulong)declared + 8 > (ulong)bytes.Length || declared < 36) return false;
        var offset = 12; var format = false; var data = false;
        while (offset + 8 <= bytes.Length)
        {
            var length = BitConverter.ToUInt32(bytes.Slice(offset + 4, 4));
            if (length > bytes.Length - offset - 8) return false;
            if (bytes.Slice(offset, 4).SequenceEqual("fmt "u8) && length >= 16) format = true;
            if (bytes.Slice(offset, 4).SequenceEqual("data"u8) && length > 0) data = true;
            offset += 8 + (int)length + ((int)length & 1);
        }
        return format && data;
    }
    private static bool IsFlacContainer(ReadOnlySpan<byte> bytes) => bytes.Length >= 42 && bytes[..4].SequenceEqual("fLaC"u8) &&
        (bytes[4] & 0x7f) == 0 && ((bytes[5] << 16) | (bytes[6] << 8) | bytes[7]) == 34;
    private static bool IsMp4Container(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 16 || !bytes.Slice(4, 4).SequenceEqual("ftyp"u8)) return false;
        var size = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes[..4]);
        return size >= 16 && size <= bytes.Length;
    }
    private static bool IsOggContainer(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 27 || !bytes[..4].SequenceEqual("OggS"u8) || bytes[4] != 0) return false;
        var segments = bytes[26];
        if (bytes.Length < 27 + segments) return false;
        var payload = 0;
        for (var i = 0; i < segments; i++) payload += bytes[27 + i];
        return payload > 0 && bytes.Length >= 27 + segments + payload;
    }
    private static bool ValidId3(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 10 || !bytes[..3].SequenceEqual("ID3"u8) || bytes[3] is < 2 or > 4 ||
            (bytes[6] | bytes[7] | bytes[8] | bytes[9]) >= 128) return false;
        var size = (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
        return size + 10 <= bytes.Length;
    }
    private static bool HasTwoMp3Frames(ReadOnlySpan<byte> bytes)
    {
        static int FrameLength(ReadOnlySpan<byte> data)
        {
            if (data.Length < 4 || data[0] != 0xff || (data[1] & 0xe0) != 0xe0) return 0;
            var version = (data[1] >> 3) & 3;
            var layer = (data[1] >> 1) & 3;
            var bitrateIndex = data[2] >> 4;
            var rateIndex = (data[2] >> 2) & 3;
            if (version is 0 or 1 || layer != 1 || bitrateIndex is 0 or 15 || rateIndex == 3) return 0;
            ReadOnlySpan<int> rates = [44100, 48000, 32000];
            ReadOnlySpan<int> highBitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
            ReadOnlySpan<int> lowBitrates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
            var rate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4);
            var bitrate = (version == 3 ? highBitrates : lowBitrates)[bitrateIndex] * 1000;
            return (version == 3 ? 144 : 72) * bitrate / rate + ((data[2] >> 1) & 1);
        }
        var first = FrameLength(bytes);
        return first >= 4 && bytes.Length >= first + 4 && FrameLength(bytes[first..]) is var second && second >= 4 &&
            bytes.Length >= first + second;
    }

    private readonly record struct WavInfo(uint SampleRate, uint DataBytes)
    {
        public double Seconds => DataBytes / (SampleRate * 2.0);
    }
    private static bool TryParseWav(ReadOnlySpan<byte> bytes, out WavInfo info)
    {
        info = default;
        if (bytes.Length < 44 || !bytes[..4].SequenceEqual("RIFF"u8) || !bytes[8..12].SequenceEqual("WAVE"u8) ||
            (ulong)BinaryPrimitives.ReadUInt32LittleEndian(bytes[4..8]) + 8 != (ulong)bytes.Length) return false;
        var offset = 12;
        uint rate = 0, payload = 0;
        var format = false; var data = false;
        while (offset < bytes.Length)
        {
            if (bytes.Length - offset < 8) return false;
            var length = BinaryPrimitives.ReadUInt32LittleEndian(bytes.Slice(offset + 4, 4));
            if (length > bytes.Length - offset - 8 || (ulong)length + (ulong)(length & 1) > (ulong)(bytes.Length - offset - 8)) return false;
            var chunk = bytes.Slice(offset + 8, (int)length);
            if (bytes.Slice(offset, 4).SequenceEqual("fmt "u8))
            {
                if (format || length is not (16 or 18) || length == 18 && BinaryPrimitives.ReadUInt16LittleEndian(chunk[16..18]) != 0) return false;
                rate = BinaryPrimitives.ReadUInt32LittleEndian(chunk[4..8]);
                if (BinaryPrimitives.ReadUInt16LittleEndian(chunk[..2]) != 1 ||
                    BinaryPrimitives.ReadUInt16LittleEndian(chunk[2..4]) != 1 || rate is < 8000 or > 96000 ||
                    BinaryPrimitives.ReadUInt32LittleEndian(chunk[8..12]) != rate * 2 ||
                    BinaryPrimitives.ReadUInt16LittleEndian(chunk[12..14]) != 2 ||
                    BinaryPrimitives.ReadUInt16LittleEndian(chunk[14..16]) != 16) return false;
                format = true;
            }
            else if (bytes.Slice(offset, 4).SequenceEqual("data"u8))
            {
                if (data || length == 0 || (length & 1) != 0) return false;
                payload = length;
                data = true;
            }
            offset += 8 + (int)length + (int)(length & 1);
        }
        if (!format || !data || offset != bytes.Length) return false;
        info = new(rate, payload);
        var frames = payload / 2;
        return frames >= (rate + 49) / 50 && frames <= (ulong)rate * 290;
    }
    private static IReadOnlyList<VoiceLabCharacterTiming> Alignment(JsonElement row, string text, double duration)
    {
        if (!row.TryGetProperty("alignment", out var alignment) || alignment.ValueKind != JsonValueKind.Object ||
            !alignment.TryGetProperty("characters", out var characters) || characters.ValueKind != JsonValueKind.Array ||
            !alignment.TryGetProperty("character_start_times_seconds", out var starts) || starts.ValueKind != JsonValueKind.Array ||
            !alignment.TryGetProperty("character_end_times_seconds", out var ends) || ends.ValueKind != JsonValueKind.Array ||
            characters.GetArrayLength() == 0 || characters.GetArrayLength() != starts.GetArrayLength() || starts.GetArrayLength() != ends.GetArrayLength())
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
        var output = new List<VoiceLabCharacterTiming>();
        var joined = new StringBuilder();
        var previous = 0.0;
        for (var i = 0; i < characters.GetArrayLength(); i++)
        {
            var character = characters[i]; var start = starts[i]; var end = ends[i];
            if (character.ValueKind != JsonValueKind.String || start.ValueKind != JsonValueKind.Number || end.ValueKind != JsonValueKind.Number ||
                !start.TryGetDouble(out var begin) || !end.TryGetDouble(out var finish) || !double.IsFinite(begin) || !double.IsFinite(finish) ||
                begin < previous || finish < begin || finish > duration + 0.05) throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
            var value = character.GetString()!;
            if (value.Length == 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
            joined.Append(value); output.Add(new(value, begin, finish)); previous = finish;
        }
        if (joined.ToString() != text) throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
        return output;
    }
    private static JsonDocument Parse(byte[] bytes)
    {
        try { return JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 }); }
        catch (JsonException) { throw Malformed(); }
    }
    private static VoiceLabException Malformed() => new(VoiceLabErrorKind.MalformedResponse);
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
    private static bool IsSafeId(string? id) => id is not null && SafeId.IsMatch(id);
    private static string RequiredString(JsonElement row, string name) => row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString()) ? value.GetString()! : throw Malformed();
    private static string? OptionalString(JsonElement row, string name) => !row.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null ? null : value.ValueKind == JsonValueKind.String ? value.GetString() : throw Malformed();
    private static bool RequiredBool(JsonElement row, string name) => row.TryGetProperty(name, out var value) ? value.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw Malformed() } : throw Malformed();
    private static bool? OptionalBool(JsonElement row, string name) => !row.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null ? null : value.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw Malformed() };
    private static int RequiredInt(JsonElement row, string name) => row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result) ? result : throw Malformed();
    private static int? OptionalInt(JsonElement row, string name) => !row.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null ? null : value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result) ? result : throw Malformed();
    private static long? OptionalLong(JsonElement row, string name) => !row.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null ? null : value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var result) ? result : throw Malformed();
}

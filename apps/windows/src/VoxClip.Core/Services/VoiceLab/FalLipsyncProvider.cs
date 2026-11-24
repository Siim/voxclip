using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
#pragma warning disable CS1591

namespace VoxClip.Core.Services.VoiceLab;

public enum FalLipsyncError { InvalidInput, ApprovalRequired, MissingKey, Busy, UnsafeUrl, InvalidResponse, TooLarge, Http, SubmissionUnconfirmed, RemoteFailed }

public sealed class FalLipsyncException(FalLipsyncError code, int? status = null) : Exception(
    status is { } value ? $"fal.ai lip sync: {code} (HTTP {value})." : $"fal.ai lip sync: {code}.")
{
    public FalLipsyncError Code { get; } = code;
    public int? Status { get; } = status;
}

public sealed class FalLipsyncQuote
{
    internal FalLipsyncQuote(Guid owner, byte[] account, DateTimeOffset expires, WholeClipLipsync model, SyncMode mode, CostEstimate estimate)
    { Owner = owner; Account = account; Expires = expires; Model = model; Mode = mode; Estimate = estimate; }
    internal Guid Owner { get; }
    internal byte[] Account { get; }
    internal DateTimeOffset Expires { get; }
    internal bool Used;
    public WholeClipLipsync Model { get; }
    public SyncMode Mode { get; }
    public CostEstimate Estimate { get; }
    public bool MatchesAccount(string fingerprint) => Convert.ToHexStringLower(Account) == fingerprint;
}

public sealed class FalLipsyncProvider : ILipsyncProvider, IDisposable
{
    public const string KeyAccount = "fal-api-key";
    public const long MaximumVideoBytes = 512L * 1024 * 1024;
    public const long UploadVideoBudgetBytes = 364_500_000;
    public static readonly TimeSpan JobDeadline = TimeSpan.FromMinutes(30);
    private const int MaximumJsonBytes = 1024 * 1024;
    private const string Lifecycle = "{\"expiration_duration_seconds\":3600}";
    private readonly HttpClient http;
    private readonly IKeyProvider keys;
    private readonly VoiceLabPriceCatalog prices;
    private readonly Guid owner = Guid.NewGuid();
    private int submitting;

    public FalLipsyncProvider(IKeyProvider keys, VoiceLabPriceCatalog prices)
        : this(keys, prices, new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { }

    internal FalLipsyncProvider(IKeyProvider keys, VoiceLabPriceCatalog prices, HttpMessageHandler handler)
    {
        this.keys = keys;
        this.prices = prices;
        http = new(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public string Id => "fal";
    public IReadOnlyList<LipsyncModel> Models { get; } = Array.AsReadOnly(WholeClipLipsyncValues.All.Select(model => model.LipsyncModel()).ToArray());
    public static double UploadSeconds(double needed) => LipsyncRenderWindow.UploadSeconds(needed);
    public static double UploadSeconds(double needed, double fps) => Math.Ceiling(UploadSeconds(needed) * fps) / fps;
    public async Task<string> AccountFingerprintAsync(CancellationToken ct) =>
        Convert.ToHexStringLower(Hash(await KeyAsync(ct).ConfigureAwait(false)));

    public Task<CostEstimate> EstimateAsync(LipsyncModel model, double seconds, double fps, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Models.Contains(model) || WholeClipLipsyncValues.FromRawValue(model.Id) is not { } choice ||
            !double.IsFinite(seconds) || seconds is < 3 or > 300 || !double.IsFinite(fps) || fps is < 1 or > 120)
            throw new FalLipsyncException(FalLipsyncError.InvalidInput);
        return Task.FromResult(VoiceLabPricing.Estimate(VoiceLabPricedOperation.FalLipsync(choice.Endpoint()), choice.Model(), seconds, 1, null, prices));
    }

    public async Task<FalLipsyncQuote> QuoteAsync(WholeClipLipsync model, double neededSeconds, double fps, SyncMode mode, CancellationToken ct)
    {
        if (!Enum.IsDefined(model) || !Enum.IsDefined(mode) || !double.IsFinite(neededSeconds) || neededSeconds <= 0)
            throw new FalLipsyncException(FalLipsyncError.InvalidInput);
        var estimate = await EstimateAsync(model.LipsyncModel(), UploadSeconds(neededSeconds, fps), fps, ct).ConfigureAwait(false);
        if (estimate.Usd is null) throw new FalLipsyncException(FalLipsyncError.InvalidInput);
        return new(owner, Hash(await KeyAsync(ct).ConfigureAwait(false)), DateTimeOffset.UtcNow.AddMinutes(5), model, mode, estimate);
    }

    public Task<LipsyncJob> SubmitAsync(LipsyncModel model, string videoPath, string audioPath, LipsyncOptions options, CancellationToken ct) =>
        Task.FromException<LipsyncJob>(new FalLipsyncException(FalLipsyncError.ApprovalRequired));

    public async Task<LipsyncJob> SubmitApprovedAsync(FalLipsyncQuote quote, string videoPath, string audioPath,
        VoiceConsentStore consent, VoiceConsentRecord record, VoiceLabDispatchBinding? binding, CancellationToken ct,
        Func<Task>? beforeSubmit = null, Func<LipsyncJob, Task>? accepted = null)
    {
        if (Interlocked.Exchange(ref submitting, 1) != 0) throw new FalLipsyncException(FalLipsyncError.Busy);
        try
        {
            lock (quote)
            {
                if (quote.Owner != owner || quote.Used || quote.Expires < DateTimeOffset.UtcNow)
                    throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
                quote.Used = true;
            }
            consent.ValidateUse(record);
            binding?.Validate();
            var key = await KeyAsync(ct).ConfigureAwait(false);
            if (!CryptographicOperations.FixedTimeEquals(quote.Account, Hash(key)))
                throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
            await using var video = OpenUpload(videoPath, UploadVideoBudgetBytes);
            await using var audio = OpenUpload(audioPath, 64L * 1024 * 1024);
            var videoUrl = await UploadAsync(video, "window.mp4", "video/mp4", key, consent, record, binding, ct).ConfigureAwait(false);
            var audioUrl = await UploadAsync(audio, "mixed.wav", "audio/wav", key, consent, record, binding, ct).ConfigureAwait(false);
            var latestKey = await KeyAsync(ct).ConfigureAwait(false);
            if (!CryptographicOperations.FixedTimeEquals(quote.Account, Hash(latestKey)))
                throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
            using var submit = Request(HttpMethod.Post, new("https://queue.fal.run/" + quote.Model.Endpoint()), key);
            submit.Content = JsonBody(writer =>
            {
                writer.WriteString("video_url", videoUrl);
                writer.WriteString("audio_url", audioUrl);
                writer.WriteBoolean("enable_safety_checker", true);
                writer.WriteString("sync_mode", quote.Mode == SyncMode.Remap ? "remap" : "cut_off");
                if (quote.Model.Model() is { } model) writer.WriteString("model", model);
            });
            submit.Headers.Add("X-Fal-Object-Lifecycle-Preference", Lifecycle);
            ct.ThrowIfCancellationRequested();
            if (beforeSubmit is not null) await beforeSubmit().ConfigureAwait(false);
            LipsyncJob job;
            try
            {
                using var deadline = Deadline(ct);
                using var response = await DispatchAsync(submit, consent, record, binding, deadline.Token).ConfigureAwait(false);
                using var result = await ReadJsonAsync(response, deadline.Token).ConfigureAwait(false);
                job = Recover(quote.Model, ReadString(result.RootElement, "request_id"));
            }
            catch (Exception error) when (error is OperationCanceledException or IOException or HttpRequestException ||
                error is FalLipsyncException { Status: null or 408 or 499 or >= 500 })
            {
                throw new FalLipsyncException(FalLipsyncError.SubmissionUnconfirmed);
            }
            if (accepted is not null) await accepted(job).ConfigureAwait(false);
            return job;
        }
        finally { Volatile.Write(ref submitting, 0); }
    }

    public LipsyncJob Recover(WholeClipLipsync model, string requestId)
    {
        if (!Enum.IsDefined(model) || requestId.Length is < 1 or > 128 ||
            requestId.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not '-' and not '_'))
            throw new FalLipsyncException(FalLipsyncError.InvalidResponse);
        var path = "https://queue.fal.run/fal-ai/sync-lipsync/requests/" + requestId;
        return new(model.LipsyncModel(), requestId, new(path + "/status"), new(path), new(path + "/cancel"), [], DateTimeOffset.UtcNow);
    }

    public async Task<LipsyncState> PollAsync(LipsyncJob job, CancellationToken ct)
        => await PollAsync(job, null, ct).ConfigureAwait(false);

    public async Task<LipsyncState> PollAsync(LipsyncJob job, string? account, CancellationToken ct)
    {
        var canonical = Canonical(job);
        var key = await BoundKeyAsync(account, ct).ConfigureAwait(false);
        using var status = await GetJsonAsync(canonical.StatusUrl!, key, ct).ConfigureAwait(false);
        var state = ReadString(status.RootElement, "status");
        if (state is "IN_QUEUE")
            return new LipsyncState.Queued(status.RootElement.TryGetProperty("queue_position", out var position) && position.ValueKind == JsonValueKind.Number &&
                position.TryGetInt32(out var index) && index >= 0 ? index : null);
        if (state is "IN_PROGRESS") return new LipsyncState.Running(null);
        if (state is "FAILED" or "CANCELLED" || HasError(status.RootElement)) return new LipsyncState.Failed("providerFailed", "fal.ai did not finish the lip sync.");
        if (state != "COMPLETED") throw new FalLipsyncException(FalLipsyncError.InvalidResponse);
        using var result = await GetJsonAsync(canonical.ResponseUrl!, key, ct).ConfigureAwait(false);
        if (HasError(result.RootElement)) return new LipsyncState.Failed("providerFailed", "fal.ai did not return a lip sync.");
        if (!result.RootElement.TryGetProperty("video", out var video)) throw new FalLipsyncException(FalLipsyncError.InvalidResponse);
        return new LipsyncState.Done(MediaUrl(ReadString(video, "url")));
    }

    public async Task DownloadAsync(Uri result, string path, IProgress<double>? progress, CancellationToken ct)
    {
        result = MediaUrl(result.OriginalString);
        using var request = Request(HttpMethod.Get, result);
        using var deadline = Deadline(ct, TimeSpan.FromMinutes(10));
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        Check(response);
        var expected = response.Content.Headers.ContentLength;
        if (expected is 0 or > MaximumVideoBytes) throw new FalLipsyncException(FalLipsyncError.TooLarge);
        var partial = path + "." + Guid.NewGuid().ToString("N") + ".part";
        try
        {
            await using (var target = OpenPrivate(partial))
            {
                var length = await CopyAsync(response, target, MaximumVideoBytes, progress, deadline.Token).ConfigureAwait(false);
                if (length == 0 || expected is { } size && size != length) throw new FalLipsyncException(FalLipsyncError.InvalidResponse);
                await target.FlushAsync(deadline.Token).ConfigureAwait(false);
                target.Flush(true);
            }
            File.Move(partial, path, true);
            progress?.Report(1);
        }
        finally { File.Delete(partial); }
    }

    public async Task CancelAsync(LipsyncJob job, CancellationToken ct)
    {
        using var request = Request(HttpMethod.Put, Canonical(job).CancelUrl!, await KeyAsync(ct).ConfigureAwait(false));
        using var deadline = Deadline(ct);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        Check(response);
    }

    public async Task CleanupAsync(LipsyncJob job, CancellationToken ct)
        => await CleanupAsync(job, null, ct).ConfigureAwait(false);

    public async Task CleanupAsync(LipsyncJob job, string? account, CancellationToken ct)
    {
        var id = Canonical(job).RemoteId;
        using var request = Request(HttpMethod.Delete, new($"https://api.fal.ai/v1/models/requests/{id}/payloads"), await BoundKeyAsync(account, ct).ConfigureAwait(false));
        using var deadline = Deadline(ct);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.NotFound) Check(response);
    }

    private async Task<string> BoundKeyAsync(string? account, CancellationToken ct)
    {
        var key = await KeyAsync(ct).ConfigureAwait(false);
        if (account is not null && Convert.ToHexStringLower(Hash(key)) != account) throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
        return key;
    }

    private LipsyncJob Canonical(LipsyncJob job) => Recover(WholeClipLipsyncValues.FromRawValue(job.Model.Id) ??
        throw new FalLipsyncException(FalLipsyncError.InvalidInput), job.RemoteId);

    private async Task<string> UploadAsync(FileStream file, string name, string type, string key,
        VoiceConsentStore consent, VoiceConsentRecord record, VoiceLabDispatchBinding? binding, CancellationToken ct)
    {
        using var deadline = Deadline(ct, TimeSpan.FromSeconds(60 + file.Length / 250_000d));
        using var initiate = Request(HttpMethod.Post, new("https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"), key);
        initiate.Headers.Add("X-Fal-Object-Lifecycle", Lifecycle);
        initiate.Content = JsonBody(writer => { writer.WriteString("file_name", name); writer.WriteString("content_type", type); });
        using var reply = await DispatchAsync(initiate, consent, record, binding, deadline.Token).ConfigureAwait(false);
        using var json = await ReadJsonAsync(reply, deadline.Token).ConfigureAwait(false);
        var target = SafeUrl(ReadString(json.RootElement, "upload_url"));
        if (!(IsMediaHost(target.Host) || target.Host == "storage.fal.ai")) throw new FalLipsyncException(FalLipsyncError.UnsafeUrl);
        var location = MediaUrl(ReadString(json.RootElement, "file_url"));
        using var put = Request(HttpMethod.Put, target);
        put.Content = new StreamContent(file);
        put.Content.Headers.ContentType = new MediaTypeHeaderValue(type);
        using var response = await DispatchAsync(put, consent, record, binding, deadline.Token).ConfigureAwait(false);
        Check(response);
        return location.AbsoluteUri;
    }

    private async Task<HttpResponseMessage> DispatchAsync(HttpRequestMessage request, VoiceConsentStore consent, VoiceConsentRecord record,
        VoiceLabDispatchBinding? binding, CancellationToken ct)
    {
        var permit = new VoiceDispatchPermit(consent, record.RecordId, Guid.NewGuid(), () => consent.ValidateUse(record), binding);
        try { return await permit.Start(() => http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct), ct).ConfigureAwait(false); }
        finally { permit.Finish(); }
    }

    private async Task<JsonDocument> GetJsonAsync(Uri uri, string key, CancellationToken ct)
    {
        using var request = Request(HttpMethod.Get, uri, key);
        using var deadline = Deadline(ct);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        return await ReadJsonAsync(response, deadline.Token).ConfigureAwait(false);
    }

    private static async Task<JsonDocument> ReadJsonAsync(HttpResponseMessage response, CancellationToken ct)
    {
        Check(response);
        using var output = new MemoryStream();
        await CopyAsync(response, output, MaximumJsonBytes, null, ct).ConfigureAwait(false);
        try
        {
            var json = JsonDocument.Parse(output.GetBuffer().AsMemory(0, (int)output.Length));
            if (json.RootElement.ValueKind == JsonValueKind.Object) return json;
            json.Dispose();
        }
        catch (JsonException) { }
        throw new FalLipsyncException(FalLipsyncError.InvalidResponse);
    }

    private static async Task<long> CopyAsync(HttpResponseMessage response, Stream output, long limit, IProgress<double>? progress, CancellationToken ct)
    {
        await using var source = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        var buffer = new byte[64 * 1024];
        long total = 0;
        while (await source.ReadAsync(buffer, ct).ConfigureAwait(false) is var count && count > 0)
        {
            total += count;
            if (total > limit) throw new FalLipsyncException(FalLipsyncError.TooLarge);
            await output.WriteAsync(buffer.AsMemory(0, count), ct).ConfigureAwait(false);
            if (response.Content.Headers.ContentLength is > 0 and var expected) progress?.Report(Math.Min(1, total / (double)expected));
        }
        return total;
    }

    private static FileStream OpenUpload(string path, long limit)
    {
        if ((File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new FalLipsyncException(FalLipsyncError.InvalidInput);
        var file = File.OpenRead(path);
        if (file.Length > 0 && file.Length <= limit) return file;
        file.Dispose();
        throw new FalLipsyncException(FalLipsyncError.InvalidInput);
    }

    private static FileStream OpenPrivate(string path)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Options = FileOptions.Asynchronous };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        return new FileStream(path, options);
    }

    private static string ReadString(JsonElement element, string field) => element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text ? text :
        throw new FalLipsyncException(FalLipsyncError.InvalidResponse);
    private static bool HasError(JsonElement body) => body.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null;

    private static Uri SafeUrl(string text)
    {
        if (text.Length > 8192 || text.Contains('\\') || text.Contains("%2f", StringComparison.OrdinalIgnoreCase) ||
            text.Contains("%5c", StringComparison.OrdinalIgnoreCase) || !Uri.TryCreate(text, UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps || uri.Port != 443 || uri.UserInfo != "" || uri.Fragment != "")
            throw new FalLipsyncException(FalLipsyncError.UnsafeUrl);
        return uri;
    }

    private static bool IsMediaHost(string host) => host is "fal.media" or "v1.fal.media" or "v2.fal.media" or "v3.fal.media" or "v3b.fal.media";
    private static Uri MediaUrl(string text)
    {
        var uri = SafeUrl(text);
        if (!IsMediaHost(uri.Host) || !uri.AbsolutePath.StartsWith("/files/", StringComparison.Ordinal))
            throw new FalLipsyncException(FalLipsyncError.UnsafeUrl);
        return uri;
    }

    private async Task<string> KeyAsync(CancellationToken ct) => (await keys.GetKeyAsync(KeyAccount, ct).ConfigureAwait(false))?.Trim() is { Length: > 0 } key &&
        key.All(character => character is >= '!' and <= '~') ? key : throw new FalLipsyncException(FalLipsyncError.MissingKey);
    private static byte[] Hash(string key) => SHA256.HashData(Encoding.UTF8.GetBytes(key));
    private static HttpRequestMessage Request(HttpMethod method, Uri uri, string? key = null)
    {
        var request = new HttpRequestMessage(method, uri);
        if (key is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Key", key);
        return request;
    }
    private static CancellationTokenSource Deadline(CancellationToken ct, TimeSpan? length = null)
    {
        var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(length ?? TimeSpan.FromSeconds(60));
        return deadline;
    }
    private static void Check(HttpResponseMessage response)
    {
        if (!response.IsSuccessStatusCode) throw new FalLipsyncException(FalLipsyncError.Http, (int)response.StatusCode);
    }
    private static ByteArrayContent JsonBody(Action<Utf8JsonWriter> write)
    {
        using var output = new MemoryStream();
        using (var writer = new Utf8JsonWriter(output))
        {
            writer.WriteStartObject();
            write(writer);
            writer.WriteEndObject();
        }
        var content = new ByteArrayContent(output.ToArray());
        content.Headers.ContentType = new("application/json");
        return content;
    }
    public void Dispose() => http.Dispose();
}

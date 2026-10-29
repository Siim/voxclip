using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;

namespace VoxClip.Core.Services.Models;

/// <summary>Serialized, confirmed and checksum-verified model installs; transcription §12.</summary>
public sealed class ModelStore : IModelDownloader
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> ModelGates = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> DownloadQueues = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, Task<InstalledModel>> InFlightInstalls = new(StringComparer.OrdinalIgnoreCase);
    private readonly IModelCatalog catalog;
    private readonly string root;
    private readonly HttpClient http;
    private readonly Func<TranscriptionModel, IReadOnlyList<TranscriptionModel>, CancellationToken, Task<bool>>? confirm;
    private readonly SemaphoreSlim downloads;

    /// <summary>Use standard data paths. Installs require an explicit confirmation callback.</summary>
    public ModelStore() : this(new ModelCatalog()) { }

    /// <summary>Compose the catalogue, application data locations and transport; plan W5.</summary>
    public ModelStore(IModelCatalog catalog, DataLocations locations, HttpClient http) : this(catalog, locations.Root, http) { }

    /// <summary>Inject the host confirmation sheet and isolated paths/transport. Required models share one confirmation.</summary>
    public ModelStore(IModelCatalog catalog, string? dataRoot = null, HttpClient? httpClient = null,
        Func<TranscriptionModel, IReadOnlyList<TranscriptionModel>, CancellationToken, Task<bool>>? confirmDownload = null)
    {
        this.catalog = catalog;
        root = Path.GetFullPath(dataRoot ?? DataLocations.Resolve().Root);
        http = httpClient ?? SpeechTransport.Client;
        confirm = confirmDownload;
        downloads = DownloadQueues.GetOrAdd(root, _ => new SemaphoreSlim(1, 1));
    }

    /// <inheritdoc />
    public async Task<InstalledModel> InstallAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ModelPaths.ValidateId(id);
        var key = Path.Combine(root, id);
        var completion = new TaskCompletionSource<InstalledModel>(TaskCreationOptions.RunContinuationsAsynchronously);
        var existing = InFlightInstalls.GetOrAdd(key, completion.Task);
        if (!ReferenceEquals(existing, completion.Task)) return await existing.WaitAsync(ct).ConfigureAwait(false);
        try { completion.SetResult(await InstallOwnedAsync(id, progress, ct).ConfigureAwait(false)); }
        catch (OperationCanceledException error) { completion.SetCanceled(error.CancellationToken); }
        catch (Exception error) { completion.SetException(error); }
        finally { InFlightInstalls.TryRemove(new KeyValuePair<string, Task<InstalledModel>>(key, completion.Task)); }
        return await completion.Task.ConfigureAwait(false);
    }

    private async Task<InstalledModel> InstallOwnedAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct)
    {
        var model = await RequireModelAsync(id, ct).ConfigureAwait(false);
        var entries = new List<TranscriptionModel>();
        await DependenciesAsync(model, entries, new HashSet<string>(StringComparer.Ordinal), ct).ConfigureAwait(false);
        if (entries.All(IsInstalled)) return Installed(model)!;
        Directory.CreateDirectory(root);
        var remaining = entries.Where(entry => !IsInstalled(entry)).Sum(entry => entry.Files.Sum(file => Remaining(entry, file)));
        var needed = remaining * 1.1 + 1_073_741_824;
        var available = new DriveInfo(Path.GetPathRoot(root)!).AvailableFreeSpace;
        if (available < needed) throw SpeechCopy.DiskFull(root, needed - available);
        if (confirm is null) throw new InvalidOperationException("This model store has no download confirmation.");
        if (!await confirm(model, entries.Where(entry => entry.Id != id).ToArray(), ct).WaitAsync(ct).ConfigureAwait(false))
            throw new OperationCanceledException(ct);
        var modelGate = Gate(id);
        await modelGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var total = entries.Sum(entry => entry.TotalBytes);
            long done = 0;
            var reporting = new SpeechProgress<ModelDownloadProgress>(progress);
            foreach (var entry in entries)
            {
                var gate = Gate(entry.Id);
                if (entry.Id != id) await gate.WaitAsync(ct).ConfigureAwait(false);
                try
                {
                if (IsInstalled(entry)) { done += entry.TotalBytes; continue; }
                var directory = ModelPaths.DirectoryFor(root, entry.Id);
                Directory.CreateDirectory(directory);
                foreach (var file in entry.Files)
                {
                    ModelPaths.ValidateFileName(file.Name);
                    var target = Path.Combine(directory, file.Name);
                    if (!await MatchesAsync(target, file, ct).ConfigureAwait(false))
                    {
                        await downloads.WaitAsync(ct).ConfigureAwait(false);
                        try { await DownloadAsync(file, target, received => reporting.Report(new(id, file.Name, "downloading", done + received, total)), ct).ConfigureAwait(false); }
                        finally { downloads.Release(); }
                    }
                    done += file.Bytes;
                    reporting.Report(new(id, file.Name, "verifying", done, total));
                }
                await SpeechTransport.AtomicWriteAsync(Path.Combine(directory, "installed.json"), writer =>
                {
                    writer.WriteStartObject();
                    foreach (var property in entry.RawMetadata.EnumerateObject())
                        if (property.Name != "installedAt") property.WriteTo(writer);
                    writer.WriteString("installedAt", UtcTimestamp.Format(DateTimeOffset.UtcNow));
                    writer.WriteEndObject();
                }, ct).ConfigureAwait(false);
                }
                finally { if (entry.Id != id) gate.Release(); }
            }
            return Installed(model)!;
        }
        catch (IOException error) when ((error.HResult & 0xffff) is 0x70 or 0x27 or 28)
        {
            throw SpeechCopy.DiskFull(root, needed);
        }
        finally { modelGate.Release(); }
    }

    /// <inheritdoc />
    public async Task<bool> VerifyAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct)
    {
        var gate = Gate(id);
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var model = await RequireModelAsync(id, ct).ConfigureAwait(false);
            if (!IsInstalled(model)) return false;
            long done = 0;
            var reporting = new SpeechProgress<ModelDownloadProgress>(progress);
            foreach (var file in model.Files)
            {
                if (!await MatchesAsync(Path.Combine(ModelPaths.DirectoryFor(root, id), file.Name), file, ct).ConfigureAwait(false))
                {
                    File.Delete(Path.Combine(ModelPaths.DirectoryFor(root, id), "installed.json"));
                    return false;
                }
                done += file.Bytes;
                reporting.Report(new(id, file.Name, "verifying", done, model.TotalBytes));
            }
            return true;
        }
        finally { gate.Release(); }
    }

    /// <inheritdoc />
    public async Task RemoveAsync(string id, CancellationToken ct)
    {
        var gate = Gate(id);
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await RequireModelAsync(id, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var directory = ModelPaths.DirectoryFor(root, id);
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
        finally { gate.Release(); }
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<InstalledModel>> ListInstalledAsync(CancellationToken ct) =>
        (await catalog.GetModelsAsync(ct).ConfigureAwait(false)).Select(Installed).OfType<InstalledModel>().ToArray();

    private SemaphoreSlim Gate(string id)
    {
        ModelPaths.ValidateId(id);
        return ModelGates.GetOrAdd(Path.Combine(root, id), _ => new SemaphoreSlim(1, 1));
    }

    private async Task<TranscriptionModel> RequireModelAsync(string id, CancellationToken ct)
    {
        ModelPaths.ValidateId(id);
        return await catalog.GetModelAsync(id, ct).ConfigureAwait(false) ?? throw SpeechCopy.ModelMissing(null, id, 0);
    }

    private async Task DependenciesAsync(TranscriptionModel model, List<TranscriptionModel> entries, HashSet<string> visiting, CancellationToken ct)
    {
        if (entries.Any(entry => entry.Id == model.Id)) return;
        if (!visiting.Add(model.Id)) throw new InvalidDataException("Cyclic model dependency.");
        foreach (var id in model.Requires) await DependenciesAsync(await RequireModelAsync(id, ct).ConfigureAwait(false), entries, visiting, ct).ConfigureAwait(false);
        visiting.Remove(model.Id);
        entries.Add(model);
    }

    private bool IsInstalled(TranscriptionModel model) => Installed(model)?.Verified == true;

    private InstalledModel? Installed(TranscriptionModel model)
    {
        var directory = ModelPaths.DirectoryFor(root, model.Id);
        var path = Path.Combine(directory, "installed.json");
        if (!File.Exists(path)) return null;
        var broken = new InstalledModel(model.Id, directory, false, null) { Status = "Broken" };
        try
        {
            using var marker = JsonDocument.Parse(File.ReadAllText(path));
            if (marker.RootElement.GetProperty("id").GetString() != model.Id) return broken;
            var files = marker.RootElement.GetProperty("files").EnumerateArray().ToArray();
            foreach (var saved in files)
            {
                var name = saved.GetProperty("name").GetString()!;
                ModelPaths.ValidateFileName(name);
                var filePath = Path.Combine(directory, name);
                if (!File.Exists(filePath) || new FileInfo(filePath).Length != saved.GetProperty("bytes").GetInt64()) return broken;
            }
            var current = files.Length == model.Files.Count && model.Files.All(file => files.Any(saved =>
                saved.GetProperty("name").GetString() == file.Name && saved.GetProperty("bytes").GetInt64() == file.Bytes &&
                saved.GetProperty("sha256").GetString() == file.Sha256));
            return new(model.Id, directory, current, null) { Status = current ? "Installed" : "Update available" };
        }
        catch (Exception error) when (error is IOException or JsonException or KeyNotFoundException or InvalidOperationException or UnauthorizedAccessException) { return broken; }
    }

    private long Remaining(TranscriptionModel model, ModelFile file)
    {
        var partial = Path.Combine(ModelPaths.DirectoryFor(root, model.Id), file.Name) + ".partial";
        return file.Bytes - (PartialMatches(partial, file) ? Math.Min(new FileInfo(partial).Length, file.Bytes) : 0);
    }

    private static bool PartialMatches(string partial, ModelFile file)
    {
        try
        {
            if (!File.Exists(partial)) return false;
            using var document = JsonDocument.Parse(File.ReadAllText(partial + ".json"));
            var data = document.RootElement;
            return data.GetProperty("url").GetString() == file.Url.AbsoluteUri && data.GetProperty("bytes").GetInt64() == file.Bytes &&
                data.GetProperty("sha256").GetString() == file.Sha256 && new FileInfo(partial).Length <= file.Bytes;
        }
        catch (Exception error) when (error is IOException or JsonException or KeyNotFoundException or InvalidOperationException) { return false; }
    }

    private async Task DownloadAsync(ModelFile file, string target, Action<long> report, CancellationToken ct)
    {
        var partial = target + ".partial";
        if (!PartialMatches(partial, file) && File.Exists(partial)) File.Delete(partial);
        await SpeechTransport.AtomicWriteAsync(partial + ".json", writer =>
        {
            writer.WriteStartObject(); writer.WriteString("url", file.Url.AbsoluteUri); writer.WriteNumber("bytes", file.Bytes);
            writer.WriteString("sha256", file.Sha256); writer.WriteEndObject();
        }, ct).ConfigureAwait(false);
        if (await MatchesAsync(partial, file, ct).ConfigureAwait(false))
        {
            File.Move(partial, target, true); File.Delete(partial + ".json"); return;
        }
        if (File.Exists(partial) && new FileInfo(partial).Length == file.Bytes)
        {
            File.Delete(partial); File.Delete(partial + ".json");
            throw SpeechCopy.Checksum(file.Name);
        }
        using var whole = CancellationTokenSource.CreateLinkedTokenSource(ct);
        whole.CancelAfter(TimeSpan.FromHours(3));
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                var offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
                using var request = new HttpRequestMessage(HttpMethod.Get, file.Url);
                if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(whole.Token);
                idle.CancelAfter(TimeSpan.FromSeconds(300));
                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, idle.Token).ConfigureAwait(false);
                if (SpeechTransport.Retryable(response.StatusCode) && attempt < 2)
                {
                    await Task.Delay(SpeechTransport.Backoff(response, attempt), whole.Token).ConfigureAwait(false);
                    continue;
                }
                if (!response.IsSuccessStatusCode)
                    throw new VoxClipException(response.StatusCode == HttpStatusCode.TooManyRequests ? VoxClipErrorCode.RateLimited : VoxClipErrorCode.ProviderError,
                        response.StatusCode == HttpStatusCode.TooManyRequests ? "Hugging Face is busy. Try again in a minute."
                            : $"Hugging Face answered {(int)response.StatusCode}: The model download could not be completed.");
                if (response.StatusCode == HttpStatusCode.PartialContent)
                {
                    var range = response.Content.Headers.ContentRange;
                    if (range?.From != offset || range.Length != file.Bytes)
                        throw new VoxClipException(VoxClipErrorCode.ProviderError, "Hugging Face answered 206: The model host returned an invalid resume range.");
                }
                else offset = 0;
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[1 << 20];
                if (offset > 0)
                {
                    await using var previous = File.OpenRead(partial);
                    int read;
                    while ((read = await previous.ReadAsync(buffer, whole.Token).ConfigureAwait(false)) > 0) hash.AppendData(buffer, 0, read);
                }
                await using (var input = await response.Content.ReadAsStreamAsync(idle.Token).ConfigureAwait(false))
                await using (var output = new FileStream(partial, offset > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, true))
                {
                    var received = offset;
                    while (true)
                    {
                        idle.CancelAfter(TimeSpan.FromSeconds(300));
                        var read = await input.ReadAsync(buffer, idle.Token).ConfigureAwait(false);
                        if (read == 0) break;
                        if (received + read > file.Bytes) throw SpeechCopy.Checksum(file.Name);
                        await output.WriteAsync(buffer.AsMemory(0, read), whole.Token).ConfigureAwait(false);
                        hash.AppendData(buffer, 0, read); received += read; report(received);
                    }
                    if (received != file.Bytes) throw new HttpRequestException("Incomplete model transfer.");
                }
                var digest = Convert.ToHexStringLower(hash.GetHashAndReset());
                if (digest != file.Sha256)
                    throw SpeechCopy.Checksum(file.Name);
                whole.Token.ThrowIfCancellationRequested();
                File.Move(partial, target, true); File.Delete(partial + ".json"); return;
            }
            catch (VoxClipException error) when (error.Code == VoxClipErrorCode.ModelChecksumMismatch)
            {
                File.Delete(partial); File.Delete(partial + ".json"); throw;
            }
            catch (Exception error) when ((error is HttpRequestException or IOException or OperationCanceledException) && !ct.IsCancellationRequested)
            {
                if (error is IOException diskError && (diskError.HResult & 0xffff) is 0x70 or 0x27 or 28) throw;
                if (attempt == 2 || whole.IsCancellationRequested)
                    throw new VoxClipException(VoxClipErrorCode.Offline, "You're offline. On-device transcription and editing still work.");
                await Task.Delay(SpeechTransport.Backoff(null, attempt), ct).ConfigureAwait(false);
            }
        }
    }

    private static async Task<bool> MatchesAsync(string path, ModelFile file, CancellationToken ct)
    {
        if (!File.Exists(path) || new FileInfo(path).Length != file.Bytes) return false;
        await using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false)) == file.Sha256;
    }
}

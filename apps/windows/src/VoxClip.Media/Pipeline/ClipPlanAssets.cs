using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Music;

namespace VoxClip.Media.Pipeline;

/// <summary>The shared, fixed-shape illustration quote.</summary>
public sealed record ClipIllustrationQuote(Uri Endpoint, int Size, decimal UsdPerImage)
{
    /// <summary>Load the quote shipped with both apps.</summary>
    public static ClipIllustrationQuote Load(string sharedRoot)
    {
        var quote = JsonSerializer.Deserialize<ClipIllustrationQuote>(File.ReadAllBytes(Path.Combine(sharedRoot, "data", "clip-illustration.json")),
            new JsonSerializerOptions(JsonSerializerDefaults.Web));
        if (quote is not { Size: 768, UsdPerImage: > 0 and <= 0.01m } || quote.Endpoint?.AbsoluteUri != "https://fal.run/fal-ai/flux/schnell")
            throw new InvalidDataException("Illustration pricing isn't available.");
        return quote;
    }
}

/// <summary>Materializes checked plan asset requests into the owning project's local asset folders.</summary>
public sealed class ClipPlanAssets(IMusicHttp http)
{
    private readonly OpenverseMusicClient openverse = new(http);

    /// <summary>Find and download a licensed sound that fits the chosen source span.</summary>
    public async Task<JsonElement?> SoundAsync(ClipAutopilotAction.Asset request, string projectId, string root, CancellationToken ct)
    {
        var length = request.End - request.Start;
        var results = await openverse.SearchAsync(request.Text, new HashSet<string>(), 0, ct, sound: true).ConfigureAwait(false);
        if (results.FirstOrDefault(candidate => candidate.DurationSeconds <= length) is not { } candidate) return null;
        var bytes = await openverse.DownloadAsync(candidate, ct).ConfigureAwait(false);
        if (bytes.Length > 16 * 1024 * 1024) return null;
        var hash = Hash(bytes);
        var relative = $"{projectId}/sfx-{hash[..48]}.{candidate.FileExtension}";
        var path = Save(bytes, relative, projectId, ClipEffectsRenderInput.SoundRoot(root));
        var probe = await new FfmpegMediaProbe().ProbeAsync(path, ct).ConfigureAwait(false);
        if (probe.Audio is null || !double.IsFinite(probe.DurationSeconds) || probe.DurationSeconds <= 0 || probe.DurationSeconds > length + 1e-9) return null;
        var effect = Entry(request, "sound");
        effect["sound"] = new JsonObject { ["source"] = "library", ["file"] = relative, ["sha256"] = hash,
            ["durationSeconds"] = probe.DurationSeconds, ["title"] = candidate.Title, ["creator"] = candidate.Creator,
            ["license"] = candidate.License switch { MusicLicense.By => "by", MusicLicense.Pdm => "pdm", _ => "cc0" },
            ["attribution"] = candidate.Attribution, ["sourceUrl"] = candidate.SourceUrl };
        effect["gainDb"] = -15;
        return JsonSerializer.SerializeToElement(effect);
    }

    /// <summary>Reuse a previously saved result without sending the prompt again.</summary>
    public JsonElement? SavedIllustration(ClipAutopilotAction.Asset request, string projectId, string root, ClipIllustrationQuote quote)
    {
        var relative = IllustrationPath(request, projectId, quote);
        return File.Exists(Path.Combine(ClipEffectsRenderInput.ImageRoot(root), relative)) ? Picture(request, relative) : null;
    }

    /// <summary>Dispatch one approved illustration and save its bytes before returning the placement.</summary>
    public async Task<JsonElement> IllustrationAsync(ClipAutopilotAction.Asset request, string projectId, string root, ClipIllustrationQuote quote, string key)
    {
        using var call = new HttpRequestMessage(HttpMethod.Post, quote.Endpoint);
        call.Headers.Authorization = new("Key", key);
        call.Content = JsonContent.Create(new { prompt = request.Text, image_size = new { width = quote.Size, height = quote.Size },
            num_images = 1, enable_safety_checker = true, output_format = "png", sync_mode = true });
        var reply = await http.SendAsync(call, CancellationToken.None).ConfigureAwait(false);
        if (reply.Status is < 200 or >= 300 || reply.Body.Length > 16 * 1024 * 1024)
            throw new VoxClipException(VoxClipErrorCode.ProviderError, "Illustration generation did not finish.");
        using var json = JsonDocument.Parse(reply.Body);
        var images = json.RootElement.GetProperty("images");
        const string prefix = "data:image/png;base64,";
        if (images.GetArrayLength() != 1 || images[0].GetProperty("url").GetString() is not { } url || !url.StartsWith(prefix, StringComparison.Ordinal))
            throw new InvalidDataException("Illustration generation did not return a PNG.");
        var bytes = Convert.FromBase64String(url[prefix.Length..]);
        if (!bytes.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
            throw new InvalidDataException("Illustration generation did not return a PNG.");
        var relative = IllustrationPath(request, projectId, quote);
        Save(bytes, relative, projectId, ClipEffectsRenderInput.ImageRoot(root));
        return Picture(request, relative);
    }

    private static JsonObject Entry(ClipAutopilotAction.Asset request, string kind) => new()
    {
        ["id"] = request.Id, ["clipId"] = request.ClipId, ["kind"] = kind, ["start"] = request.Start, ["end"] = request.End
    };

    private static JsonElement Picture(ClipAutopilotAction.Asset request, string relative)
    {
        var effect = Entry(request, "illustration");
        effect["imageFile"] = relative;
        return JsonSerializer.SerializeToElement(effect);
    }

    private static string IllustrationPath(ClipAutopilotAction.Asset request, string projectId, ClipIllustrationQuote quote)
        => $"{projectId}/illustration-{Hash(Encoding.UTF8.GetBytes($"{quote.Endpoint.AbsoluteUri}\n{quote.Size}\n{request.Text}"))}.png";

    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    private static string Save(byte[] bytes, string relative, string projectId, string root)
    {
        if (!Guid.TryParseExact(projectId, "D", out _)) throw new InvalidDataException("Invalid asset project.");
        var path = Path.Combine(root, relative);
        var directory = Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint) || new DirectoryInfo(root).Attributes.HasFlag(FileAttributes.ReparsePoint) ||
            (File.Exists(path) && File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint))) throw new InvalidDataException("Invalid asset path.");
        if (File.Exists(path)) return path;
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write)) { stream.Write(bytes); stream.Flush(true); }
            try { File.Move(temporary, path); } catch (IOException) when (File.Exists(path)) { }
        }
        finally { File.Delete(temporary); }
        return path;
    }
}

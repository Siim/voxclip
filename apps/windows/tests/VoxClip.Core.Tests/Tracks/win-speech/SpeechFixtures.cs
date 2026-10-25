using System.Net;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Models;
using VoxClip.Tests.Support;

namespace VoxClip.Core.Tests.Tracks.Speech;

internal sealed class SpeechFiles : IDisposable
{
    internal string Root { get; } = Path.Combine(Path.GetTempPath(), "voxclip-speech-" + Guid.NewGuid().ToString("N"));
    internal string Wav => Path.Combine(Root, "audio.wav");
    internal SpeechFiles()
    {
        Directory.CreateDirectory(Root);
        File.WriteAllBytes(Wav, new byte[96]);
    }
    internal TranscriptionRequest Request(TranscriptionOptions? options = null, LanguageChoice? language = null) => new(
        new(TranscriptEngine.Elevenlabs, null, language ?? new LanguageChoice.Auto(), options ?? new()),
        new(Wav, 16000, 1, 0, 0), new string('a', 64));

    internal async Task<ModelCatalog> CatalogueAsync(byte[] contents, string id = "whisper-base.en-q5_1", bool dependencies = false)
    {
        var source = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(FixtureLoader.SharedRoot, "catalog", "transcription-models.json")))!;
        var model = source["models"]!.AsArray().Single(entry => entry!["id"]!.GetValue<string>() == id)!;
        if (!dependencies) model["requires"] = new JsonArray();
        SetFile(model, contents);
        if (dependencies) SetFile(source["models"]!.AsArray().Single(entry => entry!["id"]!.GetValue<string>() == "silero-vad-v6.2.0")!, contents);
        var path = Path.Combine(Root, "catalog.json");
        await File.WriteAllTextAsync(path, source.ToJsonString());
        return ModelCatalog.FromFile(path);
    }

    private static void SetFile(JsonNode model, byte[] contents)
    {
        model["files"]![0]!["bytes"] = contents.Length;
        model["files"]![0]!["sha256"] = Convert.ToHexStringLower(SHA256.HashData(contents));
        model["totalBytes"] = contents.Length;
    }

    public void Dispose() => Directory.Delete(Root, true);
}

internal sealed class StubHttp(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    internal int Calls { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Calls++;
        return send(request, cancellationToken);
    }
    internal static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = new StringContent(json) };
}

internal sealed class TestKeys(string? key = "synthetic-test-credential") : IKeyProvider
{
    public Task<string?> GetKeyAsync(string account, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(account == "elevenlabs-api-key" ? key : null);
    }
}

internal sealed class CaptureProgress<T>(Action<T>? report = null) : IProgress<T>
{
    internal List<T> Values { get; } = [];
    public void Report(T value) { lock (Values) Values.Add(value); report?.Invoke(value); }
}

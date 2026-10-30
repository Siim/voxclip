using System.Text.Json;
using VoxClip.Core.Services.Speech;

namespace VoxClip.Core.Services.Models;

/// <summary>Catalogue-based confirmation and progress copy for Windows model downloads.</summary>
public static class ModelDownloadCopy
{
    /// <summary>The catalogue display name, falling back to the model id.</summary>
    public static string DisplayName(TranscriptionModel model) => Text(model, "displayName") ?? model.Id;

    /// <summary>The download confirmation title.</summary>
    public static string Title(TranscriptionModel model) => $"Download {DisplayName(model)} from {Host(model)}?";

    /// <summary>The publisher's terms and attribution, including required-model sizes.</summary>
    public static string Body(TranscriptionModel model, IReadOnlyList<TranscriptionModel> dependencies) =>
        $"This model is published by {Text(model, "publisher") ?? Host(model)}, not by VoxClip. It downloads from the publisher ({Size(model, dependencies)}) and runs on this PC. Licence: {model.License}. By downloading you accept the publisher's terms.\n\n{model.Attribution}";

    /// <summary>The combined download size.</summary>
    public static string Size(TranscriptionModel model, IReadOnlyList<TranscriptionModel> dependencies) =>
        SpeechCopy.Bytes(model.TotalBytes + dependencies.Sum(entry => entry.TotalBytes));

    /// <summary>Progress across the model and its required files.</summary>
    public static string Progress(TranscriptionModel model, ModelDownloadProgress progress) => progress.TotalBytes is long total && total > 0
        ? $"Downloading {DisplayName(model)} · {Math.Clamp(progress.BytesReceived * 100 / total, 0, 100)}% · {SpeechCopy.Bytes(progress.BytesReceived)} of {SpeechCopy.Bytes(total)}"
        : $"Downloading {DisplayName(model)}…";

    /// <summary>An HTTPS source page on the download host, if provided by the catalogue.</summary>
    public static Uri? SourcePage(TranscriptionModel model) =>
        Uri.TryCreate(Text(model, "sourcePage"), UriKind.Absolute, out var page) && page.Scheme == Uri.UriSchemeHttps && page.Host == Host(model) ? page : null;

    /// <summary>The transitive required models, counted once.</summary>
    public static IReadOnlyList<TranscriptionModel> Dependencies(TranscriptionModel model, IReadOnlyList<TranscriptionModel> catalogue)
    {
        var found = new List<TranscriptionModel>();
        void Add(TranscriptionModel entry)
        {
            foreach (var id in entry.Requires)
                if (id != model.Id && found.All(item => item.Id != id) && catalogue.FirstOrDefault(candidate => candidate.Id == id) is { } required)
                { found.Add(required); Add(required); }
        }
        Add(model);
        return found;
    }

    private static string Host(TranscriptionModel model) => model.Files.FirstOrDefault()?.Url.Host ?? model.LicenseUrl.Host;

    private static string? Text(TranscriptionModel model, string name) =>
        model.RawMetadata.ValueKind == JsonValueKind.Object && model.RawMetadata.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text ? text : null;
}

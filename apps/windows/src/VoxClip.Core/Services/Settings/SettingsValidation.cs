using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.Settings;

internal static class SettingsValidation
{
    internal static AppSettings Defaults()
    {
        var settings = new AppSettings("voxclip-settings/1") { Values = AppSettings.Defaults.ToDictionary(pair => pair.Key, pair => pair.Value.Clone(), StringComparer.Ordinal) };
        using var catalog = JsonDocument.Parse(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "catalog", "llm-providers.json")));
        foreach (var connector in catalog.RootElement.GetProperty("connectors").EnumerateArray())
        {
            var id = connector.GetProperty("id").GetString()!;
            if (connector.TryGetProperty("defaultModel", out var model) && model.ValueKind == JsonValueKind.String)
                settings.Values["llm.model." + id] = model.Clone();
            if (id is "ollama" or "lmstudio" && connector.TryGetProperty("baseUrl", out var url))
                settings.Values["llm.baseUrl." + id] = url.Clone();
        }
        return settings;
    }

    internal static void ValidateJson(string json)
    {
        using var document = JsonDocument.Parse(json);
        Require(document.RootElement.ValueKind == JsonValueKind.Object);
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in document.RootElement.EnumerateObject()) Require(keys.Add(property.Name));
    }

    private static readonly HashSet<string> KnownKeys = AppSettings.Defaults.Keys.ToHashSet(StringComparer.Ordinal);

    internal static bool KnownKey(string key)
        => KnownKeys.Contains(key) || key is "llm.baseUrl.ollama" or "llm.baseUrl.lmstudio" ||
            Regex.IsMatch(key, "\\A(?:llm\\.(?:model|cloudConsent)|voiceLab\\.providerConsent)\\.[a-z0-9]+(?:-[a-z0-9]+)*\\z", RegexOptions.CultureInvariant);

    internal static void Validate(AppSettings settings)
    {
        Require(settings.Schema == "voxclip-settings/1" && !settings.Values.ContainsKey("schema"));
        foreach (var pair in settings.Values)
        {
            var value = pair.Value;
            Require(value.ValueKind != JsonValueKind.Undefined);
            switch (pair.Key)
            {
                case "general.appearance": Choice(value, "system", "light", "dark"); break;
                case "general.transcriptTextSize": if (value.ValueKind != JsonValueKind.Null) Require(value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var size) && double.IsFinite(size) && size >= 13 && size <= 28); break;
                case "general.recentProjects": Strings(value, 20, false, false); break;
                case "editing.pauseBreath": Choice(value, "tight", "natural", "relaxed"); break;
                case "captions.defaultStyleId": Pattern(value, "[a-z0-9]+(?:-[a-z0-9]+)*"); break;
                case "cache.limitGB": Require(value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var limit) && limit is 2 or 5 or 10 or 20); break;
                case "transcription.engineMode": Choice(value, "local", "apple", "elevenlabs", "ask"); break;
                case "transcription.language": Pattern(value, "(?:auto|[a-z]{2,3})"); break;
                case "transcription.recentLanguages": Strings(value, 10, true, true); break;
                case "transcription.elevenlabs.region": Choice(value, "default", "us", "eu", "in", "sg"); break;
                case "export.defaultAspect": Choice(value, "source", "16:9", "9:16", "1:1"); break;
                case "export.quality": Choice(value, "standard", "high"); break;
                case "export.folder": if (value.ValueKind != JsonValueKind.Null) Text(value, 1, int.MaxValue); break;
                case "export.fileNamePattern": Text(value, 1, 200); break;
                case "update.lastCheckAt": if (value.ValueKind != JsonValueKind.Null) Require(value.ValueKind == JsonValueKind.String && value.TryGetDateTimeOffset(out _)); break;
                case "update.latestVersion": if (value.ValueKind != JsonValueKind.Null) Text(value, 0, int.MaxValue); break;
                case "update.htmlURL":
                    if (value.ValueKind != JsonValueKind.Null)
                        Require(value.ValueKind == JsonValueKind.String && value.GetString()!.StartsWith("https://github.com/", StringComparison.Ordinal) &&
                            !value.GetString()!.Any(character => char.IsControl(character) || character == '\\') &&
                            Uri.TryCreate(value.GetString(), UriKind.Absolute, out var updateUri) && updateUri.Scheme == "https" && updateUri.Host == "github.com" && updateUri.UserInfo.Length == 0);
                    break;
                case "llm.connector": case "llm.cliPath.claude-code": case "llm.cliPath.codex": Text(value, 0, int.MaxValue); break;
                case "llm.baseUrl.ollama": case "llm.baseUrl.lmstudio": Pattern(value, "https?://[\\s\\S]*"); break;
                case "llm.clips.lastPreset": Choice(value, "best", "hooks", "topics", "quotes", "custom"); break;
                case "llm.tighten.strength": Choice(value, "light", "normal", "strong"); break;
                case "general.showLowConfidence": case "general.openLastProject": case "onboarding.completed": case "transcription.cloudConsent.elevenlabs":
                case "export.srt": case "export.openFolderAfter": case "update.autoCheck": case "llm.clips.snapToLines": case "voiceLab.enabled": Boolean(value); break;
                default:
                    if (Regex.IsMatch(pair.Key, "\\Allm\\.model\\.[a-z0-9]+(?:-[a-z0-9]+)*\\z", RegexOptions.CultureInvariant)) Text(value, 1, 128);
                    else if (Regex.IsMatch(pair.Key, "\\A(?:llm\\.cloudConsent|voiceLab\\.providerConsent)\\.[a-z0-9]+(?:-[a-z0-9]+)*\\z", RegexOptions.CultureInvariant)) Boolean(value);
                    break;
            }
        }
    }

    private static void Strings(JsonElement value, int maximum, bool unique, bool language)
    {
        Require(value.ValueKind == JsonValueKind.Array && value.GetArrayLength() <= maximum);
        var found = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in value.EnumerateArray())
        {
            Text(item, 1, int.MaxValue);
            if (language) Pattern(item, "[a-z]{2,3}");
            if (unique) Require(found.Add(item.GetString()!));
        }
    }
    private static void Pattern(JsonElement value, string pattern) => Require(value.ValueKind == JsonValueKind.String && Regex.IsMatch(value.GetString()!, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant));
    private static void Text(JsonElement value, int minimum, int maximum) => Require(value.ValueKind == JsonValueKind.String && value.GetString()!.EnumerateRunes().Count() >= minimum && value.GetString()!.EnumerateRunes().Count() <= maximum);
    private static void Boolean(JsonElement value) => Require(value.ValueKind is JsonValueKind.True or JsonValueKind.False);
    private static void Choice(JsonElement value, params string[] choices) => Require(value.ValueKind == JsonValueKind.String && choices.Contains(value.GetString(), StringComparer.Ordinal));
    private static void Require(bool condition) { if (!condition) throw new JsonException("Invalid settings value."); }
}

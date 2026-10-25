using System.Collections.Frozen;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.Captions;

internal static class CaptionDataLoader
{
    private static readonly Lazy<CaptionData> CurrentData = CreateCache(() => Load(SharedResources.ResolveRoot()));
    internal static CaptionData Current => CurrentData.Value;

    internal static Lazy<CaptionData> CreateCache(Func<CaptionData> load) => new(load, LazyThreadSafetyMode.PublicationOnly);

    internal static CaptionData Load(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        root = Path.GetFullPath(root);
        JsonElement Read(string path)
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, path)));
            return document.RootElement.Clone();
        }
        var manifest = Read("fonts/fonts.json");
        var fonts = manifest.GetProperty("fonts").EnumerateArray().Select(font => new CaptionFontInfo(
            font.GetProperty("file").GetString()!, font.GetProperty("path").GetString()!,
            font.GetProperty("family").GetString()!, font.GetProperty("weight").GetInt32(), font.GetProperty("italic").GetBoolean(),
            font.GetProperty("unitsPerEm").GetInt32(), font.GetProperty("capHeight").GetInt32(), font.GetProperty("spaceAdvance").GetInt32(),
            font.GetProperty("sha256").GetString()!, Array.AsReadOnly(font.GetProperty("coverage").EnumerateArray()
                .Select(range => (range[0].GetInt32(), range[1].GetInt32())).ToArray()))).ToFrozenDictionary(font => font.File, StringComparer.Ordinal);
        var caseMap = Read("caption-styles/casemap.json");
        var upper = caseMap.GetProperty("upper").EnumerateArray().ToFrozenDictionary(pair => pair[0].GetInt32(), pair => pair[1].GetInt32());
        var lower = caseMap.GetProperty("lower").EnumerateArray().ToFrozenDictionary(pair => pair[0].GetInt32(), pair => pair[1].GetInt32());
        return new(root, fonts, upper, lower, caseMap.GetProperty("rules"),
            Read("caption-styles/stopwords.json").GetProperty("languages"), Read("caption-styles/emoji-keywords.json").GetProperty("languages"));
    }
}

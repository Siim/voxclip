using System.Collections.Frozen;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Services.Captions;

namespace VoxClip.Core.Services.Settings;

/// <summary>Strictly decoded bundled styles, ordered for the gallery; captions §2.4.</summary>
public sealed class CaptionStyleLibrary
{
    private readonly FrozenDictionary<string, CaptionStyle> byId;

    private CaptionStyleLibrary(CaptionStyle[] styles)
    {
        Styles = Array.AsReadOnly(styles);
        byId = styles.ToFrozenDictionary(style => style.Id, StringComparer.Ordinal);
    }

    /// <summary>Load generated caption-style contracts from the selected shared directory.</summary>
    public static CaptionStyleLibrary Load(string sharedRoot)
    {
        var data = CaptionDataLoader.Load(Path.GetFullPath(sharedRoot));
        return new(Directory.EnumerateFiles(Path.Combine(data.Root, "caption-styles", "styles"), "*.json")
            .Select(path => CaptionStyleResolver.Decode(File.ReadAllText(path), data))
            .OrderBy(style => style.Order).ThenBy(style => style.Id, StringComparer.Ordinal).ToArray());
    }

    /// <summary>Bundled styles in ascending gallery order.</summary>
    public IReadOnlyList<CaptionStyle> Styles { get; }

    /// <summary>Find an exact bundled style ID, or return null.</summary>
    public CaptionStyle? Find(string id) => byId.GetValueOrDefault(id);
}

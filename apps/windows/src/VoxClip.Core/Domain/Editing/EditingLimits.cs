using System.Text;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Persistable editor input limits from project.schema.json.</summary>
public static class EditingLimits
{
    /// <summary>Maximum normalized correction length in Unicode code points.</summary>
    public const int MaxCorrectionCodePoints = 200;
    /// <summary>Maximum trimmed clip title length in Unicode code points.</summary>
    public const int MaxClipTitleCodePoints = 120;
    /// <summary>Maximum ASCII clip/result identifier length.</summary>
    public const int MaxIdLength = 64;

    internal static bool ValidLength(string text, int maximum) => text.EnumerateRunes().Count() <= maximum;

    internal static bool ValidId(string id) => id.Length is >= 1 and <= MaxIdLength && char.IsAsciiLetterOrDigit(id[0]) &&
        id.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or ':' or '-');
}

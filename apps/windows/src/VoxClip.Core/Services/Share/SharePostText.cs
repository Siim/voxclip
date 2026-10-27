using System.Text.Json;
using VoxClip.Core.Domain.Share;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.Share;

/// <summary>Post text for Copy caption, Open X, Open LinkedIn and VoxConvo publish; publishing §2.1 and voice-lab §11.3.
/// Reads shared/data/share-text.json once through <see cref="SharedResources"/>; a missing or invalid file throws
/// <see cref="VoxClipException"/> with <see cref="VoxClipErrorCode.SharedResourcesMissing"/>. The App and voxclip-cli call
/// <see cref="Preflight"/> at launch, and after it succeeds the file is never read again.</summary>
public static class SharePostText
{
    /// <summary>The launch check next to <see cref="SharedResources.ResolveRoot"/>: loads the rules or throws.</summary>
    public static void Preflight() => _ = ShareTextRulesLoader.Current;

    /// <summary>X 280 (weighted), LinkedIn 3,000 (Unicode scalars), VoxConvo 2,048 (UTF-16 code units).</summary>
    public static int Limit(ShareDestination destination) => ShareTextRulesLoader.Current.Limit(destination);

    /// <summary>The X counter: twitter-text v3 weighted length of the NFC text.</summary>
    public static int XWeight(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return ShareTextRulesLoader.Current.XWeight(text);
    }

    /// <summary>The LinkedIn counter: Unicode scalar count.</summary>
    public static int LinkedInLength(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return ShareTextRules.LinkedInLength(text);
    }

    /// <summary>UTF-16 code units, a deliberately conservative bound on vox-api's <c>@Length(0, 2048)</c> for <c>NewPostInput.text</c>:
    /// validator.js <c>isLength</c> subtracts surrogate pairs and U+FE0E/U+FE0F, so any text within 2,048 units is accepted.</summary>
    public static int VoxConvoLength(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return ShareTextRules.VoxConvoLength(text);
    }

    /// <summary>The caption as <c>share.captions</c> holds it: its first 3,000 Unicode scalars (voice-lab §11.3), a lone surrogate
    /// counting as one, as <see cref="LinkedInLength"/> counts it. Both Apps cap their caption field with it, so the field, Copy
    /// caption, the composers and the saved caption see the same text.</summary>
    public static string CapCaption(string caption)
    {
        ArgumentNullException.ThrowIfNull(caption);
        int count = 0, length = 0;
        foreach (var rune in caption.EnumerateRunes())
        {
            if (++count > 3000) return caption[..length];
            length += rune.Utf16SequenceLength;
        }
        return caption;
    }

    /// <summary>The text Open X (<see cref="ShareDestination.X"/>) or VoxConvo publish (<see cref="ShareDestination.VoxConvo"/>) sends.
    /// A caption that fits is returned unchanged. Otherwise the last occurrence of <paramref name="disclosureLine"/> is removed, the
    /// rest is cut at a word boundary with "…", and the line follows after a blank line, never cut. LinkedIn returns the caption
    /// unchanged; Copy caption never uses this.</summary>
    public static string ComposerText(string caption, ShareDestination destination, string? disclosureLine)
    {
        ArgumentNullException.ThrowIfNull(caption);
        return ShareTextRulesLoader.Current.ComposerText(caption, destination, disclosureLine);
    }

    /// <summary>The default caption: <paramref name="title"/> (null for the full take), blank line, and the first sentence of
    /// <paramref name="words"/>, the target's edited, corrected word texts in transcript order. At most 40 words, followed by "…"
    /// when no word ends a sentence.</summary>
    public static string DefaultCaption(string? title, IEnumerable<string> words)
    {
        ArgumentNullException.ThrowIfNull(words);
        return ShareTextRulesLoader.Current.DefaultCaption(title, words);
    }

    /// <summary>The caption field text: the saved or default caption, with the line appended after a blank line when a line exists
    /// and is not present, the caption cut (never the line) to keep the text within 3,000 Unicode scalars. Otherwise the input
    /// unchanged.</summary>
    public static string FieldText(string savedOrDefault, string? line)
    {
        ArgumentNullException.ThrowIfNull(savedOrDefault);
        return ShareDisclosure.FieldText(savedOrDefault, line, ShareTextRulesLoader.Current);
    }
}

/// <summary>Loads shared/data/share-text.json once per process; architecture §2.4. A failed load is kept too, as the Mac keeps its
/// <c>Result</c>, so a process that failed the preflight never loads mid-session.</summary>
internal static class ShareTextRulesLoader
{
    private static readonly Lazy<ShareTextRules> CurrentRules = CreateCache(() => Load(SharedResources.ResolveRoot()));

    internal static ShareTextRules Current => CurrentRules.Value;

    /// <summary>ExecutionAndPublication caches the exception of a failed load as well; PublicationOnly would load again on every
    /// call.</summary>
    internal static Lazy<ShareTextRules> CreateCache(Func<ShareTextRules> load) => new(load, LazyThreadSafetyMode.ExecutionAndPublication);

    internal static ShareTextRules Load(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        try { return ShareTextRules.Parse(File.ReadAllText(Path.Combine(root, "data", "share-text.json"))); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or FormatException
            or InvalidOperationException or KeyNotFoundException or IndexOutOfRangeException)
        {
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.", error);
        }
    }
}

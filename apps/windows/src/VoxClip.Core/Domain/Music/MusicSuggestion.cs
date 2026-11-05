using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.Music;

/// <summary>What Claude (or the user's search) asks for; doc/spec/music.md §3.4, the twin of Mac MusicBrief. The planner's music
/// suggestion maps onto it: its mood and title become the library query, its Eleven Music prompt the generation prompt.</summary>
public sealed record MusicBrief(string Mood, string Query = "", string Prompt = "", string? Reason = null)
{
    /// <summary>The words the library search sends, at most 200 characters.</summary>
    public string SearchText
    {
        get
        {
            var text = (string.IsNullOrWhiteSpace(Query) ? Mood : Query).Trim();
            return text.Length <= 200 ? text : text[..200];
        }
    }

    /// <summary>The instrumental prompt Eleven Music receives, at most 2,000 characters.</summary>
    public string CompositionPrompt
    {
        get
        {
            var text = Prompt.Trim();
            var basis = text.Length == 0 ? $"Instrumental background music, {Mood.Trim()} mood, steady, sits under a voice" : text;
            return basis.Length <= 2000 ? basis : basis[..2000];
        }
    }

    /// <summary>Lower-cased words of three or more letters, for matching the user's own file names.</summary>
    public IReadOnlySet<string> Keywords => MusicWords.Split(Mood + " " + Query).Where(word => word.Length >= 3).ToHashSet(StringComparer.Ordinal);

    /// <summary>The planner's pick as a brief: its title and mood search the library, its prompt makes a track.</summary>
    public static MusicBrief From(Autopilot.ClipAutopilotPlan.Music music) =>
        new(music.Mood, (music.Title + " " + music.Mood).Trim(), music.Prompt, music.Reason.Length == 0 ? null : music.Reason);
}

/// <summary>Lower-case letter and digit runs.</summary>
public static class MusicWords
{
    /// <summary>The lower-case words of <paramref name="text"/>.</summary>
    public static IEnumerable<string> Split(string text)
    {
        var word = new System.Text.StringBuilder();
        foreach (var character in text.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(character)) { word.Append(character); continue; }
            if (word.Length > 0) { yield return word.ToString(); word.Clear(); }
        }
        if (word.Length > 0) yield return word.ToString();
    }
}

/// <summary>One playable choice in the Music section: a library match, a priced generation not yet made, or the user's file.</summary>
public sealed record MusicCandidate(string Id, MusicSource Source, string Title, MusicLicense License, string FileExtension)
{
    /// <summary>The artist, when the source names one.</summary>
    public string? Creator { get; init; }
    /// <summary>The credit text (required for CC BY).</summary>
    public string? Attribution { get; init; }
    /// <summary>The landing page (library).</summary>
    public string? SourceUrl { get; init; }
    /// <summary>The file to download (library, https) or the user's file path (file); null for a generation not yet made.</summary>
    public string? Audio { get; init; }
    /// <summary>The Eleven Music prompt (generated).</summary>
    public string? Prompt { get; init; }
    /// <summary>The track's length when known.</summary>
    public double? DurationSeconds { get; init; }
    /// <summary>The quoted price (generated only).</summary>
    public CostEstimate? Estimate { get; init; }
    /// <summary>Why it suits the clip.</summary>
    public string? Reason { get; init; }
    /// <summary>The source's tags and genres, used for ranking.</summary>
    public IReadOnlyList<string> Tags { get; init; } = [];
    /// <summary>Paid before it can play.</summary>
    public bool NeedsGeneration => Source == MusicSource.Generated && Audio is null;
}

/// <summary>At most one candidate per source, ordered library, generated, file, and why a source has nothing (offline,
/// rate-limited, no key); a note never hides the others.</summary>
public sealed record MusicSuggestionResult(IReadOnlyList<MusicCandidate> Candidates, IReadOnlyDictionary<MusicSource, string> Notes)
{
    /// <summary>Nothing found and nothing to say.</summary>
    public static MusicSuggestionResult Empty { get; } = new([], new Dictionary<MusicSource, string>());
}

/// <summary>Eleven Music length and price; music.md §3.2 and shared/catalog/voice-lab.json's <c>musicCompose</c> row.</summary>
public static class MusicPricing
{
    /// <summary>The catalogue operation.</summary>
    public static readonly VoiceLabPricedOperation Operation = new("elevenlabs", "musicCompose", null, "second");
    /// <summary>The model the catalogue prices.</summary>
    public const string Model = "music_v1";
    /// <summary>VoxClip asks for 3 s to 5 min.</summary>
    public const double MinimumSeconds = 3, MaximumSeconds = 300;

    /// <summary>The whole-second length composed for a clip of <paramref name="clipSeconds"/>: rounded up, within 3 s and 5 min.</summary>
    public static int LengthSeconds(double clipSeconds) =>
        !double.IsFinite(clipSeconds) || clipSeconds <= 0 ? (int)MinimumSeconds : (int)Math.Min(MaximumSeconds, Math.Max(MinimumSeconds, Math.Ceiling(clipSeconds)));

    /// <summary>The catalogue's price for <paramref name="seconds"/> of music.</summary>
    public static CostEstimate Estimate(int seconds, VoiceLabPriceCatalog catalog) => VoiceLabPricing.Estimate(Operation, Model, seconds, 1, null, catalog);

    /// <summary>"$0.15", cents rounded up so the label never under-states the charge; null for an unknown price.</summary>
    public static string? Label(CostEstimate estimate) => estimate.Usd is { } usd
        ? "$" + (Math.Ceiling(usd * 100) / 100).ToString("0.00", CultureInfo.InvariantCulture) : null;
}

/// <summary>The text an export's post carries; music.md §5.</summary>
public static class MusicCredits
{
    /// <summary>The track's credit line (Mac ProjectMusic.creditLine), or null for the user's own file. Library tracks use Openverse's
    /// attribution ("Music: " + attribution), or "Music: “title” by creator (CC0) url" without one; generated tracks credit Eleven Music.</summary>
    public static string? Line(ProjectMusic music) => music.License switch
    {
        MusicLicense.Own => null,
        MusicLicense.Generated => $"Music: “{music.Title}”, made with Eleven Music.",
        _ when music.Attribution is { Length: > 0 } attribution => "Music: " + attribution,
        _ => $"Music: “{music.Title}”" + (music.Creator is { } creator ? " by " + creator : "")
            + $" ({(music.License == MusicLicense.Cc0 ? "CC0" : music.License == MusicLicense.Pdm ? "Public Domain Mark" : "CC BY")})"
            + (music.SourceUrl is { } url ? " " + url : "")
    };

    /// <summary>The post text with the track's credit appended once, on its own line.</summary>
    public static string PostText(string text, ProjectMusic? music)
    {
        if (music is null || Line(music) is not { } line || text.Contains(line, StringComparison.Ordinal)) return text;
        var trimmed = text.Trim();
        return trimmed.Length == 0 ? line : trimmed + "\n\n" + line;
    }
}

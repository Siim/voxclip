using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Derived project sample clock; recordings keep their stored local transcripts.</summary>
public sealed class ProjectClock
{
    /// <summary>A half-open recording region on the primary audio grid.</summary>
    /// <param name="Key">Media content key.</param>
    /// <param name="Label">Display name.</param>
    /// <param name="ColourIndex">Stable zero-based index into the recording ramp.</param>
    /// <param name="OffsetSamples">First project sample.</param>
    /// <param name="DurationSamples">Region length on the project grid.</param>
    /// <param name="GainDb">Level adjustment.</param>
    /// <param name="Prefix">Word ID qualifier; empty for primary words.</param>
    public sealed record Region(string Key, string Label, int ColourIndex, long OffsetSamples, long DurationSamples, double GainDb, string Prefix)
    {
        /// <summary>Exclusive end on the project grid.</summary>
        public long EndSample => OffsetSamples + DurationSamples;
    }

    /// <summary>Primary recording's planning rate.</summary>
    public int SampleRate { get; }
    /// <summary>Regions in clock order, primary first.</summary>
    public IReadOnlyList<Region> Regions { get; }
    /// <summary>Joined view, or the original transcript when there is one region.</summary>
    public TranscriptModel? Transcript { get; }
    /// <summary>Joined words in clock order.</summary>
    public IReadOnlyList<TimedWord> Words => Transcript?.Words ?? [];
    /// <summary>Exclusive clock end, including internal guard gaps.</summary>
    public long TotalSamples => Regions[^1].EndSample;
    internal IReadOnlyList<MediaInterval> SampleRegions => Regions.Select(region => new MediaInterval(region.OffsetSamples, region.EndSample)).ToArray();
    /// <summary>Half-open intervals that have no source media.</summary>
    public IEnumerable<(long Start, long End)> GuardGaps => Regions.Zip(Regions.Skip(1), (before, after) => (before.EndSample, after.OffsetSamples));
    private readonly IReadOnlyDictionary<string, int>? regionByWord;

    private ProjectClock(int sampleRate, IReadOnlyList<Region> regions, TranscriptModel? transcript, IReadOnlyDictionary<string, int>? regionByWord = null)
        => (SampleRate, Regions, Transcript, this.regionByWord) = (sampleRate, regions, transcript, regionByWord);

    /// <summary>Derive the clock without modifying the snapshot.</summary>
    public static ProjectClock Build(Project project)
    {
        var primary = project.Media.Source;
        var rate = Math.Max(1, primary.Audio?.SampleRate ?? 48_000);
        Region first = new(primary.ContentKey, Label(primary), 0, 0, Samples(primary.DurationSeconds, rate) ?? 0, 0, "");
        if (project.Transcript is not { } transcript || project.Media.SpokenSources is not { Count: > 0 } sources)
            return new(rate, [first], project.Transcript);
        List<Region> regions = [first];
        List<TimedWord> words = [.. transcript.Words];
        var regionByWord = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var word in words) regionByWord[word.Id] = 0;
        foreach (var source in sources)
        {
            if (project.Media.AdditionalSources?.FirstOrDefault(reference => reference.ContentKey == source.SourceKey) is not { } reference) continue;
            var offset = Samples(source.OffsetSeconds, rate) ?? 0;
            var duration = Samples(reference.DurationSeconds, rate) ?? 0;
            if (offset < regions[^1].EndSample || offset > long.MaxValue - duration) continue;
            var index = regions.Count;
            var colour = ((PrefixNumber(source.WordIdPrefix) ?? 2) - 1) % 6;
            regions.Add(new(source.SourceKey, source.Label ?? Label(reference), colour, offset, duration, source.GainDb ?? 0, source.WordIdPrefix));
            double Shift(double seconds) => (offset + EditingMath.Round(seconds * rate)) / rate;
            foreach (var word in source.Transcript.Words)
            {
                var id = source.WordIdPrefix + word.Id;
                regionByWord[id] = index;
                words.Add(word with { Id = id, Start = Shift(word.Start), End = Shift(word.End),
                    RawStart = word.RawStart is { } start ? Shift(start) : null, RawEnd = word.RawEnd is { } end ? Shift(end) : null });
            }
        }
        return new(rate, regions, transcript with { Words = words, DurationSeconds = (double)regions[^1].EndSample / rate }, regionByWord);
    }

    /// <summary>Find the region containing a project sample; null in a gap.</summary>
    public Region? RegionAt(long sample) => Regions.FirstOrDefault(region => region.OffsetSamples <= sample && sample < region.EndSample);

    /// <summary>Find the region of a known word ID.</summary>
    public Region? RegionOf(string wordId) => regionByWord is null ? (Words.Any(word => word.Id == wordId) ? Regions[0] : null) :
        regionByWord.TryGetValue(wordId, out var index) ? Regions[index] : null;

    /// <summary>Whether both range endpoints belong to the same known region.</summary>
    public bool ContainsRange(string startWordId, string endWordId) => RegionOf(startWordId) is { } start && start == RegionOf(endWordId);

    /// <summary>Resolve a clock sample to its recording and resampled local position.</summary>
    public (string Key, long LocalSample)? Resolve(long sample) => RegionAt(sample) is { } region ? (region.Key, sample - region.OffsetSamples) : null;

    /// <summary>Map a sample on the resampled recording grid onto the clock.</summary>
    public long? MapTime(string key, long localSample) => Regions.FirstOrDefault(region => region.Key == key) is { } region &&
        localSample >= 0 && localSample < region.DurationSamples ? region.OffsetSamples + localSample : null;

    /// <summary>Invert <see cref="MapTime"/> outside guard gaps.</summary>
    public (string Key, long LocalSample)? SourceTime(long clockSample) => Resolve(clockSample);

    /// <summary>Quantize local seconds onto the clock.</summary>
    public double? ClockTime(string key, double localSeconds) => Samples(localSeconds, SampleRate) is { } sample &&
        MapTime(key, sample) is { } mapped ? (double)mapped / SampleRate : null;

    /// <summary>Resolve clock seconds to quantized seconds in a recording.</summary>
    public (string Key, double LocalSeconds)? LocalTime(double clockSeconds) => Samples(clockSeconds, SampleRate) is { } sample &&
        Resolve(sample) is { } result ? (result.Key, (double)result.LocalSample / SampleRate) : null;

    /// <summary>Detect only pauses between words from the same recording.</summary>
    public IReadOnlyList<Pause> Pauses(double thresholdSeconds)
    {
        var detected = EditingAlgorithms.DetectPauses(Words, thresholdSeconds);
        return regionByWord is null ? detected : detected.Where(pause =>
            regionByWord[Words[pause.AfterIndex].Id] == regionByWord[Words[pause.AfterIndex + 1].Id]).ToArray();
    }

    internal static int? PrefixNumber(string prefix) => prefix.Length >= 3 && prefix[0] == 'r' && prefix[^1] == '.' &&
        int.TryParse(prefix.AsSpan(1, prefix.Length - 2), NumberStyles.None, CultureInfo.InvariantCulture, out var number) &&
        number >= 2 && prefix == FormattableString.Invariant($"r{number}.") ? number : null;

    internal static void Validate(Project project)
    {
        var sources = project.Media.SpokenSources;
        Require((project.SchemaVersion == ProjectSerialization.CurrentVersion) == (sources is not null), "Spoken recordings require project version 7.");
        if (sources is null) return;
        Require(sources.Count is >= 1 and <= 5 && project.Transcript is not null, "Spoken recordings need a primary transcript and one to five companions.");
        var media = project.Media;
        var rate = media.Source.Audio?.SampleRate ?? 48_000;
        var end = media.Source.DurationSeconds;
        var previousPrefix = 1;
        HashSet<string> keys = new(StringComparer.Ordinal) { media.Source.ContentKey };
        var ids = project.Transcript!.Words.Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var source in sources)
        {
            var references = media.AdditionalSources?.Where(reference => reference.ContentKey == source.SourceKey).ToArray() ?? [];
            var prefix = PrefixNumber(source.WordIdPrefix);
            Require(keys.Add(source.SourceKey) && Regex.IsMatch(source.SourceKey, "\\A[a-f0-9]{64}\\z") && references.Length == 1 &&
                prefix > previousPrefix, "Invalid spoken recording key or prefix.");
            var reference = references[0];
            Require(source.OffsetSeconds >= Math.Ceiling(end) + 1 && reference.DurationSeconds > 0 &&
                Samples(source.OffsetSeconds + reference.DurationSeconds, rate) is not null, "Invalid spoken recording offset or duration.");
            Require(source.Label is null || source.Label.EnumerateRunes().Count() <= 24, "Invalid spoken recording label.");
            Require(source.GainDb is null or >= -12 and <= 12, "Invalid spoken recording gain.");
            var previousStart = double.NegativeInfinity;
            foreach (var word in source.Transcript.Words)
            {
                var qualified = source.WordIdPrefix + word.Id;
                Require(double.IsFinite(word.Start) && double.IsFinite(word.End) && word.Start >= 0 && word.Start >= previousStart &&
                    word.End > word.Start && word.End <= reference.DurationSeconds && ValidWordId(word.Id) && ValidWordId(qualified) &&
                    ids.Add(qualified), "Invalid spoken recording word or timing.");
                previousStart = word.Start;
            }
            end = source.OffsetSeconds + reference.DurationSeconds;
            previousPrefix = prefix!.Value;
        }
    }

    private static bool ValidWordId(string id) => Regex.IsMatch(id, "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\\z");
    private static long? Samples(double seconds, int rate) => seconds >= 0 && rate > 0 &&
        EditingMath.Round(seconds * rate) is >= 0 and < 9223372036854775808.0 and var sample ? (long)sample : null;

    /// <summary>The display label of a file before it has been added to the project clock.</summary>
    public static string Label(MediaReference reference)
    {
        var path = reference.AbsolutePath.Replace('\\', '/');
        var stem = Path.GetFileNameWithoutExtension(path);
        var number = Regex.Match(stem, "(?<![0-9])[0-9]{4}(?![0-9])", RegexOptions.RightToLeft);
        return number.Success ? number.Value : string.Concat(Path.GetFileName(path).EnumerateRunes().Take(12).Select(rune => rune.ToString()));
    }

    private static void Require(bool valid, string message)
    {
        if (!valid) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, message);
    }
}

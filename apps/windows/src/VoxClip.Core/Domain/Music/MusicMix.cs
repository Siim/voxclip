using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Music;

/// <summary>Pure arithmetic for the music bed under the voice; doc/spec/music.md §4, the twin of Mac Core MusicMix.swift. Media
/// decodes and mixes audio, this decides every gain: speech activity from the final voice audio, ducking, fades, the loudness
/// match and crossfaded loops. shared/fixtures/music/music-mix-cases.json replays it on both platforms.</summary>
public static class MusicMix
{
    /// <summary>Analysis frames are 10 ms long.</summary>
    public const double FrameSeconds = 0.01;
    /// <summary>The dip under speech.</summary>
    public const double DuckDb = -12.0;
    /// <summary>Ducking reaches its depth by each speech onset over this.</summary>
    public const double AttackSeconds = 0.15;
    /// <summary>Ducking recovers over this after speech ends.</summary>
    public const double ReleaseSeconds = 0.4;
    /// <summary>Loops overlap by up to one second, equal-power.</summary>
    public const double LoopCrossfadeSeconds = 1.0;
    /// <summary>The speech level assumed when a clip has no measurable speech, in dBFS RMS.</summary>
    public const double FallbackSpeechDb = -20.0;
    /// <summary>The level of a silent frame.</summary>
    public const double SilenceFloorDb = -120.0;
    /// <summary>The bed never gains more than this, so a near-silent track is not pushed into noise.</summary>
    public const double MaximumBoostDb = 12.0;
    /// <summary>The bed never sits lower than this.</summary>
    public const double MinimumBedDb = -60.0;
    /// <summary>Speech gaps shorter than this stay ducked.</summary>
    public const double BridgeGapSeconds = 0.25;
    /// <summary>Blips shorter than this are not speech.</summary>
    public const double MinimumSpeechSeconds = 0.05;

    /// <summary>RMS level in dBFS of each whole or trailing partial frame of mono samples.</summary>
    public static double[] FrameLevels(ReadOnlySpan<float> mono, double sampleRate)
    {
        var accumulator = new LevelAccumulator(FrameSize(sampleRate));
        accumulator.Append(mono);
        return accumulator.Finish();
    }

    /// <summary>Samples per 10 ms analysis frame at <paramref name="sampleRate"/>.</summary>
    public static int FrameSize(double sampleRate) => Math.Max(1, (int)Math.Round(sampleRate * FrameSeconds, MidpointRounding.AwayFromZero));

    /// <summary>Streams mono samples into 10 ms RMS levels without keeping the audio.</summary>
    public sealed class LevelAccumulator(int frameSize)
    {
        private readonly List<double> levels = [];
        private double sum;
        private int count;

        /// <summary>Samples per level.</summary>
        public int FrameSize { get; } = Math.Max(1, frameSize);

        /// <summary>Adds samples; a non-finite sample counts as silence.</summary>
        public void Append(ReadOnlySpan<float> samples)
        {
            foreach (var sample in samples)
            {
                var value = float.IsFinite(sample) ? (double)sample : 0;
                sum += value * value;
                count++;
                if (count == FrameSize) Flush();
            }
        }

        private void Flush()
        {
            var mean = sum / count;
            levels.Add(mean > 0 ? Math.Max(SilenceFloorDb, 10 * Math.Log10(mean)) : SilenceFloorDb);
            sum = 0; count = 0;
        }

        /// <summary>The levels, including a trailing partial frame.</summary>
        public double[] Finish()
        {
            if (count > 0) Flush();
            return levels.ToArray();
        }
    }

    /// <summary>Which frames hold speech. The threshold follows the clip's own loud frames (90th percentile − 25 dB, never below
    /// −50 dBFS), short blips are dropped and short pauses between words are bridged.</summary>
    public static bool[] SpeechActivity(IReadOnlyList<double> levels)
    {
        var audible = levels.Where(level => level > -80).Order().ToArray();
        if (audible.Length == 0) return new bool[levels.Count];
        var index = Math.Min(audible.Length - 1, (int)Math.Round((audible.Length - 1) * 0.9, MidpointRounding.AwayFromZero));
        var threshold = Math.Max(-50.0, audible[index] - 25);
        var active = levels.Select(level => level >= threshold).ToArray();
        var minimumRun = (int)Math.Round(MinimumSpeechSeconds / FrameSeconds, MidpointRounding.AwayFromZero);
        var bridge = (int)Math.Round(BridgeGapSeconds / FrameSeconds, MidpointRounding.AwayFromZero);
        ReplaceRuns(active, true, minimumRun, false, interiorOnly: false);
        ReplaceRuns(active, false, bridge, true, interiorOnly: true);
        return active;
    }

    private static void ReplaceRuns(bool[] flags, bool value, int limit, bool replacement, bool interiorOnly)
    {
        var start = 0;
        while (start < flags.Length)
        {
            var end = start;
            while (end < flags.Length && flags[end] == flags[start]) end++;
            var interior = start > 0 && end < flags.Length;
            if (flags[start] == value && end - start < limit && (interior || !interiorOnly))
                for (var index = start; index < end; index++) flags[index] = replacement;
            start = end;
        }
    }

    /// <summary>The power mean of <paramref name="levels"/> where <paramref name="include"/> is true, in dB; null when nothing is.</summary>
    public static double? PowerMeanDb(IReadOnlyList<double> levels, IReadOnlyList<bool> include)
    {
        double sum = 0; var count = 0;
        for (var index = 0; index < Math.Min(levels.Count, include.Count); index++)
        {
            if (!include[index]) continue;
            sum += Math.Pow(10, levels[index] / 10); count++;
        }
        return count > 0 && sum > 0 ? 10 * Math.Log10(sum / count) : null;
    }

    /// <summary>The speech loudness of the final voice audio, or null without speech.</summary>
    public static double? SpeechLevelDb(IReadOnlyList<double> levels, IReadOnlyList<bool> activity) => PowerMeanDb(levels, activity);

    /// <summary>The track's own level over its audible frames.</summary>
    public static double? MusicLevelDb(IReadOnlyList<double> levels) => PowerMeanDb(levels, levels.Select(level => level > -70).ToArray());

    /// <summary>The static gain that puts the bed <paramref name="gainDb"/> below (or above) the speech: speech + gain − music, bounded.</summary>
    public static double BedGainDb(double? speechDb, double? musicDb, double gainDb)
    {
        var speech = speechDb ?? FallbackSpeechDb;
        var music = musicDb ?? speech;
        return Math.Min(MaximumBoostDb, Math.Max(MinimumBedDb, speech + gainDb - music));
    }

    /// <summary>Per-frame ducking in dB, linear in dB: it reaches <see cref="DuckDb"/> by each speech onset (the attack starts
    /// 150 ms early, since the whole clip is known) and recovers over 400 ms after speech ends. All zeros without ducking.</summary>
    public static double[] DuckingGainsDb(IReadOnlyList<bool> activity, bool ducking = true)
    {
        var count = activity.Count;
        if (!ducking || !activity.Contains(true)) return new double[count];
        var attack = Math.Max(1.0, AttackSeconds / FrameSeconds);
        var release = Math.Max(1.0, ReleaseSeconds / FrameSeconds);
        var untilNext = new double[count];
        var sinceLast = new double[count];
        var next = double.PositiveInfinity;
        for (var index = count - 1; index >= 0; index--) { next = activity[index] ? 0 : next + 1; untilNext[index] = next; }
        var last = double.PositiveInfinity;
        for (var index = 0; index < count; index++) { last = activity[index] ? 0 : last + 1; sinceLast[index] = last; }
        var gains = new double[count];
        for (var index = 0; index < count; index++)
        {
            var before = DuckDb * Math.Max(0, 1 - untilNext[index] / attack);
            var after = DuckDb * Math.Max(0, 1 - sinceLast[index] / release);
            gains[index] = Math.Min(before, after);
        }
        return gains;
    }

    /// <summary>The ducking gain at <paramref name="seconds"/>, interpolated between frame centres, as a linear factor.</summary>
    public static double DuckFactor(IReadOnlyList<double> gainsDb, double seconds)
    {
        if (gainsDb.Count == 0) return 1;
        var position = seconds / FrameSeconds - 0.5;
        var lower = Math.Max(0, Math.Min(gainsDb.Count - 1, (int)Math.Floor(position)));
        var upper = Math.Min(gainsDb.Count - 1, lower + 1);
        var fraction = Math.Max(0, Math.Min(1, position - lower));
        var db = gainsDb[lower] + (gainsDb[upper] - gainsDb[lower]) * fraction;
        return Math.Pow(10, db / 20);
    }

    /// <summary>Linear fade-in from silence and fade-out to silence over a bed of <paramref name="duration"/> seconds.</summary>
    public static double FadeFactor(double seconds, double duration, double fadeIn, double fadeOut)
    {
        var factor = 1.0;
        if (fadeIn > 0) factor = Math.Min(factor, Math.Max(0, seconds / fadeIn));
        if (fadeOut > 0) factor = Math.Min(factor, Math.Max(0, (duration - seconds) / fadeOut));
        return Math.Min(1, factor);
    }

    /// <summary>One stretch of the source track placed in the bed. Neighbours overlap by FadeIn/FadeOut frames.</summary>
    public sealed record LoopPiece(long SourceStart, long OutputStart, long Count, long FadeIn = 0, long FadeOut = 0);

    /// <summary>How a track of <paramref name="trackFrames"/> fills <paramref name="outputFrames"/> starting
    /// <paramref name="offsetFrames"/> in: trimmed when long enough, otherwise looped from the track's start with equal-power
    /// crossfades of up to <paramref name="crossfadeFrames"/> (a quarter of a short track).</summary>
    public static IReadOnlyList<LoopPiece> LoopPieces(long trackFrames, long offsetFrames, long outputFrames, long crossfadeFrames)
    {
        if (trackFrames < 4 || outputFrames <= 0 || offsetFrames < 0 || offsetFrames >= trackFrames) return [];
        var pieces = new List<LoopPiece> { new(offsetFrames, 0, Math.Min(trackFrames - offsetFrames, outputFrames)) };
        var end = pieces[0].Count;
        var crossfade = Math.Max(1, Math.Min(crossfadeFrames, trackFrames / 4));
        while (end < outputFrames)
        {
            var overlap = Math.Min(crossfade, pieces[^1].Count / 2);
            var start = end - overlap;
            var count = Math.Min(trackFrames, outputFrames - start);
            pieces[^1] = pieces[^1] with { FadeOut = overlap };
            pieces.Add(new(0, start, count, overlap));
            end = start + count;
        }
        return pieces;
    }

    /// <summary>Equal-power crossfade weight of a piece at <paramref name="index"/> frames into it.</summary>
    public static double PieceWeight(LoopPiece piece, long index)
    {
        var weight = 1.0;
        if (piece.FadeIn > 0 && index < piece.FadeIn) weight *= Math.Sin(Math.PI / 2 * (index + 0.5) / piece.FadeIn);
        var tail = piece.Count - index;
        if (piece.FadeOut > 0 && tail <= piece.FadeOut) weight *= Math.Sin(Math.PI / 2 * (tail - 0.5) / piece.FadeOut);
        return weight;
    }
}

/// <summary>The track a preview or export mixes under the voice: the project's entry for the scope and its file in the data
/// folder (<c>&lt;data&gt;/Music/&lt;projectId&gt;/music-….ext</c>), the twin of Mac MusicRenderInput.</summary>
public sealed record MusicRenderInput(ProjectMusic Entry, string AssetPath)
{
    /// <summary><c>&lt;data folder&gt;/Music</c>, holding one folder per project id.</summary>
    public static string Root(string dataRoot) => Path.Combine(dataRoot, "Music");

    /// <summary>Where <paramref name="asset"/>'s file lives.</summary>
    public static string PathFor(MusicAsset asset, string dataRoot) => Path.Combine(Root(dataRoot), asset.File.Replace('/', Path.DirectorySeparatorChar));

    /// <summary>The input for a clip's (or with null the full video's) track, or null without one.</summary>
    public static MusicRenderInput? Resolve(Project project, string? clipId, string dataRoot) =>
        MusicProject.Entry(clipId, project) is { } entry ? new(entry, PathFor(entry.Asset, dataRoot)) : null;
}

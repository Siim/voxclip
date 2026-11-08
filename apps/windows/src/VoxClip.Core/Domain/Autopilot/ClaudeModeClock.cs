using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>One stage from a video to its clips, as <c>voxclip-cli autopilot --timings</c> and the app's Claude mode log line name it.
/// Twin of the Mac <c>ClaudeModeStage</c>; <c>frames</c> and <c>opening</c> are Mac-only until Windows has a frame analyzer.</summary>
public enum ClaudeModeStage
{
    /// <summary>Reading the source's streams.</summary>
    Probe,
    /// <summary>Decoding the speech audio.</summary>
    Audio,
    /// <summary>Speech to words.</summary>
    Transcribe,
    /// <summary>Find Clips.</summary>
    Find,
    /// <summary>One clip's plan.</summary>
    Plan,
    /// <summary>One clip applied.</summary>
    Apply,
    /// <summary>One clip exported.</summary>
    Export,
    /// <summary>One clip's export self-check (ADR-R49), after its export and beside the other clips' work.</summary>
    Check
}

/// <summary>One stage's wall time: when it started and ended, in seconds from the run's start, and for a clip stage which clip (1 is
/// the best; the rank Find Clips gave it).</summary>
public sealed record ClaudeModeTiming(ClaudeModeStage Stage, int? Clip, double Start, double End)
{
    /// <summary>How long it ran.</summary>
    public double Seconds => Math.Max(0, End - Start);
}

/// <summary>The wall times of one run from a video to its clips (ai.md §16.12): numbers only, never a title, a word or a path, so they
/// can go to the log and the CLI's JSON as they are. Thread-safe; stages may overlap (clips plan at once). Twin of the Mac
/// <c>ClaudeModeClock</c>.</summary>
public sealed class ClaudeModeClock
{
    private readonly object gate = new();
    private readonly List<ClaudeModeTiming> entries = [];
    private readonly Dictionary<(ClaudeModeStage, int?), double> open = [];
    private readonly Func<double> now;

    /// <summary>A clock from now; <paramref name="now"/> (seconds since the run started) replaces the wall clock in tests.</summary>
    public ClaudeModeClock(Func<double>? now = null)
    {
        var stopwatch = Stopwatch.StartNew();
        this.now = now ?? (() => stopwatch.Elapsed.TotalSeconds);
    }

    /// <summary>Seconds since the run started.</summary>
    public double Elapsed => now();

    /// <summary>Records <paramref name="stage"/> as running from <paramref name="start"/> (an earlier <see cref="Elapsed"/>) until now.</summary>
    public void Record(ClaudeModeStage stage, int? clip, double start)
    {
        var end = Elapsed;
        lock (gate) entries.Add(new(stage, clip, start, Math.Max(start, end)));
    }

    /// <summary>Starts <paramref name="stage"/> for <paramref name="clip"/> now; <see cref="End"/> records it. A stage begun twice keeps its
    /// first start.</summary>
    public void Begin(ClaudeModeStage stage, int? clip = null)
    {
        var start = Elapsed;
        lock (gate) open.TryAdd((stage, clip), start);
    }

    /// <summary>Records <paramref name="stage"/> for <paramref name="clip"/> from its <see cref="Begin"/> until now; nothing when it was not
    /// begun or has ended.</summary>
    public void End(ClaudeModeStage stage, int? clip = null)
    {
        double start;
        lock (gate) { if (!open.Remove((stage, clip), out start)) return; }
        Record(stage, clip, start);
    }

    /// <summary>Times <paramref name="body"/> as <paramref name="stage"/>.</summary>
    public async Task<T> TimedAsync<T>(ClaudeModeStage stage, int? clip, Func<Task<T>> body)
    {
        var start = Elapsed;
        try { return await body().ConfigureAwait(false); }
        finally { Record(stage, clip, start); }
    }

    /// <summary>Every recorded stage, in the order each ended.</summary>
    public IReadOnlyList<ClaudeModeTiming> Timings { get { lock (gate) return entries.ToArray(); } }

    /// <summary>When the first clip was postable: the end of the first clip's apply, seconds from the start; null before one is.</summary>
    public double? FirstReady => Timings.Where(timing => timing.Stage == ClaudeModeStage.Apply).Select(timing => (double?)timing.End).Min();

    private double Total => Timings.Select(timing => timing.End).DefaultIfEmpty(0).Max();

    /// <summary>The wire name: "transcribe", "plan".</summary>
    public static string Name(ClaudeModeStage stage) => stage.ToString().ToLowerInvariant();

    /// <summary>The CLI's <c>timings</c> object: each stage with its clip and seconds (three decimals), the first postable clip and the
    /// whole run.</summary>
    public JsonObject Json()
    {
        static JsonNode Number(double value) => JsonValue.Create(Math.Round(value * 1000, MidpointRounding.AwayFromZero) / 1000)!;
        var stages = new JsonArray(Timings.Select(timing =>
        {
            var fields = new JsonObject { ["stage"] = Name(timing.Stage), ["seconds"] = Number(timing.Seconds), ["start"] = Number(timing.Start), ["end"] = Number(timing.End) };
            if (timing.Clip is { } clip) fields["clip"] = clip;
            return (JsonNode)fields;
        }).ToArray());
        return new JsonObject { ["stages"] = stages, ["firstClipSeconds"] = FirstReady is { } first ? Number(first) : null, ["totalSeconds"] = Number(Total) };
    }

    /// <summary>The app log's one line, numbers only: "claude-mode timings transcribe=53.1 find=41.2 plan1=61.0 apply1=1.4 … first=… total=…".</summary>
    public string LogLine()
    {
        var parts = Timings.Select(timing => Name(timing.Stage) + (timing.Clip?.ToString(CultureInfo.InvariantCulture) ?? "") + "=" + EditingFormat.ToFixed1(timing.Seconds));
        var first = FirstReady is { } ready ? "first=" + EditingFormat.ToFixed1(ready) : "first=none";
        return string.Join(" ", new[] { "claude-mode timings" }.Concat(parts).Append(first).Append("total=" + EditingFormat.ToFixed1(Total)));
    }
}

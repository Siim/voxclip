using System.Text.Json;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Services.Settings;

/// <summary>Who makes the clips of every new video (design.md §6.6, settings clips.mode): Claude runs Make top N postable
/// by itself after transcription and Find Clips (§6.7), or the creator picks. Missing means not chosen yet, and the editor
/// asks once, inline. The Mac twin is ClipsMode.swift.</summary>
public static class ClipsMode
{
    /// <summary>Settings key of the mode: claude, pick, or missing (not chosen yet).</summary>
    public const string Key = "clips.mode";
    /// <summary>Settings key of Claude mode's clips per video.</summary>
    public const string CountKey = "clips.autopilot.count";
    /// <summary>Settings key of Claude mode's spend cap per video, USD.</summary>
    public const string CapKey = "clips.autopilot.capUSD";
    /// <summary>"✦ Claude does it all".</summary>
    public const string Claude = "claude";
    /// <summary>"I'll pick".</summary>
    public const string Pick = "pick";
    /// <summary>Top 1 / 3 / 5 per video.</summary>
    public static IReadOnlyList<int> Counts { get; } = [1, 3, 5];
    /// <summary>Up to $0 / $1 / $2 / $5 per video for paid voice and generated music; $0 means none.</summary>
    public static IReadOnlyList<int> CapsUsd { get; } = [0, 1, 2, 5];
    /// <summary>Top 3 per video.</summary>
    public const int DefaultCount = 3;
    /// <summary>Up to $2 per video.</summary>
    public const int DefaultCapUsd = 2;
}

/// <summary>Claude mode's per-video choices; Mode is null until the creator chooses.</summary>
public sealed record ClipsAutopilotSettings(string? Mode = null, int Count = ClipsMode.DefaultCount, int CapUsd = ClipsMode.DefaultCapUsd)
{
    /// <summary>"✦ Claude does it all · top 3 · ≤$2" (the status bar item in Claude mode).</summary>
    public string Summary => $"✦ Claude does it all · top {Count} · ≤${CapUsd}";
}

/// <summary>Reads and writes Claude mode's three settings keys on <see cref="AppSettings"/>.</summary>
public static class ClipsModeSettings
{
    /// <summary>The mode, count and cap; a missing or invalid value reads as its default (mode: not chosen).</summary>
    public static ClipsAutopilotSettings GetClipsAutopilot(this AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var mode = settings.Values.TryGetValue(ClipsMode.Key, out var stored) && stored.ValueKind == JsonValueKind.String && stored.GetString() is ClipsMode.Claude or ClipsMode.Pick
            ? stored.GetString() : null;
        var count = settings.GetDouble(ClipsMode.CountKey) is { } c && ClipsMode.Counts.Contains((int)c) && c == Math.Floor(c) ? (int)c : ClipsMode.DefaultCount;
        var cap = settings.GetDouble(ClipsMode.CapKey) is { } u && ClipsMode.CapsUsd.Contains((int)u) && u == Math.Floor(u) ? (int)u : ClipsMode.DefaultCapUsd;
        return new ClipsAutopilotSettings(mode, count, cap);
    }

    /// <summary>A copy with the three keys set. Throws for a mode, count or cap the settings schema refuses.</summary>
    public static AppSettings WithClipsAutopilot(this AppSettings settings, ClipsAutopilotSettings value)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(value);
        if (value.Mode is not (null or ClipsMode.Claude or ClipsMode.Pick) || !ClipsMode.Counts.Contains(value.Count) || !ClipsMode.CapsUsd.Contains(value.CapUsd))
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Invalid Claude mode setting");
        var next = settings.With(ClipsMode.CountKey, Element(value.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)))
            .With(ClipsMode.CapKey, Element(value.CapUsd.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        if (value.Mode is { } mode) return next.With(ClipsMode.Key, Element("\"" + mode + "\""));
        next.Set(ClipsMode.Key, null);
        return next;
    }

    private static JsonElement Element(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }
}

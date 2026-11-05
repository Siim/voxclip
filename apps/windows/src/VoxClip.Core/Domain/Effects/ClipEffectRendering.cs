using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Effects;

/// <summary>A normalized rect, top-left origin (ai.md §18.2).</summary>
public readonly record struct ClipEffectRect(double X, double Y, double Width, double Height)
{
    /// <summary>Linear interpolation between two rects.</summary>
    public static ClipEffectRect Lerp(ClipEffectRect a, ClipEffectRect b, double t)
        => new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Width + (b.Width - a.Width) * t, a.Height + (b.Height - a.Height) * t);
}

/// <summary>One tracked rect at source time <see cref="T"/>.</summary>
public readonly record struct ClipEffectTrackSample(double T, ClipEffectRect Rect);

/// <summary>The sound a <c>sound</c> effect plays: a bundled id, or a library file under the data folder's SFX root.</summary>
public sealed record ClipEffectSound(string Source, string? Id, string? File, double DurationSeconds);

/// <summary>One effect as the renderer reads it (Mac ClipEffect, ai.md §18.2): the stored JSON entry, typed. Times are source
/// seconds. Picture kinds (blur, pixelate, arrow, circle) carry a rect of the source as filmed; frame kinds (title, lowerThird,
/// sticker, progress) a position in the exported frame.</summary>
public sealed record ClipEffect(string Id, string? ClipId, string Kind, double Start, double End)
{
    /// <summary>Overlays fade in and out over this many seconds, inside their range.</summary>
    public const double OverlayFadeSeconds = 0.12;
    /// <summary>A bleep's tone or silence ramps over this many seconds outside the word bounds.</summary>
    public const double BleepRampSeconds = 0.010;
    /// <summary>The bleep tone's frequency.</summary>
    public const double BleepToneHz = 1_000;
    /// <summary>The bleep tone's peak, −12 dBFS.</summary>
    public const double BleepToneAmplitude = 0.25;
    /// <summary>The longest sound effect.</summary>
    public const double MaximumSoundSeconds = 10;

    /// <summary>bleep, mute: the covered words.</summary>
    public IReadOnlyList<string> WordIds { get; init; } = [];
    /// <summary>Picture kinds' rect.</summary>
    public ClipEffectRect? Rect { get; init; }
    /// <summary>blur, pixelate: none, face or saliency.</summary>
    public string? Tracking { get; init; }
    /// <summary>blur, pixelate: the stored smoothed track; empty while untracked, so <see cref="Rect"/> holds.</summary>
    public IReadOnlyList<ClipEffectTrackSample> Track { get; init; } = [];
    /// <summary>title, lowerThird: the words; sticker: the emoji.</summary>
    public string? Text { get; init; }
    /// <summary>Frame kinds' position.</summary>
    public string? Position { get; init; }
    /// <summary>sticker: size relative to the default.</summary>
    public double? Scale { get; init; }
    /// <summary>sound: what plays.</summary>
    public ClipEffectSound? Sound { get; init; }
    /// <summary>sound: level in dB.</summary>
    public double? GainDb { get; init; }

    /// <summary>bleep, mute, blur and pixelate render wherever their range plays.</summary>
    public bool IsCensor => ClipEffects.IsCensor(Kind);
    /// <summary>bleep and mute.</summary>
    public bool UsesWords => Kind is "bleep" or "mute";
    /// <summary>Picture-space kinds.</summary>
    public bool UsesRect => Kind is "blur" or "pixelate" or "arrow" or "circle";
    /// <summary>Frame-space kinds.</summary>
    public bool UsesPosition => Kind is "title" or "lowerThird" or "sticker" or "progress";

    /// <summary>The typed effect of a stored entry (already validated by <see cref="ClipEffects.Validate(Project)"/>).</summary>
    public static ClipEffect Parse(JsonElement entry)
    {
        static ClipEffectRect Rect(JsonElement value) => new(value.GetProperty("x").GetDouble(), value.GetProperty("y").GetDouble(),
            value.GetProperty("width").GetDouble(), value.GetProperty("height").GetDouble());
        string? Text(string key) => entry.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        double? Number(string key) => entry.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : null;
        var clip = entry.GetProperty("clipId");
        var effect = new ClipEffect(entry.GetProperty("id").GetString()!, clip.ValueKind == JsonValueKind.String ? clip.GetString() : null,
            entry.GetProperty("kind").GetString()!, entry.GetProperty("start").GetDouble(), entry.GetProperty("end").GetDouble())
        {
            Text = Text("text"), Position = Text("position"), Tracking = Text("tracking"), Scale = Number("scale"), GainDb = Number("gainDb")
        };
        if (entry.TryGetProperty("wordIds", out var words)) effect = effect with { WordIds = words.EnumerateArray().Select(word => word.GetString()!).ToArray() };
        if (entry.TryGetProperty("rect", out var rect)) effect = effect with { Rect = Rect(rect) };
        if (entry.TryGetProperty("track", out var track))
            effect = effect with { Track = track.EnumerateArray().Select(sample => new ClipEffectTrackSample(sample.GetProperty("t").GetDouble(), Rect(sample))).ToArray() };
        if (entry.TryGetProperty("sound", out var sound))
        {
            string? Field(string key) => sound.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            effect = effect with { Sound = new(sound.GetProperty("source").GetString()!, Field("id"), Field("file"), sound.GetProperty("durationSeconds").GetDouble()) };
        }
        return effect;
    }

    /// <summary>The rect at source time <paramref name="time"/>: the static rect, or the stored track interpolated between its two
    /// nearest samples (held before the first and after the last).</summary>
    public ClipEffectRect? RectAt(double time)
    {
        if (Rect is not { } rect) return null;
        if (Track.Count == 0) return rect;
        if (time <= Track[0].T) return Track[0].Rect;
        if (time >= Track[^1].T) return Track[^1].Rect;
        int lower = 0, upper = Track.Count - 1;
        while (upper - lower > 1)
        {
            var middle = (lower + upper) / 2;
            if (Track[middle].T <= time) lower = middle; else upper = middle;
        }
        var a = Track[lower];
        var b = Track[upper];
        var span = b.T - a.T;
        return span > 0 ? ClipEffectRect.Lerp(a.Rect, b.Rect, (time - a.T) / span) : a.Rect;
    }

    /// <summary>An overlay's opacity at source time <paramref name="time"/>: 0 outside its range, ramping over
    /// <see cref="OverlayFadeSeconds"/> at each end.</summary>
    public double OpacityAt(double time)
    {
        if (time < Start || time >= End) return 0;
        var fade = Math.Min(OverlayFadeSeconds, (End - Start) / 2);
        if (fade <= 0) return 1;
        return Math.Min(1, Math.Min((time - Start) / fade, (End - time) / fade));
    }
}

/// <summary>The effects a preview or export draws and mixes (Mac ClipEffectsRenderInput, ai.md §18.5): the scope's effects and
/// the file each sound effect plays.</summary>
public sealed record ClipEffectsRenderInput(IReadOnlyList<ClipEffect> Effects, IReadOnlyDictionary<string, string> SoundPaths)
{
    /// <summary><c>&lt;data folder&gt;/SFX</c>, holding one folder per project id.</summary>
    public static string SoundRoot(string dataRoot) => Path.Combine(dataRoot, "SFX");

    /// <summary>A bundled sound's file: <c>shared/data/sfx/&lt;id&gt;.wav</c>.</summary>
    public static string BundledSoundPath(string id, string sharedRoot) => Path.Combine(sharedRoot, "data", "sfx", id + ".wav");

    /// <summary>The input for a clip's render (null: the full video's), or null when nothing renders there.</summary>
    public static ClipEffectsRenderInput? Resolve(Project project, string? clipId, string dataRoot, string sharedRoot)
    {
        var effects = ClipEffects.Rendered(project, clipId);
        if (effects.Count == 0) return null;
        var paths = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var effect in effects)
        {
            if (effect.Sound is not { } sound) continue;
            if (sound.Source == "bundled" && sound.Id is { } id) paths[effect.Id] = BundledSoundPath(id, sharedRoot);
            else if (sound.Source == "library" && sound.File is { } file)
                paths[effect.Id] = Path.Combine(SoundRoot(dataRoot), file.Replace('/', Path.DirectorySeparatorChar));
        }
        return new(effects, paths);
    }

    /// <summary>Picture effects: everything but bleeps, mutes and sounds.</summary>
    public IReadOnlyList<ClipEffect> Picture => Effects.Where(effect => effect.Kind is not ("bleep" or "mute" or "sound")).ToArray();
    /// <summary>Audio effects: bleeps, mutes and sounds.</summary>
    public IReadOnlyList<ClipEffect> Audio => Effects.Where(effect => effect.Kind is "bleep" or "mute" or "sound").ToArray();
    /// <summary>Freeze frames.</summary>
    public IReadOnlyList<ClipEffect> Freezes => Effects.Where(effect => effect.Kind == "freeze").ToArray();

    /// <summary>The same input without sound effects, for renders that read the voice alone (the edited WAV). Bleeps and mutes stay:
    /// they silence the voice itself.</summary>
    public ClipEffectsRenderInput? WithoutSounds
    {
        get
        {
            var kept = Effects.Where(effect => effect.Kind != "sound").ToArray();
            return kept.Length == 0 ? null : new(kept, new Dictionary<string, string>());
        }
    }

    /// <summary>The source time the picture shows at source time <paramref name="time"/>: a freeze's start while it holds.</summary>
    public double PictureTime(double time)
    {
        foreach (var freeze in Effects)
            if (freeze.Kind == "freeze" && time >= freeze.Start && time < freeze.End) return freeze.Start;
        return time;
    }
}

/// <summary>Render helpers for <c>clipEffects</c> (Mac ClipEffects.rendered / masked / maskingBleeps).</summary>
public static class ClipEffectsRendering
{
    /// <summary>A bleeped word as captions show it: each letter and digit becomes × (U+00D7), punctuation stays.</summary>
    public static string Masked(string text)
    {
        var builder = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
            builder.Append(Rune.IsLetterOrDigit(rune) ? "×" : rune.ToString());
        return builder.ToString();
    }

    // Foundation's CharacterSet.alphanumerics: letters, marks and numbers.
    private static bool Alphanumeric(Rune rune) => Rune.GetUnicodeCategory(rune) is
        System.Globalization.UnicodeCategory.UppercaseLetter or System.Globalization.UnicodeCategory.LowercaseLetter or
        System.Globalization.UnicodeCategory.TitlecaseLetter or System.Globalization.UnicodeCategory.ModifierLetter or
        System.Globalization.UnicodeCategory.OtherLetter or System.Globalization.UnicodeCategory.NonSpacingMark or
        System.Globalization.UnicodeCategory.SpacingCombiningMark or System.Globalization.UnicodeCategory.EnclosingMark or
        System.Globalization.UnicodeCategory.DecimalDigitNumber or System.Globalization.UnicodeCategory.LetterNumber or
        System.Globalization.UnicodeCategory.OtherNumber;

    /// <summary><paramref name="words"/> with every word a bleep or mute covers masked.</summary>
    public static IReadOnlyList<CaptionWord> MaskingBleeps(IReadOnlyList<CaptionWord> words, IReadOnlyList<ClipEffect>? effects)
    {
        if (effects is null) return words;
        var bleeped = effects.Where(effect => effect.UsesWords).SelectMany(effect => effect.WordIds).ToHashSet(StringComparer.Ordinal);
        if (bleeped.Count == 0) return words;
        return words.Select(word => bleeped.Contains(word.Id) ? word with { Text = Masked(word.Text) } : word).ToArray();
    }
}

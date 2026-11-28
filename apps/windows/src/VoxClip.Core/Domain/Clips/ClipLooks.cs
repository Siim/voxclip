using System.Text.Json;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>How far a look moves a picture, for the planner.</summary>
public enum ClipLookStrength
{
    /// <summary>light.</summary>
    Light,
    /// <summary>medium.</summary>
    Medium,
    /// <summary>strong.</summary>
    Strong
}

/// <summary>One of the looks in shared/looks/clip-looks.json (looks spec §4.1): a base <see cref="ClipLook"/> with adjustments
/// and a grade. A preset never sets the Fix. Its values are frozen once shipped; a retune ships under a new ID and the old entry
/// stays <see cref="Hidden"/>. Twin of the Mac <c>ClipLookPreset</c>.</summary>
/// <param name="Id">The ID a project's <c>colorGrade.preset</c> names.</param>
/// <param name="Label">The name the picker shows.</param>
/// <param name="Category">The category's ID.</param>
/// <param name="Strength">Planner guidance.</param>
/// <param name="Line">The one-line look, for help, Narrator and the planner prompt.</param>
/// <param name="PickWhen">When the planner picks it.</param>
/// <param name="PlannerAmount">Where the planner starts on a face; a hand pick starts at 100.</param>
/// <param name="Classic">One of the eight looks projects already used before the library.</param>
/// <param name="Hidden">Kept for old projects, left out of pickers.</param>
/// <param name="Base">The base look.</param>
/// <param name="Adjustments">Null when neutral, as <see cref="ProjectClipControls.ColorAdjustments"/> stores it.</param>
/// <param name="Grade">The look's own grade values: no Fix, no preset, full amount.</param>
public sealed record ClipLookPreset(string Id, string Label, string Category, ClipLookStrength Strength, string Line, string PickWhen,
    int PlannerAmount, bool Classic, bool Hidden, ClipLook Base, ClipColorAdjustments? Adjustments, ClipColorGrade Grade);

/// <summary>A look category: natural, bright, warm, film, cinematic, bw.</summary>
public sealed record ClipLookCategory(string Id, string Label);

/// <summary>A clip's colour state against the library (spec §8.3): a look applied as it is (<paramref name="Edited"/> false),
/// or edited from it.</summary>
public sealed record ClipLookMatch(ClipLookPreset Look, bool Edited);

/// <summary>shared/looks/clip-looks.json (<c>voxclip-clip-looks/1</c>), read whole and checked: the looks in display order,
/// their categories, and the shared light and Auto thresholds. A broken file is SharedResourcesMissing. Twin of the Mac
/// <c>ClipLookLibrary</c>.</summary>
public sealed class ClipLookLibrary
{
    /// <summary>The file, relative to the shared root.</summary>
    public const string Path = "looks/clip-looks.json";

    private ClipLookLibrary(IReadOnlyList<ClipLookCategory> categories, IReadOnlyList<ClipLookPreset> looks,
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, double>> measure)
    {
        Categories = categories;
        Looks = looks;
        Measure = measure;
    }

    /// <summary>The categories in display order.</summary>
    public IReadOnlyList<ClipLookCategory> Categories { get; }
    /// <summary>Every look in display order, hidden ones included.</summary>
    public IReadOnlyList<ClipLookPreset> Looks { get; }
    /// <summary>The <c>measure</c> groups (<c>auto</c>, <c>light</c>): name to number.</summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, double>> Measure { get; }
    /// <summary>The looks a picker offers.</summary>
    public IReadOnlyList<ClipLookPreset> Visible => Looks.Where(look => !look.Hidden).ToArray();

    /// <summary>The look with <paramref name="id"/>, hidden or not.</summary>
    public ClipLookPreset? Look(string id) => Looks.FirstOrDefault(look => look.Id == id);

    /// <summary>Reads the file under <paramref name="sharedRoot"/>.</summary>
    public static ClipLookLibrary Load(string sharedRoot)
    {
        try { return Parse(File.ReadAllText(System.IO.Path.Combine(sharedRoot, "looks", "clip-looks.json"))); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { throw Missing(exception); }
    }

    /// <summary>The label/ID rule: for every look but As filmed, the label with case and non-letters dropped is the ID with
    /// case dropped ("Teal &amp; Amber" is tealAmber), the key the planner validator compares names by.</summary>
    internal static string Key(string text) => new(text.ToLowerInvariant().Where(char.IsLetter).ToArray());

    /// <summary>Parses a clip-looks.json document.</summary>
    public static ClipLookLibrary Parse(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return Read(document.RootElement) ?? throw Missing(null);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            throw Missing(exception);
        }
    }

    private static VoxClipException Missing(Exception? inner) => new(VoxClipErrorCode.SharedResourcesMissing, "clip-looks.json", inner);

    private static ClipLookLibrary? Read(JsonElement root)
    {
        static HashSet<string> Keys(JsonElement element) => element.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
        static string? Text(JsonElement element, string key) =>
            element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text ? text : null;
        if (root.ValueKind != JsonValueKind.Object || !Keys(root).SetEquals(["format", "categories", "measure", "looks"]) ||
            Text(root, "format") != "voxclip-clip-looks/1") return null;
        var categories = new List<ClipLookCategory>();
        if (root.GetProperty("categories").ValueKind != JsonValueKind.Array) return null;
        foreach (var item in root.GetProperty("categories").EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object || !Keys(item).SetEquals(["id", "label"]) || Text(item, "id") is not { } id ||
                Text(item, "label") is not { } label || categories.Any(category => category.Id == id)) return null;
            categories.Add(new(id, label));
        }
        var measure = new Dictionary<string, IReadOnlyDictionary<string, double>>(StringComparer.Ordinal);
        var groups = root.GetProperty("measure");
        if (categories.Count == 0 || groups.ValueKind != JsonValueKind.Object || !Keys(groups).SetEquals(["auto", "light"])) return null;
        foreach (var group in groups.EnumerateObject())
        {
            if (group.Value.ValueKind != JsonValueKind.Object || !group.Value.EnumerateObject().Any()) return null;
            var numbers = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (var value in group.Value.EnumerateObject())
            {
                if (value.Value.ValueKind != JsonValueKind.Number || !value.Value.TryGetDouble(out var number) || !double.IsFinite(number)) return null;
                numbers[value.Name] = number;
            }
            measure[group.Name] = numbers;
        }
        string[] required = ["id", "label", "category", "strength", "line", "planner", "classic", "base", "adjustments", "grade"];
        var looks = new List<ClipLookPreset>();
        if (root.GetProperty("looks").ValueKind != JsonValueKind.Array) return null;
        foreach (var item in root.GetProperty("looks").EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object) return null;
            var keys = Keys(item);
            keys.Remove("hidden");
            if (!keys.SetEquals(required) || Text(item, "id") is not { } id || !ClipColorGrade.IsPresetId(id) || looks.Any(look => look.Id == id) ||
                Text(item, "label") is not { } label || (id != "original" && Key(label) != id.ToLowerInvariant()) ||
                Text(item, "category") is not { } category || categories.All(known => known.Id != category) ||
                Text(item, "strength") switch { "light" => ClipLookStrength.Light, "medium" => ClipLookStrength.Medium, "strong" => ClipLookStrength.Strong, _ => (ClipLookStrength?)null } is not { } strength ||
                Text(item, "line") is not { } line) return null;
            var planner = item.GetProperty("planner");
            if (planner.ValueKind != JsonValueKind.Object || !Keys(planner).SetEquals(["pickWhen", "amount"]) || Text(planner, "pickWhen") is not { } pickWhen ||
                planner.GetProperty("amount") is not { ValueKind: JsonValueKind.Number } amountValue || !amountValue.TryGetDecimal(out var amount) ||
                decimal.Truncate(amount) != amount || amount is < 0 or > 100) return null;
            var classic = item.GetProperty("classic");
            if (classic.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return null;
            var hidden = false;
            if (item.TryGetProperty("hidden", out var flag))
            {
                if (flag.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return null;
                hidden = flag.GetBoolean();
            }
            ClipLook? baseLook = Text(item, "base") switch { "original" => ClipLook.Original, "muted" => ClipLook.Muted, "warm" => ClipLook.Warm, "bw" => ClipLook.Bw, _ => null };
            if (baseLook is null || Adjustments(item.GetProperty("adjustments")) is not { } adjustments ||
                ClipColorGrade.Read(item.GetProperty("grade"), look: true) is not { } grade) return null;
            looks.Add(new(id, label, category, strength, line, pickWhen, (int)amount, classic.GetBoolean(), hidden, baseLook.Value,
                adjustments.IsNeutral ? null : adjustments, grade));
        }
        if (looks.Count == 0 || !looks.Any(look => look.Id == "original" && !look.Hidden)) return null;
        return new(categories, looks, measure);
    }

    /// <summary>A look's <c>adjustments</c>: today's four keys, a missing one meaning 0.</summary>
    private static ClipColorAdjustments? Adjustments(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) return null;
        var points = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (property.Name is not ("brightness" or "contrast" or "saturation" or "warmth") || points.ContainsKey(property.Name) ||
                property.Value.ValueKind != JsonValueKind.Number || !property.Value.TryGetDecimal(out var number) ||
                decimal.Truncate(number) != number || number is < -100 or > 100) return null;
            points[property.Name] = (int)number;
        }
        return new(points.GetValueOrDefault("brightness"), points.GetValueOrDefault("contrast"), points.GetValueOrDefault("saturation"),
            points.GetValueOrDefault("warmth"));
    }

    /// <summary>The tile a clip's colour state shows as applied or edited (spec §8.3). A look is applied when the clip's look,
    /// adjustments and grade equal its base, adjustments and grade, leaving out the amount, the preset and the Fix. A clip
    /// whose preset names a look with other values has that look edited; a preset this build doesn't know, or values no look
    /// has, is null ("Custom").</summary>
    public ClipLookMatch? Match(ProjectClipControls controls)
    {
        var values = controls.ColorGrade?.LookValues ?? ClipColorGrade.Neutral;
        bool Holds(ClipLookPreset look) => look.Base == controls.Look && look.Adjustments == controls.ColorAdjustments && look.Grade == values;
        if (controls.ColorGrade?.Preset is { } named)
            return Look(named) is { } look ? new(look, !Holds(look)) : null;
        return Looks.FirstOrDefault(Holds) is { } found ? new(found, false) : null;
    }

    /// <summary>"Warm Print", "Warm Print, edited" or "Custom".</summary>
    public string Name(ProjectClipControls controls) => Match(controls) switch
    {
        { Edited: false } match => match.Look.Label,
        { } match => match.Look.Label + ", edited",
        null => "Custom"
    };
}

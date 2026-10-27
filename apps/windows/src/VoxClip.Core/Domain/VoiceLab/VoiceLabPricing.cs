using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>What a price is looked up by: provider, operation, the endpoint where a provider prices endpoints separately,
/// and the unit the caller counts in; Voice Lab §3.2.</summary>
public sealed record VoiceLabPricedOperation(string Provider, string Operation, string? Endpoint, string Unit)
{
    /// <summary>ElevenLabs Scribe v2, in seconds of audio.</summary>
    public static readonly VoiceLabPricedOperation ElevenLabsSpeechToText = new("elevenlabs", "speechToText", null, "second");
    /// <summary>ElevenLabs Voice Isolator, in seconds of audio.</summary>
    public static readonly VoiceLabPricedOperation ElevenLabsAudioIsolation = new("elevenlabs", "audioIsolation", null, "second");
    /// <summary>ElevenLabs Voice Changer, in seconds of audio.</summary>
    public static readonly VoiceLabPricedOperation ElevenLabsVoiceChange = new("elevenlabs", "voiceChange", null, "second");
    /// <summary>ElevenLabs text to speech, in characters (Unicode scalars).</summary>
    public static readonly VoiceLabPricedOperation ElevenLabsTextToSpeech = new("elevenlabs", "textToSpeech", null, "character");
    /// <summary>ElevenLabs Forced Alignment, in seconds of audio.</summary>
    public static readonly VoiceLabPricedOperation ElevenLabsForcedAlignment = new("elevenlabs", "forcedAlignment", null, "second");
    /// <summary>ElevenLabs Instant Voice Clone, one call.</summary>
    public static readonly VoiceLabPricedOperation ElevenLabsCreateClone = new("elevenlabs", "createClone", null, "call");
    /// <summary>ElevenLabs voice deletion, one call; free (zero entry).</summary>
    public static readonly VoiceLabPricedOperation ElevenLabsDeleteClone = new("elevenlabs", "deleteClone", null, "call");
    /// <summary>sync.so lip sync, in seconds of video; the model is passed separately.</summary>
    public static readonly VoiceLabPricedOperation SyncsoLipsync = new("syncso", "lipsync", null, "second");
    /// <summary>fal lip sync at a fal endpoint id such as <c>fal-ai/latentsync</c>; the model is passed separately.</summary>
    public static VoiceLabPricedOperation FalLipsync(string endpoint) => new("fal", "lipsync", endpoint, "second");
}

/// <summary>A catalog formula; Voice Lab §3.2.</summary>
public enum VoiceLabPriceFormula
{
    /// <summary>Seconds times the hourly price over 3600.</summary>
    PerHour,
    /// <summary>Seconds times the per-minute price over 60.</summary>
    PerMinute,
    /// <summary>Seconds times the per-second price.</summary>
    PerSecond,
    /// <summary>Characters times candidates times the model's own list price over 1000; the discovered multiplier scales credits only.</summary>
    PerThousandCharacters,
    /// <summary>A flat price that includes some seconds, then a per-second price.</summary>
    FlatThenPerSecond,
    /// <summary>No charge.</summary>
    Zero,
    /// <summary>Priced only by the provider's estimate call (§3.3); unknown from the catalog.</summary>
    EstimateApi
}

/// <summary>One catalog entry; the parameters are decimals parsed from strings.</summary>
public sealed record VoiceLabPriceEntry(string Provider, string Operation, string? Model, string? Endpoint, string Unit,
    VoiceLabPriceFormula Formula, string Checked, string Source)
{
    internal IReadOnlyDictionary<string, decimal> Usd { get; init; } = new Dictionary<string, decimal>();
    internal IReadOnlyDictionary<string, decimal>? Credits { get; init; }
}

/// <summary><c>shared/catalog/voice-lab.json</c> (<c>voxclip-voice-lab-prices/1</c>), validated as a whole; Voice Lab §3.2.</summary>
public sealed class VoiceLabPriceCatalog
{
    /// <summary>The catalog format.</summary>
    public const string Format = "voxclip-voice-lab-prices/1";
    private static readonly HashSet<string> EntryKeys = new(StringComparer.Ordinal)
        { "provider", "operation", "model", "endpoint", "unit", "formula", "usdParameters", "creditsParameters", "checked", "source" };

    private VoiceLabPriceCatalog(IReadOnlyList<VoiceLabPriceEntry> entries) => Entries = entries;

    /// <summary>Every entry in file order.</summary>
    public IReadOnlyList<VoiceLabPriceEntry> Entries { get; }

    /// <summary>Parse and validate catalog bytes. Any defect is <c>SharedResourcesMissing</c>: a guessed price is worse than none.</summary>
    public static VoiceLabPriceCatalog Parse(ReadOnlyMemory<byte> utf8Json)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8Json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.EnumerateObject().All(property => property.Name is "schema" or "description" or "entries") ||
                !root.TryGetProperty("schema", out var schema) || schema.ValueKind != JsonValueKind.String || schema.GetString() != Format ||
                !root.TryGetProperty("entries", out var rows) || rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() == 0)
                throw Missing();
            var entries = rows.EnumerateArray().Select(Entry).ToArray();
            for (var index = 0; index < entries.Length; index++)
                for (var other = 0; other < index; other++)
                    Require(!(entries[other].Provider == entries[index].Provider && entries[other].Operation == entries[index].Operation &&
                        entries[other].Endpoint == entries[index].Endpoint &&
                        (entries[other].Model is null || entries[index].Model is null || entries[other].Model == entries[index].Model)));
            return new VoiceLabPriceCatalog(entries);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or FormatException)
        {
            throw Missing();
        }
    }

    /// <summary>The one entry that can price this request, or null when the price is unknown.</summary>
    public VoiceLabPriceEntry? Find(VoiceLabPricedOperation operation, string? model)
    {
        ArgumentNullException.ThrowIfNull(operation);
        return Entries.FirstOrDefault(entry => entry.Provider == operation.Provider && entry.Operation == operation.Operation &&
            entry.Endpoint == operation.Endpoint && (entry.Model is null || entry.Model == model));
    }

    private static VoiceLabPriceEntry Entry(JsonElement row)
    {
        Require(row.ValueKind == JsonValueKind.Object && row.EnumerateObject().All(property => EntryKeys.Contains(property.Name)));
        string Text(string key, string pattern)
        {
            Require(row.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && Matches(value.GetString()!, pattern));
            return value.GetString()!;
        }
        string? Optional(string key, string pattern) => row.TryGetProperty(key, out _) ? Text(key, pattern) : null;
        Dictionary<string, decimal>? Prices(string key)
        {
            if (!row.TryGetProperty(key, out var value)) return null;
            Require(value.ValueKind == JsonValueKind.Object);
            var prices = new Dictionary<string, decimal>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                Require(property.Value.ValueKind == JsonValueKind.String && prices.TryAdd(property.Name, 0));
                prices[property.Name] = VoiceLabMoney.Parse(property.Value.GetString()!, 9, 8) ?? throw Missing();
            }
            return prices;
        }
        Require(row.TryGetProperty("formula", out var name) && name.ValueKind == JsonValueKind.String);
        var formula = name.GetString() switch
        {
            "perHour" => VoiceLabPriceFormula.PerHour, "perMinute" => VoiceLabPriceFormula.PerMinute, "perSecond" => VoiceLabPriceFormula.PerSecond,
            "perThousandCharacters" => VoiceLabPriceFormula.PerThousandCharacters, "flatThenPerSecond" => VoiceLabPriceFormula.FlatThenPerSecond,
            "zero" => VoiceLabPriceFormula.Zero, "estimateApi" => VoiceLabPriceFormula.EstimateApi, _ => throw Missing()
        };
        var unit = Text("unit", "second|character|call");
        var usd = Prices("usdParameters") ?? throw Missing();
        var credits = Prices("creditsParameters");
        bool Keys(IReadOnlyDictionary<string, decimal>? prices, params string[] keys) => prices is not null && prices.Count == keys.Length && keys.All(prices.ContainsKey);
        Require(formula switch
        {
            VoiceLabPriceFormula.PerHour => unit == "second" && Keys(usd, "perHour") && credits is null,
            VoiceLabPriceFormula.PerMinute => unit == "second" && Keys(usd, "perMinute") && (credits is null || Keys(credits, "perMinute")),
            VoiceLabPriceFormula.PerSecond => unit == "second" && Keys(usd, "perSecond") && credits is null,
            VoiceLabPriceFormula.PerThousandCharacters => unit == "character" && Keys(usd, "perThousandCharacters") && (credits is null || Keys(credits, "perCharacter")),
            VoiceLabPriceFormula.FlatThenPerSecond => unit == "second" && Keys(usd, "flat", "includedSeconds", "perSecond") && credits is null,
            VoiceLabPriceFormula.Zero => usd.Count == 0 && credits is null,
            _ => unit == "second" && usd.Keys.All(key => key is "minPerSecond" or "maxPerSecond") && credits is null
        });
        return new VoiceLabPriceEntry(Text("provider", "[a-z0-9]+(?:-[a-z0-9]+)*"), Text("operation", "[a-z][A-Za-z0-9]{0,63}"),
            Optional("model", "[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"), Optional("endpoint", "[a-z0-9][a-z0-9._/-]{0,127}"), unit, formula,
            Text("checked", "[0-9]{4}-[0-9]{2}-[0-9]{2}"), Text("source", "https://[^\\s]+")) { Usd = usd, Credits = credits };
    }

    private static bool Matches(string value, string pattern) =>
        Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static void Require(bool condition) { if (!condition) throw new JsonException("Invalid Voice Lab price catalog."); }
    private static VoxClipException Missing() => new(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
}

/// <summary>Where a live provider price came from (§3.3).</summary>
public enum VoiceLabProviderPriceBasis
{
    /// <summary><c>provider-estimate</c>: sync.so's estimate call.</summary>
    ProviderEstimate,
    /// <summary><c>provider-pricing-api</c>: fal's pricing call.</summary>
    ProviderPricingApi
}

/// <summary>A live provider price that replaces a catalog estimate's amount.</summary>
public sealed record VoiceLabProviderPrice(decimal Usd, int? Credits, VoiceLabProviderPriceBasis Basis);

/// <summary>Pure catalog estimates; Voice Lab §3.1 and §3.2. <c>shared/fixtures/voice-lab/pricing-cases-README.md</c> pins every rule.</summary>
public static class VoiceLabPricing
{
    /// <summary><c>CANDIDATES</c> (§8.3): the most takes one estimate covers.</summary>
    public const int MaximumCandidates = 3;
    /// <summary>The largest number of units one estimate accepts.</summary>
    public const double MaximumUnits = 1_000_000;
    /// <summary>The smallest discovered credit multiplier an estimate accepts.</summary>
    public const double MinimumCharacterMultiplier = 0.01;
    /// <summary>The largest discovered credit multiplier an estimate accepts.</summary>
    public const double MaximumCharacterMultiplier = 100;
    /// <summary>The basis of an estimate whose price is unknown.</summary>
    public const string UnknownBasis = "unknown";

    /// <summary>The estimate for <paramref name="units"/> of <paramref name="operation"/>, or an unknown price (null <c>Usd</c>, basis
    /// <c>unknown</c>) when the catalog has no entry. TTS bills characters × candidates at the model's own list price. The multiplier from
    /// <c>GET /v1/models</c> <c>model_rates.character_cost_multiplier</c> (1 when absent, otherwise 0.01 to 100) scales credits only,
    /// because each catalog row already is that model's price. Other operations take one candidate and ignore the multiplier. A lip sync
    /// of zero seconds is invalid input: the caller refuses an empty window before it asks.</summary>
    public static CostEstimate Estimate(VoiceLabPricedOperation operation, string? model, double units, int candidates,
        double? characterMultiplier, VoiceLabPriceCatalog catalog)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(catalog);
        if (!double.IsFinite(units) || units is < 0 or > MaximumUnits || operation.Unit is "character" or "call" && Math.Truncate(units) != units ||
            operation.Operation == "lipsync" && units == 0 || candidates is < 1 or > MaximumCandidates || characterMultiplier is { } check && !IsCharacterMultiplier(check))
            throw Invalid();
        var amount = VoiceLabMoney.Exact(units);
        var unknown = new CostEstimate(operation.Provider, operation.Operation, units, operation.Unit, null, null, UnknownBasis);
        if (catalog.Find(operation, model) is not { } entry) return unknown;
        if (entry.Unit != operation.Unit || candidates != 1 && entry.Formula != VoiceLabPriceFormula.PerThousandCharacters) throw Invalid();
        decimal Usd(string name) => entry.Usd.TryGetValue(name, out var value) ? value : 0;
        var billed = units;
        decimal? credits = null;
        decimal value;
        switch (entry.Formula)
        {
            case VoiceLabPriceFormula.EstimateApi: return unknown;
            case VoiceLabPriceFormula.Zero: value = 0; break;
            case VoiceLabPriceFormula.PerHour: value = amount * Usd("perHour") / 3600; break;
            case VoiceLabPriceFormula.PerMinute:
                value = amount * Usd("perMinute") / 60;
                if (entry.Credits?.TryGetValue("perMinute", out var perMinute) == true) credits = amount * perMinute / 60;
                break;
            case VoiceLabPriceFormula.PerSecond: value = amount * Usd("perSecond"); break;
            case VoiceLabPriceFormula.FlatThenPerSecond: value = Usd("flat") + Math.Max(0, amount - Usd("includedSeconds")) * Usd("perSecond"); break;
            default:
                var multiplier = VoiceLabMoney.Exact(characterMultiplier ?? 1);
                var characters = amount * candidates;
                billed = units * candidates;
                value = characters * Usd("perThousandCharacters") / 1000;
                if (entry.Credits?.TryGetValue("perCharacter", out var perCharacter) == true) credits = characters * multiplier * perCharacter;
                break;
        }
        return new CostEstimate(operation.Provider, operation.Operation, billed, operation.Unit, VoiceLabMoney.RoundUsd(value),
            credits is { } whole ? (int)decimal.Ceiling(whole) : null, "list-" + entry.Checked);
    }

    /// <summary>True for a discovered credit multiplier from 0.01 to 100; anything else is invalid input, never a guess.</summary>
    public static bool IsCharacterMultiplier(double value) => value is >= MinimumCharacterMultiplier and <= MaximumCharacterMultiplier;

    /// <summary>The typed hook for the §3.3 live sources (fal pricing API, sync.so estimate API), which are not called yet: the
    /// provider's amount replaces <c>Usd</c>, <c>Credits</c> and <c>Basis</c>; the rest of the estimate stays.</summary>
    public static CostEstimate Apply(VoiceLabProviderPrice price, CostEstimate estimate)
    {
        ArgumentNullException.ThrowIfNull(price);
        ArgumentNullException.ThrowIfNull(estimate);
        if (price.Usd < 0 || price.Credits is < 0) throw Invalid();
        return estimate with
        {
            Usd = VoiceLabMoney.RoundUsd(price.Usd), Credits = price.Credits,
            Basis = price.Basis == VoiceLabProviderPriceBasis.ProviderEstimate ? "provider-estimate" : "provider-pricing-api"
        };
    }

    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
}

/// <summary>Decimal helpers shared by pricing, presentation and the ledger; never binary floating point for money.</summary>
internal static class VoiceLabMoney
{
    internal const int UsdDecimalPlaces = 10;

    /// <summary>A plain non-negative decimal string, <c>(0|[1-9][0-9]*)(\.[0-9]+)?</c>, within the digit limits; null otherwise.</summary>
    internal static decimal? Parse(string text, int wholeDigits, int fractionDigits)
    {
        var point = text.IndexOf('.', StringComparison.Ordinal);
        var whole = point < 0 ? text : text[..point];
        var fraction = point < 0 ? "" : text[(point + 1)..];
        static bool Digits(string part) => part.All(character => character is >= '0' and <= '9');
        if (whole.Length == 0 || whole.Length > wholeDigits || !Digits(whole) || whole.Length > 1 && whole[0] == '0' ||
            point >= 0 && (fraction.Length == 0 || fraction.Length > fractionDigits || !Digits(fraction))) return null;
        return decimal.Parse(text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture);
    }

    /// <summary>The shortest decimal that reads back as the same double (<c>ToString("R")</c>); Swift's <c>description</c> and Python's
    /// <c>repr</c> give the same digits, so both Cores price identical inputs identically.</summary>
    internal static decimal Exact(double value) => value == 0 ? 0 :
        decimal.Parse(value.ToString("R", CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture);

    /// <summary>Plain digits without an exponent or trailing fractional zeros: 0.30 is "0.3", 10.0 is "10".</summary>
    internal static string Canonical(decimal value)
    {
        var text = value.ToString(CultureInfo.InvariantCulture);
        if (text.Contains('.', StringComparison.Ordinal)) text = text.TrimEnd('0').TrimEnd('.');
        return text == "-0" ? "0" : text;
    }

    /// <summary>Half away from zero at 10 decimal places.</summary>
    internal static decimal RoundUsd(decimal value) => Math.Round(value, UsdDecimalPlaces, MidpointRounding.AwayFromZero);

    internal static decimal Power(int exponent)
    {
        var result = 1m;
        for (var step = 0; step < Math.Abs(exponent); step++) result = exponent > 0 ? result * 10 : result / 10;
        return result;
    }

    /// <summary>A whole amount with a comma between thousands.</summary>
    internal static string Grouped(decimal whole)
    {
        var digits = Canonical(whole);
        for (var index = digits.Length - 3; index > 0; index -= 3) digits = digits.Insert(index, ",");
        return digits;
    }
}

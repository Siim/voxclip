using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>One provider's estimated spend in one month; Voice Lab §3.1. <c>UnknownCount</c> counts actions without a known price.</summary>
public sealed record VoiceLabSpendTotal(decimal Usd, int UnknownCount);

/// <summary>The <c>voxclip-voice-lab-spend/1</c> document: estimates of actions that ran, by local month (<c>YYYY-MM</c>) and provider.</summary>
public sealed class VoiceLabSpendDocument
{
    /// <summary>The ledger format.</summary>
    public const string Format = "voxclip-voice-lab-spend/1";
    private static readonly Regex MonthKey = new("\\A[0-9]{4}-(?:0[1-9]|1[0-2])\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex ProviderKey = new("\\A[a-z0-9]+(?:-[a-z0-9]+)*\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly decimal Limit = VoiceLabMoney.Power(12);
    private readonly SortedDictionary<string, SortedDictionary<string, VoiceLabSpendTotal>> months = new(StringComparer.Ordinal);

    /// <summary>A snapshot of every month and its providers' totals.</summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, VoiceLabSpendTotal>> Months =>
        months.ToDictionary(pair => pair.Key, pair => (IReadOnlyDictionary<string, VoiceLabSpendTotal>)pair.Value, StringComparer.Ordinal);

    /// <summary>Read the exact format, or null: the ledger then moves the file aside. Invalid UTF-8, a byte-order mark and a
    /// repeated key at any level are refused; the counts and <c>TryAdd</c> below catch repeats.</summary>
    public static VoiceLabSpendDocument? Parse(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        try
        {
            var text = new UTF8Encoding(false, true).GetString(bytes);
            if (text.StartsWith('\uFEFF')) return null;
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 2 ||
                !root.TryGetProperty("schema", out var schema) || schema.ValueKind != JsonValueKind.String || schema.GetString() != Format ||
                !root.TryGetProperty("months", out var monthsElement) || monthsElement.ValueKind != JsonValueKind.Object) return null;
            var result = new VoiceLabSpendDocument();
            foreach (var month in monthsElement.EnumerateObject())
            {
                if (!MonthKey.IsMatch(month.Name) || month.Value.ValueKind != JsonValueKind.Object || result.months.ContainsKey(month.Name)) return null;
                var totals = new SortedDictionary<string, VoiceLabSpendTotal>(StringComparer.Ordinal);
                foreach (var provider in month.Value.EnumerateObject())
                {
                    var entry = provider.Value;
                    if (!ProviderKey.IsMatch(provider.Name) || entry.ValueKind != JsonValueKind.Object || entry.EnumerateObject().Count() != 2 ||
                        !entry.TryGetProperty("usd", out var usd) || usd.ValueKind != JsonValueKind.String ||
                        VoiceLabMoney.Parse(usd.GetString()!, 12, 10) is not { } spent ||
                        !entry.TryGetProperty("unknownCount", out var count) || count.ValueKind != JsonValueKind.Number ||
                        !count.TryGetInt32(out var unknown) || unknown < 0 || !totals.TryAdd(provider.Name, new(spent, unknown))) return null;
                }
                result.months.Add(month.Name, totals);
            }
            return result;
        }
        catch (Exception exception) when (exception is DecoderFallbackException or JsonException)
        {
            return null;
        }
    }

    /// <summary>The user's local calendar month of <paramref name="start"/> in <paramref name="timeZone"/>, on the Gregorian calendar.</summary>
    public static string Month(DateTimeOffset start, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        var local = TimeZoneInfo.ConvertTime(start, timeZone);
        return local.Year.ToString("0000", CultureInfo.InvariantCulture) + "-" + local.Month.ToString("00", CultureInfo.InvariantCulture);
    }

    /// <summary>The provider's total for the month, zero when nothing was recorded.</summary>
    public VoiceLabSpendTotal Total(string provider, string month) =>
        months.TryGetValue(month, out var totals) && totals.TryGetValue(provider, out var total) ? total : new(0, 0);

    /// <summary>Add one action that ran: a known amount to <c>Usd</c>, an unknown one to <c>UnknownCount</c>. Throws <c>InvalidInput</c> for a
    /// provider id the file cannot hold, a negative amount, or a total the reader would refuse.</summary>
    public void Record(CostEstimate estimate, string month)
    {
        ArgumentNullException.ThrowIfNull(estimate);
        if (!MonthKey.IsMatch(month) || !ProviderKey.IsMatch(estimate.Provider) || estimate.Usd is < 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var total = Total(estimate.Provider, month);
        total = estimate.Usd is { } usd ? total with { Usd = total.Usd + VoiceLabMoney.RoundUsd(usd) } :
            total.UnknownCount == int.MaxValue ? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput) : total with { UnknownCount = total.UnknownCount + 1 };
        if (total.Usd >= Limit) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        if (!months.TryGetValue(month, out var totals)) months.Add(month, totals = new SortedDictionary<string, VoiceLabSpendTotal>(StringComparer.Ordinal));
        totals[estimate.Provider] = total;
    }

    /// <summary>The canonical file: two-space indent, months and providers in ordinal order, <c>usd</c> before <c>unknownCount</c>, LF ends.</summary>
    public string Encode()
    {
        var text = new StringBuilder("{\n  \"schema\": \"" + Format + "\",\n");
        if (months.Count == 0) return text.Append("  \"months\": {}\n}\n").ToString();
        text.Append("  \"months\": {\n");
        var index = 0;
        foreach (var (month, totals) in months)
        {
            var comma = ++index < months.Count ? "," : "";
            if (totals.Count == 0) { text.Append("    \"").Append(month).Append("\": {}").Append(comma).Append('\n'); continue; }
            text.Append("    \"").Append(month).Append("\": {\n");
            var position = 0;
            foreach (var (provider, total) in totals)
            {
                text.Append("      \"").Append(provider).Append("\": {\n")
                    .Append("        \"usd\": \"").Append(VoiceLabMoney.Canonical(total.Usd)).Append("\",\n")
                    .Append("        \"unknownCount\": ").Append(total.UnknownCount.ToString(CultureInfo.InvariantCulture)).Append('\n')
                    .Append("      }").Append(++position < totals.Count ? "," : "").Append('\n');
            }
            text.Append("    }").Append(comma).Append('\n');
        }
        return text.Append("  }\n}\n").ToString();
    }
}

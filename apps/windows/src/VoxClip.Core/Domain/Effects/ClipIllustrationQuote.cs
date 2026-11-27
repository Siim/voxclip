using System.Globalization;
using System.Text.Json;

namespace VoxClip.Core.Domain.Effects;

/// <summary>The shared, fixed-shape illustration quote.</summary>
public sealed record ClipIllustrationQuote(Uri Endpoint, int Size, decimal UsdPerImage)
{
    /// <summary>The USD quote label presented by the agent tools.</summary>
    public string Price => "$" + UsdPerImage.ToString(CultureInfo.InvariantCulture);

    /// <summary>Load the quote shipped with both apps.</summary>
    public static ClipIllustrationQuote Load(string sharedRoot)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(sharedRoot, "data", "clip-illustration.json")));
        var fields = document.RootElement;
        var quote = new ClipIllustrationQuote(new Uri(fields.GetProperty("endpoint").GetString()!),
            fields.GetProperty("size").GetInt32(), fields.GetProperty("usdPerImage").GetDecimal());
        if (quote is not { Size: 768, UsdPerImage: > 0 and <= 0.01m } || quote.Endpoint?.AbsoluteUri != "https://fal.run/fal-ai/flux/schnell")
            throw new InvalidDataException("Illustration pricing isn't available.");
        return quote;
    }
}

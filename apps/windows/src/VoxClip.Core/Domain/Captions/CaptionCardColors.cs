namespace VoxClip.Core.Domain.Captions;

/// <summary>Pure sidebar card colour rules; design §5.4.3.</summary>
public static class CaptionCardColors
{
    /// <summary>Keep a box colour at 4.5:1 contrast, otherwise mix it once 45% toward white in sRGB, half-up.</summary>
    public static (byte R, byte G, byte B) SidebarKeyText((byte R, byte G, byte B) box, (byte R, byte G, byte B) background)
    {
        if (CaptionContrast.Ratio(box, background) >= 4.5) return box;
        static byte Mix(byte channel) => (byte)((channel * 55 + 255 * 45 + 50) / 100);
        return (Mix(box.R), Mix(box.G), Mix(box.B));
    }
}

internal static class CaptionContrast
{
    internal static double Ratio((byte R, byte G, byte B) foreground, (byte R, byte G, byte B) background)
    {
        static double Linear(byte channel)
        {
            var value = channel / 255.0;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }
        static double Luminance((byte R, byte G, byte B) color) =>
            0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) + 0.0722 * Linear(color.B);
        var front = Luminance(foreground);
        var back = Luminance(background);
        return (Math.Max(front, back) + 0.05) / (Math.Min(front, back) + 0.05);
    }

    internal static CaptionPaint Text(CaptionPaint paint, string box, CaptionStyle style)
    {
        if (paint is not SolidPaint text) return paint;
        static (byte R, byte G, byte B) Rgb(CaptionColor color) => (color.R, color.G, color.B);
        var background = Rgb(CaptionColor.Parse(box, style));
        if (Ratio(Rgb(CaptionColor.Parse(text.Color, style)), background) >= 4.5) return paint;
        return new SolidPaint(Ratio((0, 0, 0), background) >= Ratio((255, 255, 255), background) ? "#000000" : "#FFFFFF");
    }

    internal static CaptionStyle Resolve(CaptionStyle original)
    {
        CaptionPaint Adjusted(CaptionPaint paint, string? box) => box is null ? paint : Text(paint, box, original);
        var fill = Adjusted(original.Fill, original.Box?.Color);
        CaptionWordState? State(CaptionWordState? appearance)
        {
            if (appearance is null) return null;
            var paint = appearance.Fill ?? original.Fill;
            var resolved = Adjusted(paint, appearance.Box?.Color ?? original.Box?.Color);
            return appearance.Fill is not null || resolved != fill ? appearance with { Fill = resolved } : appearance;
        }
        return original with
        {
            Fill = fill,
            Words = original.Words is { } words ? words with { Past = State(words.Past), Active = State(words.Active), Future = State(words.Future) } : null
        };
    }
}

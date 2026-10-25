using System.Text.Json;

namespace VoxClip.App.Services;

internal sealed record StartupCheck(string Status, string Screen, bool RootLoaded, bool Rendered, int PixelWidth, int PixelHeight)
{
    internal long WindowHandle { get; init; }
    internal double RasterizationScale { get; init; }
    internal static bool HasContent(ReadOnlySpan<byte> pixels)
    {
        if (pixels.Length < 16 || pixels.Length % 4 != 0) return false;
        var visible = 0;
        var different = 0;
        var first = -1;
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            if (pixels[offset + 3] < 16) continue;
            if (first < 0) first = offset;
            visible++;
            if (Math.Abs(pixels[offset] - pixels[first]) + Math.Abs(pixels[offset + 1] - pixels[first + 1]) + Math.Abs(pixels[offset + 2] - pixels[first + 2]) > 24) different++;
        }
        return visible > 0 && different >= Math.Max(4, pixels.Length / 4 / 1000);
    }

    internal void Save(string path)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteNumber("processId", Environment.ProcessId);
            writer.WriteString("status", Status);
            writer.WriteString("screen", Screen);
            writer.WriteBoolean("rootLoaded", RootLoaded);
            writer.WriteBoolean("rendered", Rendered);
            writer.WriteNumber("pixelWidth", PixelWidth);
            writer.WriteNumber("pixelHeight", PixelHeight);
            writer.WriteNumber("windowHandle", WindowHandle);
            writer.WriteNumber("rasterizationScale", RasterizationScale);
            writer.WriteEndObject();
        }
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, stream.ToArray());
        File.Move(temporary, path, true);
    }
}

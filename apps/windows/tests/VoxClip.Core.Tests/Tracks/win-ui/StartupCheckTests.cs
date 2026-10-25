#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class StartupCheckTests
{
    [Fact]
    public void EmptyTransparentAndUniformFramesFail()
    {
        Assert.False(StartupCheck.HasContent([]));
        Assert.False(StartupCheck.HasContent(new byte[400]));
        Assert.False(StartupCheck.HasContent(Enumerable.Repeat((byte)255, 400).ToArray()));
        Assert.False(StartupCheck.HasContent([255, 255, 255]));
    }

    [Fact]
    public void TransparentBorderDoesNotCountAsRenderedContent()
    {
        var pixels = new byte[400];
        Array.Fill(pixels, (byte)255, 40, 360);
        Assert.False(StartupCheck.HasContent(pixels));
    }

    [Fact]
    public void ContrastingContentPasses()
    {
        var pixels = Enumerable.Repeat((byte)255, 400).ToArray();
        for (var offset = 80; offset < 120; offset += 4) { pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0; }
        Assert.True(StartupCheck.HasContent(pixels));
    }

    [Fact]
    public void ProbeReportIncludesOnlyReadinessMetadata()
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-startup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "check.json");
            new StartupCheck("starting", "home", false, false, 0, 0).Save(path);
            new StartupCheck("ready", "editor", true, true, 640, 400) { WindowHandle = 0x100000001, RasterizationScale = 1.5 }.Save(path);
            using var report = JsonDocument.Parse(File.ReadAllText(path));
            Assert.Equal(Environment.ProcessId, report.RootElement.GetProperty("processId").GetInt32());
            Assert.Equal("ready", report.RootElement.GetProperty("status").GetString());
            Assert.True(report.RootElement.GetProperty("rootLoaded").GetBoolean());
            Assert.True(report.RootElement.GetProperty("rendered").GetBoolean());
            Assert.Equal(0x100000001, report.RootElement.GetProperty("windowHandle").GetInt64());
            Assert.Equal(1.5, report.RootElement.GetProperty("rasterizationScale").GetDouble());
            Assert.Single(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }
}
#endif

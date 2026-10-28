using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCaptions;

public sealed class CaptionBoxTextTests
{
    [Fact]
    public void EveryBoxTextColorVector()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/box-text-colors.json");
        Assert.Equal("voxclip-caption-box-text-colors/1", fixture.RootElement.GetProperty("fixture").GetString());
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var cases = fixture.RootElement.GetProperty("cases");
        Assert.Equal(54, cases.GetArrayLength());
        static byte[] Channels(JsonElement value) => value.EnumerateArray().Select(channel => channel.GetByte()).ToArray();
        static (byte R, byte G, byte B) Rgb(byte[] channels) => (channels[0], channels[1], channels[2]);
        foreach (var item in cases.EnumerateArray())
        {
            var id = item.GetProperty("id").GetString();
            var style = library.Find(item.GetProperty("style").GetString()!)!;
            var settings = new ProjectCaptions(style.Id, item.GetProperty("overrides"), null, new Dictionary<string, CaptionPosition>());
            var request = new CaptionLayoutRequest(style, settings, new PixelSize(1080, 1920), [], "en", 0);
            var resolved = CaptionStyleResolver.Resolve(request, resources.Data);
            var appearance = CaptionTimeline.State(resolved, item.GetProperty("state").GetString()!);
            var paint = Assert.IsType<SolidPaint>(appearance?.Fill ?? resolved.Fill);
            var color = CaptionMath.ParseColor(paint.Color, resolved);
            var actual = new[] { color.R, color.G, color.B, color.A };
            var box = Channels(item.GetProperty("box"));
            var actualBox = CaptionMath.ParseColor(appearance?.Box?.Color ?? resolved.Box!.Color, resolved);
            Assert.True(new[] { actualBox.R, actualBox.G, actualBox.B, actualBox.A }.SequenceEqual(box), id);
            var text = Channels(item.GetProperty("text"));
            Assert.True(actual.SequenceEqual(Channels(item.GetProperty("expected"))), id);
            Assert.True(Math.Abs(CaptionContrast.Ratio(Rgb(text), Rgb(box)) - item.GetProperty("contrast").GetDouble()) < 1e-12, id);
            Assert.True(CaptionContrast.Ratio(Rgb(actual), Rgb(box)) >= 4.5, id);
            if (style.Id == "box-highlight") Assert.True(resolved.Words?.Active?.HideStroke);
        }
    }

    [Fact]
    public void NonBoxedTextColorsStayUnchanged()
    {
        var style = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot).Find("active-pop")!;
        Assert.Equal(style, CaptionContrast.Resolve(style));
    }
}

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
        Assert.Equal("voxclip-caption-box-text-colors/2", fixture.RootElement.GetProperty("fixture").GetString());
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var cases = fixture.RootElement.GetProperty("cases");
        Assert.Equal(74, cases.GetArrayLength());
        static byte[] Channels(JsonElement value) => value.EnumerateArray().Select(channel => channel.GetByte()).ToArray();
        static (byte R, byte G, byte B) Rgb(byte[] channels) => (channels[0], channels[1], channels[2]);
        static string[] Tokens(CaptionPaint paint) => paint switch
        {
            SolidPaint solid => [solid.Color],
            LinearPaint linear => linear.Stops.Select(stop => stop.Color).ToArray(),
            _ => throw new InvalidDataException("Unknown paint.")
        };
        static string[] ExpectedTokens(JsonElement paint) => paint.GetProperty("type").GetString() == "solid"
            ? [paint.GetProperty("color").GetString()!]
            : paint.GetProperty("stops").EnumerateArray().Select(stop => stop.GetProperty("color").GetString()!).ToArray();
        static void CheckPaint(JsonElement expected, CaptionPaint actual, CaptionStyle style)
        {
            if (expected.GetProperty("type").GetString() == "solid") Assert.IsType<SolidPaint>(actual);
            else
            {
                var linear = Assert.IsType<LinearPaint>(actual);
                Assert.Equal(expected.GetProperty("angleDeg").GetDouble(), linear.AngleDeg);
                Assert.Equal(expected.GetProperty("space").GetString(), linear.Space.ToString().ToLowerInvariant());
                Assert.Equal(expected.GetProperty("stops").EnumerateArray().Select(stop => stop.GetProperty("offset").GetDouble()), linear.Stops.Select(stop => stop.Offset));
            }
            Assert.Equal(ExpectedTokens(expected).Select(token => CaptionMath.ParseColor(token, style)), Tokens(actual).Select(token => CaptionMath.ParseColor(token, style)));
        }
        foreach (var item in cases.EnumerateArray())
        {
            var id = item.GetProperty("id").GetString();
            var style = library.Find(item.GetProperty("style").GetString()!)!;
            var settings = new ProjectCaptions(style.Id, item.GetProperty("overrides"), null, new Dictionary<string, CaptionPosition>());
            var request = new CaptionLayoutRequest(style, settings, new PixelSize(1080, 1920), [], "en", 0);
            var resolved = CaptionStyleResolver.Resolve(request, resources.Data);
            var boxState = item.GetProperty("boxState").GetString()!;
            var emphasised = item.GetProperty("emphasised").GetBoolean() ? new CaptionEmphasisedWord(0, item.GetProperty("palette").GetString()) : null;
            var actual = CaptionTimeline.Paint(resolved, item.GetProperty("state").GetString()!, emphasised, boxState);
            CheckPaint(item.GetProperty("expected"), actual.Paint, resolved);
            Assert.Equal(item.GetProperty("source").GetString(), actual.Source);
            Assert.Equal(item.GetProperty("replaced").GetBoolean(), actual.BoxContrast);
            var boxToken = CaptionTimeline.State(resolved, boxState)?.Box?.Color ?? resolved.Box?.Color;
            var contrasts = item.GetProperty("contrasts").EnumerateArray().Select(value => value.GetDouble()).ToArray();
            if (item.GetProperty("box").ValueKind == JsonValueKind.Null)
            {
                Assert.Null(boxToken);
                Assert.Empty(contrasts);
                Assert.False(actual.BoxContrast);
                CheckPaint(item.GetProperty("paint"), actual.Paint, resolved);
            }
            else
            {
                var box = Channels(item.GetProperty("box"));
                var actualBox = CaptionMath.ParseColor(boxToken!, resolved);
                Assert.True(new[] { actualBox.R, actualBox.G, actualBox.B, actualBox.A }.SequenceEqual(box), id);
                var original = ExpectedTokens(item.GetProperty("paint"));
                Assert.Equal(original.Length, contrasts.Length);
                foreach (var (token, expected) in original.Zip(contrasts))
                {
                    var foreground = CaptionMath.ParseColor(token, resolved);
                    Assert.True(Math.Abs(CaptionContrast.Ratio((foreground.R, foreground.G, foreground.B), Rgb(box)) - expected) < 1e-12, id);
                }
                foreach (var token in Tokens(actual.Paint))
                {
                    var foreground = CaptionMath.ParseColor(token, resolved);
                    Assert.True(CaptionContrast.Ratio((foreground.R, foreground.G, foreground.B), Rgb(box)) >= 4.5, id);
                }
            }
            if (style.Id == "box-highlight") Assert.True(resolved.Words?.Active?.HideStroke);
        }
    }

    [Fact]
    public void NonBoxedTextColorsStayUnchanged()
    {
        var style = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot).Find("active-pop")!;
        foreach (var state in new[] { "past", "active", "future" })
        {
            var actual = CaptionTimeline.Paint(style, state, null);
            Assert.Equal(CaptionTimeline.State(style, state)?.Fill ?? style.Fill, actual.Paint);
            Assert.False(actual.BoxContrast);
        }
    }
}

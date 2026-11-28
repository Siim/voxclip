using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>shared/looks/clip-looks.json and its loader (looks spec §4), as the Swift ClipLookLibraryTests check them.</summary>
public sealed class ClipLookLibraryTests
{
    internal static ClipLookLibrary Library() => ClipLookLibrary.Load(FixtureLoader.SharedRoot);

    private static string Changed(string id, string key, string? json)
    {
        var root = JsonNode.Parse(FixtureLoader.ReadText(ClipLookLibrary.Path))!.AsObject();
        var look = root["looks"]!.AsArray().First(item => item!["id"]!.GetValue<string>() == id)!.AsObject();
        if (json is null) look.Remove(key);
        else look[key] = JsonNode.Parse(json);
        return root.ToJsonString();
    }

    [Fact]
    public void TheFileHoldsTwentyFourLooksInSixCategories()
    {
        var library = Library();
        Assert.Equal(["natural", "bright", "warm", "film", "cinematic", "bw"], library.Categories.Select(category => category.Id));
        Assert.Equal(["Natural", "Bright", "Warm", "Film", "Cinematic", "B&W"], library.Categories.Select(category => category.Label));
        Assert.Equal(["original", "muted", "naturalBoost", "softSkin", "evenLight", "studioClean", "softLight", "brightAiry", "cleanPop", "boldPop",
            "warm", "goldenHour", "peachTone", "vintageFade", "coolFilm", "warmPrint", "matteFilm", "throwback", "tealAmber", "cinematicSoft",
            "moody", "bw", "softBW", "sepia"], library.Looks.Select(look => look.Id));
        Assert.Equal(24, library.Visible.Count);
        Assert.Equal(new Dictionary<string, int> { ["natural"] = 6, ["bright"] = 4, ["warm"] = 3, ["film"] = 5, ["cinematic"] = 3, ["bw"] = 3 },
            library.Looks.GroupBy(look => look.Category).ToDictionary(group => group.Key, group => group.Count()));
        foreach (var look in library.Looks)
        {
            Assert.True(look.Line.Length > 0 && look.PickWhen.Length > 0 && look.PlannerAmount is >= 0 and <= 100, look.Id);
            Assert.True(look.Grade.Fix.IsNeutral && look.Grade.Amount == 100 && look.Grade.Preset is null, look.Id);
        }
        var warmPrint = library.Look("warmPrint")!;
        Assert.Equal(("Warm Print", "film", ClipLookStrength.Medium, 85, ClipLook.Original, false, false),
            (warmPrint.Label, warmPrint.Category, warmPrint.Strength, warmPrint.PlannerAmount, warmPrint.Base, warmPrint.Classic, warmPrint.Hidden));
        Assert.Equal(new ClipColorAdjustments(0, 0, -10, 26), warmPrint.Adjustments);
        Assert.Equal(new ClipColorGrade
        {
            Highlights = -12, Fade = 20, Grain = 20, Curve = new(new ClipCurveChannel(0, 245, 500, 760, 965)),
            SplitTone = new(200, 10, 38, 30, 0)
        }, warmPrint.Grade);
        Assert.Equal(new ClipSplitTone(30, 60, 40, 40, 0), library.Look("sepia")!.Grade.SplitTone);
        Assert.Equal((40.0, 8, 0.3), (library.Measure.Auto.BalanceLimit, library.Measure.Auto.Frames, library.Measure.Light.DimFaceLuma));
    }

    /// <summary>The measure block holds exactly the numbers Auto and the light notes read.</summary>
    [Theory]
    [InlineData("auto", "faceTarget", null)]
    [InlineData("auto", "faceTargets", "0.5")]
    [InlineData("light", "lowColour", "0.1")]
    [InlineData("auto", "frames", "2.5")]
    [InlineData("auto", "frames", "0")]
    [InlineData("light", "warmCool", "\"0.04\"")]
    public void ABrokenMeasureBlockIsRefused(string group, string key, string? json)
    {
        var root = JsonNode.Parse(FixtureLoader.ReadText(ClipLookLibrary.Path))!.AsObject();
        var numbers = root["measure"]![group]!.AsObject();
        if (json is null) numbers.Remove(key);
        else numbers[key] = JsonNode.Parse(json);
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => ClipLookLibrary.Parse(root.ToJsonString())).Code);
    }

    /// <summary>Today's eight looks keep their IDs, labels and values; the four Mac presets reach Windows through the file.</summary>
    [Fact]
    public void TodaysEightLooksAreTheClassicOnesUnchanged()
    {
        var library = Library();
        var classic = library.Looks.Where(look => look.Classic).ToArray();
        Assert.Equal(["bw", "cleanPop", "coolFilm", "muted", "original", "softLight", "vintageFade", "warm"], classic.Select(look => look.Id).Order(StringComparer.Ordinal));
        Assert.All(classic, look => Assert.Equal(ClipColorGrade.Neutral, look.Grade));
        foreach (var (id, look, label) in new[] { ("original", ClipLook.Original, "As filmed"), ("muted", ClipLook.Muted, "Muted"), ("warm", ClipLook.Warm, "Warm"), ("bw", ClipLook.Bw, "B&W") })
            Assert.Equal((look, (ClipColorAdjustments?)null, label), (library.Look(id)!.Base, library.Look(id)!.Adjustments, library.Look(id)!.Label));
        Assert.Equal(new ClipColorAdjustments(8, 22, 18, 0), library.Look("cleanPop")!.Adjustments);
        Assert.Equal(new ClipColorAdjustments(26, -16, -8, 0), library.Look("softLight")!.Adjustments);
        Assert.Equal(new ClipColorAdjustments(0, 23, -22, -30), library.Look("coolFilm")!.Adjustments);
        Assert.Equal(new ClipColorAdjustments(8, -36, -32, 30), library.Look("vintageFade")!.Adjustments);
        Assert.Equal(["Clean Pop", "Cool Film", "Soft Light", "Vintage Fade"],
            classic.Where(look => look.Adjustments is not null).Select(look => look.Label).Order(StringComparer.Ordinal));
    }

    /// <summary>A shipped look never changes (shared/fixtures/looks/frozen-looks.json is the last release's looks).</summary>
    [Fact]
    public void ShippedLooksAreFrozen()
    {
        var library = Library();
        var frozen = JsonNode.Parse(FixtureLoader.ReadText("fixtures/looks/frozen-looks.json"))!;
        Assert.Equal("voxclip-frozen-looks/1", frozen["format"]!.GetValue<string>());
        var shipped = JsonNode.Parse(FixtureLoader.ReadText(ClipLookLibrary.Path))!["looks"]!.AsArray();
        Assert.NotEmpty(frozen["looks"]!.AsArray());
        foreach (var entry in frozen["looks"]!.AsArray())
        {
            var id = entry!["id"]!.GetValue<string>();
            var current = shipped.FirstOrDefault(item => item!["id"]!.GetValue<string>() == id);
            Assert.True(current is not null, id + " was removed");
            foreach (var key in new[] { "label", "base", "adjustments", "grade" })
                Assert.True(JsonNode.DeepEquals(entry[key], current![key]), $"{id}.{key} changed");
            Assert.NotNull(library.Look(id));
        }
    }

    [Fact]
    public void IdsFollowTheLabels()
    {
        foreach (var look in Library().Looks.Where(look => look.Id != "original"))
            Assert.Equal(look.Id.ToLowerInvariant(), new string(look.Label.ToLowerInvariant().Where(char.IsLetter).ToArray()));
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => ClipLookLibrary.Parse(Changed("warmPrint", "label", "\"Warm Prints\""))).Code);
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => ClipLookLibrary.Parse(Changed("tealAmber", "label", "\"Teal and Amber\""))).Code);
    }

    /// <summary>Presets never set the Fix, and every field is checked as strictly as a project's colorGrade.</summary>
    [Theory]
    [InlineData("goldenHour", "grade", """{"highlights":-20,"temperature":10}""")]
    [InlineData("goldenHour", "grade", """{"exposure":5}""")]
    [InlineData("goldenHour", "grade", """{"tint":-3}""")]
    [InlineData("goldenHour", "grade", """{"amount":80}""")]
    [InlineData("goldenHour", "grade", """{"preset":"goldenHour"}""")]
    [InlineData("goldenHour", "grade", """{"glow":10}""")]
    [InlineData("goldenHour", "grade", """{"vibrance":101}""")]
    [InlineData("goldenHour", "grade", """{"fade":-1}""")]
    [InlineData("goldenHour", "grade", """{"grain":10.5}""")]
    [InlineData("warmPrint", "grade", """{"curve":{"master":[0,500,400,760,965]}}""")]
    [InlineData("warmPrint", "grade", """{"curve":{}}""")]
    [InlineData("warmPrint", "grade", """{"splitTone":{"shadowHue":360,"shadowSaturation":10,"highlightHue":38,"highlightSaturation":30,"balance":0}}""")]
    [InlineData("warmPrint", "adjustments", """{"warmth":101}""")]
    [InlineData("warmPrint", "adjustments", """{"gamma":1}""")]
    [InlineData("warmPrint", "base", "\"sepia\"")]
    [InlineData("warmPrint", "category", "\"vintage\"")]
    [InlineData("warmPrint", "strength", "\"bold\"")]
    [InlineData("warmPrint", "planner", """{"pickWhen":"x","amount":101}""")]
    [InlineData("warmPrint", "planner", """{"amount":85}""")]
    [InlineData("warmPrint", "line", "\"\"")]
    [InlineData("warmPrint", "classic", "\"no\"")]
    [InlineData("warmPrint", "hidden", "\"yes\"")]
    [InlineData("warmPrint", "id", "\"muted\"")]
    [InlineData("warmPrint", "id", "\"warm-print\"")]
    [InlineData("warmPrint", "unexpected", "true")]
    public void ABrokenLookIsRefused(string id, string key, string json) =>
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => ClipLookLibrary.Parse(Changed(id, key, json))).Code);

    [Fact]
    public void AHiddenLookStaysKnownButLeavesTheVisibleList()
    {
        var library = ClipLookLibrary.Parse(Changed("throwback", "hidden", "true"));
        Assert.True(library.Look("throwback")!.Hidden);
        Assert.DoesNotContain(library.Visible, look => look.Id == "throwback");
        Assert.Equal(23, library.Visible.Count);
    }
}

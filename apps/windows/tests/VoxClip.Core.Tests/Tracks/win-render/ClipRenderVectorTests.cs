using System.Text.Json;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>The Core half of Windows clip rendering (design §6.8–6.9, ai.md §18.5): the Mac's timing, level, look, box and frame
/// decisions, replayed from shared/fixtures/clip-render/clip-render-cases.json.</summary>
public sealed class ClipRenderVectorTests
{
    private static JsonElement Cases() => FixtureLoader.ReadJson("fixtures/clip-render/clip-render-cases.json").RootElement.Clone();

    private static ProjectClipControls Controls(double speed = 1, ClipShape? shape = null, ClipLook look = ClipLook.Original, double gain = 0,
        double fadeIn = 0, double fadeOut = 0, bool mute = false, bool flip = false, int rotation = 0)
        => new("c", speed, shape, look, gain, fadeIn, fadeOut, mute, flip, rotation);

    private static ClipShape? Shape(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetString() switch
    {
        "16:9" => ClipShape.Landscape, "9:16" => ClipShape.Portrait, "1:1" => ClipShape.Square, _ => ClipShape.PortraitFourFive
    };

    private static ExportAspect Aspect(string value) => value switch
    {
        "16:9" => ExportAspect.Landscape, "9:16" => ExportAspect.Portrait, "1:1" => ExportAspect.Square, _ => ExportAspect.Source
    };

    [Fact]
    public void TheFileHasItsOwnSchemaAndEveryCategory()
    {
        var cases = Cases();
        Assert.Equal("voxclip-clip-render-cases/1", cases.GetProperty("schema").GetString());
        Assert.Equal(["schema", "description", "looks", "orient", "mapRect", "frames", "bitrates", "speed", "effectsAtSpeed", "srt", "mask"],
            cases.EnumerateObject().Select(property => property.Name));
    }

    [Fact]
    public void RenderedLengthsDivideTheEditedLengthBySpeed()
    {
        foreach (var item in Cases().GetProperty("speed").EnumerateArray())
        {
            var timing = new ClipSpeedTiming(item.GetProperty("speed").GetDouble());
            var rendered = timing.RenderedSamples(item.GetProperty("editedSamples").GetInt64());
            Assert.Equal(item.GetProperty("renderedSamples").GetInt64(), rendered);
            var seconds = rendered / item.GetProperty("rate").GetDouble();
            Assert.Equal(item.GetProperty("frames").GetInt64(), (long)Math.Round(seconds * item.GetProperty("fps").GetDouble(), MidpointRounding.AwayFromZero));
        }
        var fast = new ClipSpeedTiming(1.25);
        Assert.Equal(0.4, fast.Rendered(0.5), 12);
        Assert.Equal(1.0, fast.Edited(0.8), 12);
        Assert.Equal(1, new ClipSpeedTiming(double.NaN).Speed);
        Assert.Equal(1, new ClipSpeedTiming(-2).Speed);
        Assert.Equal(96_000, new ClipSpeedTiming(1).RenderedSamples(96_000));
    }

    [Fact]
    public void VolumeFadesAndMuteSetTheVoiceLevelOnTheRenderedClock()
    {
        Assert.Equal(1, ClipAudioMix.LinearGain(Controls(speed: 1.25)));
        Assert.Equal(0.501187, ClipAudioMix.LinearGain(Controls(gain: -6)), 5);
        Assert.Equal(0, ClipAudioMix.LinearGain(Controls(gain: 6, mute: true)));
        var faded = Controls(fadeIn: 0.5, fadeOut: 1);
        Assert.Equal(0, ClipAudioMix.Gain(0, 4, faded));
        Assert.Equal(0.5, ClipAudioMix.Gain(0.25, 4, faded), 12);
        Assert.Equal(1, ClipAudioMix.Gain(2, 4, faded));
        Assert.Equal(0.25, ClipAudioMix.Gain(3.75, 4, faded), 12);
        Assert.Equal(0, ClipAudioMix.Gain(4.5, 4, faded));
        Assert.True(Controls(speed: 1.1).ChangesAudio() && Controls(mute: true).ChangesAudio() && !Controls(look: ClipLook.Warm).ChangesAudio());
        Assert.True(Controls(look: ClipLook.Bw).ChangesPicture() && Controls(rotation: 90).ChangesPicture() && !Controls(gain: 3).ChangesPicture());
    }

    [Fact]
    public void LookRecipesMatchTheMacGoldensOnTheSyntheticFrame()
    {
        var looks = Cases().GetProperty("looks");
        var tolerance = looks.GetProperty("tolerance").GetInt32();
        var swatches = looks.GetProperty("swatches").EnumerateArray().Select(swatch => swatch.EnumerateArray().Select(value => value.GetDouble()).ToArray()).ToArray();
        Assert.True(new ClipLookRecipe(ClipLook.Original).IsIdentity);
        foreach (var (look, name) in new[] { (ClipLook.Muted, "muted"), (ClipLook.Warm, "warm"), (ClipLook.Bw, "bw") })
        {
            var recipe = new ClipLookRecipe(look);
            Assert.False(recipe.IsIdentity);
            var goldens = looks.GetProperty("macGoldens").GetProperty(name).EnumerateArray().ToArray();
            var arithmetic = looks.GetProperty("recipe").GetProperty(name).EnumerateArray().ToArray();
            for (var index = 0; index < swatches.Length; index++)
            {
                // From the 8-bit swatch, as a decoded frame stores it.
                var stored = swatches[index].Select(value => Math.Floor(value * 255 + 0.5) / 255).ToArray();
                var result = recipe.Apply(stored).Select(value => (int)Math.Floor(value * 255 + 0.5)).ToArray();
                var golden = goldens[index].EnumerateArray().Select(value => value.GetInt32()).ToArray();
                Assert.True(result.Zip(golden).All(pair => Math.Abs(pair.First - pair.Second) <= tolerance), $"{name}[{index}]: {string.Join(",", result)} vs Mac {string.Join(",", golden)}");
                Assert.Equal(arithmetic[index].EnumerateArray().Select(value => value.GetInt32()), result);
            }
        }
    }

    [Fact]
    public void EffectBoxesAndAnchorsFollowTheFlipAndQuarterTurns()
    {
        foreach (var item in Cases().GetProperty("mapRect").EnumerateArray())
        {
            var controls = Controls(flip: item.GetProperty("flip").GetBoolean(), rotation: item.GetProperty("rotation").GetInt32());
            static ClipEffectRect Rect(JsonElement value) => new(value.GetProperty("x").GetDouble(), value.GetProperty("y").GetDouble(),
                value.GetProperty("width").GetDouble(), value.GetProperty("height").GetDouble());
            var mapped = controls.MapRect(Rect(item.GetProperty("rect")));
            var expected = Rect(item.GetProperty("expected"));
            Assert.Equal(expected.X, mapped.X, 9); Assert.Equal(expected.Y, mapped.Y, 9);
            Assert.Equal(expected.Width, mapped.Width, 9); Assert.Equal(expected.Height, mapped.Height, 9);
        }
        var rect = new ClipEffectRect(0.1, 0.2, 0.3, 0.4);
        Assert.Equal(rect, ((ProjectClipControls?)null).MapRect(rect));
        Assert.Equal(rect, Controls(look: ClipLook.Warm).MapRect(rect));
        Assert.Equal((1.0, 0.0), Controls(rotation: 90).MapAnchor(0, 0));
        Assert.Equal((0.8, 0.5), Controls(flip: true).MapAnchor(0.2, 0.5));
    }

    [Fact]
    public void AClipsFrameIsItsShapeOrTheTurnedProjectFrame()
    {
        foreach (var item in Cases().GetProperty("frames").EnumerateArray())
        {
            var source = item.GetProperty("source");
            var controls = Controls(shape: Shape(item.GetProperty("shape")), rotation: item.GetProperty("rotation").GetInt32());
            var size = ClipControlsRendering.OutputSize(new(source[0].GetInt32(), source[1].GetInt32()), Aspect(item.GetProperty("aspect").GetString()!), controls);
            Assert.Equal(new PixelSize(item.GetProperty("size")[0].GetInt32(), item.GetProperty("size")[1].GetInt32()), size);
        }
        foreach (var item in Cases().GetProperty("bitrates").EnumerateArray())
        {
            var controls = Controls(shape: Shape(item.GetProperty("shape")));
            var quality = item.GetProperty("quality").GetString() == "high" ? ExportQuality.High : ExportQuality.Standard;
            Assert.Equal(item.GetProperty("bitrate").GetInt64(),
                ClipControlsRendering.VideoBitrate(controls.Shape!.Value.Size(), ExportAspect.Landscape, quality, item.GetProperty("fps").GetDouble(), controls));
        }
        // Without controls (or with only a look) the output is exactly the export preset's, so default renders are unchanged.
        var plain = ExportPresets.Output(new(1920, 1080), 29.97, ExportAspect.Source, ExportQuality.Standard);
        Assert.Equal(plain, ClipControlsRendering.Output(new(1920, 1080), 29.97, ExportAspect.Source, ExportQuality.Standard, null));
        Assert.Equal(plain, ClipControlsRendering.Output(new(1920, 1080), 29.97, ExportAspect.Source, ExportQuality.Standard, Controls(look: ClipLook.Bw)));
        var portrait = ClipControlsRendering.Output(new(1920, 1080), 30, ExportAspect.Landscape, ExportQuality.Standard, Controls(shape: ClipShape.PortraitFourFive));
        Assert.Equal((new PixelSize(1080, 1350), 6_500_000L, false), (portrait.Size, portrait.VideoBitrate, portrait.PreserveSource));
    }

    [Fact]
    public void BleepedWordsAreMaskedLetterByLetter()
    {
        foreach (var item in Cases().GetProperty("mask").EnumerateArray())
            Assert.Equal(item.GetProperty("masked").GetString(), ClipEffectsRendering.Masked(item.GetProperty("text").GetString()!));
        var words = new[] { new CaptionWord("w1", "hello", 0, 0.5), new CaptionWord("w2", "damn", 0.5, 1), new CaptionWord("w3", "there", 1, 1.5) };
        var bleep = new ClipEffect("fx-bleep-1", null, "bleep", 0.5, 1) { WordIds = ["w2"] };
        var title = new ClipEffect("fx-title-1", null, "title", 0, 1) { Text = "Hi", Position = "top" };
        Assert.Equal(["hello", "××××", "there"], ClipEffectsRendering.MaskingBleeps(words, [bleep, title]).Select(word => word.Text));
        Assert.Same(words, ClipEffectsRendering.MaskingBleeps(words, [title]));
        Assert.Same(words, ClipEffectsRendering.MaskingBleeps(words, null));
    }

    [Fact]
    public void TrackedRectsInterpolateAndOverlaysFadeInsideTheirRange()
    {
        var blur = new ClipEffect("fx-blur-1", null, "blur", 1, 3)
        {
            Rect = new(0.1, 0.1, 0.2, 0.2), Tracking = "face",
            Track = [new(1, new(0.1, 0.1, 0.2, 0.2)), new(2, new(0.3, 0.1, 0.2, 0.4))]
        };
        Assert.Equal(new ClipEffectRect(0.1, 0.1, 0.2, 0.2), blur.RectAt(0.5));
        Assert.Equal(0.2, blur.RectAt(1.5)!.Value.X, 12);
        Assert.Equal(0.3, blur.RectAt(1.5)!.Value.Height, 12);
        Assert.Equal(new ClipEffectRect(0.3, 0.1, 0.2, 0.4), blur.RectAt(2.5));
        // Untracked (or a tracker that never ran): the stored rect holds.
        Assert.Equal(new ClipEffectRect(0.1, 0.1, 0.2, 0.2), (blur with { Track = [] }).RectAt(2.5));
        var title = new ClipEffect("fx-title-1", null, "title", 1, 2) { Text = "Hi", Position = "top" };
        Assert.Equal(0, title.OpacityAt(0.99)); Assert.Equal(0, title.OpacityAt(2));
        Assert.Equal(0.5, title.OpacityAt(1.06), 9); Assert.Equal(1, title.OpacityAt(1.5)); Assert.Equal(0.5, title.OpacityAt(1.94), 9);
    }

    [Fact]
    public void TheRenderInputCarriesTheClipsControlsTheScopesEffectsAndTheirSounds()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/clip-effects/effects-project.voxclip"));
        var full = ClipRenderInput.Resolve(project, null, "/data", "/shared");
        Assert.NotNull(full);
        Assert.Null(full!.Controls);
        var effects = full.Effects!;
        Assert.All(effects.Effects, effect => Assert.True(effect.IsCensor || effect.ClipId is null));
        foreach (var effect in effects.Effects.Where(effect => effect.Sound is { Source: "bundled" }))
            Assert.Equal(Path.Combine("/shared", "data", "sfx", effect.Sound!.Id + ".wav"), effects.SoundPaths[effect.Id]);
        foreach (var effect in effects.Effects.Where(effect => effect.Sound is { Source: "library" }))
            Assert.Equal(Path.Combine("/data", "SFX", effect.Sound!.File!.Replace('/', Path.DirectorySeparatorChar)), effects.SoundPaths[effect.Id]);
        // The edited WAV keeps bleeps and mutes (they silence the voice) and drops sounds and the controls.
        var voice = full.ForEditedAudio;
        Assert.True(voice is null || (voice.Controls is null && voice.Effects!.Effects.All(effect => effect.Kind != "sound")));
        var freeze = new ClipEffectsRenderInput([new ClipEffect("fx-freeze-1", null, "freeze", 0.5, 1.5)], new Dictionary<string, string>());
        Assert.Equal(0.5, freeze.PictureTime(0.5)); Assert.Equal(0.5, freeze.PictureTime(1.49)); Assert.Equal(1.5, freeze.PictureTime(1.5)); Assert.Equal(0.2, freeze.PictureTime(0.2));
        Assert.Null(ClipRenderInput.Resolve(project with { ClipEffects = [] }, null, "/data", "/shared"));
    }
}

using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Captions;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Translated captions render on Windows (ai.md §18.2), twin of the Mac <c>translatedCaptionsRenderInTheExportAndTheSRT</c>:
/// through the CLI export path the App's preview and export share (<c>CaptionTranslations.Shown</c>), the clip's captions and SRT show
/// the translation over its words, in the clip's own caption look, after the × masking, starting and ending where the words did.</summary>
[Collection("CLI console")]
public sealed class CaptionTranslationCliTests
{
    private static Project Base() =>
        ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip")) with { ClipControls = [] };

    private static async Task<ExportJob> ExportAsync(Project project)
    {
        var (exit, job, output) = await ClipRenderCliTests.ExportStyledAsync(project, [], ["--clip", "clip-main"]);
        Assert.True(exit == 0, output);
        return Assert.IsType<ExportJob>(job);
    }

    private static string[] Bounds(string srt) => srt.Split('\n').Where(line => line.Contains("-->", StringComparison.Ordinal)).ToArray();

    [Fact]
    public async Task TranslatedCaptionsRenderInTheClipsLookAndTheSrt()
    {
        var plainProject = Base();
        // "Translate these captions to Spanish" on the clip, words 0–4 (as ClipAutopilotMapping applies Ask Claude's translate).
        var translatedProject = CaptionTranslations.Translating(0, 4, "clip-main", "es", "Así que hoy enviamos esto ahora", plainProject);
        var plain = await ExportAsync(plainProject);
        var translated = await ExportAsync(translatedProject);
        Assert.Equal(plain.Snapshot.Captions!.Style.Id, translated.Snapshot.Captions!.Style.Id);
        var shown = translated.Snapshot.Captions.Words.Select(word => word.Raw).ToArray();
        Assert.Equal(["Así", "que", "hoy", "enviamos", "esto", "ahora", "uh", "the", "clipper.", "Thanks"], shown);
        var srt = Exporter.Subtitles(translated.Snapshot.Captions, translated.Snapshot.Speed.Speed).ToUpperInvariant();
        var before = Exporter.Subtitles(plain.Snapshot.Captions, plain.Snapshot.Speed.Speed);
        Assert.True(srt.Contains("ENVIAMOS", StringComparison.Ordinal) && !srt.Contains("TODAY", StringComparison.Ordinal), srt);
        Assert.Contains("CLIPPER", srt, StringComparison.Ordinal);
        // Six translated words over five shown words: the cues still start and end where the clip's captions did.
        Assert.Equal(Bounds(before)[0][..12], Bounds(srt)[0][..12]);
        Assert.Equal(Bounds(before)[^1][^12..], Bounds(srt)[^1][^12..]);
        // The pixels change where the captions show.
        var rasterizer = new SkiaCaptionRasterizer(FixtureLoader.SharedRoot);
        var time = translated.Snapshot.Captions.Words[1].Start + 0.02;
        var after = await rasterizer.RenderAsync(new(translated.Snapshot.Captions, time, Scale: 0.25), TestContext.Current.CancellationToken);
        var said = await rasterizer.RenderAsync(new(plain.Snapshot.Captions, time, Scale: 0.25), TestContext.Current.CancellationToken);
        var left = after.Pixels.ToArray(); var right = said.Pixels.ToArray();
        var differing = 0;
        for (var index = 0; index < Math.Min(left.Length, right.Length); index++) if (Math.Abs(left[index] - right[index]) > 8) differing++;
        Assert.True(differing > left.Length / 1000, $"{differing} differing bytes");
    }

    [Fact]
    public async Task ABleepedWordStaysMaskedUnderItsTranslationAndTheFullTakesShowsInTheClip()
    {
        var project = CaptionTranslations.Translating(1, 1, null, "de", "ähm", Base());
        project = CaptionTranslations.Translating(3, 4, null, "de", "wir liefern", project);
        var bleep = System.Text.Json.JsonSerializer.SerializeToElement(new
        {
            id = "fx-bleep-1", clipId = "clip-main", kind = "bleep", start = project.Transcript!.Words[3].Start, end = project.Transcript.Words[3].End,
            wordIds = new[] { "w4" }
        });
        project = VoxClip.Core.Domain.Effects.ClipEffects.Adding([bleep], project);
        var job = await ExportAsync(project);
        Assert.Equal(["So", "ähm", "today", "×××", "liefern", "uh", "the", "clipper.", "Thanks"], job.Snapshot.Captions!.Words.Select(word => word.Raw));
    }
}

using System.Text.Json.Nodes;
using VoxClip.Cli;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Frames;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Frames;

/// <summary><c>voxclip-cli analyze-frames</c> on Windows (ADR-R48, W5), twin of the Mac command: its flags and exit codes, the cache on a second run, and faces unavailable as a clear failure (exit 7), never faceless
/// observations. The stubbed runs call the command's own code on the CLI's parsed arguments with stub faces, text and frames.</summary>
[Collection("CLI console")]
public sealed class CliAnalyzeFramesTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("voxclip-cli-frames-").FullName;

    public void Dispose() { try { Directory.Delete(directory, true); } catch (IOException) { } }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    /// <summary>five-questions.voxclip with its media pointed at a stand-in file (the decoder is a stub).</summary>
    private async Task<(string Project, string ContentKey)> ProjectAsync()
    {
        var source = Path.Combine(directory, "source.mp4");
        await File.WriteAllTextAsync(source, "stand-in media " + Guid.NewGuid().ToString("N"), Ct);
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/five-questions.voxclip"));
        var key = await new ProjectStore().ComputeContentKeyAsync(source, null, Ct);
        project = project with { Media = new(project.Media.Source with { AbsolutePath = source, SizeBytes = new FileInfo(source).Length, ContentKey = key }) };
        var path = Path.Combine(directory, "five-questions.voxclip");
        await File.WriteAllTextAsync(path, ProjectSerialization.Serialize(project), Ct);
        return (path, key);
    }

    private static async Task<JsonObject> AnalyzeAsync(CliFrameSources sources, params string[] arguments)
    {
        var parsed = CliApplication.Parse(["analyze-frames", .. arguments]);
        Assert.Empty(parsed.Errors);
        return await CliAnalyzeFrames.RunAsync(parsed, sources, Ct);
    }

    private static CliFrameSources Stubs(StubFrameDecoder decoder, StubFrameText? text = null) => new(new StubFrameFaces(), text ?? new StubFrameText(), decoder);

    /// <summary>A project's clip: its analysis, decisions and sheet in the Mac's keys, cached in the data folder the first time and read
    /// from the cache the second; the project file is left as it was.</summary>
    [Fact]
    public async Task AClipIsAnalyzedCachedAndReadFromTheCacheTheSecondTime()
    {
        var (project, key) = await ProjectAsync();
        var before = await File.ReadAllBytesAsync(project, Ct);
        var cacheFolder = Path.Combine(DataLocations.Resolve().Cache, key, "frames");
        try
        {
            var sheetOut = Path.Combine(directory, "sheet");
            var decoder = new StubFrameDecoder();
            var first = await AnalyzeAsync(Stubs(decoder), "--open", project, "--clip", "fq-clip-1", "--sheet-out", sheetOut, "--json");
            Assert.Equal(["analysis", "clipEnd", "clipStart", "decisions", "sheet"], first.Select(pair => pair.Key).Order(StringComparer.Ordinal));
            Assert.Equal(["blurCandidates", "blurSpans", "cover", "coverCandidates", "crop1x1", "crop9x16", "opening", "pitchBaseline"],
                first["decisions"]!.AsObject().Select(pair => pair.Key).Order(StringComparer.Ordinal));
            var timings = first["analysis"]!["timings"]!;
            var sentences = first["analysis"]!["sentences"]!.AsArray().Count;
            var total = sentences + first["analysis"]!["opening"]!.AsArray().Count;
            Assert.Equal((0, total), (timings["cachedFrames"]!.GetValue<int>(), timings["analyzedFrames"]!.GetValue<int>()));
            Assert.Equal(total, decoder.Reads.Count);
            Assert.True(File.Exists(Path.Combine(cacheFolder, FrameAnalysisFile.FileName)));
            Assert.Equal(sentences, Directory.GetFiles(sheetOut, "frame-*.jpg").Length);
            Assert.True(File.Exists(Path.Combine(sheetOut, "frame-01.jpg")));
            // Every face measured by the stub; the summary names it.
            Assert.All(first["analysis"]!["sentences"]!.AsArray(), frame => Assert.Equal(1, frame!["faceCount"]!.GetValue<int>()));
            Assert.Contains("eyes open", first["sheet"]!["summary"]!.GetValue<string>(), StringComparison.Ordinal);

            var again = new StubFrameDecoder();
            var second = await AnalyzeAsync(Stubs(again), "--open", project, "--clip", "fq-clip-1", "--json");
            Assert.Equal((total, 0), (second["analysis"]!["timings"]!["cachedFrames"]!.GetValue<int>(), second["analysis"]!["timings"]!["analyzedFrames"]!.GetValue<int>()));
            Assert.Empty(again.Reads);
            Assert.Equal(before, await File.ReadAllBytesAsync(project, Ct));

            // --no-cache analyzes every frame again.
            var fresh = new StubFrameDecoder();
            var third = await AnalyzeAsync(Stubs(fresh), "--open", project, "--clip", "fq-clip-1", "--no-cache", "--json");
            Assert.Equal(total, third["analysis"]!["timings"]!["analyzedFrames"]!.GetValue<int>());
            Assert.Equal(total, fresh.Reads.Count);
        }
        finally { if (Directory.Exists(cacheFolder)) Directory.Delete(cacheFolder, true); }
    }

    /// <summary><c>--video-pass</c> times the whole video's pass, the clip's frames from it and its opening; the clip's own analysis then
    /// reads the pass's frames from the cache.</summary>
    [Fact]
    public async Task TheVideoPassIsTimedAndFeedsTheClipsAnalysis()
    {
        var (project, key) = await ProjectAsync();
        var cacheFolder = Path.Combine(DataLocations.Resolve().Cache, key, "frames");
        try
        {
            var result = await AnalyzeAsync(Stubs(new StubFrameDecoder()), "--open", project, "--clip", "fq-clip-1", "--video-pass", "--json");
            var pass = result["videoPass"]!.AsObject();
            Assert.Equal(["analyzed", "cached", "clipFrames", "clipSeconds", "frames", "openingFrames", "openingSeconds", "pitchBaseline", "read", "seconds"],
                pass.Select(pair => pair.Key).Order(StringComparer.Ordinal));
            Assert.True(pass["read"]!.GetValue<bool>());
            Assert.Equal(FrameSampling.OpeningTimes(result["clipStart"]!.GetValue<double>()).Count, pass["openingFrames"]!.GetValue<int>());
            Assert.Equal(result["analysis"]!["opening"]!.AsArray().Count, pass["openingFrames"]!.GetValue<int>());
            Assert.Equal(StubFrameFaces.Face.Pitch, pass["pitchBaseline"]!.GetValue<double>());
            Assert.Equal(StubFrameFaces.Face.Pitch, result["decisions"]!["pitchBaseline"]!.GetValue<double>());
            Assert.True(pass["seconds"]!.GetValue<double>() >= 0);
            // The pass's opening scan is the clip's: all cached. (A sentence frame of a clip that starts mid-sentence may be its own.)
            var timings = result["analysis"]!["timings"]!;
            Assert.True(timings["cachedFrames"]!.GetValue<int>() >= pass["openingFrames"]!.GetValue<int>());
            Assert.True(timings["analyzedFrames"]!.GetValue<int>() <= result["analysis"]!["sentences"]!.AsArray().Count);
        }
        finally { if (Directory.Exists(cacheFolder)) Directory.Delete(cacheFolder, true); }
    }

    /// <summary>The whole CLI with no face models installed: <c>modelMissing</c>, exit 7, the line that says so, and nothing measured or
    /// cached. A missing clip or a wrong pair of options is a usage error (exit 2), as on the Mac.</summary>
    [Fact]
    public async Task WithFacesUnavailableTheCliFailsWithTheMacsCodeAndLine()
    {
        var (project, key) = await ProjectAsync();
        var (exit, output, _) = await RunAsync("analyze-frames", "--open", project, "--clip", "fq-clip-1", "--json");
        Assert.Equal(7, exit);
        var failure = JsonNode.Parse(output)!.AsObject();
        Assert.False(failure["ok"]!.GetValue<bool>());
        Assert.Equal(("analyze-frames", "modelMissing", FrameFaces.UnavailableMessage),
            (failure["command"]!.GetValue<string>(), failure["error"]!["code"]!.GetValue<string>(), failure["error"]!["message"]!.GetValue<string>()));
        Assert.DoesNotContain("faceCount", output, StringComparison.Ordinal);
        Assert.False(Directory.Exists(Path.Combine(DataLocations.Resolve().Cache, key, "frames")));

        var (human, _, errors) = await RunAsync("analyze-frames", "--open", project, "--clip", "fq-clip-1");
        Assert.Equal(7, human);
        Assert.Contains("The face models aren't installed on this PC", errors, StringComparison.Ordinal);

        Assert.Equal(2, (await RunAsync("analyze-frames", "--open", project, "--json")).Exit);
        Assert.Equal(2, (await RunAsync("analyze-frames", "--open", project, "--transcript", project, "--json")).Exit);
        Assert.Equal(2, (await RunAsync("analyze-frames", "--open", project, "--clip", "c", "--words", "0:1", "--json")).Exit);
    }

    /// <summary>The installed CLI's face source is the bundled models (W3) only while the catalogue is enabled or the developer override
    /// (<see cref="OnnxFrameFaces.OverrideVariable"/>) is set; the shipped catalogue is off, so a plain run has none.</summary>
    [Fact]
    public void TheInstalledFaceSourceFollowsTheCatalogueAndTheOverride()
    {
        var installed = CliFrameSources.Installed();
        try
        {
            Assert.Equal(new FrameModelCatalog().Enabled || OnnxFrameFaces.Overridden(), installed.Faces is OnnxFrameFaces);
        }
        finally
        {
            (installed.Faces as IDisposable)?.Dispose();
        }
    }

    /// <summary>With faces but no text recognizer (this portable CLI has no Windows OCR), nothing is measured either.</summary>
    [Fact]
    public async Task WithoutTextRecognitionNothingIsMeasured()
    {
        var (project, _) = await ProjectAsync();
        var decoder = new StubFrameDecoder();
        var error = await Assert.ThrowsAsync<VoxClipException>(() =>
            AnalyzeAsync(new CliFrameSources(new StubFrameFaces(), null, decoder), "--open", project, "--clip", "fq-clip-1", "--json"));
        Assert.Equal((VoxClipErrorCode.ModelMissing, 7, CliAnalyzeFrames.TextUnavailableMessage), (error.Code, error.ExitCode, error.Message));
        Assert.Empty(decoder.Reads);
    }

    [Fact]
    public async Task AMissingClipOrWordRangeIsAUsageError()
    {
        var (project, _) = await ProjectAsync();
        await Assert.ThrowsAsync<CliUsageException>(() => AnalyzeAsync(Stubs(new StubFrameDecoder()), "--open", project, "--clip", "nope", "--json"));
        var words = Path.Combine(directory, "words.json");
        await File.WriteAllTextAsync(words, "{}", Ct);
        var parsed = CliApplication.Parse(["analyze-frames", "--open", project, "--transcript", words, "--words", "2", "--json"]);
        Assert.Contains(parsed.Errors, error => error.Message == "A media file needs --transcript and --words first:last.");
    }

    private static async Task<(int Exit, string Output, string Errors)> RunAsync(params string[] arguments)
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(arguments, Ct);
            return (exit, output.ToString(), errors.ToString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }
}

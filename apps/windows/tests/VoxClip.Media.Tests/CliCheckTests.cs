using System.Text.Json.Nodes;
using VoxClip.Cli;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary><c>voxclip-cli check</c> and the autopilot's per-clip checks (ADR-R49), twin of the Mac CLI's: exit 0 when every check is
/// ok or skipped, 8 when any warns, and the Mac's JSON. The export command's own preparation runs on an injected probe, and the
/// checker reads a synthetic export, so nothing needs FFmpeg or a model, and nothing is sent.</summary>
[Collection("CLI console")]
public sealed class CliCheckTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("voxclip-cli-check-").FullName;

    public void Dispose() { try { Directory.Delete(directory, true); } catch (IOException) { } }

    /// <summary>five-questions.voxclip with its source media pointed at a stand-in file in the test folder, saved there.</summary>
    private async Task<(string Project, MediaInfo Media)> ProjectAsync()
    {
        var source = Path.Combine(directory, "source.mp4");
        await File.WriteAllTextAsync(source, "offline injected probe input", TestContext.Current.CancellationToken);
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/five-questions.voxclip"));
        var key = await new ProjectStore().ComputeContentKeyAsync(source, null, TestContext.Current.CancellationToken);
        project = project with { Media = new(project.Media.Source with { AbsolutePath = source, SizeBytes = new FileInfo(source).Length, ContentKey = key }) };
        var path = Path.Combine(directory, "five-questions.voxclip");
        await File.WriteAllTextAsync(path, ProjectSerialization.Serialize(project), TestContext.Current.CancellationToken);
        var media = new MediaInfo(source, project.Media.Source.DurationSeconds, project.Media.Source.Video, project.Media.Source.Audio, new(1920, 1080),
            "h264", "aac", false, 0, 1, 0);
        return (path, media);
    }

    private static ExportInputReader Open(MediaInfo media) => async (path, ct) => ((await new ProjectStore().LoadAsync(path, ct)).Project, media);

    /// <summary>A checker reading <paramref name="file"/> in place of the export, hearing with <paramref name="hearing"/> (none by
    /// default, as with no installed model).</summary>
    private static ExportCheckerFactory Checker(Func<IExportFile> file, ExportChecker.Hearing? hearing = null) =>
        (_, scratch) => new ExportChecker(hearing, scratch, FixtureLoader.SharedRoot, (_, _) => file());

    private static SyntheticExport Export(double audioEnd = 6) =>
        new(new(0, 6), new(0, audioEnd), SyntheticExport.Speech(audioEnd, -14), frame: new PixelSize(1080, 1920));

    private static async Task<(int Exit, string Output, string Errors)> RunAsync(string[] arguments, ExportInputReader? open = null,
        ExportPreparer? prepare = null, ExportCheckerFactory? checker = null)
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(arguments, TestContext.Current.CancellationToken, open, prepare, checker);
            return (exit, output.ToString(), errors.ToString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }

    [Fact]
    public async Task APassingCheckExitsZeroWithTheMacsJson()
    {
        var (project, media) = await ProjectAsync();
        var export = Path.Combine(directory, "clip.mp4");
        await File.WriteAllTextAsync(export, "synthetic export", TestContext.Current.CancellationToken);
        var (exit, output, errors) = await RunAsync(["check", "--project", project, "--clip", "1", export, "--aspect", "9:16", "--json"],
            Open(media), checker: Checker(() => Export()));
        Assert.True(exit == 0, $"exit {exit}: {output} {errors}");
        var json = JsonNode.Parse(output)!.AsObject();
        Assert.Equal(["check", "clipId", "command", "ok", "output", "version"], json.Select(pair => pair.Key).Order(StringComparer.Ordinal));
        Assert.Equal((true, "check", "fq-clip-1", export), (json["ok"]!.GetValue<bool>(), json["command"]!.GetValue<string>(),
            json["clipId"]!.GetValue<string>(), json["output"]!.GetValue<string>()));
        var check = json["check"]!.AsObject();
        Assert.Equal(["captions", "engine", "hearSeconds", "loudness", "model", "passed", "seconds", "sync", "words"], check.Select(pair => pair.Key).Order(StringComparer.Ordinal));
        Assert.True(check["passed"]!.GetValue<bool>());
        Assert.Null(check["engine"]); Assert.Null(check["model"]);
        Assert.Equal(0, check["hearSeconds"]!.GetValue<double>());
        Assert.Equal("""{"status":"skipped","reason":"No local transcription model","items":[]}""", check["words"]!.ToJsonString());
        Assert.Equal("""{"status":"ok","items":[],"startOffset":0,"endOffset":0}""", check["sync"]!.ToJsonString());
        Assert.Equal("ok", check["loudness"]!["status"]!.GetValue<string>());
        Assert.InRange(check["loudness"]!["integratedLufs"]!.GetValue<double>(), -14.05, -13.95);
        // The clip renders in the project's caption style; its 9:16 cards clear the feed's bands.
        Assert.Equal("""{"status":"ok","items":[]}""", check["captions"]!.ToJsonString());
        Assert.Equal(1, output.Count(character => character == '\n'));
    }

    [Fact]
    public async Task AWarningExitsEightAndPrintsTheReport()
    {
        var (project, media) = await ProjectAsync();
        var export = Path.Combine(directory, "clip.mp4");
        await File.WriteAllTextAsync(export, "synthetic export", TestContext.Current.CancellationToken);
        var (stub, hearing) = StubHearing.Make([]);
        var (exit, output, _) = await RunAsync(["check", "--project", project, "--clip", "fq-clip-2", export, "--aspect", "9:16", "--style", "off", "--loudness", "off"],
            Open(media), checker: Checker(() => Export(6.5), hearing));
        Assert.Equal(CliCheck.WarningExitCode, exit);
        Assert.Single(stub.Received);
        var lines = output.TrimEnd('\n').Split('\n');
        Assert.StartsWith("words: warning, 0/", lines[0], StringComparison.Ordinal);
        Assert.Contains("  0:", lines[1], StringComparison.Ordinal);
        Assert.Contains(lines, line => line == "sync: warning");
        Assert.Contains(lines, line => line == "  0:06.00 trackEnd 0.500");
        Assert.Contains(lines, line => line == "loudness: skipped (Loudness is off for this export)");
        Assert.Contains(lines, line => line == "captions: skipped (No captions or title in this export)");
        Assert.Equal("warnings", lines[^1]);
        // With --json the envelope is still ok: the export was checked, and the exit status carries the warning.
        var (jsonExit, json, _) = await RunAsync(["check", "--project", project, "--clip", "fq-clip-2", export, "--aspect", "9:16", "--json"],
            Open(media), checker: Checker(() => Export(6.5)));
        Assert.Equal(8, jsonExit);
        var result = JsonNode.Parse(json)!;
        Assert.True(result["ok"]!.GetValue<bool>());
        Assert.False(result["check"]!["passed"]!.GetValue<bool>());
        Assert.Equal("trackEnd", result["check"]!["sync"]!["items"]![0]!["kind"]!.GetValue<string>());
        Assert.Equal(0.5, result["check"]!["sync"]!["endOffset"]!.GetValue<double>(), 9);
    }

    [Fact]
    public async Task UsageAndMissingInputs()
    {
        var (project, media) = await ProjectAsync();
        var export = Path.Combine(directory, "clip.mp4");
        await File.WriteAllTextAsync(export, "synthetic export", TestContext.Current.CancellationToken);
        var unknown = await RunAsync(["check", "--project", project, "--clip", "9", export, "--aspect", "9:16", "--json"], Open(media), checker: Checker(() => Export()));
        Assert.Equal(2, unknown.Exit);
        Assert.Equal("usageError", JsonNode.Parse(unknown.Output)!["error"]!["code"]!.GetValue<string>());
        var missing = await RunAsync(["check", "--project", project, "--clip", "1", Path.Combine(directory, "missing.mp4"), "--json"], Open(media));
        Assert.Equal(3, missing.Exit);
        Assert.Equal("mediaMissing", JsonNode.Parse(missing.Output)!["error"]!["code"]!.GetValue<string>());
        var noProject = await RunAsync(["check", "--project", Path.Combine(directory, "missing.voxclip"), "--clip", "1", export, "--json"]);
        Assert.Equal(3, noProject.Exit);
        Assert.Equal(2, (await RunAsync(["check", "--clip", "1", export])).Exit);
        Assert.Equal(2, (await RunAsync(["check", "--project", project, "--clip", "1", export, "--loudness", "loud"])).Exit);
        var help = await RunAsync(["check", "--help"]);
        Assert.Equal(0, help.Exit);
        foreach (var option in new[] { "--project", "--clip", "<export>", "--aspect", "--style", "--loudness", "--json", "8 when any warns" })
            Assert.Contains(option, help.Output, StringComparison.Ordinal);
        Assert.Contains("--no-check", (await RunAsync(["autopilot", "--help"])).Output, StringComparison.Ordinal);
    }

    [Fact]
    public void TheExportsFrameNamesItsAspect()
    {
        Assert.Equal("9:16", CliCheck.Aspect(new(1080, 1920)));
        Assert.Equal("16:9", CliCheck.Aspect(new(1920, 1080)));
        Assert.Equal("1:1", CliCheck.Aspect(new(1080, 1080)));
        Assert.Equal("source", CliCheck.Aspect(new(1080, 1350)));
        Assert.Equal("source", CliCheck.Aspect(new(0, 0)));
    }

    /// <summary>Find Clips' two clips of the fixture's lines; each clip plan keeps its span with a hook title and the default look (its music
    /// stays pending).</summary>
    private sealed class Planner : ILlmConnector
    {
        public ConnectorId Id => ConnectorId.Ollama;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("fixture", "Fixture", null, 256_000, ModelSource.Curated)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(256_000);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            string reply;
            if (request.Feature == LlmFeature.ClipFinder)
                reply = new JsonObject { ["clips"] = new JsonArray(Clip("Coffee", 7, 1, 3), Clip("Sleep wins", 9, 4, 6)) }.ToJsonString();
            else
            {
                var span = System.Text.RegularExpressions.Regex.Match(request.Instruction, "from word (\\d+) to word (\\d+)");
                var (start, end) = (int.Parse(span.Groups[1].Value), int.Parse(span.Groups[2].Value));
                reply = new JsonObject
                {
                    ["startWord"] = start, ["endWord"] = end, ["title"] = "Planned " + start, ["hook"] = "We ship every week", ["cuts"] = new JsonArray(), ["pauseCuts"] = new JsonArray(),
                    ["corrections"] = new JsonArray(), ["rewrites"] = new JsonArray(), ["captionStyle"] = "vox-highlight", ["captionFont"] = "Roboto", ["captionWeight"] = 900,
                    ["captionCase"] = "upper", ["wordsPerCaption"] = 3, ["captionReason"] = "", ["look"] = "original", ["lookReason"] = "", ["speed"] = 1, ["speedReason"] = "",
                    ["lengthReason"] = "", ["tone"] = "none", ["toneSummary"] = "", ["music"] = new JsonArray(new JsonObject { ["title"] = "Pulse", ["mood"] = "driven", ["prompt"] = "Instrumental, 120 BPM", ["reason"] = "pace", ["underVoiceDb"] = 18 }),
                    ["musicPick"] = 0, ["zooms"] = new JsonArray(),
                    ["postText"] = "Post", ["score"] = 8, ["verdict"] = "post", ["scoreReason"] = "", ["questions"] = new JsonArray(),
                    ["frames"] = new JsonObject { ["blur"] = new JsonArray(), ["cover"] = new JsonObject { ["id"] = "", ["reason"] = "" } }
                }.ToJsonString();
            }
            return Task.FromResult(new RawCompletion(reply, null, model, new StopKind.Complete(), null, null));
        }
        private static JsonObject Clip(string title, int score, int first, int last) =>
            new() { ["title"] = title, ["reason"] = title + " lands.", ["score"] = score, ["start_line"] = first, ["end_line"] = last };
    }

    private async Task<JsonObject> AutopilotAsync(MediaInfo media, string project, string outDir, ExportCheckerFactory checker, params string[] extra)
    {
        var parsed = CliApplication.Parse(["autopilot", "--open", project, "--connector", "ollama", "--model", "fixture", "--count", "2",
            "--out-dir", outDir, "--quiet", "--timings", "--json", .. extra]);
        Assert.Empty(parsed.Errors);
        Task<ExportResult> Prepare(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
        {
            File.WriteAllText(job.OutputPath + ".partial", "synthetic test export");
            return Task.FromResult(new ExportResult(job.OutputPath, null, job.Snapshot.RenderedDuration, job.Snapshot.Output.Size.Width,
                job.Snapshot.Output.Size.Height, 30, 180, 48_000, job.Snapshot.Timeline.OutputSamples, "h264", "test", 0));
        }
        return await CliAutopilot.RunAsync(parsed, (_, _) => new Planner(), TestContext.Current.CancellationToken, Open(media), Prepare, checker);
    }

    [Fact]
    public async Task TheAutopilotChecksEachExportedClipUnlessToldNotTo()
    {
        var (project, media) = await ProjectAsync();
        var outDir = Directory.CreateDirectory(Path.Combine(directory, "out")).FullName;
        var opened = 0;
        var result = await AutopilotAsync(media, project, outDir, Checker(() => { Interlocked.Increment(ref opened); return Export(); }));
        var clips = result["clips"]!.AsArray().Select(clip => clip!.AsObject()).ToArray();
        Assert.Equal(2, clips.Length);
        Assert.Equal(2, opened);
        foreach (var clip in clips)
        {
            var output = Assert.Single(clip["outputs"]!.AsArray())!.GetValue<string>();
            Assert.True(File.Exists(output));
            var check = clip["check"]!.AsObject();
            Assert.True(check["passed"]!.GetValue<bool>(), check.ToJsonString());
            Assert.Equal("skipped", check["words"]!["status"]!.GetValue<string>());
            Assert.Equal("ok", check["sync"]!["status"]!.GetValue<string>());
        }
        // Each check is timed per clip, after its export.
        var stages = result["timings"]!["stages"]!.AsArray().Select(stage => (Stage: stage!["stage"]!.GetValue<string>(), Clip: stage["clip"]?.GetValue<int>(),
            Start: stage["start"]!.GetValue<double>(), End: stage["end"]!.GetValue<double>())).ToArray();
        foreach (var rank in new[] { 1, 2 })
        {
            var export = stages.Single(stage => stage.Stage == "export" && stage.Clip == rank);
            var check = stages.Single(stage => stage.Stage == "check" && stage.Clip == rank);
            Assert.True(check.Start >= export.End - 1e-3, $"clip {rank}: check {check.Start} before export end {export.End}");
        }
        // A check that fails reports it on its clip and the run goes on.
        var broken = await AutopilotAsync(media, project, Directory.CreateDirectory(Path.Combine(directory, "broken")).FullName,
            Checker(() => throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The export's audio did not decode.")));
        Assert.All(broken["clips"]!.AsArray(), clip =>
        {
            var check = clip!["check"]!.AsObject();
            Assert.Equal(["passed", "error"], check.Select(pair => pair.Key));
            Assert.Equal((false, "The export's audio did not decode."), (check["passed"]!.GetValue<bool>(), check["error"]!.GetValue<string>()));
        });

        var skipped = await AutopilotAsync(media, project, Directory.CreateDirectory(Path.Combine(directory, "unchecked")).FullName,
            Checker(() => throw new InvalidOperationException("--no-check must not check")), "--no-check");
        Assert.All(skipped["clips"]!.AsArray(), clip => Assert.Null(clip!["check"]));
        Assert.DoesNotContain(skipped["timings"]!["stages"]!.AsArray(), stage => stage!["stage"]!.GetValue<string>() == "check");
    }
}

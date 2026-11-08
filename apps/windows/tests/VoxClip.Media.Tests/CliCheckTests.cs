using System.Diagnostics;
using System.Text.Json.Nodes;
using VoxClip.Cli;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary><c>voxclip-cli check</c> and the autopilot's per-clip checks (ADR-R49), twin of the Mac CLI's: the check prepared through
/// the export command's own path, the Mac's JSON and report, exit 8 when any check warns, and each autopilot clip's <c>check</c>. The
/// export command's preparation runs on an injected probe; the checker reads a synthetic export, so nothing here needs FFmpeg or a
/// model, and nothing is sent. The whole command on a real file runs in <see cref="NativeCliCheckTests"/> (VM).</summary>
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

    /// <summary>The clip's render prepared as <c>check</c> prepares it, then checked on <paramref name="file"/>: the command's
    /// <c>check</c> object, its exit status and the words expected.</summary>
    private async Task<(JsonObject Check, int Exit, ExportCheckExpectation.Edit Edit)> CheckAsync(IExportFile file, ExportChecker.Hearing? hearing, params string[] options)
    {
        var ct = TestContext.Current.CancellationToken;
        var (project, media) = await ProjectAsync();
        var parsed = CliApplication.Parse(["--open", project, "--export", Path.Combine(directory, "clip.mp4"), "--quiet", .. options]);
        Assert.Empty(parsed.Errors);
        var prepared = await CliOperations.PrepareExportAsync(parsed, ct, Open(media), checkingOutputs: false);
        var edit = ExportCheckExpectation.Make(prepared.Snapshot, prepared.State);
        var outcome = await new ExportChecker(hearing, directory, FixtureLoader.SharedRoot).CheckAsync(file, prepared.Snapshot, edit, prepared.Loudness, Stopwatch.StartNew(), ct);
        var check = CliCheck.Json(outcome);
        return (check, CliCheck.ExitCode(new JsonObject { ["check"] = check.DeepClone() }), edit);
    }

    private static SyntheticExport Export(double audioEnd = 6) =>
        new(new(0, 6), new(0, audioEnd), SyntheticExport.Speech(audioEnd, -14), frame: new PixelSize(1080, 1920));

    private static async Task<(int Exit, string Output, string Errors)> RunAsync(string[] arguments, ExportInputReader? open = null)
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(arguments, TestContext.Current.CancellationToken, open);
            return (exit, output.ToString(), errors.ToString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }

    [Fact]
    public async Task APassingCheckIsTheMacsJsonAndExitsZero()
    {
        var (check, exit, edit) = await CheckAsync(Export(), null, "--clip", "fq-clip-1", "--aspect", "9:16");
        Assert.Equal(0, exit);
        Assert.Equal(["passed", "seconds", "hearSeconds", "engine", "model", "words", "sync", "loudness", "captions"], check.Select(pair => pair.Key));
        Assert.True(check["passed"]!.GetValue<bool>());
        Assert.Null(check["engine"]); Assert.Null(check["model"]);
        Assert.Equal(0, check["hearSeconds"]!.GetValue<double>());
        Assert.Equal("""{"status":"skipped","reason":"No local transcription model","items":[]}""", check["words"]!.ToJsonString());
        Assert.Equal("""{"status":"ok","items":[],"startOffset":0,"endOffset":0}""", check["sync"]!.ToJsonString());
        Assert.Equal("ok", check["loudness"]!["status"]!.GetValue<string>());
        Assert.InRange(check["loudness"]!["integratedLufs"]!.GetValue<double>(), -14.05, -13.95);
        // The clip renders in the project's caption style (Highlight); its 9:16 cards clear the feed's bands.
        Assert.Equal("""{"status":"ok","items":[]}""", check["captions"]!.ToJsonString());
        // The words expected are the clip's own, fq-1 to fq-22, without the project's cut fq-2 to fq-9; its "Um," is optional.
        Assert.Equal(14, edit.Words.Count);
        Assert.Equal(("Um,", true, "something"), (edit.Words[0].Text, edit.Words[0].Optional, edit.Words[1].Text));
        // Every join of the plan's kept pieces is a cut: the cut words and the tightened pauses.
        Assert.NotEmpty(edit.Cuts);
        var lines = CliCheck.Summary(check).Split('\n');
        Assert.Equal(5, lines.Length);
        Assert.Equal(("words: skipped (No local transcription model)", "sync: ok", "captions: ok", "passed"), (lines[0], lines[1], lines[3], lines[4]));
        Assert.Matches("^loudness: ok, -14\\.0 LUFS, -?\\d+\\.\\d dBTP$", lines[2]);
    }

    [Fact]
    public async Task AWarningExitsEightAndTheReportListsEachFinding()
    {
        var (stub, hearing) = StubHearing.Make([]);
        var (check, exit, edit) = await CheckAsync(Export(6.5), hearing, "--clip", "fq-clip-2", "--aspect", "9:16", "--style", "off", "--loudness", "off");
        Assert.Equal(CliCheck.WarningExitCode, exit);
        Assert.Single(stub.Received);
        Assert.Equal(("whispercpp", "stub"), (check["engine"]!.GetValue<string>(), check["model"]!.GetValue<string>()));
        Assert.Equal(0.5, check["sync"]!["endOffset"]!.GetValue<double>(), 9);
        var lines = CliCheck.Summary(check).Split('\n');
        // Nothing heard: the words at the clip's edges are cut off, the others mismatches.
        Assert.Equal($"words: warning, 0/{edit.Words.Count(word => !word.Optional)} words as edited", lines[0]);
        Assert.Contains(lines, line => System.Text.RegularExpressions.Regex.IsMatch(line, "^  0:\\d\\d\\.\\d\\d cutOff \".+\" not heard$"));
        Assert.Contains(lines, line => System.Text.RegularExpressions.Regex.IsMatch(line, "^  0:\\d\\d\\.\\d\\d mismatch \".+\" not heard$"));
        Assert.Contains("sync: warning", lines);
        Assert.Contains("  0:06.00 trackEnd 0.500", lines);
        Assert.Contains("loudness: skipped (Loudness is off for this export)", lines);
        Assert.Contains("captions: skipped (No captions or title in this export)", lines);
        Assert.Equal("warnings", lines[^1]);
        Assert.Equal(0, CliCheck.ExitCode(new JsonObject { ["output"] = "x" }));
    }

    [Fact]
    public async Task TheClipIsNamedByNumberOrIdAndBadInputsStopFirst()
    {
        var (project, media) = await ProjectAsync();
        var clips = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(project, TestContext.Current.CancellationToken)).Edits.Clips;
        Assert.Equal("fq-clip-1", CliCheck.Clip(clips, "1")!.Id);
        Assert.Equal("fq-clip-5", CliCheck.Clip(clips, "5")!.Id);
        Assert.Equal("fq-clip-3", CliCheck.Clip(clips, "fq-clip-3")!.Id);
        Assert.Null(CliCheck.Clip(clips, "0")); Assert.Null(CliCheck.Clip(clips, "6")); Assert.Null(CliCheck.Clip(clips, "-1"));
        var export = Path.Combine(directory, "clip.mp4");
        await File.WriteAllTextAsync(export, "synthetic export", TestContext.Current.CancellationToken);
        var unknown = await RunAsync(["check", "--project", project, "--clip", "9", export, "--aspect", "9:16", "--json"], Open(media));
        Assert.Equal(2, unknown.Exit);
        Assert.Equal("usageError", JsonNode.Parse(unknown.Output)!["error"]!["code"]!.GetValue<string>());
        var missing = await RunAsync(["check", "--project", project, "--clip", "1", Path.Combine(directory, "missing.mp4"), "--json"], Open(media));
        Assert.Equal(3, missing.Exit);
        Assert.Equal("mediaMissing", JsonNode.Parse(missing.Output)!["error"]!["code"]!.GetValue<string>());
        Assert.Equal(3, (await RunAsync(["check", "--project", Path.Combine(directory, "missing.voxclip"), "--clip", "1", export, "--json"])).Exit);
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

    /// <summary>Find Clips' two clips of the fixture's lines; each clip plan keeps its span with a hook title and the default look (its
    /// music stays pending).</summary>
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
                    ["lengthReason"] = "", ["tone"] = "none", ["toneSummary"] = "",
                    ["music"] = new JsonArray(new JsonObject { ["title"] = "Pulse", ["mood"] = "driven", ["prompt"] = "Instrumental, 120 BPM", ["reason"] = "pace", ["underVoiceDb"] = 18 }),
                    ["musicPick"] = 0, ["zooms"] = new JsonArray(), ["postText"] = "Post", ["score"] = 8, ["verdict"] = "post", ["scoreReason"] = "", ["questions"] = new JsonArray(),
                    ["frames"] = new JsonObject { ["blur"] = new JsonArray(), ["cover"] = new JsonObject { ["id"] = "", ["reason"] = "" } }
                }.ToJsonString();
            }
            return Task.FromResult(new RawCompletion(reply, null, model, new StopKind.Complete(), null, null));
        }
        private static JsonObject Clip(string title, int score, int first, int last) =>
            new() { ["title"] = title, ["reason"] = title + " lands.", ["score"] = score, ["start_line"] = first, ["end_line"] = last };
    }

    private async Task<JsonObject> AutopilotAsync(MediaInfo media, string project, string outDir, params string[] extra)
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
        return await CliAutopilot.RunAsync(parsed, (_, _) => new Planner(), TestContext.Current.CancellationToken, Open(media), Prepare);
    }

    [Fact]
    public async Task TheAutopilotChecksEachExportedClipAfterItsExportUnlessToldNotTo()
    {
        var (project, media) = await ProjectAsync();
        var result = await AutopilotAsync(media, project, Directory.CreateDirectory(Path.Combine(directory, "out")).FullName);
        var clips = result["clips"]!.AsArray().Select(clip => clip!.AsObject()).ToArray();
        Assert.Equal(2, clips.Length);
        foreach (var clip in clips)
        {
            Assert.True(File.Exists(Assert.Single(clip["outputs"]!.AsArray())!.GetValue<string>()));
            // The stand-in export is text, not an MP4: the check reports that on its clip, and the run goes on.
            var check = clip["check"]!.AsObject();
            Assert.Equal(["passed", "error"], check.Select(pair => pair.Key));
            Assert.False(check["passed"]!.GetValue<bool>());
            Assert.False(string.IsNullOrWhiteSpace(check["error"]!.GetValue<string>()));
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
        var skipped = await AutopilotAsync(media, project, Directory.CreateDirectory(Path.Combine(directory, "unchecked")).FullName, "--no-check");
        Assert.All(skipped["clips"]!.AsArray(), clip => Assert.Null(clip!["check"]));
        Assert.DoesNotContain(skipped["timings"]!["stages"]!.AsArray(), stage => stage!["stage"]!.GetValue<string>() == "check");
        // Without --out-dir nothing is exported, so nothing is checked.
        var parsed = CliApplication.Parse(["autopilot", "--open", project, "--connector", "ollama", "--model", "fixture", "--count", "1", "--timings", "--json"]);
        var planned = await CliAutopilot.RunAsync(parsed, (_, _) => new Planner(), TestContext.Current.CancellationToken);
        Assert.Null(planned["clips"]![0]!["check"]);
    }
}

/// <summary>The whole <c>check</c> command on a real file (VM): unequal-duration.mp4's audio ends 0.09 s before its picture.</summary>
[Trait("Category", "RequiresFFmpeg")]
[Collection("CLI console")]
public sealed class NativeCliCheckTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync();
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Fact]
    public async Task TheCommandChecksARealFileAndExitsEightOnItsSync()
    {
        var ct = TestContext.Current.CancellationToken;
        var source = NativeTest.Fixture("unequal-duration.mp4");
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-check-native-").FullName;
        var previousOutput = Console.Out;
        using var output = new StringWriter();
        try
        {
            var media = await CliOperations.ProbeInputAsync(source, ct);
            var words = Enumerable.Range(0, 4).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word, 0.5 + index * 0.8, 0.9 + index * 0.8,
                null, null, 0.9, null, TimingSource.TokenGrouped)).ToArray();
            var transcript = new Transcript(1, words, "en", null, media.DurationSeconds, new(TranscriptEngine.Whispercpp, null, null, "fixture", null), false, false, 1,
                new string('0', 64), DateTimeOffset.UnixEpoch);
            var key = await new ProjectStore().ComputeContentKeyAsync(source, null, ct);
            var project = CliOperations.NewProject(media, transcript, key);
            project = project with { Edits = project.Edits with { Clips = [new ClipRange("clip-1", "w0", "w3", null, ClipOrigin.Manual, null, null, true)] } };
            var path = Path.Combine(directory, "check.voxclip");
            await new ProjectStore().SaveAsync(project, path, ct);
            Console.SetOut(output);
            var exit = await AcceptedCli.RunAsync(["check", "--project", path, "--clip", "1", source, "--style", "off", "--json"], ct);
            Console.SetOut(previousOutput);
            Assert.True(exit == CliCheck.WarningExitCode, $"exit {exit}: {output}");
            var check = JsonNode.Parse(output.ToString())!["check"]!;
            Assert.False(check["passed"]!.GetValue<bool>());
            Assert.Equal("trackEnd", check["sync"]!["items"]![0]!["kind"]!.GetValue<string>());
            Assert.Equal("skipped", check["captions"]!["status"]!.GetValue<string>());
        }
        finally { Console.SetOut(previousOutput); Directory.Delete(directory, true); }
    }
}

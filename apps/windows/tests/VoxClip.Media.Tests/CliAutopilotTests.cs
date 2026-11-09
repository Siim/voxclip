using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Cli;
using VoxClip.Core.Services.LLM;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary><c>voxclip-cli autopilot</c> (ai.md §16.12), twin of the Mac <c>CLIAutopilotTests</c>: Find Clips, the top clips planned at
/// once with Find Clips' moments, each applied as its plan is ready, the Mac's JSON shape (minus frames) and <c>--timings</c>. The
/// command's own code runs on the CLI's parsed arguments with a stub connector, in process: nothing is sent. The option checks and
/// <c>--help</c> run through the whole CLI, and stop before any connector is made.</summary>
[Collection("CLI console")]
public sealed partial class CliAutopilotTests
{
    /// <summary>Answers Find Clips with three clips of the fixture's lines and each clip plan with a plan for its span (a rewrite and music,
    /// which the CLI leaves pending).</summary>
    private sealed class Stub : ILlmConnector
    {
        private readonly object gate = new();
        internal List<LlmRequest> Requests { get; } = [];
        public ConnectorId Id => ConnectorId.Ollama;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("fixture", "Fixture", null, 256_000, ModelSource.Curated)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(256_000);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            lock (gate) Requests.Add(request);
            string reply;
            if (request.Feature == LlmFeature.ClipFinder)
                reply = new JsonObject { ["clips"] = new JsonArray(
                    Clip("Coffee", 7, 1, 3), Clip("Sleep wins", 9, 4, 6), Clip("Mornings", 8, 7, 9)) }.ToJsonString();
            else
            {
                var span = Span().Match(request.Instruction);
                var (start, end) = (int.Parse(span.Groups[1].Value), int.Parse(span.Groups[2].Value));
                // A rewrite of the clip's third to fifth words that keeps its bridge words and changes the middle one.
                var words = Word().Matches(request.CachedBlock ?? "").ToDictionary(match => int.Parse(match.Groups[1].Value), match => match.Groups[2].Value);
                var rewrite = $"{words[start + 2]} really {words[start + 4]}";
                reply = new JsonObject
                {
                    ["startWord"] = start, ["endWord"] = end, ["title"] = "Planned " + start, ["hook"] = "A hook", ["cuts"] = new JsonArray(), ["pauseCuts"] = new JsonArray(),
                    ["corrections"] = new JsonArray(), ["rewrites"] = new JsonArray(new JsonObject { ["startWord"] = start + 2, ["endWord"] = start + 4, ["text"] = rewrite, ["reason"] = "a stumble" }),
                    ["captionStyle"] = "vox-bold", ["captionFont"] = "Roboto", ["captionWeight"] = 900, ["captionCase"] = "upper", ["wordsPerCaption"] = 3, ["captionReason"] = "",
                    ["look"] = "original", ["lookReason"] = "", ["speed"] = 1, ["speedReason"] = "", ["lengthReason"] = "", ["tone"] = "none", ["toneSummary"] = "",
                    ["music"] = new JsonArray(new JsonObject { ["title"] = "Pulse", ["mood"] = "driven", ["prompt"] = "Instrumental, 120 BPM", ["reason"] = "pace", ["underVoiceDb"] = 18 }),
                    ["musicPick"] = 0, ["zooms"] = new JsonArray(), ["postText"] = "Post", ["score"] = start == 0 ? 6 : 8, ["verdict"] = "post", ["scoreReason"] = "",
                    ["questions"] = new JsonArray(), ["frames"] = new JsonObject { ["blur"] = new JsonArray(), ["cover"] = new JsonObject { ["id"] = "", ["reason"] = "" } }
                }.ToJsonString();
            }
            return Task.FromResult(new RawCompletion(reply, null, model, new StopKind.Complete(), null, null));
        }
        private static JsonObject Clip(string title, int score, int first, int last) =>
            new() { ["title"] = title, ["reason"] = title + " lands.", ["score"] = score, ["start_line"] = first, ["end_line"] = last };
    }

    [GeneratedRegex("from word (\\d+) to word (\\d+)")]
    private static partial Regex Span();
    [GeneratedRegex("(?<!after )\\[(\\d+)\\]([^\\s(]+)")]
    private static partial Regex Word();

    /// <summary>The whole CLI, with its stdout and stderr.</summary>
    private static async Task<(int Exit, string Output, string Errors)> RunAsync(params string[] arguments)
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(arguments, TestContext.Current.CancellationToken);
            return (exit, output.ToString(), errors.ToString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }

    /// <summary>The autopilot command's result fields on <paramref name="stub"/>, with its stderr.</summary>
    private static Task<(JsonObject Fields, string Errors)> AutopilotAsync(Stub stub, params string[] arguments) => AutopilotAsync(stub, null, arguments);

    /// <summary>The same with the frame sources <paramref name="frames"/> (null: what this build installs).</summary>
    private static async Task<(JsonObject Fields, string Errors)> AutopilotAsync(Stub stub, CliFrameSources? frames, params string[] arguments)
    {
        var parsed = CliApplication.Parse(["autopilot", .. arguments]);
        Assert.Empty(parsed.Errors);
        var previousError = Console.Error;
        using var errors = new StringWriter();
        try
        {
            Console.SetError(errors);
            var fields = await CliAutopilot.RunAsync(parsed, (_, _) => stub, TestContext.Current.CancellationToken, frameSources: frames);
            return (fields, errors.ToString());
        }
        finally { Console.SetError(previousError); }
    }

    private static string Project()
    {
        var folder = Directory.CreateTempSubdirectory("voxclip-cli-autopilot-").FullName;
        var path = Path.Combine(folder, "five-questions.voxclip");
        File.Copy(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "five-questions.voxclip"), path);
        return path;
    }

    [Fact]
    public async Task TheTopClipsArePlannedWithTheirMomentsAndEachIsListedInTheMacsShape()
    {
        var project = Project();
        try
        {
            var before = await File.ReadAllBytesAsync(project, TestContext.Current.CancellationToken);
            var stub = new Stub();
            var (result, errors) = await AutopilotAsync(stub, "--open", project, "--connector", "ollama", "--model", "fixture", "--count", "2", "--timings", "--json");
            // The CLI adds ok, command and version around these.
            Assert.Equal(["clips", "found", "model", "timings"], result.Select(pair => pair.Key).Order(StringComparer.Ordinal));
            Assert.Equal((3, "fixture"), (result["found"]!.GetValue<int>(), result["model"]!.GetValue<string>()));
            var clips = result["clips"]!.AsArray();
            Assert.Equal(2, clips.Count);
            foreach (var (clip, rank) in clips.Select((clip, index) => (clip!.AsObject(), index + 1)))
            {
                Assert.Equal(["clipId", "endWordId", "outputs", "pending", "rank", "score", "startWordId", "title", "verdict"], clip.Select(pair => pair.Key).Order(StringComparer.Ordinal));
                Assert.Equal(rank, clip["rank"]!.GetValue<int>());
                Assert.Equal(["rewrite", "music"], clip["pending"]!.AsArray().Select(item => item!.GetValue<string>()));
                Assert.Empty(clip["outputs"]!.AsArray());
                Assert.Matches("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", clip["clipId"]!.GetValue<string>());
            }
            // Best first by Find Clips' score: "Sleep wins" (9), then "Mornings" (8); each plan was told its rank, title and the other clip.
            var plans = stub.Requests.Where(request => request.Feature == LlmFeature.ClipAutopilot).ToArray();
            Assert.Equal(2, plans.Length);
            Assert.Contains(plans, request => request.Instruction.StartsWith("This clip is moment 1 of 2 picked from a longer video for a series: “Sleep wins”. Sleep wins lands.\nThe other clips of this series: “Mornings” at ", StringComparison.Ordinal));
            Assert.Contains(plans, request => request.Instruction.StartsWith("This clip is moment 2 of 2 picked from a longer video for a series: “Mornings”.", StringComparison.Ordinal));
            Assert.All(plans, request => Assert.Equal((Effort.XHigh, "clip-autopilot-series-clip"), (request.Effort!.Value, request.Tag)));
            Assert.All(plans, request => Assert.Empty(request.Images));
            // The timings: find, then plan and apply per clip, numbers only.
            var timings = result["timings"]!.AsObject();
            Assert.Equal(["firstClipSeconds", "stages", "totalSeconds"], timings.Select(pair => pair.Key).Order(StringComparer.Ordinal));
            var stages = timings["stages"]!.AsArray().Select(stage => (stage!["stage"]!.GetValue<string>(), stage["clip"]?.GetValue<int>())).ToArray();
            Assert.Equal(("find", (int?)null), stages[0]);
            foreach (var clip in new int?[] { 1, 2 })
            {
                Assert.Contains(("plan", clip), stages);
                Assert.Contains(("apply", clip), stages);
            }
            Assert.True(timings["firstClipSeconds"]!.GetValue<double>() <= timings["totalSeconds"]!.GetValue<double>());
            Assert.Equal(before, await File.ReadAllBytesAsync(project, TestContext.Current.CancellationToken));
            Assert.Contains("Finding clips…", errors, StringComparison.Ordinal);
            Assert.Contains("Found 3 clips. Planning the top 2…", errors, StringComparison.Ordinal);
        }
        finally { Directory.Delete(Path.GetDirectoryName(project)!, true); }
    }

    /// <summary>five-questions.voxclip with its media pointed at a stand-in file, so the frame pass has a source (the decoder is a stub).</summary>
    private static async Task<string> SourcedProjectAsync()
    {
        var ct = TestContext.Current.CancellationToken;
        var path = Project();
        var source = Path.Combine(Path.GetDirectoryName(path)!, "source.mp4");
        await File.WriteAllTextAsync(source, "stand-in media " + Guid.NewGuid().ToString("N"), ct);
        var project = Core.Domain.Shared.ProjectSerialization.Deserialize(await File.ReadAllTextAsync(path, ct));
        var key = await new Core.Services.Project.ProjectStore().ComputeContentKeyAsync(source, null, ct);
        project = project with { Media = new(project.Media.Source with { AbsolutePath = source, SizeBytes = new FileInfo(source).Length, ContentKey = key }) };
        await File.WriteAllTextAsync(path, Core.Domain.Shared.ProjectSerialization.Serialize(project), ct);
        return path;
    }

    /// <summary>With faces (stub models, W6) each plan carries its clip's frames, and each clip's JSON the Mac's <c>frames</c> and
    /// <c>picture</c>; this CLI reads no text, so it says so, finds no screen and caches nothing. The pass and the opening scans are timed.</summary>
    [Fact]
    public async Task WithFacesEachClipCarriesItsFramesAndThePictureDecisions()
    {
        var project = await SourcedProjectAsync();
        try
        {
            var stub = new Stub();
            var decoder = new Frames.StubFrameDecoder();
            var (result, errors) = await AutopilotAsync(stub, new CliFrameSources(new Frames.StubFrameFaces(), null, decoder),
                "--open", project, "--connector", "ollama", "--model", "fixture", "--count", "2", "--timings", "--json");
            Assert.Contains(CliAutopilotFrames.FacesOnlyLine, errors, StringComparison.Ordinal);
            Assert.NotEmpty(decoder.Reads);
            // Faces only: nothing is cached, since the App's cache would read these textless frames as frames without screens.
            var key = Core.Domain.Shared.ProjectSerialization.Deserialize(await File.ReadAllTextAsync(project, TestContext.Current.CancellationToken)).Media.Source.ContentKey;
            Assert.False(Directory.Exists(Path.Combine(Core.Services.Project.DataLocations.Resolve().Cache, key, "frames")), "nothing is cached for faces only");
            var plans = stub.Requests.Where(request => request.Feature == LlmFeature.ClipAutopilot).ToArray();
            Assert.Equal(2, plans.Length);
            Assert.All(plans, request => Assert.Contains(Core.Domain.Frames.FrameSheet.SummaryHeader, request.Instruction, StringComparison.Ordinal));
            Assert.All(plans, request => Assert.Empty(request.Images));
            foreach (var clip in result["clips"]!.AsArray().Select(item => item!.AsObject()))
            {
                Assert.Equal(["clipId", "endWordId", "frames", "outputs", "pending", "picture", "rank", "score", "startWordId", "title", "verdict"],
                    clip.Select(pair => pair.Key).Order(StringComparer.Ordinal));
                var frames = clip["frames"]!.AsObject();
                Assert.Equal(["blur", "cover", "imageTokens", "images", "sent"], frames.Select(pair => pair.Key).Order(StringComparer.Ordinal));
                Assert.True(frames["sent"]!.GetValue<int>() > 0);
                Assert.Equal((false, 0), (frames["images"]!.GetValue<bool>(), frames["imageTokens"]!.GetValue<int>()));
                Assert.Empty(frames["blur"]!.AsArray());
                var picture = clip["picture"]!.AsObject();
                Assert.Equal(["blur", "cover", "crop", "opening"], picture.Select(pair => pair.Key).Order(StringComparer.Ordinal));
                // A clear look already: the start stays. The crop follows the stub's face (centred across, the crop's full height).
                Assert.Equal("{\"shift\":0,\"reason\":null}", picture["opening"]!.ToJsonString());
                Assert.Equal("{\"aspect\":\"9:16\",\"faceFound\":true,\"center\":{\"x\":0.5,\"y\":0.5}}", picture["crop"]!.ToJsonString());
                Assert.Empty(picture["blur"]!.AsArray());
                // The reply named no listed cover: the plan's validator takes C1, the best measured one, as its fallback, so no reason is shown.
                Assert.Equal(("C1", false, (string?)null), (picture["cover"]!["id"]!.GetValue<string>(), picture["cover"]!["fallback"]!.GetValue<bool>(),
                    picture["cover"]!["reason"]?.GetValue<string>()));
                Assert.Equal(frames["cover"]!.GetValue<double>(), picture["cover"]!["time"]!.GetValue<double>());
            }
            var stages = result["timings"]!["stages"]!.AsArray().Select(stage => (stage!["stage"]!.GetValue<string>(), stage["clip"]?.GetValue<int>())).ToArray();
            Assert.Contains(("frames", (int?)null), stages);
            Assert.Contains(("opening", (int?)1), stages);
            Assert.Contains(("opening", (int?)2), stages);
        }
        finally { Directory.Delete(Path.GetDirectoryName(project)!, true); }
    }

    /// <summary>Without the face models nothing is looked at: no pass, no frames in any plan, no <c>frames</c> or <c>picture</c>.</summary>
    [Fact]
    public async Task WithoutFacesNoFrameIsReadAndThePlansAreUnchanged()
    {
        var project = await SourcedProjectAsync();
        try
        {
            var stub = new Stub();
            var decoder = new Frames.StubFrameDecoder();
            var (result, errors) = await AutopilotAsync(stub, new CliFrameSources(null, null, decoder),
                "--open", project, "--connector", "ollama", "--model", "fixture", "--count", "2", "--timings", "--json");
            Assert.Empty(decoder.Reads);
            Assert.DoesNotContain(CliAutopilotFrames.FacesOnlyLine, errors, StringComparison.Ordinal);
            Assert.All(stub.Requests, request => Assert.DoesNotContain(Core.Domain.Frames.FrameSheet.SummaryHeader, request.Instruction, StringComparison.Ordinal));
            Assert.All(result["clips"]!.AsArray(), clip => Assert.Equal(["clipId", "endWordId", "outputs", "pending", "rank", "score", "startWordId", "title", "verdict"],
                clip!.AsObject().Select(pair => pair.Key).Order(StringComparer.Ordinal)));
            Assert.DoesNotContain(result["timings"]!["stages"]!.AsArray(), stage => stage!["stage"]!.GetValue<string>() is "frames" or "opening");
        }
        finally { Directory.Delete(Path.GetDirectoryName(project)!, true); }
    }

    [Fact]
    public async Task WithoutJsonTimingsPrintsOnlyTheTimings()
    {
        var project = Project();
        try
        {
            var (fields, errors) = await AutopilotAsync(new Stub(), "--open", project, "--connector", "ollama", "--model", "fixture", "--count", "1", "--timings", "--quiet");
            var timings = JsonNode.Parse(CliAutopilot.HumanOutput(fields)!)!.AsObject();
            Assert.True(timings.ContainsKey("stages") && timings.ContainsKey("firstClipSeconds") && timings.ContainsKey("totalSeconds"));
            Assert.Equal("", errors);
            var (plain, _) = await AutopilotAsync(new Stub(), "--open", project, "--connector", "ollama", "--model", "fixture", "--count", "1", "--quiet");
            Assert.Null(CliAutopilot.HumanOutput(plain));
            Assert.False(plain.ContainsKey("timings"));
        }
        finally { Directory.Delete(Path.GetDirectoryName(project)!, true); }
    }

    [Theory]
    [InlineData("--count", "0")]
    [InlineData("--count", "13")]
    [InlineData("--count", "two")]
    [InlineData("--aspect", "4:3")]
    [InlineData("--preset", "custom")]
    [InlineData("--out-dir", "/nonexistent-voxclip-folder")]
    public async Task OptionsAreChecked(string option, string value)
    {
        var project = Project();
        try
        {
            var (exit, output, _) = await RunAsync("autopilot", "--open", project, "--connector", "ollama", "--model", "fixture", option, value, "--json");
            Assert.Equal(2, exit);
            Assert.Equal("usageError", JsonNode.Parse(output)!["error"]!["code"]!.GetValue<string>());
        }
        finally { Directory.Delete(Path.GetDirectoryName(project)!, true); }
    }

    [Fact]
    public async Task HelpNamesEveryOption()
    {
        var (exit, output, _) = await RunAsync("autopilot", "--help");
        Assert.Equal(0, exit);
        foreach (var option in new[] { "--open", "--connector", "--model", "--count", "--preset", "--transcript", "--out-dir", "--aspect", "--timings", "--json" })
            Assert.Contains(option, output, StringComparison.Ordinal);
    }
}

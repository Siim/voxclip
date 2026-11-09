using System.CommandLine;
using System.Globalization;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;

namespace VoxClip.Cli;

/// <summary><c>voxclip-cli autopilot</c>: ✦ Claude does it all, headless (design §6.7, ai.md §16.12), twin of the Mac command. Probe,
/// transcription, Find Clips, then the top clips planned at once (at most three in flight; Claude Code and Codex get two more lanes) and
/// each applied and, with <c>--out-dir</c>, exported as soon as its plan is ready. Paid steps never run here: rewrites in the creator's
/// voice and music are listed as pending. Where this PC has the face models, the whole video's frame pass runs beside Find Clips and each
/// clip carries the Mac's <c>frames</c> and <c>picture</c> (<see cref="CliAutopilotFrames"/>); without them plans go as text and no clip
/// carries either.</summary>
internal static class CliAutopilot
{
    /// <summary>The command's result fields. <paramref name="connector"/> builds a connector from its id and the environment's keys.</summary>
    internal static async Task<JsonObject> RunAsync(ParseResult arguments, Func<ConnectorId, IKeyProvider, ILlmConnector> connector, CancellationToken ct,
        ExportInputReader? openExport = null, ExportPreparer? prepareExport = null, CliFrameSources? frameSources = null)
    {
        var clock = new ClaudeModeClock();
        var input = Path.GetFullPath(CliOperations.Required(arguments, "--open"));
        var count = arguments.GetValue<string?>("--count") is { } text ? int.Parse(text, NumberStyles.None, CultureInfo.InvariantCulture) : 3;
        var aspect = arguments.GetValue<string?>("--aspect") ?? "9:16";
        var preset = Enum.Parse<ClipPreset>(arguments.GetValue<string?>("--preset") ?? "best", true);
        var quiet = arguments.GetValue<bool>("--quiet");
        var outDir = arguments.GetValue<string?>("--out-dir") is { } folder ? Path.GetFullPath(folder) : null;
        if (outDir is not null && !Directory.Exists(outDir)) throw new CliUsageException("--out-dir must be an existing folder");
        var id = CliOperations.Connector(CliOperations.Required(arguments, "--connector"));
        void Line(string line) { if (!quiet) Console.Error.WriteLine(line); }

        // The video and its words.
        Project project;
        string? source = null;
        if (Path.GetExtension(input).Equals(".voxclip", StringComparison.OrdinalIgnoreCase))
        {
            if (arguments.GetValue<string?>("--transcript") is not null) throw new CliUsageException("--transcript only applies when --open is a media file.");
            var opened = await ServicesMergeAdapter.Projects().LoadAsync(input, ct).ConfigureAwait(false);
            project = opened.Project;
            source = opened.ResolvedMediaPath;
            if (project.Transcript is null || outDir is not null)
            {
                if (source is null) throw new VoxClipException(VoxClipErrorCode.MediaMissing, $"Can't find {Path.GetFileName(project.Media.Source.AbsolutePath)}. Edits are saved.");
                if (project.Transcript is null)
                {
                    var media = await clock.TimedAsync(ClaudeModeStage.Probe, null, () => CliOperations.ProbeInputAsync(source, ct)).ConfigureAwait(false);
                    var transcribed = await Transcribe(media, arguments, clock, ct).ConfigureAwait(false);
                    project = project with { Transcript = transcribed.Transcript };
                }
            }
        }
        else
        {
            source = input;
            var media = await clock.TimedAsync(ClaudeModeStage.Probe, null, () => CliOperations.ProbeInputAsync(input, ct)).ConfigureAwait(false);
            project = arguments.GetValue<string?>("--transcript") is { } words
                ? CliOperations.NewProject(media, await CliOperations.ReadTranscriptAsync(words, ct).ConfigureAwait(false), string.Empty)
                : await Transcribe(media, arguments, clock, ct).ConfigureAwait(false);
        }
        if (project.Transcript is not { } transcript || !transcript.Words.Any(word => word.Kind == WordKind.Word))
            throw new VoxClipException(VoxClipErrorCode.NoSpeech, "This video has no speech to make clips from.");

        // The connectors: the chosen one, and two more lanes for a CLI, which runs one process per connector.
        var root = SharedResources.ResolveRoot();
        var keys = new EnvironmentKeyProvider();
        var redactor = await AiMergeAdapter.CreateRedactorAsync(keys, ct).ConfigureAwait(false);
        ILlmConnector Make(ConnectorId wanted) => connector(wanted, keys);
        var model = arguments.GetValue<string?>("--model") ?? await CliOperations.DefaultModelAsync(id, ct).ConfigureAwait(false);
        var main = Make(id);
        IReadOnlyList<ILlmConnector> lanes = id is ConnectorId.ClaudeCode or ConnectorId.Codex ? [Make(id), Make(id)] : [];
        var catalog = ServicesMergeAdapter.LlmModels();
        var runner = ServicesMergeAdapter.Runner(keys, redactor);
        // The whole video's frames, beside Find Clips (ADR-R48 part 2): only with the face models. Images go to a CLI or a local AI that
        // takes them; an API key gets the text summary, as on the Mac.
        var frames = CliAutopilotFrames.Pass(project, source, frameSources ?? CliFrameSources.Installed(), Line);
        frames?.Start(clock);
        // The pass and every opening scan stop however the command ends.
        using var passStop = new PassStop(frames);
        var images = id is ConnectorId.ClaudeCode or ConnectorId.Codex or ConnectorId.Ollama or ConnectorId.LmStudio && main.SupportsImages;

        // Find Clips.
        Line("Finding clips…");
        var finder = new ClipFinder(runner, wanted => wanted == id ? main : Make(wanted), root);
        var found = await clock.TimedAsync(ClaudeModeStage.Find, null, () => finder.FindClipsAsync(new(transcript.Words, project.Edits.Corrections,
            project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal), preset, null, transcript.Language, id, model), null, ct)).ConfigureAwait(false);
        // Best first by Find Clips' score; equal scores keep transcript order, as the app's Suggested list does.
        var ranked = found.Clips.Select((clip, order) => (Clip: clip, Order: order)).OrderByDescending(item => item.Clip.Score).ThenBy(item => item.Order)
            .Select(item => (item.Clip, First: IndexOf(transcript, item.Clip.StartWordId), Last: IndexOf(transcript, item.Clip.EndWordId)))
            .Where(item => item.First >= 0 && item.Last >= item.First).Take(count)
            .Select(item => (Span: new WordSpan(item.First, item.Last), Moment: ClipAutopilotMoment.Found(new(item.First, item.Last), item.Clip.Title, item.Clip.Reason, item.Clip.Score)))
            .ToArray();
        var fields = new JsonObject { ["clips"] = new JsonArray(), ["found"] = found.Clips.Count, ["model"] = found.Model };
        // Each exported clip is checked (ADR-R49) beside the next clips' work; --no-check skips it.
        var checks = outDir is not null && !arguments.GetValue<bool>("--no-check") ? new ClipChecks(transcript, clock, ct) : null;
        if (ranked.Length > 0)
        {
            Line($"Found {found.Clips.Count} clips. Planning the top {ranked.Length}…");
            var exports = new ClipExportRoute(openExport, prepareExport, checks);
            var (clips, plannedModel, applied) = await PlanAndApplyAsync(project, transcript, ranked, main, lanes, model, catalog, runner, root, clock, Line,
                async (made, clipId, rank) => outDir is null ? [] : await ExportClipAsync(made, clipId, rank, outDir, aspect, quiet, clock, exports, ct).ConfigureAwait(false), ct,
                frames, images, [CliAutopilotFrames.Shape(aspect)]).ConfigureAwait(false);
            // Each exported clip's self-check, which ran beside the other clips' work.
            if (checks is not null)
                foreach (var clip in clips.OfType<JsonObject>())
                    if (clip["error"] is null && await checks.ResultAsync(clip["rank"]!.GetValue<int>()).ConfigureAwait(false) is { } check) clip["check"] = check;
            fields["clips"] = clips;
            fields["model"] = plannedModel;
            project = applied;
        }
        if (outDir is not null)
        {
            var saved = Path.Combine(outDir, "autopilot.voxclip");
            await ServicesMergeAdapter.Projects().SaveAsync(project, saved, ct).ConfigureAwait(false);
            fields["project"] = saved;
        }
        if (arguments.GetValue<bool>("--timings")) fields["timings"] = clock.Json();
        return fields;
    }

    /// <summary>Stops a frame pass when disposed.</summary>
    private sealed class PassStop(Media.Frames.VideoFramePass? pass) : IDisposable
    {
        public void Dispose() => pass?.Cancel();
    }

    /// <summary>What the command prints without <c>--json</c>, as on the Mac: the progress lines are on stderr, and only the timings
    /// (with <c>--timings</c>) go to stdout.</summary>
    internal static string? HumanOutput(JsonObject fields) => fields["timings"]?.ToJsonString();

    private static Task<Project> Transcribe(MediaInfo media, ParseResult arguments, ClaudeModeClock clock, CancellationToken ct) =>
        CliOperations.TranscribeMediaAsync(media, arguments, arguments.GetValue<string?>("--transcription-model"), false, true, clock, ct);

    private static int IndexOf(Core.Domain.Transcript.Transcript transcript, string id)
    {
        for (var index = 0; index < transcript.Words.Count; index++) if (transcript.Words[index].Id == id) return index;
        return -1;
    }

    /// <summary>The top clips planned at once on <paramref name="main"/> and <paramref name="lanes"/>, each applied (and handed to
    /// <paramref name="export"/>) the moment its plan is ready, one at a time. Rewrites and music stay pending. A clip whose plan failed is
    /// listed with the reason; the others go on. With <paramref name="frames"/> each request takes its clip's frames from the pass
    /// (<paramref name="images"/> sends them as pictures, else the text summary) and its opening scan starts beside it; a clip whose request
    /// carried frames gets the picture decisions for <paramref name="shapes"/> after the plan's own edits, and its JSON <c>frames</c> and
    /// <c>picture</c>.</summary>
    internal static async Task<(JsonArray Clips, string Model, Project Project)> PlanAndApplyAsync(Project start, Core.Domain.Transcript.Transcript transcript,
        IReadOnlyList<(WordSpan Span, ClipAutopilotMoment Moment)> ranked, ILlmConnector main, IReadOnlyList<ILlmConnector> lanes, string model,
        LlmCatalog catalog, LlmRunner runner, string root, ClaudeModeClock clock, Action<string> line,
        Func<Project, string, int, Task<IReadOnlyList<string>>> export, CancellationToken ct,
        Media.Frames.VideoFramePass? frames = null, bool images = false, IReadOnlyList<ExportAspect>? shapes = null)
    {
        IReadOnlyList<ExportAspect> exported = shapes ?? [ExportAspect.Portrait];
        var sent = new CliAutopilotFrames.Sent();
        var source = frames is null ? null
            : CliAutopilotFrames.Source(frames, transcript.Words, start.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal), images, clock, sent);
        var project = start;
        var request = new ClipAutopilotRequest(transcript, project.Edits, new ClipAutopilotMode.Clips(ranked.Select(item => item.Span).ToArray()))
        { Moments = ranked.Select(item => item.Moment).ToArray() };
        var service = new ClipAutopilotService(runner, catalog, root);
        var fonts = ClipAutopilotFonts.Load(root);
        var ready = Channel.CreateUnbounded<(int Clip, ClipAutopilotPlan Plan)>();
        void Progress(ClipAutopilotProgress progress)
        {
            switch (progress)
            {
                case ClipAutopilotProgress.Planning planning: clock.Begin(ClaudeModeStage.Plan, planning.Clip + 1); break;
                case ClipAutopilotProgress.Ready plan: clock.End(ClaudeModeStage.Plan, plan.Clip + 1); ready.Writer.TryWrite((plan.Clip, plan.Plan)); break;
                case ClipAutopilotProgress.Failed failed: clock.End(ClaudeModeStage.Plan, failed.Clip + 1); break;
            }
        }
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(ct);
        async Task<ClipAutopilotResult> PlanAsync()
        {
            try { return await service.PlanAsync(request, main, model, lanes, Progress, stop.Token, source).ConfigureAwait(false); }
            finally { ready.Writer.TryComplete(); }
        }
        var planning = PlanAsync();
        var clips = new SortedDictionary<int, JsonNode>();
        try
        {
            await foreach (var (index, plan) in ready.Reader.ReadAllAsync(ct).ConfigureAwait(false))
            {
                if (clips.ContainsKey(index)) continue;
                ct.ThrowIfCancellationRequested();
                // The clip's opening scan ran beside its request; it is in hand before the clip is applied.
                if (sent.Of(index) is { } scanning) await scanning.Opening.ConfigureAwait(false);
                var clipId = Guid.NewGuid().ToString("D");
                var applyStart = clock.Elapsed;
                var (applied, pending) = ClipAutopilotMapping.Apply(ClipAutopilotMapping.Operations(plan, clipId, project, fonts), project);
                project = applied;
                // What the picture showed (ADR-R48): the same four decisions as Make it postable's rows.
                Core.Domain.Frames.ClipPicture.Decisions? picture = null;
                if (frames is not null && sent.Of(index) is { } shown)
                {
                    IReadOnlyList<Core.Domain.Frames.FrameObservation>? scan = null;
                    if (Core.Domain.Frames.ClipPicture.OpeningClip(project, clipId) is { } opening) scan = await frames.OpeningAsync(opening, ct).ConfigureAwait(false);
                    var inputs = new Core.Domain.Frames.ClipPicture.Inputs(shown.Frames, shown.Sentences, scan, exported, await frames.PitchBaselineAsync(ct).ConfigureAwait(false));
                    (project, picture) = Core.Domain.Frames.ClipPicture.Apply(plan, clipId, project, inputs);
                }
                clock.Record(ClaudeModeStage.Apply, index + 1, applyStart);
                line($"Clip {index + 1} ready: score {plan.Score}/10.");
                var outputs = await export(project, clipId, index + 1).ConfigureAwait(false);
                clips[index] = new JsonObject
                {
                    ["rank"] = index + 1, ["clipId"] = clipId, ["title"] = plan.Title, ["score"] = plan.Score, ["verdict"] = plan.Verdict.Name(),
                    ["startWordId"] = transcript.Words[plan.StartWord].Id, ["endWordId"] = transcript.Words[plan.EndWord].Id,
                    ["pending"] = new JsonArray(pending.Select(item => (JsonNode)JsonValue.Create(Decision(item.Decision))!).ToArray()),
                    ["outputs"] = new JsonArray(outputs.Select(path => (JsonNode)JsonValue.Create(path)!).ToArray())
                };
                if (sent.Of(index) is { } carried)
                {
                    clips[index]["frames"] = CliAutopilotFrames.FramesJson(carried.Frames, plan);
                    if (picture is not null) clips[index]["picture"] = CliAutopilotFrames.PictureJson(picture, carried.Sentences, exported);
                }
            }
        }
        catch
        {
            await stop.CancelAsync().ConfigureAwait(false);
            try { await planning.ConfigureAwait(false); } catch (Exception) { }
            throw;
        }
        var outcome = await planning.ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        for (var index = 0; index < ranked.Count; index++)
            if (!clips.ContainsKey(index)) clips[index] = new JsonObject { ["rank"] = index + 1, ["error"] = "planFailed" };
        return (new JsonArray(clips.Values.ToArray()), outcome.Model, project);
    }

    /// <summary>The decision's wire name, as the Mac's raw values: "rewrite", "music", "pauseCut".</summary>
    internal static string Decision(ClipAutopilotDecision decision)
    {
        var name = decision.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    /// <summary>How the autopilot's exports run: the export command's input reader and encoder (injected in tests), and the clip checks.</summary>
    private sealed record ClipExportRoute(ExportInputReader? OpenExport, ExportPreparer? PrepareExport, ClipChecks? Checks);

    /// <summary>One clip in the clip style's caption look, through the export command's own path. With checks, its self-check (ADR-R49)
    /// starts as soon as it is written and runs beside the next clips' work.</summary>
    private static async Task<IReadOnlyList<string>> ExportClipAsync(Project project, string clipId, int rank, string outDir, string aspect, bool quiet,
        ClaudeModeClock clock, ClipExportRoute route, CancellationToken ct)
    {
        var projectPath = Path.Combine(outDir, $"autopilot-{clipId}.voxclip");
        await ServicesMergeAdapter.Projects().SaveAsync(project, projectPath, ct).ConfigureAwait(false);
        try
        {
            var output = Path.Combine(outDir, $"clip-{rank.ToString(CultureInfo.InvariantCulture)}-{aspect.Replace(':', 'x')}.mp4");
            var parsed = CliApplication.Parse(["--open", projectPath, "--export", output, "--clip", clipId, "--aspect", aspect, .. quiet ? new[] { "--quiet" } : []]);
            var start = clock.Elapsed;
            var prepared = await CliOperations.PrepareExportAsync(parsed, ct, route.OpenExport).ConfigureAwait(false);
            await CliOperations.WriteExportAsync(prepared, parsed, ct, route.PrepareExport).ConfigureAwait(false);
            clock.Record(ClaudeModeStage.Export, rank, start);
            route.Checks?.Start(rank, output, prepared);
            return [output];
        }
        finally { try { File.Delete(projectPath); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}

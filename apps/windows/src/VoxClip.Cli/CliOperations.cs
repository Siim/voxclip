using System.CommandLine;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.Audio;
using VoxClip.Media.Captions;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;

namespace VoxClip.Cli;

internal delegate Task<(Project? Project, MediaInfo Media)> ExportInputReader(string path, CancellationToken ct);
internal delegate Task<ExportResult> ExportPreparer(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct);

internal static class CliOperations
{
    internal static async Task<JsonObject> ExecuteAsync(string command, ParseResult arguments, CancellationToken ct, ExportInputReader? openExport = null, ExportPreparer? prepareExport = null) => command switch
    {
        "probe" => await ProbeAsync(arguments, ct).ConfigureAwait(false),
        "encoders" => new() { ["encoders"] = Node((await new EncoderProbe().ProbeAsync(WindowsAdapterIdentity.Read(), null, ct).ConfigureAwait(false)).ToArray(), CliDataJson.Default.EncoderInfoArray) },
        "plan" => await PlanAsync(arguments, ct).ConfigureAwait(false),
        "export" => await ExportAsync(arguments, ct, openExport, prepareExport).ConfigureAwait(false),
        "transcribe" => await TranscribeAsync(arguments, ct).ConfigureAwait(false),
        "render-caption" => await CaptionRendering.RunAsync(arguments, ct).ConfigureAwait(false),
        "find-clips" => await FindClipsAsync(arguments, ct).ConfigureAwait(false),
        "llm-test" => await TestLlmAsync(arguments, ct).ConfigureAwait(false),
        _ when command.StartsWith("models ", StringComparison.Ordinal) => await ModelsAsync(command[7..], arguments, ct).ConfigureAwait(false),
        _ => throw new CliUsageException("Specify a models subcommand.")
    };

    private static async Task<JsonObject> ProbeAsync(ParseResult arguments, CancellationToken ct)
    {
        var media = await new FfmpegMediaProbe().ProbeAsync(arguments.GetValue<string>("media")!, ct).ConfigureAwait(false);
        return Node(media, CliDataJson.Default.MediaInfo)!.AsObject();
    }

    private static async Task<JsonObject> PlanAsync(ParseResult arguments, CancellationToken ct)
    {
        var project = await ReadProjectAsync(Required(arguments, "--open"), ct).ConfigureAwait(false);
        var plan = BuildPlan(project, false);
        return new()
        {
            ["sampleRate"] = plan.SampleRate, ["totalSamples"] = plan.TotalSamples, ["outputSamples"] = plan.OutputSamples,
            ["durationSeconds"] = plan.Duration, ["cuts"] = Ranges(plan.Cuts), ["kept"] = Ranges(plan.Kept)
        };
    }

    private static JsonArray Ranges(IReadOnlyList<MediaInterval> intervals)
    {
        var result = new JsonArray();
        foreach (var interval in intervals) result.Add(new JsonArray(JsonValue.Create(interval.StartSample), JsonValue.Create(interval.EndSample)));
        return result;
    }

    private static async Task<(Project? Project, MediaInfo Media)> OpenExportInputAsync(string path, CancellationToken ct)
    {
        if (!Path.GetExtension(path).Equals(".voxclip", StringComparison.OrdinalIgnoreCase))
            return (null, await ProbeInputAsync(path, ct).ConfigureAwait(false));
        var opened = await ServicesMergeAdapter.Projects().LoadAsync(path, ct).ConfigureAwait(false);
        if (opened.ResolvedMediaPath is null) throw new VoxClipException(VoxClipErrorCode.MediaMissing, $"Can't find {Path.GetFileName(opened.Project.Media.Source.AbsolutePath)}. Edits are saved.");
        return (opened.Project, await ProbeInputAsync(opened.ResolvedMediaPath, ct).ConfigureAwait(false));
    }

    private static async Task<JsonObject> ExportAsync(ParseResult arguments, CancellationToken ct, ExportInputReader? openExport, ExportPreparer? prepareExport)
    {
        var timer = Stopwatch.StartNew();
        var path = Required(arguments, "--open");
        var destination = Required(arguments, "--export");
        if (Path.GetExtension(path).Equals(".voxclip", StringComparison.OrdinalIgnoreCase) && arguments.GetValue<string?>("--transcript") is not null)
            throw new CliUsageException("--transcript only applies when --open is a media file.");
        var requestedStyle = arguments.GetValue<string?>("--style");
        var requestedCaptionStyle = requestedStyle is null or "off" ? null : CaptionRendering.LoadStyle(requestedStyle);
        ValidateOutputs(arguments, path, destination);
        if (!File.Exists(path)) throw new FileNotFoundException();
        destination = OutputSafety.Resolve(destination);
        var (openedProject, media) = await (openExport ?? OpenExportInputAsync)(path, ct).ConfigureAwait(false);
        var style = requestedStyle ?? openedProject?.Captions.StyleId ?? "off";
        var captionStyle = requestedCaptionStyle ?? (style == "off" ? null : CaptionRendering.LoadStyle(style));
        RequireAudioOutput(media.Audio is not null, arguments.GetValue<string?>("--audio-out"));
        RequireSrtOutput(style, arguments.GetValue<string?>("--srt"));
        ValidateOutputs(arguments, media.Path, destination, path);
        Project project;
        if (openedProject is not null) project = openedProject;
        else
        {
            if (arguments.GetValue<string?>("--clip") is not null) throw new CliUsageException("The requested clip does not exist.");
            if (arguments.GetValue<string?>("--transcript") is { } transcriptPath)
            {
                var transcript = await ReadTranscriptAsync(transcriptPath, ct).ConfigureAwait(false);
                project = NewProject(media, transcript, string.Empty);
            }
            else project = media.Audio is null ? NewProject(media, null, string.Empty) : await TranscribeMediaAsync(media, arguments, ct).ConfigureAwait(false);
        }
        ValidateRequestedScope(project.Edits.Clips, project.Transcript?.Words.Count ?? 0,
            arguments.GetValue<string?>("--clip"), arguments.GetValue<string?>("--range"));
        if (arguments.GetValue<bool>("--cut-fillers") || arguments.GetValue<bool>("--tighten-pauses") ||
            arguments.GetValue<string?>("--clip") is not null || arguments.GetValue<string?>("--range") is not null)
        {
            var state = ApplyExportEdits(State(project), arguments.GetValue<bool>("--cut-fillers"), arguments.GetValue<bool>("--tighten-pauses"),
                arguments.GetValue<string?>("--clip"), arguments.GetValue<string?>("--range"));
            project = EditingEngine.ApplyToProject(project, state);
        }
        var plan = BuildPlan(project, true);
        RequireExportable(plan, project.Transcript is null ? true : EditingEngine.Summarize(State(project)).CanExport);
        if (media.IsHdr && !ToneMapper.Available && !arguments.GetValue<bool>("--quiet"))
            Console.Error.WriteLine("This video is HDR. Colours are converted to standard range and may look flatter.");
        var aspect = arguments.GetValue<string?>("--aspect") is { } aspectText ? Aspect(aspectText) : project.Export.Aspect;
        var quality = arguments.GetValue<string?>("--quality") is { } qualityText ? qualityText == "high" ? ExportQuality.High : ExportQuality.Standard : project.Export.Quality;
        var size = ExportPresets.OutputSize(media.OrientedSize, aspect);
        var fps = ExportPresets.OutputFrameRate(arguments.GetValue<string?>("--fps") is { } fpsText
            ? double.Parse(fpsText, NumberStyles.Float, CultureInfo.InvariantCulture) : media.Video?.FrameRate ?? 30);
        var output = new OutputSpec(size, fps, ExportPresets.VideoBitrate(size, aspect, quality, fps));
        CaptionTrack? captions = null;
        if (captionStyle is not null)
        {
            captions = await CaptionEngine.BuildAsync(new(captionStyle, project.Captions with { StyleId = captionStyle.Id }, size,
                EditingEngine.CaptionWords(State(project), plan), project.Transcript?.Language, plan.Duration), ServicesMergeAdapter.GlyphShaper(), null, ct).ConfigureAwait(false);
        }
        var snapshot = new ComposeSnapshot(media, plan, style == "off" ? null : captions, output);
        var target = project.Edits.ActiveClipId is { } selectedClip ? (ExportTarget)new ExportTarget.Clip(selectedClip) : new ExportTarget.FullEdit();
        var audioPath = arguments.GetValue<string?>("--audio-out") is { } audioDestination ? OutputSafety.Resolve(audioDestination) : null;
        var srtPath = arguments.GetValue<string?>("--srt") is { } srtDestination ? OutputSafety.Resolve(srtDestination) : null;
        var destinations = new[] { destination, srtPath, audioPath }.OfType<string>().ToArray();
        ExportResult result;
        try
        {
            if (audioPath is not null) await EditedAudioReader.WriteWaveAsync(snapshot, audioPath, ct, false).ConfigureAwait(false);
            if (srtPath is not null)
            {
                using var stream = OutputSafety.CreatePartial(srtPath + ".partial");
                await using var writer = new StreamWriter(stream, new UTF8Encoding(false));
                await writer.WriteAsync(Exporter.Subtitles(captions).AsMemory(), ct).ConfigureAwait(false);
            }
            var prepare = prepareExport ?? new Exporter().PrepareAsync;
            result = await prepare(new(snapshot, target, aspect, quality, destination, null),
                Progress<ExportProgress>(arguments, value => (value.Phase, value.Fraction)), ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            OutputSafety.Publish(destinations, ct: ct);
            result = result with { Srt = srtPath };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw ExportErrors.Map(error, destination); }
        finally { foreach (var outputPath in destinations) OutputSafety.DeletePartial(outputPath + ".partial"); }
        var fields = Node(result, CliDataJson.Default.ExportResult)!.AsObject();
        fields["captionStyle"] = style; fields["aspect"] = AspectText(aspect); fields["elapsedSeconds"] = timer.Elapsed.TotalSeconds;
        return fields;
    }

    private static void ValidateOutputs(ParseResult arguments, string source, string destination, string? project = null)
    {
        var outputs = new[] { destination, arguments.GetValue<string?>("--audio-out"), arguments.GetValue<string?>("--srt") }.OfType<string>();
        var inputs = new[] { source, project, arguments.GetValue<string?>("--transcript") }.OfType<string>();
        try { OutputSafety.Validate(inputs, outputs); }
        catch (VoxClipException exception) { throw new CliUsageException(exception.Message); }
    }

    internal static void RequireExportable(EditPlan plan, bool canExport)
    {
        if (plan.OutputSamples <= 0 || !canExport)
            throw new VoxClipException(VoxClipErrorCode.EverythingCut, "Keep at least one word before exporting.");
    }

    internal static (int Start, int End) ParseRange(string range, int wordCount)
    {
        var bounds = range.Split(':');
        if (bounds.Length != 2 || !int.TryParse(bounds[0], NumberStyles.None, CultureInfo.InvariantCulture, out var first) ||
            !int.TryParse(bounds[1], NumberStyles.None, CultureInfo.InvariantCulture, out var last) || first > last || last >= wordCount)
            throw new CliUsageException("--range must be non-negative inclusive start:end indices inside the transcript, with start <= end.");
        return (first, last);
    }

    internal static void RequireAudioOutput(bool hasAudio, string? output)
    {
        if (!hasAudio && output is not null) throw new CliUsageException("This video has no audio track, so --audio-out has nothing to write.");
    }

    internal static void RequireSrtOutput(string style, string? output)
    {
        if (style == "off" && output is not null) throw new CliUsageException("Captions are off, so --srt has nothing to write. Choose a caption style with --style.");
    }

    internal static void ValidateRequestedScope(IReadOnlyList<ClipRange> clips, int wordCount, string? clip, string? range)
    {
        if (clip is not null && !clips.Any(item => item.Id == clip)) throw new CliUsageException("The requested clip does not exist.");
        if (range is not null) ParseRange(range, wordCount);
    }

    internal static EditState ApplyExportEdits(EditState state, bool cutFillers, bool tightenPauses, string? clip, string? range,
        Func<EditState, EditOperation, EditState>? reduce = null)
    {
        ValidateRequestedScope(state.Clips, state.Transcript.Words.Count, clip, range);
        reduce ??= EditingEngine.Reduce;
        if (clip is not null) state = reduce(state, new EditOperation.SetActiveClip(clip));
        if (range is not null)
        {
            var bounds = ParseRange(range, state.Transcript.Words.Count);
            var id = "cli-range";
            for (var suffix = 2; state.Clips.Any(item => item.Id == id); suffix++) id = "cli-range-" + suffix.ToString(CultureInfo.InvariantCulture);
            var selected = new ClipRange(id, state.Transcript.Words[bounds.Start].Id, state.Transcript.Words[bounds.End].Id, null, ClipOrigin.Manual, null, null, true);
            state = reduce(state, new EditOperation.AddClip(selected));
            state = reduce(state, new EditOperation.SetActiveClip(selected.Id));
        }
        if (cutFillers) state = reduce(state, new EditOperation.CutFillers());
        if (tightenPauses) state = reduce(state, new EditOperation.TightenPauses());
        return state;
    }

    private static async Task<JsonObject> TranscribeAsync(ParseResult arguments, CancellationToken ct)
    {
        var source = Required(arguments, "--open");
        var output = Required(arguments, "--out");
        try { OutputSafety.Validate([source], new[] { output, arguments.GetValue<string?>("--raw-out") }.OfType<string>()); }
        catch (VoxClipException exception) { throw new CliUsageException(exception.Message); }
        var media = await ProbeInputAsync(source, ct).ConfigureAwait(false);
        var project = await TranscribeMediaAsync(media, arguments, ct).ConfigureAwait(false);
        await ServicesMergeAdapter.Projects().SaveAsync(project, output, ct).ConfigureAwait(false);
        if (arguments.GetValue<string?>("--raw-out") is { } rawPath)
        {
            var cache = Path.Combine(DataLocations.Resolve().Cache, project.Media.Source.ContentKey, "transcripts");
            var rawKey = project.Transcript!.RawKey;
            if (rawKey.Length != 64 || rawKey.Any(character => !char.IsAsciiHexDigit(character)))
                throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "The transcription service returned an invalid raw cache key. Your video is still here.");
            var sources = Directory.Exists(cache) ? Directory.GetFiles(cache, "*-" + rawKey[..8] + ".json") : [];
            if (sources.Length != 1) throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "The transcription service did not return one matching raw cache entry. Your video is still here.");
            await AtomicWriteAsync(rawPath, await File.ReadAllTextAsync(sources[0], ct).ConfigureAwait(false), ct).ConfigureAwait(false);
        }
        return new() { ["output"] = Path.GetFullPath(output), ["words"] = project.Transcript!.Words.Count };
    }

    private static async Task<Project> TranscribeMediaAsync(MediaInfo media, ParseResult arguments, CancellationToken ct)
    {
        var engineText = arguments.GetValue<string?>("--engine") ?? "whisper";
        if (engineText == "apple") throw new VoxClipException(VoxClipErrorCode.SpeechAssetsUnavailable, "Apple Speech is available only in the native macOS CLI.");
        if (media.Audio is null) throw new VoxClipException(VoxClipErrorCode.NoAudioTrack, "This video has no audio track, so there is nothing to transcribe.");
        var engine = engineText == "elevenlabs" ? TranscriptEngine.Elevenlabs : TranscriptEngine.Whispercpp;
        var model = arguments.GetValue<string?>("--model");
        var language = arguments.GetValue<string?>("--language") ?? "auto";
        if (engine == TranscriptEngine.Elevenlabs)
        {
            if (string.IsNullOrWhiteSpace(await new EnvironmentKeyProvider().GetKeyAsync("elevenlabs-api-key", ct).ConfigureAwait(false)))
                throw new VoxClipException(VoxClipErrorCode.KeyMissing, "Set VOXCLIP_ELEVENLABS_API_KEY to use ElevenLabs.");
        }
        else
        {
            var installed = await ServicesMergeAdapter.ModelStorage().ListInstalledAsync(ct).ConfigureAwait(false);
            if (model is null)
            {
                if (installed.Count == 0) throw new VoxClipException(VoxClipErrorCode.ModelMissing, "Install a Whisper model with voxclip-cli models install before transcribing.");
                var catalog = await ServicesMergeAdapter.Models().GetModelsAsync(ct).ConfigureAwait(false);
                model = catalog.FirstOrDefault(item => item.Engine == engine && installed.Any(local => local.Id == item.Id && local.Verified) &&
                    (language == "auto" || item.Languages.Contains(language) || item.Languages.Contains("*")))?.Id;
            }
            if (model is null || !installed.Any(item => item.Id == model && item.Verified))
                throw new VoxClipException(VoxClipErrorCode.ModelMissing, "The selected Whisper model is not installed and verified.");
        }
        var key = await ServicesMergeAdapter.Projects().ComputeContentKeyAsync(media.Path, null, ct).ConfigureAwait(false);
        var extracted = await new FfmpegAudioExtractor().ExtractAsync(new(media, key, Path.Combine(DataLocations.Resolve().Cache, key)),
            Progress<MediaProgress>(arguments, value => (value.Phase, value.Fraction)), ct).ConfigureAwait(false);
        var plan = new TranscriptionPlan(engine, model, language == "auto" ? new LanguageChoice.Auto() : new LanguageChoice.Forced(language),
            new(arguments.GetValue<bool>("--diarize"), Dtw: !arguments.GetValue<bool>("--no-dtw")));
        var transcript = await ServicesMergeAdapter.TranscribeAsync(new(plan, extracted.Audio, key), extracted.Envelope,
            Progress<TranscriptionProgress>(arguments, value => (value.Stage.ToString(), value.Fraction)), ct).ConfigureAwait(false);
        return NewProject(media, transcript, key);
    }

    private static async Task<MediaInfo> ProbeInputAsync(string path, CancellationToken ct)
    {
        try { return await new FfmpegMediaProbe().ProbeAsync(path, ct).ConfigureAwait(false); }
        catch (VoxClipException exception) when (exception.Code == VoxClipErrorCode.DecodeFailed) { throw new CliInputException(exception); }
    }

    private static async Task<JsonObject> ModelsAsync(string operation, ParseResult arguments, CancellationToken ct)
    {
        var catalog = ServicesMergeAdapter.Models(); var store = ServicesMergeAdapter.ModelStorage();
        var id = operation == "list" ? null : arguments.GetValue<string>("id");
        switch (operation)
        {
            case "list":
                return new() { ["models"] = Node((await catalog.GetModelsAsync(ct).ConfigureAwait(false)).ToArray(), CliDataJson.Default.TranscriptionModelArray),
                    ["installed"] = Node((await store.ListInstalledAsync(ct).ConfigureAwait(false)).ToArray(), CliDataJson.Default.InstalledModelArray) };
            case "install": return new() { ["model"] = Node(await store.InstallAsync(id!, Progress<ModelDownloadProgress>(arguments,
                value => (value.Stage, value.TotalBytes is > 0 ? value.BytesReceived / (double)value.TotalBytes : null)), ct).ConfigureAwait(false), CliDataJson.Default.InstalledModel) };
            case "verify":
                if (!await store.VerifyAsync(id!, null, ct).ConfigureAwait(false)) throw new VoxClipException(VoxClipErrorCode.ModelChecksumMismatch, "The model did not match its checksum. Install it again.");
                return new() { ["id"] = id, ["verified"] = true };
            case "remove": await store.RemoveAsync(id!, ct).ConfigureAwait(false); return new() { ["id"] = id, ["removed"] = true };
            default: throw new CliUsageException("Unknown models subcommand.");
        }
    }

    private static async Task<JsonObject> FindClipsAsync(ParseResult arguments, CancellationToken ct)
    {
        var project = await ReadProjectAsync(Required(arguments, "--open"), ct).ConfigureAwait(false);
        if (project.Transcript is null) throw new VoxClipException(VoxClipErrorCode.NoSpeech, "This project has no transcript.");
        var connector = Connector(Required(arguments, "--connector"));
        var model = arguments.GetValue<string?>("--model") ?? await DefaultModelAsync(connector, ct).ConfigureAwait(false);
        var preset = Enum.Parse<ClipPreset>(Required(arguments, "--preset"), true);
        var finder = await AiMergeAdapter.CreateClipFinderAsync(ct).ConfigureAwait(false);
        var result = await finder.FindClipsAsync(new(project.Transcript.Words, project.Edits.Corrections,
            project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal), preset, arguments.GetValue<string?>("--instruction"), project.Transcript.Language,
            connector, model, !arguments.GetValue<bool>("--no-snap"), arguments.GetValue<bool>("--dry-run")),
            Progress<ClipFinderProgress>(arguments, value => (value.Stage, value.Fraction)), ct).ConfigureAwait(false);
        return AiMergeAdapter.ClipResult(result);
    }

    private static async Task<JsonObject> TestLlmAsync(ParseResult arguments, CancellationToken ct)
    {
        var connectorId = Connector(Required(arguments, "--connector"));
        var connector = ServicesMergeAdapter.Connector(connectorId);
        var model = arguments.GetValue<string?>("--model") ?? await DefaultModelAsync(connectorId, ct).ConfigureAwait(false);
        var catalog = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(SharedResources.ResolveRoot(), "catalog", "llm-providers.json"), ct).ConfigureAwait(false))!;
        var test = catalog["testRequest"] ?? throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "The LLM test request is missing from the catalogue.");
        var request = new LlmRequest(LlmFeature.Test, test["system"]!.GetValue<string>(), null,
            test["instruction"]!.GetValue<string>(), "voxclip_test", test["schema"]!.DeepClone().AsObject(), 2048, Effort.Low, TimeSpan.FromSeconds(120), null, "cli-test");
        var keyProvider = new EnvironmentKeyProvider();
        var runner = ServicesMergeAdapter.Runner(keyProvider, await AiMergeAdapter.CreateRedactorAsync(keyProvider, ct).ConfigureAwait(false));
        var timer = Stopwatch.StartNew();
        var result = await runner.RunAsync(request, connector, model, ct).ConfigureAwait(false);
        if (result.Object["ok"]?.GetValue<bool>() != true || result.Object["echo"]?.GetValue<string>().Trim().ToLowerInvariant() != "voxclip")
            throw new VoxClipException(VoxClipErrorCode.ProviderError, "The model answered, but not as expected.");
        return new() { ["model"] = result.Model, ["elapsedSeconds"] = timer.Elapsed.TotalSeconds, ["usedFallback"] = result.UsedFallback };
    }

    private static async Task<string> DefaultModelAsync(ConnectorId connector, CancellationToken ct) =>
        (await ServicesMergeAdapter.LlmModels().GetModelsAsync(connector, ct).ConfigureAwait(false)).FirstOrDefault()?.Id ??
        throw new VoxClipException(VoxClipErrorCode.ModelMissing, "Select a model with --model.");

    private static ConnectorId Connector(string name) => name switch
    {
        "anthropic" => ConnectorId.Anthropic, "openai" => ConnectorId.OpenAI, "xai" => ConnectorId.Xai, "gemini" => ConnectorId.Gemini,
        "ollama" => ConnectorId.Ollama, "lmstudio" => ConnectorId.LmStudio, "claude-code" => ConnectorId.ClaudeCode, "codex" => ConnectorId.Codex,
        _ => throw new CliUsageException("Unknown connector id or connector unsupported on Windows.")
    };

    internal static async Task<Project> ReadProjectAsync(string path, CancellationToken ct)
    {
        try { return ProjectSerialization.Deserialize(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false)); }
        catch (IOException exception) { throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "This project file can't be read: the file could not be opened.", exception); }
    }

    private static async Task<TranscriptModel> ReadTranscriptAsync(string path, CancellationToken ct)
    {
        try
        {
            var transcript = JsonSerializer.Deserialize(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false), CliDataJson.Default.Transcript) ?? throw new JsonException();
            if (transcript.Words is null || transcript.Engine is null || transcript.SchemaVersion != 1) throw new JsonException();
            var ids = new HashSet<string>(StringComparer.Ordinal); var previous = double.NegativeInfinity;
            foreach (var word in transcript.Words)
            {
                if (string.IsNullOrWhiteSpace(word.Id) || word.Text is null || !ids.Add(word.Id) || !double.IsFinite(word.Start) || !double.IsFinite(word.End) || word.Start < 0 || word.Start < previous || word.End <= word.Start || word.Timing == TimingSource.Estimated) throw new JsonException();
                previous = word.Start;
            }
            return transcript;
        }
        catch (Exception exception) when (exception is IOException or JsonException)
        { throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "This project file can't be read: the stored transcript is invalid.", exception); }
    }

    internal static EditPlan BuildPlan(Project project, bool activeClip)
    {
        VoiceLabProject.RequireLegacyRendering(project, activeClip && project.Edits.ActiveClipId is { } id ? VoiceLabOutputScope.Clip(id) : VoiceLabOutputScope.Full);
        var reference = project.Media.Source;
        var rate = reference.Audio?.SampleRate ?? 48_000;
        if (project.Edits.CutWordIds.Count == 0 && project.Edits.CutPauseIds.Count == 0 && (!activeClip || project.Edits.ActiveClipId is null))
        {
            var total = checked((long)Math.Floor(reference.DurationSeconds * rate + 0.5));
            return new(rate, total, [], total > 0 ? [new(0, total)] : [], total, []);
        }
        var state = State(project);
        if (!activeClip) state = state with { ActiveClipId = null };
        return EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, reference.DurationSeconds), reference.DurationSeconds, rate, state.PauseKeepSeconds);
    }

    private static EditState State(Project project)
        => EditingEngine.FromProject(project) ?? throw new VoxClipException(VoxClipErrorCode.NoSpeech, "This project has no transcript to edit.");

    internal static Project NewProject(MediaInfo media, TranscriptModel? transcript, string key)
    {
        var now = DateTimeOffset.UtcNow;
        var project = new Project("voxclip-project", 1, Guid.NewGuid().ToString("N"), now, now, new("voxclip-cli", CliApplication.Version, OperatingSystem.IsWindows() ? "windows" : "macos"),
            new(new(media.Path, null, new FileInfo(media.Path).Length, media.DurationSeconds, key, media.Video, media.Audio)), null,
            new(1.0, 0.15, [], [], new Dictionary<string, string>(StringComparer.Ordinal), [], null),
            new("off", JsonDocument.Parse("{}").RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()),
            new(ExportAspect.Source, ExportQuality.Standard, false, null), new(new Dictionary<string, string>()), new([]), new([]));
        return transcript is null ? project : ProjectStore.ReplaceTranscript(project, transcript);
    }

    internal static async Task AtomicWriteAsync(string path, string text, CancellationToken ct)
    {
        path = OutputSafety.Resolve(path);
        var temporary = path + ".partial";
        try
        {
            using (OutputSafety.CreatePartial(temporary)) { }
            await File.WriteAllTextAsync(temporary, text, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested(); OutputSafety.Publish([path]);
        }
        finally { File.Delete(temporary); }
    }

    internal static ExportAspect Aspect(string value) => value switch
    { "source" => ExportAspect.Source, "16:9" => ExportAspect.Landscape, "9:16" => ExportAspect.Portrait, "1:1" => ExportAspect.Square, _ => throw new CliUsageException("Invalid aspect.") };
    internal static string AspectText(ExportAspect value) => value switch
    { ExportAspect.Portrait => "9:16", ExportAspect.Landscape => "16:9", ExportAspect.Square => "1:1", _ => "source" };
    internal static string Required(ParseResult arguments, string option) => arguments.GetValue<string?>(option) ?? throw new CliUsageException("Missing " + option + ".");
    private static JsonNode? Node<T>(T value, JsonTypeInfo<T> metadata) => JsonSerializer.SerializeToNode(value, metadata);

    private static IProgress<T> Progress<T>(ParseResult arguments, Func<T, (string Phase, double? Fraction)> describe)
        => new CliProgress<T>(arguments.GetValue<bool>("--quiet"), describe);

    private sealed class CliProgress<T>(bool quiet, Func<T, (string Phase, double? Fraction)> describe) : IProgress<T>
    {
        private string? previous;
        private readonly Stopwatch timer = Stopwatch.StartNew();
        private double lastPercentage = -1;
        public void Report(T value)
        {
            if (quiet) return;
            var (phase, fraction) = describe(value);
            var now = timer.Elapsed.TotalSeconds;
            var changed = phase != previous;
            var suffix = string.Empty;
            if (fraction is { } number && now - lastPercentage >= 1)
            { suffix = string.Create(CultureInfo.InvariantCulture, $" {number:P0}"); lastPercentage = now; }
            if (!changed && suffix.Length == 0) return;
            previous = phase;
            Console.Error.WriteLine(phase + suffix);
        }
    }
}

internal sealed class CliUsageException(string message) : Exception(message);
internal sealed class CliInputException(VoxClipException failure) : Exception(failure.Message, failure)
{
    internal VoxClipException Failure { get; } = failure;
}
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, UseStringEnumConverter = true,
    RespectRequiredConstructorParameters = true, RespectNullableAnnotations = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow)]
[JsonSerializable(typeof(MediaInfo))]
[JsonSerializable(typeof(EncoderInfo[]))]
[JsonSerializable(typeof(ExportResult))]
[JsonSerializable(typeof(TranscriptModel))]
[JsonSerializable(typeof(TranscriptionModel[]))]
[JsonSerializable(typeof(InstalledModel[]))]
[JsonSerializable(typeof(InstalledModel))]
[JsonSerializable(typeof(CaptionWord[]))]
internal partial class CliDataJson : JsonSerializerContext;

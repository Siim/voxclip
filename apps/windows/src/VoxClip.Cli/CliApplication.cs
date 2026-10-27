using System.CommandLine;
using System.CommandLine.Help;
using System.CommandLine.Parsing;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Share;
namespace VoxClip.Cli;

internal static class CliApplication
{
    private static readonly Option<bool> Json = new("--json") { Description = "Print exactly one final JSON object.", Recursive = true };
    private static readonly Option<bool> Quiet = new("--quiet") { Description = "Suppress human progress on stderr.", Recursive = true };
    private static readonly Option<bool> RuntimeTerms = new("--runtime-terms") { Description = "Print the bundled Windows component terms and their SHA-256.", Recursive = true };
    private static readonly Option<string?> AcceptRuntimeTerms = new("--accept-runtime-terms") { Description = "Accept the displayed Windows component terms SHA-256 for this user.", Recursive = true };
    private static readonly Redactor BasicRedactor = new([], Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    private static readonly Lazy<Redactor> DiagnosticRedactor = new(ServicesMergeAdapter.DiagnosticRedactor);
    internal static string Version => Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown";

    internal static async Task<int> RunAsync(string[] args, CancellationToken ct, ExportInputReader? openExport = null, ExportPreparer? prepareExport = null,
        WindowsRuntimeAgreement? runtimeAgreement = null, Func<string, bool>? inputExists = null)
    {
        var root = BuildCommand(openExport, prepareExport, inputExists);
        var result = root.Parse(args);
        if (result.Errors.Count > 0)
        {
            foreach (var error in result.Errors) Console.Error.WriteLine(BasicRedactor.Redact(error.Message));
            if (result.GetValue(Json)) WriteJson(new(false, CommandName(result), null,
                new("usageError", BasicRedactor.Redact(result.Errors[0].Message)), Version));
            return 2;
        }
        var runtimeAgreementWork = false;
        var normalWorkAuthorized = false;
        int FailRun(string code, string message, int exitCode) => Fail(result, code, message, exitCode,
            redactor: normalWorkAuthorized ? DiagnosticRedactor.Value : BasicRedactor);
        try
        {
            if (result.GetValue(RuntimeTerms) || result.GetValue(AcceptRuntimeTerms) is not null)
            {
                runtimeAgreementWork = true;
                var agreement = runtimeAgreement ?? WindowsRuntimeAgreement.ForCurrentUser();
                var terms = agreement.LoadTerms();
                if (result.GetValue(RuntimeTerms))
                {
                    if (result.GetValue(Json)) WriteJson(new(true, "runtime-terms", terms.Sha256 + "\n" + terms.DisplayText, null, Version));
                    else Console.Out.WriteLine(terms.DisplayText + "\n\nSHA-256: " + terms.Sha256);
                    return 0;
                }
                agreement.Accept(terms, result.GetValue(AcceptRuntimeTerms)!);
                if (result.GetValue(Json)) WriteJson(new(true, "accept-runtime-terms", terms.Sha256, null, Version));
                else Console.Out.WriteLine("Windows component terms accepted for this user (" + terms.Sha256 + ").");
                return 0;
            }
            var informationalAction = result.Action is HelpAction ||
                root.Options.OfType<VersionOption>().Any(option => result.GetResult(option) is not null) ||
                result.CommandResult.Command.Name == "version";
            if ((OperatingSystem.IsWindows() || runtimeAgreement is not null) && !informationalAction)
            {
                runtimeAgreementWork = true;
                var agreement = runtimeAgreement ?? WindowsRuntimeAgreement.ForCurrentUser();
                var terms = agreement.LoadTerms();
                if (!agreement.IsAccepted(terms))
                    return FailRun("runtimeTermsRequired",
                        "Review the Windows component terms with `voxclip-cli --runtime-terms`, then run `voxclip-cli --accept-runtime-terms <SHA-256>`.", 7);
            }
            runtimeAgreementWork = false;
            normalWorkAuthorized = !informationalAction;
            // The App's launch check before any work: the shared root and its share-text rules.
            if (!informationalAction) SharePostText.Preflight();
            return await result.InvokeAsync(new InvocationConfiguration { EnableDefaultExceptionHandler = false, ProcessTerminationTimeout = null }, ct).ConfigureAwait(false);
        }
        catch (InvalidDataException exception) when (runtimeAgreementWork) { return FailRun("runtimeTermsUnavailable", exception.Message, 7); }
        catch (IOException) when (runtimeAgreementWork)
        { return FailRun("runtimeTermsUnavailable", "Could not read or save the Windows component terms. Check the installed files and user data permissions.", 7); }
        catch (UnauthorizedAccessException) when (runtimeAgreementWork)
        { return FailRun("runtimeTermsUnavailable", "Could not read or save the Windows component terms. Check the installed files and user data permissions.", 7); }
        catch (OperationCanceledException) { return FailRun("cancelled", string.Empty, 6); }
        catch (CliUsageException exception) { return FailRun("usageError", exception.Message, 2); }
        catch (CliInputException exception) { return FailRun(exception.Failure.WireCode, FailureMessage(exception.Failure), 3); }
        catch (Exception exception) when (AiMergeAdapter.IsGate(exception))
        {
            var gate = AiMergeAdapter.Gate(exception);
            return FailRun(gate.Code, gate.Message, gate.ExitCode);
        }
        catch (LlmException exception)
        {
            var mapped = new VoxClipException(exception.Error.Code, exception.Error.UserMessage);
            return FailRun(mapped.WireCode, mapped.Message, mapped.ExitCode);
        }
        catch (VoxClipException exception)
        {
            return FailRun(exception.WireCode, FailureMessage(exception), exception.ExitCode);
        }
        catch (VoxClip.Core.Domain.VoiceLab.VoiceLabProjectException exception)
        { return FailRun("exportFailed", exception.Code switch
            {
                VoxClip.Core.Domain.VoiceLab.VoiceLabProjectErrorCode.UnsupportedRendering or VoxClip.Core.Domain.VoiceLab.VoiceLabProjectErrorCode.NeedsVoiceLabUpgrade =>
                    "This Voice Lab project needs a reviewed v3 render recipe before export. Your video and edits are still here.",
                VoxClip.Core.Domain.VoiceLab.VoiceLabProjectErrorCode.VideoModeUnsupported =>
                    "This Voice Lab video timing or mode is not supported in this build. Your generated audio and edits are saved.",
                VoxClip.Core.Domain.VoiceLab.VoiceLabProjectErrorCode.UnsupportedAssetFormat =>
                    "This Windows build cannot read this generated audio format. Keep the paid file for a supported build.",
                VoxClip.Core.Domain.VoiceLab.VoiceLabProjectErrorCode.CleanAudioUnsupported =>
                    "This Voice Lab Clean audio edit cannot be rendered in this build. Your video and edits are saved.",
                _ => "This Voice Lab render recipe cannot be used here (" + exception.Code + "). Your generated audio and edits are saved."
            }, 5); }
        catch (VoxClip.Media.VoiceLab.VoiceLabAssetException exception)
        { return FailRun("exportFailed", exception.Message, 5); }
        catch (VoxClip.Media.VoiceLab.VoiceLabTempoException exception)
        { return FailRun("exportFailed", exception.Message, 5); }
        catch (JsonException) { return FailRun("projectUnreadable", "This project file can't be read: the input JSON is invalid.", 3); }
        catch (FileNotFoundException) { return FailRun("mediaMissing", "The input file cannot be found.", 3); }
        catch (DirectoryNotFoundException) { return FailRun("mediaMissing", "The input folder cannot be found.", 3); }
        catch (IOException) { return FailRun(result.CommandResult.Command == root ? "exportFailed" : "projectUnreadable", "The file could not be read or written.", result.CommandResult.Command == root ? 5 : 3); }
        catch (UnauthorizedAccessException) { return FailRun(result.CommandResult.Command == root ? "exportFailed" : "projectUnreadable", "Permission to access the file was denied.", result.CommandResult.Command == root ? 5 : 3); }
        catch (Exception) { return FailRun("unexpectedFailure", "The command could not be completed.", 1); }
    }

    internal static string FailureMessage(VoxClipException exception) => exception is MediaException { Code: VoxClipErrorCode.DecodeFailed }
        ? $"VoxClip couldn't decode this video: {exception.Message.TrimEnd('.')}. Your edits are saved." : exception.Message;

    private static RootCommand BuildCommand(ExportInputReader? openExport, ExportPreparer? prepareExport, Func<string, bool>? inputExists)
    {
        var root = new RootCommand("VoxClip headless media tool.");
        root.Options.Add(Json);
        root.Options.Add(Quiet);
        root.Options.Add(RuntimeTerms);
        root.Options.Add(AcceptRuntimeTerms);
        Add(root, "--open", "Project or media path.");
        Add(root, "--export", "Destination MP4 path.");
        Add(root, "--style", "Caption style id, or off.");
        Choice(root, "--aspect", "Output aspect.", "source", "16:9", "9:16", "1:1");
        Add(root, "--clip", "Stored clip id, mutually exclusive with --range.");
        Add(root, "--range", "Inclusive startWordIndex:endWordIndex.");
        Add(root, "--transcript", "Use a fixture word transcript.");
        Speech(root);
        Flag(root, "--cut-fillers", "Cut fillers before pause tightening.");
        Flag(root, "--tighten-pauses", "Cut long pauses after fillers.");
        Choice(root, "--quality", "Encoding quality.", "standard", "high");
        root.Options.Add(new Option<string?>("--fps") { Description = "Constant output frame rate." });
        Add(root, "--srt", "SRT sidecar path.");
        Add(root, "--audio-out", "Edited faded 32-bit float WAV test hook.");
        root.Validators.Add(validation =>
        {
            if (validation.GetValue(RuntimeTerms) && validation.GetValue(AcceptRuntimeTerms) is not null)
                validation.AddError("Use --runtime-terms or --accept-runtime-terms, not both.");
            if (validation.GetValue<string?>("--clip") is not null && validation.GetValue<string?>("--range") is not null)
                validation.AddError("--clip and --range are mutually exclusive.");
            if (validation.GetValue<string?>("--fps") is { } fps && !TryFps(fps, out _))
                validation.AddError("--fps must be greater than zero and at most 60");
            if (validation.GetValue<string?>("--range") is { } range)
            {
                var bounds = range.Split(':');
                if (bounds.Length != 2 || !int.TryParse(bounds[0], NumberStyles.None, CultureInfo.InvariantCulture, out var first) ||
                    !int.TryParse(bounds[1], NumberStyles.None, CultureInfo.InvariantCulture, out var last) || first > last)
                    validation.AddError("--range must be non-negative inclusive start:end indices, with start <= end.");
            }
        });
        Stub(root, "export", openExport, prepareExport);

        var probe = Command(root, "probe", "Print media probe facts.");
        probe.Arguments.Add(new Argument<string>("media"));
        Stub(probe, "probe", inputExists: inputExists);
        var transcribe = Command(root, "transcribe", "Transcribe and save a project.");
        Add(transcribe, "--open", "Source media.", true);
        Speech(transcribe, requireEngine: true);
        Add(transcribe, "--raw-out", "Raw engine-response cache copy.");
        Flag(transcribe, "--no-dtw", "Disable Whisper DTW alignment.");
        Flag(transcribe, "--diarize", "Request supported diarization.");
        Add(transcribe, "--out", "Destination .voxclip project.", true);
        Stub(transcribe, "transcribe");
        var models = Command(root, "models", "Manage transcription models.");
        Stub(models, "models");
        foreach (var operation in new[] { "list", "install", "verify", "remove" })
        {
            var command = Command(models, operation, "Model " + operation + ".");
            if (operation != "list") command.Arguments.Add(new Argument<string>("id"));
            Stub(command, "models " + operation);
        }
        var plan = Command(root, "plan", "Print the edit plan.");
        Add(plan, "--open", "Project path.", true);
        Stub(plan, "plan");
        var caption = Command(root, "render-caption", "Render one transparent caption golden case.");
        Add(caption, "--case", "Caption layout fixture; style is read from its input.");
        Add(caption, "--tiles", "Gallery preview-tiles.json, mutually exclusive with --case.");
        caption.Options.Add(new Option<string?>("--sample") { Description = "Render one zero-based case sample instead of all samples." });
        Add(caption, "--out", "PNG destination.", true);
        caption.Validators.Add(validation =>
        {
            var hasCase = validation.GetValue<string?>("--case") is not null;
            var hasTiles = validation.GetValue<string?>("--tiles") is not null;
            if (hasCase == hasTiles) validation.AddError("Specify exactly one of --case or --tiles.");
            if (validation.GetValue<string?>("--sample") is { } sample &&
                (!int.TryParse(sample, NumberStyles.None, CultureInfo.InvariantCulture, out _) || !hasCase))
                validation.AddError("--sample must be a non-negative index with --case.");
        });
        Stub(caption, "render-caption");
        var clips = Command(root, "find-clips", "Find clips without modifying the project.");
        Add(clips, "--open", "Project path.", true);
        Choice(clips, "--preset", "Prompt preset.", "best", "hooks", "topics", "quotes", "custom").Required = true;
        Add(clips, "--instruction", "Custom instruction (never logged).");
        Add(clips, "--connector", "Connector catalog id.", true);
        Add(clips, "--model", "Model id.");
        Flag(clips, "--no-snap", "Disable line-boundary snapping.");
        Flag(clips, "--dry-run", "Print rendered prompts without sending (not yet implemented).");
        Stub(clips, "find-clips");
        var test = Command(root, "llm-test", "Run the connector test.");
        Add(test, "--connector", "Connector catalog id.", true);
        Add(test, "--model", "Model id.");
        Stub(test, "llm-test");
        Stub(Command(root, "encoders", "Probe the Windows H264 encoder ladder."), "encoders");
        var version = Command(root, "version", "Print version and runtime platform.");
        version.SetAction(result =>
        {
            var platform = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux";
            var text = $"VoxClip {Version} ({platform}-{RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()})";
            if (result.GetValue(Json)) WriteJson(new(true, "version", text, null, Version));
            else Console.Out.WriteLine(text);
            return 0;
        });
        return root;
    }

    internal static bool TryFps(string value, out double fps)
        => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out fps) &&
            double.IsFinite(fps) && fps > 0 && fps <= 60;

    internal static int? Sample(ParseResult arguments)
    {
        var value = arguments.GetValue<string?>("--sample");
        return value is null ? null : int.Parse(value, NumberStyles.None, CultureInfo.InvariantCulture);
    }

    private static void Speech(Command command, bool requireEngine = false)
    {
        Choice(command, "--engine", "Transcription engine (apple is macOS-only).", "whisper", "apple", "elevenlabs").Required = requireEngine;
        Add(command, "--model", "Installed model catalog id.");
        Add(command, "--language", "auto or a BCP47 language code.");
    }
    private static Command Command(Command parent, string name, string description)
    {
        var child = new Command(name, description);
        parent.Subcommands.Add(child);
        return child;
    }
    private static void Add(Command command, string name, string description, bool required = false)
        => command.Options.Add(new Option<string?>(name) { Description = description, Required = required });
    private static void Flag(Command command, string name, string description)
        => command.Options.Add(new Option<bool>(name) { Description = description });
    private static Option<string?> Choice(Command command, string name, string description, params string[] choices)
    {
        var option = new Option<string?>(name) { Description = description };
        option.AcceptOnlyFromAmong(choices);
        command.Options.Add(option);
        return option;
    }
    private static void Stub(Command command, string name, ExportInputReader? openExport = null, ExportPreparer? prepareExport = null,
        Func<string, bool>? inputExists = null) => command.SetAction(async (result, ct) =>
    {
        ct.ThrowIfCancellationRequested();
        if (name == "export" && (result.GetValue<string?>("--open") is null || result.GetValue<string?>("--export") is null))
            return Fail(result, "usageError", "Export requires --open and --export.", 2, name);
        var path = name == "probe" ? result.GetValue<string>("media") : result.GetValue<string?>("--open");
        if (name != "export" && path is not null && !(inputExists ?? File.Exists)(path))
            return Fail(result, "mediaMissing", "The input file cannot be found.", 3, name);
        var fields = await CliOperations.ExecuteAsync(name, result, ct, openExport, prepareExport).ConfigureAwait(false);
        fields["ok"] = true; fields["command"] = name; fields["version"] = Version;
        if (result.GetValue(Json)) Console.Out.WriteLine(fields.ToJsonString());
        else if (name == "export")
        {
            Console.Out.WriteLine(fields["output"]?.GetValue<string>());
            Console.Out.WriteLine("encoder: " + fields["encoder"]?.GetValue<string>());
        }
        else Console.Out.WriteLine(fields["output"]?.GetValue<string>() ?? fields.ToJsonString());
        return 0;
    });
    private static int Fail(ParseResult result, string code, string message, int exitCode, string? command = null, Redactor? redactor = null)
    {
        var scrubber = redactor ?? DiagnosticRedactor.Value;
        if (result.GetValue(Json)) WriteJson(new(false, command ?? CommandName(result), null, new(code, scrubber.Redact(message)), Version));
        else if (message.Length != 0) Console.Error.WriteLine(scrubber.Redact(code + ": " + message));
        return exitCode;
    }
    private static void WriteJson(CliEnvelope value) => Console.Out.Write(JsonSerializer.Serialize(value, CliJsonContext.Default.CliEnvelope) + "\n");
    private static string CommandName(ParseResult result) => result.CommandResult.Parent is null ? "export" :
        result.CommandResult.Parent is CommandResult parent && parent.Command.Name == "models" ? "models " + result.CommandResult.Command.Name : result.CommandResult.Command.Name;
}
internal sealed record CliError(string Code, string Message);
internal sealed record CliEnvelope(bool Ok, string Command,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Output,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] CliError? Error, string Version);
[JsonSourceGenerationOptions(NewLine = JsonFormatting.NewLine, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(CliEnvelope))]
internal partial class CliJsonContext : JsonSerializerContext;

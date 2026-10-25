using System.CommandLine;
using System.CommandLine.Parsing;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Cli;

internal static class CliApplication
{
    private static readonly Option<bool> Json = new("--json") { Description = "Print exactly one final JSON object.", Recursive = true };
    private static readonly Option<bool> Quiet = new("--quiet") { Description = "Suppress human progress on stderr.", Recursive = true };
    private static readonly Redactor DiagnosticRedactor = new(
        new[] { "ELEVENLABS_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY", "GEMINI_API_KEY" }
            .Select(Environment.GetEnvironmentVariable).OfType<string>(),
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    private static string Version => Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown";

    internal static async Task<int> RunAsync(string[] args, CancellationToken ct)
    {
        var root = BuildCommand();
        var result = root.Parse(args);
        if (result.Errors.Count > 0)
        {
            foreach (var error in result.Errors) Console.Error.WriteLine(DiagnosticRedactor.Redact(error.Message));
            if (result.GetValue(Json)) WriteJson(new(false, result.CommandResult.Command.Name, null, new("usageError", "Invalid command line."), Version));
            return 2;
        }
        try { return await result.InvokeAsync(cancellationToken: ct).ConfigureAwait(false); }
        catch (OperationCanceledException) { return Fail(result, "cancelled", string.Empty, 6); }
        catch (VoxClipException exception) { return Fail(result, exception.WireCode, exception.Message, exception.ExitCode); }
        catch (Exception) { return Fail(result, "unexpectedFailure", "The command could not be completed.", 1); }
    }

    private static RootCommand BuildCommand()
    {
        var root = new RootCommand("VoxClip headless media tool. Unfinished operations return notImplemented (exit 1).");
        root.Options.Add(Json);
        root.Options.Add(Quiet);
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
        root.Options.Add(new Option<double?>("--fps") { Description = "Constant output frame rate." });
        Add(root, "--srt", "SRT sidecar path.");
        Add(root, "--audio-out", "Edited faded 32-bit float WAV test hook.");
        root.Validators.Add(validation =>
        {
            if (validation.GetValue<string?>("--clip") is not null && validation.GetValue<string?>("--range") is not null)
                validation.AddError("--clip and --range are mutually exclusive.");
            if (validation.GetValue<double?>("--fps") is { } fps && (!double.IsFinite(fps) || fps <= 0))
                validation.AddError("--fps must be finite and positive.");
            if (validation.GetValue<string?>("--range") is { } range)
            {
                var bounds = range.Split(':');
                if (bounds.Length != 2 || !int.TryParse(bounds[0], NumberStyles.None, CultureInfo.InvariantCulture, out var first) ||
                    !int.TryParse(bounds[1], NumberStyles.None, CultureInfo.InvariantCulture, out var last) || first > last)
                    validation.AddError("--range must be non-negative inclusive start:end indices, with start <= end.");
            }
        });
        Stub(root, "export");

        var probe = Command(root, "probe", "Print media probe facts.");
        probe.Arguments.Add(new Argument<string>("media"));
        Stub(probe, "probe");
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
        caption.Options.Add(new Option<int?>("--sample") { Description = "Render one zero-based case sample instead of all samples." });
        Add(caption, "--out", "PNG destination.", true);
        caption.Validators.Add(validation =>
        {
            var hasCase = validation.GetValue<string?>("--case") is not null;
            var hasTiles = validation.GetValue<string?>("--tiles") is not null;
            if (hasCase == hasTiles) validation.AddError("Specify exactly one of --case or --tiles.");
            if (validation.GetValue<int?>("--sample") is { } sample && (sample < 0 || !hasCase))
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
        Stub(Command(root, "encoders", "Probe the hardware H264 encoder ladder."), "encoders");
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
    private static void Stub(Command command, string name) => command.SetAction((result, ct) =>
    {
        ct.ThrowIfCancellationRequested();
        if (name == "export" && (result.GetValue<string?>("--open") is null || result.GetValue<string?>("--export") is null))
            return Task.FromResult(Fail(result, "usageError", "Export requires --open and --export.", 2, name));
        var path = name == "probe" ? result.GetValue<string>("media") : result.GetValue<string?>("--open");
        if (path is not null && !File.Exists(path))
            return Task.FromResult(Fail(result, "mediaMissing", "The input file cannot be found.", 3, name));
        return Task.FromResult(Fail(result, "notImplemented", "win-media", 1, name));
    });
    private static int Fail(ParseResult result, string code, string message, int exitCode, string? command = null)
    {
        if (result.GetValue(Json)) WriteJson(new(false, command ?? result.CommandResult.Command.Name, null, new(code, message), Version));
        else if (message.Length != 0) Console.Error.WriteLine(DiagnosticRedactor.Redact(code + ": " + message));
        return exitCode;
    }
    private static void WriteJson(CliEnvelope value) => Console.Out.Write(JsonSerializer.Serialize(value, CliJsonContext.Default.CliEnvelope) + "\n");
}
internal sealed record CliError(string Code, string Message);
internal sealed record CliEnvelope(bool Ok, string Command,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Output,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] CliError? Error, string Version);
[JsonSourceGenerationOptions(NewLine = JsonFormatting.NewLine, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(CliEnvelope))]
internal partial class CliJsonContext : JsonSerializerContext;

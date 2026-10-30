using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Process;

namespace VoxClip.Core.Services.LLM;

internal sealed class CliLlmAdapter(ConnectorId id, LlmCatalog catalog, IProcessRunner processes, IRedactor redactor, Action<string>? onDiagnostic, string? pathOverride)
{
    private static readonly SemaphoreSlim ClaudeGate = new(1, 1);
    private static readonly SemaphoreSlim CodexGate = new(1, 1);
    private static readonly SemaphoreSlim PathGate = new(1, 1);
    private static string? loginPath;
    private readonly JsonObject provider = catalog.Provider(id);
    private readonly JsonObject settings = catalog.Provider(id)["cli"]!.AsObject();
    private Detection? detected;
    private IReadOnlyList<LlmModel>? cachedModels;
    private readonly Dictionary<string, HashSet<string>> efforts = new(StringComparer.Ordinal);
    private string Label => provider["label"]!.GetValue<string>();
    internal bool IsApiKeyAuth { get; private set; }
    internal string? AuthMethod { get; private set; }
    internal CliDetectionInfo? DetectionInfo => detected is null ? null : new(detected.Path, detected.Version, AuthMethod, IsApiKeyAuth);
    internal DateTimeOffset? ModelsFetchedAt { get; private set; }
    internal string? LastRefreshError { get; private set; }
    internal void SetRedactor(IRedactor value) => redactor = value;
    private sealed record Detection(string Path, string Executable, IReadOnlyList<string> Prefix, string Stamp, string Version, string Help, HashSet<string> Features);
    private sealed class CliTooOldException(string version, string[] missing) : Exception
    {
        internal ConnectorStatus.CliTooOld Status { get; } = new(version, missing);
    }

    internal async Task<ConnectorStatus> StatusAsync(CancellationToken ct)
    {
        if (provider["enabled"]?.GetValue<bool>() != true) return new ConnectorStatus.Unavailable($"{Label} is not enabled.");
        try
        {
            var detection = await DetectAsync(ct).ConfigureAwait(false);
            if (detection is null) return new ConnectorStatus.CliMissing();
            var authSettings = settings["detect"]!["auth"]!;
            var result = await CommandAsync(detection, Strings(authSettings["args"]), null, catalog.Timeout("cliDetect"), ct).ConfigureAwait(false);
            CheckOutput(result);
            AuthMethod = null;
            IsApiKeyAuth = false;
            var authText = result.StandardOutput + "\n" + result.StandardError;
            if (result.ExitCode == authSettings["signedOutExitCode"]!.GetValue<int>() ||
                authSettings["signedOutText"]?.GetValue<string>() is { Length: > 0 } signedOutText && authText.Contains(signedOutText, StringComparison.OrdinalIgnoreCase))
                return new ConnectorStatus.CliSignedOut();
            if (id == ConnectorId.ClaudeCode)
            {
                var auth = LlmOutput.Envelope(result.StandardOutput) as JsonObject;
                if (auth?["loggedIn"] is not JsonValue loggedInValue || !loggedInValue.TryGetValue<bool>(out var loggedIn)) throw ProbeFailure();
                if (!loggedIn) return new ConnectorStatus.CliSignedOut();
                if (result.ExitCode != 0) throw ProbeFailure();
                AuthMethod = Text(auth?["authMethod"]);
                IsApiKeyAuth = AuthMethod?.Contains("api", StringComparison.OrdinalIgnoreCase) == true;
                return new ConnectorStatus.Ready();
            }
            if (result.ExitCode != 0) throw ProbeFailure();
            AuthMethod = authSettings["apiKeyText"]?.GetValue<string>() is { Length: > 0 } apiKeyText &&
                authText.Contains(apiKeyText, StringComparison.OrdinalIgnoreCase) ? "apiKey" :
                authText.Contains("ChatGPT", StringComparison.OrdinalIgnoreCase) ? "chatgpt" : throw ProbeFailure();
            IsApiKeyAuth = AuthMethod == "apiKey";
            return new ConnectorStatus.Ready();
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw Failure(LlmErrorKind.Cancelled, "", LlmFeature.Test); }
        catch (CliTooOldException exception) { return exception.Status; }
        catch (LlmException exception) when (exception.Error.Kind == LlmErrorKind.Cancelled && ct.IsCancellationRequested) { throw; }
        catch (Exception) { return StatusFailure(ProbeFailure()); }
    }

    private static ConnectorStatus.Unavailable StatusFailure(LlmException failure) =>
        new(failure.Error.UserMessage.Replace(" Your edits are saved.", "", StringComparison.Ordinal));
    private LlmException ProbeFailure() => Failure(LlmErrorKind.CliFailed, "", LlmFeature.Test, "The CLI could not be started or its output could not be read.");
    private void CheckOutput(ProcessResult result)
    {
        if (result.OutputTruncated) throw ProbeFailure();
    }

    private static bool Supports(string help, string flag) => Regex.IsMatch(help, "(?<![a-zA-Z0-9_-])" + Regex.Escape(flag) + "(?![a-zA-Z0-9_-])", RegexOptions.CultureInvariant);
    private static string[] Strings(JsonNode? node) => node!.AsArray().Select(item => item!.GetValue<string>()).ToArray();

    private async Task<Detection?> DetectAsync(CancellationToken ct)
    {
        var path = await LocateAsync(ct).ConfigureAwait(false);
        if (path is null) return null;
        var file = new FileInfo(path);
        var stamp = path + ":" + file.Length.ToString(CultureInfo.InvariantCulture) + ":" + file.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture);
        if (detected?.Stamp == stamp) return detected;
        var executable = path;
        IReadOnlyList<string> prefix = [];
        if (OperatingSystem.IsWindows() && Path.GetExtension(path).Equals(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            var relativeScript = id == ConnectorId.ClaudeCode ? new[] { "node_modules", "@anthropic-ai", "claude-code", "cli.js" } : new[] { "node_modules", "@openai", "codex", "bin", "codex.js" };
            var script = Path.Combine(new[] { Path.GetDirectoryName(path)! }.Concat(relativeScript).ToArray());
            if (!File.Exists(script)) script = Environment.ExpandEnvironmentVariables(settings["npmShimScript"]!.GetValue<string>());
            if (!File.Exists(script)) return null;
            var node = Path.Combine(Path.GetDirectoryName(path)!, "node.exe");
            if (!File.Exists(node))
            {
                var found = await RawCommandAsync(Path.Combine(Environment.SystemDirectory, "where.exe"), new[] { "node" }, ct).ConfigureAwait(false);
                node = found.StandardOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.Trim()).FirstOrDefault(candidate => Path.IsPathFullyQualified(candidate) && Path.GetExtension(candidate).Equals(".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(candidate)) ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "node.exe");
            }
            if (!File.Exists(node)) return null;
            executable = node; prefix = new[] { script };
        }
        var provisional = new Detection(path, executable, prefix, stamp, "unknown", "", new(StringComparer.Ordinal));
        var version = await CommandAsync(provisional, Strings(settings["detect"]!["version"]!["args"]), null, catalog.Timeout("cliDetect"), ct).ConfigureAwait(false);
        CheckOutput(version);
        var match = Regex.Match(version.StandardOutput.Trim(), settings["detect"]!["version"]!["regex"]!.GetValue<string>(), RegexOptions.CultureInvariant);
        if (version.ExitCode != 0 || !match.Success) throw new CliTooOldException("unknown", ["version"]);
        var help = await CommandAsync(provisional, Strings(settings["detect"]!["help"]!["args"]), null, catalog.Timeout("cliDetect"), ct).ConfigureAwait(false);
        CheckOutput(help);
        var helpText = help.StandardOutput + "\n" + help.StandardError;
        var missing = settings["detect"]!["help"]!["requiredFlags"]!.AsArray().Select(flag => flag!.GetValue<string>()).Where(flag => !Supports(helpText, flag)).ToArray();
        if (help.ExitCode != 0 || missing.Length > 0) throw new CliTooOldException(match.Groups[1].Value, missing.Length > 0 ? missing : ["help"]);
        var features = new HashSet<string>(StringComparer.Ordinal);
        if (id == ConnectorId.Codex)
        {
            var listed = await CommandAsync(provisional, Strings(settings["detect"]!["features"]!["args"]), null, catalog.Timeout("cliDetect"), ct).ConfigureAwait(false);
            CheckOutput(listed);
            if (listed.ExitCode != 0) throw new CliTooOldException(match.Groups[1].Value, ["features list"]);
            foreach (var line in listed.StandardOutput.Split('\n'))
            {
                var feature = Regex.Match(line.Trim(), settings["detect"]!["features"]!["lineRegex"]!.GetValue<string>(), RegexOptions.CultureInvariant);
                if (feature.Success && feature.Groups[2].Value.Trim() != "removed") features.Add(feature.Groups[1].Value);
            }
        }
        return detected = provisional with { Version = match.Groups[1].Value, Help = helpText, Features = features };
    }

    private async Task<string?> LocateAsync(CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(pathOverride) && File.Exists(pathOverride)) return Candidate(pathOverride);
        var platform = OperatingSystem.IsWindows() ? "windows" : "macos";
        foreach (var value in Strings(settings["searchPaths"]![platform]))
        {
            var path = Expand(value);
            if (Candidate(path) is { } candidate) return candidate;
        }
        var lookup = Strings(settings["shellLookup"]![platform]);
        var result = await RawCommandAsync(OperatingSystem.IsWindows() ? Path.Combine(Environment.SystemDirectory, "where.exe") : lookup[0], lookup.Skip(1).ToArray(), ct).ConfigureAwait(false);
        foreach (var line in result.StandardOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var path = line.Trim();
            if (OperatingSystem.IsWindows() && !new[] { ".exe", ".cmd" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) continue;
            if (Candidate(path) is { } candidate) return candidate;
        }
        return null;
    }
    private static string? Candidate(string path)
    {
        if (!Path.IsPathFullyQualified(path) || !File.Exists(path)) return null;
        if (!OperatingSystem.IsWindows()) return path;
        var extension = Path.GetExtension(path);
        if (extension.Equals(".exe", StringComparison.OrdinalIgnoreCase) || extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase)) return path;
        return extension.Length == 0 && File.Exists(path + ".cmd") ? path + ".cmd" : null;
    }
    private static string Expand(string value) => value.StartsWith("~/", StringComparison.Ordinal) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), value[2..]) : Environment.ExpandEnvironmentVariables(value);

    private async Task<IReadOnlyDictionary<string, string?>?> EnvironmentAsync(CancellationToken ct)
    {
        if (!OperatingSystem.IsMacOS()) return null;
        await PathGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (loginPath is null)
            {
                using var workspace = new CliWorkspace(onDiagnostic);
                var result = await processes.RunAsync(new("/bin/zsh", new[] { "-lc", "printf %s \"$PATH\"" }, workspace.Cwd, null, catalog.Timeout("cliDetect")), null, ct).ConfigureAwait(false);
                if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StandardOutput)) throw new IOException("Could not resolve the login-shell PATH.");
                loginPath = result.StandardOutput.Trim();
            }
            return new Dictionary<string, string?> { ["PATH"] = loginPath };
        }
        finally { PathGate.Release(); }
    }

    private async Task<ProcessResult> RawCommandAsync(string executable, IReadOnlyList<string> args, CancellationToken ct)
    {
        using var workspace = new CliWorkspace(onDiagnostic);
        return await processes.RunAsync(new(executable, args, workspace.Cwd, null, catalog.Timeout("cliDetect"), await EnvironmentAsync(ct).ConfigureAwait(false)), null, ct).ConfigureAwait(false);
    }
    private async Task<ProcessResult> CommandAsync(Detection detection, IReadOnlyList<string> args, string? input, TimeSpan timeout, CancellationToken ct)
    {
        using var workspace = new CliWorkspace(onDiagnostic);
        return await processes.RunAsync(new(detection.Executable, detection.Prefix.Concat(args).ToArray(), workspace.Cwd, input, timeout, await EnvironmentAsync(ct).ConfigureAwait(false)), null, ct).ConfigureAwait(false);
    }

    internal async Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
    {
        var gate = id == ConnectorId.ClaudeCode ? ClaudeGate : CodexGate;
        try { await gate.WaitAsync(ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw Failure(LlmErrorKind.Cancelled, model, request.Feature); }
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        var attempted = false;
        var outcome = "failed";
        RawCompletion? completion = null;
        try
        {
            var status = await StatusAsync(ct).ConfigureAwait(false);
            if (status is not ConnectorStatus.Ready) throw Failure(status switch { ConnectorStatus.CliSignedOut => LlmErrorKind.CliSignedOut, ConnectorStatus.CliTooOld => LlmErrorKind.CliTooOld, ConnectorStatus.CliMissing => LlmErrorKind.CliMissing, _ => LlmErrorKind.Unavailable }, model, request.Feature,
                status is ConnectorStatus.CliTooOld old ? old.Version : status is ConnectorStatus.Unavailable unavailable ? unavailable.Reason : status is ConnectorStatus.CliMissing ? settings["installHint"]?.GetValue<string>() : null);
            var detection = detected!;
            using var workspace = new CliWorkspace(onDiagnostic);
            var schemaFile = Path.Combine(workspace.Io, "schema.json");
            var outputFile = Path.Combine(workspace.Io, "last.json");
            var args = new List<string>();
            if (id == ConnectorId.ClaudeCode)
            {
                args.AddRange(new[] { "-p", "--output-format", "json", "--json-schema", request.Schema.ToJsonString(LlmRuntime.CompactJson), "--system-prompt", request.System, "--tools", "", "--no-session-persistence" });
                if (model != "default") args.AddRange(new[] { "--model", model });
                if (request.Feature != LlmFeature.VoiceRewrite && catalog.Fallback(id, model) is { } fallback && Supports(detection.Help, "--fallback-model")) args.AddRange(new[] { "--fallback-model", fallback });
                if (request.Effort is not null && Supports(detection.Help, "--effort")) args.AddRange(new[] { "--effort", request.Effort.Value.ToString().ToLowerInvariant() });
                args.Add("--safe-mode");
                foreach (var optional in new[] { "--strict-mcp-config", "--disable-slash-commands" }) if (Supports(detection.Help, optional)) args.Add(optional);
            }
            else
            {
                await File.WriteAllTextAsync(schemaFile, request.Schema.ToJsonString(LlmRuntime.CompactJson) + "\n", new UTF8Encoding(false), ct).ConfigureAwait(false);
                args.AddRange(new[] { "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config" });
                if (Supports(detection.Help, "--ignore-rules")) args.Add("--ignore-rules");
                args.AddRange(new[] { "--sandbox", "read-only", "--cd", workspace.Cwd });
                if (model != "default") args.AddRange(new[] { "--model", model });
                var effort = request.Effort?.ToString().ToLowerInvariant();
                if (effort is not null && (model == "default" || efforts.GetValueOrDefault(model)?.Contains(effort) == true)) args.AddRange(new[] { "-c", "model_reasoning_effort=" + Toml(effort) });
                args.AddRange(new[] { "-c", "web_search=\"disabled\"", "-c", "approval_policy=\"never\"", "-c", "mcp_servers={}", "-c", "developer_instructions=" + Toml(request.System) });
                foreach (var feature in Strings(settings["disableFeatures"]).Where(detection.Features.Contains)) args.AddRange(new[] { "--disable", feature });
                args.AddRange(new[] { "--output-schema", schemaFile, "--output-last-message", outputFile, "-" });
            }
            attempted = true;
            stopwatch.Restart();
            var result = await processes.RunAsync(new(detection.Executable, detection.Prefix.Concat(args).ToArray(), workspace.Cwd,
                LlmConnector.UserContent(request), request.Timeout, await EnvironmentAsync(ct).ConfigureAwait(false)), null, ct).ConfigureAwait(false);
            outcome = result.ExitCode.ToString(CultureInfo.InvariantCulture);
            if (result.OutputTruncated) throw Failure(LlmErrorKind.CliFailed, model, request.Feature, "CLI output exceeded the 16 MB limit.");
            if ((result.StandardOutput + result.StandardError).Contains("unknown option", StringComparison.OrdinalIgnoreCase)) detected = null;
            completion = id == ConnectorId.ClaudeCode ? ParseClaude(result, request, model) : await ParseCodexAsync(result, outputFile, request, model, ct).ConfigureAwait(false);
            return completion;
        }
        catch (TimeoutException) { outcome = "timeout"; throw Failure(LlmErrorKind.Timeout, model, request.Feature); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { outcome = "cancelled"; throw Failure(LlmErrorKind.Cancelled, model, request.Feature); }
        catch (IOException) { throw Failure(LlmErrorKind.CliFailed, model, request.Feature, "The CLI could not be started or its output could not be read."); }
        finally
        {
            if (attempted) WriteDiagnostic($"llm connector={LlmCatalog.WireId(id)} model={completion?.Model ?? model} feature={LlmCatalog.FeatureId(request.Feature)} tag=\"{request.Tag}\" attempt=1 status={outcome} ms={(long)stopwatch.Elapsed.TotalMilliseconds} in={completion?.Usage?.Input} out={completion?.Usage?.Output} cacheRead={completion?.Usage?.CacheRead} cacheWrite={completion?.Usage?.CacheWrite} requestId={completion?.RequestId}");
            gate.Release();
        }
    }

    private RawCompletion ParseClaude(ProcessResult result, LlmRequest request, string model)
    {
        var root = LlmOutput.Envelope(result.StandardOutput) as JsonObject;
        if (root?["type"] is not JsonValue typeValue || !typeValue.TryGetValue<string>(out var type) || type != "result" ||
            root["is_error"] is not JsonValue errorValue || !errorValue.TryGetValue<bool>(out var isError))
            throw Failure(LlmErrorKind.CliFailed, model, request.Feature, FirstLine(result.StandardError));
        var message = root["result"] is JsonValue resultValue && resultValue.TryGetValue<string>(out var resultText) ? resultText : FirstLine(result.StandardError);
        if (isError || result.ExitCode != 0)
            throw Classify(message, model, request.Feature, Count(root, "api_error_status"));
        var answering = (root["modelUsage"] as JsonObject)?.OrderByDescending(pair => Count(pair.Value, "outputTokens") ?? Count(pair.Value, "output_tokens") ?? 0)
            .ThenBy(pair => System.Text.Encoding.UTF8.GetBytes(pair.Key), Utf8KeyComparer.Instance).FirstOrDefault().Key ?? model;
        var usage = root["usage"];
        // ai.md §6.8: the stop reason, before the reply is read.
        var stopReason = root["stop_reason"] is JsonValue stopValue && stopValue.TryGetValue<string>(out var stopText) ? stopText : null;
        StopKind stop = stopReason switch { "max_tokens" => new StopKind.Truncated(), "refusal" => new StopKind.Refused(null), _ => new StopKind.Complete() };
        return new(message, root["structured_output"] is JsonObject structured ? structured.DeepClone() : null, answering, stop,
            new(Count(usage, "input_tokens"), Count(usage, "output_tokens"), Count(usage, "cache_read_input_tokens"), Count(usage, "cache_creation_input_tokens")), null);
    }

    private async Task<RawCompletion> ParseCodexAsync(ProcessResult result, string outputFile, LlmRequest request, string model, CancellationToken ct)
    {
        JsonObject? completed = null;
        string? message = null;
        string? failed = null;
        var sawFailure = false;
        string? lastAgent = null;
        foreach (var line in result.StandardOutput.Split('\n'))
        {
            if (LlmOutput.Envelope(line) is not JsonObject item) continue;
            switch (Text(item["type"]))
            {
                case "turn.completed": completed = item; break;
                case "turn.failed":
                    sawFailure = true;
                    failed = Text((item["error"] as JsonObject)?["message"]);
                    break;
                case "error":
                    var error = Text(item["message"]);
                    if (error is not null && !error.StartsWith("Reconnecting...", StringComparison.Ordinal)) message = error;
                    break;
                case "item.completed":
                    if (item["item"] is JsonObject agent && Text(agent["type"]) == "agent_message") lastAgent = Text(agent["text"]);
                    break;
            }
        }
        if (result.ExitCode != 0 || completed is null || sawFailure) throw Classify(failed ?? message ?? FirstLine(result.StandardError), model, request.Feature);
        if (File.Exists(outputFile) && new FileInfo(outputFile).Length > 16 * 1024 * 1024) throw Failure(LlmErrorKind.CliFailed, model, request.Feature, "CLI output exceeded the 16 MB limit.");
        var text = File.Exists(outputFile) ? await File.ReadAllTextAsync(outputFile, ct).ConfigureAwait(false) : null;
        if (string.IsNullOrWhiteSpace(text)) text = lastAgent;
        var usage = completed["usage"];
        return new(text, null, model, new StopKind.Complete(), new(Count(usage, "input_tokens"), Count(usage, "output_tokens"), Count(usage, "cached_input_tokens"), null), null);
    }

    internal async Task<IReadOnlyList<LlmModel>> ModelsAsync(bool refresh, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (provider["enabled"]?.GetValue<bool>() != true) throw Failure(LlmErrorKind.Unavailable, "", LlmFeature.Test, $"{Label} is not enabled.");
        if (id == ConnectorId.ClaudeCode || !refresh) return cachedModels ?? catalog.Models(id);
        try
        {
            var detection = await DetectAsync(ct).ConfigureAwait(false);
            if (detection is null) throw Failure(LlmErrorKind.CliMissing, "", LlmFeature.Test, settings["installHint"]?.GetValue<string>());
            using var workspace = new CliWorkspace(onDiagnostic);
            var sequence = settings["modelListViaAppServer"]!["sequence"]!.DeepClone().AsArray();
            sequence[0]!["params"]!["clientInfo"]!["version"] = LlmRuntime.Version;
            var command = new ProcessRequest(detection.Executable, detection.Prefix.Concat(Strings(settings["modelListViaAppServer"]!["args"])).ToArray(), workspace.Cwd,
                string.Join("\n", sequence.Select(item => item!.ToJsonString())) + "\n", catalog.Timeout("modelList"), await EnvironmentAsync(ct).ConfigureAwait(false));
            var result = processes is IAppServerRunner rpc ? await rpc.RunAppServerAsync(command, ct).ConfigureAwait(false) : await processes.RunAsync(command, null, ct).ConfigureAwait(false);
            foreach (var line in result.StandardOutput.Split('\n'))
            {
                var response = LlmOutput.Envelope(line);
                if (Count(response, "id") != 2) continue;
                if ((response?["result"] as JsonObject)?["data"] is not JsonArray data)
                    throw new IOException("The app server returned no model list.");
                var models = new List<LlmModel> { new("default", "CLI default", null, null, ModelSource.Curated) };
                foreach (var item in data)
                {
                    if (item is not JsonObject entry || entry["hidden"] is JsonValue hidden && hidden.TryGetValue<bool>(out var isHidden) && isHidden ||
                        Text(entry["id"]) is not { } model) continue;
                    efforts[model] = (entry["supportedReasoningEfforts"] as JsonArray ?? []).Select(effort => Text((effort as JsonObject)?["reasoningEffort"]))
                        .OfType<string>().ToHashSet(StringComparer.Ordinal);
                    models.Add(new(model, Text(entry["displayName"]) ?? model, null, null, ModelSource.Discovered));
                }
                LastRefreshError = null;
                ModelsFetchedAt = DateTimeOffset.UtcNow;
                return cachedModels = models;
            }
            throw new IOException("The app server returned no model list.");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw Failure(LlmErrorKind.Cancelled, "", LlmFeature.Test); }
        catch (LlmException exception) when (exception.Error.Kind == LlmErrorKind.Cancelled && ct.IsCancellationRequested) { throw; }
        catch (CliTooOldException exception)
        { LastRefreshError = "Couldn't refresh: " + Failure(LlmErrorKind.CliTooOld, "", LlmFeature.Test, exception.Status.Version).Message; }
        catch (Exception exception)
        { LastRefreshError = "Couldn't refresh: " + (exception is LlmException failure ? failure.Message : ProbeFailure().Message); }
        return cachedModels ?? catalog.Models(id);
    }

    private void WriteDiagnostic(string message)
    {
        if (onDiagnostic is null) return;
        try { onDiagnostic(redactor.Redact(message)); }
        catch (Exception) { }
    }

    internal static string Toml(string value)
    {
        var builder = new StringBuilder("\"");
        foreach (var rune in value.EnumerateRunes())
            builder.Append(rune.Value switch
            {
                0x5c => "\\\\", 0x22 => "\\\"", 8 => "\\b", 9 => "\\t", 10 => "\\n", 12 => "\\f", 13 => "\\r",
                < 0x20 or 0x7f => "\\u" + rune.Value.ToString("X4", CultureInfo.InvariantCulture), _ => rune.ToString()
            });
        return builder.Append('"').ToString();
    }
    private sealed class Utf8KeyComparer : IComparer<byte[]>
    {
        internal static readonly Utf8KeyComparer Instance = new();
        public int Compare(byte[]? left, byte[]? right) => left.AsSpan().SequenceCompareTo(right);
    }
    private static string? Text(JsonNode? node) => node is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? text : null;
    private static long? Count(JsonNode? node, string key) => node is JsonObject objectValue ? LlmOutput.CliInteger(objectValue[key]) : null;
    private static string FirstLine(string value) => value.Split('\n').Select(EditingAlgorithms.JsTrim).FirstOrDefault(line => line.Length != 0) ?? "The CLI exited without a result.";
    private LlmException Classify(string message, string model, LlmFeature feature, long? status = null)
    {
        bool Matches(string list) => (settings[list] as JsonArray ?? []).Any(marker => message.Contains(marker!.GetValue<string>(), StringComparison.OrdinalIgnoreCase));
        if (Matches("authErrorMarkers") || id == ConnectorId.ClaudeCode && status is 401 or 403)
            return Failure(LlmErrorKind.CliSignedOut, model, feature, message);
        if (Matches("limitMarkers") || id == ConnectorId.ClaudeCode && status == 429)
            return Failure(LlmErrorKind.PlanLimit, model, feature, message);
        if (id == ConnectorId.ClaudeCode)
        {
            var claudeKind = Matches("overloadMarkers") || status == 529 ? LlmErrorKind.Overloaded :
                message.Contains("prompt is too long", StringComparison.OrdinalIgnoreCase) ? LlmErrorKind.ContextTooLong : LlmErrorKind.CliFailed;
            return Failure(claudeKind, model, feature, message);
        }
        var kind = Matches("overloadMarkers") ? LlmErrorKind.Overloaded :
            Matches("modelErrorMarkers") ? LlmErrorKind.ModelNotFound :
            message.Contains("context", StringComparison.OrdinalIgnoreCase) && (message.Contains("length", StringComparison.OrdinalIgnoreCase) || message.Contains("window", StringComparison.OrdinalIgnoreCase)) ? LlmErrorKind.ContextTooLong : LlmErrorKind.CliFailed;
        return Failure(kind, model, feature, message);
    }
    private LlmException Failure(LlmErrorKind kind, string model, LlmFeature feature, string? detail = null) => LlmErrors.Create(kind, Label, model, feature, detail: detail, redactor: redactor);
}

internal sealed class CliWorkspace : IDisposable
{
    private readonly Action<string>? onDiagnostic;
    private readonly string root;
    internal string Cwd { get; }
    internal string Io { get; }
    internal CliWorkspace(Action<string>? onDiagnostic)
    {
        this.onDiagnostic = onDiagnostic;
        root = Path.Combine(Path.GetTempPath(), "VoxClip", "cli", Guid.NewGuid().ToString("N"));
        Cwd = Path.Combine(root, "cwd"); Io = Path.Combine(root, "io");
        if (OperatingSystem.IsWindows()) { Directory.CreateDirectory(Cwd); Directory.CreateDirectory(Io); }
        else { Directory.CreateDirectory(root, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); Directory.CreateDirectory(Cwd, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); Directory.CreateDirectory(Io, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); }
    }
    public void Dispose()
    {
        try { if (Directory.EnumerateFileSystemEntries(Cwd).Any()) Warn("warning cli-wrote-files"); Directory.Delete(root, true); }
        catch (IOException) { Warn("warning cli-temp-cleanup-failed"); }
        catch (UnauthorizedAccessException) { Warn("warning cli-temp-cleanup-failed"); }
    }
    private void Warn(string message)
    {
        try { onDiagnostic?.Invoke(message); }
        catch (Exception) { }
    }
}

using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Process;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.Captions;
using VoxClip.Media.Speech;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;

namespace VoxClip.Cli;

internal static class AiMergeAdapter
{
    internal static async Task<ClipFinder> CreateClipFinderAsync(CancellationToken ct)
    {
        var keys = new EnvironmentKeyProvider();
        var redactor = await CreateRedactorAsync(keys, ct).ConfigureAwait(false);
        // TODO(merge): W7 ClipFinder(LlmRunner, Func<ConnectorId, ILlmConnector>, string sharedRoot).
        return MergeApi.Construct<ClipFinder>([ServicesMergeAdapter.Runner(keys, redactor),
            (Func<ConnectorId, ILlmConnector>)(id => ServicesMergeAdapter.Connector(id, keys)), SharedResources.ResolveRoot()]);
    }

    internal static async Task<IRedactor> CreateRedactorAsync(IKeyProvider provider, CancellationToken ct)
    {
        var keys = new List<string>();
        foreach (var account in new[] { "elevenlabs-api-key", "llm-api-key-anthropic", "llm-api-key-openai", "llm-api-key-xai", "llm-api-key-gemini" })
            if (await provider.GetKeyAsync(account, ct).ConfigureAwait(false) is { } key) keys.Add(key);
        return new Redactor(keys, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    }

    internal static bool IsGate(Exception exception) => exception.GetType().FullName == "VoxClip.Core.Services.LLM.ClipFinderGateException";

    internal static (string Code, string Message, int ExitCode) Gate(Exception exception)
    {
        // TODO(merge): catch ClipFinderGateException directly and read Kind/UserMessage once win-ai is merged.
        var type = exception.GetType();
        return Gate(type.GetProperty("Kind")?.GetValue(exception)?.ToString(),
            type.GetProperty("UserMessage")?.GetValue(exception) as string ?? exception.Message);
    }

    internal static (string Code, string Message, int ExitCode) Gate(string? kind, string message) => kind switch
    {
        "NoWords" => ("noWords", message, 3),
        "NeedInstructions" => ("needInstructions", message, 2),
        _ => throw new InvalidOperationException("Unknown clip-finder gate.")
    };

    internal static JsonObject ClipResult(AiResult result)
    {
        return System.Text.Json.JsonSerializer.SerializeToNode(result, ProjectJsonContext.Default.AiResult)!.AsObject();
    }
}

internal static class ServicesMergeAdapter
{
    private static readonly HttpClient Http = new();
    internal static ProjectStore Projects() => new();
    // TODO(merge): W5 ModelCatalog(sharedRoot), ModelStore(IModelCatalog, DataLocations, HttpClient).
    internal static ModelCatalog Models() => MergeApi.Construct<ModelCatalog>([SharedResources.ResolveRoot()]);
    internal static ModelStore ModelStorage() => MergeApi.Construct<ModelStore>([Models(), DataLocations.Resolve(), Http]);
    // TODO(merge): W7 LlmCatalog.Load(sharedRoot), never the parameterless unavailable placeholder.
    internal static LlmCatalog LlmModels() => MergeApi.Invoke<LlmCatalog>(typeof(LlmCatalog).GetMethod("Load", [typeof(string)]), null, [SharedResources.ResolveRoot()]);
    internal static LlmConnector Connector(ConnectorId id, IKeyProvider? keys = null)
        => MergeApi.Construct<LlmConnector>([id, keys ?? new EnvironmentKeyProvider(), new ProcessRunner(), LlmModels(), Http]);
    internal static LlmRunner Runner(IKeyProvider keys, IRedactor redactor) => new(keys, LlmModels(), redactor);
    internal static IGlyphShaper GlyphShaper() => new HarfBuzzGlyphShaper(SharedResources.ResolveRoot());
    internal static ICaptionRasterizer Rasterizer() => new SkiaCaptionRasterizer(SharedResources.ResolveRoot());
    internal static Redactor DiagnosticRedactor() => new(
        new[] { "VOXCLIP_ELEVENLABS_API_KEY", "VOXCLIP_ANTHROPIC_API_KEY", "VOXCLIP_OPENAI_API_KEY", "VOXCLIP_XAI_API_KEY", "VOXCLIP_GEMINI_API_KEY" }
            .Select(Environment.GetEnvironmentVariable).OfType<string>(), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    internal static ITranscriptionService Transcription()
    {
        // TODO(merge): W5 ElevenLabsTranscriber(keys, http), WhisperNetTranscriber(models), TranscriptionService(engines, locations).
        var cloud = MergeApi.Construct<ElevenLabsTranscriber>([new EnvironmentKeyProvider(), Http]);
        var local = MergeApi.Construct<WhisperNetTranscriber>([ModelStorage()]);
        return MergeApi.Construct<TranscriptionService>([new ITranscriber[] { cloud, local }, DataLocations.Resolve()]);
    }

    internal static Task<TranscriptModel> TranscribeAsync(TranscriptionRequest request, AudioEnvelope? envelope, IProgress<TranscriptionProgress>? progress, CancellationToken ct)
    {
        // TODO(merge): W5 ITranscriptionService.TranscribeAsync(request, envelope, progress, ct).
        return MergeApi.Invoke<Task<TranscriptModel>>(typeof(ITranscriptionService).GetMethod("TranscribeAsync",
            [typeof(TranscriptionRequest), typeof(AudioEnvelope), typeof(IProgress<TranscriptionProgress>), typeof(CancellationToken)]), Transcription(), [request, envelope, progress, ct]);
    }
}

internal static class MergeApi
{
    internal static T Construct<T>(object?[] arguments)
    {
        var constructor = typeof(T).GetConstructors().SingleOrDefault(candidate =>
        {
            var parameters = candidate.GetParameters();
            return parameters.Length == arguments.Length && parameters.Select((parameter, index) =>
                arguments[index] is null ? !parameter.ParameterType.IsValueType : parameter.ParameterType.IsInstanceOfType(arguments[index])).All(matches => matches);
        });
        return Invoke<T>(constructor, null, arguments);
    }

    internal static T Invoke<T>(MethodBase? method, object? target, object?[] arguments)
    {
        if (method is null) throw new VoxClipException(VoxClipErrorCode.NotImplemented, "The sibling service integration is not merged. Your edits are saved.");
        try { return (T)(method is ConstructorInfo constructor ? constructor.Invoke(arguments) : method.Invoke(target, arguments))!; }
        catch (TargetInvocationException exception) when (exception.InnerException is not null)
        {
            ExceptionDispatchInfo.Capture(exception.InnerException).Throw();
            throw;
        }
    }
}

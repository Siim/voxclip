using VoxClip.Core.Services.LLM;
namespace VoxClip.Cli;

/// <summary>CLI key boundary; architecture §9.4. Never reads DPAPI or writes keys to disk.</summary>
public sealed class EnvironmentKeyProvider : IKeyProvider
{
    /// <inheritdoc />
    public Task<string?> GetKeyAsync(string account, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var variable = account switch
        {
            "elevenlabs-api-key" => "VOXCLIP_ELEVENLABS_API_KEY", "llm-api-key-anthropic" => "VOXCLIP_ANTHROPIC_API_KEY",
            "llm-api-key-openai" => "VOXCLIP_OPENAI_API_KEY", "llm-api-key-xai" => "VOXCLIP_XAI_API_KEY", "llm-api-key-gemini" => "VOXCLIP_GEMINI_API_KEY", _ => null
        };
        return Task.FromResult(variable is null ? null : Environment.GetEnvironmentVariable(variable));
    }
}

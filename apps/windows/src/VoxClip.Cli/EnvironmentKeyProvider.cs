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
            "elevenlabs-api-key" => "ELEVENLABS_API_KEY", "llm-api-key-anthropic" => "ANTHROPIC_API_KEY",
            "llm-api-key-openai" => "OPENAI_API_KEY", "llm-api-key-xai" => "XAI_API_KEY", "llm-api-key-gemini" => "GEMINI_API_KEY", _ => null
        };
        return Task.FromResult(variable is null ? null : Environment.GetEnvironmentVariable(variable));
    }
}

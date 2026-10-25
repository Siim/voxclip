namespace VoxClip.Core.Services.Speech;

/// <summary>Future own-voice consent matching boundary; Voice Lab §6.6. No model or native dependency is added in M1.</summary>
public interface ISpeakerEmbedder
{
    /// <summary>Calibrated catalog model id.</summary>
    string ModelId { get; }
    /// <summary>Embedding dimension.</summary>
    int Dimension { get; }
    /// <summary>Embed at least three seconds of mono16k speech, returning an L2-normalized vector.</summary>
    Task<ReadOnlyMemory<float>> EmbedAsync(ReadOnlyMemory<float> pcm16k, CancellationToken ct);
}

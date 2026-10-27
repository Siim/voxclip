using System.Buffers.Binary;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.Services;

internal sealed class Waveform(IAudioExtractor extractor, string cacheRoot)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, IReadOnlyList<float>> cached = new(StringComparer.Ordinal);
    internal async Task<IReadOnlyList<float>> GetAsync(MediaInfo media, string contentKey, CancellationToken ct)
    {
        if (media.Audio is null) return [];
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (cached.TryGetValue(contentKey, out var previous)) return previous;
            var result = await Task.Run(async () =>
            {
                var index = new CacheIndex(cacheRoot);
                var directory = index.EntryDirectory(contentKey);
                var entry = (await index.ReadAsync(ct).ConfigureAwait(false)).FirstOrDefault(entry => entry.ContentKey == contentKey);
                var file = Path.Combine(directory, "envelope-10ms.f32");
                AudioEnvelope? envelope = null;
                if (entry?.Envelope is { } metadata && File.Exists(file) && new FileInfo(file).Length == metadata.Count * 4L && new FileInfo(file).LinkTarget is null)
                {
                    var bytes = await File.ReadAllBytesAsync(file, ct).ConfigureAwait(false);
                    var levels = new float[metadata.Count];
                    for (var offset = 0; offset < levels.Length; offset++) levels[offset] = BinaryPrimitives.ReadSingleLittleEndian(bytes.AsSpan(offset * 4, 4));
                    if (levels.All(level => float.IsFinite(level) && level >= 0)) envelope = new(metadata.SampleRate, metadata.FrameSeconds, levels);
                }
                envelope ??= (await index.ExtractAudioAsync(extractor, media, contentKey, null, ct).ConfigureAwait(false)).Envelope;
                return Rms50(envelope);
            }, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (cached.Count >= 4) cached.Remove(cached.Keys.First());
            cached[contentKey] = result;
            return result;
        }
        finally { gate.Release(); }
    }
    internal static IReadOnlyList<float> Rms50(AudioEnvelope envelope)
    {
        if (envelope.FrameSeconds != 0.01) throw new ArgumentException("Expected the native 10 ms envelope.", nameof(envelope));
        var result = new float[(envelope.Rms.Count + 4) / 5];
        for (var bucket = 0; bucket < result.Length; bucket++)
        {
            var count = Math.Min(5, envelope.Rms.Count - bucket * 5);
            double squares = 0;
            for (var index = 0; index < count; index++) { var level = envelope.Rms[bucket * 5 + index]; squares += level * (double)level; }
            result[bucket] = (float)Math.Sqrt(squares / count);
        }
        return result;
    }
}

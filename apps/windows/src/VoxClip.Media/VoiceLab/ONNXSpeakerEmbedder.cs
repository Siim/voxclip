using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using Whisper.net;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed class ONNXSpeakerEmbedder : IDisposable
{
    private readonly InferenceSession session;
    private readonly SpeakerModel model;
    private readonly string directory;
    private readonly string vad;
    private readonly SemaphoreSlim gate = new(1, 1);
    public string ModelId => model.Id;
    public int Dimension => 256;
    public ONNXSpeakerEmbedder(string directory)
    {
        model = new SpeakerModelCatalog().Entry;
        this.directory = Path.GetFullPath(directory);
        var files = model.VerifiedFiles(this.directory);
        vad = files.Vad;
        using var options = new SessionOptions { IntraOpNumThreads = 2, GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
        session = new InferenceSession(files.Model, options);
        if (!session.InputMetadata.Keys.SequenceEqual(["feats"]) || !session.OutputMetadata.Keys.SequenceEqual(["embs"]))
        {
            session.Dispose();
            throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        }
    }
    public void ValidateAvailability()
    {
        if (new SpeakerModelCatalog().Entry.Identity != model.Identity) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        model.VerifiedFiles(directory);
    }
    public VoiceSpeakerCheck SpeakerCheck(string language = "en") => VoiceSpeakerCheck.Create(this, model, language);
    public async Task<IReadOnlyList<(int Start, int End)>> VoicedRangesAsync(float[] pcm16k, CancellationToken ct)
    {
        if (pcm16k.Length is < 48000 or > 16000 * 240 || pcm16k.Any(sample => !float.IsFinite(sample))) throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);
        ct.ThrowIfCancellationRequested();
        using var factory = WhisperVadFactory.FromPath(vad);
        await using var detector = factory.CreateBuilder().WithUseGpu(false).WithThreads(2).WithThreshold(0.5f)
            .WithMinSpeechDuration(TimeSpan.FromMilliseconds(250)).WithMinSilenceDuration(TimeSpan.FromMilliseconds(100))
            .WithMaxSpeechDuration(TimeSpan.MaxValue).WithSpeechPadding(TimeSpan.Zero).WithSamplesOverlap(TimeSpan.Zero).Build();
        var segments = await detector.DetectSpeechAsync(pcm16k, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var ranges = new List<(int Start, int End)>();
        foreach (var segment in segments)
        {
            var start = Math.Clamp((int)Math.Round(segment.Start.TotalSeconds * 16000, MidpointRounding.AwayFromZero), 0, pcm16k.Length);
            var end = Math.Clamp((int)Math.Round(segment.End.TotalSeconds * 16000, MidpointRounding.AwayFromZero), start, pcm16k.Length);
            if (end == start) continue;
            if (ranges.Count > 0 && start <= ranges[^1].End) ranges[^1] = (ranges[^1].Start, Math.Max(ranges[^1].End, end));
            else ranges.Add((start, end));
        }
        return ranges;
    }
    public async Task<float[]> EmbeddingAsync(float[] pcm16k, CancellationToken ct)
    {
        var snapshot = pcm16k.ToArray();
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ValidateAvailability();
            var ranges = await VoicedRangesAsync(snapshot, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var voiced = SpeakerAudio.Select(snapshot, ranges);
            var mean = new float[Dimension];
            foreach (var window in SpeakerAudio.Windows(voiced))
            {
                ct.ThrowIfCancellationRequested();
                var features = SpeakerAudio.Features(window);
                var tensor = new DenseTensor<float>(features, [1, 298, 80]);
                using var result = session.Run([NamedOnnxValue.CreateFromTensor("feats", tensor)], ["embs"]);
                var raw = result.Single().AsTensor<float>().ToArray();
                if (raw.Length != Dimension) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
                var vector = SpeakerAudio.Normalized(raw);
                for (var index = 0; index < mean.Length; index++) mean[index] += vector[index];
            }
            ct.ThrowIfCancellationRequested();
            return SpeakerAudio.Normalized(mean);
        }
        finally { gate.Release(); }
    }
    public void Dispose()
    {
        gate.Wait();
        try { session.Dispose(); }
        finally { gate.Release(); }
    }
}

public sealed class VoiceSpeakerCheck
{
    public static bool WindowsNativeParityVerified => false;
    public static string? UnavailableReason => WindowsNativeParityVerified ? null :
        "Own-voice speaker checking is unavailable until native win-arm64 and win-x64 ONNX Runtime parity is verified.";
    private readonly ONNXSpeakerEmbedder? embedder;
    public double? Threshold { get; }
    public string? Language { get; }
    public string? ModelId => embedder?.ModelId;
    public bool Available => WindowsNativeParityVerified && embedder is not null && Threshold.HasValue;
    public static VoiceSpeakerCheck Unavailable { get; } = new(null, null, null);
    private VoiceSpeakerCheck(ONNXSpeakerEmbedder? embedder, SpeakerModel? model, string? language)
    {
        this.embedder = embedder;
        Language = language;
        Threshold = language is null ? null : model?.CalibratedThreshold(language);
    }
    internal static VoiceSpeakerCheck Create(ONNXSpeakerEmbedder embedder, SpeakerModel model, string language)
    {
        if (!WindowsNativeParityVerified) return Unavailable;
        var canonical = new SpeakerModelCatalog().Entry;
        if (canonical.Identity != model.Identity || canonical.CalibratedThreshold(language) is null) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        embedder.ValidateAvailability();
        return new(embedder, canonical, language);
    }
    public bool Supports(string language) => Available && Language == language;
    public void ValidateAvailability()
    {
        if (!Available) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        embedder!.ValidateAvailability();
    }
    public Task<float[]> EmbeddingAsync(float[] pcm16k, CancellationToken ct)
    {
        ValidateAvailability();
        return embedder!.EmbeddingAsync(pcm16k, ct);
    }
}

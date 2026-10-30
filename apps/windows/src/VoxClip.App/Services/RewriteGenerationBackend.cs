using System.Buffers.Binary;
using System.Globalization;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.Services;

internal sealed class RewriteGenerationBackend : IDisposable
{
    private readonly ElevenLabsVoiceLab client;
    private readonly VoiceConsentStore store;
    private readonly VoiceLabDispatchGate gate = new();
    private readonly Func<bool> current;
    internal VoiceLabTakeRun Runner { get; }
    internal RewriteGenerationBackend(DataLocations data, IKeyProvider keys, ILog log, VoiceLabPriceCatalog prices,
        ElevenLabsRegion region, string projectId, Func<bool> current, Func<Action, Task> onUi)
    {
        this.current = current;
        store = new(data);
        client = new(keys, region, log, prices, new VoiceLabSpendLedger(data));
        Runner = new(client, store, VoiceSpeakerCheck.Unavailable,
            new(projectId, Path.Combine(data.Root, "VoiceLab"), Path.Combine(data.Root, "VoiceLabScratch")), gate,
            async ct =>
            {
                var valid = false;
                await onUi(() => valid = !ct.IsCancellationRequested && current());
                return valid;
            });
    }
    internal async Task<RewriteGenerationChoices> DiscoverAsync(string language, CancellationToken ct)
    {
        RequireCurrent(ct);
        VoiceSpeakerCheck.Unavailable.ValidateAvailability();
        var models = (await client.DiscoverModelsAsync(ct)).Where(model => model.SupportsTimestampedTts && model.Languages.Contains(language)).ToArray();
        RequireCurrent(ct);
        var remote = await client.ListOwnClonesAsync(ct);
        RequireCurrent(ct);
        var voices = store.ActiveVoices().Where(record => record.Statement.Language == language &&
            remote.Any(voice => voice.Id == record.VoiceId && (!voice.RequiresVerification || voice.IsVerified)))
            .Select(record => new RewriteVoice(record.RecordId, VoiceLabel(record.VoiceName, record.CreatedAt))).ToArray();
        return new(voices, models);
    }
    internal static string VoiceLabel(string name, DateTimeOffset date) =>
        name + " · consent " + date.ToString("MMM d", CultureInfo.InvariantCulture);
    private void RequireCurrent(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!current()) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
    internal static async Task<float[]> ReadSourceAsync(string path, long frames, int rate, CancellationToken ct,
        Func<string, long, long, double, CancellationToken, Task<byte[]>>? conversion = null)
    {
        if (frames is <= 0 or > RewriteSourceLimit.MaxFrames || rate is < 8_000 or > 96_000)
            throw new VoiceLabSourceAudioException(VoiceLabSourceAudioErrorCode.TooLarge);
        var samples = new float[checked((int)frames)];
        var convert = conversion ?? VoiceLabSourceAudio.ConversionInputAsync;
        long start = 0;
        while (start < frames)
        {
            ct.ThrowIfCancellationRequested();
            var end = Math.Min(frames, start + 280L * rate);
            if (frames - end < (rate + 49) / 50) end = frames;
            var wav = await convert(path, start, end, rate, ct);
            if (wav.LongLength != 44 + (end - start) * 2) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            for (var index = 0; index < end - start; index++)
                samples[checked((int)start + index)] = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + index * 2, 2)) / 32768f;
            start = end;
        }
        return samples;
    }
    public void Dispose() { gate.Invalidate(); client.Dispose(); }
}

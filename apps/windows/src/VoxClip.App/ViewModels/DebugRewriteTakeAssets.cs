#if DEBUG
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed class DebugRewriteTakeAssets(VoiceLabTakeStorage storage)
{
    private readonly Dictionary<Guid, (VoiceLabTakeScratch Scratch, VoiceLabTakeInput Input, uint Seed)> rows = [];
    internal VoiceLabTakeScratch? Scratch(Guid id) => rows.GetValueOrDefault(id).Scratch;
    internal async Task<VoiceLabTakeRow> RowAsync(VoiceLabTakeInput input, VoiceLabTakeQuote quote, VoiceLabTakeQaResult qa,
        double score, bool changed, CancellationToken ct)
    {
        const int rate = 24_000;
        Directory.CreateDirectory(storage.PaidRoot); Directory.CreateDirectory(storage.ScratchRoot);
        var window = input.Window;
        var frames = checked((long)Math.Floor((window.End - window.Start) * rate + 0.5)) + (changed ? rate / 5 : 0);
        var incoming = (long)Math.Ceiling(window.LeftSeam.FadeSamples / 2 * (double)rate / input.SourceSampleRate);
        var outgoing = (long)Math.Ceiling((window.RightSeam.FadeSamples - window.RightSeam.FadeSamples / 2) * (double)rate / input.SourceSampleRate);
        var samples = Enumerable.Range(0, checked((int)(incoming + frames + outgoing))).Select(index => (float)(0.05 * Math.Sin(index * 0.1))).ToArray();
        var paid = VoiceLabAssetStore.WriteDerived(samples, rate, storage.ProjectId, Guid.NewGuid().ToString("D"), storage.PaidRoot, DateTimeOffset.UtcNow, ct);
        var snapshot = await VoiceLabAssets.PreparePaidAsync(paid, storage.ProjectId, storage.PaidRoot, storage.ScratchRoot, ct);
        try
        {
            var duration = frames / (double)rate;
            var words = new[] { new VoiceLabWord(input.Text, Math.Min(0.01, duration / 4), Math.Max(duration / 2, duration - 0.01), true) };
            var plan = new VoiceLabFitPlan([], new(0, 0), new(0, 0), incoming, incoming + frames, window.Start, window.End,
                window.StartSample, window.EndSample, frames, words);
            VoiceLabFitResult fit = changed ? new VoiceLabFitResult.ChangedDuration(plan, duration, 0.2) : new VoiceLabFitResult.Exact(plan);
            var fitted = VoiceLabSilenceFit.Prepare(snapshot, paid, fit, window, input.SourceSampleRate, ct);
            var source = new float[checked((int)Math.Floor(input.Source.TotalFrames * (double)rate / input.SourceSampleRate + 0.5))];
            var tone = VoiceLabRoomToneSelection.Select(input.Items, input.SourceEnvelope, input.SourceSampleRate, input.Source.TotalFrames);
            var scratch = VoiceLabTakeRenderer.Stage(fitted, new(rate, samples, 0, tone, fit), input, VoiceLabSourceExcerpt.Whole(source), storage.ScratchRoot, ct);
            var id = quote.Synthesis.Review.RequestId; rows.Add(id, (scratch, input, quote.Seed));
            var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "v1/text-to-speech/fixture-provider-voice/with-timestamps",
                input.ModelId, "fixture-provider-voice", quote.Synthesis.Review.RequestId, "fixture", null);
            return new(id, quote.Index, quote.Seed, receipt, Quote: quote, Audio: scratch.Audio, Qa: qa, Score: score);
        }
        catch { await snapshot.InvalidateAsync(); throw; }
    }
    internal async Task RejectAsync(Guid id)
    {
        if (rows.Remove(id, out var row)) await row.Scratch.InvalidateAsync();
    }
    internal async Task InvalidateAsync()
    {
        var previous = rows.Values.ToArray(); rows.Clear();
        foreach (var row in previous) await row.Scratch.InvalidateAsync();
    }
    internal Task<(VoiceLabPublishedTake, VoiceConsentRecord)> PublishAsync(Guid id, DateTimeOffset date, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!rows.TryGetValue(id, out var row) || !row.Scratch.IsValid) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var published = row.Scratch.Fitted.Publish(storage.ProjectId, Guid.NewGuid().ToString("D"), storage.PaidRoot, date, id.ToString("D"), row.Seed, 0, ct);
        var consent = new VoiceConsentRecord("voxclip-voice-consent/1", row.Input.RecordId, "elevenlabs", "ivc", "fixture-provider-voice", "Fixture voice",
            VoiceConsentStatus.Active, date.AddDays(-1), null, new("en", "Fixture only", [], "fixture.wav", new('a', 64), new(0, "fixture")),
            new(true, true, true, date.AddDays(-1)), [], new("fixture-speaker", 0.5, "fixture"), new("fixture", "windows"));
        return Task.FromResult((new VoiceLabPublishedTake(published.Assets, published.Audio, published.OutDuration, published.Words, published.Chunks), consent));
    }
}
#endif

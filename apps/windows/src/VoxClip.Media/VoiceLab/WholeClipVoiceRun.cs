using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public static class WholeClipVoiceRun
{
    public static string PartText(PlacedOrRefused.Placed part) => string.Join(' ', part.Hunk.NewTokens);

    public static async Task<SavedWholeClipVoice> ExecuteAsync(Project project, WholeClipRevoicePlan plan,
        string path, string paidRoot, string recordId, string modelId, decimal approved, Func<VoiceLabTakeRun> createRunner,
        Func<Guid, CancellationToken, Task> authorize, Action<Action> start, WholeClipVoiceRecovery recovery, IProgress<string>? progress, CancellationToken ct)
    {
        var scope = plan.Original.Scope;
        var rate = checked((int)plan.Original.SampleRate);
        var words = project.Transcript!.Words.Select(word => word with { Text = project.Edits.Corrections.GetValueOrDefault(word.Id, word.Text) }).ToArray();
        var cuts = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var clean = WholeClipRevoicePlan.WithoutPrevious(project, scope.ClipId!);
        List<VoiceLabSegment> segments = [];
        Dictionary<string, VoiceLabAsset> assets = new(StringComparer.Ordinal);
        VoiceLabVoiceReference? reference = null;
        decimal spent = 0;
        var natural = 0.0;
        for (int index = 0; index < plan.Parts.Count; index++)
        {
            ct.ThrowIfCancellationRequested();
            progress?.Report($"Voice {index + 1} of {plan.Parts.Count}…");
            var part = plan.Parts[index];
            var window = part.Window;
            var silence = VoiceLabWindowPlanner.LendableSilence(clean, scope, window);
            var source = await VoiceLabSourceAudio.RewriteSourceAsync(path, plan.Original.TotalSourceSamples, rate, window,
                silence.Incoming, silence.Outgoing, words, ct).ConfigureAwait(false);
            var input = new VoiceLabTakeInput(PartText(part), modelId, recordId, project.Transcript.Language ?? "en", (uint)index,
                project.Media.Source.ContentKey, source.Excerpt, source.Envelope, rate, words, cuts, window, silence.Incoming, silence.Outgoing, false, true)
            {
                EditedLayout = new(WholeClipRevoice.EditedCuts(plan.Original, window.StartSample, window.EndSample), project.Edits.PauseThresholdSeconds),
            };
            var runner = createRunner();
            try
            {
                var quote = await runner.PrepareAsync(input, ct).ConfigureAwait(false);
                if (quote.Estimate.Usd is not { } price || spent + price > approved)
                    throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired, "The voice price changed. Check the price again.");
                var result = await runner.ExecuteWithDispatchAsync(quote, new(authorize, start), null, ct).ConfigureAwait(false);
                foreach (var row in result.Rows)
                {
                    if (row.Quote is not { } charged) continue;
                    if (row.Receipt is not null && charged.AdoptedAsset is null) spent += charged.Synthesis.Estimate.Usd ?? 0;
                    if (row.QaReceipt is not null) spent += charged.Qa.Estimate.Usd ?? 0;
                }
                ct.ThrowIfCancellationRequested();
                if (result.BestAutomatic is not { Audio: { } audio } rowPicked)
                    throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio, $"Part {index + 1} has no verified take that fits. Your paid takes are saved.");
                var date = DateTimeOffset.UtcNow;
                var (published, record) = await runner.PublishForAcceptanceAsync(rowPicked.Id, date, ct).ConfigureAwait(false);
                var take = new VoiceLabPublishedTake(published.Assets, published.Audio, published.OutDuration, published.Words, published.Chunks);
                var candidate = VoiceLabRecipeBuilder.Candidate(rowPicked, input, take, record, date,
                    rowPicked.Fits ? null : VoiceLabVideoMode.Cut);
                var segment = VoiceLabRecipeBuilder.Segment(Guid.NewGuid().ToString("D"), [candidate], 0, input, audio.Fit.Plan);
                natural += (audio.Fit.Plan.TrimEndFrame - audio.Fit.Plan.TrimStartFrame) / (double)audio.SampleRate;
                segments.Add(segment);
                foreach (var asset in published.Assets) assets[asset.Id] = asset;
                reference = new(record.RecordId, record.Provider, record.VoiceId!, record.RecordId, record.VoiceName, VoiceLabVoiceStatus.Active);
            }
            finally { await runner.InvalidateAsync().ConfigureAwait(false); }
        }
        var fit = WholeClipRevoice.FitVoice(natural, plan.Original.Duration, VoiceLabTakeQuality.Tokens(plan.Script.Text).Length, 0);
        if (fit is WholeClipRevoice.Fit.Reword or WholeClipRevoice.Fit.CannotFit)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio, "The voice is longer than the edited clip. Shorten the wording or use the patch. Your paid takes are saved.");
        var draft = WholeClipRevoiceDraft.Voice(project, scope.ClipId!, new(segments, assets.Values.ToArray(), reference));
        var saved = new SavedWholeClipVoice(draft, segments.Select(segment => segment.Id).ToArray(), spent) { Recovery = recovery };
        WholeClipVoiceCheckpoint.Keep(paidRoot, saved);
        return saved;
    }
}

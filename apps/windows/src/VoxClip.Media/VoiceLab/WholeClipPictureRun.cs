using System.Security.Cryptography;
using System.Text;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed record WholeClipPictureApproval(decimal Price, string Account);

public sealed class WholeClipPictureRun(FalLipsyncProvider provider, VoiceConsentStore consent, string paidRoot, string scratchRoot, string projectId,
    VoiceLabSpendLedger? spend = null)
{
    private readonly LipsyncRun run = new(provider, consent, paidRoot, projectId, spend);

    public static IReadOnlyList<VoiceLabSelectedRecipe> Recipes(VoiceLabPreparedRender rendered, SavedWholeClipVoice saved) =>
        saved.SegmentIds.Select(id => rendered.SelectedSegmentRecipes.Single(item => item.SegmentId == id)).ToArray();

    public bool HasAttempt(string identity, SavedWholeClipVoice saved, VoiceLabPreparedRender rendered, WholeClipLipsync model, double fps) =>
        Jobs(identity, rendered, saved, model, fps).Any(job => run.State(job.Input) != LipsyncAttemptState.NotSent);

    public async Task<WholeClipPictureApproval> PriceAsync(WholeClipRevoicePlan? plan, string identity, SavedWholeClipVoice? voice,
        VoiceLabPreparedRender? rendered, WholeClipLipsync model, double fps, CancellationToken ct)
    {
        var account = await provider.AccountFingerprintAsync(ct).ConfigureAwait(false);
        if (voice is not null && rendered is not null)
        {
            var jobs = Jobs(identity, rendered, voice, model, fps);
            decimal remaining = 0;
            foreach (var job in jobs)
            {
                switch (run.State(job.Input))
                {
                    case LipsyncAttemptState.Unconfirmed: throw new FalLipsyncException(FalLipsyncError.SubmissionUnconfirmed);
                    case LipsyncAttemptState.Failed: throw new FalLipsyncException(FalLipsyncError.RemoteFailed);
                    case LipsyncAttemptState.NotSent:
                        remaining += (await run.QuoteAsync(job.Input, ct).ConfigureAwait(false)).Estimate.Usd!.Value;
                        break;
                }
            }
            return new(remaining, account);
        }
        if (plan is null) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        decimal ceiling = 0;
        foreach (var window in plan.Windows)
        {
            var projected = LipsyncRenderWindow.Project(window, plan.Original);
            ceiling += (await provider.QuoteAsync(model, projected.Seconds(plan.Original.SampleRate), fps, projected.Mode, ct)
                .ConfigureAwait(false)).Estimate.Usd!.Value;
        }
        return new(ceiling, account);
    }

    public async Task<VoiceLabEditCommand.AcceptWholeClip> ExecuteAsync(string identity, SavedWholeClipVoice saved,
        ComposeSnapshot snapshot, string script, WholeClipLipsync model, WholeClipPictureApproval approval, VoiceConsentRecord record,
        VoiceLabDispatchBinding binding, IFrameFaces? faces, IProgress<string>? progress, CancellationToken ct)
    {
        var rendered = snapshot.VoiceLab?.Prepared ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var rate = rendered.OutputPlan.SampleRate;
        var fps = snapshot.Media.Video!.FrameRate;
        var jobs = Jobs(identity, rendered, saved, model, fps);
        decimal remaining = 0, picturePaid = 0;
        foreach (var job in jobs)
        {
            var estimate = await provider.EstimateAsync(model.LipsyncModel(), FalLipsyncProvider.UploadSeconds(job.Input.Seconds, fps), fps, ct).ConfigureAwait(false);
            var price = estimate.Usd ?? throw new FalLipsyncException(FalLipsyncError.InvalidInput);
            switch (run.State(job.Input))
            {
                case LipsyncAttemptState.Unconfirmed: throw new FalLipsyncException(FalLipsyncError.SubmissionUnconfirmed);
                case LipsyncAttemptState.Failed: throw new FalLipsyncException(FalLipsyncError.RemoteFailed);
                case LipsyncAttemptState.NotSent: remaining += price; break;
            }
        }
        if (remaining > approval.Price || approval.Account != await provider.AccountFingerprintAsync(ct).ConfigureAwait(false))
            throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
        List<WholeClipLipSync> pictures = [];
        foreach (var job in jobs)
        {
            ct.ThrowIfCancellationRequested();
            binding.Validate();
            progress?.Report($"Lip sync {pictures.Count + 1} of {jobs.Count}…");
            SavedLipsyncPicture picture;
            if (run.State(job.Input) == LipsyncAttemptState.NotSent)
            {
                if (faces is null || !await LipsyncMedia.HasFaceAsync(snapshot.Media, job.Window.Source.StartSample / rate,
                    job.Window.Source.EndSample / rate, faces, ct).ConfigureAwait(false))
                    throw new VoiceLabException(VoiceLabErrorKind.InvalidInput, "No face could be verified in this part. Your voice is saved.");
                using var upload = await LipsyncMedia.PrepareAsync(snapshot, job.Window, scratchRoot, ct).ConfigureAwait(false);
                var quote = await run.QuoteAsync(job.Input, ct).ConfigureAwait(false);
                if (!quote.MatchesAccount(approval.Account) || quote.Estimate.Usd is not { } amount || amount > remaining)
                    throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
                remaining -= amount;
                picture = await run.ExecuteAsync(job.Input, quote, upload.Video, upload.Audio, record, binding, null, ct).ConfigureAwait(false);
            }
            else picture = await run.ExecuteAsync(job.Input, null, null, null, record, binding, null, ct).ConfigureAwait(false);
            var asset = await LipsyncMedia.ImportAsync(picture, projectId, paidRoot, snapshot.Media, job.Input.Seconds, ct).ConfigureAwait(false);
            picturePaid += run.AcceptedPrice(job.Input) ?? throw new FalLipsyncException(FalLipsyncError.InvalidResponse);
            pictures.Add(new(job.Window, asset, picture.RequestId));
        }
        var recipes = Recipes(rendered, saved);
        var speed = recipes.Sum(item => (item.Recipe.Video.RetimeFactor ?? 1) * item.Recipe.Video.OutputSamples) /
            recipes.Sum(item => item.Recipe.Video.OutputSamples);
        var match = new WholeClipRevoiceRecord(Guid.NewGuid().ToString("D"), rendered.OutputPlan.Scope.ClipId!, saved.SegmentIds, script,
            record.RecordId, speed, model.RawValue(), (double)(saved.Spent + picturePaid), null, DateTimeOffset.UtcNow);
        return WholeClipRevoiceDraft.WithPicture(saved.Voice(record.RecordId), match, recipes, pictures);
    }

    private static IReadOnlyList<(LipsyncRenderWindow Window, LipsyncRunWindow Input)> Jobs(string identity,
        VoiceLabPreparedRender rendered, SavedWholeClipVoice saved, WholeClipLipsync model, double fps)
    {
        var plan = rendered.OutputPlan;
        var recipes = Recipes(rendered, saved);
        var voice = string.Join(';', recipes.Select(item => item.Recipe.Audio.AssetId));
        return LipsyncRenderWindow.Jobs(plan, recipes).Select(window =>
        {
            var inputs = FormattableString.Invariant($"{identity}\n{voice}\n{window.Source.StartSample}:{window.Source.EndSample}\n{window.OutputStartSample}:{window.OutputEndSample}");
            var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(inputs)));
            return (window, new LipsyncRunWindow(hash, window.Seconds(plan.SampleRate), fps, model, window.Mode));
        }).ToArray();
    }
}

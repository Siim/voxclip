using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private void ConfigureWholeClip(RewriteSession session)
    {
        if (demo) return;
        var services = App.Services;
        var paidRoot = Path.Combine(services.Data.Root, "VoiceLab");
        var scratchRoot = Path.Combine(services.Data.Root, "VoiceLabScratch");
        var consent = new VoiceConsentStore(services.Data);
        Task OnUi(Action action)
        {
            if (DispatcherQueue.HasThreadAccess) { action(); return Task.CompletedTask; }
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!DispatcherQueue.TryEnqueue(() =>
            {
                try { action(); completion.SetResult(); }
                catch (Exception error) { completion.SetException(error); }
            })) completion.SetException(new OperationCanceledException());
            return completion.Task;
        }
        Task<ComposeSnapshot> Snapshot(Project draft, string clipId, CancellationToken ct)
        {
            draft = draft with { Edits = draft.Edits with { ActiveClipId = WholeClipRevoice.OutputScope(clipId).ClipId } };
            return SnapshotAsync(ct, EditingEngine.FromProject(draft), draft);
        }

        session.ConfigureWholeClip(async (selection, model, ct) =>
        {
            var edited = selection.Edited;
            var clipId = selection.ClipId;
            var source = media ?? MediaFromProject(edited);
            if (!LipsyncMedia.Supports(source)) throw new RewriteGenerationException("Lip sync needs a video with sound at 1–60 frames per second.");
            if (edited.VoiceLab.CleanAudio?.Mode == VoiceLabCleanAudioMode.On)
                throw new RewriteGenerationException("Turn off Clean Audio before revoicing this clip on Windows. Nothing was sent.");
            consent.ValidateUse(consent.Load(selection.RecordId));
            var catalog = VoiceLabPrices.Load();
            var spend = new VoiceLabSpendLedger(services.Data);
            using var fal = new FalLipsyncProvider(services.Keys, catalog);
            var pictureRun = new WholeClipPictureRun(fal, consent, paidRoot, scratchRoot, edited.Id);
            var saved = WholeClipVoiceCheckpoint.Read(paidRoot, edited.Id, selection.Recovery.BaseKey, selection.Identity);
            if (saved is null && selection.Kept is { } kept && selection.Intent is WholeClipIntent.RedoLipSync or WholeClipIntent.Sharper)
                saved = SavedWholeClipVoice.FromKept(edited, kept, selection.Recovery);
            async Task<ComposeSnapshot> VoiceSnapshot(SavedWholeClipVoice voice, CancellationToken token) =>
                await Snapshot(WholeClipRevoiceDraft.Voice(edited, clipId, voice.Voice(selection.RecordId)), clipId, token);
            if (saved is not null) session.KeepWholeClipVoice(selection, saved);
            var rendered = saved is null ? null : (await VoiceSnapshot(saved, ct)).VoiceLab?.Prepared;
            var fps = source.Video!.FrameRate;
            if (selection.Intent == WholeClipIntent.Revoice && model == WholeClipLipsync.Lipsync2 && saved is not null && rendered is not null &&
                pictureRun.HasAttempt(selection.Identity, saved, rendered, WholeClipLipsync.Sync3, fps)) model = WholeClipLipsync.Sync3;
            var picture = await pictureRun.PriceAsync(selection.Plan, selection.Identity, saved, rendered, model, fps, ct);
            if (picture.Price > 0 && services.FrameFaces is null)
                throw new RewriteGenerationException("The Windows face check isn't available. No video was sent.");
            var region = ElevenLabsRegions.FromSettings(services.Settings, services.Log);
            var limit = services.Settings.GetVoiceLabMonthlyCap("elevenlabs");
            var falLimit = services.Settings.GetVoiceLabMonthlyCap("fal");
            string? elevenKey = null;
            decimal voicePrice = 0;
            if (saved is null)
            {
                var faces = services.FrameFaces!;
                foreach (var window in selection.Plan!.Windows)
                    if (!await LipsyncMedia.HasFaceAsync(source, window.StartSample / selection.Plan.Original.SampleRate,
                        window.EndSample / selection.Plan.Original.SampleRate, faces, ct))
                        throw new RewriteGenerationException("No face could be verified in part of this clip. Nothing was sent.");
                if (!services.Get("voiceLab.providerConsent.elevenlabs", false))
                    throw new RewriteGenerationException("Allow ElevenLabs in Voice Lab settings before making a whole-clip voice.");
                elevenKey = await services.Keys.GetKeyAsync("elevenlabs-api-key", ct);
                using var pricing = new ElevenLabsVoiceLab(services.Keys, region, services.Log, catalog);
                foreach (var part in (selection.Plan ?? throw new RewriteGenerationException("The saved voice couldn't be verified.")).Parts)
                {
                    var tts = pricing.Estimate(VoiceLabOperation.TextToSpeech, VoiceLabWordingFit.ModelId, VoiceLabTextLength.Length(WholeClipVoiceRun.PartText(part)), VoiceLabPricing.MaximumCandidates);
                    var qa = pricing.Estimate(VoiceLabOperation.SpeechToText, ElevenLabsScribe.ModelId, VoiceLabTakeProcessing.MaximumQaSeconds, VoiceLabPricing.MaximumCandidates);
                    voicePrice += (tts.Usd ?? throw new RewriteGenerationException("ElevenLabs pricing is unavailable.")) + (qa.Usd ?? throw new RewriteGenerationException("ElevenLabs pricing is unavailable."));
                }
            }
            var disclosure = (saved is null ? $"Sends the full script and the voice for word checks to ElevenLabs ({VoiceLabCostPresentation.Format(voicePrice)} with all retries). " : "Uses your saved voice. ") +
                (picture.Price > 0 ? $"Sends the edited picture and voice to fal.ai with your key ({VoiceLabCostPresentation.Format(picture.Price)})." : "Recovers the existing fal.ai job. Nothing new is sent for lip sync.");
            if (saved is null && limit is { } cap)
            {
                await WorkflowSpendCache.RefreshAsync(services.Data);
                if (WorkflowSpendCache.Monthly is not { } total) throw new RewriteGenerationException("Monthly spend is unavailable. Nothing was sent.");
                if (total.Usd <= cap && total.Usd + voicePrice > cap) disclosure += " This crosses your ElevenLabs monthly warning amount.";
            }
            if (picture.Price > 0 && falLimit is { } falCap)
            {
                var total = await spend.TotalForCapAsync("fal", DateTimeOffset.Now, ct) ??
                    throw new RewriteGenerationException("fal.ai monthly spend is unavailable. Nothing was sent.");
                if (total.Usd <= falCap && total.Usd + picture.Price > falCap) disclosure += " This crosses your fal.ai monthly warning amount.";
            }

            return new WholeClipOffer(selection, model, voicePrice, picture, disclosure, async (offer, progress, token) =>
            {
                var binding = session.WholeClipBinding();
                bool Current() => session.WholeClipCurrent(selection) && services.VoiceLabEnabled &&
                    ElevenLabsRegions.FromSettings(services.Settings, services.Log) == region &&
                    services.Settings.GetVoiceLabMonthlyCap("fal") == falLimit;
                var storeRecord = consent.Load(selection.RecordId);
                consent.ValidateUse(storeRecord);
                using var activeFal = new FalLipsyncProvider(services.Keys, catalog, (fingerprint, status) =>
                {
                    services.Log.Write(VoxClip.Core.Services.Logging.LogLevel.Warn, "voice-lab", $"lipsync provider=fal event=cleanup-unconfirmed status={status}");
                    services.FalCleanup.MarkDenied(fingerprint);
                });
                if (await activeFal.AccountFingerprintAsync(token) != offer.Picture.Account)
                    throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
                if (saved is null)
                {
                    bool VoiceCurrent() => Current() && services.Get("voiceLab.providerConsent.elevenlabs", false) &&
                        services.Settings.GetVoiceLabMonthlyCap("elevenlabs") == limit;
                    using var backend = new RewriteGenerationBackend(services.Data, services.Keys, services.Log, catalog,
                        region, edited.Id, VoiceCurrent, OnUi, services.LocalTiming);
                    async Task Authorize(Guid request, CancellationToken currentToken)
                    {
                        bool current = false;
                        await OnUi(() => current = VoiceCurrent());
                        if (!current || string.IsNullOrWhiteSpace(elevenKey) ||
                            await services.Keys.GetKeyAsync("elevenlabs-api-key", currentToken) != elevenKey)
                            throw new VoiceLabRunInvalidatedException();
                    }
                    await Authorize(Guid.Empty, token);
                    var choices = await backend.DiscoverAsync(edited.Transcript?.Language ?? "en", token);
                    if (!choices.Voices.Any(voice => voice.Id == selection.RecordId) || !choices.Models.Any(model => model.Id == VoiceLabWordingFit.ModelId))
                        throw new RewriteGenerationException("That voice or Eleven v4 is no longer available on this account.");
                    saved = await WholeClipVoiceRun.ExecuteAsync(edited, selection.Plan!, source.Path, paidRoot,
                        selection.RecordId, VoiceLabWordingFit.ModelId, offer.VoicePrice,
                        () => backend.CreateRunner(services.LocalTiming), Authorize, action => { binding.Validate(); action(); }, selection.Recovery, progress, token,
                        selection.Intent == WholeClipIntent.RedoVoice ? selection.Kept?.CreatedAt : null);
                    session.KeepWholeClipVoice(selection, saved);
                }
                token.ThrowIfCancellationRequested();
                if (!Current()) throw new VoiceLabRunInvalidatedException();
                var snapshot = await VoiceSnapshot(saved, token);
                return await new WholeClipPictureRun(activeFal, consent, paidRoot, scratchRoot, edited.Id, spend).ExecuteAsync(selection.Identity, saved,
                    snapshot, selection.Recovery.Script, offer.Model, offer.Picture, storeRecord, binding, services.FrameFaces, progress, token);
            });
        }, (id, key) => WholeClipVoiceCheckpoint.ReadLatest(paidRoot, id, key), recordId => consent.ValidateUse(consent.Load(recordId)),
        async (project, clipId, audioOnly, ct) =>
        {
            if (preview is not { } player) return;
            var snapshot = await Snapshot(project, clipId, ct);
            await previewChanges.WaitAsync(ct);
            try
            {
                if (audioOnly)
                {
                    await player.PauseAsync(ct);
                    await LipsyncMedia.PlayVoiceAsync(snapshot with { Clip = null, Captions = null, ContextDemo = null }, ct);
                    return;
                }
                await player.UpdateSnapshotAsync(snapshot, ct);
                presenter?.Attach(snapshot);
                await player.SeekAsync(0, true, ct);
                await player.PlayAsync(ct);
                while (player.Position.IsPlaying) await Task.Delay(100, ct);
            }
            finally
            {
                try
                {
                    if (!audioOnly && !lifetime.IsCancellationRequested)
                    {
                        await player.PauseAsync(lifetime.Token);
                        var live = await SnapshotAsync(lifetime.Token);
                        await player.UpdateSnapshotAsync(live, lifetime.Token);
                        presenter?.Attach(live);
                    }
                }
                finally { previewChanges.Release(); }
            }
        });
        session.WholeClipApplied = () => DispatcherQueue.TryEnqueue(() =>
            _ = RunAsync(() => OpenRewriteAsync(false, wholeClipIntent: WholeClipIntent.Revoice), "Whole-take voice"));
    }
}

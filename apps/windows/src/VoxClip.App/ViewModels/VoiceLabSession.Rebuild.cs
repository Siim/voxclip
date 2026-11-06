using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>What the rebuild finder found, for the row (Media <c>VoiceRebuildFinder.Found</c>): the line shown first, the pieces' lengths
/// in send order, and the backend's own handle for the preparation. For a video's voice (§6.13), <see cref="RemovesBackgroundNoise"/> says a
/// piece is under 20 dB and <see cref="VideoMilliseconds"/> is the video's own speech, the anchor's clip not counted.</summary>
internal sealed record VoiceRebuildFind(string Summary, IReadOnlyList<double> PieceSeconds, object Ticket, bool RemovesBackgroundNoise = false,
    long VideoMilliseconds = 0);
/// <summary>A prepared rebuild creation (the attested route's local quote): the new record id, its price, the speech it sends and the
/// backend's own plan.</summary>
internal sealed record VoiceRebuildQuote(string RecordId, decimal? Usd, long TrainingMilliseconds, object Ticket);
/// <summary>The finder found too little verified speech (<see cref="Milliseconds"/>), <see cref="Noisy"/> stretches under the floor.</summary>
internal sealed class VoiceRebuildNotEnoughException(long milliseconds, int noisy) : Exception("not enough")
{
    internal long Milliseconds { get; } = milliseconds;
    internal int Noisy { get; } = noisy;
}

internal enum VoiceRebuildPhase { Idle, Finding, Found, Preparing, Ready, Creating, Created, Failed }

/// <summary>One voice's "Rebuild from my videos" row (voice-lab.md §6.12, ADR-R44; Mac <c>VoiceRebuildState</c>). Free and local until the
/// one priced click: the verified speech is found and shown first, the three attestations are ticked inline, and Rebuild · price goes
/// through the existing attested creation. Afterwards the row offers Use the new voice for Rewrite and Remove the old voice, inline.</summary>
internal sealed class VoiceRebuildState(string oldId)
{
    internal string OldId { get; } = oldId;
    internal VoiceRebuildPhase Phase { get; set; }
    /// <summary>The row's footer: always the next step.</summary>
    internal string Line { get; set; } = "";
    internal string Summary { get; set; } = "";
    internal VoiceRebuildFind? Found { get; set; }
    internal VoiceRebuildQuote? Quote { get; set; }
    internal bool OwnVoice { get; set; }
    internal bool Adult { get; set; }
    internal bool OwnVideosOnly { get; set; }
    internal bool Attested => OwnVoice && Adult && OwnVideosOnly;
    internal DateTimeOffset AcceptedAt { get; set; }
    internal string? NewRecordId { get; set; }
    internal bool UsedForRewrite { get; set; }
    internal bool ConfirmingRemoval { get; set; }
    internal bool Removed { get; set; }
    internal int Version { get; set; }
}

internal sealed partial class VoiceLabSession
{
    internal const string RebuildIntro = "Makes a new copy of your voice from your clearest speech across your videos, checked against your consent recording. Finding it is free and stays on this PC.";
    private readonly Dictionary<string, VoiceRebuildState> rebuilds = [];

    /// <summary>The rebuild row of a voice, kept while Settings is open.</summary>
    internal VoiceRebuildState Rebuild(string recordId)
    {
        if (!rebuilds.TryGetValue(recordId, out var state)) rebuilds[recordId] = state = new(recordId);
        return state;
    }
    internal bool HasRebuild(string recordId) => rebuilds.ContainsKey(recordId);

    /// <summary>Rebuild from my videos is shown on an active attested voice (<c>/2</c>, project consent) where the speaker check is ready.
    /// Behind the closed parity gate it never is.</summary>
    internal bool RebuildOffered(VoiceConsentRecord record) => record.ProjectConsent is not null && LearningOffered(record);

    /// <summary>Finds the rebuild set across <paramref name="projects"/> (default: recent projects and the export folder), on this PC.</summary>
    internal async Task FindRebuildAsync(string recordId, IReadOnlyList<string>? projects = null)
    {
        var state = Rebuild(recordId);
        if (state.Phase is VoiceRebuildPhase.Finding or VoiceRebuildPhase.Creating or VoiceRebuildPhase.Preparing || Busy ||
            Records.FirstOrDefault(record => record.RecordId == recordId) is not { Status: VoiceConsentStatus.Active } record || !RebuildOffered(record)) return;
        var paths = projects ?? Backend.LearningProjects();
        state.Found = null; state.Quote = null; state.Summary = ""; state.UsedForRewrite = false; state.ConfirmingRemoval = false;
        var version = ++state.Version;
        if (paths.Count == 0)
        {
            state.Phase = VoiceRebuildPhase.Failed;
            state.Line = "Open or export a video first. VoxClip rebuilds your voice from your projects on this PC.";
            Notify();
            return;
        }
        state.Phase = VoiceRebuildPhase.Finding;
        state.Line = $"Finding your clearest speech in video 1 of {paths.Count}… Nothing is sent.";
        Notify();
        try
        {
            var found = await Task.Run(() => Backend.FindRebuildAsync(recordId, paths, (index, count) => Dispatch(() =>
            {
                if (state.Version != version) return;
                state.Line = $"Finding your clearest speech in video {index} of {count}… Nothing is sent.";
                Notify();
            }), Lifetime), Lifetime);
            await Dispatch(() =>
            {
                if (state.Version != version) return;
                state.Found = found; state.Summary = found.Summary; state.Phase = VoiceRebuildPhase.Found;
            });
            await RebuildAttestationsChangedAsync(state);
        }
        catch (VoiceRebuildNotEnoughException error)
        {
            await Dispatch(() => { if (state.Version == version) Fail(state, NotEnoughLine(error.Milliseconds, error.Noisy, paths.Count)); });
        }
        catch (VoiceRebuildFailedException error) when (error.Kind == VoiceRebuildFailureKind.Unavailable)
        {
            await Dispatch(() => { if (state.Version == version) Fail(state, "The speaker check isn't ready. Download it in Voice Lab, then try again."); });
        }
        catch (OperationCanceledException) { await Dispatch(() => { if (state.Version == version) { state.Phase = VoiceRebuildPhase.Idle; state.Line = ""; Notify(); } }); }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            await Dispatch(() => { if (state.Version == version) Fail(state, "Couldn't read your videos for a rebuild. Nothing was sent. Try again."); });
        }
    }

    private void Fail(VoiceRebuildState state, string line) { state.Phase = VoiceRebuildPhase.Failed; state.Line = line; Notify(); }

    /// <summary>Ticks or unticks one of the three attestations inline (own voice, 18 or older, own videos only).</summary>
    internal Task SetRebuildAttestationAsync(VoiceRebuildState state, bool? ownVoice = null, bool? adult = null, bool? ownVideosOnly = null)
    {
        if (state.Phase == VoiceRebuildPhase.Creating) return Task.CompletedTask;
        var was = state.Attested;
        state.OwnVoice = ownVoice ?? state.OwnVoice; state.Adult = adult ?? state.Adult; state.OwnVideosOnly = ownVideosOnly ?? state.OwnVideosOnly;
        if (state.Attested && !was) state.AcceptedAt = Clock.GetUtcNow();
        return RebuildAttestationsChangedAsync(state);
    }

    /// <summary>With all three attestations, prepares the local creation quote (free); otherwise drops it.</summary>
    private async Task RebuildAttestationsChangedAsync(VoiceRebuildState state)
    {
        if (state.Phase is not (VoiceRebuildPhase.Found or VoiceRebuildPhase.Ready or VoiceRebuildPhase.Preparing) || state.Found is not { } found) { Notify(); return; }
        var version = ++state.Version;
        var drafted = state.Quote;
        state.Quote = null;
        if (drafted is not null) await Task.Run(() => Backend.CancelRebuildAsync(drafted, Lifetime));
        if (!state.Attested)
        {
            state.Phase = VoiceRebuildPhase.Found;
            state.Line = "Tick the three boxes to rebuild. Only this speech is sent to ElevenLabs; no video.";
            Notify();
            return;
        }
        if (Records.FirstOrDefault(record => record.RecordId == state.OldId) is not { } old) return;
        state.Phase = VoiceRebuildPhase.Preparing;
        state.Line = "Preparing the price… Nothing is sent.";
        Notify();
        var attestations = new VoiceConsentAttestations(true, true, true, state.AcceptedAt);
        try
        {
            var quote = await Task.Run(() => Backend.PrepareRebuildAsync(old, found, attestations, RebuildName(old.VoiceName), Lifetime), Lifetime);
            await Dispatch(() =>
            {
                if (state.Version != version) { _ = Backend.CancelRebuildAsync(quote, CancellationToken.None); return; }
                state.Quote = quote; state.Phase = VoiceRebuildPhase.Ready;
                state.Line = $"Sends {VoiceRebuild.Amount(quote.TrainingMilliseconds)} of your speech to ElevenLabs to make a new voice, with your checkbox consent. No video is sent. Your current voice stays until you remove it.";
                Notify();
            });
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            await Dispatch(() =>
            {
                if (state.Version != version) return;
                state.Phase = VoiceRebuildPhase.Found; state.Line = RebuildError(error); Notify();
            });
        }
    }

    /// <summary>Too little clean speech that's clearly the owner's: how much, why, and the next step.</summary>
    internal static string NotEnoughLine(long milliseconds, int noisy, int videos)
    {
        var found = $"Only {VoiceRebuild.Amount(milliseconds)} of clean speech that's clearly yours in {videos} {(videos == 1 ? "video" : "videos")}";
        var why = noisy > 0 ? $", and {noisy} {(noisy == 1 ? "stretch was" : "stretches were")} too noisy to train a voice" : "";
        return found + why + ". A rebuild needs 30 s. Transcribe a video recorded somewhere quiet, then try again.";
    }

    /// <summary>"siim (VoxClip)" → "siim": the display name the new voice keeps.</summary>
    internal static string RebuildName(string voiceName) => voiceName.EndsWith(" (VoxClip)", StringComparison.Ordinal) ? voiceName[..^" (VoxClip)".Length] : voiceName;

    /// <summary>Rebuild · price: the only paid click. The consent, journal and creator binding are the attested creation's own.</summary>
    internal static string RebuildTitle(VoiceRebuildState state) => state.Quote is not { } quote ? "Rebuild"
        : quote.Usd is not { } usd ? "Rebuild · Cost unknown" : "Rebuild · " + (usd == 0 ? "$0" : VoiceLabCostPresentation.Format(usd));

    internal async Task ApproveRebuildAsync(VoiceRebuildState state)
    {
        if (state.Phase != VoiceRebuildPhase.Ready || state.Quote is not { } quote || Busy || !Enabled) return;
        Busy = true; state.Phase = VoiceRebuildPhase.Creating;
        state.Line = "Making your new voice in your ElevenLabs account…";
        Notify();
        try
        {
            var created = await Task.Run(() => Backend.ApproveRebuildAsync(state.OldId, quote, Lifetime), Lifetime);
            await Dispatch(() =>
            {
                state.Quote = null; state.Found = null; state.NewRecordId = created.Record.RecordId; state.Phase = VoiceRebuildPhase.Created;
                var learned = created.Carried == 0 ? "" : $" It keeps what VoxClip learned from {created.Carried} of your videos.";
                state.Line = created.Record.Status == VoiceConsentStatus.VerificationRequired
                    ? "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back."
                    : $"Your rebuilt voice is ready.{learned} Next: use it for Rewrite, then remove the old voice.";
            });
        }
        catch (VoiceLabRebuildSaveException error)
        {
            await Dispatch(() =>
            {
                UnsavedRecord = error.Record;
                Fail(state, "ElevenLabs made the new voice, but its consent record couldn't be saved. Retry saving below. Don't rebuild again.");
            });
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            await Dispatch(() =>
            {
                state.OwnVoice = false; state.Quote = null; state.Phase = VoiceRebuildPhase.Found;
                state.Line = RebuildError(error) + " Tick the first box again for a fresh price.";
            });
        }
        finally { await Dispatch(() => { Busy = false; Notify(); }); }
        await LoadAsync(recover: false);
    }

    /// <summary>Use the new voice for Rewrite: Rewrite starts with it wherever it is listed.</summary>
    internal async Task UseRebuiltVoiceAsync(VoiceRebuildState state)
    {
        if (state.Phase != VoiceRebuildPhase.Created || state.NewRecordId is not { } id ||
            !Records.Any(record => record.RecordId == id && record.Status == VoiceConsentStatus.Active)) return;
        await Backend.SetRewriteVoiceAsync(id, Lifetime);
        state.UsedForRewrite = true;
        state.Line = state.Removed ? "Rewrite uses your rebuilt voice." : "Rewrite uses your rebuilt voice. Next: remove the old voice.";
        Notify();
    }

    /// <summary>Remove the old voice asks inline first ([Keep it] [Remove old voice]); no dialog.</summary>
    internal void ConfirmOldVoiceRemoval(VoiceRebuildState state, bool confirming)
    {
        if (state.Phase != VoiceRebuildPhase.Created || state.Removed) return;
        state.ConfirmingRemoval = confirming; Notify();
    }

    /// <summary>Remove the old voice, after its inline confirmation: the existing deletion (creator binding, journal, tombstone).</summary>
    internal async Task RemoveOldVoiceAsync(VoiceRebuildState state)
    {
        if (state.Phase != VoiceRebuildPhase.Created || state.NewRecordId is not { } id || !state.ConfirmingRemoval || Busy || !Enabled) return;
        Busy = true; state.ConfirmingRemoval = false; Notify();
        string line;
        try
        {
            await Task.Run(() => Backend.DeleteAsync(state.OldId, Lifetime), Lifetime);
            if (Backend.RewriteVoice() is null || Backend.RewriteVoice() == state.OldId) { await Backend.SetRewriteVoiceAsync(id, Lifetime); state.UsedForRewrite = true; }
            state.Removed = true;
            line = "Removed the old voice. Rewrite uses your rebuilt voice. Existing takes stay playable and labelled.";
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            line = RebuildError(error) + " The old voice is still here; Remove the old voice again to retry.";
        }
        finally { await Dispatch(() => { Busy = false; Notify(); }); }
        await LoadAsync(recover: false);
        await Dispatch(() => { state.Line = line; Notify(); });
    }

    /// <summary>Plays one of the found pieces on this PC.</summary>
    internal async Task PlayRebuildPieceAsync(VoiceRebuildState state, int index)
    {
        if (state.Found is not { } found || index < 0 || index >= found.PieceSeconds.Count) return;
        try { await Backend.PlayRebuildPieceAsync(found, index, Lifetime); }
        catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException)
        { state.Line = "This piece couldn't be played. Nothing changed."; Notify(); }
    }

    internal static string RebuildError(Exception error) => error switch
    {
        VoiceConsentException { Kind: VoiceConsentError.SpeakerMismatch } => "Some of this speech doesn't sound like your consent recording, and too little is left. Nothing was sent.",
        VoiceLabException { Kind: VoiceLabErrorKind.NoVoiceSlots } => "Your ElevenLabs account has no free voice slot. Free one on elevenlabs.io, then try again.",
        VoiceLabException { Kind: VoiceLabErrorKind.PlanUnavailable } => "Instant voice cloning needs an ElevenLabs Starter plan or higher.",
        VoiceLabException { Kind: VoiceLabErrorKind.MissingKey } => "Add your ElevenLabs key above, then try again.",
        VoiceCreatorMismatchException => VoiceCreatorMismatchException.Explanation,
        _ => "Couldn't finish. Nothing more was sent."
    };
}

/// <summary>A rebuild whose voice exists at ElevenLabs but whose consent record couldn't be saved (Media <c>VoiceConsentSaveException</c>).</summary>
internal sealed class VoiceLabRebuildSaveException(VoiceConsentRecord record) : Exception("saved remotely, not locally")
{
    internal VoiceConsentRecord Record { get; } = record;
}

/// <summary>The rebuilt voice's record and how many learned references it carried over (one hop against its own embedding).</summary>
internal sealed record VoiceRebuildCreated(VoiceConsentRecord Record, int Carried);

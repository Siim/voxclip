using System.Globalization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Where one video's own voice is this run (Mac <c>VideoVoiceState.Phase</c>).</summary>
internal enum VideoVoicePhase
{
    /// <summary>Nothing asked or made yet.</summary>
    Idle,
    /// <summary>Finding the video's speech (free, on this PC), then making the voice in the user's ElevenLabs account.</summary>
    Making,
    /// <summary>The video's own voice: Rewrite's takes in this video use it (<see cref="VideoVoiceState.RecordId"/>).</summary>
    Ready,
    /// <summary>Takes use the anchor: too little of the video's own speech, or no voice made from videos to match from.</summary>
    Anchor,
    /// <summary>Making it failed; takes use the anchor. Try Again acts.</summary>
    Failed
}

/// <summary>One video's own voice this run (voice-lab.md §6.13, ADR-R45; design.md R2 "A matching voice for this video"; Mac
/// <c>VideoVoiceState</c>).</summary>
internal sealed class VideoVoiceState(string contentKey)
{
    internal string ContentKey { get; } = contentKey;
    internal VideoVoicePhase Phase { get; set; }
    /// <summary>The video's own voice once <see cref="VideoVoicePhase.Ready"/>.</summary>
    internal string? RecordId { get; set; }
    /// <summary>The Rewrite panel's line for this video.</summary>
    internal string Line { get; set; } = "";
    /// <summary>The Rewrite run that showed the anchor note: it is said once.</summary>
    internal object? NotedIn { get; set; }
    /// <summary>The making, while it runs.</summary>
    internal Task Work { get; set; } = Task.CompletedTask;
}

/// <summary>A matching voice for each video (voice-lab.md §6.13, ADR-R45; Mac <c>VoiceLabSession+PerVideo</c>): the remembered answer, the
/// anchor, making a video's voice from its own owner-verified speech under the anchor's consent, using it, and removing the previous
/// video's voice through the existing deletion, with a backed-off retry and Settings' note. Behind the closed parity gate
/// (<see cref="VoiceSpeakerCheck.WindowsNativeParityVerified"/> false) the backend has no speaker check
/// (<see cref="IVoiceLabBackend.LearningAvailable"/> is false), so nothing here is offered, made, used, removed or paid for.</summary>
internal sealed partial class VoiceLabSession
{
    internal const string VideoVoiceQuestion = "Make a matching voice from this video? Your takes will sound like this recording. The previous video's voice is removed.";
    private readonly Dictionary<string, VideoVoiceState> videoVoices = new(StringComparer.Ordinal);
    private CancellationTokenSource? removalRetry;

    /// <summary>What Voice Lab remembers about per-video voices, as last read or written.</summary>
    internal VoicePerVideoBook PerVideoBook { get; private set; } = new();
    /// <summary>Settings › Voices' one line while a removal is owed; null when none is.</summary>
    internal string? PerVideoNote { get; private set; }
    /// <summary>The voices of open Rewrites holding paid takes nobody used or discarded yet: those voices are not removed until they are.</summary>
    internal Func<IReadOnlySet<string>> PendingTakeVoices { get; set; } = () => new HashSet<string>(StringComparer.Ordinal);
    /// <summary>This run's state per video content key.</summary>
    internal IReadOnlyDictionary<string, VideoVoiceState> VideoVoices => videoVoices;
    /// <summary>A background retry of an owed removal is scheduled.</summary>
    internal bool RemovalRetryScheduled => removalRetry is not null;
    /// <summary>The scheduled retry: it waits for the earliest owed removal, then runs the removals.</summary>
    internal Task RemovalRetryWork { get; private set; } = Task.CompletedTask;

    /// <summary>The remembered answer: Settings › Voices shows and changes it; Claude mode only reads it.</summary>
    internal VoicePerVideo.Mode VideoVoiceMode => VoicePerVideo.FromSetting(Backend.MatchEachVideo());

    /// <summary>Stores the answer (<c>voiceLab.matchEachVideo</c>): Ask clears it.</summary>
    internal async Task SetVideoVoiceModeAsync(VoicePerVideo.Mode mode)
    {
        if (!Enabled) return;
        await Backend.SetMatchEachVideoAsync(VoicePerVideo.ToSetting(mode), Lifetime);
        Notify();
    }

    /// <summary>"free": the catalogue's creation price; null (and the opt-in says so) when it has none.</summary>
    internal string? VideoVoicePrice => Backend.VideoVoicePrice();

    internal VideoVoiceState VideoVoice(string contentKey)
    {
        if (!videoVoices.TryGetValue(contentKey, out var state)) videoVoices[contentKey] = state = new(contentKey);
        return state;
    }

    /// <summary>The consent voice per-video voices are made from and fall back to: an active voice in the project's statement language that
    /// is not a video's own, Settings' "Use for Rewrite" choice first (Mac <c>anchorVoice</c>).</summary>
    internal VoiceConsentRecord? AnchorVoice(string? language)
    {
        var primary = CreateVoiceSession.StatementLanguage(language, _ => true);
        var anchors = Records.Where(record => record.Status == VoiceConsentStatus.Active && record.Language == primary &&
            !PerVideoBook.IsVideoVoice(record.RecordId)).ToArray();
        var preferred = Backend.RewriteVoice();
        return anchors.FirstOrDefault(record => record.RecordId == preferred) ?? anchors.FirstOrDefault();
    }

    /// <summary>The voice Rewrite starts with in a video: its own voice when matching is on and it has one, otherwise the anchor, never
    /// another video's voice.</summary>
    internal string? RewriteVoicePreference(string contentKey, string? language)
    {
        if (VideoVoiceMode == VoicePerVideo.Mode.Match && PerVideoBook.VideoFor(contentKey) is { } video &&
            Records.Any(record => record.RecordId == video.RecordId && record.Status == VoiceConsentStatus.Active)) return video.RecordId;
        return AnchorVoice(language)?.RecordId;
    }

    /// <summary>The opt-in can be offered in this project: Voice Lab is on, the project is transcribed in a language a voice can be listed
    /// in, its anchor was made from videos (an attested <c>/2</c> voice, whose consent clip goes first), and the speaker check for it is
    /// ready on this PC. Behind the closed parity gate it never is.</summary>
    internal bool OffersVideoVoice(Project project)
    {
        if (!Enabled || project.Transcript is null || string.IsNullOrEmpty(project.Media.Source.ContentKey) ||
            VoicesUnavailable(project.Transcript.Language, SpeakerCalibrated)) return false;
        return AnchorVoice(project.Transcript.Language) is { ProjectConsent: not null } anchor && Backend.LearningAvailable(anchor.Language);
    }

    /// <summary>Settings › Voices shows "Each video": an attested voice can be matched on this PC, or the book still holds something.</summary>
    internal bool ShowsVideoVoiceRows => Enabled && (Records.Any(record => record.Status == VoiceConsentStatus.Active && record.ProjectConsent is not null &&
        Backend.LearningAvailable(record.Language)) || PerVideoBook.Videos.Count > 0 || PerVideoBook.Removals.Count > 0 || PerVideoBook.Measurements.Count > 0);

    /// <summary>Reads the book after the records (Mac <c>loadPerVideo</c>): a voice deleted elsewhere is no longer any video's, and a failed
    /// removal schedules its retry.</summary>
    private async Task LoadPerVideoAsync(int version, CancellationToken ct)
    {
        if (Backend.PerVideoStore is not { } store) { await Dispatch(() => { if (Current(version)) PerVideoNote = RemovalNote(PerVideoBook); }); return; }
        var book = await store.LoadAsync(ct);
        var records = Records;
        var gone = records.Where(record => record.Status == VoiceConsentStatus.Deleted).Select(record => record.RecordId).ToHashSet(StringComparer.Ordinal);
        var known = records.Select(record => record.RecordId).ToHashSet(StringComparer.Ordinal);
        bool Stale(string id) => gone.Contains(id) || !known.Contains(id);
        if (records.Count > 0 && (book.Videos.Any(video => Stale(video.RecordId)) || book.Removals.Any(removal => Stale(removal.RecordId))))
        {
            var cleaned = book with { Videos = book.Videos.Where(video => !Stale(video.RecordId)).ToArray(), Removals = book.Removals.Where(removal => !Stale(removal.RecordId)).ToArray() };
            try { book = await store.UpdateAsync(_ => cleaned, ct); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException) { book = cleaned; }
        }
        var retry = false;
        await Dispatch(() =>
        {
            if (!Current(version)) return;
            PerVideoBook = book; PerVideoNote = RemovalNote(book);
            retry = book.Removals.Any(removal => removal.LastError is not null);
        });
        if (retry) ScheduleRemovalRetry();
    }

    private async Task<VoicePerVideoBook> UpdateBookAsync(Func<VoicePerVideoBook, VoicePerVideoBook> change)
    {
        var book = PerVideoBook;
        if (Backend.PerVideoStore is { } store)
            try { book = await store.UpdateAsync(change, Lifetime); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException) { book = change(book); }
        else book = change(book);
        await Dispatch(() => { PerVideoBook = book; PerVideoNote = RemovalNote(book); Notify(); });
        return book;
    }

    /// <summary>Makes this video's own voice, or returns the state already making or holding one (Mac <c>makeVideoVoice</c>). Only with the
    /// stored answer "match": the opt-in's click is the approval for this and every later video.</summary>
    internal VideoVoiceState MakeVideoVoice(Project project, string media)
    {
        var key = project.Media.Source.ContentKey;
        var state = VideoVoice(key);
        if (!state.Work.IsCompleted || !Enabled || VideoVoiceMode != VoicePerVideo.Mode.Match || state.Phase == VideoVoicePhase.Making) return state;
        if (PerVideoBook.VideoFor(key) is { } video &&
            Records.FirstOrDefault(record => record.RecordId == video.RecordId && record.Status == VoiceConsentStatus.Active) is { } made)
        {
            state.Phase = VideoVoicePhase.Ready; state.RecordId = made.RecordId;
            state.Line = $"Takes in this video use {made.VoiceName}, made from this video.";
            return state;
        }
        if (state.Phase == VideoVoicePhase.Ready) { state.Phase = VideoVoicePhase.Idle; state.RecordId = null; }
        var owner = AnchorVoice(project.Transcript?.Language);
        // The gate: no speaker check here, nothing is found, made or sent.
        if (owner is not null && !Backend.LearningAvailable(owner.Language)) return state;
        if (PerVideoBook.ShortNoted.Contains(key) && state.Phase != VideoVoicePhase.Anchor)
        {
            // Said once already, in an earlier run: no note again.
            state.Phase = VideoVoicePhase.Anchor; state.Line = "";
            return state;
        }
        if (state.Phase == VideoVoicePhase.Anchor) return state;
        if (owner is not { ProjectConsent: not null } anchor)
        {
            state.Phase = VideoVoicePhase.Anchor;
            state.Line = owner is null ? "" : $"Takes use {owner.VoiceName}: only a voice made from your videos can be matched to a video.";
            return state;
        }
        state.Phase = VideoVoicePhase.Making;
        state.Line = "Finding your clearest speech in this video… Nothing is sent yet.";
        Notify();
        state.Work = RunVideoVoiceAsync(state, project, media, anchor);
        return state;
    }

    /// <summary>Too little of the video's own verified speech: the anchor, said once.</summary>
    internal static string ShortLine(long milliseconds, string anchor) =>
        $"This video has only {VoiceRebuild.Amount(milliseconds)} of your own clear speech, so takes use {anchor}. A matching voice needs {VoiceRebuild.Amount(VoicePerVideo.MinimumVideoMs)}.";

    private async Task RunVideoVoiceAsync(VideoVoiceState state, Project project, string media, VoiceConsentRecord anchor)
    {
        await Task.Yield();
        var key = project.Media.Source.ContentKey;
        var owner = RebuildName(anchor.VoiceName);
        try
        {
            var found = await Task.Run(() => Backend.FindVideoVoiceAsync(anchor.RecordId, new(project, media), Lifetime), Lifetime);
            Lifetime.ThrowIfCancellationRequested();
            if (Busy) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            var title = VoicePerVideo.Title(project.Media.Source.AbsolutePath);
            await Dispatch(() =>
            {
                state.Line = $"Making a matching voice from {VoiceRebuild.Amount(found.VideoMilliseconds)} of this video in your ElevenLabs account…";
                Busy = true; Notify();
            });
            VoiceRebuildCreated created;
            // The anchor's attestations are the consent this voice is made under; its consent clip is the first file.
            try { created = await Task.Run(() => Backend.CreateVideoVoiceAsync(anchor, found, VoicePerVideo.DisplayName(owner, title), Lifetime), Lifetime); }
            finally { await Dispatch(() => { Busy = false; Notify(); }); }
            var record = created.Record;
            Backend.SeedRateCalibration(anchor.RecordId, record.RecordId);
            var video = new VoicePerVideoBook.Video(key, record.RecordId, anchor.RecordId, anchor.ReferenceAudioSha256, Scalars(title, 200),
                Timestamp(Clock.GetUtcNow()), found.VideoMilliseconds / 1_000.0, found.RemovesBackgroundNoise);
            await UpdateBookAsync(book => book.Adding(video));
            await LoadAsync(recover: false);
            Backend.Log($"per-video voice made video={key[..Math.Min(8, key.Length)]} speech_ms={found.VideoMilliseconds} files={found.PieceSeconds.Count} noise_removal={(found.RemovesBackgroundNoise ? "true" : "false")}");
            if (record.Status != VoiceConsentStatus.Active)
            {
                await Dispatch(() =>
                {
                    state.Phase = VideoVoicePhase.Failed;
                    state.Line = $"ElevenLabs needs to verify this video's voice before it can be used. Finish verification on elevenlabs.io. Takes use {owner}.";
                    Notify();
                });
                return;
            }
            await Dispatch(() =>
            {
                state.Phase = VideoVoicePhase.Ready; state.RecordId = record.RecordId;
                state.Line = $"Takes in this video use {record.VoiceName}, made from this video.";
                Notify();
            });
            await RemovePreviousVideoVoicesAsync();
        }
        catch (VoiceRebuildNotEnoughException error)
        {
            await UpdateBookAsync(book => book.ShortNoted.Contains(key) ? book : book with { ShortNoted = book.ShortNoted.Append(key).TakeLast(256).ToArray() });
            await Dispatch(() => { state.Phase = VideoVoicePhase.Anchor; state.Line = ShortLine(error.Milliseconds, owner); Notify(); });
        }
        catch (OperationCanceledException)
        {
            await Dispatch(() => { state.Phase = VideoVoicePhase.Idle; state.Line = ""; Notify(); });
        }
        catch (VoiceLabRebuildSaveException error)
        {
            await Dispatch(() => UnsavedRecord = error.Record);
            await LoadAsync(recover: false);
            await Dispatch(() =>
            {
                state.Phase = VideoVoicePhase.Failed;
                state.Line = $"ElevenLabs made this video's voice, but its consent record couldn't be saved. Retry saving it in Settings › Voices. Takes use {owner}.";
                Notify();
            });
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            await LoadAsync(recover: false);
            await Dispatch(() =>
            {
                state.Phase = VideoVoicePhase.Failed;
                state.Line = $"Couldn't make this video's voice. {RebuildError(error)} Takes use {owner}.";
                Notify();
            });
        }
    }

    /// <summary>Removes every previous video's voice the book owes, through the existing deletion (creator binding, journal, tombstone).
    /// Never the anchor or the current video's voice, and not yet one an open Rewrite still holds unused paid takes of. A failure stays owed:
    /// a one-line note in Settings › Voices and a retry in the background, backing off from 30 s to an hour.</summary>
    internal async Task RemovePreviousVideoVoicesAsync(DateTimeOffset? now = null)
    {
        var book = PerVideoBook;
        if (book.Removals.Count == 0 || !Enabled) return;
        var at = now ?? Clock.GetUtcNow();
        var pending = PendingTakeVoices();
        var current = book.Videos.Select(video => video.RecordId).ToHashSet(StringComparer.Ordinal);
        var anchors = Records.Where(record => record.Status == VoiceConsentStatus.Active && !book.IsVideoVoice(record.RecordId))
            .Select(record => record.RecordId).ToHashSet(StringComparer.Ordinal);
        HashSet<string> drop = new(StringComparer.Ordinal);
        Dictionary<string, VoicePerVideoBook.Removal> replace = new(StringComparer.Ordinal);
        foreach (var removal in book.Removals)
        {
            if (Records.FirstOrDefault(record => record.RecordId == removal.RecordId) is not { Status: not VoiceConsentStatus.Deleted } record)
            { drop.Add(removal.RecordId); continue; }
            var anchorId = anchors.Contains(record.RecordId) ? record.RecordId : book.Videos.FirstOrDefault()?.AnchorId ?? "";
            var keep = VoicePerVideo.Kept(record.RecordId, anchorId, current.Contains(record.RecordId) ? record.RecordId : "", pending);
            if (keep is VoicePerVideo.Keep.Anchor or VoicePerVideo.Keep.Current) { drop.Add(removal.RecordId); continue; }
            if (keep is VoicePerVideo.Keep.PendingTakes) { replace[removal.RecordId] = removal with { LastError = null, NextAttemptAt = null }; continue; }
            try
            {
                await Task.Run(() => Backend.DeleteAsync(record.RecordId, Lifetime), Lifetime);
                drop.Add(removal.RecordId);
                Backend.Log($"per-video voice removed attempts={removal.Attempts + 1}");
            }
            catch (OperationCanceledException) when (Lifetime.IsCancellationRequested) { return; }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                var attempts = removal.Attempts + 1;
                var delay = Math.Min(3_600, 30 * Math.Pow(2, Math.Min(attempts - 1, 7)));
                replace[removal.RecordId] = removal with
                {
                    Attempts = attempts, LastError = Scalars(RebuildError(error), 300), NextAttemptAt = Timestamp(at.AddSeconds(delay))
                };
                Backend.Log($"per-video voice removal failed attempts={attempts}");
            }
        }
        await UpdateBookAsync(stored => stored with
        {
            Removals = stored.Removals.Where(removal => !drop.Contains(removal.RecordId))
                .Select(removal => replace.GetValueOrDefault(removal.RecordId) ?? removal).ToArray()
        });
        await LoadAsync(recover: false);
        if (PerVideoBook.Removals.Any(removal => removal.LastError is not null)) ScheduleRemovalRetry();
    }

    /// <summary>Settings › Voices' one line while a removal is owed (Mac <c>removalNote</c>).</summary>
    internal static string? RemovalNote(VoicePerVideoBook book)
    {
        var failed = book.Removals.Where(removal => removal.LastError is not null).ToArray();
        if (failed.Length > 0)
        {
            var more = failed.Length > 1 ? $" and {failed.Length - 1} more" : "";
            return $"Couldn't remove the voice for {failed[0].Title}{more} yet. VoxClip retries in the background.";
        }
        return book.Removals.FirstOrDefault() is { } waiting ? $"The voice for {waiting.Title} is removed once its unused takes are used or discarded." : null;
    }

    /// <summary>Retries owed removals when the earliest is due, in the background, until the session ends.</summary>
    private void ScheduleRemovalRetry()
    {
        removalRetry?.Cancel(); removalRetry?.Dispose(); removalRetry = null;
        var due = PerVideoBook.Removals.Select(removal => DateTimeOffset.TryParse(removal.NextAttemptAt, CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out var at) ? at : (DateTimeOffset?)null).Where(at => at is not null).Min();
        if (due is not { } next || !Enabled) return;
        removalRetry = CancellationTokenSource.CreateLinkedTokenSource(Lifetime);
        // Between a second and the backoff's ceiling of an hour, whatever the stored time says.
        var delay = TimeSpan.FromSeconds(Math.Clamp((next - Clock.GetUtcNow()).TotalSeconds, 1, 3_600));
        RemovalRetryWork = RetryRemovalsLaterAsync(delay, removalRetry.Token);
    }

    private async Task RetryRemovalsLaterAsync(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Task.Delay(delay, Clock, ct);
            if (!ct.IsCancellationRequested) await RemovePreviousVideoVoicesAsync();
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    }

    /// <summary>"Did matching help" (Mac <c>recordTakeMatch</c>): a take's speaker cosine against the original speech beside it, measured on
    /// this PC. The first take with a video's own voice is kept for that video; the anchor's takes in the video are pooled (mean).</summary>
    internal async Task RecordTakeMatchAsync(string contentKey, string title, string recordId, double score)
    {
        if (!double.IsFinite(score) || score is < -1 or > 1) return;
        var isVideoVoice = PerVideoBook.VideoFor(contentKey)?.RecordId == recordId;
        var isAnchor = !PerVideoBook.IsVideoVoice(recordId);
        var old = PerVideoBook.Measurements.FirstOrDefault(measurement => measurement.ContentKey == contentKey);
        if (isVideoVoice && old?.VideoVoice is not null || !isVideoVoice && !isAnchor) return;
        double? anchorScore = isAnchor ? old?.Anchor is { } pooled ? (pooled + score) / 2 : score : null;
        var measurement = new VoicePerVideoBook.Measurement(contentKey, Scalars(title, 200), isVideoVoice ? score : null, anchorScore, Timestamp(Clock.GetUtcNow()));
        await UpdateBookAsync(book => book.Measuring(measurement));
        Backend.Log($"per-video take match video={contentKey[..Math.Min(8, contentKey.Length)]} voice={(isVideoVoice ? "video" : "anchor")} score={score.ToString("F3", CultureInfo.InvariantCulture)}");
        if (!isVideoVoice) return;
        // The first take with the video's own voice: the anchor's earlier takes give it something to compare with.
        if (PerVideoBook.Measurements.FirstOrDefault(stored => stored.ContentKey == contentKey) is { } recorded) LogMatchComparison(recorded);
        _ = MeasureAnchorBaselineAsync();
    }

    /// <summary>A take's speaker cosine against the speech beside it, on this PC; null without a speaker check (the closed gate).</summary>
    internal Task<double?> ScoreTakeMatchAsync(VoiceLabTakeAudio take, VoiceLabTakeInput input) =>
        Enabled ? Backend.ScoreTakeMatchAsync(take, input, Lifetime) : Task.FromResult<double?>(null);

    /// <summary>Settings › Voices' diagnostic for one video (Mac <c>matchLine</c>): "DJI_0030: its own voice 0.71 · siim 0.54".</summary>
    internal static string MatchLine(VoicePerVideoBook.Measurement measurement, string anchor)
    {
        static string Score(double value) => value.ToString("F2", CultureInfo.InvariantCulture);
        string?[] parts = [measurement.VideoVoice is { } own ? "its own voice " + Score(own) : null, measurement.Anchor is { } pooled ? $"{anchor} {Score(pooled)}" : null];
        return measurement.Title + ": " + string.Join(" · ", parts.Where(part => part is not null));
    }

    /// <summary>Settings › Voices' line under "Each video" for the stored answer (Mac <c>VideoVoiceRows.modeLine</c>).</summary>
    internal static string ModeLine(VoicePerVideo.Mode mode, string anchor) => mode switch
    {
        VoicePerVideo.Mode.Match => $"Each video gets a voice made from its own speech, so takes sound like that recording. The previous video's voice is removed; {anchor} stays.",
        VoicePerVideo.Mode.Anchor => $"Every video uses {anchor}.",
        _ => "Rewrite asks once, on the next video that needs your voice."
    };

    /// <summary>The three answers Settings › Voices offers, in the Mac's order.</summary>
    internal static IReadOnlyList<(VoicePerVideo.Mode Mode, string Title)> ModeChoices(string anchor) =>
        [(VoicePerVideo.Mode.Match, "Make a matching voice"), (VoicePerVideo.Mode.Anchor, "Use " + anchor), (VoicePerVideo.Mode.Ask, "Ask in Rewrite")];

    /// <summary>The anchor's short name for Settings and the Rewrite card ("siim"), or "your voice" with none.</summary>
    internal string AnchorName(string? language) => AnchorVoice(language) is { } anchor ? RebuildName(anchor.VoiceName) : "your voice";

    /// <summary>One video's row in Settings › Voices: "siim · car (VoxClip) · 41 s of car, background noise removed".</summary>
    internal string VideoLine(VoicePerVideoBook.Video video)
    {
        var name = Records.FirstOrDefault(record => record.RecordId == video.RecordId)?.VoiceName ?? video.Title;
        return $"{name} · {VoiceRebuild.Amount((long)Math.Round(video.VideoSeconds * 1_000))} of {video.Title}{(video.RemovesBackgroundNoise ? ", background noise removed" : "")}";
    }

    private static string Timestamp(DateTimeOffset value) => value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    private static string Scalars(string text, int limit) => string.Concat(text.EnumerateRunes().Take(limit).Select(rune => rune.ToString()));
}

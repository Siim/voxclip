using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>A matching voice for each video in Rewrite (voice-lab.md §6.13, ADR-R45; design.md R2 "A matching voice for this video"; Mac
/// <c>RewriteVideoVoice.swift</c>): the one-time inline question, the video's own voice made before any take is priced, and the take-match
/// diagnostic. ✦ Make it postable and ✦ Claude does it all reach it through <see cref="DiscoverWindowsAsync"/>; they never press the card,
/// so with the answer unset their takes use the anchor, and with the stored answer "match" they make the voice like a manual run. Behind the
/// closed parity gate <see cref="VoiceLabSession.OffersVideoVoice"/> is false: no card, nothing made, and Rewrite keeps the voice it had.</summary>
internal sealed partial class RewriteSession
{
    internal const string VideoVoiceCardId = "Rewrite.Steps.VideoVoice";
    internal const string VideoVoiceMatchChip = "Rewrite.Chip.VideoVoiceMatch";
    internal const string VideoVoiceAnchorChip = "Rewrite.Chip.VideoVoiceAnchor";
    internal const string VideoVoiceRetryChip = "Rewrite.Chip.VideoVoiceRetry";
    internal const string VideoVoiceSends = " Only your clearest speech from this video is sent to ElevenLabs; no video.";
    private VoiceLabSession? videoVoiceLab;
    private Func<string?> videoMedia = () => null;
    private readonly HashSet<Guid> videoVoiceMeasured = [];

    /// <summary>The last chip's work (Match this video, Try Again): the video's voice made and chosen.</summary>
    internal Task VideoVoiceWork { get; private set; } = Task.CompletedTask;
    /// <summary>The take-match diagnostic's last scoring, in the background.</summary>
    internal Task VideoVoiceMatchWork { get; private set; } = Task.CompletedTask;

    /// <summary>Connects this Rewrite to Voice Lab's per-video voices and the project's resolved source media.</summary>
    internal void ConfigureVideoVoice(VoiceLabSession voiceLab, Func<string?> media)
    {
        if (videoVoiceLab is not null) videoVoiceLab.Changed -= VideoVoiceLabChanged;
        videoVoiceLab = voiceLab;
        videoMedia = media;
        voiceLab.Changed += VideoVoiceLabChanged;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void VideoVoiceLabChanged(object? sender, EventArgs args) { if (IsOpen) Changed?.Invoke(this, EventArgs.Empty); }
    private void DisconnectVideoVoice() { if (videoVoiceLab is not null) videoVoiceLab.Changed -= VideoVoiceLabChanged; }

    /// <summary>The opt-in applies here: the gate is open, an attested anchor exists and the source media is found.</summary>
    private bool OffersVideoVoiceHere => videoVoiceLab is { } lab && lab.OffersVideoVoice(Project) && videoMedia() is { Length: > 0 };

    /// <summary>The voice Rewrite starts with here (Mac <c>preferredVoiceForVideo</c>): this video's own when it has one, otherwise the anchor.
    /// Null where the opt-in doesn't apply, so the window's own preference (<c>voiceLab.rewriteVoice</c>) decides as before.</summary>
    internal string? PreferredVoiceForVideo =>
        OffersVideoVoiceHere ? videoVoiceLab!.RewriteVoicePreference(Project.Media.Source.ContentKey, Project.Transcript?.Language) : null;

    /// <summary>Every new take window prefers this video's voice, then its own preference.</summary>
    private void PreferVideoVoice(RewriteGeneration window)
    {
        var fallback = window.PreferredVoice;
        window.PreferredVoice = () => PreferredVoiceForVideo ?? fallback?.Invoke();
    }

    /// <summary>The voices of this Rewrite's phrases that hold paid takes not used or discarded yet: their voices are kept.</summary>
    internal IReadOnlySet<string> PendingTakeVoices => IsOpen
        ? generationWindows.Where(window => window.HasPaidTakes && window.VoiceId is not null).Select(window => window.VoiceId!).ToHashSet(StringComparer.Ordinal)
        : new HashSet<string>(StringComparer.Ordinal);

    /// <summary>Before a price (Mac <c>ensureVideoVoice</c>): with the stored answer "match", this video's voice is made (or the one being
    /// made is awaited) and chosen, so every take of every clip in the video uses it. A run with paid takes keeps its voice.</summary>
    internal async Task EnsureVideoVoiceAsync()
    {
        if (videoVoiceLab is not { } lab || lab.VideoVoiceMode != VoicePerVideo.Mode.Match || !OffersVideoVoiceHere || generationWindows.Count == 0 || HasPaidTakes) return;
        var state = lab.MakeVideoVoice(Project, videoMedia()!);
        if (!state.Work.IsCompleted)
        {
            Changed?.Invoke(this, EventArgs.Empty);
            await state.Work;
        }
        if (!GenerationIsCurrent || HasPaidTakes || state.Phase != VideoVoicePhase.Ready || state.RecordId is not { } id) return;
        foreach (var window in generationWindows.ToArray())
        {
            if (!window.HasDiscovered || window.VoiceId == id) continue;
            // Listed before the voice existed: list again, and the window starts with it.
            if (!window.Voices.Any(voice => voice.Id == id)) await window.DiscoveryInputsChangedAsync();
            await window.ChooseVoiceAsync(id);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The panel's card for this video's voice, or null (Mac <c>videoVoiceSteps</c>): the question while the answer is unset, then
    /// what the video's voice is doing. Every chip acts; nothing here is disabled.</summary>
    internal RewriteNextStepCard? VideoVoiceCard
    {
        get
        {
            if (videoVoiceLab is not { } lab || Review is null || PricedVoiceHunks.Count == 0 || !OffersVideoVoiceHere ||
                lab.AnchorVoice(Project.Transcript?.Language) is not { } anchor) return null;
            var name = VoiceLabSession.RebuildName(anchor.VoiceName);
            switch (lab.VideoVoiceMode)
            {
                case VoicePerVideo.Mode.Anchor:
                    return null;
                case VoicePerVideo.Mode.Ask:
                    if (HasPaidTakes) return null;
                    var price = lab.VideoVoicePrice;
                    var unknown = price is null ? " VoxClip's price list has no price for making a voice." : "";
                    return new(VideoVoiceCardId, VoiceLabSession.VideoVoiceQuestion + VideoVoiceSends + unknown,
                    [
                        new(VideoVoiceMatchChip, "Match this video · " + (price ?? "price unknown"), false, MatchThisVideoAsync),
                        new(VideoVoiceAnchorChip, "Use " + name, false, UseAnchorForVideosAsync)
                    ], Asks: false);
                default:
                    if (!lab.VideoVoices.TryGetValue(Project.Media.Source.ContentKey, out var state) || state.Line.Length == 0) return null;
                    switch (state.Phase)
                    {
                        case VideoVoicePhase.Making:
                            return new(VideoVoiceCardId, state.Line, [], Asks: false);
                        case VideoVoicePhase.Anchor:
                            // Said once: in the first Rewrite that found too little of the video's own speech.
                            if (state.NotedIn is not null && !ReferenceEquals(state.NotedIn, this)) return null;
                            state.NotedIn = this;
                            return new(VideoVoiceCardId, state.Line, [], Asks: false);
                        case VideoVoicePhase.Failed:
                            if (HasPaidTakes) return new(VideoVoiceCardId, state.Line, [], Asks: false);
                            return new(VideoVoiceCardId, state.Line, [new(VideoVoiceRetryChip, "Try Again", false, () =>
                            {
                                state.Phase = VideoVoicePhase.Idle; state.Line = "";
                                return StartVideoVoiceAsync();
                            })], Asks: false);
                        default:
                            return null;
                    }
            }
        }
    }

    /// <summary>"Match this video · price": the one-time opt-in, remembered; the video's voice is made now.</summary>
    private async Task MatchThisVideoAsync()
    {
        if (videoVoiceLab is not { } lab) return;
        await lab.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Match);
        AutoFix.Announcement = "Matching voice on. Making a voice from this video.";
        await StartVideoVoiceAsync();
    }

    /// <summary>"Use siim": every video keeps the anchor, remembered; Settings › Voices can change it.</summary>
    private async Task UseAnchorForVideosAsync()
    {
        if (videoVoiceLab is not { } lab) return;
        await lab.SetVideoVoiceModeAsync(VoicePerVideo.Mode.Anchor);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private Task StartVideoVoiceAsync()
    {
        VideoVoiceWork = EnsureVideoVoiceAsync();
        Changed?.Invoke(this, EventArgs.Empty);
        return VideoVoiceWork;
    }

    /// <summary>The take-match diagnostic (Mac <c>measureVideoVoiceMatch</c>): each paid take, once, against the original speech beside it,
    /// on this PC, in the background; Voice Lab keeps the first with the video's own voice and pools the anchor's.</summary>
    private void MeasureVideoVoiceMatch()
    {
        if (videoVoiceLab is not { } lab || !OffersVideoVoiceHere) return;
        List<(VoiceLabTakeAudio Audio, VoiceLabTakeInput Input)> work = [];
        foreach (var window in generationWindows)
            foreach (var row in window.Rows)
            {
                if (row.Receipt is null || row.Audio is not { } audio || window.IsRecorded(row.Id) || videoVoiceMeasured.Contains(row.Id) ||
                    window.InputFor(row.Id) is not { } input) continue;
                videoVoiceMeasured.Add(row.Id);
                work.Add((audio, input));
            }
        if (work.Count == 0) return;
        var key = Project.Media.Source.ContentKey;
        var title = VoicePerVideo.Title(Project.Media.Source.AbsolutePath);
        var previous = VideoVoiceMatchWork;
        VideoVoiceMatchWork = MeasureAsync();
        async Task MeasureAsync()
        {
            await previous;
            foreach (var (audio, input) in work)
            {
                double? score;
                try { score = await Task.Run(() => lab.ScoreTakeMatchAsync(audio, input)); }
                catch (Exception error) when (error is not OutOfMemoryException) { continue; }
                if (score is { } value) await lab.RecordTakeMatchAsync(key, title, input.RecordId, value);
            }
        }
    }
}

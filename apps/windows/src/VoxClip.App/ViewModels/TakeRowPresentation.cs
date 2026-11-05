using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Pure R11 row content. The editor owns selection, mono styling and whole-run retry.</summary>
public sealed record TakeRowPresentation(string Title, string Duration, string Note, string AutomationName,
    string PlayName, string RejectName, bool Selectable, bool BestMatch, string? FailureText)
{
    public bool JoinAdvisory { get; init; }
    public string Copy => Title + " · " + Duration + " · " + Note;
    /// <summary>Accessible name while the row's Play button shows Pause.</summary>
    public string PauseName => PlayName.Length > 0 ? "Pause" + PlayName[4..] : "";
    public string PlayHelp => Selectable ? PlayName : PlayName.EndsWith(", not checked", StringComparison.Ordinal)
        ? "Listen to this take as ElevenLabs returned it. It was not checked and stays left out."
        : "Listen to this take. It stays left out.";
    /// <summary>A passing take's join advisory, a note rather than a choice (ADR-R39).</summary>
    public const string JoinNote = "join may sound slightly louder";
    /// <summary>Indexes are Core's zero-based take indexes; bestId is the exact ranked best take.</summary>
    public static TakeRowPresentation From(VoiceLabTakeRow row, Guid? bestId, int phraseNumber = 1)
    {
        var number = (row.Index + 1).ToString(CultureInfo.InvariantCulture);
        var title = "Take " + number;
        if (row.Stopped)
            return new(title, "", "", title + ", stopped", "", "", false, false, title + " stopped.");
        // ADR-R37: a short take waits for its run's pooled voice check; it can't be chosen yet and has failed nothing.
        if (row.VoiceCheck is VoiceLabTakeVoiceCheck.WaitingCheck && row.Failure is null && row.ShortPhraseCopy is { } waiting)
            return new(title, "", waiting, title + ", " + waiting, "", "", false, false, null);
        if (!row.Selectable)
        {
            var notChecked = row.Audio is null && row.Generated is not null;
            var copy = title + (notChecked ? " · not checked: " : ": ") + FailureReason(row) + " Left out.";
            var play = row.Audio is not null || notChecked
                ? "Play phrase " + phraseNumber.ToString(CultureInfo.InvariantCulture) + ", take " + number + (notChecked ? ", not checked" : "") : "";
            return new(title, "", "", copy, play, "", false, false, copy);
        }
        var audio = row.Audio!;
        var duration = (audio.Fit.Plan.OutputFrames / (double)audio.SampleRate).ToString("F1", CultureInfo.InvariantCulture) + " s";
        var best = row.Id == bestId;
        // ADR-R39: a join advisory is a note on the take's row, "join may sound slightly louder", beside its ▶; the take is
        // chosen like any other, automatically when it ranks best.
        if (row.HasJoinAdvisory)
        {
            var advisory = (best ? "Best match · " : "") + JoinNote;
            return new(title, duration, advisory, title + ", " + duration + ", " + advisory,
                "Play take " + number + ", join advisory", "Reject take " + number, true, best, null) { JoinAdvisory = true };
        }
        var frames = audio.Fit.Plan.Edits.Sum(edit => edit.Kind == VoiceLabFitEditKind.Insert ? edit.Count : -edit.Count);
        var fit = best ? "Best match" : VoiceLabPauseFitNote.Format(frames / (double)audio.SampleRate);
        // ADR-R37: a pooled check names its takes; an unmeasured voice says so, and only a click chooses it.
        var note = row.ShortPhraseCopy is { } voice ? (best ? "Best match · " + voice : voice) : fit;
        return new(title, duration, note, title + ", " + duration + ", " + note,
            "Play take " + number, "Reject take " + number, true, best, null);
    }

    private static string FailureReason(VoiceLabTakeRow row)
    {
        if (row.Failure is VoiceLabException provider) return provider.Kind switch
        {
            VoiceLabErrorKind.InvalidAlignment => "The take's word timing could not be validated.",
            VoiceLabErrorKind.InvalidAudio => "The take's audio could not be validated.",
            VoiceLabErrorKind.Network => "The provider request failed because of a connection problem. Checks may be incomplete.",
            VoiceLabErrorKind.MalformedResponse => "The provider returned an unreadable response. Checks may be incomplete.",
            VoiceLabErrorKind.SpeakerMismatch => "The speaker verification did not complete successfully. No generated-voice match result is available.",
            VoiceLabErrorKind.PermissionMissing => "The ElevenLabs key is missing a required permission. Your edits are saved.",
            VoiceLabErrorKind.MissingKey => "An ElevenLabs key is required. Your edits are saved.",
            VoiceLabErrorKind.QuotaExceeded => "ElevenLabs says this account is out of credit or over its quota. Your edits are saved.",
            VoiceLabErrorKind.RateLimited => "ElevenLabs is rate limiting this request. Nothing is retried automatically.",
            VoiceLabErrorKind.ProviderFailure => provider.Detail is { } status
                ? "ElevenLabs could not complete the request (" + status + "). Checks may be incomplete."
                : "ElevenLabs could not complete the request. Checks may be incomplete.",
            VoiceLabErrorKind.UnsupportedFormat => "The audio format is not supported for this request.",
            VoiceLabErrorKind.UnsupportedModel or VoiceLabErrorKind.UnsupportedEndpoint => "The selected speech model or operation is not supported.",
            VoiceLabErrorKind.ResponseTooLarge => "The provider response was too large to process. Checks may be incomplete.",
            VoiceLabErrorKind.InvalidInput => "The request inputs could not be validated.",
            VoiceLabErrorKind.ConsentRequired => "Voice consent could not be verified for this request. Your edits are saved.",
            VoiceLabErrorKind.PlanUnavailable => "This request is unavailable on the current provider plan.",
            VoiceLabErrorKind.NoVoiceSlots => "The ElevenLabs account has no available voice slots.",
            _ => RewriteSession.Refusal(provider)
        };
        if (row.Failure is VoiceConsentException consent) return consent.Kind switch
        {
            VoiceConsentError.SpeakerUnavailable => "The speaker check is unavailable. This take could not be verified.",
            VoiceConsentError.SpeakerMismatch => "The speaker verification did not complete successfully. No generated-voice match result is available.",
            VoiceConsentError.InvalidRecord => "The voice consent record could not be verified. Checks may be incomplete.",
            _ => RewriteSession.Refusal(consent)
        };
        if (row.Failure is null && row.Qa is { Passed: false } qa && qa.Failures.Count > 0)
            return string.Join(" ", qa.Failures.Select(failure => failure switch
            {
                VoiceLabTakeQaFailure.InsufficientGeneratedSpeech => "Not enough generated speech for the speaker check. It requires at least 3 seconds of voiced speech; this take could not be verified.",
                VoiceLabTakeQaFailure.Transcript => qa.TranscriptMatch is { } match && double.IsFinite(match)
                    ? "The recognized words did not pass the word check." : "The word check did not complete. No word-match result is available.",
                VoiceLabTakeQaFailure.Speaker => qa.SpeakerScore is { } score && double.IsFinite(score)
                    ? "The voice did not pass the speaker-match check." : "The speaker check did not complete. No speaker-match result is available.",
                VoiceLabTakeQaFailure.Clipping => qa.PeakDbfs is { } peak && double.IsFinite(peak)
                    ? "The audio did not pass the clipping check." : "The clipping check did not complete.",
                VoiceLabTakeQaFailure.Loudness => qa.LufsJumpLu is { } jump && double.IsFinite(jump)
                    ? "The audio did not pass the loudness check at the joins." : "The loudness check at the joins did not complete.",
                _ => "The required checks did not complete. No result is available."
            }));
        return row.Failure is null && row.Qa?.Passed == true ? "The checked audio is unavailable."
            : "The required checks did not complete. No result is available.";
    }

    /// <summary>Preselects the highest-ranked eligible take only after a completed or early-stop run. Core's ranking puts clean
    /// takes before ones with a join advisory, which is chosen when it is the best left (ADR-R39).</summary>
    public static Guid? Preselect(VoiceLabTakeRunResult result, IReadOnlySet<Guid>? rejected = null) =>
        result.End is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop
            ? result.Ranked.FirstOrDefault(row => row.Selectable && rejected?.Contains(row.Id) != true)?.Id : null;

    /// <summary>Live notification for a newly ready row, using its zero-based Core index.</summary>
    public static string Ready(int index) => $"Take {(index + 1).ToString(CultureInfo.InvariantCulture)} ready.";
    /// <summary>Live notification for the fitting take, using its zero-based Core index.</summary>
    public static string Fits(int index) => $"Take {(index + 1).ToString(CultureInfo.InvariantCulture)} fits.";
    /// <summary>Verbatim Mac combined summary. fittedTakeNumber is one-based, unlike row indexes.</summary>
    public static string Completion(int count, int? fittedTakeNumber, int failed = 0)
    {
        var failures = failed == 1 ? "one" : failed == 2 ? "two" : failed.ToString(CultureInfo.InvariantCulture);
        if (fittedTakeNumber is { } number)
            return Fits(number - 1) + (failed > 0 ? " " + char.ToUpperInvariant(failures[0]) + failures[1..] + " failed the speech check." : "");
        var ready = count == 3 ? "Three takes ready." : count == 1 ? "One take ready." : "Two takes ready.";
        return failed > 0 ? ready[..^1] + ", " + failures + " failed the speech check." : ready;
    }
    /// <summary>Verbatim terminal message when no take can be selected. No single-take retry is offered.</summary>
    public const string NonePassed = "These takes didn't sound right. Try different wording or re-record.";
}

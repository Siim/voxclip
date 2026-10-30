using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Pure R11 row content. The editor owns selection, mono styling and whole-run retry.</summary>
public sealed record TakeRowPresentation(string Title, string Duration, string Note, string AutomationName,
    string PlayName, string RejectName, bool Selectable, bool BestMatch, string? FailureText)
{
    /// <summary>Accessible name while the row's Play button shows Pause.</summary>
    public string PauseName => Selectable ? "Pause take " + Title[5..] : "";
    /// <summary>Indexes are Core's zero-based take indexes; bestId is the exact ranked best take.</summary>
    public static TakeRowPresentation From(VoiceLabTakeRow row, Guid? bestId)
    {
        var number = (row.Index + 1).ToString(CultureInfo.InvariantCulture);
        var title = "Take " + number;
        if (!row.Selectable)
            return new(title, "", "", title + ", didn't pass the speech check", "", "", false, false,
                title + " didn't pass the speech check.");
        var audio = row.Audio!;
        var duration = (audio.Fit.Plan.OutputFrames / (double)audio.SampleRate).ToString("F1", CultureInfo.InvariantCulture) + " s";
        var best = row.Id == bestId;
        var frames = audio.Fit.Plan.Edits.Sum(edit => edit.Kind == VoiceLabFitEditKind.Insert ? edit.Count : -edit.Count);
        var note = best ? "Best match" : VoiceLabPauseFitNote.Format(frames / (double)audio.SampleRate);
        return new(title, duration, note, title + ", " + duration + ", " + note,
            "Play take " + number, "Reject take " + number, true, best, null);
    }

    /// <summary>Preselects the highest-ranked eligible take only after a completed or early-stop run.</summary>
    public static Guid? Preselect(VoiceLabTakeRunResult result, IReadOnlySet<Guid>? rejected = null) =>
        result.End is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop
            ? result.Ranked.FirstOrDefault(row => rejected?.Contains(row.Id) != true)?.Id : null;

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

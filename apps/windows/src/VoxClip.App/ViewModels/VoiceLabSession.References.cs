using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>"Let a video teach your voice" in Settings › Voices (voice-lab.md §6.9, ADR-R41; Mac <c>VoiceLabSession+References</c>): each
/// voice says how many of the owner's videos taught the guard, Learn from my videos reads recent projects and the export folder on this
/// PC, and Forget learned references removes them, inline. Nothing is sent anywhere. Learn is offered only where the speaker check is
/// ready (<see cref="IVoiceLabBackend.LearningAvailable"/>), so behind the closed parity gate there is no control that can't act.</summary>
internal sealed partial class VoiceLabSession
{
    private readonly Dictionary<string, string> learningLines = [];
    private CancellationTokenSource? learning;

    /// <summary>The inline line under a voice after Learn or Forget, by record id.</summary>
    internal IReadOnlyDictionary<string, string> LearningLines => learningLines;
    /// <summary>A learning pass is running; the voice rows' learn, forget and rebuild buttons wait for it.</summary>
    internal bool IsLearning => learning is not null;

    /// <summary>The projects to learn from (Mac <c>learningProjects</c>): the recent list, then the <c>.voxclip</c> files at the top of the
    /// export folder in path order, each once. Never Desktop or Documents.</summary>
    internal static IReadOnlyList<string> LearningProjects(IReadOnlyList<string> recent, string exportFolder)
    {
        var paths = recent.ToList();
        try
        {
            if (Path.IsPathFullyQualified(exportFolder) && Directory.Exists(exportFolder))
                paths.AddRange(Directory.EnumerateFiles(exportFolder, "*.voxclip", SearchOption.TopDirectoryOnly)
                    .Where(path => string.Equals(Path.GetExtension(path), ".voxclip", StringComparison.OrdinalIgnoreCase)).Order(StringComparer.Ordinal));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
        var seen = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        return paths.Where(path => Path.IsPathFullyQualified(path) && seen.Add(Path.GetFullPath(path))).ToArray();
    }

    /// <summary>The voice row's line: how many of the owner's videos the guard has learned from.</summary>
    internal static string LearnedLine(VoiceConsentRecord record) => VoiceSpeakerReferences.LearnedCount(record.Speaker) switch
    {
        0 => "Not learned from your videos yet. VoxClip learns your voice from each video you transcribe.",
        1 => "Learned from 1 of your videos",
        var count => $"Learned from {count} of your videos"
    };

    /// <summary>Learn from my videos can act for this voice: it is active, nothing else runs, and the speaker check is ready here.</summary>
    internal bool CanLearn(VoiceConsentRecord record) => LearningOffered(record) && !Busy && !loading && !IsLearning;
    /// <summary>Learn from my videos is shown for this voice: it is active and the speaker check for its language is ready here. Behind the
    /// closed parity gate it never is, so the row shows only what was learned.</summary>
    internal bool LearningOffered(VoiceConsentRecord record) =>
        Enabled && record.Status == VoiceConsentStatus.Active && Backend.LearningAvailable(record.Language);
    /// <summary>Forget learned references can act: the voice holds some.</summary>
    internal bool CanForget(VoiceConsentRecord record) =>
        Enabled && !Busy && !loading && record.Speaker.References is { Length: > 0 };

    /// <summary>Learns a reference for <paramref name="recordId"/> from each of the owner's projects, one at a time, with the progress inline.</summary>
    internal async Task LearnFromVideosAsync(string recordId, IReadOnlyList<string>? projects = null)
    {
        if (Records.FirstOrDefault(record => record.RecordId == recordId) is not { } record || !CanLearn(record)) return;
        var paths = projects ?? Backend.LearningProjects();
        if (paths.Count == 0) { learningLines[recordId] = "Open or export a video first. VoxClip learns from your projects on this PC."; Notify(); return; }
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(Lifetime);
        learning = cancellation;
        var token = cancellation.Token;
        learningLines[recordId] = $"Learning from video 1 of {paths.Count}… Nothing is sent.";
        Notify();
        var learned = 0;
        var other = 0;
        try
        {
            for (var index = 0; index < paths.Count; index++)
            {
                token.ThrowIfCancellationRequested();
                var number = index + 1;
                await Dispatch(() => { learningLines[recordId] = $"Learning from video {number} of {paths.Count}… Nothing is sent."; Notify(); });
                var path = paths[index];
                VoiceReferenceLearnerOutcome? outcome;
                try
                {
                    outcome = await Task.Run(async () => await Backend.ReadProjectAsync(path, token) is { } source
                        ? await Backend.LearnAsync(source, recordId, token) : (VoiceReferenceLearnerOutcome?)null, token);
                }
                catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException) { outcome = null; }
                if (outcome is VoiceReferenceLearnerOutcome.Learned or VoiceReferenceLearnerOutcome.Kept) learned++;
                else if (outcome is VoiceReferenceLearnerOutcome.NotTheOwner) other++;
                else if (outcome is VoiceReferenceLearnerOutcome.Unavailable && index == 0 && !Backend.LearningAvailable(record.Language))
                {
                    await Dispatch(() => learningLines[recordId] = "The speaker check isn't ready. Download it in Voice Lab, then try again.");
                    return;
                }
            }
            await LoadAsync(recover: false);
            await Dispatch(() =>
            {
                var total = Records.FirstOrDefault(item => item.RecordId == recordId) is { } now ? VoiceSpeakerReferences.LearnedCount(now.Speaker) : 0;
                var videos = paths.Count == 1 ? "video" : "videos";
                var summary = learned == 0 ? $"No new speech of yours found in {paths.Count} {videos}." : $"Checked {paths.Count} {videos}: your voice is learned from {total}.";
                if (other > 0) summary += $" {other} didn't sound like you; nothing was kept from {(other == 1 ? "it" : "them")}.";
                learningLines[recordId] = summary;
            });
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        finally
        {
            await Dispatch(() =>
            {
                if (ReferenceEquals(learning, cancellation)) learning = null;
                cancellation.Dispose();
                Notify();
            });
        }
    }

    /// <summary>Forgets every learned reference of a voice. The guard then judges phrases against the consent statement only.</summary>
    internal async Task ForgetLearnedAsync(string recordId)
    {
        if (Records.FirstOrDefault(record => record.RecordId == recordId) is not { } record || !CanForget(record)) return;
        learning?.Cancel();
        string line;
        try
        {
            await Task.Run(() => Backend.ForgetReferencesAsync(recordId, Lifetime), Lifetime);
            line = "Forgot what VoxClip learned from your videos. Your consent statement still checks every phrase.";
        }
        catch (OperationCanceledException) when (Lifetime.IsCancellationRequested) { return; }
        catch (Exception error) when (error is not OutOfMemoryException) { line = "Couldn't forget the learned references. Nothing else changed."; }
        await LoadAsync(recover: false);
        await Dispatch(() => { learningLines[recordId] = line; Notify(); });
    }

    /// <summary>Learns quietly from a project the user just transcribed, for every active voice in its language (Mac
    /// <c>learnFromTranscribed</c>). Does nothing where the speaker check isn't ready.</summary>
    internal async Task LearnFromTranscribedAsync(VoxClip.Core.Domain.Shared.Project project, string media)
    {
        var language = project.Transcript?.Language;
        if (!Enabled || IsLearning || project.Transcript is null) return;
        var source = new VoiceLabProjectSource(project, media);
        var voices = Records.Where(record => record.Status == VoiceConsentStatus.Active && (language is null || record.Language == language) &&
            Backend.LearningAvailable(record.Language)).Select(record => record.RecordId).ToArray();
        if (voices.Length == 0) return;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(Lifetime);
        learning = cancellation;
        try
        {
            foreach (var recordId in voices)
                try { await Task.Run(() => Backend.LearnAsync(source, recordId, cancellation.Token), cancellation.Token); }
                catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException) { }
            await LoadAsync(recover: false);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally
        {
            await Dispatch(() =>
            {
                if (ReferenceEquals(learning, cancellation)) learning = null;
                cancellation.Dispose();
                Notify();
            });
        }
    }
}

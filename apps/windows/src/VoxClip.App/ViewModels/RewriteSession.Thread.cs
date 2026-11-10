using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.ViewModels;

/// <summary>What the AI answers a thread with: the live connector after its inline consent (the Rewrite panel's), or a test's stand-in.</summary>
internal delegate Task<RewriteFollowupReply> RewriteThreadBackend(RewriteFollowupRequest request, CancellationToken ct);

/// <summary>How a version went into the change's place: through the local rediff as the change's one hunk, or, for the recorded words,
/// out of the proposal (nothing to change).</summary>
internal enum RewriteThreadApply { Failed, Applied, LeftOut }

/// <summary>Talk back to Claude about a change (design.md §6.3 "Talk back to Claude" and "Your own words", ADR-R50; Mac
/// <c>RewriteThread.swift</c>). The thread sits under the focused pending change; a version goes in through the local rediff and becomes
/// that change's words for Keep, so it is priced and voiced as any Rewrite change. Nothing is voiced or paid in the thread.</summary>
internal sealed partial class RewriteSession
{
    /// <summary>The thread's input and request, for the focused change.</summary>
    internal RewriteThreadState Thread { get; } = new();
    /// <summary>The AI the thread talks to; null sends nothing and says so. The Rewrite panel sets the live send.</summary>
    internal RewriteThreadBackend? ThreadBackend { get; set; }
    /// <summary>Each change's thread by ordinal, with the change's source span when it was stored: a change whose span moved has a new
    /// thread.</summary>
    private readonly Dictionary<int, (string Span, RewriteThread Thread)> threads = [];
    private RewriteFollowupPrompt? followupPrompt;
    private bool followupPromptRead;

    /// <summary>The prompt's bubbles and limits, read once; null without the shared resources.</summary>
    internal RewriteFollowupPrompt? FollowupPrompt
    {
        get
        {
            if (followupPromptRead) return followupPrompt;
            followupPromptRead = true;
            try { followupPrompt = RewriteFollowupPrompt.Load(SharedResources.ResolveRoot()); }
            catch (Exception error) when (error is VoxClipException or IOException or UnauthorizedAccessException) { followupPrompt = null; }
            return followupPrompt;
        }
    }

    /// <summary>The change a thread shows for: the focused one, still waiting, in a review that can change now, before any paid take (a
    /// change with takes is past review, as a kept change is on the Mac).</summary>
    private (RewriteThreadKey Key, VoiceLabDiffHunk Hunk)? ThreadTarget
    {
        get
        {
            if (!IsOpen || !ReviewIsCurrent || Review is not { } review || HasPaidTakes || Editor.IsReadOnly || Editor.Busy || Editor.IsLeaving) return null;
            var ordinal = FocusedChange;
            if (ordinal < 1 || ordinal > review.Diff.Hunks.Count || changeStates.GetValueOrDefault(ordinal) != TranscriptChangeState.Pending) return null;
            return (new(ProposalRevision, ordinal), review.Diff.Hunks[ordinal - 1]);
        }
    }

    private static string Span(VoiceLabDiffHunk hunk) => hunk.SourceStartIndex + ":" + hunk.SourceEndIndex + ":" + string.Join(",", hunk.SourceWordIds);
    /// <summary>The change's words as the text shows them: its new tokens, empty for a cut.</summary>
    internal string ChangeText(int ordinal) => Review is { } review && ordinal >= 1 && ordinal <= review.Diff.Hunks.Count
        ? string.Join(" ", review.Diff.Hunks[ordinal - 1].NewTokens) : "";

    /// <summary>The change's recorded words: its span as the take reads it, corrected spelling included.</summary>
    internal string RecordedText(int ordinal)
    {
        if (Review is not { } review || ordinal < 1 || ordinal > review.Diff.Hunks.Count) return "";
        var ids = review.Diff.Hunks[ordinal - 1].SourceWordIds;
        var words = Transcript.ToDictionary(word => word.Id, StringComparer.Ordinal);
        return string.Join(" ", ids.Select(id => words.TryGetValue(id, out var word) ? word.Text : null).OfType<string>());
    }

    /// <summary>The change's thread as it stands: its stored one following the words in the text, or a new one.</summary>
    internal RewriteThread? ThreadFor(int ordinal)
    {
        if (Review is not { } review || ordinal < 1 || ordinal > review.Diff.Hunks.Count) return null;
        var hunk = review.Diff.Hunks[ordinal - 1];
        var text = string.Join(" ", hunk.NewTokens);
        return threads.TryGetValue(ordinal, out var stored) && stored.Span == Span(hunk) ? stored.Thread.Following(text) : RewriteThread.Start(text);
    }

    private void StoreThread(int ordinal, RewriteThread thread)
    {
        if (Review is { } review && ordinal >= 1 && ordinal <= review.Diff.Hunks.Count) threads[ordinal] = (Span(review.Diff.Hunks[ordinal - 1]), thread);
    }

    /// <summary>The change left the proposal (its recorded words): its thread goes with it, and the later changes' threads move down.</summary>
    private void DropThread(int ordinal)
    {
        var moved = threads.Where(pair => pair.Key > ordinal).OrderBy(pair => pair.Key).ToArray();
        threads.Remove(ordinal);
        foreach (var pair in moved) { threads.Remove(pair.Key); threads[pair.Key - 1] = pair.Value; }
    }

    /// <summary>The focused change's thread, or null where none shows: no review, not waiting, past paid takes, or folded with Esc.</summary>
    internal RewriteThreadDisplay? ThreadDisplay
    {
        get
        {
            if (ThreadTarget is not { } target || Thread.Folded == target.Key || ThreadFor(target.Key.Ordinal) is not { } thread) return null;
            var prompt = FollowupPrompt;
            var mine = Thread.Key == target.Key;
            var fit = Review?.VoiceHunks.FirstOrDefault(hunk => hunk.Ordinals.Contains(target.Key.Ordinal))?.SpokenTiming ?? "";
            return new(target.Key, target.Key.Ordinal, thread.Turns.TakeLast(2).ToArray(), thread.Current + 1, thread.Versions.Count,
                target.Hunk.Kind == VoiceLabDiffHunkKind.Voice ? 1 : 0, thread.NextSteps.Take(prompt?.MaxNextSteps ?? 2).ToArray(), prompt?.KeepBubble ?? "",
                prompt?.SteadyBubbles ?? [], RewriteThreadDisplay.CostLineFor(Connector?.Connector.Id), Thread.Sending == target.Key,
                mine ? Thread.Error : null, mine && Thread.Failed is not null, thread.Versions[thread.Current].Yours, Thread.OwnWords == target.Key,
                mine ? Thread.Text : "", fit, AiName, mine ? Thread.Confirmation : null);
        }
    }

    /// <summary>The scope as the follow-up's source block names it.</summary>
    internal string FollowupScope => requestedScope switch
    {
        { ClipId: not null } => "clip",
        { First: not null } or null => "passage",
        _ => "fullTake"
    };

    private void Announce(string text) => Editor.Announce(text);

    // Sending

    /// <summary>Sends <paramref name="message"/> about the focused change (Enter, a bubble, Try Again). "3 more versions" asks for
    /// alternatives. The input keeps its text until the reply is in; an error shows in place and keeps it; nothing is voiced or paid.</summary>
    internal Task SendThreadAsync(string message, RewriteFollowupKind kind = RewriteFollowupKind.Reply, bool fromInput = false)
    {
        var words = EditingAlgorithms.JsTrim(message);
        if (words.Length == 0 || ThreadTarget is not { } target || Thread.Sending is not null || ThreadFor(target.Key.Ordinal) is not { } thread) return Task.CompletedTask;
        var key = target.Key;
        var request = new RewriteFollowupRequest(kind, FollowupScope, Project.Transcript?.Language ?? "en",
            string.Join(" ", Source.Where(word => word.Kind == WordKind.Word).Select(word => word.Text)), key.Ordinal, RecordedText(key.Ordinal),
            thread.Versions.Select(version => version.Text).ToArray(), [.. thread.Messages, words]);
        Thread.Follow(key);
        // A bubble or Try Again talks to the AI: the input leaves your own words first, with nothing put in place.
        if (Thread.OwnWords is not null) LeaveThreadOwnWords(focus: false);
        Thread.Error = null;
        Thread.Failed = null;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        Thread.Begin(key, cancellation);
        Announce(kind == RewriteFollowupKind.Versions ? $"Asking {AiName} for 3 more versions" : $"Asking {AiName}");
        Changed?.Invoke(this, EventArgs.Empty);
        var running = RunThreadAsync(request, words, kind, key, fromInput, cancellation);
        Thread.Run(running);
        return running;
    }

    private async Task RunThreadAsync(RewriteFollowupRequest request, string message, RewriteFollowupKind kind, RewriteThreadKey key, bool fromInput,
        CancellationTokenSource cancellation)
    {
        try
        {
            if (ThreadBackend is not { } backend) throw new InvalidOperationException($"Choose a connector in Settings → {SettingsSections.ProvidersAndKeys}. Nothing was sent.");
            var reply = await backend(request, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            ReceiveThread(reply, message, kind, key, fromInput);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            // Stop, a closed Rewrite or a declined confirmation: nothing changes and nothing is said.
            if (error is OperationCanceledException || cancellation.IsCancellationRequested || error is LlmException { Error.Kind: LlmErrorKind.Cancelled }) return;
            if (!IsOpen || key.Proposal != ProposalRevision || Thread.Key != key) return;
            // The live send's own readiness copy (no connector, another request running, the sign-in) is already the line.
            var line = error is InvalidOperationException ? error.Message : Refusal(error);
            Thread.Error = line.Length == 0 ? $"{AiName} couldn't answer. Try Again. Your edits are saved." : line;
            Thread.Failed = new(message, kind);
            Announce(Thread.Error);
        }
        finally
        {
            Thread.End(key);
            cancellation.Dispose();
            if (IsOpen) Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Try Again after an error: the failed message, sent again.</summary>
    internal Task RetryThreadAsync() => Thread.Failed is { } failed
        ? SendThreadAsync(failed.Message, failed.Kind, EditingAlgorithms.JsTrim(Thread.Text) == failed.Message) : Task.CompletedTask;

    /// <summary>A bubble: "✓ That's it, keep it" is exactly Keep; "✎ My own words" switches the input to your own words and back; "3 more
    /// versions" asks for alternatives; any other bubble, ✦ or steady, sends its words as your message.</summary>
    internal Task PressThreadBubbleAsync(string title)
    {
        if (ThreadDisplay is not { } display) return Task.CompletedTask;
        if (title == display.Keep) { KeepThreadChange(); return Task.CompletedTask; }
        if (title == RewriteThreadDisplay.OwnWordsBubble) { ToggleThreadOwnWords(); return Task.CompletedTask; }
        return SendThreadAsync(title, title == FollowupPrompt?.SteadyBubbles.LastOrDefault() ? RewriteFollowupKind.Versions : RewriteFollowupKind.Reply);
    }

    /// <summary>Stop while the AI works: the request is cancelled, nothing changes and the input keeps its text.</summary>
    internal void StopThread()
    {
        Thread.Cancellation?.Cancel();
        Thread.Confirmation?.Cancel();
        Announce("Stopped. Nothing changed.");
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The live send's inline confirmation, shown in the thread while it waits (null when it is answered).</summary>
    internal void ShowThreadConfirmation(InlineApproval? approval)
    {
        Thread.Confirmation = approval;
        if (IsOpen) Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The AI's reply: a new version (or three for "3 more versions"), put in the change's place through the local rediff, so its
    /// diff, kinds, fit and cost are worked out again here. Words that match the version in the text add none, and the AI's line says so.</summary>
    private void ReceiveThread(RewriteFollowupReply reply, string message, RewriteFollowupKind kind, RewriteThreadKey key, bool fromInput)
    {
        if (!IsOpen || key.Proposal != ProposalRevision || changeStates.GetValueOrDefault(key.Ordinal) != TranscriptChangeState.Pending ||
            ThreadFor(key.Ordinal) is not { } thread) return;
        var versions = thread.Versions.ToList();
        var count = versions.Count;
        var note = reply.Note;
        int? target = null;
        foreach (var text in reply.Texts)
        {
            var found = versions.FindIndex(version => RewriteFollowupPrompt.Key(version.Text) == RewriteFollowupPrompt.Key(text));
            if (found >= 0)
            {
                if (kind == RewriteFollowupKind.Reply) target = found;
                continue;
            }
            versions.Add(new(text, reply.Note));
            if (target is null || target < count) target = versions.Count - 1;
        }
        if (kind == RewriteFollowupKind.Reply && target == thread.Current) note = "Kept the words as they are." + (note.Length == 0 ? "" : " " + note);
        else if (note.Length == 0) note = kind == RewriteFollowupKind.Versions ? $"{versions.Count - count} more versions." : "Changed the words.";
        var current = thread.Current;
        if (target is { } next && next != current)
        {
            switch (AcceptThreadWords(key.Ordinal, versions[next].Text))
            {
                case RewriteThreadApply.Failed:
                    Thread.Error = "The new words couldn't be put in the text. Your edits are saved.";
                    return;
                case RewriteThreadApply.LeftOut:
                    Announce($"{AiName}: {note} Change {key.Ordinal} keeps its recorded words.");
                    return;
            }
            current = next;
        }
        if (changeStates.GetValueOrDefault(key.Ordinal) != TranscriptChangeState.Pending) return;
        var updated = thread with
        {
            Versions = versions, Current = current, NextSteps = reply.NextSteps,
            Turns = [.. thread.Turns, new(RewriteThreadSpeaker.You, message), new(RewriteThreadSpeaker.Claude, note)]
        };
        StoreThread(key.Ordinal, updated);
        if (fromInput && Thread.Key == key) Thread.Text = "";
        Announce($"{AiName}: {note} Version {current + 1} of {versions.Count}.");
    }

    // Versions and folding

    /// <summary>‹ and ›, Alt+Page Up and Alt+Page Down: the change's text becomes the previous or next version through the local rediff.
    /// Nothing is sent, and no undo step is added.</summary>
    internal bool SwitchThreadVersion(int step)
    {
        if (ThreadTarget is not { } target || Thread.Sending is not null || ThreadFor(target.Key.Ordinal) is not { } thread) return false;
        var next = thread.Current + step;
        if (next < 0 || next >= thread.Versions.Count) return false;
        var applied = AcceptThreadWords(target.Key.Ordinal, thread.Versions[next].Text);
        if (applied == RewriteThreadApply.Failed) return false;
        // Words equal to the recorded ones leave nothing to change: the edit left the change out, and its thread went with it.
        if (applied == RewriteThreadApply.LeftOut || changeStates.GetValueOrDefault(target.Key.Ordinal) != TranscriptChangeState.Pending) return true;
        StoreThread(target.Key.Ordinal, thread with { Current = next });
        Announce($"Version {next + 1} of {thread.Versions.Count}");
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Esc: the thread folds; the version stays in the text, and focusing the change again opens it.</summary>
    internal bool FoldThread()
    {
        if (ThreadDisplay is not { } display) return false;
        Thread.Folded = display.Key;
        Announce($"Folded the talk about change {display.Ordinal}");
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>F2, Enter, a click on the change's new words and the review's Edit: the thread opens and its input takes the keys.</summary>
    internal bool OpenThreadInput()
    {
        if (Thread.Folded is { } folded && folded.Ordinal == FocusedChange) Thread.Folded = null;
        if (ThreadDisplay is not { } display) return false;
        Thread.Follow(display.Key);
        Thread.FocusRequest++;
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>"✓ That's it, keep it", Ctrl+Enter in the input: exactly the change's Keep, which includes it for takes; the thread folds,
    /// as a kept change has none.</summary>
    internal bool KeepThreadChange()
    {
        if (ThreadDisplay is not { } display || !SetChangeIncluded(display.Ordinal, true)) return false;
        Thread.Folded = display.Key;
        Announce($"Kept change {display.Ordinal}");
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Ctrl+Backspace in the input: exactly the change's Undo, which leaves it out; a change left out has no thread.</summary>
    internal bool UndoThreadChange()
    {
        if (ThreadDisplay is not { } display || !SetChangeIncluded(display.Ordinal, false)) return false;
        threads.Remove(display.Ordinal);
        Announce($"Change {display.Ordinal} keeps its recorded words");
        return true;
    }

    /// <summary>The thread's input keys (design.md §6.3 "Keys", in their Windows form). False hands the key back to the text box.</summary>
    internal bool ThreadInputKey(RewriteThreadInputKey key)
    {
        if (ThreadDisplay is not { } display) return false;
        switch (key)
        {
            case RewriteThreadInputKey.Enter:
                if (display.OwnWords) return ApplyThreadOwnWords(Thread.Text);
                if (EditingAlgorithms.JsTrim(Thread.Text).Length == 0 || display.Sending) return true;
                _ = SendThreadAsync(Thread.Text, fromInput: true);
                return true;
            case RewriteThreadInputKey.ShiftEnter: return false;
            case RewriteThreadInputKey.Escape:
                if (display.Sending) { StopThread(); return true; }
                if (display.OwnWords) { LeaveThreadOwnWords(); return true; }
                return FoldThread();
            // While the input is empty, or always with your own words, the version keys are left to the text.
            case RewriteThreadInputKey.PreviousVersion or RewriteThreadInputKey.NextVersion:
                if (display.OwnWords || Thread.Text.Length > 0) return false;
                SwitchThreadVersion(key == RewriteThreadInputKey.NextVersion ? 1 : -1);
                return true;
            case RewriteThreadInputKey.Keep: return KeepThreadChange();
            case RewriteThreadInputKey.Undo: return UndoThreadChange();
            default: return false;
        }
    }

    /// <summary>The input's text as typed; it belongs to the shown change.</summary>
    internal void SetThreadText(string text)
    {
        if (ThreadDisplay is not { } display) return;
        Thread.Follow(display.Key);
        Thread.Text = text;
    }

    // Your own words

    /// <summary>"✎ My own words" and Shift+F2: the bubble switches the input to your own words, and again back to the AI.</summary>
    internal void ToggleThreadOwnWords()
    {
        if (Thread.OwnWords is { } own && own == ThreadDisplay?.Key) { LeaveThreadOwnWords(); return; }
        OpenThreadOwnWords();
    }

    /// <summary>The input takes the change's words as the text shows them, the cursor at their end, for you to type over. What it held for
    /// the AI comes back when your own words leave. False where no thread shows or the AI is working.</summary>
    internal bool OpenThreadOwnWords()
    {
        if (Thread.Folded is { } folded && folded.Ordinal == FocusedChange) Thread.Folded = null;
        if (ThreadDisplay is not { } display || display.Sending) return false;
        Thread.Follow(display.Key);
        if (Thread.OwnWords != display.Key)
        {
            Thread.Draft = Thread.Text;
            Thread.Text = ChangeText(display.Ordinal);
            Thread.OwnWords = display.Key;
        }
        Thread.FocusRequest++;
        Announce($"Your own words for change {display.Ordinal}. Enter puts them in place, Escape cancels. Nothing is sent.");
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Esc, or the bubble again: back to the AI with nothing changed; the input holds what it held for the AI.</summary>
    internal void LeaveThreadOwnWords(bool focus = true)
    {
        if (Thread.OwnWords is null) return;
        Thread.OwnWords = null;
        Thread.Text = Thread.Draft;
        Thread.Draft = "";
        if (!focus) return;
        Thread.FocusRequest++;
        Announce("Back to talking to Claude. Nothing changed.");
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Enter with your own words: they go into the change's place as a new version, "your words", through the local rediff
    /// Claude's versions take, and nothing is sent. They are this Rewrite's words for the change (<see cref="AcceptThreadWords"/>), so Keep
    /// prices and voices them as any change, the voice made from your text. An empty text makes the change a cut; the recorded words leave
    /// nothing to change, so it is left out; the words already in the text change nothing; a version's words show that version.</summary>
    internal bool ApplyThreadOwnWords(string typed)
    {
        if (ThreadTarget is not { } target || Thread.OwnWords != target.Key || Thread.Sending is not null || ThreadFor(target.Key.Ordinal) is not { } thread) return false;
        var key = target.Key;
        var text = EditingAlgorithms.JsTrim(typed);
        if (text == EditingAlgorithms.JsTrim(thread.Versions[thread.Current].Text))
        {
            LeaveThreadOwnWords(focus: false);
            Announce("Nothing changed: those are the words in the text.");
            Changed?.Invoke(this, EventArgs.Empty);
            return true;
        }
        var applied = AcceptThreadWords(key.Ordinal, text);
        if (applied == RewriteThreadApply.Failed)
        {
            Thread.Error = "Your words couldn't be put in the text. Your edits are saved.";
            Thread.Failed = null;
            Changed?.Invoke(this, EventArgs.Empty);
            return false;
        }
        // The recorded words (or none for added words): the edit left the change out, and its thread went with it.
        if (applied == RewriteThreadApply.LeftOut || changeStates.GetValueOrDefault(key.Ordinal) != TranscriptChangeState.Pending)
        {
            LeaveThreadOwnWords(focus: false);
            Announce($"Change {key.Ordinal} keeps its recorded words. Nothing was sent.");
            Changed?.Invoke(this, EventArgs.Empty);
            return true;
        }
        var shown = ChangeText(key.Ordinal);
        var versions = thread.Versions.ToList();
        var found = versions.FindIndex(version => version.Text == shown);
        if (found < 0) { versions.Add(new(shown, null, Yours: true)); found = versions.Count - 1; }
        // The AI's next steps were for its own words.
        StoreThread(key.Ordinal, thread with { Versions = versions, Current = found, NextSteps = [], Turns = [.. thread.Turns, new(RewriteThreadSpeaker.Yours, text)] });
        LeaveThreadOwnWords(focus: false);
        Thread.Error = null;
        Announce((text.Length == 0 ? $"Change {key.Ordinal} cuts its words now." : $"Your words are in change {key.Ordinal}.") +
            $" Version {found + 1} of {versions.Count}. Nothing was sent.");
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>A new proposal, or the whole words edited by hand: every thread starts again.</summary>
    private void ResetThreads()
    {
        Thread.Cancellation?.Cancel();
        Thread.Confirmation?.Cancel();
        threads.Clear();
        Thread.Folded = null;
    }
}

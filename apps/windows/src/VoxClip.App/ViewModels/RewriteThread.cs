using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

/// <summary>One version of a change's new words. <see cref="Note"/> is the AI's note when a reply made it; null for the Rewrite's own
/// first version and for your own words. <see cref="Yours"/> is your own words ("✎ My own words"), typed and applied with no request:
/// "‹ 3 of 3 › · your words".</summary>
internal sealed record RewriteThreadVersion(string Text, string? Note, bool Yours = false);

/// <summary>Who a thread turn is from. <see cref="Yours"/> is your own words put in place, "You · your own words: “…”": a turn of the
/// thread, never a message to the AI.</summary>
internal enum RewriteThreadSpeaker { You, Claude, Yours }

internal sealed record RewriteThreadTurn(RewriteThreadSpeaker Speaker, string Text);

/// <summary>One change's talk with the AI (design.md §6.3 "Talk back to Claude", ADR-R50; Mac <c>RewriteThread</c>): every version of its
/// new words, the version in the text, the turns, and the AI's next steps from its last reply. A change with no thread yet has one version,
/// its words as they read now.</summary>
internal sealed record RewriteThread(IReadOnlyList<RewriteThreadVersion> Versions, int Current, IReadOnlyList<RewriteThreadTurn> Turns,
    IReadOnlyList<string> NextSteps)
{
    internal static RewriteThread Start(string text) => new([new(text, null)], 0, [], []);

    /// <summary>What the user said about the change, in order: every message the next request carries. Your own words are not here.</summary>
    internal IReadOnlyList<string> Messages => Turns.Where(turn => turn.Speaker == RewriteThreadSpeaker.You).Select(turn => turn.Text).ToArray();

    /// <summary>The thread with <paramref name="text"/>, the change's words as they read now, as its current version. A local edit made
    /// them differ (the wording fit, a re-ask); they become a version of their own, so the next request and the arrows read what the text
    /// shows.</summary>
    internal RewriteThread Following(string text)
    {
        var key = RewriteFollowupPrompt.Key(text);
        if (RewriteFollowupPrompt.Key(Versions[Current].Text) == key) return this;
        var found = Versions.ToList().FindIndex(version => RewriteFollowupPrompt.Key(version.Text) == key);
        return found >= 0 ? this with { Current = found } : this with { Versions = [.. Versions, new(text, null)], Current = Versions.Count };
    }
}

/// <summary>Which change of which proposal a thread's input, request, error and fold belong to: <see cref="Proposal"/> is the session's
/// <see cref="RewriteSession.ProposalRevision"/>.</summary>
internal readonly record struct RewriteThreadKey(int Proposal, int Ordinal);

/// <summary>What a thread request is: a message to the AI or "3 more versions".</summary>
internal sealed record RewriteThreadFailure(string Message, RewriteFollowupKind Kind);

/// <summary>The thread's input and request (design.md §6.3; Mac <c>RewriteThreadState</c>): one per Rewrite session, for the focused change.
/// The words typed, the request in flight, an error and a fold belong to one change of one proposal.</summary>
internal sealed class RewriteThreadState
{
    internal string Text { get; set; } = "";
    /// <summary>The change <see cref="Text"/> and <see cref="Error"/> belong to; a focus move to another change starts with an empty input.</summary>
    internal RewriteThreadKey? Key { get; private set; }
    /// <summary>Thread errors that are not the AI's: the new words couldn't go into the text, or they wait for the paid takes' discard.</summary>
    internal const string ApplyFailed = "The new words couldn't be put in the text. Your edits are saved.";
    internal const string WaitsForDiscard = "Changing these words discards your paid takes: confirm in the Rewrite panel. Your edits are saved.";
    /// <summary>The change whose request is in flight.</summary>
    internal RewriteThreadKey? Sending { get; private set; }
    internal string? Error { get; set; }
    /// <summary>The message that failed, which Try Again sends again.</summary>
    internal RewriteThreadFailure? Failed { get; set; }
    /// <summary>The change whose thread Esc folded; focusing that change again opens it.</summary>
    internal RewriteThreadKey? Folded { get; set; }
    /// <summary>Moves when F2, Enter or a click on the change's new words asks the input to take the keys.</summary>
    internal int FocusRequest { get; set; }
    /// <summary>The change whose input takes your own words ("✎ My own words", Shift+F2): Enter puts them in place as a version, and
    /// nothing is sent. Null is the AI's mode.</summary>
    internal RewriteThreadKey? OwnWords { get; set; }
    /// <summary>What the input held for the AI when your own words took it, given back when they leave.</summary>
    internal string Draft { get; set; } = "";
    /// <summary>The inline connector confirmation the live send waits on (the Rewrite consent, as Ask Claude's).</summary>
    internal InlineApproval? Confirmation { get; set; }
    internal CancellationTokenSource? Cancellation { get; private set; }
    /// <summary>The request in flight, for tests and Stop.</summary>
    internal Task Running { get; private set; } = Task.CompletedTask;

    internal void Begin(RewriteThreadKey key, CancellationTokenSource cancellation) { Sending = key; Cancellation = cancellation; }
    internal void Run(Task task) => Running = task;
    internal void End(RewriteThreadKey key)
    {
        if (Sending != key) return;
        Sending = null;
        Cancellation = null;
    }

    /// <summary>Moves the input to <paramref name="key"/>, keeping what it holds when the key is the same.</summary>
    internal void Follow(RewriteThreadKey key)
    {
        if (Key == key) return;
        Key = key; Text = ""; Error = null; Failed = null; OwnWords = null; Draft = "";
    }

    /// <summary>The change <paramref name="key"/> was kept or left out, so it has no thread: its request stops, and its input, error and
    /// fold go. If it waits again later, its thread starts again.</summary>
    internal void Leave(RewriteThreadKey key)
    {
        if (Sending == key) { Cancellation?.Cancel(); Confirmation?.Cancel(); }
        if (Folded == key) Folded = null;
        if (Key != key) return;
        Key = null; Text = ""; Error = null; Failed = null; OwnWords = null; Draft = "";
    }
}

/// <summary>The focused change's thread as the transcript shows it (Mac <c>RewriteThreadDisplay</c>).</summary>
internal sealed record RewriteThreadDisplay(RewriteThreadKey Key, int Ordinal, IReadOnlyList<RewriteThreadTurn> Turns, int Version, int Versions,
    int VoicePhrases, IReadOnlyList<string> Steps, string Keep, IReadOnlyList<string> Steady, string CostLine, bool Sending, string? Error,
    bool Retry, bool Yours, bool OwnWords, string Input, string FitLine, string AiName, InlineApproval? Confirmation)
{
    internal const string OwnWordsBubble = "✎ My own words";
    internal const string OwnWordsPlaceholder = "Your exact words · ↵ applies · Esc cancels";
    internal const string OwnWordsCostLine = "Free · nothing is sent";
    /// <summary>The Windows keys for the Mac's ⌥←/⌥→ (Alt+← is Back) and ⌥E (Alt+E would reach menu access keys).</summary>
    internal const string PreviousVersionKey = "Alt+Page Up";
    internal const string NextVersionKey = "Alt+Page Down";
    internal const string OwnWordsKey = "Shift+F2";
    internal string VersionLine => $"{Version} of {Versions}";
    /// <summary>"· your words" after the arrows when the version in the text is yours.</summary>
    internal string? YoursLine => Yours ? "· your words" : null;
    /// <summary>Beside the input: the AI's cost line, or "Free · nothing is sent" for your own words.</summary>
    internal string InputCostLine => OwnWords ? OwnWordsCostLine : CostLine;
    /// <summary>"· 1 phrase to voice at Keep" or "· text only, free".</summary>
    internal string PhrasesLine => VoicePhrases == 0 ? "· text only, free" : $"· {VoicePhrases} phrase{(VoicePhrases == 1 ? "" : "s")} to voice at Keep";
    internal string Placeholder => OwnWords ? OwnWordsPlaceholder : "Tell Claude what to change…";
    internal string WorkingLine => $"{AiName} is working on it";

    // Narrator (design.md §6.3 "VoiceOver", in their Windows form).
    internal string Label => $"Talk to Claude about change {Ordinal}";
    internal string InputLabel => OwnWords ? $"Your own words for change {Ordinal}" : $"Tell Claude what to change about change {Ordinal}";
    internal string VersionLabel => $"Version {Version} of {Versions}";
    internal static string TurnLabel(RewriteThreadTurn turn) => turn.Speaker switch
    {
        RewriteThreadSpeaker.Claude => "Claude: " + turn.Text,
        RewriteThreadSpeaker.Yours => "You: your own words: " + turn.Text,
        _ => "You: " + turn.Text
    };
    internal static string StepLabel(string step) => step + ", suggested by Claude";
    internal static string OwnWordsAction(int ordinal) => $"Type your own words for change {ordinal}";
    internal static string TalkAction(int ordinal) => $"Talk to Claude about change {ordinal}";

    /// <summary>"Free on your Claude plan", "Free on your ChatGPT plan", "Billed to your {provider} key" or "Free on this PC": the cost line
    /// Ask Claude's field and the thread's input show (design.md §6.8).</summary>
    internal static string CostLineFor(ConnectorId? connector) => connector switch
    {
        ConnectorId.ClaudeCode => "Free on your Claude plan",
        ConnectorId.Codex => "Free on your ChatGPT plan",
        ConnectorId.Ollama or ConnectorId.LmStudio => "Free on this PC",
        ConnectorId.Anthropic => "Billed to your Anthropic key",
        ConnectorId.OpenAI => "Billed to your OpenAI key",
        ConnectorId.Xai => "Billed to your xAI key",
        ConnectorId.Gemini => "Billed to your Gemini key",
        _ => ""
    };
}

/// <summary>A key the thread's input or the transcript hands the thread (design.md §6.3 "Keys", in their Windows form).</summary>
internal enum RewriteThreadInputKey { Enter, ShiftEnter, Escape, PreviousVersion, NextVersion, Keep, Undo }

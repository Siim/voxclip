using VoxClip.Core.Services.Settings;

namespace VoxClip.App.ViewModels;

// "✦ Claude does it all" (design §6.6, §6.7), twin of the Mac ClaudeMode.swift: one remembered choice, Settings clips.mode. In
// Claude mode a newly imported video runs the whole loop with no clicks once it is transcribed: Find Clips, then Make top N
// postable within the per-video cap, then one card with Export all. "I'll pick" leaves the clips to the creator. The run is not
// stored in the project: a reopened project never starts it again. Windows still asks how to transcribe (the transcription job),
// and Claude mode takes over when the transcript arrives.

/// <summary>What Claude mode needs from the creator before it can go on, with the one action that fixes it.</summary>
public abstract record ClaudeModeBlocker(string Reason)
{
    /// <summary>No AI is chosen, or the chosen one isn't ready: Settings › Providers &amp; Keys.</summary>
    public sealed record SetUp(string Text) : ClaudeModeBlocker(Text);
    /// <summary>The chosen AI asks before each send (a first use, or a key that bills it): Find Clips asks inline.</summary>
    public sealed record ApproveSend(string Text) : ClaudeModeBlocker(Text);
    /// <summary>Find Clips failed or found nothing: Find Clips again.</summary>
    public sealed record FindAgain(string Text) : ClaudeModeBlocker(Text);

    /// <summary>The card's one action.</summary>
    public string Action => this switch
    {
        SetUp => "Set Up Claude…",
        ApproveSend => "Find Clips",
        _ => "Find Clips Again"
    };
}

/// <summary>Where Claude mode is for this video.</summary>
public enum ClaudeModePhase
{
    /// <summary>Nothing for this video (not new, "I'll pick", or not chosen yet).</summary>
    Idle,
    /// <summary>Waiting for the transcript or Find Clips.</summary>
    Waiting,
    Blocked,
    Running,
    Done,
    Stopped
}

/// <summary>The outside world Claude mode talks to. The editor page builds the live one; tests and the smoke pass stubs.</summary>
/// <param name="Settings">The remembered mode, clips per video and cap.</param>
/// <param name="Save">Remembers new choices in Settings.</param>
/// <param name="Finding">Find Clips is running.</param>
/// <param name="FindProblem">What the last Find Clips said when it failed; null otherwise.</param>
/// <param name="FindIfFree">Starts Find Clips when it needs no approval, and returns null; otherwise returns what blocks it.</param>
/// <param name="Fix">The blocked card's action: Settings, or Find Clips' own panel, which asks inline.</param>
public sealed record ClaudeModeServices(
    Func<ClipsAutopilotSettings> Settings,
    Func<ClipsAutopilotSettings, Task> Save,
    Func<bool> Finding,
    Func<string?> FindProblem,
    Func<Task<ClaudeModeBlocker?>> FindIfFree,
    Action<ClaudeModeBlocker> Fix)
{
    /// <summary>Writes one info line to the app log (category <c>claude-mode</c>): the run's stage timings, numbers only.</summary>
    public Action<string>? Log { get; init; }
}

/// <summary>One line of card C: the transcript, Find Clips, then each clip.</summary>
public sealed record ClaudeModeStep(string Id, ClaudeModeStepState State, string Text, string Detail = "");

/// <summary>A step's glyph: ✓ done, ✦ now, ○ to do, ! a note.</summary>
public enum ClaudeModeStepState { Done, Now, Todo, Note }

/// <summary>The clip row's pill while Claude mode makes it.</summary>
public enum ClaudeClipState { Ready, Making, Waiting, Stopped, Failed }

/// <summary>The editor's Claude mode state for its video.</summary>
public sealed class ClaudeModeState
{
    /// <summary>The video was newly imported in this window and Claude has not started on it yet.</summary>
    public bool Armed { get; internal set; }
    public ClaudeModePhase Phase { get; internal set; }
    public ClaudeModeBlocker? Blocker { get; internal set; }
    /// <summary>The clips the run makes, best first.</summary>
    public IReadOnlyList<string> ClipIds { get; internal set; } = [];
    /// <summary>How many moments Find Clips offered.</summary>
    public int Found { get; internal set; }
    public MakeItBudget? Budget { get; internal set; }
    /// <summary>The run's stage wall times from the video's arming (ai.md §16.12): transcribe, find, then plan and apply per clip.</summary>
    public Core.Domain.Autopilot.ClaudeModeClock? Clock { get; internal set; }
    /// <summary>A Find Clips ran on this video since it was armed.</summary>
    public bool Searched { get; internal set; }
    public ClaudeModeServices? Services { get; set; }
    /// <summary>The run, from the start to the last clip.</summary>
    internal Task? Task { get; set; }
    /// <summary>Going on once Find Clips' task has ended.</summary>
    internal Task? AfterFind { get; set; }
    public bool Running => Phase == ClaudeModePhase.Running;
    /// <summary>Waits until the run and any continuation after Find Clips have ended (tests and the smoke).</summary>
    public async Task WaitAsync()
    {
        if (AfterFind is { } after) await after;
        if (Task is { } run) await run;
    }
}

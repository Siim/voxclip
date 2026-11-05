using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;

namespace VoxClip.App.ViewModels;

/// <summary>One chip of the "Rewrite as" strip (design §6.3.1): Fix mistakes, Shorter, a catalogue tone or a saved tone.</summary>
/// <param name="Instruction">The exact text Rewrite sends.</param>
/// <param name="Detail">The menu's trailing line: "hook, punchy, payoff", "saved".</param>
public sealed record RewriteStripItem(string Id, string Title, string Instruction, string Detail, RewriteStripKind Kind)
{
    /// <summary>The creator's default (the clip style's Tone): first in every strip, marked "· your default".</summary>
    public bool IsDefault { get; init; }
    /// <summary>The menu's label: "✦ Viral YouTuber · your default".</summary>
    public string Label => IsDefault ? Title + " · your default" : Title;
    public const string FixMistakesId = "fix-mistakes";
    public const string ShorterId = "make-shorter";
}

/// <summary>What a strip item is.</summary>
public enum RewriteStripKind { Fix, Tone, Saved }

/// <summary>The tone catalogue and the creator's saved tones (Settings rewrite.myTones), read and written by the page.</summary>
public sealed record RewriteToneServices(RewriteToneCatalog Catalog, Func<IReadOnlyList<RewriteTone>> Saved, Func<IReadOnlyList<RewriteTone>, Task> Store);

/// <summary>A strip item chosen: Rewrite opens on these words (the selection), this clip, or the scope now, with the instruction,
/// and asks at once.</summary>
public sealed record RewriteAsRequest(string Instruction, string Title, string? ClipId = null, (int First, int Last)? Words = null);

/// <summary>The Rewrite-as strip (design §6.3.1) and the review's tone row (§6.7), twin of the Mac <c>EditorModel+RewriteTones</c>
/// and <c>MakeItTone</c>.</summary>
public sealed partial class EditorViewModel
{
    public const string FixMistakesInstruction = "Fix slips and repeats. Keep my words and my voice; change as little as possible.";
    public const string ShorterInstruction = "Make it shorter, mostly by cutting. Keep my words and my voice.";
    public const string ToneRowId = "tone";
    public const string AsSaidId = "as-said";

    /// <summary>The tone catalogue and saved tones; null hides every strip.</summary>
    public RewriteToneServices? Tones { get; set; }
    /// <summary>A chip asked for a rewrite: the page opens Rewrite on the request's words and sends it.</summary>
    public event EventHandler<RewriteAsRequest>? RewriteAsRequested;

    private IReadOnlyList<RewriteTone> SavedTones => Tones?.Saved() ?? MakeIt.Services?.SavedTones ?? [];
    private RewriteToneCatalog? ToneCatalog => Tones?.Catalog ?? MakeIt.Services?.Tones;

    /// <summary>The strip in its one order: the default first, then Fix mistakes, Shorter, the catalogue tones and the saved tones.
    /// The default is the clip style's Tone when it names a tone; Auto, As I said it or a tone no longer known make Fix mistakes it.</summary>
    public IReadOnlyList<RewriteStripItem> RewriteStripItems
    {
        get
        {
            if (ToneCatalog is not { } catalog) return [];
            List<RewriteStripItem> items =
            [
                new(RewriteStripItem.FixMistakesId, "Fix mistakes", FixMistakesInstruction, "slips and repeats", RewriteStripKind.Fix),
                new(RewriteStripItem.ShorterId, "Shorter", ShorterInstruction, "mostly by cutting", RewriteStripKind.Fix),
                .. catalog.Tones.Select(tone => new RewriteStripItem(tone.Id, tone.ChipTitle, tone.Instruction, tone.Descriptor, RewriteStripKind.Tone)),
                .. SavedTones.Select(tone => new RewriteStripItem(tone.Id, tone.Title, tone.Instruction, "saved", RewriteStripKind.Saved))
            ];
            var wanted = project.ClipStyle?.Tone is { } id && items.Any(item => item.Id == id) ? id : RewriteStripItem.FixMistakesId;
            var index = items.FindIndex(item => item.Id == wanted);
            var first = items[index] with { IsDefault = true };
            items.RemoveAt(index);
            return [first, .. items];
        }
    }

    /// <summary>The chip the field's text names (it shows that chip's instruction), if any.</summary>
    public RewriteStripItem? RewriteStripMatch(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length == 0 ? null : RewriteStripItems.FirstOrDefault(item => item.Instruction == trimmed);
    }

    /// <summary>The strips show while Rewrite can run: a transcript, an editable project and the catalogue.</summary>
    public bool ShowsToneStrip => ToneCatalog is not null && HasTranscript && !IsReadOnly && !isLeaving && !Busy;

    /// <summary>The selection flyout's "✦ Rewrite as ▾": rewrites the selected words in that tone at once.</summary>
    public bool RewriteSelectionAs(RewriteStripItem item)
    {
        if (!ShowsToneStrip || !HasSelection) return false;
        Request(item, new(item.Instruction, item.Title, Words: (SelectionStart, SelectionEnd)));
        return true;
    }

    /// <summary>The scope bar's tone row: rewrites the scope now (the open clip, or the full take) in that tone.</summary>
    public bool RewriteScopeAs(RewriteStripItem item)
    {
        if (!ShowsToneStrip) return false;
        ClearSelection();
        Request(item, new(item.Instruction, item.Title, ClipId: state?.ActiveClipId));
        return true;
    }

    /// <summary>A clip row's "Rewrite as": a suggestion is kept first, then its clip is rewritten in that tone.</summary>
    public bool RewriteClipAs(RewriteStripItem item, string clipId)
    {
        if (!ShowsToneStrip || ClipSpan(clipId) is null || !KeepForRowAction(clipId)) return false;
        SetScope(clipId);
        ClearSelection();
        Request(item, new(item.Instruction, item.Title, ClipId: clipId));
        return true;
    }

    private void Request(RewriteStripItem item, RewriteAsRequest request)
    {
        Announcement?.Invoke(this, "Rewriting as " + item.Title.Replace("✦ ", "", StringComparison.Ordinal));
        RewriteAsRequested?.Invoke(this, request);
    }

    /// <summary>Ctrl+R on a word selection with an empty field (or one a chip fills): the default tone at once; null otherwise.</summary>
    public RewriteStripItem? RewriteShortcutItem(string fieldText) =>
        ShowsToneStrip && HasSelection && (fieldText.Trim().Length == 0 || RewriteStripMatch(fieldText) is not null) ? RewriteStripItems.FirstOrDefault() : null;

    // MARK: Saved tones

    /// <summary>"+ Save as my tone" can keep the field's text: not empty, not a chip already, and fewer than the limit saved.</summary>
    public bool CanSaveAsTone(string fieldText) =>
        Tones is { } tones && fieldText.Trim().Length > 0 && RewriteStripMatch(fieldText) is null && tones.Saved().Count < tones.Catalog.MaxMyTones;

    /// <summary>"+ Save as my tone": keeps <paramref name="instruction"/> under <paramref name="title"/>; it shows as a chip and in the
    /// clip style card's Tone menu. Null when the title or text is refused, or the limit is reached.</summary>
    public async Task<RewriteTone?> SaveToneAsync(string title, string instruction)
    {
        if (Tones is not { } tones || !CanSaveAsTone(instruction)) return null;
        try
        {
            var (next, made) = MyRewriteTones.Saving(title, instruction, tones.Saved(), tones.Catalog.MaxMyTones);
            await tones.Store(next);
            Announcement?.Invoke(this, $"Saved “{made.Title}” as your tone.");
            MakeItNotify();
            return made;
        }
        catch (Core.Domain.VoiceLab.VoiceLabException) { return null; }
    }

    /// <summary>Settings › Clips: renames a saved tone; its id stays, so clip styles that chose it keep it.</summary>
    public async Task<bool> RenameToneAsync(string id, string title)
    {
        if (Tones is not { } tones) return false;
        try { await tones.Store(MyRewriteTones.Renaming(id, title, tones.Saved())); return true; }
        catch (Core.Domain.VoiceLab.VoiceLabException) { return false; }
    }

    /// <summary>Settings › Clips: deletes a saved tone. A clip style that chose it plans as Auto from then on.</summary>
    public Task DeleteToneAsync(string id) => Tones is { } tones ? tones.Store(MyRewriteTones.Deleting(id, tones.Saved())) : Task.CompletedTask;

    // MARK: The review's tone row

    /// <summary>"✦ Claude wrote it as Viral YouTuber" with "Hook first · voiced 2 phrases, $0.18"; null when no tone was used.</summary>
    private MakeItRow? MakeItToneRow(ClipAutopilotPlan plan, MakeItRun run, IReadOnlyList<MakeItRow> rows)
    {
        if (plan.ToneChoice is not { } tone) return null;
        var voiced = rows.Count(row => row.Id.StartsWith("rewrite-", StringComparison.Ordinal) && run.Inverses.ContainsKey(row.Id));
        var parts = new List<string>();
        if (tone.Summary.Length > 0) parts.Add(tone.Summary);
        if (voiced > 0) parts.Add($"voiced {voiced} {(voiced == 1 ? "phrase" : "phrases")}, {MakeItController.Dollars(run.VoiceSpent)}");
        return new(ToneRowId, MakeItToneText(tone.Title, "Claude"))
        {
            Kind = MakeItRowKind.Choice, Detail = string.Join(" · ", parts), Play = ClipPlay(run.ClipId, project), Undoable = voiced > 0,
            Change = MakeItChange.Tone, Options = MakeItToneChoices.Where(choice => choice.Id != tone.Id).Select(choice => choice.Title).ToArray()
        };
    }

    public static string MakeItToneText(string title, string who) => $"✦ {who} wrote it as {title}";

    /// <summary>The chips Change shows: the strip's tones (the catalogue, then the saved ones) and As I said it.</summary>
    public IReadOnlyList<(string Id, string Title)> MakeItToneChoices =>
        [.. RewriteStripItems.Where(item => item.Kind != RewriteStripKind.Fix).Select(item => (item.Id, item.Title)), (AsSaidId, ToneCatalog?.AsSaid.Label ?? "As I said it")];

    /// <summary>A chip on the tone row. As I said it takes the tone's rewording back; a tone takes this clip's decisions back and plans
    /// it again in that tone, all as one undo step ("Change tone").</summary>
    public bool MakeItChooseTone(string id, MakeItRun run)
    {
        if (run.Running || !run.Rows.Any(row => row.Id == ToneRowId)) return false;
        run.OpenChoice = null;
        if (id == AsSaidId) return MakeItRemoveTone(run, chose: true);
        if (run.Plan?.ToneChoice?.Id == id || MakeIt.Services is null) return false;
        BeginUndoGroup("Change tone");
        TakeBackMakeIt(run);
        MakeIt.Forget(run.ClipId);
        MakeIt.ToneOverride = id;
        if (!MakeItPostable(run.ClipId, beginsGroup: false)) { EndUndoGroup(); MakeIt.ToneOverride = null; return false; }
        return true;
    }

    /// <summary>Takes the tone's rewording back: every voiced rewrite of the run is turned off (its paid take kept), as one step. The
    /// row's Undo, and As I said it, which then names the creator's choice.</summary>
    public bool MakeItRemoveTone(MakeItRun run, bool chose)
    {
        var index = run.Rows.FindIndex(row => row.Id == ToneRowId);
        if (index < 0 || run.Rows[index].Undone || run.Running) return false;
        var ids = run.Rows.Where(row => row.Id.StartsWith("rewrite-", StringComparison.Ordinal) && !row.Undone && run.Inverses.ContainsKey(row.Id)).Select(row => row.Id).ToArray();
        if (ids.Length > 0)
        {
            BeginUndoGroup(chose ? "As I said it" : "Undo tone");
            try { foreach (var rowId in ids) MakeItUndo(rowId, run); }
            finally { EndUndoGroup(); }
        }
        var asSaid = ToneCatalog?.AsSaid.Label ?? "As I said it";
        run.Rows[index] = chose
            ? run.Rows[index] with { Text = "You chose " + asSaid, Detail = ids.Length == 0 ? "No words were reworded." : "Claude's rewording is taken back; your words play again.", Undoable = false, Change = MakeItChange.None }
            : run.Rows[index] with { Undone = true };
        Announcement?.Invoke(this, ids.Length == 0 ? "Your own words were kept." : "Claude's rewording taken back.");
        MakeItNotify();
        return true;
    }
}

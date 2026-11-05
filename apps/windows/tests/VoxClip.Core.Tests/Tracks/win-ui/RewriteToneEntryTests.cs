#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.MakeItPostableTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The "Rewrite as" strip on Windows (design §6.3.1) and the review's tone row (§6.7), twin of the Mac
/// <c>RewriteToneEntryTests</c>: one order with the clip style's tone first; the scope bar's tone row, the selection flyout, Ctrl+R and
/// a clip row each ask Rewrite on their own words; saved tones are chips and Settings renames and deletes them; the review names the
/// tone, and Change re-plans the clip in another tone as one undo step. ✦ Ask Claude's "Reword these words" runs the same chips on the asked words or clip, and never mixes them with its effect chips.</summary>
public sealed class RewriteToneEntryTests
{
    private static readonly RewriteToneCatalog Catalog = RewriteToneCatalog.Load(Root);

    private sealed class Saved
    {
        internal IReadOnlyList<RewriteTone> Tones { get; set; } = [];
        internal RewriteToneServices Services() => new(Catalog, () => Tones, next => { Tones = next; return Task.CompletedTask; });
    }

    private static (EditorViewModel Editor, Saved Saved, List<RewriteAsRequest> Requests) Open(string? tone = null, bool suggested = false)
    {
        var editor = Editor(suggested);
        var saved = new Saved();
        editor.Tones = saved.Services();
        if (tone is not null) editor.ChooseClipStyle(Style() with { Tone = tone }, Library, collapse: true);
        var requests = new List<RewriteAsRequest>();
        editor.RewriteAsRequested += (_, request) => requests.Add(request);
        return (editor, saved, requests);
    }

    [Fact]
    public void TheStripHasOneOrderAndTheDefaultComesFirst()
    {
        var (editor, _, _) = Open();
        var items = editor.RewriteStripItems;
        Assert.Equal([RewriteStripItem.FixMistakesId, RewriteStripItem.ShorterId, .. Catalog.Tones.Select(tone => tone.Id)], items.Select(item => item.Id));
        Assert.True(items[0].IsDefault);
        Assert.Equal("Fix mistakes · your default", items[0].Label);
        Assert.Equal(EditorViewModel.FixMistakesInstruction, items[0].Instruction);
        var (funny, _, _) = Open("funny");
        Assert.Equal(["funny", RewriteStripItem.FixMistakesId, RewriteStripItem.ShorterId], funny.RewriteStripItems.Take(3).Select(item => item.Id));
        Assert.True(funny.RewriteStripItems[0].IsDefault);
        Assert.Single(funny.RewriteStripItems, item => item.IsDefault);
        // As I said it, or a tone no longer known, makes Fix mistakes the default.
        var (asSaid, _, _) = Open("as-said");
        Assert.Equal(RewriteStripItem.FixMistakesId, asSaid.RewriteStripItems[0].Id);
    }

    [Fact]
    public void TheScopeBarStripRewritesTheOpenClipAndMarksTheChip()
    {
        var (editor, _, requests) = Open("funny");
        editor.SetScope("c1");
        var item = editor.RewriteStripItems.First(item => item.Id == "punchy-reel");
        Assert.True(editor.RewriteScopeAs(item));
        var request = Assert.Single(requests);
        Assert.Equal(("c1", (ValueTuple<int, int>?)null, item.Instruction), (request.ClipId, request.Words, request.Instruction));
        Assert.Null(editor.RewriteStripMatch("my own words"));
        Assert.Equal(item.Id, editor.RewriteStripMatch("  " + item.Instruction + " ")!.Id);
        // The full take is a scope too.
        editor.SetScope(null);
        Assert.True(editor.RewriteScopeAs(item));
        Assert.Null(requests[^1].ClipId);
    }

    [Fact]
    public void TheSelectionFlyoutAndCtrlRRewriteTheSelectedWords()
    {
        var (editor, _, requests) = Open("funny");
        Assert.Null(editor.RewriteShortcutItem(""));
        editor.Select(12);
        editor.Select(14, extend: true);
        var shortcut = editor.RewriteShortcutItem("");
        Assert.Equal("funny", shortcut!.Id);
        Assert.Equal("funny", editor.RewriteShortcutItem(Catalog.Tones[0].Instruction)!.Id);
        Assert.Null(editor.RewriteShortcutItem("make it rhyme"));
        Assert.True(editor.RewriteSelectionAs(shortcut));
        Assert.Equal(((int, int)?)(12, 14), Assert.Single(requests).Words);
        Assert.Equal(shortcut.Instruction, requests[0].Instruction);
    }

    [Fact]
    public void AClipRowRewritesItsClipAndKeepsASuggestionFirst()
    {
        var (editor, _, requests) = Open(suggested: true);
        Assert.Single(editor.SuggestedClips);
        Assert.True(editor.RewriteClipAs(editor.RewriteStripItems[1], "c1"));
        Assert.Empty(editor.SuggestedClips);
        Assert.Equal("c1", editor.State!.ActiveClipId);
        Assert.Equal("c1", Assert.Single(requests).ClipId);
        Assert.False(editor.HasSelection);
        Assert.False(editor.RewriteClipAs(editor.RewriteStripItems[1], "missing"));
    }

    [Fact]
    public async Task SavedTonesAreChipsAndSettingsRenameAndDeleteThem()
    {
        var (editor, saved, _) = Open();
        Assert.False(editor.CanSaveAsTone(""));
        Assert.False(editor.CanSaveAsTone(EditorViewModel.ShorterInstruction));
        Assert.True(editor.CanSaveAsTone("Say it like a sports commentator."));
        var tone = await editor.SaveToneAsync("Commentator", "Say it like a sports commentator.");
        Assert.Equal("my-commentator", tone!.Id);
        var last = editor.RewriteStripItems[^1];
        Assert.Equal(("my-commentator", "Commentator", "saved", RewriteStripKind.Saved), (last.Id, last.Title, last.Detail, last.Kind));
        Assert.False(editor.CanSaveAsTone("Say it like a sports commentator."));
        Assert.Contains(("my-commentator", "Commentator"), editor.MakeItToneChoices);
        Assert.Null(await editor.SaveToneAsync("", "Something else."));
        Assert.True(await editor.RenameToneAsync("my-commentator", "Play by play"));
        Assert.Equal(("my-commentator", "Play by play"), (saved.Tones[0].Id, saved.Tones[0].Title));
        Assert.False(await editor.RenameToneAsync("my-missing", "X"));
        await editor.DeleteToneAsync("my-commentator");
        Assert.Empty(saved.Tones);
        Assert.DoesNotContain(editor.RewriteStripItems, item => item.Kind == RewriteStripKind.Saved);
    }

    [Fact]
    public async Task TheReviewNamesTheToneAndChangeReplansInOneUndoStep()
    {
        var (editor, _, _) = Open("viral-youtuber");
        var stub = new Stub { VoiceReady = true, Voice = _ => new(new MakeItRewriteResult.NeedsYou("Rewrite is waiting for you.")) };
        stub.Series = request => new([Plan() with
        {
            ToneChoice = request.Tone is ClipAutopilotTone.Fixed { Tone: var tone } ? new(tone.Id, tone.Title, "Hook first") : null
        }], [], []);
        var run = await RunAsync(editor, stub);
        var row = run.Rows[0];
        var viral = Catalog.Tones.Single(tone => tone.Id == "viral-youtuber");
        Assert.Equal((EditorViewModel.ToneRowId, EditorViewModel.MakeItToneText(viral.Title, "Claude"), "Hook first", false, MakeItChange.Tone),
            (row.Id, row.Text, row.Detail, row.Undoable, row.Change));
        Assert.DoesNotContain(viral.ChipTitle, row.Options);
        Assert.Contains(Catalog.AsSaid.Label, row.Options);
        editor.MakeItChangeRow(row.Id, run);
        Assert.Equal(row.Id, run.OpenChoice);
        var funny = Catalog.Tones.Single(tone => tone.Id == "funny");
        Assert.True(editor.MakeItChoose(funny.ChipTitle, row.Id, run));
        var again = editor.MakeIt.Run("c1")!;
        await again.Task!;
        Assert.Equal("funny", Assert.IsType<ClipAutopilotTone.Fixed>(stub.Requests[^1].Tone).Tone.Id);
        Assert.Equal(EditorViewModel.MakeItToneText(funny.Title, "Claude"), again.Rows[0].Text);
        Assert.Equal("Change tone", editor.UndoActionName);
        editor.Undo();
        Assert.Equal("Make it postable", editor.UndoActionName);
        // The next request uses the clip style's tone again.
        Assert.Equal("viral-youtuber", Assert.IsType<ClipAutopilotTone.Fixed>(editor.MakeItRequest("c1")!.Tone).Tone.Id);
        // As I said it keeps the creator's words and names the choice.
        editor.Redo();
        Assert.True(editor.MakeItChoose(Catalog.AsSaid.Label, EditorViewModel.ToneRowId, again));
        Assert.Equal(("You chose " + Catalog.AsSaid.Label, "No words were reworded.", MakeItChange.None), (again.Rows[0].Text, again.Rows[0].Detail, again.Rows[0].Change));
    }

    [Fact]
    public async Task ChangeOnAPhraseOpensRewriteWithThePlannedWords()
    {
        var editor = Editor();
        var run = await RunAsync(editor, new Stub());
        (MakeItRun Run, MakeItRow Row)? asked = null;
        editor.MakeItChangeRequested += (_, change) => asked = change;
        var phrase = run.Rows.Single(row => row.Change == MakeItChange.Phrase);
        editor.MakeItChangeRow(phrase.Id, run);
        Assert.Equal(("much clearer", (20, 21)), (asked!.Value.Row.Planned, asked.Value.Row.Words!.Value));
    }

    [Fact]
    public void SuggestedRanksByThePlannersScore()
    {
        var editor = RewriteAutoFixTests.Editor();
        var project = editor.Project with
        {
            Ai = new([Result([new AiClip("First", "", 5, "w0", "w9"), new AiClip("Second", "", 5, "w20", "w29")])]),
            Edits = editor.Project.Edits with
            {
                Clips = [new ClipRange("s0", "w0", "w9", null, ClipOrigin.Ai, "r1", 0, false), new ClipRange("s1", "w20", "w29", null, ClipOrigin.Ai, "r1", 1, false)]
            }
        };
        editor = new(project);
        Assert.Equal(["s0", "s1"], editor.SuggestedClips.Select(clip => clip.Id));
        editor.MakeIt.Record(9, ClipAutopilotVerdict.PostFirst, "s1");
        Assert.True(editor.ApplyBatch([new EditOperation.SetWordCuts(["w50"], true)]));
        Assert.Equal(["s1", "s0"], editor.SuggestedClips.Select(clip => clip.Id));
        Assert.Equal(["s1", "s0"], editor.RankedSuggestions.Select(clip => clip.Id));
    }

    [Fact]
    public void AskClaudeRewordsTheAskedWordsAndKeepsEditsApart()
    {
        var (editor, _, requests) = Open("funny");
        editor.AskClaudeServices = new AskClaudeServices { Ask = (_, _) => throw new InvalidOperationException("not sent"), Available = () => true, CostLine = () => "" };
        editor.SetScope("c1");
        editor.Select(12);
        editor.Select(14, extend: true);
        Assert.True(editor.OpenAskClaudeOnSelection());
        var quick = editor.AskClaudeQuickTones;
        Assert.Equal(["funny", RewriteStripItem.FixMistakesId, RewriteStripItem.ShorterId, "punchy-reel"], quick.Select(item => item.Id));
        Assert.True(quick[0].IsDefault);
        Assert.Equal(quick, editor.AskClaudeTones);
        // Tones never join the effect chips.
        var effects = AskClaudeState.Chips.Select(chip => chip.Label).ToHashSet();
        Assert.DoesNotContain(editor.RewriteStripItems, item => effects.Contains(item.Title));
        // More… shows every chip of the strip, in place.
        editor.ShowAllAskClaudeTones();
        Assert.Equal(editor.RewriteStripItems, editor.AskClaudeTones);
        // A chip is the strip's chip: Rewrite runs at once on the asked words with that tone, and the field closes.
        Assert.True(editor.AskClaudeRewriteAs(quick[0]));
        Assert.Equal(new RewriteAsRequest(quick[0].Instruction, quick[0].Title, Words: (12, 14)), requests[^1]);
        Assert.False(editor.AskClaude.IsOpen);
        // On a whole clip it rewords the clip.
        Assert.True(editor.OpenAskClaudeOnClip("c1"));
        var shorter = editor.RewriteStripItems.First(item => item.Id == RewriteStripItem.ShorterId);
        Assert.True(editor.AskClaudeRewriteAs(shorter));
        Assert.Equal(new RewriteAsRequest(shorter.Instruction, shorter.Title, ClipId: "c1"), requests[^1]);
    }

    [Fact]
    public void TheStripsAreWiredWhereTheCreatorAsks()
    {
        var app = Path.Combine(Path.GetDirectoryName(Root)!, "apps", "windows", "src", "VoxClip.App");
        var flyout = File.ReadAllText(Path.Combine(app, "Controls", "SelectionFlyout.cs"));
        Assert.Contains("Label = \"✦ Rewrite as\"", flyout);
        var transcript = File.ReadAllText(Path.Combine(app, "Controls", "TranscriptView.cs"));
        Assert.Contains("selectionFlyout.RewriteAs = item => model?.RewriteSelectionAs(item);", transcript);
        var page = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.xaml"));
        Assert.Contains("x:Name=\"ToneButton\"", page);
        Assert.Contains("x:Name=\"SaveToneHost\"", page);
        var code = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.xaml.cs"));
        Assert.Contains("ViewModel.RewriteShortcutItem(ShellAsk.Text)", code);
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml"));
        foreach (var key in new[] { "ClipRow", "SuggestionRow" })
            Assert.Contains("AutomationProperties.AutomationId=\"Clip.RewriteAs\"", window.Split($"x:Key=\"{key}\"")[1].Split("</MenuFlyout>")[0]);
        var settings = File.ReadAllText(Path.Combine(app, "SettingsWindow.xaml.cs"));
        Assert.Contains("Ui.Text(\"Your tones\"", settings);
    }
}
#endif

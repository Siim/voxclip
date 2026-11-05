#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.AskClaudeAppTests;
using static VoxClip.Core.Tests.Tracks.WinUi.MakeItPostableTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The Windows Ask Claude smoke, a headless twin of Mac <c>S-ask-bleep-blur</c> and <c>S-ask-overlay</c>: the user selects words,
/// opens the inline field from the selection flyout, a chip fills it, they type and press Return, then work the change list. A scripted
/// Claude Code connector answers through the real <see cref="AskClaudeService"/>; nothing is paid or sent anywhere. Checks A1–A12 after
/// each step, as on the Mac (A8 compares the one render input the preview and the export both resolve).</summary>
public sealed class AskClaudeSmokeTests
{
    private sealed class Smoke(EditorViewModel editor, Fake fake)
    {
        internal List<string> Log { get; } = [];
        internal List<string> Failures { get; } = [];
        internal List<ConnectorConsentAction> Consents { get; } = [];

        internal void Record(string action, params (string Invariant, bool Passed, string Detail)[] checks)
        {
            Log.Add($"{Log.Count + 1}. {action}");
            foreach (var (invariant, passed, detail) in checks)
            {
                Log.Add($"   {invariant} {(passed ? "pass" : "FAIL")}: {detail}");
                if (!passed) Failures.Add($"{action} · {invariant}: {detail}");
            }
        }

        /// <summary>An applied row can be undone, a paid one has its priced click, a later one says why.</summary>
        internal static bool CanAct(AskClaudeRow row) => row.Status switch
        {
            AskClaudeRowStatus.Applied or AskClaudeRowStatus.Undone => true,
            AskClaudeRowStatus.Paid => row.Price.Length > 0,
            AskClaudeRowStatus.Later => row.Reason.Length > 0,
            _ => row.WholeClipId is { Length: > 0 }
        };

        /// <summary>The preview (the open scope) and the export (the full edit here) resolve the same effects, and bleeped words mask.</summary>
        internal (string, bool, string)[] Render(bool masked)
        {
            var data = Path.Combine(Path.GetTempPath(), "voxclip-ask-claude-smoke");
            var preview = ClipRenderInput.Resolve(editor.Project, editor.State?.ActiveClipId, data, Root)?.Effects?.Effects ?? [];
            var export = ClipRenderInput.Resolve(editor.Project, null, data, Root)?.Effects?.Effects ?? [];
            var same = preview.Count > 0 && preview.Select(effect => effect.Id).SequenceEqual(export.Select(effect => effect.Id));
            var checks = new List<(string, bool, string)> { ("A8", same, "preview and export effects: " + string.Join(", ", preview.Select(effect => effect.Id))) };
            if (masked)
            {
                var captions = editor.Words.Select(word => new CaptionWord(word.Id, editor.DisplayText(word), word.Start, word.End)).ToArray();
                var blocks = ClipEffectsRendering.MaskingBleeps(captions, export).Count(word => word.Text.Contains('×'));
                checks.Add(("A8", blocks > 0, $"{blocks} caption word(s) masked by the bleep"));
            }
            return [.. checks];
        }

        internal async Task RunAsync(int first, int last, string instruction, string[] expected, string undoOne, bool masked, int paidRows = 0, string? adjust = null)
        {
            var before = editor.Project;
            // 1. Select the words, then the selection flyout's ✦ Ask Claude.
            editor.Select(first);
            editor.Select(last, extend: true);
            var opened = editor.OpenAskClaudeOnSelection();
            Record($"select words {first}–{last}, click [✦ Ask Claude]",
                ("A1", opened && editor.AskClaude.IsOpen, "the inline field opens in the right column: " + editor.AskClaude.Label),
                ("A2", editor.AskClaudeCostLine == "Free on your Claude plan", "cost line: " + editor.AskClaudeCostLine),
                ("A3", fake.Requests.Count == 0, "nothing is sent before Return"));

            // 2. A chip only fills the field; then the user's own words and Return.
            editor.FillAskClaude(AskClaudeState.Chips[0].Text);
            var chipSent = fake.Requests.Count;
            editor.AskClaude.Text = instruction;
            await editor.SendAskClaudeAsync();
            var run = editor.AskClaude.Run;
            var kinds = editor.Project.ClipEffects.Select(effect => effect.GetProperty("kind").GetString()!).ToArray();
            var request = fake.Requests.FirstOrDefault();
            List<(string, bool, string)> answer =
            [
                ("A3", chipSent == 0, "a chip filled the field and sent nothing"),
                ("A4", fake.Requests.Count == 1 && request is { Feature: LlmFeature.AskClaude, Effort: Effort.XHigh } && request.Instruction.Contains("Instruction: " + instruction, StringComparison.Ordinal)
                    && Consents.Count <= 1 && Consents.All(action => action == ConnectorConsentAction.AskClaude),
                    $"{fake.Requests.Count} request(s), feature {request?.Feature}, consent {string.Join(", ", Consents)}"),
                ("A5", kinds.Order().SequenceEqual(expected.Order()), "applied: " + string.Join(", ", kinds) + " " + editor.AskClaude.Error),
                ("A6", run is not null && run.Rows.Count == expected.Length + paidRows && run.AppliedCount == expected.Length,
                    "rows: " + string.Join("; ", run?.Rows.Select(row => row.Title + " " + row.Status) ?? [])),
                ("A7", run?.Rows.All(CanAct) == true, "every row offers a control that acts"),
                .. Render(masked)
            ];
            if (paidRows > 0)
            {
                var paid = run?.Rows.Count(row => row.Status == AskClaudeRowStatus.Paid && row.Price.StartsWith("Voice it · ", StringComparison.Ordinal)) ?? 0;
                answer.Add(("A9", paid == paidRows, $"{paid} priced row(s) wait for their click; no voice was made"));
            }
            Record($"type '{instruction}', press Return", [.. answer]);
            if (run is null) return;

            // 3. Adjust a row inline: nudge its start by a tenth of a second.
            if (adjust is not null && run.Rows.FirstOrDefault(row => Kind(row) == adjust) is { } adjusted && editor.AskClaudeEffect(adjusted.Id)?.Start is { } start)
            {
                editor.ToggleAskClaudeAdjust(adjusted.Id);
                editor.NudgeAskClaudeEffect(adjusted.Id, true, 0.1);
                var moved = editor.AskClaudeEffect(adjusted.Id)?.Start ?? start;
                Record($"click [Adjust] on {adjusted.Title}, nudge its start", [("A10", Math.Abs(moved - start - 0.1) < 1e-6, $"start {start} → {moved}"), .. Render(masked)]);
                editor.ToggleAskClaudeAdjust(adjusted.Id);
            }

            // 4. Undo one row: the others stay.
            if (run.Rows.FirstOrDefault(row => Kind(row) == undoOne) is { } undone)
            {
                editor.UndoAskClaudeRow(undone.Id);
                var left = editor.Project.ClipEffects.Select(effect => effect.GetProperty("kind").GetString()!).ToArray();
                Record($"click [Undo] on {undone.Title}",
                    ("A11", !left.Contains(undoOne) && left.Length == expected.Length - 1 && undone.Status == AskClaudeRowStatus.Undone, "left: " + string.Join(", ", left)));
            }

            // 5. Undo all, then Done.
            editor.UndoAllAskClaude();
            Record("click [Undo all]",
                ("A12", editor.Project.ClipEffects.Count == 0 && editor.Project.Edits == before.Edits && run.AppliedCount == 0, $"effects left: {editor.Project.ClipEffects.Count}"),
                ("A3", fake.Requests.Count == 1, "undo sent nothing"));
            editor.CloseAskClaude();
            Record("click [Done]", ("A1", !editor.AskClaude.IsOpen, "the field closes; the column returns to captions"));
        }

        private static string? Kind(AskClaudeRow row) =>
            row.Operation.Action is ClipAutopilotAction.Effect { Value: var value } ? value.GetProperty("kind").GetString() : null;
    }

    private static Smoke Prepare(string reply)
    {
        var (editor, fake) = Open(reply);
        var smoke = new Smoke(editor, fake);
        var send = editor.AskClaudeServices!.Ask;
        // The page asks inline once for a first send on a plan; the smoke records the consent action it would show.
        editor.AskClaudeServices = new AskClaudeServices
        {
            Ask = (ask, ct) => { if (smoke.Consents.Count == 0) smoke.Consents.Add(ConnectorConsentAction.AskClaude); return send(ask, ct); },
            Available = editor.AskClaudeServices.Available, CostLine = editor.AskClaudeServices.CostLine, Prices = editor.AskClaudeServices.Prices
        };
        return smoke;
    }

    private static void Pass(Smoke smoke) => Assert.True(smoke.Failures.Count == 0, string.Join("\n", smoke.Failures) + "\n" + string.Join("\n", smoke.Log));

    /// <summary>The mockup's example: words over an invoice on screen, "blur the invoice on screen and bleep the amount".</summary>
    [Fact]
    public async Task SAskBleepBlur()
    {
        var smoke = Prepare(Reply(Op("blur", ("x", 0.55), ("y", 0.2), ("width", 0.35), ("height", 0.3), ("tracking", "none"), ("target", "the invoice")),
            Op("bleep", ("startWord", 7), ("endWord", 8))));
        await smoke.RunAsync(6, 10, "blur the invoice on screen and bleep the amount", ["blur", "bleep"], "blur", masked: true);
        Pass(smoke);
    }

    /// <summary>A title, an emoji and an arrow; the paid rewrite waits for its priced click; Adjust; Undo all.</summary>
    [Fact]
    public async Task SAskOverlay()
    {
        var smoke = Prepare(Reply(Op("title", ("text", "Day 1"), ("position", "top")), Op("sticker", ("text", "🎉"), ("position", "topRight"), ("scale", 0.18)),
            Op("arrow", ("x", 0.6), ("y", 0.55), ("width", 0.12), ("height", 0.12), ("target", "the button")),
            Op("rewrite", ("startWord", 13), ("endWord", 19), ("text", "film a quick clip in one go"))));
        await smoke.RunAsync(11, 19, "add a title Day 1, an emoji and an arrow at the button", ["title", "sticker", "arrow"], "sticker", masked: false, paidRows: 1, adjust: "title");
        Pass(smoke);
    }
}
#endif

using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

// Rewrite fixes its own stuck phrases (design.md R2 "Automatic fixes", voice-lab.md §8.2.2; Mac RewriteAutoFix.swift). Once
// the user approves Get Price, every phrase whose takes are stuck is handled phrase by phrase with no click, through the paths
// the next-step chips use: a measured reword for a take too long or too short, one more take for a failed check, then a scoped
// reword with easier words. Each phrase gets at most three automatic rounds; after the last its original words are kept.
// Automatic spend is capped at max($0.10, the approved price); the next step past it waits for [Keep fixing · ≈ $y]. New
// takes are added beside the old ones, never in place of a paid one. Stop keeps everything made so far and shows the chips.

/// <summary>Why a phrase's takes are stuck: what the resolver fixes and what the phrase's one plain sentence says.</summary>
internal abstract record StuckTakeReason
{
    /// <summary>The closest take is too long (or too short) for its slot even with every duration choice.</summary>
    internal sealed record Length(bool TooLong, double Measured, double Slot, Guid Take, int Number, bool Selected) : StuckTakeReason;
    /// <summary>Every take failed the word check (a homophone of the asked words passes, voice-lab.md §8.11).</summary>
    internal sealed record Words : StuckTakeReason;
    /// <summary>Every take failed the speaker check.</summary>
    internal sealed record Voice : StuckTakeReason;
    /// <summary>The phrase is too short to check the voice on its own words: it needs its whole sentence.</summary>
    internal sealed record ShortSpeech : StuckTakeReason;
    /// <summary>Any other failed check, in the take row's own words.</summary>
    internal sealed record Other(string Reason) : StuckTakeReason;
}

/// <summary>The step past the spending cap: what [Keep fixing · ≈ $y] approves. <see cref="Take"/>: a take whose quote is ready.</summary>
internal sealed record AutoFixCap(int Phrase, decimal? Usd, bool Take);

internal sealed class RewriteAutoFixState
{
    /// <summary>Rounds per phrase before its original words are kept.</summary>
    internal const int MaximumRounds = 3;
    /// <summary>The least automatic fixes may spend after an approved price.</summary>
    internal const decimal MinimumAllowance = 0.10m;
    internal bool Armed { get; set; }
    internal bool Stopped { get; set; }
    internal string StopReason { get; set; } = "";
    /// <summary>What automatic fixes may spend: max($0.10, the approved price), raised by Keep fixing.</summary>
    internal decimal Allowance { get; set; }
    /// <summary>What automatic fixes spent so far: takes, and AI sends billed to a key.</summary>
    internal decimal Spent { get; set; }
    internal AutoFixCap? Capped { get; set; }
    /// <summary>Keep fixing approved the next step, whose price may be unknown (an AI send billed to a key).</summary>
    internal bool NextApproved { get; set; }
    internal Dictionary<int, int> Rounds { get; } = [];
    internal HashSet<int> TriedAnother { get; } = [];
    /// <summary>The live line of the phrase being fixed.</summary>
    internal Dictionary<int, string> Lines { get; } = [];
    /// <summary>Phrases whose rounds ended: their original words are kept.</summary>
    internal HashSet<int> GaveUp { get; } = [];
    /// <summary>What the fixes decided on their own, for the summary.</summary>
    internal List<string> Notes { get; } = [];
    /// <summary>"Choose yourself…" was opened: the chips show while fixes run.</summary>
    internal bool ShowChoices { get; set; }
    internal string Announcement { get; set; } = "";
    internal int Token { get; set; }
    internal Task? Work { get; set; }
    /// <summary>Fixing without a click right now.</summary>
    internal bool Running => Armed && !Stopped && Capped is null;
    /// <summary>The chips show: after Stop, at the cap, or once asked for.</summary>
    internal bool ChoicesShown => !Running || ShowChoices;

    internal void Reset()
    {
        Token++; Work = null;
        Armed = false; Stopped = false; StopReason = ""; Allowance = 0; Spent = 0; Capped = null; NextApproved = false;
        Rounds.Clear(); TriedAnother.Clear(); Lines.Clear(); GaveUp.Clear(); Notes.Clear(); ShowChoices = false; Announcement = "";
    }
}

internal sealed partial class RewriteSession
{
    internal const string ClearerInstruction = "Avoid words that are hard to say or hear; keep the meaning.";
    internal RewriteAutoFixState AutoFix { get; } = new();
    private bool manualStep;
    /// <summary>The settled automatic step, for tests and the smoke: completes when no step runs.</summary>
    internal Task AutoFixWork => AutoFix.Work ?? Task.CompletedTask;

    /// <summary>What automatic fixes may spend after this price: max($0.10, the price).</summary>
    internal static decimal AutoFixAllowance(decimal? usd) => Math.Max(RewriteAutoFixState.MinimumAllowance, usd ?? 0);
    internal static string Dollars(decimal usd) => "$" + usd.ToString("0.00", CultureInfo.InvariantCulture);
    /// <summary>The line under Get Price's priced button (design.md R2): what the approval also covers.</summary>
    internal string? AutoFixAllowanceLine => !HasPaidTakes && PreparedBatch is { } batch
        ? $"Automatic fixes may spend up to {Dollars(AutoFixAllowance(batch.Estimate.Usd))} more." : null;
    /// <summary>[Keep fixing · ≈ $y] past the cap; null otherwise.</summary>
    internal string? KeepFixingTitle => AutoFix.Capped is { } cap
        ? "Keep fixing" + (cap.Usd is { } usd ? " · ≈ " + Dollars(usd) : "") : null;
    internal string? AutoFixCapLine => AutoFix.Capped is null ? null
        : $"Automatic fixes spent {Dollars(AutoFix.Spent)} of {Dollars(AutoFix.Allowance)}. The next fix waits for you.";

    /// <summary>The approved Get Price: stuck phrases of these takes are fixed from now on.</summary>
    private void ArmAutoFix(VoiceLabTakeBatch batch)
    {
        AutoFix.Reset();
        AutoFix.Armed = true;
        AutoFix.Allowance = AutoFixAllowance(batch.Estimate.Usd);
        foreach (var window in generationWindows) window.KeepEveryTake();
    }

    /// <summary>Counts <paramref name="usd"/> against the allowance. Past it the step waits for Keep fixing and its round is given back.</summary>
    private bool AutoFixCharge(decimal? usd, int phrase, bool take)
    {
        // A chip the user clicked carries its own price: the click approves it, outside the automatic allowance.
        if (manualStep) return true;
        if (AutoFix.NextApproved)
        {
            AutoFix.NextApproved = false;
            AutoFix.Spent += usd ?? 0;
            return true;
        }
        if (usd is not { } amount || AutoFix.Spent + amount > AutoFix.Allowance)
        {
            AutoFix.Capped = new(phrase, usd, take);
            AutoFix.Rounds[phrase] = Math.Max(0, AutoFix.Rounds.GetValueOrDefault(phrase, 1) - 1);
            AutoFix.Lines.Clear();
            return false;
        }
        AutoFix.Spent += amount;
        return true;
    }
    /// <summary>An AI send billed to a key counts against the cap (its price is unknown, so it waits for Keep fixing); a
    /// subscription or local AI costs nothing extra.</summary>
    private bool AutoFixChargeSend(int phrase) => !FitAsksFirst || AutoFixCharge(null, phrase, take: false);

    /// <summary>[Keep fixing · ≈ $y]: approves the next step and goes on.</summary>
    internal void KeepFixing()
    {
        if (AutoFix.Capped is not { } cap || !IsOpen) return;
        AutoFix.Allowance = AutoFix.Spent + Math.Max(cap.Usd ?? 0, RewriteAutoFixState.MinimumAllowance);
        AutoFix.Capped = null;
        AutoFix.NextApproved = true;
        if (cap.Take && generationWindows.ElementAtOrDefault(cap.Phrase) is not null)
        {
            AutoFix.Rounds[cap.Phrase] = AutoFix.Rounds.GetValueOrDefault(cap.Phrase) + 1;
            RunAutoStep(cap.Phrase, $"Fixing phrase {cap.Phrase + 1}: making a take…", () => StartAutomaticTakeAsync(cap.Phrase));
            return;
        }
        AdvanceAutoFix();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Stop: ends the fixes and any take they run, and keeps everything made so far; the chips show.</summary>
    internal void StopAutoFix(string reason = "")
    {
        if (!AutoFix.Armed || AutoFix.Stopped) return;
        AutoFix.Stopped = true; AutoFix.StopReason = reason;
        AutoFix.Token++; AutoFix.Work = null; AutoFix.Lines.Clear(); AutoFix.NextApproved = false;
        if (MeasuredWording is { Preparing: true }) { CancelMeasuredWording(); MeasuredWording = null; }
        foreach (var window in generationWindows.Where(window => window.IsRunning).ToArray()) _ = window.CancelAsync();
        Changed?.Invoke(this, EventArgs.Empty);
    }
    internal void ShowAutoFixChoices() { AutoFix.ShowChoices = true; Changed?.Invoke(this, EventArgs.Empty); }

    /// <summary>Why phrase <paramref name="index"/>'s takes are stuck (Mac <c>stuckReason</c>); null when it isn't.</summary>
    internal StuckTakeReason? StuckReason(int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window || window.LeftOut || window.Rows.Count == 0 ||
            window.IsRunning || window.IsPreparing) return null;
        var current = window.Rows.Where(row => !row.Stopped).ToArray();
        if (current.Length == 0) return null;
        if (window.Selected is { Selectable: true } selected)
        {
            if (!window.NeedsShorterWording || RewriteGeneration.Length(selected) is not { } length || window.Slot(selected) is not { } slot) return null;
            return new StuckTakeReason.Length(length > slot, length, slot, selected.Id, selected.Index + 1, true);
        }
        // A passing take not chosen yet (a join to listen to first) is the user's pick, not a stuck phrase.
        if (current.Any(row => row.Selectable)) return null;
        var closest = current.Where(row => RewriteGeneration.Length(row) is not null && window.Slot(row) is not null)
            .OrderBy(row => Math.Abs(RewriteGeneration.Length(row)!.Value - window.Slot(row)!.Value)).ThenBy(row => row.Index).FirstOrDefault();
        if (closest is not null && !window.LengthFits(closest))
        {
            var length = RewriteGeneration.Length(closest)!.Value;
            var slot = window.Slot(closest)!.Value;
            return new StuckTakeReason.Length(length > slot, length, slot, closest.Id, closest.Index + 1, false);
        }
        var failures = current.SelectMany(row => row.Qa?.Failures ?? []).ToArray();
        if (failures.Contains(VoiceLabTakeQaFailure.InsufficientGeneratedSpeech) || current.Any(row => row.Failure is VoiceInsufficientGeneratedSpeechException))
            return new StuckTakeReason.ShortSpeech();
        if (failures.Contains(VoiceLabTakeQaFailure.Transcript)) return new StuckTakeReason.Words();
        if (failures.Contains(VoiceLabTakeQaFailure.Speaker)) return new StuckTakeReason.Voice();
        return new StuckTakeReason.Other(current.Select(row => TakeRowPresentation.From(row, null, index + 1).FailureText).LastOrDefault(text => text is not null)
            ?? "Its takes did not pass the checks.");
    }

    /// <summary>The phrase's one plain sentence for <paramref name="reason"/> (design.md R2): what went wrong, never a list of checks.</summary>
    internal static string StuckSentence(StuckTakeReason reason, int phrase)
    {
        static string Seconds(double value) => value.ToString("F1", CultureInfo.InvariantCulture) + " s";
        return reason switch
        {
            StuckTakeReason.Length length => $"Phrase {phrase}: {(length.Selected ? "Take " + length.Number : "Its closest take")} runs {Seconds(length.Measured)} for a {Seconds(length.Slot)} slot, too {(length.TooLong ? "long" : "short")} to fit.",
            StuckTakeReason.Words => $"Phrase {phrase}: the word check heard different words in every take.",
            StuckTakeReason.Voice => $"Phrase {phrase}: no take sounded enough like your voice.",
            StuckTakeReason.ShortSpeech => $"Phrase {phrase}: too short to check your voice on its own words.",
            StuckTakeReason.Other other => $"Phrase {phrase}: {other.Reason}",
            _ => $"Phrase {phrase}: its takes did not pass the checks."
        };
    }

    /// <summary>Takes the next automatic step, if one is due: one phrase, one step at a time. Called whenever the takes settle.</summary>
    internal void AdvanceAutoFix()
    {
        if (!AutoFix.Running || AutoFix.Work is not null || !IsOpen || !GenerationIsCurrent || IsGeneratingBatch || applyingBatch ||
            MeasuredWording is { Preparing: true } || PendingPaidReviewChange is not null ||
            generationWindows.Any(window => window.IsRunning || window.IsPreparing)) return;
        // A spending limit or a provider failure ends the fixes the same way Stop does.
        if (generationWindows.FirstOrDefault(window => window.Phase == RewriteGenerationPhase.Failed && window.Problem.Length > 0) is { } failed)
        {
            StopAutoFix(failed.Problem);
            return;
        }
        for (var index = 0; index < generationWindows.Count; index++)
        {
            if (StuckReason(index) is not { } reason) { AutoFix.Lines.Remove(index); continue; }
            var used = AutoFix.Rounds.GetValueOrDefault(index);
            if (used >= RewriteAutoFixState.MaximumRounds) { GiveUp(index); continue; }
            AutoFix.Rounds[index] = used + 1;
            var phrase = index;
            var number = index + 1;
            switch (reason)
            {
                case StuckTakeReason.Length length:
                    RunAutoStep(phrase, $"Fixing phrase {number}: asking {Connector?.Name ?? "the AI"} for a {(length.TooLong ? "shorter" : "longer")} wording…",
                        () => RewordForLengthAsync(phrase, length));
                    break;
                case StuckTakeReason.ShortSpeech when CanWidenToSentence(phrase):
                    RunAutoStep(phrase, $"Fixing phrase {number}: voicing its whole sentence…", () => WidenToSentenceAsync(phrase));
                    break;
                case StuckTakeReason.Words when AutoFix.TriedAnother.Contains(phrase):
                    RunAutoStep(phrase, $"Fixing phrase {number}: asking {Connector?.Name ?? "the AI"} for words that are easier to say…",
                        () => RewordClearerAsync(phrase));
                    break;
                default:
                    AutoFix.TriedAnother.Add(phrase);
                    RunAutoStep(phrase, $"Fixing phrase {number}: trying another take…", () => StartAutomaticTakeAsync(phrase));
                    break;
            }
            return;
        }
    }

    private void RunAutoStep(int phrase, string line, Func<Task> body)
    {
        AutoFix.Lines.Clear();
        AutoFix.Lines[phrase] = line;
        AutoFix.Announcement = line;
        var token = AutoFix.Token;
        var gate = new TaskCompletionSource();
        AutoFix.Work = RunAsync();
        Changed?.Invoke(this, EventArgs.Empty);
        gate.SetResult();
        async Task RunAsync()
        {
            await gate.Task;
            try { if (token == AutoFix.Token && IsOpen) await body(); }
            catch (OperationCanceledException) { }
            catch (Exception error) when (error is not OutOfMemoryException) { if (IsOpen && token == AutoFix.Token) StopAutoFix(Refusal(error)); }
            finally
            {
                if (token == AutoFix.Token && IsOpen)
                {
                    AutoFix.Work = null;
                    AutoFix.Lines.Remove(phrase);
                    AdvanceAutoFix();
                    Changed?.Invoke(this, EventArgs.Empty);
                }
            }
        }
    }

    /// <summary>Makes the take of phrase <paramref name="index"/>'s ready quote, within the cap. Every earlier take stays.</summary>
    internal async Task StartAutomaticTakeAsync(int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window || !GenerationIsCurrent) return;
        if (window.IsPreparing) await window.PendingUpdate;
        if (window.Quote is null) await window.InputsChangedAsync(preserveReview: true);
        if (window.Quote is not { } quote || !GenerationIsCurrent || window.IsRunning) return;
        if (!AutoFixCharge(quote.Estimate.Usd, index, take: true)) { Changed?.Invoke(this, EventArgs.Empty); return; }
        MeasuredWording = null;
        AutoFix.Lines[index] = $"Fixing phrase {index + 1}: making a take…";
        Changed?.Invoke(this, EventArgs.Empty);
        window.MarkEstimateShown(quote);
        // The approved Get Price covers this take's own price; a changed monthly-cap decision still needs the user.
        var asked = 0;
        await window.GenerateAsync((_, _) => Task.FromResult(asked++ == 0), quote, autoplay: false);
    }

    /// <summary>A take too long or too short: one measured reword from that take, then a take of the new wording.</summary>
    private async Task RewordForLengthAsync(int index, StuckTakeReason.Length reason)
    {
        if (Connector is null || generationWindows.ElementAtOrDefault(index) is null) return;
        if (!AutoFixChargeSend(index)) { Changed?.Invoke(this, EventArgs.Empty); return; }
        CancelMeasuredWording();
        MeasuredWording = new(index, reason.Take, reason.Number, reason.Measured, reason.Slot) { Unselected = !reason.Selected };
        await (MeasuredWork = RewordMeasuredTakeAsync(true));
        if (MeasuredWording is not { } suggestion) return;
        if (suggestion.KeepOriginal) { GiveUp(index); return; }
        if (suggestion.Text is null || suggestion.Problem.Length > 0) return;
        await StartAutomaticTakeAsync(index);
    }

    /// <summary>Takes that failed the word check twice: the AI rewords this phrase alone with easier words (a scoped re-ask),
    /// kept with this phrase's takes like a measured reword so no other phrase changes, then a take of it is made.</summary>
    private async Task RewordClearerAsync(int index)
    {
        if (PricedVoiceHunks.ElementAtOrDefault(index) is not { Ordinals.Count: 1, Window: { } placed } phrase ||
            generationWindows.ElementAtOrDefault(index) is not { } window || Review is null) return;
        var ordinal = phrase.Ordinals[0];
        if (!AutoFixChargeSend(index)) { Changed?.Invoke(this, EventArgs.Empty); return; }
        var reply = await SendReaskAsync(new("Easier words", ClearerInstruction, [ordinal], RewriteBlockedReason.Take), lifetime.Token);
        if (reply is null || !IsOpen || Review is null) return;
        var outcomes = RewriteScopedReply.Assign(Review.Diff.Hunks, new HashSet<int> { ordinal - 1 }, reply.Hunks);
        switch (outcomes.GetValueOrDefault(ordinal - 1))
        {
            case { Kind: RewriteScopedReply.OutcomeKind.Replace, Index: var found }:
                var hunk = reply.Hunks[found];
                if (!hunk.SourceWordIds.SequenceEqual(Review.Diff.Hunks[ordinal - 1].SourceWordIds)) return;
                string Text(string id) => Transcript.First(word => word.Id == id).Text;
                var text = string.Join(" ", placed.LeftBridgeWordIds.Select(Text).Concat(hunk.NewTokens).Concat(placed.RightBridgeWordIds.Select(Text)));
                if (text == (measuredWording.GetValueOrDefault(index) ?? phrase.PatchText)) return;
                measuredWording[index] = text;
                await window.InputsChangedAsync(preserveReview: true);
                await StartAutomaticTakeAsync(index);
                break;
            case { Kind: RewriteScopedReply.OutcomeKind.KeepOriginal }:
                GiveUp(index);
                break;
        }
    }

    private bool CanWidenToSentence(int index)
    {
        if (PricedVoiceHunks.ElementAtOrDefault(index) is not { Ordinals.Count: 1 } phrase) return false;
        var widened = ReviewSurroundingSentence(phrase.Ordinals[0]);
        SentenceReview = null; SentenceProblem = ""; SentenceRefusedOrdinal = null;
        return widened;
    }

    /// <summary>A phrase too short to check on its own: its whole sentence is voiced instead, when it fits the clip. Its
    /// failed short takes are replaced, as a manual Use surrounding sentence does.</summary>
    private async Task WidenToSentenceAsync(int index)
    {
        if (PricedVoiceHunks.ElementAtOrDefault(index) is not { Ordinals.Count: 1 } phrase ||
            generationWindows.ElementAtOrDefault(index) is not { } previous) return;
        var voice = previous.VoiceId;
        if (!ReviewSurroundingSentence(phrase.Ordinals[0]) || SentenceReview is not { } review || !AcceptSurroundingSentence(review)) return;
        if (generationWindows.ElementAtOrDefault(index) is not { } window) return;
        window.KeepEveryTake();
        await window.DiscoverAsync();
        if (voice is not null) await window.ChooseVoiceAsync(voice);
        await window.PendingUpdate;
        AutoFix.Notes.Add($"Phrase {index + 1} is voiced as its whole sentence, so your voice can be checked.");
        await StartAutomaticTakeAsync(index);
    }

    /// <summary>The rounds ended: the phrase keeps its original words; its takes stay listed and text fixes still apply.</summary>
    private void GiveUp(int index)
    {
        if (!AutoFix.GaveUp.Add(index)) return;
        generationWindows.ElementAtOrDefault(index)?.LeaveOut();
        AutoFix.Lines.Remove(index);
        AutoFix.Announcement = $"Phrase {index + 1} kept your original audio after {AutoFix.Rounds.GetValueOrDefault(index, RewriteAutoFixState.MaximumRounds)} tries.";
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Keep original words for one phrase with takes: no take of it is used, every take stays (never a discard).</summary>
    internal bool KeepOriginal(int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window || !window.LeaveOut()) return false;
        AutoFix.Lines.Remove(index);
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }
    /// <summary>Undo of Keep original words or of the last automatic round: the phrase's automatic take is used again.</summary>
    internal bool UndoKeepOriginal(int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window || !window.Restore()) return false;
        AutoFix.GaveUp.Remove(index);
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }
    /// <summary>Phrases kept as recorded, by phrase index.</summary>
    internal IReadOnlyList<int> LeftOutPhrases => generationWindows.Select((window, index) => (window, index)).Where(item => item.window.LeftOut)
        .Select(item => item.index).ToArray();
}

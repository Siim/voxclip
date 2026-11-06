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
    /// <summary>The provider refused or could not finish the takes (key, credit, permission, rate, network): its cause and its one
    /// fix show; no wording round can help.</summary>
    internal sealed record Provider(Exception Error) : StuckTakeReason;
    /// <summary>No word timing even after recovery from the word check and on device (voice-lab.md §8.5): one more take.</summary>
    internal sealed record Timing : StuckTakeReason;
    /// <summary>The use-time guard refused the phrase's speech before anything was sent (ADR-R40, voice-lab.md §6.9): no retry or
    /// rewording can change that, so the phrase is settled with <see cref="Reason"/>.</summary>
    internal sealed record Blocked(string Reason) : StuckTakeReason;
    /// <summary>Any other failed check, in the take row's own words.</summary>
    internal sealed record Other(string Reason) : StuckTakeReason;

    /// <summary>Only wording and fit failures are fixed by rewording (voice-lab.md §8.2.2).</summary>
    internal bool Rewords => this is Length or Words;
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
    /// <summary>Wordings the AI suggested that were not used (a repeat, not moving toward the slot, or without the bridge words),
    /// by phrase: the next round is told about them with the wordings that were voiced.</summary>
    internal Dictionary<int, List<VoiceLabFitTried>> Refused { get; } = [];
    /// <summary>Phrases [Price a take] priced afresh (after an account failure, or with no take yet): their control now makes the
    /// take at the price it shows.</summary>
    internal HashSet<int> Priced { get; } = [];
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
        Refused.Clear(); Priced.Clear();
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

    /// <summary>Make it postable's budget left after the takes' price: automatic fixes never spend past it. Null: no ceiling.</summary>
    internal decimal? AutoFixCeiling { get; set; }

    /// <summary>The approved Get Price: stuck phrases of these takes are fixed from now on.</summary>
    private void ArmAutoFix(VoiceLabTakeRunParts batch)
    {
        AutoFix.Reset();
        AutoFix.Armed = true;
        AutoFix.Allowance = Math.Min(AutoFixAllowance(batch.Estimate.Usd), AutoFixCeiling ?? decimal.MaxValue);
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
        if (generationWindows.ElementAtOrDefault(index) is not { } window || window.LeftOut || window.IsRunning || window.IsPreparing) return null;
        if (window.WaitsOnBlock) return new StuckTakeReason.Blocked(window.Blocked!);
        if (window.Rows.Count == 0) return null;
        // ADR-R37: a short take waiting for its run's pooled voice check is not stuck yet.
        if (window.Rows.Any(row => row.VoiceCheck is VoiceLabTakeVoiceCheck.WaitingCheck)) return null;
        var current = window.Rows.Where(row => !row.Stopped && !window.IsBeforeExpression(row.Id)).ToArray();
        if (current.Length == 0) return null;
        if (window.Selected is { Selectable: true } selected)
        {
            // A take too short for every duration is not reworded longer, which would only pad (ADR-R42): its phrase keeps the
            // recorded audio (SettleTakesThatFitNoDuration).
            if (!window.NeedsShorterWording || RewriteGeneration.Length(selected) is not { } length || window.Slot(selected) is not { } slot ||
                length <= slot) return null;
            return new StuckTakeReason.Length(true, length, slot, selected.Id, selected.Index + 1, true);
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
        var providers = current.Select(row => row.Failure).OfType<VoiceLabException>().Where(error => IsAccountFailure(error.Kind)).ToArray();
        if (providers.Length == current.Length) return new StuckTakeReason.Provider(providers[^1]);
        if (current.All(row => RewriteGeneration.Length(row) is null && row.Failure is VoiceLabException { Kind: VoiceLabErrorKind.InvalidAlignment }))
            return new StuckTakeReason.Timing();
        var failures = current.SelectMany(row => row.Qa?.Failures ?? []).ToArray();
        if (failures.Contains(VoiceLabTakeQaFailure.InsufficientGeneratedSpeech) || current.Any(row => row.Failure is VoiceInsufficientGeneratedSpeechException ||
                row.VoiceCheck.Evidence?.Mode == VoiceLabShortSpeechMode.Unmeasured))
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
            StuckTakeReason.Provider provider => $"Phrase {phrase}: {ProviderProblem(provider.Error)}",
            StuckTakeReason.Timing => $"Phrase {phrase}: its take's word timing couldn't be read, even from the word check.",
            StuckTakeReason.Blocked blocked => $"Phrase {phrase}: {blocked.Reason}",
            StuckTakeReason.Other other => $"Phrase {phrase}: {other.Reason}",
            _ => $"Phrase {phrase}: its takes did not pass the checks."
        };
    }

    /// <summary>Provider failures no wording round can fix (voice-lab.md §8.2.2; Mac <c>isAccountFailure</c>): each has one fix.</summary>
    internal static bool IsAccountFailure(VoiceLabErrorKind kind) => kind is VoiceLabErrorKind.QuotaExceeded or VoiceLabErrorKind.Unauthorized or
        VoiceLabErrorKind.MissingKey or VoiceLabErrorKind.PermissionMissing or VoiceLabErrorKind.RateLimited or VoiceLabErrorKind.Network or
        VoiceLabErrorKind.ProviderFailure or VoiceLabErrorKind.PlanUnavailable or VoiceLabErrorKind.FeatureUnavailable or
        VoiceLabErrorKind.VoiceAccessDenied or VoiceLabErrorKind.ModelAccessDenied;
    /// <summary>The one fix an account failure names (Mac <c>ClipTakePlan.nextStep</c>); null when it has none.</summary>
    internal static string? ProviderFix(VoiceLabErrorKind kind) => kind switch
    {
        VoiceLabErrorKind.QuotaExceeded => "Add credit to your ElevenLabs account, then choose Price a take.",
        VoiceLabErrorKind.Unauthorized or VoiceLabErrorKind.MissingKey => "Check the ElevenLabs key in Settings, then choose Price a take.",
        VoiceLabErrorKind.PermissionMissing => "Give the ElevenLabs key the Text to Speech permission, then choose Price a take.",
        VoiceLabErrorKind.RateLimited or VoiceLabErrorKind.Network or VoiceLabErrorKind.ProviderFailure => "Choose Price a take to send it again.",
        _ => null
    };
    /// <summary>A failure's cause, then its one fix when it is an account failure: a run stopped by one says what to do next.</summary>
    internal static string ProviderProblem(Exception error) =>
        Refusal(error) + (error is VoiceLabException { Kind: var kind } && ProviderFix(kind) is { } fix ? " " + fix : "");

    /// <summary>design.md R2 "A take that can't fit its place" (Mac <c>settleTakesThatFitNoDuration</c>): a phrase whose take no video
    /// duration can carry (too short even with a cut, too long even with the matched speed, or a duration that can't be mapped) keeps
    /// its recorded audio with one line of why, and Use goes on with the rest, with no click in every mode. It runs before the footer
    /// is read, whenever the takes settle. A too-long take is left to the resolver while it is armed (<see cref="ResolverOwns"/>) and
    /// to the measured rewording round while that round is about to start, runs or waits on the creator
    /// (<see cref="MeasuredRoundOwns"/>); their ends settle it here. A too-short take is never reworded longer (ADR-R42).</summary>
    internal void SettleTakesThatFitNoDuration()
    {
        if (!IsOpen || !GenerationIsCurrent || IsGeneratingBatch || applyingBatch ||
            generationWindows.Any(window => window.IsRunning || window.IsPreparing)) return;
        List<int> settled = [];
        for (var index = 0; index < generationWindows.Count; index++)
        {
            if (!generationWindows[index].FitsNoDuration || AutoFix.Lines.ContainsKey(index) || ResolverOwns(index) || MeasuredRoundOwns(index)) continue;
            if (generationWindows[index].LeaveOut()) settled.Add(index);
        }
        if (settled.Count == 0) return;
        var copy = NoDurationCopy(settled.Select(index => index + 1).ToArray());
        if (AutoFix.Notes.Contains(copy)) return;
        AutoFix.Notes.Add(copy);
        AutoFix.Announcement = copy;
    }
    /// <summary>The armed resolver has a fix for phrase <paramref name="index"/> (Mac <c>resolverOwns</c>): a wording round, Keep fixing
    /// at the cap, or after Stop the phrase's own steps.</summary>
    private bool ResolverOwns(int index) => AutoFix.Armed && Wording(index) == PhraseWording.Suggested &&
        StuckReason(index) is { } reason and not StuckTakeReason.Provider;
    /// <summary>The measured rewording round has a shorter wording to offer for this too-long take (Mac <c>measuredRoundOwns</c>): it is
    /// about to start, is running, or waits on the creator (Skip, Keep Take N or the priced Make Take). Its end settles the phrase if
    /// the take still fits no duration. The round starts only while the resolver is not armed (<see cref="ObserveMeasuredTakes"/>); a
    /// too-short take never gets it.</summary>
    private bool MeasuredRoundOwns(int index)
    {
        if (Connector is null || Wording(index) != PhraseWording.Suggested || generationWindows.ElementAtOrDefault(index) is not { } window ||
            window.Selected is not { } take || RewriteGeneration.Length(take) is not { } length || window.Slot(take) is not { } slot || length <= slot) return false;
        if (MeasuredWording is { } open && open.Window == index && open.Take == take.Id) return true;
        return !AutoFix.Armed && !measuredTakes.Contains(take.Id) && (take.Receipt?.ModelId ?? window.InputFor(take.Id)?.ModelId) == synthesisModel;
    }
    /// <summary>The measured card's keep button (Mac <c>measuredKeepTitle</c>). A take no video duration carries can't be kept: keeping it
    /// ends in the recorded audio (<see cref="SettleTakesThatFitNoDuration"/>), so the button names that instead of the take.</summary>
    internal string MeasuredKeepTitle(RewriteMeasuredWording suggestion) => suggestion.AwaitingApproval ? "Skip"
        : MeasuredFitsNoDuration(suggestion) ? "Keep Original Audio" : $"Keep Take {suggestion.Number}";
    /// <summary>The measured round's take fits no video duration (its card says so; Mac <c>fitsNoDuration</c> for the round's phrase).</summary>
    internal bool MeasuredFitsNoDuration(RewriteMeasuredWording suggestion) => generationWindows.ElementAtOrDefault(suggestion.Window)?.FitsNoDuration == true;

    /// <summary>Takes the next automatic step, if one is due: one phrase, one step at a time. Called whenever the takes settle.</summary>
    internal void AdvanceAutoFix()
    {
        ApplyPendingExpressions();
        SettleTakesThatFitNoDuration();
        if (!AutoFix.Running || AutoFix.Work is not null || !IsOpen || !GenerationIsCurrent || IsGeneratingBatch || applyingBatch ||
            MeasuredWording is { Preparing: true } || PendingPaidReviewChange is not null ||
            generationWindows.Any(window => window.IsRunning || window.IsPreparing)) return;
        // A spending limit ends the fixes the same way Stop does. An account failure on a phrase's takes shows its cause and its
        // one fix on that phrase's card instead (voice-lab.md §8.2.2): a round of new words can't help it.
        if (generationWindows.Select((window, index) => (window, index)).FirstOrDefault(item => item.window.Phase == RewriteGenerationPhase.Failed &&
                item.window.Problem.Length > 0 && StuckReason(item.index) is not StuckTakeReason.Provider) is { window: { } failed })
        {
            StopAutoFix(failed.Problem);
            return;
        }
        // A collision found after paid takes (Mac's refused takes plan): a merge would discard the paid takes, so the refused
        // change keeps its original words, which costs nothing and moves no take. Its card shows if that can't be done.
        if (HasPaidTakes && Collision is { } collision && KeepCollidedOriginal(collision.Change))
        {
            var note = $"Change {collision.Change} keeps its original words: it's too close to change {collision.Earlier} to voice separately.";
            AutoFix.Notes.Add(note);
            AutoFix.Announcement = note;
        }
        for (var index = 0; index < generationWindows.Count; index++)
        {
            // The user's own words and own takes are final: the resolver never rewrites them (design.md §6.3.8).
            if (Wording(index) != PhraseWording.Suggested || StuckReason(index) is not { } reason) { AutoFix.Lines.Remove(index); continue; }
            if (reason is StuckTakeReason.Provider) { AutoFix.Lines.Remove(index); AutoFix.ShowChoices = true; continue; }
            // A phrase the guard settled is never retried or reworded: its card offers Keep as recorded and Say it myself.
            if (reason is StuckTakeReason.Blocked) { AutoFix.Lines.Remove(index); continue; }
            var used = AutoFix.Rounds.GetValueOrDefault(index);
            if (used >= RewriteAutoFixState.MaximumRounds) { GiveUp(index); continue; }
            if (reason is StuckTakeReason.Timing && AutoFix.TriedAnother.Contains(index)) { GiveUp(index); continue; }
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
        await (MeasuredWork = RewordMeasuredTakeAsync(true, automatic: !manualStep));
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
        // The loop's memory (voice-lab.md §8.2.2): the wordings this phrase already had, with their results.
        var tried = TriedWordings(index);
        var history = fitService.TriedBlock(tried)?.Text;
        var reply = await SendReaskAsync(new("Easier words", ClearerInstruction + (history is null ? "" : "\n" + history), [ordinal], RewriteBlockedReason.Take), lifetime.Token);
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
                // A wording already tried is never voiced again: the next round hears that it repeated.
                if (tried.Any(row => VoiceLabFitTried.Key(row.Text) == VoiceLabFitTried.Key(text)))
                {
                    Refuse(index, new(text, "repeat"));
                    return;
                }
                if (BridgeFor(index) is { } bridge && !bridge.Keeps(text))
                {
                    Refuse(index, new(text, "missingBridge"));
                    return;
                }
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
    private void Refuse(int index, VoiceLabFitTried row)
    {
        if (!AutoFix.Refused.TryGetValue(index, out var list)) AutoFix.Refused[index] = list = [];
        list.Add(row);
    }

    /// <summary>The bridge words phrase <paramref name="index"/>'s wording must keep (Mac <c>ClipTakePlan.bridge</c>); null when its
    /// window has none.</summary>
    internal VoiceLabFitBridge? BridgeFor(int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window) return null;
        var input = window.ReviewedInput ?? window.PreparedWindow?.Input ?? window.Rows.Select(row => window.InputFor(row.Id)).LastOrDefault(input => input is not null);
        if (input is null) return null;
        try { return VoiceLabFitBridge.From(input); }
        catch (VoiceLabException) { return null; }
    }

    /// <summary>The wordings phrase <paramref name="index"/> already had, oldest first, each with its latest measured result, then the
    /// AI's wordings that were not used (Mac <c>triedWordings</c>). One entry per variant (<see cref="VoiceLabFitTried.Key"/>).</summary>
    internal IReadOnlyList<VoiceLabFitTried> TriedWordings(int index)
    {
        List<VoiceLabFitTried> result = [];
        void Add(VoiceLabFitTried row)
        {
            var key = VoiceLabFitTried.Key(row.Text);
            if (key.Length == 0) return;
            var found = result.FindIndex(item => VoiceLabFitTried.Key(item.Text) == key);
            if (found >= 0) result[found] = row; else result.Add(row);
        }
        if (generationWindows.ElementAtOrDefault(index) is not { } window) return result;
        foreach (var row in window.Rows)
        {
            if (window.InputFor(row.Id)?.Text is not { } text) continue;
            if (row.Qa?.Failures.Contains(VoiceLabTakeQaFailure.Transcript) == true) { Add(new(text, "words")); continue; }
            if (RewriteGeneration.Length(row) is not { } length || window.Slot(row) is not { } slot) { Add(new(text, "unchecked")); continue; }
            var difference = length - slot;
            Add(window.LengthFits(row) ? new(text, "fit") : new(text, difference > 0 ? "tooLong" : "tooShort", Math.Abs(difference)));
        }
        foreach (var row in AutoFix.Refused.GetValueOrDefault(index) ?? []) Add(row);
        return result;
    }

    /// <summary>"Round k of 3 · tried: …" under a phrase the loop rewords (voice-lab.md §8.2.2), so its learning is visible.</summary>
    internal string? AutoFixHistoryLine(int index)
    {
        if (!AutoFix.Armed || AutoFix.Rounds.GetValueOrDefault(index) is not (> 0 and var round)) return null;
        var tried = TriedWordings(index);
        if (tried.Count == 0) return null;
        static string Seconds(double? value) => (value ?? 0).ToString("F1", CultureInfo.InvariantCulture) + " s";
        var bridge = BridgeFor(index)?.Display;
        var items = tried.TakeLast(4).Select(row => $"“{row.Text}” ({row.Result switch
        {
            "tooLong" => Seconds(row.Seconds) + " long",
            "tooShort" => Seconds(row.Seconds) + " short",
            "words" => "words misheard",
            "fit" => "fits",
            "repeat" => "repeat, not used",
            "notShorter" => "not shorter, not used",
            "notLonger" => "not longer, not used",
            "missingBridge" => bridge is null ? "dropped the joining words, not used" : $"dropped “{bridge}”, not used",
            _ => "not checked"
        }})");
        return $"Round {Math.Min(round, RewriteAutoFixState.MaximumRounds)} of {RewriteAutoFixState.MaximumRounds} · tried: " + string.Join(", ", items);
    }

    /// <summary>Phrases kept as recorded, by phrase index.</summary>
    internal IReadOnlyList<int> LeftOutPhrases => generationWindows.Select((window, index) => (window, index)).Where(item => item.window.LeftOut)
        .Select(item => item.index).ToArray();
}

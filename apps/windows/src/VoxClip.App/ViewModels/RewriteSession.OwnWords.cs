using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>A phrase card's three ways to its words (design.md §6.3.8 "Your own words", voice-lab.md §8.13; Mac
/// <c>PhraseWording</c>): the AI's suggestion, the user's own typed words read by their cloned voice, or the user saying the phrase
/// into the microphone. Suggested is the default; switching keeps every take, and all of them stay in the phrase's one take list.</summary>
internal enum PhraseWording { Suggested, OwnWords, Microphone }

internal static class PhraseWordingCopy
{
    internal static string Title(PhraseWording wording) => wording switch
    {
        PhraseWording.OwnWords => "My words",
        PhraseWording.Microphone => "● Say it myself",
        _ => "✦ Suggested"
    };
    internal static string ShortTitle(PhraseWording wording) => wording switch
    {
        PhraseWording.OwnWords => "Mine",
        PhraseWording.Microphone => "● Say",
        _ => "✦ AI"
    };
    internal const string OwnWordsFooter = "Next: listen, then Use. Lip sync follows if it's on.";
    internal const string MicrophoneFooter = "Next: Use, then Export. No ElevenLabs cost for your own take.";
}

/// <summary>My words' live length line (Mac <c>OwnWordsFit</c>): the plan's own estimate of how long the cloned voice takes to read
/// the words, and its verdict for this gap.</summary>
internal sealed record RewriteOwnWordsFit(int Words, double Seconds, double Gap, double Lower, double Upper, bool Fits, bool TooLong)
{
    internal string Line
    {
        get
        {
            var about = Seconds.ToString("F1", CultureInfo.InvariantCulture);
            var gap = Gap.ToString("F1", CultureInfo.InvariantCulture);
            var verdict = Fits ? "✓" : TooLong ? "· likely too long" : "· likely too short";
            return $"Your voice reads this. {Words} {(Words == 1 ? "word" : "words")} · about {about} s, the gap is {gap} s {verdict}";
        }
    }
}

/// <summary>The AI's shorter or longer version of the user's words (Mac <c>OwnWordsAdvice</c>): it fills the field and sends nothing
/// for takes. A send billed to the user's key waits for its inline [Send].</summary>
internal sealed class RewriteOwnWordsAdvice
{
    internal int? Phrase { get; set; }
    internal bool Running { get; set; }
    internal bool Awaiting { get; set; }
    internal string Problem { get; set; } = "";
}

internal sealed partial class RewriteSession
{
    private readonly Dictionary<int, PhraseWording> wordings = [];
    private readonly Dictionary<int, string> ownWords = [];
    /// <summary>The one phrase whose own-words field shows (house rule: one free-text field); another phrase's words read as a line.</summary>
    internal int? OwnWordsEditing { get; set; }
    internal RewriteOwnWordsAdvice OwnWordsAdvice { get; } = new();

    internal PhraseWording Wording(int index) => wordings.GetValueOrDefault(index);
    internal string? OwnWords(int index) => ownWords.GetValueOrDefault(index);

    /// <summary>The bridge words phrase <paramref name="index"/> keeps from the recording on each side of its change.</summary>
    internal (IReadOnlyList<string> Left, IReadOnlyList<string> Right) BridgeWords(int index)
    {
        if (PricedVoiceHunks.ElementAtOrDefault(index)?.Window is not { } window) return ([], []);
        IReadOnlyList<string> Words(IReadOnlyList<string> ids) => ids.Select(id => Transcript.FirstOrDefault(word => word.Id == id)?.Text)
            .Where(text => text is not null).SelectMany(text => EditingAlgorithms.SplitWords(text!)).ToArray();
        return (Words(window.LeftBridgeWordIds), Words(window.RightBridgeWordIds));
    }

    /// <summary>The words My words starts from: the phrase's change, without the bridge words it keeps from the recording.</summary>
    internal string ChangeWords(int index)
    {
        var words = EditingAlgorithms.SplitWords(CurrentSuggestion(index) ?? "");
        var (left, right) = BridgeWords(index);
        var start = Math.Min(words.Count, left.Count);
        var end = Math.Min(words.Count - start, right.Count);
        return string.Join(" ", words.Skip(start).Take(words.Count - start - end));
    }

    /// <summary>The whole phrase as the cloned voice reads it: the bridge words around the user's own words; null before any words.</summary>
    internal string? OwnWordsText(int index)
    {
        var typed = EditingAlgorithms.SplitWords(OwnWords(index) ?? "");
        if (typed.Count == 0) return null;
        var (left, right) = BridgeWords(index);
        return string.Join(" ", left.Concat(typed).Concat(right));
    }

    /// <summary>The AI's wording for phrase <paramref name="index"/>: a measured rewording, else the reply's phrase.</summary>
    private string? CurrentSuggestion(int index) => measuredWording.GetValueOrDefault(index) ?? PricedVoiceHunks.ElementAtOrDefault(index)?.PatchText;

    /// <summary>The text phrase <paramref name="index"/>'s next take voices: the user's own words in My words, else the suggestion.</summary>
    internal string? CurrentWording(int index) =>
        Wording(index) == PhraseWording.OwnWords && OwnWordsText(index) is { } own ? own : CurrentSuggestion(index);

    /// <summary>The segmented control: switching keeps every take; the next take follows the chosen wording.</summary>
    internal async Task ChooseWordingAsync(PhraseWording wording, int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window || Wording(index) == wording) return;
        var before = CurrentWording(index);
        if (wording == PhraseWording.Suggested) wordings.Remove(index); else wordings[index] = wording;
        if (wording == PhraseWording.OwnWords)
        {
            OwnWordsEditing = index;
            if (!ownWords.ContainsKey(index)) ownWords[index] = ChangeWords(index);
        }
        if (OwnWordsAdvice.Phrase == index) { OwnWordsAdvice.Phrase = null; OwnWordsAdvice.Awaiting = false; }
        Changed?.Invoke(this, EventArgs.Empty);
        // The quote follows the words a take would voice; every earlier take stays listed.
        if (CurrentWording(index) != before && !window.IsRunning)
        {
            window.KeepEveryTake();
            await window.InputsChangedAsync(preserveReview: true);
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Typing in My words: the text is kept; a quote for other words no longer approves a take (it waits for the price of
    /// these words, <see cref="PriceOwnWordsAsync"/>).</summary>
    internal void EditOwnWords(string text, int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is null) return;
        ownWords[index] = text;
        if (OwnWordsAdvice.Phrase == index && !OwnWordsAdvice.Running) { OwnWordsAdvice.Phrase = null; OwnWordsAdvice.Awaiting = false; }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The quote [Make take · ≈ $x] approves: the user's words, priced for this phrase alone. Nothing is sent.</summary>
    internal async Task PriceOwnWordsAsync(int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window || !GenerationIsCurrent || window.IsRunning ||
            Wording(index) != PhraseWording.OwnWords || OwnWordsText(index) is not { } text || OwnWordsQuoted(index, text)) return;
        window.KeepEveryTake();
        await window.InputsChangedAsync(preserveReview: true);
        if (window.Quote is { } quote && OwnWordsQuoted(index, text)) window.MarkEstimateShown(quote);
        Changed?.Invoke(this, EventArgs.Empty);
    }
    private bool OwnWordsQuoted(int index, string text) => generationWindows.ElementAtOrDefault(index) is { IsPreparing: false } window &&
        window.PreparedWindow?.Input.Text == text;

    /// <summary>The title of [Make take · ≈ $x] for the user's words, once its quote is for these exact words; null otherwise.</summary>
    internal string? OwnWordsTakeTitle(int index) =>
        Wording(index) == PhraseWording.OwnWords && OwnWordsText(index) is { } text && OwnWordsQuoted(index, text) &&
        generationWindows[index] is { CanExecute: true } window ? window.GenerationButtonTitle("Make take") : null;

    /// <summary>[Make take · ≈ $x] for the user's words: the existing priced path; the click is the approval.</summary>
    internal async Task MakeOwnWordsTakeAsync(int index, Func<string, CancellationToken, Task<bool>> confirm)
    {
        if (OwnWordsTakeTitle(index) is null || generationWindows[index] is not { Quote: { } quote } window) return;
        window.KeepEveryTake();
        await window.GenerateAsync(confirm, quote, autoplay: false);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>My words' live line (Mac <c>ownWordsFit</c>); null before any words or without timed speech.</summary>
    internal RewriteOwnWordsFit? OwnWordsFit(int index)
    {
        if (OwnWordsText(index) is not { } text || PricedVoiceHunks.ElementAtOrDefault(index) is not { Window: { } placed } hunk) return null;
        try
        {
            var (rate, _, spoken) = SpeakingRate();
            var calibrated = VoiceLabWordingFit.Multiplier(RateSamples(synthesisModel));
            var silence = VoiceLabWindowPlanner.LendableSilence(Project, Scope, placed);
            var tags = VoiceLabAudioTags.Reanchored(hunk.RequestAudioTags, hunk.PatchText ?? text, text);
            var timing = VoiceLabPaceMatching.Measure(text, rate, placed, silence.Incoming, silence.Outgoing, Project.Media.Source.Audio?.SampleRate ?? 48_000,
                hardJoinSmoothing: true, supportsPace: false, sourceItems: spoken, sourceEnvelope: Envelope, audioTags: tags, modelId: synthesisModel, rateMultiplier: calibrated);
            var lower = timing.MinimumSeconds ?? timing.SlotSeconds;
            return new(EditingAlgorithms.SplitWords(text).Count, timing.EstimateSeconds, placed.End - placed.Start, lower,
                Math.Max(lower, timing.MaximumSeconds ?? timing.SlotSeconds), timing.Fits, timing.TooLong);
        }
        catch (Exception error) when (error is VoiceLabGeometryException or VoiceLabLengthBudgetException or VoiceLabException) { return null; }
    }

    /// <summary>[✦ Shorten my words] or [✦ Lengthen my words]: the AI fits the user's words to the gap and its reply fills the field.
    /// Nothing is sent for takes. A send billed to a key waits for the inline [Send] (<paramref name="approved"/>).</summary>
    internal async Task AdviseOwnWordsAsync(int index, bool approved = false)
    {
        if (!IsOpen || Connector is not { } connector || OwnWordsAdvice.Running || OwnWordsText(index) is not { } text ||
            OwnWordsFit(index) is not { } fit || PricedVoiceHunks.ElementAtOrDefault(index) is not { } hunk) return;
        OwnWordsAdvice.Phrase = index; OwnWordsAdvice.Problem = "";
        if (FitAsksFirst && !approved)
        {
            OwnWordsAdvice.Awaiting = true;
            Changed?.Invoke(this, EventArgs.Empty);
            return;
        }
        OwnWordsAdvice.Awaiting = false; OwnWordsAdvice.Running = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var (_, wordsPerSecond, _) = SpeakingRate();
            var calibrated = VoiceLabWordingFit.Multiplier(RateSamples(synthesisModel));
            var target = VoiceLabWordingFit.WordTarget(wordsPerSecond, calibrated, fit.Lower, fit.Upper, 0);
            var original = string.Join(" ", hunk.Hunk.SourceWordIds.Select(id => Transcript.First(word => word.Id == id).Text));
            var request = new VoiceLabFitPhrase(hunk.Ordinals[0], original, text, fit.Seconds, fit.Gap, fit.TooLong ? "shorter" : "longer", target, Calibrated: true);
            using var lease = Editor.LlmRuns.TryAcquire() ?? throw new RewriteGenerationException(FitBusy);
            var action = fitService.Prepare([request], connector.Connector.Id, connector.Model, Language);
            var updates = await fitService.ProposeAsync([request], connector.Connector, connector.Model, Language, fitService.Approve(action, true), lifetime.Token);
            if (!IsOpen || updates.FirstOrDefault() is not { KeepOriginal: false } update) return;
            var (left, right) = BridgeWords(index);
            var words = EditingAlgorithms.SplitWords(update.Text).ToList();
            if (words.Take(left.Count).SequenceEqual(left, StringComparer.Ordinal)) words.RemoveRange(0, left.Count);
            if (words.Count >= right.Count && words.TakeLast(right.Count).SequenceEqual(right, StringComparer.Ordinal)) words.RemoveRange(words.Count - right.Count, right.Count);
            OwnWordsAdvice.Running = false;
            EditOwnWords(string.Join(" ", words), index);
            OwnWordsEditing = index;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (IsOpen) OwnWordsAdvice.Problem = Refusal(error); }
        finally
        {
            OwnWordsAdvice.Running = false;
            if (IsOpen) Changed?.Invoke(this, EventArgs.Empty);
        }
    }
    internal void CancelOwnWordsAdvice()
    {
        OwnWordsAdvice.Awaiting = false; OwnWordsAdvice.Phrase = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void ResetWordings()
    {
        wordings.Clear(); ownWords.Clear(); OwnWordsEditing = null;
        OwnWordsAdvice.Phrase = null; OwnWordsAdvice.Awaiting = false; OwnWordsAdvice.Problem = "";
    }
}

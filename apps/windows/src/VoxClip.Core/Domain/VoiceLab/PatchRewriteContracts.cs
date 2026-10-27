using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The character range for one transcript line's new text (voice-lab §8.1), computed by the caller from the length budget.
/// <c>Line</c> is the <c>[a-b]</c> label <c>formatTranscript</c> emits (ai.md §11.3); 1 ≤ MinChars ≤ MaxChars ≤ 5,000, in
/// <see cref="VoiceLabTextLength"/> units.</summary>
public sealed record PatchRewriteLineRange(string Line, int MinChars, int MaxChars);

/// <summary>One Fix with AI request (voice-lab §8.1, path 3). <c>Entries</c> are the in-scope transcript items with their absolute
/// indices and display text (ai.md §11.2), and <c>Ranges</c> holds one range per formatted line, in line order. <c>Instruction</c> says
/// what to fix, for example "I said 2024; it's 2025", and must not be empty after <c>jsTrim</c>.</summary>
public sealed record PatchRewriteRequest(Guid RequestId, IReadOnlyList<ClipWord> Entries, IReadOnlyList<PatchRewriteLineRange> Ranges,
    string Instruction, string Language);

/// <summary>One validated line edit; review data is inert. <c>Text</c> is the new text of the whole line exactly as the model returned it,
/// <c>Length</c> is Core's own <see cref="VoiceLabTextLength"/> of it, and <c>InRange</c> says whether that lies in the line's range; an
/// edit outside it is kept and shown with the fit meter (§8.9.1). <c>IsDeletion</c> means the text is empty after <c>jsTrim</c>: the
/// edit deletes the whole line, and is in range with length 0. <c>CheckThis</c> means the edit adds a digit run, a URL or a
/// capitalised token found nowhere in the transcript or the instruction (§8.1).</summary>
public sealed record PatchRewriteEdit(string Line, string Text, string Reason, int Length, bool InRange, bool CheckThis, bool IsDeletion);

/// <summary>Validated Fix with AI edits in arrival order. <c>UnknownLines</c> counts edits for no emitted line, <c>DuplicateLines</c> later
/// edits for a line that already had one (the first is kept), and <c>MalformedItems</c> items dropped as malformed: those structural
/// validation drops (ai.md §2.3), and those whose text or reason holds a control character other than tab or whose text is over
/// 2,000 UTF-8 bytes (§8.1).
/// <c>CheckThisMessage</c> is the badge copy from <c>shared/prompts/patch-rewrite.json</c>. Review data cannot synthesize audio or
/// change the original timed words.</summary>
public sealed record PatchRewriteProposal(Guid Id, IReadOnlyList<PatchRewriteEdit> Edits, int UnknownLines, int DuplicateLines,
    int MalformedItems, string CheckThisMessage, ConnectorId Connector, string Model, string? ProviderRequestId);

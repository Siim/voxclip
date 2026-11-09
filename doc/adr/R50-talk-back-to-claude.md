# ADR-R50: Talk back to Claude about a change, in a thread under its words

Date: 2026-11-09. Status: accepted (package v2-rewrite-thread, Mac). The Windows twin is owed (apps/windows/CONTRACTS.md).

## Context

After a Rewrite, the user could keep a change, undo it, or retype its words in an edit popover. They could not tell
Claude what was wrong with it. The user asked for "the bubbles that help me to pick, if this text satisfies me, or the
versions how I want to bend it", in the transcript.

Their case was Clip 1. Claude's rewrite read "…got its first buyer. A scammer. I was so happy. At first. What happened
next?…", which says they were happy about the scammer. They wanted to reply "It reads like I was happy about the scammer.
I was happy about the sale." and get a fixed version in place.

The lead's mockup (`ux/rewrite-chat/mockup.html`) showed five layouts:
- A, a thread under the passage;
- B, pick one of three versions;
- C, a chat in the right panel;
- D, a bend bar on the change;
- E, a margin comment.

The user picked **A, with D's version arrows** ("‹ 2 of 2 ›" instead of A's version pills), plus **B's "3 more versions"**
as a bubble.

## Decision

1. **Where.** The thread sits under the paragraph of the focused pending change, in the transcript's scroll flow,
   indented to the text column.
   - It has a 2 pt `change.add` rule at 45 % and no box (§6.3: no outlines in the transcript).
   - Only the focused change shows its thread, and it follows the focus.
   - It shows when a Rewrite result arrives, under the first focused change, with just the bubbles and the input.
   - The transcript keeps the thread's height free under the paragraph: its paragraph spacing grows by that height. A
     thread under the take's last paragraph ends that paragraph with a line break, because TextKit 2 adds no spacing after
     a document's last paragraph.
2. **What it holds.**
   - The last two turns, "You" and "✦ Claude"; older ones fold into the versions. Claude's line is its one-sentence note.
   - "‹ n of m ›", then "· N phrases to voice at Keep" or "· text only, free".
   - The bubbles: "✓ That's it, keep it"; up to two ✦ next steps from Claude's last reply; Shorter, Closer to my words and
     3 more versions.
   - The input, "Tell Claude what to change…", 1 to 4 lines, with the cost line beside it ("Free on your Claude plan",
     "Billed to your {provider} key"), as Ask Claude's.
3. **Versions are local.** A reply's words become version n+1 and go into the change's place through `editChange`, so the
   diff, the kinds, the fit and the cost are worked out again here. The arrows and ⌥←/⌥→ switch versions the same way and
   send nothing.
   - A version from Claude is the reply's own words for that change, not a hand edit. The session takes it as the change's
     reply (`acceptThreadWords`), so Keep prices and voices it as it does any Rewrite change.
   - Switching versions is not an undo step. Keep is one, as before.
   - A reply with the same words adds no version, and Claude's line starts "Kept the words as they are."
4. **The request carries the whole thread.** It sends:
   - the scope's words, as the passage request sends them;
   - the change's recorded words;
   - every version so far, oldest first;
   - every message, oldest first, the newest being the instruction.

   Rewrite's data-not-commands sentence and its "Why the length is fixed" paragraph are reused word for word
   (`shared/prompts/rewrite-followup.json`, ai.md §12.10).
5. **"3 more versions" is one request.** The `rewrite_followup_versions` schema returns `alternatives` (three texts), a
   note and next steps. One request costs one send on a key and one use of the plan. The texts are one change's words, a
   few hundred tokens together, well inside `maxOutputTokens` 4000. Alternatives that repeat a version or each other are
   dropped. The new versions are n+1 to n+3, and the first one shows.
6. **Nothing is voiced or paid in the thread.**
   - The send asks through the Rewrite consent (action `rewrite`), in the thread's own inline confirmation row, once per AI.
   - Readiness errors show in place with Rewrite's copy (`PanelError.line`) and Try Again, and the input keeps its text.
     Stop cancels the request with nothing changed.
   - Only the kept version goes on to the existing voice and price steps.
7. **Keys.**
   - ↵ sends and ⇧↵ adds a line.
   - Esc folds the thread. The version stays in the text, and focusing the change again opens the thread.
   - ⌘↩ and ⌘⌫ keep or undo the change, also with the input focused.
   - ⌥←/⌥→ switch versions while the input is empty. In the transcript they switch versions once the thread has two or
     more; otherwise they still move by sentence.
8. **The edit popover is gone** (`ChangeEditPopover`). Return, F2, a click on a change's new words and VoiceOver's action
   ("Talk to Claude about change N") open the thread and put the keys in its input. Retyping a change's words by hand is
   no longer offered on the Mac; telling Claude replaces it.

## Consequences

- One change at a time talks to Claude. Another change's thread keeps its versions and turns on the proposal until that
  change is kept or undone, or the proposal closes.
- A long thread pushes the transcript down. Only two turns show.
- While the wording fit runs, the thread steps aside, because the fit owns the change's words then.
- Windows still has its inline correction row. The thread, the prompt and the vector replay are its twin's work.

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
   no longer offered on the Mac; telling Claude replaces it. (Superseded the same day: see "Update: your own words".)

## Consequences

- One change at a time talks to Claude. Another change's thread keeps its versions and turns on the proposal until that
  change is kept or undone, or the proposal closes.
- A long thread pushes the transcript down. Only two turns show.
- While the wording fit runs, the thread steps aside, because the fit owns the change's words then.
- Windows still has its inline correction row. The thread, the prompt and the vector replay are its twin's work.

## Update 2026-11-09: your own words (package v2-thread-own-words)

**Context.** Item 8 left no way to type a change's words by hand: only Claude could change them. design.md §6.3 still promised "Each change can be edited before anything is paid for". The user approved restoring hand edits inside the thread.

**Decision.**

1. **A bubble, "✎ My own words"**, last after the steady bubbles, always there while the thread shows. A click, or ⌥E on the focused change in the transcript, switches the input to your own words:
   - it fills with the shown version's words, the cursor at the end;
   - the placeholder reads "Your exact words · ↵ applies · Esc cancels";
   - the cost line reads "Free · nothing is sent";
   - the bubble shows as selected.

   Return and F2 still open the thread for Claude.
2. **↵ applies the text locally** as a new version, through `editChange` as a Claude version goes, with no request. The version row reads "‹ n of n › · your words", and the turn reads "You · your own words: “…”". As the popover did, an empty text makes the change a cut, and the recorded words leave nothing to change, so the change is left out. Esc or the bubble again goes back to Claude with nothing changed.
3. **Your words are takes-eligible.** They go through `acceptThreadWords` like Claude's versions, so Keep reviews, prices and voices them, and the voice is made from your text.
   - The popover's hand edits were not takes-eligible: the footer said "Takes are made from the AI's words. Rewrite again to make takes of an edited change."
   - That rule had no product reason in the plan, the ADRs or the contracts. It was a limit of the code: the session's review, guard input and take plan were built from the reply's hunks, and a hand edit changed only the proposal's parts, so the take would not have matched the text. `acceptThreadWords` (Decision 3) now rebuilds the hunk, `replyParts` and the review from the edited change, which removes the limit for any words.
   - Matching the old rule would also strand the user. Keep, then nothing to press but Rewrite again, is the dead end the Rewrite smoke's I10 invariant fails on, and the smoke shows exactly that when `acceptThreadWords` is left out.
   - Nothing about consent changes. The voice guard (ADR-R40) still judges the patch speech per phrase, the export still says AI MODIFIED for a cloned voice, and the takes are still priced and approved inline.
4. **Your words are a version, never a message.** A later request carries them in the versions. Claude's ✦ next steps are cleared, because they were for its own words.

**Consequences.**
- The Mac again lets a change be edited by hand before anything is paid for, inline, with no pop-up.
- The Windows twin owes the bubble with the thread (apps/windows/CONTRACTS.md).


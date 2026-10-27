# Editing engine

Status: normative for VoxClip 0.1.0 (milestone M1). It applies to `VoxClipCore` (Swift) and `VoxClip.Core` (C#).

Golden fixtures: `shared/fixtures/editing/` (format and loading rules in its `README.md`). Generator: `tools/fixtures/editing/`. Schemas: `shared/schemas/project.schema.json` and `shared/schemas/timed-word.schema.json`.

Provenance: the engine is a port of VoxConvo's word editor as it sits in the VoxConvo working tree (`vox-web/src/utils/mediaTimeline.ts`, which is byte-identical to the `vox-api` copy, plus `wordBoundaries.ts`, `transcriptionTiming.ts`, `clips.ts`, `audioEditor.ts` and the session logic in `VoiceRecorder.tsx`). Those files are vendored unmodified in `tools/fixtures/editing/reference/`. Where this document and the VoxConvo code disagree, this document wins, and section 8 lists every deliberate difference. The VoxConvo docs (`doc/web/creator-editor.md`) and the 2025 design notes describe superseded constants (a 1 s pause threshold, a 50 ms breath and no word reach). Do not use them.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Contents

1. Overview
2. Data model
3. Constants
4. Numeric and text primitives
5. Import post-processing
6. Edit operations
7. Planning, time mapping and rendering rules
8. Deliberate divergences from VoxConvo
9. Cross-language traps
10. Project file semantics
11. Conformance
12. Deferred and out of scope

---

## 1. Overview

The source media is never edited. Word timings are fixed once at import and never change after that. An edit is a set of cut item ids, a set of cut pause ids, a map of text corrections, and an optional active clip that acts as a range layer. Every preview, export, caption pass and scrubber reading derives from one `EditPlan`, which is rebuilt from that state:

```text
engine words ─► cleanWords ─► [tightenIntoSound] ─► [refineWordBoundaries] ─► [findUnlabeledSpeech] ─► ids ─► detectPauses
                                   (only with decoded audio; tightening only for gapless engines; gap search only for non-verbatim engines)
                                                   │
                     Transcript (immutable items) + Pauses (derived)
                                                   │
user ops ─► EditState { cutWordIds, cutPauseIds, corrections, clips, activeClipId, pauseKeepSeconds, pauseThresholdSeconds }
                                                   │
                                 buildSegments(state) ─► buildEditPlan(segments, duration, sampleRate)
                                                   │
          ├─ preview: composition of plan.kept (one clock: edited time)
          ├─ export: the same plan.kept, 5 ms join fades, video frames pulled through sourceTime
          ├─ captions: captionCopy(segments, plan) on the edited timeline (styling: captions spec)
          └─ scrubber and transcript taps: mapTime / sourceTime
```

A cut is computed in seconds, rounded to whole audio samples, and merged. The kept intervals are the complement of the cuts. `mapTime` (source to edited) and `sourceTime` (edited to source) are exact inverses on the sample grid.

Voice Lab schemaVersion 2 and 3 use a separate ordered output-piece plan for generated audio (Voice Lab §10, ADR-R24/R26). Version 3 pairs that plan with selected candidate recipes and pure disclosure through `VoiceLabRenderContract.prepare`. The version-1 subtractive `EditPlan` and its wire format remain unchanged. An `EditPlan`-only consumer must check render capability before preview/export; its source `kept` ranges cannot represent enabled synthetic audio.

## 2. Data model

### 2.1 Time

- Times are seconds stored as IEEE-754 binary64 (`Double`, `double`) on the **source presentation timeline**: the container timeline after edit lists, with encoder priming removed and any start delay applied. Engines report times relative to the audio they were given, so adapters add the offset of the first audio sample and any VAD segment start before the words reach `cleanWords`.
- Sample indices are signed 64-bit integers (`Int64`, `long`).
- The plan sample rate is the native sample rate of the source audio track. A source without audio uses 48000. The plan duration is the audio track's presentation duration, or the video track's when there is no audio. Preview, export and captions MUST all use the same rate and duration. Both are stored in the project file (`media.source.audio.sampleRate`, `media.source.durationSeconds`).

### 2.2 TimedWord (transcript item)

Schema: `shared/schemas/timed-word.schema.json`. This is the same type as `TimedWord` in the transcription spec (section 3.1), which produces it. Every field is written, with `null` for absent optional values.

```text
TimedWord {
  id: String          // unique in the transcript, never reused; import assigns "w1", "w2", ... in final start order
  text: String        // NFC, JS-trimmed, non-empty; punctuation attached ("words,")
  kind: word | event | unlabeledSpeech
  start: Double       // refined source time, >= 0
  end: Double         // > start
  rawStart: Double?   // after cleanWords, before tightening and refinement; null for detected items
  rawEnd: Double?
  conf: Double?       // [0, 1]; null if the engine gives none
  speaker: String?    // diarization label
  timing: native | dtw | tokenGrouped | runGrouped | detected   // detected = found by 5.8
}
```

Kinds:

| kind | Meaning | Cuttable | Caption | Filler | Correctable |
|---|---|---|---|---|---|
| `word` | Transcribed speech, hesitations included | yes | yes | if its current text matches the filler rule (6.2) | yes |
| `event` | A non-speech sound labelled by the engine, for example Scribe `audio_event` "(laughs)" | yes | no | no | no |
| `unlabeledSpeech` | Audible speech in a gap that a non-verbatim engine did not transcribe (5.8). Text `…` (U+2026) | yes | no | always | no |

"Filler" is never a stored kind. It is derived from the current text so that a correction can create or remove a filler, which is the reference behaviour. Pauses are not items (2.4).

Transcript invariants: items are sorted by `start`, with ties kept in engine order; ids are unique; every item has `end > start` and `start >= 0`. A reader that finds a violation MUST reject the transcript as corrupt and MUST NOT repair it silently.

### 2.3 Transcript

The transcription spec (section 3.1) defines this type, and the project file stores it as is. The fields the editing engine reads:

```text
Transcript {
  schemaVersion: 1
  words: [TimedWord]
  language: String?            // hyphenated BCP 47: primary subtag for whispercpp and ElevenLabs ("et"), full tag for Apple ("en-GB")
  languageProbability: Double?
  durationSeconds: Double      // source audio duration on the presentation timeline
  engine: { id: "elevenlabs" | "whispercpp" | "apple-speech", modelId?, modelSha256?, engineVersion, locale? }
  verbatim: Bool               // keeps fillers as words; false runs the gap search (5.8)
  refined: Bool                // decoded audio was available, so 5.5 to 5.8 ran
  pipelineVersion: Int         // bumped when the transcription grouping or this import post-process changes output
  rawKey: String               // cache key of the raw engine result (transcription spec 14.2)
  createdAt: timestamp
}
```

The engine timing (`native`, `dtw`, `tokenGrouped`, `runGrouped`) comes from the transcription spec's `RawTranscript.timing` and is copied to every item.

### 2.4 Pause

Pauses are derived from the transcript and the pause threshold (5.10). They are not stored in the project file, but their ids are.

```text
Pause {
  id: "pause-after-" + items[i].id    // the item BEFORE the gap
  afterIndex: i                        // gap between items[i] and items[i+1]
  start: items[i].end
  end: items[i+1].start
  duration: end - start                // computed exactly as items[i+1].start - items[i].end
  label: "pause " + toFixed1(duration) + "s"
}
```

### 2.5 EditState

```text
EditState {
  transcript: Transcript               // immutable
  pauses: [Pause]                      // derived from transcript + pauseThresholdSeconds
  pauseThresholdSeconds: Double        // 0.8 when transcript.refined, else 1.0, set at import
  pauseKeepSeconds: Double             // breath next to each kept word in a cut pause; default 0.15
  cutWordIds: Set<String>              // any item kind
  cutPauseIds: Set<String>
  corrections: Map<wordId, String>     // only kind == word; value != the transcribed text
  clips: [ClipRange]                   // the clip range layer
  activeClipId: String?                // the selected clip, or null for the full take
}
ClipRange { id, startWordId, endWordId, title?, origin: manual | ai, aiResultId?, aiClipIndex?, selected: Bool }
```

`selected` is the checkbox in the Clips list. "Export N clips" exports the selected clips in list order. It never affects planning. New clips, manual and AI, start selected.

`textOf(item) = corrections[item.id] ?? item.text`.

The clip is a **range layer**. Selecting a clip never writes cut flags. Words outside the clip are excluded only when the plan is built (7.1), so cuts and corrections made while a clip is active stay in `cutWordIds` and `corrections` when the clip changes or is left.

Indices: a clip is resolved to item indices `[startIndex, endIndex]` with `0 <= startIndex <= endIndex < items.count`. Index-based APIs (session ops, `clipTimes`, the clip finder) use these indices. The project file stores ids.

### 2.6 EditSegment (planner input)

```text
EditSegment {
  id: String
  kind: word | pause | range           // explicit; implementations MUST NOT infer it from the id
  wordKind: word | event | unlabeledSpeech   // kind == word only; default word
  text: String                         // kind == word only
  start: Double
  end: Double
  cut: Bool                            // kind == range is always cut
}
```

`range` segments are clip heads and tails, plus any other exact cut range a future feature needs. They are always cut, and a range with `cut == false` is invalid input that MUST be rejected.

### 2.7 EditPlan

```text
MediaInterval { startSample: Int64, endSample: Int64 }   // half-open [startSample, endSample); start = startSample / rate
EditPlan {
  sampleRate: Double
  totalSamples: Int64        // max(0, jsRound(duration * rate))
  cuts: [MediaInterval]      // sorted, disjoint, merged; consecutive cuts are separated by at least one kept sample
  kept: [MediaInterval]      // complement of cuts in [0, totalSamples)
  outputSamples: Int64       // sum of kept lengths
  duration: Double           // outputSamples / rate
  mapTime(source) -> edited
  sourceTime(edited) -> source
}
```

The macOS canonical initializer takes `sampleRate`, `totalSamples`, `cuts` and `kept`; output samples and joins are derived from the kept intervals. The legacy initializer with explicit derived values is deprecated and asserts their agreement in DEBUG builds. Decoding still normalizes stale derived fields from kept intervals without changing the wire format.

On Windows, construction, record copies and decoding silently normalize supplied output samples and joins from the kept intervals, sample rate and source bounds in both Debug and Release. Supplied derived fields never override those values, regardless of initializer order.

### 2.8 CaptionWord

```text
CaptionWord { id, text, start, end }    // EDITED timeline, derived, never stored
```

## 3. Constants

All values are exact decimal literals parsed to binary64.

| Name | Value | Use | Reference |
|---|---|---|---|
| `WORD_REACH` | 0.1 s | Silence a cut word takes on each side, at most half the gap | mediaTimeline.ts:20 |
| `pauseKeepSeconds` default | 0.15 s | Breath kept next to each kept word in a cut pause (both sides) | mediaTimeline.ts:21-22 |
| `NEIGHBOUR_EPSILON` | 1e-6 s | Pause neighbour search tolerance | mediaTimeline.ts:30-31 |
| `DEFAULT_SAMPLE_RATE` | 48000 | Sources without audio | mediaTimeline.ts:51 |
| `PAUSE_THRESHOLD_REFINED` | 0.8 s (inclusive) | Pause detection after refinement | VoiceRecorder.tsx:786 |
| `PAUSE_THRESHOLD_UNREFINED` | 1.0 s (inclusive) | Pause detection without decoded audio | VoiceRecorder.tsx:786 |
| `CLIP_LEAD` | 0.12 s | Padding before a clip's first word, at most half the gap | clips.ts:37 |
| `CLIP_TAIL` | 0.25 s | Padding after a clip's last word, at most half the gap | clips.ts:38 |
| `CLIP_TAIL_OVERSHOOT` | 3600 s | Clip tail range end beyond the last word (clamped by the planner) | VoiceRecorder.tsx:495 |
| `JOIN_FADE` | 0.005 s | Linear fade on each side of a join, at most half a part | audioEditor.ts:23 |
| `FRAME_SECONDS` | 0.01 s | Level frame length | wordBoundaries.ts:19 |
| `MAX_LEAD` / `MAX_TAIL` | 0.35 s / 0.3 s | Refinement widening limits | wordBoundaries.ts:20-21 |
| `BRIDGE_FRAMES` | 2 | Quiet frames a sound run may span | wordBoundaries.ts:22 |
| `TOUCHING` | 0.03 s | Words this close share an edge | wordBoundaries.ts:23 |
| `VALLEY_REACH` | 0.07 s | Shared edge search radius | wordBoundaries.ts:24 |
| `MIN_WORD` | 0.04 s | Minimum word length kept by refinement and tightening | wordBoundaries.ts:25 |
| Room percentile, room factor, speech factor, valley ratio | 10 %, ×2, ×0.08, 0.5 | Level threshold and valley test | wordBoundaries.ts:44-48, 88 |
| `TIGHTEN_MIN_SILENT_FRAMES` | 7 | Silent frames (more than 60 ms) needed at a gapless range edge before it is trimmed | VoxClip |
| `TIGHTEN_SPLIT_FRAMES` | 15 | A quiet stretch of at least this many frames inside a gapless range separates sound islands | VoxClip |
| `UNLABELED_MIN_GAP` | 0.25 s | Shortest gap searched for untranscribed speech | VoxClip (local-models research 7.4) |
| `UNLABELED_MIN_FRAMES` | 10 | Shortest reported run, bridged frames included | VoxClip |
| `UNLABELED_PEAK_FACTOR` | 0.25 | A run's loudest frame must reach this fraction of the median speech level | VoxClip |
| Filler rule | `^(um+\|uh+\|erm+\|hmm+)[,.!?]?$`, ASCII case-insensitive | Cut fillers | VoiceRecorder.tsx:1054 |

The VoxClip-only values (`TIGHTEN_*`, `UNLABELED_*`) were chosen on synthetic audio. Tune them on the bilingual test set before 0.1.0 ships. Any change goes through the generator and the fixture diff (11.3).

## 4. Numeric and text primitives

These primitives decide parity between Swift, C# and the reference. Each one has fixtures.

### 4.1 jsRound

JavaScript `Math.round`: round to nearest, with ties toward +∞.

```text
jsRound(x: Double) -> Double:   // x finite
  f = floor(x)
  return (x - f >= 0.5) ? f + 1 : f
```

- MUST NOT use `floor(x + 0.5)`. It rounds `0.49999999999999994` to 1 (fixture `plan/rounding-unit-rate`).
- C# `Math.Round(x)` is banker's rounding and fails `plan/rounding-half-up`. Use the function above.
- Every input reaching `jsRound` is finite, because of the guards in 7.4 and 7.5. Convert to `Int64` only after clamping.

`clampSample(t) = min(totalSamples, max(0, jsRound(t * rate)))`. Round first, then clamp, then convert to Int64.

### 4.2 Stable sort

Every "sort by start" in this document is stable: equal keys keep their input order. Implement it as a sort on `(key, originalIndex)`. C# `List<T>.Sort` and `Array.Sort` are unstable. Swift's `sort` is not documented as stable, so do not rely on it. Fixtures: `plan/stable-sort-tie-a` and `plan/stable-sort-tie-b` give different cuts for the same words in a different input order.

### 4.3 Expression order and floating-point mode

Evaluate every expression in the order written here, in binary64, with no fused multiply-add, no reassociation and no fast-math. For example, `pause.start + 0.15` with `start = 1.4` is `1.5499999999999998`, and fixtures assert pre-rounding values (`segmentCuts.rawStart/rawEnd`) exactly. Do not use `Decimal`/`decimal` or `Float` for times. There is no exception to the no-FMA rule: `toFixed1` (4.4) is integer-only, and it is the one Core function both this spec and the AI spec (ai.md 11.3) use.

### 4.4 toFixed1

Pause labels use JavaScript `Number.prototype.toFixed(1)`, which rounds the exact binary value of the double, with exact ties going up. Swift `String(format: "%.1f")` rounds exact ties to even (`1.25` gives `"1.2"`). Implement it exactly with integers:

```text
toFixed1(x: Double) -> String:      // x finite, x >= 0
  decompose x = m · 2^e exactly (m integer, 0 <= m < 2^53)
  if e >= 0:     n = m · 10 · 2^e                               // big integer (x >= 2^52 never occurs for durations)
  else if -e > 60: n = 0                                        // x < 2^-8, so 10x rounds to 0
  else:          k = -e; n = (10·m + 2^(k-1)) >> k               // fits in UInt64
  return decimalString(n / 10) + "." + decimalString(n mod 10)   // integer division
```

Examples: `1.25` → `"1.3"`, `2.25` → `"2.3"`, `0.85` (binary value just below) → `"0.8"`, `3.35 - 2.5` (= 0.8500000000000001) → `"0.9"`, `59.95` → `"60.0"`. Fixtures: `pauses/label-rounding` and `pauses/label-to-fixed` (80 durations). The generator self-checks this algorithm against `toFixed` on 200,000 values.

### 4.5 Whitespace, trim and split

`jsTrim` and `splitWords` use exactly JavaScript's whitespace set (`String.prototype.trim`, regex `\s`):

```text
JS_WHITESPACE = { U+0009, U+000A, U+000B, U+000C, U+000D, U+0020, U+00A0, U+1680, U+2000–U+200A,
                  U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF }
jsTrim(s)     = s without leading and trailing scalars in JS_WHITESPACE
splitWords(s) = jsTrim(s) split on maximal runs of JS_WHITESPACE, empty tokens removed
```

U+0085, U+180E and U+200B are **not** whitespace. U+FEFF is. Platform `Trim()` and `.whitespacesAndNewlines` differ from this set, so implement it explicitly. Fixture: `text/js-whitespace`.

### 4.6 String length

`estimateTranscriptWords` measures length in UTF-16 code units: Swift `s.utf16.count`, C# `s.Length`. Fixture `estimate/utf16-length` (an emoji counts 2).

### 4.7 normalizeForMatch

Used only by `alignTranscriptWords`.

```text
normalizeForMatch(s):
  out = ""
  for each Unicode scalar c of s:
    lower = (c == U+0130) ? "i" : unconditionalLowercase(c)   // Swift: c.properties.lowercaseMapping; C#: Rune.ToLowerInvariant(c)
    for each scalar d of lower: if generalCategory(d) is L* or N*: out += d
  return out
```

The reference uses the host locale's `toLocaleLowerCase()`. VoxClip uses an invariant mapping, so a Turkish, Azeri or Lithuanian system locale never changes the result. U+0130 is special-cased because .NET's invariant mapping leaves it unchanged. JS final-sigma context (`Σ` → `ς` at the end of a word) is not applied. That case only changes whether the final text's punctuation is used, and both outcomes keep timings correct. Combining marks (Mn) are not L/N, so they are removed. Because all text is NFC (5.2), NFD input cannot reach this function from the pipeline. Fixtures: `align/*`.

### 4.8 NFC

`cleanWords` converts every engine text to NFC (Swift `precomposedStringWithCanonicalMapping`, C# `Normalize(NormalizationForm.FormC)`). Corrections are stored NFC as well.

.NET normalisation needs ICU. With `InvariantGlobalization` on, `string.Normalize(FormC)` silently returns its input unchanged (measured on .NET 10.0.102), so it MUST stay off in every .NET project (architecture 2.3). `VoxClip.Core.Tests` asserts `"õ".Normalize(NormalizationForm.FormC) == "õ"` so that a later property change fails CI. Fixtures `ingest/clean-words`, `fillers/anchors-and-case` and `text/js-whitespace` contain non-NFC input.

### 4.9 Float32 levels

Refinement levels are stored as 32-bit floats (the reference uses a `Float32Array`). Sums of squares accumulate in binary64. The square root is taken in binary64 and then rounded to binary32 for storage. Every comparison and product involving a level (`level >= threshold`, `quietest * 2`, `speechLevel * 0.08`, `level * 0.5`) converts the level to binary64 first. Sorting levels sorts their binary32 values.

### 4.10 Non-finite numbers in JSON

Fixtures encode non-finite inputs as the strings `"NaN"`, `"Infinity"` and `"-Infinity"`. C#: `JsonNumberHandling.AllowNamedFloatingPointLiterals`. Swift: `nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")`. Project files never contain non-finite numbers.

### 4.11 Filler matching

```text
isFillerText(t) = t matches ^(um+|uh+|erm+|hmm+)[,.!?]?$ with ASCII-only case folding, anchored at the absolute start and end
```

Implement it by hand or with explicit classes such as `[Uu][Mm]+`, anchored with `\A…\z`. Do not use `$`. In .NET and ICU, `$` also matches before a final newline, so `"um\n"` would match there. Fixtures: `fillers/regex` and `fillers/anchors-and-case`.

## 5. Import post-processing

This runs once per transcription, before the first edit, and its results are written to the project file. Opening a project never reruns it. Stored times are therefore identical on both platforms even though their decoders differ, and an app update that changes the pipeline never moves the words of an existing project.

### 5.0 Pipeline

```text
importPipeline(rawWords, audio?, timing, verbatim):
  items = cleanWords(rawWords); for each item: rawStart = start; rawEnd = end; timing = RawTranscript.timing
  if audio decoded:
    if timing in {runGrouped, tokenGrouped, dtw}: items = tightenIntoSound(items, audio, timing)
    items = refineWordBoundaries(items, audio)
    if !verbatim:
      extra = findUnlabeledSpeech(items, audio) as { text "…", kind unlabeledSpeech, conf null, rawStart null, rawEnd null, timing detected }
      items = stableSortByStart(items ++ extra)
  assign ids: items[k].id = "w" + (k + 1)
  pauseThresholdSeconds = audio decoded ? 0.8 : 1.0
  pauses = detectPauses(items, pauseThresholdSeconds)
```

Fixtures: `pipeline/gapless-non-verbatim` (Apple-style: tighten, refine, find the dropped filler) and `pipeline/native-verbatim-no-audio` (Scribe-style without audio).

Engine adapters, defined in the transcription spec, end at `RawWord { text, start?, end?, conf?, speaker?, kind?: word | event }` in engine order and on the source timeline. Scribe `spacing` tokens are dropped by the adapter, and `audio_event` tokens become `kind: event`.

### 5.1 Audio analysis

The analysis input is the source audio track decoded to binary32 PCM at its **native** rate, with all channels and no resampling, after priming removal (AVAssetReader linear PCM Float32 on macOS; FFmpeg decode to `fltp` on Windows). Implementations compute `level[]` in one streaming pass. Nothing below needs the PCM itself.

```text
analyze(items, audio):                       // items: anything with start, end
  frameSize   = max(1, jsRound(rate * 0.01))           // integer samples per frame
  frameLength = frameSize / rate
  frames      = floor(audioLengthInSamples / frameSize)
  if items empty or frames < 10 or channels == 0: return none
  for f in 0..frames-1:
    sum = 0                                                  // binary64
    for c in 0..channels-1 (in order): for i in f·frameSize ..< (f+1)·frameSize (in order): sum += Double(x[c][i]) · Double(x[c][i])
    level[f] = Float32( sqrt(sum / (frameSize · channels)) )
  frameAt(t)  = min(frames - 1, max(0, floor(t / frameLength)))
  quietest    = sortAscending(level)[floor(frames · 0.1)]
  speech      = sortAscending(concatenation over items, in order, of level[frameAt(w.start) ... frameAt(w.end)] inclusive)
  speechLevel = speech.count > 0 ? speech[floor(speech.count / 2)] : 0
  threshold   = max(quietest · 2, speechLevel · 0.08)
  if !(threshold > 0): return none
  audible(f)  = level[f] >= threshold
  total       = audioLengthInSamples / rate
```

Each step calls `analyze` with its own input items, so `threshold` is recomputed per step while `level[]` stays the same. When `analyze` returns none, the step returns its input unchanged (`findUnlabeledSpeech` returns nothing).

Decoders differ slightly between AVFoundation and FFmpeg, so a fresh import of the same file can refine differently by one frame (10 ms) on the two platforms. Stored projects are unaffected.

### 5.2 cleanWords

```text
cleanWords(raw):
  out = []; prefix = ""
  for r in raw (engine order):
    kind = (r.kind == event) ? event : word
    text = jsTrim(NFC(r.text ?? ""))
    if text == "": continue
    if kind == word and isPunctuationOnly(text):
      if isOpeningOnly(text): prefix = prefix + text                 // joins the next word
      else if out nonEmpty and out.last.kind == word: out.last.text = out.last.text + text   // never extends its end
      continue                                                        // otherwise dropped; punctuation times are ignored
    if !(finite(r.start) and finite(r.end) and r.start >= 0 and r.end > r.start): continue   // prefix stays pending
    conf = (finite(r.conf) and 0 <= r.conf <= 1) ? r.conf : null
    out.append({ text: kind == word ? prefix + text : text, start: r.start, end: r.end, conf, kind, speaker: r.speaker ?? null })
    if kind == word: prefix = ""
  return stableSortByStart(out)                                       // a prefix still pending at the end is dropped

isPunctuationOnly(t) = every scalar of t has General_Category P* (Pc, Pd, Ps, Pe, Pi, Pf, Po)
isOpeningOnly(t)     = every scalar of t is Ps, Pi, U+00BF (¿) or U+00A1 (¡)
```

Fixture: `ingest/clean-words`.

### 5.3 alignTranscriptWords (reference `transcriptionTiming.ts:11-17`)

This is for adapters that get timed words without punctuation plus a separate final text. A timestamp is never moved onto a different word.

```text
alignTranscriptWords(words[{word, start, end}], finalText):
  tokens = splitWords(finalText)
  same   = tokens.count == words.count and for all i: normalizeForMatch(words[i].word) == normalizeForMatch(tokens[i])
  out    = words with word = same ? tokens[i] : words[i].word
  return out.filter(jsTrim(word) != "" and finite(start) and finite(end) and start >= 0 and end > start)
```

Fixtures: `align/*` (7).

### 5.4 estimateTranscriptWords (reference `transcriptionTiming.ts:20-30`)

This is the fallback for an engine segment without word times, ported for parity with the reference. No v1 engine needs it, and schemaVersion 1 has no `estimated` timing value. An adapter that starts using it must first add that value to the transcription spec's `TimingSource` and to `timed-word.schema.json`, and it must mark the words in the UI as approximately timed.

```text
estimateTranscriptWords(text, start, end):
  tokens = splitWords(text)
  if tokens empty or !finite(start) or !finite(end) or end <= start: return []
  L = Σ utf16Length(token); consumed = 0
  for token: s = start + consumed / L * (end - start); consumed += utf16Length(token); e = start + consumed / L * (end - start)
             emit { word: token, start: s, end: e, conf: 0 }
```

`consumed / L * (end - start)` means `(consumed / L) * (end - start)`. Fixtures: `estimate/*` (5).

### 5.5 tightenIntoSound (VoxClip)

Gapless engines stretch word ranges over silence. Apple run-grouped ranges absorb the silence **before** a word, and whisper ranges (end = next word's start) absorb the silence **after** it. Tightening shrinks each range to its sound, so refinement and the gap search can work. It never widens a range.

```text
tightenIntoSound(items, audio, timing):
  a = analyze(items, audio); if none: return items
  keepLast = (timing == runGrouped)
  for each item w:
    first = a.frameAt(w.start)
    last  = min(a.frames - 1, max(0, ceil(w.end / a.frameLength) - 1))
    if first > last: unchanged
    runs    = audibleRuns(a, first, last)
    islands = merge consecutive runs while (next.first - current.last - 1) < TIGHTEN_SPLIT_FRAMES
    if islands empty: unchanged
    (fa, fb) = keepLast ? islands.last : islands.first
    start = w.start; end = w.end
    if fa - first >= TIGHTEN_MIN_SILENT_FRAMES: start = max(w.start, fa · a.frameLength)
    if last - fb  >= TIGHTEN_MIN_SILENT_FRAMES: end   = min(w.end, (fb + 1) · a.frameLength)
    if end - start < MIN_WORD:
      start = max(w.start, end - MIN_WORD)
      end   = min(w.end, start + MIN_WORD)
    w.start = start; w.end = end

audibleRuns(a, from, to):              // a run spans at most BRIDGE_FRAMES consecutive quiet frames
  runs = []; f = from
  while f <= to:
    if !a.audible(f): f += 1; continue
    last = f; quiet = 0
    for g in f+1 ... to: if a.audible(g): last = g; quiet = 0 else: quiet += 1; if quiet > BRIDGE_FRAMES: break
    runs.append((f, last)); f = last + 1
  return runs
```

Fixtures: `tighten/*` (4).

### 5.6 refineWordBoundaries (reference `wordBoundaries.ts:27-94`, unchanged)

Each word moves outward to where its sound starts and stops, so cuts land in silence. Neighbour limits use the **input** (unrefined) times.

```text
refineWordBoundaries(words, audio):
  a = analyze(words, audio); if none: return words
  n = words.count
  refined[i] for each i:
    w = words[i]; prevEnd = i > 0 ? words[i-1].end : none; nextStart = i < n-1 ? words[i+1].start : none
    earliest = max(0, w.start - 0.35, prevEnd == none ? 0 : (prevEnd + w.start) / 2)
    latest   = min(a.total, w.end + 0.3, nextStart == none ? a.total : (w.end + nextStart) / 2)
    first = edge(a.frameAt(w.start), -1, f => f · a.frameLength >= earliest)
    last  = edge(a.frameAt(w.end),   +1, f => (f + 1) · a.frameLength <= latest)
    start = first < 0 ? w.start : min(w.start, first · a.frameLength)
    end   = last  < 0 ? w.end   : max(w.end, (last + 1) · a.frameLength)
  edge(from, step, inside):
    found = -1; quiet = 0; f = from
    while 0 <= f < a.frames and inside(f):
      if a.audible(f): found = f; quiet = 0
      else: quiet += 1; if quiet > BRIDGE_FRAMES: break
      f += step
    return found
  // valley pass: sequential, reads refined[i-1] as already updated
  for i in 1 ... n-1:
    prev = refined[i-1]; next = refined[i]
    if next.start - prev.end > TOUCHING: continue
    middle = (prev.end + next.start) / 2
    from = ceil(max(middle - 0.07, prev.start + 0.04) / a.frameLength)
    to   = floor(min(middle + 0.07, next.end - 0.04) / a.frameLength) - 1
    if from > to or to >= a.frames: continue
    valley = the first f in from...to with the smallest level[f]
    if level[valley] > level[a.frameAt(middle)] · 0.5: continue          // one continuous sound
    edgeT = (valley + 0.5) · a.frameLength
    refined[i-1].end = edgeT; refined[i].start = edgeT
  return refined
```

Fixtures: `boundaries/*` (8), using the synthetic audio of 11.4.

### 5.7 Pauses from refined items

```text
detectPauses(items, threshold):
  for i in 0 ... items.count-2 (transcript order, no re-sort):
    gap = items[i+1].start - items[i].end
    if gap >= threshold: emit Pause(id "pause-after-" + items[i].id, start items[i].end, end items[i+1].start, duration gap, label "pause " + toFixed1(gap) + "s")
```

Only gaps **between** consecutive items count. Silence before the first item or after the last never becomes a pause, and an `event` or `unlabeledSpeech` item splits a gap. Changing `pauseThresholdSeconds` later re-derives the list and removes ids from `cutPauseIds` that no longer exist. Fixtures: `pauses/*`.

### 5.8 findUnlabeledSpeech (VoxClip)

Non-verbatim engines (multilingual Whisper, Apple) drop "um" and "ee". This search finds voiced sound that no item covers, so "Cut fillers" can offer it. It runs only when `transcript.verbatim == false`, after refinement.

```text
findUnlabeledSpeech(items, audio):        // items sorted by start
  a = analyze(items, audio); if none: return []
  found = []; reached = 0
  for k in 0 ... items.count:             // k == count is the trailing gap
    gapStart = reached
    gapEnd   = k < items.count ? items[k].start : a.total
    if k < items.count: reached = max(reached, items[k].end)
    if !(gapEnd - gapStart >= UNLABELED_MIN_GAP): continue
    f0 = max(0, ceil(gapStart / a.frameLength))
    f1 = min(a.frames - 1, floor(gapEnd / a.frameLength) - 1)        // frames fully inside the gap
    for (first, last) in audibleRuns(a, f0, f1):
      peak = max level[first ... last]
      if last - first + 1 >= UNLABELED_MIN_FRAMES and peak >= a.speechLevel · UNLABELED_PEAK_FACTOR:
        found.append({ start: first · a.frameLength, end: (last + 1) · a.frameLength })
  return found
```

A breath is usually audible but well below speech, so it fails the peak test. Fixtures: `gaps/*` (2).

## 6. Edit operations

### 6.1 Scope

While a clip is active, every bulk operation and every count acts on the clip's **scope**:

```text
inScope(i)          = activeClip == none or (activeClip.startIndex <= i <= activeClip.endIndex)
pauseInScope(p)     = inScope(p.afterIndex) and inScope(p.afterIndex + 1)
```

With no active clip, the scope is the whole take. Edits themselves are global to the take: one cut set, one correction map.

### 6.2 Fillers

```text
isFiller(item) = item.kind == unlabeledSpeech or (item.kind == word and isFillerText(textOf(item)))
fillers        = items i where inScope(i) and item not cut and isFiller(item)
```

The default rule is the reference rule (4.11), which tests the **current** (corrected) text. Matches: `um`, `umm…`, `uh`, `erm`, `hmm`, `hmmm…` with one optional trailing `, . ! ?`. Non-matches: `hm`, `uhm`, `er`, `ah`, `mm`, `eh`, `um...`, `um;`, `"um"`, `Ümm`.

### 6.3 Operations

Each operation is a pure function `(EditState, Op) -> EditState`. The app makes each one a single undo step, and every operation pauses playback.

For AI-linked clip additions, the macOS history entry point is `EditHistory.apply(_:aiResults:)`, supplied with the project's current AI results. It performs the same reference and batch-size checks as `Project.applyEditing`; a rejected command changes neither the edit state nor the undo/redo stacks. The state-only overload remains available when AI context is unavailable.

| Op | Semantics |
|---|---|
| `toggle(id)` | If `id` is a pause id (by lookup in `pauses`, never by prefix), flip its membership in `cutPauseIds`. Otherwise, if it is an item id, flip its membership in `cutWordIds`. No scope check. |
| `cutSelection(ids)` | If every id in `ids` is already cut, uncut them all. Otherwise cut them all. Words and pauses may be mixed. This is ⌫ on a selection. |
| `restoreSelection(ids)` | Uncut every id in `ids`. |
| `cutFillers` | Add every id in `fillers` (6.2) to `cutWordIds`. Never uncuts anything. |
| `tightenPauses` | Add every pause with `pauseInScope` to `cutPauseIds`. |
| `restoreCuts` | Remove every in-scope item from `cutWordIds` and every in-scope pause from `cutPauseIds`. Corrections are kept. Out-of-scope cuts are kept. |
| `correct(id, text)` | `t = jsTrim(NFC(text))`. Ignored if `t == ""`, if the item is not `kind == word`, or if `t == textOf(item)`. If `t` equals the transcribed `item.text`, remove the correction. Otherwise set `corrections[id] = t`. Times never change. A multi-word value such as "going to" stays on that one item's time slot. |
| `setActiveClip(clipId?)` | Set `activeClipId`. Nothing else changes. Fixtures call it `previewClip` with an index pair or null. |
| `addClip(startIndex, endIndex, origin, …)` | Append a `ClipRange` with a new id and `selected = true`. Manual clips come from a word selection and need no AI key. |
| `addAIClips(resultId, clips)` | One undo step named "Find clips": for each result clip in order, append a `ClipRange { origin: ai, aiResultId: resultId, aiClipIndex: k, title, selected: true }`, skipping a clip whose `(startWordId, endWordId)` equals an existing clip's. Never removes or changes existing clips (ai.md 11.8). |
| `updateClip(id, startIndex, endIndex)` | Nudge or reselect the edges, keeping `0 <= start <= end < count`. The "‹ ›" buttons move one item. If it is the active clip, the range layer follows. Edits are untouched. |
| `renameClip(id, title?)` | Set the title (JS-trimmed; empty means null). |
| `setClipSelected(id, selected)` | Set the checkbox. Nothing else changes. |
| `removeClip(id)` | Remove the clip and its `share.captions` entry. If it was active, `activeClipId = null`. The AI result it came from stays. |
| `setPauseKeep(seconds)` | `pauseKeepSeconds`, 0 to 1. The UI offers named levels (design spec). The default is 0.15. |
| `setPauseThreshold(seconds)` | Re-derive `pauses` (5.7) and drop missing ids from `cutPauseIds`. |

Fixtures: `session/fillers-pauses-restore` (no clip; VoxConvo and VoxClip agree), `session/clip-preview` and `session/clip-range-layer`. The fixture op names are `toggle`, `cutSelection`, `cutFillers`, `tightenPauses`, `restoreCuts`, `correct` and `previewClip`.

### 6.4 EditSummary and reference labels

```text
EditSummary (all scoped):
  fillerCount     = fillers.count
  cutWordCount    = in-scope items in cutWordIds
  pauseCount      = in-scope pauses
  cutPauseCount   = in-scope pauses in cutPauseIds
  canCutFillers   = fillerCount > 0
  canTighten      = pauseCount > 0 and cutPauseCount != pauseCount
  hasEdits        = cutWordCount > 0 or cutPauseCount > 0         // shows "Restore cuts"
  canExport       = not (in-scope items nonEmpty and every in-scope item is cut)
```

Product wording belongs to the design spec. The session fixtures keep VoxConvo's English strings, so test suites format them with this helper. It is test code, not UI copy:

```text
cutFillersLabel = fillerCount > 0 ? "Cut fillers · " + fillerCount : "Cut fillers"          // U+00B7 with spaces
status          = hasEdits ? w + (w == 1 ? " word" : " words") + " and " + p + (p == 1 ? " pause" : " pauses") + " cut. Preview before publishing." : null
fixture ui      = { cutFillersLabel, cutFillersEnabled: canCutFillers, tightenPausesEnabled: canTighten,
                    restoreCutsVisible: hasEdits, status, publishEnabled: canExport }
```

### 6.5 Derived transcript text

The transcript string used for copying, share captions and the clip finder is derived from the items. It is never a patched string. Default joining: the `textOf` of `kind == word` items in order, separated by U+0020. The clip-finding spec defines its own numbered-line format.

## 7. Planning, time mapping and rendering rules

### 7.1 buildSegments

```text
buildSegments(state, activeClip?):        // activeClip = resolved indices or none
  segs = []
  for i, item in transcript.words:
    segs += { id: item.id, kind: word, wordKind: item.kind, text: textOf(item), start: item.start, end: item.end,
              cut: item.id in cutWordIds or !inScope(i) }
  for p in pauses (derived order) where p.id in cutPauseIds:            // out-of-scope pause cuts are included
    segs += { id: p.id, kind: pause, start: p.start, end: p.end, cut: true }
  if activeClip:
    (cs, ce) = clipTimes(items, activeClip.startIndex, activeClip.endIndex)
    head = { id: "clip-head", kind: range, start: 0,  end: cs, cut: true }
    tail = { id: "clip-tail", kind: range, start: ce, end: max(ce, items.last.end) + 3600, cut: true }
    append head if head.end > head.start; append tail if tail.end > tail.start
  return stableSortByStart(segs)
```

Words outside the clip are cut only inside this function. Pauses cut for the full take stay in force inside a clip, so a clip never contains audio that the full take cuts. For example, a cut pause right after the clip's last word shortens the clip's 0.25 s tail to the pause breath. VoxConvo behaves the same way.

### 7.2 clipTimes (reference `clips.ts:32-40`)

```text
clipTimes(items, s, e):
  first = items[s]; last = items[e]; prev = s > 0 ? items[s-1] : none; next = e+1 < count ? items[e+1] : none
  start = max(0, first.start - min(0.12, prev != none ? max(0, first.start - prev.end) / 2 : 0.12))
  end   = last.end + min(0.25, next != none ? max(0, next.start - last.end) / 2 : 0.25)      // not clamped to the duration
```

The clip length shown in the UI is `end - start`. Fixtures: `clip-range/*`.

### 7.3 cutRange (reference `mediaTimeline.ts:28-45`)

```text
isValid(s)    = finite(s.start) and finite(s.end) and s.end > s.start
speech        = stableSortByStart(segments where isValid and kind == word)            // all words, cut or kept, every wordKind
cutRange(s):
  if s.kind == pause:
    before = among speech with end <= s.start + 1e-6, the one with the greatest end (the first in sorted order wins ties)
    after  = the first in speech (sorted order) with start >= s.end - 1e-6
    return [ s.start + (before exists and !before.cut ? pauseKeep : 0),
             s.end   - (after  exists and !after.cut  ? pauseKeep : 0) ]
  if s.kind == range: return [s.start, s.end]
  k = position of s in speech (by identity or index, never by value)
  earlierEnd = max(0, max over speech[0 ... k-1] of end)
  if earlierEnd >= s.end: return [s.start, s.end]                 // nested in an earlier word: exact
  nextStart = k + 1 < speech.count ? speech[k+1].start : duration
  reach(gap) = min(0.1, max(0, gap) / 2)
  return [ s.start - reach(s.start - earlierEnd), s.end + reach(nextStart - s.end) ]
```

`before.cut`/`after.cut` are the segment flags, so out-of-scope words count as cut. Consequences:

- A cut word takes at most half of each neighbouring gap. Two adjacent cut words therefore meet and merge, and a kept neighbour always keeps at least half the gap.
- The silence before a word is measured to the latest end of **all** earlier words, and the silence after it to the start of the **next** word only. Overlaps give a negative gap, which means zero reach.
- A pause keeps a breath only next to words that stay. A pause of `2 · pauseKeep` or less between two kept words gives an empty range, which is dropped.

### 7.4 buildEditPlan (reference `mediaTimeline.ts:48-92`)

```text
buildEditPlan(segments, duration, rate):
  require finite(duration) and duration >= 0 and finite(rate) and rate > 0, else error "Invalid media duration or sample rate"
  require every range segment has cut == true
  totalSamples = max(0, jsRound(duration · rate))
  selected = for s in segments (input order) where s.cut and isValid(s):
               (a, b) = cutRange(s); (sa, sb) = (clampSample(a), clampSample(b)); keep if sb > sa
  selected = stableSort(selected by sa)
  cuts = []
  for c in selected:
    if cuts nonEmpty and c.sa <= cuts.last.sb: cuts.last.sb = max(cuts.last.sb, c.sb)    // overlapping OR touching merge
    else cuts.append(c)
  kept = []; cursor = 0
  for c in cuts: if c.sa > cursor: kept.append([cursor, c.sa]); cursor = c.sb
  if cursor < totalSamples: kept.append([cursor, totalSamples])
  outputSamples = Σ (k.sb - k.sa); duration' = outputSamples / rate
```

Invalid segments (NaN, ±∞, `end <= start`) are ignored, both as cuts and as speech neighbours. Out-of-range cuts clamp to `[0, totalSamples]`, and the clip tail's +3600 relies on that. Fixtures: `plan/*` (34) assert `segmentCuts` (pre-rounding values per cut segment in input order), `cuts`, `kept`, `outputSamples`, `durationSeconds`, `captions` and the mapping probes.

### 7.5 Time mapping (reference `mediaTimeline.ts:94-112`)

```text
mapTime(t):                                   // source -> edited; a time inside a cut collapses to the join
  s = clampSample(finite(t) ? t : 0)
  removed = 0
  for c in cuts: if c.sa >= s: break; removed += min(s, c.sb) - c.sa
  return min(outputSamples, max(0, s - removed)) / rate

sourceTime(e):                                // edited -> source
  r = max(0, jsRound((finite(e) ? e : 0) · rate))
  for k in kept: len = k.sb - k.sa; if r < len: return (k.sa + r) / rate; r -= len
  return totalSamples / rate                  // at or past the end: END OF SOURCE, not the end of the last kept part

cutContaining(t) = the first cut c with c.sa / rate <= t < c.sb / rate, or none     // fixtures: previewSkip
```

These invariants hold for every plan (the generator's property checks: 300 random plans, 200 probes each, at 1k/16k/44.1k/48k):

1. `mapTime(sourceTime(e)) == e` exactly for every sample-aligned `e` in `[0, outputSamples)`.
2. `sourceTime(mapTime(s)) == jsRound(s·rate)/rate` for every `s` outside the cuts.
3. `mapTime` is non-decreasing.
4. Consecutive cuts are separated by at least one kept sample.
5. At an exact join, `sourceTime(edge)` is the start of the next kept part.

### 7.6 Caption copy (reference `mediaTimeline.ts:118-126`)

```text
captionCopy(segments, plan):
  for s in segments (input order) where s.kind == word and s.wordKind == word and !s.cut and isValid(s):
    (a, b) = (plan.mapTime(s.start), plan.mapTime(s.end))       // boundaries mapped independently
    if b > a: emit CaptionWord { id: s.id, text: s.text, start: a, end: b }
```

- A kept word that overlaps a cut is shortened. A word entirely inside a cut disappears. Out-of-scope words are cut, so they never appear in a clip's captions.
- The text is the corrected text with no transform. Case, punctuation stripping, paging and timing styles belong to the captions spec and are applied to this copy only, **after** planning. A transform can never change the plan.
- The transcript stays on source time. Only this copy is on the edited timeline. It is also the `{word, start, end, conf}` list that VoxConvo publishing (M2) sends.

### 7.7 Join fades (reference `audioEditor.ts:19-29`)

```text
fadeLength = jsRound(0.005 · rate)
offset = 0
for k in plan.kept:
  len  = k.sb - k.sa
  fade = min(fadeLength, floor(len / 2))
  part = { outputStart: offset, length: len, fadeIn: k.sa > 0 ? fade : 0, fadeOut: k.sb < totalSamples ? fade : 0 }
  offset += len
gain(output sample o in part P): i = o - P.outputStart; j = P.length - 1 - i
  g = 1; if i < P.fadeIn: g = g · i / P.fadeIn; if j < P.fadeOut: g = g · j / P.fadeOut
```

- Fades are linear and change amplitude only, never length. The first sample of a fade-in and the last of a fade-out are exactly 0. The two ranges never overlap, because `fade <= floor(len/2)`.
- A clip's first part fades in and its last part fades out, because they start after 0 and end before the source end. The very start and end of the source are never faded.
- macOS applies the gains in an `MTAudioProcessingTap` on the composition's audio mix (the media spec has the measured reasons `setVolumeRamp` is not used). If the tap runs at a different rate than the plan, scale the part boundaries once in `prepare`. Windows applies the same gains to decoded `fltp` samples. Both use the same tap or filter for preview and export.
- Fixtures: `fades/*` (5). Gains are binary32 (`Float32(i / N)`); compare with tolerance 1e-7.

### 7.8 Consumers

- **Preview** plays a composition of `plan.kept`: an AVMutableComposition with CMTime timescale = `sampleRate` on macOS, and the equivalent sample-accurate timeline on Windows. The player clock is edited time. Captions are drawn from `captionCopy` on that clock. There is no seek-skipping, so the reference's two-clock preview is not carried over.
- **Export target scope** resolves `fullEdit` to no clip and `clip(id)` to that exact clip before building segments. The edit plan and `captionCopy` for one output consume the same resolved segments; the editor's currently open clip affects only the ordinary preview. An unknown clip id is an export error, not a full-edit fallback.
- **Transcript highlight** at edited time `e`: `s = sourceTime(e)`. The highlighted word is the first `kind == word` item in transcript order that is not cut (effective cut, 7.1) and has `start <= s < end`.
- **Transcript tap** seeks to `mapTime(item.start)`. A cut item seeks to the join where it was.
- **Scrubber** range is `[0, plan.duration]` in edited time.
- **Video frames.** The output frame at edited time `e` shows the source frame that is displayed at `sourceTime(e)`, that is the latest frame with `pts <= sourceTime(e)`. AVComposition does this by construction. The Windows engine MUST pull frames the same way. Video is accurate to one frame and audio to one sample.
- **Rebuild** the plan after every operation. It costs O(items). Debounce composition rebuilds by about 150 ms while the user is clicking.
- **Export MUST refuse** when `outputSamples == 0` or `!canExport`, with the error `everythingCut` (architecture 10.2; wording in the design spec). Exporters MUST NOT write a 1-sample file as the reference did.

### 7.9 Worked example (fixture `plan/pause-breath-and-filler`, rate 1000, duration 6)

Segments: `so` [1, 1.4] kept; `pause-after-so` [1.4, 3.4] cut; `right` [3.4, 3.9] kept; `um` [4.2, 4.5] cut; `then` [4.8, 5.2] kept.

- Pause: `before = so` is kept, so the start is `1.4 + 0.15 = 1.5499999999999998`. `after = right` is kept, so the end is `3.4 - 0.15 = 3.25`. Samples [1550, 3250].
- `um`: earlierEnd 3.9 gives a gap of 0.3 and a reach of 0.1, so the start is `4.1000000000000005`. nextStart 4.8 gives a reach of 0.1, so the end is 4.6. Samples [4100, 4600].
- kept = [0,1550], [3250,4100], [4600,6000]. outputSamples = 3800, duration = 3.8.
- Captions: so [1, 1.4], right [1.7, 2.2], then [2.6, 3.0].
- `mapTime(2.4)` = 1.55 (inside the pause cut). `sourceTime(1.55)` = 3.25 (after the cut). `cutContaining(4.35)` ends at 4.6.

## 8. Deliberate divergences from VoxConvo

| # | VoxConvo | VoxClip | Evidence |
|---|---|---|---|
| 1 | Previewing a clip rewrites cut flags (words outside it are cut) and snapshots the words. Leaving the clip, or nudging an edge, restores the snapshot, so cuts and corrections made during the preview are lost. Counts cover the whole take. | The clip is a range layer (2.5, 7.1). The stored state is never rewritten, and edits made in a clip persist. Bulk operations and counts are scoped to the clip (6.1). The plans are identical to VoxConvo's while a clip is active. | `session/clip-preview` was **deliberately changed** to these semantics. The VoxConvo steps are kept in its `informative.voxconvoSteps`. Its final step now keeps the correction "Today" (VoxConvo: "today"); during the preview `cutWords` is `[w0]` (VoxConvo: `[w0, w1, w8]`) and `status` counts only in-clip cuts. New: `session/clip-range-layer`. |
| 2 | Segment type is inferred from id prefixes (`pause-`, `clip-`). The video upload drops ids, so the server planned `clip-head`/`clip-tail` as words: up to 100 ms more of the clip tail, and 60 ms of the lead-in, were trimmed in the rendered file compared with the preview and caption metadata. | Explicit `kind` on every segment, in memory and on disk. Ids are opaque. Head and tail are exact ranges everywhere, which fixes the clip head/tail mismatch. | `plan/kinds-not-id-prefixes`, `plan/clip-head-tail` |
| 3 | Pause operations are global even during a clip preview. | Tighten and restore act on in-scope pauses only. Pause cuts made for the full take still apply inside a clip (7.1). | `session/clip-range-layer` |
| 4 | Scribe `audio_event` tokens are dropped. | They are kept as `event` items: cuttable, they bound silence and split pauses, but they are never captioned. | `plan/non-caption-items`, `pipeline/native-verbatim-no-audio` |
| 5 | No recovery of fillers that engines drop. | `tightenIntoSound` and `findUnlabeledSpeech` produce `unlabeledSpeech` items that "Cut fillers" counts. | `tighten/*`, `gaps/*`, `pipeline/gapless-non-verbatim` |
| 6 | The server applies punctuation removal and uppercasing **before** planning, and emptied words drop out of the neighbour set, so the server's reach and breath can differ from the client's. | Caption transforms apply to the caption copy after planning (7.6). | `caption-text/punctuation-uppercase` is kept as an informative record of the VoxConvo transform and its `ß` → `SS` trap. |
| 7 | Two clocks: the video preview seek-skips on the source clock, and audio plays a rendered buffer on the edited clock. | One edited clock over a composition (7.8). | (media specs) |
| 8 | A fully cut take renders a 1-sample buffer. | Export refuses (7.8). | `plan/complete-removal` |
| 9 | The transcript string is patched by splitting on spaces, which breaks once a correction contains a space. | Text is derived from items (6.5). | |
| 10 | The breath (0.15 s) and the pause threshold are constants. | Both are per-project parameters with the reference defaults (`pauseKeepSeconds`, `pauseThresholdSeconds`). | `plan/pause-breath-tight` |
| 11 | Match normalisation uses the host locale. | Invariant lowercase with the U+0130 rule; NFC at ingest (4.7, 4.8). | `align/dotted-capital-i` |
| 12 | Engine words are trusted as given. | `cleanWords`: NFC, trim, punctuation attachment, invalid-time removal, stable sort by start (5.2). | `ingest/clean-words` |
| 13 | A word corrected back to its original text keeps a correction entry, and pause chips toggle in "correct" mode. | Correcting back removes the entry. Only `kind == word` items are correctable. There is no separate correct mode (design spec). | `session/clip-range-layer` |

`caption-text/punctuation-uppercase` also gained a `notes` field marking it informative. Its expectations are unchanged.

## 9. Cross-language traps

| Trap | Rule | Fixtures |
|---|---|---|
| Sample rounding | `jsRound` (4.1). C# `Math.Round` defaults to banker's rounding; `floor(x+0.5)` is wrong at 0.49999999999999994. | `plan/rounding-half-up`, `plan/rounding-unit-rate` |
| Stable sort | Sort on (key, index) (4.2). | `plan/stable-sort-tie-a/b`, `ingest/clean-words` |
| Expression order, FMA | Binary64, the written order, no contraction (4.3). | every `segmentCuts.rawStart/rawEnd` |
| `toFixed(1)` | Exact integer algorithm (4.4). `%.1f` ties to even. | `pauses/label-rounding`, `pauses/label-to-fixed` |
| Whitespace | The JS set exactly (4.5). | `text/js-whitespace`, `align/whitespace-tokens` |
| UTF-16 lengths | `utf16.count` / `Length` (4.6). | `estimate/utf16-length` |
| Lowercasing | Invariant, U+0130 → `i`, no final sigma (4.7). | `align/dotted-capital-i`, `align/unicode-normalise` |
| Uppercasing `ß` | JS `toUpperCase` gives `SS`, Swift `uppercased()` gives `SS`, .NET `ToUpperInvariant` keeps `ß`. The editing engine never changes case. The captions spec defines a deterministic rule. | `caption-text/punctuation-uppercase` (informative) |
| Regex anchors and case | Absolute anchors, ASCII folding (4.11). | `fillers/anchors-and-case` |
| Float32 levels | Store levels as binary32 and do arithmetic in binary64 (4.9). | `boundaries/*`, `tighten/*`, `gaps/*` |
| `sin` ulp differences | The synthetic generator uses libm `sin`. Tolerance is 1e-6, and refined times are frame multiples. If a platform ever fails, commit the PCM as `.f32` next to the fixture and load that instead. | `boundaries/*` |
| Non-finite JSON | Named literals (4.10). | `plan/invalid-and-out-of-bounds` |
| NaN in min/max | Swift `max(a, b)` with NaN depends on argument order, while JS and C# propagate NaN. Every algorithm guards non-finite values first (`isValid`, `finite(t) ? t : 0`); keep those guards before any min/max. | `plan/invalid-and-out-of-bounds` |
| Negative zero | `max(0, -0.0)` can return `-0.0` in Swift. Compare numerically, never by bit pattern or string. | |
| Identity | `speech.indexOf(segment)` is by reference in JS. Use positions. | `plan/stable-sort-tie-*` |
| Integer vs double | Sample math in Int64; divide by `rate` only to report seconds. | all plan fixtures |
| JSON keys | Keys are exactly as in the schemas (camelCase). Swift's synthesized `Codable` writes a property named `modelID` as `"modelID"`, but the key is `"modelId"`, so give such properties explicit `CodingKeys`. Optional fields are written as `null`, never omitted. | `projects/*` round trip |

## 10. Project file semantics

Schema: `shared/schemas/project.schema.json` (JSON Schema 2020-12; `transcript.words[]` items use `timed-word.schema.json`). Examples: `shared/fixtures/projects/*.voxclip`, with expected plans in `shared/fixtures/editing/projects/*.json`.

### 10.1 Encoding

- One UTF-8 JSON document without a BOM, extension `.voxclip`, identical on both platforms. Writers SHOULD indent with two spaces and end the file with LF. Key order is not significant.
- Numbers are finite. Doubles MUST round-trip exactly (write the shortest representation that parses back to the same binary64). Reading and writing a file therefore never changes a time. Verify this for the encoder in use on each platform with a test that saves and reloads both example projects.
- Every `timestamp` (`createdAt`, `modifiedAt`, `consentVerifiedAt` and the other dates in the schema) is written as UTC `YYYY-MM-DDTHH:MM:SS.sssZ`: exactly three fractional digits, uppercase `T` and `Z`, ASCII digits, the proleptic Gregorian calendar and years 0001–9999. The writer rounds the instant to the nearest millisecond, and an exact half goes to the later instant, so `2026-12-31T23:59:59.9995Z` is written `2027-01-01T00:00:00.000Z`. An instant that rounds past `9999-12-31T23:59:59.999Z` cannot be saved. The rounding works on integers (milliseconds or 100 ns ticks); it never formats a binary64 value, and no locale or calendar setting applies.
- A reader accepts exactly `YYYY-MM-DDTHH:MM:SS`, then optionally `.` and 1–9 digits, then `Z`. It refuses offsets, a lowercase `t` or `z`, a space for `T`, missing seconds, 10 or more fractional digits, impossible dates and times (hour 24, second 60, February 29 in a common year) and years outside 0001–9999. It reads the digits exactly and rounds them as the writer does, so on both platforms the loaded value is the one the next save writes. Three-digit text therefore saves byte for byte, and loading then saving never moves a stored date. Values read from disk always agree on both platforms. Only an instant made in memory that lies exactly on a half millisecond can round differently, because a macOS `Date` is binary64 and may hold it just below or above the half. Older text with no fraction, or with the 0–7 fractional digits that Windows builds before 2026-10-27 wrote, loads and is written once in canonical form. Cases: `shared/fixtures/projects/timestamps.json`.
- VoxClip's other persisted timestamps are written the same way: cache metadata (`createdAt`, `lastAccessAt`), raw transcription results (`createdAt`), model markers (`installed.json` `installedAt`), the LLM model cache (`llm-models.json` `fetchedAt`), provenance sidecars (`export.createdAt`, `aiSegments[].generatedAt`, `consent[].verifiedAt`), the macOS Apple speech locale ledger (`apple-speech-locales.json` `lastUsed`) and the setting `update.lastCheckAt`. Some of their readers are more lenient: cache metadata also accepts an offset (architecture §8.2), a raw result whose `createdAt` cannot be read still loads, and `update.lastCheckAt` still reads the forms earlier builds wrote. An instant in cache metadata that rounds past `9999-12-31T23:59:59.999Z` makes the entry a cache miss. Log lines, provider request bodies and HTTP dates such as `Retry-After` are not covered and keep their own formats.
- `cutWordIds` and `cutPauseIds` are written in transcript order, and `corrections` keys in transcript order, so saves are stable and diffable.
- Secrets never appear: no API keys, tokens, account names or provider credentials. Absolute paths can reveal a user name, so the share UI SHOULD say so before a project file is shared.

### 10.2 Saving

On every save, `modifiedAt` and `savedBy` are updated, and `relativePath` is recomputed against the directory of the file being written (null when the media is on a different volume or drive).

- **macOS app.** `VoxClipDocument` uses the public macOS 26 `NSDocument` safe-writing lifecycle (architecture 2.6 and 7.1). Save and Save As snapshot the accepted project against the final destination URL before the temporary safe-write URL is chosen. A cross-folder Move uses that same safe writer for the destination and removes the original through file coordination; a same-folder Rename uses AppKit's coordinated native move because the relative media path does not change. Save Copy writes the target representation without adopting its location. Successful location-changing operations leave a portable `relativePath` immediately and a clean document and window if no later edit was accepted. An edit accepted after the write snapshot remains in memory, dirty and undoable while the file contains the earlier snapshot; both document and window stay marked edited after Move token completion. Failure or cancellation retains the prior file bytes, location and edited project. NSDocument's change-count token checkpoints a successful write; Undo and Redo return to and depart from the saved state without clearing later edits.
- **Windows app and the CLI.** Every operation autosaves, debounced by about 1 s, and the file is also saved on close. Writes are atomic: write a temporary file in the same directory, flush it, then replace (Windows `File.Replace`, or `File.Move(temp, path, overwrite: true)` when there is no existing file; the macOS CLI uses `Data.write(options: .atomic)`).

### 10.3 Resolving the source media

The source media hash is `contentKey`. It is the same value as the architecture's cache key and the transcription cache's `mediaHash`:

```text
contentKey = lowercase hex SHA-256( UTF-8 "voxclip-source-v1\n" + decimal(sizeBytes) + "\n" + head + tail )
head = the first 1,048,576 bytes; tail = the last 1,048,576 bytes
a file smaller than 2 MiB is hashed once, whole, with no tail
```

Fixture: `media/content-key`.

1. If `absolutePath` exists and its size equals `sizeBytes`, compute `contentKey`. If it matches, use the file.
2. Otherwise resolve `relativePath` against the directory that contains the `.voxclip` file, converting `/` to the native separator, and apply the same check. On success, the next save rewrites `absolutePath`.
3. Otherwise ask the user to locate the file. A file whose size and hash match is accepted silently. A different file is accepted only after an explicit confirmation, and only if its probed planning duration is within 0.05 s of `durationSeconds`. In that case `sizeBytes`, `contentKey`, `video` and `audio` are updated, and the transcript and edits are kept.
4. Until the media is resolved, the project opens read-only with the transcript visible.

On Windows, steps 1 and 2 probe a candidate only if it has one of two forms, checked after converting `/` to `\`: a drive-letter path (`X:\…`, with an ASCII letter), or a UNC path (`\\server\share\…`) on the same server and share as the `.voxclip` file itself, comparing the server and share case-insensitively. The project file's full path, resolved against the current directory, must also have one of these forms; a project on a device path never probes any candidate. Every other form is never probed, including the device and NT prefixes `\\?\`, `\\.\` and `\??\` (`\??\UNC\…` reaches the network like a UNC path), and UNC paths on any other share. Probing such a path can open an SMB session with the user's credentials as soon as a crafted project is opened. Those candidates go straight to step 3, and the locate dialog shows the stored path.

### 10.4 Loading and validation

- `format` must be `voxclip-project`. A file with a higher `schemaVersion` MUST NOT be edited ("made with a newer VoxClip"). Older versions are migrated in memory and written as the current version.
- The file must decode strictly into the typed project model, and the transcript invariants (2.2) must hold. Otherwise it is rejected as damaged (`projectUnreadable`). Strict decoding is the runtime form of schema validation (architecture 2.1): unknown keys are rejected except under `extensions`, required keys must be present (explicit `null` included), and the schema's enum, pattern, range and uniqueness rules are checked in code. No JSON Schema engine runs in the apps; the test suites validate every file the apps write with a real JSON Schema 2020-12 validator.
- References are then checked against the transcript and the derived pauses. Unknown ids in `cutWordIds`, `cutPauseIds` or `corrections` are dropped. So are clips with an unknown word id or with start after end, corrections on non-`word` items, corrections equal to the transcribed text, an `activeClipId` that names no clip (set to null), `aiResultId` values that resolve to nothing (set to null together with `aiClipIndex`), and `share.captions` entries whose key is neither `full` nor an existing clip id. Each drop is reported in the open log, and the cleaned state is what the next save writes.
- `media.source.durationSeconds` and `audio.sampleRate` feed `buildEditPlan`. A null `audio` means rate 48000.

### 10.5 Transcript replacement

Re-transcribing ("Transcribe Again…", design 11.3) replaces `transcript` and assigns new ids. It MUST clear `edits.cutWordIds`, `cutPauseIds`, `corrections`, `clips` and `activeClipId`, `ai.results` and `share.captions`, after a confirmation that names what will be lost (copy in design 13). `pauseThresholdSeconds` is reset from the new `refined` flag.

### 10.6 AI results

`ai.results` caches clip-finding runs: provider (connector id from `shared/catalog/llm-providers.json`), model, preset (`best`, `hooks`, `topics`, `quotes`, `custom`), instructions, language, `inputSha256` (SHA-256 of the exact transcript block sent) and the validated clips with indices resolved to word ids.

- A successful run appends its `aiResult` and then applies `addAIClips` (6.3): one `ClipRange` per result clip, `origin: ai`, with `aiResultId`, `aiClipIndex` and `selected: true`, skipping clips that duplicate an existing range. A new run never removes existing clips.
- The Clips list shows every `ClipRange`, manual and AI, sorted by start word index, then by position in `clips`. Score and reason come from the linked result clip. Removing a clip deletes only the `ClipRange`.
- Nudging or renaming an AI clip changes only the `ClipRange`. Results remain valid after cuts. If the current transcript block hashes differently (because of corrections), the UI marks the result as made from an older transcript.
- On save, results beyond the newest 10 that no `ClipRange` references are dropped.

### 10.7 Caches and other sections

- Levels, waveforms, thumbnails, decoded or proxy audio, and transcription uploads live in the app support directory, keyed by `contentKey`. They never live in the project file. Deleting them never loses work.
- `captions` stores `styleId`, a merge-patch `overrides` object (validated by the captions engine), and an optional dragged `position` with per-aspect overrides. The Export sheet's Captions picker and the inspector gallery read and write the same `styleId`; `"off"` burns no captions.
- `export` stores the Export sheet's choices: `aspect` (`source`, `16:9`, `9:16`, `1:1`), `quality` (`standard`, `high`), `srt` and the last `folder` (null for the settings default). Output size, bitrate and frame rate are never stored; they are derived at export time (architecture 4.1). New projects copy the settings defaults (`export.defaultAspect`, `export.quality`, `export.srt`). Framing is the M1 centre crop; face-tracked reframe (M2) adds fields in a new schemaVersion.
- `share.captions` maps an export target (`full` or a clip id) to the caption text the user edited in the share row (publishing 2.1). Entries for removed clips are dropped by `removeClip` and on load (10.4).
- `voiceLab.segments` is reserved for M3 and MUST be empty in schemaVersion 1. `extensions` holds reverse-DNS-keyed data from forks, which VoxClip preserves when saving.

## 11. Conformance

### 11.1 What must pass

Both core libraries MUST load every file under `shared/fixtures/editing/` and pass it. Dispatch is on `kind`:

| kind | Function under test |
|---|---|
| `edit-plan` | `buildEditPlan` (`segmentCuts` through `cutRange`), `mapTime`, `sourceTime`, `cutContaining`, `captionCopy` |
| `join-fades` | 7.7 part table and gains |
| `edit-session` | the reducer (6.3), `buildSegments`, `EditSummary` with the reference labels (6.4) |
| `pause-detection`, `pause-label` | 5.7, 4.4 |
| `filler-detection` | 4.11 |
| `transcript-alignment` | 5.3 |
| `estimated-words` | 5.4 |
| `clip-range` | 7.2 |
| `word-boundaries` | 5.6 |
| `word-tightening` | 5.5 |
| `unlabeled-speech` | 5.8 |
| `word-cleanup` | 5.2 |
| `import-pipeline` | 5.0 end to end |
| `text-whitespace` | 4.5 |
| `content-key` | 10.3 |
| `project-plan` | project load (10.4), `buildSegments`, `buildEditPlan` and `captionCopy` for the take and each clip |
| `caption-text` | informative; skipped by editing suites |

An unknown `kind` MUST fail the run, so new fixture kinds are never skipped silently.

### 11.2 Comparison rules

- Sample counts and indices: exact.
- Seconds: `|a - b| <= 1e-9` unless the fixture gives `tolerance`. Plan values are `Int64 / rate` and come out bit-identical, so exact comparison also passes.
- Gains: `tolerance` 1e-7. Audio-derived times: `tolerance` 1e-6.
- Strings: exact, by Unicode scalars.
- `informative`, `notes`, `description` and `source` are never asserted.

### 11.3 Changing behaviour

The fixtures are generated (`tools/fixtures/editing`, `npm run generate`) and committed. `npm run check` fails when a committed file differs from what the generator produces, and CI SHOULD run it. A change to any algorithm or constant here goes through the generator: VoxConvo behaviour comes from the vendored reference, and VoxClip rules from `tools/fixtures/editing/lib/voxclip.mjs`. The resulting fixture diff is reviewed as a behaviour change. Hand-editing fixtures is not allowed.

### 11.4 Synthetic audio ("vox-take-v1")

Audio-based fixtures describe their input as `{generator: "vox-take-v1", sampleRate: 16000, seconds, sections: [[from, to, kind]]}`. Both suites rebuild it exactly:

```text
data = Float32[seconds · 16000], zero-filled
seed = 7 (binary64); noise() = { seed = (seed · 16807) mod 2147483647; return (seed / 2147483647) · 2 - 1 }   // exact in binary64 or Int64
for i in 0 ..< data.count: data[i] = Float32(0.002 · noise())
for [from, to, kind] in sections (in order):
  for i in jsRound(from · 16000) ..< jsRound(to · 16000):
    v = kind == "vowel" ? 0.5 · sin(2π · 180 · i / 16000) : 0.1 · noise()          // "hiss"; noise keeps advancing
    if i < data.count: data[i] = Float32(v)                                          // writes past the end are discarded
```

`2π · 180 · i / 16000` is evaluated as `((2 · π) · 180 · i) / 16000` from left to right, with π the binary64 nearest to pi. The analysis is mono at 16 kHz, so `frameSize = 160`.

## 12. Deferred and out of scope

- **Leading and trailing silence trim.** The reference never creates pauses before the first item or after the last. `cutRange` already handles a pause with one neighbour (it keeps the breath on the word side), so this needs only new pause ids (`pause-lead`, `pause-tail`) and fixtures. It is not in 0.1.0.
- **Per-language filler lists and multi-word suggestions.** The M1 rule is English hesitations only (4.11), and it is not editable in 0.1.0. Estonian candidates (`ee`, `eee`, `äää`, `mm`, `hmm`) need a reviewed list per language. `öö` (night) and multi-word discourse fillers (`nagu`, `noh`, `tead`, "you know", "I mean") are real words and can only ever be suggestions. A later change needs a settings key, a matching algorithm in 4.11 and fixtures before any UI ships; transcription.md 7.7 records candidate lists as input. Until then, `unlabeledSpeech` covers dropped fillers for non-verbatim engines, and the verbatim engine (ElevenLabs Scribe) transcribes "ee" as a word the user can cut. TalTech is `verbatim: false` until transcription.md 16.4 measures its filler recall, so the gap search runs on TalTech takes.
- **AI tighten (M2).** An LLM may only propose additions to `cutWordIds` and `cutPauseIds`, shown as suggestions and applied as one undoable operation. It never edits text or timings.
- **Recording (M2).** Live pause chips use 1.0 s on raw times. After recording, the import pipeline runs on the recorded file.
- **Voice Lab (M3).** Version 2 stores reversible source-preserving replacements; version 3 adds explicit render recipes and request-bound Core preparation (Voice Lab §10.5). Core plans `source`/`synth` output pieces without changing the subtractive plan or source word times. Actual Media composition, insertion mapping, lip-sync rendering and disclosure outputs remain later work.
- **Caption gap filling and paging** are owned by the captions spec, which consumes `captionCopy`.

# Editing fixtures

These are the golden test vectors for the word-editing engine specified in [`doc/spec/editing.md`](../../../doc/spec/editing.md). The Swift core (`VoxClipCore`) and the C# core (`VoxClip.Core`) MUST both pass every file here.

The files are generated. Do not edit them by hand. To change behaviour, change the generator in [`tools/fixtures/editing`](../../../tools/fixtures/editing), run `npm run generate`, and review the diff as a behaviour change. `npm run check` fails when a committed file is not exactly what the generator produces.

## Layout

```text
shared/fixtures/editing/
  <group>/<name>.json      one fixture per file; the fixture id is "<group>/<name>"
```

| Group | kind | Files | Spec section |
|---|---|---|---|
| `plan/` | `edit-plan` | 34 | 7.3 to 7.6 |
| `fades/` | `join-fades` | 5 | 7.7 |
| `session/` | `edit-session` | 3 | 6, 7.1 |
| `projects/` | `project-plan` | 2 | 10.4, 7.1 |
| `pauses/` | `pause-detection`, `pause-label` | 4 + 1 | 5.7, 4.4 |
| `fillers/` | `filler-detection` | 2 | 4.11 |
| `align/` | `transcript-alignment` | 7 | 5.3 |
| `estimate/` | `estimated-words` | 5 | 5.4 |
| `clip-range/` | `clip-range` | 2 | 7.2 |
| `boundaries/` | `word-boundaries` | 8 | 5.6 |
| `tighten/` | `word-tightening` | 4 | 5.5 |
| `gaps/` | `unlabeled-speech` | 2 | 5.8 |
| `ingest/` | `word-cleanup` | 2 | 5.2, 4.8 |
| `pipeline/` | `import-pipeline` | 2 | 5.0 |
| `text/` | `text-whitespace` | 1 | 4.5 |
| `media/` | `content-key` | 1 | 10.3 |
| `caption-text/` | `caption-text` | 1 | informative only |

## File format

Every file is one JSON object:

```jsonc
{
  "schema": "voxclip-editing-fixture/1",
  "id": "plan/pause-breath-and-filler",          // equals the path without ".json"
  "kind": "edit-plan",                           // selects the runner
  "origin": "voxconvo",                          // see "Origins"
  "source": "vox-web/test/caption-timing.test.mjs:137",
  "description": "…",
  "notes": "…",                                  // optional: deliberate changes and quirks
  "input": { … },
  "expected": { … },
  "informative": { … }                           // optional, never asserted
}
```

`source`, `description`, `notes` and `informative` are documentation. Runners never assert them.

`fades/one-sample-zero-fade` also asserts the optional `expected.joins` sample triples (`outSample`, `fadeOutLen`, `fadeInLen`): a single kept sample has zero-length fades, an empty join list and unity gain. Its `origin` is `voxclip` because derived joins are a VoxClip editing §2.7 rule, not a field from the VoxConvo reference. Its inputs and expectations are generated, not hand-edited.

### Origins

| origin | Where the expectation comes from |
|---|---|
| `voxconvo` | The vendored VoxConvo TypeScript, run unmodified (`tools/fixtures/editing/reference`) |
| `voxconvo-reimplemented` | VoxConvo UI semantics from `VoiceRecorder.tsx`, re-implemented in the generator because that file is not vendored |
| `voxclip` | Rules VoxClip defines in the spec, implemented in `tools/fixtures/editing/lib/voxclip.mjs` |

### Conventions

- Times are seconds as binary64. Sample counts and indices are integers.
- Non-finite inputs are the strings `"NaN"`, `"Infinity"` and `"-Infinity"`. Decode them with `JsonNumberHandling.AllowNamedFloatingPointLiterals` (C#) or `nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")` (Swift). Expected values are always finite.
- Probe lists are `[input, expected]` pairs.
- An object such as `texts` is a map: compare it by key, not by order.
- Segments use explicit `kind` (`word`, `pause`, `range`). Ids carry no meaning; `plan/kinds-not-id-prefixes` uses misleading ids on purpose.
- Words in session inputs have no `kind`, which means `word`.

### Comparison rules

- Integers (samples, counts, indices): exact.
- Seconds: `|actual - expected| <= 1e-9`, or `<= expected.tolerance` when present (1e-6 for audio-derived times, 1e-7 for fade gains).
- Strings and booleans: exact, by Unicode scalars.
- Arrays: same length and order.

## Inputs and expectations by kind

| kind | input | expected |
|---|---|---|
| `edit-plan` | `durationSeconds`, `sampleRate`, optional `pauseKeepSeconds` (default 0.15), `segments[{id, kind, wordKind?, text?, start, end, cut}]` in input order | `totalSamples`, `outputSamples`, `durationSeconds`, `segmentCuts[{id, rawStart, rawEnd, startSample, endSample, empty}]` (one per valid cut segment, input order, before merging), `cuts[[sa,sb]]`, `kept[[sa,sb]]`, `captions[{id, start, end}]`, `mapTime[[source, edited]]`, `sourceTime[[edited, source]]`, `previewSkip[[source, cutEnd or null]]` (`cutContaining`) |
| `join-fades` | as `edit-plan` | `kept`, `outputSamples`, `parts[{outputStart, length, fadeIn, fadeOut}]`, `gains[[outputSample, gain]]` (every non-unity sample, or probes when there are many), `tolerance` |
| `edit-session` | `durationSeconds`, `sampleRate`, `hasDecodedAudio`, `words[{id, text, start, end}]`, `ops[]` | `steps[]`, one for the initial state and one after each op: `{after, cutWords[], cutPauses[], texts{}, activeClip [s,e] or null, ui{…}, durationSeconds, captions[{text, start, end}]}` |
| `project-plan` | `projectPath` (relative to the repository root) | `sampleRate`, `sourceDurationSeconds`, `pauses[{id, start, end, label}]`, `take{outputSamples, durationSeconds, kept, captions[{id, text, start, end}]}`, `clips[{id, startWord, endWord, sourceStart, sourceEnd, outputSamples, durationSeconds, kept, captions}]` |
| `pause-detection` | `hasDecodedAudio`, `words[{id, start, end}]` | `pauses[{id, start, end, duration, label}]` |
| `pause-label` | `durations[]` | `labels[]` |
| `filler-detection` | `pattern`, `flags` (documentation), `words[]` | `matches[]` |
| `transcript-alignment` | `words[{word, start, end}]`, `finalText` | `words[{word, start, end}]` |
| `estimated-words` | `text`, `start`, `end` | `words[{word, start, end, conf}]` |
| `clip-range` | `words[{word, start, end}]`, `ranges[[startWord, endWord]]` | `ranges[{startWord, endWord, start, end}]` |
| `word-boundaries` | `audio` (synthetic), `words[{id, word, start, end}]` | `words[{id, start, end}]`, `tolerance` |
| `word-tightening` | `audio`, `timing`, `words[{id, start, end}]` | `words[{id, start, end}]`, `tolerance` |
| `unlabeled-speech` | `audio`, `words[{id, start, end}]` (sorted) | `items[{start, end}]`, `tolerance` |
| `word-cleanup` | `rawWords[{text, start, end, conf?, kind?, speaker?}]` | `words[{text, start, end, conf, kind, speaker}]` |
| `import-pipeline` | `audio` (synthetic or null), `timing`, `verbatim`, `rawWords[]` | `words[]` (TimedWord with every field), `pauseThresholdSeconds`, `pauses[]`, `tolerance` |
| `text-whitespace` | `strings[]` | `trim[]`, `split[[…]]` |
| `content-key` | `sizes[]`; the file of each size has byte `i` = `(i * 31 + 7) mod 251` | `contentKeys[]` (lowercase hex) |
| `caption-text` | `words[]` | `removePunctuation[]`, `uppercase[]`, `both[]` (informative) |

Session op shapes: `{"op":"toggle","id"}`, `{"op":"cutSelection","ids":[…]}`, `{"op":"cutFillers"}`, `{"op":"tightenPauses"}`, `{"op":"restoreCuts"}`, `{"op":"correct","id","text"}`, `{"op":"previewClip","clip":[startIndex, endIndex] or null}` (that is `setActiveClip`).

The session `ui` block keeps VoxConvo's English strings. Build it in test code from the engine's `EditSummary` with the helper in spec section 6.4: `cutFillersLabel`, `cutFillersEnabled`, `tightenPausesEnabled`, `restoreCutsVisible`, `status`, `publishEnabled`. The product's UI copy is defined in the design spec and is not tested here.

### Synthetic audio

`audio` objects are `{"generator": "vox-take-v1", "sampleRate": 16000, "seconds", "sections": [[from, to, "vowel" or "hiss"]]}`. Rebuild the PCM exactly as spec section 11.4 describes (Park-Miller noise with seed 7, a 180 Hz vowel, writes past the end discarded), then run the analysis on it as one channel at 16 kHz.

## How the suites load the fixtures

Both suites read the files in place. They do not copy them into bundles.

1. **Find the repository root.** If `VOXCLIP_SHARED_DIR` is set (architecture section 2.4; CI sets it), the repository root is its parent directory. Otherwise walk up from the test source file (Swift: `#filePath`) or from the test assembly directory (C#: `AppContext.BaseDirectory`) until a directory contains `shared/fixtures/editing`.
2. **Enumerate** every `*.json` file under `shared/fixtures/editing/` recursively and sort the paths, so the run order is stable. Each file is one test case, named after its `id`.
3. **Check the header.** `schema` must be `voxclip-editing-fixture/1` and `id` must equal the relative path without `.json`.
4. **Dispatch on `kind`.** An unknown kind fails the test. `caption-text` is informative and is reported as skipped.
5. **Decode** with named non-finite literals enabled. Treat numbers as binary64 and integers as Int64.
6. **Resolve `projectPath`** against the repository root.

Swift (swift-testing in `apps/macos`, test target for `VoxClipCore`):

```swift
@Suite struct EditingFixtures {
  static let root = RepoRoot.locate(from: #filePath)                       // walks up to shared/fixtures/editing
  static let files = FixtureFiles.all(under: root.appending(path: "shared/fixtures/editing"))

  @Test(arguments: files) func fixture(_ file: FixtureFile) throws {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    let header = try decoder.decode(FixtureHeader.self, from: file.data)
    #expect(header.schema == "voxclip-editing-fixture/1" && header.id == file.relativeID)
    switch header.kind {
    case "edit-plan": try EditPlanFixture.run(file.data, decoder)
    // … one case per kind in the table above
    case "caption-text": return                                        // informative
    default: Issue.record("unknown fixture kind \(header.kind)")
    }
  }
}
```

C# (xUnit in the `VoxClip.Core` test project; it runs on Windows and on the macOS CI runner):

```csharp
public static IEnumerable<object[]> Files() =>
    Directory.EnumerateFiles(Path.Combine(RepoRoot.Locate(), "shared", "fixtures", "editing"), "*.json", SearchOption.AllDirectories)
             .OrderBy(p => p, StringComparer.Ordinal).Select(p => new object[] { p });

static readonly JsonSerializerOptions Json = new() {
    NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals, PropertyNameCaseInsensitive = false };

[Theory, MemberData(nameof(Files))]
public void Fixture(string path) {
    using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
    var kind = doc.RootElement.GetProperty("kind").GetString();
    switch (kind) {
        case "edit-plan": EditPlanFixture.Run(doc.RootElement, Json); break;
        // … one case per kind in the table above
        case "caption-text": return;                               // informative
        default: throw new Xunit.Sdk.XunitException($"unknown fixture kind {kind}");
    }
}
```

## Deliberate changes from the VoxConvo expectations

- `session/clip-preview` now expects range-layer semantics: the clip never rewrites cut flags, counts and Restore cuts are scoped to the clip, and leaving the clip keeps edits made during it. The VoxConvo steps are kept under `informative.voxconvoSteps`. The plans are identical until the clip is left. See spec section 8, item 1.
- `caption-text/punctuation-uppercase` gained a `notes` field marking it informative. Its expectations are unchanged.

Every other fixture that came from the planning research (57 fixtures, generated from the same reference) is content-identical apart from the added `schema` and `origin` fields. The other 27 files are new, and most of them have `origin: voxclip`.

# macOS implementation contracts

### 2026-10-26 — Paired rendering prerequisite status

- The Windows audited runtime pin now includes `atempo` after native ARM64 and emulated x64 graph and strict shipping checks. This does not validate either platform's production duration fit or generated-audio composition. Mac composition and disclosure remain under review, and both App/CLI active-synth guards remain enforced. The development machine's disk reserve is an execution constraint, not a product rendering requirement.

### 2026-10-26 — Approved disclosure staging route (ADR-R27)

- The reviewed helper API uses one reusable `VoiceLabDisclosureOverlay(plan:width:height:fontURL:captionBlocks:)`, drawing after captions via `draw(into:at:)`. Interval-wide caption bounds come from the existing renderer. `VoiceLabDisclosureWriter.stage(sourceMP4:stagedMP4:finalFilename:project:prepared:appVersion:createdAt:)` takes finalized muxer output, stages a marked MP4 and returns sidecar bytes for the existing export transaction.
- The helper handoff is `4deca8f`, not integrated into main. Native owners must first finish geometry bounds and immutable snapshot review fixes, production composition, asset lifetime and transactional disclosure verification. ADR-R27 records the accepted post-mux XMP route, not completed app/CLI rendering; current guards remain active.

### 2026-10-26 — Reviewed Voice Lab v3 Core integration

- Integrated the paired render contract through `f2a58e3`, including typed malformed-input and label-position rejection, public Swift recipe construction, detached Windows prepared collections, selected-scope seam checks and stretch-aware half-handle requirements. Existing v1/v2 schema definitions and the three frozen service artifacts remain unchanged. `prepare`/`verify` is the native composition handoff; active-synth app and CLI guards remain enforced.
- Combined-main verification passed 415 Swift Core tests and 8 selected Media/actual-CLI checks. The .NET Release build had zero warnings and errors; the full Core run passed 1,375 tests with 27 existing native/live/informative skips and no failures, followed by 8 Media/actual-CLI checks without skips. The stale future-schema tests now use version 4 and retain their file-preservation assertions. Twelve project fixtures and three transcript fixtures passed schema validation; render generators reproduced their files unchanged.
- Native mixed-audio/video composition, visible disclosure, XMP and transactional provenance output remain pending. The Windows shipping runtime lacks the specified `atempo` filter, so pitch-preserving fitting needs an audited runtime update. No provider call, push, package or release is established by this integration.

### 2026-10-26 — Voice Lab v3 render contract (ADR-R26)

- Core now reads/writes explicit schemaVersion 3 candidate recipes and prepares a request-bound output plan, selected recipes and per-scope disclosure. Source-video capability requires equal rounded input/output lengths; known other video modes stay stored but fail preparation. Seam handles, one-sample gaps, clipped edges, QA, room tone and bounded chunks have paired generated fixture coverage. `RenderTimeline` is inert; actual app/CLI/Media synth refusal stays active. Version 1 and 2 remain untouched and are never promoted automatically. Speaker matching, native composition, visible label, XMP and sidecar remain later integration work.

### 2026-10-26 — Reviewed paid-audio boundary integration

- Integrated the paired asset preparation and review fixes through `57d6230`. Prepared handles own private snapshots with verified hash, decoded format, rate, duration and trim; they never remove paid originals. Combined-main verification passed seven Media asset tests, six Core project tests and the actual CLI active/disabled rendering boundary test. Swift test compilation retains the existing unrelated Foundation Models unnecessary-`try` warning. Current app and CLI rendering guards remain in place; no generated-audio playback or export is enabled.

### 2026-10-26 — Voice Lab Media asset preflight follow-up

- A named pipe at a valid paid `.wav` path blocked the final `openat` before type or cancellation checks in a bounded, owned production-call test. Media now opens that final entry nonblocking and rejects it as `unsafePath` after `fstat`, before reading; regular WAV and FLAC preparation still uses the exact-byte snapshot. A changed source caption correction with identical audio pieces rejects the stale output plan, while the rebuilt plan prepares normally. The focused Swift run passed 7 Media asset tests and 6 Core project tests; `swift build -j 2` passed. No composition or playback capability is added.

### 2026-10-26 — Voice Lab v2 project and Core output pieces (ADR-R24)

- `ProjectVoiceLab` now retains typed `VoiceLabAsset` and `VoiceLabSegment` records in schemaVersion 2. Version 1 still writes only empty `segments`; generated assets require the version bump. `VoiceLabProject` validates and performs immutable accept, enable, disable, delete and candidate-selection transitions without changing source words or deleting assets. `VoiceLabOutputPlanner.build(_:scope:)` returns ordered source/synth sample pieces, mapping and captions for explicit full or clip scope. `requireLegacyRendering` rejects active synth for callers still using a source-only `EditPlan`. App, CLI and Media integration is a separate handoff; no rendering, consent capture or lip-sync is implied.

### 2026-10-26 — paired Voice Lab Core integration

- The lead integrated reviewed Mac Core `aabf7f1` and Windows Core `458e5be` against the same rewrite prompt and version-1 behavior fixture, including all 31 conversion-input cases. Both services retain original timed words, require exact-input single-use approval, and check connector/model/context before a rewrite send. The Windows clone route additionally validates declared WAV samples; that stricter clone-input check is recorded in the Voice Lab spec. No app workflow, project schema, media composition, consent capture or speaker verification is implied by this Core integration.

### 2026-10-25 — ADR-R22 hardware colour acceptance

- The lead accepted ADR-R22 for required-hardware macOS `h264_videotoolbox` only. It supersedes only the macOS decoded-canonical-RGB clause of ADR-R21. Windows software and hardware gates remain unchanged. The exporter still requires hardware acceleration and uses the one `FrameCompositor` path for preview and export. No fixture, bitrate, encoder setting or production pixel conversion changed.
- An internal, optional read-only writer observer copies selected composed BGRA RGB values and PTS before a successful append; no sample or pixel buffer escapes it. It is absent from ordinary exports. Canonical case 8 pairs 72 observed frame/pixel samples with the decoded output of that same in-process export. A separate Release CLI export of the same source and identity plan is decoded and checked against that witness, including its own H.264 High, 8-bit 4:2:0, MPEG limited and BT.709 format metadata. The CLI writer input is not directly observed. Both YUV and BGRA decode paths must return 60 frames for each output, agree on finite PTS at every frame, and match the writer PTS at sampled frames. Sampling checks actual image and plane bounds before reading. Both full CSVs are written under `VOXCLIP_E2E_OUT` and all colour failures are collected.
- Local Release verification: `swift build -c release -j 2`, the independent coefficient/mutation test, all ten canonical CLI cases with the exact Release CLI, and native colour/export cancellation regressions passed. Both 72-row CSVs show maximum submitted-to-canonical RGB error 2 and decoded Y/U/V error 0/1/1. Frame 30 green remains decoded RGB 0/192/5, as ADR-R22 explains. Hosted CI acceptance remains pending.

### 2026-10-26 — Voice Lab conversion WAV boundary correction

- Mac Core conversion preparation and dispatch now walk the complete RIFF/WAVE chunk structure, require the declared RIFF size to equal the actual file boundary, bound every chunk and odd pad, and require one PCM `fmt ` and one `data` chunk. Mono PCM16 at 8–96 kHz needs consistent byte rate and block alignment, whole samples, at least 20 ms and at most 290 seconds. Ordinary ancillary chunks and nonzero-index `Data` slices are accepted without a validation copy. Invalid inputs cause no network or paid send; exact input bytes remain bound to the single-use quote.
- `shared/fixtures/voice-lab/contract.json` version 1 adds `conversionInputs` with synthetic construction parameters and expected validity. Windows Core should consume this exact table for parity. Existing rewrite proposals and source word timing remain inert; this handoff does not provide media, UI, lip sync or a complete Voice Lab workflow.

### 2026-10-25 — Mac Voice Lab Core service handoff

Review correction: Core now issues bounded, instance-scoped quotes through `prepareClone`, `prepareDelete`, `prepareSynthesis`, `prepareConversion`, and `VoiceRewriteService.prepare`. Authorization references the quote and is consumed before dispatch. Its exact inputs, region/endpoint, model/voice/language, consent state, audio hash or full rewrite source/timings, and estimate must still match. The shared parity source is `shared/fixtures/voice-lab/contract.json` version 1. Stock rights use the `premade` or owned `generated` allowlist; duplicate discovery identities fail with typed errors. TTS carries explicit `language_code` except for documented `eleven_multilingual_v2` auto-detection. Conversion accepts complete mono PCM16 WAV input. Raw signed PCM output may begin `FF FF`; structural containers and encoded response types fail. Cancellation after send, network loss, 429 and invalid replies consume the quote and need a fresh estimate and approval. Windows Core should match the shared fixture before media or UI integration.

- `Domain/VoiceLab/VoiceLabContracts.swift` carries operation authorization, own-voice policy, discovery, audio, provenance and rewrite review values. `Services/VoiceLab/ElevenLabsVoiceLab.swift` uses the existing ElevenLabs region and key provider, discovers models/plan/voices, handles explicit clone create/list/delete, timestamped PCM TTS and voice conversion. `Services/VoiceLab/VoiceRewriteService.swift` consumes `shared/prompts/voice-rewrite.json` through the selected `LLMConnector`; Windows Core must consume the same prompt and match the offline wire/policy tests.
- The caller supplies a verified consent record and speaker match, shows an estimate and review, then creates an operation- and request-matched authorization for each generation. The LLM rewrite request has its own estimate and authorization. Unknown prices remain unknown. The service sends each mutation once, rejects malformed PCM/timing, keeps original timed words in rewrite proposals and returns a provider receipt. `VoiceLabAudioResult` is raw mono 16-bit little-endian PCM at 24 kHz, with character timing only for TTS.
- Media and UI must implement source-preserving timeline composition, preview/accept/undo, speaker verification, persistent consent, disclosure and optional lip sync. Long full-take text needs chunk planning with an explicit estimate and authorization per paid request. No project schema, UI or lip-sync pipeline changed in this round.

### 2026-10-25 — canonical macOS bar acceptance diagnosis

- Exact main `fc5ce0f` and tooling `64a5990` are merged into `track/mac-media`. The tooling suite writes all ten canonical CLI reports. Nine cases pass; `e2e-8-bars` fails only at frame 30, green bar, all three interior positions: direct AVFoundation BGRA decode returns blue 5 against canonical blue 0 and the required ±3. The assertion now reports the source RGB and decoded YUV at each failing point without changing the limit.
- On this M3 Max, the committed source at frame 30 and each of those positions decodes to RGB `1/191/2` and NV12 `134/64/52`. A temporary callback immediately before `AVAssetWriterInput.SampleBufferReceiver.appendImmediately` observed the actual submitted BGRA `1/192/2`. Its maximum canonical RGB error across all eight bars, three positions and frames 9, 15 and 30 was 2. The callback and temporary test were removed after measurement. The paired output decodes to NV12 `134/65/51` and AVFoundation BGRA `0/192/5`; its maximum canonical RGB error is 5. The rounded BT.709 limited forward transform of submitted green RGB is `134/64/52`. Across all 72 paired samples, decoded Y/U/V differ by at most one code value from that forward transform.
- The diagnostic `ffprobe` run reported H.264 High, `yuv420p`, `color_range=tv`, and BT.709 primaries, transfer and matrix. The source decode, composed writer input, buffer colour attachments and output metadata showed no wrong matrix or range. The old decoded-canonical-RGB ±3 gate failed through VideoToolbox's BGRA-to-H.264 conversion and lossy encode. Focused native cap/crop/709 regressions passed all six parameter cases. ADR-R22 now defines permanent acceptance above; the local canonical suite passes all ten cases.

### 2026-10-25 — mac-media round 7: final verification

- Merged main `1db3af2` normally as `b55132d`, without conflicts or dropped contract entries. Code verified at `a0d7dc3`. From `apps/macos`, `timeout 1800 swift build` and `timeout 1800 swift test` both exit 0 with the supplied `VOXCLIP_SHARED_DIR` and `VOXCLIP_MEDIA_FFPROBE` overrides and no compiler warnings. The full run reports 105 Media tests (100 passed, 5 skipped) in 93.439 seconds and 110 Core tests (107 passed, 3 skipped) in 6.255 seconds, zero failures. The six focused fix runs additionally pass all 40 parameter cases.
- Ten sequential filtered `ExportStopTests|cancellationDeletesPartialOutput` runs all exit 0: 300 ordinary stops, 40 blocked pulls (20 returning real buffers after stop), and 10 user cancellations. Maximum ordinary-stop, blocked-pull and user-cancel latencies are 0.164977458, 0.061514959 and 0.043026875 seconds respectively. Every ordinary writer cancellation observes zero appends in flight; blocked-pull cases require both deferred reader cancellations and reject late appends. Zero two-second watchdog failures or hangs occur; no parallel stress test processes are used.
- The full suite also passes 30 paired SIGINT iterations: 60 CLI exports, exit 6 throughout, zero watchdogs, maximum interrupt latency 0.15341725 seconds. Temporary fixtures and exports use the existing owned-directory cleanup. No GUI, live provider, artificial CPU load, push or merge into main is used. The branch diff against main is empty for `doc/` and `apps/windows/`; frozen Core `ContractTests.swift` matches main and all six M7 `TODO(merge)` sites match the incoming track baseline. All started build/test/CLI workloads have exited before this handoff.

### 2026-10-25 — mac-media round 7: frozen-file justification

- Of the two reviewed frozen files, the retained exception is `Sources/VoxClipCore/Domain/Shared/VoxClipError.swift` (common/mac-core owner). Architecture §9.3's publication paragraph, currently line 636, explicitly requires `exportFailed` to say "Couldn't put back {file name}. The previous version is saved as {backup file name}." when restoration fails. That pinned recovery sentence cannot carry the normal, false unchanged-data reassurance, and recovery errors must survive cancellation. Per the lead's round-seven decision 6, retain this spec-required exception for acceptance at merge; it changes no public error cases or wire values.
- Core's recovery recognition and Media's message construction now share one package-only prefix constant, so the English discriminator cannot drift independently. The complete exit-code regression (architecture §9.3's exit table) moves into the owned `Tests/VoxClipMediaTests/Pipeline/ExportSafetyTests.swift`; frozen `Tests/VoxClipCoreTests/ContractTests.swift` is restored byte-for-byte to main and needs no exception.

### 2026-10-25 — mac-media round 7: late pull and publication cleanup tests

- Architecture §5.6, "the blocked call is abandoned, and its reader is released when the call returns": an internal decode-boundary gate now lets both audio and video tests resume a real provider pull only after export cancellation has returned. The observer confirms a non-nil buffer arrives after stop, no append check runs after `stoppedAt`, and exactly two reader cancellations occur with zero pulls in flight. The earlier pre-check gate cases remain covered; all blocked-pull cases use a tiny 2-second source and semaphore ordering, not a sleep-based cancellation race.
- Architecture §9.3, "Every other backup is deleted on success, failure and cancellation": the successful symlink-destination CLI export now rejects every `.rollback-` name and every name containing `.partial`, in addition to audio staging leftovers.

### 2026-10-25 — mac-media round 7: explicit style preflight

- Architecture §9.3, "Other bad arguments are usage errors (exit 2) before the input is opened": explicit `--style` IDs resolve during output preflight, before loading projects, probing, transcription or `everythingCut`. A saved project's default style still resolves in the export path. Eight CLI cases cover unknown and traversal-style IDs with missing media, untranscribed media, all-filler input and an unreadable project; each requires one JSON usage error, no data directory and no output or partial/rollback files.

### 2026-10-25 — mac-media round 7: post-probe scope checks

- Architecture §9.3 supersedes the round-six pre-source-resolution scope placement below. Saved projects now relink and probe, validate audio/SRT arguments, then validate clip/range arguments, still before transcription or `everythingCut`. The five existing unknown-scope cases now use resolvable tiny media; four missing-media cases require exit 3 for both clip and range arguments placed before or after the input flags. Saved inputs and existing output bytes remain unchanged.

### 2026-10-25 — mac-media round 7: imported pause thresholds

- Architecture §9.1 step 3 and editing §2.5: the shared CLI `imported` constructor sets `ProjectEdits.pauseThresholdSeconds` to 0.8 for refined transcripts and 1.0 otherwise, for both media-file export and `transcribe --out`. No existing Core import helper exposes this initialization rule; `Project.replaceTranscript` uses the same values. Two CLI cases with a 0.9-second gap require 1.4 seconds of refined output versus an unchanged 2-second unrefined take.

### 2026-10-25 — mac-media round 7: scope before reducers

- Architecture §9.1 step 3: the CLI selects an explicit clip or new word-range clip before `.cutFillers`, then `.tightenPauses`; otherwise it preserves the saved active clip or whole-take media scope. The pause flag help now describes that selected scope. Four CLI regression cases compare exported samples and duration with the scoped Core plan, cover both clips containing fillers, and require the saved input to remain byte-identical. All six M7 `TODO(merge)` sites stay unchanged.

### 2026-10-25 — mac-media round 6: final verification

- Merged main `8bd6d1b` normally as `1c6a896`, with no conflicts or dropped contract entries. Implementation is `618cdd5`. From `apps/macos`, both `timeout 1800 swift build` and both `timeout 1800 swift test` runs exit 0 with the lead's shared-directory and ffprobe overrides and no compiler warnings. Each run reports 99 media tests (5 skipped) and 111 Core tests (3 skipped), zero failures. Media/Core durations are 92.334/6.250 seconds and 92.507/6.241 seconds.
- Thirty sequential filtered stop-suite plus user-cancel runs all exit 0: 900 ordinary stops, 60 fault-injected unreturning pulls and 30 separate user cancellations. Ordinary stop min/max/mean is 0.000425709/0.178791042/0.038372794899 seconds; blocked pull is 0.000504833/0.047675083/0.012816400717; user cancel is 0.020775750/0.070810917/0.033699404200. Every ordinary writer cancellation records zero appends in flight. There are zero two-second watchdog failures, hangs, leftover assertions or test issues.
- Both full suites additionally pass the 30-pair SIGINT watchdog: 60 interrupted CLI exports per run, all exit 6, zero watchdogs; maximum interrupt latencies are 0.147620334 and 0.165224667 seconds. No VoxClip CLI or Swift test-helper crash report appears. The shared machine independently produced five `dotnet` report files on 2026-10-25 at 16:02:52 (two), 16:03:10 (two) and 16:03:36 (one), local UTC+02:00; this track never invoked dotnet.
- Generated test media and exports use the existing owned temporary-directory cleanup. All started build/test/CLI workloads have exited. No GUI app, provider call, artificial CPU load, push or merge into main was used. The branch diff against main is empty for `doc/` and `apps/windows/`; all six M7 merge sites are unchanged, and the working tree is clean after this record is committed.

### 2026-10-25 — mac-media round 6: CLI preflight parity and leftovers

- Architecture §9.3: a project rejects `--transcript` before opening either input. Unknown project clips and out-of-transcript ranges are rejected before source resolution or transcription; media inputs reject every clip before transcription. ArgumentParser's bare `message(for:)` supplies JSON usage copy, while human errors retain the full help text on stderr. Finite, non-finite, negative and nonnumeric FPS values go through the pinned validation sentence; negative values are consumed as option values rather than mistaken for flags.
- Folder, special-file, missing-parent, input-overwrite and reserved-partial-overlap checks use the pinned output-path copy. The complete Core exit-code table is covered, including a set-equality check against every wire code. Edited WAV output already uses the plan rate and sample count and is unchanged.
- The user-cancel test requires an empty destination directory. CLI audio-failure tests now assert exact remaining files in both the output and restored-permission audio folders, permitting only their deliberately pre-existing unsafe partial directory. Writer scratch, partial siblings, Remaker directories and rollback files can no longer evade obsolete-prefix assertions. Six focused CLI tests and the Core exit-table test pass.

### 2026-10-25 — mac-media round 6: recoverable publication rollback

- Architecture §9.3: publication records each failed restore, retains its backup, attempts all remaining restores, and deletes every other backup and partial. The package-only rename seam exercises failed MP4 and SRT restores and cancellation immediately after the first successful publication, for both existing and newly created outputs.
- A failed restore is `exportFailed`, exit 5, with exactly "Couldn't put back {file name}. The previous version is saved as {backup file name}." The Core description recognizes this pinned recovery context and never appends the false unchanged-data reassurance. Recovery failures take precedence over task cancellation; the original publication error is still passed to the redacted diagnostic logger. Four focused tests (seven parameterized cases) pass.

### 2026-10-25 — mac-media round 6: bounded export stops

- Architecture §5.6: each reader owns a distinct composition copy. Pumps never cancel readers. Each pull uses an isolated serial executor and a one-shot continuation raced against the shared stop signal; an abandoned pull retains only its reader, never a writer receiver. After the task group joins, reader cancellation runs immediately for idle readers and is deferred until an outstanding pull returns for a busy reader. Writer cancellation follows the join with zero appends in flight, then owned partials and scratch are removed.
- Every stop-suite case and the separate user-cancel regression has an independent two-second test watchdog, not a task-group race that would itself wait for a wedged child. Fault-injected unreturning video and audio pulls both return cancellation and remove every partial before the test releases the blocked thread; reader-cancellation observers require zero same-output pulls in flight. The focused suite passes all three tests, including 30 ordinary stops, two blocked pulls and one separate user cancellation, without a crash.

Baseline: 2026-10-25. The declarations in this package are the coordination boundary for parallel implementation. Read the cited specs before changing behavior. Only this directory was scaffolded; shared data and specifications remain authoritative outside it.

### 2026-10-25 — mac-ui round 3 logging integration

`RedactingLogger(homeDirectory:)` remains redact-only with no sink (plan §4.1.3).
Only AppModel constructs the file-sink initializer; it injects that single logger
into its settings/project stores and ElevenLabs/Whisper adapters. Core defaults
and the CLI do not create log files implicitly (architecture §9.4, §11.1).

## Ownership

| Folder / files | Owner | Scope |
| --- | --- | --- |
| Sources/VoxClipCore/Domain/Editing/ | mac-editing | Pause/filler detection, boundary refinement, alignment, estimation, reducer/history, plans/mappings, clip range layer |
| Sources/VoxClipCore/Domain/Transcript/ | mac-speech | Raw tokens, assembler, clean/tighten/gap pipeline, language routing |
| Sources/VoxClipCore/Domain/Captions/ | mac-captions | Style schema, transforms, paging, line breaking, placement, easing and caption protocols |
| Sources/VoxClipCore/Domain/Clips/ | mac-ai | Presets, transcript numbering, canonical responses, finalizeClips, tighten suggestions |
| Sources/VoxClipCore/Domain/Shared/ | common, frozen | Portable word/project/export values, media descriptions/protocols, errors, redactor and version comparison; coordinate changes with the lead |
| Sources/VoxClipCore/Services/Project/, Settings/ | mac-editing | Project/settings persistence, cache, resource and data locations |
| Sources/VoxClipCore/Services/LLM/, Process/ | mac-ai | API/CLI connectors, runner, key injection, process sandbox and M3 lipsync seam |
| Sources/VoxClipCore/Services/Speech/, Models/ | mac-speech | Transcription orchestration, ElevenLabs, model catalog/downloads; M3 speaker seam |
| Sources/VoxClipCore/Services/Logging/, Updates/ | mac-ui | Redacting sinks and update checks |
| Sources/VoxClipMedia/Pipeline/, Audio/ | mac-media | Probe, composition, compositor, tap, preview, export, thumbnails and audio extraction |
| Sources/VoxClipMedia/Captions/ | mac-captions | CoreText shaping and the single caption rasterizer |
| Sources/VoxClipMedia/Speech/ | mac-speech | whisper.cpp and Apple Speech adapters |
| Sources/VoxClipMedia/Intelligence/ | mac-ai | Apple Foundation Models connector |
| Sources/VoxClip/, Sources/VoxClip/Info.plist, VoxClip.entitlements | mac-ui | Document/window lifecycle, view models, editor, welcome, settings, UI-only Keychain and app metadata |
| Sources/voxclip-cli/ | mac-media | ArgumentParser command tree, headless orchestration and environment-only key provider |
| Tests/VoxClipCoreTests/Editing/, Speech/, Captions/, AI/ | respective mac-* track | Replace that track's disabled placeholder and add fixture tests |
| Tests/VoxClipMediaTests/Pipeline/, UI/ | mac-media / mac-ui | Native tests and track placeholders |
| Tests/VoxClipCoreTests/FixtureLoader.swift, ContractTests.swift; Tests/VoxClipMediaTests/FixtureLoader.swift, MediaContractTests.swift | common, frozen | Baseline schema/resource/safety smoke tests; do not concurrently rewrite these files |
| Package.swift, Package.resolved, README.md, CONTRACTS.md, THIRD_PARTY_NOTICES.md | lead / coordination | Shared package metadata, dependency pins, contracts and legal notices |

Create additional caption and speech tests under uniquely owned subfolders of either test target, not in another track's files. Keep build output in .build and temporary tooling outside the source tree. Never edit apps/windows, shared or doc from a macOS implementation track.

## How to work in parallel

1. Edit only your owned folders. Update existing stubs in place; do not add duplicate implementations or backup files.
2. Import VoxClipCore in Media; app and CLI may import both. Core imports Foundation/Synchronization only and has no package dependencies. Domain must remain deterministic and I/O-free.
3. Treat all public signatures, wire keys and actor annotations below as fixed. Propose a change by appending a **dated note to CONTRACTS.md**, naming affected tracks, rationale and migration, and wait for coordination; never silently change a contract.
4. Source timings stay immutable. Clip ranges do not mutate cut flags. Pass only Sendable value snapshots across actors; preview graphs stay on MainActor and export graphs stay with their queue. CompositionBuilder.build inherits caller isolation and returns a deliberately non-Sendable RenderGraph.
5. Replace throwing stubs with real implementations and enable your track's placeholder only when fixture-backed tests exist. Until then stubs throw VoxClipError.notImplemented("track"); nonthrowing placeholders are documented and marked TODO(track), never fatalError or fabricated successful work.
6. Protocol adapter progress callbacks match the topic specs. Services expose completed placeholder AsyncStreams now; real services coalesce progress to at most 10 Hz. Close-window cancellation, real-time tap constraints and sequential per-window export are mandatory when implementing.
7. Read shared data at runtime through SharedResources (§2.4); do not copy it here or add SwiftPM resources. Tests use source-relative FixtureLoader plus VOXCLIP_SHARED_DIR. No model, key or real provider call is part of a normal build/test.
8. Preserve Package.resolved and exact dependency pins. Run swift build and swift test before handing a track back. The six disabled tests are deliberate placeholders, not behavioral coverage.

## Serialization and safety

- TimedWord, Transcript and Project use the project/timed-word schemas, including explicit null for nullable required fields, persisted engine metadata and camelCase keys. ProjectJSON supplies UTC RFC 3339 dates, stable object keys, round-trip doubles and validation of core timing invariants. ProjectStore owns full schema validation, reference cleanup, migrations and transcript-order serialization of cut IDs before disk writes; its skeleton refuses writes.
- ProjectEdits is the persisted subset; EditState also contains the immutable transcript and derived pauses. Source paths, models and caches are never created by a value initializer. Only the app creates its new-document UUID/date; Domain never reads a clock or generates randomness.
- CaptionStyle mirrors every schema property and enum. CaptionStylePosition includes anchors/draggability; CaptionPosition is the project's x/y-only override. CaptionPaint is a tagged solid/linear union. Defaults are decoded explicitly, with null preserved where null has distinct semantics.
- Keys are injected through KeyProvider, never stored in requests, project/settings data or child-process additions. Redactor intentionally has no Codable conformance so registered session secrets cannot accidentally be serialized. No sink currently writes a line; RedactingLogger drops messages safely until mac-ui implements all sinks.
- M2/M3 CostEstimate, SpeakerEmbedder, Lipsync* and TightenEdit are contracts only. Schema version 1 still forbids Voice Lab segments; ProjectJSON refuses to save any. No ONNX/lipsync dependency, download or provider action was added.

## Dependency pins

Verified against official GitHub release metadata on 2026-10-25:

- swift-argument-parser **1.8.2**, exact; Apache-2.0. Package.resolved records revision **6a52f3251125d74daf04fcbd5e6f08a75d074382**.
- whisper.cpp **b5454** (runtime **1.9.5**), official release asset: https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip (MIT; includes ggml).
- whisper archive SHA-256 / SwiftPM checksum: **e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b**. Downloaded to /tmp/voxclip-whisper-b5454-xcframework.zip and checked with swift package compute-checksum; matches the catalog's macOS runtime pin.
- b5454 is the newest release with an xcframework asset and GitHub marks it **prerelease**. This follows the task's newest-shipping-artifact requirement; newest non-prerelease shipping xcframework is b4938. No floating latest URL is used.

## Spec conflicts and dated decisions

### 2026-10-25 — mac-media round 4 review fixes and verification

- This entry supersedes the round-3 media verification and helper-drain descriptions below. Commit `11f7498` reverted every track hunk in `doc/architecture.md`, `doc/spec/captions.md` and `apps/windows/CONTRACTS.md`; normal merge `e0e1384` brought in main `453dbb3` without conflicts. Both contract ledgers were preserved. `git diff main...HEAD -- doc apps/windows` is empty. Accepted rules come from the lead, not new track-authored specification text.
- Architecture §5.6: video and audio now have separate readers over the same composition and time range. A throwing task group cancels siblings on the first error and preserves that first error. Each pump cancels its own reader at its sample boundary before awaiting writer shutdown; no cross-output helping or drain loop remains. The immutable internal reader/provider/receiver bundle has one pump owner. Writer cancellation and owned partial/work-directory cleanup complete before errors return.
- `exportPumpsStopAtSampleBoundaries` runs ten injected video failures, ten injected audio failures and ten user cancellations per suite. In both final runs, pulls started after stop are `[0, 0]`, maximum in-flight pulls are `[1, 1]`, and final in-flight counts are zero. Run-one maxima for video/audio/cancel are 0.099084292/0.099748959/0.044730208 seconds; run-two maxima are 0.095057458/0.108348208/0.100971708 seconds, all below the one-second bound.
- The bounded CLI watchdog uses a separate generated 60-second 1920×1080 H.264/AAC fixture and thirty pairs of concurrent exports, with seeded random SIGINT offsets in 0.5–2.5 seconds. Both final runs finish all sixty exports with exit 6, no partial or writer scratch, and zero watchdog firings. Run one: min/max/mean 0.006442875/0.172144333/0.081762401 seconds. Run two: 0.024170417/0.346518625/0.082192087 seconds. Every cancellation is asserted within two seconds; a stuck child is killed and fails the test rather than hanging the suite.
- Architecture §9.3: MP4, edited WAV and SRT are staged as files at the symlink-resolved destination plus `.partial`. Regular stale partials are replaced; partial directories and symlinks are rejected by CLI preflight as usage errors. The hidden audio staging directory is gone. AVAssetWriter scratch uses a uniquely owned visible work directory, removed on success, failure and cancellation. WAV and SRT preparation finishes before MP4 publication; sidecars publish only after MP4 publication succeeds. WAV preparation errors identify the requested destination rather than a staging path, with normal home-directory redaction.
- Output regressions pass: an immutable existing MP4 preserves its bytes and both existing sidecars, with accurate unchanged-data error copy; symlinked SRT/WAV destinations retain their links and update their targets; all three regular stale partials are replaced; all three output types reject partial directories/symlinks with exit 2; and a real unwritable WAV destination leaves an existing MP4 and WAV unchanged. A silent source with `--audio-out` is `usageError`, exit 2, with exactly “This video has no audio track, so --audio-out has nothing to write.”
- The CLI uses `JSONProjectStore.contentKey(for:)` for import and transcription; the duplicate CryptoKit implementation was removed. Every M7 adapter is marked `TODO(merge)`, including SRT, rasterizer selection, page lookup and the caption harness. The CLI marker explicitly includes the M6 `CaptionStyle.resolved(overrides:frame:)` dependency. These gates remain disabled for lead integration after mac-captions; no unavailable caption implementation is claimed.
- Final code verification at `96d2ae7`, from `apps/macos`: `timeout 1800 swift build` and two `timeout 1800 swift test` runs, with `VOXCLIP_SHARED_DIR=<repo>/shared` and `VOXCLIP_MEDIA_FFPROBE=<path to ffprobe>`. Both runs pass 89 media tests (84 passed, 5 skipped) and 110 Core tests (107 passed, 3 skipped), with no warnings or failures. Media/Core durations are 97.757/6.305 seconds and 97.636/6.586 seconds. Other compiler jobs were active; startup load averages were 23.04 and 27.36.
- The real 60-second 1080p-to-portrait CLI export passes ffprobe in both runs: H.264 High, 1080×1920, yuv420p, 30/1, 1,800 frames, BT.709 matrix/transfer/primaries and duration 60.000000 seconds; AAC LC, 48,000 Hz, stereo, 2,815 encoded frames and duration 60.000000 seconds. CLI audio accounting is 2,880,000 samples. The exact-duration benchmark retains PCM source audio so AAC passthrough priming cannot silently shorten the benchmark fixture.
- Eight expected skips remain per run: mac-ui, mac-captions and mac-ai placeholders; the informative editing caption-text case; three opt-in live speech-provider tests; and the separate opt-in performance benchmark. The CLI ffprobe export is enabled and passes. Windows-only checks and live providers were not run in this mac-media/headless task. No new normative spec question or public-contract proposal is needed; the staged-WAV seam is package-scoped and additive.
- Preliminary verification caught the AAC benchmark priming issue and a writer-shutdown ordering stall; both were fixed before the final successful runs. An intervening shared-temp run lost multiple CLI test directories and failed with missing-file errors; no cause is claimed. Reruns used a worktree-local `TMPDIR`, and the two final runs above are clean. Generated media, owned temporary logs and verification scratch are removed after checking results. No build tree was copied, no other worktree was changed, no GUI app was launched, and no push was made.

### 2026-10-25 — Initial skeleton

- **Transcript drift (resolved during scaffolding):** the earlier transcription draft had a flat Transcript and separate adapter metadata. The updated transcription §3.1 now agrees with architecture §3 and the schemas. There is one canonical EngineRef for raw and stored transcripts, with `id`, `modelId`, `modelSha256`, `engineVersion` and `locale`; no duplicate engine model is retained. All required nullable project fields encode explicit null.
- **Estimated timing (resolved during scaffolding):** the updated editing §5.4 and transcription §3.1 agree that schema v1 has no `estimated` provenance. TimingSource mirrors the schema exactly. The estimation algorithm remains a throwing stub until its owner defines a non-persisted result or coordinates a schema revision; no v1 adapter uses it.
- **Folder drift:** AI spec's old VoxClipCore/AI path is superseded by architecture §2.1's Domain/Clips + Services/LLM and this ownership map. Native Apple ML remains in Media.
- **Name collision:** architecture §5.1 informally calls the native components CaptionRasterizer and Exporter, which are also Core protocol names. Concrete implementations are CoreTextCaptionRasterizer and AVExporter; their Core protocols keep the required names. There is still only one rasterizer and one frame compositor.
- **Settings schema supplied during scaffolding:** architecture §2.5's shared/schemas/settings.schema.json is now present. SettingsDocument uses its voxclip-settings/1 discriminator, flattens settings into the root and preserves unknown root keys. mac-editing owns applying the schema's typed settings and defaults.
- **Skeleton-only error:** architecture §10.2 has no notImplemented code, while this task explicitly requires VoxClipError.notImplemented(track). The extra code maps to unexpected-failure exit **1**, never success. Remove this transitional wire value once all tracks are implemented.
- **Runtime preset codec:** VideoCodec retains the future HEVC capability, but architecture §4.1 and ADR-R10 allow only H.264 output in M1. ExportPreset is derived runtime configuration, never persisted inside ProjectExport; the implementation must produce H.264 only.
- **Primitive scope:** model and project value initializers do not perform I/O. Full media processing, downloads, providers, cache eviction, logging sinks and update checks remain safe stubs, not claims of working M1 features.

### 2026-10-25 — Concurrent shared-schema reconciliation

- The shared schema and editing/transcription specs changed while this skeleton was being built. One canonical TranscriptEngine now follows the catalogue vocabulary (`elevenlabs`, `whispercpp`, `apple-speech`), not the earlier dotted identifiers; EngineRef lives in Domain/Shared and serves both raw and persisted transcripts. `PIPELINE_VERSION` is the named Core constant from transcription §3.1.
- ClipRange now persists the required `selected` checkbox (default true for newly created clips). Project now persists required `share.captions` through ProjectShare. Both are covered by the portable project fixture round-trip tests; no external schemas or fixtures were edited here.
- ProjectExport follows the reconciled schema (`aspect`, `quality`, `srt`, required nullable `folder`), not the earlier `presets`/`selectedPresetId` shape. Dimensions, bitrates and framing are runtime ExportPreset values derived from the source; M2 framing persistence requires a new schemaVersion.
- EditCommand includes the reconciled `addAIClips`, `renameClip` and `setClipSelected` operations. AI batches carry caller-prepared ClipRange ids so the reducer remains pure. mac-editing coordinates removed-clip share-caption cleanup at the Project layer, since EditState deliberately contains no publishing state.
- Editing alignment accepts timed RawWord values plus `finalText`; estimation accepts `text`, `start` and `end` and returns RawWord values without invented persisted provenance (editing §5.3–5.4). These are pre-import helpers, not mutations of an existing Transcript.
- The primary CLI export form uses ArgumentParser's default `export` subcommand (also callable explicitly). Keeping its options off the routing root prevents `--json`, `--open`, `--engine` and other overlapping flags from being consumed before their intended subcommand sees them. Parser usage failures map from ArgumentParser's exit 64 to the architecture's exit 2.

### 2026-10-25 — mac-ai injection and M2 integration

- Owner: mac-ai. Consumers: mac-ui and mac-media (CLI). The existing ClipFinder initializer already accepts an injected LLMRunner (KeyProvider, catalog and Redacting), and find accepts the caller's connector. HTTPConnector accepts KeyProvider, catalog, Redacting and an optional baseURL; CLIConnector accepts catalog, Redacting, ProcessRunner and an executable override. The legacy StubLLMConnector now also has an additive initializer accepting id, keys, catalog, log, optional baseURL and cliPath; its existing initializer is preserved for environment-backed discovery. Apple remains in VoxClipMedia and is never substituted with cloud.
- TODO(M2): TightenInput, TightenLineEdit, TightenProposal and the richer pure-deletion validation types remain internal until the M2 consumer contract is agreed. The existing public TightenEdit is unchanged.
- Round-three integration uses mac-editing's public toFixed1 in Domain/Editing for production and shared fixture checks.

### 2026-10-25 — mac-ai round-two review fixes

- Owner: mac-ai; consumers: mac-ui, mac-media/CLI, and mac-editing. Approved additive feature gate: `ClipFinderGateError.noWords(message:)` and `.needInstructions(message:)` carry the exact clip-finder prompt message through `userMessage`/`LocalizedError`, with no LLM error code or provider retry/logging (AI §11.1). Consumers should catch these before presenting connector errors; existing LLMError cases are unchanged.
- The existing public helpers are now indexed below: ClipPromptDocument, ClipRequestBuilder, ClipWindow, LLMConnectionTestResult, LLMEnvironmentKeyProvider, LLMTokenCounting, AIText, AIHash and CLIConnector.Detection. JSONValue's ai-prefixed convenience members are internal implementation details, not additions to the frozen common JSONValue contract; AI tests use testable imports.
- Additive runtime configuration: ClipRequestBuilder accepts optional catalog `policy`; windows accepts `localServer` (default false); ClipWindow carries optional `maxOutputTokens`. FinalizeClipsOptions accepts optional prompt `limits` (default null, omitted from its encoded value when absent). Existing calls retain their defaults. ClipFinder supplies the shared prompt limits and catalog policy, and opts only Ollama/LM Studio into AI §11.5's local reserve clamp. M2 TightenRequestBuilder remains internal.
- StubLLMConnector's injected initializer accepts optional `cacheURL`, defaulting to the existing data cache; tests pass nil. Round-four review supersedes the earlier TLS/loopback override rule: authenticated HTTP connectors always use their catalog base URL. LLMError.userMessage adds optional `cli` and `includeEditsSaved` parameters; picker labels remain distinct from CLI names, and nested status reasons omit the reassurance so it appears once.
- CLI Settings consumers explicitly call the existing `detection(refresh: true)` API. Ordinary status uses fingerprint-cached capabilities, still checks sign-in, and gives the immediately following send one short-lived, single-use auth preflight result. The nonthrowing ConnectorStatus contract is unchanged: cancellation has an empty unavailable status at the connector boundary and the runner checks task cancellation immediately after awaiting status, returning LLMError.cancelled without a provider failure.
- FoundationModelsConnector adds `init(log:)` for an injected redacting sink; its existing default initializer remains. CLI and Apple generation attempts emit metadata-only redacted lines (AI §4.9). Connection Test always carries English and uses the catalog Test timeout, including Apple (30 seconds).
- Live tests require `VOXCLIP_LIVE_TESTS=1` AND the connector's VOXCLIP API-key variable, or the narrower switch `VOXCLIP_LIVE_CLI=1`, `VOXCLIP_LIVE_OLLAMA=1`, or `VOXCLIP_LIVE_FM=1`. `VOXCLIP_LIVE_OLLAMA_MODEL` selects an already installed local model. Keys or narrower switches alone never enable calls. This review round permits only explicitly opted-in local Ollama; no other live tests were run.
- Shared fixture suites fail, rather than skip, when an explicit VOXCLIP_SHARED_DIR lacks fixtures/llm. Round-four review restores source-relative discovery when that variable is unset; golden suites skip with a reason only when no shared/ directory is selected or found. Shared data and doc/spec files remain lead-owned and were not copied or modified.
- Resume verification on 2026-10-25 also requires the filtered pure-golden test to fail independently: unreadable required files retain a failing test case instead of disappearing from its argument list. No public API changes are introduced.
- Attempt-three verification on 2026-10-25 extends that fail-closed loader to missing, malformed or empty `cases` arrays, with regression tests for unreadable files and stable filtering/order. A filtered pure-golden run must not pass with zero cases from an explicitly selected invalid corpus (AI §13.1); valid connector-only fixtures remain owned by their connector suites. No public contracts change.

### 2026-10-25 — mac-ai round 3: M8 and M9 contracts

- M8 now exposes `LLMCatalog.load(shared:) throws -> LLMCatalog` and `LLMConnectors.make(_:catalog:keys:processes:settings:) -> any LLMConnector` (plan §4.1.2). The factory honors configured local base URLs only for Ollama and LM Studio (AI §8.2), CLI executable overrides, injected keys/processes, and disabled catalog entries. Cloud connectors always use the catalog base URL; HTTPConnector also ignores overrides whenever the catalog declares `auth.keyAccount`. Apple returns `StubLLMConnector(id: .appleFoundation)`; native callers still select VoxClipMedia's FoundationModelsConnector explicitly.
- M9 changes `ClipFinder.find(_:connector:model:) async throws -> ProjectAIResult`. The returned value owns the new schema-valid id, creation date, connector, answering model (preferring an answering fallback), normalized instructions, language, full corrected transcript hash, and ordered clips resolved to word ids (AI §11.8). `lastRun` and ClipFinderRunSummary are internal diagnostics only.
- Consumer action for mac-ui: InspectorView must use the returned ProjectAIResult instead of building its own result, computing a hash, or storing the selected model/raw instructions. Load catalogs and create connectors through M8; keep the Apple native-connector special case.

### 2026-10-25 — mac-ai round 4: fallback footer state

- Additive contract for mac-ui: `ClipFinder.lastUsedFallback: Bool?` has read-only public access, without changing M9's find signature. It is nil before a run or after failure, false after a successful primary-model run, and true after a successful run using a fallback. Each find resets the previous value. When true, render AI §4.3/§11.8's footer: "Answered by {fallback} because {model} was busy.", using the returned answering model and the requested model. Do not infer fallback use by comparing model ids.

### 2026-10-25 — mac-ai round 4: schema-valid answering model

- M9 normalizes an empty answering model or one exceeding project.schema.json's 128-Unicode-scalar limit to the requested model id. This applies after choosing the fallback or last-window model (AI §11.8); the requested id already obeys the settings schema. Integration tests persist both invalid-provider cases and their referencing AI clips through JSONProjectStore.

### 2026-10-25 — mac-ai round 4: local settings and rejection copy

- Local 401/403 failures use the complete sentence "{label} rejected the request ({status})." before the standard " Your edits are saved." suffix. Status, Test, and send regressions cover both local connectors and both codes without suggesting an API key.
- Copy as specified in AI §5 (main e170871): "{label}'s server address in Settings isn't valid." An unusable local base URL (credentials, query, fragment, non-HTTP scheme, missing host, or parse failure) is an unavailable settings error, never a provider rejection with invented HTTP status 0. The factory and direct HTTPConnector initialization share this copy; tests assert the exact reason and reassurance without provider calls.

### 2026-10-25 — mac-ai round 3: shared editing primitives

- Pause labels and AI rounding fixtures now call Domain/Editing's public `toFixed1`; the temporary duplicate is removed. Clip scoring uses `EditingPrimitives.jsRound`. AIText.trim remains a source-compatible forwarding alias to `EditingPrimitives.jsTrim`, and tightening tokenization calls `EditingPrimitives.splitWords` directly. AI §11.9 and editing §4.3 use the same whitespace set; there is no semantic difference or remaining merge adapter in mac-ai's folders.

### 2026-10-25 — mac-ai round 3: local authentication status

- HTTP `.needsKey` status is reserved for catalog entries with `auth.keyAccount`. Ollama/LM Studio 401 and 403 responses preserve their HTTP status in `.unavailable(reason: "{label} rejected the request ({status}).")`, which maps to providerError rather than keyMissing (AI §5). Status, preflight, generation, and redacted user-copy regression tests cover both servers and both HTTP codes without live calls.
- All cloud status entry/fallback paths also require `auth.keyAccount` before reporting `.needsKey`; missing auth metadata is an unavailable configuration, not an instruction to add a key. Regression tests remove the account from each cloud provider while retaining its valid endpoint.

### 2026-10-25 — mac-ai round 3: CLI status copy

- CLI detection failures now use AI §5's cliFailed/timeout copy, with the CLI name distinct from its picker label, registered-secret redaction, and no embedded edits-saved reassurance. Missing, signed-out, too-old, and silent cancellation statuses keep their existing typed cases. Fake authentication probes cover exit 2 and thrown timeout/cliFailed on both CLIs; no real CLI or provider is called.

### 2026-10-25 — mac-ai round 3: preflight diagnostics

- Find/prepare status gates and ordinary LLMRunner failures share one case/code/user-copy logging and redaction path (AI §4.9, architecture §11). Each failed gate emits exactly one llm error entry; cancellation stays info-level and silent. Input-only feature gates still emit no provider error. Regression coverage checks missing keys, stopped local servers, registered-secret redaction, ordinary runner preflight, and existing cancellation paths.

### 2026-10-25 — mac-ai round 3: process timing verification

- ProcessRunner lifecycle tests are serialized and use loaded-machine headroom without weakening their regressions (AI §6.10). Escaped-pipe timing starts before task creation, checks readiness/completion order, and allows six seconds for escalation/drain. Successful leader exit has a ten-second request deadline but must finish within two seconds; TERM-responsive timeout checks the deadline lower bound and a two-second upper bound.

### 2026-10-25 — mac-ai round 4: source-relative fail-closed golden corpus

- All pure, HTTP, CLI, and Apple golden suites use VOXCLIP_SHARED_DIR when set; otherwise they walk from #filePath to the repo's shared/ directory (architecture §2.4 and the shared LLM fixture README). They skip with a reason only when neither selects or finds shared/. Any selected path (including an empty override) is authoritative: missing directories/files, unreadable or malformed data, and empty case lists fail instead of falling back or producing zero-case success. A discovered shared/ without its corpus fails too. The valid corpus remains shared-owned and is never copied into an app or test bundle.
- Unset full-suite verification also checks the unchanged M8 Apple stub without assuming runtime resources are discoverable from Swift Testing's executable. Its factory test permits only the existing `VoxClipError.sharedResourcesMissing` bootstrap error in addition to LLMError, and only for Apple; all injected key/process providers must remain unused. Production Apple routing is unchanged.

### 2026-10-25 — Caption implementation integration proposal (superseded)

The accepted round-3 entry point below supersedes this proposal's integration guidance.

- **Affected tracks: mac-captions, mac-media and mac-ui.** Caption sizing implements the current captions §5.3 and ADR-R16: `font.sizeRef` defaults to `shortEdge`. All 86 authoritative layout fixtures agree. No shared data or fixed signature changed.
- `CaptionLayoutEngine.build(input:style:resources:shaper:)` is the complete caption entry point. Supply the already edited, corrected caption copy, its language and duration, and the export frame size. `CaptionResources` is decoded from caller-supplied data; Domain does no I/O. Media loads it through `SharedResources`. Retain the returned immutable `CaptionLayoutResult` for both preview and export; `track` projects the older lightweight `CaptionTrack` for compatibility but does not retain emphasis, emoji or shaping.
- **Coordination required:** the frozen synchronous `CaptionTrack.build`, `CaptionPager.pages`, `CaptionLineBreaker.lines` and `CaptionPlacement.place` signatures cannot express the normative pipeline: they lack output dimensions, manifest metrics, case map/language, injected asynchronous shaping, and/or resolved emphasis/emoji. They remain source-compatible and fail explicitly with `CaptionFailure.missingContext`, rather than invent metrics or perform Domain I/O. Migrate their callers to the complete entry point; a future contract revision may retire these seams. The existing easing seam is implemented; text transformation also has an additive language/resources overload.
- `CoreTextCaptionRasterizer.rasterize(_:time:previewWidth:reduceMotion:)` consumes the complete layout without reflow. The page-only protocol works after `prepare(_:)` with that same complete layout and rejects unprepared/mismatched snapshots rather than silently relaying out a page. `CaptionRaster` stays premultiplied **RGBA** as frozen; `composite(into:)` blends it into a locked **BGRA** `CVPixelBuffer`. A compositor must retain the complete layout, not reconstruct it from a lightweight page. `CaptionRenderHarness.renderCase(at:sample:out:)` and `renderTiles(at:out:)` implement the three render-caption library forms, reading only sample times/golden flags from expected metadata, never expected geometry or shaping. Command parsing and compositor wiring remain mac-media-owned.
- Invalid project patches are rejected as a whole and fall back to the aspect-resolved built-in style. `CaptionStyleResolver.resolution` exposes `rejectedOverrides` so mac-ui can show the specified inspector message. Strict decoding requires `text`, as both schema.json and captions §2.2 (main fb11d5f) specify; a patch that deletes it is rejected.
- Frozen smoke-test files were not modified. Fixture/font/style assets are read-only. Until this branch merges, verification sets `VOXCLIP_SHARED_DIR=<worktree>/shared`, which includes this branch's committed goldens; main's pre-merge shared directory does not.
- **Fixture precision resolved in round 6:** main `fa50bc1` writes full-precision easing vectors with exact endpoints. `captionMathFixtures` now checks every easing vector within 1e-9, including `easeOutBack(1.70158)`, per captions §16.3; the temporary quantization exception is removed.

### 2026-10-25 — Caption integration acceptance (round 3)

- Lead decision 1 accepts `CaptionPipeline.init(shared:) throws` and `layout(words: [CaptionWord], language: String?, style: CaptionStyle, position: CaptionPosition?, frame: PixelSize, duration: Double) async throws -> CaptionLayoutResult`. Editing §7.6's `captionCopy` returns exactly `[CaptionWord]`. Styles are already resolved: the pipeline does not reapply aspect overrides. It loads resources once and retains a caching CoreTextShaper.
- **Approved frozen change:** `Domain/Shared/MediaContracts.swift` adds `RenderRequest.captionLayout: CaptionLayoutResult?` and the trailing initializer argument `captionLayout: CaptionLayoutResult? = nil`. Existing calls compile unchanged. mac-media must draw only this complete snapshot; legacy captions/style/placement fields are not rendering input. mac-ui and mac-media migrate at integration, not in this owned track.
- `CaptionLayoutResult` is Equatable and Sendable, projects `track` for compatibility/SRT, exposes half-open `page(at:)`, and reports `dropped` words with sourceIndex, text and reason `empty`/`no-glyphs`.
- The four frozen synchronous seams and the three-argument `CaptionTextTransformer.apply` are deprecated with a `Use CaptionPipeline.layout` message and continue throwing. Removal belongs to the lead after callers migrate. The page-only raster protocol requires `prepare(layout)` and `request.style == layout.style`; one slot serves one layout per rasterizer.
- `CoreTextCaptionRasterizer.draw(_:time:into:previewWidth:reduceMotion:) throws` is the concurrent-frame entry point for real BGRA pixel buffers. `CaptionRaster` remains premultiplied RGBA (captions §13.1); no straight-alpha CGImage wrapper is permitted.
- Strict decoding requires `text`, as both schema.json and captions §2.2 (main fb11d5f) specify; a patch that deletes it is rejected.
- String length limits count Unicode scalars as JSON Schema requires. Tags enforce unique valid items; fallback filenames and emphasis palette entries enforce their referenced schema patterns as well as array bounds (captions §2.4).
- Historical WIP commits are not rewritten: the lead will squash them on merge (decision 5).
- **Fixture precision clarification:** `limitPx` is serialized to three decimals by the shared reference. Its comparison permits only the 0.0005 px rounding interval, not the general 0.5 px geometry tolerance. The resolved fractional fields remain within 1e-9, integer fit limits remain exact, and unlisted numeric fields have no tolerance (captions §16.3). Default fixture assertions do not write fixed temporary files.
- The accepted draw entry point is nonisolated and leases renderer-local scratch surfaces for concurrent frames. Static page overlays use a lock-protected LRU capped at 64 MiB per window, keyed by the complete layout, page, preview scale, active word, revealed cluster counts and Reduce Motion state. The round-4 entry below supersedes the original blanket exclusion of animated states. Default tests cover the real RenderRequest/BGRA path and concurrent cached draws without full-frame raster allocations; the release performance test measures all 19 portrait style families (captions §13.8–13.9).
- ZWNJ scalars split CoreText substitution spans without splitting the caption run. Cached GPOS/legacy kern adjustments are reapplied across that boundary, so ZWNJ blocks ligatures but not kerning, matching HarfBuzz. The cascade's ignorables are hidden before CoreText even when mapped (CoreText otherwise loses kerning across mapped ZWNJ), then reinserted as zero-advance space glyphs with their original grapheme clusters. Per-word no-glyphs failures become `dropped` entries (captions §4.3–4.5).

## 2026-10-25 — round-2 mac-ui content identity adapter

Round 3 removes the temporary SourceIdentity adapter. Imports and Locate use
`JSONProjectStore.contentKey(for:)` off the main actor; resolution delegates to
the app's injected `JSONProjectStore.resolveSource(for:projectURL:)`, absolute
first as editing §10.3 requires. The six shared content-key fixtures exercise it.
VoxClipDocument uses `decodeReportingWarnings`, reports cleanup through app.log,
and saves with `encode`, `relativePath(source:projectURL:)`, current savedBy and
modifiedAt (editing §10). Editor commands use `EditHistory.apply(_:aiResults:)`
and `projectEdits`, with native undo capped at 500 actions. Successful duplicate
AI runs are retained even when no range is added. The UI still prepares
ProjectAIResult until `ClipFinder.find(_:connector:model:) -> ProjectAIResult`
lands with mac-ai M9; captions and media seams remain TODO(merge).

### Round-2 production editing handoff

All clip operations now dispatch the frozen `EditCommand` cases. There is no
DEBUG reducer, pause detector, planner, or time mapper. Self-tests use a
production document with main's editing core after the round-3 merge.
The UI reads `EditState.summary` directly, builds canonical `EditPlan` values,
and replaces transcripts through `Project.replaceTranscript`. Fillers delegate to
Core's `isFillerText` using corrected word text and explicit word kinds.

## 2026-10-25 — mac-ui integration proposals and handoff constraints

No frozen protocol or portable wire signatures were changed. The app calls the
existing reducer, transcription, caption, model, preview and export contracts.
Throwing services remain visibly unavailable, not simulated successes. Only
DEBUG fixture documents use the synthetic in-memory preview; edit commands still
go through the production reducer.

Coordination requested before the following production integrations:

- **Lead / design tooling:** `tools/design` is absent in both the main checkout
  and this worktree. The mandated token generator cannot be run within mac-ui's
  ownership. No hand-authored `Tokens.swift` or replacement generator was added.
  `DesignValues` reads the canonical tokens and font manifest at runtime until
  the lead supplies the generator; replace that adapter with generated helpers.
- **mac-ai + mac-ui:** expose the concrete connector factory accepting the
  catalogue, settings snapshot, `KeyProvider` and `Redacting` dependencies.
  `LLMConnector` exists but only `StubLLMConnector` is constructible here. The app
  deliberately reports unavailable status. CLI rows detect executables without
  reading sign-in tokens; version/sign-in probes await the connector owner.
  Any future keyed network connector must use an ephemeral URLSession without
  URLCache, cookie storage or credential storage, like the ElevenLabs Test action.
- **mac-ai + common:** `ClipFinder.find` returns suggestions only. Persisted
  results also require the actual answered model (including fallback) and the
  full-take cached-block hash. The UI computes the latter using `formatTranscript`
  and the shared prompt wrapper, but cannot recover the answered model. Propose
  a result envelope with suggestions, answered model and input hash; migrate the
  app's persistence adapter atomically with that contract revision.
- **mac-speech + mac-ui:** expose the routed import decision, language-detection
  readiness, supported Apple locales, recommended model ID and download sizes.
  The current picker can query adapter readiness but cannot implement the full
  automatic-routing decision from the frozen contracts. Also pass the selected
  ElevenLabs region through its constructor/request; only keys are accepted now.
  The UI's free subscription Test uses the selected regional host. Auto detection
  and ready-engine automatic import need integration after the routing API lands.
- **mac-captions + mac-ui (lead decision, 2026-10-25):** the frozen caption
  builder/pager/line-breaker/placement/three-argument text-transform seams are no
  longer called by the UI. The AppModel-owned `CaptionHandoff` is the single
  pipeline merge point. Its layout input carries the EditState, CaptionSettings,
  EditPlan, OutputSpec, language and style. Tile input also carries source sample
  words, state/plan, language, frame, overrides, placement and source still time.
  Captions-off requests use an empty track. Selected captions report unavailable
  in preview and fail export rather than silently exporting without captions.
  At merge, resolve the style with
  `CaptionStyleResolver`, use its `resolution.rejectedOverrides` for the settings
  warning, call `CaptionPipeline.layout` with the editing caption copy, and fill
  the lead-approved additive `RenderRequest.captionLayout` for preview and
  export. Gallery rasterization must use the prepared layout overload of
  `CoreTextCaptionRasterizer`; show `CaptionLayoutResult.dropped` in the inspector.
  These new symbols are not yet present in this worktree; no local duplicate or
  substitute renderer was introduced.
- **common / publishing + mac-ui:** architecture §2.1 assigns share text rules to
  `Domain/Publishing`, but the scaffold has no such contract. The current UI-only
  adapter supplies safe HTTPS intents, counts and truncation. Move it behind the
  common fixture-backed publishing API when provided; exact twitter-text URL and
  emoji edge-case parity remains unverified.

Normative design decisions retained: the inspector's AI tab stays hidden in M1
(design §6.3), despite the broad implementation brief listing it; manual clips
always need no connector. Round 3 restores the five design §10 Settings panes
at 600×480: General, Transcription (including Models), AI, Export and About.
Accounts remains hidden until M2. LAN ingest is M2,
so no local-network permission was added. Info.plist includes AppIcon and the
speech/camera/microphone purpose strings requested by mac-release.

## Round-2 verification boundary

Word states now use TextKit 2 rendering attributes and indexed spans, without
mutating backing storage on cuts or playhead ticks. Corrections replace only the
changed paragraphs. Timeline geometry is a cached projection with hash-set cut
lookups; static drawing is separated from the playhead and scrub lookups are
binary searches. Round 3's synthetic 10,000-word harness records the production
EditHistory-to-TextKit path with 2,000 initial cuts, plus offscreen scrolling CPU
timings. Timeline mapping uses cut prefix sums checked against Core's mapper.
These are offscreen CPU measurements, not proof of physical 60 Hz delivery.
The latency budget uses an optimized app with the DEBUG offscreen entry points:
`swift build -c release -Xswiftc -DDEBUG`. Set
`VOXCLIP_UI_PERFORMANCE_EXECUTABLE` to that build's VoxClip executable when
running the opt-in Swift tests; ordinary self-tests and demo captures still use
the adjacent Debug app. The benchmark records assertion configuration in its
scope and applies 30 distinct word toggles, rather than alternating one cached
state. Unoptimized Debug timings remain diagnostic, not product latency evidence.
Core summaries have a bounded recent-state cache, and word-only cuts reuse
Core-built segments; regression checks compare both projections back to Core.

The production mac-editing reducer, planner, pause/filler functions and
`EditState.summary` are merged and exercised by the offscreen assertions.
There are no local reducer/planner copies. CaptionPipeline, CaptionLayoutResult and the
additive RenderRequest.captionLayout are also absent; the typed handoff above
retains the inputs but does not pretend to prepare a layout.

Toolbar probes capture enabled and disabled native Export controls in both
appearances. Key-window and app-active inputs are simulated only in DEBUG;
the process remains prohibited from activation. Pixel probes measure label-to-
bezel contrast and verify distinct key/inactive captures. Physical display
delivery still requires an unlocked session. Evidence is stored as small JPEGs.

Offscreen app tests are opt-in with VOXCLIP_UI_TESTS=1, use an adjacent executable
or VOXCLIP_APP_EXECUTABLE, and use a native Process deadline, not coreutils.
VOXCLIP_UI_EVIDENCE_DIR retains named screenshot/report folders; otherwise tests
remove scratch. Test processes suppress scene presentation and activation, use
isolated data, disable restoration/split autosave and never read Keychain keys.
Only view caching is used: no screencapture permission or unlocked screen needed.

Remaining acceptance work beyond integration: full VoiceOver word-state speech
and RTL traversal, still-backed caption thumbnails and live caption layouts,
cloud-engine routing/cost details, structured error metadata for model size,
language/engine and disk-space requirements, and release-bundle end-to-end
media/export verification. Frozen String-only errors cannot reliably reconstruct
those missing fields; no raw Core localizedDescription is shown.

### 2026-10-25 — mac-media implementation and integration notes

- Native export drains audio and video independently under the exporter actor. Awaiting a timestamp-interleaved append deadlocked the writer's interleaver; finalization waits for both receiver finishes. No additional unchecked Sendable boundary was introduced.
- Stress verification also exposed the SDK provider's synchronous copyNextSampleBuffer inside its async next(): concurrent exports could exhaust the cooperative thread pool and starve caption work. Decoder pulls now use a dispatch TaskExecutor preference, with exclusively transferred pump inputs, so the exporter actor stays responsive to cancellation. Swift 6 checks these transfers; no unchecked Sendable boundary was added.
- SIGINT verification found two cancellation defects: the dispatch signal handler inherited main-actor isolation despite its global queue (fixed with an explicit Sendable handler), and a suspended SDK receiver.append could remain unresolved after cancelWriting (fixed with independently paced appendImmediately loops and cancellable 1 ms backpressure waits). Native partial files are deleted and CLI cancellation returns exit 6 with one JSON object.
- Internal temporary-path refinement for architecture 5.6: the writer still uses an MP4 `.partial` file, now inside a uniquely owned hidden sibling staging directory rather than directly beside the destination. This SDK left `.partial.sb-*` staging siblings after cancellation even when cancelWriting returned. Removing only the owned directory cleans all native scratch files without glob-deleting unrelated user files; final publication is still an atomic same-volume rename. No public API or JSON contract changed. The regression preserves an unrelated similarly named file.
- The post-effects tap uses the returned source time range on every callback, never a running counter. At rate 2, AVPlayer can return fewer frames than the range's edited-time sample count. The callback therefore scales frame offsets by range duration / frame count; normal-rate reader export remains exactly one edited sample per frame. Seek/rate tests cover this native scheduling difference.
- Clip-edge join coordination: the tap's binary search accepts a leading join at sample 0 and a trailing join at outputSamples; a zero-length side applies no fade and never divides. A rendered head-and-tail-cut single-part regression asserts exact silence at both clip edges and the 5 ms ramps. The rate-rescaling regression covers these same edge entries at 44.1 → 48 kHz. No mac-editing logic or signature was changed.
- The frozen MediaContractTests.swift probe assertion alone now expects mediaMissing("no-video.mov") instead of notImplemented("mac-media"). All other frozen assertions and public signatures are unchanged.
- Test media is generated on demand using AVFoundation inside the owned Pipeline test folder's generator; no binary fixtures are committed outside track ownership. Shared canonical media and tools/fixtures/media are lead-owned and still need integration.
- BT.709 code-value validation uses native NV12 decoding with the explicit limited-range 709 matrix, not a display-managed RGB conversion. The bars fixture supplies known NV12 values with high-quality H.264 High input to avoid compounded fixture quantization, and exports at the specified 8 Mbps preset. The compositor disables Core Image working-space conversion for orientation/crop/scale and tags its buffers as 709; otherwise repeated transfer conversions shifted bar values on export. Caption blending remains gamma-encoded sRGB. All eight exported 75% bars are within ±3 code values.
- H.264-only M1 output follows architecture 4.1, 5.6 and the existing runtime-codec decision above. The task's broader HEVC-output request conflicts with that decision; HEVC Main 10 input is covered, but enabling HEVC output needs a coordinated OutputSpec codec field and preset policy.
- Lead-approved caption integration (mac-captions, mac-media, mac-ui): CaptionPipeline.layout consumes editing §7.6's caption copy, resolved style, placement, frame size and duration. mac-captions adds the trailing default-nil RenderRequest.captionLayout field; no frozen RenderRequest declaration is edited in this track. CoreTextCaptionRasterizer.draw(layout, time:into:previewWidth:reduceMotion:) draws the caption band into a locked BGRA buffer with premultiplied RGBA internally. Deprecated CaptionTrack.build / CaptionPager / CaptionLineBreaker / CaptionPlacement / three-argument CaptionTextTransformer are no longer called by the media or CLI paths.
- Caption merge is isolated behind exactly two TODO(merge) adapter functions: FrameCompositor.drawCaptions and CLIWorkflow.captions. The former retains the existing injected test-only rasterizer path until the direct-draw API merges; pixel buffers remain on the render queue, with no new unchecked Sendable boundary or new straight-alpha implementation. The latter carries the render request, transcript and corrections for the editing caption-copy / CaptionPipeline swap, and fails explicitly rather than pretending nonempty captions were rendered. These APIs are not present in this worktree, so real-caption acceptance remains deferred to integration.
- The same CLI adapter dispatches render-caption to CaptionRenderHarness.renderCase(at:sample:out:) / renderTiles(at:out:). These calls are compile-gated with VOXCLIP_CAPTION_PIPELINE solely until the harness merges; remove the interim gate at integration. There is no second CLI shaper, pager, layout model or PNG renderer. Non-normative --style / --layout-out overrides now report usage exit 2 instead of silently bypassing the harness, which owns fixture styles and layout output paths. Missing/ambiguous case-versus-tiles choices and invalid sample combinations also report exit 2.
- CLI video-only proposal (lead): architecture 9.1 says to transcribe bare media, while 9.5 exports counter/big/bars fixtures without transcripts. A video-only --style off mode should be agreed before silently bypassing transcription. Until then pass a stored (possibly empty) Transcript to those exports.

### 2026-10-25 — mac-media final verification

- On Apple M3 Max / macOS 27.0.1, bounded `swift build` passed in 2.22 s command wall (Swift-reported build 0.27 s), and bounded `swift test` passed in 20.94 s command wall: 39 Media declarations and 18 Core declarations, 51 passing and 6 skipped. Skips are the five other-track placeholders and the opt-in benchmark; parameterized CLI acceptance additionally exercises three native fixtures and six invalid harness argument combinations. The opt-in 60-second native benchmark was also run separately and passed (5.439 s export).
- A fresh bounded `swift run voxclip-cli export` of generated 60-second 1920×1080 media with a stored empty transcript, captions off and portrait framing took 5.4997 s inside the exporter / 6.57 s command wall. Bounded ffprobe verified playable MP4, H.264 High at 1080×1920 / 30 fps / 1,800 frames / 60 seconds, BT.709 primaries+transfer+matrix and AAC-LC stereo at 48 kHz. This is faster than §14's 15-second numerical target on this M3 Max, not a base-M1 or real-caption acceptance claim. No FFmpeg libraries are linked to the CLI; ffprobe is a verification-only external tool.
- Native coverage includes sample-exact cuts, leading/trailing clip-edge silence and zero-length fade sides, AVPlayer seeking/rate changes, 17-cut chirp alignment within 48 samples, 59-join alignment, caption interval/failure doubles, 1080p cap, all crop aspects, frame barcodes, ±3-code-value BT.709 bars, Main10 HEVC with two AAC tracks, unsupported containers, progress throttling, exporter queue cancellation, SIGINT exit 6 and scratch cleanup. All fixtures are generated on demand; zero media bytes are committed.
- Remaining acceptance work belongs to the integration/hardware pass: actual editing caption-copy and CaptionPipeline/direct-draw/harness swaps; canonical filler/caption CLI cases and real transcriber/LLM paths from the other tracks; base-M1 timing; a 60-minute memory run; and an encoded HDR/tone-map fixture (the generated Main10 fixture is SDR). HEVC output and transcript-free video-only CLI semantics remain the explicit coordination questions above. Verification logs and playable benchmark outputs are retained under /tmp/voxclip-mac-media-resume, outside the repository.

### 2026-10-25 — mac-media review fixes, export safety

- Supersedes the earlier cancellation claim: reader teardown now happens only after both pumps have joined. Cancellation and pump errors stop the writer; stopped pumps drain until their sibling finishes. The regression cancels after an actual encoding callback, and the CLI stress test sends 50 randomized SIGINTs to a 60-second 1080p export.
- Destinations are checked before graph construction and again before publication; only regular files can be replaced. CLI usage exit 2 rejects folders, input overwrites and overlapping outputs before probing or transcribing. Run-time and parse-time usage failures produce the same JSON error when requested. JSON success output requires --json, and SRT output requires --srt.
- The owned staging directory is now the visible, exclusively created <destination>.partial. SDK scratch files stay inside it; cancellation removes it, and a crash leftover prevents silent reuse. Errors retain redacted native domain/code chains; AVFoundation, Cocoa and POSIX full-disk errors map to diskFull.
- Video writer timestamps use a 600 Hz frame grid, independent of source audio; the frame count is round(duration × fps). Edited WAV verification checks the unpadded decoded count. Tests no longer depend on Homebrew timeout, and generated fixtures/intermediates are removed at process exit/after muxing.
- Corrected the type index after the earlier exporter/preview file moves. The undocumented extract-audio command and its unused helper have been removed. Version uses the lowercase macos platform identifier.

### 2026-10-25 — mac-media resumed review, resampling

- Audited the checkpoint's equal-weight Float32 downmix, normal converter priming, Int16 rounding, four-edge crop checks, and held-last-frame video tail. Generated stereo/right-only, six-channel, and 20 ms / 500 ms overhang regressions pass.
- The export audio pump now bounds its 48 kHz PCM to round(plan.duration × 48000), appending explicit silence for the resampler's short tail. This corrects the measured 17-sample (44.1 kHz) and 25-sample (32 kHz) deficits. The sample-rate-native edited WAV still verifies the actual decoded count without padding. Architecture sections 5.3, 5.6 and 9.5 govern these distinct counts.

### 2026-10-25 — mac-media resumed review, caption seams

- Supersedes the earlier caption-adapter payload note: CLIWorkflow.captions now receives the effective EditState (including stored edits), resolved active ClipRange, project caption overrides, and language. Its M7-gated body calls editing captionCopy/buildSegments, resolves the style, and invokes CaptionPipeline.layout. The harness is constructed once per command and its instance methods are awaited.
- CompositionBuilder creates one concrete CoreTextCaptionRasterizer per builder. PreviewPlayerController retains its builder across loads and instruction-only updates. Instructions retain that concrete rasterizer for synchronous M7 draw(into:); optional legacy protocol injection remains solely for existing test doubles. No default production caption path depends on injection.
- SRT filters invisible pages, preserves line breaks, and numbers the remaining cues consecutively. Once M7 lands, CaptionSubtitles.srt(layout) preserves transform-none/punctuation-keep source text using the burn-in's exact page grouping, instead of serializing transformed layout.track text. The current plain-track writer expects untransformed text. Real M7 rendering remains untestable until the other tracks' APIs merge; no caption implementation was copied into this track.

### 2026-10-25 — mac-media resumed review, remaining boundaries

- Cancellation no longer races cancelWriting against finishWriting. After the joined pumps and final drain delay, the writer leaves the active-cancellation slot; finalization finishes before a late cancellation is reported. A cancellation from the finalizing callback is checked before finalization starts. Preparing/finalizing regressions and overlapping preview rebuilds cover the phase boundaries.
- Shared export presets now also exercise the implicit full-frame crop used in production for odd source dimensions. Both affine preview and Lanczos export assert all four colour-bar edges. Original native export errors survive cleanup, and edited-audio setup errors use the same disk-full/encoder mapping.
- Default Whisper selection filters installed catalog entries by engine, model-file role and requested language before audio extraction. Speech catalog/store implementations remain external-track stubs. Metadata-only caption state avoids deriving uncut pauses; stored pause cuts still force derivation. CLI identity exports cover empty and nonempty stored transcripts.
- The opt-in CLI_FFPROBE check uses VOXCLIP_MEDIA_FFPROBE, generates 60-second native 1080p media and verifies a real portrait CLI export. Generated fixture directories are removed at process exit, and both this check and the opt-in native benchmark delete their exports immediately after checking them.
- A repeated suite exposed a test-only two-code-value H.264 colour difference in a held frame. The overhang fixture now carries a complete compact frame barcode: every tail frame must decode to the final source frame, while colour comparisons use the existing three-code-value BT.709 tolerance rather than bit equality across lossy re-encoding.
- A later stress run exposed a watchdog timeout. Writer cancellation is now single-owner, stopped pumps cannot finish writer inputs, and sibling completion is checked before requesting another sample. The input-finish/stop transition is protected by the shared pump mutex; reader cancellation still occurs only after both pumps join.

### 2026-10-25 — mac-media round-two final verification

- Supersedes the earlier verification counts: bounded `swift build` passed, and bounded `swift test` with the CLI ffprobe check enabled passed 73 declarations (67 passed, six skipped). Media: 55 declarations, 53 passed; Core: 18 declarations, 14 passed. Skips are the five other-track placeholders and the opt-in native benchmark. Logs: `/tmp/voxclip-mac-media-2b-verified-build.log` and `/tmp/voxclip-mac-media-2b-verified-full-test.log`.
- After the writer-handoff fix, the dedicated SIGINT stress check and the final full suite each completed 50 randomized 0.05–1.2-second interrupts against generated 60-second 1080p media: 100/100 exit 6, valid cancellation JSON, no output or partial scratch left behind, and unrelated similarly named files preserved. The dedicated log is `/tmp/voxclip-mac-media-2b-stress-final.log`.
- All ten final media-suite repetitions passed: 52 declarations per run, 51 passed and the mac-ui placeholder skipped. Stress, CLI ffprobe and native benchmark are excluded from these repetitions. Logs: `/tmp/voxclip-mac-media-2b-final-repeat-1.log` through `-10.log`.
- The real CLI portrait export probes as H.264 High, 1080×1920, yuv420p, 30/1 fps, 1,800 frames, 60.000000 seconds, BT.709 matrix/transfer/primaries, plus AAC-LC stereo at 48 kHz for 60.000000 seconds. Verification uses the existing non-GPL Conda ffprobe, not a shipped dependency. Generated media was deleted, no build trees were copied, no filesystem ENOSPC occurred, and free space returned to about 8 GiB.
- Integration still must replace the marked M5 sizing bridges and enable the M7 caption layout/direct-draw bodies after the caption/editing tracks land. Public OutputSpec.resolved remains source-compatible until that swap. Model catalog/store implementations remain speech-track stubs. Real captions, edit/filler CLI integration, live transcription, Windows, base-M1 performance, HDR tone mapping and long memory soaks are not acceptance claims of this verification.
### 2026-10-25 — mac-editing additive integration notes

- Owner **mac-editing**, consumer **mac-ai**: `public func toFixed1(_ value: Double) -> String` in `Domain/Editing/EditingPrimitives.swift` is the shared editing §4.4 / AI §11.3 primitive. It uses exact integer decomposition, not formatting or FMA. Existing signatures are unchanged. The editing label fixtures, AI §13.3 vectors, and a digest of 100,000 deterministic Node `toFixed(1)` outputs cover it.
- The owned Editing folder also exposes `EditingImport.cleanWords`, `.tightenIntoSound`, `.findUnlabeledSpeech`, and `.pipeline`. The mac-speech-owned free functions can delegate to these implementations; they are not rewritten by mac-editing.
- The original `cutRange` signature lacks the source duration needed for the last word's trailing reach. An additive overload takes `duration:`; `buildEditPlan` always supplies the authoritative duration. The original overload uses the last valid segment end as its inferred duration.
- `AudioEnvelope` has no exact source sample count. The refinement API infers analysis duration from `levels.count * (max(1, jsRound(sampleRate * 0.01)) / sampleRate)`; an additive `duration:` overload and `EditingImport.pipeline` accept the exact native duration, including a partial final frame. The envelope's `frameSeconds` hint is ignored (editing §5.1).
- `EditState` does not contain share captions. `Project.applyEditing` removes a deleted clip's share entry alongside the pure reducer; callers that keep share state separately must do the same.
- With explicit lead approval, the frozen baseline test is renamed `projectStoreRejectsMissingInput` and its former `.notImplemented("mac-editing")` assertion now expects `.projectUnreadable("Invalid project document")`. No other frozen test is changed.

### 2026-10-25 — mac-editing round 2: planner and real-time fades

- `FadePart` in `Domain/Editing/EditPlanner.swift` is the public Codable/Sendable part-table value (`outputStart`, `length`, `fadeIn`, `fadeOut`). `EditPlan.fadeParts` is now a stored, read-only derived table, built once by the planner or initializer/decoder and refreshed when its public source fields change. The table is not a new wire key; it is reconstructed from `kept`, `sampleRate`, and `totalSamples`.
- `EditPlan.joins` includes leading/trailing clip-edge joins as well as internal joins. Consumers binary-searching only joins now get the same gains as the allocation-free, binary-search `EditPlan.joinGain(at:)`. Source endpoints remain unfaded.
- `EditPlanner.swift` indexes speech rank, prefix-max ends, sorted starts and end/rank ties once per rebuild. `Tests/VoxClipCoreTests/Editing/EditingPerformance.swift` measures 10,000 words with 2,000 cuts (release median budget: 10 ms); adversarial range checks preserve the reference expression bits.

### 2026-10-25 — mac-editing round 2: save-safe reducer

- New public `EditingLimits` in `Domain/Editing/EditingContracts.swift` exposes `maxCorrectionScalars = 200`, `maxClipTitleScalars = 120`, and `clipIDPattern` (the project schema's ASCII id pattern). UI consumers must count Unicode scalars, not grapheme clusters. Reducer corrections, clip additions/AI batches and renames reject values outside these limits; the project validator shares the constants.
- Bulk operations and summaries resolve active-clip word bounds once per call. `Project.replaceTranscript` keeps the existing `pauseKeepSeconds` while resetting the threshold from the replacement's refined flag.

### 2026-10-25 — mac-editing round 2: project persistence

- `JSONProjectStore` in `Services/Project/ProjectStore.swift` adds `init(logger:)` (default: Core `RedactingLogger`) and `loadReportingWarnings(from:) -> (Project, [String])`. Both load APIs log every cleanup warning through `Logger`; consumers needing warnings must use the returned per-document tuple. `loadWarnings` remains only as a compatibility snapshot of the last load and is not a per-document reporting API.
- Save retains the newest ten AI runs overall, plus older referenced runs, ordered by `createdAt` with later array position winning ties. Filtering preserves stored order (editing §10.6, AI §11.8).

### 2026-10-25 — mac-editing round 2: settings recovery

- `JSONSettingsStore` in `Services/Settings/SettingsStore.swift` adds `init(logger:)`, `init(locations:logger:)` and a read-only `lastLoadError: VoxClipError?`. The frozen `init()` and `init(locations:)` signatures remain unchanged, as does `JSONProjectStore.init()`. Decode/schema/value failures move the original bytes to `settings.json.damaged-<timestamp>`, recover individually valid known and unknown keys when JSON parses, cache the recovered defaults-backed document, and log a static warning through Core `Logger`. No preference values are logged. Subsequent saves work normally; read/quarantine/write and invalid-encoding errors use `VoxClipError.projectUnreadable`.
- `SettingsDocument.validate()` now rejects update URLs unless their scheme is HTTPS and their exact host is `github.com` (and disallows embedded credentials). No settings wire keys were added. `Tests/VoxClipCoreTests/Editing/SettingsRecoveryTests.swift` covers corruption, partial recovery, concurrent loads, save/reopen and URL validation.

### 2026-10-25 — mac-editing round 2: conformance and API inventory

- `toFixed1` uses JavaScript-compatible exponent form for finite values at least `1e21`; the integer-only duration path is unchanged. `LevelAnalysis` derives native-rate frame size/length per editing §5.1 and ignores the envelope hint, including mismatches. Fixture `segmentCuts.rawStart/rawEnd` comparisons now require identical binary64 bits. The informative `caption-text` fixture is explicitly disabled with the editing §11.1 reason; unknown kinds still fail.
- Additional source files/types from rounds 1–2, beyond the frozen skeleton inventory (all writers/maintainers: **mac-editing**):

| File under `Sources/VoxClipCore/` | Public additions / boundary |
| --- | --- |
| `Domain/Editing/EditPlanner.swift` | `FadePart`; `clipTimes`, `buildSegments`, `cutRange` (including `duration:` overload), `buildEditPlan`, `captionCopy`; stored `EditPlan.fadeParts` |
| `Domain/Editing/EditSession.swift` | `EditState.init(transcript:edits:)`, active clip/text/project-edits accessors; `Project.applyEditing` and `replaceTranscript` |
| `Domain/Editing/EditingContracts.swift` | `EditingLimits`; existing contract types remain in place |
| `Domain/Editing/EditingImport.swift` | `EditingImportResult`, `EditingImport` (`cleanWords`, `tightenIntoSound`, `findUnlabeledSpeech`, `pipeline`); `refineWordBoundaries` and `duration:` overload |
| `Domain/Editing/EditingPrimitives.swift` | `EditingPrimitives` (`jsRound`, JS whitespace/trim/split, normalization); `toFixed1`, `detectPauses`, `isFillerText`, `alignTranscriptWords`, `estimateTranscriptWords` |
| `Domain/Editing/SourceContentKey.swift` | `SourceContentKey.hash(sizeBytes:head:tail:)` |
| `Services/Project/AtomicJSON.swift` | Internal atomic writer/encoder; no public type |
| `Services/Project/ProjectMigrations.swift` | Internal schema-version dispatch; no public type |
| `Services/Project/ProjectValidation.swift` | Internal schema/model validator; no public type |
| `Services/Project/CacheStore.swift` | New public `CacheEnvelope`; existing `CacheEntry` adds `schema` and optional `envelope` |
| `Services/Project/ProjectStore.swift` | Existing `JSONProjectStore` adds logger injection, per-load warning tuple, static decode/encode/reference cleanup/content-key/relative-path helpers and `relink` |
| `Services/Settings/SettingsValidation.swift` | `SettingsDocument.defaults`, keyed default access, per-provider model accessors and `validate`; no new public type |
| `Services/Settings/SettingsStore.swift` | Existing `JSONSettingsStore` adds logger injection, `lastLoadError` and `lastWriteError` diagnostics |

- New test files under `Tests/VoxClipCoreTests/Editing/`: `EditingFixtures.swift`, `EditingProperties.swift`, `PersistenceTests.swift`, `EditingPerformance.swift`, `SettingsRecoveryTests.swift`. Their helper types are internal; `EditingPlaceholder.swift` is updated in place. No frozen test changed in round 2.
- Cache wire additions are local `Cache/<contentKey>/meta.json` metadata, not project/settings fields: `CacheEntry.schema = "voxclip-cache/1"` and optional `envelope: {sampleRate, frameSeconds, count}` (`CacheEnvelope`, native rate, frame hint, Float32-level count). Metadata callers supply the optional envelope; `CacheStore.record` persists it through `AtomicJSON.encoded`. `CacheStore.entry` rewrites `lastAccessAt` while preserving the schema/envelope. These functions are the current writers; no new PCM/levels payload or extra wire key is introduced by round 2. The derived fade-part table is not serialized.

### 2026-10-25 — mac-editing round 2: verification

- Worktree `voxclip-wt/mac-editing`, branch `track/mac-editing`; all commands below ran in `apps/macos`. No shared fixtures, frozen tests, other tracks, or main-checkout files changed in round 2.
- `timeout 1200 swift build`: exit 0, `Build complete! (2,89 sec)`.
- `timeout 1800 swift test`: exit 0, `Test run with 50 tests in 5 suites passed after 4.338 seconds`; 83 normative editing fixture cases pass. The informative caption-text fixture reports SKIPPED with its editing §11.1 reason; the other five tracks' existing disabled placeholders remain skipped.
- `timeout 1800 swift test -c release --filter 'EditingFixtures|EditingProperties'`: exit 0, 14 tests in two suites pass in 0.516 seconds, including all 83 normative fixtures with exact raw cut-range bits and join-list/part-table gain parity.
- `timeout 1800 swift test -c release --filter EditingPerformance`: exit 0, two tests (including both parameterized rebuild cases) pass. On local arm64 `Mac15,11`, after one warm-up and 20 measured runs: 10,000 words / 2,000 word cuts median **0.193417 ms**, p95 **0.199166 ms**, max **0.200125 ms**; 10,000 words / 2,000 pause cuts median **0.349167 ms**, p95 **0.350916 ms**, max **0.351625 ms**. Both medians satisfy the 10 ms release budget. Active-clip cut fillers + tighten pauses + restore + two summaries on 10,000 words total **7.145042 ms**, below the 50 ms interaction budget.
- Full command output is retained locally as `/tmp/voxclip-mac-editing-final-build.log`, `-tests.log`, `-performance.log`, and `-release-conformance.log` with the same prefix. These are verification artifacts, not shipped project data.

### 2026-10-25 — mac-editing round 3: document coding entry points

- Binding lead decision for mac-ui/mac-media: the existing static `JSONProjectStore.decode` now performs strict checks followed by editing §10.4 reference cleanup. Additive `decodeReportingWarnings(_:) -> (Project, [String])` returns those same cleaned values and per-document warnings; `loadReportingWarnings` delegates to it and logs under architecture §11.1 category `import`, not `project`.
- Additive public `JSONProjectStore.pruneAIResults(_:) -> Project` keeps the newest ten runs plus older referenced runs (editing §10.6, AI §11.8), with the existing date/position tie-break and stored order. Static `encode` applies reference cleanup and retention before canonical encoding, including share-caption pruning (§10.7); file `save` inherits these rules. NSDocument consumers use the static coding entry points from plan §4.1.2 M4; no migration or wire-key change is required.
- Direct static coding tests cover 15 results, old/new referenced runs, dangling cuts, corrections, clip/active-clip/AI ids and share-caption ids. Original value snapshots remain unmodified.

### 2026-10-25 — mac-editing round 3: durable settings recovery

- For mac-ui/settings consumers, `JSONSettingsStore.load` now copies the original bytes to `settings.json.damaged-<timestamp>` and atomically writes the recovered document to `settings.json` before caching/returning it (architecture §2.5, editing §10.2 atomic-write rule). Individually valid known preferences and unknown future keys survive a new store/launch without any explicit save, including `update.autoCheck = false`; successful recovery still surfaces `lastLoadError` on the recovering store.
- Recovery-write failure throws typed `VoxClipError.projectUnreadable("Could not persist recovered settings")`, sets `lastLoadError`/`lastWriteError`, and leaves both original bytes and the damaged backup intact. Round 4 keeps the recovered document as both `current` and `pending`: subsequent loads use it in memory, saves merge into it, and `flush()` or a debounced save retries only the atomic write without creating another backup. No public signature or wire-key change. Tests cover fresh-store reopening for every corruption class, loads/saves/flushes while the file remains immutable, recovery after unlocking, and exactly one unchanged backup throughout.

### 2026-10-25 — mac-editing round 3: coherent plan-derived values

- Binding lead decision for mac-media/mac-ui: `EditPlan` rebuilds `fadeParts`, `outputSamples` and `joins` together from `kept`, `totalSamples` and `sampleRate` after source-field mutations. Initializers/decoding also derive canonical values, including absent/stale joins. Existing public initializer parameters, writable properties and Codable keys remain source-compatible; attempts to set inconsistent derived values are normalized immediately. No new wire key or migration.
- Round-4 consumer action for mac-media: build plans with canonical `EditPlan.init(sampleRate:totalSamples:cuts:kept:)`. The old `outputSamples:`/`joins:` overload is deprecated and asserts agreement with derived values in DEBUG builds. Update `MediaPipelineTests.swift:187` (`zeroLengthFadeSidesLeaveSamplesUnchanged`) and `AudioAlignmentAndQueueTests.swift:24` after merging: pass real `kept` ranges, including a one-sample part for a zero-length fade side and a full kept interval for the identity plan. Explicit derived arguments no longer define a plan.
- Join-list gains equal `joinGain(at:)` at every sample after initialization, decoding and source mutations, including rescaling and empty kept parts (editing §§7.4, 7.7; architecture §5.3). Raw cut-range conformance uses exact numeric equality, not binary64 bit equality, so signed zero follows editing §9; a dedicated negative-zero comparison regression is included.

### 2026-10-25 — mac-editing round 3: linear caption rebuild

- `captionCopy` retains its public signature and exact editing §7.6 semantics, but maps all word boundaries with one forward sweep over cuts. Already monotone boundaries need no sorting; overlapping or unsorted inputs use fixed-width Int64 radix ordering, preserving input word order and O(items + cuts) work even for nested word ends. Timing calculations stay integer-exact and caption transforms remain outside the planner.
- For mac-ui/mac-media, the §7.8/architecture §14 release benchmark now includes `buildSegments`, `buildEditPlan`, `captionCopy` and summary, with a 10 ms median assertion for 10,000 words and word/pause/mixed/alternating cuts. Caption-only stage timing also has an assertion. A 300-plan adversarial test compares every caption boundary with independent `mapTime` calls, including unsorted/overlapping words, invalid segments, clamping, signed zero and wide sample integers. No API or wire change.

### 2026-10-25 — mac-editing round 3: AI-reference-safe reducer

- Binding lead decision for mac-ai/mac-ui/mac-media: the existing state-only `EditReducer.reduce` rejects malformed `aiResultId` strings and negative `aiClipIndex` values on clip additions, following `project.schema.json` and editing §6.3. AI batches assign canonical metadata before validating their resulting clips.
- Additive overload `EditReducer.reduce(_:command:aiResults: [ProjectAIResult]) -> EditState` validates result existence and upper index bounds against the actual cached result, and rejects oversized/unknown-result AI batches without applying any of that command. `Project.applyEditing` uses this context-aware overload automatically. Callers reducing standalone EditState snapshots should supply `aiResults` when editing AI links: the frozen EditState deliberately carries no AI cache, so the original overload cannot infer a result's clip count. Existing signatures and state/wire keys remain unchanged.
- 2026-10-25 round-4 consumer action for mac-ui/mac-ai: `EditorModel` should call additive `EditHistory.apply(_:aiResults:)` with the current project's `ai.results` for editing commands. It uses the same context-aware reducer as `Project.applyEditing`; rejected AI references/batches leave state, undo and redo unchanged, and valid additions remain one undo step. Existing `apply(_:)` stays available for state-only callers. Parity tests cover missing/malformed/orphaned references, negative/end/past-end indices, oversized batches, valid last indices and canonical batches, including undo/redo.
- Tests exercise invalid ids, negative/end/past-end indices, orphaned indices, missing results, invalid batches, the last valid result index and successful canonical AI batches; invalid commands leave both reducer and project snapshots unchanged.

### 2026-10-25 — mac-editing round 3: resumed verification

- Audited all two confirmed findings and ten minor findings against the main-checkout specs and the preserved round-three commits, including checkpoint `24eafb7`. The checkpoint's reducer implementation and regressions are complete and correct; no source repair or history rewrite was necessary. All findings are addressed by the five round-three ledger entries above; none was declined.
- Verification ran only in this track's `apps/macos`, with `VOXCLIP_SHARED_DIR=<repo>/shared`, Apple Swift 6.4 on arm64 macOS 27, and a separate `timeout 1800` around every build/test command. `swift build`, focused `swift test --filter 'EditingProperties|EditingPersistence|EditingSettingsRecovery'`, full `swift test`, and full `swift test -c release` all exited 0 without compiler warnings.
- Focused regressions: 32 tests in 3 suites passed. Both complete configurations reported 56 Core tests in 5 suites and 5 tests in the Media target. All 83 normative editing fixtures passed in debug and release. The informative caption-text case and the five existing other-track placeholders remain explicitly skipped; no new skip was introduced.
- Release plan-only rebuilds, 10,000 words and 2,000 cuts, 20 measured runs after warm-up: word cuts median 0.204 ms, p95 0.232 ms, max 0.279 ms; pause cuts median 0.362 ms, p95 0.367 ms, max 0.371 ms. Active-clip filler/tighten/restore operations plus two summaries took 8.380 ms (50 ms limit).
- Release full rebuilds include segments, plan, caption copy and summary for 10,000 words. Median / p95 / max, in milliseconds: word cuts 4.479 / 4.881 / 4.971; pause cuts 5.084 / 5.539 / 5.625; mixed cuts 5.860 / 6.002 / 6.148; alternating cuts 3.987 / 4.141 / 4.261. Caption-stage medians were respectively 0.213 / 0.264 / 0.238 / 0.157 ms. Every release median assertion passed the architecture §14 10 ms budget.
- Logs are local verification artifacts under `/tmp/voxclip-mac-editing-r3-`: `focused.log`, `build.log`, `debug.log`, and `release.log`. No GUI app was launched, signing/notarization was not attempted (pending the locked-screen prerequisite), and the unavailable Windows VM was not accessed. No background build/test process was left by this attempt. Shared data, main and other worktrees are unchanged.

### 2026-10-25 — mac-speech round 3 routing and resume corrections

- Affects mac-speech, mac-ui and mac-media: runtime routing checks Apple language support but leaves `.forced(primary)` in the plan. Only `AppleSpeechTranscriber` resolves the regional locale, preferred languages first (transcription §10.2). Domain never reads system preferences.
- `SpeechRoutingSnapshot.modelDTWDefaults` is additive, initially empty; the bundled catalogue fills it per model and the runtime router honors it (transcription §9.4, §9.7). `BundledModelCatalog.fromWhisperLanguage` adds the reverse whisper-code mapping, including `jw` to `jv`. Existing signatures and project wire keys are unchanged.
- Download retries read the actual partial-file size, not URL resource-cache metadata (§12.3). Word assembly absorbs up to six following bracket drafts (§6 rule 1), matching Windows. Local regressions cover two mid-body interruptions and seven-draft bracket events; shared fixtures remain the lead/shared-fixtures track's responsibility.

### 2026-10-25 — mac-speech recovery and merge handoff

- Existing frozen signatures and schema values are unchanged; frozen contract tests were not edited. Additive speech-only APIs expose catalogue runtime metadata, a runtime-locale routing snapshot and typed routing prompts, injectable HTTP/consent hooks and native token/run mapping for tests. UI and CLI may adopt these without changing their current calls.
- Lead coordination supersedes the original ownership table's import-pipeline wording: mac-editing alone owns cleanup, sound tightening, refinement and gap detection. The frozen public free functions `cleanWords`, `tightenIntoSound` and `findUnlabeledSpeech` keep throwing `notImplemented("mac-editing")` until merge. Only the internal `SpeechEditingImportAdapter` used by the service passes words through and reports `refined = false` rather than claiming analysis ran.
- The adapter's four TODO(merge) hooks match the read-only mac-editing `EditingImport` API. Cleanup and tightening are nonthrowing; gap detection forwards `duration: Double? = nil`; `pipeline(_:envelope:timing:verbatim:duration:)` throws and returns `(words: [TimedWord], refined: Bool)`. The service already uses `try` and passes the exact `request.audio.durationSeconds`, including a partial final frame. At merge, replace all seven TODO(merge) bodies: the adapter's first three forward their same-name `EditingImport` methods; its pipeline uses `let result = try EditingImport.pipeline(words, envelope: envelope, timing: timing, verbatim: verbatim, duration: duration); return (result.words, envelope != nil)`. `EditingImportResult` supplies words, pauses and pause threshold, not a `refined` member. The three frozen public free functions in `TranscriptContracts.swift` keep their signatures and forward as `return EditingImport.cleanWords(words, timing: timing)`, `return EditingImport.tightenIntoSound(words, envelope: envelope, timing: timing)` and `return EditingImport.findUnlabeledSpeech(words, envelope: envelope)`; they must not remain stubs after merge. Replace the three `notImplemented` expectations in `WordAssemblyTests.publicEditingSeamsRemainUnimplemented` with forwarding assertions and rename the test. Its adapter call now uses `envelope: nil`, so the `!result.refined` and word-id assertions remain valid before and after merge. Then run the editing import fixtures through the service.
- `ModelStore` without a confirmation hook cancels installation before fetching bytes. UI/CLI must inject the licence confirmation callback (or explicit headless consent). Shared dependency downloads are covered by the parent model's confirmation. Listing, verification and explicit removal keep their existing contracts.
- Full runtime-aware routing uses `LanguageRouter.route(language:mode:snapshot:)`; the original synchronous overload cannot discover Apple locale support or key/model readiness. The app must not treat it as a runtime readiness check. All route alternatives are prompts, never implicit uploads.
- Automatic local routing can call `TranscriptionService.detectLanguage(_:using:)` with a `WhisperCppTranscriber`, then put the returned language/probability in the routing snapshot. Detection uses only an installed OpenAI multilingual model, the first VAD unit and at most 30 seconds; TalTech detection is rejected. No audio is uploaded. Existing `Transcriber` requirements are unchanged.
- `TranscriptionOptions.dtw` is the explicit decode choice. The runtime router seeds it from the catalogue's per-model `dtwDefault`, falling back to true; explicit plans retain their supplied value. Detection uses that same option and context key as the following transcription, preserving the 120-second keep-alive. No tri-state option or schema change was introduced.
- Cache eviction/protection remains owned by mac-editing's `CacheStore` and the window/CLI integration. Speech writes atomic raw entries under the content key and does not implement a competing eviction policy.
- The pinned whisper C API provides an abort callback for decoding, but none for model loading, VAD or language detection. Cancellation is checked around those calls; the strict one-second stop guarantee cannot be made for those uninterruptible native calls without a coordinated runtime/API change. The live decode-abort probe is separate from that limitation.

### 2026-10-25 — mac-media round 3 headless audio facts

- Match the existing Windows export result for architecture §9.3/§9.5 parity: `audioSampleRate` is always the 48,000 Hz export target. A video-only output reports `audioSamples == 0` and contains no audio track. No public type, initializer or wire key changed; the native colour-bar CLI regression checks all three facts.

### 2026-10-25 — mac-media round 3 integrated verification

- Supersedes the mac-media round-two verification and boundaries above. Normal merge `0b78eea` joins `76fdf21` with main `93e0b64`, preserving both sides' same-date notes. Verification now uses the real mac-editing and mac-speech implementations, not their earlier placeholders.
- All media/CLI/test `EditPlan` constructions use the canonical kept-range initializer; Core supplies unscaled join gains. The scoped CLI summary gate refuses all-cut words even when gaps remain. Bounded in-flight pump draining and append-retry failure checks preserve prompt cancellation and the first real error. The 48 kHz movie clock, verified WAV tail padding, staged audio publication, global SRT indices, usage exits and video-only export facts resolve review minors 0–9. Minor 10 remains for the lead's squash merge, as instructed.
- `OutputSpec.resolved` is package-scoped; CLI and tests compile without public exposure. The marked M5 sizing bridge and M7 caption adapters remain `TODO(merge)` until their owner integrations land. Neither real caption rendering nor live transcription is claimed by this run.
- With `VOXCLIP_SHARED_DIR` pointing to the main checkout's `shared/`, `timeout 1800 swift build` passes without warnings. `timeout 1800 swift test` passes: media 89 total (83 passed, 6 skipped), Core 110 total (107 passed, 3 skipped), zero failures or compile warnings. No mac-editing or mac-speech placeholder skip remains. The skips are UI, captions, AI, the informative editing caption-text case, three live-provider tests and two opt-in benchmarks; the ffprobe benchmark was then enabled separately and passed.
- Under the full-suite load, cancellation one second into a generated 60 s 1920×1080 source with audio returns in 0.166016333 s (limit 0.5 s). Injected video/audio pump failures return in 0.087733542/0.102219416 s. All 50 deterministic SIGINT offsets from 0.05–1.2 s exit 6 with no owned scratch: min 0.023607791 s, max 0.355669917 s, mean 0.10187137322 s.
- The separate 60 s portrait CLI/ffprobe check passes: H.264 High, 1080×1920, yuv420p, 30/1, 1,800 frames, BT.709 primaries/transfer/matrix, duration 60.000000 s; AAC LC, 48,000 Hz stereo, duration 60.000000 s (2,815 AAC packets). CLI audio accounting is 2,880,000 samples. Generated media and scratch are removed immediately by test cleanup. No build tree was copied, no push was made, and no attribution trailer was added.

### 2026-10-25 — mac-media round 5: joined writer cancellation

- Architecture §5.6 clarification for the lead: cancellation and pump failures only stop the shared pump state. The writer is cancelled only after the throwing task group has joined both reader pumps, never while an append can still be running (the AVAssetWriter header forbids that overlap).
- Every receiver append is counted in `ExportPumpState`, including rejected retries and throwing appends. The serialized video-failure, audio-failure and user-cancel stop regressions require zero in-flight appends at every writer cancellation across all ten iterations per case. The six M7 merge adapter sites are unchanged.

### 2026-10-25 — mac-media round 5: transactional publication

- Architecture §9.3 now has one publication owner for MP4, SRT and staged WAV, in that order. `ExportSafety.publishAll` copies every existing destination to an adjacent `.rollback-<UUID>` before the first atomic rename; failure or cancellation restores replaced originals and removes newly created outputs. Partial files and backups are cleaned on every exit. Only owned backup copies have immutable/append-only flags cleared so a locked original never leaves an undeletable backup.
- The exporter's extra staged outputs are package-scoped; the public `Exporter` protocol and result remain unchanged. CLI regressions lock each of the existing MP4, SRT and WAV outputs independently and require exit 5, byte-identical originals and no partials/backups. Unit regressions cover rollback of replaced and previously absent outputs, and cancellation before publication. Real M7 caption layout remains gated until the lead's integration; these publication-only CLI cases use an empty synthetic transcript with an enabled caption style.

### 2026-10-25 — mac-media round 5: argument precedence and Off sidecars

- Architecture §9.3 argument validation runs immediately after the sole source probe, for both bare media and saved projects, before reading/transcribing a supplied source or evaluating the editing summary. Silent `--audio-out` and effective-Off `--srt` return exit 2 with the pinned usage sentences, without touching any output. The probe is reused for import, transcription and output sizing.
- Off cannot reach the CLI's SRT serialization path, so a kept-word transcript no longer produces a successful empty subtitle sidecar. Regression cases cover silent media without a transcript, all-cut silent media, default/explicit Off, saved-project Off, and saved-project all-cut precedence; each preserves all existing output bytes and leaves no scratch or transcription data directory.

### 2026-10-25 — mac-media round 5: silent cancellation and watchdog coverage

- Architecture §10.2 cancelled JSON has `message: ""`, matching Windows; non-JSON cancellation stays silent. The 30-pair SIGINT watchdog requires that empty message and exit 6 for every subprocess.
- The preserved SDK-like neighbour is named after the real `interrupted-0.mp4` output. Its exact name must be the only leftover matching `.partial` (including `.partial.sb-*`), `voxclip-export-*` or `Remaker-*`, so neither export's SDK scratch can evade the watchdog assertions.

### 2026-10-25 — mac-media round 5: plain partial-path usage copy

- Architecture §9.3 invalid reserved partial directories and links use the Windows sentence: "Choose a regular file for each .partial output; directories and links are not allowed." This is a plain exit-2 usage error, never an `exportFailed` description wrapped as usage copy. All six MP4/SRT/WAV directory-or-link regression combinations assert the exact sentence and unchanged destinations.

### 2026-10-25 — mac-media round 5: portable verification paths

- The historical round-four verification entry now uses `<repo>/shared` and `<path to ffprobe>`, not a maintainer home directory. Run commands with the local `VOXCLIP_SHARED_DIR` and `VOXCLIP_MEDIA_FFPROBE` values supplied by the lead; no local account or checkout path belongs in committed verification notes.

### 2026-10-25 — mac-media round 5: final verification

- Merged main `6d9e4d3` normally as `ce04f70`, with no conflicts; both tracks' contract entries remain. Code verified at `046e40c` from `apps/macos`, building in place with the lead's `VOXCLIP_SHARED_DIR` and `VOXCLIP_MEDIA_FFPROBE`. Both `timeout 1800 swift build` runs and both `timeout 1800 swift test` runs exit 0, without compiler warnings. Each full run reports 93 media tests (88 passed, 5 skipped) and 110 Core tests (107 passed, 3 skipped), zero failures. Media/Core durations: 99.483/6.156 seconds and 97.543/6.157 seconds.
- Twenty filtered runs of `ExportStopTests|cancellationDeletesPartialOutput` all exit 0: 600 stop-suite writer cancellations each observe exactly zero appends in flight, and all 20 separate user-cancel cases pass. Maximum stop latency is 0.218937375 seconds. No signal exit occurs.
- Two final filtered 30-pair SIGINT watchdog runs each interrupt 60 CLI exports; every export exits 6 with an empty JSON message, zero watchdogs and only the preserved similarly named user file left behind. Maximum interrupt latencies are 0.424847458 and 0.400985833 seconds (means 0.099725320 and 0.092970673). The earlier smoke watchdog and both full-suite watchdogs also pass: 300 interrupted CLI exports in total, no signal exits.
- No new `swiftpm-testing-helper` or `voxclip-cli` crash report appeared during verification. Generated fixture/export directories are removed; no media or build tree was copied into the repository or another worktree. The branch diff against main is empty for `doc/` and `apps/windows/`, adds no home paths, and changes none of the six M7 merge adapters. No GUI app or live provider was launched, no push was made, and commit messages have no attribution trailer.

### 2026-10-25 — mac-speech round 5 forced-language normalization

- Service imports and direct ElevenLabs calls normalize a forced language's lowercase primary subtag through catalogue `languageCodes.iso639_3` before cache identity, lookup or multipart construction. `est`, `ekk`, `EST-ee` and `et` therefore share one paid result and send `language_code=et`. Auto still omits the form field. Input values remain immutable, malformed identifiers are rejected before files or uploads, and explicit Apple regions remain available to locale resolution (transcription §3.3, §8.1, §10.2, §14.2).
- Regression tests inspect the mock upload's actual multipart file, canonical key and file name, and reuse across aliases for direct calls and service calls with or without an injected catalogue. Generic local imports verify that the engine sees the normalized language and runs once. Catalogue tests cover other ISO aliases and explicit Apple-region preservation.

### 2026-10-25 — mac-speech round 5 parameterized error copy

- Lead-approved speech error payloads now include `modelMissing(String, size: String = "unknown size")`, `keyRejected(String, status: Int? = nil)`, `transcriptionLanguageUnsupported(String, language: String = "the selected language")`, `speechAssetsUnavailable(String, reason: String = "unavailable")`, `providerError(String, provider: String? = nil, status: Int? = nil)` and `diskFull(String, size: String? = nil)`. Codes and CLI exit statuses are unchanged; existing constructors still compile with defaults, but associated-value pattern matches must adopt the new arity. These are error values, not project schema fields.
- mac-ui's read-only `UserMessages.swift` was inspected on `track/mac-ui`. For speech failures it must use `VoxClipError.errorDescription` directly, rather than reconstructing older partial messages or running `clean` on tuples. In particular retain the catalogue display name plus size, H:MM:SS duration for both upload limits, engine plus language, provider plus HTTP status and redacted detail, and asset language plus reason. Speech-specific optional provider/size parameters preserve the existing copy for errors from other domains when omitted.
- `SpeechErrorCopy` supplies deterministic Windows-compatible duration and decimal-size formatting, display names for engines and missing catalogue models, and parameterized language errors. Missing local model downloads report the readiness byte count including dependencies. Unknown catalogue ids honestly retain "unknown size". No model is downloaded by error handling or tests (architecture §10.2, design §13).

### 2026-10-25 — mac-speech round 5 no-speech parity

- ElevenLabs and the final editing-import pipeline require at least one word, not just an event or unlabeled item (transcription §3.4). Scribe word tokens carry `kind: nil` (transcription §3.2); explicit events carry `.event`. Nil kinds count as words in fresh and cached imports. Cached events-only responses keep their paid bytes and raise `noSpeech` without another upload.
- Both platforms share `shared/fixtures/transcription/elevenlabs/events-only.json` under transcription §16.2, with machine-readable expectations in `events-only.expected.json` and the layout in `shared/fixtures/transcription/README.md`. macOS consumes both files for direct/service imports and cache reuse, plus generic events-only and unlabeled-only results. The fixture test resolves this checkout's shared root so an external `VOXCLIP_SHARED_DIR` for existing assets cannot hide the new files before merge.

### 2026-10-25 — mac-speech round 6 shared recorded-response contract

- The hand-written transcription fixture format follows transcription §16.1–§16.2: an unchanged response body plus an expected-outcome sidecar with derivation, exact RawTokens and stable import error code. `events-only` expects one `.event`, normalized language `en`, `noSpeech` on fresh/cached import, and exactly one upload. Nil token kinds mean words on both platforms.
- Consumer action for win-speech: the Windows `VoxClip.Core.Tests` recorded-response suite must consume both shared files and assert the sidecar's RawTokens, language, `importError` and `expectedUploads`, rather than an inline expectation. Its existing inline cases do not automatically load new files. This macOS round does not change Windows-owned tests or claim verified cross-platform consumption; the lead must schedule that adoption before asserting parity.

### 2026-10-25 — mac-speech round 6 error-payload integration

The six lead-approved associated-value additions remain in place for architecture §10.2 and transcription §3.4. Old single-String construction remains source-compatible through defaults; single-binding switch patterns now bind tuples and must be migrated.

| Case | Current shape (old shape: one String) |
| --- | --- |
| `modelMissing` | `modelMissing(String, size: String = "unknown size")` |
| `keyRejected` | `keyRejected(String, status: Int? = nil)` |
| `transcriptionLanguageUnsupported` | `transcriptionLanguageUnsupported(String, language: String = "the selected language")` |
| `speechAssetsUnavailable` | `speechAssetsUnavailable(String, reason: String = "unavailable")` |
| `providerError` | `providerError(String, provider: String? = nil, status: Int? = nil)` |
| `diskFull` | `diskFull(String, size: String? = nil)` |

- Consumer action for mac-ui, in its integration round after this merge: route speech errors through `VoxClipError.errorDescription`, or bind every associated value explicitly. Do not pass a tuple to `clean`, `provider` or `httpStatus` in `UserMessages.swift`. Update the `DebugRegressions.swift` key rejection case to `.keyRejected("ElevenLabs", status: 401)`. Provider-answer wording requires both a provider and an actual HTTP status; local model/options validation uses `transcriptionFailed` instead of pretending a provider answered. Media limits and unsupported languages retain their specific codes and exact copy.
- Consumer action for mac-media: construct local missing-model failures with `SpeechErrorCopy.modelMissing(descriptor)` (or the readiness helper including dependencies), rather than a free-form model id, when a catalogue descriptor is available. Unknown sizes remain honest fallbacks, not fabricated download sizes.
- No wording change is proposed for `mediaTooLong`: it remains exactly "ElevenLabs accepts up to 10 hours. This take is {duration}." Every branch-owned `doc/` hunk was reverted; lead-owned specs are unchanged. Optional lead documentation proposals only: describe canonical language aliases before cache/upload and best-effort persistence of paid responses as already recorded in the round-5 contracts. Neither proposal changes the required copy.

### 2026-10-25 — mac-speech round 6 ElevenLabs region integration

- `ElevenLabsRegion` is the closed settings enum from `settings.schema.json`: `.default` (`default`), `.us` (`us`), `.eu` (`eu`, EU residency), `.india` (`in`), `.singapore` (`sg`). Its `baseURL` is exclusively transcription §8.1's fixed five-host table. No initializer accepts a free-text base URL anymore. Every Scribe upload uses the selected enum's URL, including retries; region is deliberately absent from the raw cache key.
- The production initializer changes from `ElevenLabsTranscriber(keys:logger:)` to `await ElevenLabsTranscriber(keys:settings:logger:)`, with a `SettingsDocument` snapshot. Callers that already resolved the setting may use `ElevenLabsTranscriber(keys:region:logger:)` with an explicit enum. The injected-session initializer replaces `base: URL` with `region: ElevenLabsRegion = .default`; an async `init(keys:settings:session:catalog:sleep:logger:)` also resolves settings for injected transports.
- Consumer action for mac-ui in its integration round: pass the current settings snapshot when creating the transcriber in `TranscriptionSheet.swift`. Route Settings' key/subscription test through the same `await ElevenLabsRegion.from(settings:logger:)` and `region.baseURL`, removing the UI-only host map. Every ElevenLabs call, not just the free key test, must use that resolved region. Recreate the transcriber when the user changes the setting; do not silently retain the old keys-only initializer.
- Missing `transcription.elevenlabs.region` uses Default without a warning. Unknown strings or non-string stored values use Default and emit a redacted `transcribe` warning without echoing untrusted settings content. Tests intercept uploads to all five exact hosts, reject free-text settings as endpoints, check the schema enum, and reuse one paid cache entry across US and EU without another key/upload. No live calls are made.

### 2026-10-25 — mac-speech round 5 paid-response cache failures

- Successful ElevenLabs responses attempt atomic persistence before and after mapping, retrying each failed write twice with 50 ms and 100 ms delays. Exhausted writes emit a path-free warning through the injected logger but do not discard the mapped transcript; mac-ui/mac-media must keep storing the returned transcript in the project. Pre-upload cache validation is unchanged. This supersedes round 3's unconditional post-response persistence guarantee (transcription §14.3).
- Regression coverage makes the cache directory unwritable after the mock upload, restores it during either retry, and re-imports without a key with one paid call total. A permanently unwritable directory still returns words after both write phases exhaust their retries.

### 2026-10-25 — mac-speech round 3 cache visibility and safety

- Affects mac-speech, mac-ui and mac-media: additive `TranscriptionResult` has `transcript: Transcript` and non-positional `fromCache: Bool = false`, initialized with `init(transcript:fromCache:)`. Adopt `TranscriptionService.transcribeResult(_:using:envelope:)` to show transcription §14.3's "Using the earlier ElevenLabs transcript of this file (no charge)." The flag is true for a reused ElevenLabs raw result or retained paid response. The existing `transcribe` method still returns `Transcript`; no project wire fields or frozen enums changed.
- ElevenLabs validates the bundled catalogue and cache destination before upload, alongside the request, language, model, duration, size, key and multipart constraints. Every successful HTTP response is persisted atomically before mapping or cancellation checks; the internal raw cache permits `raw: null` while mapping is pending and optionally retains exact `providerResponseBytes` for malformed JSON too. Mapping retries use those bytes without another paid call. No actor dictionary retains provider bodies, and valid mapped entries remain compatible with the prior cache format (transcription §8.1–§8.4, §14.2–§14.3).
- `SpeechProgressLimiter<Value>` is an additive public Core service shared by model downloads and both native engines. It coalesces to 10 Hz, delivers the trailing value while a job is idle and exposes `finish()` to await the final report; the duplicate native limiter was removed (transcription §13.1). ElevenLabs and whisper accept an injected `Redacting` logger so app/CLI sinks and registered secrets are used. Whisper/ggml warning and error callbacks forward at warn to `transcribe`; the process-lifetime mutex-protected box outlives the C callbacks. `SpeechRuntimeVersion.macOS` supplies exactly major.minor for the engine version and User-Agent (transcription §8.1, §9.1, §9.4, §10.5; architecture §11.1–§11.2).
- Apple asset mapping rethrows `VoxClipError` before checking the real Speech error domain and applies the same mapping to one recovery attempt. Releasing a locale uses the actual reserved `Locale` and checks the Boolean result. CAF conversion writes and closes a same-directory temporary file before atomic replacement, retaining earlier complete input on failure or cancellation (transcription §10.3–§10.4; architecture §8.2).
- Live ElevenLabs tests require `VOXCLIP_LIVE_TESTS=1` and its key; Apple tests accept that switch or `VOXCLIP_TEST_APPLE_SPEECH=1`. The live whisper download and cancellation test accepts `VOXCLIP_LIVE_TESTS=1` or `VOXCLIP_TEST_DOWNLOAD=1`. The undocumented aliases were removed (AGENTS.md Build and test; plan §1 rule 6; transcription §16.3).

## Approved mac-ai round 7 alignment (2026-10-25)

- `CLIConnector.refreshWarning: String?` is additive, actor-isolated and read-only to consumers, matching the existing HTTP connector warning surface. AI spec sections 6.10 and 9 require failed model refreshes to retain cached or curated models and expose `Couldn't refresh: {message}`; successful refreshes clear it. mac-ui can read the property after refreshing; no persisted format or protocol changes.
- Detection and sign-in probes now use AI section 6.10's generic failure detail, combine both help streams, and prioritize catalog signed-out markers and Claude's boolean sign-in state over exit status. Probe cancellation remains silent. All redirects are refused, and credential-bearing auth on keyless connectors is rejected before provider access, including native Apple generation, per AI section 1 rule 5.
- AI section 5 copy uses the catalog label except for the CLI-specific short-name rows. Unknown versions omit the version placeholder; missing CLI messages include the catalog install hint. Fake-runner regressions cover failed or unparseable versions, failed help, missing flags and failed Codex features, with no sign-in or generation after incompatibility.

### 2026-10-25 — mac-ui round 3 verification

- Normal merge `8544417` integrates main `03cd58e`; both dated contract sections
  are retained. The editing seams use Core directly. Caption, AI and media
  handoffs remain pending their owning tracks.
- Sanitized `timeout 1800 swift build` and `timeout 1800 swift test` pass without
  warnings. The opt-in run executes 145 tests: 138 pass and seven skip (three
  live speech engines, the three unmerged subsystem placeholders, and the
  informative caption-text fixture). No mac-ui merge assertion skips remain.
- The Debug app's offscreen self-test passes 125/125 assertions. Demo captures
  include the 600-point Settings window: its 492.5-point native tab bar remains
  attached, rather than overflowing. Export label/bezel contrast is at least
  12.81:1 across the four key/inactive appearance probes.
- The separately optimized app built with `-c release -Xswiftc -DDEBUG` passes
  13/13 performance assertions. The same DEBUG-only offscreen entry point times
  30 distinct edits on 10,000 words and 2,000 initial cuts: median 4.184 ms,
  p95 4.695 ms, maximum 5.174 ms; scrolling p95 2.395 ms. There are zero storage
  rebuilds and one changed span per cut. The test harness uses the documented
  `VOXCLIP_UI_PERFORMANCE_EXECUTABLE` override only for this measurement.
- Unoptimized Debug timing is not a passing latency claim: a diagnostic run
  peaked at 82.454 ms. That report is retained separately from optimized results.
  No budget assertion was relaxed and no timing check is a merge skip.
- Evidence is in `/tmp/voxclip-mac-ui-r3/`: build/test logs, JSON reports and 26
  JPEGs (about 2.2 MB). Only DEBUG offscreen modes ran, with activation prohibited,
  isolated data, no Keychain, no keys and no live providers.

### 2026-10-25 — Caption style resolution acceptance (round 4)

- M6 is implemented: `CaptionStyleLibrary.init(shared:)` strictly decodes and manifest-validates built-ins, exposes `styles` sorted by `order`, and looks up `style(id:)`. `CaptionStyle.resolved(overrides:frame:) throws` applies the aspect override before the RFC 7396 project patch, validates semantics, and throws rather than accepting an invalid patch (captions §2.4–2.5).
- Additive `CaptionPipeline.resolve(_:overrides:frame:) -> CaptionStyleResolver.Resolution` also checks the loaded font manifest. Invalid patches fall back atomically to the aspect-resolved unpatched style with `rejectedOverrides == true`; the inspector shows “These caption settings could not be applied.” M7 `layout` still takes an already-resolved style and never reapplies aspect overrides. All layout fixtures compare M6/M7 with the engine's own resolution.
- Consumer action — mac-media: `Sources/voxclip-cli/CLIWorkflow.swift`, `captions(_:)` export branch, must replace the provisional `style.resolved` call with `await pipeline.resolve` before M7 and retain `rejectedOverrides`; `Sources/VoxClipMedia/Pipeline/FrameCompositor.swift`, `drawCaptions`, consumes only the resulting `RenderRequest.captionLayout` and the accepted `draw(_:time:into:previewWidth:reduceMotion:)` path.
- Consumer action — mac-ui: `Sources/VoxClip/CaptionHandoff.swift`, `layout(_:)` and `tile(_:)`, must resolve with the window's pipeline, show the rejection note, select `positionByAspect[preset] ?? position`, and pass that position with the resolved style to M7. Both consumer worktrees were inspected read-only; no consumer files changed here.

### 2026-10-25 — Calibrated caption image comparison (round 4)

- Swift golden/direct parity uses `CaptionImageComparison.compare(_:_:)` on premultiplied full-frame rasters, matching captions §16.5: mean ≤ 4.5; pixels above 32 ≤ max(2% of ink-union pixels, 96); max ≤ 128; alpha SSIM ≥ 0.98 unless max ≤ 2. SSIM uses the padded ink bounds and valid 11×11 Gaussian window; empty-image rules are explicit. Failing golden comparisons write an opaque ×4 diff PNG.
- Thirteen synthetic PNG pairs exercise the mean, count floor, 2% share, max, low-alpha SSIM exemption, structural alpha failure and corner padding boundaries. Their Swift verdicts and numeric metrics agree with isolated `tools/captions/compare_overlays.py` from main. The Python interpreter must have `tools/captions/requirements.txt` installed; tests accept `VOXCLIP_CAPTION_PYTHON` or `python3` on PATH.

### 2026-10-25 — Bit-exact caption render optimization (round 4)

- Renderer leases own their word paths, stroked outlines, shadow buffers and blur scratch. Geometry keys include layout identity, page, visible clusters and emphasis; scaled outlines additionally retain their CoreGraphics transform and surface coordinates. Disjoint word components draw on independent scratch buffers with the original full-surface CTM, not translated tiles or extra clips that change antialiasing.
- Each distinct `(dxEm, dyEm)` rasterizes one pre-blur shadow mask, copied for matching offsets. Independent shadows blur concurrently, then composite in array order. Large integer box passes and mask blends also use disjoint stripes with unchanged rounding. Shadow geometry reuse never crosses a changed transform, cluster count, word opacity or layout.
- Page fades reuse pre-page-alpha bands and apply a 256-entry round-half-up table at raster/composite time. Karaoke caches through captions §13.3 step 9, then redraws active fill, cursor and emoji as applicable. The shared band LRU remains capped at **64 MiB per window**. Geometry motion, jitter and cursors remain outside completed-band caching.
- **Lead follow-up required — word fades:** per-word opacity is applied separately to fill, stroke, boxes and shadow masks by captions §13.5–13.6. Multiplying a neutral flattened band by the page-alpha table is not bit-exact: even plain `vox-bold` word fades at 0.02, 0.04, 0.06 and 0.10 seconds differed by one channel level in a probe. Word-fade bands therefore keep exact word opacities in their cache keys and preserve per-operation alpha; they do not yet reuse one neutral word-alpha band across different opacity values. This deliberately preserves the binding bit-exact requirement rather than silently changing pixels.
- Tests compare page fades, wipe bases and word fades with uncached renders byte-for-byte; 24 distinct style/time frames rendered concurrently with `cacheLimit: 0` match sequential BGRA draws. Dense bounded-blur cases also exercise the parallel stripe path. The release performance test has no warm-up and measures both `cacheLimit: 0` and default-cache sequential 30 fps passes, asserting p95 ≤ 3.0 ms per style at 1080×1920 and zero full-frame caption rasters.
- The first full release verification exposed seven timing assertions while the benchmark ran alongside fixture rendering, Python comparison and concurrent-frame stress tests. The benchmark now runs in SwiftPM's XCTest phase, before the Swift Testing suites, so the required unfiltered `VOXCLIP_PERF_TESTS=1 swift test -c release` measures playback without those self-generated competing workloads. Its frame sequences, cold caches, thresholds and timed scope are unchanged; all functional suites still run.

### 2026-10-25 — Cancellation-safe caption caches (round 5)

- Shadow rebuilds clear their geometry key before any scratch mutation and publish it only after every mask and blur succeeds. Cancellation is checked outside that mutation/publication interval; missing results, wrong mask dimensions and shadow-count mismatches throw instead of trapping. Failed renderer leases are discarded, never returned to the idle pool (captions §13.9).
- Cache audit: glyph paths and transformed outlines publish complete values after construction; font paths, emoji pixels and resized emoji images publish only after successful loading. Direct-layout changes clear geometry before publishing the new layout. Fade bands and karaoke step-nine bands enter the pool LRU only after the entire render succeeds; renderer-local wipe bands are reset at each render. None has a key/data split across a throwing operation.
- Two regressions pass in Debug: neon/editorial A → cancelled different-page B → next-active-word A′ at six cancellation delays with both zero/default band-cache budgets, plus deterministic failure injected after the first shadow-mask mutation on both a directly reused renderer and the pool. Every recovered frame is byte-identical to a fresh zero-band-cache render.

### 2026-10-25 — Proposed M7 style-resolution index addition (round 5)

- Proposal for the lead, affecting mac-ui and mac-media: add `public func resolve(_ style: CaptionStyle, overrides: [String: JSONValue], frame: PixelSize) -> CaptionStyleResolver.Resolution` to the `CaptionPipeline` M7 signature block in plan §4.1.2. This source-compatible implementation already exists; no prior signature is removed or changed.
- Rationale/migration: callers use `await pipeline.resolve(style, overrides: overrides, frame: frame)` before layout to enforce the captions §2.5 font-manifest rules. An invalid patch returns the aspect-resolved unpatched style with `rejectedOverrides == true` for the §2.4 inspector notice. The pure M6 extension continues throwing for invalid typed/semantic patches.
- Removed this track's earlier plan.md addition. Documentation remains lead-owned; the lead can add the proposed line at merge. Historical WIP commits remain untouched for the lead's squash merge, as directed.

### 2026-10-25 — Explicit caption comparator availability (round 5)

- Swift verdict assertions for all 13 synthetic §16.5 boundary pairs run unconditionally in their own test. The Python cross-check probes `VOXCLIP_CAPTION_PYTHON` (otherwise `python3`) once with `-I -c 'import numpy'`. A missing isolated numpy import skips only the cross-check locally with an explanatory test message, and is a clear failure whenever `CI` is set.
- Verified both numpy-present cross-check success and numpy-absent local skipping; the CI-negative check deliberately fails while the Swift-only assertions still pass. Main's merged macOS CI provisions numpy before Swift tests and parity.

### 2026-10-25 — Stored caption goldens and exact cache parity (round 5)

- Regenerated and committed the §16.4 golden set from this round's renderer: **262 layout samples, 38 tiles, 300 PNGs and 87 JSON indexes (387 files)**. Compared the SHA-256 of every relative file with `/tmp/voxclip-mac-captions-goldens-r4`: **zero missing, extra or differing files**.
- `goldenRenders` verifies the complete root, per-case PNG file lists, fixture-selected sample/style/time/frame metadata and each indexed PNG SHA-256. It decodes straight RGBA crops, restores them into transparent full frames with exact `(2*c*a+255)/510` premultiplication, and checks current renders with `CaptionImageComparison` (§16.5), including all tiles. Pixel failures write a ×4 diff to a unique temporary folder and report its path.
- Cached/direct comparisons use `rgba ==` for every layout sample and tile (§13.9), not cross-platform tolerances. Exact image equality short-circuits the §16.5 comparator while retaining the correct ink-pixel count and zero metrics; its Swift boundary and Python parity tests still pass.
- Verification: the four reader/comparator/stored-golden tests passed, covering all 300 stored PNGs. Absent golden folders skip with a test message; withholding a single index from an existing folder produced the expected immediate failure, then the index was restored unchanged. A synthetic cropped PNG round-trips at its indexed coordinates with exact half-up premultiplication.

### 2026-10-25 — Honest caption performance gate (round 5)

- Renamed the existing modes to **band-uncached** (zero band-LRU budget, renderer-local reuse retained) and **playback** (default 64 MiB band LRU). Each style/mode starts three independent passes and asserts the minimum of the three per-pass p95 values against the unchanged **3.0 ms M3 Max** gate at 1080×1920.
- Added **full-rebuild**: measure each page's first nontransparent visible 30 fps frame with a fresh renderer per page. Its glyph-path, transformed-outline, shadow geometry, masks and blur caches are cold, including lazy renderer resources. The same 3.0 ms best-of-three p95 gate applies; no warm-up, per-frame minimum, discarded slow sample or relaxed threshold is used.
- Every pass prints median, p95, frame count and all three load averages. Final verification below records the quiet-wait outcome, complete three-pass table and measured margins; any full-rebuild failure remains a failure for lead review rather than being relabelled as a pass.

### 2026-10-25 — Repeated cancellation verification caveat (round 5)

- The initial two-test repeated run passed 13 processes, then iteration 14 reported byte differences in all 12 neon timed-cancellation cases; editorial and deterministic shadow-failure recovery still passed. There was no trap. The original failure had no pixel diagnostic artifact, so its cause is **not established** and must not be reported as an explained reference outlier or silently discarded.
- Expanded the regression suite with 24 fresh/reused zero-band-cache controls per style across detached tasks, before cancellation, and diagnostic actual/expected/×4-difference PNGs plus differing-byte counts, maximum and first offset on a mismatch. The expanded three-test suite then passed **20 consecutive processes (60 tests, 960 uncancelled controls and 480 timed-cancellation sequences)** without reproducing the pixel failure. The original unexplained observation remains a lead-review caveat.

### 2026-10-25 — Exact golden fixture times (round 5 lead update)

- Merged current main `8bd6d1b`, including the binding caption rules in `66ce1c6`, with a normal conflict-free merge. Captions §16.4 now takes each tile's decoded fixture `t` unchanged; layout sample times already used the fixture value. Stored-index time comparison permits at most 1e-9 seconds, while the writer regressions require exact fixture values.
- Regenerated all 387 golden files from the updated writer. Every one of the 300 PNG SHA-256 values and all 86 case JSON indexes still match `/tmp/voxclip-mac-captions-goldens-r4`. The only changed file is `tiles.json`: exactly 20 of its 38 `t` values lose recomputation noise, with all other fields unchanged. This is the intentional lead-approved exception to the earlier all-file SHA identity result.
- The stored golden and crop/tolerance tests passed (2 tests): 262 layout samples and 38 tiles, exact cached/direct pixels, and all fixture-selected times verified.

### 2026-10-25 — Exact easing endpoints (round 5 lead update)

- `CaptionMath.ease` clamps its input to [0, 1] and returns the exact endpoint before evaluating any polynomial, as now pinned by captions §11.2. Interior overshoot is retained. Added coverage for every easing and overshoot 0, 1.70158 and 2.5, including infinities, the least negative subnormal and the first value above 1.
- The endpoint test, existing math fixtures and complete regenerated golden suite passed (3 tests). All 300 golden PNGs remain SHA-identical to round 4; the only index difference remains the separately approved `tiles.json` timestamp correction.

### 2026-10-25 — Stable caption bands on video targets (round 5 lead update)

- Audited captions §13.9: both a band-cache miss (including `cacheLimit: 0`) and a hit already return a flattened transparent `CaptionBand`; `CoreTextCaptionRasterizer.draw(_:time:into:previewWidth:reduceMotion:)` composites that band into the video target exactly once. The cache does not select a different target-drawing path. No production routing change was necessary.
- Added byte-exact opaque BGRA coverage at 1080×1920 for all 18 cursor-free gallery styles, before and after cache hits, against a zero-cache renderer. Reduced motion puts geometric/jitter animation at rest; the cursor-bearing typewriter has no stable completed-band state and is intentionally excluded. The opaque-target and four existing pipeline tests passed (5 tests).
- Scratch audit: each renderer retains one current canvas, one current set of shadow canvases/blur buffers and one wipe-base band. Replaced canvases and shadow sets are released, blur capacity follows the largest mask/row, and failed renderers are discarded. The pool retains at most four idle renderers, eight layout snapshots and 64 MiB of completed bands. Per-word geometry/transformed outlines cap at 512 entries, resampled emoji at 64, shadow tables and blur-rounding tables at eight; native glyph/font and source-emoji resources are bounded by the bundled font/emoji repertoire, not retained per page. No per-page scratch collection grows as tracks/pages are drawn.

### 2026-10-25 — Measured caption performance stop (round 5)

- **Gate not met; stop for lead decision.** On the 14-core Apple M3 Max, the final Release benchmark ran all 171 style/mode passes and failed 20 unchanged 3.0 ms assertions: all 19 full-rebuild styles, plus `one-word` band-uncached (best p95 3.569 ms). All 19 playback gates and the other 18 band-uncached gates passed. No slow pass or sample was discarded.
- Honored the cumulative 20-minute quiet-wait cap. The first run started at load 104.06/102.07/72.90, observed 91.28–112.70 / 99.62–103.91 / 72.88–73.89, and failed 22 gates. After the lead-update fixes, the final run started at 5.79/10.26/26.56; measured pass loads were 6.05–6.87 / 9.71–9.79 / 25.35–25.64. The one-minute load was below eight, but the machine was not proven idle. Margins below are observed lower-load margins, not invented idle-machine margins.
- Short Release profile, independent fresh renderers: `vox-bold` 570 frames, median total 3.630 ms; `neon` 150 frames, setup/paths/outlines/masks 4.075 ms plus blur/blend/fill/composite 2.812 ms, total 6.897 ms; `active-pop` 210 frames, corresponding medians 4.167 + 1.334 ms, total 5.514 ms. Segment medians need not sum to total medians. The no-shadow `vox-bold` has no shadow-hook split. Profile loads were 11.32–11.79 / 15.64–15.80 / 34.07–34.24.
- Separate 30-pass initialization probes measured resource loading/parsing at median 3.272 ms (`vox-bold`), 3.241 ms (`neon`) and 3.360 ms (`active-pop`), with font open/hash/validation another 0.214 / 0.116 / 0.410 ms respectively. Fresh renderer resource parsing alone consumes the gate; neon also spends substantial time in blur/composite. Existing cropped blur scratch, mask/table reuse and path/outline caches remain, but warm reuse does not demonstrate a cold gate. Potential immutable resource-snapshot sharing is not implemented or silently excluded from the timing. No threshold relaxation or speculative cancellation/pixel change is made; further optimization is for the lead decision.
- Logs and the full per-pass medians remain in ignored `.build/round5-verification/perf-initial.log`, `perf-final.log`, `perf-final.json` and `profile-detailed.log`. One final-log stdout record (typewriter cold pass 3) was split by XCTest stderr; only the receipt parser rejoins its two observed fragments, leaving the raw log unchanged.

Each cell is **p95 milliseconds @ one-/five-/fifteen-minute load** for that complete pass. The margin is 3.0 ms minus the minimum of the three complete-pass p95 values. `n` is frames per pass.

| Style | Mode | n | Pass 1 | Pass 2 | Pass 3 | Best p95 | Margin ms |
|---|---|---:|---|---|---|---:|---:|
| active-pop | band-uncached | 240 | 2.652 @ 6.14/9.79/25.64 | 2.675 @ 6.14/9.79/25.64 | 2.698 @ 6.14/9.79/25.64 | 2.652 | +0.348 |
| active-pop | playback | 240 | 2.644 @ 6.14/9.79/25.64 | 2.655 @ 6.14/9.79/25.64 | 2.689 @ 6.14/9.79/25.64 | 2.644 | +0.356 |
| active-pop | full-rebuild | 7 | 6.714 @ 6.14/9.79/25.64 | 7.084 @ 6.14/9.79/25.64 | 6.839 @ 6.14/9.79/25.64 | 6.714 | -3.714 |
| bounce | band-uncached | 240 | 2.296 @ 6.14/9.79/25.64 | 2.403 @ 6.14/9.79/25.64 | 2.372 @ 6.14/9.79/25.64 | 2.296 | +0.704 |
| bounce | playback | 240 | 2.376 @ 6.14/9.79/25.64 | 2.316 @ 6.05/9.71/25.52 | 2.325 @ 6.05/9.71/25.52 | 2.316 | +0.684 |
| bounce | full-rebuild | 5 | 4.505 @ 6.05/9.71/25.52 | 4.415 @ 6.05/9.71/25.52 | 4.422 @ 6.05/9.71/25.52 | 4.415 | -1.415 |
| box-highlight | band-uncached | 240 | 0.914 @ 6.05/9.71/25.52 | 0.930 @ 6.05/9.71/25.52 | 0.885 @ 6.05/9.71/25.52 | 0.885 | +2.115 |
| box-highlight | playback | 240 | 0.867 @ 6.05/9.71/25.52 | 0.877 @ 6.05/9.71/25.52 | 0.868 @ 6.05/9.71/25.52 | 0.867 | +2.133 |
| box-highlight | full-rebuild | 5 | 4.772 @ 6.05/9.71/25.52 | 4.673 @ 6.05/9.71/25.52 | 4.813 @ 6.05/9.71/25.52 | 4.673 | -1.673 |
| clean-subtitle | band-uncached | 258 | 0.690 @ 6.05/9.71/25.52 | 0.664 @ 6.05/9.71/25.52 | 0.673 @ 6.05/9.71/25.52 | 0.664 | +2.336 |
| clean-subtitle | playback | 258 | 0.556 @ 6.05/9.71/25.52 | 0.529 @ 6.05/9.71/25.52 | 0.523 @ 6.05/9.71/25.52 | 0.523 | +2.477 |
| clean-subtitle | full-rebuild | 2 | 4.369 @ 6.05/9.71/25.52 | 4.408 @ 6.05/9.71/25.52 | 4.129 @ 6.05/9.71/25.52 | 4.129 | -1.129 |
| editorial | band-uncached | 258 | 0.850 @ 6.05/9.71/25.52 | 0.850 @ 6.05/9.71/25.52 | 0.919 @ 6.05/9.71/25.52 | 0.850 | +2.150 |
| editorial | playback | 258 | 0.578 @ 6.05/9.71/25.52 | 0.603 @ 6.05/9.71/25.52 | 0.620 @ 6.05/9.71/25.52 | 0.578 | +2.422 |
| editorial | full-rebuild | 3 | 5.660 @ 6.05/9.71/25.52 | 5.905 @ 6.05/9.71/25.52 | 6.159 @ 6.05/9.71/25.52 | 5.660 | -2.660 |
| emoji-accent | band-uncached | 240 | 1.021 @ 6.05/9.71/25.52 | 1.095 @ 6.05/9.71/25.52 | 1.150 @ 6.05/9.71/25.52 | 1.021 | +1.979 |
| emoji-accent | playback | 240 | 1.061 @ 6.05/9.71/25.52 | 1.051 @ 6.05/9.71/25.52 | 1.032 @ 6.05/9.71/25.52 | 1.032 | +1.968 |
| emoji-accent | full-rebuild | 5 | 5.528 @ 6.05/9.71/25.52 | 5.327 @ 6.05/9.71/25.52 | 5.468 @ 6.05/9.71/25.52 | 5.327 | -2.327 |
| gradient | band-uncached | 240 | 1.653 @ 6.05/9.71/25.52 | 4.974 @ 6.05/9.71/25.52 | 2.056 @ 6.05/9.71/25.52 | 1.653 | +1.347 |
| gradient | playback | 240 | 1.639 @ 6.05/9.71/25.52 | 1.644 @ 6.05/9.71/25.52 | 1.624 @ 6.05/9.71/25.52 | 1.624 | +1.376 |
| gradient | full-rebuild | 7 | 7.113 @ 6.05/9.71/25.52 | 7.238 @ 6.05/9.71/25.52 | 7.091 @ 6.05/9.71/25.52 | 7.091 | -4.091 |
| karaoke | band-uncached | 234 | 2.319 @ 6.05/9.71/25.52 | 1.686 @ 6.05/9.71/25.52 | 1.333 @ 6.05/9.71/25.52 | 1.333 | +1.667 |
| karaoke | playback | 234 | 1.372 @ 6.05/9.71/25.52 | 0.774 @ 6.69/9.78/25.45 | 0.797 @ 6.69/9.78/25.45 | 0.774 | +2.226 |
| karaoke | full-rebuild | 4 | 7.247 @ 6.69/9.78/25.45 | 7.085 @ 6.69/9.78/25.45 | 6.977 @ 6.69/9.78/25.45 | 6.977 | -3.977 |
| lower-third | band-uncached | 267 | 0.795 @ 6.69/9.78/25.45 | 0.838 @ 6.69/9.78/25.45 | 0.843 @ 6.69/9.78/25.45 | 0.795 | +2.205 |
| lower-third | playback | 267 | 0.810 @ 6.69/9.78/25.45 | 0.643 @ 6.69/9.78/25.45 | 0.662 @ 6.69/9.78/25.45 | 0.643 | +2.357 |
| lower-third | full-rebuild | 3 | 5.533 @ 6.69/9.78/25.45 | 5.158 @ 6.69/9.78/25.45 | 5.878 @ 6.69/9.78/25.45 | 5.158 | -2.158 |
| neon | band-uncached | 240 | 2.136 @ 6.69/9.78/25.45 | 2.208 @ 6.69/9.78/25.45 | 2.132 @ 6.69/9.78/25.45 | 2.132 | +0.868 |
| neon | playback | 240 | 2.263 @ 6.69/9.78/25.45 | 2.221 @ 6.69/9.78/25.45 | 2.198 @ 6.69/9.78/25.45 | 2.198 | +0.802 |
| neon | full-rebuild | 5 | 8.242 @ 6.69/9.78/25.45 | 8.153 @ 6.69/9.78/25.45 | 8.210 @ 6.69/9.78/25.45 | 8.153 | -5.153 |
| one-word | band-uncached | 225 | 4.698 @ 6.69/9.78/25.45 | 5.219 @ 6.69/9.78/25.45 | 3.569 @ 6.69/9.78/25.45 | 3.569 | -0.569 |
| one-word | playback | 225 | 1.719 @ 6.69/9.78/25.45 | 1.716 @ 6.69/9.78/25.45 | 1.713 @ 6.69/9.78/25.45 | 1.713 | +1.287 |
| one-word | full-rebuild | 19 | 7.404 @ 6.69/9.78/25.45 | 7.113 @ 6.69/9.78/25.45 | 7.039 @ 6.69/9.78/25.45 | 7.039 | -4.039 |
| outline | band-uncached | 240 | 1.539 @ 6.69/9.78/25.45 | 1.603 @ 6.69/9.78/25.45 | 1.388 @ 6.69/9.78/25.45 | 1.388 | +1.612 |
| outline | playback | 240 | 0.530 @ 6.69/9.78/25.45 | 0.529 @ 6.69/9.78/25.45 | 0.577 @ 6.69/9.78/25.45 | 0.529 | +2.471 |
| outline | full-rebuild | 7 | 7.465 @ 6.69/9.78/25.45 | 7.158 @ 6.69/9.78/25.45 | 7.385 @ 6.69/9.78/25.45 | 7.158 | -4.158 |
| pill | band-uncached | 246 | 0.786 @ 6.69/9.78/25.45 | 0.754 @ 6.69/9.78/25.45 | 0.808 @ 6.87/9.76/25.35 | 0.754 | +2.246 |
| pill | playback | 246 | 0.633 @ 6.87/9.76/25.35 | 0.601 @ 6.87/9.76/25.35 | 0.618 @ 6.87/9.76/25.35 | 0.601 | +2.399 |
| pill | full-rebuild | 3 | 4.355 @ 6.87/9.76/25.35 | 4.260 @ 6.87/9.76/25.35 | 4.078 @ 6.87/9.76/25.35 | 4.078 | -1.078 |
| two-tone | band-uncached | 240 | 0.911 @ 6.87/9.76/25.35 | 0.932 @ 6.87/9.76/25.35 | 0.892 @ 6.87/9.76/25.35 | 0.892 | +2.108 |
| two-tone | playback | 240 | 0.414 @ 6.87/9.76/25.35 | 0.395 @ 6.87/9.76/25.35 | 0.407 @ 6.87/9.76/25.35 | 0.395 | +2.605 |
| two-tone | full-rebuild | 5 | 4.850 @ 6.87/9.76/25.35 | 4.846 @ 6.87/9.76/25.35 | 4.757 @ 6.87/9.76/25.35 | 4.757 | -1.757 |
| typewriter | band-uncached | 258 | 0.776 @ 6.87/9.76/25.35 | 0.769 @ 6.87/9.76/25.35 | 0.760 @ 6.87/9.76/25.35 | 0.760 | +2.240 |
| typewriter | playback | 258 | 0.775 @ 6.87/9.76/25.35 | 0.813 @ 6.87/9.76/25.35 | 0.787 @ 6.87/9.76/25.35 | 0.775 | +2.225 |
| typewriter | full-rebuild | 3 | 4.274 @ 6.87/9.76/25.35 | 3.968 @ 6.87/9.76/25.35 | 3.963 @ 6.87/9.76/25.35 | 3.963 | -0.963 |
| vhs | band-uncached | 240 | 1.713 @ 6.87/9.76/25.35 | 1.730 @ 6.87/9.76/25.35 | 1.741 @ 6.87/9.76/25.35 | 1.713 | +1.287 |
| vhs | playback | 240 | 1.722 @ 6.87/9.76/25.35 | 1.738 @ 6.87/9.76/25.35 | 1.732 @ 6.87/9.76/25.35 | 1.722 | +1.278 |
| vhs | full-rebuild | 5 | 5.569 @ 6.87/9.76/25.35 | 5.567 @ 6.87/9.76/25.35 | 5.452 @ 6.87/9.76/25.35 | 5.452 | -2.452 |
| vox-bold | band-uncached | 192 | 0.108 @ 6.87/9.76/25.35 | 0.101 @ 6.87/9.76/25.35 | 0.102 @ 6.87/9.76/25.35 | 0.101 | +2.899 |
| vox-bold | playback | 192 | 0.045 @ 6.87/9.76/25.35 | 0.046 @ 6.87/9.76/25.35 | 0.045 @ 6.87/9.76/25.35 | 0.045 | +2.955 |
| vox-bold | full-rebuild | 19 | 4.122 @ 6.87/9.76/25.35 | 3.989 @ 6.87/9.76/25.35 | 3.485 @ 6.87/9.76/25.35 | 3.485 | -0.485 |
| vox-bold-plus | band-uncached | 228 | 0.690 @ 6.87/9.76/25.35 | 0.695 @ 6.87/9.76/25.35 | 0.686 @ 6.87/9.76/25.35 | 0.686 | +2.314 |
| vox-bold-plus | playback | 228 | 0.385 @ 6.87/9.76/25.35 | 0.378 @ 6.87/9.76/25.35 | 0.369 @ 6.87/9.76/25.35 | 0.369 | +2.631 |
| vox-bold-plus | full-rebuild | 19 | 5.341 @ 6.87/9.76/25.35 | 13.171 @ 6.87/9.76/25.35 | 5.619 @ 6.87/9.76/25.35 | 5.341 | -2.341 |
| vox-highlight | band-uncached | 192 | 0.214 @ 6.87/9.76/25.35 | 0.202 @ 6.87/9.76/25.35 | 0.201 @ 6.87/9.76/25.35 | 0.201 | +2.799 |
| vox-highlight | playback | 192 | 0.094 @ 6.87/9.76/25.35 | 0.096 @ 6.87/9.76/25.35 | 0.095 @ 6.87/9.76/25.35 | 0.094 | +2.906 |
| vox-highlight | full-rebuild | 19 | 3.918 @ 6.87/9.76/25.35 | 3.701 @ 6.87/9.76/25.35 | 3.824 @ 6.87/9.76/25.35 | 3.701 | -0.701 |

### 2026-10-25 — Final round 5 verification and handoff

- Merges: first integrated main `52b753e4` in `f483723`, then the binding caption-rule update through main `8bd6d1b` in `b0ce4db`, and finally current main `5e8b05c` in `c695cb7`. All were ordinary conflict-free merges, preserving both contract histories. The final merge brings only Windows implementations and an AI-spec clarification, with no incoming macOS or caption data changes. No merge into main and no push was performed.
- With `VOXCLIP_SHARED_DIR` fixed to this worktree's `shared` and `VOXCLIP_CAPTION_PYTHON=<python>` (numpy installed from `tools/captions/requirements.txt`), `timeout 1800 swift build` passes. Full Debug `timeout 1800 swift test` passes **184 Swift Testing tests: 66 Media + 118 Core**, plus the intentionally skipped opt-in XCTest performance test. Caption fixtures cover **86 cases, 599 pages and 3,589 samples** with zero mismatches; stored goldens cover **262 layout samples + 38 tiles**. The 13 Swift comparison boundary pairs and their isolated Python/numpy cross-check pass. Earlier numpy-absent local-skip and expected CI-negative-failure probes remain recorded.
- After the lead updates, the expanded cancellation suite passes **20/20 fresh test processes: 60 tests, 960 uncancelled fresh/reused controls and 480 timed cancellation sequences**, plus deterministic injected shadow-failure recovery. The earlier pre-diagnostic neon mismatch remains unexplained as documented above; these passing repeats do not erase that observation.
- `VOXCLIP_PERF_TESTS=1 timeout 1800 swift test -c release --filter CaptionPerformance` completes with exit 1 and **20 failed budget assertions**, as fully tabulated above. It is not a passing performance gate; stop for the lead decision. The three-pass minimum and 3.0 ms threshold remain unchanged.
- Reran `bash tools/captions/parity.sh` after the final main merge. Both Release CLIs build; .NET reports zero warnings/errors. The script exits 2 before comparison because the Swift CLI still requires `--style`, although the pinned fixture-only CLI contract does not. Windows `CliApplication.cs` also still stubs `render-caption`. Those CLI implementations are outside this track; cross-platform pixel parity is **blocked, not passed**.
- Final SHA audit: all **387** paths present, no extra/missing files, **300 PNGs and 86 case indexes unchanged** against round 4; only `tiles.json` differs, exactly the **20 approved fixture-time corrections**, with every non-time field unchanged. `git diff main...HEAD -- doc` and `git diff --check` are empty. The tracked tree is clean and the profiling source/binary scratch has been deleted; bounded verification logs/receipts remain ignored under `.build/round5-verification/`.
- Crash-report file counts do not establish whether tests trapped: `swiftpm-testing-helper` reached the per-process 25-report daily cap, after which crashes may only update existing reports. The observed additions were helper bootstrap `_assertionFailure`/SIGTRAP reports with no VoxClip test image loaded, not evidence of caption-test crashes. Use recorded command exit statuses, not report counts, to assess completed test runs. Historical receipts: `crash-audit-lead-update.json` and `final-audit.json` in the ignored verification directory.

### 2026-10-25 — Round 6 caption verification corrections

- Golden generation uses `VOXCLIP_SHARED_DIR=<worktree>/shared VOXCLIP_GOLDEN_OUT=<fresh-output-outside-shared> swift test --filter goldenRenders` from `apps/macos`. This calls `CaptionRenderHarness`, the same library the CLI must use. The lead tracks a byte-identical rerender through `voxclip-cli render-caption` once mac-media lands the command; no golden is regenerated in this round. The authoritative totals are 86 layout cases, 262 golden samples and 38 tiles; the lead owns updating older 84/258 counts in captions §§16.1 and 16.4.
- Golden/cache parity and tile-state checks always run. Normal runs require the stored golden root; generation bypasses only stored comparison and refuses protected shared paths. See `tools/captions/README.md` for the explicit reviewed-copy workflow.
- Python comparison success is printed only when all synthetic pairs match in exit status and metrics; otherwise the log reports failed pairs. Cancellation, cache-parity and stored-golden mismatch images use fresh system temporary directories and report their paths even if a diagnostic write fails.

### 2026-10-25 — Round 6 render determinism and verification

- Ordinary merges integrated main `8a1d88c` in `558f519` and then main `fa50bc1` in `ffac921`. Both were conflict-free and preserve the contract history. The first includes the captions §13.9 setup/page-first budget split; the second supplies full-precision easing fixtures. No merge into main, push or track-authored `doc/` edit was made.
- **C1:** a process-wide lock protects the first glyph fill/stroke warm-up and its completion flag. It draws real bundled glyph outlines into alpha-only and premultiplied BGRA contexts with the lane context configuration, including filled stroked outlines and `strokePath`. First renderers wait even on the single-lane path; glyph-free groups stay serial. `coldRendererRepeatability` now checks two independently rendered references before the 24 fresh/reused controls per style.
- The standalone `tools/captions/cg-first-fill-probe.swift` builds with `swiftc -swift-version 6`, takes `<shared-directory> cold|warm`, reads bundled Righteous glyphs, and compares concurrent mask lanes against serial references. Sequential fresh-process evidence: **19 mismatches / 2,000 cold processes** (186.72 s), **0 / 2,000 warmed processes** (185.69 s). No warmed mismatch occurred, so mask-lane parallelism remains enabled; the serial-mask fallback and its cost measurement were not needed. The compiled probe scratch was removed; its source and ignored evidence logs remain.
- **C0:** the normal golden test checks all **262 samples + 38 tiles**, including byte-exact cached/direct parity and tile states. A copied shared tree without `golden/`, even with `VOXCLIP_SKIP_CAPTION_GOLDENS=1`, completes that sweep and then fails exactly once with the missing root path (expected exit 1). Protected-output tests pass for the configured shared root, committed goldens, normalized paths and symlink aliases with nonexistent output leaves. Reviewed generation writes elsewhere; it does not compare its output against itself.
- Resource-error tests pass for missing styles directories, corrupt JSON and unreadable style files, all mapped to `VoxClipError.sharedResourcesMissing`. Semantic `CaptionFailure` and existing `VoxClipError` values retain their types. The artifact-location test verifies fresh system temporary directories and all three diagnostic PNGs; write/difference errors cannot hide the original assertion or byte statistics.
- Python/numpy parity passes all **13 synthetic pairs**, including the explicit empty-image verdicts. A copied shared tree with no adjacent comparison script produces **13 failed pairs**, expected exit 1 and no success line. The public ledger now names `CoreTextCaptionRasterizer.draw(_:time:into:previewWidth:reduceMotion:)`, uses `<python>` rather than a home-directory interpreter, and makes no count-based crash-audit claim.
- Required verification uses `VOXCLIP_SHARED_DIR=<worktree>/shared` and `VOXCLIP_CAPTION_PYTHON=<worktree>/apps/macos/.build/caption-venv/bin/python` with isolated numpy. From `apps/macos`, `timeout 1800 swift build` exits 0. Both `timeout 1800 swift test` runs exit 0 (151.76 s and 148.68 s), each reporting **69 Media tests + 118 Core tests**. Those reporter totals include the five existing Media and two Core Swift Testing skips; the XCTest performance test is separately opt-in and skipped in normal runs. All caption golden/cache/state checks run, with **86 layout cases, 599 pages and 3,589 samples**, zero fixture mismatches, and the strict **1e-9** easing check passing.
- The final **50/50 sequential fresh** `swift test --skip-build --filter CaptionCancellationTests` processes exit 0: **150 passed tests**, 2,400 uncancelled fresh/reused controls, 100 independent-reference comparisons and 1,200 timed cancellation sequences, plus deterministic injected shadow-failure recovery. No completed process trapped; this statement is based on recorded exit statuses, not diagnostic-report counts.
- **Performance:** `page-first` uses one renderer per pass, warmed by an untimed page excluded from measurement, then times the remaining pages' first frames. Steady passes exclude page-first frames and one-time resource setup. Gates remain best p95 of three: **7.5 ms page-first**, **3.0 ms band-uncached/playback**. Release test targets compile with `swift build -c release --build-tests -Xswiftc -enable-testing` (the build-only invocation needs explicit testability for optimized dependencies). The acceptance suite was **not run**: a bounded 20-minute quiet-machine observation overlapped the tail of sequential verification, no final gate check qualified below 2, and the final `uptime` one-minute load was **6.30**. The 41 samples taken every 30 seconds had a minimum of **2.50**. No performance pass or new p95 table is claimed; the old setup-inclusive `full-rebuild` table is historical, not this round's acceptance measure.
- All **300 committed PNGs remain SHA-256 byte-identical** to the round-4 snapshot, with no golden changes or regeneration in this round. The CLI byte-identical rerender remains lead/mac-media follow-up as recorded above. Tested implementation commit: `cd4c558`. Receipts are ignored under `apps/macos/.build/round6-verification/`: `probe-counts.json`, `probe-cold.log`, `probe-warm.log`, `focused-final.log`, `missing-goldens.log`, `python-failure-reporting.log`, `full-test-{1,2}.log`, `cancellation-{01..50}.log`, `verification.json`, `perf-load-window.json`, `performance-decision.json` and `final-audit.json`. All verification and observation processes exited; copied shared-tree and probe binary scratch were removed.

## Mac integration sizing and caption contract

`OutputSizing` is an additive Core API in `Domain/Shared/OutputSizing.swift`. The Mac UI and Media pipeline use it for oriented source size, output size, frame rate, bitrate and centre crop. It preserves the existing `OutputSpec` and `RenderRequest` signatures. Source geometry swaps width and height for 90° and 270° rotation before sizing. Caption style resolution uses `CaptionStyleResolver.aspect` for preview drag guides and `CaptionStyleResolver.preset` for stored per-preset positions; a source frame without an exact preset uses the common position. Preview and export retain the same prepared `CaptionLayoutResult` in `RenderRequest` and draw it through `FrameCompositor`.

`OutputSizing.centerCrop(source: PixelSize, output: PixelSize) -> CaptionRect` uses only Core domain types. `FrameCompositor` adds the oriented CIImage extent origin when converting that crop to `CGRect`; matching source ratios within one output pixel retain the full source after even output rounding. `EditorModel.renderRequest` resolves the requested full take or clip once and passes the same edit segments to the plan and caption handoff. A missing clip id fails before planning, while a transcript-free full take has no caption layout. The offscreen integrated flow checks full export with a clip open, a disjoint clip export, current-clip preview, and a rendered caption frame.

The integrated `render-caption` command accepts `--case <fixture> --out <dir>`, the optional `--sample <index>` on that form, or `--tiles <styles-dir> --out <dir>`. The fixture owns the style; `--style` and `--layout-out` overrides are usage errors, as architecture §9.2 specifies. These are source-compatible additions and integrations; no frozen model or project wire fields changed.

## Public type and protocol index

Paths are relative to apps/macos. Nested public types are qualified with their enclosing type. Public member signatures and documentation live at these exact paths.

| Public type / protocol | File | Owning track |
| --- | --- | --- |
| `AIHash` | `Sources/VoxClipCore/Domain/Clips/AIHash.swift` | mac-ai |
| `AIText` | `Sources/VoxClipCore/Domain/Clips/AIJSON.swift` | mac-ai |
| `AppleSpeechTranscriber` | `Sources/VoxClipMedia/Speech/AppleSpeechTranscriber.swift` | mac-speech |
| `AppModel` | `Sources/VoxClip/VoxClipApp.swift` | mac-ui |
| `AspectRatio` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `AudioEnvelope` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `AudioExtractionRequest` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `AudioExtractionResult` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `AudioExtractor` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `AVAudioExtractor` | `Sources/VoxClipMedia/Audio/AudioPipeline.swift` | mac-media |
| `AVExporter` | `Sources/VoxClipMedia/Pipeline/Exporter.swift` | mac-media |
| `AVMediaProbe` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
| `BoundaryRefinement` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `BundledModelCatalog` | `Sources/VoxClipCore/Services/Models/ModelCatalog.swift` | mac-speech |
| `CacheEntry` | `Sources/VoxClipCore/Services/Project/CacheStore.swift` | mac-editing |
| `CacheStore` | `Sources/VoxClipCore/Services/Project/CacheStore.swift` | mac-editing |
| `CanonicalResponseParser` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `CaptionAnim` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionAnimation` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionAnimEasing` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionAnimType` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionAspectOverride` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionAspects` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionBlur` | `Sources/VoxClipMedia/Captions/CaptionDrawingMath.swift` | mac-captions |
| `CaptionBox` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionBoxGeometry` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionBoxScope` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionCursorGeometry` | `Sources/VoxClipCore/Domain/Captions/CaptionTimeline.swift` | mac-captions |
| `CaptionDroppedWord` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionEasing` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionEffects` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEffectsJitter` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEffectsRgbSplit` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmoji` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmojiGeometry` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionEmojiResampler` | `Sources/VoxClipMedia/Captions/CaptionEmojiResampler.swift` | mac-captions |
| `CaptionEmojiSource` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmphasis` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmphasisSource` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionFailure` | `Sources/VoxClipCore/Domain/Captions/CaptionRules.swift` | mac-captions |
| `CaptionFont` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionFontCascade` | `Sources/VoxClipCore/Domain/Captions/CaptionFontCascade.swift` | mac-captions |
| `CaptionFontFeatures` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionFontRecord` | `Sources/VoxClipCore/Domain/Captions/CaptionRules.swift` | mac-captions |
| `CaptionFontRun` | `Sources/VoxClipCore/Domain/Captions/CaptionFontCascade.swift` | mac-captions |
| `CaptionFontSizeRef` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionFrameState` | `Sources/VoxClipCore/Domain/Captions/CaptionTimeline.swift` | mac-captions |
| `CaptionGoldenImage` | `Sources/VoxClipMedia/Captions/CaptionGoldenWriter.swift` | mac-captions |
| `CaptionGoldenImage.Crop` | `Sources/VoxClipMedia/Captions/CaptionGoldenWriter.swift` | mac-captions |
| `CaptionGoldenWriter` | `Sources/VoxClipMedia/Captions/CaptionGoldenWriter.swift` | mac-captions |
| `CaptionImageComparison` | `Sources/VoxClipMedia/Captions/CaptionImageComparison.swift` | mac-captions |
| `CaptionInputWord` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionLayout` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionLayoutAlign` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionLayoutBalance` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionLayoutEngine` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionLayoutInput` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionLayoutInput.Frame` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionLayoutInput.Settings` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionLayoutResult` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionLine` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionLineBreaker` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionMath` | `Sources/VoxClipCore/Domain/Captions/CaptionRules.swift` | mac-captions |
| `CaptionMeasuredWord` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionMotion` | `Sources/VoxClipCore/Domain/Captions/CaptionTimeline.swift` | mac-captions |
| `CaptionPage` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPageLayout` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionPager` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPaint` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionPaintSpace` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionPaintStop` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionPipeline` | `Sources/VoxClipMedia/Captions/CaptionPipeline.swift` | mac-captions |
| `CaptionPlacement` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPoint` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPosition` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `CaptionPreview` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionRaster` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionRasterizer` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionRasterRequest` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionRect` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionRenderHarness` | `Sources/VoxClipMedia/Captions/CaptionRenderHarness.swift` | mac-captions |
| `CaptionResources` | `Sources/VoxClipCore/Domain/Captions/CaptionRules.swift` | mac-captions |
| `CaptionReveal` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionRevealCursor` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionRevealUnit` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionSettings` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `CaptionShadow` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStroke` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStyle` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStyleLibrary` | `Sources/VoxClipCore/Services/Settings/CaptionStyleLibrary.swift` | mac-captions |
| `CaptionStylePosition` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStylePositionAnchorX` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStylePositionAnchorY` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStyleResolver` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionStyleResolver.Resolution` | `Sources/VoxClipCore/Domain/Captions/CaptionLayoutEngine.swift` | mac-captions |
| `CaptionSubtitles` | `Sources/VoxClipCore/Domain/Captions/CaptionSubtitles.swift` | mac-captions |
| `CaptionText` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionTextOptions` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionTextPunctuation` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionTextRules` | `Sources/VoxClipCore/Domain/Captions/CaptionRules.swift` | mac-captions |
| `CaptionTextTransform` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionTextTransformer` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionTimeline` | `Sources/VoxClipCore/Domain/Captions/CaptionTimeline.swift` | mac-captions |
| `CaptionTrack` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionWord` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionWordAppearance` | `Sources/VoxClipCore/Domain/Captions/CaptionTimeline.swift` | mac-captions |
| `CaptionWordBox` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionWordState` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionWordStates` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CLIConnector` | `Sources/VoxClipCore/Services/LLM/CLIConnector.swift` | mac-ai |
| `CLIConnector.Detection` | `Sources/VoxClipCore/Services/LLM/CLIConnector.swift` | mac-ai |
| `ClipCandidate` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipFinder` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `ClipFinderGateError` | `Sources/VoxClipCore/Domain/Clips/ClipFinderGateError.swift` | mac-ai |
| `ClipFinderRequest` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipOrigin` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ClipPreset` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipPresetID` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipPromptDocument` | `Sources/VoxClipCore/Domain/Clips/ClipRequests.swift` | mac-ai |
| `ClipRange` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ClipRequestBuilder` | `Sources/VoxClipCore/Domain/Clips/ClipRequests.swift` | mac-ai |
| `ClipSuggestion` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipWindow` | `Sources/VoxClipCore/Domain/Clips/ClipRequests.swift` | mac-ai |
| `ClipWord` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `CompositionBuilder` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
| `ConnectorID` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `ConnectorStatus` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `CoreTextCaptionRasterizer` | `Sources/VoxClipMedia/Captions/CaptionRasterizer.swift` | mac-captions |
| `CoreTextShaper` | `Sources/VoxClipMedia/Captions/CoreTextCaptions.swift` | mac-captions |
| `CostEstimate` | `Sources/VoxClipCore/Domain/Shared/VoiceLab.swift` | common (frozen; lead approval) |
| `DataLocations` | `Sources/VoxClipCore/Services/Settings/SharedResources.swift` | mac-editing |
| `EditCommand` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `EditHistory` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `EditorModel` | `Sources/VoxClip/EditorView.swift` | mac-ui |
| `EditorView` | `Sources/VoxClip/EditorView.swift` | mac-ui |
| `EditPlan` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `EditReducer` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `EditSegment` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `EditSegmentKind` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `EditState` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `EditSummary` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `Effort` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `ElevenLabsTranscriber` | `Sources/VoxClipCore/Services/Speech/ElevenLabsTranscriber.swift` | mac-speech |
| `EngineRef` | `Sources/VoxClipCore/Domain/Shared/Transcript.swift` | common (frozen; lead approval) |
| `Exporter` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `ExportFrameRate` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ExportJob` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `ExportPhase` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `ExportPreset` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ExportProgress` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `ExportQuality` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ExportQueue` | `Sources/VoxClipMedia/Pipeline/Exporter.swift` | mac-media |
| `ExportResult` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `ExportTarget` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `ExtractedAudio` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `FadeContext` | `Sources/VoxClipMedia/Audio/AudioPipeline.swift` | mac-media |
| `FadeTap` | `Sources/VoxClipMedia/Audio/AudioPipeline.swift` | mac-media |
| `FinalizeClipsOptions` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `FormattedTranscript` | `Sources/VoxClipCore/Domain/Clips/TranscriptLines.swift` | mac-ai |
| `FoundationModelsConnector` | `Sources/VoxClipMedia/Intelligence/FoundationModelsConnector.swift` | mac-ai |
| `FoundationProcessRunner` | `Sources/VoxClipCore/Services/Process/ProcessRunner.swift` | mac-ai |
| `FrameCompositor` | `Sources/VoxClipMedia/Pipeline/FrameCompositor.swift` | mac-media |
| `GlyphShaper` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `GlyphShapeRequest` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `GroupingRule` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `GroupingRule.Conf` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `GroupingRule.End` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `HTTPConnector` | `Sources/VoxClipCore/Services/LLM/HTTPConnector.swift` | mac-ai |
| `Join` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `JSONProjectStore` | `Sources/VoxClipCore/Services/Project/ProjectStore.swift` | mac-editing |
| `JSONSettingsStore` | `Sources/VoxClipCore/Services/Settings/SettingsStore.swift` | mac-editing |
| `JSONValue` | `Sources/VoxClipCore/Domain/Shared/JSONValue.swift` | common (frozen; lead approval) |
| `KeyProvider` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LanguageChoice` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `LanguageRouter` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `LipsyncJob` | `Sources/VoxClipCore/Domain/Shared/VoiceLab.swift` | common (frozen; lead approval) |
| `LipsyncModel` | `Sources/VoxClipCore/Domain/Shared/VoiceLab.swift` | common (frozen; lead approval) |
| `LipsyncOptions` | `Sources/VoxClipCore/Domain/Shared/VoiceLab.swift` | common (frozen; lead approval) |
| `LipsyncProvider` | `Sources/VoxClipCore/Services/LLM/LipsyncProvider.swift` | mac-ai |
| `LipsyncState` | `Sources/VoxClipCore/Domain/Shared/VoiceLab.swift` | common (frozen; lead approval) |
| `LipsyncTier` | `Sources/VoxClipCore/Domain/Shared/VoiceLab.swift` | common (frozen; lead approval) |
| `LLMCatalog` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMConnectionTestResult` | `Sources/VoxClipCore/Services/LLM/LLMCatalog.swift` | mac-ai |
| `LLMConnector` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMConnectors` | `Sources/VoxClipCore/Services/LLM/LLMConnectors.swift` | mac-ai |
| `LLMEnvironmentKeyProvider` | `Sources/VoxClipCore/Services/LLM/LLMEnvironmentKeyProvider.swift` | mac-ai |
| `LLMError` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMFeature` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMModel` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMModel.Source` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMRequest` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMResult` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMRunner` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMTokenCounting` | `Sources/VoxClipCore/Services/LLM/LLMTokenCounting.swift` | mac-ai |
| `LLMUsage` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `Log` | `Sources/VoxClipCore/Services/Logging/Logger.swift` | mac-ui |
| `LogEntry` | `Sources/VoxClipCore/Services/Logging/Logger.swift` | mac-ui |
| `Logger` | `Sources/VoxClipCore/Services/Logging/Logger.swift` | mac-ui |
| `LogLevel` | `Sources/VoxClipCore/Services/Logging/Logger.swift` | mac-ui |
| `MediaAudio` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `MediaInterval` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `MediaProbe` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `MediaProbeResult` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `MediaReference` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `MediaVideo` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ModelCatalog` | `Sources/VoxClipCore/Services/Models/ModelCatalog.swift` | mac-speech |
| `ModelDescriptor` | `Sources/VoxClipCore/Services/Models/ModelCatalog.swift` | mac-speech |
| `ModelDownloader` | `Sources/VoxClipCore/Services/Models/ModelCatalog.swift` | mac-speech |
| `ModelDownloadProgress` | `Sources/VoxClipCore/Services/Models/ModelCatalog.swift` | mac-speech |
| `ModelFile` | `Sources/VoxClipCore/Services/Models/ModelCatalog.swift` | mac-speech |
| `ModelStore` | `Sources/VoxClipCore/Services/Models/ModelCatalog.swift` | mac-speech |
| `Mulberry32` | `Sources/VoxClipCore/Domain/Captions/CaptionRules.swift` | mac-captions |
| `OutputSpec` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `Pause` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `PixelSize` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewEngine` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewEvent` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewFrame` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewPlayerController` | `Sources/VoxClipMedia/Pipeline/PreviewPlayerController.swift` | mac-media |
| `ProcessRequest` | `Sources/VoxClipCore/Services/Process/ProcessRunner.swift` | mac-ai |
| `ProcessResult` | `Sources/VoxClipCore/Services/Process/ProcessRunner.swift` | mac-ai |
| `ProcessRunner` | `Sources/VoxClipCore/Services/Process/ProcessRunner.swift` | mac-ai |
| `Project` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectAI` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectAIClip` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectAIResult` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectEdits` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectExport` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectJSON` | `Sources/VoxClipCore/Domain/Shared/ProjectJSON.swift` | common (frozen; lead approval) |
| `ProjectMedia` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectPlatform` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectShare` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectStore` | `Sources/VoxClipCore/Services/Project/ProjectStore.swift` | mac-editing |
| `ProjectVoiceLab` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ProjectWriter` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `RawCompletion` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `RawToken` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `RawTranscript` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `RawWord` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `Readiness` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `Redacting` | `Sources/VoxClipCore/Services/Logging/Logger.swift` | mac-ui |
| `RedactingLogger` | `Sources/VoxClipCore/Services/Logging/Logger.swift` | mac-ui |
| `Redactor` | `Sources/VoxClipCore/Domain/Shared/Redactor.swift` | common (frozen; lead approval) |
| `ReframeSettings` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `RenderGraph` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
| `RenderInstruction` | `Sources/VoxClipMedia/Pipeline/FrameCompositor.swift` | mac-media |
| `RenderRequest` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `SettingsDocument` | `Sources/VoxClipCore/Services/Settings/SettingsStore.swift` | mac-editing |
| `SettingsStore` | `Sources/VoxClipCore/Services/Settings/SettingsStore.swift` | mac-editing |
| `SettingsView` | `Sources/VoxClip/WelcomeView.swift` | mac-ui |
| `ShapedGlyph` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `ShapedRun` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `ShapedWord` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `SharedResources` | `Sources/VoxClipCore/Services/Settings/SharedResources.swift` | mac-editing |
| `SpeakerEmbedder` | `Sources/VoxClipCore/Services/Speech/SpeakerEmbedder.swift` | mac-speech |
| `StopKind` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `StubLLMConnector` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `SyncMode` | `Sources/VoxClipCore/Domain/Shared/VoiceLab.swift` | common (frozen; lead approval) |
| `ThumbnailService` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
| `TightenEdit` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `TimedWord` | `Sources/VoxClipCore/Domain/Shared/Transcript.swift` | common (frozen; lead approval) |
| `TimeRange` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `TimingSource` | `Sources/VoxClipCore/Domain/Shared/Transcript.swift` | common (frozen; lead approval) |
| `Transcriber` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `TranscriberCapabilities` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `Transcript` | `Sources/VoxClipCore/Domain/Shared/Transcript.swift` | common (frozen; lead approval) |
| `TranscriptEngine` | `Sources/VoxClipCore/Domain/Shared/Transcript.swift` | common (frozen; lead approval) |
| `TranscriptionOptions` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `TranscriptionPlan` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `TranscriptionProgress` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `TranscriptionRequest` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `TranscriptionService` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `TranscriptionStage` | `Sources/VoxClipCore/Services/Speech/Transcriber.swift` | mac-speech |
| `TranscriptLine` | `Sources/VoxClipCore/Domain/Clips/TranscriptLines.swift` | mac-ai |
| `UpdateChecker` | `Sources/VoxClipCore/Services/Updates/UpdateChecker.swift` | mac-ui |
| `UpdateChecking` | `Sources/VoxClipCore/Services/Updates/UpdateChecker.swift` | mac-ui |
| `UpdateRelease` | `Sources/VoxClipCore/Services/Updates/UpdateChecker.swift` | mac-ui |
| `VideoCodec` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `VoxClipDocument` | `Sources/VoxClip/VoxClipDocument.swift` | mac-ui |
| `VoxClipDocument.Snapshot` | `Sources/VoxClip/VoxClipDocument.swift` | mac-ui |
| `VoxClipError` | `Sources/VoxClipCore/Domain/Shared/VoxClipError.swift` | common (frozen; lead approval) |
| `VoxClipErrorCode` | `Sources/VoxClipCore/Domain/Shared/VoxClipError.swift` | common (frozen; lead approval) |
| `WelcomeView` | `Sources/VoxClip/WelcomeView.swift` | mac-ui |
| `WhisperCppTranscriber` | `Sources/VoxClipMedia/Speech/WhisperCppTranscriber.swift` | mac-speech |
| `WordAssembler` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `WordKind` | `Sources/VoxClipCore/Domain/Shared/Transcript.swift` | common (frozen; lead approval) |

### ADR-R24 render capability integration

The app cached plan and render request, and CLI plan/export, reject an enabled synthetic piece in their selected scope before rendering. Disabled replacements and clips excluding synth retain ordinary source rendering; v2 decode/save/reopen remains supported. Parent verification: Swift build, six VoiceLab project tests, CLI plan rejection/restoration, and the app self-test (147 assertions including six render-boundary checks) passed with isolated data and no Keychain/provider calls. Media splicing and the complete Voice Lab app workflow remain pending.
### 2026-10-26 — mac-ui workspace correction (ADR-R25)

- `HomeView` replaces the historical `WelcomeView` inventory entry above. Home is an empty state inside the normal document window. A native sidebar exposes Home, Transcript and Clips; the editor keeps preview and playback beside the active task. Clip results stay above collapsible AI setup, with manual selection routed to Transcript. Captions remain in the secondary inspector. The export sheet names the selected clip or full-video scope.
- The document controller still owns deliberate new and opened project windows. The originating empty Home is captured before an asynchronous saved-project open and closes only after that open succeeds; an occupied project stays open. Same-window import retains native Save As, undo and dirty-close behavior. No project wire format, renderer, provider policy or shared fixture changed.
- Local verification used an isolated data directory and canonical `VOXCLIP_SHARED_DIR`, with live provider and model downloads disabled. `swift test --jobs 2` passed 187 Media tests and 372 Core tests. The focused mac-ui run passed 6 tests, including 141 offscreen assertions and 31 native scene checks. The scene exercised synthetic import, fake local connector readiness, manual clipping, the actual toolbar export control and attached clip sheet, caption switching, resize, Save As/reopen, undo-to-clean, Cancel on dirty close, Finder open and multiple document windows. Owned-window light/dark captures are under `/tmp/voxclip-mac-ui-evidence/final-tests/scene` and offscreen captures under `/tmp/voxclip-mac-ui-evidence/final-tests/ui`. No live service was called.

### 2026-10-26 — mac-ui connector readiness follow-up (ADR-R25)

- The Clips workspace refreshes connector readiness after key Save/Test-save/Forget and relevant AI server or CLI settings changes. Check Again retries a stopped local service, missing model, or other recoverable status in place. Find Clips stays actionable with a selected connector and transcript; the clip finder still performs the current connector preflight and consent check. A canceled older status request cannot overwrite the current selection.
- The focused Mac UI suite passed 6 tests with 141 offscreen assertions; the final native scene passed 42 checks. It checks rendered readiness and the actual Find button with fake connectors and an in-memory key store: missing key → saved key → forgotten key, stopped local service → Check Again → ready, server address change → unavailable → Check Again → ready, delayed settings load, and a delayed prior connector response. The AX checks select the owned document window. Runs used isolated data with Keychain, provider calls, and model downloads disabled. Owned-window stopped and recovered captures are under `/tmp/voxclip-mac-ui-evidence/readiness-final4/scene`.

### 2026-10-26 — combined Mac workspace and Voice Lab boundary verification

- The parent integration retains the ADR-R24 render guards and renumbers the Mac workspace decision to ADR-R25; ADR-R23 remains the Windows runtime agreement. The combined Debug build passed. The focused UI suite passed its five non-scene tests, including all 147 offscreen assertions and the synthetic local export. Evidence is under `/tmp/voxclip-main-ux-integrated/`.
- The native scene passed its first four checks, then failed its activation prerequisite before the first capture. The host reported `CGSSessionScreenIsLocked=true`; its window was visible but could not become active or key. A focused retry reproduced that prerequisite failure. The prior track's 42 native checks remain recorded above; the combined-head native scene is pending an unlocked screen. No production change or acceptance relaxation was made for the locked session.

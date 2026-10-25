# macOS implementation contracts

Baseline: 2026-10-25. The declarations in this package are the coordination boundary for parallel implementation. Read the cited specs before changing behavior. Only this directory was scaffolded; shared data and specifications remain authoritative outside it.

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

## Public type and protocol index

Paths are relative to apps/macos. Nested public types are qualified with their enclosing type. Public member signatures and documentation live at these exact paths.

| Public type / protocol | File | Owning track |
| --- | --- | --- |
| `AppleSpeechTranscriber` | `Sources/VoxClipMedia/Speech/AppleSpeechTranscriber.swift` | mac-speech |
| `AppModel` | `Sources/VoxClip/VoxClipApp.swift` | mac-ui |
| `AspectRatio` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `AudioEnvelope` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `AudioExtractionRequest` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `AudioExtractionResult` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `AudioExtractor` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `AVAudioExtractor` | `Sources/VoxClipMedia/Audio/AudioPipeline.swift` | mac-media |
| `AVExporter` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
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
| `CaptionBox` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionBoxScope` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEasing` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionEffects` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEffectsJitter` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEffectsRgbSplit` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmoji` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmojiSource` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmphasis` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionEmphasisSource` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionFont` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionFontFeatures` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionFontSizeRef` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionLayout` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionLayoutAlign` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionLayoutBalance` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionLine` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionLineBreaker` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPage` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPager` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPaint` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionPaintSpace` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionPaintStop` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionPlacement` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPoint` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionPosition` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `CaptionPreview` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionRaster` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionRasterizer` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionRasterRequest` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionRect` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionReveal` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionRevealCursor` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionRevealUnit` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionSettings` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `CaptionShadow` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStroke` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStyle` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStylePosition` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStylePositionAnchorX` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionStylePositionAnchorY` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionText` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionTextOptions` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionTextPunctuation` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionTextTransform` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionTextTransformer` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionTrack` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionWord` | `Sources/VoxClipCore/Domain/Captions/CaptionContracts.swift` | mac-captions |
| `CaptionWordBox` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionWordState` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `CaptionWordStates` | `Sources/VoxClipCore/Domain/Captions/CaptionStyle.swift` | mac-captions |
| `ClipCandidate` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipFinder` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `ClipFinderRequest` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipOrigin` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ClipPreset` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipPresetID` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipRange` | `Sources/VoxClipCore/Domain/Shared/Project.swift` | common (frozen; lead approval) |
| `ClipSuggestion` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `ClipWord` | `Sources/VoxClipCore/Domain/Clips/ClipContracts.swift` | mac-ai |
| `CompositionBuilder` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
| `ConnectorID` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `ConnectorStatus` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `CoreTextCaptionRasterizer` | `Sources/VoxClipMedia/Captions/CoreTextCaptions.swift` | mac-captions |
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
| `ExportQueue` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
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
| `GroupingRule.Conf` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `GroupingRule.End` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `GroupingRule` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
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
| `LLMConnector` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMError` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMFeature` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMModel.Source` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMModel` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMRequest` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMResult` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
| `LLMRunner` | `Sources/VoxClipCore/Services/LLM/LLMContracts.swift` | mac-ai |
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
| `OutputSpec` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `Pause` | `Sources/VoxClipCore/Domain/Editing/EditingContracts.swift` | mac-editing |
| `PixelSize` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewEngine` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewEvent` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewFrame` | `Sources/VoxClipCore/Domain/Shared/MediaContracts.swift` | common (frozen; lead approval) |
| `PreviewPlayerController` | `Sources/VoxClipMedia/Pipeline/MediaPipeline.swift` | mac-media |
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
| `VoxClipDocument.Snapshot` | `Sources/VoxClip/VoxClipDocument.swift` | mac-ui |
| `VoxClipDocument` | `Sources/VoxClip/VoxClipDocument.swift` | mac-ui |
| `VoxClipError` | `Sources/VoxClipCore/Domain/Shared/VoxClipError.swift` | common (frozen; lead approval) |
| `VoxClipErrorCode` | `Sources/VoxClipCore/Domain/Shared/VoxClipError.swift` | common (frozen; lead approval) |
| `WelcomeView` | `Sources/VoxClip/WelcomeView.swift` | mac-ui |
| `WhisperCppTranscriber` | `Sources/VoxClipMedia/Speech/WhisperCppTranscriber.swift` | mac-speech |
| `WordAssembler` | `Sources/VoxClipCore/Domain/Transcript/TranscriptContracts.swift` | mac-speech |
| `WordKind` | `Sources/VoxClipCore/Domain/Shared/Transcript.swift` | common (frozen; lead approval) |

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

### 2026-10-25 — mac-speech round 3 cache visibility and safety

- Affects mac-speech, mac-ui and mac-media: additive `TranscriptionResult` has `transcript: Transcript` and non-positional `fromCache: Bool = false`, initialized with `init(transcript:fromCache:)`. Adopt `TranscriptionService.transcribeResult(_:using:envelope:)` to show transcription §14.3's "Using the earlier ElevenLabs transcript of this file (no charge)." The flag is true for a reused ElevenLabs raw result or retained paid response. The existing `transcribe` method still returns `Transcript`; no project wire fields or frozen enums changed.
- ElevenLabs validates the bundled catalogue and cache destination before upload, alongside the request, language, model, duration, size, key and multipart constraints. Every successful HTTP response is persisted atomically before mapping or cancellation checks; the internal raw cache permits `raw: null` while mapping is pending and optionally retains exact `providerResponseBytes` for malformed JSON too. Mapping retries use those bytes without another paid call. No actor dictionary retains provider bodies, and valid mapped entries remain compatible with the prior cache format (transcription §8.1–§8.4, §14.2–§14.3).
- `SpeechProgressLimiter<Value>` is an additive public Core service shared by model downloads and both native engines. It coalesces to 10 Hz, delivers the trailing value while a job is idle and exposes `finish()` to await the final report; the duplicate native limiter was removed (transcription §13.1). ElevenLabs and whisper accept an injected `Redacting` logger so app/CLI sinks and registered secrets are used. Whisper/ggml warning and error callbacks forward at warn to `transcribe`; the process-lifetime mutex-protected box outlives the C callbacks. `SpeechRuntimeVersion.macOS` supplies exactly major.minor for the engine version and User-Agent (transcription §8.1, §9.1, §9.4, §10.5; architecture §11.1–§11.2).
- Apple asset mapping rethrows `VoxClipError` before checking the real Speech error domain and applies the same mapping to one recovery attempt. Releasing a locale uses the actual reserved `Locale` and checks the Boolean result. CAF conversion writes and closes a same-directory temporary file before atomic replacement, retaining earlier complete input on failure or cancellation (transcription §10.3–§10.4; architecture §8.2).
- Live ElevenLabs tests require `VOXCLIP_LIVE_TESTS=1` and its key; Apple tests accept that switch or `VOXCLIP_TEST_APPLE_SPEECH=1`. The live whisper download and cancellation test accepts `VOXCLIP_LIVE_TESTS=1` or `VOXCLIP_TEST_DOWNLOAD=1`. The undocumented aliases were removed (AGENTS.md Build and test; plan §1 rule 6; transcription §16.3).

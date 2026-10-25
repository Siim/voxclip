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

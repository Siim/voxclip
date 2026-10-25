# Windows fixed contracts

Baseline: **2026-10-25**. This is the handoff boundary for parallel implementers, not permission to redesign neighboring tracks. All paths below are relative to `apps/windows/`. Public source declarations are real C# types; their XML documentation cites the owning spec. The initial inventory contains 304 public declarations across 52 source files, including nested union cases and test-support types. Internal CLI wiring is separately owned by win-media.

## Ownership rules

| Track | Exclusive implementation folders |
|---|---|
| win-editing | `src/VoxClip.Core/Domain/Editing/`, `src/VoxClip.Core/Services/Project/`, `src/VoxClip.Core/Services/Settings/` |
| win-speech | `src/VoxClip.Core/Domain/Transcript/`, `src/VoxClip.Core/Services/Speech/`, `src/VoxClip.Core/Services/Models/`, `src/VoxClip.Media/Speech/` |
| win-captions | `src/VoxClip.Core/Domain/Captions/`, `src/VoxClip.Media/Captions/` |
| win-ai | `src/VoxClip.Core/Domain/Clips/`, `src/VoxClip.Core/Services/LLM/`, `src/VoxClip.Core/Services/Process/` |
| win-media | `src/VoxClip.Core/Services/Media/`, `src/VoxClip.Media/Ffmpeg/`, `src/VoxClip.Media/Pipeline/`, `src/VoxClip.Media/Audio/`, `src/VoxClip.Cli/`, `tests/VoxClip.Media.Tests/` |
| win-ui | `src/VoxClip.App/`, `src/VoxClip.Core/Services/Logging/`, `src/VoxClip.Core/Services/Updates/` |
| skeleton / lead | `src/VoxClip.Core/Domain/Shared/`, solution/build/package configuration, shared test support and common contract tests, this inventory |

- Update the existing stub **in place**; do not create alternate implementations or backup source trees. A type's owner controls its implementation, not unilateral breaking changes to public contracts.
- Each track owns its corresponding `tests/VoxClip.Core.Tests/Tracks/*PlaceholderTests.cs`. Add further track tests under a matching `Tracks/<track>/` folder to avoid collisions. Replace skip placeholders with conformance coverage when the implementation is ready.
- No track edits another track's folders without agreement. Project files, central packages, shared value types, `ProjectJsonContext`, the common test fixture loader and common test classes require lead coordination. New source files compile through SDK globs; do not edit csproj files to list ordinary C# files.
- `Domain/Shared` is deliberately frozen common value code, owned by the skeleton/lead. Project persistence details remain schema-driven. `Services/Media` holds media-free boundaries in Core, not native media implementations. Core has no third-party packages or UI/native dependencies.
- Never edit `doc/`, `shared/` or `apps/macos/` as part of a Windows implementation track. Runtime assets remain linked from `shared/`, not copied into source. Separate platform contracts share behavior through fixtures, not native code.

## How to propose a contract change

1. Append a **dated proposal** to the Change ledger below: proposed signature/type/JSON delta, owning track, affected consumers, spec section, migration/fixture impact and rationale.
2. Ask the lead and affected owners to agree before editing public declarations. A proposal is not approval; explicitly record the agreed decision and date.
3. Land producer, consumer, generated serialization metadata and test changes together. Rebuild the five-project cross-platform solution and both WinUI RIDs. Never silently rename fields, change enum wire values, remove cancellation or change ownership.
4. Update this inventory for every added/removed public type; use fully qualified nested case names. Serialized types must have source-generated metadata, never a reflection-only JsonSerializer call in AOT-compatible Core.

## Concurrency and lifecycle boundary

Long-running service contracts take `CancellationToken` and nullable `IProgress<T>` where meaningful. Pure domain math and per-frame allocation-free draw calls are synchronous; draw/compose still accept cancellation. Async resource owners use `IAsyncDisposable`. Consumers hand off immutable snapshots; they never share FFmpeg contexts across threads. UI owners dispatch progress/state changes to the UI thread. Preview and export both call `IFrameComposer.Compose`, with exactly one caption rasterizer. Finalizers may release handles only, never perform native owner-thread operations.

Stub async work throws `VoxClipException(NotImplemented, "<track-id>")`; safe startup/status placeholders return documented empty/unavailable states and do no I/O. Their absence of an exception does **not** mean a feature is implemented. `NotImplemented` is a skeleton-only code and must not ship as a new platform behavior without an agreed spec change. Native, HTTP and subprocess failures eventually map to the stable architecture §10.2 codes; logs contain redacted metadata, never provider bodies, prompts, transcript text, raw paths or keys.

## Persisted and runtime boundaries

- `Project`/`TimedWord`/`Transcript` mirror the final project schema, including required export choices, `share.captions`, clip `selected` and empty `voiceLab.segments`. The stored transcript and its timings never change during editing. `ProjectSerialization` provides strict generated decoding/basic invariants; full store cleanup, relink and atomic I/O remain win-editing work.
- `ExportPreset`/`FrameRate`/`ReframeSettings` are **runtime resolved output types**, not custom presets stored in a v1 project. Stored `ProjectExport` has only aspect, quality, SRT and folder.
- `AppSettings` preserves a **flat dotted-key** settings object through extension data, including unknown keys and `llm.model.<connector>`; there is no serialized `values` wrapper. Treat loaded mutable JSON collections as owned snapshots, not shared mutable state.
- `TranscriptEngineInfo` is stored engine metadata; `TranscriptEngine` and `EngineRef` route adapter work. They must not be substituted in the project JSON.
- Caption schema records and enum wire values are declared in `CaptionStyle.cs`; runtime layout is in `CaptionContracts.cs`. Schema `CaptionLayout` is not a second caption engine. The rasterizer consumes bundled font glyph outlines; `DrawText`/system-font fallback is forbidden.
- LLM JSON uses `RawClip` double indices (`start_word`, `end_word`) until per-item validation. Clip finding returns `AiResult`; the editor stores it and executes `AddAiClips` as one undo step. The service never silently changes edits or writes a project.
- Voice Lab and speaker embedding declarations are future placeholders only. Schema-v1 voice segments stay empty; no network calls, billing, account linking or source replacement is implemented.

## Spec reconciliations and limitations (2026-10-25)

1. **Transcript shape:** transcription §3.1 uses a compact transcript/engine enum and broader timing options, while architecture §3, editing §10 and `project.schema.json` define the portable expanded transcript with an engine metadata object and explicit per-word provenance. Persistence follows the latter; adapter routing and raw timing types remain separate. Persisted `estimated` timing is rejected, as in the project schema.
2. **Speech interface:** the transcription C# sketch omits Swift `prepare` and `needsSystemAssets`. Both are present in the cross-platform contract; Windows never implements Apple Speech, but can decode catalogue entries.
3. **Preview caption size:** architecture §6.3 describes composition at preview size; captions requires stable export-resolution layout. The contract keeps canonical export-pixel caption geometry and lets the single compose path rasterize it at a uniform preview scale. It does not introduce preview-specific reflow or a second renderer. Architecture wins on threading, module placement and output target size.
4. **Inspector tabs:** ADR-R12 describes M1 Captions/Clips only; the skeleton brief explicitly requests an AI tab. The extra tab is a disabled placeholder, not an M1 feature. No Voice Lab controls or implementation are exposed.
5. **Errors:** `NotImplemented` is explicitly required by the skeleton brief but absent from architecture §10.2. It is the sole added error code, maps to exit 1, and is documented as non-shipping. `MediaException` carries safe native return metadata while remaining a `VoxClipException`.
6. **Test runner:** the latest stable NuGet `xunit.v3` package is 4.0.2 and uses Microsoft.Testing.Platform v2. .NET 10 needs the `global.json` runner opt-in and `dotnet test --project ...`; the architecture's older positional project command is not compatible. The category filter expression is unchanged.
7. **Dependencies:** the user requires SkiaSharp 3.x and two exact Microsoft SDK pins, which override unqualified latest wording. NAudio.Wasapi 22.0.0 is unlisted, not the selected stable version. Whisper.net.Runtime includes win-arm64 and win-x64 CPU assets; NoAvx adds the x64 CPU fallback. FFmpeg.AutoGen 9.0.1.1 is paired with the pinned BtbN FFmpeg 9.0 LGPL-shared ABI, never GPL.
8. **Concurrent schema refinements:** during this handoff, shared contracts changed to simplified stored export choices, required `share.captions` and clip `selected`, flat settings and automatic addition of AI result ranges. This skeleton follows those current schemas/specs, not the older custom-export-preset/accept-only drafts. Current architecture §9 also adds `--audio-out` and the three caption rendering forms; the CLI includes all of them.
9. **Environment:** the VM has no WinUI template/global winapp tool. The checked-in scaffold builds directly with the pinned SDK; no global tooling or other VM folders were changed. FFmpeg binaries, real decoder/license loading, media conformance and release packaging are future track work. Compilation is not a claim of complete product behavior.
10. **Globalization:** the current architecture §2.3 explicitly requires ICU-backed NFC, overriding the older draft's invariant-globalization setting. `Directory.Build.props` matches the current block verbatim, leaves invariant mode unset, and a regression test checks decomposed-to-composed normalization. Cross-platform determinism uses explicit ordinal/casemap/invariant-number APIs, not runtime invariant mode.

## Public declaration inventory

Every listed declaration maps to its containing file and one owner. Nested union cases are prefixed with their parent type. Names are namespace-relative; the file declares the exact namespace. Test classes are included for completeness but are not production APIs.

| Public declarations | File | Owning track |
|---|---|---|
| `App` | `src/VoxClip.App/App.xaml.cs` | win-ui |
| `MainWindow` | `src/VoxClip.App/MainWindow.xaml.cs` | win-ui |
| `EditorPage` | `src/VoxClip.App/Pages/EditorPage.xaml.cs` | win-ui |
| `HomePage` | `src/VoxClip.App/Pages/HomePage.xaml.cs` | win-ui |
| `SettingsWindow` | `src/VoxClip.App/SettingsWindow.xaml.cs` | win-ui |
| `HomeViewModel` | `src/VoxClip.App/ViewModels/HomeViewModel.cs` | win-ui |
| `EnvironmentKeyProvider` | `src/VoxClip.Cli/EnvironmentKeyProvider.cs` | win-media |
| `ShapingRequest`, `GlyphOffset`, `ShapedRun`, `IGlyphShaper`, `MeasuredCaptionWord`, `CaptionLine`, `CaptionWordRect`, `CaptionBoxLayout`, `CaptionEmphasisedWord`, `CaptionEmojiLayout`, `CaptionPage`, `CaptionTrack`, `CaptionLayoutRequest`, `PixelBuffer`, `CaptionRenderRequest`, `ICaptionRasterizer`, `CaptionEngine`, `CaptionMath` | `src/VoxClip.Core/Domain/Captions/CaptionContracts.cs` | win-captions |
| `CaptionFont`, `CaptionText`, `CaptionLayout`, `CaptionStylePosition`, `CaptionAspectOverride`, `CaptionAspects`, `CaptionStroke`, `CaptionShadow`, `CaptionBoxShape`, `CaptionBox`, `CaptionWordBox`, `CaptionWordState`, `CaptionWordStates`, `CaptionReveal`, `CaptionAnimationSpec`, `CaptionAnimation`, `CaptionEmphasis`, `CaptionEmoji`, `CaptionEffects`, `CaptionPreview`, `CaptionStyle`, `CaptionFontFeatures`, `CaptionRevealCursor`, `CaptionEffectsRgbSplit`, `CaptionEffectsJitter`, `CaptionFontSizeRefValue`, `CaptionTextTransformValue`, `CaptionTextPunctuationValue`, `CaptionLayoutBalanceValue`, `CaptionLayoutAlignValue`, `CaptionStylePositionAnchorXValue`, `CaptionStylePositionAnchorYValue`, `CaptionBoxScopeValue`, `CaptionRevealUnitValue`, `CaptionAnimationSpecTypeValue`, `CaptionAnimationSpecEasingValue`, `CaptionEmphasisSourceValue`, `CaptionEmojiSourceValue`, `CaptionPaint`, `SolidPaint`, `LinearPaint`, `GradientStop`, `GradientSpace` | `src/VoxClip.Core/Domain/Captions/CaptionStyle.cs` | win-captions |
| `ClipPreset`, `AiClip`, `AiResult`, `RawClip`, `ClipPresetRules`, `ClipWord`, `TranscriptLine`, `ClipCandidate`, `FinalizeClipsRequest`, `FinalizeClipsResult`, `ClipValidation`, `TightenEdit`, `TightenResult` | `src/VoxClip.Core/Domain/Clips/ClipModels.cs` | win-ai |
| `Pause`, `ClipOrigin`, `ClipRange`, `EditState`, `EditSegmentKind`, `EditSegment`, `MediaInterval`, `Join`, `EditPlan`, `CaptionWord`, `EditOperation`, `EditOperation.Toggle`, `EditOperation.CutSelection`, `EditOperation.RestoreSelection`, `EditOperation.SetWordCuts`, `EditOperation.SetPauseCuts`, `EditOperation.Correct`, `EditOperation.CutFillers`, `EditOperation.TightenPauses`, `EditOperation.RestoreCuts`, `EditOperation.SetActiveClip`, `EditOperation.AddClip`, `EditOperation.AddAiClips`, `EditOperation.UpdateClip`, `EditOperation.RenameClip`, `EditOperation.SetClipSelected`, `EditOperation.RemoveClip`, `EditOperation.SetPauseKeep`, `EditOperation.SetPauseThreshold`, `EditSummary`, `EditingEngine`, `EditHistory` | `src/VoxClip.Core/Domain/Editing/EditingModels.cs` | win-editing |
| `ExportAspect`, `ExportQuality`, `FrameRate`, `FrameRateJsonConverter`, `ExportPreset`, `ReframeSettings`, `ExportPresets` | `src/VoxClip.Core/Domain/Shared/ExportPreset.cs` | skeleton / lead |
| `MediaInfo`, `AudioExtractionRequest`, `MediaProgress`, `ComposeSnapshot`, `OutputSpec`, `ExportTarget`, `ExportTarget.FullEdit`, `ExportTarget.Clip`, `ExportJob`, `ExportProgress`, `ExportResult`, `PreviewFrame`, `PreviewPosition`, `EncoderInfo`, `EncoderCacheKey` | `src/VoxClip.Core/Domain/Shared/MediaModels.cs` | skeleton / lead |
| `Project`, `SavedBy`, `ProjectMedia`, `MediaReference`, `VideoTrackInfo`, `AudioTrackInfo`, `ProjectEdits`, `ProjectCaptions`, `ProjectExport`, `ProjectShare`, `ProjectAi`, `VoiceLabPlaceholder` | `src/VoxClip.Core/Domain/Shared/Project.cs` | skeleton / lead |
| `ProjectJsonContext`, `UtcTimestampConverter` | `src/VoxClip.Core/Domain/Shared/ProjectJsonContext.cs` | skeleton / lead |
| `ProjectSerialization` | `src/VoxClip.Core/Domain/Shared/ProjectSerialization.cs` | skeleton / lead |
| `IRedactor`, `Redactor` | `src/VoxClip.Core/Domain/Shared/Redactor.cs` | skeleton / lead |
| `TimedWord`, `WordKind`, `PixelSize`, `CaptionPosition`, `RectD`, `PointD`, `TimeRange` | `src/VoxClip.Core/Domain/Shared/TimedWord.cs` | skeleton / lead |
| `VersionComparison` | `src/VoxClip.Core/Domain/Shared/VersionComparison.cs` | skeleton / lead |
| `VoxClipErrorCode`, `VoxClipException`, `MediaException` | `src/VoxClip.Core/Domain/Shared/VoxClipException.cs` | skeleton / lead |
| `Transcript`, `TranscriptEngineInfo`, `TranscriptEngine`, `TimingSource`, `BoundaryRefinement` | `src/VoxClip.Core/Domain/Transcript/Transcript.cs` | win-speech |
| `TranscriptJsonContext` | `src/VoxClip.Core/Domain/Transcript/TranscriptJsonContext.cs` | win-speech |
| `EngineRef`, `RawToken`, `RawTranscript`, `RawWord`, `GroupingEnd`, `GroupingConfidence`, `GroupingRule`, `LanguageChoice`, `LanguageChoice.Auto`, `LanguageChoice.Forced`, `TranscriptionOptions`, `TranscriptionPlan`, `ExtractedAudio`, `TranscriptionRequest`, `TranscriptionStage`, `TranscriptionProgress`, `TranscriberCapabilities`, `Readiness`, `Readiness.Ready`, `Readiness.NeedsKey`, `Readiness.NeedsModels`, `Readiness.NeedsSystemAssets`, `Readiness.UnsupportedLanguage`, `Readiness.Unavailable`, `AudioEnvelope`, `WordAssembler`, `TranscriptPostProcessor` | `src/VoxClip.Core/Domain/Transcript/TranscriptionModels.cs` | win-speech |
| `ClipFinderRequest`, `ClipFinderProgress`, `IClipFinder`, `ClipFinder` | `src/VoxClip.Core/Services/LLM/ClipFinder.cs` | win-ai |
| `ConnectorId`, `LlmFeature`, `Effort`, `ModelSource`, `LlmRequest`, `StopKind`, `StopKind.Complete`, `StopKind.Truncated`, `StopKind.Refused`, `LlmUsage`, `RawCompletion`, `LlmResult`, `LlmModel`, `ConnectorStatus`, `ConnectorStatus.Ready`, `ConnectorStatus.NeedsKey`, `ConnectorStatus.NotRunning`, `ConnectorStatus.NoModels`, `ConnectorStatus.Unavailable`, `ConnectorStatus.CliMissing`, `ConnectorStatus.CliTooOld`, `ConnectorStatus.CliSignedOut`, `ILlmConnector`, `IKeyProvider`, `LlmErrorKind`, `LlmError`, `LlmException`, `LlmCatalog`, `LlmRunner`, `LlmConnector` | `src/VoxClip.Core/Services/LLM/LlmContracts.cs` | win-ai |
| `LlmJsonContext` | `src/VoxClip.Core/Services/LLM/LlmJsonContext.cs` | win-ai |
| `CostEstimate`, `LipsyncTier`, `LipsyncModel`, `SyncMode`, `LipsyncOptions`, `LipsyncJob`, `LipsyncState`, `LipsyncState.Queued`, `LipsyncState.Running`, `LipsyncState.Done`, `LipsyncState.Failed`, `ILipsyncProvider` | `src/VoxClip.Core/Services/LLM/VoiceLabContracts.cs` | win-ai |
| `LogLevel`, `LogEntry`, `ILog`, `Log` | `src/VoxClip.Core/Services/Logging/Log.cs` | win-ui |
| `IMediaProbe`, `IAudioExtractor`, `AudioExtractionResult`, `IPreviewEngine`, `IExporter`, `IEncoderProbe`, `IFrameComposer` | `src/VoxClip.Core/Services/Media/MediaContracts.cs` | win-media |
| `ModelFile`, `TranscriptionModel`, `InstalledModel`, `ModelDownloadProgress`, `IModelCatalog`, `IModelDownloader`, `ModelCatalog`, `ModelStore` | `src/VoxClip.Core/Services/Models/ModelContracts.cs` | win-speech |
| `ModelsJsonContext` | `src/VoxClip.Core/Services/Models/ModelsJsonContext.cs` | win-speech |
| `ProcessRequest`, `ProcessResult`, `ProcessProgress`, `IProcessRunner`, `ProcessRunner` | `src/VoxClip.Core/Services/Process/IProcessRunner.cs` | win-ai |
| `ProjectOpenResult`, `IProjectStore`, `ProjectStore` | `src/VoxClip.Core/Services/Project/IProjectStore.cs` | win-editing |
| `SharedResources`, `DataLocations` | `src/VoxClip.Core/Services/Project/SharedResources.cs` | win-editing |
| `AppSettings`, `ISettingsStore`, `SettingsStore` | `src/VoxClip.Core/Services/Settings/ISettingsStore.cs` | win-editing |
| `SettingsJsonContext` | `src/VoxClip.Core/Services/Settings/SettingsJsonContext.cs` | win-editing |
| `ISpeakerEmbedder` | `src/VoxClip.Core/Services/Speech/ISpeakerEmbedder.cs` | win-speech |
| `ITranscriber`, `ElevenLabsTranscriber`, `ITranscriptionService`, `TranscriptionService` | `src/VoxClip.Core/Services/Speech/ITranscriber.cs` | win-speech |
| `UpdateInfo`, `IUpdateChecker`, `UpdateChecker` | `src/VoxClip.Core/Services/Updates/IUpdateChecker.cs` | win-ui |
| `WasapiAudioPlayer` | `src/VoxClip.Media/Audio/WasapiAudioPlayer.cs` | win-media |
| `HarfBuzzGlyphShaper`, `SkiaCaptionRasterizer` | `src/VoxClip.Media/Captions/HarfBuzzGlyphShaper.cs` | win-captions |
| `FfmpegLoader` | `src/VoxClip.Media/Ffmpeg/FfmpegLoader.cs` | win-media |
| `FfmpegMediaProbe`, `FfmpegAudioExtractor`, `PreviewEngine`, `Exporter`, `FrameComposer`, `EncoderProbe` | `src/VoxClip.Media/Pipeline/MediaPipeline.cs` | win-media |
| `WhisperNetTranscriber` | `src/VoxClip.Media/Speech/WhisperNetTranscriber.cs` | win-speech |
| `FixtureLoader` | `tests/Support/FixtureLoader.cs` | skeleton / lead |
| `SharedContractTests` | `tests/VoxClip.Core.Tests/SharedContractTests.cs` | skeleton / lead |
| `AiPlaceholderTests` | `tests/VoxClip.Core.Tests/Tracks/AiPlaceholderTests.cs` | win-ai |
| `CaptionsPlaceholderTests` | `tests/VoxClip.Core.Tests/Tracks/CaptionsPlaceholderTests.cs` | win-captions |
| `EditingPlaceholderTests` | `tests/VoxClip.Core.Tests/Tracks/EditingPlaceholderTests.cs` | win-editing |
| `SpeechPlaceholderTests` | `tests/VoxClip.Core.Tests/Tracks/SpeechPlaceholderTests.cs` | win-speech |
| `UiPlaceholderTests` | `tests/VoxClip.Core.Tests/Tracks/UiPlaceholderTests.cs` | win-ui |
| `MediaContractTests` | `tests/VoxClip.Media.Tests/MediaContractTests.cs` | win-media |

## Change ledger

- **2026-10-25 — Initial skeleton baseline (skeleton / lead):** created the contracts above against the current specifications; reconciliations are listed explicitly. This establishes the fixed parallel implementation boundary. Subsequent changes use the proposal process above; this does not authorize unrelated spec changes.
- **Future proposal template:** `YYYY-MM-DD — track — Proposed/Approved/Rejected — old signature → new signature; affected consumers; spec evidence; lead/owner decision; tests and migration impact`.

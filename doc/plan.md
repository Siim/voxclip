# VoxClip implementation plan

Status: M1 preview baseline and continuation of the full requested product. Updated 2026-10-26. Owner: the lead.

This plan splits M1 into seven tracks. Each track is built by one implementer in its own git worktree and owns a disjoint set of paths. Section 4 fixes the public API between tracks, so dependent tracks start at the same time against the same signatures. Section 5 holds the brief for each track. The orchestrator hands out these briefs as they are. Section 6 is the 0.1.0 release checklist.

M1 is everything the specs mark M1 or 0.1.0: import, transcription (three engines), word editing, clips (manual and AI), captions (19 styles), export (source, 16:9, 9:16, 1:1), the share helpers, update checks, the CLI, release packaging on both platforms, and the voxconvo.com download page. M2 and M3 surfaces remain absent from the M1 preview until implemented. They remain part of the continuation below; the milestone split does not complete or reduce the user's request.

## 0. Full scope and current delivery status

The original request includes turning a rough vlog into better wording with the user's chosen LLM, speaking the revision in their own cloned voice, voice changing, and lip-sync. A cut-only editor or a signed M1 preview does not satisfy that workflow. The earlier deferral of full-take re-voicing in the Voice Lab spec is superseded by this scope clarification: passage and full-take rewriting and re-voicing remain required work. Consent, explicit paid actions, preservation of original media, and review before applying generated results still apply.

Status on 2026-10-26 distinguishes implemented code, local test evidence, and delivery:

| Requested area | Current state | Remaining work |
|---|---|---|
| Native Swift/SwiftUI Mac and .NET/WinUI Windows apps | Import, transcription, word editing, manual/AI clips, preview, project save/reopen and export are integrated | Combined release acceptance, real-device workflows and accessibility/performance checks |
| Clipping workspace and startup | Both workspace corrections are integrated: Mac Home/import shares the document window; Windows exposes clipping, preserves keyboard focus, handles file and no-file reactivation, and saves projects/settings before update restart. Normal open, same-window Recent reopen and repeated native fake-dispatch probes passed | Installed updater termination, final packaged workflows, spoken Narrator and remaining text-field shortcut coverage, and combined Mac native scene rerun after the host is unlocked |
| Bring your own LLM | Catalog-backed cloud, local and CLI connectors are wired for clip finding | Live-provider acceptance and rewrite workflow integration |
| ElevenLabs key and local speech models | Transcription routes and secure key storage are integrated | Real local-model quality and explicit live-provider acceptance |
| Caption burner and styles | Shared preview/export composition, 19 styles and 300 cross-platform golden samples | Quiet-host timing and hosted CI on the final combined revision |
| Signed apps | Signed and notarized local Mac 0.1.0 build 1 preview produced; it predates the workspace redesign | Refreshed signed Mac preview, signed Windows preview and public-release acceptance |
| Open-source monorepo | Public MIT repository contains both native apps, shared data and specs | Continue shipping corresponding source and complete bundled payload notices |
| VoxConvo download page | Local page and redirect changes are implemented and tested | Deployment and published downloadable artifacts |
| VoxConvo, X and LinkedIn integration | Export/share helpers exist | VoxConvo sign-in/upload/publish and integrated sharing acceptance; composer links do not establish direct upload |
| AI rewrite, own-voice clone and voice changer | Both native Core services, shared offline contracts, reversible v2/v3 projects, explicit candidate render recipes, deterministic full/clip plans, pure disclosure, paid-audio snapshot validation and the audited Windows atempo runtime are integrated; active synth is explicitly blocked at legacy render boundaries | Native audio/video composition, production fit and asset lifecycle acceptance, visible/XMP/sidecar disclosure, consent recording and speaker verification, bounded full-take generation, preview/accept/undo and UI |
| Lip-sync | Spec and interface seams only | Provider adapter, jobs/cancellation, media integration, disclosure and end-to-end acceptance |

Native composition is under review on both platforms. The reviewed disclosure helper handoff is not integrated; ADR-R27 approves its post-mux XMP staging route while production composition and transaction checks remain open. The minimal Windows `atempo` runtime is integrated after reproducible builds, licence review, 26 graph cases and the unchanged strict shipping selection on native ARM64 and x64 under ARM64 emulation. Raw output counts and marker positions still require production handle/trim/seam acceptance; the runtime pass does not establish that behavior.

The agreed follow-on specs also contain AI tighten, Clean audio, camera/microphone recording and expanded ingest. These are still open; a reserved type or protocol is not an implementation.

Continuation order:

1. Finish the current preview acceptance fixes in parallel with feature development: integrate the reviewed workspace changes, preserve Windows colour correctness while checking conversion performance, and validate the current installed runtime agreement and notices, then run combined hosted CI. The reviewed optimized Windows decoder is integrated after both RIDs passed 22 converter, 49 strict shipping and two cleanup tests without skips. x64 ran under ARM emulation; E2E times improved to 58.74 seconds on x64 and 25.63 seconds on native ARM64, while physical-device performance acceptance remains open. Preserve encoder contracts and fixture thresholds.
2. Retain the integrated rewrite and ElevenLabs Core request-binding contracts on both platforms, and connect them to the native workflow with separate review and approval for each paid action. Live-provider and real local-model acceptance remain separate from offline tests.
3. Use the integrated v3 recipes and paid-audio snapshots in the existing native preview/export composition paths, with matching captions and mandatory visible/XMP/provenance disclosure. Support both passage and full-take revisions. Verify production pitch-preserving fit with the audited Windows atempo runtime and Mac TimePitch, including actual body, handle and seam timing; ordinary resampling is not a substitute. Add native UI and verify save/reopen, preview, accept, disable, undo and export.
4. Implement lip-sync using a verified provider API with explicit user selection, cost preview and cancellation. Do not assume speech synthesis alone supplies lip-sync. Complete the recording, Clean audio, AI tighten and ingest work recorded in the topic specs.
5. Complete VoxConvo authentication and publishing, deploy the download integration, and validate sharing. Prepare signed artifacts and draft releases under the release policy; a human publishes public releases.

The original M1 track briefs below remain the baseline for their assigned work. New continuation briefs explicitly expand ownership and deliverables; their M1-only exclusions must not be used to discard the original full product scope.

## 1. Rules for every track

1. **Worktree and paths.** Work only in your track's worktree (branch `m1/<track-id>`), and change only the paths your brief lists. You may read everything. Never edit `doc/`, another track's paths, `apps/*/CONTRACTS.md`, `apps/macos/Package.swift`, `apps/macos/Package.resolved`, the Windows solution and props files (`VoxClip.slnx`, `VoxClip.CrossPlatform.slnf`, `Directory.Build.props`, `Directory.Packages.props`, `global.json`, the Core, Media and test `.csproj` files), the root `THIRD_PARTY_NOTICES.md`, `LICENSE`, `AGENTS.md`, `CHANGELOG.md` or `.gitignore`. These belong to the lead.
2. **Specs are normative.** Read the documents your brief names before you write code. If a spec is wrong, ambiguous or contradicts another, do not edit `doc/`. Implement the most literal reading that passes the shared fixtures, mark the place with `TODO(<track-id>): spec question`, and list it in your final report.
3. **Contracts.** The scaffold contracts (`apps/macos/CONTRACTS.md`, `apps/windows/CONTRACTS.md` and the declarations they index) plus section 4 of this plan are fixed. Source-compatible additions inside your own paths are allowed: new types, new members, and new trailing parameters with default values. Any other change to a public signature, a JSON wire name or an enum value is a contract change. Do not make it. Put the proposal (old and new signature, affected tracks, spec section, reason) in your final report and continue with other work.
4. **Shared data.** `shared/` is the source of truth. Read it at runtime through `SharedResources`; never copy it into an app folder. Only the `tooling` and `parity` tracks write under `shared/`, and only the paths their briefs list.
5. **Fixtures decide.** A behaviour both apps share is done when it passes the shared fixtures on both platforms. Required M1 fixture files and native test projects are CI prerequisites: absence fails the job. Local optional runs may skip unavailable inputs only with the missing path in the skip message; `VOXCLIP_REQUIRE_NATIVE=1` and `VOXCLIP_REQUIRE_E2E=1` turn missing native and canonical CLI inputs into failures. A test must never pass without checking anything.
6. **Secrets and network.** Never write a key, token, password or the contents of an `.env` or signing file anywhere: code, tests, fixtures, logs, reports. Refer to secrets by variable name and file location only. Default test runs make no network calls and download nothing. Live tests run only with `VOXCLIP_LIVE_TESTS=1`, model downloads only with `VOXCLIP_TEST_DOWNLOAD=1`, and both read keys from the `VOXCLIP_*_API_KEY` variables (architecture section 9.4).
7. **Licences.** Follow AGENTS.md rule 4, including only its specific pinned runtime exceptions in ADR-029 and ADR-030. No other GPL or proprietary code, fonts or binaries. Do not add a dependency. If you need one, propose it in your report; the lead pins it and adds its notice.
8. **Stubs.** Replace the scaffold stubs in place. Do not leave duplicate implementations, backup files or dead code. Remove a track placeholder test only when real tests replace it. At hand-off, no M1 path you own may still throw `notImplemented`. Seams the specs mark M2 or M3 (lipsync, speaker embedding, AI tighten, cost estimates) stay as stubs.
9. **Git.** Do not merge, rebase, push or touch other branches; the lead merges. Commit messages follow AGENTS.md: imperative subject of at most 72 characters, a body that names the spec section, and no AI attribution of any kind.
10. **Final report.** End with a report that lists what is done, the exact verification commands you ran with their results, the skipped tests and why, the spec questions (rule 2), contract proposals (rule 3), and every check you could not run (for example Windows-only checks without a Windows machine).

## 2. Phase 0: lead pre-flight (before any worktree is created)

1. Check that both scaffolds are committed (the Windows skeleton landed in commit `975471a`) and that both baselines pass: `cd apps/macos && swift build && swift test`, and `cd apps/windows && dotnet build VoxClip.CrossPlatform.slnf -c Release && dotnet test --project tests/VoxClip.Core.Tests -c Release`.
2. Check that no `apps/windows/build/skeleton.tar` or other build archive is tracked (the root `.gitignore` now ignores `*.tar` and `*.tar.xz`).
3. Check that `apps/windows/Directory.Build.props` does not set `InvariantGlobalization` (ADR-R19).
4. Add `Whisper.net.Runtime.Vulkan` `1.9.1` to `Directory.Packages.props` and reference it from `src/VoxClip.Media/VoxClip.Media.csproj` (transcription.md section 9; the version exists on nuget.org).
5. Merge the licence texts from `apps/macos/THIRD_PARTY_NOTICES.md` and `apps/windows/THIRD_PARTY_NOTICES.md` into the root `THIRD_PARTY_NOTICES.md`, delete the two per-app files, and fix the links in both app READMEs (AGENTS.md rule 4: one notices file).
6. Land the contract changes of sections 4.1.2 and 4.2.2 as compiling stubs: exact signatures, bodies that throw `notImplemented` with the owning track id. Then append a dated entry to both `CONTRACTS.md` files: "plan.md section 4 approved; mac-editing, mac-speech, mac-captions and mac-ai are the mac-core track; mac-media and mac-ui are the mac-app track (same for Windows)". Also replace Windows reconciliation item 1, since transcription.md section 3.1 now matches the schema. If the lead prefers, the core tracks write these stubs as their first commit instead; the app tracks then start once the lead has merged that commit.
7. Commit, then create one worktree per track from that commit.

## 3. Tracks and order

| Id | Title | Depends on | Main output |
|---|---|---|---|
| `tooling` | Shared tools and fixtures | none | design-token generator, version scripts, LLM, transcription, media and camera fixtures |
| `mac-core` | macOS core: editing, transcription, captions, AI | `tooling` (fixtures, section 4.4) | `VoxClipCore` domain and services, CoreText captions, whisper.cpp, Apple Speech, Foundation Models |
| `mac-app` | macOS media pipeline, app, CLI and packaging | `mac-core` (section 4.1), `tooling` (tokens, media fixtures) | AVFoundation pipeline, SwiftUI app, `voxclip-cli`, `bundle.sh` |
| `win-core` | Windows core: editing, transcription, captions, AI | `tooling` (fixtures, section 4.4) | `VoxClip.Core` domain and services, HarfBuzz and Skia captions, Whisper.net |
| `win-app` | Windows media pipeline, app, CLI and packaging | `win-core` (section 4.2), `tooling` (tokens, media fixtures) | FFmpeg pipeline, WinUI 3 app, `voxclip-cli.exe`, Velopack, release scripts |
| `parity` | Cross-platform parity and CI | `mac-app`, `win-app`, `mac-core`, `win-core` (section 4.3) | caption goldens, end-to-end comparison, CI wiring |
| `vox-site` | voxconvo.com download page and redirects | none | `/download` page and `302` redirects in vox-web |

All seven tracks start together. A dependency means "codes against the contract in section 4", not "waits for".

Merge order:

1. `tooling`: the token generator and both generated token files first, as a separate small merge on day one, because the app UIs reference the tokens. The fixtures follow as they are ready.
2. `mac-core` and `win-core`: merge in increments (editing, captions, transcription, AI). The app tracks rebase on each merge.
3. `mac-app` and `win-app`.
4. `parity`: the integrated CI requires current test projects, canonical media fixtures, caption assets, and plan and E2E reports. Earlier scaffold guards no longer waive these requirements.
5. `vox-site` merges in the vox-web repository whenever it is ready; its deployment setting follows ADR-R17 (section 6).

Each core track covers four scaffold sub-areas: editing, speech, captions and ai. If one track is too large, the lead may split it along the scaffold's sub-track folders (`apps/*/CONTRACTS.md`, "Ownership"). No contract changes in that case, and the brief's acceptance list splits by the same folders.

## 4. Contracts between tracks

### 4.1 macOS: what `mac-app` uses from `mac-core`

#### 4.1.1 Existing API (binding; full declarations in `apps/macos/Sources`, indexed in `apps/macos/CONTRACTS.md`)

```swift
// Domain/Shared (frozen value types; owned by mac-core): Project, ProjectMedia, MediaReference, MediaVideo, MediaAudio,
// ProjectEdits, ClipRange, ClipOrigin, CaptionSettings, CaptionPosition, ProjectExport, AspectRatio, ExportQuality,
// ExportPreset, ProjectShare, ProjectAI, ProjectAIResult, ProjectAIClip, Transcript, TimedWord, WordKind, TimingSource,
// EngineRef, TranscriptEngine, JSONValue, ProjectJSON, Redactor, compareVersions, VoxClipError, VoxClipErrorCode,
// and the media protocols mac-app implements: MediaProbe, AudioExtractor, PreviewEngine, Exporter with
// MediaProbeResult, AudioExtractionRequest, AudioExtractionResult, RenderRequest, OutputSpec, PixelSize,
// ExportJob, ExportTarget, ExportProgress, ExportPhase, ExportResult, PreviewEvent, PreviewFrame.

// Editing (Domain/Editing/EditingContracts.swift)
public struct EditState { transcript, pauses, pauseThresholdSeconds, pauseKeepSeconds, cutWordIds, cutPauseIds, corrections, clips, activeClipId }
public enum EditCommand { case toggle(id:), cutSelection(ids:), restoreSelection(ids:), cutFillers, tightenPauses, restoreCuts,
  correct(id:text:), setActiveClip(clipId:), addClip(ClipRange), addAIClips(resultId:clips:), updateClip(id:startIndex:endIndex:),
  renameClip(id:title:), setClipSelected(id:selected:), removeClip(id:), setPauseKeep(seconds:), setPauseThreshold(seconds:) }
public enum EditReducer { public static func reduce(_ state: EditState, command: EditCommand) -> EditState }
public struct EditHistory { public init(state: EditState); public private(set) var state: EditState
  public var canUndo: Bool; public var canRedo: Bool
  public mutating func apply(_ command: EditCommand); public mutating func undo(); public mutating func redo() }
public struct EditPlan { sampleRate: Double, totalSamples: Int64, cuts: [MediaInterval], kept: [MediaInterval], outputSamples: Int64, joins: [Join]
  public var duration: Double
  public static func build(transcript: Transcript, editState: EditState, activeClip: ClipRange?, duration: Double, sampleRate: Double) throws -> EditPlan
  public func mapTime(_ source: Double) -> Double; public func sourceTime(_ edited: Double) -> Double; public func joinGain(at sample: Int64) -> Double }
public struct EditSummary { fillerCount, cutWordCount, pauseCount, cutPauseCount: Int; canCutFillers, canTighten, hasEdits, canExport: Bool }
public func clipTimes(_ words: [TimedWord], startIndex: Int, endIndex: Int) throws -> TimeRange

// Transcription (Services/Speech, Services/Models, Domain/Transcript, VoxClipMedia/Speech)
public protocol Transcriber: Sendable { var engine: TranscriptEngine { get }
  func capabilities(model: String?) -> TranscriberCapabilities; func supports(_ language: LanguageChoice, model: String?) async -> Bool
  func readiness(for plan: TranscriptionPlan) async -> Readiness
  func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws
  func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript }
public actor TranscriptionService { public init()
  public func transcribe(_ request: TranscriptionRequest, using engine: any Transcriber, envelope: AudioEnvelope?) async throws -> Transcript
  public func progress() -> AsyncStream<TranscriptionProgress> }
public struct TranscriptionPlan { init(engine: TranscriptEngine, model: String? = nil, language: LanguageChoice = .auto, options: TranscriptionOptions = .init()) }
public struct TranscriptionRequest { init(plan: TranscriptionPlan, audio: ExtractedAudio, contentKey: String) }
public struct ExtractedAudio { init(wav16k: URL, sampleCount: Int64, durationSeconds: Double, timelineStart: Double = 0, audioTrackIndex: Int = 0) }
public enum LanguageRouter { public static func route(language: LanguageChoice, preferred: TranscriptEngine, installedModels: [String]) throws -> TranscriptionPlan }
public actor ElevenLabsTranscriber: Transcriber { public init(keys: any KeyProvider) }
public actor WhisperCppTranscriber: Transcriber { public init() }          // VoxClipMedia
public actor AppleSpeechTranscriber: Transcriber { public init() }         // VoxClipMedia
public protocol ModelCatalog { func models() async throws -> [ModelDescriptor]; func model(id: String) async throws -> ModelDescriptor }
public protocol ModelDownloader { func installedModels() async throws -> [String]
  func install(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
  func verify(id: String) async throws -> Bool; func remove(id: String) async throws }
public actor BundledModelCatalog: ModelCatalog { public init(shared: SharedResources) }
public actor ModelStore: ModelDownloader { public init(catalog: any ModelCatalog, locations: DataLocations) }

// Project, settings, resources, cache (Services/Project, Services/Settings)
public protocol ProjectStore: Sendable { func load(from url: URL) async throws -> Project
  func save(_ project: Project, to url: URL) async throws; func resolveSource(for project: Project, projectURL: URL) async throws -> URL }
public actor JSONProjectStore: ProjectStore { public init() }
public protocol SettingsStore: Sendable { func load() async throws -> SettingsDocument; func save(_ settings: SettingsDocument) async throws; func flush() async throws }
public actor JSONSettingsStore: SettingsStore { public init() }
public struct SettingsDocument { public var values: [String: JSONValue] }
public struct SharedResources { public let root: URL; public static func locate(environment:executableURL:bundleURL:) throws -> SharedResources }
public struct DataLocations { settings, models, cache: URL; public init(environment:home:) }
public actor CacheStore { public init(locations: DataLocations)
  public func entry(contentKey: String) async throws -> CacheEntry?; public func evict(limitBytes: Int64, protectedKeys: Set<String>) async throws }

// Captions (Domain/Captions, VoxClipMedia/Captions)
public protocol GlyphShaper: Sendable { func shape(_ request: GlyphShapeRequest) async throws -> [ShapedRun] }
public protocol CaptionRasterizer: Sendable { func rasterize(_ request: CaptionRasterRequest) async throws -> CaptionRaster }
public struct CaptionRasterRequest { init(page: CaptionPage, style: CaptionStyle, time: Double, width: Int, height: Int, reduceMotion: Bool = false) }
public struct CaptionRaster { width, height, bytesPerRow: Int; rgba: Data }   // premultiplied RGBA (captions 13.1); composite(into:) blends it into a BGRA frame
public struct CaptionTrack { words: [CaptionWord]; pages: [CaptionPage] }
public struct CaptionTextOptions { init(uppercase: Bool = false, removePunctuation: Bool = false) }
public actor CoreTextShaper: GlyphShaper { public init(shared: SharedResources) }
public actor CoreTextCaptionRasterizer: CaptionRasterizer { public init(shared: SharedResources) }   // the only rasterizer

// AI (Services/LLM, Services/Process, Domain/Clips, VoxClipMedia/Intelligence)
public protocol LLMConnector: Sendable { var id: ConnectorID { get }; func status() async -> ConnectorStatus
  func models(refresh: Bool) async throws -> [LLMModel]; func contextTokens(model: String) async -> Int?
  func send(_ request: LLMRequest, model: String) async throws -> RawCompletion }
public protocol KeyProvider: Sendable { func key(for provider: String) async throws -> String? }
public actor LLMRunner { public init(keys: any KeyProvider, catalog: LLMCatalog, log: any Redacting)
  public func run(_ request: LLMRequest, on connector: any LLMConnector, model: String) async throws -> LLMResult }
public actor ClipFinder { public init(runner: LLMRunner, shared: SharedResources); public func presets() async throws -> [ClipPreset] }
public struct ClipFinderRequest { init(transcript:corrections:cutWordIds:preset:instruction:snap:) }
public protocol ProcessRunner: Sendable { func run(_ request: ProcessRequest) async throws -> ProcessResult }
public struct FoundationProcessRunner: ProcessRunner { public init() }
public actor FoundationModelsConnector: LLMConnector { public init() }   // VoxClipMedia, id .appleFoundation
```

#### 4.1.2 Additions and changes (mac-core implements; signatures fixed here)

```swift
// M1. Audio analysis, editing.md 5.1 (Domain/Editing/AudioAnalysis.swift). The extractor feeds every decoded
// Float32 sample at the source rate; finish() returns level[] exactly as editing 5.1 defines it, frameSeconds 0.01.
public struct AudioEnvelopeBuilder: Sendable {
    public init(sampleRate: Double, channels: Int)
    public mutating func append(interleaved samples: UnsafeBufferPointer<Float>)   // any length; frames may span calls
    public func finish() -> AudioEnvelope
}

// M2. Scoped counts and gates, editing.md 6.4 (Domain/Editing).
extension EditSummary { public static func summarize(_ state: EditState) -> EditSummary }

// M3. Project bridge, editing.md 10.4 to 10.7 (Domain/Editing/ProjectBridge.swift).
extension EditState {
    /// nil when project.transcript is nil (the untranscribed state). Pauses are derived (editing 5.7) with
    /// edits.pauseThresholdSeconds; the edits are copied as stored.
    public static func from(_ project: Project) throws -> EditState?
}
extension Project {
    /// Copies the persisted subset of `state` into `edits` and drops `share.captions` entries whose clip no longer exists.
    public func applying(_ state: EditState) -> Project
}
/// Edited caption words after cuts and corrections, on the edited timeline (captions 8.1).
public func captionWords(_ state: EditState, plan: EditPlan) throws -> [CaptionWord]

// M4. Document coding, editing.md 10.1 to 10.4 (Services/Project). The macOS document (NSDocument / DocumentGroup)
// uses these; JSONProjectStore.load/save are file I/O around them.
extension JSONProjectStore {
    public static func decode(_ data: Data) throws -> Project     // checks, migrations, reference cleanup (10.4)
    public static func encode(_ project: Project) throws -> Data   // canonical encoding (10.1); cut ids in transcript order; pruning (10.6, 10.7)
}

// M5. Export sizing, architecture.md 4.1 (Domain/Shared/OutputSizing.swift; mirrors Windows ExportPresets).
// Tested against shared/fixtures/export/presets.json.
public enum OutputSizing {
    public static func outputSize(source: PixelSize, aspect: AspectRatio) -> PixelSize
    public static func centerCrop(source: PixelSize, output: PixelSize) -> CaptionRect   // x, y, width, height in oriented source pixels (Core may not import CoreGraphics)
    public static func outputFrameRate(_ sourceRate: Double) -> Double
    public static func videoBitrate(size: PixelSize, aspect: AspectRatio, quality: ExportQuality, fps: Double) -> Int
}

// M6. Caption styles, captions.md 2.4 (Services/Settings/CaptionStyleLibrary.swift; Domain/Captions).
public struct CaptionStyleLibrary: Sendable {
    public init(shared: SharedResources) throws          // strict typed decoding of caption-styles/styles/*.json
    public var styles: [CaptionStyle] { get }           // sorted by `order`
    public func style(id: String) -> CaptionStyle?
}
extension CaptionStyle {
    /// Project overrides (RFC 7396 merge patch) and the aspect override for `frame`, in the order captions 2.4 defines.
    public func resolved(overrides: [String: JSONValue], frame: PixelSize) throws -> CaptionStyle
}

// M7. Caption layout, captions.md 3 to 13 (decided 2026-10-25; supersedes the earlier CaptionLayoutEngine.layout sketch).
// The frozen CaptionTrack.build, CaptionPager.pages, CaptionLineBreaker.lines, CaptionPlacement.place and the 3-argument
// CaptionTextTransformer.apply cannot express the pipeline (no frame, font metrics or async shaping). They are deprecated
// and removed once mac-media and mac-ui call CaptionPipeline.
public actor CaptionPipeline {                            // VoxClipMedia/Captions; loads CaptionResources once, caches shaping
    public init(shared: SharedResources) throws
    public func layout(words: <editing 7.6 caption copy>, language: String?, style: CaptionStyle /* resolved */,
                       position: CaptionPosition?, frame: PixelSize, duration: Double) async throws -> CaptionLayoutResult
}
extension CaptionLayoutResult /* Domain, Equatable, Sendable */ {
    public var track: CaptionTrack { get }                // lightweight projection for SRT and compatibility
    public func page(at editedTime: Double) -> CaptionPage?   // captions 8.1
    // plus `dropped` (sourceIndex, text, reason "empty" | "no-glyphs") for the inspector note
}
extension RenderRequest { public var captionLayout: CaptionLayoutResult? }   // additive, trailing init parameter = nil
extension CoreTextCaptionRasterizer {                     // band-only composite into the locked BGRA buffer; safe for concurrent frames
    public func draw(_ layout: CaptionLayoutResult, time: Double, into pixelBuffer: CVPixelBuffer,
                     previewWidth: Int? = nil, reduceMotion: Bool = false) throws
}

// M8. Connectors, ai.md 3 and 6 (Services/LLM/LLMConnectors.swift).
extension LLMCatalog { public static func load(shared: SharedResources) throws -> LLMCatalog }   // catalog/llm-providers.json
public enum LLMConnectors {
    /// Every ConnectorID except .appleFoundation, for which it returns StubLLMConnector(id: .appleFoundation);
    /// callers use FoundationModelsConnector() from VoxClipMedia for that id. A catalog entry with enabled: false
    /// gives a connector whose status() is .unavailable.
    public static func make(_ id: ConnectorID, catalog: LLMCatalog, keys: any KeyProvider,
                            processes: any ProcessRunner, settings: SettingsDocument) -> any LLMConnector
}

// M9. Clip finder result, ai.md 11.8 (Services/LLM). The existing find(...) changes its return type from [ClipSuggestion].
public actor ClipFinder {
    /// One aiResult with a new id matching $defs/id and createdAt = now; clips in ai.md 11.7 order, titles filled per 11.8.
    public func find(_ request: ClipFinderRequest, connector: any LLMConnector, model: String) async throws -> ProjectAIResult
}

// M10. Typed settings, architecture.md 2.5 and settings.schema.json (Services/Settings).
extension SettingsDocument {
    public static let defaults: [String: JSONValue]      // hand-coded schema defaults; a test compares them with the schema
    public func bool(_ key: String) -> Bool?             // stored value, else the default, else nil
    public func double(_ key: String) -> Double?
    public func string(_ key: String) -> String?
    public mutating func set(_ key: String, _ value: JSONValue?)   // nil removes the key
}

// M11. Constructor defaults (source-compatible).
public actor WhisperCppTranscriber { public init(locations: DataLocations = DataLocations()) }   // models under locations.models
public actor JSONSettingsStore { public init(locations: DataLocations = DataLocations()) }
```

The app turns a `ProjectAIResult` into clips like this: append the result to `project.ai.results`. Then build one `ClipRange(id: <new id>, startWordId:, endWordId:, title:, origin: .ai, aiResultId: result.id, aiClipIndex: k, selected: true)` per result clip, and dispatch `.addAIClips(resultId: result.id, clips:)`. The reducer drops duplicates (editing 6.3).

#### 4.1.3 What mac-core uses from mac-app's paths

Only the existing logging protocols in `Sources/VoxClipCore/Services/Logging/Logger.swift`: `Logger`, `Redacting`, `Log`, `LogEntry`, `LogLevel`, `RedactingLogger`. Their signatures are fixed. mac-core tests use test doubles for `Redacting`, `KeyProvider` and `ProcessRunner`. mac-core never imports the app or the CLI.

### 4.2 Windows: what `win-app` uses from `win-core`

#### 4.2.1 Existing API (binding; full declarations in `apps/windows/src`, indexed in `apps/windows/CONTRACTS.md`)

```csharp
// Domain/Shared (frozen; owned by win-core): Project, ProjectMedia, MediaReference, ProjectEdits, ProjectCaptions, ProjectExport,
// ProjectShare, ProjectAi, TimedWord, WordKind, PixelSize, CaptionPosition, RectD, PointD, TimeRange, ExportAspect, ExportQuality,
// FrameRate, ExportPreset, ReframeSettings, ExportPresets (OutputSize, OutputFrameRate, VideoBitrate, CenterCrop), MediaInfo,
// AudioExtractionRequest, MediaProgress, ComposeSnapshot, OutputSpec, ExportTarget, ExportJob, ExportProgress, ExportResult,
// PreviewFrame, PreviewPosition, EncoderInfo, EncoderCacheKey, ProjectSerialization, ProjectJsonContext, IRedactor, Redactor,
// VersionComparison, VoxClipErrorCode, VoxClipException, MediaException.

// Editing (Domain/Editing/EditingModels.cs)
public sealed record EditState(...);  public abstract record EditOperation { Toggle, CutSelection, RestoreSelection, SetWordCuts, SetPauseCuts,
  Correct, CutFillers, TightenPauses, RestoreCuts, SetActiveClip, AddClip, AddAiClips, UpdateClip, RenameClip, SetClipSelected, RemoveClip,
  SetPauseKeep, SetPauseThreshold }
public sealed record EditSummary(int FillerCount, int CutWordCount, int PauseCount, int CutPauseCount, bool CanCutFillers, bool CanTighten, bool HasEdits, bool CanExport);
public static class EditingEngine {
  public static EditSummary Summarize(EditState state);
  public static EditState Reduce(EditState state, EditOperation operation);
  public static EditPlan BuildEditPlan(IReadOnlyList<EditSegment> segments, double duration, double sampleRate, double pauseKeepSeconds = 0.15);
  public static IReadOnlyList<EditSegment> BuildSegments(EditState state, double duration);
  public static IReadOnlyList<CaptionWord> CaptionWords(EditState state, EditPlan plan); }
public sealed record EditHistory(EditState Present, IReadOnlyList<EditState> UndoStack, IReadOnlyList<EditState> RedoStack) {
  public EditHistory Apply(EditOperation operation); public EditHistory Undo(); public EditHistory Redo(); }

// Transcription (Services/Speech, Services/Models, Domain/Transcript, VoxClip.Media/Speech)
public interface ITranscriber { TranscriptEngine Engine { get; } TranscriberCapabilities Capabilities(string? model);
  Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct);
  Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct);
  Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct);
  Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct); }
public sealed record TranscriptionPlan(TranscriptEngine Engine, string? Model, LanguageChoice Language, TranscriptionOptions Options);
public sealed record ExtractedAudio(string Wav16kPath, long SampleCount, double DurationSeconds, double TimelineStart, int AudioTrackIndex);
public sealed record TranscriptionRequest(TranscriptionPlan Plan, ExtractedAudio Audio, string ContentKey);
public interface IModelCatalog { Task<IReadOnlyList<TranscriptionModel>> GetModelsAsync(CancellationToken ct); Task<TranscriptionModel?> GetModelAsync(string id, CancellationToken ct); }
public interface IModelDownloader { Task<InstalledModel> InstallAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct);
  Task<bool> VerifyAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct); Task RemoveAsync(string id, CancellationToken ct);
  Task<IReadOnlyList<InstalledModel>> ListInstalledAsync(CancellationToken ct); }

// Project, settings, resources (Services/Project, Services/Settings)
public interface IProjectStore { Task<ProjectOpenResult> LoadAsync(string path, CancellationToken ct); Task SaveAsync(Project project, string path, CancellationToken ct);
  Task<string?> ResolveMediaAsync(MediaReference source, string projectPath, CancellationToken ct);
  Task<string> ComputeContentKeyAsync(string mediaPath, IProgress<double>? progress, CancellationToken ct); }
public interface ISettingsStore { Task<AppSettings> LoadAsync(CancellationToken ct); Task SaveAsync(AppSettings settings, CancellationToken ct); Task FlushAsync(CancellationToken ct); }
public static class SharedResources { public static string ResolveRoot(string? executableDirectory = null); }
public sealed record DataLocations(string Root, string Settings, string Models, string Cache, string Autosave, string Secrets, string Logs) { public static DataLocations Resolve(); }

// Captions (Domain/Captions, VoxClip.Media/Captions)
public interface IGlyphShaper { Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct); }
public sealed record CaptionLayoutRequest(CaptionStyle Style, ProjectCaptions Captions, PixelSize Frame, IReadOnlyList<CaptionWord> Words, string? Language, double Duration);
public sealed record CaptionTrack(CaptionStyle Style, PixelSize Frame, IReadOnlyList<MeasuredCaptionWord> Words, IReadOnlyList<CaptionPage> Pages, double Duration);
public static class CaptionEngine { public static Task<CaptionTrack> BuildAsync(CaptionLayoutRequest request, IGlyphShaper shaper, IProgress<double>? progress, CancellationToken ct); }
public sealed record PixelBuffer(Memory<byte> Pixels, int Width, int Height, int Stride);           // premultiplied BGRA8
public sealed record CaptionRenderRequest(CaptionTrack Track, double Time, bool ReduceMotion = false, double Scale = 1);
public interface ICaptionRasterizer { void Draw(CaptionRenderRequest request, PixelBuffer target, CancellationToken ct);
  Task<PixelBuffer> RenderAsync(CaptionRenderRequest request, CancellationToken ct); }

// AI (Services/LLM, Services/Process, Domain/Clips)
public interface ILlmConnector { ConnectorId Id { get; } Task<ConnectorStatus> GetStatusAsync(CancellationToken ct);
  Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct); Task<int?> GetContextTokensAsync(string model, CancellationToken ct);
  Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct); }
public interface IKeyProvider { Task<string?> GetKeyAsync(string account, CancellationToken ct); }
public sealed class LlmRunner { public LlmRunner(IKeyProvider keys, LlmCatalog catalog, IRedactor log);
  public Task<LlmResult> RunAsync(LlmRequest request, ILlmConnector connector, string model, CancellationToken ct); }
public sealed record ClipFinderRequest(IReadOnlyList<TimedWord> Words, IReadOnlyDictionary<string, string> Corrections, IReadOnlySet<string> CutWordIds,
  ClipPreset Preset, string? Instructions, string? Language, ConnectorId Connector, string Model, bool Snap = true, bool DryRun = false);
public interface IClipFinder { Task<AiResult> FindClipsAsync(ClipFinderRequest request, IProgress<ClipFinderProgress>? progress, CancellationToken ct); }
public interface IProcessRunner { ... }   public sealed class ProcessRunner : IProcessRunner
```

#### 4.2.2 Additions and changes (win-core implements; signatures fixed here)

```csharp
// W1. One EngineRef, transcription.md 3.1 (Domain/Transcript; ProjectJsonContext and TranscriptJsonContext regenerate).
// Transcript.Engine and RawTranscript.Engine both use it; delete TranscriptEngineInfo. JSON names id, modelId, modelSha256,
// engineVersion, locale; enum wire values "elevenlabs", "whispercpp", "apple-speech". Nulls are written.
public sealed record EngineRef(TranscriptEngine Id, string? ModelId, string? ModelSha256, string EngineVersion, string? Locale);

// W2. Audio analysis, editing.md 5.1 (Domain/Editing/AudioAnalysis.cs). Rms holds editing 5.1 level[], FrameSeconds 0.01.
public sealed class AudioEnvelopeBuilder {
    public AudioEnvelopeBuilder(int sampleRate, int channels);
    public void Append(ReadOnlySpan<float> interleaved);    // any length; frames may span calls
    public AudioEnvelope Finish();
}

// W3. Project bridge, editing.md 10.4 to 10.7 (Domain/Editing).
// Members added to the existing static class EditingEngine:
    public static EditState? FromProject(Project project);                  // null when the project has no transcript
    public static Project ApplyToProject(Project project, EditState state); // persisted subset; drops share captions of removed clips

// W4. Caption styles, captions.md 2.4 (Services/Settings/CaptionStyleLibrary.cs). Resolution stays inside CaptionEngine.BuildAsync.
public sealed class CaptionStyleLibrary {
    public static CaptionStyleLibrary Load(string sharedRoot);   // strict generated decoding of caption-styles/styles/*.json
    public IReadOnlyList<CaptionStyle> Styles { get; }           // sorted by order
    public CaptionStyle? Find(string id);
}

// W5. Transcription composition, transcription.md 3.3, 8, 9, 11, 12 and 14 (Services/Speech, Services/Models, Domain/Transcript, Media/Speech).
public interface ITranscriptionService {   // changed: the envelope is passed in, as on macOS
    Task<Transcript> TranscribeAsync(TranscriptionRequest request, AudioEnvelope? envelope, IProgress<TranscriptionProgress>? progress, CancellationToken ct);
}
public sealed class TranscriptionService : ITranscriptionService { public TranscriptionService(IReadOnlyList<ITranscriber> engines, DataLocations locations); }
public sealed class ElevenLabsTranscriber : ITranscriber { public ElevenLabsTranscriber(IKeyProvider keys, HttpClient http); }
public sealed class WhisperNetTranscriber : ITranscriber { public WhisperNetTranscriber(IModelDownloader models); }
public sealed class ModelCatalog : IModelCatalog { public ModelCatalog(string sharedRoot); }
public sealed class ModelStore : IModelDownloader { public ModelStore(IModelCatalog catalog, DataLocations locations, HttpClient http); }
public static class LanguageRouter { public static TranscriptionPlan Route(LanguageChoice language, TranscriptEngine preferred, IReadOnlyList<string> installedModels); }

// W6. Caption engines (VoxClip.Media/Captions). Fonts come from <sharedRoot>/fonts.
public sealed class HarfBuzzGlyphShaper : IGlyphShaper { public HarfBuzzGlyphShaper(string sharedRoot); }
public sealed class SkiaCaptionRasterizer : ICaptionRasterizer { public SkiaCaptionRasterizer(string sharedRoot); }

// W7. Connectors and clip finder, ai.md 3, 6 and 11 (Services/LLM).
public sealed class LlmCatalog { public static LlmCatalog Load(string sharedRoot); }
public sealed class LlmConnector : ILlmConnector {   // added constructor; the id-only constructor stays the unavailable placeholder
    public LlmConnector(ConnectorId id, IKeyProvider keys, IProcessRunner processes, LlmCatalog catalog, HttpClient http);
}
public interface IClipFinder { Task<IReadOnlyList<ClipPreset>> GetPresetsAsync(CancellationToken ct); }   // added member
public sealed class ClipFinder : IClipFinder { public ClipFinder(LlmRunner runner, Func<ConnectorId, ILlmConnector> connectorFor, string sharedRoot); }

// W8. Typed settings, architecture.md 2.5 and settings.schema.json (Services/Settings).
// Members added to the existing record AppSettings:
    public static IReadOnlyDictionary<string, JsonElement> Defaults { get; }   // hand-coded schema defaults; a test compares them with the schema
    public bool? GetBool(string key); public double? GetDouble(string key); public string? GetString(string key);
    public void Set(string key, JsonElement? value);                         // null removes the key
public sealed class SettingsStore : ISettingsStore { public SettingsStore(DataLocations locations); }
```

The Windows app turns an `AiResult` into clips the same way as section 4.1.2: append it to `project.ai.results`, then one `EditOperation.AddAiClips` built from the result's clips with new clip ids.

#### 4.2.3 What win-core uses from win-app's paths

Nothing. `Services/Logging` (`ILog`, `Log`) and `Services/Media` belong to win-app, and win-core does not reference them. Core services take `IRedactor` from `Domain/Shared` for redaction.

### 4.3 CLI and end-to-end contract (app tracks to `parity`)

- The command tree, flags, JSON output and exit codes are architecture.md section 9. Both CLIs implement every M1 command. `plan --json` has the shape in section 9.2. `render-caption` writes `<dir>/<case>/s<index>.png` plus `<dir>/<case>.json`, and `<dir>/tiles/` for `--tiles`.
- The end-to-end cases, case ids and the `VOXCLIP_E2E_OUT` report are defined in architecture section 9.5. macOS writes them from `Tests/VoxClipMediaTests/E2E/`, Windows from `tests/VoxClip.Media.Tests/E2E/`. CI supplies the absolute Release CLI path in `VOXCLIP_CLI` and sets `VOXCLIP_REQUIRE_E2E=1`; missing inputs fail. Local runs may skip when the CLI or canonical fixtures are absent and strict mode is unset.
- The Windows CLI loads FFmpeg lazily. `version`, `plan`, `render-caption` and `models list` run on macOS without FFmpeg. The caption parity and plan parity checks depend on this.

### 4.4 Shared fixtures and tools (`tooling` to everyone)

Already in the repository: `shared/fixtures/editing` (85), `projects` (2), `captions`, `redaction/cases.json` (architecture 11.2), `version/compare.json` (architecture 13.1) and `export/presets.json` (architecture 4.1).

Produced by `tooling`, with the names below fixed:

| Path | Defined by | Consumers |
|---|---|---|
| `apps/macos/Sources/VoxClip/Design/Tokens.swift`, `apps/windows/src/VoxClip.App/Themes/Tokens.xaml` | design.md 16 | mac-app, win-app |
| `tools/release/set-version.sh`, `tools/release/check-version.sh` | release.md 4 | lead, CI |
| `shared/fixtures/llm/{format-transcript,to-fixed,finalize-clips,extensions,clip-finder-requests}.json` | ai.md 13.1 | mac-core, win-core |
| `shared/fixtures/transcription/` (README, word-assembly and pipeline cases, `elevenlabs/` canned responses) | transcription.md 16.1, 16.2 | mac-core, win-core |
| `shared/fixtures/media/` (`index.json`, the six media files, the three `*.transcript.json` companions) | architecture.md 9.5 | mac-app, win-app, parity |
| `shared/fixtures/ingest/media/pocket4-like-2tracks.mov`, `shared/fixtures/ingest/README.md` | ingest.md 3.1, 18.2, 18.9 | mac-app, win-app |

## 5. Track briefs

Each brief stands on its own. Section 1 applies to every track.

### 5.1 `tooling`: Shared tools and fixtures

**Goal.** Build the shared generators and fixture sets that the other tracks test against, so that both platforms check the same data.

**Worktree.** Repository `<repo>`, your own worktree, branch `m1/tooling`.

**You own only these paths:** `tools/design/`, `tools/release/`, `tools/fixtures/llm/`, `tools/fixtures/media/`, `tools/schemas/`, `shared/fixtures/llm/`, `shared/fixtures/transcription/`, `shared/fixtures/media/`, `shared/fixtures/ingest/`, plus exactly two generated files in app trees: `apps/macos/Sources/VoxClip/Design/Tokens.swift` and `apps/windows/src/VoxClip.App/Themes/Tokens.xaml`. Change nothing else.

**Read first:** `AGENTS.md`; `doc/plan.md` sections 1 and 4.4; `doc/design.md` section 16 and `shared/design/tokens.json`; `doc/release.md` section 4 (steps 1 and 2); `doc/spec/ai.md` sections 11.3 to 11.7 and 13; `shared/prompts/README.md`; `doc/spec/transcription.md` sections 3, 6, 8.2, 9 (token handling), 14.2 and 16; `doc/spec/editing.md` sections 5 and 11.4; `doc/architecture.md` sections 2.4, 9.5 and 12; `doc/spec/ingest.md` sections 3.1, 18.2 and 18.9; `shared/schemas/project.schema.json`.

**Deliverables, in this order:**

1. **Design tokens (merge this alone, first).** `tools/design` (Node 22; no dependencies, or dev dependencies with a committed `package-lock.json`). `npm --prefix tools/design run generate` writes `Tokens.swift` and `Tokens.xaml` exactly as design.md section 16 says. That covers naming (`color.text.primary` becomes `vcTextPrimary` and `VcTextPrimaryBrush`), the header `GENERATED from shared/design/tokens.json - do not edit`, Swift dynamic `NSColor` colours and `CGFloat` constants, `Font` helpers that load DM Sans and Geist Mono by file URL from `SharedResources`, and XAML `ThemeDictionaries` `Default`, `Light` and `HighContrast`. Output is deterministic. `npm --prefix tools/design run check` exits 1 on drift.
2. **Version scripts.** `tools/release/set-version.sh X.Y.Z` sets `CFBundleShortVersionString`, increments `CFBundleVersion` in `apps/macos/Sources/VoxClip/Info.plist`, and sets `<Version>` in `apps/windows/Directory.Build.props`. `tools/release/check-version.sh` exits 1 when the two versions disagree. Both run under bash 3.2 and on ubuntu (no `PlistBuddy`; use `python3` `plistlib`).
3. **LLM fixtures.** `tools/fixtures/llm` (Node 22, no dependencies) is VoxClip's own MIT implementation of ai.md sections 11.3 to 11.7, written from the spec. `npm --prefix tools/fixtures/llm run generate` writes the five files of section 4.4 from the section 13.2 to 13.6 inputs, every preset, and the prompts in `shared/prompts/clip-finder.json`. `run check` regenerates, fails on any difference, and self-checks against every vector printed in ai.md section 13. Give each file a `schema`, `source` and `description` field, as the editing fixtures do.
4. **Transcription fixtures.** `shared/fixtures/transcription/README.md`, plus the word-assembly cases (`{name, rule, timelineStart, tokens, expect}`) and pipeline cases of section 16.1, covering all 12 required cases, and `elevenlabs/` canned responses for section 16.2. Expected values are hand-derived from the spec. Each case carries a `derivation` note naming the rule it checks. The README says the files are hand-written and how to change them.
5. **Media fixtures.** `tools/fixtures/media/generate.swift` (run as `swift tools/fixtures/media/generate.swift --out shared/fixtures/media`) writes the five AVFoundation files of architecture section 9.5 (`joins-tone.mov`, `fillers-chirp.mp4`, `counter-1080p.mp4`, `big-2400x1350.mp4`, `bars-1080p.mp4`) and the three transcript companions (`joins-tone`, `fillers-chirp`, `fillers-only`): VideoToolbox H.264 (never x264), BT.709 tags, barcode, tones and chirps exactly as specified. It also writes `index.json` with sha256 values. `--verify <dir>` re-checks sizes, sha256, durations, dimensions, codecs and audio formats. `--long-hevc <file>` and `--motion-60s <file>` write the on-demand clips, which are never committed. `tiny.webm` (VP9 and Opus, 1 s) is made once with an FFmpeg build that has libvpx (dev machine only) and committed. Record the exact command in `shared/fixtures/media/README.md`. Every file is at most 2 MB.
6. **Camera-file fixture.** `shared/fixtures/ingest/media/pocket4-like-2tracks.mov` (HEVC Main 10, track 1 a 1 kHz tone, track 2 a 300 Hz tone, 6 s) and `shared/fixtures/ingest/README.md`. Use the command in ingest.md section 18.2, or an AVAssetWriter equivalent with the same properties in `generate.swift --pocket4`. At most 2 MB.
7. **Schema checks.** Extend `tools/schemas/validate.py` so that a run with no arguments also validates every `shared/fixtures/media/*.transcript.json` against `$defs/transcript`.

**Acceptance criteria:**

- Running `npm --prefix tools/design run generate` twice leaves `git status` clean. `cd apps/macos && swift build` compiles with the generated `Tokens.swift`. `python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" apps/windows/src/VoxClip.App/Themes/Tokens.xaml` succeeds. Every colour token appears in both files.
- `bash tools/release/check-version.sh` exits 0 on the tree. A run of `set-version.sh 0.1.1` on a temporary copy of the two files changes exactly the three values.
- `npm --prefix tools/fixtures/llm run check` passes, and regeneration leaves `shared/fixtures/llm` unchanged.
- `swift tools/fixtures/media/generate.swift --verify shared/fixtures/media` passes, and `python3 tools/schemas/validate.py` passes.
- `find shared/fixtures -type f -size +2M` prints nothing. Every `*.json` under `shared/fixtures` parses.
- `bash -n` and `shellcheck` pass on every shell script you add.

**Verification commands:**

```sh
npm --prefix tools/design run generate && npm --prefix tools/design run check && git status --short
(cd apps/macos && swift build)
bash tools/release/check-version.sh
npm --prefix tools/fixtures/llm run generate && npm --prefix tools/fixtures/llm run check && git diff --exit-code shared/fixtures/llm
swift tools/fixtures/media/generate.swift --verify shared/fixtures/media
python3 tools/schemas/validate.py
find shared/fixtures -type f -size +2M
python3 -c "import json,glob; [json.load(open(p)) for p in glob.glob('shared/fixtures/**/*.json', recursive=True)]"
```

### 5.2 `mac-core`: macOS core (editing, transcription, captions, AI)

**Goal.** Implement the macOS core so that it passes every shared fixture. That covers the word editor's domain and persistence, the three transcription engines, the caption layout and the single CoreText rasterizer, and the LLM connectors with the clip finder. Implement the contract additions in `doc/plan.md` section 4.1.2 so `mac-app` can build on them.

**Worktree.** Repository `<repo>`, your own worktree, branch `m1/mac-core`.

**You own only these paths (under `apps/macos/`):** `Sources/VoxClipCore/Domain/` except `Domain/Publishing/`; `Sources/VoxClipCore/Services/Project/`, `Settings/`, `LLM/`, `Process/`, `Speech/`, `Models/`; `Sources/VoxClipMedia/Captions/`, `Speech/`, `Intelligence/`; `Tests/VoxClipCoreTests/` except `Tests/VoxClipCoreTests/App/`; and new folders `Tests/VoxClipMediaTests/Captions/`, `Speech/`, `Intelligence/`. `Domain/Shared/` is frozen: its public signatures and wire names change only through the section 4.1.2 additions (`OutputSizing.swift` is new there). Fixing behaviour inside it to match the fixtures, for example the `Redactor` rules, is part of your work. Keep `Tests/VoxClipCoreTests/FixtureLoader.swift` and `ContractTests.swift` working; extend them, do not rewrite them.

**Read first:** `AGENTS.md`; `doc/plan.md` sections 1, 4.1 and 4.4; `apps/macos/CONTRACTS.md` and `apps/macos/README.md`; `doc/decisions.md`; `doc/architecture.md` sections 2, 3, 4, 7, 8, 10, 11.2 and 13.1; `doc/spec/editing.md` (all); `doc/spec/transcription.md` (all; the Windows-only parts for context); `doc/spec/captions.md` sections 1 to 13 and 16; `doc/spec/ai.md` sections 1 to 11 and 13 to 14 (section 12 is M2; skip it); `shared/prompts/README.md`; `shared/catalog/*.json`; `shared/schemas/*.json`; the READMEs under `shared/fixtures/`.

**Deliverables:**

1. **Contract additions.** M1 to M11 of `doc/plan.md` section 4.1.2, with exactly those signatures, unless the lead already landed them as stubs (phase 0). Then delete `CaptionTrack.build(...)`.
2. **Editing** (editing.md): numeric and text primitives (section 4, including `toFixed1` as section 4.4 defines it and no fused multiply-add), audio analysis (5.1), the import post-process (5.0 to 5.8), pauses, fillers, the reducer with every operation of 6.3 including `addAIClips`, `renameClip` and `setClipSelected`, `EditHistory` capped at 500, summaries (6.4), planning, time mapping and join fades (7), and project semantics (10). `JSONProjectStore` covers decode, cleanup and migrations, canonical atomic writes, and relinking by the project rules. `JSONSettingsStore` covers atomic, debounced writes and unknown keys kept. `CacheStore` covers the size limit and protected keys. `SharedResources` and `DataLocations` follow architecture 2.4 and 2.5. `compareVersions`, `Redactor` (architecture 11.2, a single implementation) and `OutputSizing` (4.1) must match their fixtures.
3. **Transcription** (transcription.md): `WordAssembler`, `cleanWords`, `tightenIntoSound`, `findUnlabeledSpeech` and `LanguageRouter`. `TranscriptionService` runs the pipeline, caches raw transcripts under the section 14.2 keys, reports progress at most 10 Hz, and cancels cleanly. Adapters: ElevenLabs Scribe v2 (section 8; the first-use consent sheet is mac-app's, stored as `transcription.cloudConsent.elevenlabs`), whisper.cpp through the pinned xcframework with DTW and the catalogue models (section 9), and Apple `SpeechTranscriber` (section 10, full BCP 47 tag via `identifier(.bcp47)`). The model catalogue and store (section 12) download, resume, verify sha256 and remove.
4. **Captions** (captions.md): style decoding and resolution (2), text and the case map (3), CoreText shaping over the bundled fonts with nearest-weight fallback (4), frame, pages and lines, placement, timing, emphasis and emoji, word appearance, animation and geometry (5 to 12). `CoreTextCaptionRasterizer` (13) is the only rasterizer: glyph paths, explicit shapes, our own blur, premultiplied RGBA drawn only over the caption band of the BGRA frame.
5. **AI** (ai.md): canonical request and result (2), connectors for `anthropic`, `openai`, `xai`, `gemini`, `ollama`, `lmstudio`, `claude-code` and `codex` (6), and `apple-foundation` in `VoxClipMedia/Intelligence`. The CLI connectors must follow section 7: `--safe-mode` always, never `--setting-sources`, no reuse of the user's auth variables, and the catalog `enabled` switch honoured. Also: runner policy (4), error mapping (5), model lists (9), and the clip finder pipeline (11) returning a `ProjectAIResult` (M9). Keys reach connectors only through `KeyProvider`. Prompts and schemas come verbatim from `shared/prompts`.
6. **Tests.** Fixture runners for every kind in `shared/fixtures/editing/README.md`, plus `shared/fixtures/captions` (layout, text normalisation, math, preview tiles), `transcription`, `llm`, `redaction`, `version`, `export` and the two projects (byte-identical round trip). Add adapter tests with recorded responses (a `URLProtocol` stub; no network) and CLI-connector tests with fake executables. Add a test that `SettingsDocument.defaults` equals the schema defaults, and a benchmark test for the architecture section 14 plan rebuild budget (10,000 words, under 10 ms). Remove the four disabled placeholders in `Tests/VoxClipCoreTests/{Editing,Speech,Captions,AI}` once real tests replace them.

**Acceptance criteria:**

- `swift build` gives zero warnings in owned files under Swift 6 strict concurrency. `swift test` passes with zero failures. Skips happen only for fixtures that do not exist yet and for live tests, and each skip names its reason.
- Fixture pass counts in your report: editing 84/84, projects 2/2, redaction 10/10, version 9/9, export 15/15, captions (all layout, text, math and tile cases), transcription (all section 16.1 cases), and LLM (all ai.md section 13 vectors, plus `shared/fixtures/llm` once `tooling` merges).
- No M1 path you own still throws `notImplemented`; check with `grep -rn notImplemented` and list the remaining M2 and M3 seams.
- Default runs make no network calls and read no Keychain. Live runs: `VOXCLIP_LIVE_TESTS=1` with `VOXCLIP_ELEVENLABS_API_KEY` set, and `VOXCLIP_TEST_DOWNLOAD=1` for one small model download and verify.

**Verification commands:**

```sh
cd apps/macos
swift build 2>&1 | tee /tmp/mac-core-build.log; grep -c "warning:" /tmp/mac-core-build.log
VOXCLIP_SHARED_DIR="$PWD/../../shared" swift test
grep -rn "notImplemented" Sources/VoxClipCore/Domain Sources/VoxClipCore/Services/{Project,Settings,LLM,Process,Speech,Models} Sources/VoxClipMedia/{Captions,Speech,Intelligence}
```

### 5.3 `mac-app`: macOS media pipeline, app, CLI and packaging

**Goal.** Ship the macOS product on top of `mac-core`: the AVFoundation pipeline (one compositor, sample-exact cuts, 5 ms join fades), the SwiftUI document app with every M1 screen, the `voxclip-cli` used for end-to-end tests, and `bundle.sh`.

**Worktree.** Repository `<repo>`, your own worktree, branch `m1/mac-app`.

**You own only these paths (under `apps/macos/`):** `Sources/VoxClipMedia/Pipeline/`, `Audio/`; `Sources/VoxClipCore/Services/Logging/`, `Updates/`; a new `Sources/VoxClipCore/Domain/Publishing/` for the pure share helpers; `Sources/VoxClip/` (including `Info.plist`) except the generated `Sources/VoxClip/Design/Tokens.swift`; `VoxClip.entitlements`; `Sources/voxclip-cli/`; `Tests/VoxClipMediaTests/` except its `Captions/`, `Speech/` and `Intelligence/` folders; a new `Tests/VoxClipCoreTests/App/`; `bundle.sh`; `dmg-background.png`; `README.md`.

**Depends on.** The `mac-core` API in `doc/plan.md` section 4.1 (code against those signatures; until mac-core merges, its functions throw `notImplemented`), and the `tooling` outputs in section 4.4 (`Tokens.swift`, `shared/fixtures/media`, the camera-file fixture).

**Read first:** `AGENTS.md`; `doc/plan.md` sections 1, 4.1, 4.3 and 4.4; `apps/macos/CONTRACTS.md` and `README.md`; `doc/decisions.md`; `doc/architecture.md` (all; mainly 2, 4, 5, 7 to 11, 13 and 14); `doc/design.md` (all M1 parts); `doc/spec/editing.md` sections 6.4 and 10; `doc/spec/transcription.md` sections 4, 8.5, 11 to 13 and 15; `doc/spec/captions.md` sections 1, 14 and 15; `doc/spec/ai.md` sections 7, 8, 10 and 11.8; `doc/publishing.md` sections 1 and 2; `doc/release.md` sections 1, 2 and 4; `doc/spec/ingest.md` sections 3.1 and 18.9.

**Deliverables:**

1. **Media pipeline** (architecture 5): `AVMediaProbe`, and `AVAudioExtractor` (16 kHz WAV plus the envelope through `AudioEnvelopeBuilder`, cached per section 8). `CompositionBuilder` inserts kept ranges on the source-sample timescale. `FadeTap` takes its sample position from `timeRangeOut` (5.3). `FrameCompositor` is the single `AVVideoCompositing` for preview and export: orient, crop by `OutputSizing.centerCrop`, scale, captions from `CoreTextCaptionRasterizer` at the page for the edited time. Also: `PreviewPlayerController` (playhead kept in source time across rebuilds; edit-to-preview under 300 ms after the 150 ms debounce), `AVExporter` and `ExportQueue` (sequential per window, H.264 only, sizes and bitrates from `OutputSizing`, SRT sidecar per section 4.1, `everythingCut` refused), and `ThumbnailService`.
2. **CLI** (architecture 9): every M1 command and the primary export form, sharing the app's reducers, planner and exporter. That includes `plan --json` (9.2 shape), the three `render-caption` forms, `--audio-out` (32-bit float WAV of the edited, faded audio), the exit codes of 9.3, and stdout JSON. Keys come only from `VOXCLIP_*_API_KEY` (9.4); fix the scaffold's old names, and register every key with the redactor. `version` prints `VoxClip 0.1.0 (macos-arm64)`.
3. **App** (design.md, architecture 2.6): `DocumentGroup` with the content types and open routing of architecture 2.6, the Welcome window, and the editor (transcript editor with selection, cut and restore, corrections, the pause and filler controls with the `EditSummary` gates, preview and transport, timeline, inspector Captions and Clips tabs with the clip lifecycle of ai.md 11.8). Also: the import sheet and untranscribed state (design 7.1), the export sheet mapped to `project.export` and `captions.styleId` (design 8), the share helpers (publishing 2), onboarding with no preselected connector (design 9), Settings with the keys of design 10, menus and shortcuts (11), states and exact copy (13), and accessibility (15). Further: Keychain `KeyProvider` (never in the CLI), logging sinks through the single redactor (architecture 11), and the GitHub update check (13.1, parsing tested with recorded JSON).
4. **Share helpers** in `Domain/Publishing` (pure): default caption text, the X weighted count, URL building and the host check, with the publishing section 2.3 tests in `Tests/VoxClipCoreTests/App/`.
5. **End-to-end tests** in `Tests/VoxClipMediaTests/E2E/`: architecture 9.5 cases 1 to 9 through the built CLI (`VOXCLIP_CLI`), media checks with `AVAssetReader`, and `VOXCLIP_E2E_OUT` reports. Also the 5.3 seek acceptance test and the ingest 18.9 camera-file test (first audio track transcribed and exported).
6. **Packaging**: `bundle.sh` per release.md 2.3, with ad-hoc mode for anyone, `--sign-only` and `--release` for maintainers, the six runtime `shared/` folders copied with the `diff -r` parity check, the root `THIRD_PARTY_NOTICES.md` and `LICENSE`, `shared/brand/macos/AppIcon.icns`, and the licence gate. Also `dmg-background.png` (600×400).

**Acceptance criteria:**

- `swift build` and `swift test` pass. Cases 1 to 9 pass when `shared/fixtures/media` exists, and the run writes ten reports with `VOXCLIP_E2E_OUT` set.
- `swift run voxclip-cli plan --open ../../shared/fixtures/projects/interview-take.voxclip --json` matches the `take` expectation in `shared/fixtures/editing/projects/` (kept ranges and output samples).
- `./bundle.sh` (ad-hoc) produces `dist/VoxClip.app`; `codesign --verify --deep --strict dist/VoxClip.app` passes; `diff -r` of each copied `shared/` folder against the repository is empty; no `fixtures` folder is inside the bundle; the app launches, and a sample project opens.
- Manual pass on this Mac, recorded in the report: import a short talking-head video, transcribe it with Apple Speech (or a downloaded whisper model), cut fillers, undo and redo, add a manual clip, pick each caption style, export 16:9, 9:16 and 1:1 with SRT, then copy caption and Open X. Also give measured numbers for the architecture section 14 budgets.
- The CLI never touches the Keychain (`VOXCLIP_NO_KEYCHAIN` path tested). No test makes a network call.

**Verification commands:**

```sh
cd apps/macos
swift build && VOXCLIP_SHARED_DIR="$PWD/../../shared" swift test
swift build --product voxclip-cli && VOXCLIP_CLI="$(swift build --show-bin-path)/voxclip-cli" VOXCLIP_E2E_OUT=/tmp/e2e-macos VOXCLIP_SHARED_DIR="$PWD/../../shared" swift test --filter E2E
swift run voxclip-cli version
swift run voxclip-cli plan --open ../../shared/fixtures/projects/interview-take.voxclip --json
./bundle.sh && codesign --verify --deep --strict dist/VoxClip.app
```

### 5.4 `win-core`: Windows core (editing, transcription, captions, AI)

**Goal.** Implement the Windows core so that it passes the same shared fixtures as macOS. That covers editing and persistence, ElevenLabs and Whisper.net transcription, HarfBuzz shaping with the single Skia glyph-outline rasterizer, and the LLM connectors with the clip finder. Implement the contract changes in `doc/plan.md` section 4.2.2 so `win-app` can build on them.

**Worktree.** Repository `<repo>`, your own worktree, branch `m1/win-core`.

**You own only these paths (under `apps/windows/`):** `src/VoxClip.Core/Domain/` except `Domain/Publishing/`; `src/VoxClip.Core/Services/Project/`, `Settings/`, `Speech/`, `Models/`, `LLM/`, `Process/`; `src/VoxClip.Media/Captions/`, `Speech/`; `tests/VoxClip.Core.Tests/` except `Tracks/UiPlaceholderTests.cs` and `Tracks/win-app/`; `tests/Support/`; and new folders `tests/VoxClip.Media.Tests/Captions/` and `Speech/`. `Domain/Shared/` is frozen: its public signatures and wire names change only for W1 (`ProjectJsonContext` metadata). Fixing behaviour inside it to match the fixtures is part of your work. You do not edit `.csproj` or props files; the lead adds `Whisper.net.Runtime.Vulkan` in phase 0.

**Read first:** `AGENTS.md`; `doc/plan.md` sections 1, 4.2 and 4.4; `apps/windows/CONTRACTS.md` and `README.md`; `doc/decisions.md` (ADR-R18 and ADR-R19 in particular); `doc/architecture.md` sections 2, 3, 4, 7, 8, 10, 11.2 and 13; `doc/spec/editing.md` (all, with section 9 on cross-language traps); `doc/spec/transcription.md` (all; Apple Speech for context only); `doc/spec/captions.md` sections 1 to 13 and 16; `doc/spec/ai.md` sections 1 to 11 and 13 to 14; `shared/prompts/README.md`; `shared/catalog/*.json`; `shared/schemas/*.json`; the READMEs under `shared/fixtures/`.

**Deliverables:**

1. **Contract changes.** W1 to W8 of `doc/plan.md` section 4.2.2, with exactly those signatures, unless the lead already landed them as stubs. W1 must keep both project fixtures round-tripping byte for byte.
2. **Editing** (editing.md), as on macOS: primitives (ordinal and invariant string APIs, NFC with ICU on, `toFixed1` per section 4.4), audio analysis, the import post-process (`TranscriptPostProcessor`), pauses, fillers, the reducer and history, `Summarize`, planning and join fades, and the project bridge. Also `ProjectStore` (strict generated decoding, cleanup, migrations, relink, `ComputeContentKeyAsync` per editing 10.3, atomic writes), `SettingsStore` (500 ms debounced atomic writes; unknown keys kept), `SharedResources`, `DataLocations`, `ExportPresets`, `VersionComparison` and `Redactor`, all matching their fixtures.
3. **Transcription** (transcription.md): `WordAssembler`, including the U+FFFD repair for split UTF-8, plus `LanguageRouter` and `TranscriptionService` (cache keys per 14.2, progress, cancellation). Adapters: ElevenLabs (section 8; the consent sheet is win-app's) and Whisper.net 1.9.1 with the runtime order Vulkan, then CPU, then CPU NoAvx on x64, and CPU on arm64, logging the loaded library (section 9). The model catalogue and store (section 12) download, resume, verify sha256 and remove.
4. **Captions** (captions.md): `CaptionEngine` (styles, text with `casemap.json` only, measurement, frame, pages, lines, placement, timing, emphasis, emoji, appearance, animation, geometry); `HarfBuzzGlyphShaper` calling HarfBuzz directly (no `SKShaper`); `SkiaCaptionRasterizer` drawing glyph outlines and explicit shapes only (no `DrawText`, no text blobs, no system fonts); `CaptionStyleLibrary`.
5. **AI** (ai.md): the same connector set as macOS minus `apple-foundation` (which reports unavailable on Windows), the CLI connectors under section 7 through `ProcessRunner`, plus `LlmRunner` policy, error mapping, model lists and `ClipFinder` returning `AiResult`, with presets from `shared/prompts`. Keys come only through `IKeyProvider`.
6. **Tests** (xUnit v3): runners for every editing fixture kind, the caption fixtures (layout, text, math, tiles) in `tests/VoxClip.Media.Tests/Captions/` (they run on macOS with the native SkiaSharp and HarfBuzz assets), transcription, LLM, redaction, version, export and project round trips; adapter tests with a fake `HttpMessageHandler`; CLI-connector tests with fake executables; a settings-defaults-equal-schema test; the section 14 plan benchmark. Replace the four core track placeholders in `tests/VoxClip.Core.Tests/Tracks/` (editing, speech, captions, AI).

**Acceptance criteria:**

- On macOS, in `apps/windows`, the cross-platform build has zero warnings (warnings are errors) and both test commands below pass. Skips happen only for missing fixtures, `RequiresWindows`, `RequiresFFmpeg` and live tests.
- Fixture pass counts in your report: editing 84/84, projects 2/2, redaction 10/10, version 9/9, export 15/15, captions (all layout, text, math and tile cases), transcription (all section 16.1 cases), and LLM (all ai.md section 13 vectors, plus `shared/fixtures/llm` once `tooling` merges).
- If you have SSH access to the Windows VM of release.md 3.1 (ask the lead for the host), `dotnet test` of both projects passes there too, including the Whisper.net runtime-selection test. Otherwise list it as not run.
- No M1 path you own still throws `NotImplemented`.

**Verification commands:**

```sh
cd apps/windows
dotnet build VoxClip.CrossPlatform.slnf -c Release
dotnet test --project tests/VoxClip.Core.Tests -c Release
dotnet test --project tests/VoxClip.Media.Tests -c Release --filter "Category!=RequiresFFmpeg&Category!=RequiresWindows"
grep -rn "NotImplemented" src/VoxClip.Core/Domain src/VoxClip.Core/Services/{Project,Settings,Speech,Models,LLM,Process} src/VoxClip.Media/{Captions,Speech}
```

### 5.5 `win-app`: Windows media pipeline, app, CLI and packaging

**Goal.** Ship the Windows product on top of `win-core`: the FFmpeg LGPL pipeline with one compose path for preview and export, the WinUI 3 app with every M1 screen, `voxclip-cli.exe`, Velopack updates, and the signed release scripts.

**Worktree.** Repository `<repo>`, your own worktree, branch `m1/win-app`.

**You own only these paths (under `apps/windows/`):** `src/VoxClip.Core/Services/Media/`, `Logging/`, `Updates/`; a new `src/VoxClip.Core/Domain/Publishing/` for the pure share helpers; `src/VoxClip.Media/Ffmpeg/`, `Pipeline/`, `Audio/`; `src/VoxClip.App/` (including `VoxClip.App.csproj`) except the generated `Themes/Tokens.xaml`; `src/VoxClip.Cli/` (including `VoxClip.Cli.csproj`); `tests/VoxClip.Media.Tests/` except its `Captions/` and `Speech/` folders and the `.csproj`; `tests/VoxClip.Core.Tests/Tracks/UiPlaceholderTests.cs` and a new `tests/VoxClip.Core.Tests/Tracks/win-app/`; `build/`; `README.md`.

**Depends on.** The `win-core` API in `doc/plan.md` section 4.2 (code against those signatures), and the `tooling` outputs in section 4.4 (`Tokens.xaml`, `shared/fixtures/media`, the camera-file fixture).

**Read first:** `AGENTS.md`; `doc/plan.md` sections 1, 4.2, 4.3 and 4.4; `apps/windows/CONTRACTS.md` and `README.md`; `doc/decisions.md`; `doc/architecture.md` (all; mainly 2, 4, 6 to 11, 13 and 14); `doc/design.md` (all M1 parts, Windows mappings in section 17); `doc/spec/editing.md` sections 6.4 and 10; `doc/spec/transcription.md` sections 4, 8.5, 9.2, 11 to 13 and 15; `doc/spec/captions.md` sections 1, 14 and 15; `doc/spec/ai.md` sections 7, 8, 10 and 11.8; `doc/publishing.md` sections 1 and 2; `doc/release.md` sections 1, 3 and 4; `doc/spec/ingest.md` sections 3.1 and 18.9.

**Deliverables:**

1. **FFmpeg** (architecture 6.1): consume the schema-2 self-built pin in `build/ffmpeg.json` with its local ZIP hashes, exact configure strings, licence and SHA-256-pinned sources; no `btbnCommit` or shipping URL exists. `Fetch-Ffmpeg.ps1` accepts a verified local ZIP per RID and has a separate test-only `ffmpeg.exe` mode. `FfmpegLoader` retains the licence gate (`avcodec_configuration()` has neither `--enable-gpl` nor `--enable-nonfree`, licence LGPL; failure is `ffmpegLicenceGate`) and lazy loading (section 4.3 of this plan).
2. **Media pipeline** (architecture 6): probe, audio extraction (16 kHz WAV plus envelope through `AudioEnvelopeBuilder`), `FrameComposer` as the one compose path (orient, centre crop by `ExportPresets.CenterCrop`, scale, captions via `ICaptionRasterizer.Draw`), the preview engine with WASAPI audio and join fades, and the exporter with the encoder ladder and encoder probe (cached), sample-exact audio, H.264 only, the SRT sidecar and `everythingCut`. Meet the 6.3 and 6.6 acceptance tests with the on-demand clips.
3. **CLI** (architecture 9): the same commands, flags, JSON and exit codes as macOS (System.CommandLine), `VOXCLIP_*_API_KEY` only (fix `EnvironmentKeyProvider` and the scrub list), and `version` printing `VoxClip 0.1.0 (windows-x64)` or `(windows-arm64)`.
4. **App** (design.md, architecture 2.6): `Program.Main` in the order `VelopackApp.Build().Run()`, `AppInstance.FindOrRegisterForKey("VoxClip")` with redirection, then `XamlCheckProcessRequirements`, `ComWrappersSupport.InitializeComWrappers` and `Application.Start`. Also the Home page, editor, inspector, import sheet, export and share (publishing 2), onboarding, the Settings window, CommandBar commands and shortcuts, states and copy, accessibility, Mica, and `Tokens.xaml` merged in `App.xaml`. Project files sit next to the video, with the Autosave InfoBar and "Save project as…" (architecture 2.6). Further: the DPAPI key store (architecture 11.4), logging sinks through `Redactor`, Velopack updates (13.2), and the `.voxclip` association in the install hook. Copy only the six runtime `shared/` folders (`caption-styles`, `catalog`, `design`, `fonts`, `prompts`, `schemas`) into the App and CLI output, and take the icon from `shared/brand`.
5. **Share helpers** in `Domain/Publishing`, with the publishing 2.3 tests in `tests/VoxClip.Core.Tests/Tracks/win-app/`.
6. **End-to-end tests** in `tests/VoxClip.Media.Tests/E2E/` (`Category=RequiresFFmpeg`): cases 1 to 9 through the built CLI (`VOXCLIP_CLI`) with FFmpeg decoding for the checks, `VOXCLIP_E2E_OUT` reports, and the ingest 18.9 camera-file test.
7. **Release scripts** (release.md 3): `build/release-windows.sh` (Mac side, including the FFmpeg source tarball step), `build/vm-release.ps1` (ASCII only; credentials in memory; build phase with node reuse off; signing phase sets `AZURE_*` only inside `try/finally`; verify phase checks the notices files), and `build/sign-if-needed.ps1`. They never print or store credential values.

**Acceptance criteria:**

- On macOS: `dotnet build VoxClip.CrossPlatform.slnf -c Release` with zero warnings, the filtered test run passes, and the CLI's `version`, `plan --open <project> --json`, `render-caption --case <fixture> --out <dir>` and `models list --json` run without FFmpeg present.
- On Windows (the VM of release.md 3.1, or report as not run): both RIDs build sequentially with `-m:1`, both test projects pass with FFmpeg fetched by `Fetch-Ffmpeg.ps1`, e2e cases 1 to 9 pass and write ten reports, and the app launches, opens a sample, exports 9:16 with captions, and runs a second instance that redirects to the first.
- `bash -n` and `shellcheck` pass on `release-windows.sh`, and the PowerShell parser reports no errors for the `.ps1` files (with `pwsh` on the Mac if it is installed, otherwise on the VM).
- `plan --json` output equals the macOS CLI output for both shared projects. Compare with `parity`'s script when it exists, or by hand.

**Verification commands:**

```sh
cd apps/windows
dotnet build VoxClip.CrossPlatform.slnf -c Release
dotnet test --project tests/VoxClip.Core.Tests -c Release
dotnet test --project tests/VoxClip.Media.Tests -c Release --filter "Category!=RequiresFFmpeg&Category!=RequiresWindows"
dotnet run --project src/VoxClip.Cli -c Release --no-build -- plan --open ../../shared/fixtures/projects/interview-take.voxclip --json
bash -n build/release-windows.sh && shellcheck build/release-windows.sh
pwsh -NoProfile -Command '$e=$null; foreach($f in Get-ChildItem build/*.ps1){[void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$null,[ref]$e); if($e){$e; exit 1}}'
# Windows VM (PowerShell, in apps\windows):
#   powershell -NoProfile -File build\Fetch-Ffmpeg.ps1 -RuntimeIdentifier win-x64
#   dotnet build src\VoxClip.App -c Release -r win-x64 -p:Platform=x64 -m:1
#   dotnet build src\VoxClip.App -c Release -r win-arm64 -p:Platform=ARM64 -m:1
#   dotnet test --project tests\VoxClip.Media.Tests -c Release
```

### 5.6 `parity`: Cross-platform parity and CI

**Goal.** Prove that the two apps behave the same: caption pixels, edit plans and end-to-end export results. Wire those checks into CI.

**Worktree.** Repository `<repo>`, your own worktree, branch `m1/parity`.

**You own only these paths:** `tools/parity/`, `tools/captions/parity.sh`, `tools/captions/compare_overlays.py`, `shared/fixtures/captions/golden/`, `.github/workflows/ci.yml`.

**Depends on.** The CLI and end-to-end contract in `doc/plan.md` section 4.3 (both app tracks) and the caption renderers (both core tracks). Part A needs none of them; part B runs after they merge.

**Read first:** `AGENTS.md`; `doc/plan.md` sections 1, 3 and 4.3; `doc/architecture.md` sections 9 and 12; `doc/spec/captions.md` section 16; `shared/fixtures/captions/README.md`; `tools/captions/README.md`; `shared/fixtures/editing/README.md` (the `project-plan` kind); the current `.github/workflows/ci.yml`.

**Deliverables:**

- **Part A (start now):**
  1. `tools/parity/compare_e2e.py` (Python 3 standard library only): compares two `VOXCLIP_E2E_OUT` directories by the rules in architecture 9.5, prints one line per difference, and exits 1 on any difference or a missing case. `tools/parity/test_compare_e2e.py` covers it with synthetic reports.
  2. `tools/parity/plan_parity.sh`: runs `plan --open <p> --json` with the Swift and the .NET CLI for every `shared/fixtures/projects/*.voxclip` on macOS. It compares the two outputs (ignoring nothing but `version`) and checks them against the `take` expectations in `shared/fixtures/editing/projects/`.
  3. CI (`ci.yml`): require integrated projects and canonical fixtures. macOS runs the Release CLI E2E suite with `VOXCLIP_REQUIRE_E2E=1`, uploads ten reports, and runs plan parity. Windows runs strict native and CLI E2E tests against test-only FFmpeg and uploads its reports. `e2e-parity` downloads both report sets and runs `compare_e2e.py`. Use one .NET compile job and at most two Swift compile jobs; run `dotnet test --project` from `apps/windows`.
- **Part B (after the core and app tracks merge):**
  4. Caption goldens: render every golden sample and gallery tile with the macOS CLI (`voxclip-cli render-caption`), review them visually, and commit them under `shared/fixtures/captions/golden/` in the layout `parity.sh` and captions section 16.4 expect. Report the total size; no single file may exceed 2 MB.
  5. Run `tools/captions/parity.sh`, `tools/parity/plan_parity.sh` and, with both report sets, `compare_e2e.py`. Fix only your own tools. Report renderer or CLI differences to the lead with the failing case, the diff image or JSON, and the owning track.

**Acceptance criteria:**

- `actionlint` reports no problems for `ci.yml`, and the YAML loads. Missing required media fixtures or app implementations fail the corresponding CI job.
- `python3 -m unittest discover -s tools/parity` passes, and `bash -n` and `shellcheck` pass on the scripts.
- Part B: `parity.sh` exits 0 (Swift against C#, and both against the goldens). Plan parity exits 0. `compare_e2e.py` exits 0 on the macOS and Windows report sets.

**Verification commands:**

```sh
actionlint .github/workflows/ci.yml
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"
python3 -m unittest discover -s tools/parity -p 'test_*.py'
bash -n tools/parity/plan_parity.sh tools/captions/parity.sh && shellcheck tools/parity/plan_parity.sh tools/captions/parity.sh
# Part B
bash tools/captions/parity.sh /tmp/voxclip-parity
bash tools/parity/plan_parity.sh
python3 tools/parity/compare_e2e.py /tmp/e2e-macos /tmp/e2e-windows
```

### 5.7 `vox-site`: voxconvo.com download page and redirects

**Goal.** Finish the M1 web part of publishing.md section 4: the `/download` page and the `302` redirects to the GitHub release assets, in vox-web. Nothing else.

**Where.** `<vox>/vox-web`, a separate git repository with uncommitted user edits. Work in that working tree directly: no worktree, no branch, and no git command that changes state (`add`, `commit`, `checkout`, `stash`, `reset`, `restore`). The owner commits. Read `<vox>/CLAUDE.md` and `<vox>/AGENTS.md` first. Never modify `<vox>/x11-api` or `x11-ui`, and never touch `vox-api`.

**You may change only these files, and only their download-related parts:** `server.mjs` (the VoxClip redirect block), `src/components/Download/` (all), `src/App.tsx`, `src/lib/metadata.ts` and `src/Layout.tsx` (the `/download` entries), `src/entryServer.tsx` and `src/entryClient.tsx` (only to pass the Windows-availability flag to the page), `src/index.css` (download rules), `test/ssr.test.mjs` (download tests), and `.env.example` (variable names with empty values, no secrets). Save `git status --short` before you start, and check at the end that only these files changed.

**Read first:** `<repo>/doc/publishing.md` sections 1, 3.4 (rows W1 to W5, W7, W9, W10) and 4; `<repo>/doc/release.md` section 1.1 (asset names); `<repo>/doc/decisions.md` ADR-R17; and the existing download code in vox-web.

**Current state.** Most of the work already exists in the vox-web working tree: the redirect block in `server.mjs` (case-insensitive, trailing slashes ignored, unknown names redirect to `/download`), `src/components/Download/index.tsx`, the route, metadata and layout entries, the "Desktop app" links in `Splash.tsx`, and SSR tests. Complete it in place. Do not rewrite it.

**Deliverables:**

1. Add the `windows-ffmpeg-source` alias and the `VoxClip-win-ffmpeg-source.tar.xz` asset to the redirect map, plus `VOXCLIP_RELEASES_PAGE`, exactly as publishing.md 4.2 shows.
2. `VOXCLIP_WINDOWS_AVAILABLE=false` makes every `windows*` alias and Windows asset answer `302` to `https://github.com/Siim/voxclip/releases`. The page then renders no Windows buttons, no Windows requirements and no FFmpeg source line, and server render and hydration agree.
3. The FFmpeg LGPL line next to the Windows buttons, with its link (publishing 4.1).
4. Check the page copy against publishing 4.1 (hero, sub, buttons, requirements, repository and releases links, checksum note, privacy line) and fix any difference.
5. Tests in `test/ssr.test.mjs`: the source-tarball redirects; the flag-off redirects and page (start the server with the variable set); `Cache-Control: no-store` on every redirect; no API query from any download path.

Out of scope: the `/device` page (W6), the sidebar entry (W8), every vox-api change (including A7 reserved handles), and deployment.

**Acceptance criteria:**

- `npm test` and `npm run build` pass in vox-web. If either already fails on the untouched tree for reasons outside these files, show that with the output from before your change, and report it.
- With a local server, these curl checks give the documented `Location` and `Cache-Control: no-store`: `/download/macos`, `/download/windows`, `/download/windows-arm64` and `/download/windows-ffmpeg-source`. Repeat with `VOXCLIP_WINDOWS_AVAILABLE=false`; the `windows*` paths must then answer with the releases page. `/download` returns 200 HTML, and with the flag off it contains no `/download/windows` link.
- `git status --short` shows changes only in the allowed files, compared with the status you saved.

**Verification commands:**

```sh
cd <vox>/vox-web
git status --short > /tmp/vox-web-status-before.txt   # run once, before any edit
npm test
npm run build
PORT=3199 node server.mjs & sleep 2
for p in macos windows windows-arm64 windows-ffmpeg-source; do curl -sI "http://127.0.0.1:3199/download/$p" | grep -iE '^(HTTP|location|cache-control)'; done
kill %1
VOXCLIP_WINDOWS_AVAILABLE=false PORT=3199 node server.mjs & sleep 2
curl -sI http://127.0.0.1:3199/download/windows | grep -i location
curl -s http://127.0.0.1:3199/download | grep -c '/download/windows'
kill %1
git status --short | diff /tmp/vox-web-status-before.txt -
```

## 6. 0.1.0 release checklist

Release policy (ADR-R17, a lead decision): 0.1.0 targets both platforms together. If macOS passes this checklist and Windows does not, the lead may publish macOS alone as 0.1.0. Windows then ships first in a later 0.1.x, and vox-web runs with `VOXCLIP_WINDOWS_AVAILABLE=false` until that release exists. Published releases are never edited.

**Test machines:**

| Machine | Used for |
|---|---|
| Mac A: base Apple M1 (8 GB), macOS 26 | architecture section 14 budgets, release build, notarization |
| Mac B: any Apple silicon Mac with macOS 26, a second user account | quarantined first launch, camera and microphone prompts, Keychain prompts, Apple Speech asset download |
| Windows A: mid-range x64 Windows 11 laptop with an integrated GPU (2022) | section 14 budgets, Whisper.net on Vulkan and on CPU, encoder ladder (`h264_qsv` or `h264_amf`, then `h264_mf`) |
| Windows B: clean Windows 10 22H2 x64 VM snapshot | both installers, Velopack update from the previous build, `.voxclip` association, uninstall |
| Windows C: Windows 11 on Arm (Snapdragon X) | arm64 installer, Whisper.net CPU arm64, `h264_mf` export |

Machines that are not available are listed in the release notes as "not tested".

**Checklist:**

1. CI is green on the release commit: the macOS, Windows, fixtures and e2e-parity jobs, with caption parity and plan parity passing.
2. Every shared fixture set passes on both platforms. The track final reports list no open M1 skips other than live tests.
3. Live checks with real keys, run by the lead (keys from the `VOXCLIP_*_API_KEY` variables, never written down): ElevenLabs transcription, one download and transcription for each whisper model family in the catalogue, Apple Speech on Mac B, and the Test button for each API connector in use.
4. Manual acceptance on Mac A and Windows A (design.md flows): import, transcribe with each engine, cut and restore, undo, clips (manual, and AI with one cloud connector, one local connector (Ollama or LM Studio) and Foundation Models on macOS), each caption style, export in each aspect with SRT, share helpers, settings, onboarding, updates (a newer draft tag must be detected after publishing).
5. Performance: every architecture section 14 budget is measured on Mac A and Windows A and recorded in the release issue.
6. Privacy: a network capture of a local-only session (whisper, Ollama) shows no traffic except the update check (AGENTS.md rule 10).
7. Licences: the macOS `nm` gate and the Windows `avcodec_configuration()` gate pass. `VoxClip-win-ffmpeg-source.tar.xz` is attached. `THIRD_PARTY_NOTICES.md` covers every component (release.md section 4, step 3b).
8. Subscription connector check (release.md section 4, step 3a; ADR-R20): `enabled` in `shared/catalog/llm-providers.json` matches the lead's decision.
9. release.md section 4, steps 1 to 9, in order. `CHANGELOG.md` gets the release date.
10. vox-web is deployed with `VOXCLIP_WINDOWS_AVAILABLE` set per ADR-R17. The release.md section 4 step 9 curl checks pass, including `/download/windows-ffmpeg-source`.

## 7. Open questions for the lead

1. ADR-R16: confirm the short-edge caption size, or choose `height` with rescaled portrait sizes and regenerated caption fixtures.
2. **Decided 2026-10-25:** the vendored VoxConvo files (`tools/fixtures/editing/reference/*.ts`) and the clip-finder prompt are published under MIT.
3. ADR-R17: approve the macOS-first fallback, or require both platforms in 0.1.0.
4. ADR-R1 and ADR-R2 (the extra `VoxClipMedia` target and `VoxClip.Cli` project): confirm.
5. **Decided 2026-10-25:** the CLI connectors ship enabled in 0.1.0 without waiting for written confirmation from Anthropic and OpenAI (ADR-R20). The requests stay open (ai.md section 14, item 8).
6. The Estonian filler list stays deferred (editing.md section 12). Confirm that 0.1.0 ships English hesitations only.
7. Default caption style `vox-highlight` (settings `captions.defaultStyleId`): confirm.
8. whisper.cpp `b5454` is a GitHub pre-release; the newest non-prerelease build with an xcframework is `b4938`. Keep `b5454`?
9. The vox-api reserved handles (publishing.md A7, M1 "with the download page") are outside `vox-site`. Who runs the read-only handle check against the production database, and when does A7 ship?
10. Should the UI mention the roughly 12,000-token fixed overhead of the Codex connector in the connector's cost line?
11. **Decided 2026-10-25:** FFmpeg.AutoGen 9.0.1.1 is MIT. The exact pinned NuGet `LICENSE.txt` text and copyright are in root `THIRD_PARTY_NOTICES.md`; the package repository pin is `7ec3390be7216bd1f8482b824f90c27cb601cd89`.
12. Windows VM access for the `win-core`, `win-app` and `parity` implementers (release.md section 3.1 host). Without it, Windows-only checks wait for the lead.

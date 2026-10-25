# win-speech handoff — 2026-10-25

## Round 7 — test-network safety and native transport

Merged main normally as `5e21f2a` (parents `b917ae0`, `fa50bc1`), without
conflicts. The main parent contains `1db3af2`. No manual edits were made in
`doc/`, no other worktree was changed, and nothing was pushed or merged into main.

### Lead decisions and commits

1. **Public construction — `f9131f3`:** remove both client-taking public
   constructors with lead-approved W5 ledger changes. The constructor inventory
   pins exactly two public constructors and rejects public clients, handlers
   and host inputs. `ContractTests.CompositionSignaturesMatchW5` pins the
   retained key-provider/region/catalogue/logger signature.
2. **Test factory — `f9131f3`:** use only internal static
   `ForTesting(IKeyProvider, HttpMessageHandler, ElevenLabsRegion, ModelCatalog?, ILog?)`.
   It rejects a null handler; its private shared constructor cannot be called
   from tests. All stub call sites use the factory. Its wrapper client is owned
   by the adapter; the supplied handler remains caller-owned. Region reflection
   tests retain the Core.Tests-only friend boundary.
3. **Assembly guards — `692b284`:** both Core.Tests and Media.Tests link the
   same module initializer. Unless `VOXCLIP_LIVE_TESTS=1` and a provider key are
   both present, the default HTTP proxy bypasses only loopback and directs all
   other destinations to the refusing loopback proxy `127.0.0.1:9`. The guard
   records attempted hosts without throwing from proxy resolution. Shared
   regressions prove default clients are blocked and loopback remains usable.
   Production-constructor regressions exercise ElevenLabs key tests/uploads,
   a Hugging Face install and OpenAI: speech/download failures are `offline`,
   the LLM adapter retains its existing `Network` error, and each guard hit is
   asserted. Owned speech and LLM handlers retain system-proxy use. The only
   proxy-disabled handlers are explicitly rerouted to loopback by TLS tests.
4. **Model copy — `85f2112`:** validate model-id syntax only for engines that
   use the model as an identifier. Invalid ElevenLabs models reach the fixed
   scribe_v2 `transcriptionFailed` copy, without echoing input. All 22 direct and
   service local-validation cases pass, without upload/cache access.
5. **User-Agent — `13c3f45`:** compute it once and send it on subscription GETs
   and upload POSTs. All 17 key-test cases pass, including exact header parity.
6. **Published helpers — `f9131f3`:** add
   `SpeechCopy.ValidateIdentifiers(TranscriptionPlan)` to both the public helper
   boundary and the published-operations ledger list; retain prior ledger entries.
7. **Native TLS — `2ac78da`:** speech and AI use one shared certificate helper
   with a PKCS#12 export/load round trip. Schannel could not use the old
   in-memory private keys. Speech cleanup previously swallowed the TLS server
   failure; upload retries then waited on a server that had already failed,
   producing cancellation timeouts rather than the original authentication
   error. Cleanup now preserves server failures. The 15-second deadline was
   not increased. A native baseline reproduced the problem (14 of 28 region
   cases failed on this VM); after the fix, all 36 combined speech/AI transport
   cases pass natively and portably, with matching `providerError`/307 results.

### Current public constructors

```csharp
public ElevenLabsTranscriber();
public ElevenLabsTranscriber(IKeyProvider keys,
    ElevenLabsRegion region = ElevenLabsRegion.Default,
    ModelCatalog? modelCatalog = null, ILog? logger = null);
```

`FromSettings` and `CreateEnvironmentKeyProvider` are unchanged public factories.
There are no public constructors taking `HttpClient` or `HttpMessageHandler`.

### Verification at production/test HEAD `2ac78da`

Portable commands run from `apps/windows`, with
`VOXCLIP_SHARED_DIR=<repo>/shared`,
`VOXCLIP_SCHEMA_PYTHON=<python>`,
`VOXCLIP_LIVE_TESTS=0` and a temporary, cleaned-up `VOXCLIP_DATA_DIR`:

```sh
dotnet build VoxClip.CrossPlatform.slnf -c Release --disable-build-servers -p:UseSharedCompilation=false
dotnet test --project tests/VoxClip.Core.Tests -c Release --no-build
dotnet test --project tests/VoxClip.Media.Tests -c Release --no-build --filter 'Category!=RequiresFFmpeg&Category!=RequiresWindows'
```

- Release build: **0 warnings, 0 errors**.
- Portable Core: **1,164 passed, 28 skipped, 0 failed** (1,192 total).
- Portable Media: **47 passed, 1 skipped, 0 failed** (48 selected).
- Focused transport: **36 passed, 0 failed** on both macOS ARM64 and Windows ARM64.
- Full native Core: **1,171 passed, 18 skipped, 3 failed** (1,192 total).

Native runs used `git archive HEAD`, not a live checkout, under
`C:\voxclip-build\win-speech\<unique-run-token>`. Each run atomically acquired
`C:\voxclip-build\vm.lock`, wrote its unique owner token, waited no more than
30 minutes for another owner, bounded the test process to 15 minutes, and
released only its own lock in `finally`. Run directories and local archive
scratch were deleted. No live provider calls or model downloads were enabled.

The full native zero-failed target is blocked by unrelated win-editing tests,
reported to the lead without modifying that track:

- `SettingsStoreTests.InvalidUtf8SettingsArePreservedAndRecoveredAsDefaults:56`
  hard-codes LF inside indented JSON; Windows emits CRLF there (the trailing
  file newline is still LF).
- `SettingsStoreTests.ReplacementsAreAlwaysWholeJsonAndFlushWritesOnlyTheLatestSnapshot:119`
  hit a transient `FileNotFoundException` while a concurrent reader opened the
  replaced settings file.
- `SettingsStoreTests.EveryWriterOutputPassesTheRealDraft202012Schemas:247`
  could not launch a real Python interpreter: the VM exposes only Windows
  Store `python`/`python3` aliases, not an installed Python in command discovery
  or the standard PythonCore registry entries.

Core skips are existing OS-specific process/filesystem cases, live provider
and local-generation gates, two track placeholders and the informative
caption-transform fixture. Media's skipped test is the opted-out live model
download/transcription case. FFmpeg/Windows-specific Media cases were filtered.

## Round 6 follow-up after the squash merge

Main was merged normally as `901dc9c`, preserving both contract ledgers and
this branch-only handoff. The verified production-code tip is `e576b1b`.
The lead-only minor findings 3, 6, 7, 8, 13, 14 and 15 were not changed.

### Binding decisions and regression evidence

1. **Core-owned key test — `84936e2` (minors 0, 1, 10):**
   `ElevenLabsTranscriber.TestKeyAsync` makes only the unpaid subscription GET
   at the selected region, using the same owned handler as uploads. It
   registers the key before sending. HTTP 200 returns "Works."; a 401/403
   reporting a missing permission returns the exact user_read-is-fine copy;
   another 401 throws the fixed keyRejected copy. Other failures never echo
   response bodies. The typed result's account-read flag never proves
   speech_to_text permission. Sixteen stub cases cover status/copy mapping,
   missing keys, request shape, logging, timeout/offline handling and caller
   cancellation. Loopback TLS covers key tests at all five fixed hosts,
   settings selection and a cross-host 307 with no forwarded key.
   `BaseUri` exposes only the fixed enum-to-origin map for display.
   **win-ui action:** compose with `FromSettings`, call `TestKeyAsync` and
   display `Message`; delete the hard-coded host and redirecting HttpClient
   in SettingsWindow.xaml.cs:141-142. No UI files were edited by this track.
2. **No production host/client injection — `391de0c` (minor 4):**
   the internal constructor takes an `ElevenLabsRegion`, never a Uri or host
   string. Remove Core's VoxClip.Media friend grant. Only Core.Tests can
   access injected clients and the loopback handler hook. Publish just the
   existing copy, progress and catalogue helpers needed by native Whisper.
   Reflection verifies the accessibility boundary, while public-constructor
   TLS tests prove a supplied compatibility client is ignored for keys.
3. **Dead transport removal — `e6798d0` (minors 2, 5, 12):**
   delete `SpeechTransport.CloudClient`. One factory supplies per-adapter
   handlers with redirects/cookies disabled, the 30-second connection timeout
   and the system proxy retained. Handler-ownership and region tests pass;
   the non-key-bearing model-download client is unchanged.
4. **Invalid identifier copy — `e576b1b` (minor 9):**
   validate forced-language and model syntax before catalogue/cache access,
   uploads or native work. Service imports and direct ElevenLabs/Whisper
   calls throw transcriptionLanguageUnsupported with exactly
   "{engine} can't transcribe the selected model or language identifier."
   Read-only mac-speech-5 SpeechErrorCopy/SpeechRawCache supplied the copy.
   Traversal, slash, empty model, long language and newline regressions pass;
   strict end anchors also reject trailing newlines. Well-formed unsupported
   codes retain their existing copy. The 21 Core local-validation cases and
   eight native-adapter identifier cases do not upload or download anything.
5. **Inventory — `84936e2` (minor 11):**
   CONTRACTS.md inventories ElevenLabsRegion, ElevenLabsRegions and
   ElevenLabsKeyTestResult; it also records the newly public Whisper helper
   types and the exact UI consumer action.

### Final public signatures

Existing constructors and FromSettings signatures remain unchanged. The new
key-test/display/result surface is:

```csharp
public Task<ElevenLabsKeyTestResult> ElevenLabsTranscriber.TestKeyAsync(CancellationToken ct);
public static Uri ElevenLabsRegions.BaseUri(this ElevenLabsRegion region);
public sealed record ElevenLabsKeyTestResult(bool CanReadAccountDetails, string Message);
```

The former internal helpers exposed to remove Media's broad friend access are:

```csharp
public static class SpeechCopy
{
    public static void ValidateIdentifiers(TranscriptionPlan plan);
    public static VoxClipException ModelMissing(TranscriptionModel? model, string? id, long bytes);
    public static VoxClipException ChooseLanguage();
    public static VoxClipException Unsupported(TranscriptEngine engine, string language);
}
public sealed class SpeechProgress<T>(IProgress<T>? target) : IProgress<T>
{
    public void Report(T value);
    public Task CompleteAsync(T value, CancellationToken ct);
}
public Task<JsonElement> ModelCatalog.RootAsync(CancellationToken ct);
public Task<string> ModelCatalog.NormalizeLanguageAsync(string code, CancellationToken ct);
public Task<string> ModelCatalog.FromWhisperLanguageAsync(string code, CancellationToken ct);
```

Round 7 replaces the old test-only constructor with the internal factory
`ElevenLabsTranscriber.ForTesting(IKeyProvider keys, HttpMessageHandler handler,
ElevenLabsRegion region, ModelCatalog? modelCatalog = null, ILog? logger = null)`.
The handler is required. The old testRegion name protected only named calls;
positional calls still selected a public overload that discarded the client.
Both public HttpClient constructors are now removed with lead approval, and
both test assemblies block non-loopback HTTP unless live tests and a key are enabled.

### Final verification

Run from apps/windows, with the lead-supplied VOXCLIP_SHARED_DIR and
VOXCLIP_SCHEMA_PYTHON, and VOXCLIP_LIVE_TESTS/VOXCLIP_TEST_DOWNLOAD unset:

```sh
timeout 1200 dotnet build VoxClip.CrossPlatform.slnf -c Release --disable-build-servers
timeout 1200 dotnet test --project tests/VoxClip.Core.Tests -c Release --no-build
timeout 1200 dotnet test --project tests/VoxClip.Media.Tests -c Release --no-build --filter 'Category!=RequiresFFmpeg&Category!=RequiresWindows'
```

- Cross-platform Release build: zero warnings, zero errors.
- Full Core: 1,184 total; 1,156 passed, 28 explicit skips, zero failed.
- Portable Media: 46 total; 45 passed, one opt-in model/live skip, zero failed.
- Speech-only Core: 247 total; 246 passed, one opt-in live skip, zero failed.
- Speech-only Media: 42 total; 41 passed, one opt-in live skip, zero failed.
- Region/transport safety contains 28 passing cases, including the boundary
  reflection check and upload/key-test TLS coverage.
- Builds/tests ran sequentially; no VM or model download was used. No doc/
  file was edited by hand; main's existing documentation changes came only
  through the requested normal merge. Nothing was pushed or merged into main.

**Intermediate-run caveat:** changing the internal constructor's third
parameter to a region initially made three-argument test calls select the
public compatibility overload. An intermediate failed run therefore issued
requests to ElevenLabs using only synthetic credentials and synthetic test
audio, receiving 401 responses. No real key was read or used. The distinct
testRegion name and explicit test calls fix that overload collision; negative
validation cases now also use injected no-upload guards. Final verification
uses stubs/loopback only. The round as a whole must not be described as having
made zero live network requests.

## Round 5 audit and verification

The continuation audited all eight binding decisions against the committed code,
tests and Windows contract ledger. No further production-code fix was needed.
Main was merged normally at `25c78f6` (parents `0c01dab` and `52b753e`), keeping
both sides of `CONTRACTS.md`. `4888e0f` adapted the merged editing fixture to the
W1 engine enum. `882475b` completed the editing import seam: speech now calls
the editing-owned `EditingImport.Pipeline` and no temporary duplicate adapter
remains. Its eight shared import fixtures pass in the full Core run.

### Decisions and regression evidence

1. **Region — `934e3b8`:** `ElevenLabsRegion` is the closed five-case enum;
   production origins come only from the exact fixed host table. Missing
   settings quietly select Default; invalid strings and non-string settings
   select Default with one value-free, redacted warning. No public constructor
   accepts a URI or host string. All five public-region uploads and the settings
   factory use loopback TLS in `RegionSafetyTests`; that class has 18 passing
   cases, including known/invalid/missing settings and public-signature checks.
   Raw cache keys are unchanged. The dated contract entry tells win-ui to read
   settings for imports and key tests, and the CLI to use Default without
   reading settings. This track owns no UI Test button.
2. **Redirects — `934e3b8`:** public constructors use a Core-owned
   `SocketsHttpHandler` with `AllowAutoRedirect = false`, `UseCookies = false`
   and the system proxy enabled. Only the internal test constructor accepts an
   effective injected client. The public W5 regression
   `PublicW5ConstructorDoesNotForwardKeysOn307WithADefaultClient` passes with a
   normal redirecting compatibility client; TLS receives one keyed request at
   the selected host and no connection follows the cross-host 307.
3. **Detection reroute — `5d8f2d1`:** the confidence-qualified detected language
   is normalized and checked against the catalogue's Windows local candidates
   before decode. `DetectedEstonianOnTurboReroutesBeforeAnyDecode` passes for
   `et` and `est` at the 0.5 threshold, with no decode and the exact unsupported
   code/copy. `DetectedTurboLanguagesReachDecode` passes for `en` and `de`.
4. **Catalogue — `4955c04`:** both language maps, finite cloud limits,
   wildcard/auto defaults, per-platform choices and consumed Whisper metadata
   are validated before the catalogue is exposed. All 23 cases in
   `CatalogueValidationTests` pass with `SharedResourcesMissing`, the exact
   reinstall copy and no upload.
5. **Local errors — `354f155`:** the 13 `LocalValidationTests` cases pass for
   keyterms, their count/length, speakers/diarization, forced language, wrong
   engine and wrong Scribe model. Direct and service paths use typed VoxClip
   errors and the approved macOS reason strings before upload/cache access.
6. **Shared responses — `9f3d0fc`:**
   `PairedResponseMapsExactlyAndReusesOnePaidUpload` discovers the canonical
   sidecars and asserts every raw-token field, normalized language, import error
   and upload count. The shared events-only case passes: two `noSpeech` imports
   across service instances cost one synthetic upload. Missing fixtures are
   explicitly skipped, not silently passed.
7. **Downloads — `1901732`:** `DownloadHttpFailuresUseThePinnedCodesAndCopy`
   passes for 403/404/429/503, including retry counts and exact provider/rate-limit
   copy. `ExhaustedTransportFailuresAreOffline` passes for connection and stream
   failures after retries. All 21 `ModelStoreTests` cases pass without downloads.
8. **Paths — `dd5d0cf`:** the handoff uses a portable worktree placeholder.
   The complete track diff contains no absolute home-directory paths.

### Public ElevenLabs composition

```csharp
public enum ElevenLabsRegion { Default, Us, Eu, In, Sg }
public ElevenLabsTranscriber();
public ElevenLabsTranscriber(IKeyProvider keys, ElevenLabsRegion region = ElevenLabsRegion.Default,
    ModelCatalog? modelCatalog = null, ILog? logger = null);
public static ElevenLabsTranscriber FromSettings(IKeyProvider keys, AppSettings settings,
    ILog? logger = null, ModelCatalog? modelCatalog = null);
public static class ElevenLabsRegions
{
    public static ElevenLabsRegion FromSettings(AppSettings settings, ILog? log = null);
}
```

### Verification

Run from `apps/windows` with `VOXCLIP_SHARED_DIR=<main-checkout>/shared`,
`VOXCLIP_LIVE_TESTS=0` and `VOXCLIP_TEST_DOWNLOAD=0`. The default Python lacks
the editing schema validator; `VOXCLIP_SCHEMA_PYTHON` selected an existing
interpreter with `jsonschema` 4.23.0 and `referencing`. No dependencies were
installed. All commands used the Release configuration and a 1200-second
deadline; tests used `--no-build` after the cross-platform build.

| macOS ARM64 suite | Passed | Skipped | Total |
| --- | ---: | ---: | ---: |
| Core default | 552 | 6 | 558 |
| Core speech namespace | 212 | 1 | 213 |
| Media portable | 37 | 1 | 38 |
| Media speech namespace | 33 | 1 | 34 |

The five-project `VoxClip.CrossPlatform.slnf` build passes with zero warnings
and zero errors. There are no test failures; filtered counts overlap. Core's
six skips are the live ElevenLabs test, three other-track placeholders, the
Windows-only NTFS test and the required informative editing fixture. Media's
one skip is the opt-in native model smoke. The speech namespaces are
`VoxClip.Core.Tests.Tracks.Speech` and `VoxClip.Media.Tests.Speech`; Media
portable excludes `RequiresFFmpeg` and `RequiresWindows`.

Windows ARM64 built Core, Media and Media.Tests in Release with zero warnings
and zero errors, then passed `LiveCpuTranscriptionWithAndWithoutDtw`: **1 passed,
0 skipped, 0 failed**. This used the committed `dd5d0cf` source snapshot; the
continuation changes only this report. The smoke explicitly set
`VOXCLIP_TEST_DOWNLOAD=1` and `VOXCLIP_LIVE_TESTS=0`, selecting only that test.
It downloaded and SHA-256 verified only `whisper-base.en-q5_1` (59.7 MB) and its
Silero VAD dependency (0.9 MB), in 3.00 seconds.

After an untimed warm-up, DTW ON/OFF/OFF/ON each produced 23 tokens and 16 words
from the 5.975-second synthetic English take, preserving its filler. Mean decode
was 2.005 seconds with DTW and 1.124 seconds without. Warm decode cancellation
returned in 0.204 seconds, first VAD cancellation in 0.002 seconds, and first
model-load cancellation in under 0.001 seconds. Native drain ownership, timing
bounds and the silence/noSpeech check all passed. These are smoke measurements,
not accuracy or large-model conformance claims.

The VM run waited for the shared lock without taking over another owner. Each
owned lock was released in finally, including transport/runner setup retries;
the successful run removed its source/build tree and downloaded models. Remote
staging/helper files and local verification scratch were removed as well. No
live ElevenLabs call was made, no other model was downloaded, and nothing was
pushed or merged into main.

## Round 4 report

Worktree: `voxclip-wt/win-speech`, branch
`track/win-speech`. Verification below uses code revision `469f04f`; later
changes only update this handoff. Nothing was pushed.

### Merge from main

`5469dc1` is a normal two-parent merge of `main` at `1d57b7b` into the starting
`a2f75df`. It merged cleanly, retaining both sides of `CONTRACTS.md`. The W1–W8
contracts in `doc/plan.md` §4.2.2 were read before the implementation fixes.

### Lead decisions and regression coverage

1. **W1/W5:** one typed `EngineRef` now serves stored and raw transcripts;
   `TranscriptEngineInfo` is removed. Both generated JSON contexts use the
   prescribed property names, engine wire values and explicit nulls. Tests cover
   all engines and both contexts. W5 constructors, explicit-envelope service
   overload and public catalogue-backed `LanguageRouter.Route` are implemented.
   Existing overloads remain; explicit null never invokes the compatibility
   envelope resolver. Signature, routing and isolated-root tests pass.
   `ModelCatalog(string)` takes the shared root; internal `FromFile` serves Core
   tests. Read, permission, parse and invalid/null-value failures use the exact
   `SharedResourcesMissing` reinstall error before any paid upload.
2. **Paid transcripts:** atomic cache writes retry twice with short delays,
   warn without paths and still return the completed transcript. A failed paid
   response is retained in process for later cache recovery across service
   instances; the returned transcript must still be saved in the project.
   Preflight checks real available space against a duration-scaled response
   estimate of at least 4 MiB and reports the actual shortfall. Access denial is
   not diskFull. The read-only-after-upload test restores write access, imports
   again across service instances, repairs the cache and requires one HTTP call.
   Windows verification also fixed the fixture's DACL restoration so this test
   actually makes the directory writable again.
3. **Progress:** adapter and service fractions are stage-local. Public pure
   `ImportProgress.Overall` supplies the UI's §13.1 import-wide ranges. Tests
   cover upload completion, indeterminate decode, alignment and range mapping.
4. **Install dedupe:** a per-root/per-model task is registered before disk
   preflight and consent, and removed in finally. Tests require one confirmation
   and one transfer, shared pending consent, independent waiter cancellation and
   retry after declined consent. Consent holds no model/download gate.
5. **Copy:** failed detection and Auto on a non-detection model ask
   “Which language is spoken?” with `TranscriptionLanguageUnsupported`; neither
   service nor adapter fills a language template with “auto”. Unknown model sizes
   are omitted rather than shown as 0 bytes. Direct/service and threshold tests
   cover these paths without native loading.
6. **Detected codes:** whisper codes are reversed through the catalogue's
   `whisperCodeFor` mapping before normalization; `jw` becomes `jv` for transcript
   language and prompt lookup. Decode still maps `jv` to `jw`. Four alias tests pass.
7. **Download opt-in:** either `VOXCLIP_TEST_DOWNLOAD=1` or
   `VOXCLIP_LIVE_TESTS=1` enables the model smoke. Six switch-matrix tests cover
   this without network access. Use the narrower download switch for native-only
   verification; provider tests remain separately gated.
8. **Public handoff:** implementation attribution was removed. Historical WIP
   commit cleanup remains the lead's merge responsibility. New commits have
   subjects within 72 characters, explanatory bodies and no attribution trailers.

The Windows noSpeech rule still requires at least one `WordKind.Word`; existing
empty/events-only paid-response reuse tests and exact error-copy tests remain.
No macOS, shared fixture, other worktree or unrelated track source was changed.

### Final W1/W5 signatures

```csharp
public sealed record EngineRef(TranscriptEngine Id, string? ModelId,
    string? ModelSha256, string EngineVersion, string? Locale);
Task<Transcript> ITranscriptionService.TranscribeAsync(TranscriptionRequest request,
    AudioEnvelope? envelope, IProgress<TranscriptionProgress>? progress, CancellationToken ct);
TranscriptionService(IReadOnlyList<ITranscriber> engines, DataLocations locations);
ElevenLabsTranscriber(IKeyProvider keys, HttpClient http);
WhisperNetTranscriber(IModelDownloader models);
ModelCatalog(string sharedRoot);
ModelStore(IModelCatalog catalog, DataLocations locations, HttpClient http);
static TranscriptionPlan LanguageRouter.Route(LanguageChoice language,
    TranscriptEngine preferred, IReadOnlyList<string> installedModels);
public static double? ImportProgress.Overall(TranscriptionStage stage,
    TranscriptEngine engine, double? fraction);
```

### Verification and cleanup

Both platforms built with zero warnings and errors. macOS built the five-project
cross-platform solution; Windows ARM64 built Core/Media and their test projects.
Counts are passed / skipped / total, with zero failures; filters overlap.

| Suite | macOS ARM64 | Windows ARM64 |
| --- | --- | --- |
| Core default | 161 / 5 / 166 | 161 / 5 / 166 |
| Core speech namespace | 143 / 1 / 144 | 143 / 1 / 144 |
| Media portable default | 33 / 1 / 34 | 33 / 1 / 34 |
| Media speech namespace | 29 / 1 / 30 | 29 / 1 / 30 |
| Native Windows whisper smoke | not rerun | 1 / 0 / 1 |

Media portable default excludes `RequiresFFmpeg` and `RequiresWindows`. Default
runs explicitly disabled both live switches. The Windows smoke used
`VOXCLIP_TEST_DOWNLOAD=1`, `VOXCLIP_LIVE_TESTS=0` and only the
`LiveCpuTranscriptionWithAndWithoutDtw` filter, with a synthetic 16 kHz mono WAV.
No live ElevenLabs call was made.

Only the small `whisper-base.en-q5_1` model (59.7 MB) and its Silero VAD dependency
were installed and SHA-256 verified. After warm-up, ON/OFF/OFF/ON decoded the
5.975 s take into 23 tokens and 16 words each time. Mean decode was 1.111 s with
DTW and 0.905 s without. Warm decode cancellation returned in 0.008 s; first VAD
and model-load cancellation returned in under 0.001 s with safe native drain.
The silence/noSpeech check passed. These are smoke measurements, not boundary
accuracy, multilingual or large-model conformance claims; DTW stays on by default.

Each VM attempt acquired `C:\voxclip-build\vm.lock` with this run's unique owner
token and released it in finally; no existing lock was removed or taken over.
The acquisition wait was bounded to 30 minutes. Work stayed beneath
`C:\voxclip-build\win-speech`; commands were sequential and time-bounded, with
no background loops. All downloaded models, verification source/build trees and
scratch were removed after the successful run. Local verification scratch is
also removed before handoff.

The editing-owned import pipeline is still a lead merge boundary, described
below. Round-three notes that follow are historical; this report supersedes
their earlier contract proposals, progress mapping and Windows verification gap.

## Round 3 scope (historical)

Completed round 3 on `track/win-speech`, resuming checkpoint `98cb6bf`.
The checkpoint's model gates, native ownership wrapper, DTW metrics and smoke
assertions were reviewed against the current main specs and retained.
All tracked changes are confined to the four speech-owned source folders,
the speech placeholder test, `Tracks/win-speech/`, and the agreed new
`tests/VoxClip.Media.Tests/Speech/` folder, plus the approved
`InternalsVisibleTo` project items and `CONTRACTS.md` ledger entries.
No main checkout, other worktree, central package configuration, reference
repository or shared fixture was changed. Main and win-editing were read-only.
No new dependency was introduced. Existing Whisper.net 1.9.1 packages are used.

- Deterministic raw-token assembly, grouping confidence, bracket events and offsets.
- Catalogue-backed Windows language routing, local detection threshold and RAM defaults.
- ElevenLabs Scribe v2 streaming multipart transport, limits, mapping, restricted-key
  lookup, privacy-safe diagnostics, cancellation, bounded retries and timeouts.
  The default cloud transport does not follow redirects with `xi-api-key`.
- Per-project/app-wide queues, progress throttling and atomic content-key raw caches,
  including the original ElevenLabs response for future remapping.
- Bundled catalogue validation and confirmed model installation: dependencies,
  disk-space checks, incremental SHA-256, validated HTTP range resume, partial
  retention on cancellation, atomic installed markers, verification and removal.
- CPU Whisper.net adapter, native VAD units, normalization, DTW, English filler
  prompt, special-token filtering, UTF-8 repair and 120-second context retention.

## Binding editing merge boundary

The earlier implementations of cleanWords, tighten, refinement and
unlabeled-speech detection were removed. `TranscriptPostProcessor` uses the small
internal `EditingImportAdapter` marked `TODO(merge)`. It only passes valid timed
engine words through, assigns provisional ids and deliberately reports
`Refined = false`; it does not claim editing-pipeline conformance.

The adapter now has exactly the read-only win-editing parameter/result shape:

```csharp
EditingImportResult Pipeline(IReadOnlyList<RawWord> raw, AudioEnvelope? envelope,
    TimingSource timing, bool verbatim, double? durationSeconds = null)
// Result: Words, PauseThresholdSeconds, Pauses
```

At merge, change only the callee in `TranscriptPostProcessor.Process` from
`EditingImportAdapter.Pipeline` to
`VoxClip.Core.Domain.Editing.EditingImport.Pipeline`; every argument is already
passed in the right order and the caller already reads `import.Words`.
`Refined` is `envelope is not null && import.PauseThresholdSeconds == 0.8`:
the pass-through's 1.0 keeps it false, and editing's envelope-backed 0.8 makes
it true without another call-site edit. Delete the temporary internal adapter
and its internal result type at merge. The editing owner must supply the final
ids, normalization/punctuation, refinement, detected speech and pauses. Run the
shared editing pipeline/tighten/gaps fixtures through that boundary after merge.
There are no transcription shared fixtures in this worktree yet; the assembler
and adapters currently have synthetic unit coverage instead.

## Round 3 contracts and proposals (historical)

Existing public methods, records and interfaces retain their frozen signatures.
Constructor injection was added without removing parameterless construction;
`WhisperNetTranscriber` additionally implements `IAsyncDisposable` to release its
warm context. Internal helpers have no public consumer contract. Common frozen
test files were not edited: this baseline had no win-speech NotImplemented
assertions there. Only the owned speech placeholder was replaced.

1. **2026-10-25 — win-speech — proposed, not applied:** expose the tested internal
   `TranscriptionRouter`/`RoutingDecision` and a local language-detection entry
   point through a lead-approved public import-planning contract. The frozen
   `ITranscriptionService` receives an already selected plan; it cannot represent
   settings mode, RAM, interactive choices or confirmation results. Explicit
   plans work now; UI default planning needs that agreed boundary.
2. **2026-10-25 — win-speech — proposed, not applied:** raw-cache JSON mappings for
   frozen `EngineRef.Engine`/`Model` and `RawTranscript.ProviderRequestId` should
   be agreed with the macOS owner. Their current source-generated C# names are
   `engine`/`model`/`providerRequestId`; transcription §3 uses
   `id`/`modelId`/`providerRequestID`. A later change can use JSON property
   attributes without renaming C# members, but requires cache migration tests.
3. **2026-10-25 — win-speech — inventory follow-up:** concrete implementations
   moved out of the aggregate stub files into same-named files in their owned
   folders. The lead should update CONTRACTS.md's file-location inventory.

Applied approvals already recorded in `CONTRACTS.md` (all dated 2026-10-25):

- Move existing friend grants into Core/Media project items, deleting both
  `SpeechTestAccess.cs` files; no new friend assembly was added (`5889565`).
- Add init-only `InstalledModel.Status` without changing its positional
  constructor: Installed, Update available, Broken (`c21fb7b`).
- Make environment-key selection explicit through
  `ElevenLabsTranscriber.CreateEnvironmentKeyProvider()`; normal app callers
  inject `IKeyProvider`, and parameterless construction reads no secret (`c21fb7b`).
- Add non-persisted init-only `Transcript.FromCache` for paid-cache-hit copy;
  keep paid provider JSON durable before mapping (`c9e1c94`).

No new dependency was introduced during round 3. Its service-side progress
rescaling and W1/W5 proposals were superseded by the round-four changes above.

## Round 3 review audit

Identifiers below are zero-based indices in the review JSON.

- **confirmed[0], confirmed[1]:** removed per-job `VerifyAsync` hashing. Native
  readiness uses only installed marker identity and on-disk sizes. The live
  smoke injects a store that throws if inference hashes, installs or removes.
- **confirmed[2]:** replaced the cold-first comparison with an untimed warm-up,
  then ON/OFF/OFF/ON runs. Native VAD, model/processor load, language detection
  and decode have separate timers; current measurements are below.
- **confirmed[3]:** per-root/model gates serialize install/verify/remove;
  a separate root download queue covers transfers only. Confirmation holds no
  gate. Regression tests cover pending consent, unrelated downloads, verify,
  list/remove and same-model double installs.
- **minors[0]:** cache the paid 200 JSON atomically before mapping, including
  empty words, events-only and malformed provider shapes. Replay never bills
  again. Complete paid results are cached before honoring cancellation.
- **minors[1], minors[4]:** signal Transcribing immediately after serialization
  sends the complete multipart body, not after response headers. Stage changes
  and final fractions bypass throttling. Service upload maps to 0.10–0.50,
  cloud processing is indeterminate in 0.50–0.95, alignment is 0.95–1.00.
  Verification also exposed a timer-rounding race in `CompleteAsync`: its final
  flush now bypasses throttling unconditionally, with cancellation checked
  before and after the delay instead of accidentally dropping completion.
- **minors[2], minors[5], minors[14]:** routing and capabilities honor optional
  catalogue `whisper.dtwDefault`; absent means true. Explicit plan options win.
- **minors[3]:** caller-visible cancellation uses `NativeWork.WaitAsync(ct)`
  around the owned job. The abandoned operation drains safely, disposes native
  objects and only then releases native/instance gates. Tokens are checked
  between native stages. Both successful and faulted drain paths are tested.
- **minors[6]:** Windows `apple` settings route as local; ask and keyless
  ElevenLabs decisions retain the full local alternative and its model size.
  The cloud offer remains conditional on the key; nothing uploads to detect.
- **minors[7]:** model/size/PC, engine/language, duration, checksum filename and
  volume/free-space values use the exact design §13 / architecture §10.2 copy.
  The final audit also normalized unavailable-engine, invalid-WAV and model-host
  errors, and checked malformed 200 responses. Duration labels retain total
  hours instead of wrapping at 24 hours; exact-copy regression assertions cover
  these remaining branches.
- **minors[8]:** marker-bearing stale installs remain visible as Update
  available, size-broken installs as Broken; both have `Verified=false`.
- **minors[9], minors[12]:** match the actual editing pipeline parameter order
  and result fields; the one-line callee swap and refinement behavior are
  documented above. Full editing fixtures remain a post-merge responsibility.
- **minors[10]:** use the documented download switch, assert a spoken filler,
  warm up before measurements and run both DTW orders.
- **minors[11]:** persist `Whisper.net 1.9.1 (whisper.cpp 1.8.5)` exactly;
  User-Agent uses the assembly version and three-component OS version.
- **minors[13]:** assert in-audio monotonic word timings, changed DTW starts
  and stable word counts. Count actual native DTW timestamps; if none are
  returned, log safely and label the result tokenGrouped rather than dtw.
- **minors[15]:** parameterless constructors use no environment key; only the
  named factory selects the VoxClip environment variable. App DPAPI wiring
  stays with the UI owner and CLI factory wiring with the CLI owner.
- **minors[16]:** apply the lead-approved project-item friend grants and ledger
  entry, rather than silently widening assembly access from a speech file.
- **minors[17]:** remove the old download-switch name everywhere, use
  `VOXCLIP_DATA_DIR` when set and a temporary fallback otherwise. Non-macOS
  smoke cleanly skips without the documented `VOXCLIP_TEST_WAV` input.
- **minors[18]:** do not reword/squash old commits: the binding lead instruction
  reserves history cleanup for merge. New fix commits have subjects at most
  72 characters, spec-citing bodies and no attribution trailers.

The review's dropped idle-timeout concern remains unchanged: the 300 s idle
timer and bounded retries are required by transcription §8.3 / architecture
§10.1. No undocumented timeout exception or cloud retry policy was added.

## Round 3 verification (historical)

Run from `apps/windows/` so its Microsoft.Testing.Platform `global.json` applies:

```sh
timeout 1200 dotnet build VoxClip.CrossPlatform.slnf -c Release --disable-build-servers
timeout 1200 dotnet test --project tests/VoxClip.Core.Tests -c Release
timeout 1200 dotnet test --project tests/VoxClip.Media.Tests -c Release --filter 'Category!=RequiresFFmpeg&Category!=RequiresWindows'
timeout 1200 dotnet test --project tests/VoxClip.Media.Tests -c Release --no-build --filter-namespace 'VoxClip.Media.Tests.Speech'
VOXCLIP_TEST_DOWNLOAD=1 timeout 1200 dotnet test --project tests/VoxClip.Media.Tests -c Release --no-build --filter-namespace 'VoxClip.Media.Tests.Speech' --output Detailed
```

`VOXCLIP_LIVE_TESTS=1` also enables that download smoke as of round 4. Prefer
`VOXCLIP_TEST_DOWNLOAD=1` with `VOXCLIP_LIVE_TESTS=0` for native-only checks.

macOS arm64, .NET SDK 10.0.102: cross-platform five-project build has zero
warnings/errors. Core: 134 total, 129 passed, 5 skipped (4 existing other-track
placeholders and the live ElevenLabs test); 111 passed cases belong to speech.
These final offline results cover the source and regression tests in `4ca69db`.
Default cross-platform Media filter: 18 total, 17 passed, 1 opt-in live skip.
Media speech filter: 14 total, 13 passed, 1 opt-in live skip by default;
with `VOXCLIP_TEST_DOWNLOAD=1`, all 14 passed, including the native smoke once.

The requested bare `timeout 1200 dotnet build -c Release` was attempted and
fails NETSDK1100 on VoxClip.App: the full solution includes WinUI and cannot
build on macOS as-is. The documented five-project cross-platform solution
above succeeds. No Windows targeting/configuration workaround was made.
Every build/test was timeout-wrapped. Default runs explicitly unset the
download and live switches. Two initial filtered invocations selected zero
tests; the listed namespace-filter and normal runner invocations passed.

The live test explicitly accepts the model licence hook and downloads
`whisper-base.en-q5_1` (59,721,011 bytes) and Silero VAD (885,098 bytes), verifies
SHA-256. This attempt set `VOXCLIP_DATA_DIR` to an isolated temporary directory
and deleted it after the single run (58 MiB peak including both models).
It creates a
5.975-second PCM16 mono 16 kHz WAV using this Mac's `say` and `afconvert`, without
using the media track's `IAudioExtractor`. The text starts “Hello, um, today…”.

Final verified run: download plus SHA-256 verification 2.39 s. After the
untimed warm-up, decode order was ON/OFF/OFF/ON:

| DTW | Total | VAD | Model/processor load | Decode | Decode RTF |
|---|---|---|---|---|---|
| On | 0.482 s | 0.038 s | 0.000 s | 0.342 s | 0.057 |
| Off | 0.543 s | 0.038 s | 0.046 s | 0.360 s | 0.060 |
| Off | 0.469 s | 0.055 s | 0.000 s | 0.315 s | 0.053 |
| On | 0.594 s | 0.048 s | 0.050 s | 0.398 s | 0.067 |

Means: DTW-on VAD **0.043 s**, load **0.025 s**, decode **0.370 s**;
DTW-off VAD **0.047 s**, load **0.023 s**, decode **0.337 s**. Forced English
did not need language detection. Totals also include input/preparation and the
final progress flush; do not interpret the remainder as decode cost.
Every measured run produced 23 tokens / 16 words, kept the filler, and passed
monotonic in-audio timing, stable word count and real DTW-difference checks.
The former 10.680 s versus 0.394 s cold-first comparison is withdrawn; these
new short-clip smoke measurements do not justify changing the DTW-on default.
This single native run used `bca5cbe`; later error-copy and final-progress-flush
hardening was rechecked by the full offline suites without a second download.

Caller-visible cancellation: warm decode **0.003 s**, first VAD **0.001 s**,
first model load **<0.001 s**; no partial transcript was returned. Cleanup
waited for each native operation to drain safely before disposing its owners.

The test also checks that VAD rejects silence. No manually annotated boundary
accuracy, bilingual filler recall or TalTech quantization-compatibility claim is
made. ElevenLabs live testing is skipped: no real key was used. The macOS native
runtime worked. Per the binding clarification, no SSH, VM probe, lock access,
background loop, interactive GUI or notarization was attempted.

## Remaining constraints

- The binding editing merge adapter must be replaced before shipping import.
- Whisper.net 1.9.1 exposes cancellation for decode/abort, which the live test
  checks. VAD, language detection and synchronous native model initialization
  still have no abort API. The caller now returns cancelled promptly, but those
  calls can keep using CPU/memory until they finish. Native/instance gates remain
  held until drain, so a following local job or DisposeAsync may wait. Large-model
  drain time and real multilingual detection cancellation were not live-measured;
  only the permitted small English model was downloaded.
- CPU runtimes are selected for x64/arm64; x64 has the existing NoAvx fallback.
  Vulkan is not enabled: the frozen baseline does not reference its package and
  this track was explicitly scoped to CPU. TalTech large-model tests remain
  release/lead follow-up; the small-model Windows execution is verified above.
- Cache eviction/open-project pinning remain the shared cache owner's concern;
  this service only owns raw transcript reuse inside each content entry.

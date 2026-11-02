# Windows v2 workflow seams

This describes the integrated source implementation, not an accepted native Windows build. Current focused and broad portable checks pass; exact source/run evidence and remaining gates are recorded in `/tmp/clipper-planning/reports/windows-v2-integrated-implementation-sol-high.md`. No native window, live provider, model, download or microphone acceptance is implied.

## One panel host

`Controls/RightColumn.cs` owns the header and a single body below the viewer. Captions reuses the existing renderer and editor. `DirectorPanel` hosts the existing Rewrite view and its `DirectorTask` projection; it does not create another connector or editor. The Voice job exposes the native speaker / ONNX prerequisite refusal. It has no enabled creation, download or synthesis action.

Export and Transcribe are `InlineEditorJob` controls. The names `ExportDialog` and `TranscriptionDialog` remain only to keep the shell's existing constructors and awaited `ShowAsync()` calls source compatible. Neither derives from `ContentDialog` or opens a window. The job registers against its actual `EditorViewModel`, never the first app window. Switching away cancels an unpaid approval; a running job receives cancellation before the host permits replacement. Focus moves to a live header control before removal.

`EditorPage.InitializeIntegratedEditor` mounts `PreviewPane` and `MediaRelinkBanner` around the existing preview and transport, removing them from their previous parent first. There is no second media presenter. The relink banner only returns approval; it does not change source identity or relax ProjectStore's duration validation. One `RightColumn.SourcePlaybackRequested` subscription routes inline Space to the real editor transport. `PreviewTransportCoordinator` serializes source and candidate startup, stopping every candidate before source playback/seek and pausing source before candidate playback.

## Approval and currentness

`InlineApproval` binds one immutable request/snapshot and consumes one affirmative action. Pointer and fresh nonrepeat Ctrl+Return are explicit. Plain Return uses the original Win32 message time and requires 500 ms after the row is shown; repeat and pre-row events cannot pay. Space cannot activate a paid primary. The `RightColumn.SourcePlaybackRequested` event is the shell's playback relay for Space.

Rewrite distinguishes one-time cloud/CLI privacy permission from per-send API-key billing approval through Core's `KindForLlmSend`. Plan-signed-in CLI and loopback-local sends have no extra cost approval; first-use privacy still applies where required. Unknown CLI auth does not send. Remote local servers name and pin their endpoint, with session-scoped consent; they do not persist a host-independent privacy grant. The displayed provider-pricing link contains no invented price.

The editor reference, source, instruction, connector, model, endpoint and request revision must remain current through approval and dispatch. Local cuts and corrections use the editor's existing batch command and one Undo. Text proposal does not require decoding source audio or a speaker model. Actual audio replacement still requires the original geometry, QA, native speaker, consent and output gates.

## Transcription and export

Transcribe consumes `App.Services.Transcription`, the existing local router, cache lease, audio extractor and model installer. Installed local routes start during initialization. Downloads retain the publisher/licence approval and resume behavior, then start local transcription. There is no automatic cloud fallback. Remembering a new-import choice stores language only.

Every ElevenLabs run shows a catalogue-derived price and visible audio-only terms. A missing key has a secure Save Key row and no enabled paid primary. A saved key or remembered privacy permission does not start a run. Source-read-only and leaving guards, immutable choices, source-file read access, content-key and duration checks run before upload. Choices or project changes cancel or obsolete the worker; a returned transcript cannot overwrite a newer edit. Cancellation after upload says ElevenLabs may still bill audio already received.

Daily transcription accounting is a durable local estimate, not the provider account total. `TranscriptionRequest.Observe` receives real cache, upload-started, accepted and completed evidence. The ledger persists before upload, deduplicates actual provider request IDs and retains interrupted uploads as billing-unconfirmed across restart. Cache reuse/pre-upload cancellation clears unpaid pending estimates. Ledger corruption or failed persistence refuses upload; observer failures never enter a provider retry. Accepted HTTP responses cannot be automatically retried even if observation, response decoding or cancellation fails. Accounting runs before stale UI filtering, and status updates marshal back to the UI dispatcher.

Export consumes the real `ExportDialogRouting`, compose callback, exporter and export ledger. It freezes its chosen target, aspect, quality, captions and source for the run, rejects changed source identity and records a completed output against the captured project even if the panel closes. Output-file, SRT, disclosure and user-initiated share behavior are retained. It never publishes for the user or reports a simulated export as successful.

Voice accounting reads the existing local monthly ledger before progress/current-row filtering and on execution termination, including stale/retired executions. It never refreshes a provider account for display. Retirement first cancels and drains scoped workers. A two-second drain timeout keeps cleanup deferred and retains private scratches; it does not authorize deletion while a producer still runs. Both `Cleanup` and `DeferredCleanup` must be observed by the integrating lifecycle owner.

## Integrated review and timeline

`RewriteSession.Windows` creates a real generation instance for each included placed voice passage. The displayed union quote pins every window, voice, model, scope, local operation and review disposition. Dispatch is sequential; currentness is checked through approval and each send. Region changes retire and drain every old window before rediscovering the new set. Excluding or editing a change retires obsolete quotes without changing unrelated dispositions or scoped line/reason/check-this metadata.

Acceptance prepares immutable published results for every included passage, rechecks their project/review/currentness, and calls the editor's scoped list overload once with all segments, assets and local cuts/corrections. One Undo restores the entire prior project. No per-window loop mutates editor history. Full-take proposals use Core's real `PatchRewriteService` and per-hunk diff stitching rather than a whole-take passage-token-limited diff. Scope action names remain `Rewrite full take`, `Rewrite clip {n}` and `Rewrite {w} words`.

Transcript proposal callbacks reveal, focus, edit, include and exclude the same review. Corrections are inline, have IME-safe commit/cancel behavior, and invalidate pending stale selection/caret openings. Source caret, cuts, accepted-speech projection and proposal paint remain separate. The timeline shares Show Cuts with the transcript/shell, persists its S/M/L track size, and receives only real caption track/edit-plan/project snapshots from the existing preview pipeline. Stale snapshots are refused. Empty FX and unavailable captions are not replaced with fabricated data.

## Native capability boundary

Core `65a12ed5466be6ad4bcce99e311ab9f97ab8a60e` is merged into the existing shell branch. Its W1–W4/WC1 planners, batch/cost/enrollment/recovery APIs are consumed rather than copied. `PlaceAll` and the existing placement/render checks remain authoritative. Explicit take UUID selection remains subordinate to actual selectable QA rows.

Native speaker parity remains false. Voice creation/synthesis, unsupported insertion, retime/fit and nonunity source-video paths keep their typed refusals; no ONNX or speaker bypass was added. Existing consent, payment, read-only, media identity, export/SRT/disclosure and share boundaries remain in force. The new Mac own-clip/suggestion-context preference, own-clip voice checkbox and local `/2` consent schema/records were not imported and are not Windows compatibility/parity claims. Native Windows x64/ARM64 compile, High Contrast/scaling/Narrator and full acceptance remain prerequisites before publication.

No dependencies, pins, generated tokens or shared fixture expectations were changed by this integration.

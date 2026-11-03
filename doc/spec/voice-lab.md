# Voice Lab

Status:

- **§4 Clean audio**: normative for M2.
- **§5 to §12 Voice Lab beta**: the Mac beta includes passage Rewrite, clip-audio checkbox consent, scoped voice changing, explicit sentence-context review and per-passage duration choices. The Mac and Windows Core service foundation is described in §2.6. Windows voice creation still waits for the native speaker check (§6.6). Lip-sync provider jobs and local result validation are implemented as services; the editor workflow and lip-sync render route remain unavailable. Native, real-voice, provider and release gates remain open. Unapproved lip-sync settings providers stay hidden in 0.1.0 through the shipped-availability flag.
- **§13**: later capabilities and integration limits.

Voice Lab is every VoxClip feature that sends the user's voice to an AI service and gets new audio or video back. It is separate from transcription (`doc/spec/transcription.md`) and from AI tighten (`doc/spec/ai.md` §12). AI tighten only proposes cuts, never makes synthetic media, and never reuses anything defined here.

Related documents:

| Topic | Owner |
|---|---|
| Edit plan, segment kinds, project file, undo | `doc/spec/editing.md`, `shared/schemas/project.schema.json` |
| Data directories, secrets, logging, error codes | `doc/architecture.md` |
| Voice Lab entry points and right-column panels (§6.3–§6.4), Settings → Voice Lab, copy style | `doc/design.md` |
| Share helpers, VoxConvo publish, caption text | `doc/publishing.md` |
| Caption rendering (the disclosure label is drawn by the same compositor) | the captions spec |

Key words: "must" is a requirement, "should" is a default, and "may" is optional.

---

## 1. Phases and principles

### 1.1 Phases

| Phase | Feature | Synthetic speech or face? | Visible label | Keys |
|---|---|---|---|---|
| M2 | **Clean audio**: ElevenLabs Voice Isolator | No. Noise removal is "standard editing" under the Commission's Art. 50 Guidelines | none | ElevenLabs |
| M3 beta | **My voice**: consent-guarded Instant Voice Clone of the user's own voice | enables synthesis | n/a | ElevenLabs |
| M3 beta | **Voice changer**: speech-to-speech into the user's own clone or a stock voice | yes | AI MODIFIED, for the whole converted range | ElevenLabs |
| M3 beta | **Re-voice a phrase**: patch mode. Replace or insert a few words with TTS in the user's own clone | yes | AI MODIFIED at the start and around each patch | ElevenLabs |
| M3 beta | **Lip sync** of patch windows | yes (face) | as for patch mode | fal.ai or sync.so |
| Voice Lab workflow | AI rewrite and own-voice re-voice of a passage or full take | yes | persistent when the whole take is synthetic | ElevenLabs, with lip sync when selected |
| Later | Own-voice dubbing (translation) | yes | persistent, plus "translated" | ElevenLabs, plus lip sync |

### 1.2 Principles

1. **Prefer real audio.** A deletion is a cut in the word editor, never a synthetic segment. Only insertions and replacements are re-voiced.
2. **Opt in, per action.** Each synthetic segment can be previewed, accepted, turned off or deleted. Nothing synthetic is generated without a click.
3. **Own voice only.** Cloning, and re-voicing with a clone, need a VoxClip consent record (§6) and a speaker match at use time. VoxClip never offers cloning someone else's voice.
4. **Always labelled.** An export with any synthetic segment carries the disclosure outputs in §11. The default build lets the user change only the label's position.
5. **One timeline model.** Synthetic audio and video are segments in the edit plan (§10), never destructive bakes. Undo, restore and captions keep working.
6. **A cost preview before every paid action** (§3). There are no paid background jobs.
7. **Bring your own keys, in the app process.** No VoxConvo server is involved. Keys are handled as in `doc/architecture.md` §11.4.
8. **Runtime discovery.** ElevenLabs models are chosen from `GET /v1/models`, and plan limits from `GET /v1/user/subscription`. Model ids are never hard-coded as the only option, because ElevenLabs removed `scribe_v1` about 16 months after launch.
9. **No telemetry.** Logs follow `doc/architecture.md` §11. They never contain audio, transcript text, consent statements or prompts.

---

## 2. Providers, keys and permissions

### 2.1 Accounts and headers

| Provider | Secret account (Keychain service `com.voxconvo.voxclip` / DPAPI `<data>\Secrets\<account>.bin`) | Header | Base |
|---|---|---|---|
| ElevenLabs | `elevenlabs-api-key` (shared with transcription) | `xi-api-key: <key>` | `https://api.elevenlabs.io`, or the region from `transcription.md` §8.1 |
| fal.ai | `fal-api-key` (*new*) | `Authorization: Key <key>` | `https://queue.fal.run`, `https://rest.fal.ai`, `https://api.fal.ai` |
| sync.so | `syncso-api-key` (*new*) | `x-api-key: <key>` | `https://api.sync.so` |

Every key loaded is registered with the log redactor (`doc/architecture.md` §11.2 rule 1). Keys never appear in project files, provenance files, URLs or logs.

### 2.2 Restricted ElevenLabs key

Settings → Voice Lab explains how to create a dedicated restricted key on elevenlabs.io, with only these permissions and a monthly credit quota. The permission strings below are the ones the ElevenLabs API-key API uses:

| Feature | Milestone | Permissions |
|---|---|---|
| Transcription | M1 | `speech_to_text` |
| Test button, plan gating | M1+ | `user_read` |
| Clean audio | M2 | `audio_isolation` |
| My voice (create, list, delete) | M3 | `create_instant_voice_clone`, `voices_read`, `voices_write`, `speech_to_text` (consent check) |
| Re-voice a phrase | M3 | `text_to_speech`, `models_read`, `speech_to_text` (QA check), `forced_alignment` (optional) |
| Voice changer | M3 | `speech_to_speech`, `voices_read` |

Copy for the guidance panel:

> Create a key just for VoxClip on elevenlabs.io → Developers → API keys. Allow only the permissions listed for the features you use, and set a monthly credit limit. Never enable voice-library publishing, sharing or workspace permissions for this key.

Permissions VoxClip never needs, and which the panel tells the user not to enable:

- `create_professional_voice_clone` (until a later PVC path), `share_voice_externally`, `publish_voice_to_voice_library`;
- all `workspace_*`, `dubbing_*` and `convai_*` permissions;
- `service_account_write` and `create_user_api_key`.

A 401 or 403 whose body names a missing permission maps to `keyPermissionMissing`, with the permission name from this table, for example "This ElevenLabs key can't use the voice isolator. Allow the audio_isolation permission for the key on elevenlabs.io."

### 2.3 Plan gating

`GET {base}/v1/user/subscription` (needs `user_read`) runs when Settings → Voice Lab opens and before cloning. Read these fields:

- `tier`, `status`;
- `character_count`, `character_limit`, `next_character_count_reset_unix`;
- `can_use_instant_voice_cloning`, `voice_slots_used`, `voice_limit`.

Gates:

| Condition | Effect |
|---|---|
| `can_use_instant_voice_cloning == false` | "My voice" is disabled: "Instant voice cloning needs an ElevenLabs Starter plan or higher." |
| `voice_slots_used >= voice_limit` | "My voice" is disabled: "Your ElevenLabs account has no free voice slots." |
| `tier` is `free`, or `status` is `free` | Every Voice Lab row shows "Free ElevenLabs plans allow non-commercial use only." |

`output_format` uses 44.1 kHz PCM only when the tier is Pro or higher. Until the tier names are mapped, the Core service uses `pcm_24000`. A rejected output format is reported without a second paid request. Media integration can resample after validating PCM.

If `user_read` is missing, Core reports the permission failure and leaves clone creation unavailable because its plan and slot gates cannot be checked. Other generation routes still report their own permission or plan failure at action time.

### 2.4 Key tests

| Provider | Test call | Paid? |
|---|---|---|
| ElevenLabs | `GET /v1/user/subscription` (transcription.md §8.5) | no |
| fal.ai | `GET https://api.fal.ai/v1/models/pricing?endpoint_id=fal-ai/latentsync` → 200 with `prices[]` | no |
| sync.so | `POST https://api.sync.so/v2/generations/estimate` `{"model":"lipsync-2","duration":1}` → 200 with `estimatedGenerationCost` | no |

### 2.5 First-use consent per provider

Before the first paid request to each provider, show a sheet. The answer is stored as `voiceLab.providerConsent.<provider>` in settings. The sheet copy:

| Provider | Copy |
|---|---|
| ElevenLabs (Clean audio) | "Clean audio sends this take's audio track to ElevenLabs with your key. ElevenLabs bills your account. No video is sent." |
| ElevenLabs (Voice Lab) | "Voice Lab sends audio of your voice and the words to speak to ElevenLabs with your key. Under ElevenLabs' terms, ElevenLabs may use uploaded content, including your voice, to improve its services unless you opt out in your ElevenLabs account. Generated audio can be traced to your account." |
| fal.ai / sync.so | "Lip sync uploads a short video of the edited part (about {n} seconds) and its audio to {provider} with your key. The files are deleted from {provider} after download where its API allows." |

Buttons: **Continue**, **Cancel**.

---

### 2.6 Cross-platform Core service foundation

The own-voice dispatch boundary and the withdrawal/deletion journal share a per-record gate. Transport starts synchronously under that gate; a committed withdrawal prevents every later start. If dispatch started first, the journal retains its request ID as ambiguous, without retrying the paid request. A failed withdrawal write also leaves dispatch blocked until recovery.

At transport start, a take's dispatch capability checks both its own-voice permit and its reserved input revision. The app checks project selection, provider consent and region on the main actor and starts the transport in that same non-suspending turn. Run invalidation and transport start share a revision gate. An earlier asynchronous validation is not dispatch authorization. Unapproved quote expiry uses five elapsed minutes on a monotonic clock; wall-clock dates are display metadata only. Exactly five minutes is expired, including after a backward wall-clock adjustment. Execution reserves one owner before any suspension; only that owner discards its quotes.

`ElevenLabsVoiceLab` discovers models (`GET /v1/models`), subscription (`GET /v1/user/subscription`) and paginated voices (`GET /v2/voices`) through the selected ElevenLabs region. The caller on each platform selects a discovered model and voice. `VoiceRewriteService` takes a separate estimate and affirmative authorization for its selected LLM connector/model before sending source words and the user's instruction. It returns an inert proposal with original timed words intact. Rewriting a passage and rewriting the entire selected take are both supported requests. The service does not edit, synthesize, or follow URLs in model output. ADR-R30 adds a length budget to this request (§8.9.1).

Creating an Instant Voice Clone takes a verified own-voice consent record and speaker-match policy input, plus explicit authorization for that operation. The caller passes one clone request (`VoiceLabCloneRequest` on both platforms). It holds the display name, the language, the ordered samples, each marked as the consent statement or a training sample, the creation time and the noise-removal choice. §6.7 lists the request rules and the parts that are sent. Core retains `requires_verification` without treating a pending voice as usable. `listOwnClones` filters owned cloned voices from the paginated voice list; deletion is a separate authorized call. Stock selection allows only `premade`, or owner-created `generated`; `cloned`, `professional`, `famous` and unknown categories are denied. The own path requires a matching active consent identity, speaker match and completed provider verification.

Each paid action starts with preparation on the same service instance that will dispatch it: Swift uses `VoiceEnrollment` for clone preparation through package-internal `prepareEnrollmentClone(_:policy:requestID:)` (the plan gate runs in `validateCreationQuote` at execution); other actions use `prepareDelete`, `prepareSynthesis(text:modelID:voice:language:options:requestID:)` or `prepareConversion(audio:modelID:voice:language:seed:cleanAudioOn:requestID:)`. Windows uses `PrepareClone(VoiceLabCloneRequest, …)`, `PrepareDeletion`, `PrepareSynthesis(…, VoiceLabSpeechOptions, …)` or `PrepareConversion(…, uint seed, bool cleanAudioOn, …)`. `VoiceLabSpeechOptions` carries the seed and the optional previous and next text. Preparation performs no provider call. Its immutable quote binds the operation and caller request ID, provider/region/endpoint, displayed estimate, selected model/voice/language, consent identity and verification state, and all billable text or the SHA-256 of exact audio bytes. It also binds every other request field that can change the paid result:

- **Speech:** the seed and, except for `eleven_v3`, the trimmed `previous_text` and `next_text`. V3 has no stitching: context is neither sent nor bound into its quote.
- **Conversion:** the seed and the Clean audio state.
- **Clone:** the trimmed display name, the `labels` language, the creation time, the noise-removal choice, and each sample's position, role and SHA-256.

The caller shows that quote and authorizes it after an affirmative action, using `VoiceLabAuthorization(quote:approved:)` in Swift or the service’s `Approve` method in Windows. The service validates current inputs against the prepared quote, then consumes it before the first possible billable dispatch. Quotes are instance-scoped, hold at most 32 outstanding entries and cannot be replayed sequentially or concurrently. A changed input, model, region, voice, estimate or consent state needs a new quote and approval. A rewrite proposal's ID is the request ID when preparing synthesis of its approved text.

The macOS passage session keeps its displayed quote when the panel mounts or an unchanged field value is written back. Concurrent preparation for the same inputs cannot replace that quote. Real input changes and explicit fresh-quote actions still discard it; detected sign-in cost presentation remains current.

An unapproved prepared quote expires five minutes after preparation on both platforms; approval must occur strictly before that deadline. For a bounded take run (§8.6, S14), Core prepares the complete immutable set before showing its summed cost cap: up to three TTS quotes, binding seeds and trimmed context, and one bounded Scribe QA quote for each take. One affirmative approval authorizes exactly this set, not subsequent runs or changed inputs. Approved remaining quotes do not expire on the clock while that run is active. Each is consumed immediately before its own dispatch. Completion, early stop, cancellation or a change to inputs, model, region, voice, consent or estimate discards the entire unsent remainder. Cancellation before dispatch sends nothing; an in-flight quote remains consumed and its outcome may be ambiguous. Unsent quotes never enter the spend ledger. The $0.50/unknown-price confirmation and monthly-cap warning apply to the run's total, including Scribe QA.

Both Core implementations select the speech transport from the discovered model capability (§8.5), request raw `pcm_24000`, and require valid original-text character timing. TTS models use `POST /v1/text-to-speech/{voice_id}/with-timestamps` with the §8.5 TTS body: `voice_settings`, `seed`, supported trimmed context and `apply_text_normalization: "auto"`. It sends explicit `language_code` for supported models except `eleven_multilingual_v2`, whose documented behavior is language auto-detection. The quote exposes `explicit(language)` or `autoDetected(expected: language)` so the caller can show which mode will run. The language must be in the discovered model's language list. Eleven v4 uses `POST /v1/text-to-dialogue/with-timestamps` on both platforms, with exactly one input, `settings.stability/similarity`, no context and valid `voice_segments`. V4 Turbo remains unsupported because its websocket transport is outside this cut. Endpoint, model, voice, language, seed and text remain bound to one approval; an approval cannot cross speech routes. Voice conversion uses `POST /v1/voice-changer/{voice_id}` for discovered conversion-capable models and the same PCM output. Its documented request has no language field, so Core requires the chosen language in the model's capability list and marks the quote as auto-detected rather than implying forced language selection. The multipart body is the §7.3 request: `audio`, `model_id`, `voice_settings`, `seed`, and `remove_background_noise`, which is false when Clean audio is on. For the same boundary, both Cores write the same multipart bytes, framed as described in §6.7. Conversion input must be a complete RIFF/WAVE file whose declared RIFF length ends at the actual file boundary. Every chunk length and odd-length pad must fit; ordinary ancillary chunks may appear before, between or after audio chunks. Exactly one unambiguous PCM `fmt ` chunk (16 bytes, or 18 with zero extension length) and one `data` chunk are required. Audio is mono, 16-bit PCM at 8–96 kHz, with byte rate and block alignment matching the format, whole samples, at least 20 ms and at most 290 seconds. The whole upload is limited to 16 MiB and the quote binds its exact bytes. Invalid input is refused before a paid send. Missing or malformed alignment makes timestamped TTS invalid. Empty, odd-length, oversized or structurally encoded output is invalid; raw PCM samples with header-like first bytes remain valid. Encoded conversion content types are invalid. A generation is sent once; the caller must make a new estimate and affirmative authorization before trying again. Estimates retain unknown currency and credit amounts when pricing is unavailable. A cancellation before dispatch sends nothing; after dispatch, cancellation or network loss is ambiguous and the same quote stays consumed. No clone, speech or conversion request is retried automatically. Discovery rejects malformed or duplicate model/voice identities, repeated cursors and more than 20 voice pages.

This Core boundary does not yet record consent, perform speaker embedding, join audio to the timeline, preview or undo a segment, or run lip sync. Those are required before the whole Voice Lab workflow is usable in the app. Both implementations consume the exact `shared/prompts/voice-rewrite.json` and `shared/fixtures/voice-lab/contract.json`, including the 31 conversion-input cases. Both Cores validate clone uploads with the same rules (§6.7) and conversion input with the same parser. Both also consume `shared/fixtures/voice-lab/request-cases.json`, which holds:

- 21 request goldens: the exact method, path, query, headers and body for clone, TTS and voice changer requests. Multipart bodies are pinned byte for byte with a fixed boundary.
- 18 quote mutations, each changing one field after approval.
- 42 clone-input cases.
- The Unicode White_Space set that both Cores trim with.

## 3. Cost preview

### 3.1 Rule

Every action that can bill a provider shows an estimate **before** it runs.

```swift
public struct CostEstimate: Codable, Sendable, Hashable {
    public var provider: String          // "elevenlabs" | selected LLM connector | "fal" | "syncso"
    public var operation: String         // "voiceRewrite", "patchRewrite", "createClone", "deleteClone", "textToSpeech", "voiceChange", plus later media operations
    public var units: Double             // minutes, characters, seconds or tokens, per `unit`
    public var unit: String              // "minute" | "character" | "second" | "call" | "token"
    public var usd: Decimal?             // nil when the price is unknown
    public var credits: Int?             // ElevenLabs credits, when known
    public var basis: String             // "list-<checked>" (§3.2) | "provider-estimate" | "provider-pricing-api" | "unknown"
}
```

An LLM send (`voiceRewrite`, `patchRewrite`) estimates its request in tokens with basis `unknown`. Its presentation depends on who pays:

- A CLI connector signed in on a plan, a loopback local server, a remote local server and Apple on-device present as **inline with no amount**. Their button is just the action, and they do not confirm. The send line says where the words go.
- An API-key connector, and a CLI connector signed in with an API key, present as **confirm** with "VoxClip can't tell what this costs. Check {provider}'s pricing." on every send.

A CLI's sign-in method is one of three, each named by what the detection of ai.md §6.8 item 3 and §6.9 item 4 reads:

- **Plan**: a method ai.md recognises as a plan. That is Claude Code's `claude.ai` or OAuth sign-in (the list in ai.md §6.8 item 3), or Codex's "Logged in using ChatGPT".
- **API key**: Claude Code's `authMethod` is an API key, or Codex's status says "Logged in using an API key".
- **Unknown**: anything else. That includes Claude Code's `third_party` (Bedrock or Vertex, billed to the user's cloud account), `none` or a missing method, and any other successful Codex output. An unknown method sends nothing (ai.md §4.8): no sheet, no confirmation and no inline send.

A method is never a plan just because it is not an API key. The first-use privacy confirmation (ai.md §4.8, inline on Mac) still comes before each connector's first send; a first API-key send combines privacy and billing in that one inline row. `VoiceLabCostPresentation`, or a helper beside it, applies this rule on both platforms from the connector kind and the sign-in method that ai.md §6.8–§6.10 detection already reads; it adds no setting or field. The table below covers every other estimate.

| Estimate | Presentation |
|---|---|
| under $0.50 and known | shown on the button: "Clean audio · ≈ $0.36", "Re-voice · 3 takes · ≈ $0.02". One click runs it |
| $0.50 or more, any lip sync, or unknown | a confirmation: "This will cost about {amount} on your {provider} account." (or "VoxClip can't tell what this costs. Check {provider}'s pricing.") with [Continue] and [Cancel] |

`VoiceLabCostPresentation` in Core applies the table on both platforms:

- `kind(estimate, isLipSync:providerName:cap:)` is inline only when `usd` is known, below 0.50 before rounding, the action is not lip sync, and it does not cross the monthly cap (below). A $0.4999 action stays on the button as "≈ $0.50". Everything else confirms.
- An action whose estimate is exactly $0, such as creating or deleting a voice, shows no amount anywhere: `kind` is inline with empty text, its button is just the action, and the ledger does not record it. Lip sync is the exception and always confirms. A valid lip-sync estimate is never $0 anyway, because zero seconds is invalid input (§3.2).
- In the confirmation, `{amount}` is the formatted amount without "≈ " ("$0.50", "$12", "$1,200"). A known amount below a cent reads "This will cost less than $0.01 on your {provider} account." `{provider}` is the provider's display name ("ElevenLabs", "fal.ai", "sync.so").
- `buttonTitle(action, takes:kind:)` joins the action, the take count ("1 take", "3 takes") and an inline amount with " · ". A button whose action confirms carries no amount: "Clean audio", "Lip sync", "Re-voice · 3 takes".

`format(usd)` writes every amount:

- Below $0.01 it is "< $0.01", with no "≈".
- Otherwise the amount is rounded once, half away from zero, to two significant digits or to the cent, whichever is coarser. Amounts below $10 show two decimals; amounts from $10 show whole dollars with comma thousands. The text starts with "≈ ".
- Examples: 0.0144 → "≈ $0.01", 0.015 → "≈ $0.02", 0.36 → "≈ $0.36", 0.4999 → "≈ $0.50", 1.2 → "≈ $1.20", 9.949 → "≈ $9.90", 9.95 → "≈ $10", 12345.6 → "≈ $12,000".

Spend ledger:

- `<data>/VoiceLab/spend.json` sums the estimates of actions that were run, per provider and calendar month, in the format `voxclip-voice-lab-spend/1`:

  ```json
  {
    "schema": "voxclip-voice-lab-spend/1",
    "months": {
      "2026-10": {
        "elevenlabs": {
          "usd": "0.36",
          "unknownCount": 0
        }
      }
    }
  }
  ```

  `usd` is the sum of the known estimates as a decimal string with at most 10 decimals. `unknownCount` counts the actions whose price was unknown. Months and providers are written in ordinal order, with a two-space indent, LF line ends and a final LF.
- `ElevenLabsVoiceLab` calls `record(estimate, at:)` itself, once for each action the provider accepted. Acceptance is the 2xx status line: once a 2xx status and its headers arrive, the provider has billed. The record of the approved quote's estimate, with the time the request was sent, starts at that point and is never undone. A cancellation after that point does not prevent it.
  - If reading the body then fails, through a cancellation mid-body, a dropped connection, or a body over the size limit (by `Content-Length` or as read), the record still finishes before the error is thrown. The user sees the error and gets no receipt, but the money is counted.
  - Nothing is recorded for a refused authorization, a failed request, a 4xx or 5xx reply, or a cancellation before the status line.
  - The record runs off the caller's actor and thread, in a detached task on macOS and on the thread pool on Windows, never on the main actor or the UI thread. It ignores the caller's cancellation.
  - The App and CLI never record and never call a Voice Lab provider directly.
  - A $0 estimate is not recorded and touches nothing.
  - The month key is the local calendar month at the time the request was sent, in the device's time zone as it is when the action is recorded, not when the ledger was created: an action started at 23:30 on 31 October counts in October even if it finishes in November.
- A recorder takes the advisory lock `spend.json.lock` beside the file: an exclusive `flock` on macOS and an exclusive `FileShare.None` open on Windows. Readers, including the cap check, take a shared lock (`FileShare.Read` on Windows) and wait at most 0.5 seconds, so they never read through a replacement. The lock is polled every 10 ms for up to 5 seconds without blocking a thread: `record` is async on both platforms. Only another holder (`EWOULDBLOCK`, or a sharing or lock violation on Windows) is waited for; any other failure, such as read-only media or a full disk, is `writeFailed` at once. Cancelling the wait gives `cancelled`.
- Under the lock the recorder reads the file, adds the estimate, writes a 0600 temporary file in the same directory and moves it over `spend.json`. macOS flushes the temporary file with `F_FULLFSYNC` and the directory after the rename; Windows flushes it with `Flush(true)` before `File.Replace`. The lock file is never deleted. Two recorders in separate processes never lose an update.
- `<data>/VoiceLab` is created as the paid-asset writer creates it: only its last component, mode 0700, inside an existing data folder. A missing data folder is `writeFailed`, never created.
- A file that is not exactly this format is renamed to `spend.corrupt-<Unix milliseconds>.json` and a fresh ledger starts. This covers invalid UTF-8, a byte-order mark, an extra or repeated key, a bad month or provider key, and a bad amount or count.
- Recording never throws into the provider path. It returns a typed warning instead (`replacedCorruptLedger` with the backup name, `lockTimedOut`, `cancelled`, `writeFailed` or `invalidEstimate`), and the action's result stands. `ElevenLabsVoiceLab` logs the warning and returns it as `spendWarning` on the action's `VoiceLabReceipt`, which the audio and clone results forward. The caller shows it as a notice, never as a failure. When the body failed, the caller gets the error instead, and the warning is only logged. The service's own records ignore cancellation, so `cancelled` reaches only a direct caller of `record` that cancels the wait.
- The ledger is an estimate, not a bill. The provider's own credit quota, such as the restricted key's limit, is the hard stop.

Soft cap:

- Settings → Voice Lab → "Warn me above $__ a month per provider" has no default. It is stored as `voiceLab.monthlyCapUsd.<provider>`: a decimal string with at most two decimals (`"20"`, `"12.5"`), or null or absent for no cap.
- An action crosses the cap when its estimate is known and takes the provider's known total for that month from at most the cap to above it. `kind` takes the cap and that total (`VoiceLabMonthlyCap(limit:spent:)`): an action that crosses always confirms, even under $0.50, and the confirmation adds "This takes you past your ${cap} limit for {provider} this month." The cap is written "$20", "$12.50" or "$1,000".
- `wouldCross(cap:provider:estimate:at:)` and `total(provider:at:)` read the ledger under the shared lock. When the ledger cannot be read in time, the total is unknown and nothing crosses.

### 3.2 Prices (API list prices, USD, checked 2026-10-25)

Prices live in a data file, `shared/catalog/voice-lab.json` (format `voxclip-voice-lab-prices/1`), so they can be updated without code changes. `tools/schemas/validate.py` checks it against `shared/schemas/voice-lab-prices.schema.json`. Each entry is `{provider, operation, model?, endpoint?, unit, formula, usdParameters, creditsParameters?, checked, source}`:

- Prices are decimal strings such as `"0.22"`, never binary floating point. Both platforms compute in decimal and round `usd` half away from zero to 10 decimals.
- `formula` is `perHour`, `perMinute`, `perSecond`, `perThousandCharacters`, `flatThenPerSecond`, `zero` or `estimateApi`. The schema fixes each formula's unit and parameter keys.
- Duration rows take seconds, TTS rows take characters (Unicode scalars), and creating or deleting a voice takes one call. A lip sync of zero seconds is invalid input, with or without a catalog entry: the caller refuses an empty window before it asks.
- An entry applies when provider, operation and endpoint match; an entry without `model` applies to every model. A catalog with two entries that could price the same request, or with any other defect, does not load (`sharedResourcesMissing`).
- `VoiceLabPricing.estimate(operation:model:units:candidates:characterMultiplier:catalog:)`, whose `operation` names the provider, operation, endpoint and unit, gives the basis `list-<checked>`. A model or operation without an entry gives `usd` nil and the basis `unknown`, never a guess. So does an `estimateApi` entry, until a §3.3 live price arrives through `applying(_:to:)`.
- TTS bills each model at its own row's list price. The `model_rates.character_cost_multiplier` that `GET /v1/models` reports is a credit multiplier, so it scales credits only, never dollars. When absent it is 1. Outside 0.01 to 100 it is invalid input to an estimate and a malformed response from discovery.
- Credits: Voice Isolator and Voice Changer cost 1,000 per minute, rounded up to a whole credit. TTS costs ceil(characters × candidates × multiplier × credits per character). Every other operation has unknown credits.
- `shared/fixtures/voice-lab/pricing-cases.json` pins every entry, the format boundaries, the ledger and the cap for both platforms.

Initial values:

| Operation | Price | Formula |
|---|---|---|
| ElevenLabs Scribe v2 (consent check, patch QA) | $0.22 per audio hour | `seconds / 3600 × 0.22` |
| ElevenLabs Voice Isolator | $0.12 per minute; 1,000 credits per minute on credit plans | `seconds / 60 × 0.12` |
| ElevenLabs Voice Changer | $0.12 per minute; 1,000 credits per minute | `seconds / 60 × 0.12` |
| ElevenLabs TTS `eleven_v4`, `eleven_v3`, `eleven_multilingual_v2` | $0.08 per 1,000 characters; 1 credit per character × multiplier | `characters × candidates / 1000 × 0.08`; credits `ceil(characters × candidates × multiplier)`, with `multiplier = model_rates.character_cost_multiplier` from `GET /v1/models` (default 1) |
| ElevenLabs TTS `eleven_flash_v2_5`, `eleven_v4_turbo` | $0.04 per 1,000 characters, already the half rate; their multiplier (0.5) halves credits, not dollars | `characters × candidates / 1000 × 0.04`; credits as above |
| ElevenLabs Forced Alignment | $0.22 per audio hour | as for Scribe |
| ElevenLabs Instant Voice Clone | no per-call charge (Starter plan or higher) | 0 |
| ElevenLabs voice deletion | no charge (lead decision, 2026-10-27) | 0 |
| fal `fal-ai/latentsync` | $0.20 flat up to 40 s, then $0.005 per second | `0.20 + max(0, s − 40) × 0.005` |
| fal `fal-ai/sync-lipsync/v2`, model `lipsync-2` | $3.00 per minute | `s × 0.05` |
| fal `fal-ai/sync-lipsync/v2`, model `lipsync-2-pro` | $5.00 per minute (shown as 1.67 × lipsync-2, checked 2026-10-26) | `s × 5 / 60` |
| fal `fal-ai/sync-lipsync/v3` (sync-3) | $8.00 per minute (model page, checked 2026-10-26) | `s × 8 / 60` |
| sync.so `lipsync-2`, `lipsync-2-pro`, `sync-3` | $0.04–0.05, $0.067–0.083 and $0.107–0.133 per second, depending on plan | from the estimate API (§3.3) |

### 3.3 Live price sources (preferred when reachable)

| Provider | Call | Use |
|---|---|---|
| sync.so | `POST https://api.sync.so/v2/generations/estimate` with `{model, duration, fps}` | `estimatedGenerationCost` (USD) and `estimatedCredits`; `basis = provider-estimate` |
| fal | `GET https://api.fal.ai/v1/models/pricing?endpoint_id=<id>` | `prices[].unit_price`, `unit`, `currency`. Use it only when `unit` is understood (`second`, `video`, `minute`); otherwise fall back to §3.2 |
| ElevenLabs | no price API | the §3.2 table, plus the credit multiplier from `GET /v1/models` |

---

## 4. M2: Clean audio (ElevenLabs Voice Isolator)

### 4.1 Behaviour

- **Where.** Edit > **Clean Audio…** (and ⋯ > Clean Audio… on Windows) opens a right-column panel shaped like Rewrite (`doc/design.md` §6.4). It has:
  - the button "Clean Audio · ≈ $X";
  - the line "Uses your ElevenLabs credits. Sends the audio track only.";
  - after a run, a **Mix** slider from 0 to 100% (default 100%), an **A/B** toggle (hold to hear the original), and **Remove**.
- **Effect.** Clean audio replaces the audio track. The cuts, timeline, transcript and captions do not change, and no re-transcription happens.
- **Label.** None. Noise removal that does not change the meaning is out of scope of Art. 50. The run is still recorded in the provenance sidecar (§11.8) and in C2PA as `c2pa.filtered`, with no AI `digitalSourceType`.

### 4.2 Input

1. Decode the source audio track at its native rate (capped at 48 kHz; higher rates are resampled to 48 kHz). Downmix to mono with an equal-weight average, keeping the same timeline as `audio-16k.wav` (transcription.md §4).
2. Write 16-bit PCM WAV to `<data>/Cache/<contentKey>/isolate-in-<rate>.wav`. At 48 kHz mono that is 5.76 MB per minute, about 346 MB per hour.
3. Split into requests when the duration exceeds 3 540 s or the size exceeds 480 000 000 bytes:
   - Put each split at the quietest 10 ms frame inside the transcript pause (gap ≥ 0.4 s) nearest to every multiple of 3 300 s.
   - If no such pause lies within ±120 s of the target, split at the quietest frame within ±2 s.
   - Chunks do not overlap.

### 4.3 Request

```
POST {base}/v1/audio-isolation
xi-api-key: <key>
Content-Type: multipart/form-data
  audio = <isolate-in-<rate>.wav or chunk>; filename="audio.wav"; Content-Type: audio/wav
```

- Send no `file_format` part, because the WAV header describes the audio. `pcm_s16le_16` is accepted only for raw 16 kHz input, which this flow does not use.
- Limits (capability page): 500 MB and 1 hour per file. Video containers are accepted too, but are never sent.
- Response: 200 with the audio bytes. The format is undocumented, so sniff it:

  | First bytes | Format |
  |---|---|
  | `RIFF….WAVE` | WAV |
  | `ID3`, or an MPEG frame sync `0xFFE` | MP3 |
  | `fLaC` | FLAC |
  | `OggS` | Ogg |

  Decode with AVFoundation (`AVAudioFile`) on macOS and FFmpeg on Windows.
- Errors:
  - 401 → `keyRejected`; 403 → `keyPermissionMissing` (`audio_isolation`); a quota or credits message → `quotaExceeded`; other errors → `providerError`.
  - 429 and 5xx are retried per `doc/architecture.md` §10.1 rule 5. Other errors are not retried.
- Cancel aborts the request. The UI says "Cancelled. ElevenLabs may still bill audio it already received."

### 4.4 Duration check and alignment (per chunk)

1. Decode the output and resample it to the input rate.
2. `Δ = outputSamples − inputSamples`. If `|Δ| ≤ round(0.020 × rate)`, trim or zero-pad the end to the input length. Done.
3. Otherwise compute 10 ms RMS envelopes of the input and the output: frames of `round_half_up(rate × 0.01)` samples from sample 0, without the partial final frame. Search whole-frame lags up to `floor(round_half_up(0.5 s × rate) ÷ frame)` frames on each side, or ±0.3 s for the voice changer (§7.3).
   - **Score.** Each lag scores the Pearson correlation of the overlapping frames, with both means taken over that overlap, clamped to at most 1. A constant overlap scores 0. So does an overlap shorter than half the shorter envelope, `ceil(min(nIn, nOut) / 2)` frames, because two frames correlate ±1 by construction and would beat the true lag of a one-word chunk.
   - **Choice.** `L` is the first lag with the strictly highest score, searched in the order 0, −1, +1, −2, +2, …. Ties go to the smallest `|L|`, then to the negative lag. A positive `L` means the output is late.
4. If the peak is below 0.5, or `|Δ − L|` is above 20 ms, fail with "Clean audio came back out of sync, so it was not applied. Try again." The cost was spent; say so.
5. Otherwise shift by `L`, then trim or pad to the input length.
6. Join chunks by concatenation. The split points lie in silence, so no crossfade is needed.

### 4.5 Storage

- Write the aligned result as FLAC (24-bit, mono, at the input rate) to `<data>/VoiceLab/<contentKey>/clean-<inputSha8>.flac`.
  - macOS: `ExtAudioFile` with `kAudioFormatFLAC`.
  - Windows: FFmpeg's `flac` encoder.
- This directory is **not** cache. Eviction never touches it, because the file is paid and needed for export. Settings → Voice Lab → Storage lists it, with Remove.
- When the mix is not 100%, render a mixed file `clean-<inputSha8>-mix<pct>.flac` = `mix × clean + (1 − mix) × original` on slider release. Preview and export both use that single file.
- If the file is missing (for example after opening the project on another machine), show "The Clean audio file isn't on this computer." with [Run again · ≈ $X] and [Turn off]. Until then, export uses the original audio and says so in the Export sheet.

### 4.6 Media integration

The Clean audio file replaces the source audio track as the input of the edit plan:

- The same rate, the same `totalSamples`, and the same kept ranges and join fades (`editing.md` §7.4, §7.7).
- macOS: the composition builder takes the audio track from the FLAC `AVURLAsset` instead of the source.
- Windows: the audio decoder reads the FLAC.
- `media.source` is unchanged. Turning Clean audio off restores the original immediately.

### 4.7 Project data (the schema version that ships M2)

`voiceLab.cleanAudio` is `null`, or:

```json
{
  "enabled": true,
  "mix": 1.0,
  "provider": "elevenlabs",
  "endpoint": "audio-isolation",
  "inputSha256": "<sha256 of isolate-in-<rate>.wav>",
  "resultSha256": "<sha256 of clean-<inputSha8>.flac>",
  "resultFile": "<contentKey>/clean-<inputSha8>.flac",
  "sampleRate": 48000,
  "alignmentLagSeconds": 0.0,
  "chunks": 1,
  "estimateUsd": 0.36,
  "createdAt": "2026-10-25T12:00:00Z"
}
```

`resultFile` is relative to `<data>/VoiceLab/`. Turning Clean audio on or off and moving the mix slider are each one undo step.

### 4.8 Acceptance tests

1. **Request.** The multipart body matches a golden file: part `audio`, filename and content type, and no other parts.
2. **Format sniffing.** WAV, MP3, FLAC and Ogg samples are detected.
3. **Alignment.**
   - An output 15 ms longer is trimmed.
   - An output delayed by 120 ms (synthetic envelope) is shifted back to within 1 ms.
   - An unrelated output fails with the out-of-sync error.
4. **Chunking.** A 2 h synthetic take splits at the pauses nearest 3 300 s and 6 600 s, and the reassembled length equals the input length.
5. **Export.**
   - With mix 100%, the exported audio equals the clean file over the kept ranges, sample-exact apart from the join fades.
   - With Clean audio off, the export is bit-identical to an export without Clean audio.
6. **No label.** No disclosure label is drawn. The provenance sidecar lists `cleanAudio`.
7. **Key handling.** The redactor test includes an `xi-api-key` header from this request.

A local, offline alternative (DeepFilterNet or similar) is out of scope until its licence is confirmed.

---

## 5. Voice Lab beta: 0.1.0 gate and settings

0.1.0 ships text Rewrite. Voice Lab is a beta behind its setting: Mac can create your voice, re-voice rewritten words and change the voice of a passage or full take; Windows re-voice is not available until voice creation is. Lip sync is later (M3+).

- Settings → Voice Lab → **Show Voice Lab (beta)**. It is off by default in release builds; development builds turn it on (below). On Mac, turning it on opens the inline Voice first-use card; Windows retains its one-time presentation:
  - "Voice Lab can create a copy of your own voice and re-voice words you rewrite. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key."
  - Buttons [Turn on] and [Cancel].
- **Rewrite** (the scope bar, the sidebar row's Rewrite, the selection bar and the menus; `doc/design.md` §6.3) does not need Voice Lab. It proposes cuts, text fixes and phrases in your voice. Cuts and fixes apply with Voice Lab off. Phrases in your voice, making your voice, takes, **Insert Words…**, **Change Voice…** and lip sync need `voiceLab.enabled` and `voiceLab.betaNoticeAccepted`. With Voice Lab off, voice changes stay visible but excluded, with "Needs Voice Lab (beta)", and the panel offers **Turn On Voice Lab…**, which opens the inline Voice job on Mac (the one-time presentation on Windows).
- Your voice is made inside Rewrite (§6.5.2). Settings → Voice Lab lists and deletes voices; it no longer creates them.
- Windows appends "Creating your voice isn't available on Windows yet." to the beta notice. Its full notice is "Voice Lab can create a copy of your own voice and re-voice words you rewrite. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key. Creating your voice isn't available on Windows yet." Unshipped lip-sync keys and monthly-cap rows stay hidden on both platforms; saved values are preserved.
- Settings → Voice Lab also shows:
  - the ElevenLabs key row (§2); fal.ai and sync.so key rows and monthly caps are hidden in 0.1.0 behind one lip-sync availability constant per platform. Stored keys and settings are preserved for M3+;
  - **My voices**: the consent records, with their voice name, creation date, ElevenLabs voice id, and [Delete voice];
  - the ElevenLabs spend cap (§3.1) and the label position (§11.2);
  - Content Credentials (C2PA) for Clean-audio-only exports, on or off (§11.7; exports that need disclosure always carry a machine-readable mark);
  - storage.
- None of these features may block the core loop: import, cut, captions, clips, export.

Settings persist the switch as `voiceLab.enabled` (default false), the acknowledged one-time notice as `voiceLab.betaNoticeAccepted` (default false), the label position as `voiceLab.labelPosition` (`top-right` by default; `top-left`, `bottom-right`, `bottom-left` are the other values), and the Clean-audio-only C2PA preference as `voiceLab.c2pa` (default true). Keys and consent records are not settings values. Per-provider caps retain the keys and decimal-string format in §3.1.

Release builds always list the Voice Lab pane.

Development builds turn Voice Lab on by default, because the app is under active development. While the settings file has no `voiceLab.enabled` or no `voiceLab.betaNoticeAccepted`, a development build reads that key as true. The app never writes this value. A value the user sets, true or false, always wins, so turning Voice Lab off sticks. Development builds also let Rewrite's Voice Lab parts skip the beta notice.

- **macOS.** A development build is a DEBUG build: `./bundle.sh` with no mode option. `--release` and `--sign-only` make Release builds. Only the app's own settings file gets the overlay; harness sessions and injected test stores keep the shipped default.
- **Windows.** A development build defines `VOXCLIP_DEVELOPMENT`. Debug defines it by default, and a Release-config test copy opts in with `-p:VoxClipDevelopmentBuild=true`. On Windows, MSBuild ignores an environment variable of that name in any letter case; on macOS and Linux it ignores only the exact name. Self-checks, demo captures and native probes keep the shipped default, and so do test stores.
- Turning Voice Lab back on in a development build skips the beta notice and writes only `voiceLab.enabled`. Acceptance is written only when the user confirms the notice.
- Release pipelines never make a development build. Release-boundary tests check this on both platforms.

---

## 6. My voice: consent-guarded own-voice clone (ElevenLabs IVC)

ElevenLabs' Instant Voice Clone guide requires confirmation of rights and consent. The creation API accepts sample files and returns `requires_verification`; VoxClip must honor that flag. A recorded statement was VoxClip's additional product guard, not a mandatory field of the IVC creation endpoint. ADR-R34 replaces that extra recording for existing project speech with explicit checkbox consent. The read-aloud route retains its recorded-statement flow.

The app is open source, so the guard is good-faith friction and an audit trail, not security. The real backstops are ElevenLabs' terms and the traceability of its output to the user's account.

### 6.1 Preconditions

- The §2.3 gates pass, or cannot be checked.
- **Notice**, shown before anything is recorded. Exact text:
  > Your voice clone is created in your ElevenLabs account and stays there. ElevenLabs' terms let it use uploaded content, including your voice, to improve its services; you can opt out of training in your ElevenLabs account, but the opt-out is not retroactive. You can delete the voice at any time from VoxClip or ElevenLabs. ElevenLabs' Prohibited Use Policy applies, including its rules on political content.

  It links to `https://elevenlabs.io/terms-of-use` and `https://elevenlabs.io/use-policy`.
- **Attestations**: three checkboxes, all required:
  - "I confirm this is my own voice and I consent to creating a voice clone."
  - "I am 18 or older."
  - "I will use it only on videos of myself."
- **Display name**: 1 to 60 Unicode scalars after trimming Unicode whitespace; the trimmed name is stored and used in the statement and the voice name. It must not contain a control character (§6.7). The consent form applies the same count as `addVoiceReference` (§10.5) before the paid clone is created, so a name the reference would refuse never reaches ElevenLabs. Grapheme clusters and UTF-16 units are not the measure: 31 decomposed `õ` (62 scalars) are refused.

### 6.1.1 Existing clip audio: checkbox consent (ADR-R34)

For the project-audio choice, the inline agreement leads to **Use Clip Audio**, enabled only with a valid display name, all three explicit attestations and usable analyzed speech. The checkbox text is the fixed `VoiceConsentRecord.ProjectConsent.text`, saved verbatim as evidence. Explain: "Your agreement is saved with the selected clip audio. You do not need to record a consent statement. ElevenLabs may ask you to verify the voice after creation."

Preparation extracts the selected project spans, takes the first accepted training span as the reference and runs the existing calibrated speaker-consistency checks against that reference. This checks consistency among the selected audio; it does not independently establish the user's identity. At least 30 seconds must pass, up to 120 seconds. The named reference is one of the training uploads, sent exactly once. No microphone, statement nonce, fabricated transcript or Scribe statement request is involved. Project speech may be reused from the full source according to §6.5.1; the scope label is not a promise that a very short clip alone supplies enough training speech.

The ready step shows the selected speech duration, checkbox consent and the actual creation quote. Only **Create My Voice** authorizes the account check and upload. Changing the agreement or audio invalidates the ready plan. A response that requires verification stays unusable until genuine provider verification is completed and checked again. The read-aloud choice remains available when project speech is insufficient or unsuitable.

The Mac implementation uses this route. Windows Core accepts `/2` evidence, private reference storage and creation-only quote binding for compatibility; portable tests cover that contract. Native Windows clone creation remains gated on the speaker check. This does not claim a completed Windows enrollment workflow or relax its speaker gate.

### 6.2 Consent statement (recorded-statement route)

A new statement is generated for each attempt:

| Language | Template |
|---|---|
| en | `My name is {name}. Today is {date}. This is my own voice, and I agree to an AI copy of it being made with ElevenLabs for editing my own videos. {w1} {w2} {w3} {w4}.` |
| et (draft, needs native review before release) | `Minu nimi on {name}. Täna on {date}. See on minu enda hääl ja ma nõustun, et sellest tehakse ElevenLabsi abil tehisintellekti koopia minu enda videote toimetamiseks. {w1} {w2} {w3} {w4}.` |

- **Language.** The statement uses the transcript language of the open project, or else of the most recent project (its primary subtag: `en-GB` is `en`), but only when that language has a calibrated speaker check (§6.6). Otherwise it uses English. Only English is calibrated today, so an Estonian user records an English statement. Training audio from a project (§6.5 a) may be in any language, because the speaker match compares voices, not words. The consent record and the clone's `labels` language stay the statement language.
- **`{date}`.** The local date written out in full. Use fixed month tables, not the OS locale, because the Windows build runs with `InvariantGlobalization`:
  - en: `25 October 2026`, months January … December;
  - et: `25. oktoober 2026`, months jaanuar, veebruar, märts, aprill, mai, juuni, juuli, august, september, oktoober, november, detsember.
- **`{w1..w4}`.** A nonce of four different words drawn with the system CSPRNG from `shared/voice-lab/nonce-words-<lang>.txt`. Create these lists with M3: at least 500 common words each, 4 to 8 letters, easy to pronounce, with no homophones of each other, no profanity and no names. The nonce defeats replaying an old recording.

### 6.3 Live recording

This section applies only to the recorded-statement/read-aloud route; §6.1.1 requires no microphone recording.

- The statement is recorded from the microphone in the app. Imported files are not accepted.
- Recording uses the M2 capture stack: 48 kHz mono, at least 5 s, at most 30 s, with a level meter and a "Read this aloud" teleprompter.
- **macOS callback isolation.** Both AVAudioEngine taps are Sendable callbacks created by the synchronized sample sink, outside the main-actor recorder. They consume each audio buffer on the audio queue without accessing UI state. The main-actor meter reads the sink; stopping closes it before removing the taps, so a late callback cannot change an accepted or discarded take.
- The recording is kept in memory and in `<data>/VoiceLab/consent/<recordId>/statement.wav`.
- **Windows capture.** Windows records the default Console-role WASAPI input in shared mode on its own thread and keeps device-rate mono samples in memory; the session converts them once to 48 kHz with the Core resampler. The statement is validated at 5–30 s; training capture stops at 90 s and is validated at 60–120 s. The temporary 16 kHz Scribe input is removed after verification. The endpoint is fixed for a take: device loss, a stalled input, unplugging, lock or sleep discards the take instead of switching devices. Silence is exact digital zero on every original channel for 2.0 s, or packets flagged silent; opposite-phase stereo is not silence. Closing Settings, turning Voice Lab off, an update restart (reported as busy) and quitting discard and abandon an active capture, and startup removes abandoned statements even with the beta gate off. macOS likewise stops a take after 2.0 s of digital zero on every input channel before the mono mix.

### 6.4 Verification

The statement/Scribe checks below apply to recorded statements. The attested project route has no statement to transcribe and prepares a creation-only quote; its local speaker reference is selected project speech (§6.1.1). Provider-required verification remains separate and mandatory for both routes.

1. **Order.** After the live statement (§6.3), the speaker match (§6.6) runs on device first, against the selected project spans or the read-aloud. Only when enough audio passes does the panel offer **Create My Voice**. Its single approval covers, in order: the plan check (§2.3); then, only if the plan check passes, Scribe transcription of the statement (ElevenLabs Scribe v2, transcription.md §8, with `language_code` set to the statement language; under $0.01); then, only if item 3 passes, the creation (§6.7). The approval binds everything §6.7's quote binds: the trimmed name, the language, the creation time, the noise-removal choice, and each file's position, role and SHA-256 (the statement is the first file). So the file set is final when the user approves, and any change to these needs a new approval. A failed plan check stops before Scribe and spends nothing. A failed statement check creates nothing and spends only the Scribe request.
2. **Normalise.** Tokenise both texts on whitespace and normalise with `normalizeForMatch` (`editing.md` §4.7).
3. **Pass** only if all of these hold:
   - word-level WER (Levenshtein distance / expected word count) ≤ 0.15;
   - all four nonce words appear in the recognised tokens;
   - the recognised language matches the statement language.
4. **Attempts.** Three distinct statement recordings per 10 minutes, identified by statement WAV SHA-256 plus nonce. Rechecking the same saved statement against project audio or a read-aloud, or preparing again after quote expiry, does not consume another attempt. On failure, show "That didn't match the statement. Read it again, clearly, in one take." and generate a new statement for the next attempt. The speaker match reruns on the new recording.

### 6.5 Training samples

The consent statement is always recorded live and verified (§6.2–§6.4); it is what keeps cloning to the user's own voice. The source is chosen automatically: (a) when §6.5.1 selects at least 30 s that pass §6.6; otherwise (b).

- **(a) This project's audio.** Spans of the take in the project open in the editor. Other projects are not offered yet. Spans are read from the source media, so words cut in the edit still count and edits never change the selection. This is the default for a project that has a transcript, including from Rewrite's **Make Your Voice**, which passes the rewrite scope's clip as `preferRange`. §6.5.1 chooses the spans: at most 120 s of clear speech, and at least 30 s before the speaker match. Below that, the steps fall back to (b). The copy says "video", not "project".
- **(b) A fresh read-aloud.** A 90 s script from `shared/voice-lab/scripts-<lang>.txt` (created with M3), recorded like §6.3. It is uploaded in spans of 5 to 30 s, preferring spans between pauses. It is used whenever (a) is unavailable or fails §6.6.

Then process the samples:

1. Normalise each span to −20 dBFS RMS over voiced frames (frames above −45 dBFS), with true peak at most −3 dBTP.
2. Encode each span as mono 16-bit PCM WAV at its source rate (8–96 kHz). Core accepts only WAV until spike S5 (§14) settles the upload format. After S5, the candidate is AAC-LC 256 kbps, 44.1 kHz mono, in M4A: AVAssetWriter on macOS, FFmpeg's native `aac` encoder on Windows. Project spans are cut from the mean of the source's audio channels; a source rate outside 8–96 kHz makes (a) unavailable.
3. Upload 1 to 25 files, counting the consent statement from step 4. Each file lasts 5 to 30 s, and together they last 10 to 240 s (§6.7). The recommended total is 1 to 2 minutes. More than 3 minutes gives little improvement. Project audio sends at most 120 s of spans, so at most 24 spans.
4. **Add the consent statement recording as one of the samples.** This makes the clone provably derived from the consenting speaker.
5. Set `remove_background_noise=false`. It "can make the quality worse" on clean audio. Use `true` only when the SNR is below 20 dB and Clean audio has not been applied to the source take. Project spans always pass 20 dB, so they send `false`.

Training WAVs of either source are temporary. They are kept in memory or private temporary files and deleted after the upload, or when the enrollment is explicitly discarded without an upload.

#### 6.5.1 Span selection (project audio)

`VoiceTrainingSpans.select` (Swift) and `VoiceTrainingSpans.Select` (C#) are pure Core functions with the same result on both platforms. Vectors: `shared/fixtures/voice-lab/training-spans.json`.

Inputs:

- **Items.** The project transcript's items in stored order, each with `kind`, `start`, `end`, `conf`, `speaker` and `synthetic`. Times are source seconds, not edited times. `synthetic` is true for every item from `firstWordId` to `lastWordId` of any Voice Lab segment.
- **Excluded ranges.** Source `[start, end]` ranges that must never be used: the `replace` range of every Voice Lab segment, enabled or not, passage or full take. VoxClip never trains on generated audio.
- **Frame levels.** The take's 10 ms levels in dBFS, on the placed source timeline described below. Frame `i` covers mono samples `floor(i × rate / 100)` up to, not including, `floor((i + 1) × rate / 100)`, in integer arithmetic, and the take has `floor(samples × 100 / rate)` frames. A frame's level is `20 × log10(max(rms, 1e-9))`, with `rms` the root mean square of its samples in binary64.
- **Duration.** The take's source duration in seconds.
- **Preferred range** (optional). `preferRange` is a source `[startMs, endMs]`, the scope clip's range from `clipTimes` converted by `ms(t)`. Absent, the selection is unchanged.

Every time is first converted to whole milliseconds, `ms(t) = floor(t × 1000 + 0.5)` in binary64. Everything after that is integer arithmetic, except the SNR.

| Constant | Value |
|---|---|
| `TRAIN_MIN_CONF` | 0.8 (inclusive) |
| `TRAIN_MAX_GAP` | 2,000 ms (inclusive) |
| `TRAIN_SPAN_MIN`, `TRAIN_SPAN_MAX` | 5,000 ms and 30,000 ms (both inclusive) |
| `TRAIN_VOICED` | −45 dBFS (a voiced frame is above it) |
| `TRAIN_MIN_SNR` | 20 dB (inclusive) |
| `TRAIN_TOTAL_MIN`, `TRAIN_TOTAL_MAX` | 30,000 ms and 120,000 ms (both inclusive) |

1. **Usable words.** An item is usable when its `kind` is `word`, `conf` is null or at least `TRAIN_MIN_CONF`, `synthetic` is false, `ms(start) < ms(end) ≤ ms(duration)`, and it overlaps no excluded range (`xs < end` and `xe > start`, in milliseconds).
2. **Runs.** Walk the items in order. A run is a sequence of consecutive usable words, so any other item ends it: an event, unlabeled speech, or a low-confidence, synthetic or excluded word. A usable word joins the current run only when all of these hold; otherwise it starts a new run:
   - its `speaker` equals the run's (null equals only null);
   - it starts at most `TRAIN_MAX_GAP` after the run's end;
   - no excluded range has `xs <` its start and `xe >` the run's end.

   A run starts at its first word's start and ends at the largest end among its words.
3. **Split.** A piece longer than `TRAIN_SPAN_MAX` is split between two of its consecutive words. Each side runs from its first word's start to its largest word end. A boundary is valid when both sides last at least `TRAIN_SPAN_MIN`. Choose the valid boundary with the longest gap (the right side's start minus the left side's end). Break ties by the smallest `|leftEnd + rightStart − pieceStart − pieceEnd|`, the gap nearest the middle, then by the earlier boundary. Split the left side, then the right, again until no piece is longer than `TRAIN_SPAN_MAX`. A long piece with no valid boundary is rejected as `unsplittable`. A piece shorter than `TRAIN_SPAN_MIN` is rejected as `short`.
4. **SNR.** The take's floor is its 10th-percentile frame: sort all `n` levels ascending and take index `floor(n / 10)`. A piece covers frames `floor((startMs + 5) / 10)` up to, not including, `floor((endMs + 5) / 10)`, clamped to `0…n`. Sort its voiced frames ascending and take index `floor(m / 2)` of the `m` frames. `snrDb` is that level minus the floor, in binary64. With no voiced frame, or no frames at all, `snrDb` is null. A piece qualifies when `snrDb ≥ TRAIN_MIN_SNR`; otherwise it is rejected as `lowSnr`.
5. **Minimum.** `availableMs` is the total duration of the qualifying spans. Below `TRAIN_TOTAL_MIN` the status is `belowMinimum` and nothing is selected.
6. **Pick.** Partition the qualifying spans into *preferred* (`startMs < preferRange.end` and `endMs > preferRange.start`) and *other*. Rank each group by `snrDb` descending, then duration descending, then start ascending. Walk the preferred ranking, then the other ranking, and select each span that keeps the total at or below `TRAIN_TOTAL_MAX`. A span that does not fit is skipped, and a later, shorter one may still fit. `selectedMs` is the selected total. The result adds `preferredMs`: the sum, over the selected spans, of each span's overlap with `preferRange`, in milliseconds (0 when absent).

The result has `status` (`ok` or `belowMinimum`), `availableMs`, `selectedMs`, `preferredMs` and the selected spans in source order, each with `startMs`, `endMs` and `snrDb`. For tests and diagnostics it also lists the qualifying spans and the rejected pieces in source order, each rejected piece with its `reason` (`short`, `unsplittable` or `lowSnr`) and `snrDb`.

The vectors in `training-spans.json` must cover `preferRange`: no preference (the existing cases, unchanged); preferred spans alone filling the 120 s cap; preferred spans below the cap, filled from the other spans; a preferred span that partly overlaps the range; a preferred range with no qualifying span (`preferredMs` 0); and ties across the groups.

For the analysis, Media decodes the take once and streams it into the frame levels; it never holds the whole take in memory. The analysis runs on device when a Rewrite proposal needs a voice (§6.5.2), needs no network and is free. Media then cuts each selected span from the same mono mix, at samples `floor((startMs × rate + 500) / 1000)` up to, not including, `floor((endMs × rate + 500) / 1000)` in integer arithmetic. A cut therefore lasts 5 to 30 s in samples, and its WAV records `seconds` as its sample count over the rate.

The levels and the cuts use the same placed source timeline, the one transcript times use. Each decoded frame is placed by the §7.2 extraction rule, with its origin: the first at `round_half_up(position)`, a later one at `previousEnd` when it is within one tick of it. The mono stream starts at source sample 0. Silence fills the time before a late first frame and any timestamp gap, and overlap, including samples before source zero, is skipped. The media's duration bounds the stream: a frame placed at or after sample `ceil(duration × rate)` is dropped, so a corrupt timestamp cannot stretch the take, and the take's Duration is the smaller of the placed length and the media's duration, each floored to whole milliseconds. So mono sample `s` of the levels is mono sample `s` of every cut, and audio that starts late or has a gap stays aligned with its transcript. Unlike a voice-changer chunk, a cut does not refuse a gap: it holds the silence the levels measured.

#### 6.5.2 Making your voice inside Rewrite

**ADR-R34 update:** project audio now follows §6.1.1 without recording a statement. V1 proceeds through **Use Clip Audio**, local consistency checking, then the priced create action. References below to comparing or keeping a live statement apply to the legacy recorded route only. A project mismatch means selected spans are inconsistent with the chosen project-speech reference.

Voices are made only from Rewrite, when a proposal has phrases in your voice and no consented voice exists for the project's language. The steps and copy are `doc/design.md` §6.3.7 "Your voice, from this clip": add a key (if missing), agree (the notice, three attestations, the name and the plan check), read the statement aloud, the on-device check, then **Create My Voice**.

- The analysis starts with the proposal, using `preferRange` = the rewrite's clip (Full take: none; a selection: the clip containing it, if any).
- Below 30 s, unreadable media, or media labelled AI modified switches to the read-aloud with the copy in design.md.
- A speaker mismatch keeps the recorded statement and offers **Record a Read-Aloud**.
- In a project whose language has no calibrated speaker check, voice changes show "Your voice works in English projects only for now." and the voice steps are not offered.
- **Windows.** The flow and copy are the same. Until the Windows speaker check is enabled (§6.6), V1 shows the not-ready callout and offers only the free changes.

The guards of the old sheet carry over unchanged:

- **Amounts.** The speech row's `{t}` is `selectedMs` and `{c}` is `preferredMs` (§6.5.1). Without `preferRange`, the row shows no `{c}` and names no clip (design.md §6.3.7 V1). Below 30 s, `{n}` is `floor(availableMs / 1000)` whole seconds. The `{m}` that V4 and V5 send and the quote binds is the training audio that passed §6.6.
- **Unreadable media.** The source media is missing, cannot be decoded or has a rate outside 8–96 kHz.
- **Media labelled AI modified.** A re-imported export keeps no Voice Lab segments, so its generated speech cannot be excluded. When the source's XMP names a trained-algorithmic `DigitalSourceType` (`trainedAlgorithmicMedia` or `compositeWithTrainedAlgorithmicMedia`, §11.7), in the top-level XMP UUID box or in QuickTime's `moov/udta/XMP_`, project audio is not used. The label is read before any decoding.
- **Speaker mismatch.** §6.6 runs on every selected span right after the statement is recorded, before any request (§6.4 item 1). When fewer than 30 s pass, the steps block with the mismatch copy, and **Record a Read-Aloud** switches to (b). The recorded statement is kept, so it is not recorded again. Project audio is not offered again in that enrollment.
- **Which voices a project lists.** Rewrite lists only voices whose statement language is the project's transcript language, and the statement falls back to English while only English is calibrated (§6.2). A voice made from a project in an uncalibrated language could never be listed there, so the steps are not offered in it.

### 6.6 Speaker match (on device)

For attested project consent, the first accepted project training WAV supplies the owner-reference embedding. The same calibrated model, per-window comparisons, retained-duration minimum and use-time checks apply; references below to the statement mean that chosen reference for this route. Checkbox consent supplies the ownership attestation, not a fabricated speaker-identity verification.

```swift
public protocol SpeakerEmbedder: Sendable {
    var modelID: String { get }                 // catalogue id
    var dimension: Int { get }
    func embed(_ pcm16k: [Float]) async throws -> [Float]   // L2-normalised; input ≥ 3 s of speech
}
```

- **Implementation.** ONNX Runtime on both platforms: the official SwiftPM package on macOS, `Microsoft.ML.OnnxRuntime` on Windows, both with CPU execution. The model is downloaded like a transcription model, through a `voice-lab` catalogue entry (spike S6 picks it). Candidates: WeSpeaker ResNet34, 3D-Speaker CAM++, SpeechBrain ECAPA-TDNN. The model must have an OSI or CC-BY licence and weights that allow commercial use.
- **Embedding.** Use 16 kHz mono input. Embed 3 s windows with a 1.5 s hop over voiced frames only, and average them.
- **Score.** Cosine similarity of the L2-normalised embeddings.
- **Threshold τ.** It comes from calibration (spike S6), not a model-family starting point. Use the 99.9th percentile of clean calibration impostor scores plus `max(0.002, measured cross-runtime drift)`, rounded up to 0.01. Freeze it before speaker-disjoint validation. Every corpus × input-rate condition must have false-accept rate ≤ 0.5% and same-speaker pass ≥ 95%, with at least 200 impostor and 50 same-speaker pairs. τ is stored per model in the catalogue. **M3 does not ship without a calibrated τ.**
- **Clone creation.** §6.6 runs on every selected span right after the statement is recorded, and on a read-aloud right after it is recorded, before any request (§6.4 item 1). Every training sample must score ≥ τ against the consent recording. If any sample fails, or has too little voiced speech to embed, drop it. For a read-aloud, if the remaining total falls under 10 s, block with "Some of these recordings don't sound like the voice in your consent statement." For project spans (§6.5 a) the floor is 30 s, with the mismatch copy of `doc/design.md` §6.3.7 V3 and the switch to a read-aloud. Dropped spans are not replaced from the unselected ones.
- **Project span parts.** Without speaker labels (diarization off), a project span can hold another voice beside the user's, and the mean of its windows can still pass. So a project span is also scored in parts: its windows, in order, are grouped three at a time, about the six seconds of each S6 calibration clip, and a last group of one window joins the group before. Each group's mean, normalised, is compared with the statement like a whole sample. The span's score is the lowest of its parts and its whole mean, and it must be ≥ τ. A read-aloud is scored on its mean only. A shorter stretch of another voice inside one part can still pass; this narrows the gap, it does not close it.
- **Language.** Project spans may be in another language than the statement. They are scored with the statement language's τ; cross-language pairs were not part of the S6 calibration.

**S6 outcome (macOS W2, 2026-10-29).** Use the official WeSpeaker ResNet34-LM VoxCeleb ONNX export, 256 dimensions, at Hugging Face revision `f0c48c298fd835726c27956a5d617bad7115627e`. Its official model card declares CC BY 4.0, and the toolkit repo's licence is Apache-2.0. The exact 26,530,309-byte file and SHA-256 are pinned in `shared/catalog/voice-lab-models.json`, alongside the existing Silero VAD v6.2.0 asset. The Mac uses Microsoft's official ONNX Runtime SwiftPM 1.19.2 package (CPU only); weights remain an explicitly approved download, not a bundled model. Settings → Voice Lab and Local Models use the existing resumable-download, size, licence and verification patterns.

The preprocessing contract `sinc32-blackman94-silero-6.2.0-kaldi80-v2` first converts mono PCM16 WAV to 16 kHz using the shared, deterministic windowed-sinc algorithm in `VoiceConsentAudio`, not the earlier box average. Decode PCM16 to Float32 by dividing by 32768. Native 16 kHz is identity. Otherwise, in binary64 set `c = 0.94 × min(1, 16000 / inputRate)` and `R = ceil(32 / c)`. Output sample `i` is at input position `i × inputRate / 16000`; use taps `-R...R` about its floor with fractional offset `f`. For tap distance `d = tap - f`, use `c × sinc(c × d) × (0.42 + 0.5 × cos(πd/R) + 0.08 × cos(2πd/R))` inside `|d| ≤ R`, zero outside, where `sinc(x) = sin(πx)/(πx)` and its value for `|x| < 1e-12` is 1. Normalize each phase's complete tap sum to unity. Input outside the recording is zero; there is no delay or edge renormalization. Accumulate in binary64, cast each output to Float32, and emit `floor(inputFrames × 16000 / inputRate)` samples. Rational phases repeat every `16000 / gcd(inputRate, 16000)` output samples. Windows must match this contract and the 48 kHz / 44.1 kHz parity WAVs before enabling a threshold for this version.

Then use the existing whisper.cpp Silero VAD on CPU, with threshold 0.5, 250 ms minimum speech, 100 ms minimum silence and no padding/overlap. Concatenate voiced ranges, take the 3 s / 1.5 s windows, compute the official export's 80-bin Kaldi-compatible Hamming log-mel features with mean normalization, normalize each embedding, average and normalize again. The offline Python tool decodes corpus excerpts to realistic 48 kHz and 44.1 kHz PCM16 and calls the DEBUG Swift CLI hook for this exact production resampler, embedding helper, ONNX Runtime and cosine function. Python never substitutes its own scores. The independent NumPy feature vector remains a numerical unit test. `tools/voice-lab/README.md` specifies reproduction commands.

The earlier 16-kHz-only calibration and τ are superseded. The review calibration uses LibriSpeech dev-clean plus test-clean (CC BY 4.0): 80 disjoint speakers, three distinct six-second utterances each, rendered at both 48 kHz and 44.1 kHz. Dev-other plus test-other add 66 speaker-disjoint validation speakers with the same selection. In total there are 146 speakers, 438 distinct source utterances, 876 rate renders, 47,088 impostor pairs and 876 same-speaker pairs. A pair always uses two different utterances within one corpus/rate condition. Speakers, source clips, rate renders and pairs are counted separately; the correlated pairs and rate versions are not independent statistical trials or independent microphone recordings.

The lead-approved margin rule supersedes the earlier maximum-impostor rule, which unnecessarily forced clean FAR to zero. Pool the dev-clean and test-clean impostor scores at both 48 kHz and 44.1 kHz; sort them and linearly interpolate at index `(n − 1) × 0.999`. Add `max(0.002, measured cross-runtime drift)` and use decimal ceiling to the next 0.01 (an exact hundredth stays unchanged). Freeze that candidate before evaluating dev-other and test-other; do not lower it after seeing disjoint validation. All embeddings and cosine scores come from production Swift, so separate Python/runtime drift is not applicable (recorded as 0). The fixed 0.002 margin is ten times the retained 0.0002 parity tolerance, not a measured bound on another runtime or unseen inputs. Every corpus × rate must independently meet FAR ≤ 0.5% and same-speaker pass ≥ 95%.

The 2026-10-29 end-to-end production rerun gives clean P99.9 = 0.44653703263815736, hence `ceil-to-0.01(0.44653703263815736 + 0.002)` = **τ = 0.45**. All predeclared per-condition gates pass:

| Corpus | Input rate | False accepts / impostor pairs | FAR | Same-speaker passes / pairs | Same-speaker pass |
|---|---:|---:|---:|---:|---:|
| dev-clean | 48,000 Hz | 5 / 7,020 | 0.071225% | 120 / 120 | 100% |
| dev-clean | 44,100 Hz | 5 / 7,020 | 0.071225% | 120 / 120 | 100% |
| test-clean | 48,000 Hz | 8 / 7,020 | 0.113960% | 120 / 120 | 100% |
| test-clean | 44,100 Hz | 8 / 7,020 | 0.113960% | 120 / 120 | 100% |
| dev-other | 48,000 Hz | 0 / 4,752 | 0% | 99 / 99 | 100% |
| dev-other | 44,100 Hz | 0 / 4,752 | 0% | 99 / 99 | 100% |
| test-other | 48,000 Hz | 2 / 4,752 | 0.042088% | 98 / 99 | 98.989899% |
| test-other | 44,100 Hz | 2 / 4,752 | 0.042088% | 98 / 99 | 98.989899% |

Pooled results are 30/47,088 false accepts (0.063710%) and 874/876 same-speaker passes (99.771689%); pooling does not replace the per-condition gates. The catalogue publishes `threshold: 0.45` and `outcome: passed`, with date, rule, corpus and separate speaker/clip/render/pair counts. Only English may obtain a production speaker check, and only with installed, hash-verified model/VAD assets and matching calibration/preprocessing evidence. The check is bound to its calibration language at clone preparation, creation and use; passing an English check cannot authorize an Estonian consent record. Estonian remains unavailable. The curves, all pair scores, input/asset hashes and selection policy live in `shared/fixtures/voice-lab/speaker/`. Pairs share speakers and clips and rate renders share source utterances: these are correlated observations, not independent statistical trials, field-accuracy evidence or spoof resistance. **The user's own-voice check on this Mac's microphone is still owed before release.** Estonian has no calibrated check and stays unavailable in this release. Windows must establish parity for this preprocessing version before enabling it.

### 6.7 Create the voice

For recorded statements, creation is reached through the single approval of §6.4 item 1 after its statement check passes. For attested project audio, creation uses the separate explicit creation-only quote in §6.1.1. The request contains only accepted training WAVs (1–24 files, each 5–30 seconds, 30–120 seconds retained in total); there is no consent-statement file. Its description identifies checkbox consent and the project-reference hash, rather than calling it a consent recording. Name, language, exact file order/bytes, reference evidence, complete timestamped attestations and account are bound to the quote. The recorded-statement request below remains byte-compatible.

```
POST {base}/v1/voices/add
xi-api-key: <key>
Content-Type: multipart/form-data; boundary="voxclip-<32 lowercase hex>"
  name                     = "{display name} (VoxClip)"
  files                    = consent-statement.wav          (the consent statement recording; always the first file)
  files                    = sample-02.wav, sample-03.wav …  (the training samples in caller order; project spans in source order)
  remove_background_noise  = false, or true per §6.5 step 5
  description              = "VoxClip own-voice clone. Consent sha256:{statementSha256}. Created {created}."
  labels                   = {"language":"et","voxclip_record_id":"{recordId}"} (a JSON string; the private recovery hint is best-effort, never the only recovery evidence)
→ 200 { "voice_id": "c38kUX8pkfYO2kHyqfFy", "requires_verification": false }
```

Core sends WAV only until spike S5 settles the upload format. Core refuses the request before any provider call unless all of these hold:

- **Display name.** 1 to 60 Unicode scalars after trimming Unicode whitespace (the White_Space property) at both ends. The trimmed name is stored and sent.
  - It must contain no control character (General Category Cc: U+0000–U+001F, U+007F and U+0080–U+009F) anywhere.
  - Trimming runs first, so a line break or U+0085 at either end is removed, while one inside the name is refused.
  - Format characters (Cf) such as U+200B ZERO WIDTH SPACE are not White_Space and are allowed, so they stay.
  - The ElevenLabs API reference documents no length limit for `name`.
- **Language.** Two or three lowercase ASCII letters (`[a-z]{2,3}`), matched against the whole value. It is sent as the `labels` language.
- **Files.** 1 to 25 files, exactly one of them the consent statement. Each file is a complete mono PCM16 WAV at 8–96 kHz, as accepted by the conversion-input parser in §2.6. Each is at most 16 MiB and lasts 5 to 30 seconds; together they last 10 to 240 seconds.
- **Created.** The creation time, floored to whole seconds, falls between 1970-01-01T00:00:00Z and 9999-12-31T23:59:59Z. `{created}` is that time in UTC, written as `YYYY-MM-DDTHH:MM:SSZ`.

`{statementSha256}` is the lowercase hex SHA-256 of the consent statement file as sent. The quote binds:
- the trimmed name;
- the language;
- the creation time;
- the noise-removal choice;
- each file's position, role and SHA-256.

Any change to these needs a new quote and approval.

Both Cores frame multipart parts identically:
- Each part starts with `--`, the boundary and CRLF, then its header lines, each followed by CRLF.
- Names and filenames are quoted, and there is no `filename*`.
- A text part has only `Content-Disposition`. A file part has `Content-Disposition`, then `Content-Type: audio/wav`.
- An empty line follows the headers, then the part's bytes and CRLF.
- The body ends with `--`, the boundary, `--` and CRLF.

The boundary is `voxclip-` plus 32 lowercase hex, quoted in the request's Content-Type.

- `requires_verification == true`: do not use the voice. Show "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back." Store the record with `status: "verificationRequired"`.
- Errors map as in §4.3, with the permission `create_instant_voice_clone`.

On Mac, a completely observed, typed clone-endpoint `subscriptionRequired`, `featureUnavailable` or missing `create_instant_voice_clone` permission settles the dispatched operation as terminal `refused`. The private operation journal retains sanitized refusal proof and dispatch/account/audit evidence, and the original actionable error stays visible. The private enrollment inputs and reference audio remain available until their original 24-hour expiry for a fresh quote and explicit approval; a consumed quote is never reused. Network loss, cancellation, incomplete refusals, 5xx and malformed accepted responses remain ambiguous and keep the existing remote-reconciliation boundary. A failed refusal-journal write cannot establish settlement across restart and remains ambiguous. Neither outcome automatically repeats creation.


### 6.8 Consent record

Recovery reuses the exact saved clone request. A recorded-statement `/1` recovery uploads its saved statement and training audio, skipping only Scribe. An attested `/2` recovery uploads only saved training audio and retains its original checkbox evidence and reference hash; it never invents a recorded statement. Both require a fresh explicit priced action with the original account and preserve the dispatched-operation boundary against duplicate creation.

The Mac attested route writes `voxclip-consent/2`, with no `statement` field. Its `projectConsent` object has `{language, text, audioFile: "reference.wav", audioSha256}`. The fixed text must match the displayed checkbox exactly; the first training sample has the same audio hash, every sample is sourced from `project`, and all timestamped attestations are required. It retains the model/threshold/reference embedding, training hashes, creator account, status and app fields. A reference mismatch, substituted sample, changed consent text, mixed evidence type or incomplete attestation refuses creation/recovery/use. Its private audit records `consentMethod: "projectAttestation"` and `referenceAudioSha256`, with no false `statementSha256`. Cancellation and deletion remove the reference audio using the same durable cleanup boundary.

The synthetic shared record `shared/fixtures/voice-lab/consent-record-project.json` pins the attested format for both Cores and schema validation. `tools/fixtures/voice-lab/generate_creator.py` derives it from the unchanged recorded fixture, with one 30-second project sample and the fixed reference hash. It contains no real voice audio or provider asset.

Existing `voxclip-consent/1` files remain strict recorded-statement records. Their JSON fields, validation and historical evidence are preserved; they are not silently migrated into attestations. The example below is this recorded format.

Windows Core/Media also preserve project-attestation records with schema `voxclip-consent/2`. These records omit `statement` and contain `projectConsent: {language, text, audioFile: "reference.wav", audioSha256}`. The exact text is "I confirm this is my own voice and I consent to creating a voice clone." The first accepted training WAV is the reference, every sample is from `project`, each lasts 5–30 seconds and the retained sum is 30–120 seconds in whole milliseconds. A `/1` record must not contain project consent, and a `/2` record must not contain a recorded statement. No legacy record is silently migrated.

The project route binds the timestamped attestations, exact ordered WAVs, reference hash, name, language, nonce and creation settings to a creation-only quote. It neither prepares nor sends Scribe and never marks a statement verified. Recovery validates the saved WAV durations/hashes, evidence, creator and original deadline; it reuses a current creation quote or offers a fresh creation-only quote after expiry, without extending the 24-hour journal lifetime. Its minimal private audit records `consentMethod: "projectAttestation"` and `referenceAudioSha256`, omitting `statementSha256`. Withdrawal, deletion and abandoned-journal cleanup remove `reference.wav` through the existing private durable store. `/1` JSON and request fingerprint shape remain unchanged.

This is Windows metadata/service compatibility, not an enabled paid clone path. `VoiceSpeakerCheck.WindowsNativeParityVerified` remains false; shipping preparation and use refuse before provider access. Native x64/ARM64 ONNX/speaker parity, Windows inline consent UI and cross-platform fixture validation remain prerequisites. See [Windows project-consent compatibility](../windows-project-consent.md) for the service compatibility boundary.

Stored locally in `<data>/VoiceLab/consent/<recordId>/record.json`, never uploaded, and never inside a project file:

```json
{
  "schema": "voxclip-consent/1",
  "recordId": "6f0c2c1e-8a0e-4c5e-9d1f-0b9d4a7f2e11",
  "provider": "elevenlabs",
  "type": "ivc",
  "voiceId": "c38kUX8pkfYO2kHyqfFy",
  "voiceName": "Siim (VoxClip)",
  "status": "active",
  "createdAt": "2026-10-25T12:00:00Z",
  "deletedAt": null,
  "creator": { "region": "eu", "keyFingerprint": "0123456789abcdef" },
  "statement": { "language": "et", "text": "Minu nimi on …", "nonce": ["…", "…", "…", "…"],
                 "audioFile": "statement.wav", "audioSha256": "…", "stt": { "wer": 0.04, "transcriptionId": "…" } },
  "attestations": { "ownVoice": true, "adult": true, "ownVideosOnly": true, "acceptedAt": "2026-10-25T11:58:10Z" },
  "samples": [ { "sha256": "…", "seconds": 14.2, "source": "project", "speakerScore": 0.81 } ],
  "speaker": { "model": "<embedder id>", "threshold": 0.62, "embedding": "<base64 little-endian Float32 × dimension>" },
  "app": { "version": "0.3.0", "platform": "macos" }
}
```

After the on-device match, macOS `VoiceEnrollment.preparePlan` returns an `EnrollmentQuote(verify, create)` without provider calls. The inline Voice job shows the statement playback, send line and **Create My Voice · {quote price}**. That single click approves `execute(approved:)`, which runs the plan check, Scribe verification and creation in that order. A speaker mismatch sends no request. A statement mismatch clears the recording and returns to recording, creating nothing. The former sheet and its compatibility `verify`, `prepare` and `create` APIs have been deleted; tests exercise the combined job and its Core plan. A verified crash boundary offers **Resume Creation** to prepare a creation-only quote, followed by an explicit priced click. Recovery never automatically replays Scribe or creation.

Windows W4 mirrors the combined plan through `PreparePlanAsync` → one reviewed `EnrollmentQuote.Estimate` → `ExecuteAsync`; recovery uses `RecoverPlanAsync` followed by an explicit priced click. The existing `CreateVoiceSession` / `VoiceCreationFlow` legacy entry points remain compatibility paths until W8/WV10 replaces their UI. The native speaker parity gate remains closed, so the shipping app cannot reach a paid enrollment.

A passed Scribe verification is atomically journaled at `<data>/VoiceLab/consent/<recordId>/enrollment.json` before the creation intent. This private, temporary journal holds the combined quote, exact WAV file set, verified consent draft and training duration. It is separate from the minimal remote-operation journal below. Startup preserves this verified enrollment only before the original creation time plus 24 hours, and exposes it for **Create again**, never an automatic paid retry. At the 24-hour boundary it removes the temporary journal, statement and training audio. An undecodable, invalid-bound or stale journal is abandoned and reported by count, without preventing other valid journals or saved voices from loading. Recovery binds the original key fingerprint and region, statement hash, file roles and bytes, name, language, creation time and speaker model/threshold. It reuses the original unsent create quote only within its original five-minute lifetime; otherwise it prepares a new creation quote and requires a new click. A recovered `EnrollmentQuote.verify` is absent and its `estimate` counts creation alone, matching exactly what `execute` will send. It does not prepare another verification quote or resend the already verified statement to Scribe. An uncertain dispatched creation cannot use this path and follows remote reconciliation instead. A durably settled typed refusal may recover its retained inputs only through a new quote and explicit approval, retaining the previous operation audit. Cancellation clears the temporary journal before attempting withdrawal or statement removal; successful creation and ambiguous dispatched-operation reconciliation also remove it. A settled refusal preserves its private retry inputs until their original expiry, and reconciliation only cleans its local pending draft without provider calls.

- Sample audio is deleted after a successful upload. Only the hashes stay.
- `samples[].source` is `project` for spans of the open project's audio (§6.5 a) and `readAloud` for a read-aloud (§6.5 b). Each entry keeps the SHA-256 and `seconds` of the WAV as sent and its speaker score. The record stores no project path, span times or transcript text.
- The statement audio stays until the voice is deleted.
- The project file only references the record by `recordId` (§10.1).
- New records include `creator` with a settings region raw value (`default`, `us`, `eu`, `in`, `sg`) and the first 16 lowercase hex characters of SHA-256 over the API key's UTF-8 bytes. Never persist the key. Legacy records omit `creator` and match on their recorded region or operation journal's region only, with `default` when neither records one. Both operation kinds carry the same fingerprint as `creatorKeyFingerprint`.

Each create or delete operation has one private, atomically written journal at `<data>/VoiceLab/voice-ops/<operationId>.json`. It contains only the operation and record IDs, kind, state, provider recovery label/nonce, exact expected provider name, region, remote voice ID once known, timestamps, verification requirement, retry metadata and a minimal audit object. The audit contains the record ID, statement-audio SHA-256, training-recording SHA-256 values, creation and attestation timestamps, language and remote ID once known. It contains no audio, statement text or embedding. The audit is durable in the initial creation intent. A journal without audit data cannot authorize generation; cleanup still runs. A create's full consent draft uses the normal `record.json` above, not a second copy in the journal; it cannot authorize generation while the operation is unfinished.

Recovery lists owned voices of category `cloned`. It matches the recovery label OR the exact expected provider name with `created_at_unix` inside the journal's 24-hour creation window (rounded down to the provider's seconds precision at the start). The label is a best-effort hint, not the sole recovery evidence. Multiple candidates, or a same-name candidate without a creation timestamp and without the label, require user review in Settings; no voice is deleted. That obligation stays visible even if a later listing is empty. Retry can resolve it only with one unambiguous match.

A candidate carrying a different recovery nonce is not ours, even if its name and creation time match. It is never deleted by fallback matching. An ambiguous or unprovable candidate keeps the obligation visible for user review.

Completing or recovering a successful creation resets the enrollment session to a new record ID. Discarding a later enrollment cannot withdraw a saved active voice. Withdrawal without an unfinished creation refuses active and verification-required records. Startup cleanup removes only absent records or pending drafts; a non-pending record that fails validation is preserved and reported, never inferred to be abandoned.

The transcript keeps clip boundaries inside an atomic accepted replacement visible: interior start badges map to its leading edge and interior end brackets to its trailing edge, each in source order. Source clip ranges are unchanged. Disabling, undoing and redoing the replacement rebuilds those markers from the same source IDs.

Remote reconciliation starts in a background task after settings load, never in the import or quit critical path. It is cancelled on quit and follows persisted retry backoff, including withdrawal deletes. With the beta off and no consent records or obligations, it does not start provider or Keychain work. Existing cleanup obligations can finish in the background even while the beta is off; turning the beta off does not abandon a deletion.

Before Record or any paid enrollment step, the same own-voice predicate requires an available local speaker check, a finite calibrated threshold and a calibrated language (English in 0.1.0). Unavailable checks refuse with `speakerUnavailable` before Scribe receives audio. The model's verified files are rechecked at the recording and paid-action boundaries.

On macOS, production speaker-check construction has a private initializer and one factory. The factory takes the verified ONNX model handle and catalogue entry, checks the entry against the trusted shipped catalogue, revalidates model identity and files, and derives the language-bound threshold itself. No Release initializer exposes a numeric threshold or arbitrary embedder, including inside the Media module. Unavailable checks are a non-authorizing singleton; fake embedder injection exists only in DEBUG Testing SPI. Release boundary checks include same-module negative compilation against the production declaration.

Creation proceeds `intent` → `dispatched` → `created` → `saved`, then removes the journal. `dispatched` is flushed immediately before the POST, after key and speaker/consent checks. A restart from an undispatched intent with a C7 verified-enrollment journal removes the unsent operation intent and offers **Create again** without a provider call. Legacy intents without that journal remove the statement and unsent draft. An uncertain dispatch also removes the statement and unresolved draft at once, retaining only the recovery metadata needed to list owned voices by the original label; it never repeats the create POST. Listings use persisted exponential backoff from 30 seconds to one hour. The 24-hour deadline only bounds creation blocking: after it, an operation no longer blocks a new creation, regardless of listing outcome. Cleanup remains open after a failed listing, with a future retry and Settings copy “Checking your ElevenLabs account for an unfinished voice…” plus Retry. Only a successful empty listing after the deadline marks the operation `abandoned` and stops retrying. A late match is withdrawn, including after the blocking deadline.

Creation can instead move to `withdrawing` → `withdrawn`; the journal is removed only after the local statement and any known remote voice are gone. A known creation with valid consent can finish a failed local save without another create request. The Voice job also offers **Remove This Voice**, which durably requests withdrawal before removing the statement. Settings lists every unfinished operation with its plain state and Retry, including the unfinished-account check described above. Only live `dispatched` and `created` operations before the 24-hour deadline block a new creation; withdrawing and abandoned operations do not. One reconciler runs at launch, when Voice Lab opens and when a persisted retry becomes due. The store actor writes and claims a live creation intent in one call, before another task can observe it. The creator releases the claim on every outcome, including local cleanup failures; operation claims prevent concurrent reconciliation and dispatch of the same operation.

### 6.9 Use-time guard

Mac Make Takes pins the observed creator key and region through discovery, quote preparation, approval, synthesis and QA transcription dispatch. Changing the credential refuses the existing approval before sending. A legacy record with no historical creator remains usable only when its recorded region and owned-voice discovery match; the run pins the account actually observed without inventing historical creator evidence.

Before generating anything with the clone for a project, run the guard:

- **Patch mode:** embed up to 10 s of the project's speech nearest the patch.
- **Voice changer:** embed the first 30 s of speech in the range.

The cosine against the record's embedding must be ≥ τ. Otherwise block with "This doesn't sound like the voice owner. Voice Lab is only for your own videos." The default build has no override.

The result is cached per (project `contentKey`, `recordId`).

### 6.10 Deletion

[Delete voice] runs:

1. Verify the current key fingerprint and region against the creator binding, then `DELETE {base}/v1/voices/{voice_id}` → `{"status":"ok"}`. A 404 counts as deleted only after that match.
2. Delete the local statement audio.
3. Set `status: "deleted"` and `deletedAt`, keeping the record and its hashes as the audit trail.

The same operation journal records `intent` → `remoteDeleted` → `audioRemoved` → `tombstoned`, then is removed. The reconciler enumerates `voice-ops/` independently of consent records, so a missing `record.json` cannot strand deletion or its local audio. Each boundary is independently resumable; repeating a DELETE after an uncertain response is safe because a creator-matched 404 is success. Withdrawal of a creation uses its existing journal, not a second deletion journal. Existing rendered assets are never deleted by this recovery.

On a creator mismatch, refuse with: "This voice was created with a different ElevenLabs key or region. Use that key to delete it, or remove it from VoxClip only; the voice may stay in that ElevenLabs account." **Remove from VoxClip only** makes no remote request and writes a non-authorizing tombstone with `remoteStateUnknown: true`.

If an uncertain creation's unresolved draft was discarded and the remote voice appears later, deletion writes the journal's minimal audit to `<data>/VoiceLab/consent/<recordId>/audit.json`, adding the remote ID and deletion timestamp before removing the operation. It does not fabricate a full consent record or retain its statement text, name or embedding. This private, non-authorizing tombstone survives startup cleanup and keeps the original hashes and timestamps. Existing full consent records are still tombstoned as above. Journals from older versions whose draft and audit were already lost can finish remote cleanup but cannot reconstruct missing historical hashes.

Projects with segments that used the voice keep their rendered assets, which stay playable and labelled. They cannot generate new takes with the voice.

### 6.11 Which voices appear

Only voices with an active VoxClip consent record appear as "My voice". Other cloned or professional voices in the user's ElevenLabs account are never offered for re-voicing or voice changing.

A Professional Voice Clone path, where ElevenLabs runs its own voice-captcha verification, is a later upgrade and not part of the M3 beta.

---

## 7. Voice changer (speech-to-speech)

Mac conversion planning reads a bounded source-audio RMS envelope on the original source clock and omits the partial final 10 ms bucket. Regions without audio have zero planning energy, so an otherwise valid passage can be selected when the video's audio track starts later or ends earlier. This planning envelope never supplies provider audio: each upload still requires continuous decoded samples across its exact reviewed range and real overlap handles. Voice discovery does not require an unused subscription-read permission. Clone creation still checks its required paid plan.

### 7.1 Targets

- **My studio voice**: the user's own consented clone (§6.11). This turns a noisy or tired take into the clone. The §6.9 guard applies.
- **Stock voices**, for anonymity or characters: `GET {base}/v2/voices?category=premade&page_size=100`, plus `category=generated` voices with `is_owner == true` (voices the user designed).
- Voices with `category` of `cloned`, `professional` or `famous` are never offered unless they are the user's consented clone.

### 7.2 Scope and chunking

- The scope is a selection of words, or the whole take. The converted range runs from the selection's first word start minus 0.1 s to its last word end plus 0.1 s, clamped to the neighbouring gaps.
- The voice changer accepts at most 5 minutes of audio per request, and the uploaded file must be smaller than 50 MB, on every plan ([Voice changer guide](https://elevenlabs.io/docs/eleven-creative/playground/voice-changer)). Core's voice-changer upload cap is therefore 50,000,000 bytes, exclusive. It replaces the shared 16 MiB cap for this endpoint only; the other endpoints keep their own caps.
- A chunk holds at most `maxFrames = min(290 × sourceRate, floor((50,000,000 − 1 − 44) / 2))` source frames: 44 bytes of WAV header and 2 bytes per mono PCM16 frame. That is 290 s up to a source rate of 86.2 kHz, 283.4 s at 88.2 kHz and 260.4 s at 96 kHz. Split at the quietest 10 ms frame of the transcript pause (gap ≥ 0.4 s) nearest each `maxFrames − 10 s` mark (280 s at 48 kHz).
- One request at a time. All chunks use one random `seed` from 0 to 4294967295, stored with the segment.
- **Extraction from the take, both platforms.** Decode exactly the half-open source-grid range `[startSample, endSample)` at the native source rate, with an equal-weight mono downmix, no resampling, and mono PCM16 WAV output. `position` is the frame's timestamp in source seconds × rate, using the origin already used by preview and export: the AVFoundation asset timeline on macOS, and the container start time (DecodeSession's origin) on Windows. `tickSamples` is rate × that frame's own timestamp resolution: `rate / CMTime.timescale` on macOS, and `rate × streamTimeBase` on Windows, in binary64. The first decoded frame is placed at `round_half_up(position)`, never compared with the requested start. Only between decoded frames, `|position − previousEnd| < max(1, tickSamples)`, strictly, places a frame at `previousEnd`; otherwise use `round_half_up(position)`. Advance `previousEnd` by the full decoded sample count, including skipped overlap, so drift cannot accumulate past one tick. Refuse a gap inside the requested range with `rangeOutsideMedia`; skip overlap, including samples before the requested range or before source zero. Negative finite positions are allowed within the overflow guard; nonfinite or absurdly large positions are `unreadable`. A missing timestamp (an invalid presentation time on macOS) is `unreadable` before the first placed frame and sequential at `previousEnd` after it. Evaluate placement in binary64 in this order: `seconds = Double(value) × (Double(num) ÷ Double(den))`, `position = (seconds − origin) × Double(rate)`, and `tickSamples = Double(rate) × Double(num) ÷ Double(den)` left to right, followed by half-up `floor(position + 0.5)`; for CMTime, `num = 1`, `den = timescale` and `origin = 0.0`, while Windows uses DecodeSession's origin; half-sample ties are decided by that binary64 evaluation, not exact arithmetic. Sample-accurate containers (MP4, MOV and WAV at a sample-rate timescale) are exact. Coarse containers, such as the 1 ms of Matroska, WebM and FLV, anchor the first frame after a seek at its own timestamp, the same anchor DecodeSession and the rest of the Windows media pipeline use for preview, export and render; post-seek positions lie within one tick of sequential decoding. Gaps shorter than one container tick are undetectable. Shared production-placement vectors are in `shared/fixtures/voice-lab/continuity-cases.json`.

### 7.3 Request

```
POST {base}/v1/voice-changer/{voice_id}?output_format=pcm_24000
xi-api-key: <key>
Content-Type: multipart/form-data
  audio                    = <chunk as 16-bit WAV at the source rate, mono>; filename="audio.wav"
  model_id                 = eleven_multilingual_sts_v2     (or the GET /v1/models entry with can_do_voice_conversion that lists the language)
  voice_settings           = {"stability":0.5,"similarity_boost":0.75}
  seed                     = <seed>
  remove_background_noise  = true, or false when Clean audio is on
→ 200 raw 16-bit little-endian mono PCM at 24 kHz (output_format=pcm_24000); WAV, MP3 and other encoded or container replies are refused
```

The parts are framed as in §6.7.

- **Duration check per chunk.** As in §4.4, but with a cross-correlation search of ±300 ms. The docs do not promise that timing is preserved.
- **Language.** The voice changer lists 29 languages, and Estonian is not among them. For a language not in the model's `languages`, require a 10 s preview first: "ElevenLabs doesn't list {language} for the voice changer. Listen to a 10-second preview before converting."
- **Preview.** "Preview 10 s" converts the first 10 s of speech in the scope. The cost is shown on the button.
- **Result.** Transcript words keep their source times, and captions are unchanged. The segment is stored as `kind: "voiceChanger"` (§10.1).
- **Label.** AI MODIFIED for the whole converted range, and for the whole clip when §11.1 makes it persistent (a converted range covering at least 50% of the exported clip).

---

## 8. Re-voice a phrase (patch mode)

### 8.1 Entry points

All of these end in the Rewrite review (`doc/design.md` §6.3): tracked changes in the transcript and a checklist in the panel.

1. **Rewrite a scope.** The scope is the selected kept or suggested clip, or Full take. The scope bar's field supplies the instruction, or "Fix slips and repeats. Keep my words and my voice; change as little as possible." when it is empty. This is "Fix with AI" over the scope through `PatchRewriteService`:
   - `entries` are the scope's kept items, in source order. Each uses the ai.md §11.2 item format, with corrections applied, but unlike §11.2, which includes every item, cut items are left out.
   - Items an enabled replacement of the scope already re-voices (§8.4 replaced items) are left out too. Their cuts and corrections are dormant (§10.2) and no window may overlap them, so no edit to them could apply, and the model never edits words the video no longer has. Turning the replacement off brings its source words back into the next plan. Each line flags the items such a run precedes, back to the entry before (`revoicedBefore`), because no window may span the run (§8.4 step 6).
   - `ranges` come from `VoiceLabLengthBudget`, with each `formatTranscript` line as one replace hunk.
   - `ScopeRewritePlan` (`Domain/VoiceLab/`) builds the entries, lines and ranges for the scope (Swift `make`). It first reads the take, the source envelope when there is one, and the scope's render scope as `place` reads them. One it cannot read is invalid input for the whole plan, and so is a scope `VoiceLabOutputPlanner` does not render (§10.2), such as a clip boundary through a replacement.
   - A line's window runs from its first to its last word item in the scope's render scope (§8.4, with a clip's `clipTimes` head and tail), at the §8.9.1 rate: the stored candidates the caller passes for the voice, model and language key, or else the take's transcript with corrections applied. When `place` refuses that window, or the source envelope is missing, the line takes `fullTake` of its own items instead (advisory, first word start to last word end). A refusal that says the scope does not render as it stands (`invalidInput` naming a replacement, §8.4 step 6) is invalid input for the whole plan instead.
   - The model returns a line's whole text, echoing its event labels, and Core counts every letter of it (Validation below). So both bounds add the `VoiceLabTextLength` of the line's non-word entries, and keeping a label never pushes an edit out of range. A line with no word item gets that length, at least 1, on both bounds. Both bounds are capped at 5,000.
   - The request limits are unchanged (1 to 3,000 entries; 20,000 bytes). Above 3,000 entries the panel says "Rewrite works on up to 3,000 words at a time." with the entry count; within that but above 20,000 bytes it gives the too-much-text copy of `doc/design.md` §6.3.6 R1x, which names no count.
   - Each returned line edit becomes new text for that line. `ScopeRewriteDiff` (`Domain/VoiceLab/`) turns the edits into review hunks in transcript order (Swift `hunks(plan:proposal:)`). A line without an edit is unchanged. An edit for a line the plan does not have, or a second edit for one line, is invalid input.
     - **Echoed labels.** The model reads a line's events as their labels and unlabeled speech as `…`, and may return them. Core pairs the edit's tokens with the line as the model read it: the §8.2 steps 1–3 diff over the line's entry texts, every entry tokenised as a word. A non-word entry is echoed when each of its tokens pairs with an `equal` and no inserted token falls between them. Echoed tokens are dropped and never spoken. Each echoed entry splits the line into stretches: the items and new tokens between two echoed entries, or between one and the line's edge. A label the model left out or changed is not echoed. Its entry stays in its stretch, where a voice hunk across it absorbs it (§8.2 step 6), and a changed label's tokens are new words.
     - **Re-voiced runs.** A run of items an enabled replacement already re-voices is not in the plan, but no window may span it, so it splits its line into stretches too. The model never saw the run, so each new token joins the stretch of the source token the pairing walked last, or the first stretch before any. A change the model made on both sides of the run therefore becomes two changes beside it, never one hunk across it.
     - **Per line.** `VoiceLabWordDiff` runs on each stretch alone, against its items as the transcript holds them, corrections applied, so every DP stays within one line. An empty edit cuts the line's words; its events and unlabeled speech stay (§8.2 step 5).
     - **Across lines.** §8.2 step 6 then runs across stretches in transcript order: each stretch's first voice hunk may merge with the last voice hunk before it, by the same rule. The counts, times and barriers read the plan's items. An echoed entry is a barrier, and so is a re-voiced run between the two hunks, which would put the merged window over a replacement (§8.4 step 6). A cut item is not among the plan's items and never stops a merge, as within one line. An insertion's time is its stretch's anchor, and its barrier position is the item of the next word token in its stretch, or of the stretch's last word for an insertion at the stretch's end. An insertion into a stretch with no word item anchors at the start of the stretch's first item, else at the start of the echoed entry after it, else at the end of the one before it, and is never merged. A hunk's source token indices address the word tokens of all the plan's lines in order. They order the hunks, but they cannot say on which side of an event or an echoed label an insertion lies.
     - **Carried per hunk.** Each hunk carries the line labels and reasons of the edits it comes from, several after a merge across lines. It carries `checkThis` when one of its own new tokens is a token the rule below flags in its edit, with the edit's whole text giving each token's sentence start; a merged hunk carries it when one part does. A cut never carries it. An insertion has no source item, so it carries the ID of the plan item it follows instead (none before the plan's first item): it lies between that item and the plan's next one, at its anchor. Two insertions merged with nothing between keep the earlier one's anchor and item.
     - **Budget and header.** The §8.2 patch budget and header read these hunks after every merge, against the whole transcript, as they read a passage's (Swift `VoiceLabPatchBudget.evaluate(hunks:transcript:)` and `VoiceLabDiffSummary.make(hunks:meters:…)`).
     - The prompt file, schema, validation and `checkThis` below are unchanged.
2. **Rewrite a selection.** A word selection uses `VoiceRewriteService` (passage) with the field's instruction, as before.
3. **Type New Words…** on a selection. The user types the new words in the edit popover; an empty field means "delete" and becomes a cut. No AI is involved.
4. **Insert Words…** at a caret between two words. This is an insertion.

Several voice hunks may be included in one review. `VoiceLabWindowPlanner.placeAll` (§8.4) places them together. Takes for all of them run under one approval (§8.6), and **Use Takes** accepts them as one undo step (§8.12). Consent, the shared run lease and the request rules follow `ai.md` §4.7–§4.8.

**Fix with AI over a scope (item 1).** The user's LLM (`doc/spec/ai.md` connectors) proposes line edits for the instruction, for example "I said 2024; it's 2025".

Fix with AI has its own prompt file, `shared/prompts/patch-rewrite.json` (`promptVersion` 1), and its own schema name, `patch_edits`. It never reuses `tighten_edits` (`ai.md` §12.8). Its schema:

```json
{ "type": "object", "additionalProperties": false, "required": ["edits"],
  "properties": { "edits": { "type": "array", "items": {
    "type": "object", "additionalProperties": false, "required": ["line", "text", "reason"],
    "properties": { "line": { "type": "string" }, "text": { "type": "string" }, "reason": { "type": "string" } } } } } }
```

The transcript block uses the clip finder's line format (`ai.md` §11.3). The system prompt tells the model:
- every added word is spoken by an AI copy of the speaker's voice and labelled, so it must change as little as possible;
- deleting is preferred;
- keep the speaker's register;
- never add facts, numbers, names or claims that are not in the transcript or the instruction;
- keep each edited line inside its character range; deleting a whole line is allowed, with empty text;
- return an empty list when nothing should change.

Each line's character range comes from the length budget (§8.9.1), with the line's words treated as one replace hunk: the same `LENGTH_AIM_MIN` to `LENGTH_AIM_MAX` aim and the same `minChars` and `maxChars` formulas, plus the length of the event labels the line holds (item 1). The caller computes the ranges and Core takes them as given. The request states the range for every line.

**Request.** Each Core's `PatchRewriteService` (`Services/VoiceLab/`) has the shape of `VoiceRewriteService`: prepare a quote, approve it, then propose. A `PatchRewriteRequest` holds:
- `entries`: the in-scope transcript items `{index, text, start, end}` (`ai.md` §11.2). There are 1 to 3,000 of them, with indices of 0 or more in strictly increasing order, finite times with 0 ≤ `start` ≤ `end`, and text that is not empty after `jsTrim` (`editing.md` §4.5). Their text joined with spaces is at most 20,000 UTF-8 bytes.
- `ranges`: one `{line, minChars, maxChars}` for each line `formatTranscript` makes of the entries, in line order. `line` is that line's `[a-b]`, and 1 ≤ `minChars` ≤ `maxChars` ≤ 5,000.
- `instruction`: not empty after `jsTrim`, and at most 1,000 UTF-8 bytes.
- `language`: a tag of the form `[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*`.

Any other value fails with the service's invalid-input error (`VoiceLabError.invalidInput`, `VoiceLabErrorKind.InvalidInput`) before a quote or a send. The quote binds the entries with their times, the ranges, the instruction, the language, the connector, the model and the prompt file, so any change needs a new quote and approval. Both Cores bind the prompt file as the SHA-256 of its bytes after CRLF→LF: any edit to the file refuses an earlier quote, but a checkout's line endings do not. A declined approval or a used quote sends nothing.

The quote's estimate is `est()` (`ai.md` §11.5) of the whole rendered request, `system + cachedBlock + instruction`, in the unit `token`, with basis `unknown` and no price or credits. Both Cores check the request before they estimate it.

**Rendering.** All request text comes from the prompt file.
- `cachedBlock` is `transcriptBlock.prefix + rendered + transcriptBlock.suffix`, where `rendered` is `formatTranscript` of the entries (`ai.md` §11.3).
- `instruction` is `request.rangesLine`, then one `request.rangeLine` per line in line order, each on its own line, with `{line}` and with `{minChars}` and `{maxChars}` as decimal integers. A blank line follows, then `request.instructionLine` with `{instruction}`, the instruction after `jsTrim`.

For three lines it reads:

```text
Letters and digits allowed in the new text of each line, not counting spaces and punctuation:
[40-48] 27 to 31
[49-53] 17 to 21
[54-57] 12 to 15

Instruction: I said 2024; it's 2025.
```

The send is a `voiceRewrite` request (`ai.md` §2.1) with medium effort, the schema `patch_edits` and the tag `patch-rewrite`, so, as for the passage rewrite, the connector makes one attempt, never resends it and names no fallback model (`ai.md` §12.8). Both suites send the 5 cases of `shared/fixtures/llm/patch-rewrite-requests.json` through `PatchRewriteService`, compare `system`, `cachedBlock` and `instruction` byte for byte, compare the quote's estimate with `expected.estimate`, and check the preflight of `ai.md` §12.8 with `expected.preflight`.

**Answer.** The answering model must be the quoted one, by the rule of `ai.md` §12.8, where a Claude Code alias accepts the model it names. A reply from any other model fails with the invalid-output error (`LLMError.invalidOutput`, `LlmErrorKind.InvalidOutput`). Then a truncated reply fails with the truncated error, and a refusal with the refused error (`LLMError.refused`, `LlmErrorKind.Refused`), which keeps the passage rewrite's copy: "The model declined to rewrite this recording."

**Strict JSON.** Both Cores read the reply by the strict JSON rule of `ai.md` §4.5, so a reply that one rejects the other rejects too, as a typed invalid-output error and never a crash.

**Validation.** The reply then passes the structural validation of `ai.md` §2.3.
- A reply with no JSON object, or with no `edits` array, fails with the invalid-output error.
- An item is malformed when it lacks a string `line`, `text` or `reason`, when its `text` or `reason` holds a control character (Cc) other than tab, or when its `text` is over 2,000 UTF-8 bytes. A malformed item is dropped and counted in `malformedItems`; it never fails the reply.
- Keys outside the schema are ignored.

Each remaining item is then checked in order:
- `line`, after `jsTrim`, must match an emitted `[a-b]`, compared as scalar sequences. Otherwise the item is dropped and counted in `unknownLines`.
- Duplicates are dropped. Only the first item for a line is kept, and each later one is counted in `duplicateLines`.
- Core counts each edit's letters and digits itself: `length` is the `VoiceLabTextLength` of `text`, and `inRange` says whether it lies in the line's range. An edit outside its line's range is kept and shown as it is, with the fit meter (§8.9.1).
- A `text` that is empty after `jsTrim` deletes the whole line. Such an edit has `isDeletion` true, `length` 0 and `inRange` true. A text of punctuation alone deletes nothing; its length is 0, so it is out of range.
- `checkThis` marks an edit that adds something found nowhere in the transcript or the instruction (the rules below). Such an edit gets a warning badge with the copy in `messages.checkThis`: "Check this: it adds something you didn't say."
- An empty `edits` list is a valid result: nothing needs to change.

The whole reply keeps the 20,000-byte rule: the kept edits' `text` values may hold at most 20,000 UTF-8 bytes together. A reply with more fails with the invalid-output error.

The `checkThis` rules:
- Texts are compared after NFC. The sources are the entry texts and the instruction.
- A *digit run* is a maximal run of Nd scalars. An edit adds one when its text holds a run that no source holds: `2025` is new next to `2024`, and so is `٢٠٢٥` next to `2025`.
- Tokens come from `splitWords` (`editing.md` §4.5). A token's *key* is its text without the scalars that are not letters (L*) or numbers (N*). This is `normalizeForMatch` (`editing.md` §4.7) without its lowercase step, so case counts. A token *appears* when some source token has the same key. Keys and digit runs compare as scalar sequences, never by canonical equivalence: a key that keeps two conjoining jamo differs from the precomposed Hangul syllable they spell.
- A token is a *URL* when it contains `://`, or when it starts with `www.` in any ASCII case once its leading scalars that are not letters or numbers are skipped.
- A token is *capitalised* when its first letter is Lu or Lt. It is *at a sentence start* when it is the edit's first token, or when the token before it ends a sentence by the `ai.md` §11.3 rule (`.`, `!`, `?`, `。`, `！` or `？`, followed only by `"`, `'`, `”`, `’` or `)`).
- `checkThis` is set when the edit adds a digit run, or holds a URL or a capitalised token not at a sentence start that does not appear.

These rules are a heuristic. They can badge an edit that adds no fact, for example a word capitalised after a colon that the transcript has in lower case, and they miss a new fact written in lower case. The badge only asks the user to look; it blocks nothing.

`PatchRewriteProposal` lists the edits in arrival order. Each edit carries `line`, `text` exactly as returned, `reason`, `length`, `inRange`, `checkThis` and `isDeletion`. The proposal also carries `unknownLines`, `duplicateLines`, `malformedItems`, the badge copy, and `model`, the model that answered. It is review data only: it changes no project and starts no generation.

There is no automatic retry (S15). Asking again, including Shorter or Longer, is a new send with its own quote and approval. Both suites replay the 72 cases of `shared/fixtures/voice-lab/patch-rewrite-cases.json`, written by `tools/fixtures/voice-lab/generate_patch_rewrite.py` from canned replies. 35 of them also go through `VoiceRewriteService`, so both services read the same replies alike.

Every path ends in the word diff (§8.2).

### 8.2 Word diff (LCS)

For each edited line, or each selected range plus its new text:

1. **Tokenise** both sides on whitespace (`editing.md` §4.5). Only source items of kind `word` are tokenised; retain events and unlabeled speech in source order for merge barriers and explicit absorption. Each source token retains its item ID and timing, even when one item holds several tokens. Display keeps the surface forms. Refuse more than 2,000 tokens on either side with a typed `tokenLimit` error naming the side, count and limit, before allocating the DP.
2. **Normalise** for comparison with `normalizeForMatch` (`editing.md` §4.7).
3. **LCS.** Run a longest common subsequence over the normalised arrays with the O(n·m) suffix DP. Walk forward from `(0, 0)`: a match emits `equal` and advances both sides; otherwise delete when the new side is exhausted or `L[i+1,j] >= L[i,j+1]`, and insert otherwise. Thus equal-length alternatives choose deletion. Stably partition every maximal non-`equal` run into its deletes followed by its inserts, retaining source order and new-text order within each group. "Ties prefer `delete` before `insert`" is also an output-order property: **every delete precedes every insert within a replace region**, including regions where the DP first encountered an insertion. Emit `equal`, `delete` and `insert` operations with both surface tokens on an equal, only the source token on a delete and only the new token on an insert. Comparison runs through NFC before `normalizeForMatch`; surface differences are ordinal, including a decomposed spelling of the same NFC text.
4. **Whole-item hunks.** Form regions from adjacent `delete`/`insert` runs and surface-only changes. Before classification, widen each region to whole source items: any deleted/replaced token, surface correction, or insertion between an item's tokens includes the entire item. Include its kept new-side surface tokens in their original positions on both sides of the edit. Merge widened regions that share an item or touch. Insertions between items remain insert-only hunks with their anchor. Raw LCS operations stay token-level.
5. **Classify** each hunk:
   - **cut**: every source token is deleted and nothing is inserted. Its whole word items join `edits.cutWordIds`. No AI.
   - **textOnly**: the whole region's normalised token arrays are equal but the surface differs (case or punctuation). Its `correctedTexts` supplies one full corrected text per source word item in source-ID order, joining that item's new surface tokens positionally with single spaces. It becomes `edits.corrections`. No AI.
   - **voice**: anything else. It needs TTS; a partial deletion such as a timed item `hello world` becoming `hello` re-voices the whole item with its kept words.
6. **Merge voice hunks** separated only by `equal` operations when there are at most 2 equal source `word` items (not tokens), **or** at most 0.35 s of source time between the hunks. The time is the later hunk's first source word start minus the earlier hunk's last source word end, not the duration of the intervening equal words. An insert-only hunk uses its anchor: the next source token's start, or the final source token's end for an end insertion, or 0 for an empty source. Use binary64 subtraction and an inclusive `<= 0.35` comparison, without an epsilon. Merge transitively in source order. A cut between voice hunks prevents merging. The intervening equal words become bridge words and are re-voiced: their new-side surface tokens join the patch text in order, and their IDs join both the hunk's covered source IDs and its distinct bridge IDs. A text-only correction among these equal words is absorbed, with its new surface retained, not returned as a second overlapping hunk. Never merge across an `event` or `unlabeledSpeech` item between the hunks, regardless of word count or time; insert-only hunks use their anchor position in source order. A single user-edit voice hunk whose own source words straddle non-word items keeps its shape and reports their IDs, strictly between its first and last source word, in `absorbedItemIds`. Accepting it replaces those items with the new voice (§8.4 step 4); the App shows each absorbed item as removed in the read-only diff line. Cuts and textOnly corrections affect only their word IDs and never non-word items.
7. **Display.** The review shows each hunk as a tracked change in the transcript (`doc/design.md` §6.3.5): its removed words, its new words, its re-voiced bridge words, and the events or unlabeled speech it absorbs (`absorbedItemIds`), each marked as such. It also shows one checklist row per hunk. A cut-only or text-only review applies with **Apply {c} Changes**: one undo step, no AI. Voice hunks need an active voice; without one, the panel offers **Make Your Voice**.
8. **Header.** A live summary. The clip-first panel words it by `doc/design.md` §6.3.6 R2 (the sub-line and the meta line). `VoiceLabDiffSummary` returns the distinct cut word count, merged voice-hunk count, sum of the per-hunk duration estimates and TTS cost estimate, plus the passage panel's copy, "3 cuts · 2 re-voiced phrases (4.1 s of AI voice) · ≈ $0.02" (singular `cut` and `re-voiced phrase` for 1), which goes when design.md §6.3 replaces that panel. The estimate is summed once per hunk, not once per candidate. Inject `VoiceLabPricing`'s catalog, selected model, candidate count and optional credit multiplier; price the total Unicode scalars of each complete patch text, including spaces, punctuation and bridges, with no separator charged between separate hunks. This is billing length, not `VoiceLabTextLength`. The cost uses the existing pricing and presentation rules (§3.2); omit the amount when the catalog is absent or its price is unknown, and return nil cost when there are no voice hunks. Nothing is sent. Each voice hunk also shows the fit meter (§8.9.1). Supply an optional complete patch text for each voice hunk in order: left window bridge + new words + right window bridge (§8.4 step 4). Price only when every hunk has complete text. Any missing text (including no placed window or a refused window) returns nil cost and omits the amount suffix; never fall back to hunk tokens. A supplied text count different from the voice-hunk count is typed `invalidInput`.

**Patch budget.** Re-voicing is for small fixes. Count the new-side tokens of **every voice hunk after merging, including the bridge words**, because all of them will be spoken by the AI voice. Let `wordItems` be the number of items of kind `word` in the whole transcript, not the selection; events and unlabeled speech never enlarge that denominator. Disable voice hunks exactly when `count × 100 > 15 × wordItems` or `count > 60`, using integer arithmetic. Both boundaries are inclusive for acceptance: exactly 15% and exactly 60 tokens pass. `VoiceLabPatchBudget` returns the typed flag `allowed` or `reRecordInstead`, counts and optional copy. The clip-first panel shows the over-budget callout of `doc/design.md` §6.3.6 R2 from these counts. The optional copy is the passage panel's "That's a lot to re-voice. Re-record these sentences instead.", which goes when design.md §6.3 replaces that panel. Cuts and text-only corrections remain available.

`VoiceLabWordDiff` in both Cores (`Domain/VoiceLab/`) returns ordered `ops` and `hunks`. A hunk holds `kind` (`cut`, `textOnly`, `voice`), distinct source IDs in source order, new surface tokens, bridge IDs, a half-open source-token index range and, for insert-only hunks, its anchor seconds. The indices address the word-only token array, not transcript item indices. Shared `word-diff-cases.json`, written by `tools/fixtures/voice-lab/generate_word_diff.py`, pins equal-length alternatives, surface-only edits, insert anchors, merge and patch-budget boundaries and the DP limit; both Core suites replay every case.

### 8.3 Constants

```text
SEAM_MIN_GAP          = 0.12 s    a seam may sit in an inter-word gap at least this long
SEAM_SEARCH_WORDS     = 3         widen the window by up to 3 words on each side to find such a gap
SEAM_FADE             = 20 ms     equal-power crossfade at a seam in a gap
HARD_SEAM_FADE        = 12 ms     at a seam on a word boundary with no gap
TTS_TRIM_LEAD         = 0.03 s    keep before the first aligned character
TTS_TRIM_TAIL         = 0.06 s    keep after the last aligned character
STRETCH_OK            = [0.92, 1.08]   validation bound for a stored fit factor only; rendering refuses any value but 1 (§10.5)
PAUSE_SLACK_KEEP      = 0.15 s    silence kept next to a word when a seam borrows pause time
SEAM_PAD_MAX          = 0.3 s     room tone (or silence) padded at a gap seam or take edge, per side
HARD_SEAM_PAD_MAX     = 60 ms     room tone (or silence) padded at a hard seam, per seam
PAUSE_FLOOR_PHRASE    = 60 ms     shortest an intra-phrase pause inside a take may become
PAUSE_FLOOR_PUNCT     = 150 ms    shortest a pause at punctuation inside a take may become
PAUSE_GROWTH_MAX      = 0.25 s    most any one pause inside a take may grow
LENGTH_AIM_MIN        = 0.92      new wording aims at 92% to 97% of its window (§8.9.1)
LENGTH_AIM_MAX        = 0.97
RETIME_VIDEO_OK       = [0.80, 1.25]   video retime range for zoomCover
LOUDNESS_NEIGHBOURHOOD= 3.0 s     on each side of the window
VOICED_FRAME          = −45 dBFS  10 ms RMS
GAIN_CLAMP            = ±12 dB, then a true-peak limit of −1 dBTP
ROOM_TONE_MIN_RUN     = 0.5 s     searched inside gaps of at least 0.5 s
ROOM_TONE_XFADE       = 50 ms
CANDIDATES            = 3         most sequential takes per generation run (§8.6)
PREV_TEXT_MAX         = 100 characters (Text to Dialogue, API limit), 300 Unicode scalars (Text to Speech, VoxClip limit; §8.5 trimming)
```

The six silence-fit constants (`PAUSE_SLACK_KEEP`, `SEAM_PAD_MAX`, `HARD_SEAM_PAD_MAX`, `PAUSE_FLOOR_PHRASE`, `PAUSE_FLOOR_PUNCT` and `PAUSE_GROWTH_MAX`) are tuned by ear after the listening check (§8.9.4). `PAUSE_SLACK_KEEP` and `SEAM_PAD_MAX` keep the values of the earlier seam step, and the three pause constants are proposals from the duration-fit research. `HARD_SEAM_PAD_MAX` starts at the intra-phrase pause floor, because a hard seam sits in connected speech, where a longer inserted silence is heard as an artifact.

### 8.4 Window and join placement

For each accepted voice hunk replacing source words `[a..b]`, or inserting between `k` and `k+1`, the window is placed for the render scope (the full take or one clip) exactly as `VoiceLabOutputPlanner` builds that scope (§10.2), beside the replacements already in the project:

- The **replacements** are the scope's enabled segments, selected as the output planner selects them: enabled and, in a clip scope, overlapping the clip's range (`clipTimes`). An enabled segment outside the take, or a replacement that crosses that range, has no synth samples, has no selected recipe or overlaps another, leaves the scope unrenderable, and the hunk is refused with `invalidInput`. Each replacement's fades come from its selected recipe's seams. An item wholly inside a replacement is a **replaced item**: it is already re-voiced.
- **Kept source** is the complement of the scope's edit-plan cuts (`buildSegments` and `buildEditPlan`, `editing.md` §7.2–§7.3, with a clip's head and tail ranges) and of every synth range. It is computed after the words and pauses inside every replacement and inside the window are dropped, as the output planner drops them, so nested and overlapping items, cut pauses, clip edges and other replacements all count.
- A **kept item** is a transcript item (word, event or unlabeled speech) that the scope does not cut: it is not in `cutWordIds`, and in a clip scope it lies inside the clip.
- The **gap** before an item runs from the latest end of the items before it to the earliest start of that item and the items after it.
- The transcript must follow the project rule (finite times, `0 ≤ start < end`, starts in transcript order, unique IDs). Otherwise the hunk is refused with `invalidInput`.

1. **Left seam.** Look left from `a`, over up to `SEAM_SEARCH_WORDS` words, for a gap of at least `SEAM_MIN_GAP`. Only kept words bridge: the search stops at a cut word, a word outside the clip, a replaced item, an event or unlabeled speech.
   - If one is found, place the seam at the **centre of the quietest 10 ms frame inside that gap**, sample `i·F + ceil(F/2)` of frame `i`. Choose only among frames whose centred fade lies wholly in kept source (step 5) and clear of each replacement's own outer fade halves: `floor(N/2)` samples before its start and `ceil(N/2)` after its end. Ties go to the frame nearest the gap centre, then the earlier one. A gap with no such frame is skipped, and the search goes on. The words between the gap and `a` become left bridge words.
   - A cut's reach depends on which items the window drops. The left search therefore measures kept source against the widest window the right side could reach: its farthest bridge, or the take end when the right side could extend to it. The right search mirrors this, and step 5 checks the final window.
   - Otherwise, place the seam at `a.start − min(0.03, max(0, gapBefore) / 2)` and use `HARD_SEAM_FADE`. Overlapping items leave no gap, so the reach is clamped at zero, as `editing.md` §7.3 clamps a cut's reach.
   - A replacement R that ends no later than the end of `gapBefore` moves the gap's start to the later of its own start and `(jsRound(R.end × rate) + ceil(N_R/2) + floor(N_hard/2)) / rate`, where `N_R` is R's outgoing fade and `N_hard` is `HARD_SEAM_FADE` in samples. The hard seam then leaves the outer halves of both fades in the kept source between R and `a` whenever the silence holds them. When it does not, step 6 refuses the hunk.
   - **Take start.** Take edges count kept and replaced items only. When no kept or replaced item lies before the window's first word, the window instead extends to the take start (sample 0), and the seam has kind `none` (§10.5). There is no fade. This covers a passage with no item before it and one where every earlier item is cut. Earlier cut items are absorbed into the window and replaced with it, so a cut filler at 0.0 s before a rewrite of the first sentence leaves no fade across the cut. The rule applies whatever the gap, and whether or not a fade would cross the edge. In a clip scope the window extends only when the clip's range (`clipTimes`) starts at 0, because the output plan refuses a replacement outside the clip (§10.2).
2. **Right seam.** The mirror image: look right from `b`. A replacement R that starts no earlier than the start of the gap after `b` moves the hard seam's gap end to the earlier of its own end and `(jsRound(R.start × rate) − floor(N_R/2) − ceil(N_hard/2)) / rate`, with `N_R` R's incoming fade. When no kept or replaced item lies after the window's last word, the window extends to the take end with kind `none` and absorbs any later cut items. The take end is exactly `media.source.durationSeconds`, on sample `jsRound(durationSeconds × rate)`, never `totalSamples / rate`. In a clip scope the window extends only when the clip's range ends at or after `durationSeconds`.
3. **Insertions.** If the gap between `k` and `k+1` is at least `SEAM_MIN_GAP`, both seams lie inside it, `PAUSE_SLACK_KEEP` from each word. Otherwise treat it as a replace of `k+1` with bridging.
4. **Window.** `W = [seamIn, seamOut]`, and the patch text is left bridge + new words + right bridge. The replace range's first and last word IDs are the first and last items wholly inside `W`, absorbed cut items included. `W` also absorbs an event or unlabeled speech wholly inside it, such as an event that starts with the passage or one nested in its last word. An item that crosses a seam refuses the hunk with `windowCrossesWord`, and so does a kept word wholly inside `W` that is neither a passage nor a bridge word, because its speech would be lost.
5. **Fades.** A seam's centred fade of `N` source samples (`SEAM_FADE` or `HARD_SEAM_FADE`) has a left half of `floor(N/2)` and a right half of `ceil(N/2)`, with `seam` on the source sample grid. §10.5 never shortens a fade, so every seam with a fade must meet three rules:
   - **Inside the take.** `seam − floor(N/2) ≥ 0` and `seam + ceil(N/2) ≤ totalSamples`. A hard seam that breaks this refuses the hunk with `seamFadeOutsideTake`.
   - **Outer half in kept source.** The kept source contiguous with the seam, measured for the final window, must hold `floor(N/2)` samples before an incoming seam and `ceil(N/2)` after an outgoing one. Otherwise the hunk is refused with `seamFadeCrossesCut`, which reports the side and the needed and available samples. A fade therefore never crosses a cut word's reach, a cut pause or a clip edge. The window does not absorb a cut word to avoid this, because that would undo the user's cut timing and lengthen the take; the refusal comes before any paid take. The UI may later offer to include the cut word in the passage or to restore it.
   - **Fades fit the window.** `ceil(Nin/2) + floor(Nout/2) ≤ seamOut − seamIn` in samples, which is the render validator's `overlappingFades` rule (§10.5). A shorter window refuses the hunk with `windowTooShort`, which reports the needed and available samples. Nothing bridges it automatically.
6. **Replacements.** A window that overlaps a replacement, by the validator's `overlappingReplacement` rule in seconds, refuses the hunk with `overlapsReplacement` and that segment's ID. The final check measures the pieces the output plan builds with the window as one more replacement, and the pieces it builds without the window:
   - A window that touches a replacement, with no kept source between them, refuses with `adjacentReplacement` and that segment's ID. So does a single kept piece between them shorter than `ceil(Nout/2) + floor(Nin/2)`, prepare's `overlappingFades` rule across one piece.
   - Every replacement's seams are checked as the window's are: each fade's outer half lies in the kept source right beside its seam, and a single kept piece between two replacements holds both outer halves. The window's dropped items can lengthen a cut's reach (`editing.md` §7.3), for example when no kept word follows a cut pause any more. A check that holds without the window and fails with it refuses the hunk with `adjacentReplacement` and that replacement's ID.
   - A check that already fails without the window is not the window's doing. An edit after acceptance, such as cutting the pause that a replacement's seam lies in, can leave its fade across a cut, and prepare still renders it. Such a seam is judged by prepare's own rule: the neighbouring output piece is source and holds the fade's outer half, and the kept source between this replacement and the next one, the window included, holds both fades' outer halves. If the rule holds with the window, the check passes. If it fails with the window but holds without it, the hunk is refused with `adjacentReplacement`. If it fails without the window too, the scope does not render today, and the hunk is refused with `invalidInput` and that replacement's ID.
   - `place` never emits `synthToSynth` seams, because changing the recipe of an accepted, paid segment is out of scope. A later UX can offer to re-voice touching passages together.

When several rules fail, the first in this order is reported: `invalidInput` for the window's own samples, `overlapsReplacement`, `windowCrossesWord` (a crossing item, then a lost word), `seamFadeOutsideTake`, then for the incoming side `adjacentReplacement` (or `invalidInput` naming that replacement) and `seamFadeCrossesCut`, then the same for the outgoing side, `windowTooShort`, and finally each replacement in source order, its incoming seam, outgoing seam and then the kept piece after it, with `adjacentReplacement` or `invalidInput` and its ID.

**Several hunks.** `placeAll(project:scope:envelope:hunks:)` places a review's voice hunks in source order. Before either single-window placement or placement beside reservations, a temporary local project adds every review cut hunk's word IDs to `edits.cutWordIds`. Seam search therefore sees those deletions, never kept bridge words; the caller's project is not changed. Each placed window counts as a replacement for the later hunks, under the same `overlapsReplacement`, `adjacentReplacement` and fade rules.

When a window would overlap or touch an earlier window of the same review, the two hunks are merged into one: the words between them become bridges, re-voiced. The merge is kept only if the merged hunk still passes this section and the §8.2 patch budget. Otherwise the later hunk is refused with `collidesWithChange(index)`, copy "Too close to the change before it to voice separately. Edit them together or leave one out." `place` itself is unchanged.

The Swift input is `[VoiceLabDiffHunk]` (a scope review maps its `ScopeRewriteDiff.Hunk.hunk`). Only voice hunks produce `PlacedOrRefused` results. A placed result holds the merged hunk, its window and the original input `indices`, in source order; a refusal holds the original hunk, its original input `index` and `VoiceLabWindowRefusal`. A geometry refusal wraps the unchanged `VoiceLabGeometryError`. A collision's index names the first original voice hunk of the earlier placed group, not its sorted row number. Absorbed text-only hunks also join `indices`, so the caller removes their separate rows and combines the original lines, reasons and `checkThis` flags. Cuts and unabsorbed text-only hunks remain with the caller.

Placement first checks the unchanged single-window geometry, then places beside every earlier accepted window using their exact seam kinds and fades. A collision includes touching source-sample ranges and insufficient kept source for both windows' fades, not just overlapping seconds. Merging is transitive: every expanded window is placed again, and can collide with another earlier group. Intervening kept word items become bridges with project corrections and any review text-only correction applied. A cut word, a cut hunk, an event or unlabeled speech between the changes prevents a merge. An existing project replacement is never merged or edited. A failed merge restores every earlier group unchanged; only the later original hunk is refused.

After a provisional merge, the patch budget counts the whole review: the other accepted groups, the merged group and the remaining voice hunks. Already placed groups and the merged group include the words added by seam widening on both sides as well as their internal bridges. Previously refused voice hunks do not count. Count with integer arithmetic as in §8.2; exactly 15% and exactly 60 tokens still pass. Planning writes no project edits or paid recipes; its temporary reservations are not renderable assets and must never be saved. Insert-only hunks keep `place`'s `insertionUnsupported` refusal.

Its vectors are the separate `window-all-cases.json` file (schema `voxclip-voice-lab-window-all-cases/1`), generated by standalone `generate_window_all.py`. The legacy `window-cases.json` remains byte-identical. Both files require exact regeneration, not float tolerance. Swift `placeAll` and C# `VoiceLabWindowPlanner.PlaceAll` share this contract; both Core suites replay every case and validate and prepare each accepted union beside existing segments with the review cuts applied locally. The separate C# `VoiceLabWindowAllTests` replay leaves its legacy window reader untouched and checks the same outcomes, input-index identities, bridge surfaces, seconds, samples and seam fades exactly, including double bits and odd fade halves. Both use binary64 arithmetic, inclusive comparisons and the existing jsRound conversion; neither introduces an epsilon or recomputes take-edge seconds from sample counts.

### 8.5 TTS request

The model comes from `GET {base}/v1/models`. Keep entries with `can_do_text_to_speech` whose `languages[].language_id` include the take's language. The selected model must support the selected endpoint. These are examples for future A/B testing, not sole choices:

1. `eleven_v4`
2. `eleven_v3`
3. `eleven_multilingual_v2`, for its 29 languages, when the user picks it in the per-voice A/B preview

On first use of a voice in a language, the user hears a 10 s A/B preview of the candidate models and the choice is remembered per voice.

**Default on macOS and Windows (2026-11-03).** The Speech model picker lists discovered models that can make timestamped takes, in the account's order and under their account display names. `VoiceLabModel.speechRoute` classifies `can_do_text_to_speech` models as `textToSpeech`, except `eleven_v4` uses `textToDialogue` and `eleven_v4_turbo` has no supported route (websocket out of scope). Models without that capability have no route. `supportsTimestampedTTS` means a take can be made on either route. Multilingual v2 remains the default when listed (`patchDefault`), otherwise the first model sent context, otherwise the first `textToSpeech` model, with v4 as the fallback only when no other take model is available. V4 stays explicit-only when a TTS model is available, including v3. Instant clones use their existing `voice_id` on either route. No new picker controls or approval flow are introduced.

**Dialogue request (eleven_v4, explicitly selected).** The models page says v4 is available "via the Text to Dialogue API":

```
POST {base}/v1/text-to-dialogue/with-timestamps?output_format=pcm_24000
xi-api-key: <key>
Content-Type: application/json
{
  "inputs": [ { "text": "<patch text>", "voice_id": "<clone voice id>" } ],
  "model_id": "eleven_v4",
  "language_code": "et",
  "settings": { "stability": 0.5, "similarity": 0.8 },
  "seed": <candidate seed>,
  "apply_text_normalization": "auto"
}
→ 200 { "audio_base64": "…", "alignment": { "characters": […], "character_start_times_seconds": […],
        "character_end_times_seconds": […] } | null, "normalized_alignment": … | null, "voice_segments": […] }
```

V4 sends exactly one input and no context in this cut: `sendsSpeechContext == false`, and neither the quote nor the request binds previous/next text. The API spells the optional context fields `previous_text` and `future_text` (at most 100 characters each, not supported by every model); `next_text` is not a dialogue field. A later, separately validated context policy can enable them. Refuse dialogue text above min(model maximum, 2,000 Unicode scalars), before any paid send; TTS keeps min(model maximum, 5,000). Seed remains UInt32. The quote/claim binds region, endpoint, model, voice, language, seed and exact text, so approval cannot cross routes. Own-voice authorization requires the service-issued quote’s explicit `voiceID` to equal the consent record’s `voiceId` on both speech routes; the dialogue endpoint alone carries no voice identity. Send once, with the existing cancellation and ambiguous-dispatch rules. Pricing uses the existing `eleven_v4` per-character catalog rate and discovered character-cost multiplier; missing prices remain unknown.

The dialogue response requires nonempty `voice_segments`. Every segment must name the requested voice and dialogue input 0, have integral character indices with start ≥ 0 and start ≤ exclusive end, with end bounded by `max(alignment.characters.count, normalized_alignment.characters.count)` when `normalized_alignment` is a valid alignment object (otherwise use the original array count), and finite times with start ≥ 0, start ≤ end, and end ≤ PCM duration + 0.05 s (the same 50 ms tolerance as alignment). This array-length bound is provisional pending the lead’s live probe: the provider documents indices as being in the characters array without specifying original versus normalized alignment, while this request uses `apply_text_normalization: "auto"`. Validate the normalized object with the existing character/timing rules over its own joined text; a missing, null or malformed normalized object cannot widen the bound and never replaces original alignment. Missing or invalid segments fail `malformedResponse`. Fault order is normative: decode `audio_base64` → validate PCM → validate original `alignment` → validate `voice_segments`. With null alignment and a wrong segment voice, the outcome is `invalidAlignment`, not `malformedResponse`. Original `alignment` must pass the existing text/timing validator; null, absent or malformed alignment fails `invalidAlignment`, even when `normalized_alignment` is valid. Never retry the paid call automatically. A permission-missing 403 on either speech route identifies `text_to_speech`. Valid decoded PCM and its provider receipt are retained on the failed row and stay playable as unchecked paid audio even when alignment or voice-segment validation fails; no such row can be selected or proceed to QA.

Shared contract: `shared/fixtures/voice-lab/dialogue-cases.json` (`voxclip-voice-lab-dialogue-cases/1`), generated by `tools/fixtures/voice-lab/generate_dialogue.py`. Request framing matches existing TTS cases and adds canonical sorted compact UTF-8 JSON bytes/length/SHA-256. Both Cores replay all request, response and route cases. Existing TTS goldens remain unchanged.

**TTS request (eleven_v3 or multilingual v2, selected with its own estimate):**

```
POST {base}/v1/text-to-speech/{voice_id}/with-timestamps?output_format=pcm_24000
{
  "text": "<patch text>",
  "model_id": "eleven_v3",
  "language_code": "et",                      // omit for eleven_multilingual_v2
  "voice_settings": { "stability": 0.5, "similarity_boost": 0.8 },
  "seed": <candidate seed, UInt32>,
  "previous_text": "<≤300 Unicode scalars before; see below>",   // omitted when empty
  "next_text": "<≤300 Unicode scalars after; see below>",        // omitted when empty
  "apply_text_normalization": "auto"
}
→ 200 { "audio_base64": "…", "alignment": … | null, "normalized_alignment": … | null }
```

For `eleven_v3` and `eleven_v4`, `sendsSpeechContext` is false. V3 omits `previous_text` and `next_text`; v4 omits all context as above. Other TTS models use the following context rules. Core removes Unicode White_Space at both ends of `previous_text` and `next_text`. A trimmed text of at most 300 Unicode scalars is sent as it is. A longer `previous_text` keeps its last 300 scalars and a longer `next_text` its first 300, and two steps then adjust the cut:

1. **Word rule.** If the kept scalars contain at least one White_Space character, a word split by the cut is dropped. White_Space beside the cut is kept.
2. **Clean cut.** The cut then moves until it splits no cluster.
   - A scalar *extends* a cluster when it is a combining mark (General Category M: Mn, Mc or Me), U+200D ZERO WIDTH JOINER, or a variation selector (U+FE00–U+FE0F, U+E0100–U+E01EF).
   - A cut before scalar *i* is clean when scalar *i* does not extend a cluster and scalar *i* − 1 is not U+200D.
   - `next_text` keeps scalars [0, *k*). While the cut at *k* is not clean, *k* decreases, so a partial cluster is dropped back to and including its base. A complete cluster before a clean cut is kept whole.
   - `previous_text` keeps [*j*, *n*). While the cut at *j* is not clean, *j* increases, so orphaned marks and joiners are dropped.

A field that is empty after this is omitted. The quote binds the seed and the trimmed strings.

- **Audio.** With `pcm_*` formats, `audio_base64` is raw 16-bit little-endian mono PCM at that rate. Resample to the source rate.
- **Alignment.** Use `alignment`, not `normalized_alignment`, so caption text equals the typed text ("2025", not "twenty twenty-five"). The current Core timestamped path rejects null or malformed alignment. The later media QA path may use the Scribe/interpolation recovery in §8.8, after it is implemented and tested; null alignment must never be presented as timestamped speech.
- **Pronunciation.** The user may type a respelling for a word ("say it like"). eleven_v4 also accepts IPA wrapped in `/…/`. The respelling is sent as the text; the caption keeps the typed word.
- **Pace (the one caller voice-setting choice).** `VoiceLabSpeechOptions.pace` / `VoiceLabTakeInput.pace` is optional; nil means 1.0. TTS accepts finite values in **[0.7, 1.2]**, validates before quoting or sending (before rounding, never clamping), and sends `voice_settings.speed` rounded to two decimals, nearest with halfway values away from zero, only for a raw pace other than 1.0. Nil/1.0 leaves the existing request bytes/settings unchanged. All other voice settings remain the constants above. The quote/claim/review binds the unrounded pace; nil/1.0 are equivalent, but any other change needs a new approval, even if it rounds to the same speed. Receipts and persisted recipe/segment `provenance.pace` record the effective rounded pace, 1.0 when omitted. The project field is optional, so old projects remain valid without a schema-version change or migration. Pricing remains per character. `VoiceLabPace.clamp` is a pure caller helper with range constants, not provider validation; NaN maps to 1.0 and infinities to their boundary. No pace selection UI or automatic fitting policy is added here.

  Documentation checked read-only on 3 November 2026: [TTS with timestamps](https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps) accepts `VoiceSettingsResponseModel.speed`; [voice settings](https://elevenlabs.io/docs/api-reference/voices/settings/update) documents default 1.0 and slower/faster semantics; the [TTS guide](https://elevenlabs.io/docs/eleven-creative/playground/text-to-speech) gives minimum 0.7 and maximum 1.2. [Text to Dialogue](https://elevenlabs.io/docs/api-reference/text-to-dialogue/convert)'s settings list stability, similarity and clone strength, **not speed**. Dialogue therefore accepts only nil/1.0 pace and refuses non-default pace as `invalidInput` before quote or send, including values that round to 1.0. It never sends a speed field or silently ignores a requested pace.
- **Retries.** Synthesis, voice conversion, clone creation and deletion are never retried automatically: a timeout can mean ElevenLabs already billed or completed the request. A different endpoint or model needs a new estimate, review and affirmative authorization. Both Core implementations offer Eleven v4 through Text to Dialogue with the validation and route-bound approval above. A reply without valid original alignment fails the paid take; it never triggers a fallback request. V4 Turbo remains hidden.

### 8.6 Candidates

Mac review authorization pins the editor project, pending local edit commands, complete review hunks and proposal change content/states, included voice ordinals, scope/session revision, selected voice/model and region. Changing only a pending correction or its inclusion invalidates both the old displayed quote and acceptance, including corrected bridge speech. Focus-only movement does not. An unpaid plan needs fresh preparation and an explicit new approval; a paid plan remains guarded by the existing discard question and is never silently replaced. Dispatched work retains that owner while accepted charges are still pending delivery to the plan. Invalidation drains the operation before clearing its busy state and retains all accepted-charge accounting.

An explicit selectable take UUID survives progress, failed or better retries, Stop and three-slot eviction. Automatic ranking applies only until the user chooses a take. Row audition pauses source preview; source Play, Space and playback shortcuts stop audition, including a pending scratch startup. Selection, Stop, leaving and invalidation still tear down audition. Accepted-charge updates refresh the local monthly spend cache even after Stop/cancellation or a late obsolete/unpriced response. This reads the local ledger only, never a provider refresh. Daily transcription and monthly Voice Lab amounts share one status slot with distinct labels, not one combined ledger.

Paid plain Return uses the original AppKit event timestamp, not a delayed handler's time, for the 500 ms appearance guard. Key repeat and Space cannot spend; explicit Command-Return retains its existing policy, and inline questions choose the safe answer.

- The Mac first run generates one candidate per phrase. Each separately approved Try another makes one more candidate, retaining at most three visible slots. The bounded low-level runner still supports up to `CANDIDATES` takes for an explicitly prepared set, with seeds `s`, `s+1` and `s+2` modulo 2^32, where `s` is a random UInt32 per hunk stored with the segment. Prepare all per-take quotes before the run. One affirmative approval covers exactly this bounded set and its summed TTS plus Scribe QA cap (S14, §2.6). Every new run requires a new approval. Provider auth, quota or consent failures stop the run; a non-fatal failed take remains a row and the next independently quoted seed may run.

Windows keeps its bounded multi-candidate runner; missing or malformed timestamp alignment stops that run because a candidate cannot be accepted without it (§2.6).
- Each candidate goes through §8.7 to §8.11, and the fit planner (§8.9.2) runs before QA. Words, clipping, speaker and consent failures remain hard refusals. A join-loudness-only failure is **passed with advisory**, not rejected: it can be auditioned and explicitly chosen with **Use anyway** (§8.11).
- **Early stop.** Generation stops at the first take that passes QA and that the fit planner fits exactly (`exact`, §8.9.2). The already-prepared unsent quotes are discarded, never dispatched or recorded.
- **Pace.** ElevenLabs has no target-duration parameter. The provider/take layer supports an explicitly supplied per-phrase pace under §8.5; all candidates retain it while their seeds change. A fit-selection package can choose an estimate against the slot and must obtain a fresh quote when changing pace. Automatic calibration/feedback adjustment remains future work (§14 S13), not a hidden provider retry. Dialogue/v4 remains default-pace only; do not assume that an undocumented setting is supported or that the provider will produce an exact target duration.
- Rank clean passes before advisory passes, then rank within each group by `score = 0.6 × (1 − fitCost) + 0.3 × matchRatio + 0.1 × flatness`, where:
  - `fitCost` is 0 when the planner fits the take exactly; otherwise it is `min(1, |residualSeconds| / (0.25 × w))`, rising with the residual that `changedDuration` reports (§8.9.2);
  - `matchRatio` is the LCS ratio from §8.11;
  - `flatness = 1 − min(1, stdev / 6)`, where `stdev` is the population standard deviation of the candidate's momentary loudness (§8.11 item 3). Measure the trimmed take every `round_half_up(0.1 × rate)` samples from its first sample, with 400 ms windows, keeping whole windows only. Drop windows below −70 LUFS, so silence between words does not count as variation. With fewer than two windows left, flatness is 1.
- Show the best clean candidate. Never auto-select an advisory, including when it is the only take. Use-all, Keep-all, automatic review selection and numeric take shortcuts cannot accept one; **Use anyway** is required for that take. The user can audition every take ("Take 1 · 2 · 3") and pick one. Early stop still requires a clean pass.
- If every take is rejected, the phrase shows the copy and actions of `doc/design.md` §6.3.8 T3 for a phrase with no passing take.
- Another run (Try Another or Try Again, design.md §6.3.8) needs a new user action and its own quote; no take is generated automatically. The estimate shown before a run covers exactly its held plan: one take per phrase initially and one per separately approved retry (§3.2), and the spend ledger records only the takes that were sent (§3.1).

With several hunks, all per-take quotes for all hunks are prepared before the run. One affirmative approval covers the union of the bounded sets and their summed TTS plus Scribe QA cap. The run takes one hunk at a time, in source order, with early stop per hunk. Try Another on one phrase is a new approval for that phrase's set.

The Mac clip takes engine (V18a, UI integration in V18) places the entire included review with
`placeAll` before decoding source audio or preparing any take quote. It preflights all pending
windows together against the final review cuts, using the same output-piece and seam checks as
`acceptAll`; one invalid member refuses the set without payment. The engine exposes one summed
estimate and approval, then runs phrases in source order. Stop drains the active operation and
keeps completed takes and selections; later phrases remain waiting. Its configured spending cap
is checked against the ledger and the unsent remainder before execution, between phrases and
immediately before every paid request. An unreadable ledger, unknown price with a cap, or a
cap overrun stops the next request and preserves completed work. This engine does not override
the cap under an earlier approval; the single-passage compatibility workflow retains §3.1's
soft-cap confirmation until its UI is replaced.

The phrase rows retain three selectable slots. V18a's Try Another prepares and prices one new
candidate for that phrase only (one TTS plus its Scribe QA), under its own affirmative action.
It uses a fresh seed beyond that phrase's previously quoted candidates and preserves the old
playable takes. A deferred approval is bound to the displayed quote ID, never a newer quote.
It fills an unused slot, or replaces the lowest-ranked unselected slot when all three are full;
the selected take and other phrases stay intact. A length-changed take can be selected for
audition and length comparison but is left out of Phase 0 acceptance. The engine publishes
selected exact-fit, QA-passing takes as a segment/asset list and voice reference; V19 passes
that list, the final cuts/fixes and the actual scope to C4 `acceptAll` once (§8.12).

### 8.7 Trim, level, room tone

1. **Trim** the TTS audio to `[firstCharStart − TTS_TRIM_LEAD, lastCharEnd + TTS_TRIM_TAIL]` using `alignment`, clamped to the asset. Character times are first clamped to the asset's last frame: to the latest binary64 time `t ≤ frames / rate` with `ceil(t × rate) ≤ frames`, the rounding the fit planner gives a word's end. The client accepts a last end up to 50 ms past the PCM, and Eleven v3 times its last character to the end of the audio, where `ceil(1.36 × 24,000)` is already one frame past a 1.36 s asset (Mac since 2026-11-03; before that such takes failed as `invalidAlignment`). When alignment is null, the trim runs from the start of the first to the end of the last 10 ms frame above `VOICED_FRAME`, widened by `TTS_TRIM_LEAD` before and `TTS_TRIM_TAIL` after, and clamped to the asset.
2. **Level.** The TTS gets one static gain, stored as `audio.gainDb`. Nothing limits dynamically, and the voice itself is not altered.
   - **Frames.** A frame is 10 ms, `round_half_up(rate × 0.01)` samples. It is voiced when its RMS is above `VOICED_FRAME`. A voiced RMS is taken over every sample of the voiced frames: 20·log10 of the square root of their pooled mean square.
   - **Source level.** Take the source audio (or the Clean audio when it is on) in `[start − LOUDNESS_NEIGHBOURHOOD, start)` and `[end, end + LOUDNESS_NEIGHBOURHOOD)` around `W = [start, end)`, each side clamped to the take. `W` itself is excluded, because it is the audio being replaced. Frame each side on its own grid from its first sample, and ignore a trailing partial frame. Pool the voiced frames of both sides into one mean square.
   - **TTS level.** Take the voiced frames of the trimmed TTS (item 1) in the same way, framed from its first sample.
   - **Gain.** `min(clamp(sourceLevel − ttsLevel, −GAIN_CLAMP, +GAIN_CLAMP), −1 dBTP − ttsTruePeak)`. The −1 dBTP limit is a cap on this one gain.
   - **True peak.** Measure it as in ITU-R BS.1770-4 Annex 2, with the 48-tap, 4-phase interpolating filter: 4× below 96 kHz, 2× below 192 kHz using the filter's even phases 0 and 2, and the sample peak from 192 kHz. The audio is silent outside the trimmed TTS, so the ringing of an abrupt start or end counts. The true peak is the larger of the interpolated peak and the sample peak, because no Annex 2 phase lands on an input sample. Both rules can only lower the gain, which is the safe direction.
   - **Failure.** The source level depends only on the source and `W`, so it is measured when `W` is placed. If neither side of `W` has a voiced frame, the window is refused with `noVoicedAudio` before any paid take, as for `roomToneUnavailable`. A take with no voiced frame of its own is rejected as `noVoicedAudio`.
3. **Room tone** (only when Clean audio is off):
   - Find the quietest 0.5 s run inside source gaps of at least 0.5 s between items of any kind: the lowest summed power over 50 whole 10 ms frames. A run must hold both 50 whole frames and `jsRound(0.5 × rate)` samples, and the stored range is the second. Ties go to the earliest run.
   - Loop it under the patch with 50 ms crossfades between loops, at the background level beside the window (Mac since 2026-11-03; Windows and earlier recipes keep the natural level, `gainDb` 0). The level is the RMS pooled over the unvoiced 10 ms frames (at or below `VOICED_FRAME`) that touch each seam from outside `W`, framed outward from the seam and stopping at the first voiced frame or after 0.4 s, the window QA reads there (`VoiceLabLoudness.seamBackgroundRmsDb`). `roomTone.gainDb` is that level less the run's RMS, clamped to `GAIN_CLAMP` (`roomToneGainDb`). With fewer than 10 such frames, as at hard seams in connected speech, the gain is 0. The quietest half second of a whole take can sit far under the noise around the window: in a live car vlog it was −66 dBFS against −50 to −64 dBFS in the pauses beside four windows, so the patch's pads and pauses dipped audibly.
   - **Two levels (Mac since 2026-11-03).** The background is also measured on each side on its own (`seamBackgroundSidesRmsDb`): before the incoming seam and after the outgoing one, each needing 10 unvoiced frames. When both sides are measured and differ by at least 1 dB (`roomToneRampMinimumDb`), `roomTone.gainDb` is the left side's level less the run's RMS and `roomTone.endGainDb` the right side's, each clamped to `GAIN_CLAMP`, and the bed's gain moves linearly in dB between them across the window: at output frame `p` of a window `L` frames long it is `gainDb + (endGainDb − gainDb) × clamp(p / L, 0, 1)` (`VoiceLabRoomTone.gainDb(atFrame:of:)`, Windows `GainDbAt`), so a seam handle outside the window keeps its side's level. The final render takes `L = outDuration × rate`; the take QA mix takes the planned output frames. Otherwise, including equal backgrounds and a side without enough pause, the bed keeps the single pooled level above and `endGainDb` is omitted. A live window with 8 LU between its two backgrounds (−58 and −50 LUFS) could not meet both joins with one level.
   - Store the room-tone source range with the segment. With Clean audio on, skip room tone: both sides are already clean.
   - If no source gap holds a whole `ROOM_TONE_MIN_RUN`, passage TTS with Clean audio off is refused with `roomToneUnavailable` before any paid take, and the UI offers Clean audio (§4) instead.

### 8.8 Synthetic word times

Convert character alignment to words:

```
words = []; buf = ""; s = nil; e = 0
for i in characters.indices:
    ch = characters[i]
    if ch is whitespace: if s != nil && buf != "": words.append((buf, s, e)); buf = ""; s = nil
    else: if s == nil: s = starts[i]; buf += ch; e = ends[i]
if s != nil && buf != "": words.append((buf, s, e))
```

Then:

1. **Check.** Each derived token and each patch-text token is NFC-normalised, then normalised with `normalizeForMatch` (`editing.md` §4.7, which is defined on NFC text). The results must be equal, compared ordinally. A token that holds a lone surrogate or a noncharacter (U+FDD0–U+FDEF, or U+xFFFE or U+xFFFF in any plane) fails the check. Every platform tests for both before NFC and never relies on normalisation throwing. Words keep the provider's characters as their text.
2. **Fallback, in order**, when the check fails or the alignment is null:
   1. Forced Alignment, but only when the language is in `eleven_multilingual_v2`'s `languages`. That list does not include Estonian.
      ```
      POST {base}/v1/forced-alignment
      multipart: file = <candidate WAV>, text = <patch text>
      → { "characters": [{text,start,end}], "words": [{text,start,end,loss}], "loss": … }
      ```
   2. Otherwise, the Scribe words from the QA pass (§8.11), LCS-matched to the patch tokens. Their times are copied. Unmatched tokens are interpolated between neighbours in proportion to character count.
3. **Times.** Word times are relative to the output start of the window. The fit planner returns them (§8.9.2): each word keeps its aligned duration and moves by the pads and silence edits before it. Every word, bridge words included, is marked `synthetic: true`.

### 8.9 Duration fit

#### Pre-pay phrase fit (3 November 2026)

Rewrite checks every included voice change before **Get Price**. The local-length sentence in
`shared/prompts/voice-rewrite.json` applies to selection and scope rewrites. A passage-wide
character budget does not permit any single changed phrase to grow unchecked.

The estimator counts Unicode letters and digits in the complete synthesized patch (including
bridge words). Measure the clip's corrected transcript letters and digits per voiced second
using the union of its word spans (no inter-word pauses), excluding cut words. Multiply
this user rate by the calibrated provider cadence multiplier **1.8**, not a 20 characters/s
floor: slower users still get slower estimates. Add 0.12 s for each comma,
semicolon, colon or dash pause and 0.22 s for each sentence-ending punctuation group.
Trimmed provider lead/tail allowance is `TTS_TRIM_LEAD + TTS_TRIM_TAIL`.
Punctuation runs count once. Estimates are advisory, never speech-check evidence.
`ClipTakePlan.validateSpeechAvailability` retains its conservative generated-speech rule;
the fit estimate must not enable a short-phrase speaker check.

Calibration uses the app's `SpeakerVAD.ranges` and `VoiceConsentAudio.pcm16k`, the pinned
Silero 6.2.0 model, CPU, threshold 0.5, minimum speech 250 ms, silence 100 ms, no padding.
The supplied 3 November casual clip has 9.988221436984691 letters/digits per word-span
second. Phrase 2 (45 letters/digits) measured 2.6799375 voiced seconds from 2.7399375 raw;
its estimate is 2.832948… s (5.71% high). Phrase 3 (20 letters/digits, two commas and a
stop) measured 1.63 voiced seconds from 1.9504375 raw; its estimate is 1.662421… s and
cannot fit the 1.1 s source window, even at 0.80× source-video speed. Phrase 1's two
supplied takes measured 11.02 and 12.2148125 voiced seconds. Deterministic calibration
vectors live in the new `phrase-timing-cases.json`, not an existing replay category.

The slot is the longest usable take: evaluate the same silence-only fit planner and video
duration gate as a paid take, with lendable source silence and the existing 0.80×–1.25×
source-video speed range. Borrowed silence expands the fit window before testing retiming;
the maximum slot is that maximally borrowed window divided by 0.80, minus required
incoming/outgoing edge padding (all sample-rounded by the planner). This follows the
existing post-take gate, rather than independently capping retiming at the unborrowed window.
do not invent an independent speed or pause gate in the UI. A fully voiced hypothetical
take is conservative: no unmeasured generated internal silence is assumed shrinkable.
Before pricing, “fits” means that at least one post-take video option permits a hypothetical
take of exactly the estimated length. Slot and estimate are displayed in seconds to one decimal.

Rows read `≈ {estimate} s · slot {slot} s · fits` when usable, otherwise omit `· fits` and
show **Too long for its slot. A take won't fit the video.**, **Ask for shorter**,
**Keep original words**, and the quiet **Price it anyway** override. Only included phrases
that fit or have that explicit override enter the quote. The footer reads
`{n} phrase(s) need(s) a shorter wording.` and **Get Price · {k} phrase(s)**;
omit the priced button when k is zero. With no blocked phrases, read **Nothing paid yet.**
The same gate can reject wording that is too short to pad or retime safely. In that case
say **Too short for its slot. A take won't fit the video.**, offer **Use surrounding sentence** instead of
asking for fewer words, and use `{n} phrase(s) need(s) wording that fits.` in the footer.
The original-words and explicit pricing override remain available.

**Pace matching (3 November 2026).** The calibrated estimate above is the 1.0× baseline.
For each complete voice phrase, choose a provider pace within 0.70–1.20, on the provider's
0.01 grid. Prefer a predicted **Keep source video duration** exact fit, aiming at the midpoint
of its exact-fit duration interval. If that interval is unreachable, choose a permitted pace
that passes **Match video**, still as close to that midpoint as possible. Derive the intervals
from the existing fit planner: its one-frame take gives maximum permitted seam/edge padding,
and its overlong take gives the maximum borrowed window and required edge padding. Assume
no editable generated internal pauses. Verify the chosen prediction through the actual
video-duration gate. Never enlarge room-tone padding to make pace matching succeed.
The row reads `≈ 4.6 s at ≈0.80× pace · slot 5.1 s · fits`; omit the pace clause at 1.0×.
The row's per-hunk pace is approximate; complete-phrase pricing also accounts for kept
cuts and merged hunks. The edit popover uses the selected speech model's pace capability.
VoiceOver reads the timing line for fitting rows too. With a current take plan, timing
always uses that plan's current model, including during generation and after a model
change that keeps paid takes. Without a current plan it uses the picker. Paid-plan
membership stays bound to its reviewed ordinals; changing models never silently adds
or removes a phrase or invalidates another phrase's paid takes.
Pace scales the whole predicted trimmed take, not the source video. The estimate remains
advisory. Dialogue/v4 has no supported non-default speed and uses the same gate at 1.0×.

If no permitted pace fits, retain the too-long warning and **Ask for shorter**, or the
too-short warning and **Use surrounding sentence / Keep original words** (replacing Ask
again for short wording). Sentence expansion uses the existing full-sentence inline review,
scope/reservation checks and fresh separate paid quote; selecting the action is not a pricing
override or a send approval. The unchanged generated-speech floor still governs speaker
measurement eligibility, not this timing decision.

On **Try another** for a selected take that cannot keep the source duration, recalibrate
from its measured trimmed audio duration before fitting edits, borrowing, padding or retiming:
`newPace = clamp(oldPace × measuredSpeech / targetSpeech)`. Use the selected take's receipt
pace, not an unused retry quote's pace; target the exact-fit midpoint, respect provider
hundredth-step rounding, then fall back to the reachable Match video interval. Preparing or
re-preparing a retry sends nothing and creates a new pace-bound quote/approval. Include the
non-default phrase paces beside the priced action. Older paid takes keep their receipt pace.
Before a retry quote is held, the next-take pace label computes the same measured retry
pace that pricing will use; with a held quote it shows that quote's input pace. Re-decoding
an expanded surrounding sentence uses the plan's current model: exactly 1.0 for v4,
otherwise a fresh exact-fit-first pace calculation, not the initial model's old pace.
Shared sample-exact regression observations live in `pace-matching-cases.json`, separate
from both the provider request fixtures and the original calibration vectors.

**Ask for shorter** uses the same scope and normal text-only Rewrite send, with fresh
consent/approval checks, never a previous send authorization. Append the shared
`shorterFeedbackBlock`, rendering `shorterPhraseLine` for each blocked phrase with its
original/proposed words and estimate/slot seconds. The new proposal replaces the old one
and resets timing overrides. **Keep original words** uses the existing per-change exclusion.
The optional `feedback` field is distinct from the user's instruction: preserve the existing
1,000-byte instruction limit and bound feedback to 20,000 UTF-8 bytes. Both passage and
scope request fingerprints bind feedback to the fresh send quote; nil retains the existing
request and fixture shape. Render template placeholders once, never inside substituted words.
Paid takes with neither video option available also offer both recovery actions; further
audio generation always goes through the usual fresh price and approval.
After payment, shorter-wording feedback uses the selected take's measured output duration
(`outputFrames / sampleRate`), falling back to the best measured take. It includes all
reviewed ordinals of a merged phrase, not only the first hunk. The shared
`prompts/voice-rewrite-shorter-measured.json` keys `shorterMeasuredFeedbackBlock` and
`shorterMeasuredPhraseLine` distinguish these readings from the unchanged pre-pay
estimate templates and leave the existing request fixtures' source hashes intact.

While paid takes exist, Price it anyway, Keep original words, Keep, Undo, Keep All and
editing proposal words use the same inline Discard Changes / Keep Working confirmation
as Ask for shorter. Before confirmation, no proposal state, inclusion override, quote,
selection or paid plan changes. Keep Working leaves all of them untouched. Confirmation
retires the old plan before applying the requested review action; no provider call is made.
Failed surrounding-sentence review clears its redirect ordinal but keeps the inline failure.
Price it anyway also clears that redirect; an ordinal no longer in the reviewed voice set
cannot redirect Get Price. The compatibility single-take session announces fitting progress
only for automatically selectable takes, never advisory takes it cannot accept.

Voiced speech is never time-stretched (ADR-R30). A take reaches the length of its window in this order: length-budgeted wording before any paid call (§8.9.1); one initial take followed by separately approved one-take retries (§8.6); silence-only fit (steps 1 and 2 below); and otherwise a changed duration with the ADR-R28 video choice, after as much silence fit as the limits allow (step 3).

Let `D = duration(trimmed TTS)` (§8.7 step 1). At a take edge (seam kind `none`, §8.4) the planner keeps the source edge silence with an edge pad `e` (§8.9.2); elsewhere `e = 0`. Let `w = duration(W) − e`, the part of the window the take must fill, and `ρ = D − w`. A positive `ρ` means the take is too long.

1. **Silence fit.** The fit planner (§8.9.2) places `ρ` in the pauses inside the take, which it finds from the character alignment: punctuation pauses first, then the others, each in proportion to its length and within `PAUSE_FLOOR_PHRASE`, `PAUSE_FLOOR_PUNCT` and `PAUSE_GROWTH_MAX`. It edits silence only, and every voiced sample is copied bit-exactly. When the result is `exact`, Media writes the fitted WAV (§8.9.3): the output timeline is unchanged, the recipe's fit factor is 1, and the video stays source video. This step replaces the earlier pitch-preserving fit.
2. **Borrow pause time.** Whatever step 1 cannot place goes to the seams, in the same plan:
   - If the TTS is longer, widen `W` into the neighbouring gaps, keeping at least `PAUSE_SLACK_KEEP` of silence next to each kept word.
   - If the TTS is shorter, pad room tone (or silence) equally at both seams: up to `SEAM_PAD_MAX` at a gap seam or take edge, and up to `HARD_SEAM_PAD_MAX` at a hard seam. A hard seam sits in connected speech, so it takes only a short pause. Whatever the take's own pauses and the seams cannot hold becomes a changed duration (step 3).
3. **Choose how to match the video.** When the planner returns `changedDuration`, its partial silence edits stay, and only the residual changes the output length (`outDuration ≠ inDuration`): `outDuration = duration(W) + residualSeconds`, and the fit factor stays 1. A smaller residual keeps the retime factor inside `RETIME_VIDEO_OK` more often. Show both **Lip sync** and **Retimed source video** for each rewrite and require the user's choice (ADR-R28). Do not automatically choose a mode or reuse the last rewrite's choice. Keep an unavailable option visible with its reason; do not fall back to the other option after a failure.
   - **Retimed source video (`zoomCover`)**: a jump cut to 1.12× around the face during the replaced range, with source frames retimed by `duration(W) / outDuration`. Explain the speed change and slight crop before selection. Only allowed when that factor is in `RETIME_VIDEO_OK`.
     - Face centre: Vision `VNDetectFaceRectanglesRequest` on macOS, `Windows.Media.FaceAnalysis.FaceDetector` on Windows, sampled every 0.5 s and averaged.
     - With no face, use the frame centre.
   - **Lip sync (`lipsync`)**: §9, with `sync_mode = "remap"`. Show the provider, what is sent and the current cost before the separate paid-action approval.
   - If neither approach can handle the range, the hunk is rejected: "This change is too long to patch. Re-record this sentence instead."

`STRETCH_OK` remains only as a validation bound for stored recipes (§10.5). It no longer selects a fit step, and rendering refuses any fit factor other than 1. A micro-stretch of at most ±3% is an optional later experiment (§8.9.5). What was tried before ADR-R30, and why it was rejected, is recorded in [`doc/archive/voice-lab-stretch-history.md`](../archive/voice-lab-stretch-history.md).

#### 8.9.1 Length budget and fit meter

`VoiceLabLengthBudget` in each Core (`Domain/VoiceLab/`) is free, pure and identical on both platforms.

- **Length.** The length of a text is its number of letters and digits after Unicode NFC normalisation: scalars of general category L or Nd. Spaces, punctuation, symbols such as emoji, combining marks (M) and other number forms (No, Nl) do not count, and Estonian õ, ä, ö and ü count as one letter each, precomposed or not. Each Core computes it with one function, `VoiceLabTextLength` in `Domain/VoiceLab/` (Swift `length(_:)`, C# `Length(string)`), which the budget, the meter and every proposal check use. NFC is each Core's one exact helper, Swift `EditingPrimitives.nfc` and C# `EditingAlgorithms.Nfc` (`editing.md` §4.8; ADR-R19 keeps NFC working on Windows). Foundation's NSString canonical-mapping methods leave a precomposed syllable and a trailing jamo apart; the Swift helper composes them. .NET's normaliser rejects an unpaired surrogate and U+FFFE, so the C# helper makes an unpaired surrogate U+FFFD, as a Swift string holds it, and keeps U+FFFE, normalising the runs around it on their own. Neither U+FFFE nor U+FFFD is a letter or digit, so the length is the same on both platforms. Both suites replay the 39 cases of `shared/fixtures/voice-lab/text-length-cases.json`, written by `tools/fixtures/voice-lab/generate_text_length.py`.
- **Rate.** Letters and digits per second, kept per voice ID, model ID and language. Until the project stores a candidate for that key, the rate comes from the take's own transcript: the length of its `word` items divided by the total duration of its voiced word spans. A voiced word span is a run of `word` items with no detected pause between them (editing.md §5.7), timed from its first word's start to its last word's end. Call the existing Core pause detector on **all** transcript items with the take's pause threshold; an event or unlabeled-speech item also ends a voiced word run. Once stored candidates exist for the key, the rate is their total text length divided by the total of their aligned spans, each from the first character's start to the last character's end. The pure API takes a list of `(text, firstCharStart, lastCharEnd)` for one caller-selected key; it neither searches project state nor pools keys. Empty candidate lists fall back to the transcript; malformed candidate spans are `invalidInput`, never a silent fallback. No positive text length or voiced duration is `rateUnavailable`. Add lengths and durations in input order, with one binary64 subtraction per span, then divide once. The rate is learned only from candidates stored in the project; for privacy, there is no rate store shared across projects.
- **Estimate.** A text of length `n` is expected to give a trimmed take (§8.7 step 1) of `n / rate + TTS_TRIM_LEAD + TTS_TRIM_TAIL` seconds. Evaluate in binary64 as `speech = Double(n) / rate`, `lead = speech + TTS_TRIM_LEAD`, `estimate = lead + TTS_TRIM_TAIL`, in that order.
- **Target.** New wording aims at `LENGTH_AIM_MIN` to `LENGTH_AIM_MAX` of `w` (§8.9), so it comes out 3–8% short: the silence fit lengthens a take easily, but it can shorten one only by the pause time the take has. The character range for the words to be written, where `f` is the length of the bridge words the window already holds:

  ```text
  minChars = max(1, floor((LENGTH_AIM_MIN × w − TTS_TRIM_LEAD − TTS_TRIM_TAIL) × rate) − f)
  maxChars = max(minChars, ceil((LENGTH_AIM_MAX × w − TTS_TRIM_LEAD − TTS_TRIM_TAIL) × rate) − f)
  ```

  **Evaluation order.** For each bound, separately compute `aim = LENGTH_AIM_* × w`, `lead = aim − TTS_TRIM_LEAD`, `tail = lead − TTS_TRIM_TAIL`, `scaled = tail × rate`, then `floor(scaled)` for the minimum or `ceil(scaled)` for the maximum, then subtract `f`, then clamp as above. Every operation is binary64; do not combine trims, reassociate, fuse operations or add rounding tolerances. Returned character counts must fit a signed 32-bit integer; otherwise return `invalidInput` rather than clamp to the request's 5,000-character limit. That request validation remains separate.

  **Take edges.** Take `incomingSilence` and `outgoingSilence` from `VoiceLabWindowPlanner.lendableSilence` (§8.9.2). Before a take exists, an incoming `none` seam contributes `max(0, incomingSilence − TTS_TRIM_LEAD)` to `e`, and an outgoing `none` seam contributes `max(0, outgoingSilence − TTS_TRIM_TAIL)`. Other seam kinds contribute 0. Add the incoming and outgoing pads, then evaluate `w = (W.end − W.start) − e`. A hard seam takes nil silence; a gap or none seam requires finite, non-negative silence. Refuse unsupported `synthToSynth` seams, non-positive `w` and non-positive or non-finite rates with `invalidInput`. `passage` resolves the window's bridge IDs and sums their `VoiceLabTextLength` for `f`; the caller places the **whole selection as one replace hunk**, and does the same for each Fix-with-AI line. `fullTake` is advisory, takes first-word start through last-word end, and uses `e = f = 0`.

- **Rewrite request.** `VoiceRewriteRequest` carries `targetSeconds`, which is `w`, and `minChars` and `maxChars` from the range above, as required members on both platforms. `targetSeconds` must be finite, above 0 and at most 600, and the range must satisfy 1 ≤ `minChars` ≤ `maxChars` ≤ 5,000. Any other value fails with the service's invalid-input error (`VoiceLabError.invalidInput`, `VoiceLabErrorKind.InvalidInput`) before a quote or a send. Core takes the three values from the caller and computes no window or rate itself. For a passage, `W` is the §8.4 window of the whole selection treated as one replace hunk, and `f` is the length of that window's bridge words. For a full take the budget is advisory, because the timeline follows each chunk's natural length (§13): `w` runs from the take's first word start to its last word end, and `f` is 0. `shared/prompts/voice-rewrite.json` (`promptVersion` 1, its first versioned form) holds all the request text, in `request`:
  - `cachedBlock` is `sourceBlock` with `{scope}` (`passage` or `fullTake`), `{language}`, and `{source}`, the source words joined with single spaces.
  - `instruction` is `instructionBlock` with `{instruction}`, the user's request after `jsTrim` (`editing.md` §4.5), followed by a blank line; this part is left out when the trimmed request is empty. Then come `returnLine`, a line break, and `lengthLine` with `{targetSeconds}` written by `toFixed1` (`ai.md` §11.3) and `{minChars}` and `{maxChars}` as decimal integers.

  A 4.1 s gap with the range 52–55 renders "Length: the new words should take about 4.1 seconds to say, which is 52 to 55 letters and digits. Spaces and punctuation are not counted. Write natural wording that stays inside this range." Both suites send the 7 cases of `shared/fixtures/llm/voice-rewrite-requests.json` (passage and full take, with and without a request, six budgets including `minChars` = `maxChars`) through `VoiceRewriteService`, compare `system`, `cachedBlock` and `instruction` byte for byte, and check the preflight of `ai.md` §12.8 with `expected.preflight`. The rewrite quote binds the three fields like the rest of the request, so a changed budget needs a new quote and approval; `contract.json` has a `rewriteMutations` row for each. Like the Fix with AI quote (§8.1), it binds the prompt file as the SHA-256 of its bytes after CRLF→LF, and its estimate is `est()` of the whole rendered request, `system + cachedBlock + instruction`, in the unit `token`, with basis `unknown` and no price or credits; each case's `expected.estimate` pins it. Both Cores check the request, budget included, before they estimate it.
- **Check.** LLMs miscount length, so Core counts the proposal itself: `VoiceRewriteProposal` carries `proposedLength` (C# `ProposedLength`), the `VoiceLabTextLength` of the proposed text, and `inRange` (`InRange`). A proposal outside the range is shown as it is, with the meter. Shorter or Longer is always a new send with its own quote and approval (`doc/spec/ai.md`, S15); there is no automatic length retry.
- **Fit meter.** `VoiceLabFitMeter` costs nothing and updates live as the user edits New words, including text they type. It is computed per voice hunk, for that hunk's complete patch text (window bridges included) and window, with the same pre-take `w` and `e`. Return `estimateSeconds`, `gapSeconds = w`, the bounds, typed verdict `fits` or `willChangeLength`, and copy. For each gap seam, `borrow = max(0, outsideSilence − PAUSE_SLACK_KEEP)`; hard and none seams borrow 0, following §8.9.2. Thus the meter never counts the protected 0.15 s or take-edge silence as borrowable. `pad = HARD_SEAM_PAD_MAX` at a hard seam and `SEAM_PAD_MAX` at a gap seam or take edge. Evaluate `lower = (w − padIn) − padOut` and `upper = (w + borrowIn) + borrowOut`, in binary64. **fits** means `lower <= estimate <= upper`, inclusive at both bounds, without an epsilon; otherwise it means **will change length**. The copy is "about 4.3 s for a 4.1 s gap: fits" or "about 4.3 s for a 4.1 s gap: will change length", with both numbers formatted by the existing `toFixed1` (not locale formatting). With more than one voice hunk, prefix its new words in curly quotes and ` · `, as in "“on Sunday” · about 1.2 s for a 1.1 s gap: fits" (design.md). The pauses inside a take are unknown until it exists, so a take can still fit when the meter says it will change length. The planner decides (§8.9.2). The `newWords` input is required: the hunk's new-side tokens (`newTokens`) joined with single spaces. They include the diff-merge bridge words a merged hunk re-voices (§8.2 step 6), which the diff line also marks, and never the window-search bridges (§8.4 step 4). Multi-hunk quotes always use `newWords`, never the complete patch text used for duration.

Shared `length-budget-cases.json`, written by `tools/fixtures/voice-lab/generate_length_budget.py`, pins every pair of gap/hard/none seams, take-edge pads, transcript and stored-candidate rates, full-take scope, floor/ceil values within 1e-9 of an integer, and both meter verdicts immediately inside and outside the inclusive bounds. Both Core suites replay every case.

#### 8.9.2 Fit planner

`VoiceLabFitPlanner` in each Core (`Domain/VoiceLab/`) is free, pure and deterministic, and gives the same result on both platforms. Its shared vectors are `shared/fixtures/voice-lab/fit-cases.json`, written by `tools/fixtures/voice-lab/generate.py` through its standard-library reference planner `tools/fixtures/voice-lab/generate_fit.py`.

- **Inputs.** The window `W` and the kind of each seam (§8.4). For each `gap` seam, its lendable silence: the kept source contiguous with the seam on its outer side, measured as §8.4 step 5 measures it for the final window, with every replacement's outer fade halves taken out, up to the nearest kept transcript item outside `W`. So it stops at that item, a cut item's reach, a cut pause, a clip edge or another replacement's outer fade half, and borrowing never widens `W` over a cut or into another replacement's fade. The caller computes it with `VoiceLabWindowPlanner.lendableSilence(project:scope:window:)` (C# `LendableSilence`) from the project, scope and window that `place` used. That helper builds the scope's kept source with the code `place` uses. It returns each gap seam's lendable silence in seconds (source samples over the source rate), each `none` seam's source silence between the take edge and the window's nearest word in transcript seconds, and nil (C# null) only for a `hard` seam. Its pair feeds the fit planner directly; a take-edge value is for padding, never borrowing. The trimmed take (§8.7 step 1), its words from the character alignment (§8.8) and its 10 ms RMS envelope. The patch tokens, and the §8.3 constants.
- **Take edges.** At a `none` seam the planner pads the take with silence so that its first aligned word starts where the window's first source word started; at the take end, its last aligned word ends as far from the end as the window's last source word did. This edge pad `e` is never negative; when the window reaches both edges, `e` is the sum of both pads. Before a take exists, the length budget and the meter compute `e` with the default trims. A `none` seam has no outside silence to borrow.
- **Pauses.** An internal pause lies between two consecutive aligned words of the take. Its editable run is the longest run of whole 10 ms frames, counted from the paid asset's first sample, that lies after the earlier word's last character end and before the later word's first character start, with every frame below `VOICED_FRAME`. The pause's length is the length of that run. It is a **punctuation pause** when the patch token before it ends with a Unicode punctuation character (general category P), and an **intra-phrase pause** otherwise.
- **Limits** (§8.3, tuned by ear after the listening check in §8.9.4):

  | Pause | May shorten to | May lengthen by |
  |---|---|---|
  | intra-phrase | `PAUSE_FLOOR_PHRASE` (60 ms) | the smaller of `PAUSE_GROWTH_MAX` (0.25 s) and its run less `SEAM_FADE` |
  | punctuation | `PAUSE_FLOOR_PUNCT` (150 ms) | the smaller of `PAUSE_GROWTH_MAX` and its run less `SEAM_FADE` |

  A pause already at or below its floor is not shortened. Lengthening repeats frames of the run once, and the repeat and its one join must fit inside the run, so a 100 ms pause lengthens by at most 80 ms and a run no longer than `SEAM_FADE` is not lengthened. Both floors exceed `SEAM_FADE`, so such a run is not edited at all.
- **Distribution.** A positive `ρ` shortens pauses and a negative `ρ` lengthens them.
  1. Spread `|ρ|` over the punctuation pauses in proportion to their lengths. A pause that would pass its limit stops at the limit, and the remainder is spread again over the punctuation pauses that can still change, until nothing remains or none can change.
  2. Spread what remains over the intra-phrase pauses in the same way.
  3. Place what still remains at the seams (§8.9 step 2), split equally between them. A seam that reaches its limit passes the rest to the other seam. When borrowing, the limit is `PAUSE_SLACK_KEEP` kept next to the kept word. When padding, it is `SEAM_PAD_MAX` at a gap seam or take edge and `HARD_SEAM_PAD_MAX` at a hard seam.
  4. If anything remains after that, the result is `changedDuration`. The edits from steps 1 to 3 stay, every one of them at its limit, and only the remainder changes the output length.
- **Rounding.** Edits are whole frames of the paid asset, and borrowing moves a seam by whole source samples, each rounded with the JavaScript half-up rule. An `exact` output has `jsRound(n × assetRate / sourceRate)` frames, where `n` is the returned window's length in source samples, so it matches the window within one asset sample (§10.1). A `changedDuration` output adds its signed residual frames to that count: `outputFrames = jsRound(n × assetRate / sourceRate) + residualFrames`, with `residualSeconds = residualFrames / assetRate` (§8.9.3). The final sub-millisecond residual left by rounding goes into the pad at a seam that sits in a gap or at a take edge, the incoming seam first, as long as that pad stays non-negative. Otherwise, as at hard seams, it goes into the TTS tail trim, then the lead trim (§8.7 step 1).
- **Edits.** Each edit lies inside its pause's editable run, centred in it. Shortening removes samples; lengthening inserts samples repeated from the same run. Every edit has equal-power joins of `SEAM_FADE` that lie wholly inside the run, so no edit touches an aligned word span or a 10 ms frame at or above `VOICED_FRAME`.
- **Output** (`VoiceLabFitResult`, whose `VoiceLabFitPlan` holds the fields below). Either of:
  - `exact(editList, newWordTimes)`: the edits in paid-asset frames, the pad and the borrowed source samples at each seam, the final trims and window bounds, and the word times relative to the output start. Each word keeps its aligned duration and moves by the pads and edits before it.
  - `changedDuration(partialEditList, naturalOut, residualSeconds)` when the limits cannot hold `ρ`. `partialEditList` has the same fields as `editList`, word times included, and holds the edits that fill the limits. `naturalOut` is `e + D`, the take's length before any edit. `residualSeconds` is the part of `ρ` that the limits could not hold, with the sign of `ρ`, so the partially fitted take lasts `duration(W) + residualSeconds`. §8.9 step 3 applies.
- **Pinned readings.** Where the rules above leave a choice, both Cores and the reference planner take the most literal reading, and the named vectors in `fit-cases.json` pin it. Frames are paid-asset frames, `jsRound` is editing §4.1, `n` is the window's length in source samples, `t0` and `t1` are the trims in frames, and `N = jsRound(SEAM_FADE × assetRate)`.
  - **Words and pauses.** A word covers frames `floor(start × assetRate)` to `ceil(end × assetRate)`, exclusive. A frame is voiced when its level, read as binary64, is at least `VOICED_FRAME_LEVEL`. Of two equally long runs the earlier is the pause. Punctuation is judged on the last Unicode scalar of the patch token. General Category comes from the platform (Swift `Unicode.Scalar.Properties.generalCategory`, C# `Rune.GetUnicodeCategory`). Both follow the UCD; the fixtures cover the characters that matter. The take's lead and tail are not pauses. Vectors: `pause-threshold-above`, `pause-threshold-below`, `pause-longest-run`, `pause-longest-run-tie`, `pause-frames-from-asset-start`, `pause-take-edges-are-not-pauses`, `punctuation-categories`.
  - **Edge pads.** Each `none` seam has its own pad, `max(0, jsRound(silence × assetRate) − f)`, where `f` is the frames between the trim and the nearest word span. Each pad stays at its own edge, `e` is their sum, and step 3 pads add to it. The window holds `jsRound(n × assetRate / sourceRate)` frames, and `ρ` is `e + t1 − t0` minus that. Vectors: `edge-start`, `edge-end`, `edge-both`, `edge-never-negative`, `edge-pads-beyond`, `edge-too-long`, `limit-pad-edge`.
  - **Limits.** A pause whose run is `L` frames may shorten by `max(0, L − jsRound(floor × assetRate))` frames. Lengthening repeats frames of the run once, so the repeated frames and one join must fit inside it: a pause may lengthen by `min(jsRound(PAUSE_GROWTH_MAX × assetRate), L − N)` frames when `L > N`, and not at all otherwise. Both floors exceed `SEAM_FADE`, so a shortened pause always holds its join. Vectors: `limit-punctuation-floor`, `limit-phrase-floor`, `limit-growth-max`, `limit-growth-run`, `pause-at-floor`, `pause-at-floor-lengthens`, `pause-run-shorter-than-fade`, `pause-run-equal-to-fade`, `pause-run-just-longer-than-fade`.
  - **Proportion.** In each round, every pause whose exact share (`amount × L / ΣL`, over the pauses still changing) passes its limit stops at the limit, all of them at once. When none passes, each pause takes the floor of its share, and the frames left over go one each to the largest remainders, ties to the earlier pause. An amount at least the group's total room fills every pause to its limit. Vectors: `redistribute-punctuation`, `redistribute-to-phrase`, `redistribute-together`, `redistribute-largest-remainder`, `redistribute-tie-earlier`, `pause-punctuation-first`, `pause-punctuation-versus-phrase`.
  - **Seams.** The incoming seam takes the odd frame or sample. A `gap` seam can lend `max(0, jsRound(silence × sourceRate) − jsRound(PAUSE_SLACK_KEEP × sourceRate))` source samples; `hard` and `none` seams lend nothing. Borrowing is exact when the window widened by both lends holds at least `jsRound(n × assetRate / sourceRate)` frames plus the remainder. The seams then borrow `jsRound(remainder × sourceRate / assetRate)` samples between them, at most what both can lend (Residual below may raise it); otherwise each lends all it can and the result is `changedDuration`. Pads are whole frames: up to `jsRound(SEAM_PAD_MAX × assetRate)` at a gap seam or take edge and `jsRound(HARD_SEAM_PAD_MAX × assetRate)` at a hard seam, beyond the edge pad. Vectors: `seam-borrow-both-gaps`, `seam-borrow-odd-sample`, `seam-borrow-passes-to-other`, `seam-borrow-hard-incoming`, `seam-borrow-none-incoming`, `seam-silence-within-slack`, `seam-pad-both-gaps`, `seam-pad-odd-frame`, `seam-pad-hard-passes`, `seam-pad-gap-to-hard`, `limit-pad-gap`, `limit-pad-hard`, `limit-borrow-slack`, `changed-borrow-at-limit`.
  - **Residual.** Only the borrowing step leaves a rounding residual, including when its first borrow rounds to zero: the widened window's frames minus the planned frames. It goes to the incoming pad unless that seam is hard or the pad would turn negative, then to the outgoing pad on the same terms. Next it goes to the tail trim, while the last word span stays inside the trim and the trim inside the asset, and then to the lead trim on the same terms. When none can take it, the residual is negative: the widened window is short of the planned frames. The seams then borrow the fewest more source samples whose widened window holds the planned frames, at most what both can lend and split again as above, and the residual, now zero or more, goes into the pad of the gap seam that borrowed, the incoming one first. Borrowing is exact only when the widest window holds the planned frames, so such a borrow always exists and a residual never refuses a take. A residual still negative is a planner fault, `fitTouchesVoice`. Vectors: `residual-incoming-pad`, `residual-incoming-edge-pad`, `residual-outgoing-pad`, `residual-outgoing-edge-pad`, `residual-tail-trim`, `residual-lead-trim`, `residual-unplaced`, `residual-raise-outgoing-borrow` and `residual-zero-borrow` (48 kHz asset, 16 kHz source, incoming pad 2 frames and borrow 1 sample).
  - **Edits.** An edit of `c` frames in a run that starts at frame `s` starts at `s + floor((L − c) / 2)`. A removal drops frames `[start, start + c)`, and an insertion plays them twice. The playhead jumps once, and the one join is centred on the jump: `floor(N / 2)` frames before it and `ceil(N / 2)` after. Edit and join cover `[start − floor(N / 2), start + c + ceil(N / 2))`, which lies inside the run.
  - **Times.** Each word moves by the incoming pad minus `t0`, plus the frames the edits before it add or remove. That offset is divided by `assetRate` and added to the word's aligned start and end in binary64. The word keeps its provider text and is `synthetic: true`. Both seam times are on the source grid, whether or not the seam borrowed: `windowStart = windowStartSample / sourceRate` and `windowEnd = windowEndSample / sourceRate`, in binary64. This makes an exact fit's `jsRound(outDuration × sourceRate)` equal the window's source-sample length, as required to render source video without changing the timeline (§8.9 step 1). `naturalOut` is `(e + t1 − t0) / assetRate`, and `residualSeconds` is the planned frames minus the widened window's frames, divided by `assetRate`. Last, each word's start and end `t` are clamped in binary64 to the output duration the recipe states (`outDuration`, §8.9.3): `min(t, windowEnd − windowStart)` for `exact` and `min(t, windowEnd − windowStart + residualSeconds)` for `changedDuration`, with the seam times above. The output's `jsRound(n × assetRate / sourceRate)` frames can last up to half a frame longer than the window, and without the clamp the last word could end after `outDuration`, which §10.5 refuses. An aligned word shorter than one source sample is invalid timing of the take and is refused before fitting with `invalidWordTiming`. Before constructing any plan, validation also checks the clamped words against all of §10.5: `end ≤ outDuration`, `samples(end) ≤ out`, `end > start`, `samples(end) > samples(start)` and `start ≥ previous end`. A clamp that would collapse the final word is refused with `invalidWordTiming`, never `fitTouchesVoice`. Vectors: `refuse-word-below-source-sample`, `refuse-word-straddles-source-sample`, `refuse-final-word-clamp-collapse`, `seam-times-off-grid`, `seam-times-borrowed`, `changed-longer`, `changed-shorter`, `changed-offgrid-hard-residual-eight`, `round-word-end-clamped`.
  - **Ties.** Every rounded quantity is non-negative, so each tie rounds up. The vectors put a tie in a take that is too long and in one that is too short, and in a borrow, an edge pad and the 22.05 kHz growth and punctuation-floor limits: the six `round-tie-*` cases. `round-unity-recipe-half-frame` also pins the unity recipe's asset-frame equation (§8.9.3, §10.5) at a half-frame tie.
  - **Inputs.** A `hard` seam has no outside silence, and every other seam has a finite, non-negative one. These are `invalidInput`:
    - a source rate below 1 Hz or above 1 MHz, so that no borrow overflows a 64-bit sample count;
    - a `synthToSynth` seam;
    - an empty window, or a seam sample off the window;
    - a left `none` seam whose window does not start at source sample 0;
    - an incoming gap silence that reaches before source sample 0;
    - a silence whose source samples or asset frames reach 2^53, or a widened window end whose source sample times the asset rate reaches 2^53;
    - an envelope at another rate, or with another count than the asset's whole 10 ms frames;
    - trims outside the asset, a tail trim at or before the lead trim, or a trim at 2^53 asset frames or more;
    - an asset of 2^31 frames or more.

    A take with no words refuses with `alignmentUnavailable`. A token count that differs from the word count, an empty token, or empty aligned word text refuses with `alignmentMismatch` (`refuse-empty-word-text`). Word spans out of order, empty, ending at 2^53 asset frames or more, or outside the trims refuse with `invalidWordTiming`. Each Core refuses these inputs with typed errors and never traps. Other input-refusal vectors: `refuse-synth-to-synth`, `refuse-gap-without-silence`, `refuse-hard-with-silence`, `refuse-negative-silence`, `refuse-take-start-off-zero`, `refuse-silence-before-take`, `refuse-empty-window`, `refuse-envelope-rate`, `refuse-envelope-length`, `refuse-asset-too-long`, `refuse-trim-outside-asset`, `refuse-trim-end-before-start`, `refuse-source-rate-too-low`, `refuse-source-rate-too-high`, `refuse-no-words`, `refuse-token-count`, `refuse-empty-token`, `refuse-word-before-trim`, `refuse-words-overlap` and `refuse-empty-word`. The three word-span refusals are cited under Times; the empty aligned-text refusal is cited above.
  - **Voice invariant.** Each Core and the reference check every plan before returning it:
    - both pads are non-negative;
    - the edits are in order and apart, inside the trims;
    - no edit or join overlaps a word span or a frame at or above `VOICED_FRAME`;
    - the pads, trims and edits add up to the output's frames.

    A failure is the typed `fitTouchesVoice`: a planner fault, never a property of the take. So every output sample outside the edits and their joins is a copy of its paid frame.
- **Vectors.** `fit-cases.json` (schema `voxclip-voice-lab-fit-cases/1`) holds named cases in eleven categories: pauses, limits, redistribution, seams, edges, changedDuration, rounding, residual, rates, spec15 (§15 test 4) and refusals. The rates cases put 22.05, 44.1 and 48 kHz assets against 8, 16, 22.05, 44.1 and 48 kHz sources: `rates-22050-in-8000`, `rates-22050-in-16000`, `rates-22050-in-22050`, `rates-22050-in-44100`, `rates-22050-in-48000`, `rates-44100-in-8000`, `rates-44100-in-16000`, `rates-44100-in-22050`, `rates-44100-in-44100`, `rates-44100-in-48000`, `rates-48000-in-8000`, `rates-48000-in-16000`, `rates-48000-in-22050`, `rates-48000-in-44100` and `rates-48000-in-48000`. The §15 test 4 cases are `s15-five-percent-longer`, `s15-five-percent-shorter`, `s15-one-word-hard-seams`, `s15-borrow-beside-pause`, `s15-forty-percent-longer`, `s15-partial-at-limits` and `s15-take-edge`. The property picks include those low source rates too. The file also holds 2,000 property cases from seed 20261027. Both Cores replay every case. For each plan they check again:
  - the voice invariant;
  - the centring and limits of each edit;
  - the seam limits;
  - the word and window times;
  - the full §10.5 word rule: `end ≤ outDuration`, `samples(end) ≤ out`, `end > start`, `samples(end) > samples(start)` and `start ≥ previous end`;
  - the output length: for an `exact` plan, `jsRound(n × assetRate / sourceRate)` frames and `jsRound(outDuration × sourceRate) == windowEndSample − windowStartSample` for the window it returns.

  `generate.py` writes the file byte-identically on every run.

#### 8.9.3 Fitted asset

At accept time, `VoiceLabSilenceFit` in each Media (`apps/macos/Sources/VoxClipMedia/VoiceLab/VoiceLabSilenceFit.swift`, `apps/windows/src/VoxClip.Media/VoiceLab/VoiceLabSilenceFit.cs`) writes a derived fitted WAV for each unrejected candidate whose plan pads or edits the take's audio. Before accept, Media renders the same audio to scratch for audition and for the QA pass (§8.11). The renderers do not change.

- **Source.** The SHA-256-verified private snapshot of the paid asset (§10.4). The fitted WAV has the paid asset's sample rate, channel count and sample format.
- **Content.** In order: the incoming handle, the incoming pad, the edited take, the outgoing pad and the outgoing handle. Every sample outside the edits, their joins and the pads is a bit-exact copy of the paid frames. On Mac since 2026-11-03, one exception: when the take's trim starts at the paid asset's first frame or ends at its last, and that frame is not silent (Eleven v3 stops mid-word), the take's own edge gets an equal-power fade of `min(jsRound(0.005 × a), L / 2)` frames, `L` being the take's frames between the pads: sin(π/2 · k/n) in, cos(π/2 · (k + 1)/n) out, so the edge sample is 0 and does not click against the silence beside it. Such a candidate is derived. Source frames are never shaped. Pads are silence; room tone is mixed under the whole window at render time (§8.7 step 3). The handles meet §10.5: they copy the paid frames beyond the trim, or continue the silence where a pad meets the seam. A provider take can end on its last aligned frame (Eleven v3 does) or start within a handle of its first one. TTS is silent outside its trim (§8.7 item 2), so the frames a handle needs beyond the paid asset are written as silence, and such a candidate is derived even when its plan neither pads nor edits. Mac since 2026-11-03; before that the fit read past the paid file and the take failed as `invalidAudio`.
- **Storage.** `<data>/VoiceLab/<projectId>/<assetId>.wav`, next to the paid assets. The file is immutable and SHA-256-bound, and `voiceLab.assets` lists it like any v3 audio asset. Undo and delete never remove it (§10.3).
- **Recipe.** `audio.assetId` names the fitted asset, `audio.trimStart` and `audio.trimEnd` bound the content between the handles, `audio.stretch = 1`, and `outDuration = plan.windowEnd − plan.windowStart`, plus `residualSeconds` for `changedDuration`. This subtraction and optional addition use binary64 exactly as §8.9.2 Times pins them, never samples divided by the source rate. The trims lie on the fitted asset's frame grid and satisfy `jsRound(trimEnd × a) − jsRound(trimStart × a) == plan.outputFrames`, where `a` is its rate. `recipe.chunks` keep the paid asset: each chunk's `assetId`, `assetSha256`, `requestId` and `seed` name the paid generation, while its assembled frames lie on the fitted asset's grid between the trims. The §10.5 unity frame-grid validation accepts this shape, and both renderers play it through their verified unity path. A candidate whose plan neither pads nor edits the take points `audio.assetId` at the paid asset itself. Either way, when a seam borrowed, the segment's replaced range and the chunk source bounds use the widened window.

**Proposed schema change (not adopted).** An optional audit record `recipe.fit = {"kind": "silence", "edits": [...]}` would keep the planner's edits, pads and borrowed samples with the recipe. A reviewer could then see what changed, and a missing fitted WAV could be rebuilt from the paid asset if both platforms write identical bytes. `shared/schemas/project.schema.json` has no such field: the recipe's `audio` object holds only the asset, trims, fit factor and gain, and the recipe allows no other properties. Adding it needs a schema revision. Until then, the fitted WAV's SHA-256 and the paid chunks are the record.

**Mac W4 boundary (2026-10-29).** Core returns only trim, gain, room-tone and fit analysis; it no longer carries a second fit/mix implementation. Media's `VoiceLabSilenceFit.prepare` takes `VoiceLabAssets.preparePaid`'s SHA-verified private snapshot, preserves integer PCM16/24/32 or IEEE float32/64 WAV frames and channels, and produces the fitted bytes once. `VoiceLabAudioRenderer.stageTake` writes those bytes to private scratch and composes the audition/QA mix at the paid take's rate using the renderer's existing equal-power and 50 ms room-loop math. Its unity export path is unchanged. `VoiceLabTakeRun.scratch(for:)` exposes the lease; `reject` and cancellation invalidate its scratch files, never the paid asset. `VoiceLabAudition` exposes play, stop, position refresh and completion, plus take/selection-change, rejection and session-end hooks for W6. No panel UI is added here.

`VoiceLabFittedAudio.publish` returns verified asset records and the unity audio, words, exact duration, widened source bounds and paid-identity chunks that W5 applies to its recipe. The project transaction belongs to W5; Media never lists a half-written file. The immutable writer uses exclusive partial files, file sync, exclusive rename, directory sync and SHA-256 readback. Injected failures after directory creation, partial creation, header, each PCM block, file sync, rename, directory sync and verification leave no final asset or a complete one. A post-rename failure preserves the complete file but returns no record to list. `shared/fixtures/voice-lab/fitted-asset-cases.json` and its README pin the cross-platform byte contract; both Media suites replay all cases.

#### 8.9.4 Listening check (release gate)

The fit policy ships only after the user's listening check passes (§14 S16). It uses the same setup as the earlier comparisons, and its pass criteria, below, are written down before any file is generated.

- **Material.** Six real passages in the user's own clone, in both languages if the user vlogs in both. Each language has at least one take that is too long (the fit shortens its pauses) and one that is too short (the fit lengthens them). At least one item must be a one-word patch with hard seams in connected speech, so that `HARD_SEAM_PAD_MAX` is heard.
- **Presentation.** Each passage plays in its full context: 2 s before and after, with the final seams and room tone, loudness-matched, in random order with hidden labels.
- **Variants.** X is the natural-length take (changed duration, no fit). Y is the silence fit to the exact window. Z is the ±3% micro-stretch, included only if that experiment is approved (§8.9.5).
- **Listening.** On the Mac's speakers and on headphones. For each item the user answers: natural or not; any metallic, robotic or echo sound; pauses natural or not; seam audible or not.
- **Pass.** Y has no reported artifact on any item, and its pacing is judged natural on at least 5 of the 6. Any failure names the pause rule to fix, and the §8.3 constants are tuned from the answers. Z is adopted only if the user cannot tell it from X and calls it artifact-free on every item.

#### 8.9.5 Micro-stretch (optional later experiment)

A micro-stretch of at most ±3% on the dry TTS, before room tone is added, with Signalsmith Stretch (MIT) or Sonic (Apache-2.0), may be tried later. It needs the user's approval, the blinded listening check (variant Z in §8.9.4) and a later ADR. Until then the §10.5 refusal stays. FFmpeg `atempo`, SoundTouch, Apple `AVAudioUnitTimePitch` and Rubber Band are not fit candidates.

Private take invalidation is explicit and idempotent: first stop every registered consumer, then remove both the fitted/mixed scratch directory and its private paid-snapshot directory. Retaining a stale take or snapshot handle never retains those files after invalidation completes. Every audition instance subscribes to its lease, including players in other windows; invalidation awaits their stop on the main actor without polling position. Published paid and fitted assets are untouched.

### 8.10 Seams

- Apply equal-power crossfades of `SEAM_FADE` at both seams, or `HARD_SEAM_FADE` at hard seams. The synthetic audio and the source audio overlap by the fade length, centred on the seam.
- The plan's 5 ms join fades (`editing.md` §7.7) still apply at cut joins elsewhere.

### 8.11 QA checks (hard gates and advisory joins)

**Join advisory (3 November 2026).** Only a finite measured excess above 2 LU at a join is advisory. Such a take is **passed with advisory**, selectable through its inline **Use anyway** action, but never selected automatically. The row reads `Take {n} · {dur} · The join may sound uneven ({side} side). Listen before using.` and offers **Play** and **Use anyway** without an alert or sheet. `{side}` is `left`, `right`, or `either` when both joins exceed the threshold. Playback does not select or accept it. **Use anyway** records that take's measured seams and the acceptance time, selects it, and leaves the normal per-take video-duration choice and **Use Takes** transaction unchanged. It does not claim that playback finished or that the joins passed. Clean passes win best-take ordering even at a lower score. No Use-all, Keep-all, auto-accept or keyboard shortcut bypasses the explicit choice. A later retry preserves the acceptance only for the same take ID and identical measured seams.

Words/Scribe, clipping, speaker/voice (including pooled short-speech rules), alignment, consent, quote approval and use-time guards remain hard gates exactly as before. Missing or invalid loudness measurements remain failures; this policy does not waive incomplete checks or a hard failure accompanied by a join advisory.

Eleven v4 dialogue replies may omit `alignment` or return null. That is `invalidAlignment`, never timestamped success: the paid request remains recorded and valid PCM stays playable as unchecked audio under the existing failed-take rules, with no automatic retry or normalized-alignment substitution. A take proceeds to QA only after valid original-text alignment and voice-segment validation. Saved `.tts` recipes accept the exact dialogue endpoint `v1/text-to-dialogue/with-timestamps` only with `eleven_v4`; v4 on a TTS endpoint is `endpointUnsupported`. Other models keep the existing timestamped TTS endpoint contract.

Mac DEBUG/profile builds write redacted speech-validation JSON under the app log location, `Diagnostics/VoiceLab/speech-validation-<request-id>.json` (normally `~/Library/Logs/VoxClip/Diagnostics/VoiceLab/`; an isolated `VOXCLIP_DATA_DIR` uses its `Logs/` directory). Both speech routes record the route, model, typed text, joined original/normalized alignment text, character counts, first/last five original start/end times, PCM duration and all non-secret segment fields. The exact failed rule includes a zero-based Unicode-scalar index and both `U+` values for text mismatch, or the original alignment/segment entry index for timing/range failures. Audio, headers and credentials are excluded; registered secrets are redacted before encoding. A single INFO event says `voicelab dialogue validation failed check=<name>` without text. Diagnostic I/O cannot change the validation result or paid-audio retention. Release contains neither the evidence writer nor its destination override. This diagnostic does not relax alignment or substitute normalized metadata.

**Run continuation.** Ordinary failed takes, including QA rejection and malformed dialogue segments (`malformedResponse`), remain failed rows and the next independently quoted phrase proceeds. Missing/malformed original alignment (`invalidAlignment`) is the existing route-blocking exception: end the approved batch after that paid take because the current timestamped path has no alignment recovery. Account/auth, quota and consent failures also stop it. Retain completed rows and playable valid PCM/receipts, discard unused authorizations, and require a fresh quote and explicit approval for any later retry. Mac marks every remaining phrase in that batch **Stopped**, with the actual cause, rather than leaving it **Waiting**. Alignment copy names the model, for example `Stopped: Eleven v4 replies can't be checked yet. Nothing sent for this phrase. Try again after the timing issue is resolved.` Existing takes use `No new take sent for this phrase.` See the [probe analysis](../voice-lab-validation-probe.md); no comparison relaxation is enabled.

On Mac the inline phrase rows read `RewriteSession.takePlan` (`ClipTakePlan`), not the compatibility passage generator. The displayed action captures the held `approvalID` and passes it as `quoteID` to deferred start or phrase-only retry. Replacing, expiring or invalidating that quote requires fresh preparation and another explicit approval. A retry prepares one candidate for its phrase; it never regenerates another phrase. Stop drains the operation and ends audition without discarding completed takes. Every failure remains visible. A QA-passing changed-duration take is auditionable but left out of Phase 0 acceptance: no nonunity fitting or video-mode fallback is enabled. Future changed-duration rendering still requires an explicit, unremembered choice for each rewrite (§8.9).

Scribe QA is separately priced as `speechToText`/`scribe_v2`, but its bounded quote is included inside the approved run total, not approved after synthesis. The run reserves at most 290 seconds per QA request, including the half-second source context on each available side. A candidate whose final QA buffer exceeds that cap is invalid and is not sent to Scribe. The spend ledger retains the conservative quoted estimate only for accepted sends; it is not an actual provider invoice. Mac W4 reads back the private float32 scratch WAV containing the fitted audio, static gain, room-tone loop and centred seams. Scribe's PCM16 upload is encoded from that readback; mixed sample peak and seam loudness jump measure the same readback. Speaker matching and flatness still measure the ungained trimmed paid take, not source context or room tone. Scribe dispatch uses the same voice and current-input gates as TTS. Missing or malformed alignment remains invalid under §2.6. The §8.8 fallback is not enabled until its LCS tie-breaking and interpolation bounds at missing leading/trailing neighbours are defined precisely; no alignment repair is silently purchased.

The W3 input holds decoded source audio on the source sample grid, an already-placed window and complete patch text including bridge words. W4 owns bounded media extraction and scratch sizing; W3 bounds each paid candidate and its QA buffer as above. Source level and room tone are checked before any paid request.

**Short phrases (ADR-R37).** Scribe, clipping and loudness checks run for every completed take, including short ones, except that a take already rejected by generated-speaker extraction skips the paid Scribe request. Extract generated voiced samples using the same VAD. A take with at least three seconds of voiced speech keeps its per-take speaker check. Short takes wait for the run's voice check and cannot be selected while waiting. At the end of the approved run, or on Stop over completed takes, split the run's short generated VAD outputs into consecutive groups for the same consent record, closing each group at the first take reaching three seconds. Attach a leftover tail below three seconds to the preceding group. For each complete group, use the unchanged 3 s windows / 1.5 s hops and consent threshold. A measured mismatch adds `.speaker` only to its own group’s takes, retaining any independent words or acoustic failure. Never use source speech, pad or repeat a take, or generate extra audio to fill a pool.

If the completed pool still contains less than three seconds of voiced speech, record an unavailable measurement with absent speaker score. Its takes remain selectable only for an active own clone with `recordedStatement` or `projectAttestation` consent, after words and acoustic QA pass. Any measured mismatch for that record in the plan (a group or a long take) blocks this exception, including previously completed unmeasured rows, until a later approved run passes a measured check. A passing check in the failing run cannot clear it. Unmeasured takes require an explicit click and never displace a selected take automatically; automatic selection considers only measured passing takes. Inline copy is `Short phrase · words checked · voice checked across 3 takes` (actual count) or `voice couldn't be measured (under 3 s of speech)`; the latter also identifies the own-clone exception. Show successful pooled copy once per phrase, only for a take whose words and speaker checks passed. Waiting copy is `waiting for the voice check`. Preserve specific fatal errors when finalizing the local checks, and name consent/provider errors using their actual cause. This policy replaces the old short-speech refusal, without lowering the calibrated threshold.

The first plan quotes one take per phrase. `Try another` quotes exactly one more synthesis and its bounded Scribe request for that phrase, and needs a fresh priced approval. A short retry borrows only earlier generated voiced samples for the same consent record in this plan: that phrase's takes most recent first, then the plan's other takes most recent first. Stop at three seconds, truncating the final donor to the remaining frames. The new take receives that pool's verdict; donor takes retain theirs. Duration estimates are advisory for optional `Use surrounding sentence`; the short text and original reviewed source window remain allowed. The advisory uses `max(userRate, 20)` characters per second, subtracts the 0.03 s lead and 0.06 s tail allowance, and retains 80% as estimated voiced time. These conservative planning assumptions are not speaker thresholds. Existing accepted TTS word alignments supply `VoiceLabRateCandidate` measurements when available.

Windows currently retains the `insufficientGeneratedSpeech` refusal below 48,000 generated voiced samples and skips Scribe on that refusal. ADR-R37 adoption is a separate Windows integration; the Mac pooled policy above does not imply that it has shipped there.

For the W3 transcript comparison, assign a Scribe word to the fitted patch when the midpoint of its recognised interval lies in the half-open fitted patch interval. The extra source context remains in the acoustical checks and upload but does not enter the intended-text token comparison.

1. **Re-transcribe** the final patched window, `[seamIn − 0.5 s, seamOut + 0.5 s]` of the mixed audio with the silence fit applied (§8.9), with Scribe v2 and `language_code`. Compare the normalised recognised tokens inside the window with the intended text, bridge words included:
   - for 5 tokens or fewer, require exact equality;
   - otherwise require an LCS ratio of at least 0.9 (`2 × LCS / (expected + recognised)`).
2. **No clipping.** The sample peak of the final mixed window, with the static gain of §8.7 item 2 applied, is below 0 dBFS. The window is the same span as item 1. The sample peak is 20·log10(max |x|) and is stored as `qa.peakDbfs`. There is no dynamic limiter: the true-peak cap in §8.7 item 2 is the only limit.
3. **Loudness jump (advisory).** A finite measured excess over 2 LU at either seam requests listening and explicit **Use anyway**, not rejection. The measurement and 2 LU threshold remain unchanged.
   - **Momentary loudness.** Momentary loudness is BS.1770-4: −0.691 + 10·log10 of the K-weighted mean square, with channel weight 1, over `round_half_up(0.4 × rate)` samples. The K-weighting runs over the mixed audio from its first sample, with zero filter state, so the audio before a window sets the filter state. Its biquads follow libebur128's bilinear-transform derivation (MIT), prewarped at each f0: the shelf at f0 1681.974450955533 Hz, gain 3.999843853973347 dB and Q 0.7071752369554196 with the mid-band numerator term Vh^0.4996667741545416, and the RLB high-pass at f0 38.13547087602444 Hz and Q 0.5003270373238773 with the numerator [1, −2, 1] not divided by a0. At 48 kHz this meets the published BS.1770 coefficients within 1e-6, and those coefficients are the normative anchor.
   - **Windows.** Measure `[seam − 0.4 s, seam)` and `[seam, seam + 0.4 s)` on the mixed audio's own sample grid. A window cut short by the audio's edge is shortened. If either window is then shorter than 0.1 s, the seam fails with `insufficientContext`.
   - **Floor.** Floor each window's loudness at −70 LUFS, the BS.1770 absolute gate. The jump is `|max(M_after, −70) − max(M_before, −70)|`. It is always finite, and two windows at the floor give 0. A cut from room tone to digital silence is audible, so it reads the room tone's distance from −70 LUFS, and QA can catch it.
   - **Against the source (Mac, 2026-11-03).** A seam sits in a pause or at a word edge, so one 400 ms side usually holds more speech than the other, and the unedited source steps there too: at the four seams of a live car-vlog review the source alone jumped 5 to 38 LU, so no take could pass. The take QA therefore also measures the two windows on the unedited source, over the same lead, window and tail on the same grid (`VoiceLabTakeAudio.sourceSeamSteps`). Both sides use the signed step `S = max(M_after, −70) − max(M_before, −70)` (`VoiceLabLoudness.seamStepsLu`; the jump above is `|S|`). A seam's value is how far the mixed step lies outside the interval between 0 and the source's own step: `max(0, min(0, S_source) − S_mixed, S_mixed − max(0, S_source))` (`VoiceLabLoudness.seamExcessLu`). So a seam passes when its jump is no larger than the source's natural jump at that point, in the same direction, plus the unchanged 2 LU limit. A step in the opposite direction counts in full, so a take far louder than the speech it replaces cannot pass by mirroring the source's step. A take louder than the speech it replaces, or room tone that stops where the source has background on both sides, still fails; a take whose speech starts a few frames later than the source's does not. **Pause joins (Mac, 2026-11-03).** The 400 ms windows read where speech falls, so a take that ends in a longer pause than the source leaves a quieter window before the outgoing seam and failed with no audible join (live take 3, 7.1 LU; a casual take ending 0.4 s before the source's next word, 31.6 LU). Pooled pause levels misread too: the unvoiced frames beside a join also hold inhales, a word's decay and the take's own onset, all below `VOICED_FRAME` (live casual takes, 3.0 to 5.0 LU with a continuous trace at the join). A seam whose **generated side** (after the incoming seam, before the outgoing one; `VoiceLabTakeAudio.generatedAfter`) is in a pause is therefore a pause join. That side is framed in 10 ms frames outward from the seam and keeps the unvoiced frames (RMS at or below `VOICED_FRAME`) up to the first voiced frame or 0.4 s; a run stopped by the take's speech leaves out the take's trimmed lead (`TTS_TRIM_LEAD`) before its first word, or tail (`TTS_TRIM_TAIL`) after its last. With at least 0.1 s kept, its level `L` is the K-weighted loudness of just those frames, floored at −70 LUFS (`VoiceLabLoudness.generatedPauseLufs`). The reference is the unedited source's own pauses at the seam, each framed the same way but read whole, to the first voiced frame or the edge of the audio QA holds, and counted when it holds at least 0.1 s: on the source side, which the join meets, and on the window side, the pause the take's pause stands in for. Their range `[P_min, P_max]` runs over the K-weighted loudness, each floored at −70 LUFS, of the 0.1 s spans stepping frame by frame through those pauses and of each pause's 30 ms next to the seam (`VoiceLabLoudness.sourcePausesLufs`, `VoiceLabTakeAudio.sourceSeamPauses`), so a breath that decays to the floor at the join, or the source's own step from its floor into an inhale, stays inside it (live 16:16 run, 3.6 and 6.4 LU with continuous traces). The seam's value is `max(0, P_min − L, L − P_max)`, with the same 2 LU limit (`VoiceLabLoudness.seamExcessLu`). Where the source side is not in a pause, the take's pause meets source speech and the onset or end of that speech is the join: the seam then also passes when the rule above passes for its 400 ms windows (live 16:16 run, 2.6 LU against the pause replaced, 0 by its windows). Room tone that stops, or sits louder or quieter than every part of the source pauses at the seam, still fails; a longer take pause, an inhale or a word's decay in the source does not. A take whose last word trails off before a hard seam inside connected speech is a real step and still fails (live 16:16 phrase 1, the take's last 0.4 s 7.7 LU under the speech it replaces). A seam whose generated side is not in a pause, or whose source has no pause beside it, keeps the rule above. Windows still compares the plain jump.
   - **Recipe value.** `qa.lufsJumpLu` is the largest jump over the seams whose kind is not `none`, and 0 when there is no such seam; on Mac takes it is the largest seam value, as above.
   - The shared vectors `shared/fixtures/voice-lab/audio-math-cases.json` pin every rule in §4.4 step 3, §8.6 flatness, §8.7 item 2 and this item; `shared/fixtures/voice-lab/audio-math-README.md` names the case for each.
4. **Speaker.** A long take or short-take pool scores ≥ τ against the consent embedding. The explicitly recorded own-clone under-length exception above carries no measured score.

QA results are stored with the segment (§10.1). A candidate that fails is not offered. Newly accepted short takes add optional `recipe.qa.shortSpeech` evidence: `mode` (`pooled` or `unmeasured`), `recordId`, `consentMethod`, `voicedFrames` at 16 kHz, and `takeCount`. Pooled evidence requires at least 48,000 frames and a measured passing score. Unmeasured evidence requires fewer than 48,000 frames, own-clone consent, an absent score and `speakerPassed: false`. The evidence binds to the recipe's consent record; ordinary recipes without it retain the measured-score rule. Existing encoded recipes omit the optional field unchanged.

### 8.12 Accept

macOS take review retains at most three private scratches per phrase plus one staged/in-flight attempt across the serialized set runner. Evicting an unselected retry slot awaits its consumer-aware retirement before another attempt proceeds; the selected and other visible slots survive. Stop and invalidation drain that cleanup. Original/published paid assets remain retained. Late results from stale inputs cannot restore rows or playback; actual accepted request costs remain accounted.

macOS V19 routes the inline **Use Takes** action through `RewriteSession.acceptTakes` and the scoped C4 list overload. Publication of every selected fitting phrase finishes and is revalidated before one snapshot mutation includes the pending cuts and corrections. A stopped run may deliberately use only its finished fitting subset; a transaction never commits a prefix of the selected set. Refused/stale publication shows neither success feedback nor an undo entry. Changed-duration rows still cannot be accepted; the explicit future per-rewrite video-choice policy is unchanged.

After success, a six-second announced toast and the same host's in-use Voice rows show the actual accepted count. The footer reports actual take spend (including paid failed/retried attempts), or "Spend unavailable", and **Undo Voice**. This restores all voice segments, assets, cuts and fixes with the one scoped native undo; charges are not refunded. Feedback is in-memory and valid only for the accepted project/revision, with Undo also checking the top native action. It does not mislabel a later unrelated undo, survive a changed project, or fabricate success on redo. AI transcript tint/underline, viewer **AI voice**, export disclosure and optional post disclosure OFF by default reuse the existing implementations.

Accepting stores the segment (`kind: "tts"`) with its assets, words, provenance and QA, as one undo step.

- While the segment is enabled, the source words inside `[firstWordId, lastWordId]` are covered (§10.2).
- [Turn off] keeps the segment but plays the source.
- [Delete] removes it.

`VoiceLabEditCommand.acceptAll(segments:assets:voice:)` validates the nonempty set (no overlaps, each recipe valid in the output scope) and applies it, with the review's cut and correction commands, as one undo step named "Rewrite clip {n}" (or "Rewrite {w} words", "Rewrite full take").

C4 stages all members before validation; a touching pair or full-take group need not be valid one member at a time. Any overlap among new members, or with an enabled stored replacement, refuses the whole review. The command reconciles identical stored assets, refuses conflicting or duplicate supplied IDs, and checks active consent for every unrejected own-voice candidate. `VoiceLabProject.validate(_:scope:accepting:)` prepares the completed output (including the review's cuts and corrections), requires every new segment to be enabled and wholly inside that output, and checks the alternatives' scope seams as well as the selected recipes. An empty list throws `invalidSegment` before any upgrade or consent-reference change. A failure records no edit or undo step. The single `accept` API is the one-element form.

On Mac, `EditorModel.applyVoiceLab(_:assets:voice:scope:localCommands:)` takes the complete list and its `RewriteScope`. Clip numbers follow the sidebar's kept-then-suggested order; selection counts include spoken words, and Full take uses its own name. It reduces the review's local commands in memory before acceptance, then calls `replace` once. AppKit receives that name through `setActionName`, so Edit > Undo, redo, segments, assets, cuts, corrections and document dirty state share one snapshot transaction. The single-command overload remains available for the passage workflow until V15/V19 switch their Keep path to the scoped list; it refuses `.acceptAll`. Sets must use the list overload with an explicit scope. Core's scope-free `acceptAll.actionName` is "Accept Voice Lab takes"; the app caller supplies the scoped Rewrite name above, including on Windows. C# W2b now implements the same `AcceptAll` transition, output-scope/alternative checks, and scoped-list history transaction. `EditorViewModel.ApplyVoiceLab(segments, assets, voice, scope, actionName, expectedProject, localOperations)` reduces local review operations and snapshots the original project once; its command overload refuses `AcceptAll`. `UndoActionName` / `RedoActionName` carry the caller's Rewrite title. `RewriteSession.GenerationInputAsync` runs the shared geometry-only `ValidatePlacement` against the locally edited project before reading source audio or preparing a takes quote; a predictable refusal appears inline. The returned fitted window is checked again before any take is published. Provider QA, generated alignment/duration and the resulting asset/recipe data can only be checked after generation. Take provenance stores the endpoint as a relative `v1/...` path so a provider receipt's leading slash does not cause a later acceptance refusal.

---

## 9. Lip sync

ElevenLabs has no video-to-video lip-sync API. Its `POST /v1/flows/video` takes only image-driven and generative models. Lip sync therefore uses a second provider.

### 9.1 Provider interface

```swift
public enum LipsyncTier: String, Codable, Sendable { case fast, quality, best }
public struct LipsyncModel: Codable, Hashable, Sendable {
    public var provider: String          // "fal" | "syncso"
    public var id: String                // "fal-ai/latentsync", "fal-ai/sync-lipsync/v2:lipsync-2", "syncso:sync-3", …
    public var tier: LipsyncTier
    public var supportsRemap: Bool       // can handle audio/video duration mismatch
}
public enum SyncMode: String, Codable, Sendable { case cutOff = "cut_off", remap }
public struct LipsyncOptions: Codable, Sendable { public var syncMode: SyncMode; public var seed: UInt32? }
public struct LipsyncJob: Codable, Sendable {
    public var model: LipsyncModel
    public var remoteID: String
    public var statusURL: URL?; public var responseURL: URL?; public var cancelURL: URL?   // fal
    public var uploadedAssetIDs: [String]                                                  // sync.so cleanup
    public var submittedAt: Date
}
public enum LipsyncState: Sendable { case queued(position: Int?), running(progress: Double?), done(URL), failed(code: String, message: String) }

public protocol LipsyncProvider: Sendable {
    var id: String { get }
    var models: [LipsyncModel] { get }
    func estimate(_ model: LipsyncModel, seconds: Double, fps: Double) async throws -> CostEstimate
    func submit(_ model: LipsyncModel, video: URL, audio: URL, options: LipsyncOptions) async throws -> LipsyncJob
    func poll(_ job: LipsyncJob) async throws -> LipsyncState
    func cancel(_ job: LipsyncJob) async
    func download(_ result: URL, to file: URL) async throws
    func cleanup(_ job: LipsyncJob) async          // delete uploads where the API allows; never throws
}
```

```csharp
public enum LipsyncTier { Fast, Quality, Best }
public sealed record LipsyncModel(string Provider, string Id, LipsyncTier Tier, bool SupportsRemap);
public enum SyncMode { CutOff, Remap }
public sealed record LipsyncOptions(SyncMode SyncMode, uint? Seed);
public sealed record LipsyncJob(LipsyncModel Model, string RemoteId, Uri? StatusUrl, Uri? ResponseUrl, Uri? CancelUrl,
                                IReadOnlyList<string> UploadedAssetIds, DateTimeOffset SubmittedAt);
public abstract record LipsyncState {
    public sealed record Queued(int? Position) : LipsyncState; public sealed record Running(double? Progress) : LipsyncState;
    public sealed record Done(Uri Result) : LipsyncState;     public sealed record Failed(string Code, string Message) : LipsyncState; }
public interface ILipsyncProvider {
    string Id { get; }
    IReadOnlyList<LipsyncModel> Models { get; }
    Task<CostEstimate> EstimateAsync(LipsyncModel model, double seconds, double fps, CancellationToken ct);
    Task<LipsyncJob> SubmitAsync(LipsyncModel model, string videoPath, string audioPath, LipsyncOptions options, CancellationToken ct);
    Task<LipsyncState> PollAsync(LipsyncJob job, CancellationToken ct);
    Task CancelAsync(LipsyncJob job);
    Task DownloadAsync(Uri result, string path, CancellationToken ct);
    Task CleanupAsync(LipsyncJob job);
}
```

### 9.2 Models

| Tier | fal.ai (default provider: one key covers every model) | sync.so (direct) |
|---|---|---|
| **fast** (default) | `fal-ai/latentsync`: ByteDance LatentSync, Apache-2.0. Equal durations only (`supportsRemap = false`) | — |
| **quality** | `fal-ai/sync-lipsync/v2` with `model: "lipsync-2"` | `lipsync-2` |
| quality+ | `fal-ai/sync-lipsync/v2` with `model: "lipsync-2-pro"` | `lipsync-2-pro` |
| **best** | `fal-ai/sync-lipsync/v3` (sync-3) | `sync-3` |

Settings → Voice Lab → Lip sync has two choices: the provider (fal.ai, sync.so) and the tier (Fast, Quality, Best). When the window's duration changed (`remap` is needed), a model without `supportsRemap` is skipped in favour of the next tier, after confirmation.

### 9.3 Window procedure

1. **Window.** `L = [seamIn − 1.0 s, seamOut + 1.0 s]`, clamped to the take and at least 3 s long. The handles give the model speaking motion; lipsync-2 works in 2 s chunks.
2. **Face check.**
   - Sample one frame every 0.5 s across `L`. Detect faces with Vision on macOS or `FaceDetector` on Windows.
   - Require a face in at least 80% of the samples, with the largest face at least 8% of the frame height.
   - Otherwise lip sync is unavailable: "No clear face in this part. Use zoom cover instead."
3. **Mezzanine.**
   - Video: H.264 High at the source resolution and frame rate, with a bitrate of `0.33 bits × pixels × fps` (≈ 20 Mbps at 1080p30) and a keyframe every second. Use AVAssetWriter on macOS and the encoder ladder on Windows. There is no audio track.
   - Audio: 16-bit WAV, 48 kHz mono, of the **final mixed audio** of `L`: the source handles plus the patch.
4. **Submit.** Use `sync_mode = "cut_off"` when the window duration is unchanged, and `"remap"` when it changed.
5. **Download** the result immediately, because result URLs expire. Then conform it:
   - Probe the result, and scale it to the window's size if it differs.
   - Compare the mean luma of the first frame with the source frame at the same time. If it differs by more than 8 code values on average, try a full/limited range conversion. If it still differs, show the warning "The lip-sync clip's colours differ slightly."
6. **Replace frames** only inside `[seamIn − 0.2 s, seamOut + 0.2 s]`, with a 3-frame crossfade to the source frames at both ends.
7. **Store** the result as the segment's `video.mode = "lipsync"` with its asset and provenance (§10.1). Then call `cleanup`.

### 9.4 fal.ai flow

1. **Upload** the mezzanine and the WAV:
   - `POST https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3` with header `Authorization: Key <key>` and body `{"file_name":"window.mp4","content_type":"video/mp4"}`. The response is `{upload_url, file_url}`.
   - `PUT <upload_url>` with the bytes and the same `Content-Type`.
   - The fal SDKs document CDN uploads, but this REST initiate path is not on fal's current public CDN page. Spike S8 verifies the path, and also the lifecycle header that limits retention of the uploaded files (`X-Fal-Object-Lifecycle-Preference`; the documented default is no expiry).
2. **Submit** with `POST https://queue.fal.run/<endpoint>` and a JSON body. The response is `{request_id, status_url, response_url, cancel_url, queue_position}`.

   | Endpoint | Body |
   |---|---|
   | `fal-ai/latentsync` | `{"video_url": …, "audio_url": …, "guidance_scale": 1.0, "seed": <seed>}` |
   | `fal-ai/sync-lipsync/v2` | `{"video_url": …, "audio_url": …, "model": "lipsync-2" \| "lipsync-2-pro", "sync_mode": "cut_off" \| "remap"}` |
   | `fal-ai/sync-lipsync/v3` | `{"video_url": …, "audio_url": …, "sync_mode": "cut_off" \| "remap"}` |

   Always use the returned URLs. Follow-up paths contain only `owner/app`, and building a path from the full model id returns 405.
3. **Poll** `GET <status_url>` every 5 s. After 2 minutes, poll every 15 s.
   - Statuses are `IN_QUEUE` (with `queue_position`), `IN_PROGRESS` and `COMPLETED`.
   - `error` or `error_type` means the job failed.
   - The deadline is 30 minutes, then cancel.
4. **Fetch the result** with `GET <response_url>` and read `video.url`.
5. **Cancel** with `PUT <cancel_url>`:

   | Response | Meaning |
   |---|---|
   | 200 `OK` | removed |
   | 202 `CANCELLATION_REQUESTED` | the job may still finish and bill |
   | 400 `ALREADY_COMPLETED` | it already finished |

6. **Retries.** A submit is retried only after an explicit 429 or 5xx response, never after a timeout, because a lost response may still have started a billed job.
7. **Cleanup** after the download, or after a terminal failure or cancel:
   - `DELETE https://api.fal.ai/v1/models/requests/{request_id}/payloads` removes the request payloads and output files.
   - `POST https://rest.fal.ai/storage/files/delete` removes each uploaded input file.

### 9.5 sync.so flow

1. **Upload** each file:
   1. `POST https://api.sync.so/v2/assets/upload` with `{fileName, contentType, size}`. The response is `{uploadUrl, url, expiresIn}`.
   2. `PUT <uploadUrl>` with the bytes and the same `Content-Type`.
   3. `POST https://api.sync.so/v2/assets` with `{url, type: "VIDEO" | "AUDIO", name}`. The response gives the asset `id`.
2. **Submit:**
   ```
   POST https://api.sync.so/v2/generate
   x-api-key: <key>
   Idempotency-Key: <UUID per window job; reused on retry>
   { "model": "lipsync-2" | "lipsync-2-pro" | "sync-3",
     "input": [ { "type": "video", "assetId": "<id>" }, { "type": "audio", "assetId": "<id>" } ],
     "options": { "sync_mode": "cut_off" | "remap" },
     "outputFileName": "voxclip-<segmentId>" }
   → 201 { "id": "…", "status": "PENDING", … }      (200 + Idempotency-Replayed: true on a keyed replay)
   ```
3. **Poll** with `GET https://api.sync.so/v2/generate/{id}?include=progress` every 5 s; after 2 minutes, every 15 s. The API accepts either `wait=true&timeout≤10` or `include=progress`, not both together. Progress needs `include=progress`, so VoxClip does not use `wait`.
   - Statuses: `PENDING`, `PROCESSING`, `COMPLETED` (with `outputUrl` and `outputDuration`), `FAILED`, `REJECTED` (with `error` and `errorCode`).
   - The deadline is 30 minutes.
4. **Errors.** A 429 with `errorCode: concurrency_limit_reached` waits `retryAfterSeconds` and retries with the same Idempotency-Key. Other error bodies show `message` and `suggestion`.
5. **Cleanup** after the download: `DELETE https://api.sync.so/v2/assets/{id}` for both assets, then `DELETE https://api.sync.so/v2/generations/{id}`. The generation can be deleted only in a terminal state; while processing it returns 409 `generation_not_deletable_while_processing`.
6. **No cancel.** sync.so has no cancel endpoint. [Cancel] stops polling only, and the job still finishes and bills. While a sync.so job runs, the progress row says "sync.so will finish and bill this job." VoxClip deletes the generation and assets once the job reaches a terminal state, on the next launch if needed.
7. **Watermarks.** sync.so's pricing page lists "No watermark" from the Creator plan up, and a sync.so blog page says output is watermark-free on all paid plans. Spike S8 checks the lowest plan. Until then, before the first sync.so job, show "sync.so may add a watermark on its lowest plan."

### 9.6 Concurrency

One lip-sync job per provider at a time, queued. Progress shows "Lip sync · queued (3)" → "Lip sync · 40%" → "Lip sync · downloading", with [Cancel].

Local result import uses a private `.partial.mp4` stage so AVFoundation recognizes the container before publication. Bounded copy, self-contained container checks, H.264 metadata validation, hash binding, cancellation and no-clobber publication remain mandatory. A successful service import does not enable the editor's lip-sync render route.

---

## 10. Data model: AI segments in the edit plan

### 10.1 Version 2 project representation (ADR-R24)

`schemaVersion: 1` continues to require exactly `voiceLab: {"segments": []}`. A project that stores generated media may use `schemaVersion: 2` and a `voiceLab` object with required `assets` and `segments` arrays. An ordinary project is not rewritten to v2 merely because the app understands this format. Both native Core serializers retain unknown reverse-DNS `extensions` when they load and save all supported versions. Current readers accept versions 1–4 and reject version 5 or later. Version 4 adds the explicit context-demo and motion fields described in `context-demo.md`; it retains the v3 Voice Lab policy.

A v2 asset is `{id, kind: "audio", file, sha256, durationSeconds, sampleRate, createdAt}`. `file` is a relative `<projectId>/<assetId>.wav` or `.flac` name under the paid VoiceLab store. Asset IDs used as file components contain only lowercase ASCII letters, digits, `_` and `-`; Windows device names (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, `lpt1`–`lpt9`) are rejected. There is no colon, trailing dot/space, absolute path, URI, parent traversal or backslash path. A project carries no audio bytes, credentials, or consent-statement recording. Assets are immutable paid outputs and delete/disable operations do not erase them. A media adapter must resolve the store path, verify SHA-256 and duration before rendering; this Core round only validates the reference and plans pieces.

**Explicit upgrade and asset naming (2026-10-26).** `VoiceLabProject.upgradeToV3` (Swift `upgradeToV3(_:)`, C# `UpgradeToV3(project)`) is the only promotion between versions. Loading and saving never call it.

It validates the input first, then:
- A version 1 project, or a version 2 project without segments, becomes version 3 with `voiceLab` = `{assets, segments: [], cleanAudio: {mode: "off", assetId: null, mix: null}, voices: [], videoAssets: []}`. A version 2 project keeps its assets.
- Every other field is unchanged, including the transcript, word times, edits, captions, share text, export settings and reverse-DNS extensions.
- A version 2 project with any segment, enabled or disabled, throws `legacySegmentsNeedReview`.
- A version 3 project is returned unchanged.

Accept upgrades a version 1 or segment-free version 2 project before it appends, so it never writes version 2. A recipe-less segment therefore fails version 3 validation with `missingRenderPolicy`, because it lacks the scope and recipes of §10.5, instead of creating a version 2 project.

`VoiceLabAssetNaming.file(projectId:assetId:extension:)` (C# `VoiceLabAssetNaming.File(projectId, assetId, fileExtension)`) states the asset file rule above once. Given a lowercase canonical project UUID, a safe asset ID and the exact extension `wav` or `flac`, it returns `<projectId>/<assetId>.<extension>`. Otherwise it throws `invalidAsset`. Media writers name new paid assets with it.

Core validation applies the same rule in two places:
- It checks every stored asset file and reports `unsafePath` when the stored name differs.
- It names each §10.5 video asset `<projectId>/<videoAssetId>.mp4` and reports `invalidAsset` when that name differs.

A v2 segment has `{id, kind, enabled, replace, outDuration, audio, text, words, provenance, qa, candidates, selectedCandidateIndex}`. `kind` is `tts` or `voiceChanger`. `replace` has source seconds `start` and `end` plus `firstWordId` and `lastWordId`; this round supports positive-length passage and full-take replacement. Insertion (`afterWordId` and a zero-length source range) is reserved for a later version with an explicit inverse mapping rule. `audio` identifies the selected asset, trim bounds, stretch and gain. `outDuration` must equal the trimmed asset duration times stretch within one asset sample. `candidates` retain their asset IDs, score and rejection reason; the selected index must name an unrejected candidate and match `audio.assetId`. `provenance` records provider endpoint name, model, voice ID, optional consent **record ID**, optional request ID, optional seed and creation time. `qa` has optional transcript match, loudness jump, peak and speaker score. All persisted numbers must be finite.

For `tts`, `text` contains original and new spoken text and `words` contains positive, ordered times relative to the output start, each with a `synthetic` flag. In version 2 only, `synthetic: false` marks a bridge word whose text was kept although its audio was re-voiced. In version 3 recipes every TTS word, bridge words included, is `synthetic: true` (§8.8, §10.5). `voiceChanger` stores `text: null` and `words: null`; captions retain the source words. This v2 object is the first audio-only project format, not the final Voice Lab schema.

In v3/v4, an unranked `voiceChanger` candidate may store `score: null`; its exact recipe, measured loudness and peak remain required. Conversion does not invent a TTS ranking, transcript match or speaker score. TTS candidates and legacy v2 candidates still require a finite ranking score when unrejected.

**Historical v2 omissions.** Version 3 now specifies these fields in §10.4. Version 2 does not imply defaults for any omitted field:

| Area | Required later representation or behavior |
|---|---|
| Voice and clean audio | `voiceLab.cleanAudio` and owned `voices` with consent record ID, provider, voice ID and display name (§4.7, §6.8). A project stores no consent statement recording. |
| Audio assembly | `audio.roomTone` with source start/end and gain (and an optional `endGainDb`, the bed's gain at the window's end, §8.7 item 3), null when Clean audio is on; `audio.seamFadeMs` with in/out values. Generated seams use equal-power fades, not the ordinary 5 ms join fade (§8.7, §8.10). |
| Voice changer | `audio.chunks: [{sourceStart, sourceEnd, requestId}]`, the `eleven_multilingual_sts_v2` model and the seed used for every chunk (§7.2–7.3). The v2 audio record cannot describe or schedule these chunks. |
| Video and lip sync | Video assets need duration, frame rate, width and height. Segment `video.mode` needs `source`, `zoomCover`, `retimed` and `lipsync`; zoomCover stores zoom and source-frame retime. Lip sync stores asset ID, provider, model, request ID, source window start/end, replacement start/end and sync mode. Source mode uses original frames; zoomCover uses the stored face centre; lip sync uses its generated frames and three-frame crossfades (§8.9, §9). |
| Generation record | Each candidate needs its seed alongside asset ID, score and rejection; provenance needs selected candidate index and cost in USD as well as provider/model/request metadata (§3, §8.6). The v2 index selects an asset but cannot reconstruct those missing details. |
| QA and disclosure | Apply the transcript, loudness, peak and speaker QA gates (§8.11). Derive per-export AI kinds and duration, visible disclosure and provenance output (§11); do not infer finished disclosure from v2 captions alone. |

Core validation rejects missing/dangling assets, duplicate IDs, unsafe files, malformed or out-of-bounds ranges, source words crossing a replacement seam, conflicting enabled replacements, invalid candidates, nonfinite values and invalid relative word timing with typed Voice Lab errors. Disabled segments remain saved, but do not replace source. Asset existence and hash checking belong to the Media preparation boundary in §10.4; missing assets must stop a synthetic render rather than silently play original audio.

Replacing the source transcript clears segments whose word IDs and ranges belonged to the old transcript, while retaining the paid asset list. A later workflow can offer explicit reattachment; this round does not guess a match from new timings.

### 10.2 Deterministic output pieces

`VoiceLabOutputPlanner.build(project, scope)` in each Core has explicit `full` or `clip(id)` scope. Full scope ignores `edits.activeClipId`. It returns ordered `source` and `synth` output pieces with half-open source and output sample bounds, derived duration, source/edited mapping and caption words. Replacement bounds and `outDuration` are rounded with the existing JavaScript half-up sample rule at the source audio rate. Source word times and stored cuts never change.

Mapping probes round to that sample grid before lookup. As in the existing `EditPlan`, `sourceTime(output duration)` returns the full source duration even for a selected clip whose last output piece ends earlier; probes within the output use the selected pieces. This endpoint convention preserves existing clip callers while the explicit piece bounds identify the actual last included source sample.

Enabled replacements may touch at a seam but cannot overlap. An enabled range covers source words fully inside it; their individual cuts and corrections are dormant while enabled. A cut from a neighboring word or pause stops at the synthetic seam. A clip may fully include or exclude a replacement, but a clip boundary through one is rejected as an invalid scope. Source intervals outside replacements retain the existing subtractive edit plan, including cuts, pause breath and clip range behavior. Disabling or deleting the segment restores that plan and its original source captions. A synthetic output piece contributes its rounded `outDuration`; source-to-edited and edited-to-source positions inside it interpolate linearly between its rounded bounds. Source captions within `voiceChanger` pieces follow that mapping, with the original source text. `tts` captions use the relative output word times. Core's `requireLegacyRendering` capability check throws for any active synthetic piece; old `EditPlan`-only Media, app and CLI consumers must call it before preview/export until they render these output pieces. There is no source-only fallback for active synthetic audio. Legacy callers enforce this check for their explicit scope; the reviewed v3 App/export paths in §10.5 use the prepared contract instead. Both legacy CLI plan commands still enforce it. An included replacement returns “This build cannot preview or export generated voice segments yet. Your video and edits are still here.” CLI reports `exportFailed` with exit 5 before encoding or creating output files. A source-only clip that excludes all enabled replacements and a project with only disabled replacements continue through the ordinary renderer.

The shared `passage-project.voxclip`, `full-take-project.voxclip` and `plan-cases.json` fixtures under `shared/fixtures/voice-lab/` are generated by `tools/fixtures/voice-lab/generate.py` and consumed by both native Core tests. The separate `project-plan-README.md` describes them; `README.md` describes `contract.json`. `contract.json` is written by `tools/fixtures/voice-lab/generate_contract.py`, which reproduces its hand-written tables byte for byte and adds the `rewriteMutations` rows for `targetSeconds`, `minChars` and `maxChars` (§8.9.1). `generate.py` also writes `fit-cases.json` through `generate_fit.py` (§8.9.2), and `fit-README.md` describes it. They contain no provider output or binary media.

### 10.3 Undo

Accept, turn off, turn on, delete, choosing another candidate, and changing the lip-sync tier are each one undo step. Undo and redo restore the exact project snapshots, including `modifiedAt`, and preserve the document's prior clean or dirty count. Undo never deletes assets. Unreferenced assets are removed when the project is closed, after 7 days.

The passage workflow keeps strict output-scope acceptance after applying the review's local cuts and corrections. Before decoding source for a takes quote, `RewriteSession.prepareTakes` checks that known window against the same final review. `RewriteGenerationSession.prepare` repeats that check before preparing the provider quote. `VoiceLabRenderContract.validatePlacement` projects the window through the same output-piece builder, stored-recipe policy checks and selected-seam validator used by acceptance; it creates no recipe, asset or consent record. A predictable scope, overlap or surrounding-source fade failure is shown inline and no quote or paid send proceeds. The seam message is "This change can't blend beside the proposed cuts. Keep more of the surrounding speech or re-record this sentence. Your edits are saved."

Fit can borrow silence and move a boundary; generated duration, QA, alignment, returned media, receipt and consent validity cannot be known from the text/window alone. Returned fit geometry is checked again before publication, and final recipes still pass strict acceptance. These result-dependent failures can therefore still refuse a paid take; the preflight never promises QA or a successful generated asset. V15/V19 must apply this preflight to their included windows and complete local review before offering the inline takes price; multi-window staging remains their integration work.

Mac W5 stages these actions behind DEBUG until W6. `VoiceLabRecipeBuilder` builds the candidate from the fitted publication, fit analysis, QA, consent reference, receipt and quote without I/O. It uses the published unity asset, keeps original paid chunks, records relative synthetic words and source-grid video/seam policy, and refuses failed QA or changed-duration acceptance without supported explicit video treatment. Retimed output is bounded by the v3 0.80–1.25 speed range; a lip-sync choice alone is not a rendered video asset and cannot be accepted. `RewriteGenerationSession.accept` reserves acceptance before publication, revalidates its input revision and project snapshot after each suspension, and applies `VoiceLabEditCommand` through the document's single native undo transaction. Failed or stale publication never changes the project. Other fitting candidates with the same widened source window are retained; candidates requiring an unapproved length treatment or a different window are not silently substituted.

`Domain/Editing/EditingContracts.swift` defines the `VoiceLabEditCommand` acceptAll, single accept, setEnabled, delete and chooseCandidate project-value transitions and their scope-free action names. The app registers exactly one whole-project inverse for each successful command or scoped set; a set uses its caller-supplied Rewrite scope name, never a Full take default. Windows W2b mirrors the command variants, validation, asset conflict/deduplication rule and one-step project/asset-reference/dirty-state undo semantics; this does not alter the shared project schema or source timings.

The specification does not define an undo-history expiry or authorize collecting catalogued assets after a segment is disabled, deleted or undone. Mac therefore conservatively retains every asset listed in any project snapshot observed by the document, persists that protection in the project's private `.asset-retention.json`, and never ages it out. Complete unlisted WAV/FLAC/MP4 assets discovered at launch are paid data, permanently protected rather than automatically collected in 0.1.0. Other unreferenced candidates observed at close get a persisted discovery timestamp and `lastObservedAt`, not their creation or modification date. Only project close can delete them, at seven days or later. A wall time earlier than any recorded timestamp, a forward jump exceeding 24 hours beyond monotonic elapsed time within one session, or loss of monotonic continuity at a process restart restarts grace. An open sibling document defers deletion. Cleanup holds the publication lock, pins directories, skips symlinks and unrelated names, and rechecks references and file identity immediately before every deletion. Corrupt retention metadata refuses cleanup. A narrower catalog/history retention horizon remains a lead decision, not an inferred destructive policy.

Accepted transcript text is presentation-only: its stored synthetic words replace the covered source words in the text view, with the AI chip and a one-pixel dashed accent underline. The underlying transcript and timings remain unchanged. Turning the segment off reveals the original source text. Sidebar scope metadata, viewer/stage, the visible Export sheet disclosure and export accessible names disclose enabled AI speech even if local media is unavailable; Full Take does not inherit the active clip's scope. Asset preflight failures are separate errors, never a reason to hide the disclosure. The DEBUG Use Take footer closes Rewrite and returns focus only after successful acceptance. The privacy panel lists all six §12 data rows and QA audio. Native accept/transcript captures remain lead-owned gates.

The v2 Core functions return new project values for accept, enable/disable, delete and candidate selection. They do not register app `UndoManager`/`EditHistory` steps. Mac W5 adds the app undo wiring and conservative cleanup above; Windows app wiring and lip-sync tier changes remain integration work. No Core transition deletes a paid asset.

Since 2026-10-26, accept upgrades a version 1 or segment-free version 2 project to version 3 before appending (§10.1), so the result is always a version 3 project. Accept still returns a new value, and the earlier value restores the project byte for byte. `upgradeToV3`, `addVoiceReference` and `markVoiceDeleted` are likewise pure values without I/O or undo registration.

### 10.4 Paid-audio Media boundary (2026-10-26)

Mac `VoiceLabAssets.prepare(project:plan:paidRoot:)` and Windows `VoiceLabAssets.PrepareAsync(project, plan, paidRoot, cancellationToken)` validate the project through Core and prepare only `synth` pieces in the explicit full or clip plan. Before preparation, Media rebuilds the plan from the current project and selected scope and requires its sample grid, ordered pieces and captions to match; a changed caption correction invalidates an earlier plan even when audio pieces are unchanged. Results are keyed by segment ID, so two segments may select the same paid asset with different trims. A prepared handle gives the selected asset ID, a private audio snapshot URL/path, decoded sample rate, channels and frame count, half-open trim frames, stretch and gain. Trim seconds use JavaScript half-up rounding on the **asset's** sample grid. Core already owns the piece's source/output bounds and verifies its `audio.assetId` against the selected candidate; Media checks the selected file bytes before composition. The caller retains the handle through preview/export and releases it afterwards; release removes only the private snapshot, never the paid file.

The caller supplies the paid Voice Lab root. A v2 `asset.file` remains exactly `<projectId>/<assetId>.wav` or `.flac`; it is resolved below that root, with symlink/reparse escapes rejected. Mac uses `O_NONBLOCK` when opening the final file and rejects nonregular files before reading, so a named pipe cannot stall preparation. Media streams the paid file into a private snapshot while computing SHA-256. It decodes and checks that snapshot, and future composition must consume **that same snapshot**, closing the path swap between validation and rendering. It rejects missing, altered, unreadable, unsupported, malformed, wrong-rate or wrong-duration audio with typed errors before a synthetic render. Lengths are bounded to 8 GiB, 24 hours of 192 kHz samples, 1–8 channels and 8–192 kHz; decoded duration may differ from the stored duration by at most one native sample. Cancellation removes only incomplete snapshots. No failed check substitutes source audio.

macOS uses AVAudioFile for WAV and for FLAC when the installed Core Audio decoder can open it; unsupported codec data fails with `unsupportedFormat`. The current pinned Windows runtime has no FLAC decode/container path (`tools/ffmpeg-build/components.md`), so Windows returns `UnsupportedFormat` for `.flac`. Its portable Media boundary validates RIFF/WAVE PCM16/24/32 or IEEE float32/64 samples and rejects other WAV codecs as unsupported. Windows-native reparse and decoder acceptance still need a Windows run before a release claim. The paired tests generate the same 24 kHz mono PCM16 tone in code; no generated voice or provider output is a fixture.

Mac `EditorModel`, `CLIWorkflow` and `CompositionBuilder`, and Windows `EditorViewModel`, `CliOperations` and Media preview/export now use the request-bound v3 path in §10.5. They retain prepared handles and use `VoiceLabOutputPlan.pieces` for mixed source/synth composition. Older recipes and unsupported capabilities remain refused. This boundary does not add v2 fields for room tone, seams, video retiming, consent, disclosure or lip sync. Version 3 defines those explicit recipes in §10.5; native composition and workflow gates remain required before an enabled replacement can render.

At launch, before writing paid or fitted audio, Mac recovery deletes only store-owned, regular `.partial` files older than the operating system's process-start timestamp. The exact temporary naming convention, no-follow descriptors and a shared inter-process writer/recovery lock protect active writers and unrelated files. Complete unlisted assets are paid data, never startup garbage or automatically deleted after discovery.

### 10.5 Version 3 render recipe and preparation (ADR-R26)

**Accepted join advisory (3 November 2026).** Version 3 and 4 render-recipe QA may carry optional `joinAdvisory: {seams: [{side, excessLu}], acceptedAt}`. Omit the field when absent, never write null. `seams` contains one or two entries with distinct `side` values `left` or `right`; each `excessLu` is finite and greater than 2. The maximum equals the recipe's `qa.lufsJumpLu`. `acceptedAt` is a UTC timestamp no later than provenance `createdAt`, set only by the take's explicit **Use anyway** action. Both Cores read, preserve and validate it; render preparation and export accept the loudness excess only with this evidence. Missing acceptance retains the <=2 LU render rule. Invalid evidence is refused even on an unselected stored candidate. No evidence relaxes words, clipping, speaker, consent or disclosure validation. Old projects without this field decode unchanged. Shared vectors live in `join-advisory-cases.json`; Windows generation and inline advisory selection are twin obligations, not implied by reader support.

**Short-speech reader evidence (2026-11-02, ADR-R37 Mac contract).** Both version 3
and version 4 recipe QA may carry `shortSpeech`, omitted rather than written as
null when absent. Its exact keys are `mode`, `recordId`, `consentMethod`,
`voicedFrames` and `takeCount`. Modes are `pooled` and `unmeasured`; consent
methods are `recordedStatement` and `projectAttestation`. The record ID is
nonempty and matches the recipe's provenance consent record and the own-voice
reference when rendering. Evidence is never valid for a stock voice, including
on rejected stored candidates. Counts are nonnegative integers, with at least
one take. Pooled evidence needs at least 48,000 voiced 16 kHz frames and two
takes; unmeasured evidence has fewer than 48,000 frames.

Own-TTS pooled evidence retains the measured speaker score, passing flag,
threshold and model requirements. An unmeasured own-TTS recipe instead requires
a null speaker score, `speakerPassed: false`, a finite threshold in [0, 1] and
a nonempty speaker model. Word, acoustic, consent, asset and video guards remain
unchanged; absence of evidence never permits an unmeasured recipe. Stored assets
remain renderable after voice deletion. Windows reader/validator/render-preparation
parity does not change `VoiceLabTakeRun`: short-take generation still refuses
insufficient speech and pooled/unmeasured generation support remains owed.
The isolated `short-speech-recipe-cases.json` corpus pins this wire contract.

Version 3 adds explicit `voiceLab.cleanAudio`, `voices`, and `videoAssets` and requires every unrejected candidate to carry a complete `recipe`. `cleanAudio` records `off` with null asset and mix, or `on` with an asset and mix; Core reports `cleanAudioUnsupported` for active non-null use until Media implements it. A segment records `scope: passage | fullTake`; a full-take group covers the take without the patch 15%/60-word budget. Candidate recipes record asset trim, fit factor, gain, relative words (every TTS word `synthetic: true`, bridge words included), bounded source and assembled chunk spans with request IDs and seeds, room tone or explicit null, in/out seam policy, tagged video mode, applicable QA, provenance, cost quote and own/stock voice source. `usd: null` means the price was unknown. The source transcript, word times, cuts and reverse-DNS extensions remain unchanged. No v2 segment is promoted automatically; recovery needs explicit future per-segment review.

`VoiceLabRenderContract.prepare(project, scope, labelPosition)` uses `VoiceLabOutputPlanner` as the sole source of ordered pieces, mapping and captions. It returns an immutable selected-recipe snapshot and `VoiceLabDisclosurePlan` for that exact project, scope and position; downstream consumers must call `verify` before using it. Full ignores `activeClipId`; a clip cannot bisect an enabled replacement. Disabled and excluded replacements remain source-renderable. Candidate selection transfers the complete validated candidate recipe into segment fields, and accept/enable/disable/delete remain reversible project transitions that never delete paid assets. New own-voice acceptance requires an active consent reference; a previously accepted asset remains playable after voice deletion because rendering uses its stored consent evidence, not a provider lookup or a new speaker match. A record is evidence of generation/accept review, not speaker verification by itself.

**Voice references (2026-10-26).** `addVoiceReference` adds an own-voice reference to a version 3 project, and `markVoiceDeleted` sets an existing one to `deleted`. Both refuse version 1 and 2 projects with `requiresVersion3`, and both return a new project without changing segments or assets.

A new reference must meet every condition below; any violation throws `invalidVoice`:

- an ID and consent record ID that follow the Voice Lab ID rule, with the ID unique in the project;
- provider `elevenlabs`;
- a voice ID of 1–128 ASCII letters, digits, `_` or `-`, matching the provider client's path-safe rule;
- status `active`;
- a display name of 1–60 Unicode scalars after trimming Unicode whitespace; the trimmed name is stored (§6.1);
- no other active reference with the same provider and voice ID. A deleted reference does not block it.

Marking a missing ID throws `missingVoice`. Marking an already deleted reference returns an equal project. Deletion never removes the reference, a segment or an asset.

Earlier own-voice segments still validate and prepare with their stored consent evidence. Accept, however, requires every unrejected own-voice candidate in the segment to name an active reference, selected or not, and throws `consentUnverified` otherwise. A rejected candidate cannot be selected, so it needs no active reference. Candidate selection does not check voice status: a take accepted while consent was active stays selectable and renderable after deletion.

A loaded project whose references share an ID fails with `consentUnverified`, the code for every other defect in a single reference. These transitions are pure values without I/O or undo registration (§10.3).

**Stored recipe shape (2026-10-26).** Version 3 validation checks the project schema shape of every stored recipe, rejected or not, of any kind or voice source. The check includes:

- ID and SHA-256 patterns;
- non-empty chunks, region, endpoint, model and voice ID;
- the provenance provider pattern `[a-z0-9-]+`;
- the cost quote ID, and a `usd` that is null or at least 0;
- finite numbers;
- non-negative counts and sample positions;
- `transcriptMatch`, `speakerScore`, `speakerThreshold`, `faceX` and `faceY` within [0, 1];
- a non-empty `speakerModel`, video provider and video model when present;
- `syncMode` null or `remap`.

For each candidate in order, an unrejected candidate first passes render policy, then every stored recipe passes the shape check; the first failure is reported, and a shape failure is `invalidSegment`. Accept therefore never returns a project that fails `project.schema.json` or cannot be written as JSON.

Render policy also refuses an unrejected candidate whose provenance endpoint contains `://`, with `invalidSegment`. Selecting that candidate would copy the endpoint into the segment, whose provenance rule refuses it with the same code.

Every saved `video` object carries all 15 keys, with `null` for the fields its mode does not use. The schema and both platforms' project readers require every key, explicit `null` included (architecture §2.1 rule 8). Files written by development builds before 2026-10-26 that omit these keys are refused.

The shared cases are `shared/fixtures/voice-lab/upgrade-cases.json`, generated by `tools/fixtures/voice-lab/generate_upgrade.py` and described in `upgrade-README.md`.

Every unrejected recipe, unity or nonunity, selected or not, must also satisfy the selected segment's content-duration rule: `abs((trimEnd − trimStart) × audio.stretch − outDuration) ≤ 1 / assetSampleRate`. Each Core uses one shared helper for the project and render-validator checks; failure is `invalidSegment`. Passing either baseline below does not waive this rule. `unity-inconsistent-alternate` in `render-cases.json` pins a valid selected candidate and an unrejected alternate whose 96,292 content frames at 96 kHz exceed its declared 1.003 s by four frames, with an 8 kHz source and replacement [1.5000416666666667, 2.503]. Both validators refuse the alternate before it can be saved or selected; rejected candidates retain their shape-only check.

For a unity recipe (`audio.stretch == 1`), validation compares content on the asset frame grid, not a binary64 duration ratio: `jsRound(trimEnd × a) − jsRound(trimStart × a) == outputFrames`. Let `windowFrames = jsRound((samples(replace.end) − samples(replace.start)) × a / sourceRate)` and `windowDuration = replace.end − replace.start`. The recipe ties `outDuration` to the content with `residualFrames = jsRound((outDuration − windowDuration) × a)`, `outputFrames = windowFrames + residualFrames` and `outDuration = windowDuration + residualFrames / a`, allowing at most four ULPs of the larger duration for arithmetic roundoff. Exact fits have zero residual frames; partial fits use the planner's residual frames. Validation first tries these equations with the binary64 baseline `replace.end − replace.start`. Only if that fails, and `outDuration` is exactly `samples(outDuration) / sourceRate` (an existing source-grid recipe), it tries them with `(samples(replace.end) − samples(replace.start)) / sourceRate`. Every recipe may satisfy the binary64 baseline; a bitwise source-grid duration does not choose the baseline. Vectors: `unity-binary64-residual-eight`, `unity-binary64-residual-nine` and `unity-legacy-source-grid-only` in `render-cases.json`. New fitted recipes always use the binary64 seam-time subtraction in §8.9.3. Nonunity stored recipes must satisfy the same one-asset-frame content-duration check as unity recipes, in addition to their duration-ratio and `STRETCH_OK` checks; Media still refuses them (ADR-R30).

All source intervals use JavaScript half-up rounding on the source sample grid; trim and handle frames use the asset sample grid. A centered N-frame seam has left half `floor(N/2)` and right half `N − floor(N/2)`. Equal-power gains use `u = i/(N−1)` for `N ≥ 2`, with exact endpoints. Stored gap seams use 20 ms and hard seams 12 ms; real take edges use explicit `none`. Every gap or hard seam's centred fade lies inside the take, its outer half lies in the kept source beside the seam, and the window holds both inner halves (§8.4 step 5). Window placement refuses a hunk that cannot meet these with `seamFadeOutsideTake`, `seamFadeCrossesCut` or `windowTooShort`, and one beside another enabled replacement that cannot keep both pieces' fades with `overlapsReplacement` or `adjacentReplacement` (§8.4 step 6). A scope where one replacement's seams already fail prepare's rule (§8.4 step 6) is refused with `invalidInput` and that replacement's ID. So in a scope that validates and prepares without the new window, every window it returns also validates and prepares, including with other enabled replacements, and a replacement whose fade a later cut has crossed, which prepare still renders, does not block a window elsewhere. Touching synth pieces share one agreeing seam. Missing handles, a fade shorter than two frames, a clip ending on an internal seam, or overlapping windows fail preparation without shortening a fade or swallowing even a one-sample source gap. Ordinary source cut joins retain their separate 5 ms linear fade. Passage TTS with Clean audio off requires the stored 0.5 s room-tone run; when no source gap holds a whole run, the passage is refused with `roomToneUnavailable` before any paid take, and the UI offers Clean audio (§8.7). Full take and voice changing have an explicit null policy when room tone is not needed.

An incoming synth seam needs `floor(N/2)` output samples of asset handle before its trim; an outgoing seam needs `ceil(N/2)` after its trim, including when two synth pieces share the seam. For a needed half of `k` source-grid output samples, the minimum raw handle is `ceil(k × assetSampleRate / (sourceSampleRate × audio.stretch))` asset frames. A touching synth seam has zero source handle on both sides and keeps the one N-frame fade.

`video.mode` is one of `source`, `retimed`, `zoomCover`, or `lipsync`, with mode-specific data validated and retained. Pure Core preparation accepts `source` when rounded replacement input/output sample lengths are equal, and the §8.9 step 3 policies `zoomCover` and `lipsync` with their validated mode-specific data. `retimed` and changed-duration source mode still report `videoModeUnsupported`; unknown mode strings and integer enum values are invalid. Native Mac request capture accepts prepared source-video recipes and the explicitly chosen, composition-verified `zoomCover` route with factor 0.80–1.25 and crop 1.12. Windows retains its explicit unsupported visual-route refusal. Both platforms still refuse legacy retimed and lip-sync rendering before native work. Provider job support alone does not enable a render route. Core validation keeps a stored fit factor within `STRETCH_OK` (`[0.92, 1.08]`). That range is only a validation bound: under ADR-R30 every renderable recipe has a fit factor of 1, and Media refuses any other value (below). Retime policies validate `[0.80, 1.25]`. TTS requires timestamped alignment, applicable transcript and calibrated speaker QA evidence; stock voice changing does not inherit TTS-specific transcript/speaker gates. Core does not claim a QA record proves actual speaker verification.

The prepared disclosure derives kinds, synthetic output seconds, persistence (`voiceChanger ≥ 50%` or all AI `> 30%`), first exposure `[0,min(3,duration)]`, and clamped segment intervals expanded by 0.5 s and merged when their gap is less than 1 s. It stores 150 ms fades, chosen position and language-specific post text. It does not draw a label, write XMP/sidecar output or accept a render. Callers use it only with native composition and visible/provenance output bound to the same prepared contract.

**Mac renderer.** Media renders reviewed, equal-rounded-length v3 source-video recipes with unity audio fit through `CompositionBuilder` for preview, MP4 and edited WAV. The App and CLI now prepare requests for this saved-recipe subset; legacy CLI plan output remains guarded. It validates the prepared request and source identity, snapshots paid audio, stages bounded source/mixed/fitted CAF on the source grid, and retains those files through player or reader completion. Synthetic tests compare decoded MP4 AAC waveform levels, correlation and marker positions with production edited WAV across passage, full-take and touching-piece routes while allowing one AAC priming packet at the boundary. The player test verifies graph and scratch lifetime after load and close; it does not establish audible playback.

**Nonunity refusal.** Both renderers refuse every recipe whose `audio.stretch` is not 1, before paid snapshot, scratch or output creation: Mac reports the typed `nonunityFitUnsupported` capability error, and Windows throws `VoiceLabTempoException`. Both messages say that VoxClip does not support a take stretched to fit its window. Under ADR-R30 this refusal is permanent; it stays until a later ADR adopts a micro-stretch (§8.9.5). Only duration-arithmetic roundoff takes the unity path: within four binary64 ULPs of 1 on Mac, and 1 or its immediately adjacent binary64 values on Windows, so `1 + 1e-9` is refused. The TimePitch and `atempo` diagnostics behind the refusal are recorded in [`doc/archive/voice-lab-stretch-history.md`](../archive/voice-lab-stretch-history.md).

Mac export estimates planned peak scratch, muxing, XMP stage, metadata and prior-output rollback bytes across the actual volumes before creating snapshots or output, then rechecks as work advances. After destination and prepared-request safety checks, an empty output timeline fails with `everythingCut` before the WAV size estimate, capacity check, source reader, paid snapshot or output staging. For combined CLI output, the same transaction preflight also includes the edited WAV partial before WAV staging; an already staged WAV is reflected in free space and is not counted again. A known WAV frame count beyond the RIFF limit fails before reader, snapshot or output creation. There is no fixed 15 GiB product reserve. A sidecar partial is removed only after this invocation exclusively creates it. The app bundle supplies the version for provenance; CLI supplies its declared version explicitly, and a missing version fails before export. Generation, live providers, consent capture, changed-duration video, other video modes and lip sync remain outside this guarded renderer.


**Mac persisted-recipe request wiring.** The App and CLI use the canonical `<data>/VoiceLab` root and prepare the frozen project, selected full or clip scope and the default top-right disclosure position (§11.2) before rendering. Transport, scrubbing, dormant source cuts, captions and output sizing follow the prepared timeline. Full App export ignores its preview clip; CLI preserves the saved active scope unless explicitly overridden. Caption layout retains the project's original settings, including per-aspect position and overrides, while displaying the prepared source and replacement words. Captions Off removes captions but retains disclosure. Missing or altered paid assets, invalid recipes, active v2 synth, unsupported video modes and nonunity fit refuse rendering; a failed current preview request clears its player, and cancellation or stale requests cannot clear a later preview. Combined CLI MP4/WAV/SRT/provenance still uses Media's capacity preflight and publication transaction. No consent capture, generation, candidate acceptance, video retiming or lip-sync workflow is enabled by this caller integration.

**Windows renderer.** `VoiceLabRenderInput` captures an isolated project and verifies its prepared request, media and captions before asynchronous preparation. `ComposeSnapshot.Timeline` drives bounded source/synth audio, video lookup and output duration through the existing preview, MP4 and edited-WAV paths. Prepared private asset leases remain alive until the readers and WASAPI producer stop. The single `FrameComposer` draws disclosure after captions; the exporter stages recognized XMP and the final MP4 hash/provenance through the existing output transaction. Combined CLI destination/capacity helpers include requested WAV/SRT/sidecar and previous outputs.

**Windows persisted-recipe request wiring.** The App and CLI now prepare the exact current v3 project and selected full or clip scope, then capture it with the canonical `<data>/VoiceLab` paid root. Full export ignores the editor's active clip; clip export uses that clip's edits. Synthetic captions, transport and output sizing follow the prepared output timeline, including when captions are off. Windows preview/export admit the already reviewed source-video, equal-rounded-length, unity-audio subset and publish mandatory disclosure outputs through the existing Media route. Missing or changed paid audio and unsupported recipe, video, clean-audio or fit policies stop with actionable errors; a failed preview update disposes its old player and frame. Disabled or excluded replacements still use source rendering. Version 2 active synth and the legacy CLI `plan --json` shape remain refused. This wiring does not capture consent, generate or accept a candidate, verify a speaker, apply nonunity fit, retime source video, lip-sync or complete publishing.

**Windows caller acceptance for that subset.** An isolated normal ARM64 Debug App accepted the real first-launch terms UI, reopened a persisted synthetic v3 project, advanced its WASAPI-driven preview clock through a selected replacement, and published full and selected-clip MP4/SRT/provenance sets. Independently decoded 1280×720 outputs showed the AI MODIFIED chip, source and synthetic caption glyphs, and the synthetic tone at the scope's mapped time; the full output lasted 7.0 s and the selected clip 3.4 s. A second saved project with a moving synthetic source verified three source-frame positions in each App output against Core's full or clip map. The matching crop had 4.70–6.05 mean channel error after encoding; a 0.6 s wrong source position had 21.71–62.63. The App showed missing and altered paid-asset notices in preview and export, cleared the preview, kept published output hashes, and left the synthetic paid file unchanged after restoration. Standalone ARM64 and self-contained x64-under-ARM64-emulation CLI combined MP4/WAV/SRT/sidecar routes passed with 336,000 edited-WAV samples and the audited six-DLL runtime for the matching architecture. An independent ISO BMFF parser found one top-level Adobe XMP UUID and the exact IPTC DigitalSourceType property in all six native App/CLI MP4 routes, with every sidecar bound to the final MP4 hash. A schema-v1 CLI export and normal App playback still worked. Earlier guest screenshot methods returned a white or stale entire App window and did not establish visible preview. The parent R4 repeat built exact committed source `793116f` and observed all six audited ARM64 DLLs in the normal App. After the host VM surface became responsive, actual live preview captures showed replacement WORDS at 3.0 s and the AI MODIFIED label; native play/pause/seek and stable paused transport were observed. Process-specific WASAPI loopback included only that App process tree. After alignment, all 336,000 stereo float frames exactly matched the production edited WAV, including the 660 Hz replacement interval. This establishes synthetic App audio output, not physical speaker audibility or human speech quality. The repeat restored the previously observed acceptance receipt for unchanged runtime terms; it did not accept new terms. Its first bounded capture ended before full playback and remains retained as incomplete. Installed App, physical x64, real voice and full consent/generation workflow acceptance remain open.

On Windows, native ARM64 and x64 under ARM64 emulation verified unity passage, full-take and touching output, source-only scopes, WASAPI play/pause/seek/disposal, marked MP4/WAV and rollback. These synthetic routes do not establish speech intelligibility, installed behavior or physical x64 performance. The R5 native check uses a saved caption position and unmodified `CaptionEngine` page geometry; preview and decoded export preserve the visible caption while the disclosure moves to the opposite corner.

Windows capacity accounting uses actual volume identities, including drive/mount aliases. Empty edited-WAV timelines report `EverythingCut` before querying capacity or creating readers/partials; known synthetic RIFF overflow also fails before preparation. Paid originals and existing published outputs remain protected on cancellation or failure.

---

## 11. Disclosure (EU AI Act Article 50)

### 11.1 When disclosure is required

Disclosure is derived per export, from the segments that are enabled inside the exported range:

```
segs        = enabled voiceLab.segments overlapping the exported range
required    = !segs.isEmpty
kinds       = unique(segs.kind) ∪ (any seg with video.mode == "lipsync" ? {"lipsync"} : {})
aiSeconds   = Σ edited duration of segs within the range
persistent  = kinds contains "voiceChanger" covering ≥ 50% of the range
              || aiSeconds / rangeDuration > 0.3
```

Clean audio never makes disclosure required.

The rules follow the Article 50 timeline and guidance:

- Article 50 has applied since 2 August 2026.
- The Commission Guidelines (20 July 2026) put "synthesis of realistic speech in a specific person's voice" in scope. They put noise reduction out of scope.
- Intent and consent do not exempt content from labelling.
- For video, the label must be visible at the start, and end credits alone are not enough.
- The open-source exemption in Article 2(12) does not cover Article 50.

### 11.2 Burned-in label

The label is drawn by the same compositor that draws captions: `FrameCompositor` on macOS and the Skia renderer on Windows. It sits above the captions.

| Property | Value |
|---|---|
| Text | `AI MODIFIED` (Latin capitals, the EU Code of Practice wording) |
| Font | DM Sans Bold (`shared/fonts/dm-sans/DMSans-Bold.ttf`), size `0.024 × output height` px, letter spacing 0.06 em |
| Chip | background `#000000` at 70% opacity, blended in gamma-encoded sRGB (not linear light); text `#FFFFFF`; padding 0.35 em vertical and 0.6 em horizontal; corner radius 0.3 em |
| Position | default top-right. Options: top-left, top-right, bottom-left, bottom-right. The margins are 5% of output width and 5% of output height |
| Collision | if the chip rectangle intersects the caption block in any frame of an interval, move it to the opposite top corner for that interval |
| Fades | 150 ms in and out |
| Intervals (edited timeline of the exported clip) | `[0, 3.0]`, plus `[segStart − 0.5, segEnd + 0.5]` for each segment, clamped to the clip. Merge intervals that overlap or lie less than 1.0 s apart. When `persistent`, the whole clip |

- **Per export.** Each exported clip is its own first exposure, so the intervals are computed per clip.
- **Contrast.** White on 70% black blended in sRGB has a contrast ratio of at least 8:1 over any background (worst case, a white background, gives about 8.5:1), which meets WCAG 2.1 AA. A linear-light blend would drop to about 3:1, which is why the blend space is fixed.
- **Default build.** The label cannot be turned off while `required` is true. Only its position can change, in Settings → Voice Lab → Label position.
- **Preview.** The preview draws the label too, so what you see is what you export.

### 11.3 Post text line

The post disclosure line is optional (user decision, 1 November 2026). In the Mac Export job, sharing starts in the collapsed “Share to X or LinkedIn…” section (`ui.export.shareExpanded`). **Add 'AI MODIFIED' line to the post** is **OFF by default always**, including exports containing AI-voiced phrases. Opting in appends the exact line below on its own paragraph after a blank line. Copy caption, Open X and Open LinkedIn use the current text without an interstitial. This does not change the required burned-in video label, render disclosure plan or provenance. Windows follows this contract when its inline Export lane lands; its existing dialog is pending migration.

| Condition | en | et (draft, needs native review) |
|---|---|---|
| `tts` | Some words in this video were re-voiced with an AI copy of my own voice. | Mõned sõnad selles videos on loetud minu enda hääle tehisintellekti-koopiaga. |
| `voiceChanger`, own clone | The voice in this video was converted with AI into a copy of my own voice. | Selle video hääl on tehisintellektiga muudetud minu enda hääle koopiaks. |
| `voiceChanger`, stock voice | The voice in this video was changed with AI. | Selle video häält on muudetud tehisintellektiga. |
| also `lipsync` (appended sentence) | Lip movements in parts of it were generated with AI. | Osa huulte liikumisest on loodud tehisintellektiga. |

- Core builds the line (`VoiceLabDisclosurePlan.postText`) from the sentences in this order: `tts`, then `voiceChanger` (own clone or stock voice), then `lipsync`, joined by single spaces. It is the only source of the line.
- The line is Estonian when the primary language subtag of the transcript language (the part before the first `-`) is `et`, compared ASCII case-insensitively: `et`, `et-EE` and `ET` match, `eto` does not. Otherwise it is English.
- The caption field opens with the saved or default caption and the post-line toggle off; a previously appended exact generated line is omitted until the user opts in. When the user turns the toggle on, White_Space at the end of the caption is dropped and the line is appended after a blank line (`SharePostText.fieldText`). The field text stays within the 3,000 Unicode scalars of `share.captions`: when the caption, the blank line and the line would pass 3,000, the caption is cut with the composer rules of `doc/publishing.md` §2.1 (rules 4 to 6, with `…`), measured in Unicode scalars against 3,000. The line is never cut.
- The line is present when the caption contains it after both are NFC-normalized, every run of White_Space is collapsed to one space and the ends are trimmed (`ShareDisclosure.isPresent`). Any other edit to the line counts as removing it.
- The user may edit the caption or turn the toggle off at any time. Turning it off removes the exact generated post line immediately, with no Share anyway / Restore line interstitial. Only when the rendered export actually contains AI-voiced phrases, show the inline hint “Your video still shows the AI MODIFIED label.” Nothing nags on Done.
- When the user opted in, truncation for X and for VoxConvo's 2,048-unit `text` (the composer text in `doc/publishing.md` §2.1) removes the line's last occurrence, cuts the rest of the caption and appends the line after a blank line. The disclosure line is never cut, and in truncated text it is always last. A caption that fits is sent unchanged, wherever the line is. Copy caption and Open LinkedIn never truncate.

### 11.4 X

- **M1-style intent links** (`https://x.com/intent/post?text=…`) cannot set a disclosure flag. When `required`, Open X also shows a checklist tip: "Turn on 'Made with AI' in the post's content disclosure before posting."
- **Posting through the X API** (`doc/publishing.md` §5): `POST https://api.x.com/2/tweets` must include `"made_with_ai": true`, which is described as "Disclose that the tweet contains AI-generated media". The flag reportedly cannot be changed after posting.

### 11.5 LinkedIn

LinkedIn's posting API has no disclosure field. When the user opts in, the post text line supplies the text disclosure. C2PA (§11.7) is embedded in the MP4 when enabled. LinkedIn shows a "Cr" icon for C2PA credentials it reads; whether that happens for a self-signed manifest, and whether the manifest survives its transcode, is unverified.

### 11.6 VoxConvo

- The publish call (`doc/publishing.md` §3.5.3) adds `aiDisclosure: { "modified": true, "kinds": ["tts","lipsync"], "aiSeconds": 4.1 }` to `NewPostInput`, and the text carries the line from §11.3.
- This needs a vox-api schema change and a vox-web badge. Both go in the publishing change lists before M3.
- `doc/publishing.md` §5.2 uses the same `aiDisclosure` object for cross-posting, plus the optional post line when the user opts in.

### 11.7 Machine-readable marking: XMP and C2PA Content Credentials

- **Mandatory mark.** When `required` is true (§11.1), the export **must** carry a machine-readable mark, and the default build offers no way to turn it off. Both platforms embed XMP metadata in the MP4 with `Iptc4xmpExt:DigitalSourceType = http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia`. This needs no optional component.
- **MP4 staging (ADR-R27).** Finalize the native muxer output first. Validate its top-level boxes, then copy it with bounded buffers to a distinct, exclusively created stage and append one standard Adobe XMP UUID box (`BE7ACFCB-97A9-42E8-9C71-999491E3AFAC`). Existing XMP, malformed box bounds and size-zero boxes are rejected before staging; do not strip or silently replace provider marks. The completed copy retains the original media bytes and chunk offsets. This supersedes only the earlier AVAssetWriter metadata / FFmpeg `udta` implementation route: the tested metadata calls did not retain XMP in their finished MP4s.
- **Hash and publish.** Bind a detached provenance snapshot to the verified project and prepared render before asynchronous I/O. Reserve disk for the additional MP4 copy before starting output. Hash the final marked MP4 after all metadata changes, including C2PA if present, and generate §11.8's sidecar with the intended published basename and actual app version. Stage the sidecar separately and publish the MP4, sidecar and requested SRT/WAV together through the existing export transaction. Cancellation or any marking, sidecar or publication failure preserves existing destination files and cleans only owned stages; an unmarked intermediate must never become the published export.
- **Acceptance.** Independently extract the finished MP4's XMP and verify the exact IPTC RDF property, one top-level Adobe XMP UUID and the sidecar's hash of the final bytes. Run these checks through each production export path, including cancellation and publication rollback. Helper-only probes do not establish compositor, preview, transaction or app/CLI acceptance; each newly wired caller route needs its own native verification before it is accepted.
- **C2PA on top.** When the C2PA component is present, a signed C2PA manifest is added as well for every export where `required` is true. The Settings → Voice Lab toggle "Add Content Credentials (C2PA) to exports" applies only to Clean-audio-only exports (no synthetic segment), where it defaults to on.
- **Libraries:**
  - macOS: `c2pa-swift` (contentauth, Apache-2.0).
  - Windows: a bundled, signed `c2patool.exe` (contentauth, v0.28.3 or later), invoked with a manifest file.
  - Without the component, the provenance sidecar (§11.8) is still written.
- **Manifest.** Validate the field names against the C2PA 2.4 manifest reference in spike S9.
  ```json
  {
    "claim_generator_info": [ { "name": "VoxClip", "version": "<app version>" } ],
    "title": "<export file name>",
    "assertions": [ { "label": "c2pa.actions.v2", "data": { "actions": [
      { "action": "c2pa.opened" },
      { "action": "c2pa.edited", "description": "Cut words and pauses" },
      { "action": "c2pa.filtered", "description": "Noise reduction (ElevenLabs Voice Isolator)" },
      { "action": "c2pa.edited",
        "description": "Re-voiced 2 phrases (4.1 s) with an AI clone of the speaker's own voice",
        "digitalSourceType": "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia",
        "softwareAgent": { "name": "ElevenLabs eleven_v4" } },
      { "action": "c2pa.edited", "description": "Lip movement regenerated (fal-ai/latentsync)",
        "digitalSourceType": "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia",
        "softwareAgent": { "name": "fal-ai/latentsync" } }
    ] } } ]
  }
  ```
  Include only the actions that apply. Use the IPTC spelling `compositeWithTrainedAlgorithmicMedia`; one C2PA guidance page misspells it.
- **Signing.** Use a per-install, self-signed ES256 certificate, created on first use.
  - The private key is stored in the Keychain or DPAPI (account `c2pa-signing-key`) and the certificate in `<data>/VoiceLab/c2pa/cert.pem`.
  - When c2patool needs a key file, write it to a temp file readable only by the user and delete it right after.
  - Validators show such manifests as "unknown signer", and the settings footnote says so.
- XMP and C2PA metadata are the machine-readable marking under Article 50(2), but platforms often strip them. The visible label is what viewers see.

### 11.8 Provenance sidecar

Every export that has Clean audio or any synthetic segment gets `<export name>.provenance.json` written next to it. Writing it for every export is a user option.

```json
{
  "schema": "voxclip-provenance/1",
  "app": { "name": "VoxClip", "version": "0.3.0", "platform": "macos" },
  "export": { "file": "intro-9x16.mp4", "sha256": "…", "durationSeconds": 42.317, "createdAt": "2026-10-25T12:30:00.000Z" },
  "source": { "contentKey": "…", "durationSeconds": 612.4 },
  "edits": { "cutWords": 17, "cutPauses": 4, "corrections": 2 },
  "cleanAudio": { "provider": "elevenlabs", "endpoint": "audio-isolation", "mix": 1.0 },
  "aiSegments": [
    { "kind": "tts", "outputStart": 12.10, "outputEnd": 13.78, "text": "I said 2025",
      "provider": "elevenlabs", "model": "eleven_v4", "voice": "own-clone", "seed": 3141592653,
      "lipsync": { "provider": "fal", "model": "fal-ai/latentsync" },
      "generatedAt": "2026-10-25T12:10:00.000Z", "consentRecordId": "6f0c2c1e-…" }
  ],
  "disclosure": { "required": true, "persistent": false, "labelIntervals": [[0, 3.0], [11.6, 14.28]],
                  "postText": "Some words in this video were re-voiced with an AI copy of my own voice.", "c2pa": true },
  "consent": [ { "recordId": "6f0c2c1e-…", "verifiedAt": "2026-10-25T12:00:00.000Z" } ]
}
```

The sidecar never contains keys, voice samples, consent audio, embeddings or file paths outside the export folder.

### 11.9 Watermarks and metadata

VoxClip never removes, alters or hides ElevenLabs SynthID watermarks or provider metadata, as ElevenLabs' Prohibited Use Policy requires. Ordinary gain, crossfade, silence-only fit (§8.9) and encode steps are allowed. No step may be added whose purpose is to defeat detection.

### 11.10 Legal review gate

The Guidelines do not settle whether a free, open-source, bring-your-own-key desktop app is a "provider" under Article 50(2), or whether a one-word own-voice patch meets the deepfake threshold. This spec takes the conservative reading: every synthetic segment in a realistic talking-head video is labelled.

**M3 must not be released before a legal review of §11**, including whether the mandatory XMP `DigitalSourceType` mark plus the optional self-signed C2PA manifest (§11.7) satisfy the machine-readable marking duty. Article 50 penalties fall in the €15M / 3% tier. This research is not legal advice.

---

## 12. Privacy, logging, storage

| Data | Leaves the device? | Where it is kept |
|---|---|---|
| Source audio for Clean audio | to ElevenLabs, only on the user's click | cache input WAV (evictable); result in `<data>/VoiceLab/<contentKey>/` |
| Consent statement audio | to ElevenLabs STT (check) and IVC (one sample) | `<data>/VoiceLab/consent/<recordId>/` until the voice is deleted |
| Training samples (project spans or a read-aloud) | to ElevenLabs IVC | temporary; deleted locally after upload or explicit enrollment discard; hashes kept |
| Patch text and context text | to ElevenLabs TTS (`previous_text` / `future_text`, ≤ 100 or 300 characters) | in the project segment |
| Lip-sync window video and audio | to fal.ai or sync.so | deleted remotely where the API allows; result in `<data>/VoiceLab/<projectId>/` |
| Speaker embeddings | never | in the consent record |

- Logs record the provider, endpoint path, model id, HTTP status, durations, byte counts and request ids. They never record audio, text, statements, voice ids paired with names, or keys.
- About → "What leaves this device" adds a Voice Lab section listing the rows above.

---

## 13. Later work and integration limits

- **Full-take rewrite and re-voice** remains in scope alongside passage rewrites. The current Core service accepts a full-take rewrite request and keeps source word timings, but a long take needs bounded generation chunks, reversible timeline composition, preview/accept/undo, disclosure and optional lip sync before it is available in the app. Estimate provider charges from current provider data; old illustrative per-minute figures are not prices to display to users. For full-take output:
  - offer a voiceover format with no lip-sync claim and a persistent "AI voice" label;
  - sentence-mapped lip sync, retiming each clip within ±25%;
  - a teleprompter re-record prompt, which the app should suggest first.

  A full take is generated per sentence chunk. Only chunks that fail QA or fall outside the chosen video treatment's tolerance, such as the ±25% sentence retime, are regenerated, never the whole take, and the timeline follows the chunks' natural length (ADR-R30).
- **Own-voice dubbing** (for example Estonian ↔ English) is considered later.
  - ElevenLabs Dubbing v2 has been in the API since 6 Aug 2026 (alpha). It costs $2.20 per minute, accepts files up to 3 GB, and its output is "a high-quality preview, not a production master". It has no lip sync.
  - The alternative is to translate with the user's LLM, then run TTS in the own clone, then optionally lip sync.
  - Translation is not exempt under Article 50, so the label adds "translated".
- **Professional Voice Clone** as a "verified voice", using ElevenLabs' captcha, is later.
- **sync.so dialogue editing** (`/v2/transcriptions` → `/v2/dialogue-edits` → `/v2/generate`) is a spike, not a plan. It would replace most of §8 for single-speaker videos up to 10 minutes. But it clones voices through sync's own ElevenLabs pool, which VoxClip's consent record does not cover, it needs organisation feature flags, and it bills for the whole video.

---

## 14. Spikes and open questions (resolve before the M3 beta)

| # | Question | Blocks |
|---|---|---|
| S1 | Does `/v1/text-to-dialogue/with-timestamps` with `eleven_v4` return non-null `alignment` for a single input, with absolute (not chunk-relative) times? Does `/v1/text-to-speech/{id}/with-timestamps` accept `eleven_v4`? | §8.5, §8.8 |
| S2 | Estonian IVC quality on `eleven_v4` compared with `eleven_v3`, for 1–3-word patches with `previous_text`/`future_text`. Does `similarity` 0.8 hold? | §8 defaults |
| S3 | Do Voice Isolator and Voice Changer preserve duration, and which formats come back? Is the Voice Changer acceptable on Estonian? | §4.4, §7 |
| S4 | When is `requires_verification` true for API-created IVC voices? | §6.7 |
| S5 | Which IVC upload formats are accepted (M4A AAC, WAV, FLAC)? How does multipart encode `labels`? | §6.5, §6.7 |
| S6 | WeSpeaker ResNet34-LM (CC BY 4.0), Mac ONNX Runtime SwiftPM 1.19.2 CPU. On 2026-10-29, clean P99.9 + max(0.002, drift), rounded up to 0.01, publishes English τ = 0.45. Production scoring covers 80 clean calibration + 66 disjoint harder speakers, 438 source clips, 876 renders at 48/44.1 kHz and correlated, not independent, pairs. Every corpus/rate meets FAR ≤ 0.5% and same-speaker pass ≥ 95% (worst 0.113960% / 98.989899%; full table in §6.6). Requires installed, hash-verified assets. Estonian stays unavailable; its calibration, the user's Mac microphone check before release and Windows runtime parity remain owed. | §6.6, the M3 release |
| S7 | Real processing times for fal LatentSync, lipsync-2 and sync-3 on 3 s and 10 s windows at 1080×1920 | §9 UX |
| S8 | The fal REST upload-initiate path and the storage lifecycle header for short retention. Whether sync.so watermarks output on its lowest plan | §9.4, §9.5 |
| S9 | Validate the C2PA manifest against spec 2.4. Does a self-signed manifest survive and display on LinkedIn and X? | §11.7 |
| S10 | Does `text_to_speech` permission also cover Text to Dialogue? Exact error-body fields for missing permissions | §2.2 |
| S11 | Map ElevenLabs `tier` strings to "Pro or higher" for 44.1 kHz output | §2.3 |
| S12 | Legal review of §11 | M3 release |
| S13 | Paid calibration, only with the user's explicit approval: 5 passages × 3 seeds per language on the user's own voice, plus `voice_settings.speed` 0.9 and 1.1 probes on Eleven v3 (about $0.25–1). How much does take length vary between seeds, how accurate is the length budget, and does speed change the duration? | §8.6 speed, §8.9.1 |
| S14 | Resolved: one affirmative approval for the immutable quote set of up to three sequential takes plus bounded Scribe QA, with one summed displayed cap. Consume per dispatch; discard unsent remainder on early stop, cancellation or changed inputs. Approved remainder stays valid until the run ends (§2.6). | Closed by lead decision; §8.6, design §6.3 |
| S15 | Resolved: no automatic length retry. Show an out-of-range proposal with its meter. Shorter or Longer is a new send with its own quote and approval, as `doc/spec/ai.md` requires. | Closed by lead decision; §8.9.1 |
| S16 | The listening check that gates the fit policy, and the tuning of the six fit constants from its answers | §8.9.4, ADR-R30 |

---

## 15. Acceptance tests

Unit tests run in both suites (`VoxClipCoreTests`, `VoxClip.Core.Tests`), with shared fixtures in `shared/fixtures/voice-lab/`:

1. **Word diff (§8.2).**
   - `"I said 2024"` → `"I said 2025"` gives one voice hunk of one replaced word.
   - Deletion only gives a cut hunk. A case-only change gives a textOnly hunk.
   - Two voice hunks separated by 2 equal words merge, with the bridge words re-voiced.
   - Tie-breaking is deterministic.
2. **Patch budget.** 61 changed words, or 16% of the words, disables voice hunks.
3. **Seam placement (§8.4).**
   - A gap of 0.2 s two words to the left puts the seam at its quietest frame.
   - No gap within 3 words gives a hard seam at `a.start − min(0.03, max(0, gap)/2)`.
   - A window with no kept or replaced item before its first word extends to sample 0 with seam kind `none`. It absorbs earlier cut items, so a cut "um" at 0.0 s before a rewrite of the first sentence renders. A window with no kept or replaced item after its last word extends to exactly `durationSeconds`, also off the sample grid. In a clip scope this happens only at a take edge that the clip's range touches.
   - A gap frame whose centred fade would leave kept source is never chosen: the take, a cut's reach, a cut pause or a clip's head or tail. A hard seam whose fade would leave the take refuses the hunk with `seamFadeOutsideTake`. A seam without the outer half of its fade in kept source beside it refuses with `seamFadeCrossesCut`. A window too short for both inner halves refuses with `windowTooShort`. At 22.05 and 44.1 kHz, where `floor(N/2)` and `ceil(N/2)` differ, named vectors pin each half.
   - An event that starts with the passage or lies inside its last word is absorbed, and a kept word inside the window outside the passage and its bridges refuses with `windowCrossesWord`. A transcript that breaks the project rule refuses with `invalidInput`.
   - Re-voicing the sentence after an accepted one places its seam clear of that replacement's fade: in a gap, or as a hard seam when only 18 ms of silence separates them. A window over a replacement refuses with `overlapsReplacement`. One that would touch a replacement, leave too little kept source between them on either side, or move a cut until another replacement's fade crosses it refuses with `adjacentReplacement`. A disabled replacement, or one outside the clip, changes nothing.
   - After a replacement is accepted, cutting the pause its seam lies in does not block re-voicing the first sentence: that window is accepted and renders. A scope that a replacement already leaves unrenderable, such as one whose fade now meets a 5 ms sliver of kept source, refuses with `invalidInput` and that replacement's ID, and so does a pair of replacements too close for both fades.
   - Property: every window placed for a random take, at 44.1 and 48 kHz and in full or clip scope, passes `VoiceLabProject.validate` and `VoiceLabRenderContract.prepare`, and so does every window placed beside one or two replacements that `place` itself put there, including after later cuts and replacements enabled again. `window-cases.json` carries a fixed-seed sample of each 20,000-case fuzz, and both suites validate and prepare every accepted case, named vectors included, with every replacement in the project.
4. **Duration fit (§8.9), with `fit-cases.json`.**
   - A take 5% longer than its window (`D = 1.05 × w`) whose punctuation pauses can give up the residual above their floors fits exactly: `outDuration == end − start`, the fit factor is 1, and every word keeps its aligned duration.
   - A take 5% shorter (`D = 0.95 × w`) lengthens its pauses within `PAUSE_GROWTH_MAX`, pads what remains equally at its two gap seams, and fits exactly.
   - A one-word take shorter than its window between two hard seams pads at most `HARD_SEAM_PAD_MAX` at each seam, and the rest becomes `changedDuration`.
   - A take 15% longer next to a 0.6 s source pause borrows from that pause once its own pauses reach their floors, keeping `PAUSE_SLACK_KEEP` next to the kept word.
   - No edit lies in an aligned word span or a 10 ms frame at or above `VOICED_FRAME`. The floors, `PAUSE_GROWTH_MAX` and `SEAM_PAD_MAX` hold, and the output has exactly `jsRound(n × assetRate / sourceRate)` frames.
   - A take 40% longer with no pause and no seam silence to borrow returns `changedDuration` with an empty `partialEditList` and `residualSeconds = 0.4 × w`. Retimed source video is unavailable because `1/1.4` is outside `RETIME_VIDEO_OK`; when Lip sync is unavailable too, the hunk is rejected.
   - A take whose pauses and seams can hold only part of its residual returns `changedDuration` with every edit at its limit. `residualSeconds` is the rest, and `outDuration = duration(W) + residualSeconds`.
   - At a take edge, the pad keeps the first aligned word at its source distance from the edge.
   - Both Cores run placement → lendable silence → fit → recipe → both validators → output planner → render preparation on a 44.1 kHz millisecond-word window, hard/hard at [2.556, 3.143] s, and a take-end variant. Exact fits keep identical source/output sample lengths and prepare as source video. Changed-duration recipes prepare in §8.9 step 3's `zoomCover` or `lipsync` mode; native request capture still refuses both (§10.5), preserving the source-only renderer gate.
5. **Alignment to words (§8.8).** The character alignment for `"I said 2025"` gives 3 words, all `synthetic: true`. A null or malformed alignment ends the run after that paid take; the paid asset is retained. Scribe/interpolation fallback remains deferred with §8.5 rather than buying further takes that cannot pass alignment.
6. **Candidate ranking (§8.6).** Rejected candidates are never shown. An exactly fitted take has `fitCost = 0`, and a `changedDuration` take's fit cost rises with `|residualSeconds|`. The score formula orders a fixed set.
7. **Plan mapping (§10.2).**
   - With `outDuration == in`, the plan's `mapTime` is unchanged outside the segment.
   - With `outDuration = 1.2 × in`, the edited duration grows by `0.2 × in`, and captions inside the segment come from `words`.
   - A cut segment removes the whole interval.
8. **Disclosure (§11.1, §11.2).**
   - The intervals for a 42 s clip with segments at 12.1–13.8 s and 13.9–14.2 s are `[[0,3],[11.6,14.7]]`, merged.
   - A voiceChanger segment covering 60% of the clip makes the label persistent.
   - A clip without segments gets no label.
   - Clean audio alone gets no label.
9. **Post text (§11.3).** The text for each kind combination, in en and et. X truncation keeps the disclosure line whole.
10. **Cost (§3).**
    - Isolator for 3 min = $0.36. LatentSync for 5 s = $0.20 and for 60 s = $0.30.
    - TTS for 60 characters × 3 candidates = $0.0144, shown "≈ $0.01".
    - Estimates of $0.50 or more require a confirmation.
    - An LLM send on a CLI signed in on a plan, a local server (loopback or remote) or Apple on-device is inline with no amount and does not confirm. On an API key, or a CLI signed in with an API key, it confirms on every send with the unknown-price copy. A CLI with an unknown sign-in method sends nothing. Both Cores check the same table over every connector kind and sign-in method. Its Claude Code rows include `claude.ai`, `oauth_token`, `api_key`, `third_party`, `none` and a missing method, and its Codex rows the ChatGPT status, the API-key status and an unrecognised status. `third_party`, `none`, a missing method and the unrecognised Codex status send nothing.
11. **Consent check (§6.4).**
    - A WER of 0.14 with all nonce words passes.
    - A WER of 0.10 with a nonce word missing fails.
    - A recognised language that differs from the statement fails.
    - Date strings use the month tables in en and et.
    - An Estonian transcript gives an English statement while only English has a calibrated speaker check (§6.2).
    - A speaker mismatch makes no provider request. A failed plan check makes no Scribe request. A failed statement check creates nothing. The single approval refuses a changed name, language, creation time or noise-removal choice, and a changed file set, including any file's position, role or SHA-256.
12. **Request goldens** for every endpoint in §4.3, §6.7, §7.3, §8.5, §8.8, §9.4 and §9.5: method, path, headers (with key values redacted), body or multipart parts.
    - The Isolator, forced-alignment, text-to-dialogue and lip-sync client goldens are waiting on their §4/§9 clients. Clean audio and Lip sync stay visibly unavailable with a reason in 0.1.0; no successful provider state machine is implied by the TTS/IVC goldens.
13. **Provider state machines** with mocked HTTP:
    - The following §9 state machines remain waiting on those clients; the unavailable UI cannot submit them.
    - fal `IN_QUEUE` → `IN_PROGRESS` → `COMPLETED`, and the cancel responses 200, 202 and 400;
    - sync.so `PENDING` → `COMPLETED`, `FAILED` with `errorCode`, and a 429 retry reusing the same Idempotency-Key;
    - a submit is never retried after a timeout.
14. **Redaction.** `Authorization: Key <fal key>` and `x-api-key: <sync key>` are redacted by the Core redactor (architecture §11.2), registered or not. Voice Lab log lines contain no text.
15. **Machine-readable mark (§11.7).** An export with `required == true` contains the XMP `Iptc4xmpExt:DigitalSourceType` value `…/compositeWithTrainedAlgorithmicMedia` on both platforms, with the C2PA component absent and with the Clean-audio C2PA toggle off. A Clean-audio-only export has no `DigitalSourceType`.
16. **Trim and room tone (§8.7).**
    - With null alignment, the trim runs from the first to the last voiced 10 ms frame, widened by `TTS_TRIM_LEAD` and `TTS_TRIM_TAIL` and clamped to the asset.
    - When no source gap holds a whole `ROOM_TONE_MIN_RUN`, passage TTS with Clean audio off is refused with `roomToneUnavailable` before any paid take.
17. **Length budget (§8.9.1).**
    - Both platforms count the same length for NFC and NFD Estonian text with õ, ä, ö and ü, digits and punctuation.
    - The rate and the character range follow the formulas for a fixed transcript and fixed stored candidates, and Fix with AI gives each line the same range (§8.1).
    - The voice-rewrite request with `targetSeconds`, `minChars` and `maxChars` renders identically on both platforms (shared prompt fixture), and a changed budget needs a new quote.
    - For fixed inputs the meter reads "about 4.3 s for a 4.1 s gap: fits" or "about 4.3 s for a 4.1 s gap: will change length".
18. **Takes (§8.6).** With mocked generation, a run stops after the first take that passes QA and fits exactly, and never sends more than `CANDIDATES` takes. `voice_settings.speed` is omitted unless the model and language are calibrated; when it is sent, the next take's speed follows the clamped formula.
19. **Fitted asset (§8.9.3), in both Media suites.**
    - The fitted WAV is SHA-256-bound, and every voiced span is bit-identical to the paid snapshot's frames.
    - Handles are present, and the rendered edited WAV and decoded MP4 put markers at the planned body and seam positions.
    - The recipe has a fit factor of 1, `outDuration` equal to the window (or the window plus `residualSeconds` after a partial fit), and chunks that name the paid asset's ID and SHA-256; v3 validation accepts it.
    - The existing unity passage, full-take and touching suites still pass, and both preflights still refuse a fit factor other than 1.
20. **Training spans (§6.5.1).** Both Core suites replay every case in `training-spans.json` and match its status, totals (including `preferredMs`) and span lists exactly. With a fake speaker check, spans below τ are dropped before any request, fewer than 30 s left blocks with the mismatch copy of `doc/design.md` §6.3.7 V3 and no provider call, and the request sends the statement first and the kept spans in source order.

21. **Scope rewrite plan (§8.1 item 1).** The Swift suite replays every case in `scope-rewrite-plan-cases.json`, written by `tools/fixtures/voice-lab/generate_scope_rewrite.py`: entries, lines and each line's range and its source (`window`, `lineSpan` or `noSpeech`), event labels on both bounds, enabled replacements left out of the entries and the items their runs precede, a scope that does not render, stored-candidate rates, both limits on both sides with the entry or byte count, and every plan accepted by `PatchRewriteService`. The C# suite replays it once the C# twin lands.

22. **Scope rewrite diff (§8.1 item 1).** The Swift suite replays every case in `scope-rewrite-diff-cases.json`, written by `tools/fixtures/voice-lab/generate_scope_rewrite_diff.py`, with each plan from `ScopeRewritePlan.make` and each reply through `PatchRewriteService`: echoed labels dropped and splitting a line, dropped labels absorbed, merges across lines by words and by time, cut and event barriers across lines, insertions merging across lines and their barrier positions, re-voiced runs splitting a line and stopping a merge, insertions in a line without words and the item each insertion follows, whole-line deletions, surface-only fixes, `checkThis` on the hunk whose tokens it flags, the patch budget over each case's hunks, the refusal of a proposal that does not fit the plan, and every `patch-rewrite-cases.json` reply mapped to hunks. The C# suite replays it once the C# twin lands.

Manual QA with real keys runs locally, never in CI:

- one Clean audio run on a 3 min take;
- one own-voice clone with the full consent flow in English; the Estonian consent flow is not applicable until Estonian has a calibrated speaker check. The et-v1 Riigikogu calibration failed: 89% same-speaker pass against the required 95%;
- one own-voice clone from an Estonian project's audio with an English statement;
- three patches (a replace, an insert, a bridged replace);
- one voice-changer preview;
- one LatentSync and one lipsync-2 window;
- an export checked for the label intervals, the post text, the sidecar and the C2PA validation output;
- the listening check in §8.9.4, before the fit policy ships;
- once the changed-duration video modes exist, one lip-sync and one retimed result viewed in the native preview and export.

---

## 16. Provenance

Law, guidance and standards behind §11 (checked 2026-10-27):

- [Regulation (EU) 2024/1689](https://eur-lex.europa.eu/eli/reg/2024/1689/oj) (the AI Act): Article 50 and its application date, and Article 2(12), whose open-source exemption does not reach Article 50.
- The Commission Guidelines on the transparency obligations under Article 50, approved on 20 July 2026 (C(2026) 5054 final), and the Commission's [Article 50 questions and answers](https://digital-strategy.ec.europa.eu/en/faqs/transparency-obligations-under-article-50-ai-act): speech synthesis in a specific person's voice is in scope; noise reduction is standard editing.
- The [C2PA specifications](https://spec.c2pa.org/specifications/) (manifest and actions, §11.7).
- LinkedIn's Help Center article on Content Credentials, which says images and videos signed with C2PA show a "Cr" label. Whether that happens for a self-signed manifest after LinkedIn's transcode is unverified (§11.5).

Vendor documentation checked on 2026-10-25:

- ElevenLabs API reference:
  - `audio-isolation/convert`; `voices/ivc/create` (`POST /v1/voices/add`, response `{voice_id, requires_verification}`);
  - `speech-to-speech/convert` (`POST /v1/voice-changer/{voice_id}`, fields, output formats, tier rules);
  - `text-to-speech/convert-with-timestamps`; `text-to-dialogue/convert-with-timestamps` (fields, 100-character `previous_text` / `future_text`, `voice_segments`);
  - `forced-alignment/create`; `voices/delete`; `voices/search` (`GET /v2/voices` categories);
  - `user/subscription/get`; `models/list` (`model_rates`, `languages`); `service-accounts/api-keys/create` (permission strings).
- ElevenLabs overview pages:
  - the models page: v4 "available via the Text to Dialogue API", the Estonian support matrix;
  - the voice isolator capability page: 500 MB and 1 h, 1,000 characters per minute;
  - the voice changer capability page: 5 min segments, 29 languages.
- fal.ai:
  - the `fal-ai/latentsync`, `fal-ai/sync-lipsync/v2` and `fal-ai/sync-lipsync/v3` API pages;
  - the queue REST docs (returned URLs, cancel codes);
  - the platform pricing and estimate endpoints; the storage upload initiate flow.
- sync.so: `generate-api/create` and `generate-api/get` (statuses, long-poll), `generate-api/estimate-cost`, `assets-api/create-upload` and `assets-api/create`, the pricing page, and the free trial page.
- X API `POST /2/tweets` (`made_with_ai`, `paid_partnership`).

Sources cited by the duration-fit research behind ADR-R30 (2026-10-26):

- ElevenLabs: [TTS with timestamps](https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps) (no target-duration parameter), the [TTS guide](https://elevenlabs.io/docs/eleven-creative/playground/text-to-speech) (speed "not available for the Eleven v3 model"), [TTS best practices](https://elevenlabs.io/docs/overview/capabilities/text-to-speech/best-practices), the [models page](https://elevenlabs.io/docs/overview/models) (Estonian only on v3 and v4), the [skills repository's voice settings](https://github.com/elevenlabs/skills/blob/main/text-to-speech/references/voice-settings.md) (the contradicting speed claim) and [API pricing](https://elevenlabs.io/pricing/api).
- sync.so: [sync mode](https://sync.so/docs/developer-guides/sync-mode) and [generate API](https://sync.so/docs/api-reference/api/generate-api/create.md), for changed-duration lip sync.
- The stretchers that were compared or excluded, with their sources: `doc/archive/voice-lab-stretch-history.md`.

Sources for the lip-sync corrections (lip-sync research, 2026-10-26):

- fal.ai: the [sync-3 model page](https://fal.ai/models/fal-ai/sync-lipsync/v3) ($8.00 per minute), the [lipsync-2 model page](https://fal.ai/models/fal-ai/sync-lipsync/v2), [fal CDN](https://fal.ai/docs/documentation/model-apis/fal-cdn) and [media expiration](https://fal.ai/docs/documentation/model-apis/media-expiration) (uploads, lifecycle header), and [request payloads](https://fal.ai/docs/platform-apis/v1/models/requests/payloads.md) (payload deletion).
- sync.so: [generate-api/get](https://sync.so/docs/api-reference/api/generate-api/get.md) (`wait` and `include=progress` are alternatives), [generate-api/delete](https://sync.so/docs/api-reference/api/generate-api/delete.md) (terminal states only), [assets-api/delete](https://sync.so/docs/api-reference/api/assets-api/delete.md), and the [pricing page](https://sync.so/pricing) (watermark by plan).

Repository documents: `doc/spec/editing.md` (§2, §4.5, §4.7, §7, §10, §12), `doc/spec/ai.md` (§4.8, §11.3, §12.8), `doc/architecture.md` (§2.5, §8, §10, §11), `doc/design.md` (§6.3, Settings), `doc/publishing.md` (§2, §3.5.3, §5), and `shared/schemas/project.schema.json` (`voiceLab`).

# Voice Lab

Status:

- **§4 Clean audio**: normative for M2.
- **§5 to §12 Voice Lab beta**: target design for rewriting a passage or full take in the user's own voice, voice changing and lip sync. The Mac and Windows Core service foundation is described in §2.6; timeline, media, UI and release gates remain open.
- **§13**: later capabilities and integration limits.

Voice Lab is every VoxClip feature that sends the user's voice to an AI service and gets new audio or video back. It is separate from transcription (`doc/spec/transcription.md`) and from AI tighten (`doc/spec/ai.md` §12). AI tighten only proposes cuts, never makes synthetic media, and never reuses anything defined here.

Related documents:

| Topic | Owner |
|---|---|
| Edit plan, segment kinds, project file, undo | `doc/spec/editing.md`, `shared/schemas/project.schema.json` |
| Data directories, secrets, logging, error codes | `doc/architecture.md` |
| AI tab rows, Settings → Voice Lab, copy style | `doc/design.md` |
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

`ElevenLabsVoiceLab` discovers models (`GET /v1/models`), subscription (`GET /v1/user/subscription`) and paginated voices (`GET /v2/voices`) through the selected ElevenLabs region. The caller on each platform selects a discovered model and voice. `VoiceRewriteService` takes a separate estimate and affirmative authorization for its selected LLM connector/model before sending source words and the user's instruction. It returns an inert proposal with original timed words intact. Rewriting a passage and rewriting the entire selected take are both supported requests. The service does not edit, synthesize, or follow URLs in model output.

Creating an Instant Voice Clone takes a verified own-voice consent record and speaker-match policy input, plus explicit authorization for that operation. Core retains `requires_verification` without treating a pending voice as usable. `listOwnClones` filters owned cloned voices from the paginated voice list; deletion is a separate authorized call. Stock selection allows only `premade`, or owner-created `generated`; `cloned`, `professional`, `famous` and unknown categories are denied. The own path requires a matching active consent identity, speaker match and completed provider verification.

Each paid action starts with preparation on the same service instance that will dispatch it: Swift uses `prepareClone`, `prepareDelete`, `prepareSynthesis` or `prepareConversion`; Windows uses `PrepareClone`, `PrepareDeletion`, `PrepareSynthesis` or `PrepareConversion`. Preparation performs no provider call. Its immutable quote binds the operation and caller request ID, provider/region/endpoint, displayed estimate, selected model/voice/language, consent identity and verification state, and all billable text or the SHA-256 of exact audio bytes. The caller shows that quote and authorizes it after an affirmative action, using `VoiceLabAuthorization(quote:approved:)` in Swift or the service’s `Approve` method in Windows. The service validates current inputs against the prepared quote, then consumes it before the first possible billable dispatch. Quotes are instance-scoped, hold at most 32 outstanding entries and cannot be replayed sequentially or concurrently. A changed input, model, region, voice, estimate or consent state needs a new quote and approval. A rewrite proposal's ID is the request ID when preparing synthesis of its approved text.

The first Core synthesis path uses documented `POST /v1/text-to-speech/{voice_id}/with-timestamps` for discovered TTS-capable models supported by that endpoint, raw `pcm_24000`, and validated character timing. It sends explicit `language_code` for supported models except `eleven_multilingual_v2`, whose documented behavior is language auto-detection. The quote exposes `explicit(language)` or `autoDetected(expected: language)` so the caller can show which mode will run. The language must be in the discovered model's language list. Eleven v4 and v4 Turbo are discovered but reported as unsupported by this endpoint; the documented Text to Dialogue path remains for later integration. Voice conversion uses `POST /v1/voice-changer/{voice_id}` for discovered conversion-capable models and the same PCM output. Its documented request has no language field, so Core requires the chosen language in the model's capability list and marks the quote as auto-detected rather than implying forced language selection. Conversion input must be a complete RIFF/WAVE file whose declared RIFF length ends at the actual file boundary. Every chunk length and odd-length pad must fit; ordinary ancillary chunks may appear before, between or after audio chunks. Exactly one unambiguous PCM `fmt ` chunk (16 bytes, or 18 with zero extension length) and one `data` chunk are required. Audio is mono, 16-bit PCM at 8–96 kHz, with byte rate and block alignment matching the format, whole samples, at least 20 ms and at most 290 seconds. The whole upload is limited to 16 MiB and the quote binds its exact bytes. Invalid input is refused before a paid send. Missing or malformed alignment makes timestamped TTS invalid. Empty, odd-length, oversized or structurally encoded output is invalid; raw PCM samples with header-like first bytes remain valid. Encoded conversion content types are invalid. A generation is sent once; the caller must make a new estimate and affirmative authorization before trying again. Estimates retain unknown currency and credit amounts when pricing is unavailable. A cancellation before dispatch sends nothing; after dispatch, cancellation or network loss is ambiguous and the same quote stays consumed. No clone, speech or conversion request is retried automatically. Discovery rejects malformed or duplicate model/voice identities, repeated cursors and more than 20 voice pages.

This Core boundary does not yet record consent, perform speaker embedding, join audio to the timeline, preview or undo a segment, or run lip sync. Those are required before the whole Voice Lab workflow is usable in the app. Both implementations consume the exact `shared/prompts/voice-rewrite.json` and `shared/fixtures/voice-lab/contract.json`, including the 31 conversion-input cases. Windows additionally validates clone samples declared as WAV with its complete mono-PCM16 parser; that stricter clone-input check is not yet shared by the Swift clone route. Conversion-input validation is shared.

## 3. Cost preview

### 3.1 Rule

Every action that can bill a provider shows an estimate **before** it runs.

```swift
public struct CostEstimate: Codable, Sendable, Hashable {
    public var provider: String          // "elevenlabs" | selected LLM connector | "fal" | "syncso"
    public var operation: String         // "voiceRewrite", "createClone", "deleteClone", "textToSpeech", "voiceChange", plus later media operations
    public var units: Double             // minutes, characters or seconds, per `unit`
    public var unit: String              // "minute" | "character" | "second" | "call"
    public var usd: Decimal?             // nil when the price is unknown
    public var credits: Int?             // ElevenLabs credits, when known
    public var basis: String             // "list-2026-10-25" | "provider-estimate" | "provider-pricing-api"
}
```

| Estimate | Presentation |
|---|---|
| under $0.50 and known | shown on the button: "Clean audio · ≈ $0.36", "Re-voice · 3 takes · ≈ $0.02". One click runs it |
| $0.50 or more, any lip sync, or unknown | a confirmation: "This will cost about {amount} on your {provider} account." (or "VoxClip can't tell what this costs. Check {provider}'s pricing.") with [Continue] and [Cancel] |

Amounts are formatted as "≈ $0.04": two significant digits, with "< $0.01" as the minimum.

Spend ledger and soft cap:

- `<data>/VoiceLab/spend.json` sums the estimates of actions that were run, per provider and calendar month.
- Settings → Voice Lab → "Warn me above $__ a month per provider" has no default. When an action would cross the cap, the confirmation adds "This takes you past your ${cap} limit for {provider} this month."
- The ledger is an estimate, not a bill. The provider's own credit quota, such as the restricted key's limit, is the hard stop.

### 3.2 Prices (API list prices, USD, checked 2026-10-25)

Prices live in a data file, `shared/catalog/voice-lab.json`, created with the M2 implementation, so they can be updated without code changes. Initial values:

| Operation | Price | Formula |
|---|---|---|
| ElevenLabs Scribe v2 (consent check, patch QA) | $0.22 per audio hour | `seconds / 3600 × 0.22` |
| ElevenLabs Voice Isolator | $0.12 per minute; 1,000 credits per minute on credit plans | `minutes × 0.12` |
| ElevenLabs Voice Changer | $0.12 per minute; 1,000 credits per minute | `minutes × 0.12` |
| ElevenLabs TTS `eleven_v4`, `eleven_v3`, `eleven_multilingual_v2` | $0.08 per 1,000 characters | `characters × candidates × multiplier / 1000 × 0.08`, with `multiplier = model_rates.character_cost_multiplier` from `GET /v1/models` (default 1) |
| ElevenLabs TTS `eleven_flash_v2_5`, `eleven_v4_turbo` | $0.04 per 1,000 characters | as above |
| ElevenLabs Forced Alignment | $0.22 per audio hour | as for Scribe |
| ElevenLabs Instant Voice Clone | no per-call charge (Starter plan or higher) | 0 |
| fal `fal-ai/latentsync` | $0.20 flat up to 40 s, then $0.005 per second | `0.20 + max(0, s − 40) × 0.005` |
| fal `fal-ai/sync-lipsync/v2`, model `lipsync-2` | $3.00 per minute | `s × 0.05` |
| fal `fal-ai/sync-lipsync/v2`, model `lipsync-2-pro` | about 1.67 × lipsync-2 | `s × 0.0835` |
| fal `fal-ai/sync-lipsync/v3` (sync-3) | not published on the model page | from the pricing API (§3.3), else unknown |
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

- **Where.** A row in the AI tab named **Clean audio** (`doc/design.md` §6.3). It has:
  - the button "Clean audio · ≈ $X";
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
3. Otherwise compute 10 ms RMS envelopes of the input and the output. Find the lag `L` in ±500 ms that maximises their normalised cross-correlation.
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

## 5. M3 beta: gate and settings

- Settings → Voice Lab → **Show Voice Lab (beta)**. It is off by default. Turning it on shows a one-time sheet:
  - "Voice Lab can clone your own voice, change your voice and re-voice a few words. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key and, for lip sync, your fal.ai or sync.so key."
  - Buttons [Turn on] and [Cancel].
- With Voice Lab on, the AI tab shows **My voice**, **Voice changer**, **Re-voice a phrase** and **Lip sync** (`doc/design.md` §6.3). Each row shows its cost line, what it sends, and the label that export will add.
- Settings → Voice Lab also shows:
  - the ElevenLabs, fal.ai and sync.so key rows (§2);
  - **My voices**: the consent records, with their voice name, creation date, ElevenLabs voice id, and [Delete voice];
  - the spend cap (§3.1) and the label position (§11.2);
  - Content Credentials (C2PA) for Clean-audio-only exports, on or off (§11.7; exports that need disclosure always carry a machine-readable mark);
  - storage.
- None of these features may block the core loop: import, cut, captions, clips, export.

---

## 6. My voice: consent-guarded own-voice clone (ElevenLabs IVC)

ElevenLabs' Instant Voice Clone API has no consent or verification step. Its response carries only `requires_verification`. VoxClip adds its own guard.

The app is open source, so the guard is good-faith friction and an audit trail, not security. The real backstops are ElevenLabs' terms and the traceability of its output to the user's account.

### 6.1 Preconditions

- The §2.3 gates pass, or cannot be checked.
- **Notice**, shown before anything is recorded. Exact text:
  > Your voice clone is created in your ElevenLabs account and stays there. ElevenLabs' terms let it use uploaded content, including your voice, to improve its services; you can opt out of training in your ElevenLabs account, but the opt-out is not retroactive. You can delete the voice at any time from VoxClip or ElevenLabs. ElevenLabs' Prohibited Use Policy applies, including its rules on political content.

  It links to `https://elevenlabs.io/terms-of-use` and `https://elevenlabs.io/use-policy`.
- **Attestations**: three checkboxes, all required:
  - "This is my own voice."
  - "I am 18 or older."
  - "I will use it only on videos of myself."
- **Display name**: 1 to 60 characters, used in the statement and the voice name.

### 6.2 Consent statement

A new statement is generated for each attempt:

| Language | Template |
|---|---|
| en | `My name is {name}. Today is {date}. This is my own voice, and I agree to an AI copy of it being made with ElevenLabs for editing my own videos. {w1} {w2} {w3} {w4}.` |
| et (draft, needs native review before release) | `Minu nimi on {name}. Täna on {date}. See on minu enda hääl ja ma nõustun, et sellest tehakse ElevenLabsi abil tehisintellekti koopia minu enda videote toimetamiseks. {w1} {w2} {w3} {w4}.` |

- **Language.** The statement uses the language of the most recent project transcript, or English.
- **`{date}`.** The local date written out in full. Use fixed month tables, not the OS locale, because the Windows build runs with `InvariantGlobalization`:
  - en: `25 October 2026`, months January … December;
  - et: `25. oktoober 2026`, months jaanuar, veebruar, märts, aprill, mai, juuni, juuli, august, september, oktoober, november, detsember.
- **`{w1..w4}`.** A nonce of four different words drawn with the system CSPRNG from `shared/voice-lab/nonce-words-<lang>.txt`. Create these lists with M3: at least 500 common words each, 4 to 8 letters, easy to pronounce, with no homophones of each other, no profanity and no names. The nonce defeats replaying an old recording.

### 6.3 Live recording

- The statement is recorded from the microphone in the app. Imported files are not accepted.
- Recording uses the M2 capture stack: 48 kHz mono, at least 5 s, at most 30 s, with a level meter and a "Read this aloud" teleprompter.
- The recording is kept in memory and in `<data>/VoiceLab/consent/<recordId>/statement.wav`.

### 6.4 Verification

1. **Transcribe.** Send the recording to ElevenLabs Scribe v2 (transcription.md §8) with `language_code` set to the statement language. Cost: under $0.01; shown on the button.
2. **Normalise.** Tokenise both texts on whitespace and normalise with `normalizeForMatch` (`editing.md` §4.7).
3. **Pass** only if all of these hold:
   - word-level WER (Levenshtein distance / expected word count) ≤ 0.15;
   - all four nonce words appear in the recognised tokens;
   - the recognised language matches the statement language.
4. **Attempts.** Three per 10 minutes. On failure, show "That didn't match the statement. Read it again, clearly, in one take." and generate a new statement for the next attempt.

### 6.5 Training samples

Choose one source:

- **(a) From the user's own takes.** These are projects with a transcript whose speaker passes §6.6 against the consent clip. Pick spans of words in which:
  - every `word` has `conf ≥ 0.8` (or conf is null);
  - there are no `event` or `unlabeledSpeech` items;
  - there is a single speaker label (or diarization is off);
  - the estimated SNR is at least 20 dB (median speech-frame RMS against the take's 10th-percentile frame RMS).

  Take 60 to 120 s in total, in spans of 5 to 30 s, preferring spans between pauses.
- **(b) A fresh read-aloud.** A 90 s script from `shared/voice-lab/scripts-<lang>.txt` (created with M3), recorded like §6.3.

Then process the samples:

1. Normalise each span to −20 dBFS RMS over voiced frames (frames above −45 dBFS), with true peak at most −3 dBTP.
2. Encode as AAC-LC 256 kbps, 44.1 kHz mono, in M4A: AVAssetWriter on macOS, FFmpeg's native `aac` encoder on Windows. The upload format is spike S5 (§14). The fallback is 16-bit WAV.
3. Upload at most 25 files, each at least 5 s long, totalling at least 10 s. The recommended total is 1 to 2 minutes. More than 3 minutes gives little improvement.
4. **Add the consent statement recording as one of the samples.** This makes the clone provably derived from the consenting speaker.
5. Set `remove_background_noise=false`. It "can make the quality worse" on clean audio. Use `true` only when the SNR is below 20 dB and Clean audio has not been applied to the source take.

### 6.6 Speaker match (on device)

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
- **Threshold τ.** It comes from calibration (spike S6). Set it where the false-accept rate is at most 1% on at least 200 impostor pairs, while at least 95% of 50 own-voice pairs pass. τ is stored per model in the catalogue. The ECAPA-class starting point is 0.6. **M3 does not ship without a calibrated τ.**
- **Clone creation.** Every training sample must score ≥ τ against the consent recording. If any sample fails, drop it. If the remaining total falls under 10 s, block with "Some of these recordings don't sound like the voice in your consent statement."

### 6.7 Create the voice

```
POST {base}/v1/voices/add
xi-api-key: <key>
Content-Type: multipart/form-data
  name                     = "{display name} (VoxClip)"
  files[]                  = <sample 1>   (one "files[]" part per sample, consent recording included)
  files[]                  = <sample 2> …
  remove_background_noise  = false
  description              = "VoxClip own-voice clone. Consent sha256:{statementSha256}. Created {RFC 3339 date}."
  labels                   = {"language":"et"}       (a JSON string. The API documents only the keys language, accent, gender and age, so the consent marker goes in description; spike S5 verifies the encoding)
→ 200 { "voice_id": "c38kUX8pkfYO2kHyqfFy", "requires_verification": false }
```

- `requires_verification == true`: do not use the voice. Show "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back." Store the record with `status: "verificationRequired"`.
- Errors map as in §4.3, with the permission `create_instant_voice_clone`.

### 6.8 Consent record

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
  "statement": { "language": "et", "text": "Minu nimi on …", "nonce": ["…", "…", "…", "…"],
                 "audioFile": "statement.wav", "audioSha256": "…", "stt": { "wer": 0.04, "transcriptionId": "…" } },
  "attestations": { "ownVoice": true, "adult": true, "ownVideosOnly": true, "acceptedAt": "2026-10-25T11:58:10Z" },
  "samples": [ { "sha256": "…", "seconds": 14.2, "source": "project", "speakerScore": 0.81 } ],
  "speaker": { "model": "<embedder id>", "threshold": 0.62, "embedding": "<base64 little-endian Float32 × dimension>" },
  "app": { "version": "0.3.0", "platform": "macos" }
}
```

- Sample audio is deleted after a successful upload. Only the hashes stay.
- The statement audio stays until the voice is deleted.
- The project file only references the record by `recordId` (§10.1).

### 6.9 Use-time guard

Before generating anything with the clone for a project, run the guard:

- **Patch mode:** embed up to 10 s of the project's speech nearest the patch.
- **Voice changer:** embed the first 30 s of speech in the range.

The cosine against the record's embedding must be ≥ τ. Otherwise block with "This doesn't sound like the voice owner. Voice Lab is only for your own videos." The default build has no override.

The result is cached per (project `contentKey`, `recordId`).

### 6.10 Deletion

[Delete voice] runs:

1. `DELETE {base}/v1/voices/{voice_id}` → `{"status":"ok"}`. A 404 also counts as deleted.
2. Delete the local statement audio.
3. Set `status: "deleted"` and `deletedAt`, keeping the record and its hashes as the audit trail.

Projects with segments that used the voice keep their rendered assets, which stay playable and labelled. They cannot generate new takes with the voice.

### 6.11 Which voices appear

Only voices with an active VoxClip consent record appear as "My voice". Other cloned or professional voices in the user's ElevenLabs account are never offered for re-voicing or voice changing.

A Professional Voice Clone path, where ElevenLabs runs its own voice-captcha verification, is a later upgrade and not part of the M3 beta.

---

## 7. Voice changer (speech-to-speech)

### 7.1 Targets

- **My studio voice**: the user's own consented clone (§6.11). This turns a noisy or tired take into the clone. The §6.9 guard applies.
- **Stock voices**, for anonymity or characters: `GET {base}/v2/voices?category=premade&page_size=100`, plus `category=generated` voices with `is_owner == true` (voices the user designed).
- Voices with `category` of `cloned`, `professional` or `famous` are never offered unless they are the user's consented clone.

### 7.2 Scope and chunking

- The scope is a selection of words, or the whole take. The converted range runs from the selection's first word start minus 0.1 s to its last word end plus 0.1 s, clamped to the neighbouring gaps.
- Chunks are at most 290 s, because the API maximum segment is 5 minutes. Split at the quietest 10 ms frame of the transcript pause (gap ≥ 0.4 s) nearest each 280 s mark.
- One request at a time. All chunks use one random `seed` from 0 to 4294967295, stored with the segment.

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
→ 200 audio bytes (WAV)
```

- **Duration check per chunk.** As in §4.4, but with a cross-correlation search of ±300 ms. The docs do not promise that timing is preserved.
- **Language.** The voice changer lists 29 languages, and Estonian is not among them. For a language not in the model's `languages`, require a 10 s preview first: "ElevenLabs doesn't list {language} for the voice changer. Listen to a 10-second preview before converting."
- **Preview.** "Preview 10 s" converts the first 10 s of speech in the scope. The cost is shown on the button.
- **Result.** Transcript words keep their source times, and captions are unchanged. The segment is stored as `kind: "voiceChanger"` (§10.1).
- **Label.** AI MODIFIED for the whole converted range, and for the whole clip when §11.1 makes it persistent (a converted range covering at least 50% of the exported clip).

---

## 8. Re-voice a phrase (patch mode)

### 8.1 Entry points

1. **Select words, then "Re-voice…".** The user types the new words. An empty field means "delete": that becomes a cut, and no AI is involved.
2. **Caret between two words, then "Insert words…".** This is an insertion.
3. **"Fix with AI…"** The user's LLM (`doc/spec/ai.md` connectors) proposes line edits for an instruction, for example "I said 2024; it's 2025".

   Fix with AI has its own prompt file, `shared/prompts/patch-rewrite.json` (created with M3), and its own schema name, `patch_edits`. It never reuses `tighten_edits` (`ai.md` §12.8). Its schema:

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
   - keep each line within 20% of its spoken length;
   - return an empty list when nothing should change.

   Validation:
   - `line` must match an emitted `[a-b]`; duplicates are dropped.
   - An edit that introduces digits, URLs or capitalised tokens (not at a sentence start) that appear nowhere in the transcript or the instruction gets a warning badge: "Check this: it adds something you didn't say."

All three paths end in the word diff (§8.2).

### 8.2 Word diff (LCS)

For each edited line, or each selected range plus its new text:

1. **Tokenise** both sides on whitespace (`editing.md` §4.5). Display keeps the surface forms.
2. **Normalise** for comparison with `normalizeForMatch` (`editing.md` §4.7).
3. **LCS.** Run a longest common subsequence over the normalised arrays with the O(n·m) DP. Ties prefer `delete` before `insert`, so output is deterministic. Emit `equal`, `delete` and `insert` operations.
4. **Replace hunks.** Merge each adjacent run of `delete` and `insert` into a `replace` hunk.
5. **Classify** each hunk:
   - **cut**: `delete` only. Its words join `edits.cutWordIds`. No AI.
   - **textOnly**: the normalised tokens are equal but the surface differs (case or punctuation). It becomes `edits.corrections`. No AI.
   - **voice**: `insert` or `replace`. It needs TTS.
6. **Merge voice hunks** separated by at most 2 `equal` words, or by at most 0.35 s of source time. The bridge words between them are re-voiced too, because fewer seams sound better.
7. **Display.** The transcript shows the diff inline: cut words struck in red, new words in green, re-voiced bridge words in amber. Each hunk has [Accept], [Reject] and [Edit text]. Voice hunks are disabled until an active "My voice" exists, with the action "Create your voice (2 min)".
8. **Header.** A live summary: "3 cuts · 2 re-voiced phrases (4.1 s of AI voice) · ≈ $0.02".

**Patch budget.** Re-voicing is for small fixes. When the inserted plus replaced words exceed 15% of the transcript's `word` items, or 60 words, voice hunks are disabled with "That's a lot to re-voice. Re-record these sentences instead."

### 8.3 Constants

```text
SEAM_MIN_GAP          = 0.12 s    a seam may sit in an inter-word gap at least this long
SEAM_SEARCH_WORDS     = 3         widen the window by up to 3 words on each side to find such a gap
SEAM_FADE             = 20 ms     equal-power crossfade at a seam in a gap
HARD_SEAM_FADE        = 12 ms     at a seam on a word boundary with no gap
TTS_TRIM_LEAD         = 0.03 s    keep before the first aligned character
TTS_TRIM_TAIL         = 0.06 s    keep after the last aligned character
STRETCH_OK            = [0.92, 1.08]   pitch-preserving stretch range (±8%)
PAUSE_SLACK_KEEP      = 0.15 s    silence kept next to a word when a seam borrows pause time
RETIME_VIDEO_OK       = [0.80, 1.25]   video retime range for zoomCover
LOUDNESS_NEIGHBOURHOOD= 3.0 s     on each side of the window
VOICED_FRAME          = −45 dBFS  10 ms RMS
GAIN_CLAMP            = ±12 dB, then a true-peak limit of −1 dBTP
ROOM_TONE_MIN_RUN     = 0.5 s     searched inside gaps of at least 0.5 s
ROOM_TONE_XFADE       = 50 ms
CANDIDATES            = 3
PREV_TEXT_MAX         = 100 characters (Text to Dialogue, API limit), 300 (Text to Speech, VoxClip limit)
```

### 8.4 Window and join placement

For each accepted voice hunk replacing source words `[a..b]`, or inserting between `k` and `k+1`:

1. **Left seam.** Look left from `a`, over up to `SEAM_SEARCH_WORDS` words, for a gap of at least `SEAM_MIN_GAP`.
   - If one is found, place the seam at the **centre of the quietest 10 ms frame inside that gap**. The words between the gap and `a` become left bridge words.
   - Otherwise, place the seam at `a.start − min(0.03, gapBefore / 2)` and use `HARD_SEAM_FADE`.
2. **Right seam.** The mirror image: look right from `b`.
3. **Insertions.** If the gap between `k` and `k+1` is at least `SEAM_MIN_GAP`, both seams lie inside it, `PAUSE_SLACK_KEEP` from each word. Otherwise treat it as a replace of `k+1` with bridging.
4. **Window.** `W = [seamIn, seamOut]`, and the patch text is left bridge + new words + right bridge.

### 8.5 TTS request

The model comes from `GET {base}/v1/models`. Keep entries with `can_do_text_to_speech` whose `languages[].language_id` include the take's language. The selected model must support the selected endpoint. These are examples for future A/B testing, not sole choices:

1. `eleven_v4`
2. `eleven_v3`
3. `eleven_multilingual_v2`, for its 29 languages, when the user picks it in the per-voice A/B preview

On first use of a voice in a language, the user hears a 10 s A/B preview of the candidate models and the choice is remembered per voice.

**Primary request (eleven_v4).** The models page says v4 is available "via the Text to Dialogue API":

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
  "previous_text": "<≤100 characters of transcript before the window, cut at a word boundary>",
  "future_text": "<≤100 characters after the window>",
  "apply_text_normalization": "auto"
}
→ 200 { "audio_base64": "…", "alignment": { "characters": […], "character_start_times_seconds": […],
        "character_end_times_seconds": […] } | null, "normalized_alignment": … | null, "voice_segments": […] }
```

**Alternative request (eleven_v3 or multilingual v2, explicitly selected after a new estimate when v4 is unavailable):**

```
POST {base}/v1/text-to-speech/{voice_id}/with-timestamps?output_format=pcm_24000
{
  "text": "<patch text>",
  "model_id": "eleven_v3",
  "language_code": "et",                      // omit for eleven_multilingual_v2
  "voice_settings": { "stability": 0.5, "similarity_boost": 0.8 },
  "seed": <candidate seed>,
  "previous_text": "<≤300 characters before>",
  "next_text": "<≤300 characters after>",
  "apply_text_normalization": "auto"
}
→ 200 { "audio_base64": "…", "alignment": … | null, "normalized_alignment": … | null }
```

- **Audio.** With `pcm_*` formats, `audio_base64` is raw 16-bit little-endian mono PCM at that rate. Resample to the source rate.
- **Alignment.** Use `alignment`, not `normalized_alignment`, so caption text equals the typed text ("2025", not "twenty twenty-five"). The current Core timestamped path rejects null or malformed alignment. The later media QA path may use the Scribe/interpolation recovery in §8.8, after it is implemented and tested; null alignment must never be presented as timestamped speech.
- **Pronunciation.** The user may type a respelling for a word ("say it like"). eleven_v4 also accepts IPA wrapped in `/…/`. The respelling is sent as the text; the caption keeps the typed word.
- **Retries.** Synthesis, voice conversion, clone creation and deletion are never retried automatically: a timeout can mean ElevenLabs already billed or completed the request. A different endpoint or model needs a new estimate, review and affirmative authorization. The current Core paths do not invoke Text to Dialogue v4; its timing and model capability must be verified separately before it is offered.

### 8.6 Candidates

- Generate `CANDIDATES` takes with seeds `s`, `s+1` and `s+2`, where `s` is a random UInt32 per hunk stored with the segment. Run them sequentially.
- Each candidate goes through §8.7 to §8.11. A candidate is **rejected** when it fails QA (§8.11), when the clipping check fails, or when the speaker score is below τ.
- Rank the rest by `score = 0.6 × (1 − min(1, |r − 1| / 0.25)) + 0.3 × matchRatio + 0.1 × flatness`, where:
  - `r` is the raw duration ratio (§8.9);
  - `matchRatio` is the LCS ratio from §8.11;
  - `flatness = 1 − min(1, stdev(momentary LUFS over the candidate) / 6)`.
- Show the best candidate. The user can audition all three ("Take 1 · 2 · 3") and pick one.
- If all three are rejected: "These takes didn't sound right. Try different wording or re-record."

### 8.7 Trim, level, room tone

1. **Trim** the TTS audio to `[firstCharStart − TTS_TRIM_LEAD, lastCharEnd + TTS_TRIM_TAIL]` using `alignment`. When alignment is null, use the first and last 10 ms frame above `VOICED_FRAME`.
2. **Level.** Take voiced frames in `±LOUDNESS_NEIGHBOURHOOD` around `W` from the source audio (or from the Clean audio when it is on). Gain the TTS so its voiced-frame RMS matches theirs, clamp the gain to `GAIN_CLAMP`, then apply a true-peak limit of −1 dBTP.
3. **Room tone** (only when Clean audio is off):
   - Find the quietest 0.5 s run (sliding 10 ms RMS) inside source gaps of at least 0.5 s.
   - Loop it under the patch at its natural level, with 50 ms crossfades between loops.
   - Store the room-tone source range with the segment. With Clean audio on, skip room tone: both sides are already clean.

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

1. **Check.** The derived tokens (normalised) must equal the patch text's tokens.
2. **Fallback, in order**, when the check fails or the alignment is null:
   1. Forced Alignment, but only when the language is in `eleven_multilingual_v2`'s `languages`. That list does not include Estonian.
      ```
      POST {base}/v1/forced-alignment
      multipart: file = <candidate WAV>, text = <patch text>
      → { "characters": [{text,start,end}], "words": [{text,start,end,loss}], "loss": … }
      ```
   2. Otherwise, the Scribe words from the QA pass (§8.11), LCS-matched to the patch tokens. Their times are copied. Unmatched tokens are interpolated between neighbours in proportion to character count.
3. **Times.** Word times are relative to the trimmed segment start, multiplied by the stretch factor (§8.9). The words are marked `synthetic: true`.

### 8.9 Duration fit

Let `r = duration(trimmed TTS) / duration(W)`:

1. **Within range.** If `r ∈ STRETCH_OK`, apply a pitch-preserving time-stretch to exactly `duration(W)`. The output timeline is unchanged, and the video stays source video.
   - macOS: `AVAudioUnitTimePitch` (`rate = r`) in `AVAudioEngine` offline manual rendering.
   - Windows: FFmpeg's `atempo` filter (libavfilter, LGPL), `atempo = r`.
2. **Borrow pause time.** Otherwise:
   - If the TTS is longer, widen `W` into the neighbouring gaps, keeping at least `PAUSE_SLACK_KEEP` of silence next to each kept word.
   - If the TTS is shorter, pad room tone (or silence) equally at both seams, up to 0.3 s per side.
   - Recompute `r`. If it now falls in `STRETCH_OK`, go to step 1.
3. **Change the timeline.** Otherwise the output length changes (`outDuration ≠ inDuration`), and a video mode is needed:
   - **`zoomCover`** (the default without lip sync): a jump cut to 1.12× around the face during the replaced range, with source frames retimed by `duration(W) / outDuration`. Only allowed when that factor is in `RETIME_VIDEO_OK`.
     - Face centre: Vision `VNDetectFaceRectanglesRequest` on macOS, `Windows.Media.FaceAnalysis.FaceDetector` on Windows, sampled every 0.5 s and averaged.
     - With no face, use the frame centre.
   - **`lipsync`**: §9, with `sync_mode = "remap"`.
   - Otherwise the hunk is rejected: "This change is too long to patch. Re-record this sentence instead."

The audited Windows runtime now includes `atempo`; its reproducible build and native graph evidence are recorded in `tools/ffmpeg-build/README.md`. The graph's first output PTS of zero does not establish a proportional body origin or exact output duration. Finite-window count differences and marker shifts must be handled and verified in the production composition path with the declared trim and seam handles. The app and CLI guards remain until that path passes; the runtime prerequisite alone does not enable rendering.

### 8.10 Seams

- Apply equal-power crossfades of `SEAM_FADE` at both seams, or `HARD_SEAM_FADE` at hard seams. The synthetic audio and the source audio overlap by the fade length, centred on the seam.
- The plan's 5 ms join fades (`editing.md` §7.7) still apply at cut joins elsewhere.

### 8.11 QA gate (before Accept is enabled)

1. **Re-transcribe** the final patched window, `[seamIn − 0.5 s, seamOut + 0.5 s]` of the mixed audio, with Scribe v2 and `language_code`. Compare the normalised recognised tokens inside the window with the intended text, bridge words included:
   - for 5 tokens or fewer, require exact equality;
   - otherwise require an LCS ratio of at least 0.9 (`2 × LCS / (expected + recognised)`).
2. **No clipping.** The sample peak is below 0 dBFS after the limiter.
3. **Loudness jump.** The momentary loudness (400 ms, BS.1770) jumps by at most 2 LU across each seam.
4. **Speaker.** The TTS's embedding scores ≥ τ against the consent embedding. This catches voice drift.

QA results are stored with the segment (§10.1). A candidate that fails is not offered.

### 8.12 Accept

Accepting stores the segment (`kind: "tts"`) with its assets, words, provenance and QA, as one undo step.

- While the segment is enabled, the source words inside `[firstWordId, lastWordId]` are covered (§10.2).
- [Turn off] keeps the segment but plays the source.
- [Delete] removes it.

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
   - Spike S8 verifies the lifecycle header that limits retention of the uploaded files.
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
3. **Poll** with `GET https://api.sync.so/v2/generate/{id}?wait=true&timeout=10&include=progress`, repeatedly.
   - Statuses: `PENDING`, `PROCESSING`, `COMPLETED` (with `outputUrl` and `outputDuration`), `FAILED`, `REJECTED` (with `error` and `errorCode`).
   - The deadline is 30 minutes.
4. **Errors.** A 429 with `errorCode: concurrency_limit_reached` waits `retryAfterSeconds` and retries with the same Idempotency-Key. Other error bodies show `message` and `suggestion`.
5. **Cleanup.** Delete the uploaded assets after the download (the Assets API "Delete Asset" endpoint; spike S8 confirms the path).
6. **Watermarks.** Hobbyist-plan output is watermarked. Before the first sync.so job, show "sync.so adds a watermark on its Hobbyist plan."

### 9.6 Concurrency

One lip-sync job per provider at a time, queued. Progress shows "Lip sync · queued (3)" → "Lip sync · 40%" → "Lip sync · downloading", with [Cancel].

---

## 10. Data model: AI segments in the edit plan

### 10.1 Version 2 project representation (ADR-R24)

`schemaVersion: 1` continues to require exactly `voiceLab: {"segments": []}`. A project that stores generated media may use `schemaVersion: 2` and a `voiceLab` object with required `assets` and `segments` arrays. An ordinary project is not rewritten to v2 merely because the app understands this format. Both native Core serializers retain unknown reverse-DNS `extensions` when they load and save all supported versions. Current readers reject version 4 or later.

A v2 asset is `{id, kind: "audio", file, sha256, durationSeconds, sampleRate, createdAt}`. `file` is a relative `<projectId>/<assetId>.wav` or `.flac` name under the paid VoiceLab store. Asset IDs used as file components contain only lowercase ASCII letters, digits, `_` and `-`; Windows device names (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, `lpt1`–`lpt9`) are rejected. There is no colon, trailing dot/space, absolute path, URI, parent traversal or backslash path. A project carries no audio bytes, credentials, or consent-statement recording. Assets are immutable paid outputs and delete/disable operations do not erase them. A media adapter must resolve the store path, verify SHA-256 and duration before rendering; this Core round only validates the reference and plans pieces.

A v2 segment has `{id, kind, enabled, replace, outDuration, audio, text, words, provenance, qa, candidates, selectedCandidateIndex}`. `kind` is `tts` or `voiceChanger`. `replace` has source seconds `start` and `end` plus `firstWordId` and `lastWordId`; this round supports positive-length passage and full-take replacement. Insertion (`afterWordId` and a zero-length source range) is reserved for a later version with an explicit inverse mapping rule. `audio` identifies the selected asset, trim bounds, stretch and gain. `outDuration` must equal the trimmed asset duration times stretch within one asset sample. `candidates` retain their asset IDs, score and rejection reason; the selected index must name an unrejected candidate and match `audio.assetId`. `provenance` records provider endpoint name, model, voice ID, optional consent **record ID**, optional request ID, optional seed and creation time. `qa` has optional transcript match, loudness jump, peak and speaker score. All persisted numbers must be finite.

For `tts`, `text` contains original and new spoken text and `words` contains positive, ordered times relative to the output start, each with a `synthetic` flag. `synthetic: false` marks a bridge word whose text was kept although its audio was re-voiced. `voiceChanger` stores `text: null` and `words: null`; captions retain the source words. This v2 object is the first audio-only project format, not the final Voice Lab schema.

**Historical v2 omissions.** Version 3 now specifies these fields in §10.4. Version 2 does not imply defaults for any omitted field:

| Area | Required later representation or behavior |
|---|---|
| Voice and clean audio | `voiceLab.cleanAudio` and owned `voices` with consent record ID, provider, voice ID and display name (§4.7, §6.8). A project stores no consent statement recording. |
| Audio assembly | `audio.roomTone` with source start/end and gain, null when Clean audio is on; `audio.seamFadeMs` with in/out values. Generated seams use equal-power fades, not the ordinary 5 ms join fade (§8.7, §8.10). |
| Voice changer | `audio.chunks: [{sourceStart, sourceEnd, requestId}]`, the `eleven_multilingual_sts_v2` model and the seed used for every chunk (§7.2–7.3). The v2 audio record cannot describe or schedule these chunks. |
| Video and lip sync | Video assets need duration, frame rate, width and height. Segment `video.mode` needs `source`, `zoomCover`, `retimed` and `lipsync`; zoomCover stores zoom and source-frame retime. Lip sync stores asset ID, provider, model, request ID, source window start/end, replacement start/end and sync mode. Source mode uses original frames; zoomCover uses the stored face centre; lip sync uses its generated frames and three-frame crossfades (§8.9, §9). |
| Generation record | Each candidate needs its seed alongside asset ID, score and rejection; provenance needs selected candidate index and cost in USD as well as provider/model/request metadata (§3, §8.6). The v2 index selects an asset but cannot reconstruct those missing details. |
| QA and disclosure | Apply the transcript, loudness, peak and speaker QA gates (§8.11). Derive per-export AI kinds and duration, visible disclosure and provenance output (§11); do not infer finished disclosure from v2 captions alone. |

Core validation rejects missing/dangling assets, duplicate IDs, unsafe files, malformed or out-of-bounds ranges, source words crossing a replacement seam, conflicting enabled replacements, invalid candidates, nonfinite values and invalid relative word timing with typed Voice Lab errors. Disabled segments remain saved, but do not replace source. Asset existence and hash checking belong to the Media preparation boundary in §10.4; missing assets must stop a synthetic render rather than silently play original audio.

Replacing the source transcript clears segments whose word IDs and ranges belonged to the old transcript, while retaining the paid asset list. A later workflow can offer explicit reattachment; this round does not guess a match from new timings.

### 10.2 Deterministic output pieces

`VoiceLabOutputPlanner.build(project, scope)` in each Core has explicit `full` or `clip(id)` scope. Full scope ignores `edits.activeClipId`. It returns ordered `source` and `synth` output pieces with half-open source and output sample bounds, derived duration, source/edited mapping and caption words. Replacement bounds and `outDuration` are rounded with the existing JavaScript half-up sample rule at the source audio rate. Source word times and stored cuts never change.

Mapping probes round to that sample grid before lookup. As in the existing `EditPlan`, `sourceTime(output duration)` returns the full source duration even for a selected clip whose last output piece ends earlier; probes within the output use the selected pieces. This endpoint convention preserves existing clip callers while the explicit piece bounds identify the actual last included source sample.

Enabled replacements may touch at a seam but cannot overlap. An enabled range covers source words fully inside it; their individual cuts and corrections are dormant while enabled. A cut from a neighboring word or pause stops at the synthetic seam. A clip may fully include or exclude a replacement, but a clip boundary through one is rejected as an invalid scope. Source intervals outside replacements retain the existing subtractive edit plan, including cuts, pause breath and clip range behavior. Disabling or deleting the segment restores that plan and its original source captions. A synthetic output piece contributes its rounded `outDuration`; source-to-edited and edited-to-source positions inside it interpolate linearly between its rounded bounds. Source captions within `voiceChanger` pieces follow that mapping, with the original source text. `tts` captions use the relative output word times. Core's `requireLegacyRendering` capability check throws for any active synthetic piece; old `EditPlan`-only Media, app and CLI consumers must call it before preview/export until they render these output pieces. There is no source-only fallback for active synthetic audio. The app preview and render-request boundaries and both CLI plan/export entry points enforce this check for their explicit scope. An included replacement returns “This build cannot preview or export generated voice segments yet. Your video and edits are still here.” CLI reports `exportFailed` with exit 5 before encoding or creating output files. A source-only clip that excludes all enabled replacements and a project with only disabled replacements continue through the ordinary renderer.

The shared `passage-project.voxclip`, `full-take-project.voxclip` and `plan-cases.json` fixtures under `shared/fixtures/voice-lab/` are generated by `tools/fixtures/voice-lab/generate.py` and consumed by both native Core tests. The separate `project-plan-README.md` describes them; the original provider-service `README.md` and `contract.json` stay unchanged. They contain no provider output or binary media.

### 10.3 Undo

Accept, turn off, turn on, delete, choosing another candidate, and changing the lip-sync tier are each one undo step. Undo never deletes assets. Unreferenced assets are removed when the project is closed, after 7 days.

The v2 Core functions return new project values for accept, enable/disable, delete and candidate selection. They do not register app `UndoManager`/`EditHistory` steps. App undo wiring, lip-sync tier changes and eventual asset cleanup remain integration work; no Core transition deletes a paid asset.

### 10.4 Paid-audio Media boundary (2026-10-26)

Mac `VoiceLabAssets.prepare(project:plan:paidRoot:)` and Windows `VoiceLabAssets.PrepareAsync(project, plan, paidRoot, cancellationToken)` validate the project through Core and prepare only `synth` pieces in the explicit full or clip plan. Before preparation, Media rebuilds the plan from the current project and selected scope and requires its sample grid, ordered pieces and captions to match; a changed caption correction invalidates an earlier plan even when audio pieces are unchanged. Results are keyed by segment ID, so two segments may select the same paid asset with different trims. A prepared handle gives the selected asset ID, a private audio snapshot URL/path, decoded sample rate, channels and frame count, half-open trim frames, stretch and gain. Trim seconds use JavaScript half-up rounding on the **asset's** sample grid. Core already owns the piece's source/output bounds and verifies its `audio.assetId` against the selected candidate; Media checks the selected file bytes before composition. The caller retains the handle through preview/export and releases it afterwards; release removes only the private snapshot, never the paid file.

The caller supplies the paid Voice Lab root. A v2 `asset.file` remains exactly `<projectId>/<assetId>.wav` or `.flac`; it is resolved below that root, with symlink/reparse escapes rejected. Mac uses `O_NONBLOCK` when opening the final file and rejects nonregular files before reading, so a named pipe cannot stall preparation. Media streams the paid file into a private snapshot while computing SHA-256. It decodes and checks that snapshot, and future composition must consume **that same snapshot**, closing the path swap between validation and rendering. It rejects missing, altered, unreadable, unsupported, malformed, wrong-rate or wrong-duration audio with typed errors before a synthetic render. Lengths are bounded to 8 GiB, 24 hours of 192 kHz samples, 1–8 channels and 8–192 kHz; decoded duration may differ from the stored duration by at most one native sample. Cancellation removes only incomplete snapshots. No failed check substitutes source audio.

macOS uses AVAudioFile for WAV and for FLAC when the installed Core Audio decoder can open it; unsupported codec data fails with `unsupportedFormat`. The current pinned Windows runtime has no FLAC decode/container path (`tools/ffmpeg-build/components.md`), so Windows returns `UnsupportedFormat` for `.flac`. Its portable Media boundary validates RIFF/WAVE PCM16/24/32 or IEEE float32/64 samples and rejects other WAV codecs as unsupported. Windows-native reparse and decoder acceptance still need a Windows run before a release claim. The paired tests generate the same 24 kHz mono PCM16 tone in code; no generated voice or provider output is a fixture.

Next composition call sites are Mac `EditorModel` preview and render requests, `CLIWorkflow`, and `CompositionBuilder`; Windows `EditorViewModel`, `CliOperations` and the Media preview/export pipeline. They must retain prepared handles and use `VoiceLabOutputPlan.pieces` for mixed source/synth composition before lifting any `requireLegacyRendering` check. This boundary does not add v2 fields for room tone, seams, video retiming, consent, disclosure or lip sync. Version 3 defines those explicit recipes in §10.5; native composition and workflow gates remain required before an enabled replacement can render.

### 10.5 Version 3 render recipe and preparation (ADR-R26)

Version 3 adds explicit `voiceLab.cleanAudio`, `voices`, and `videoAssets` and requires every unrejected candidate to carry a complete `recipe`. `cleanAudio` records `off` with null asset and mix, or `on` with an asset and mix; Core reports `cleanAudioUnsupported` for active non-null use until Media implements it. A segment records `scope: passage | fullTake`; a full-take group covers the take without the patch 15%/60-word budget. Candidate recipes record asset trim, pitch-preserving fit, gain, relative words, bounded source and assembled chunk spans with request IDs and seeds, room tone or explicit null, in/out seam policy, tagged video mode, applicable QA, provenance, cost quote and own/stock voice source. `usd: null` means the price was unknown. The source transcript, word times, cuts and reverse-DNS extensions remain unchanged. No v2 segment is promoted automatically; recovery needs explicit future per-segment review.

`VoiceLabRenderContract.prepare(project, scope, labelPosition)` uses `VoiceLabOutputPlanner` as the sole source of ordered pieces, mapping and captions. It returns an immutable selected-recipe snapshot and `VoiceLabDisclosurePlan` for that exact project, scope and position; downstream consumers must call `verify` before using it. Full ignores `activeClipId`; a clip cannot bisect an enabled replacement. Disabled and excluded replacements remain source-renderable. Candidate selection transfers the complete validated candidate recipe into segment fields, and accept/enable/disable/delete remain reversible project transitions that never delete paid assets. New own-voice acceptance requires an active consent reference; a previously accepted asset remains playable after voice deletion because rendering uses its stored consent evidence, not a provider lookup or a new speaker match. A record is evidence of generation/accept review, not speaker verification by itself.

All source intervals use JavaScript half-up rounding on the source sample grid; trim and handle frames use the asset sample grid. A centered N-frame seam has left half `floor(N/2)` and right half `N − floor(N/2)`. Equal-power gains use `u = i/(N−1)` for `N ≥ 2`, with exact endpoints. Stored gap seams use 20 ms and hard seams 12 ms; real take edges use explicit `none`. Touching synth pieces share one agreeing seam. Missing handles, a fade shorter than two frames, a clip ending on an internal seam, or overlapping windows fail preparation without shortening a fade or swallowing even a one-sample source gap. Ordinary source cut joins retain their separate 5 ms linear fade. Passage TTS with Clean audio off requires the stored 0.5 s room-tone run; full take and voice changing have an explicit null policy when room tone is not needed.

An incoming synth seam needs `floor(N/2)` output samples of asset handle before its trim; an outgoing seam needs `ceil(N/2)` after its trim, including when two synth pieces share the seam. For a needed half of `k` source-grid output samples, the minimum raw handle is `ceil(k × assetSampleRate / (sourceSampleRate × audio.stretch))` asset frames. A touching synth seam has zero source handle on both sides and keeps the one N-frame fade.

`video.mode` is one of `source`, `retimed`, `zoomCover`, or `lipsync`, with mode-specific data validated and retained. The current render capability accepts only `source` when rounded replacement input/output sample lengths are equal. Other known modes and changed-duration source mode report `videoModeUnsupported`; unknown mode strings and integer enum values are invalid. Pitch-preserving audio fit is limited to `[0.92, 1.08]`; retime policies validate `[0.80, 1.25]`. TTS requires timestamped alignment, applicable transcript and calibrated speaker QA evidence; stock voice changing does not inherit TTS-specific transcript/speaker gates. Core does not claim a QA record proves actual speaker verification.

The prepared disclosure derives kinds, synthetic output seconds, persistence (`voiceChanger ≥ 50%` or all AI `> 30%`), first exposure `[0,min(3,duration)]`, and clamped segment intervals expanded by 0.5 s and merged when their gap is less than 1 s. It stores 150 ms fades, chosen position and language-specific post text. It does not draw a label, write XMP/sidecar output or accept a render. The actual app/CLI legacy synth guards remain in force until native composition and visible/provenance output share the prepared contract.

**Guarded Mac renderer.** Media renders reviewed, equal-rounded-length v3 source-video recipes with unity audio fit through `CompositionBuilder` for preview, MP4 and edited WAV without changing the app/CLI active-synthetic guards. It validates the prepared request and source identity, snapshots paid audio, stages bounded source/mixed/fitted CAF on the source grid, and retains those files through player or reader completion. Synthetic tests compare decoded MP4 AAC waveform levels, correlation and marker positions with production edited WAV across passage, full-take and touching-piece routes while allowing one AAC priming packet at the boundary. The player test verifies graph and scratch lifetime after load and close; it does not establish audible playback.

Nonunity pitch-preserving fit is a typed `pitchPreservingFitUnverified` capability refusal before paid snapshot, scratch or output creation. Only numerical roundoff within four binary64 ULPs of unity takes the unity path. The direct offline `AVAudioUnitTimePitch` diagnostic still uses the inverse of stored stretch and bounded CAF rendering for measured experiments; its full frame count does not prove that body and declared seam handles survived. A first-channel, level-gated waveform heuristic previously accepted right-only and quiet copies of full-take and extra-preroll signals that it refused at normal mono level. It is not a production acceptance check. Subsequent native diagnostics reproduced an undetected middle pulse and measured tail timing drift, but did not reproduce an absent tail packet; a failed detector must not be described as proven content loss. Three tested neutral prime/drain policies failed the full provisional criteria despite returning enough frames for the nominal crop. Those diagnostic limits do not define shipping tolerances or establish a universal processor defect. The diagnostic results are retained outside the source tree for a later measured prime, drain and crop policy; that policy is not yet established.

Mac export estimates planned peak scratch, muxing, XMP stage, metadata and prior-output rollback bytes across the actual volumes before creating snapshots or output, then rechecks as work advances. After destination and prepared-request safety checks, an empty output timeline fails with `everythingCut` before the WAV size estimate, capacity check, source reader, paid snapshot or output staging. For combined CLI output, the same transaction preflight also includes the edited WAV partial before WAV staging; an already staged WAV is reflected in free space and is not counted again. A known WAV frame count beyond the RIFF limit fails before reader, snapshot or output creation. There is no fixed 15 GiB product reserve. A sidecar partial is removed only after this invocation exclusively creates it. The app bundle supplies the version for provenance; CLI supplies its declared version explicitly, and a missing version fails before export. Generation, live providers, consent capture, changed-duration video, other video modes and lip sync remain outside this guarded renderer.

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

When `required`, a disclosure line is appended to the caption text that Copy caption, Open X, Open LinkedIn and VoxConvo publish use (`doc/publishing.md` §2.1). It sits on its own paragraph after a blank line.

| Condition | en | et (draft, needs native review) |
|---|---|---|
| `tts` | Some words in this video were re-voiced with an AI copy of my own voice. | Mõned sõnad selles videos on loetud minu enda hääle tehisintellekti-koopiaga. |
| `voiceChanger`, own clone | The voice in this video was converted with AI into a copy of my own voice. | Selle video hääl on tehisintellektiga muudetud minu enda hääle koopiaks. |
| `voiceChanger`, stock voice | The voice in this video was changed with AI. | Selle video häält on muudetud tehisintellektiga. |
| also `lipsync` (appended sentence) | Lip movements in parts of it were generated with AI. | Osa huulte liikumisest on loodud tehisintellektiga. |

- The language is the transcript language when that is `et`, otherwise English.
- The user may edit the line. Removing it shows "Your post no longer says the video contains AI-modified parts." before sharing, with [Share anyway] and [Restore line].
- Truncation for X (`doc/publishing.md` §2.1) and for VoxConvo's 2,048-character `text` cuts the caption body. The disclosure line is never cut.

### 11.4 X

- **M1-style intent links** (`https://x.com/intent/post?text=…`) cannot set a disclosure flag. When `required`, Open X also shows a checklist tip: "Turn on 'Made with AI' in the post's content disclosure before posting."
- **Posting through the X API** (`doc/publishing.md` §5): `POST https://api.x.com/2/tweets` must include `"made_with_ai": true`, which is described as "Disclose that the tweet contains AI-generated media". The flag reportedly cannot be changed after posting.

### 11.5 LinkedIn

LinkedIn's posting API has no disclosure field. The post text line is the disclosure. C2PA (§11.7) is embedded in the MP4 when enabled. LinkedIn shows a "Cr" icon for C2PA credentials it reads; whether that happens for a self-signed manifest, and whether the manifest survives its transcode, is unverified.

### 11.6 VoxConvo

- The publish call (`doc/publishing.md` §3.5.3) adds `aiDisclosure: { "modified": true, "kinds": ["tts","lipsync"], "aiSeconds": 4.1 }` to `NewPostInput`, and the text carries the line from §11.3.
- This needs a vox-api schema change and a vox-web badge. Both go in the publishing change lists before M3.
- `doc/publishing.md` §5.2 uses the same `aiDisclosure` object for cross-posting, plus the disclosure line.

### 11.7 Machine-readable marking: XMP and C2PA Content Credentials

- **Mandatory mark.** When `required` is true (§11.1), the export **must** carry a machine-readable mark, and the default build offers no way to turn it off. Both platforms embed XMP metadata in the MP4 with `Iptc4xmpExt:DigitalSourceType = http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia`. This needs no optional component.
- **MP4 staging (ADR-R27).** Finalize the native muxer output first. Validate its top-level boxes, then copy it with bounded buffers to a distinct, exclusively created stage and append one standard Adobe XMP UUID box (`BE7ACFCB-97A9-42E8-9C71-999491E3AFAC`). Existing XMP, malformed box bounds and size-zero boxes are rejected before staging; do not strip or silently replace provider marks. The completed copy retains the original media bytes and chunk offsets. This supersedes only the earlier AVAssetWriter metadata / FFmpeg `udta` implementation route: the tested metadata calls did not retain XMP in their finished MP4s.
- **Hash and publish.** Bind a detached provenance snapshot to the verified project and prepared render before asynchronous I/O. Reserve disk for the additional MP4 copy before starting output. Hash the final marked MP4 after all metadata changes, including C2PA if present, and generate §11.8's sidecar with the intended published basename and actual app version. Stage the sidecar separately and publish the MP4, sidecar and requested SRT/WAV together through the existing export transaction. Cancellation or any marking, sidecar or publication failure preserves existing destination files and cleans only owned stages; an unmarked intermediate must never become the published export.
- **Acceptance.** Independently extract the finished MP4's XMP and verify the exact IPTC RDF property, one top-level Adobe XMP UUID and the sidecar's hash of the final bytes. Run these checks through each production export path, including cancellation and publication rollback. Helper-only probes do not establish compositor, preview, transaction or app/CLI acceptance; the active-synth guards remain until the complete route passes.
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
  "export": { "file": "intro-9x16.mp4", "sha256": "…", "durationSeconds": 42.317, "createdAt": "2026-10-25T12:30:00Z" },
  "source": { "contentKey": "…", "durationSeconds": 612.4 },
  "edits": { "cutWords": 17, "cutPauses": 4, "corrections": 2 },
  "cleanAudio": { "provider": "elevenlabs", "endpoint": "audio-isolation", "mix": 1.0 },
  "aiSegments": [
    { "kind": "tts", "outputStart": 12.10, "outputEnd": 13.78, "text": "I said 2025",
      "provider": "elevenlabs", "model": "eleven_v4", "voice": "own-clone", "seed": 3141592653,
      "lipsync": { "provider": "fal", "model": "fal-ai/latentsync" } }
  ],
  "disclosure": { "required": true, "persistent": false, "labelIntervals": [[0, 3.0], [11.6, 14.28]],
                  "postText": "Some words in this video were re-voiced with an AI copy of my own voice.", "c2pa": true },
  "consent": [ { "recordId": "6f0c2c1e-…", "statementSha256": "…", "createdAt": "2026-10-25T12:00:00Z" } ]
}
```

The sidecar never contains keys, voice samples, consent audio, embeddings or file paths outside the export folder.

### 11.9 Watermarks and metadata

VoxClip never removes, alters or hides ElevenLabs SynthID watermarks or provider metadata, as ElevenLabs' Prohibited Use Policy requires. Ordinary gain, stretch, crossfade and encode steps are allowed. No step may be added whose purpose is to defeat detection.

### 11.10 Legal review gate

The Guidelines do not settle whether a free, open-source, bring-your-own-key desktop app is a "provider" under Article 50(2), or whether a one-word own-voice patch meets the deepfake threshold. This spec takes the conservative reading: every synthetic segment in a realistic talking-head video is labelled.

**M3 must not be released before a legal review of §11**, including whether the mandatory XMP `DigitalSourceType` mark plus the optional self-signed C2PA manifest (§11.7) satisfy the machine-readable marking duty. Article 50 penalties fall in the €15M / 3% tier. This research is not legal advice.

---

## 12. Privacy, logging, storage

| Data | Leaves the device? | Where it is kept |
|---|---|---|
| Source audio for Clean audio | to ElevenLabs, only on the user's click | cache input WAV (evictable); result in `<data>/VoiceLab/<contentKey>/` |
| Consent statement audio | to ElevenLabs STT (check) and IVC (one sample) | `<data>/VoiceLab/consent/<recordId>/` until the voice is deleted |
| Training samples | to ElevenLabs IVC | deleted locally after upload; hashes kept |
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
| S6 | Pick and calibrate the speaker-embedding model (licence, ONNX Runtime on both platforms, τ) | §6.6, the M3 release |
| S7 | Real processing times for fal LatentSync, lipsync-2 and sync-3 on 3 s and 10 s windows at 1080×1920 | §9 UX |
| S8 | The fal storage lifecycle header for short retention. The sync.so asset delete path | §9.4, §9.5 |
| S9 | Validate the C2PA manifest against spec 2.4. Does a self-signed manifest survive and display on LinkedIn and X? | §11.7 |
| S10 | Does `text_to_speech` permission also cover Text to Dialogue? Exact error-body fields for missing permissions | §2.2 |
| S11 | Map ElevenLabs `tier` strings to "Pro or higher" for 44.1 kHz output | §2.3 |
| S12 | Legal review of §11 | M3 release |

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
   - No gap within 3 words gives a hard seam at `a.start − min(0.03, gap/2)`.
4. **Duration fit (§8.9).**
   - `r = 1.05` gives a stretch to exact length with `outDuration == end − start`.
   - `r = 1.15` with a 0.6 s adjacent pause borrows the pause and then stretches.
   - `r = 1.4` with no pause gives zoomCover with `retime = 1/1.4`, which is outside [0.8, 1.25], so the hunk is rejected.
5. **Alignment to words (§8.8).** The character alignment for `"I said 2025"` gives 3 words. A null alignment falls back to the Scribe words with interpolation.
6. **Candidate ranking (§8.6).** Rejected candidates are never shown, and the score formula orders a fixed set.
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
11. **Consent check (§6.4).**
    - A WER of 0.14 with all nonce words passes.
    - A WER of 0.10 with a nonce word missing fails.
    - A recognised language that differs from the statement fails.
    - Date strings use the month tables in en and et.
12. **Request goldens** for every endpoint in §4.3, §6.7, §7.3, §8.5, §8.8, §9.4 and §9.5: method, path, headers (with key values redacted), body or multipart parts.
13. **Provider state machines** with mocked HTTP:
    - fal `IN_QUEUE` → `IN_PROGRESS` → `COMPLETED`, and the cancel responses 200, 202 and 400;
    - sync.so `PENDING` → `COMPLETED`, `FAILED` with `errorCode`, and a 429 retry reusing the same Idempotency-Key;
    - a submit is never retried after a timeout.
14. **Redaction.** `Authorization: Key <fal key>` and `x-api-key: <sync key>` are redacted by the Core redactor (architecture §11.2), registered or not. Voice Lab log lines contain no text.
15. **Machine-readable mark (§11.7).** An export with `required == true` contains the XMP `Iptc4xmpExt:DigitalSourceType` value `…/compositeWithTrainedAlgorithmicMedia` on both platforms, with the C2PA component absent and with the Clean-audio C2PA toggle off. A Clean-audio-only export has no `DigitalSourceType`.

Manual QA with real keys runs locally, never in CI:

- one Clean audio run on a 3 min take;
- one own-voice clone with the full consent flow in English and in Estonian;
- three patches (a replace, an insert, a bridged replace);
- one voice-changer preview;
- one LatentSync and one lipsync-2 window;
- an export checked for the label intervals, the post text, the sidecar and the C2PA validation output.

---

## 16. Provenance

Research:

- `/tmp/clipper-planning/research/eleven-ai.md`: ElevenLabs product and price facts, lipsync providers, EU AI Act, X and LinkedIn rules, C2PA, and the AI re-take design.
- `local-models.md` §9: local TTS and lipsync options, rejected for v1.

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

Repository documents: `doc/spec/editing.md` (§2, §4.5, §4.7, §7, §10, §12), `doc/spec/ai.md` (§4.8, §11.3, §12.8), `doc/architecture.md` (§2.5, §8, §10, §11), `doc/design.md` (§6.3, Settings), `doc/publishing.md` (§2, §3.5.3, §5), and `shared/schemas/project.schema.json` (`voiceLab`).

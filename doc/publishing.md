# VoxClip publishing

Status: section 2 (share helpers) and section 4 (download page) are normative for M1 / 0.1.0. Section 3 (VoxConvo direct publish) is the M2 plan. Section 5 (X and LinkedIn APIs) is the later path. Date: 2026-10-25.

Principles:

1. **Export is local; posting is separate and optional.** Nothing is posted without an explicit click.
2. **No third-party secret ships in the app**, and VoxClip never holds X or LinkedIn tokens in M1 or M2.
3. **The final post call is never retried automatically.** A lost response may follow a successful write.
4. Every exported file already meets the VoxConvo, X and LinkedIn input rules: MP4, H.264 High, 4:2:0 8-bit, AAC-LC 48 kHz, long edge ≤ 1920, ≤ 60 fps, moov first (architecture.md section 4.1).

Provenance: vox-api and vox-web as read on 2026-10-25 (working trees including uncommitted edits) and current X / LinkedIn developer documentation, from the planning research `vox-integration.md`.

---

## 1. Milestones

| Milestone | Publishing surface |
|---|---|
| M1 (0.1.0) | Share helpers after export: Show in Finder/Explorer, Copy caption, Open X (web intent), Open LinkedIn (composer), drag-out of the file. clip.voxconvo.com launch page on GitHub Pages (ADR-R32, 2026-10-27) |
| M2 | VoxConvo direct publish: device-flow sign-in, prerendered upload, `createNew`. Later in M2 or v1.1: `createClipPost` with idempotency |
| Later | Optional "Use your own X app" (public PKCE client); server-side cross-posting to X and LinkedIn through vox-api |

---

## 2. Share helpers (M1)

They appear in the Export sheet after a successful export (design.md section 8).

### 2.1 Caption text

- Default caption for a clip: `<clip title>` + blank line + the clip's first sentence in its edited, corrected text (words after cuts, corrections applied, punctuation kept), words joined by single spaces. For the full edit: the first sentence of the edited take, with no title. Sentence end = the first word whose last character is `.`, `?`, `!` or `…`; if none of the first 40 words ends a sentence, the caption takes those words (at most 40) followed by `…`. An empty title or sentence is left out together with the blank line. Core: `SharePostText.defaultCaption(title:words:)` (C# `DefaultCaption(title, words)`), where `words` are the target's kept, corrected word texts in transcript order.
- The user can edit it in the caption field. The edited text is stored in the project per export target in `share.captions[targetId]` (`project.schema.json` `$defs/share`; `targetId` is `full` or the clip id; at most 3,000 characters) and reused next time. Removing a clip drops its entry (editing spec 10.4).
- Counters under the field:
  - **X:** the X weight below. Shown as `212/280`.
  - **LinkedIn:** Unicode scalar count of the text as typed, limit 3,000. Shown as `212/3,000`.
- Over the X limit the counter turns `status.warning`. Open X sends the composer text below. The copied text is never truncated.

Core implements these rules with the same API on both platforms (`SharePostText`, `ShareDisclosure`). Their constants are in `shared/data/share-text.json`: the weights and ranges, the limits, the URL weight, the TLD list, the emoji table with its source and the ellipsis. `shared/fixtures/share/generate_share_cases.py` generates that file and `shared/fixtures/share/cases.json`, which both Core suites replay. "White space" here is the Unicode White_Space set: U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000.

**X weight** (`xWeight`), the twitter-text v3 weighted length (`maxWeightedTweetLength 280`, `scale 100`, `defaultWeight 200`, `transformedURLLength 23`):

1. NFC-normalize the text, as twitter-text does. Foundation's NFC leaves a precomposed Hangul LV syllable before a trailing jamo (U+AC00 U+11A8 stays two scalars, NFC gives U+AC01), so Swift Core composes that pair afterwards (Unicode §3.12). The composer text below and the line check of voice-lab.md §11.3 normalize the same way.
2. Each URL counts 23.
3. Each extended grapheme cluster outside a URL that is an emoji counts 2.
4. Every other scalar counts 1 when its code point is in `0–4351`, `8192–8205`, `8208–8223` or `8242–8247`, otherwise 2. Thai (U+0E00–U+0E7F), for example, counts 1; CJK and Hangul count 2.

**URL.** A URL is a maximal run of non-white-space that either:

- (a) starts with `http://` or `https://` (ASCII case-insensitive) and is not preceded by an ASCII letter or digit; or
- (b) is a bare host that is not preceded by `@`, an ASCII letter or digit, `.`, `-` or `/`. The host is two or more labels `[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?` joined by dots, and its last label is a TLD from the data file (ASCII case-insensitive). It may be followed by `:` and digits, and by `/` and any non-white-space.

The URL begins at the first position in the run where (a) or (b) holds and ends at the end of the run. The characters `. , : ; ! ? ' " ’ ” ) ] } > …` are stripped from the end repeatedly and do not belong to the URL. So an e-mail address is not a URL, and neither is `https://` inside a word. The TLD list is the common gTLDs plus the EU and Nordic ccTLDs: `ai app co com de dev dk ee es eu fi fr gg info io it lt lv ly me net nl no org pl se tv uk xyz`. This approximates twitter-text, which uses the full IANA TLD list and more detailed rules.

**Emoji.** An extended grapheme cluster is an emoji when any of its scalars has Emoji_Presentation=Yes in Unicode 15.1 `emoji-data.txt` (its URL and sha256 are recorded in the data file), or is U+FE0F, U+20E3 or a Regional Indicator. The clusters are Swift `Character`s and .NET `StringInfo` text elements. They agree on the fixtures, which use only emoji from Unicode 15.0, but not on every text: the toolchains implement different Unicode versions, .NET 10 lacks the Indic conjunct rule GB9c, and some non-RGI ZWJ sequences of Emoji=No pictographs split differently.

**VoxConvo length** (`voxConvoLength`): UTF-16 code units of the text as sent, limit 2,048. This is a deliberately conservative bound. vox-api validates `NewPostInput.text` with class-validator `@Length(0, 2048)`, which calls validator.js `isLength`; that counts UTF-16 units minus surrogate pairs and U+FE0E/U+FE0F selectors, so any text within 2,048 UTF-16 units is accepted.

**Composer text** (`composerText(caption, destination, disclosureLine)`) is what Open X (limit 280 by X weight) and VoxConvo publish (limit 2,048 by UTF-16 length) send. Open LinkedIn sends the caption unchanged.

1. A caption that fits is sent unchanged, byte for byte.
2. Otherwise the caption is NFC-normalized. If the disclosure line is present (voice-lab.md §11.3), its last occurrence is removed, comparing white-space runs as equal; the white space at the join is trimmed, and the two remaining parts are joined with a blank line when both are non-empty. White space at the end is dropped. What remains is the body.
3. If the body, a blank line and the line fit, they are sent without cutting.
4. Otherwise the body is cut at the longest prefix that ends just before a white-space character and contains a word, such that the prefix without its trailing white space, then `…` (U+2026: 2 for X, 1 UTF-16 unit), then the blank line and the line, fits. Paragraph breaks and newlines inside the prefix are kept; words are never re-joined. A cut that would end inside a grapheme cluster is skipped: a Prepend scalar such as U+0600 and the space after it are one cluster.
5. If not even the first word fits, the cut falls at the last grapheme-cluster boundary inside the first word that fits. No cut splits a cluster or a surrogate pair.
6. The line follows the cut body after a blank line. It is never cut and is always last. Without a line, the cut body ends the text. If not even `…` and the line fit, the line alone is sent.

The result is the longest candidate that fits, by the destination's measure of the whole candidate text. A longer rule-4 prefix never measures less, and neither does a longer rule-5 cut, except for X, where a URL can appear or vanish as a first-word cut grows. So both Cores bisect the rule-4 candidates and, for VoxConvo and the field text, the rule-5 cuts, measuring each candidate whole. For X, rule 5 weighs every first-word cut in one pass (`lastFittingXCut`, C# `LastFittingXCut`) and takes the first that fits from the longest down, the cut a scan of whole candidates picks:

- A cut keeps the body up to a grapheme-cluster boundary, then `…` and the tail (the blank line and the line). The body is NFC and `…` never composes with the scalar before it, so the candidate's NFC text is these pieces joined.
- The candidate's URLs are those of the body and the tail, except in the run the cut ends. That run, with `…` and its trailing punctuation stripped, holds the URL starting at the first position that holds for its stripped end. One sweep finds that position for every end: a start holds for some ends inside its host or port and, from one end on, for every later end, and the host runs of different starts never overlap.
- URL starts are ASCII letters or digits, cuts are cluster boundaries, and `…` and the trailing punctuation stand alone: ASCII or General Punctuation, not white space or emoji, and their own cluster after a letter, an emoji ZWJ sequence and a virama. So no piece splits an emoji cluster, and a candidate weighs prefix sums of per-scalar weights outside its URL (an emoji cluster's 2 on its first scalar), 23 for the URL, and the weight of `…` and the tail. Both loaders reject a data file whose ellipsis or trailing punctuation breaks this.

A 3,000-scalar first word cuts for X in about 1 ms in an optimized build; scanning whole candidates from the longest down took up to 0.7 s on the Mac. `generate_share_cases.py` scans every candidate from the longest down and asserts that the one-pass X cut picks the same cut for every fixture case and 60 random first words; the fixtures pin both Cores to its results, and both Core suites also compare the one-pass cut with the scan on random words.

### 2.2 Actions

| Action | macOS | Windows | Notes |
|---|---|---|---|
| Show in Finder / Show in Explorer | `NSWorkspace.shared.activateFileViewerSelecting([url, …])` | `Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { $"/select,{path}" } })` (one window per folder; multiple files select the first) | |
| Copy caption | `NSPasteboard.general.clearContents(); setString(text, forType: .string)` | `DataPackage.SetText(text)`; `Clipboard.SetContent`; `Clipboard.Flush()` | Transient "Caption copied." |
| Open X | `NSWorkspace.shared.open(URL)` | `Windows.System.Launcher.LaunchUriAsync(uri)` | URL below. Also reveals the file and copies the full caption |
| Open LinkedIn | same | same | URL below. Also reveals the file and copies the caption (prefill is not guaranteed) |
| Drag out | SwiftUI `.draggable(fileURL)` / `NSItemProvider(contentsOf:)` on the exported-file row | `DragStarting`: `args.Data.SetStorageItems([await StorageFile.GetFileFromPathAsync(path)])`, `RequestedOperation = Copy` | Drop straight into a browser composer |

URLs (percent-encoding: UTF-8, everything except RFC 3986 unreserved `A–Z a–z 0–9 - . _ ~` is `%XX`; spaces `%20`, newlines `%0A`):

- X: `https://x.com/intent/post?text=<encoded caption>` (no media parameter exists; the user drags the file into the composer).
- LinkedIn: `https://www.linkedin.com/feed/?shareActive=true&text=<encoded caption>` (undocumented; may not prefill; desktop web only).

Before opening, the URL is checked: scheme `https`, host exactly `x.com` or `www.linkedin.com`. After opening, a one-time tip (TipKit / `TeachingTip`) says "Drag the video from {Finder/Explorer} into the post."

Advisory notices (never blocking), shown under the share row:

- X: clip longer than 2:20 → "X allows videos up to 2 min 20 s on most accounts."
- LinkedIn: shorter than 3 s or longer than 15 min → "LinkedIn accepts videos from 3 seconds to 15 minutes from the web."

### 2.3 Acceptance

- Copy caption puts exactly the field's text on the clipboard (round-trip test).
- The X URL for `Galley, not timeline\n\nLike reading a galley before a press run.` is `https://x.com/intent/post?text=Galley%2C%20not%20timeline%0A%0ALike%20reading%20a%20galley%20before%20a%20press%20run.`
- The weighted X count of `Tõnis 🙂 https://voxconvo.com` is `5 + 1 + 2 + 1 + 23 = 32`.
- Reveal selects the exported file in a new Finder / Explorer window.

---

## 3. VoxConvo direct publish (M2)

### 3.1 Today's VoxConvo (facts the plan depends on)

- vox-api uses **better-auth 1.3.32**, Google sign-in only, cookie sessions, MongoDB adapter (patched for driver v4 `findOneAndUpdate`). Every protected route and GraphQL resolves the session with `auth.api.getSession({ headers })`. There is no token mechanism for native clients.
- `POST /upload-video` always starts a server render job. It burns captions unless `subtitleConfig.style === 'none'` or `words` is empty, re-applies cuts for every word flagged `isStrikethrough`, and re-encodes when the codec is not H.264/VP8/VP9/AV1 or the long edge is over 1920 px.
- **Bug that desktop uploads hit:** multer names every upload `video-<ts>-<rand>.webm` (`vox-api/src/index.ts` ~line 436). On the pass-through path the file is stored on S3 with that name and `ContentType: video/webm` (`videoSubtitleService.ts` ~line 668) even when the bytes are MP4; Safari and iOS may refuse to play it.
- GraphQL `createNew` with only `video.converted` starts no processing (the web client's pattern). With `video.original` + `subtitleConfig` + `wordTimestamps` it starts a broken legacy re-render. `text` is limited to 2,048 characters; `transcript` has no limit.
- VoxClip calls only the endpoints listed in section 3.5.
- vox-web uses the better-auth client 1.7.4 against the 1.3.32 server: the device page uses plain `fetch`, not the client plugin.
- Handles are validated only by `^[a-zA-Z0-9_]+$`, length 1–10, with no reserved list.

### 3.2 Auth choice: OAuth 2.0 Device Authorization Grant (RFC 8628)

better-auth's built-in `deviceAuthorization()` plugin plus the `bearer()` plugin, both in the installed 1.3.32. The issued access token is a better-auth session token, so the existing `getSession`-based checks accept `Authorization: Bearer <token>` with no handler changes. Because a device code can be phished (someone starts the flow and sends the victim the approval link), device-flow sessions are restricted to what VoxClip needs (change A10): every other route answers 403 for them. The user approves in the browser where they are already signed in with Google. No loopback listener, no firewall prompt, no URL scheme, no client secret, identical on macOS and Windows.

Native requests and better-auth's origin check: the check requires an `Origin` only for requests that carry cookies. VoxClip sends no cookies and always uses `Content-Type: application/json` (or multipart for the upload), so it passes.

### 3.3 vox-api change list

The vox repos have uncommitted user edits. Edit files **in place**; never stash, reset or checkout; commit only with the owner's agreement. Document the desktop contract in `vox/doc/` (VoxConvo's rule: docs live in `doc/`).

| # | File | Change | When |
|---|---|---|---|
| A1 | `src/auth.ts` (clean in git) | In `getAuth()`, also load `better-auth/plugins` through the existing ESM `loadModule` helper and add `plugins: [bearer(), deviceAuthorization({ expiresIn: '10m', interval: '5s', userCodeLength: 8, validateClient: (id) => (process.env.DESKTOP_CLIENT_IDS || 'voxclip').split(',').includes(id) })]`. New endpoints under `/api/auth`: `POST /device/code`, `POST /device/token`, `GET /device?user_code=`, `POST /device/approve`, `POST /device/deny`. Collection `deviceCode` is created on first write | M2 |
| A2 | `src/setup-indexes.ts` | TTL index on `deviceCode.expiresAt` (`expireAfterSeconds: 0`) | M2 |
| A3 | `src/index.ts` (modified) | `GET /device` → `302` to `https://voxconvo.com/device` preserving the query string (better-auth builds `verification_uri` from the API base URL); place it next to `/health` | M2 |
| A4 | `src/index.ts` | Multer `filename`: derive the extension from `file.mimetype` / `originalname` (`video/mp4` → `.mp4`, `video/quicktime` → `.mov`, `video/webm` → `.webm`, default `.webm`). Also fixes Safari MP4 recordings published with captions Off | **before the M2 desktop release** |
| A5 | `src/index.ts` | `requireSession` stores `response.locals.userId = user.id`. `/upload-video` reads `prerendered === 'true'`; when set it calls `videoSubtitleService.startPrerenderedJob(tempPostId, request.file.path, { userId })` and ignores `words`, `subtitleConfig`, `removePunctuation`, `uppercase`. Both modes persist `userId` on the job | M2 |
| A6 | `src/services/videoSubtitleService.ts` (modified) | `startPrerenderedJob(postId, inputPath, owner)`: persist `{jobId, postId, status: 'pending', progress: 0, inputPath, userId}`; then `probeVideo`; reject when there is no video stream or the duration exceeds the configured limit; if `needsNormalizing(info)` normalise via `cutVideoSegments(path, [], …)` (no cuts) with a guard or branch for sources without audio; otherwise remux with `ffmpeg -i in -map 0 -c copy -movflags +faststart -y <name>_ready.mp4`; `uploadToS3` (an `.mp4` path → `ContentType: video/mp4`); complete the job and publish `VIDEO_JOB_PROGRESS`; delete temp files. Never call `buildSubtitleFilters` on this path. Add `userId?: string` to `VideoProcessingJob` and to `persistJob`'s `$set` | M2 |
| A7 | `src/gql/resolvers/account/accountInputSchema.ts` | Reserved handles for device authentication and existing VoxConvo routes: `device, api, post, auth, edit, search, logout, settings, help, about, privacy, terms`, plus the brand names `voxclip` and `clipper`, kept so no account can impersonate the app VoxClip publishes from. The launch-only `download, desktop, app` reservations are dropped with voxconvo.com/download (ADR-R32, user decision 2026-10-27) | M2, before device flow |
| A8 | `test/*.cjs` | Prerendered pass-through keeps MP4 bytes and `video/mp4`; never burns or cuts; a bearer token is accepted by `requireSession` and `/graphql`; device flow happy path, `authorization_pending`, `slow_down` (+5 s), `expired_token`, `access_denied` | M2 |
| A9 | `src/gql/resolvers/post/{inputSchema,index}.ts`, `src/services/postService.ts` | `createClipPost(input: ClipPostInput!)` (section 3.6): job ownership (`job.userId == session.userId`, `status == completed`), idempotency through a unique partial index `(accountId, clientRequestId)` on `posts` | v1.1 |
| A10 | `src/auth.ts`, `src/index.ts`, GraphQL context | Mark device-flow sessions (`clientId: 'voxclip'`, `scope: 'post:video'`) when the token is issued. A middleware limits such sessions to `POST /upload-video`, `GET /video-job/:id`, `POST /graphql` with only the operations `getMyAccount`, `createNew` and `createClipPost`, `GET /api/auth/get-session` and `POST /api/auth/sign-out`; anything else returns 403 `{"error":"insufficient_scope"}`. A8 tests cover the 403 for another route and another GraphQL operation | M2 (with A1) |

Before launching A7, run a read-only account-handle check for its retained route names and resolve any hit with the owner. These reservations protect device authentication and existing VoxConvo routes; they serve no purpose for the GitHub Pages launch page.

### 3.4 vox-web change list

| # | File | Change | When |
|---|---|---|---|
| W1 | `src/App.tsx` | `/device` route, standalone layout and metadata exclusions only; `/download` dropped (2026-10-27) | M2 |
| W2 | `src/lib/metadata.ts` | `/device` title "Connect VoxClip" and route exclusion; no download metadata | M2 |
| W3 | `src/Layout.tsx` | Treat `/device` as a non-handle path and add its title | M2 |
| W4 | `server.mjs` | Download redirects dropped by user decision, 2026-10-27; no launch-page server work | Dropped |
| W5 | `site/` in the public VoxClip repo | Replaces the dropped vox-web download page: clip.voxconvo.com on GitHub Pages (section 4) | M1 |
| W6 | `src/components/Device/index.tsx` (new) | The device approval page (section 3.5.2) | M2 |
| W7 | `src/components/Welcome/Splash.tsx` | "Desktop app" links point to `https://clip.voxconvo.com`; retain `callbackURL` pass-through so sign-in from `/device?user_code=…` returns there | M2, separately authorized |
| W8 | `src/components/Sidebar/index.tsx` (modified) | Optional "Desktop app" entry linking to `https://clip.voxconvo.com` | M2, separately authorized |
| W9 | `src/index.css` | Device-page additions only, reusing `.landing-page`, `.landing-header`, `.button-primary`; no download-page rules | M2 |
| W10 | `test/ssr.test.mjs` | `/device` renders the sign-in prompt for logged-out users; no download-page/redirect tests. Launch-page tests live in `site/` | M2 |

### 3.5 Desktop flow

#### 3.5.1 Connect (Settings → Accounts → VoxConvo → Connect)

```text
POST https://api.voxconvo.com/api/auth/device/code
Content-Type: application/json
{"client_id":"voxclip","scope":"post:video"}
→ 200 {"device_code":"<40 chars>","user_code":"ABCDEFGH","verification_uri":"https://api.voxconvo.com/device",
       "verification_uri_complete":"https://api.voxconvo.com/device?user_code=ABCDEFGH","expires_in":600,"interval":5}
```

The app shows the code as `ABCD-EFGH` in Geist Mono with "Confirm this code on voxconvo.com" and opens `https://voxconvo.com/device?user_code=ABCDEFGH` in the default browser (directly at the web origin, so it does not depend on A3). Then it polls every `interval` seconds:

```text
POST https://api.voxconvo.com/api/auth/device/token
Content-Type: application/json
{"grant_type":"urn:ietf:params:oauth:grant-type:device_code","device_code":"…","client_id":"voxclip"}
→ 400 {"error":"authorization_pending"}  keep polling
→ 400 {"error":"slow_down"}              add 5 s to the interval
→ 400 {"error":"expired_token"}          stop: "The code expired. Try again."
→ 400 {"error":"access_denied"}          stop: "Connection was declined on voxconvo.com."
→ 400 {"error":"invalid_grant"}          stop: "Something went wrong. Try again."
→ 200 {"access_token":"<session token>","token_type":"Bearer","expires_in":604800,"scope":"post:video"}
```

- Store the token in the Keychain (service `com.voxconvo.voxclip`, account `voxconvo-session`) or DPAPI (`<data>\Secrets\voxconvo-session.bin`); the account name is the same on both platforms (architecture.md section 11.4). Register it with the log redactor.
- Validate: `GET https://api.voxconvo.com/api/auth/get-session` with `Authorization: Bearer …`.
- Account: `POST /graphql` `query { getMyAccount { accountId handle name profileImage } }`. `null` → "Finish sign-up on voxconvo.com" with a link; no posting until it exists.
- Disconnect: `POST /api/auth/sign-out` with the bearer token, then delete the stored token.
- Any 401 later: delete the token, show "Your VoxConvo connection expired. Connect again." (sessions last 7 days, sliding by 1 day on use).

#### 3.5.2 The `/device` page (vox-web)

1. Read `user_code`, normalise with `toUpperCase().replace(/[^A-Z0-9]/g, '')`, display as `ABCD-EFGH`.
2. `GET ${REACT_APP_API_URL}/api/auth/device?user_code=<code>` with `credentials: 'include'` → `{ status: 'pending' | 'approved' | 'denied' }`, or 400 `invalid_request` / `expired_token` ("This code has expired. Start again in VoxClip.").
3. No session: "Sign in with Google to connect VoxClip" → `signIn.social({ provider: 'google', callbackURL: location.href })`.
4. Signed in with a VoxConvo account: "Connect **VoxClip** on this computer to @handle? This lets VoxClip post videos as @handle. Only approve if this code matches the one in your VoxClip app. If someone sent you this link, choose Deny." with **Approve** and **Deny** (Deny is the default button).
5. Approve: `POST ${API}/api/auth/device/approve` with JSON `{ "userCode": "<code without dashes>" }`, `credentials: 'include'` (the server's approve endpoint does not strip dashes; GET does). Deny: `POST …/device/deny` with the same body.
6. Success: "You can close this tab and return to VoxClip."

#### 3.5.3 Publish a finished export

Shown in the Export sheet as "Also post to VoxConvo @handle" when connected. The primary button becomes **Export & post**.

```text
1) POST https://api.voxconvo.com/upload-video          multipart/form-data, Authorization: Bearer …
   video=@<file>.mp4;type=video/mp4
   prerendered=true
   subtitleConfig={"style":"none","position":{"x":50,"y":80},"size":{"width":400,"fontSize":18}}   (for servers without A5)
   words=[]                                                                                          (never send cut flags)
   transcript=<final edited transcript text>
   → 200 {"success":true,"jobId":"<uuid>", …}   401 → reconnect   413 → "This video is too large for VoxConvo."

2) GET https://api.voxconvo.com/video-job/<jobId>   every 2 s, 15 s per-request timeout, overall deadline max(300 s, 120 s + 1.5 × duration)
   → {"status":"pending|processing|completed|failed","progress":0-100,"s3Url":…,"error":…}
   completed without s3Url → 10 s grace; missing job → 10 s grace; failed → stop

3) POST https://api.voxconvo.com/graphql            Authorization: Bearer …, Content-Type: application/json
   mutation createNew($d: NewPostInput!) { createNew(newPostData: $d) { postId handle video { converted } } }
   $d = { "text": <caption, at most 2,048 characters>, "transcript": <full edited transcript>,
          "wordTimestamps": JSON.stringify([{word, start, end, conf}]),   // edited (final file) timeline, seconds
          "video": { "converted": <s3Url> } }                             // NEVER video.original or subtitleConfig
   → open https://voxconvo.com/post/<postId>
```

Rules:

- The upload timeout is `max(180 s, bytes / 500)`. Progress shows "Uploading 63%" → "Processing" → "Posted · Open".
- The button disables on press. Steps 1–2 may be retried automatically (no post exists yet). **Step 3 is never retried automatically.** On failure: "Saved to {folder}. Posting to VoxConvo failed: {reason}." [Try again]. "Try again" reuses the rendered file, and reuses the completed job's `s3Url` if it is less than 24 hours old, so only step 3 repeats.
- Any edit after the render invalidates the cached render for posting.
- `wordTimestamps` are the caption words on the final clip's timeline after cuts (the same words the SRT uses).
- Against a server without A4/A5, steps 1–3 still work (`style: none`, `words: []`), but a pass-through MP4 is stored as `video/webm`. Ship A4 before the desktop M2 release.

### 3.6 Hardening (v1.1): `createClipPost`

```graphql
input ClipPostInput {
  videoJobId: String!       # server resolves s3Url from videoJobs; requires job.userId == session.userId and status 'completed'
  text: String!             # ≤ 2048
  transcript: String
  wordTimestamps: String    # JSON [{word,start,end,conf}] on the final clip timeline (seconds)
  captionStyle: String      # metadata only, e.g. "highlight"
  source: String            # "voxclip-macos@0.2.0"
  clientRequestId: String!  # UUID generated once per post attempt; unique (accountId, clientRequestId)
  parentPostId: Float
}
type Mutation { createClipPost(input: ClipPostInput!): Post! }
```

The server resolves the video URL from the job instead of trusting a URL from the client, and step 3 becomes safe to retry with the same `clientRequestId`. Once the server has it, VoxClip retries step 3 up to 3 times on network errors only.

---

## 4. Launch page on GitHub Pages (M1)

### 4.1 clip.voxconvo.com

**User decision, 2026-10-27 (ADR-R32):** voxconvo.com/download and its redirects are dropped. The public VoxClip repository owns `site/`, served by GitHub Pages at **clip.voxconvo.com**. Releases and installer files remain on GitHub Releases. No VoxConvo server or API is needed to serve the page.

- Hero: "Cut video by its words." Sections: editor capture, showreel, three downloads, four features, tutorials, privacy, MIT/source/notices and the VoxConvo footer. Pending captures are visibly labelled.
- Mac: Apple silicon, macOS 26 or later (Package.swift); Windows x64/Arm64: Windows 10 2004 or later / Windows 11 (App csproj SupportedOSPlatformVersion). Only verified release asset URLs become links; sizes and optional SHA-256 come from saved release metadata.
- Next to Windows downloads: "This software uses libraries from the FFmpeg project under the LGPL" and a link to that same release's `VoxClip-win-ffmpeg-source.tar.xz` (architecture §6.1). A Windows asset without its corresponding-source archive fails the build.
- Local transcription requires a model download; cloud transcription sends audio to the chosen provider. Find Clips sends transcript text to the chosen connector; AI tighten (coming, ai §12) will do the same. Keys are stored in Keychain/DPAPI; there is no telemetry (architecture §11).
- Voice Lab has not shipped. The page labels it **Voice Lab (beta, coming)** and says it sends the user's voice recordings, the words to speak and a little surrounding transcript for context to ElevenLabs with their key after consent; lip sync sends the selected video and audio to the chosen provider (voice-lab §1, §2.5, §12). No claim that all cloud processing receives only text.
- Both platforms launch together (ADR-R33, user decision 2026-10-27). Production release fetching requires Mac and both Windows installers. Missing assets in an offline scaffold are labelled unavailable, never invented.

### 4.2 Publication and approval

`.github/workflows/pages.yml` is dispatch- and release-published-only, with no push trigger. It checks Pages settings using a read-only API call, skips publication while disabled, fetches published app metadata and launch videos from the media release named in `site/media.json`, requires the API metadata and every video's/caption's bytes to match committed, approved size and SHA-256 pins (null pins keep placeholders without fetching media), builds and deploys through the Pages artifact actions. Site builds and tests run offline; media files enter only the build artifact and are never committed.

Each go-live action needs the user's approval, in this order (see [release §4.1](release.md#41-launch-page-go-live--users-approval-required)):

1. **Approval required:** verify `voxconvo.com` for the **Siim account** in GitHub account settings → Pages → verified domains. Add GitHub's supplied `_github-pages-challenge-…` TXT record at GoDaddy and complete verification.
2. **Approval required:** enable Pages with **GitHub Actions** as the source and set this repository's custom domain to `clip.voxconvo.com`. In Settings → Environments → `github-pages` → Deployment branches and tags, keep `main` and add tag rules `v*` and `media-v*`.
3. **Approval required:** only after account verification and repository custom-domain assignment, add the GoDaddy CNAME `clip` → `siim.github.io`.
4. **Approval required:** wait for the certificate, then turn on **Enforce HTTPS**.
5. **Approval required:** publish the release, or dispatch **Launch page** from `main`.

Never point DNS at GitHub before steps 1–2 are complete. Keep the verification TXT record permanently. If Pages is disabled again, remove the CNAME so it no longer points at GitHub. Until the environment tag rules exist, a release run only builds: its tag-ref deploy is rejected by `github-pages`. A `workflow_dispatch` from `main` publishes the same page: every run, whatever its trigger, builds `site/` and `site/media.json` from `main`.

No deployment or settings change is authorized by the tooling task.

---

## 5. X and LinkedIn APIs (later)

### 5.1 Option A: "Use your own X app" (optional, behind Settings → Accounts → Advanced)

- X "Native App" type is a public PKCE client: the user pastes only a **Client ID**, registers the callback `http://127.0.0.1:47821/callback` (fallbacks `:47822`, `:47823`; X matches callbacks exactly), and pays X's pay-per-use credits themselves (about $0.015 per post; $0.20 with a URL in the text).
- Flow: system browser (never a WebView) to `https://x.com/i/oauth2/authorize?response_type=code&client_id=…&redirect_uri=…&scope=tweet.read%20tweet.write%20users.read%20media.write%20offline.access&state=…&code_challenge=…&code_challenge_method=S256`; loopback listener; `POST https://api.x.com/2/oauth2/token` (`grant_type=authorization_code`, `code_verifier`, `client_id`); access tokens last about 2 h, refresh tokens rotate (always store the new one) in the Keychain / DPAPI.
- Upload: `POST /2/media/upload/initialize {"media_type":"video/mp4","total_bytes":N,"media_category":"tweet_video"}` → `POST /2/media/upload/<id>/append` (multipart, 4 MB segments) → `POST /2/media/upload/<id>/finalize` → poll status until `succeeded` → optional SRT via `media_category: subtitles` + `POST /2/media/subtitles` → `POST /2/tweets {"text":…, "media":{"media_ids":[id]}}`. Rate limit 100 posts / 15 min per user.
- LinkedIn BYO is not offered: it needs a client secret, a verified company Page and an HTTPS redirect; native PKCE is not self-serve.

### 5.2 Option B: server-side cross-posting through vox-api (recommended later path)

After a VoxConvo publish the clip is already on VoxConvo's S3, so vox-api pushes it to X and LinkedIn with tokens it holds; the desktop never sees third-party secrets or tokens.

- Collection `socialConnections { userId, provider: 'x'|'linkedin', providerUserId, personUrn?, accessTokenEnc, refreshTokenEnc?, expiresAt, scopes, createdAt }`, tokens encrypted with AES-GCM under a server key from an env var (not better-auth's secret).
- Routes (bearer-authenticated with the device token): `GET /desktop/v1/connect/:provider/start` → `authorizeUrl` (server-side PKCE + `state` with a short TTL; redirect URIs `https://api.voxconvo.com/oauth/x/callback`, `…/oauth/linkedin/callback`); `GET /oauth/:provider/callback` exchanges the code with the client secret from env (`X_CLIENT_ID` / `X_CLIENT_SECRET`, `LINKEDIN_CLIENT_ID` / `LINKEDIN_CLIENT_SECRET`, illustrative names) and renders "Connected. Return to VoxClip."; the desktop polls `GET /desktop/v1/connections`; `DELETE /desktop/v1/connections/:provider` revokes; `POST /desktop/v1/crosspost { videoJobId | postId, provider, text, captionsSrt? }` enqueues a job (X chunked upload as in 5.1; LinkedIn `rest/videos?action=initializeUpload` → PUT 4 MB parts → `finalizeUpload` → poll `AVAILABLE` → `rest/posts` with `LinkedIn-Version: <current YYYYMM>` and little-text escaping) and reports through the `videoJobs` poll pattern.
- Controls: per-user daily quotas (X posts are billed to VoxConvo), a monthly spend cap in the X console, no URL in X text unless the user adds one, early-access gating like `canUseClips`. Needs a privacy-policy update (VoxConvo becomes the processor of users' X/LinkedIn tokens).
- X `made_with_ai` and EU AI Act Article 50 labels apply when M3 Voice Lab features modified the clip; the cross-post request then carries the Voice Lab `aiDisclosure` object (`{ "modified": true, "kinds": [...], "aiSeconds": n }`, voice-lab.md section 11.6) and the text gets the disclosure line defined by the Voice Lab spec.

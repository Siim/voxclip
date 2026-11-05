# AI layer: connectors, prompts, clip finder and AI tighten

Status: normative for 0.1.0 (M1). Section 12 (AI tighten) is normative for M2. Written 2026-10-25.

"Must" and "never" are requirements. "Should" is a strong default that needs a written reason to change. Research and source files are cited only as provenance (§15); implementers do not need them.

Machine-readable inputs this spec governs:

| File | Content |
| --- | --- |
| `shared/catalog/llm-providers.json` | Connectors, endpoints, auth headers, curated models (2026-10), default and fallback models, structured-output mechanism, policy constants (timeouts, retries, redaction), the connection-test request, and the CLI detection commands and invocation templates |
| `shared/prompts/clip-finder.json` | Clip-finder system prompt, request templates, presets, limits, output schema |
| `shared/prompts/ai-tighten.json` | AI tighten prompt, strengths, verification limits, output schema (M2) |
| `shared/prompts/voice-rewrite.json` | Voice Lab passage/full-take rewrite prompt and review-only schema; both native Core services consume the same prompt and behavioral fixtures |
| `shared/prompts/README.md` | How the apps ship and load these files, and the parity tests that fail on drift |

Code lives in the cross-platform cores: `VoxClipCore/AI/` (Swift) and `VoxClip.Core/Ai/` (C#, `net10.0`, tests run on macOS). The one exception is the Apple Foundation Models connector, which uses a platform ML framework and lives in `VoxClipMedia` behind the Core `LLMConnector` protocol (architecture §1). Nothing in this spec touches media. The headless `voxclip-cli` exposes the same pipeline (§10.4).

---

## 1. Principles

1. **One canonical request, one schema per feature, one validator, one finaliser.** Connectors only translate the canonical request to a wire format and translate the reply back. Clip ranking and validation never depend on the connector.
2. **LLM output never edits the project by itself.** Clip suggestions are suggestions. AI tighten proposals need the user's approval. A failed or cancelled run leaves the project unchanged.
3. **Manual clips need no connector.** Selecting words and choosing "Make clip" works with no key, no network and no model.
4. **Only text leaves the machine, and only to the connector the user picked.** The transcript (word text plus timings, as formatted in §11.3) is sent. Media files never are. VoxConvo servers are never in the loop. There is no telemetry.
5. **Keys stay in the OS secret store.** They never appear in logs, URLs, project files or crash reports, and VoxClip never adds its stored keys to a child process's environment. A stored key is sent only over HTTPS to its connector's host. Everything that decides where a key goes is fixed in code on both platforms, per connector: which key it uses, the host, the header and the header value.

   | Connector | Key account | Host | Header and value |
   | --- | --- | --- | --- |
   | `anthropic` | `llm-api-key-anthropic` | `api.anthropic.com` | `x-api-key: {key}` |
   | `openai` | `llm-api-key-openai` | `api.openai.com` | `Authorization: Bearer {key}` |
   | `xai` | `llm-api-key-xai` | `api.x.ai` | `Authorization: Bearer {key}` |
   | `gemini` | `llm-api-key-gemini` | `generativelanguage.googleapis.com` | `x-goog-api-key: {key}` |

   No other connector ever receives a stored key. Nothing can change where a key goes: not a catalog file (for example one found through `VOXCLIP_SHARED_DIR`, architecture 2.4), not settings, not an injected HTTP client, not a redirect. Key-bearing requests go through a transport the connector owns, which never follows a redirect. A catalog entry that disagrees with this table makes the connector `unavailable` with "VoxClip is missing its AI configuration. Reinstall VoxClip." That includes an `auth` block on any connector the table does not list (Ollama, LM Studio, Apple, the CLI connectors): it is never ignored.
6. **Plain HTTP on both platforms.** Every HTTP connector is implemented directly on `URLSession` (Swift) and `HttpClient` (C#), with no vendor SDK. Swift has no official SDK for most of these APIs, and one wire implementation per platform lets the same request and response fixtures test both apps.
7. **Capabilities drive the UI, not provider names.** Each connector declares its group, privacy class, structured-output mode and limits in the catalog.

---

## 2. Canonical request and result

### 2.1 Types (language-neutral)

```text
LLMRequest {
  feature: clipFinder | aiTighten | voiceRewrite | test
  system: string                 // from the prompt file
  cachedBlock: string?           // "<transcript>\n" + lines + "\n</transcript>"; identical across presets of one take
  instruction: string            // the per-request text (§11.4, §12.4)
  schemaName: string             // "clips", "tighten_edits", "voice_rewrite_proposal", "patch_edits", "connection_test"
  schema: JSON object            // canonical subset, §2.2
  maxOutputTokens: int           // 16000 for clipFinder and aiTighten; voiceRewrite reserves for selected text up to the connector cap; 2048 for test
  effort: low | medium | high | xhigh | max | null   // lowest first; every AI decision feature asks for xhigh
  timeout: seconds               // from catalog policy.timeoutsSeconds
  language: BCP-47 string?       // transcript language, used by the Apple locale gate
  tag: string                    // for logs only, e.g. "clips/best part 2 of 3"
}

RawCompletion {                  // what a connector returns for one model
  text: string?                  // the reply text, when the connector returns text
  object: JSON?                  // the parsed reply, when the connector returns an object (Claude Code, Apple)
  model: string                  // model that actually answered
  stop: complete | truncated | refused(category?)
  usage: { input, output, cacheRead, cacheWrite }?   // tokens, each optional
  requestId: string?
}

LLMResult {                      // what the runner returns to features
  object: JSON object            // validated per §2.3
  droppedItems: int              // array items removed by structural validation
  model: string
  usedFallback: bool
  usage: as above
  requestId: string?
}
```

### 2.2 Canonical schema subset

Every schema in `shared/prompts/` and the catalog's `testRequest` uses only these keywords: `type` (`object`, `array`, `string`, `integer`, `number`, `boolean`), `properties`, `required`, `additionalProperties: false`, `items`, and `enum` on strings. Every object sets `additionalProperties: false`; `required` is a subset of its properties, allowing optional additive fields such as Rewrite's `audioTags`. Supplied optional fields are structurally validated; absence is valid. Numeric ranges, string lengths, formats, `$ref`, `anyOf`, nullable types and defaults are not allowed.

Both platforms' HTTP wire construction recursively promotes optional properties to required for provider structured-output schemas; the prompt requests an empty annotation array when none apply. Canonical requests and reply validation retain optionality, so older replies remain valid. Existing exhaustive schemas are unchanged. CLI schemas retain the canonical form. A unit test validates every shared schema against this subset. Local structured-generation features must explicitly support a feature's schema before offering it.

### 2.3 Structural validation

After a connector returns:

1. Get a JSON object: use `RawCompletion.object` if present; it may hold at most 64 levels (§4.5). Otherwise extract it from `text` (§4.5).
2. The object must contain the top-level array named by the schema (`clips` or `edits`), or for the test schema both `ok` and `echo`. If not, the reply is invalid (§4.6).
3. Validate each array item separately. It must be an object holding every required key with the right JSON type: `string` needs a string, `integer` and `number` accept any number the strict parse read (§4.5), integral or not, `boolean` needs a boolean, and an `enum` needs one of its strings. A failing item is dropped and counted in `droppedItems`. Extra keys are ignored.
4. Integer-ness is not checked here. `finalizeClips` checks it (§11.7), so a `5.5` index drops one clip instead of failing the reply.

Decoding keeps non-integral numbers: the strict parse holds every number as a finite binary64 (Swift `JSONValue.number`, C# a `JsonValue` read as `double`). An integer decoder that throws for the whole reply must not be used.

### 2.4 Message assembly

Every connector sends, in this order: `system`, then `cachedBlock` (when present), then `instruction`.

- Where the API takes content blocks (Anthropic, OpenAI Responses, Gemini), `cachedBlock` and `instruction` are two separate blocks in one user message.
- Where the user content is one string (xAI, Ollama, LM Studio, Apple, both CLIs), it is `cachedBlock + "\n\n" + instruction`, or `instruction` alone when `cachedBlock` is null.

---

## 3. Connector abstraction

Connector ids (catalog `connectors[].id`): `anthropic`, `openai`, `xai`, `gemini`, `ollama`, `lmstudio`, `apple-foundation` (macOS only), `claude-code`, `codex`.

### 3.1 Swift

```swift
public enum ConnectorID: String, Codable, Sendable, CaseIterable {
    case anthropic, openai, xai, gemini, ollama, lmstudio
    case appleFoundation = "apple-foundation"
    case claudeCode = "claude-code"
    case codex
}

public enum LLMFeature: String, Sendable { case clipFinder, aiTighten, test }
public enum Effort: String, Sendable { case low, medium, high, xhigh, max }

public struct LLMRequest: Sendable {
    public var feature: LLMFeature
    public var system: String
    public var cachedBlock: String?
    public var instruction: String
    public var schemaName: String
    public var schema: JSONValue
    public var maxOutputTokens: Int
    public var effort: Effort?
    public var timeout: Duration
    public var language: String?
    public var tag: String
}

public enum StopKind: Sendable, Equatable { case complete, truncated, refused(category: String?) }
public struct LLMUsage: Sendable, Equatable { public var input, output, cacheRead, cacheWrite: Int? }

public struct RawCompletion: Sendable {
    public var text: String?
    public var object: JSONValue?
    public var model: String
    public var stop: StopKind
    public var usage: LLMUsage?
    public var requestID: String?
}

public struct LLMResult: Sendable {
    public let object: JSONValue
    public let droppedItems: Int
    public let model: String
    public let usedFallback: Bool
    public let usage: LLMUsage?
    public let requestID: String?
}

public enum ConnectorStatus: Sendable, Equatable {
    case ready
    case needsKey
    case notRunning(url: String)                    // Ollama, LM Studio
    case noModels                                   // server up, no chat model installed
    case unavailable(reason: String)                // Apple Intelligence off, not eligible, not ready
    case cliMissing
    case cliTooOld(version: String, missing: [String])
    case cliSignedOut
}

public struct LLMModel: Sendable, Hashable, Codable {
    public enum Source: String, Codable, Sendable { case curated, discovered, custom }
    public let id: String
    public let name: String
    public let tier: String?                        // fast | balanced | best
    public let contextTokens: Int?
    public let source: Source
}

public protocol LLMConnector: Sendable {
    var id: ConnectorID { get }
    func status() async -> ConnectorStatus
    func models(refresh: Bool) async throws -> [LLMModel]
    func contextTokens(model: String) async -> Int?
    /// One model. HTTP retries (§4.2) happen inside; model fallback does not.
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion   // throws LLMError
}

public actor LLMRunner {
    public init(keys: KeyProvider, catalog: LLMCatalog, log: Redacting)
    /// Status preflight, send, one fallback model (§4.3), stop handling,
    /// extraction and validation (§2.3, §4.5), one corrective retry (§4.6), logging (§4.9).
    public func run(_ request: LLMRequest, on connector: any LLMConnector, model: String) async throws -> LLMResult
}
```

### 3.2 C#

```csharp
public enum ConnectorId { Anthropic, OpenAI, Xai, Gemini, Ollama, LmStudio, AppleFoundation, ClaudeCode, Codex }
public enum LlmFeature { ClipFinder, AiTighten, Test }
public enum Effort { Low, Medium, High, XHigh, Max }

public sealed record LlmRequest(
    LlmFeature Feature, string System, string? CachedBlock, string Instruction,
    string SchemaName, JsonObject Schema, int MaxOutputTokens, Effort? Effort,
    TimeSpan Timeout, string? Language, string Tag);

public abstract record StopKind {
    public sealed record Complete : StopKind;
    public sealed record Truncated : StopKind;
    public sealed record Refused(string? Category) : StopKind;
}
public sealed record LlmUsage(int? Input, int? Output, int? CacheRead, int? CacheWrite);
public sealed record RawCompletion(string? Text, JsonNode? Object, string Model, StopKind Stop, LlmUsage? Usage, string? RequestId);
public sealed record LlmResult(JsonObject Object, int DroppedItems, string Model, bool UsedFallback, LlmUsage? Usage, string? RequestId);
public sealed record LlmModel(string Id, string Name, string? Tier, int? ContextTokens, ModelSource Source);

public interface ILlmConnector
{
    ConnectorId Id { get; }
    Task<ConnectorStatus> GetStatusAsync(CancellationToken ct);
    Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct);
    Task<int?> GetContextTokensAsync(string model, CancellationToken ct);
    Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct); // throws LlmException
}

public sealed class LlmRunner(IKeyProvider keys, LlmCatalog catalog, IRedactor log)
{
    public Task<LlmResult> RunAsync(LlmRequest request, ILlmConnector connector, string model, CancellationToken ct);
}

public sealed class LlmException(LlmError error) : Exception(error.UserMessage) { public LlmError Error { get; } = error; }
```

`ConnectorId.AppleFoundation` exists so the shared catalog decodes on Windows. No Windows connector implements it, and the Windows UI hides it (catalog `platforms`).

---

## 4. Runtime policy

### 4.1 HTTP transport

- Swift: one `URLSession` with `.ephemeral` configuration (no cookies, no URL cache). Per request, `timeoutInterval = request.timeout`; on the session, `timeoutIntervalForResource = request.timeout + 30`.
- C#: one shared `HttpClient` with `Timeout = Timeout.InfiniteTimeSpan`. Each call uses a `CancellationTokenSource` with `request.timeout`, linked to the caller's token. A timeout and a user cancel must be told apart.
- Header `User-Agent: VoxClip/<version> (macOS)` or `(Windows)`.
- JSON bodies are UTF-8. Tests compare request bodies as parsed JSON, so key order does not matter.
- The system proxy is honoured.

### 4.2 Retries (per model)

- Up to **3 attempts**.
- Retry on HTTP **429** (except quota exhaustion, §5), **500, 502, 503, 504, 529**, and on a connection lost before any response (`URLError.networkConnectionLost`, `HttpRequestException` with `SocketError.ConnectionReset`).
- Wait **1 s** before attempt 2 and **2 s** before attempt 3, the same as Superscribe's `1000 × (attempt + 1)` ms.
- If the response carries a wait hint, use it instead: `retry-after` (seconds or HTTP date), `retry-after-ms`, or a Gemini `RetryInfo.retryDelay`. If the hint is over **30 s**, stop retrying and raise `rateLimited(retryAfter)`.
- Timeouts are not retried. A user cancel stops at once.

### 4.3 One fallback model

When the final error for the chosen model is `rateLimited` (not quota) or `overloaded` (503, 529, or Anthropic `overloaded_error`), the runner tries once more with the **fallback model**: the first entry of the connector's `fallbackOrder` that differs from the chosen model. The fallback gets its own 3 attempts. If there is no such entry, the original error stands.

- Never fall back for `unauthorized`, `quotaExceeded`, `modelNotFound`, `badRequest`, `contextTooLong`, `refused`, `truncated` or `timeout`.
- `LLMResult.usedFallback = true`. The UI says "Answered by {fallback} because {model} was busy."
- Anthropic Opus 5.5, Sonnet 5.5 and Opus 5 also use server-side refusal fallbacks (§6.1). That is separate from this rule.
- Claude Code: the CLI implements the fallback through `--fallback-model` (§6.8). The runner does not re-run.
- Codex: the runner re-runs once with the fallback model (§6.9).
- Ollama, LM Studio and Apple have no fallback.
- A `voiceRewrite` send (Voice Lab's Re-voice and Fix with AI) never falls back: no runner fallback, no `--fallback-model`, no Anthropic `fallbacks` and no beta resend (§12.8).

### 4.4 Timeouts

From `policy.timeoutsSeconds`. Each request is one window of one feature run.

| Use | Seconds |
| --- | --- |
| Status probes (local servers, `/api/version`) | 3 |
| Model-list refresh | 15 |
| Test button, HTTP connectors | 30 |
| Clip finder, AI tighten and Voice Lab rewrite, cloud HTTP | 360 |
| Ollama and LM Studio requests | 600 |
| Apple Foundation Models, per window | 120 |
| CLI detection commands | 10 |
| Test button, CLI connectors | 120 |
| CLI generation, per invocation | 600 |

The AI decision features ask for `xhigh` effort (below), which thinks longer than the `medium` they sent before
2026-11-04. Cloud HTTP doubles from 180 to 360 s, and CLI generation from 300 to 600 s, the catalog's longest wait
(the local-server value): a CLI adds its own start-up and retries to the provider's reply.

### 4.4.1 Effort

Find Clips, AI Tighten, Rewrite, Fix with AI, wording fit, the caption pick (§16) and the Rewrite next actions (which
send through Rewrite and Fix with AI) ask for `xhigh`: the user asked that Claude Code "make the best decisions … in extra high effort level".
The connection test stays `low`. A connector sends the highest level it supports at or below the request, and omits
effort when it supports none of those. "Supports" means:

- Anthropic, OpenAI, Gemini and Claude Code: the catalog connector's `effort.values` (Anthropic and Claude Code list
  `low`…`max`, so they send `xhigh`; OpenAI and Gemini stop at `high`). Each model gate below still applies.
- Codex: a named model's `supportedReasoningEfforts` from model/list (none listed: no effort). "CLI default" uses the
  `isDefault` model's list, else the catalog's `effort.values` (`low`, `medium`, `high`).
- xAI, Ollama, LM Studio and Apple Foundation Models ignore effort (Ollama keeps its lowest-thinking rule, §6.5).

The status bar shows the level next to the AI ("Claude Code · Opus (latest) · extra high") and Settings says "AI
decisions use extra high effort." from the catalog alone. `shared/fixtures/llm/effort-requests.json` renders every
connector at every level, plus the Codex model-list cases.

### 4.5 Strict JSON: replies and transport envelopes

Both platforms read every LLM reply and every transport envelope with one strict JSON rule, so a text one platform rejects the other rejects too, as a typed error and never a crash:

- The text is one RFC 8259 value with nothing around it but JSON whitespace. Comments, trailing commas, single quotes, `NaN` and `Infinity` are not JSON.
- It nests at most 64 levels for a reply and 512 for an envelope. The outermost object or array is level 1, so `{"x":[]}` has two levels.
- Every string escape is well formed, in key names too: an escaped high surrogate is followed by an escaped low surrogate, and a low surrogate never stands alone.
- A number token is at most 1,024 bytes, including its sign, fraction and exponent. A longer token is invalid in both replies and transport envelopes, even for exact zero. Every number is a finite binary64. A number that rounds to zero does not fit either: its value is 0, yet a digit 1 to 9 appears before any `e` or `E`, as in `1e-400`. An exact zero with any exponent, such as `0e-400`, `0E1`, `0.00e-1` or `-0.0e5`, is zero.
- Every integer field read by either CLI connector or its process runner uses a signed 64-bit range: an integral binary64 value in [-2^63, 2^63) counts, including negative values and integral floats such as `529.0`. A fractional or out-of-range value, or a field of another JSON type, is absent. This applies to error status, model-usage ranking, recorded usage and app-server response ids; the upper bound is exclusive even when a decimal token rounds to 2^63.
- Keys compare as UTF-8 bytes after JSON string escapes are decoded. Within one object, two byte-different but canonically equivalent keys make the whole text invalid, on both platforms. For example, precomposed and decomposed `café`, or `K` and KELVIN SIGN U+212A, cannot both be keys in one object. This check is per object, not across sibling objects.
- A byte-identical repeated key keeps its first value, including when its JSON escape spelling differs. The whole text is still checked, so an invalid later value of a repeated key makes the text invalid.

Each Core builds the value while it checks the text (Swift `StrictJSON`, C# `LlmOutput.TryParse`). Swift tracks each object's raw key bytes beside its canonically equivalent dictionary keys; C# detects canonical collisions with the Core's exact NFC helper, compared ordinally. C# uses `JsonDocument` for JSON grammar, depth and string escapes; Core applies the number bound, finite/non-underflow checks and key rules explicitly.

**Replies** are the model's answer: a reply text, and a reply object a connector parsed itself, such as Claude's `structured_output` (§6.8), which holds at most 64 levels like a parsed text. A reply text is read like this:

1. Trim it with jsTrim (editing §4.5) and read it as Unicode scalars, never grapheme clusters, so a combining mark cannot hide a delimiter.
2. If it starts with a code fence (```` ``` ```` or ```` ```json ````), drop the opening fence line up to its first line break, and a closing fence. A fence with no line break is all opening line, so nothing is left to parse.
3. Parse the whole text. When it parses, it is the reply, and a value that is not an object is no reply (§2.3).
4. Only when it does not parse, find the first `{` and scan forward to its matching `}`, tracking JSON strings and backslash escapes. Parse that substring.
5. Otherwise the reply is invalid.

**Transport envelopes** carry a reply or a connector's state: HTTP response bodies, the Claude CLI result (§6.8), each line of Codex `exec` and app-server output (§6.9), the model cache file (§9) and `claude auth status --json` output (§6.8). An envelope is trimmed with jsTrim and parsed whole, at most 512 levels deep, with no code fence or balanced-object scan; a CLI's output is split into lines at LF only. Text that is not one strict value is no envelope. An HTTP body that is not one counts as an empty object, so a success holds no reply. A Codex line that is not one is skipped, and a model cache that is not one is ignored. A Claude result that is not one fails the send with `cliFailed`, and Claude auth output that is not one fails the status probe.

### 4.6 One corrective retry

If extraction (§4.5) or step 2 of §2.3 fails, the runner re-sends once on the same model. The instruction gets this appended:

```text


Your previous reply was not valid JSON for the required schema ({reason}). Reply with only the JSON object.
```

`{reason}` is `not JSON` or `missing "clips"` (or the relevant key). There is no corrective retry for `truncated` or `refused`. A second failure raises `invalidOutput`.

### 4.7 Cancellation and concurrency

- One LLM run at a time per open project. Windows within a run go one after another (§11.5).
- Cancel stops HTTP tasks and kills CLI process trees (§6.10). Partial results are discarded and nothing is written to the project.

### 4.8 First-use consent per cloud connector

Mac v2 uses one inline confirmation row under the clip bar, pushing the transcript down (v5 f22–f22d). Settings → Test uses the same row inside Settings. No editor sheet presents connector consent or an API-key send. Windows Rewrite uses an inline first-use / per-send row inside its right-panel job, with the same event-time Return guard. Its other shell and Find clips confirmation routes still need their separate v2 hookup; see `doc/windows-v2-workflows.md` for that ownership boundary. A remote local-server Rewrite names and pins its server and asks for privacy approval for the session; it never claims the text stays on this PC.

Readiness is checked when the user starts an action, before consent. Detection is not a request: the catalogue version/help/sign-in commands and a key-presence check may run then. Unknown CLI sign-in methods neither send nor ask. Local models on this computer and Apple on-device need no privacy consent; a local server on another computer names its host and asks once.

For a cloud connector, store `llm.cloudConsent.<connectorId> = true` only after the user approves its first request. One approval covers Find clips, Rewrite, Tighten, Hook, Ask and Settings → Test for that connector. Cancel stores no new consent and sends nothing. A plan-signed-in CLI asks once; later free sends start at once.

- Claude Code first use: “VoxClip will run your installed Claude Code with your own sign-in.” Detail for a clip: “The {n} words of clip {c} are sent to Anthropic and count toward your Claude plan's usage. No audio or video.” **Allow and Rewrite** (neutral), **Not now**. Note: “Asked once per AI. Later sends start at once.” Codex names Codex, OpenAI and the ChatGPT plan.
- An API-key send asks every time, including a CLI signed in with an API key. Line 1: “Rewrite sends the {n} words of clip {c} to {provider} with your key.” A selection reads “these {n} words”; Full Take reads “the {n} words of this video”. Detail: “No audio or video. {model}. Asks before each send.” **Send**, **Cancel**.
- First use combines privacy consent and that billed send in one row: add “First time with {provider}: allowing it covers Find clips, Rewrite and Tighten. Each send still asks.” Use **Allow and Send**, **Not now**. There is no second approval.
- Other triggers reword that single row: “Ask sends your question and …”, “Hook sends …”, “Find clips sends this project's transcript ({n} words) …”, or “Test sends a short test request …”. A CLI on an API key reads “to Claude Code, billed to the API key it is signed in with” (Codex likewise).
- API-key sends show no invented estimate and no price on Send. Note: “VoxClip can't tell what this costs. Check {provider}'s pricing.” Link the provider's pricing; Anthropic for Claude Code, OpenAI for Codex.
- A missing key shows a secure field and **Save Key** in the row. “It is saved in the macOS Keychain; saving makes no request.” Send appears only after saving. Saving never approves the send.

The row is not modal. Its group may take focus, but a billed button never takes focus by itself and Space continues playback. Return is ignored for repeats, a keydown predating the row, and its first 0.5 seconds after opening or rewording. That interval uses the keydown's event timestamp, not its later handling time: a delayed early Return still cannot approve. Nonrepeat ⌘Return approves explicitly; Esc cancels and returns focus to the initiating verb or Ask field, preserving its text. Changing scope or action replaces the pending request and restarts the guard. Finishing a confirmation releases its per-request currentness and key-save callbacks before resuming the caller; cancelling an older task cannot dismiss a newer request.

The right panel stays on its current job until Send. After approval, Rewrite shows its running steps. A failed send retains the completed send step and adds “No answer” with the error code; offline fails “Couldn't reach {provider}”. **Try Again…** opens a new confirmation. A rejected key offers **Save Key and Try Again…**, which also reopens confirmation. No retry sends automatically.

### 4.9 Logging and redaction

One line per request attempt, metadata only:

```text
llm connector=anthropic model=claude-opus-5-5 feature=clipFinder tag="clips/best" attempt=1 status=200 ms=11873 in=4210 out=612 cacheRead=0 cacheWrite=3890 requestId=req_…
```

Never log prompts, transcript text, model replies, API keys, request headers, URLs with query strings, CLI stdout, or more than the first 200 characters of an error message.

Every string written to a log goes through the Core `Redactor` of `doc/architecture.md` §11.2, the only redactor definition: registered key values first, then its patterns, with the replacement `[REDACTED]`. Every key the connectors load is registered with it.

Errors are logged by their `LLMError` case plus the redacted user message. Never log the description of the underlying `URLError` or `HttpRequestException`: it can hold the failing URL, and a URL can hold a secret.

---

## 5. Error taxonomy and user-facing messages

`{label}` is the connector label from the catalog (for the CLI connectors "Claude Code (installed CLI)" and "Codex (installed CLI)"), `{model}` the model id, and `{cli}` is "Claude Code" or "Codex". Rows that say `{label}` use the catalog label on both platforms; only rows that say `{cli}` use the short name.

| `LLMError` case | Raised when | Retried (§4.2) | Fallback (§4.3) | User message |
| --- | --- | --- | --- | --- |
| `noConnector` | `llm.connector` is empty | no | no | Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI. (Button: **Open AI settings**.) |
| `missingKey` | API-key connector and no key stored | no | no | Add your {label} API key in Settings › AI. |
| `unauthorized` | 401 or 403 from a connector whose catalog entry has `auth.keyAccount`, Gemini 400 with reason `API_KEY_INVALID`, xAI 400 mentioning "API key" | no | no | {label} rejected the API key. Check it in Settings › AI. |
| `quotaExceeded` | Anthropic 402 `billing_error`, OpenAI 429 with code `insufficient_quota` | no | no | {label} says this account is out of credit or over its quota. |
| `rateLimited(retryAfter?)` | 429 after retries, or a wait hint over 30 s | yes | yes | {label} is rate limiting this key. Try again in a minute. (With a hint: "Try again in {n} s.") |
| `planLimit(message?)` | CLI reports a usage or rate limit | no | yes (Codex), CLI-internal (Claude Code) | Your {cli} plan's usage limit is reached. {message} |
| `overloaded` | 503, 529, `overloaded_error` after retries | yes | yes | {label} is overloaded right now. Try again shortly or pick another model. |
| `server(status)` | other 5xx after retries | yes | no | {label} had a server error ({status}). Try again. |
| `network` | DNS, offline, TLS, connection refused (cloud) | no | no | Couldn't reach {label}. Check your internet connection. |
| `timeout` | request timeout (§4.4) | no | no | {label} took too long to answer. Try again, or pick a faster model. |
| `modelNotFound(model)` | 404, OpenAI `model_not_found`, Gemini `NOT_FOUND`, Ollama "model not found", CLI model errors | no | no | {label} doesn't offer the model "{model}" to this account. Pick another model or refresh the list. |
| `contextTooLong` | 413, "prompt is too long", `context_length_exceeded`, Apple context errors after the shrink retry (§6.7) | no | no | This transcript is too long for {model}. Pick a model with a larger context. |
| `badRequest(status, message)` | any other 4xx | no | no | {label} rejected the request ({status}): {message, at most 200 characters, redacted} |
| `refused(category?)` | `stop_reason: refusal`, OpenAI `refusal` content, Gemini safety finish or block, Apple guardrail | no | no | Clip finder: "Clips could not be suggested for this recording." Tighten: "The model declined to tighten this recording." Test: "The model declined the test request." Re-voice and Fix with AI: "The model declined to rewrite this recording." |
| `truncated` | `max_tokens`, `incomplete`, `MAX_TOKENS`, Ollama `done_reason: length` | no | no | Clip finder: "The clip suggestions were incomplete. Please try again." Tighten: "The tighten suggestions were incomplete. Please try again." Re-voice and Fix with AI: "The rewrite was incomplete. Please try again." |
| `invalidOutput(reason)` | §4.6 failed twice | no | no | The model's answer wasn't in the expected format. Try again or pick another model. |
| `unsupportedLanguage(lang)` | Apple locale gate (§6.7) | no | no | Apple's on-device model doesn't support {language name}. Use an API key, a CLI or a local model for this project. |
| `notRunning(url)` | Ollama or LM Studio connection refused | no | no | macOS v2: "{label} isn't answering at {url}. Start it, then try again." Rewrite uses "choose Try Again" and the chooser uses "choose Check Again". The harness picker also retains the attempted URL. Windows: Ollama isn't running at {url}. Start Ollama and try again. / LM Studio's server isn't running at {url}. Start it from LM Studio's Developer tab. |
| `noModels` | local server has no chat model | no | no | Ollama has no chat models. Run `ollama pull <model>`, then refresh. / Load or download a model in LM Studio, then refresh. |
| `unavailable(reason)` | Apple availability; Ollama or LM Studio answering 401 or 403 (they have no key to fix); an unusable Ollama or LM Studio address in settings (credentials, query, fragment or a scheme other than http and https) | no | no | This Mac can't run Apple Intelligence. / Turn on Apple Intelligence in System Settings to use the on-device model. / Apple's on-device model is still downloading. Try again later. / {label} rejected the request ({status}). / {label}'s server address in Settings isn't valid. (also for a 404 from the local status probe) / VoxClip is missing its AI configuration. Reinstall VoxClip. (catalog disagrees with the §1 rule 5 table) / {label} is not enabled. (catalog `enabled: false`, the release kill switch; also for a 400 from a local status probe use "{label} rejected the request ({status})." without the provider's message) |
| `cliMissing` | no executable found | no | no | {cli} isn't installed. {installHint} |
| `cliTooOld(version, missing)` | required flags missing from `--help`; a non-zero or unparseable `--version`; a non-zero help exit; a failing `codex features list` | no | no | Your {cli} {version} is too old for VoxClip. Update it, then try again. When the version could not be read: Your {cli} is too old for VoxClip. Update it, then try again. |
| `cliSignedOut` | auth preflight or auth markers | no | no | {cli} isn't signed in. {signInHint} |
| `cliNetworkUnreachable(detail)` | CLI network marker in stderr or a parsed Codex transport error at VoxClip’s timeout | no | no | {cli} couldn't reach its server from VoxClip. Recovery copy below; redacted first line, at most 200 characters. |
| `cliFailed(message)` | non-zero exit or unparseable output, no better match | no | no | {cli} stopped with an error: {message, at most 200 characters, redacted} |
| `cancelled` | the user cancelled | no | no | (no message) |

Feature-level messages come from the prompt files' `messages` objects: no words, missing custom instructions, no results.

Per architecture §10.1 rule 1, every message shown after a failed AI action ends with "Your edits are saved." An AI failure never changes the project.

### 5.1 App-level error codes

The architecture (`doc/architecture.md` §10.2) defines the cross-app `VoxClipError` codes. Those codes drive `voxclip-cli` exit codes, the `--json` error object and the shared error styling. Each `LLMError` case carries one of them. For AI features, the message text in the table above is the one shown.

| App code | `LLMError` cases | CLI exit |
| --- | --- | --- |
| `keyMissing` | `noConnector`, `missingKey` | 7 |
| `keyRejected` | `unauthorized` | 1 |
| `rateLimited` | `rateLimited`, `planLimit`, `overloaded` | 1 |
| `offline` | `network`, `cliNetworkUnreachable` | 1 |
| `modelMissing` | `noModels` | 7 |
| `cliNotInstalled` | `cliMissing`, `cliTooOld` | 7 |
| `cliNotSignedIn` | `cliSignedOut` | 7 |
| `localeUnsupported` | `unsupportedLanguage` | 1 |
| `llmInvalidOutput` | `invalidOutput`, `truncated` | 1 |
| `providerError` | `quotaExceeded`, `server`, `timeout`, `modelNotFound`, `contextTooLong`, `badRequest`, `refused`, `notRunning`, `unavailable`, `cliFailed` | 1 |
| `cancelled` | `cancelled` | 6 |

---

## 6. Connector mappings

Placeholders: `{system}`, `{cachedBlock}`, `{instruction}`, `{schemaName}`, `{schema}` (the canonical object), `{maxOut}` (`request.maxOutputTokens` capped by the connector's `maxOutputTokensCap`), `{effort}`.

All bodies below are complete. A connector must not add fields that aren't listed.

### 6.1 Anthropic Messages

`POST https://api.anthropic.com/v1/messages`

Headers:
- `x-api-key: {key}`
- `anthropic-version: 2026-10-21`
- `content-type: application/json`
- Only when the model has `serverSideFallback: true` in the catalog: `anthropic-beta: server-side-fallback-2026-07-01`

```json
{
  "model": "claude-opus-5-5",
  "max_tokens": 16000,
  "system": "{system}",
  "messages": [{
    "role": "user",
    "content": [
      { "type": "text", "text": "{cachedBlock}", "cache_control": { "type": "ephemeral" } },
      { "type": "text", "text": "{instruction}" }
    ]
  }],
  "output_config": {
    "effort": "xhigh",
    "format": { "type": "json_schema", "schema": {} }
  },
  "fallbacks": "default"
}
```

- When `cachedBlock` is null (the test request), send one text block without `cache_control`.
- `fallbacks` is sent only together with the beta header.
- If a 400 says the `anthropic-beta` value is unexpected, re-send once without the header and without `fallbacks`, and remember that for this session.
- A `voiceRewrite` send carries neither the beta header nor `fallbacks`, so it is never re-sent (§12.8).
- `output_config.effort` is sent when the model has `effort: true` in the catalog, or the cached model list reports `capabilities.effort.supported`, or (for a custom id) the id matches `^claude-(opus|sonnet|haiku|fable)-5`. Otherwise `effort` is omitted.
- `output_config.format` is always sent. If the cached model list reports `capabilities.structured_outputs.supported == false` for a custom model, omit `format` and append to the instruction: `Reply with only a JSON object that matches this JSON Schema: {compact schema}`.
- **Never send** `temperature`, `top_p`, `top_k`, `thinking` (current models think adaptively by default, and `{"type":"disabled"}` is a 400 on Opus 5.5 and Sonnet 5.5), an assistant prefill message, or `tool_choice` of type `any` or `tool`. On API version `2026-10-21`, sampling parameters are a 400 on every model.

Response:
- `stop_reason`: `end_turn` or `stop_sequence` means complete. `max_tokens` means truncated. `refusal` means refused with `stop_details.category`.
- Text is the concatenation of `content[]` blocks whose `type` is `text`. Every other block type (thinking, fallback markers) is skipped.
- `model` is the answering model. After a server-side fallback it names the fallback model.
- Usage: `usage.input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.
- Request id: header `request-id`.

Errors by `error.type`:

| Type | Maps to |
| --- | --- |
| `invalid_request_error` (400) | `contextTooLong` if the message contains "prompt is too long" or "too many tokens"; otherwise `badRequest` |
| `authentication_error` (401) | `unauthorized` |
| `billing_error` (402) | `quotaExceeded` |
| `permission_error` (403) | `unauthorized` |
| `not_found_error` (404) | `modelNotFound` |
| `request_too_large` (413) | `contextTooLong` |
| `rate_limit_error` (429) | retry, then `rateLimited` |
| `api_error` (500) | retry, then `server` |
| `overloaded_error` (529) | retry, then `overloaded` |

Prompt caching: the clip-finder system prompt and the transcript block are byte-identical across presets of one take, so a second preset within 5 minutes reads the cache. The minimum cacheable prefix is 512 tokens on the 5.x models. Shorter takes simply don't cache.

### 6.2 OpenAI Responses

`POST https://api.openai.com/v1/responses`, headers `Authorization: Bearer {key}`, `content-type: application/json`.

```json
{
  "model": "gpt-5.6-terra",
  "instructions": "{system}",
  "input": [{
    "role": "user",
    "content": [
      { "type": "input_text", "text": "{cachedBlock}" },
      { "type": "input_text", "text": "{instruction}" }
    ]
  }],
  "text": { "format": { "type": "json_schema", "name": "{schemaName}", "strict": true, "schema": {} } },
  "max_output_tokens": 16000,
  "reasoning": { "effort": "high" },
  "store": false,
  "prompt_cache_key": "voxclip-0123456789abcdef"
}
```

- `reasoning` is sent only for models with `effort: true` in the catalog, or a custom id matching `^(gpt-5|gpt-6|o[0-9])`.
- `prompt_cache_key` is `voxclip-` plus the first 16 lowercase hex characters of SHA-256 of `cachedBlock`. Omit it when `cachedBlock` is null.
- `store` is always `false`.
- **Never send** `temperature` or `top_p`. Current GPT models are reasoning models and reject them.

Response:
- `status == "incomplete"`: `incomplete_details.reason` of `max_output_tokens` means truncated; `content_filter` means refused.
- `status == "failed"`: map `error.code` as in the table below.
- Otherwise iterate `output[]` items with `type == "message"`. In each item's `content[]`, `output_text` contributes `text` and `refusal` means refused.
- Usage: `usage.input_tokens`, `usage.output_tokens`, `usage.input_tokens_details.cached_tokens`.
- Request id: header `x-request-id`.

Errors (`error.code`, `error.type`, HTTP status):

| Condition | Maps to |
| --- | --- |
| 401 | `unauthorized` |
| 403 | `unauthorized` (the key is not allowed this model or region) |
| 404, or code `model_not_found` | `modelNotFound` |
| 400 with code `context_length_exceeded` | `contextTooLong` |
| other 400 | `badRequest` |
| 429 with code or type `insufficient_quota` | `quotaExceeded`, no retry |
| other 429 | retry, then `rateLimited` |
| 500, 502 | retry, then `server` |
| 503 | retry, then `overloaded` |

### 6.3 xAI

`POST https://api.x.ai/v1/chat/completions`, headers `Authorization: Bearer {key}`, `content-type: application/json`.

```json
{
  "model": "grok-4.5",
  "max_completion_tokens": 16000,
  "messages": [
    { "role": "system", "content": "{system}" },
    { "role": "user", "content": "{cachedBlock}\n\n{instruction}" }
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": { "name": "{schemaName}", "strict": true, "schema": {} }
  }
}
```

**Never send** `temperature`, `top_p` or `reasoning_effort`.

Response:
- Text is `choices[0].message.content`.
- A non-null `choices[0].message.refusal` means refused. `finish_reason == "length"` means truncated.
- Usage: `usage.prompt_tokens`, `usage.completion_tokens`, `usage.prompt_tokens_details.cached_tokens`.
- Prompt caching is automatic.

Errors:

| Condition | Maps to |
| --- | --- |
| 401, 403, or a 400 whose message mentions "API key" | `unauthorized` |
| 404 | `modelNotFound` |
| 400 mentioning "maximum context length" or "too long" | `contextTooLong` |
| other 400 | `badRequest` |
| 429 | retry, then `rateLimited` |
| 503 | retry, then `overloaded` |
| other 5xx | retry, then `server` |

### 6.4 Google Gemini

`POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`

- The model id is path-escaped. If the id starts with `models/`, strip that prefix.
- Headers: `x-goog-api-key: {key}`, `content-type: application/json`.
- **The key never goes in the URL.** A `?key=` query parameter is forbidden; URLs end up in logs and error descriptions.

```json
{
  "systemInstruction": { "parts": [{ "text": "{system}" }] },
  "contents": [{
    "role": "user",
    "parts": [{ "text": "{cachedBlock}" }, { "text": "{instruction}" }]
  }],
  "generationConfig": {
    "maxOutputTokens": 16000,
    "responseMimeType": "application/json",
    "responseJsonSchema": {}
  }
}
```

**Never send** `responseSchema` (the older OpenAPI-subset field; it is mutually exclusive with `responseJsonSchema`), `temperature`, `topP`, `topK` or `thinkingConfig`.

Response:
- If `promptFeedback.blockReason` is set, the reply is refused with that reason.
- Text is the concatenation of `candidates[0].content.parts[].text`, skipping parts with `thought: true`.
- `candidates[0].finishReason`:
  - `STOP` means complete.
  - `MAX_TOKENS` or `CONTINUATION` means truncated.
  - `SAFETY`, `RECITATION`, `LANGUAGE`, `BLOCKLIST`, `PROHIBITED_CONTENT`, `SPII` or `OTHER` means refused with that reason.
- Usage: `usageMetadata.promptTokenCount`, `candidatesTokenCount`, `cachedContentTokenCount`. Implicit caching is automatic.

Errors (`error.status`, `error.details[].reason`):

| Condition | Maps to |
| --- | --- |
| 400 `INVALID_ARGUMENT` with reason `API_KEY_INVALID` | `unauthorized` |
| 400 whose message mentions exceeding the maximum number of tokens | `contextTooLong` |
| other 400 | `badRequest` |
| 403 `PERMISSION_DENIED` | `unauthorized` |
| 404 `NOT_FOUND` | `modelNotFound` |
| 429 `RESOURCE_EXHAUSTED` | retry (honour `RetryInfo.retryDelay`), then `rateLimited` |
| 500 `INTERNAL` | retry, then `server` |
| 503 `UNAVAILABLE` | retry, then `overloaded`. This triggers the fallback model. |
| 504 `DEADLINE_EXCEEDED` | `timeout` |

### 6.5 Ollama (native API)

The base URL is `http://127.0.0.1:11434` by default and the user can change it. Use `127.0.0.1`, not `localhost`. Use the native `/api/chat`: the OpenAI-compatible `/v1` endpoint cannot set the context size and silently truncates at the server default.

**Status.** `GET /api/version` with a 3 s timeout. Connection refused means `notRunning(url)`. Then list models (§9). No chat-capable model means `noModels`.

**Model details.** `POST /api/show {"model": "{model}"}`:
- context limit = the value of the `model_info` key ending in `.context_length`;
- `capabilities` (when present) must contain `completion`. If it contains `thinking`, the request sends `"think": false`.

**Context size.**

```text
needed  = est(system) + est(cachedBlock) + est(instruction) + est(compact schema) + maxOut + 256
num_ctx = min(modelContext, max(8192, roundUp(needed, 1024)))
```

`est(s) = ceil(utf8ByteCount(s) / 2.2)`. If `needed > modelContext`, the pipeline splits the transcript into windows (§11.5) using `modelContext` as the context.

```json
POST /api/chat
{
  "model": "gemma4:12b",
  "stream": false,
  "messages": [
    { "role": "system", "content": "{system}" },
    { "role": "user", "content": "{cachedBlock}\n\n{instruction}" }
  ],
  "format": {},
  "options": { "num_ctx": 32768, "num_predict": 4096, "temperature": 0 },
  "think": false,
  "keep_alive": "10m"
}
```

- `num_predict` is `{maxOut}`, capped at 4096.
- `think` is sent only for models with the `thinking` capability.

Response:
- Text is `message.content`.
- `done_reason == "length"` means truncated.
- Usage: `prompt_eval_count` (input) and `eval_count` (output).

Errors:
- 404 or `{"error":"model '…' not found"}` means `modelNotFound`.
- Connection refused means `notRunning`.
- Other 4xx means `badRequest`. 5xx is retried, then `server`.

### 6.6 LM Studio

The base URL is `http://127.0.0.1:1234` by default and the user can change it. The connector speaks the OpenAI-compatible API, so it also works with other local OpenAI-compatible servers the user points it at.

- **Status.** `GET /v1/models` with a 3 s timeout. Connection refused means `notRunning`. An empty list means `noModels`.
- **Context.** `GET /api/v0/models/{model}`. Use `loaded_context_length` if present, else `max_context_length`. If the endpoint or fields are missing, assume 4096 and show this note under the model picker: "VoxClip can't read this model's context length, so it assumes 4,096 tokens and splits long transcripts. Load the model with a larger context in LM Studio for fewer parts." (Endpoint to verify, §14.) VoxClip never loads or unloads LM Studio models.

```json
POST /v1/chat/completions
{
  "model": "{model}",
  "max_tokens": 4096,
  "temperature": 0,
  "messages": [
    { "role": "system", "content": "{system}" },
    { "role": "user", "content": "{cachedBlock}\n\n{instruction}" }
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": { "name": "{schemaName}", "strict": true, "schema": {} }
  }
}
```

The response and errors are parsed as for xAI (§6.3). An error message containing "No models loaded" means `noModels`.

### 6.7 Apple Foundation Models (macOS only)

**Status.** `SystemLanguageModel.default.availability`:
- `.available` means ready.
- `.unavailable(.deviceNotEligible)`, `.unavailable(.appleIntelligenceNotEnabled)` and `.unavailable(.modelNotReady)` each map to `unavailable` with the matching message in §5.

**Locale gate (before every run, no model call).**
1. `lang = request.language`. If nil, use the dominant language from `NLLanguageRecognizer` over the first 2,000 words of the transcript.
2. If `lang` is nil, or `SystemLanguageModel.default.supportsLocale(Locale(identifier: lang))` is false, raise `unsupportedLanguage(lang)`.

Estonian is not supported (measured on macOS 27.0.1). The UI then points to API keys, CLIs or local servers.

**Context.**
- `contextTokens = SystemLanguageModel.default.contextSize`, read at runtime and never hard-coded. It measured 8192 on macOS 27.0.1; macOS 26 releases report 4096.
- `maxOut = min(request.maxOutputTokens, 1500)`.
- On macOS 26.4 and later, each window is confirmed with `try await SystemLanguageModel.default.tokenCount(for: prompt)`. Earlier releases use `est()`.

**Session.** One fresh `LanguageModelSession(model: .default, instructions: request.system)` per window, with no history. Prompt = `cachedBlock + "\n\n" + instruction`.

**Schema.** Build a `DynamicGenerationSchema` from the canonical schema and wrap it with `GenerationSchema(root:dependencies: [])`:

**Names (normative).** All `DynamicGenerationSchema` names must be unique within one schema. The root is named `<schemaName>`. Every property `P` of a node named `N` is named `N_P`, and that full path is passed down recursively. An array property's item schema appends `_item`, giving `N_P_item`; a nested object property is named `N_P`; a string enum property is also named `N_P`. Primitive scalar schemas (string, number, integer or boolean without enum) must not emit names because the SDK ignores them. These are schema names, not JSON property names.

- Clip schema: root `clips`, its `clips` array item `clips_clips_item`.
- Tighten schema: root `tighten_edits`, its `edits` array item `tighten_edits_edits_item`, and that item's `kind` enum `tighten_edits_edits_item_kind`.

Apple's SDK deduplicates duplicate schema names; reusing the root name for an array item produces `items.$ref: "#"`, a self-reference to the root instead of the item schema.

**SDK JSON comparison.** `GenerationSchema` JSON encoding preserves object node names (root, `N_P` and `N_P_item`) as `title`; harnesses must compare these titles byte-for-byte with the logical fixture names. It does not retain string-enum names: enum schemas encode only `type: "string"` and their enum values. String-enum names remain part of the `DynamicGenerationSchema` builder contract and the logical fixture; harnesses must derive them from the node path rather than read them from encoded JSON. Apple fixtures must not contain duplicate schema names or root self-references (`$ref: "#"`).

| Canonical | DynamicGenerationSchema |
| --- | --- |
| object | `DynamicGenerationSchema(name: pathName, properties: [...])`, using the naming rule above; every property `isOptional: false` |
| array | `DynamicGenerationSchema(arrayOf: item, maximumElements: k)`. `k` is the window's clip budget for `clips` (§11.5), nil otherwise |
| string | `DynamicGenerationSchema(type: String.self)` |
| integer | `DynamicGenerationSchema(type: Int.self)` |
| number | `DynamicGenerationSchema(type: Double.self)` |
| boolean | `DynamicGenerationSchema(type: Bool.self)` |
| string enum | `DynamicGenerationSchema(name: pathName, anyOf: values)`, using the naming rule above |

**Generation.**
- Xcode 27's SDK: `GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxOut)`. This initializer is back-deployed to macOS 26.
- Xcode 26's SDK: `GenerationOptions(sampling: .greedy, maximumResponseTokens: maxOut)`. The SDK 26 compiler has no `samplingMode:` initializer; a runtime availability check alone cannot make that reference compile.
- Call `session.respond(to: prompt, schema: schema, options: options)`. `RawCompletion.object` is decoded from `response.content.jsonString`.

**Errors.** Handle the macOS 26 `LanguageModelSession.GenerationError` and, when built with Xcode 27's SDK, the macOS 27 `LanguageModelError` and `LanguageModelSession.Error` cases. Compile the latter only when that SDK declares them; keep the legacy mapping for macOS 26 runtime errors:

| Apple error | Handling |
| --- | --- |
| context exceeded | The pipeline multiplies this window's token budget by 0.8, re-splits that window and retries once. A second failure is `contextTooLong` |
| guardrail violation, refusal | `refused` |
| unsupported language or locale | `unsupportedLanguage` |
| rate limited | wait 2 s, retry up to 2 times, then `rateLimited` |
| concurrent requests | wait 1 s, retry up to 3 times |
| timeout | `timeout` |
| anything else | `unavailable` with the error description, redacted |

Apple's Private Cloud Compute model is not used in v1.

### 6.8 Claude Code CLI (`claude -p`)

The user's own installed, unmodified Claude Code runs headless. The CLI owns sign-in. VoxClip only spawns it and reads its stdout. The compliance rules are in §7. The process rules shared with Codex are in §6.10.

**Verified on this machine (2026-10-25, Claude Code 2.1.309, macOS 27.0.1).** This command ran in an empty temporary directory:

```sh
printf 'Reply with {"ok":true}' | claude -p --output-format json \
  --json-schema '{"type":"object","additionalProperties":false,"required":["ok"],"properties":{"ok":{"type":"boolean"}}}' \
  --model haiku --fallback-model sonnet --effort low \
  --system-prompt "You are a JSON API. Answer only with the requested structured output." \
  --tools "" --no-session-persistence --safe-mode --strict-mcp-config --disable-slash-commands
```

It exited 0 and printed one JSON object. Excerpt:

```json
{"type":"result","subtype":"success","is_error":false,"result":"{\"ok\":true}",
 "structured_output":{"ok":true},"stop_reason":"tool_use","terminal_reason":"completed",
 "api_error_status":null,"num_turns":2,"modelUsage":{"claude-haiku-5-5":{}},"permission_denials":[],
 "usage":{"input_tokens":2,"output_tokens":68,"cache_read_input_tokens":0,"cache_creation_input_tokens":1048}}
```

The working directory was still empty afterwards. Structured output runs through an internal tool (`num_turns: 2`) and still works with `--tools ""`.

Signed out, the same flags exited 1 with `{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","terminal_reason":"api_error","api_error_status":null,…}`. `claude auth status --json` printed `{"loggedIn": false, "authMethod": "none", …}` and exited 1. The signed-out state was produced by pointing `CLAUDE_CONFIG_DIR` at an empty directory, as a test technique only. VoxClip never sets that variable.

**Detection.** Use the catalog `cli.detect` entries, cached per binary (§6.10):
1. `claude --version` and parse `^(\d+\.\d+\.\d+)`.
2. `claude --help` must list every `requiredFlags` entry: `--print`, `--output-format`, `--json-schema`, `--tools`, `--system-prompt`, `--model`, `--no-session-persistence`, `--safe-mode`. Otherwise `cliTooOld`. Note which `optionalFlags` are present.
3. `claude auth status --json`: `loggedIn == true` means ready. Exit code 1 or `loggedIn == false` means `cliSignedOut`. VoxClip reads only `loggedIn` and `authMethod` (a method name, not a credential), so the status line can say "Signed in · API key" and the consent confirmation (§4.8, inline on Mac) never claims plan usage for an API-key sign-in. Other fields (account details) are discarded and never stored. The method is compared after lowercasing and turning `-` and `.` into `_`. It is a plan only when it is `claude_ai` (Claude Code prints `claude.ai`), `claudeai`, `oauth` or `oauth_token`, and an API key when it names one, such as `api_key`. Every other value, including `third_party` (Bedrock or Vertex, billed to the user's cloud account) and `none`, is an unknown method: no consent confirmation and no send (§4.8).

**Invocation** (argv array, the catalog `invocation.args`):

```text
claude -p --output-format json
       --json-schema {compact canonical schema}
       --system-prompt {system}
       --tools ""
       --no-session-persistence
       [--model {model}]                 omitted when the model is "default"
       [--fallback-model {fallback}]     first fallbackOrder entry ≠ model, if --fallback-model is supported;
                                         never for a voiceRewrite send (§12.8)
       [--effort {effort}]               if supported; the resolved level (§4.4.1), xhigh for AI decisions
       --safe-mode                       always (required flag)
       [--strict-mcp-config]             if supported
       [--disable-slash-commands]        if supported
stdin: {cachedBlock}\n\n{instruction}
cwd:   a fresh empty directory
```

What the flags do:
- `--tools ""` removes every built-in tool. `--strict-mcp-config` with no `--mcp-config` loads no MCP servers. `--safe-mode` turns off CLAUDE.md files, skills, plugins, hooks, MCP servers and custom commands, while auth and model selection work normally.
- `--system-prompt` replaces the CLI's default system prompt.
- The prompt goes through stdin because Windows command lines are limited to 32,767 characters, and transcripts reach about 60 KB.
- The system prompts (1.1 KB and 1.8 KB) and the compact schema (under 1 KB) fit in argv.

**Forbidden flags** (catalog `forbiddenFlags`):
- `--bare`. It makes authentication strictly `ANTHROPIC_API_KEY` or `apiKeyHelper` and never reads the user's OAuth sign-in, which would restrict the CLI's built-in authentication methods.
- `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, `--add-dir`, `--mcp-config`, `--settings`, `--resume`, `--continue`.
- `--setting-sources` with an empty value. It disables the settings-based auth methods Claude Code supports (`apiKeyHelper`, `env` for Bedrock or Vertex), the same kind of restriction as `--bare`. A CLI without `--safe-mode` is `cliTooOld` instead.

`--system-prompt-file` also works but is not listed in `--help`, so VoxClip doesn't rely on it.

**Parsing.**
1. Timeout means `timeout`, except when the bounded stderr contains network evidence (see network recovery below); Claude stdout is excluded from timeout classification. stdout must be one transport envelope (§4.5): trimmed with jsTrim and parsed whole, at most 512 levels deep, with no code fence or balanced-object scan. Otherwise, or when it is empty, classify only the selected stderr line using the rule below. Missing or wrongly typed `type` or `is_error` fields are malformed envelopes too.
2. The object must have `type == "result"`.
3. `is_error == false` with a nonzero exit: classify only the selected stderr line, falling back to `cliFailed`; the successful model `result` text and `api_error_status` are never error-classification evidence. With a zero exit, first the stop. `stop_reason` `max_tokens` is `truncated`, and `refusal` is `refused` with no category; any other value, or none, is a complete reply. Then use `structured_output` (an object) as `RawCompletion.object`. If it is absent, extract JSON from the `result` string (§4.5). Either way the reply holds at most 64 levels.
4. `is_error == true`: `message = result`. Classify case-insensitively: the first matching category in list order wins. Each category matches its markers OR its numeric status, not all statuses before all markers:
   - `authErrorMarkers`, or `api_error_status` 401 or 403, means `cliSignedOut`.
   - `limitMarkers`, or `api_error_status` 429, means `planLimit(message)`.
   - `overloadMarkers`, or `api_error_status` 529, means `overloaded`.
   - "prompt is too long" means `contextTooLong`.
   - `networkErrorMarkers` means `cliNetworkUnreachable(detail)`.
   - Anything else means `cliFailed(message)`.
5. `model` is the `modelUsage` key with the most `outputTokens` (falling back to `output_tokens`, then zero), or the requested alias if there is no key. On a tie choose the smallest key in ordinal UTF-8 byte order, independent of JSON member order (§12.8).
6. Usage comes from `usage`. `total_cost_usd` is ignored and never shown.

Optional envelope fields of the wrong JSON type are absent, including error status, event messages, agent items and model metadata. Integer fields accept an integral binary64 number such as `529.0`, but not a fraction or a string. A Codex `turn.failed` event still fails the send when its optional error message is absent (§6.9).

**Stderr selection (both CLIs).** Select the first nonempty LF-delimited stderr line, trimmed with jsTrim. If it matches any classifier marker (auth, limit, overload, model/context or network), keep it. Otherwise select the first stderr line containing a network marker, if any. Classify **only the selected line**, applying the normal precedence within that line, and use that same line as the redacted detail. Later help lines containing `/login`, `529` or other markers cannot relabel the selected diagnostic. A first line that is a real auth error stays signed out. Empty stderr falls back to the generic no-result message. This rule applies to malformed/missing envelopes, missing Codex error events, and Claude's nonzero exit with `is_error == false`.

**CLI network recovery (both platforms).** The shared catalog’s `networkErrorMarkers` for Claude Code and Codex contain `ECONNREFUSED`, `ENETUNREACH`, `EHOSTUNREACH`, `Connection refused`, `connect ETIMEDOUT`, `getaddrinfo ENOTFOUND`, `fetch failed`, `error sending request for url`, `dns error`, `failed to lookup address information`, `No route to host`, `Network is unreachable`, `os error 61`, `os error 65` and `tcp connect error`. Matching is case-insensitive, with the same code defaults if the list is absent. Sign-out, usage-limit and overload checks keep precedence, including mixed network messages. Existing model/context errors keep precedence too. A network failure maps to `offline`, is not retried automatically, and retains only its first nonempty LF-delimited line, redacted before truncation to at most 200 characters.

At VoxClip’s own generation timeout, the process runner preserves bounded partial output. Classification text is stderr plus only the `message` from parsed Codex `error` events (including `Reconnecting...` progress and its reason) and `error.message` from parsed `turn.failed` events. Never classify whole stdout, `item.*` reasoning or agent messages, thread/item IDs, usage counts, malformed JSONL, or any Claude stdout. If the allowed transport text contains a network marker, use the same classification and precedence; without network evidence the error stays `timeout`. Cancellation remains silent and wins over timeout. Detection and sign-in probes keep their existing timeout behavior. Raw output is never logged or persisted.

On Mac, Rewrite shows two inline lines: “{cli} couldn't reach its server from VoxClip.” and “If it uses a server on your network, allow VoxClip in System Settings › Privacy & Security › Local Network, then try again.” The redacted detail uses secondary text. Other Mac features show the recovery sentences only; they never append raw detail to the recovery sentence. After an approved send fails this way, Rewrite's failed send step reads “Couldn't reach {cli}”, as for a network failure. **Open Local Network Settings** opens `x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork` through an injectable URL opener, beside the existing **Try Again** action (or **Try Again…** when a send requires approval). This is guidance for a possible LAN server, not a diagnosis of the user's permissions or proxy configuration. VoxClip never reads CLI configuration or guesses a base URL.

On Windows, the inline error reads “{cli} couldn't reach its server from VoxClip. Check your network or proxy, then try again.” followed by the existing saved-edits reassurance and retry action. No Local Network settings action is shown. `{cli}` is “Claude Code” or “Codex”, without the catalog’s installed-CLI suffix.

**Models.** The curated aliases are `sonnet` (default), `opus` and `haiku`, plus "CLI default", which omits `--model`. A custom id may be any full model id the CLI accepts. There is no list endpoint, so model refresh is not offered for this connector.

### 6.9 Codex CLI (`codex exec`)

**Verified on this machine (2026-10-25, codex-cli 0.163.0-alpha.10.2 bundled in the ChatGPT desktop app, macOS 27.0.1, signed in with ChatGPT).** That bundled copy is a private component of the ChatGPT app, not a Codex install, so VoxClip does not search for it (catalog `searchPaths`); the behaviour below must be re-verified on a standalone Codex release (Homebrew or npm `@openai/codex`) before 0.1.0 (§14 item 5). `$EMPTY` and `$IO` were two fresh temporary directories:

```sh
printf 'Reply with {"ok":true}' | codex exec --json --ephemeral --skip-git-repo-check \
  --ignore-user-config --ignore-rules -s read-only -C "$EMPTY" -m gpt-5.6-luna \
  -c 'model_reasoning_effort="low"' -c 'web_search="disabled"' -c 'approval_policy="never"' \
  -c 'mcp_servers={}' -c 'developer_instructions="You are a JSON API. Answer only with the requested structured output."' \
  --disable shell_tool --disable unified_exec --disable apps --disable plugins --disable multi_agent \
  --disable image_generation --disable hooks --disable browser_use --disable computer_use \
  --output-schema "$IO/schema.json" -o "$IO/last.json" -
```

It exited 0, and `$EMPTY` stayed empty. stdout (JSONL):

```text
{"type":"thread.started","thread_id":"…"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"ok\":true}"}}
{"type":"turn.completed","usage":{"input_tokens":12240,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":0}}
```

`last.json` held `{"ok":true}`. Codex always adds its own base instructions, about 12k input tokens even for a one-line prompt. That usage counts against the user's plan.

Other facts verified the same day:

- **Signed out, `codex exec` does not check login first.** With `CODEX_HOME` pointed at an empty directory (test technique only), it retried 401 for about 15 s, emitting events like `{"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, …)"}`, then `{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: …"}}`, and exited 1. `codex login status` printed `Not logged in` and exited 1. Hence the preflight below.
- **An unknown feature name is fatal.** `--disable no_such_feature` fails at once with `Error: Unknown feature flag: …` (exit 1). VoxClip passes only names that `codex features list` reports and whose stage is not `removed`.
- **`-c key=value` values are parsed as TOML.** If parsing fails, Codex silently uses the raw string. `developer_instructions` must therefore be a correctly escaped TOML basic string (below). The escaped clip-finder and ai-tighten system prompts round-tripped byte for byte, checked with app-server `config/read`.
- **Config keys accepted under `--strict-config`:** `web_search`, `model_reasoning_effort`, `developer_instructions`, `model_instructions_file`, `approval_policy`, `mcp_servers`. `base_instructions` is rejected. VoxClip uses `developer_instructions` and never `model_instructions_file`, which would replace Codex's base instructions and is untested with ChatGPT sign-in.
- **App server.** `codex app-server --listen stdio://` speaks newline-delimited JSON-RPC. `initialize` → `initialized` → `account/read` returned `{"account": null, "requiresOpenaiAuth": true}` signed out. `model/list` worked signed out and returned 8 models (the catalog list).
- **Old versions.** An npm install of codex-cli 0.44.0 on the same machine lacks `--ephemeral` and `--ignore-user-config`, so it is `cliTooOld`.

**Detection** (catalog `cli.detect`, cached per binary):
1. `codex --version` and parse `codex-cli (\S+)`.
2. `codex exec --help` must list `--json`, `--output-schema`, `--output-last-message`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`, `--sandbox`, `--cd`, `--model`. `--ignore-rules` is optional.
3. `codex features list` and parse each line with `^(\S+)\s+(.+?)\s+(true|false)\s*$`. Keep the names whose stage is not `removed`.
4. Auth: `codex login status`. Exit 0 means signed in ("Logged in using ChatGPT" or "Logged in using an API key"). Exit 1 or the text `Not logged in` means `cliSignedOut`.

**Preflight before every run:** step 4, with a 10 s timeout. Never start `codex exec` while signed out.

**Invocation** (argv array, the catalog `invocation.args`):

```text
codex exec --json --ephemeral --skip-git-repo-check --ignore-user-config
           [--ignore-rules]                                   if supported
           --sandbox read-only --cd {cwd}
           [--model {model}]                                  omitted when the model is "default"
           [-c model_reasoning_effort="{effort}"]             when effort is set
           -c web_search="disabled"
           -c approval_policy="never"
           -c mcp_servers={}
           -c developer_instructions={TOML basic string of system}
           --disable {f} …                                    for each f in disableFeatures present in features list
           --output-schema {io}/schema.json                   compact canonical schema
           --output-last-message {io}/last.json
           -
stdin: {cachedBlock}\n\n{instruction}
```

`disableFeatures` (verified set): `shell_tool`, `unified_exec`, `apps`, `plugins`, `multi_agent`, `image_generation`, `hooks`, `browser_use`, `computer_use`. Add a name only after verifying the invocation still succeeds with it.

**Forbidden flags:** `--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`, `--add-dir`, `--search`, `--worktree`, `--profile`, `--oss`.

**TOML basic string escaping** for `developer_instructions`. Emit `"`, then for each Unicode scalar:

| Input | Output |
| --- | --- |
| `\` | `\\` |
| `"` | `\"` |
| U+0008 | `\b` |
| tab | `\t` |
| LF | `\n` |
| U+000C | `\f` |
| CR | `\r` |
| other U+0000–U+001F, and U+007F | `\uXXXX` (uppercase hex) |
| anything else | unchanged (UTF-8) |

Then emit a closing `"`. The argument is `developer_instructions=` followed by that string.

**Parsing.**
1. Split stdout into lines at LF and read each line as a transport envelope (§4.5), skipping lines that are not one. `error` events whose message starts with `Reconnecting...` are progress, not failures.
2. Success means exit 0, a `turn.completed` event was seen and no `turn.failed` event was seen (even one without a usable message). The text is `last.json` if it is non-empty, otherwise the `text` of the last `item.completed` whose `item.type` is `agent_message`. That text is a reply (§4.5).
3. Failure: `message` is `turn.failed.error.message`, else the last non-progress `error` event message, else the first stderr line selected by §6.8, including its empty-stderr fallback. Classify case-insensitively; the first matching category in this list wins. Marker text comes from the connector's catalog lists (with code defaults for `networkErrorMarkers`):
   - `authErrorMarkers` means `cliSignedOut`.
   - `limitMarkers` means `planLimit(message)`.
   - `overloadMarkers` means `overloaded`.
   - `modelErrorMarkers` means `modelNotFound`.
   - "context" together with "length" or "window" means `contextTooLong`.
   - `networkErrorMarkers` means `cliNetworkUnreachable(detail)`.
   - Anything else means `cliFailed(message)`.
4. Usage comes only from `turn.completed.usage`: `input_tokens`, `cached_input_tokens`, `output_tokens`. All other fields, including `cache_write_input_tokens`, are ignored; cache-write usage is absent.
5. On `planLimit` or `overloaded`, the runner re-runs once with the fallback model (§4.3).

**Models.**
- The model list comes from the app server: spawn `codex app-server --listen stdio://` (§6.10 rules, 15 s timeout) and send:
  1. `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"voxclip","title":"VoxClip","version":"<app version>"}}}`
  2. `{"method":"initialized"}`
  3. `{"id":2,"method":"model/list","params":{"limit":100}}`
- Read `result.data[]`: `id`, `displayName`, `isDefault`, `hidden` (skip hidden models), and `supportedReasoningEfforts[].reasoningEffort`. Then terminate the process.
- The list is a catalog, not an entitlement check. If anything fails, use the curated list measured on 2026-10-25.
- "CLI default" omits `--model`. With `--ignore-user-config`, that is Codex's built-in default (`gpt-6.1-sol` on 2026-10-25).
- Effort is the highest level at or below the request that the chosen model lists (§4.4.1). "CLI default" uses the `isDefault` model's list, else the catalog's `effort.values`.

### 6.10 Rules shared by both CLI connectors

**Locating the binary.** The first existing executable wins:
1. The user's path override (`llm.cliPath.<id>`). This is the only way to point VoxClip at a binary outside the standard install locations.
2. Catalog `searchPaths`, with `~` and `%VAR%` expanded. Paths are only checked for existence and executed. Nothing else under `~/.claude` or `~/.codex` is ever opened.
3. The first line printed by catalog `shellLookup`.

macOS GUI apps get a minimal `PATH`, so PATH alone is never enough.

**Windows `.cmd` shims** (npm installs) are never run through `cmd.exe`, because quoting JSON and multi-line arguments through it is unsafe. Resolve `npmShimScript` and run `node.exe <script> <args…>`. `node.exe` is looked up next to the shim, then with `where.exe node`, then at `%ProgramFiles%\nodejs\node.exe`. A native `.exe` is preferred when present. The Windows install locations are to be verified on the VM (§14).

**Spawning.**
- All CLI processes go through the Core `ProcessRunner` protocol (architecture §1), so tests substitute fake executables (§13.8).
- Always with an argument array: Swift `Process.arguments`, C# `ProcessStartInfo.ArgumentList`. Never a shell string.
- Environment: inherit VoxClip's environment. On macOS, replace `PATH` with the login-shell PATH (`/bin/zsh -lc 'printf %s "$PATH"'`, cached) so npm-installed CLIs find `node`.
- VoxClip **must not set, change or add** `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `CODEX_API_KEY` or `CODEX_ACCESS_TOKEN`, and passes the user's environment through unchanged otherwise. VoxClip's own stored API keys are never passed to a CLI, and VoxClip's own environment-variable keys are named `VOXCLIP_*` (§8.1), so they can never reach a CLI under a name it reads.

**Working directory.**
- Create `<temp>/VoxClip/cli/<uuid>/cwd` (mode 0700, empty) as the working directory, and `<temp>/VoxClip/cli/<uuid>/io` for the schema and output files.
- Delete both after every run, including failed and cancelled runs.
- If `cwd` is not empty after a run, log `warning cli-wrote-files` before deleting it.

**I/O.** Write stdin as UTF-8 and close it. Read stdout and stderr concurrently to avoid a pipe deadlock, each capped at 16 MB. Both connectors select a failure's first stderr line using the LF-only, jsTrim and shared fallback rule in §6.8.

**App-server response ids.** Both Cores and both process runners use the first response line carrying a request's id (§4.5); later lines with that same id are ignored, even if they have a better-formed result. For `model/list` (id 2), if that first response's `result` is not an object, or its `data` is not an array, the model list is unavailable and refresh falls back to the cached or curated list (§9). A later valid id-2 response cannot repair it; a later malformed response cannot replace a valid first result. The initialization response likewise decides only once before the remaining handshake messages are sent.

**Timeout and cancel.**
- macOS: start the child in its own process group (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`). Send `SIGTERM` to the group, then `SIGKILL` after 3 s.
- Windows: put the child in a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, and close the job.

**Probe results (both CLIs, both platforms).**
- Required help flags are matched against the help command's stdout and stderr together.
- The sign-in check reads its signed-out signals before it looks at the exit code: the catalog `signedOutExitCode`, `loggedIn == false` in Claude Code's JSON, or the catalog `signedOutText` in either stream means `cliSignedOut`, whatever the exit code.
- A non-zero or unparseable `--version`, a non-zero help exit, missing required flags or a failing `codex features list` is `cliTooOld` (§5), checked in that order before any sign-in probe.
- Any other failure of a detection or sign-in probe (start failure, timeout, unreadable or truncated output, a sign-in probe's non-zero exit without a signed-out signal) is `cliFailed` with the message "The CLI could not be started or its output could not be read."
- Every `cliMissing` message includes the catalog `installHint`, including the refresh warning.
- A probe failure during a model refresh is a failed refresh (§9): the cached or curated list stays and the status reads "Couldn't refresh: {message}". It never escapes as an error.

**Other rules.**
- One CLI run at a time per connector.
- Cache detection results per (path, file size, modification time). Re-detect when Settings opens or a run fails with "unknown option".
- VoxClip never runs interactive commands such as `claude` without `-p`, `claude auth login`, `codex login` or `claude setup-token`. Its sign-in help shows the command with a **Copy** button and an **Open Terminal** button. The latter opens Terminal on macOS, or Windows Terminal or PowerShell on Windows, without typing anything.

---

## 7. Compliance rules for the subscription (CLI) connectors

These rules are normative. A change that breaks one must not ship.

### 7.1 Rules

1. **Unmodified binary.** VoxClip never bundles, downloads, installs, patches, wraps or replaces `claude` or `codex`. It runs the binary the user installed, as published. It never passes flags that remove, disable or restrict the CLI's authentication methods. That is why `--bare` is forbidden (§6.8).
2. **The user signs in through the CLI itself.** Sign-in happens only in the CLI's own flow (`claude`, then `/login`; `codex login`), started by the user in a terminal. VoxClip has no Claude.ai or ChatGPT login screen and offers no "Sign in with Claude".
3. **No token handling.** VoxClip never reads, copies, stores, logs or transmits CLI credentials or session tokens:
   - It never reads any file under `~/.claude`, `~/.claude.json` or `~/.codex` (including `auth.json`), nor the CLIs' Keychain or Credential Manager items. The only access to those folders is checking whether a CLI executable exists at a search path, and running it.
   - It never sets or reads the token environment variables listed in §6.10.
   - It never runs `claude setup-token` or `codex login --with-access-token`.
   - Sign-in state is learned only from `claude auth status --json` (`loggedIn` and `authMethod` only) and `codex login status` (exit code, and whether its text says "API key").
4. **No reselling or intermediation.** Usage is billed to the user under their own agreement with Anthropic or OpenAI. VoxClip is free, never charges for CLI usage, never proxies CLI traffic through any server, and never shares or pools sign-ins.
5. **Ordinary individual use.** CLI calls happen only for actions the user starts: Find clips, AI tighten, Rewrite and Test, plus the detection commands when the user opens Settings, Find clips or Rewrite, presses Detect or Retry, or starts one of those actions (§4.8). There are no background, scheduled or batch calls, windows run one at a time, and one CLI run is active at a time.
6. **Plain-text names only, no logos.**
   - The picker labels are plain text: "Claude Code (installed CLI)" and "Codex (installed CLI)". These say accurately that VoxClip runs those tools.
   - No Anthropic, Claude, Claude Code, OpenAI, ChatGPT or Codex logos or icons appear anywhere in VoxClip, its website or its release assets.
   - Those names are never part of a VoxClip product, feature, menu or button name. Features are "Find clips" and "AI tighten", never "Claude Clips" or "Codex Tighten".
   - There is no "Powered by", and nothing that suggests endorsement or partnership.
   - The same plain-text rule applies to the API-key connectors (Anthropic, OpenAI, xAI, Google Gemini), which are named only to identify the service the user's key belongs to.
7. **Attribution is plain text.** The About window and README may say: "VoxClip can run Claude Code or Codex if you have installed them and signed in. Their use is governed by your own agreements with Anthropic and OpenAI."
8. **Opt-in and disclosed.** CLI connectors are off until the user selects one, and the consent confirmation (§4.8, inline on Mac) states the detected billing method, never claiming plan usage for an API-key or unknown sign-in.
9. **Kill switch.** Each CLI connector has `enabled` in the catalog. Setting it to `false` in a release hides the connector without code changes. The switch is bundled data: it only affects builds released after the change, and the macOS app does not auto-update. It is therefore checked at release time (release.md §4 step 3a, ADR-R20), not used as a remote control.

### 7.2 What the vendors say (fetched 2026-10-25)

From Anthropic, `code.claude.com/docs/en/legal-and-compliance`:
- "The Claude Code binary must not be modified. Claude Code must be installed and run as published by Anthropic, and customers may not remove, disable, or restrict any authentication method built into it."
- "Customers may not pay for, resell, or intermediate Claude usage on their end users' behalf. Each end user must authenticate with their own Anthropic API key, Claude subscription plan credentials, or 3P inference provider credential."
- "You can accurately say, in plain text, that your product has Claude Code preinstalled or that it runs Claude Code. But you can't use the Claude Code or Anthropic names or logos as part of your own product, feature, or company name, in your own logo, or in a way that suggests Anthropic built, endorses, or is partnered with your product."
- "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."
- "Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription."
- "Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent SDK."

VoxClip's position: the user runs their own unmodified Claude Code on their own machine, signed in through Anthropic's flow, for their own edits. VoxClip neither hosts nor provides Claude Code and holds no credentials. The sentence about routing requests "through Free, Pro, or Max plan credentials on behalf of their users" is the residual risk. The lead has asked Anthropic to confirm this reading in writing (§14 item 8). On 2026-10-25 the lead decided to ship the connector enabled in 0.1.0 without waiting for the answer (ADR-R20); if Anthropic objects, the next release disables it.

From OpenAI, `developers.openai.com/siwc/token-sharing-open-source` (ChatGPT plan usage for open-source and locally hosted apps, the v1.1 feature) and its subpages:
- The page covers apps that run their own "Sign in with ChatGPT" OAuth flow, store the resulting credentials, and send Responses API requests. Those requests must set `store: false` and `stream: true`, must omit `temperature`, `top_p`, `max_output_tokens`, `metadata`, `user` and the other listed fields, and must not send `system`-role input items (use instructions or developer messages).
- UI: the sign-in action is labelled **Continue with ChatGPT**; show "Using ChatGPT plan" near the model picker; show a first-time "You're using your ChatGPT plan" notice and a **Manage usage** link. The host ID is opaque and persistent, never an email or user id. Usage is "not access to their ChatGPT conversations".
- The page says nothing about apps that call a user's own Codex CLI after `codex login`, and nothing about branding. The v1 Codex connector therefore applies rules 1 to 9 by analogy.

### 7.3 Sign in with ChatGPT (v1.1, not in 0.1.0)

v1.1 adds an `openai-chatgpt-plan` connector that implements OpenAI's documented flow: browser sign-in with fresh state, nonce and PKCE; a registered client id; the token stored in the Keychain or DPAPI under account `chatgpt-plan-token`; and the Responses constraints above. It needs its own spec. Until then, the only way to use a ChatGPT plan is the Codex CLI connector.

---

## 8. Keys and settings

### 8.1 Secret storage

Secret storage follows `doc/architecture.md` §11.4. The LLM accounts are the catalog `auth.keyAccount` values: `llm-api-key-anthropic`, `llm-api-key-openai`, `llm-api-key-xai` and `llm-api-key-gemini`.

- **macOS.** Keychain generic password, service `com.voxconvo.voxclip`, login keychain, `kSecAttrAccessibleAfterFirstUnlock`. Values are trimmed, and writing an empty value deletes the item.
- **Windows.** DPAPI `ProtectedData.Protect(bytes, entropy: UTF8("com.voxconvo.voxclip"), DataProtectionScope.CurrentUser)`, written atomically to `<data>\Secrets\<account>.bin`.
- **Core never stores keys.** The platform secret store belongs to the UI layer. Core receives a key as a value through the `KeyProvider` protocol (`func key(for account: String) -> String?`; C# `IKeyProvider`) and never keeps it. C# core tests on macOS use an in-memory provider; nothing ever writes plaintext key files.
- **Headless.** `voxclip-cli` reads keys only from the catalog `auth.debugEnvVar` variables (`VOXCLIP_ANTHROPIC_API_KEY`, `VOXCLIP_OPENAI_API_KEY`, `VOXCLIP_XAI_API_KEY`, `VOXCLIP_GEMINI_API_KEY`) and never touches the Keychain or DPAPI (architecture §9.4). This provider ships in release builds of `voxclip-cli`. Each variable is fixed in code to its account and to the destination in §1 rule 5, so no catalog can send an environment key to another connector. A release build of the app never reads these variables. The names differ from the CLIs' own variables on purpose (§6.10). An app debug build launched with `VOXCLIP_NO_KEYCHAIN=1` uses the same environment-variable provider, so ad-hoc signed builds never trigger the Keychain password prompt.
- A key is never shown back. The field placeholder reads "Saved in the Keychain; paste to replace" (macOS) or "Saved for your Windows account; paste to replace" (Windows).

### 8.2 Settings (non-secret)

These keys live in the one settings file of architecture §2 (`<data>/settings.json`, schema `shared/schemas/settings.schema.json`, `voxclip-settings/1`):

| Key | Type | Default |
| --- | --- | --- |
| `llm.connector` | connector id | empty (none chosen) |
| `llm.model.<connectorId>` | model id, per connector | catalog `defaultModel` (Ollama and LM Studio: first listed model) |
| `llm.baseUrl.ollama`, `llm.baseUrl.lmstudio` | URL | catalog `baseUrl` |
| `llm.cliPath.claude-code`, `llm.cliPath.codex` | path | empty (auto-detect) |
| `llm.cloudConsent.<connectorId>` | bool | false |
| `llm.clips.snapToLines` | bool | true |
| `llm.clips.lastPreset` | preset id | `best` |
| `llm.tighten.strength` | `light`, `normal`, `strong` | `normal` |

The model is stored **per connector**, so switching connector never keeps another connector's model id. On launch, a stored model id that appears in the connector's `retiredModels` is replaced by `defaultModel`.

A non-loopback base URL for Ollama or LM Studio is allowed. The Settings row then shows "Transcripts are sent to {host}". The URL must be `http` or `https`.

On macOS, non-loopback Ollama and LM Studio servers require the same first-use request consent as cloud connectors. The consent and Find clips footnote name the receiving host, not an API key. Changing the host clears that connector's consent; changing only its port or path does not. Loopback means `localhost`, `127.0.0.0/8`, or `::1`. An unreadable host never qualifies as loopback.

---

## 9. Model lists

1. **Curated.** The catalog `models[]` is the offline list, in catalog order, plus **Custom…**, which takes a free-text id.
2. **Refresh.** A **Refresh models** button, and an automatic refresh at most once every 7 days when the AI settings pane opens and the connector is ready. Refresh never happens at app launch or in the background otherwise.

| Connector | Source |
| --- | --- |
| Anthropic | `GET /v1/models?limit=100` with the auth headers and `anthropic-version`. Follow `has_more` and `last_id` → `after_id`. Read `data[].id`, `display_name`, `max_input_tokens`, `capabilities`. Keep models whose `capabilities.structured_outputs.supported` is not false |
| OpenAI | `GET /v1/models`. Keep ids starting `gpt-` or matching `^o[0-9]`, excluding ids containing audio, realtime, transcribe, tts, image, search, embedding, moderation or instruct. Sort by `created`, newest first |
| xAI | `GET /v1/models`. Keep ids starting `grok-`, excluding ids containing image, imagine, video, vision, tts or stt |
| Gemini | `GET /v1beta/models?pageSize=1000` with `x-goog-api-key`. Follow `nextPageToken` → `pageToken`. Keep models whose `supportedGenerationMethods` contains `generateContent` and whose id (with `models/` stripped) starts `gemini-` and contains none of embedding, image, tts, audio, live, aqa. Context = `inputTokenLimit` |
| Ollama | `GET /api/tags`, then `POST /api/show` per model for context and capabilities. Keep models with the `completion` capability (or no capabilities field) and without "embed" in the name |
| LM Studio | `GET /v1/models`. Keep ids without "embed" |
| Apple | the single model `system` |
| Claude Code | curated only |
| Codex | app server `model/list` (§6.9) |

3. **Merge.** After a successful refresh, show the curated models that are present in the refreshed list (curated order), then the other discovered models (provider order).
   - Curated models missing from the refresh are hidden. The exception is the currently selected model: it stays, marked "(not listed for this key)".
   - Ollama, LM Studio and Codex show the refreshed list as is.
4. **Cache.** Refreshed lists go to `<data>/Cache/llm-models.json` (architecture §2) as `{connectorId: {fetchedAt, models[]}}`. That file holds no keys. A failed refresh keeps the previous cache, or the curated list, and shows "Couldn't refresh: {message}".

Ollama `suggestedModels` appear only as hints when `noModels` applies: "Try `ollama pull gemma4:12b` (16 GB RAM or more)." Tags must be checked against ollama.com before each release (§14).

---

## 10. Settings UI, the Test button and the headless CLI

### 10.1 AI settings pane

1. **Connector picker**, grouped by catalog `groups`:
   - "Your API key": Anthropic, OpenAI, xAI, Google Gemini.
   - "On this computer": Apple Intelligence (macOS only), Ollama, LM Studio.
   - "Installed CLI (your own sign-in)": Claude Code, Codex.
2. **Model picker.** Shows `"{name} ({tier})"` per model, plus **Custom…**, which reveals a text field. **Refresh models** sits next to it where refresh applies.
3. **Per kind:**
   - API key: a secure field with **Save**, **Test** and **Forget**, the key hint as placeholder, and the footnote "The key stays in the macOS Keychain and is used only for AI features." (Windows: "…encrypted for your Windows account…").
   - Local server: a base URL field, a status line ("Running · 3 models" / "Not running at …"), and **Test**.
   - Apple: an availability line, "Supports: English, German, …" from `supportedLanguages`, and **Test**.
   - CLI: a status line ("Found claude 2.1.309 at ~/.local/bin/claude · Signed in", "Not signed in", "Not found", "Too old"), a **Choose…** path override, a **Sign-in help** sheet (§6.10), and **Test**.
4. **Clip-finder defaults:** a "Snap clip edges to sentence boundaries" toggle (`llm.clips.snapToLines`).

Status lines update on pane open and after **Test**. The catalog `label` is plain text with no icons (§7.1 rule 6).

### 10.2 Test button

**Test** runs the catalog `testRequest` through the normal path (`LLMRunner.run`) with the selected connector and model: `feature = test`, `cachedBlock = null`, `maxOutputTokens = 2048`, `effort = low`, timeout 30 s (CLI: 120 s).

1. For CLI connectors, run detection and the auth check first, and show their result if not ready.
2. Pass when the reply has `ok == true` and `echo`, trimmed and lowercased, equals `voxclip`. Show in green: "Works · {answering model} · {seconds} s". With a fallback: "Works · answered by {fallback}".
3. If the reply validates but doesn't match: orange "The model answered, but not as expected. It may not follow instructions well."
4. On an error: orange "Failed: {user message from §5}".
5. Test never stores the result and never runs automatically.

### 10.3 Clip, tighten and Rewrite UI hooks (owned by the editor spec)

Find Clips (its popover or flyout and the sidebar's Suggested rows) and the tighten review are specified in design.md §6.2 and §6.4. This spec fixes only their AI-specific behaviour, in §11.8 and §12.6.

Rewrite's hooks now live in design.md §6.3: the scope bar, its AI picker, the Rewrite panel, and the inline fixes for a signed-out CLI, a missing key or a stopped local server. The picker writes `llm.connector`, the value the §10.1 pane shows, and runs detection only when it opens (§7.1 rule 5). Rewrite's requests are voice-lab.md §8.1; whether a send starts at once or asks first is voice-lab.md §3.1.

### 10.4 Headless `voxclip-cli`

The command syntax, output object and exit codes follow architecture §9. This spec adds options to the architecture's `find-clips` and one new command:

- `voxclip-cli find-clips --open <project> --preset best|hooks|topics|quotes|custom [--instruction <text>] --connector <id> [--model <id>] [--no-snap] [--dry-run] --json` runs §11 and prints the suggestions. It never modifies the project file. `--dry-run` prints the rendered `system`, `cachedBlock` and `instruction` for each window without sending anything; tests and prompt reviews use it.
- `voxclip-cli llm-test --connector <id> [--model <id>] --json` runs §10.2 and exits 0 on pass. This command is new and must be added to architecture §9.2.
- Keys come from environment variables only (§8.1). Exit codes follow §5.1.

Both platforms follow architecture §9's flattened JSON-object convention, not a
`result` wrapper. Successful `find-clips --json` output contains exactly:

- `ok: true`, `command: "find-clips"`, `version: string`;
- the §11.8 run fields at the top level: `id: string`, `createdAt: string` (UTC
  RFC 3339 with exactly three fractional-second digits), `provider: string`,
  `model: string`, `preset: "best" | "hooks" | "topics" | "quotes" | "custom"`,
  `instructions: string | null`, `language: string | null`,
  `inputSha256: string` (64 lowercase hexadecimal characters), and `clips: array`;
- each clip is `{title: string, reason: string, score: integer, startWordId: string,
  endWordId: string}`. `clips` may be empty; nullable fields are present as JSON null.

With `--dry-run --json`, the complete object is instead `{ok: true,
command: "find-clips", version: string, prompts: array}`. In window order, each
prompt is `{system: string, cachedBlock: string, instruction: string}`; an absent
cached block is the empty string. No run metadata or clips are emitted, no provider
is contacted, and the project is unchanged. Failures use architecture §9's common
`{ok: false, command, error: {code: string, message: string}, version}` object.
Key order and string escaping are not specified and differ between the platforms;
consumers parse the object and compare values, never bytes. `version` is the build's
own version string. Both native CLI suites check `shared/fixtures/cli/find-clips.json`.

---

## 11. Clip finder pipeline (M1)

Constants come from `shared/prompts/clip-finder.json` (`limits`, `presets`, `request`, `generation`).

### 11.1 Inputs and gates

Inputs:
- The source words of the take, in order. A word's index is its position, and source word order and timings never change.
- Each word's display text: the correction if one exists, else the transcribed text.
- Refined source `start` and `end` in seconds.
- The cut set (word ids), used only by §11.7 step 5.
- Preset id, user instructions, connector and model, and the snap setting.

Gates, checked in order:

1. No words: "There are no words to clip." The apps disable Find Clips until the take has words (Windows: a transcript); a take with any words can run it. Neither app reads `limits.minWordsForPanel` (20) from the prompt file.
2. Preset `custom` with empty instructions: "Describe the clips you want."
3. Instructions are trimmed (§11.9 `jsTrim`) and cut to `maxInstructionsLength` (500) UTF-16 code units.
4. A connector must be chosen (`noConnector` otherwise), and its status must be `ready`, otherwise show its message (§5).
5. Consent (§4.8).
6. Apple locale gate (§6.7).

Gates 1 and 2 are feature gates, not connector errors. They show exactly the message above (from `shared/prompts/clip-finder.json`), never an `llm*` message from §5, and are never retried or logged as provider failures. Each platform raises them as a dedicated clip-finder gate error (`noWords`, `needInstructions`) that carries the message.

### 11.2 Clip words

The "words" of this spec are the transcript items of the editing spec, in transcript order. Item `i` becomes `{ index: i, text, start, end }`:

- `index` is the item's position in the transcript. That is the absolute word number the model sees and returns. Resolve it to the item id only when storing results (§11.8).
- `text`:
  - kind `word`: the display text, with any correction applied;
  - kind `event`: the stored label, for example `(laughs)`;
  - kind `unlabeledSpeech`: `…`.

  In every case `text` is cut to `maxWordTextLength` (100) UTF-16 code units, never splitting a surrogate pair.
- **All** items are included, cut ones too, for parity with VoxConvo. Cut items are handled in §11.7 step 5.

### 11.3 Transcript lines (`formatTranscript`, normative port)

Input: a list of entries `{index, text, start, end}`. The clip finder passes every word, so `index` equals the position. AI tighten passes a subset (§12.2).

```text
lines = []; lineStartPos = 0
for pos in 0 ..< entries.count:
    cur  = entries[pos]
    next = entries[pos + 1]   (absent for the last entry)
    gap  = next ? next.start - cur.end : 0               // double subtraction, this order
    sentenceEnd = cur.text matches /[.!?。！？]["'”’)]*$/
    if next is absent or sentenceEnd or gap >= 1.2 or pos - lineStartPos >= 40:
        first = entries[lineStartPos]
        text  = join(" ", entries[lineStartPos ... pos].text)
        line  = "[" + first.index + "-" + cur.index + "] " + formatTime(first.start) + " " + text
        pauseAfter = (next present and gap >= 1.5) ? "(pause " + toFixed1(gap) + "s)" : null
        lines.append({firstPos: lineStartPos, lastPos: pos, firstIndex: first.index, lastIndex: cur.index,
                      start: first.start, end: cur.end, text: line, pauseAfter})
        lineStartPos = pos + 1
rendered = each line's text, followed by its pauseAfter line when present, joined with "\n"
```

Rules the port must follow exactly:

- **Sentence end.** The text's last characters are one of `.` `!` `?` `。` `！` `？`, followed by zero or more of `"` `'` `”` `’` `)`, at the very end of the string. Other closers (for example `」`) do not count.
- **The 40-word rule** counts entry positions, not source indices. A line holds at most 41 entries.
- **`formatTime(s)`** is `floor(s / 60)`, then `:`, then `floor(fmod(s, 60))` zero-padded to 2 digits. Minutes do not wrap at 60: 4523.7 s gives `75:23`. JS `%` on doubles is `fmod` (Swift `truncatingRemainder(dividingBy:)`, C# `%`).
- **`toFixed1(x)`** must reproduce JS `Number.prototype.toFixed(1)` for finite x ≥ 0, which rounds the exact binary value and breaks exact ties upward. `String(format: "%.1f")` (Swift) does not match it. **`toFixed1` is the one shared Core Domain function of `editing.md` §4.4** (exact integer decomposition, no FMA). Both test suites run that one function against the editing fixtures `pauses/label-to-fixed` and the §13.3 vectors.

  Informative only: an FMA formulation (`p = x·10; e = fma(x, 10, −p); n = floor(p); d = (p − n) − 0.5; if d > 0 or (d == 0 and e ≥ 0): n += 1`) gives the same results (it matched Node's `toFixed(1)` on 400,029 values), but it is not used, because editing §4.3 forbids fused multiply-add in Core.

`cachedBlock = transcriptBlock.prefix + rendered + transcriptBlock.suffix`, which is `"<transcript>\n" + rendered + "\n</transcript>"`.

### 11.4 Request text

Single window. This is the exact VoxConvo request:

```text
parts = [ "The recording is " + formatTime(words.last.end) + " long." ]
if preset.instruction != "": parts.append(preset.instruction)
if instructions != "":       parts.append(preset.instruction != "" ? "Also: " + instructions : instructions)
instruction = join("\n", parts)
```

With more than one window, append these lines, also joined with `"\n"`:

```text
"This part of the transcript runs from {formatTime(window.first.start)} to {formatTime(window.last.end)}. Other parts are handled separately."
"Return at most {k} clips."
```

For preset `topics`, windows after the first also get, when the previous windows produced a valid candidate:

```text
"Topics up to word {lastEnd} are already covered. Start at word {lastEnd + 1} or later."
```

`lastEnd` is the largest `endWord` among the valid candidates so far that passed §11.7 steps 1–4.

The duration line always uses the whole take's last word, even in a window.

### 11.5 Windows (chunking over 8000 words and small contexts)

Each Core has one catalog context resolver, used by Find Clips and both Voice Lab rewrite services (§12.8). It applies the order below. A Find Clips CLI dry run uses its catalog-only form: no connector or model-list query, then curated metadata and the same connector-class fallback. Local connector probes run through `contextTokens(model)`; Apple always supplies its runtime context size, never a fixed fallback.

```text
maxWords      = limits.maxWordsPerRequest (8000)
context       = connector.contextTokens(model) ?? selected model metadata ?? curated catalog contextTokens ?? default
                (cloud API and CLI 128000; Ollama from /api/show, else 4096; LM Studio §6.6, else 4096; Apple runtime)
outputReserve = min(generation.maxOutputTokens, connector.maxOutputTokensCap ?? generation.maxOutputTokens)
                Ollama and LM Studio only: outputReserve = min(outputReserve, max(1024, floor(context / 4)))
overhead      = est(system) + est(instruction rendered with the longest window lines, k = 99) + est(compact schema) + 64
budget        = floor((context - overhead - outputReserve) * 0.9)
if budget < 600: contextTooLong
```

`est(s) = ceil(utf8ByteCount(s) / 2.2)`. This is conservative: it measured within a few percent of Apple's tokenizer for Estonian and about 30% high for English.

Each window's request sends `maxOutputTokens = outputReserve`, so Ollama's `num_predict` and `needed` (§6.5) and LM Studio's `max_tokens` use the same reserve the budget assumed. The local-server clamp exists because both servers fall back to a 4096-token context and a 4096-token output cap; without it the budget would be negative and every run on such a model would fail with `contextTooLong`.

**Packing.**
- Take lines in order. A line costs `est(line.text + "\n")`, plus `est(pauseAfter + "\n")` when it has a pause line.
- A window takes lines while its total cost is ≤ `budget` and its word count is ≤ `maxWords`. It always takes at least one line.
- If every line fits in one window, there is one window. That is the parity path and adds no window lines.

**Overlap.**
- `overlap = min(preset.maxSeconds, limits.windowOverlapMaxSeconds)`. That is 60 for best, 30 for hooks, 90 for topics, 15 for quotes and 90 for custom.
- The next window starts at the first line whose `start ≥ previousWindowLastLine.end − overlap`.
- It must start after the previous window's first line. If the rule would not move forward, start at the previous first line + 1.
- Stop after the window that contains the last line.

**Per window.**
- Each window renders its own lines. Labels and times are absolute: unchanged from the full transcript.
- `k = max(limits.windowMinClips, ceil(preset.maxClips × limits.windowClipFactor / windowCount))`, which is `max(2, ceil(maxClips × 1.5 / n))`.
- Apple on macOS 26.4 and later: confirm with `tokenCount(system) + tokenCount(cachedBlock + "\n\n" + instruction) + est(compact schema) + outputReserve ≤ contextSize`. While that fails, drop the window's trailing line and recount. The dropped lines go to the next window.

**Execution.**
- Windows run in order. Progress reads "Finding clips… part i of n".
- A failed window aborts the run with its error, and no partial results are shown.
- Cancel aborts the run.

### 11.6 Parsing

Each window's `LLMResult.object.clips` items are appended to one candidate list in arrival order (window order, then model order). Each candidate keeps `{title, start_word, end_word, reason, score}` as received.

### 11.7 `finalizeClips` (normative; VoxConvo plus marked VoxClip extensions)

Inputs: `candidates`, `words` (all words), `preset`, `lines` (from the full transcript, §11.3), `cutSet`, `windowCount`, `snap` (bool).

1. **Valid indices.** `start_word` and `end_word` must be finite, integral numbers (`x == floor(x)`), with `0 ≤ start_word ≤ end_word ≤ words.count − 1`. Drop the others.
2. **Normalise.**
   - `title = jsTrim(title)` cut to `titleMaxLength` (120) UTF-16 code units.
   - `reason = jsTrim(reason)` cut to `reasonMaxLength` (300).
   - `score = min(10, max(1, jsRound(score)))`, where `jsRound(x) = floor(x) + ((x − floor(x)) ≥ 0.5 ? 1 : 0)`. Drop a non-finite score.
   - If a cut would split a surrogate pair, drop the unpaired high surrogate.
3. **Snap** *(VoxClip extension; only when `snap` is true)*.
   - Line starts `S = {line.firstIndex}` and line ends `E = {line.lastIndex}`.
   - `start' =` the element of `S` closest to `start` within `snapRadiusWords` (3). On a tie, take the smaller.
   - `end' =` the element of `E` closest to `end` within 3. On a tie, take the larger.
   - When none is within range, the value is unchanged. If `start' > end'`, keep the original pair.
4. **Length.** `L = words[end].end − words[start].start`. Keep the clip if `L ≥ max(2, preset.minSeconds × 0.6)` and `L ≤ preset.maxSeconds × 1.4`, computed as written in doubles.
5. **Mostly cut** *(VoxClip extension)*. Drop the clip if `count(i in start…end where word i is in cutSet) / (end − start + 1) > mostlyCutFraction` (0.5).
6. **Rank.** Sort by `score` descending, then arrival order ascending. Sort with this explicit key. Don't rely on library sort stability: C# `List.Sort` is unstable.
7. **Select.** Go through the ranked list and stop when `preset.maxClips` clips are chosen. Skip a clip when:
   - it has the same `(start, end)` as a chosen clip;
   - *(VoxClip extension, only when `windowCount > 1`)* `overlapRatio ≥ nearDuplicateOverlap` (0.6) with a chosen clip, where `overlapRatio = max(0, min(e1, e2) − max(s1, s2) + 1) / (max(e1, e2) − min(s1, s2) + 1)`;
   - `preset.noOverlap` is true and `[start, end]` intersects a chosen clip, inclusive (`s ≤ e2 && s2 ≤ e`).
8. **Order.** Sort the chosen clips by `start` ascending, then selection order.

With `snap = false`, an empty cut set and one window, the output equals VoxConvo's `finalizeClips` exactly (§13.4).

Accepted lengths per preset, from step 4:

| Preset | Label | Asked length | Accepted (s) | maxClips | noOverlap |
| --- | --- | --- | --- | --- | --- |
| best | Best moments | 20–60 | 12–84 | 5 | no |
| hooks | Hooks | 15–30 | 9–42 | 5 | no |
| topics | One per topic | 20–180 | 12–252 | 12 | yes |
| quotes | Quotes | 5–15 | 3–21 | 6 | no |
| custom | Custom | 3–180 | 2–252 | 10 | no |

### 11.8 Output and clip contract

A successful run produces one `aiResult`, which is appended to the project's `ai.results` (editing spec, `shared/schemas/project.schema.json`). Reopening the project shows it without a new call.

```text
aiResult {
  id: new id
  createdAt: now
  provider: connector id
  model: LLMResult.model of the last window; the fallback model if one answered
  preset: preset id
  instructions: trimmed instructions, or null when empty
  language: request.language
  inputSha256: lowercase hex SHA-256 (UTF-8) of the single-window cachedBlock for the whole take,
               even when the run used several windows
  clips: [ { title, reason, score, startWordId: words[startWord].id, endWordId: words[endWord].id } ]   // in §11.7 order
}
```

The schema requires a non-empty `title`. If `title` is empty after §11.7 step 2, use the clip's own text (its words joined by spaces), cut to 120 UTF-16 code units at the last space. This step runs after `finalizeClips`, so parity is unaffected.

- **Source range for preview and export.** These are the editing spec's `clipTimes`, repeated here for completeness:
  - `start = max(0, first.start − min(0.12, prev ? max(0, first.start − prev.end) / 2 : 0.12))`
  - `end = last.end + min(0.25, next ? max(0, next.start − last.end) / 2 : 0.25)`
- **Clip lifecycle.** On a successful run, VoxClip appends the `aiResult`, then, as one undo step named "Find clips", appends a `ClipRange { origin: ai, aiResultId, aiClipIndex, title, selected: true }` for each result clip in §11.7 order, skipping a clip whose `(startWordId, endWordId)` equals an existing `ClipRange` (editing spec §6.3 `addAIClips`, §10.6), and then applies `setClipSelected(id, false)` to each clip it added. The new clips are suggestions (design.md §2): **Keep** sets `selected` to true, **Keep All** keeps every suggestion in one undo step, and **Dismiss** removes the `ClipRange`.
  - The sidebar lists every `ClipRange`: kept clips (manual, or AI with `selected == true`), then suggestions, each sorted by start word, then creation order. Score and reason come from the linked `aiResult`.
  - "All {n} clips" in the Export sheet exports the kept clips. Remove and Dismiss delete only the `ClipRange`.
  - A new run never removes existing clips. `ai.results` keeps the newest 10 runs; older results that no `ClipRange` references are dropped on save.
  - It never rewrites cut flags. Cuts and corrections inside the clip keep the user's edits.
- **Sidebar behaviour** (design.md §6.2):
  - Every returned clip arrives as a suggestion under **Suggested**.
  - A suggestion row shows its number, title and duration. Its tooltip and accessible description are `{score}/10 · {reason}`.
  - Clip edges change with the timeline's trim handles and with I / O (`updateClip`), which always keep at least one word.
  - With no results: "No clips matched. Try another style or describe what you want." under Suggested, with **Find Clips…**.
  - After a run answered by the fallback model, macOS shows the fallback note (§4.3) under Suggested; Windows does not show it yet. A run without a fallback shows no model line.
  - When `droppedItems > 0` or candidates were filtered, nothing extra is shown. Filtering is normal.

### 11.9 String helpers (both platforms)

- **`jsTrim`** removes leading and trailing characters from this set: U+0009–U+000D, U+0020, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF. That is JavaScript's `String.prototype.trim`. Swift's `.whitespacesAndNewlines` and C#'s `Trim()` differ on U+FEFF, so use the explicit set.
- **Lengths** are in UTF-16 code units (`utf16.count` in Swift, `Length` in C#).

---

## 12. AI tighten (M2)

### 12.1 Contract

- **What the model may do.** The LLM proposes deletions only.
- **What VoxClip verifies.** Before showing any proposal, VoxClip proves it is a **pure cut**: it removes only existing, uncut, in-scope words and changes nothing else.
- **Applying.** Applying adds word ids to the cut set as one undo step.
- **What it never does.** AI tighten never changes word text, timings, corrections or pauses, never restores cut words, and never creates synthetic audio. That is why it needs no AI-disclosure label.
- **Pauses.** Pause tightening stays the editor's separate, deterministic operation.

### 12.2 Input

- **Scope.** The clip range being edited, if any, else the whole take.
- **Entries.** In-scope transcript items of kind `word` or `event` that are **not cut**, in transcript order, with corrections applied, and with their absolute item positions as `index` (§11.2). Items of kind `unlabeledSpeech` are left out, because "Cut fillers" already handles them.
- **Lines.** `formatTranscript(entries)` (§11.3) produces them. A label `[a-b]` names the first and last entry of the line. Source indices inside it may be missing because those words are already cut; the system prompt says so.

### 12.3 Windows

The same budget computation as §11.5, with `maxWordsPerRequest = 2000` and **no overlap**: the next window starts at the line after the previous window's last line. Windows run one after another.

### 12.4 Request

- `system = ai-tighten.system`.
- `cachedBlock` is built as in §11.3.
- `instruction` joins with `"\n"`:
  1. the chosen strength's `instruction` (`light`, `normal` or `strong`; default from `llm.tighten.strength`);
  2. `"Also: " + text`, if the user typed text (trimmed, at most 200 UTF-16 units);
  3. `windowLine`, when there is more than one window.
- Schema `tighten_edits`, `maxOutputTokens` 16000, effort `xhigh` (§4.4.1).

### 12.5 Verification (normative)

Process the edits in arrival order:

1. **Line.** `edit.line`, trimmed, must equal the text before the first space of an emitted line label, for example `[40-49]`. An unknown label means reject `unknownLine`. A second edit for the same line means reject `duplicate`.
2. **Kind** must be one of the schema enum values. Otherwise reject `badKind`.
3. **Line tokens.** Split each entry's text on Unicode whitespace and normalise each part:
   1. NFC;
   2. lowercase with full Unicode mapping, invariant culture;
   3. repeatedly strip leading and trailing characters found in `normalization.stripEdgeCharacters`.

   Parts that become empty are dropped. Each remaining part is a token tagged with its entry. An entry with no tokens is *punctuation-only*.
4. **Keep tokens.** Split `edit.keep` on Unicode whitespace, normalise the same way, and drop empty parts.
5. **Right-to-left alignment.**
   - Start `j` at the last line token. For each keep token from last to first, move `j` left until `lineToken[j]` equals it.
   - If none is found, reject `notSubsequence`. Otherwise mark `j` as matched and set `j = j − 1`.
   - Matching from the right keeps the *later* copy of a doubled word ("we we went" keeps the second "we"), which is the restarted, clean version.
6. **Entry fate.**
   - An entry with tokens is kept if all its tokens matched and cut if none matched.
   - If only some matched (a corrected word that contains a space), reject `splitWord`.
   - A punctuation-only entry takes the fate of the nearest preceding entry with tokens in the line, or of the following one if none precedes it.
7. **No-op.** If no entry is cut, ignore the edit.
8. **Review flag.** `review = (keep non-empty and cutCount > reviewCutFraction × entryCount)` or `(keep empty and entryCount > wholeLinePreselectMaxWords)`. Proposals with `review` are shown but not pre-selected.

Output: `proposals[] = {lineLabel, kind, cutWordIds, preselected = !review}`, plus `rejectedCount`.

### 12.6 Review and apply

- **Display.** Proposed cuts show as amber strikes in the transcript with a kind chip (labels from `kinds`).
- **Controls.** Accept and reject per proposal, plus **Accept all** and **Reject all**.
- **Header.** "{n} edits · {w} words · {s} s shorter". `{s}` comes from the editing spec's edit plan with the accepted cuts.
- **Warnings.**
  - If accepted proposals would cut more than `warnTotalCutFraction` (40%) of the in-scope uncut words, show `messages.warnLarge`.
  - If `rejectedCount > 0`, show `messages.rejectedSome`.
- **Apply.** `cutWordIds ∪= accepted ids` in one undoable step. Nothing else changes.

### 12.7 Guarantees (each is a test)

- No proposal cuts a word outside the scope, an already-cut word, or a word missing from the reply's line.
- Applying never changes text, timings, corrections, pauses or the clip range.
- Rejected edits never change state.
- Running tighten again right after applying proposes no cuts of words already cut, because they are not in the input.

### 12.8 Voice Lab rewrite is separate

Voice Lab can rewrite a passage or an entire selected take with the chosen connector and model. Its `voice_rewrite_proposal` schema contains spoken `rewrite` text, and both native Core consumers are `VoiceRewriteService`. It never reuses `tighten_edits`, so a tighten reply can never carry an insertion. `prepare` makes an instance-scoped, single-use quote without a provider call; it binds the scope, all source word values and timings, instruction, language, connector, model, prompt/schema identity and estimate. An affirmative authorization for that exact quote is required before the connector send. The quote is consumed before dispatch, even if the response later fails or the call is cancelled after sending. A new attempt requires a new quote and approval. The result retains the original timed words and has no effect until the user reviews it. Another affirmative authorization is needed to send approved text to ElevenLabs for synthesis. The connector's reply cannot select a provider, model, endpoint or URL. Before dispatch, both services check current connector readiness, selected-model availability, output capacity and context. They use connector, selected-model and curated context metadata in that order, with the context resolution rule of §11.5. A failed nonbillable preflight leaves approval usable; only the atomic claim immediately before the one send consumes it. Fix with AI (`doc/spec/voice-lab.md` §8.1, path 3) follows the same rules with its own `patch_edits` schema, and both native Core consumers are `PatchRewriteService`. `doc/spec/voice-lab.md` §2.6 and `shared/fixtures/voice-lab/contract.json` describe the shared Core contract and pending media/UI integration.

There is no automatic model fallback: for both sends the Claude CLI gets no `--fallback-model`, and the Anthropic API gets neither `fallbacks` nor the beta header, so nothing is re-sent without them (§4.3, §6.1, §6.8). The reply must come from the quoted model:

| Connector | Selected id | Accepted answering ids |
| --- | --- | --- |
| Claude Code | `sonnet`, `opus` or `haiku` | the alias, or any id that starts with `claude-<alias>-` (for `sonnet`, for example, `claude-sonnet-5-5`) |
| Claude Code | `default` | `default`, or any id that starts with `claude-` |
| Claude Code | any other | the selected id |
| Anthropic, OpenAI, xAI, Gemini, Ollama, LM Studio | any | the selected id, or the selected id followed by a hyphen and a dated snapshot, `YYYY-MM-DD` or `YYYYMMDD` |
| Apple Foundation Models, Codex | any | the selected id |

A dated snapshot is ASCII digits naming a Gregorian date: `MM` from 01 to 12 and `DD` from 01 to the month's length, with 29 February only in a year divisible by 4 and not by 100, or divisible by 400. So `gpt-6.1-sol-2026-10-01` and `gpt-6.1-sol-20261001` answer for `gpt-6.1-sol`, but `gpt-6.1-sol-mini`, `gpt-6.1-sol-2026-02-29`, `gpt-6.1-sol20261001` and `gpt-6.1` do not. Ids compare ordinally, as UTF-8 bytes, never by case or canonical equivalence. A reply from another model fails with `invalidOutput`. Only then does the stop count: a truncated reply fails with `truncated`, and a refusal with `refused`, whose copy for both sends is "The model declined to rewrite this recording." The proposal records the model that answered. For Claude Code, choose the `modelUsage` key with the most output tokens (`outputTokens`, else `output_tokens`, else zero); ties choose the smallest key in ordinal UTF-8 byte order, never JSON order.

**Preflight.** Both sends make the same checks on both platforms:

- **Model id.** `prepare` refuses a model id that is not 1 to 256 UTF-8 bytes, or that holds a control character (Cc), as invalid input.
- **Output cap.** `maxOutputTokens = min(promptCap, connectorCap, max(512, ⌈1.5 × sourceTokens⌉))`. `promptCap` is the prompt's `maxOutputTokens`, `connectorCap` the catalog's `maxOutputTokensCap` when the connector has one, and `sourceTokens` is `est()` (§11.5) of the source: the joined source words for a rewrite, the rendered transcript lines for Fix with AI. When `maxOutputTokens < sourceTokens` the answer cannot fit, and `prepare` fails with `contextTooLong`, as does the check before the send.
- **Context.** `required = est(system + cachedBlock + instruction + compact schema) + maxOutputTokens + 64`, one `est()` of the joined text. The context follows the single catalog resolution rule of §11.5, including its connector-class fallbacks. The send fits when `context ≥ 512` and `required ≤ ⌊context × contextSafetyFactor⌋`, the product taken in binary64. Otherwise it fails with `contextTooLong` before the send, and the approval stays usable.

`shared/fixtures/voice-lab/rewrite-checks-cases.json` holds the rows just below, at and just above each bound, the answering ids included. Each case in `shared/fixtures/llm/voice-rewrite-requests.json` and `patch-rewrite-requests.json` gives its `required` tokens and the smallest context that fits them.

---

## 13. Acceptance tests

Both test suites (Swift `VoxClipCoreTests`, C# `VoxClip.Core.Tests`) must pass every vector below. The JSON vectors were produced by running a literal JavaScript copy of VoxConvo's `formatTranscript` and `finalizeClips` under Node 22.21.0.

### 13.1 Shared-resource parity

See `shared/prompts/README.md`: rendered-request parity against `shared/fixtures/llm/clip-finder-requests.json`, bundle parity, the schema-subset check (§2.2), and the no-prompt-in-code rule. `tools/fixtures/llm` (Node, no dependencies, VoxClip's own MIT implementation of §11.3–§11.7 written from this spec) generates `shared/fixtures/llm/{format-transcript,to-fixed,finalize-clips,extensions,clip-finder-requests}.json` and self-checks against the §13.2–§13.6 vectors, so the parity fixture has a producer independent of either app.

### 13.2 `formatTranscript` vector F1

Input words, as `[text, start, end]`, indices 0–66:

```json
[["So,",0,0.3],["today",0.35,0.7],["I",0.75,0.85],["want",0.85,1.1],["to",1.1,1.2],["talk.",1.2,1.6],["Um",3.85,4.1],["why",4.2,4.45],["cut",4.5,4.8],["by",4.85,5],["words?",5,5.4],["\"It",5.5,5.7],["works.\"",5.7,6.2],["Fast",7.45,7.8],["and",7.85,8],["clean",8.05,8.5],["Tere!",70,70.4],["Mis",70.5,70.7],["toimub?",70.75,71.2],["「本当",71.3,71.6],["です。」",71.6,72],["w21",72.1,72.35],["w22",72.4,72.65],["w23",72.7,72.95],["w24",73,73.25],["w25",73.3,73.55],["w26",73.6,73.85],["w27",73.9,74.15],["w28",74.2,74.45],["w29",74.5,74.75],["w30",74.8,75.05],["w31",75.1,75.35],["w32",75.4,75.65],["w33",75.7,75.95],["w34",76,76.25],["w35",76.3,76.55],["w36",76.6,76.85],["w37",76.9,77.15],["w38",77.2,77.45],["w39",77.5,77.75],["w40",77.8,78.05],["w41",78.1,78.35],["w42",78.4,78.65],["w43",78.7,78.95],["w44",79,79.25],["w45",79.3,79.55],["w46",79.6,79.85],["w47",79.9,80.15],["w48",80.2,80.45],["w49",80.5,80.75],["w50",80.8,81.05],["w51",81.1,81.35],["w52",81.4,81.65],["w53",81.7,81.95],["w54",82,82.25],["w55",82.3,82.55],["w56",82.6,82.85],["w57",82.9,83.15],["w58",83.2,83.45],["w59",83.5,83.75],["w60",83.8,84.05],["w61",84.1,84.35],["w62",84.4,84.65],["w63",84.7,84.95],["w64",85,85.25],["w65",85.3,85.55],["end.",200,200.5]]
```

Expected `rendered` (12 lines, joined with `\n`):

```text
[0-5] 0:00 So, today I want to talk.
(pause 2.3s)
[6-10] 0:03 Um why cut by words?
[11-12] 0:05 "It works."
[13-15] 0:07 Fast and clean
(pause 61.5s)
[16-16] 1:10 Tere!
[17-18] 1:10 Mis toimub?
[19-59] 1:11 「本当 です。」 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 w31 w32 w33 w34 w35 w36 w37 w38 w39 w40 w41 w42 w43 w44 w45 w46 w47 w48 w49 w50 w51 w52 w53 w54 w55 w56 w57 w58 w59
[60-65] 1:23 w60 w61 w62 w63 w64 w65
(pause 114.5s)
[66-66] 3:20 end.
```

What it covers: the 2.25 s gap rounds up to `2.3`; `works."` is a sentence end with a closing quote; `です。」` is not (`」` is not a closer); line `[19-59]` has 41 words (the 40-word rule); minutes past one; and gap-based breaks.

Single-window request for F1 with preset `best` and no instructions:

```text
The recording is 3:20 long.
Find the 3 to 5 strongest moments. Each clip should be 20 to 60 seconds long.
```

With preset `custom` and instructions `"  Funny bits  "`, the instruction is `The recording is 3:20 long.\nFunny bits`.

### 13.3 `toFixed1` and `formatTime`

| x | `toFixed1(x)` |
| --- | --- |
| 0.05 | 0.1 |
| 0.15 | 0.1 |
| 0.25 | 0.3 |
| 0.35 | 0.3 |
| 0.45 | 0.5 |
| 1.25 | 1.3 |
| 1.45 | 1.4 |
| 2.05 | 2.0 |
| 2.25 | 2.3 |
| 9.95 | 9.9 |
| 99.95 | 100.0 |
| 1.2499999999999998 | 1.2 |
| 1.2500000000000002 | 1.3 |

A randomized test also compares 100,000 values against a stored list produced by Node.

`formatTime`: 0 → `0:00`; 5.9 → `0:05`; 70 → `1:10`; 200 → `3:20`; 4523.7 → `75:23`.

### 13.4 `finalizeClips` parity vectors

These use `snap = false`, no cuts and one window. The words are `U100`: 100 words with word `i` = `{text: "w{i}", start: i, end: i + 0.8}`.

**C1, preset `best`.** Candidates in arrival order. `<T×130>` means 130 letters `T`; `<R×310>` means 310 letters `R`.

```json
[{"title":"  Strong opener  ","start_word":0,"end_word":20,"reason":" r1 ","score":8.6},
 {"title":"Best","start_word":10,"end_word":30,"reason":"r2","score":9},
 {"title":"Duplicate of best","start_word":10,"end_word":30,"reason":"r3","score":7},
 {"title":"Too short","start_word":50,"end_word":55,"reason":"r4","score":10},
 {"title":"Out of range","start_word":40,"end_word":130,"reason":"r5","score":10},
 {"title":"Reversed","start_word":60,"end_word":59,"reason":"r6","score":10},
 {"title":"Clamped score","start_word":60,"end_word":99,"reason":"r7","score":12},
 {"title":"Fractional index","start_word":5.5,"end_word":30,"reason":"r8","score":10},
 {"title":"<T×130>","start_word":20,"end_word":45,"reason":"<R×310>","score":6},
 {"title":"Low score","start_word":70,"end_word":90,"reason":"r10","score":-3.5},
 {"title":"Too long","start_word":0,"end_word":99,"reason":"r11","score":9},
 {"title":"Tie A","start_word":30,"end_word":50,"reason":"r12","score":6}]
```

Expected:

```json
[{"title":"Strong opener","reason":"r1","score":9,"startWord":0,"endWord":20},
 {"title":"Best","reason":"r2","score":9,"startWord":10,"endWord":30},
 {"title":"<T×120>","reason":"<R×300>","score":6,"startWord":20,"endWord":45},
 {"title":"Tie A","reason":"r12","score":6,"startWord":30,"endWord":50},
 {"title":"Clamped score","reason":"r7","score":10,"startWord":60,"endWord":99}]
```

`Low score` (score −3.5 → 1) is valid but sixth by rank, so `maxClips` excludes it.

**C2, preset `topics`** (noOverlap):

```json
[{"title":"A","start_word":0,"end_word":30,"reason":"a","score":7},
 {"title":"B overlaps A","start_word":30,"end_word":60,"reason":"b","score":8},
 {"title":"C","start_word":61,"end_word":99,"reason":"c","score":6},
 {"title":"D inside C","start_word":70,"end_word":90,"reason":"d","score":9},
 {"title":"E","start_word":0,"end_word":20,"reason":"e","score":5}]
```

Expected:

```json
[{"title":"E","reason":"e","score":5,"startWord":0,"endWord":20},
 {"title":"B overlaps A","reason":"b","score":8,"startWord":30,"endWord":60},
 {"title":"D inside C","reason":"d","score":9,"startWord":70,"endWord":90}]
```

**C3, preset `quotes`** (score ties and the `maxClips` cut). Candidates `Q0`–`Q7`: `Qi = {title: "Qi", start_word: 12i, end_word: 12i + 5, reason: "q", score: i even ? 7 : 8}`. Expected, by `startWord`: `Q0, Q1, Q2, Q3, Q5, Q7`, with scores 7, 8, 7, 8, 8, 8.

### 13.5 VoxClip extension vectors

**S1, snapping on F1's lines.** Starts `{0,6,11,13,16,17,19,60,66}`, ends `{5,10,12,15,16,18,59,65,66}`. Input → output:

| Input | Output | Why |
| --- | --- | --- |
| (7,14) | (6,15) | |
| (2,9) | (0,10) | |
| (12,14) | (11,15) | start tie, earlier wins |
| (30,40) | (30,40) | none within 3 |
| (17,17) | (17,18) | end tie, later wins |
| (15,15) | (15,15) | snapped start 16 > end 15, so the original is kept |

**M1, mostly cut.** U100, `best`, cut set = words 0–10. Candidate (0,20) is dropped (11/21 > 0.5). Candidate (30,50) with words 30–39 cut is kept (10/21).

**N1, near duplicates.** U100, `best`. Candidates A (10,30) score 8, B (12,32) score 8, C (40,60) score 7.
- With `windowCount = 2`: A and C (A/B overlap ratio 19/23 ≥ 0.6).
- With `windowCount = 1`: A, B and C.

**W1, windows.** 20,000 synthetic words, connector context 128,000, preset `best`. Word `i` has `start = 0.3i`, `end = 0.3i + 0.25`, and text `w{i}`, with a `.` appended when `i mod 15 = 14`. Expected:
- 3 windows, covering words 0–7994, 7800–15794 and 15600–19999 (7995, 7995 and 4400 words). The word limit binds, not the token budget.
- Every window after the first starts at the first line whose start ≥ (previous window's last line end − 60 s).
- Labels in every window equal the full transcript's labels.
- `k = max(2, ceil(5 × 1.5 / 3)) = 3`.

With `context = 8192` and `maxOutputTokensCap = 1500` (Apple), every window's estimated cost is ≤ its budget.

With `context = 4096` and `maxOutputTokensCap = 4096` on a local server (Ollama or LM Studio fallback, vector `W1-local`), `outputReserve = 1024`, the budget is positive and every window's estimated cost is ≤ its budget.

### 13.6 AI tighten verifier vectors (M2)

Line `[40-49]` holds entries 40 `So,` 41 `um,` 42 `we` 43 `we` 44 `went` 45 `to` 46 `the` 47 `uh` 48 `the` 49 `store.`

| Case | Edit | Expected |
| --- | --- | --- |
| T1 | keep `So, we went to the store.` | cut 41, 42, 46, 47; preselected |
| T2 | keep `So we went to the shop.` | reject `notSubsequence` |
| T3 | keep `""` | cut 40–49; preselected (10 ≤ 12 entries) |
| T4 | keep `store` | cut 40–48; `review` (9 > 0.6 × 10) |
| T5 | line `[99-120]` | reject `unknownLine` |
| T8 | keep `so WE went to the store` | same as T1 (case and punctuation ignored) |

More vectors:
- **T6.** Line `[50-51]`: 50 `going to` (a correction with a space), 51 `win.`. Keep `going win` → reject `splitWord`.
- **T7.** Line `[60-63]`: 60 `Well`, 61 `—`, 62 `um`, 63 `yes.`. Keep `Well yes.` → cut 62 only (`—` follows entry 60, which is kept).

### 13.7 Connector fixtures

For each HTTP connector, a fixed `LLMRequest` (the F1 transcript, preset `best`, its default model) serialises to the body in §6.1–§6.6. Compare as parsed JSON. Response fixtures cover:

- **Anthropic:** success, `stop_reason: refusal` with `stop_details.category`, `max_tokens`, 529 three times (the fallback model is called next), 402, and the beta-header 400 (re-sent without the header).
- **OpenAI:** success, `incomplete` with `max_output_tokens`, `refusal` content, 429 `insufficient_quota` (not retried).
- **Gemini:** success with a `thought` part, `MAX_TOKENS`, `SAFETY`, 400 `API_KEY_INVALID`, 503 (fallback), `RetryInfo` of 45 s (no retry, `rateLimited`). The test also asserts that no request URL contains `key=`.
- **Ollama:** a `num_ctx` computation, and `done_reason: length`.
- **Apple:** the logical schema uses the unique full-path names in §6.7, including array items, nested objects and string enums; primitive scalar schemas have no names.
- **Claude Code:** the verified success and signed-out envelopes from §6.8.
- **Codex:** the verified success JSONL and the 401 failure sequence from §6.9.

### 13.8 Runtime tests with stubs

- **Retry timing** uses an injected clock: delays are 1 s and 2 s; `retry-after: 3` waits 3 s; `retry-after: 40` stops at once.
- **Timeouts and cancel.** A timeout is not retried. Cancel during the backoff throws `cancelled` and makes no further request.
- **Redaction.** A transport error whose description holds `https://…?key=AIzaSy…` logs with the value as `[REDACTED]` (architecture §11.2). A stored key value is redacted wherever it appears.
- **Fake CLIs.** Scripts (sh and PowerShell) record their argv, cwd and environment and print recorded envelopes. The tests assert:
  - the exact argv;
  - no forbidden flags;
  - no forbidden environment variables;
  - an empty cwd that is deleted afterwards;
  - the process tree is killed on timeout and cancel;
  - `codex exec` is never started when `codex login status` exits 1.
- **Apple locale gate.** `language = "et"` raises `unsupportedLanguage` without creating a session.

### 13.9 Manual release checks (not in CI; they need keys and sign-ins)

**Release evidence (2026-10-30): pending.** Results for these checks and §14 items 1–7 and 9 are not recorded. The lead must record results or scoped waivers before publishing (release.md §4 step 3c). Item 8 retains its explicit non-gating status.

- **Test** passes for each API connector with a real key and for each CLI when signed in.
- Each CLI shows "Not signed in" correctly when signed out.
- Find clips on the bundled fixture take returns suggestions on Anthropic, OpenAI, Gemini, one local model and both CLIs.
- An Estonian project shows the Apple locale message.

---

## 14. Open verification items

Each item needs a check before 0.1.0. The owner records the result in this file.

1. **LM Studio context endpoint.** `GET /api/v0/models/{id}` and the `loaded_context_length` / `max_context_length` fields are taken from the research and have not been run (LM Studio on this machine had no models).
2. **Gemini `responseJsonSchema`** with the exact `clips` and `tighten_edits` schemas, on `gemini-3.8-flash`. The field name comes from the 2026 docs; the docs page fetched on 2026-10-25 showed only the newer Interactions API.
3. **xAI strict `json_schema`** on `grok-4.5`, and the exact status and body for an invalid key.
4. **OpenAI Responses `prompt_cache_key`** is accepted together with `store: false` on the curated models.
5. **CLI locations and standalone Codex.** Re-verify §6.9 against a standalone Codex release (Homebrew or npm `@openai/codex`) on macOS and update the catalog `verified` entry; the only verified copy so far is the one bundled inside ChatGPT.app, which VoxClip does not use. On the UTM VM check the Claude Code native installer path (`%USERPROFILE%\.local\bin\claude.exe`), Codex install paths and the npm shim scripts, and that the `node.exe <script>` launch works for both.
6. **Claude Code on Windows** prints the same result envelope. **Codex on Windows** accepts `--sandbox read-only` and the feature names in `disableFeatures`.
7. **Ollama tags** in `suggestedModels` exist on ollama.com, and each returns valid `clips` JSON on the F1 transcript.
8. **Policy reading for the subscription connectors** (§7.2). The lead asks Anthropic and OpenAI to confirm in writing that a local app invoking the user's own signed-in CLI, under rules 1–9, is acceptable, and records the answer (date, sender, quote) here. This is not a release gate: on 2026-10-25 the lead decided to ship both connectors enabled in 0.1.0 without waiting for the answers (ADR-R20). If a vendor objects, the next release sets that connector's `enabled` to `false` (release.md §4 step 3a).
9. **Codex usage overhead.** Each call carries about 12k tokens of Codex base instructions (§6.9). Decide whether the UI should mention this.

---

## 15. Provenance

- **VoxConvo `vox-api/src/services/clipService.ts`** (read 2026-10-25): `CLIP_PRESETS` (lines 22–28), `SYSTEM_PROMPT` (33–45), `ClipsSchema` (47–55), `formatTranscript` (88–103), `finalizeClips` (106–130) and the Anthropic call (151–170: `max_tokens` 16000, `output_config.effort` medium, `fallbacks: "default"`, transcript block first with `cache_control`). `vox-web/src/utils/clips.ts:32-40` is the source of `clipTimes`.
- **Superscribe** `apps/macos/Sources/Services/CleanupService.swift` and `apps/windows/Services/CleanupService.cs`:
  - provider wire formats and the curated October 2026 model lists with the fast/balanced/best tiers;
  - the 3-attempt retry with 1 s and 2 s backoff, and the 429/529 fallback model;
  - the Test button round trip and the retired-model migration;
  - `SecretStore` for the Keychain and DPAPI.
- **Project measurements** from the 2026-10-25 research (the working notes are not in the repository): Apple Foundation Models (8192-token context, 24 locales, no Estonian, 2.28 and 3.50 tokens per word); Ollama `/api/chat` and `num_ctx`; LM Studio; the window algorithm and the provider abstraction.
- **Anthropic API facts** come from the bundled Claude API reference (cached 2026-10-06):
  - the `anthropic-version` value `2026-10-21` rejects sampling parameters on every model;
  - Opus 5.5 rejects `thinking: disabled` and forced `tool_choice`;
  - `output_config.format` and `output_config.effort`;
  - the 512-token cache minimum on the 5.x models;
  - the server-side fallback beta `server-side-fallback-2026-07-01` with `fallbacks: "default"` (not on Haiku 5.5);
  - the Models API fields;
  - error types.
- **OpenAI** structured outputs (`developers.openai.com/api/docs/guides/structured-outputs`), **Gemini** `generateContent` reference (finish reasons, `Part.thought`, block reasons), and the **SIWC** pages, all fetched 2026-10-25.
- **CLI behaviour** was measured on this machine on 2026-10-25: `claude --help`, `claude auth --help`, `codex --help`, `codex exec --help`, `codex app-server --help`, `codex login status`, `codex features list`, app-server `initialize`, `account/read`, `model/list` and `config/read`; one live structured-output call per CLI; and signed-out probes with empty config directories. No credential file was read.

## 16. Make it postable planner

User decision (2026-11-04): "too many click to actually use it. claude code should make the best decisions. in extra high effort level." The approved mockup "One-click postable clips" has one **✦ Make it postable · ≈ $x** action per clip. Claude decides everything, one review lists every decision with Undo or Change, then Export. This section is the headless Core half: the plan, its requests, its checks, its editor operations and its price. It builds no UI, applies nothing and calls no paid provider; the review, the music package and the renderers own that (§16.10).

Version 2 of the plan (planner v2, 2026-11-05) answers the first live evaluation's gaps: clips ran long, a series tiled the video, misheard names could not be fixed, every clip got the same captions, there was no colour look, and a series took 4–6 minutes.

### 16.1 Files

| File | Holds |
| --- | --- |
| `shared/prompts/clip-autopilot.json` | File format `schemaVersion` 2, `promptVersion` 5. `sections` of system text and `system.plan` / `system.moments`, the section lists of the two system prompts; `looks`, the colour looks with their descriptions; transcript and request templates; defaults; limits; the plan schema `clip_autopilot_plan` and the moments schema `clip_autopilot_moments`; output-token caps (`clip` 16,000, `moments` 8,000) and the minimum timeout |
| `shared/catalog/music-prices.json` | Eleven Music list price in the Voice Lab price format (`voxclip-voice-lab-prices/1`), read by `VoiceLabPriceCatalog`. It is a separate file because both Core suites pin `voice-lab.json`'s hash and entry count. **TODO (lead):** verify the 0.15 USD per minute row before the music package ships; the pricing page also says music is billed per generation |
| `shared/fixtures/autopilot/plan-validation-cases.json` | `voxclip-autopilot-validation/1`: a synthetic 30-item transcript, two rendered-transcript vectors and eleven hand-derived validation cases (version 1 fields); its `series` case replays as the moments stage. `sources` pins the prompt's SHA-256 |
| `shared/fixtures/autopilot/plan-v2-cases.json` | `voxclip-autopilot-v2/1`: a synthetic 150-word transcript of 0.5 s words and fourteen hand-derived cases for the version 2 fields, the finished length and its flags, and the moments stage. `sources` pins the same SHA-256 |
| Mac Core `Domain/Autopilot/`, `Services/Autopilot/` | `ClipAutopilotPlan`, `ClipAutopilotMoment`, `ClipAutopilotSeries`, `ClipAutopilotPrompt`, `ClipAutopilotRequestBuilder`, `ClipAutopilotValidator`, `ClipAutopilotMapping`, `ClipAutopilotPricing`, `ClipAutopilotService`, `ClipAutopilotProgress` |

### 16.2 Contract

`ClipAutopilotPlan` (`version` 2) is one clip's decisions. A reader accepts versions 1 and 2 and upgrades a version 1 plan in memory: no corrections, the original look, no speed, empty reasons, `seconds` 0 and no flags. Any other version is refused. Word indices are transcript item positions, as in §11.2, and every range is inclusive.

- `startWord`, `endWord`: the clip, which the plan may tighten inside the requested span.
- `title` (at most 120 scalars), `hook` (the on-screen text for the first 2 s), `postText` (short X or LinkedIn text).
- `corrections` (v2): `{word, heard, text, reason}`, a misheard word spelled right in the transcript and captions. `heard` is the word as the transcript showed it, `text` its replacement; the audio is unchanged.
- `cuts`: `{startWord, endWord, kind, reason}`. `kind` is `filler`, `stumble`, `repeat`, `falseStart`, `tangent` or `other`.
- `pauseCuts`: `{afterWord, reason}`, a detected pause (editing §2.4) to tighten to the project's kept length.
- `rewrites`: `{startWord, endWord, text, reason}`. `text` is the whole new phrase as spoken. Its first and last words are the range's own first and last words: the bridge words of voice-lab.md §8.4.
- `captions`: `{styleId, font {family, weight}, case, wordsPerCaption, reason}`. `case` is `upper`, `lower` or `asSaid`; it maps to `text.transform` `uppercase`, `lowercase` or `none`. The default font is Roboto 900 (Roboto Black). `reason` (v2) says why the style suits the clip.
- `look` (v2): `{id, reason}`, where `id` is `original`, `muted`, `warm` or `bw`. It renders through the clip controls (design.md §6.9).
- `speed` (v2): `{rate, reason}` or absent; `rate` is 0.75–1.5 and never 1. It renders through the clip controls, pitch kept (design.md §6.9).
- `music`: up to three `{title, mood, prompt, reason, underVoiceDb}`, an instrumental Eleven Music prompt and how many dB the track sits under the voice; `musicPick` indexes the one to use, or is null.
- `zooms`: `{word, untilWord, scale, reason}`, a punch-in from the start of `word` to the end of `untilWord`.
- `score` 1–10, `verdict` `postFirst`, `post`, `casualPost` or `holdBack`, and `scoreReason`.
- `lengthReason` (v2): why the clip runs past the target length; empty when it does not.
- `seconds` (v2): the finished length the validator measured: the span less cut items and each tightened pause beyond `pauseKeepSeconds`, divided by the speed (`ClipAutopilotMapping.finalSeconds`).
- `questions`: `{question, answer, options}`. The plan already follows `answer`.
- `repairs`: `{field, action, detail}`, one per item the validator repaired or dropped (§16.5).
- `flags` (v2): `{kind, detail}`, what the review should show next to the plan: `overLength` past `maxReasonedSeconds` (60 s), or `longWithoutReason` past `maxTargetSeconds` (45 s) with an empty `lengthReason`.

`ClipAutopilotMoment` is a moment the first stage of a series picked: `{startWord, endWord, title, idea, score, verdict, scoreReason, captionStyle, captionReason}`. `idea` is one sentence naming the idea and why it hooks.

`ClipAutopilotSeries` (`version` 2; a reader accepts 1 and 2) holds the clips ranked best first, each with its own plan; `moments`, the first stage's picks in its rank order (empty for a clip request); and the `repairs` that left moments or plans out.

### 16.3 Request

`ClipAutopilotRequest` holds the transcript, the project's edits, a mode, the creator's caption preference, the language (the transcript's when nil) and an optional note of at most `maxNoteBytes`. The modes:

- `clip(span)`: one send, the clip plan at `effort` `xhigh`.
- `clips([span])` (v2): spans chosen already, such as the top suggestions ("✦ Make top 3 postable"). Each span is planned as its own clip request, in parallel where the service has lanes, and the result ranks them like a series. At most `maxClips`; an empty list is `invalidInput`.
- `series(range?)`, the whole transcript when nil: two stages (below).

The caption preference's set fields are **fixed** (v2): every plan uses them as they are. A nil field leaves the choice to Claude, per clip. The track/v2-captions-style `ClipStyle` maps onto it: a fixed caption style is `styleId`, Auto leaves it nil.

A request lists the scope's items except words already cut, with corrections applied; it fails with `invalidInput` for an empty or out-of-range scope, a scope with no word, more than `maxTranscriptWords` items, a long note or a malformed language tag.

**Two stages for a series** (v2):

1. **Moments.** One send over the whole range at `effort` `high` (`ClipAutopilotService.momentsEffort`), with the `system.moments` prompt, the moments schema, output cap `moments` and tag `clip-autopilot-moments`. The reply is checked as §16.5 Moments.
2. **Clip plans.** Each moment is planned as a clip request over its own span (that clip's words only), at `xhigh`, with tag `clip-autopilot-series-clip`. Its instruction starts with `momentInstruction`: the moment's rank, the count, its title and idea, and, unless the creator fixed the style, `momentCaption`, the caption style picked for it and the styles of the others. At most `ClipAutopilotService.maxParallelPlans` (3) plans are in flight at once.

`ClipAutopilotService.plan(_:connector:model:lanes:progress:)` sends. `lanes` are extra connectors of the same `ConnectorID`, one per parallel plan (another id is `invalidInput`); the service runs each through its own `LLMRunner` built from the given runner's keys, catalog and log, because a runner and a CLI connector each run one send at a time. Without lanes the clip plans go one after another. A plan that fails is left out and listed in the series' repairs (`plans[N]`, "the plan failed: <case>"); the run fails only when every clip plan fails (with the first error) or on cancellation. A moments reply with no usable moment returns an empty series, not an error. `progress` receives `pickingMoments`, `picked(moments)`, then `planning`, `planned` or `failed` per clip (`clip` indexes the moments or spans; a single clip is 0 of 1).

`ClipAutopilotService.request` builds the first `LLMRequest` a plan sends (a series' moments, or the first span of `clips`):

- `feature` `clipAutopilot`, `tag` as above;
- `system` is the section list's sections joined by blank lines, with every `{name}` filled from `limits` and `{looks}` from `looks` ("- id: description" lines). Placeholders are `{name}`, a letter then letters or digits, filled in one pass; one without a value is a defect of the file (`sharedResourcesMissing`), and so is a missing section, a `looks` list that is not exactly the four look ids, or a moments schema without object `clips` items;
- `cachedBlock` is `contextBlock`: language, recording seconds (the span's, or the transcript duration for a series), the pace (`wordsPerMinute`, and `wordsMin`–`wordsMax`, the words a `minTargetSeconds`–`maxTargetSeconds` clip holds, from `spokenTime`: the listed words that are not fillers, over the scope's time less every listed filler, event and unlabeled item and less each uncut detected pause beyond `pauseKeepSeconds`, each rounded half away from zero), the caption preference line, one `styleLine` per built-in style except `off`, the default font line then one `fontLine` per bundled upright font, and the transcript;
- the caption preference line (v2) is `captionPreference` with `{parts}`: `preferenceStyle`, `preferenceFont` and `preferenceCase` for the fields that are set, joined by "; ". With none set it is `noCaptionPreference`. (Version 1 filled unset fields with the defaults, so a font-only preference fixed vox-bold for every clip.)
- `instruction` for a clip is `clipInstruction`: the listed span's first and last index, its recorded seconds, `estimate` (the `spokenTime` seconds, `toFixed1`) and the target, with `lengthOver` (the seconds to cut, rounded up) when the estimate passes `maxTargetSeconds`, else `lengthFits`. Then `names` (v2) when the recording has any: each word **outside** the span that starts with a capital letter but not a sentence, of at least 3 characters once its punctuation is trimmed, other than "I" contractions, corrections applied, in order without repeats, at most 20. A series' first stage uses `seriesInstruction` (`maxClips`). `creatorNote` follows after a blank line when there is a note;
- `maxOutputTokens` is the file's `clip` or `moments` cap, or the connector's `maxOutputTokensCap` when lower;
- `timeout` is the larger of the catalog's timeout for the connector and `minimumTimeoutSeconds` (1,200 s).

Every send checks the model's context as Voice Lab sends do (§12.8): `est()` of the text and compact schema, plus the output cap and 64 tokens, within the safety factor. It goes through `LLMRunner` (one correction retry for a reply that is not JSON, the runner's fallback rules, and the shared parser, which drops top-level array items of the wrong type and refuses a reply missing a required key), then the reply is checked (§16.5).

**Transcript format `voxclip-indexed-words-v1`.** Each listed item is `[index]text` (`word`), `[index]text(filler)` when `EditingPrimitives.filler` holds (`filler`), or `[index](label)` for an event or unlabeled speech (`event`; brackets and parentheses are trimmed from the label, and an empty label is `…`). Text is cut to 100 UTF-16 units. A line is `{time} {words}`, where `time` is `AIText.formatTime` of its first item's start. A line ends after a word ending in `.`, `!`, `?` or `…`, after `lineWords` (16) items, or at a detected pause that is not cut and follows a listed item; the pause then gets its own line, `(pause {seconds} s after [{index}])`, with seconds in `toFixed1`. The block is wrapped in `prefix` and `suffix`. `plan-validation-cases.json` `rendering` pins two vectors: the whole transcript, and one with a cut word, a cut pause and a correction.

### 16.4 Effort on each connector

`Effort.capped(to:)` gives the highest supported level at or below the request. A clip plan asks for `xhigh`; a series' moments stage asks for `high`.

| Connector | xhigh sends |
| --- | --- |
| Claude Code | `--effort xhigh` (the CLI lists low, medium, high, xhigh, max) |
| Codex | `model_reasoning_effort="xhigh"` for `default`; for a listed model, the highest of its `supportedReasoningEfforts` at or below xhigh; nothing for an unlisted model. Other efforts keep the exact-match rule |
| Anthropic | `output_config.effort: "xhigh"` (the catalog lists low to max) |
| OpenAI | `reasoning.effort: "high"` |
| Gemini 3+ | `thinkingLevel: "HIGH"` |
| xAI, Ollama, LM Studio, Apple | unchanged (no effort parameter) |

### 16.5 Validation

`ClipAutopilotValidator` checks a reply item by item and never refuses the whole plan. Each invalid item is repaired when one safe repair exists, otherwise dropped, and recorded in `repairs`. A *listed* item is one inside the scope and not already cut. Integers are finite whole numbers within ±10⁹. Shown text is trimmed, loses control characters other than newlines, and is cut to its limit (a repair). A version 2 field the reply leaves out (only possible outside a send, since the shared parser requires every key) keeps its default without a repair.

- **Span.** A clip plan's span is clamped into the requested span (a repair); an unreadable or disjoint span falls back to the whole request (a repair). Its ends then move inward to listed words.
- **Corrections, first** (v2). In reply order, at most `maxCorrections` (12). `word` must be a listed word inside the span that reads as `heard`, comparing letters and digits only, ignoring case; otherwise the nearest such word within 3 positions (in the order −1, +1, −2, +2, −3, +3) takes it (a repair), or the item is dropped. One correction per word. `text`, newlines read as spaces, has 1 to `maxCorrectionWords` (3) words, at most `EditingLimits.maxCorrectionScalars`, no link, control character or bracket tag. It takes the word's own leading and trailing punctuation when it has none of its own at that end ("Tvilio," corrected to "Twilio" is "Twilio,"), and must then differ from the word. Every later check reads the corrected words, so a rewrite's bridge word may be a corrected one. A correction of a word the plan's cuts remove is dropped after the cuts are checked.
- **Rewrites.** In reply order, at most `maxRewrites` (3). Each is a range of 2 to `maxRewriteWords` (20) listed items inside the span, beginning and ending on a word, overlapping no earlier rewrite. Its text, newlines read as spaces, has 1 to `maxRewriteTextWords` (30) words, holds no bracket tag (`VoiceLabAudioTags.sanitizedRequest` leaves it unchanged), link or control character, and keeps the bridge words: `VoiceLabTakeProcessing.keepsBridgeWords(text, bridge: ([first word], [last word]))`, the take preflight's own check. A text whose `VoiceLabTakeQuality.tokens` equal the original's changes nothing and is dropped.
- **Cuts.** A reversed range is swapped and a range reaching outside the span is trimmed (both repairs); one wholly outside it is dropped. An unknown kind becomes `other` (a repair), and an empty reason becomes the kind's name. A cut is split around every rewrite (a repair), and is dropped when nothing is left. Cuts that overlap or touch in listed order merge, keeping the first one's kind and reason. When the cuts would remove every word of the clip, all of them are dropped. At most `maxCuts`.
- **Pause cuts.** The pause must be a detected pause after a listed word, with both of its words inside the span, not already cut, not inside a rewrite, and not named twice.
- **Captions.** The style is the creator's fixed style when the preference names a built-in style other than `off` (a repair when the reply differs); otherwise a built-in id other than `off`, or `defaults.styleId` (a repair). The font is the preference's when set and allowed (a repair when the reply differs); otherwise a bundled upright face or the default, with a family that carries its weight ("Roboto 900") split (a repair), else the default. The case is the preference's when set (a repair when the reply differs), else the reply's, else `defaults.case`. `wordsPerCaption` is clamped to 1…8. `captionReason` becomes `captions.reason`.
- **Look** (v2). Read ignoring case and non-letters, so "B&W" is `bw`; "black and white" and "monochrome" are `bw` and "none" is `original`. An unknown look becomes `original` without its reason (a repair). No look is `original`.
- **Speed** (v2). A rate within 0.005 of 1, or no speed, is no speed. A rate that is not a positive finite number is dropped. Otherwise it is clamped to `minSpeed`…`maxSpeed` (0.75…1.5; a repair) and keeps `speedReason`.
- **Music.** At most `maxMusic` (3) suggestions, each with a title and a prompt. A prompt without "instrumental" (case-insensitive) gets `music.instrumentalSuffix`. `underVoiceDb` is clamped to 6…30 dB, or the default 18 when unreadable. A pick that names no kept suggestion becomes the first one; there is no pick without suggestions.
- **Zooms.** The start word must be a kept word of the span, not cut by the plan. `untilWord` moves inside the span when it lies outside it or before `word`. It is then shortened until the zoom lasts at most `maxZoomSeconds` (6 s) and ends on a listed word (a repair). The scale is clamped to 1.05…1.35 (`MotionCue.maximumScale`), or the default 1.15 when unreadable. A zoom overlapping an earlier one is dropped. At most `maxZooms`.
- **Score and verdict.** The score is rounded and clamped to 1…10, or the default 5 when unreadable. The verdict is read ignoring case and non-letters ("post first" is `postFirst`). Otherwise it is the one the score implies: 9+ `postFirst`, 7+ `post`, 5+ `casualPost`, else `holdBack`.
- **Length** (v2). `seconds` is measured as §16.2 says. Past `maxReasonedSeconds` (60 s) the plan gets an `overLength` flag whatever its reason; past `maxTargetSeconds` (45 s) with an empty `lengthReason`, a `longWithoutReason` flag. Flags change nothing in the plan.
- **Title, hook, questions.** An empty title becomes `EditingAlgorithms.clipTitle` of the span's words. A question needs a question and an answer; options are deduplicated and cut to `maxOptions`; at most `maxQuestions`.
- **Moments** (v2, the series' first stage). In reply order, at most `maxClips` (12). A moment's span is checked as a clip span, and the moment is left out (`clips[N]`) when it is unreadable, has no words, lasts outside `minClipSeconds`…`maxClipSeconds` as recorded, or overlaps a better-ranked moment. Title, idea, score and verdict are read as above, and the caption style as Captions; their repairs are named `clips[N].field`. Only the first `postFirst` keeps it: a later one becomes `post` (a repair).
- **Series** (v2). The clip plans are ranked by score, best first, ties in the moments' order. Only the best `postFirst` keeps it; the others become `post`, with a `verdict` repair in their plan.

### 16.6 Operations

`ClipAutopilotMapping.operations(for:clipID:project:fonts:)` turns a plan into reviewable operations, one per decision, each with a stable `id` and its reason, in this order: `clip`, `title`, `correction-N`, `cut-N`, `pause-N`, `rewrite-N`, `captions`, `look`, `speed`, `zoom-N`, `music`, `hook`, `post`.

- the clip: `EditCommand.updateClip` when the span changed, for an existing clip; for a new id (a series clip), `addClip` with origin `ai` and the title;
- the title: `renameClip`, for an existing clip whose title differs;
- each correction (v2): `EditCommand.correct(id:text:)`, the editor's own transcript correction, before every cut;
- each cut and pause cut: `cutSelection` of the ids not cut yet, so the reducer's toggle always cuts;
- each rewrite: a Rewrite proposal for `RewriteScope.selection(start...end)` with the text. It needs a voice, a quote and a paid click;
- captions: the project's `CaptionSettings`, with `styleId` and merge-patch overrides `text.transform`, `layout.maxWords` (and `maxLines` 1 for one word), and `font.file`/`family`/`weight` when the font is bundled. Otherwise `pendingFont` names it, and the style's own font renders until it is bundled. The reason is `captions.reason`;
- the look (v2): `.look(clipID:look:)`, always present, so the review can show "Claude chose Warm · Change". `original` needs no rendering;
- the speed (v2): `.speed(clipID:speed:)`, only when the plan has one;
- each zoom: a constant-scale `MotionCue` (`<clipID>-zoom-N`) over the words' source time;
- the music cue: the picked track, the alternatives and `editedSeconds`, the length at the clip's own speed. A bed is staged for the rendered length (design.md §6.9), so a track of `editedSeconds` always covers the clip;
- the hook text, and the share text (`project.share.captions[clipID]`).

`ClipAutopilotMapping.apply` applies edits (corrections included), captions, the look and the speed (`ClipControlsProject.settingLook` and `settingSpeed`, design.md §6.9, keeping the clip's other controls), motion cues (through `ContextDemoProject.settingMotionCues`, which upgrades the project to version 4) and share text to a copy, in order. It returns rewrites, music and the hook as pending. Make it postable applies the same operations in its own pure step (`makeItStep`), which also records each one's inverse for the review's Undo. One undo step is the caller's choice. `finalSeconds` is `editedSeconds` divided by the speed.

### 16.7 Price

`ClipAutopilotPricing.price` returns the voice estimate, the music estimate and the LLM cost. The voice estimate is `VoiceLabPricing` text-to-speech of the rewrites' whole texts, bridge words included, for the chosen model and candidates. The music estimate prices the picked track's edited length (at the clip's own speed), rounded up to whole seconds, from `music-prices.json`; the price is unknown without that file. The LLM cost is `none` when `VoiceLabCostPresentation.kind` says the send is inline: a CLI on a plan, a local server, or Apple. Otherwise it is `unknown`. `usd` adds voice and music when every present part is priced; the plan's own sends are never part of it. Corrections, the look and the speed cost nothing.

### 16.8 Tests

`ClipAutopilotTests` and `ClipAutopilotV2Tests` (Core) cover:

- the prompt file: both system prompts filled, the looks, both schemas, defects refused (a missing section, a look missing, a bad moments schema, an unknown placeholder), and both fixtures' prompt hash;
- the rendered transcript vectors and the requests: efforts, schemas, tags, timeout, output caps, the preference line with only the fixed fields, styles and fonts, the length estimate and `lengthOver`, the names line, the note, refusals;
- every case of both fixtures, including the version 1 `series` case replayed as moments;
- a version 1 plan read and upgraded, and a version 3 plan refused;
- the service with stub connectors: the correction retry; the two stages, with a gate that holds clip plans until three are in flight (so three run at once) and a fourth lane that is never used; the moment brief text; progress events; a failed clip plan left out; every plan failing; an empty moments reply; `clips` without the moments stage; lanes of another connector refused;
- ranking and the single `postFirst`;
- mapping and apply (corrections through `correct`, look and speed pending), with `ProjectValidation` of the result;
- edited and finished length, pricing, and `Effort.capped`.

`CLIConnectorTests` and `HTTPConnectorTests` pin the xhigh arguments and bodies. No test sends anything or waits on a clock. The Windows twin of all of §16 is owed and should replay both fixtures.

### 16.9 Live evaluation

`ClipAutopilotLiveEvalTests` runs only with `VOXCLIP_AUTOPILOT_LIVE_EVAL=1`, never in CI. It needs a project (`VOXCLIP_AUTOPILOT_EVAL_PROJECT`) and an output folder under `/tmp/voxclip-autopilot-eval/` (`VOXCLIP_AUTOPILOT_EVAL_OUT`); `VOXCLIP_AUTOPILOT_EVAL_CLIP=start-end` picks the single clip (the best series clip otherwise). Before any send it runs Claude Code's sign-in check and refuses an `authMethod` naming an API key or an `ANTHROPIC_API_KEY` in the environment. It then plans a two-stage series with two extra Claude Code lanes and one single clip, and writes every request, every raw reply, the checked plans, `table.json` and `summary.md` (stage and wall times, picks, finished lengths, corrections, captions, looks, speeds, flags). Nothing it writes is committed. Run it in a clean environment, without the parent's `CLAUDE*` and `ANTHROPIC_*` variables, as the app would start the CLI.

Planner v2 evaluation (Claude Code 2.1.318, Opus, plan sign-in, three prompt rounds on the 5:48 test clip; prompt v5 kept): the series took 103 s (moments 22 s, four clip plans of 37–71 s, three at once) against 236–338 s for version 1. All four clips finished at 21–34 s; it corrected both misheard product names inside the picks, each citing the right spelling from the names line; the captions were four different styles; one look for the whole series (warm); speed 1.1 on slow delivery. A single clip took 39 s for a 42 s span and 78 s for an 83 s span. A round that told stage 1 never to pad to 20 s made it pick wider spans (clips 36–50 s), so it was reverted.

### 16.10 Owed

- **UI (Mac, built in track/v2-make-it; design.md §6.7):** the ✦ action and its cap, the run with progress lines from `ClipAutopilotProgress`, the review with Undo or Change per operation (correction, look and speed rows and the flags included), one undo step, and the questions. The Windows twin is owed.
- **Look and speed (done on Mac, design.md §6.7 and §6.9):** the run applies both in its one undo step, with "Claude chose the warm look · Change" and "Claude chose 1.1× speed · Change" rows (▶, Undo, chips that apply another as one step), and the headline is the rendered length. Windows rendering is owed; Windows refuses to export clip controls.
- **Music:** the Mac UI applies the pick through `MusicPanel` and sets `underVoiceDb` as the bed's level. Verifying the music price is still owed.
- **Rewrites (Mac, built):** each is voiced through the existing Rewrite flow (`MakeItRewriteDriver`), where window placement adds the audio bridges.
- **Roboto Black:** bundled by track/v2-captions-style; the captions operation applies it.
- **Hook:** a title card for the hook text.
- **Prompt:** `lengthReason` comes back as a length estimate even when the clip fits, so `longWithoutReason` rarely fires; the next round should ask for it to be empty within the target. Looks came back the same for a whole series.
- **Windows:** the twin, replaying both fixtures.

---

## 17. Caption pick (`captionPick`)

When the clip style's captions are Auto (design.md §6.6), one request asks the connector to choose a caption style
for each clip, with a one-line reason. A caption style the user fixed is never sent and never overridden.

- **Prompt.** The prompt is `shared/prompts/caption-pick.json` (`promptVersion` 1). Both Cores render it with
  `CaptionPickPrompt`, and the system text is sent unchanged.
- **Instruction.** The instruction fills `{preset}` with the preset label and `{styles}` with one `styleLine`
  ("- {id}: {name}. {description}") per candidate. It fills `{clips}` with one `clipLine` ("{clip} ({seconds} s)
  {title}: {text}") per clip:
  - Clips are labelled C1, C2… in clip order, at most `limits.maxClips` (24).
  - The seconds are whole seconds, with halves rounded up; a negative or non-finite length is 0.
  - A blank title is "Untitled".
  - The text is trimmed and cut to `limits.maxClipChars` (600) by the shared clip-text rule.
- **Candidates.** The candidates are every library caption style except those tagged with one of the preset's
  `excludeCaptionTags` (Calm story and Demo / tutorial exclude `emoji`), in gallery order (`order`, then `id`).
- **Request.** The request uses feature `captionPick`, output `caption_picks` (`{picks: [{clip, style, reason}]}`,
  strict), `maxOutputTokens` 2000 and effort `xhigh` (decision, §4.4.1). Its activity tag is "caption-pick {n} clips".
  It is sent only after the inline connector confirmation, with the verb "Pick styles" and consent action
  `pickCaptions`.
- **Reply.** Labels and styles are trimmed. A pick is dropped when its label is unknown or repeated, when its style is
  not a candidate, or when its style is `auto`. The reason keeps its first `limits.maxReasonChars` (120) Unicode
  scalars. The surviving picks are recorded as `clipStyle.captionPicks[clipId]`, after picks for clips that no longer
  exist are pruned. Recording is a no-op unless captions are still Auto when the reply arrives.
- **Errors.** Refusal and truncation have their own `captionPick` messages in both LLM error tables. Every other
  failure uses the shared connector errors, shown inline under the Captions style row.
- **Vectors.** `shared/fixtures/clip-style/caption-pick.json` comes from `tools/fixtures/clip-style/gen_caption_pick.py`,
  an independent standard-library producer. It holds 4 request vectors (instruction text), 4 reply vectors (picks and
  dropped counts) and 14 clip style contract cases (validation, fixing, pruning and the summary). It also records the
  sha256 of the prompt and of `shared/data/clip-styles.json`, so a stale fixture fails both Cores.

## 18. Ask Claude (`askClaude`)

The creator selects words, a clip or a time range, types what they want, and gets edits from one shared toolbox
(design.md §6.8). The free edits apply as one undo step; anything that can cost money waits for its own priced click.

### 18.1 Request

- **Selection.** `AskClaudeSelection` is a word range (transcript indices, inclusive), a whole clip, or a source time
  range, with the clip it belongs to (nil for the full video). `AskClaudeScope.resolve` turns it into a word range
  (nil when a time range holds no words), source seconds and the clip. The request lists at most
  `limits.maxSelectionWords` (400) selected words.
- **Instruction.** The user's words, trimmed and cut to `limits.maxInstructionChars` (500 UTF-16 units). An empty
  instruction sends nothing.
- **Context.** The instruction template carries the selection line, one `wordLine` per selected word
  ("[{index}] {start}-{end} {text}", corrections applied), `limits.contextWords` (20) words before and after, the
  clip line, the frame ("{width}x{height} recorded, exported {aspect}"), what the stretch already has (effects that
  overlap it, its clip's zooms, corrections and cuts on its words), the Vision detections and the toolbox. Seconds
  and normalized numbers are written with two decimals and a point.
- **Detections.** Before the request, Vision looks at the selected stretch of the source (`ClipEffectVision.detect`):
  faces (`VNDetectFaceRectanglesRequest`) and text (`VNRecognizeTextRequest`), labelled D1, D2… with their seconds,
  normalized top-left rect and, for text, what it reads (cut to 60 characters). At most `limits.maxDetections` (24)
  are listed. Connectors take text only, so the detections stand in for frame thumbnails, which are owed.
- **Send.** Feature `askClaude`, output `ask_claude_ops` (strict), `maxOutputTokens` 4000, effort `xhigh` (decision,
  §4.4.1), after the inline connector confirmation (verb "Ask Claude", consent action `askClaude`). Refusal and
  truncation have their own `askClaude` messages; other failures use the shared connector errors, inline under the
  field.

### 18.2 Toolbox and contract

The toolbox extends the planner's operations (`ClipAutopilotOperation`, §16) additively: `Decision` gains `bleep`,
`blur`, `overlay`, `freeze`, `sound`, `stretch`, `translate` and `duck`; `Action` gains `effect(ClipEffect)`,
`stretch(clipID:start:end:rate:)`, `translateCaptions(clipID:startWord:endWord:language:text:)` and
`musicDucking(clipID:on:)`. `ClipAutopilotMapping.apply` adds effects through `ClipEffects.adding`. A clip plays at one
speed (design.md §6.9): a stretch that covers a whole clip, within `ClipControlsProject.wholeClipToleranceSeconds`
(0.25 s) at each end, sets that clip's speed (`ClipControlsProject.wholeClip`, `settingSpeed`); a stretch over part of
a clip is returned as pending, and the editor's row offers "Apply 1.25× to the whole clip". Translate stays pending.

| Kind | Group | Fields | Becomes |
|---|---|---|---|
| `bleep`, `mute` | Censor | startWord, endWord | `ClipEffect` with `wordIds` and the words' bounds |
| `blur`, `pixelate` | Censor | start, end, target or x/y/width/height, tracking | `ClipEffect` with `rect`, `tracking` and `track` |
| `title`, `lowerThird` | Overlays | start, end, text, position | `ClipEffect` with `text`, `position` |
| `sticker` | Overlays | start, end, text, position, scale | `ClipEffect` (one of the prompt's `stickers`) |
| `arrow`, `circle` | Overlays | start, end, target or x/y/width/height | `ClipEffect` with `rect` |
| `progress` | Overlays | start, end, position | `ClipEffect` |
| `speed` | Timing | start, end, rate | `stretch` (the clip's speed when whole; else pending with a whole-clip offer) |
| `freeze` | Timing | start, end | `ClipEffect` |
| `jumpCut` | Timing | startWord, endWord | `edit(.cutSelection)` |
| `zoom` | Timing | start, end, scale | `motion` cue |
| `correction` | Words | startWord, text | `edit(.correct)` |
| `rewrite` | Words | startWord, endWord, text | `rewrite` (paid) |
| `translate` | Words | startWord, endWord, language, text | `translateCaptions` (pending) |
| `music` | Sound | text (the mood) | `music` cue (a row that opens Music) |
| `duck` | Sound | start, end | `musicDucking` |
| `sound` | Sound | start, sound | `ClipEffect` with a bundled `sound` |

**Project contract.** Effects are stored as the root `clipEffects` array, project schema v4 only, omitted when empty;
adding the first effect promotes a project to v4. `ClipEffect` has `id` (`fx-<kind>-<n>`), optional `clipId`,
`kind`, `start` and `end` (source seconds, at most 600 s long) and exactly the keys of its kind:

- `bleep`, `mute`: `wordIds`. `blur`, `pixelate`: `rect`, `tracking` (`none`, `face` or `saliency`), `track`.
- `title`, `lowerThird`: `text` (≤80 scalars), `position`. `sticker`: `text` (≤16 scalars), `position`, `scale`
  (0.5–3). `arrow`, `circle`: `rect`. `progress`: `position`.
- `freeze`: no more (≤5 s). `sound`: `sound` (`bundled` with `id` whoosh, pop or ding, or `library` with `file`,
  `sha256`, `title`, `creator`, `license` of `cc0`, `by` or `pdm`, `attribution` and `sourceUrl`; ≤10 s) and `gainDb`.
- A `rect` is normalized, top-left, inside the frame. A `track` sample is `{t, x, y, width, height}`.

At most 500 entries, unique ids. The JSON Schema `$defs` (`clipEffect`, `clipEffectRect`, `clipEffectTrackSample`,
`clipEffectBundledSound`, `clipEffectLibrarySound`) come from `tools/schemas/generate_clip_effects_schema.py`.
Removing a clip removes its effects; replacing the transcript clears them. Censor kinds render in every clip and the
full edit; other kinds only in their `clipId` (or the full edit when it is nil).

### 18.3 Prompt

`shared/prompts/ask-claude.json` (`promptVersion` 1) holds the system text, the request templates, the toolbox
(`kind`, `group`, `fields`, `use`, in this order), the 50 `stickers` (the bundled Noto emoji in
`shared/fonts/noto-emoji/png128`, without variation selectors), the `limits` and `generation`. `AskClaudePrompt`
renders it; its sha256 is recorded in the vectors. The reply schema `ask_claude_ops` is
`{summary, ops: [{kind, startWord, endWord, start, end, text, target, x, y, width, height, tracking, position, rate,
scale, sound, language, choice, reason}]}`, every field required: an unused field is -1 (word indices and seconds), 0
(numbers) or "".

### 18.4 Validation and repair

`AskClaudeValidator.answer` checks the reply op by op, in order, keeping at most `limits.maxOps` (12):

- **Clamping.** Word indices are clamped to the selection; a missing or empty range takes the whole selection. Seconds
  are clamped to the selection; missing seconds take the words' times, then the selection. Rates are clamped to
  0.5–2 and sticker scales to 0.5–3; text is trimmed and cut to `limits.maxTextChars` (80).
- **Regions.** `target` may name a detection (D1…), "face" or "screen", or the op gives a rect. With neither, the
  largest face seen in the stretch (else the largest text box) is pre-picked and named ("the face at the left",
  "the text \"INVOICE 1042\""): `choices[opId]` makes the row read "Claude chose … · Change". A face target tracks
  the face unless the op says otherwise.
- **Sounds.** Unknown names map through aliases (swoosh → whoosh, click → pop, chime → ding…) and otherwise to a
  whoosh, noting the choice. Lengths: whoosh 0.45 s, pop 0.12 s, ding 0.8 s, at −6 dB.
- **Drops.** An op that cannot act is left out with a repair line ("Left out sticker: not one of the bundled
  emoji."): no words or time in the selection, no text, no region, the same speed, words already cut, no new
  spelling, a zoom or music with no clip, a duck with no music, an invalid language tag, or a kind outside the
  toolbox. Each built effect is validated against the project contract before it is kept.
- **Paid.** `rewrite` and `music` operations are listed in `paid`. The editor never applies them with the answer: the
  rewrite row shows "Voice it · about $X" (the text priced at the ElevenLabs `eleven_multilingual_v2`
  text-to-speech rate) and hands off to Rewrite, which confirms the exact price; the music row opens Music.

### 18.5 Rendering (Mac)

`RenderCallerInputs.prepare` resolves `ClipEffectsRenderInput` (the effects of the rendered clip, sound files by
effect id) for the preview and the export alike, so the preview is the export.

- **Picture.** `FrameCompositor` applies blur (`CIGaussianBlur`) and pixelate (a pre-blur at half the cell size,
  then `CIPixellate`) in source space before crop and motion, and draws titles (Roboto Black on a dark box), lower
  thirds (DM Sans Bold with an accent bar), emoji (the bundled PNG), arrows, circles and the progress bar on the
  output frame after motion, under the captions. Overlays fade over 0.12 s at each end.
- **Tracking.** After the answer, a tracked censor is traced through its range (`ClipEffectVision.track`): every 0.25 s
  it detects faces (each grown by 25 %) or the salient object, picks the one nearest the previous rect (a frame with
  none keeps it), smooths the samples with a centred 3-sample average and stores them as `track`. Rendering
  interpolates between samples.
- **Freeze.** The picture over the freeze range is its first frame, held; the voice plays on.
- **Audio.** Bleep and mute silence the voice over the words' exact bounds with 10 ms ramps outside them (an
  `MTAudioProcessingTap` on the voice). A bleep adds a 1 kHz tone at 0.25 with the complementary ramps. Sounds are
  staged with the tones into one 48 kHz stereo track mixed under the voice like the music bed. Renders that read the
  voice alone (`withoutMusic`: the edited-audio export and duration probes) drop the sound effects but keep bleeps and
  mutes, so the edited audio is censored like the video.
- **Captions.** Bleeped and muted words show × (U+00D7) for each letter and digit, punctuation kept. Every bundled
  caption font has ×, and it is a symbol, so styles that strip punctuation keep it.
- **Clip controls** (design.md §6.9). At a clip's speed every effect keeps its edited time and lands on the rendered
  clock: the bleep's silence is applied to the 1× voice before it is stretched, the tone and sounds are placed at their
  times ÷ speed (never resampled, so the tone stays 1 kHz), and overlays show over their window ÷ speed. The look
  grades the picture before any effect, so overlays keep their colours. Censor and pointer boxes are given on the
  source as filmed and are flipped and turned with the picture (`ProjectClipControls.mapRect`).
- **Default.** With no effects nothing in the render path changes.

### 18.6 Vectors

- `shared/fixtures/clip-effects/` (`tools/fixtures/clip-effects/generate_clip_effects.py`): a v4 project with one
  effect of each kind, and `effects-wire-cases.json` (valid and invalid entries with their schema verdicts), read by
  both Cores and the schema tests.
- `shared/fixtures/ask-claude/ask-claude-cases.json` (`tools/fixtures/ask-claude/generate_ask_claude.py`): the
  invoice project, a request rendered independently of both Cores, and five replies with hand-derived operations,
  choices and repairs. It records the prompt's sha256, so a stale fixture fails.
- Mac pixel goldens under `shared/fixtures/media/effects/` (blur, pixelate, title, lower third, emoji, arrow,
  circle and progress) and the bundled sounds in `shared/data/sfx/` (`tools/media/sfx/gen_sfx.py --check`).

### 18.7 Windows

Windows Core opens, validates and saves `clipEffects` unchanged (`Domain/Effects/ClipEffects.cs` keeps entries as JSON
elements and checks them against the same wire vectors), prunes them with their clip and clears them with the
transcript. It refuses to export a project with effects ("Windows cannot render Ask Claude effects (bleeps, blurs,
overlays, freeze frames or sound effects) into exports yet. Export this project on a Mac…"). The Windows Ask Claude request, validator, field and renderers are owed.

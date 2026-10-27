# Voice Lab pricing, cost presentation and spend ledger cases

`pricing-cases.json` holds the shared cases for voice-lab.md §3.1 and §3.2: the price catalog `shared/catalog/voice-lab.json`, `VoiceLabPricing`, `VoiceLabCostPresentation`, the spend ledger and the monthly cap setting. The Mac suite `apps/macos/Tests/VoxClipCoreTests/VoiceLab/VoiceLabPricingTests.swift` and the Windows suite `apps/windows/tests/VoxClip.Core.Tests/Tracks/voice-lab/VoiceLabPricingTests.cs` replay every case.

Regenerate only with `python3 tools/fixtures/voice-lab/generate_pricing.py` and review the diff as a behaviour change. The generator uses only the Python standard library. It is an independent reference of the rules below, written with the `decimal` module, and the tests never run it. Two runs give identical bytes. `inputs` pins the SHA-256 of the catalog the cases were computed from, so a price change needs a regenerated fixture. Expected values are never edited by hand.

## Money

Prices are decimal strings in the catalog. Both Cores parse them into `Decimal` or `decimal`, never into binary floating point. Units and the character multiplier arrive as doubles; each is converted to the shortest decimal that reads back as the same double (Swift `description`, .NET `ToString("R")`, Python `repr`). An estimate's `usd` is computed in decimal arithmetic, in the order the formulas are written, and then rounded half away from zero to 10 decimal places (`usdDecimalPlaces`). Every expected `usd` is written in canonical form: plain digits, no exponent and no trailing fractional zeros, so 0.30 is `"0.3"` and 10.0 is `"10"`. Tests compare the canonical strings.

## Catalog lookup

A request names an operation (`provider`, `operation`, `endpoint` or null, `unit`) and a model or null. An entry matches when its provider and operation are equal, its endpoint equals the request's (both may be absent), and it has no model or the same model. Both Cores refuse a catalog in which two entries could match one request, an unknown `schema`, an unknown formula, a formula with the wrong unit or parameters, or a price that is not a decimal string.

## Estimates

`estimates` cases give the operation, `model`, `units`, `candidates` and `characterMultiplier`, and `expected` is either `{"error": "invalidInput"}` or `units`, `unit`, `usd`, `credits` and `basis`. The checks run in this order:

1. `units` must be finite, from 0 to 1,000,000, and whole for the units `character` and `call`; a lip sync (operation `lipsync`) needs more than 0 seconds, because the caller refuses an empty window before it asks; `candidates` must be 1 to 3 (`CANDIDATES`); a multiplier must be absent or from 0.01 to 100. Otherwise `invalidInput`, even for a provider the catalog lacks.
2. Without a matching entry, the estimate is unknown: `usd` and `credits` are null, `basis` is `unknown`, and `units` and `unit` are the request's. A guess is never made.
3. A matching entry whose unit differs from the request's, or more than one candidate for a formula other than `perThousandCharacters`, is `invalidInput`.
4. The formula gives `usd`, with `u` the units and `p` the price parameter:

| Formula | `usd` | `credits` |
|---|---|---|
| `perHour` | `u × p / 3600` | null |
| `perMinute` | `u × p / 60` | with `creditsParameters.perMinute` k, `ceil(u × k / 60)`; otherwise null |
| `perSecond` | `u × p` | null |
| `perThousandCharacters` | `u × candidates × p / 1000`: each row already is that model's list price | `ceil(u × candidates × multiplier × perCharacter)`, multiplier 1 when absent |
| `flatThenPerSecond` | `flat + max(0, u − includedSeconds) × perSecond` | null |
| `zero` | `0` | null |
| `estimateApi` | null, `basis` `unknown`: the price comes from the provider's estimate call (§3.3) | null |

A priced estimate's `basis` is `list-<checked>`. For `perThousandCharacters`, `units` is the billed count, `u × candidates`; elsewhere it is `u`. The multiplier is a credit multiplier: it scales TTS credits only and is ignored outside `perThousandCharacters`.

`providerPrices` cases apply a live provider price (§3.3) to an estimate through the typed hook. The price replaces `usd`, rounded as above, `credits` and `basis`, which is `provider-estimate` or `provider-pricing-api`; provider, operation, units and unit stay. A negative amount or credit count is `invalidInput`.

`quotes` cases are the estimates on `ElevenLabsVoiceLab` quotes, prepared after mocked discovery: TTS is one candidate with the model's discovered `model_rates.character_cost_multiplier` and units counted in Unicode scalars, a voice-changer quote is `frames / rate` seconds of its WAV, and creating or deleting a voice is one free call.

## Formatting and presentation

`formats` cases give the text of an amount. Below $0.01 it is `< $0.01`. Otherwise, with `e = floor(log10(usd))`, the amount is rounded half away from zero to a multiple of `10^max(e − 1, −2)`: two significant digits, but never finer than a cent, so it is rounded only once. A rounded amount below $10 shows exactly two decimals (`≈ $0.36`, `≈ $1.20`, and `≈ $0.01` for $0.0149). From $10 it shows no decimals, with a comma between thousands (`≈ $12`, `≈ $1,000`). Every amount from $0.01 starts with `≈` and a space.

`presentation` and `presentations` give the kind. An amount of exactly 0 is `inline` with empty text: a free action shows no amount. Lip sync is the exception and always confirms; a valid lip-sync estimate is never $0, so only a hand-built one reaches this. Otherwise it is `inline` with the formatted amount when `usd` is known, below 0.50 before any rounding, the action is not lip sync, and it does not cross `cap`. Otherwise it is `confirm`, with the §3.1 sentence: "This will cost about {amount} on your {provider} account.", where `{amount}` is the formatted amount without `≈` and the space; "This will cost less than $0.01 on your {provider} account." below a cent; or "VoxClip can't tell what this costs. Check {provider}'s pricing." when `usd` is unknown. `{provider}` is the caller's display name. A presentation with `cap` (`limit` and the month's known `spent`) crosses when `spent ≤ limit < spent + usd`; crossing always confirms and appends the cap sentence below after one space. Reaching the limit exactly, or starting above it, does not cross.

`buttons` cases join the action, `"{n} take"` or `"{n} takes"` when the caller passes a take count, and the inline amount, with ` · `. A free action or a confirmation button carries no amount.

## Spend ledger

`<data>/VoiceLab/spend.json` sums the estimates of actions that ran. `record` adds one estimate under the user's local calendar month at the action's start (`YYYY-MM`, Gregorian) and the estimate's provider: a known `usd` is added to `usd`, and an unknown one adds 1 to `unknownCount`, and an amount of exactly 0 is not recorded at all. The file is written in the canonical form of `ledger.emptyFile`: two-space indent, `schema` then `months`, months and providers in ordinal order, `usd` (a canonical decimal string) before `unknownCount`, LF line ends and a final LF. Writes go to a temporary file in the same directory, created with mode 0600 where the platform has modes, and then replace `spend.json`. They happen while the writer holds an exclusive lock on `spend.json.lock`, which is never deleted; readers hold a shared lock for at most 0.5 seconds. Only `<data>/VoiceLab` itself is ever created, with mode 0700, and only inside an existing data folder.

- `rollovers` record a sequence in a fixed UTC offset (`timeZoneOffsetSeconds`); each step gives the `month` it lands in and `ledger` is the final file.
- `concurrent` runs two in-process writers on separate ledger instances for one file. They start together at a barrier and each records its estimate `recordsPerWriter` times. Any lost update changes the final file, which must equal `ledger`.
- `existing` starts from a file holding `content` (or the bytes of `contentBase64`) and records `recoveryRecord`. A `corrupt` file is renamed `spend.corrupt-<unix milliseconds>.json`, with `-1`, `-2` … added if that name exists. It keeps its exact bytes, a fresh ledger is started, and `record` returns the typed recovery warning. A file is corrupt when it is not UTF-8 JSON without a byte-order mark, repeats a key in any object (keys compare after unescaping), is not an object with exactly `schema` (`voxclip-voice-lab-spend/1`) and `months`, has a month key that is not `YYYY-MM`, a provider key outside `[a-z0-9]+(-[a-z0-9]+)*`, or an entry other than exactly `usd` (matching `(0|[1-9][0-9]{0,11})(\.[0-9]{1,10})?`) and a whole `unknownCount` from 0 to 2,147,483,647.
- `freeOnly` records only $0 estimates in a fresh data folder: every record returns no warning and neither `<data>/VoiceLab` nor the ledger is created.
- `cap` records `existing` in UTC and checks `wouldCross`. It is true only when the estimate is known and the provider's total for the month of `at` is at most the cap before the action and above it after. `sentences` give the §3.1 sentence; a whole cap shows no decimals and any other cap shows two.

`record` never throws into the provider path. A lock not acquired within 5 seconds, a cancelled wait, an I/O failure or an invalid estimate returns a typed warning instead, and nothing is recorded. Only another holder of the lock is waited for: any other I/O failure, such as a read-only folder, is `writeFailed` at once.

## Settings

`settings` cases are `voiceLab.monthlyCapUsd.<provider>` values for Settings → Voice Lab → "Warn me above $__ a month per provider". The value is null (no cap), or a decimal string with up to nine whole digits and up to two decimals. It has no default.

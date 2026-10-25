# Windows release tooling

Run from the release Mac. The normative product contract is `doc/release.md`;
this file describes the implementation and its current integration gates.
Real uploads may create a missing draft; nothing publishes or pushes a release.

## Usage

```sh
apps/windows/build/release-windows.sh --upload --dry-run
apps/windows/build/release-windows.sh --skeleton-test --no-upload
apps/windows/build/release-windows.sh --no-upload
apps/windows/build/release-windows.sh --upload
apps/windows/build/release-windows.sh --upload-only /absolute/path/to/run
```

The default is build/sign/package/verify **and upload to a draft**. `--dry-run` prints
the plan without SSH, credential access, signing, or GitHub requests.
`--no-upload` stops after local verification. `--upload` explicitly requests the
default; it creates a missing draft `v<version>` (a pre-release for a pre-release
version), and checks draft status before every upload attempt. Uploads are restricted to the
constant Setup/feed/source/checksum names and the versioned packages in the
Velopack feeds. Legacy feeds, portable ZIPs, local metadata and evidence never
enter the upload set. Failed uploads retain the artifacts for `--upload-only`.
Without a directory argument, `--upload-only` uses `.release/latest`, a symlink
updated only after the final Mac hashes and optional `osslsigncode` checks pass
for a clean production build. Failed verification preserves any previous pointer.

Production builds require a clean tree with HEAD tagged `v<version>` and matching
Windows/macOS versions. `--allow-dirty` permits a non-uploadable test build but
does not bypass the FFmpeg source or release-icon gates. `--skeleton-test` still
requires the complete schema-2 FFmpeg pin and staged local builds, but uses the
shared brand ICO when the release ICO is absent. It still builds both apps for
both architectures, signs and verifies every PE, packages, and tests
installation. It **never** makes a releasable source archive or upload manifest,
and cannot be combined with upload.
`--resume-skeleton <run-id>` retries only such a failed test's signing/packaging
and verification, retaining its original published source commit. It never
turns an untagged payload into a releasable build. Timestamp-service failures
retry up to three times, and completed signatures are not needlessly repeated.
Resume only runs created by the round-3-or-newer driver whose `config.json`
contains `BuildRoot`. The historical run recorded below predates that field
and cannot be resumed by the current driver; start a new skeleton run instead.

## Prerequisites and overrides

- Mac: Bash, Python 3 with lzma support, tar, SSH/SCP, `shasum`, `iconv`, and GNU
  `timeout` (Homebrew coreutils). GitHub CLI is required only for real uploads.
- VM: Windows 11 ARM64, key-based SSH, .NET 10 SDK, x64 signtool and the matching
  x64 Artifact Signing dlib, and its x64 .NET signing runtime. x64 builds and the
  x64 FFmpeg gate run under Windows emulation.
- `VOXCLIP_WIN_HOST`: required; explicitly select the release VM.
- `VOXCLIP_SIGNING_ENV`: required; external signing env file, with no personal default.
  Every ancestor of its resolved path is compared with the checkout by device
  and inode, rejecting internal files through symlinks, case variants on
  case-insensitive filesystems and other aliases. Missing credentials fail.
  Files with more than one hard link are refused before locking or staging.
  All local staging, secret-name checks and VM configuration generation finish
  before acquiring the VM lock or deleting any older VM run.
- `VOXCLIP_TIMEOUT`: defaults to `/opt/homebrew/bin/timeout`.
- `VOXCLIP_BUILD_TIMEOUT`: whole remote pipeline limit in seconds; default 5400.
- `VOXCLIP_VM_DOTNET`, `VOXCLIP_VM_SIGNTOOL`, `VOXCLIP_VM_DLIB`,
  `VOXCLIP_VM_SIGNING_DOTNET_ROOT`: override the existing owner VM tool paths.
  Without `VOXCLIP_VM_SIGNTOOL`, the VM chooses the newest Windows Kits
  `10.0.26100.0` or later `x64\signtool.exe`, then the pinned AzureTrustedSignTool
  `1.3.13` bundle under `%USERPROFILE%\.dotnet\tools\.store\azuretrustedsigntool\`
  `1.3.13\azuretrustedsigntool\1.3.13\tools\net8.0\any\Sdk\signtool.exe`.
  This bundled x64 tool is an accepted prerequisite with the matching x64 dlib;
  a Windows SDK is not required when it is available. `evidence/signing-tool.json`
  and the verification receipt record the chosen path and file version, both
  PE machine types, and the dlib path. The VM checks the PE headers before any
  signing environment is set and refuses a mismatched or invalid pair with a
  signing-prerequisite error; the bundled x64 tool with the x64 dlib passes.
- `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT`, `AZURE_SIGNING_PROFILE`:
  required non-secret metadata from the external env file, or from the driver's
  own Mac process environment only when that name is absent from the file.
  File values win even when empty or invalid; credentials never use this fallback.
  Account and profile must match `^[A-Za-z0-9][A-Za-z0-9-]{1,63}$`.
  Endpoint must be exactly `https://<region>.codesigning.azure.net`, with a
  lowercase region matching `^[a-z]{2,8}$`. When absent from both the file and
  environment, the Mac uses `https://neu.codesigning.azure.net` and sends it
  explicitly over stdin; the VM still requires and validates the endpoint.
  For example, export `AZURE_SIGNING_ACCOUNT='<account>'` and
  `AZURE_SIGNING_PROFILE='<profile>'` with the actual non-secret names before
  invoking the driver; this example uses the default endpoint. The placeholder
  brackets are not literal input.
  Mac preflight validates all three before locking and reports only an invalid
  variable's name. The VM validates them again. They share the credential stdin
  payload and never appear on the SSH command line or in driver diagnostics.
  Tenant, client ID and client secret each require a non-empty canonical name
  or its KVT/KVI/KVS alias before taking the VM lock; empty quotes do not count.
  A non-empty unquoted canonical value takes precedence, even if it is only
  whitespace and therefore rejected. Only an empty canonical value uses its
  alias; the VM repeats the same non-blank effective-value check with `.Trim()`.
- `VOXCLIP_GITHUB_REPO` (or the spec's `GITHUB_REPO`): defaults to `Siim/voxclip`.

The pinned Velopack 1.2.161 CLI uses the documented single-file `{{file}}`
signing template with an explicit `-Paths` argument. The `{{file...}}` template
in the release spec fails for Setup signing in this version and is not used.
Its local `assets.<channel>.json` uses `RelativeFileName`; feed entries use
`FileName`. The owner's certificate spells the publisher with an Estonian
umlaut. Publisher checks normalize that spelling to `Haugas Development OU`,
while signature evidence preserves the exact certificate subject in UTF-8.

The default VM workspace is `C:\voxclip-build\win-release`;
`VOXCLIP_WIN_BUILD_DIR` overrides its parent. The shared `vm.lock` protects all
VM work. Each invocation generates a random owner token separate from the run
directory ID, including on resume. Acquisition writes it into `vm.lock.<owner>` and atomically
renames the directory to `vm.lock`. Contention waits for at most 35 minutes.
No lock is ever taken over, regardless of age; on expiry the owner and age are
reported for a human to resolve. Cleanup removes only a lock with our owner.
Acquisition timeouts and SSH transport failures retry within that deadline;
an owner check keeps retrying after ambiguous replies, including later contention,
to recover our own acquisition. Cleanup attempts an owner-checked release only
after acquisition succeeds or remains uncertain, never after definite contention
alone. A first-attempt exit 74 in uncertain-acquisition cleanup stays silent
and never removes a foreign lock.
Diagnostics include the run ID, invocation owner and lock path.
After ambiguous acquisition, exit cleanup retries transport failures at most
three times with 20/40-second backoff. Successful release and first-attempt 74
stay silent; only exhausted transport retries produce the ambiguous-cleanup
WARNING. A later 74 after 124/255 follows the lost-reply rule below.
An ownership heartbeat retries transport failures three times, 20 seconds apart,
but aborts immediately when the owner check fails. Other tracks need no heartbeat.
After copy-back hashes pass, the driver stops and reaps its heartbeat, cleans
remote process metadata and releases its lock. Source creation, manifest work
and uploads then run on the Mac without requiring the VM to remain available.
Cleanup and Release each retry transport exits 124/255 at most three times with
20/40-second backoff. A final failure prints a CRITICAL lock-retained diagnostic;
cleanup does not silently retry it again at exit. The already hash-verified Mac
source, manifest and upload steps still finish, then the driver exits 75 and
reports that the VM lock needs human inspection.
If Release returns 74 after an earlier ambiguous 124/255, the driver describes
the current lock and reports a lost release reply instead of a retained lock;
Mac work continues without exit 75. A first-attempt 74 keeps the CRITICAL path.

After taking the lock, the driver deletes **older runs in this track's runs
directory**, including stale publish trees, before checking for 10 GiB free.
Copy any wanted older results off the VM first. It never touches
`C:\superscribe-build`. Velopack is a local tool under this track's tools folder,
pinned to the application's `Directory.Packages.props` version. The expected
repository tool manifest is not present in the skeleton, so no global tool or
unpinned install is used as a fallback.

## Credential lifetime and failure handling

Dirty and skeleton source archives enumerate only the staged source paths with
`git ls-files -z --cached --others --exclude-standard -- <staged paths>`, piped
to an isolated validator before `tar --null -T <validated list> --no-recursion`.
Git ignore rules exclude ignored files, including ignored hard links. Independently,
staging rejects secret-like names case-insensitively: `*.env`, `.env*`,
`azure-signing*`, `*.pfx`, `*.p12`, `*.cer`, `*.key`, `*.pem` and `signing/`
components. It reports the offending path without creating an archive. Matching
tar exclusions provide a second layer even when deeper ignore negations apply.
The validator omits tracked paths deleted from the working tree but still in the
index, so dirty and skeleton staging archive the files that actually remain.
Paths outside the staged roots and unlisted directory contents never enter it.
The driver regression suite includes an untracked nested Git repository: only its
listed directory entry may be archived, never its files or `.git` contents.

Never enable shell tracing or print/source the env file. Per ADR-R7, the Mac
uses `python3 -I` to read bytes, strip a leading UTF-8 BOM and normalize CR/CRLF
before matching exact assignments to the nine allowed names. Unrelated lines
are skipped without decoding; allowed lines must be valid UTF-8. Each value is
one quoted or unquoted shell word on one line; malformed allowed assignments
report the variable name only. Other parsing failures use one fixed message,
never exception text, bytes or offsets. The complete set is validated and
UTF-8-encoded in memory before a single binary write, including validation-only
preflight, so a later failure cannot stream a partial set. Grep options cannot
expand the stream.
Every driver Python invocation uses `-I`, including `release-assets.py` and
heredocs. Planted launch-directory modules cannot run even with an empty or
relative `PYTHONPATH` entry. Child processes do not inherit `VOXCLIP_SIGNING_ENV`.
No env file or credential value is copied to VM disk or passed in SSH arguments.
The VM reads stdin once into memory, **before building or downloading**. It accepts the standard
`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` names and the legacy
`AZURE_SIGNING_KVT`, `AZURE_SIGNING_KVI`, `AZURE_SIGNING_KVS` aliases.
Other variables never leave the Mac; no Superscribe Python helper is used.
Legacy account/endpoint aliases are deliberately ignored; only the three
documented tenant/client/secret aliases are accepted.

Credentials remain in memory only. Only non-secret metadata is written as ASCII JSON.
Build-server reuse and shared compilation are disabled. Build servers are shut
down before Azure environment variables are set. Those variables exist only
inside signing/packing `try/finally`, and are removed before package verification
and installation. The x64 signing runtime override is scoped to the signing
wrapper, not the ARM64 Velopack host. Existing valid publisher signatures stay
intact, including third-party signatures without timestamps. Unsigned PEs and
owned files with invalid or missing RFC 3161 timestamps are signed in batches
of 50 and verified afterwards. A valid-but-untimestamped owned signature is
re-signed on resume; invalid third-party signatures fail verification untouched.
Before signing, both channels download the prior public Velopack release as a
delta base. A failed download is tolerated only after GitHub confirms there is
no latest published release and the repository itself is accessible. Network,
API and download failures with an existing release stop packaging.

Every SSH call and SCP transfer is bounded. Long steps run in the background
with an interruptible Bash `wait`. The cleanup trap disables its EXIT trap and
ignores further INT, TERM and HUP signals during bounded cleanup. It first stops
and reaps the heartbeat, terminates the active timeout process, then stops the
recorded remote process tree, removes non-secret
metadata, and finally releases its own lock. PID and start
time must both match before a process is killed. A failed cleanup is a loud,
nonzero failure; failed remote process cleanup retains the lock for inspection.
PowerShell independently clears Azure variables and private metadata in `finally`.

## Verification and artifacts

Results land in `apps/windows/build/.release/<UTC-run-id>/` (git-ignored):

- `upload/`: both Setup.exe files, both feeds, feed-listed packages,
  `SHA256SUMS-windows.txt`; production builds also contain
`VoxClip-win-ffmpeg-source.tar.xz`.
- `evidence/verification.json`: version, source commit, SDK, Velopack version,
  verification status, and the non-uploadable test-build bit.
- `evidence/<rid>/*-signatures.json`: path, signer subject, certificate
  thumbprint, timestamp subject, RFC 3161 presence and SHA-256 for every PE in
  payload, Setup, package and installation.
- `evidence/<rid>/install-test.json`: actual install path and CLI version.
- `evidence/<rid>-ffmpeg.json`: results of calling `avcodec_configuration()` and
  `avcodec_license()` from the actual shipped DLL with a matching-architecture
  executable. GPL, nonfree, nonshared and non-LGPL builds fail.
- `vm-release.log`: build and verification output, never credential values.

Every PE is verified using both Authenticode and `signtool verify /pa /all`.
Every owned signature must also have a timestamper certificate and the RFC 3161
unsigned attribute in the embedded PE signature; legacy timestamps do not pass.
The installer signer must contain `Haugas Development OU`. Packages are expanded
and checked. Silent installs use `--silent --installto <unique temp directory>`,
verify shipped files and signatures, require the exact CLI version and installer
architecture, then uninstall and remove the temp directory, including on failure.
An existing real installation is not touched. Tests check that existing
`%LOCALAPPDATA%\VoxConvo\VoxClip` data is unchanged. No settings or models are deleted.
Before Setup starts, `out/evidence/<rid>/install-root.json` records the unique
install root. The marker is deleted only when cleanup succeeds. After stopping
the remote process tree, driver cleanup handles every marker in this run only:
bounded uninstall, process cleanup, root removal, then marker deletion. It never
sweeps unmarked temp installs or other runs. Failed cleanup retains the marker
and VM lock for inspection; the remote cleanup call has a 600-second limit.
Setup has its own 300-second timeout, CLI `version` has 60 seconds, and uninstall has a 180-second timeout;
the wait targets the installer process, not a possibly long-lived GUI child.

Copied-back files are hash-checked against the VM checksum list. After local
source and manifest checks, installed `osslsigncode` verifies both Setup files
before upload; a missing tool is skipped with a notice. `--upload-only` also
runs this optional check on retained installers. Local cleanup
restores directory permissions with `chmod -R u+rwX` before `rm -rf`.

Aggregate failures include the original verification error and
every cleanup error in the outer message, including on Windows PowerShell 5.1.
On a failed remote run, exit cleanup copies only `out/evidence` back to the Mac
with a 60-second timeout before remote cleanup; it never copies `private`.
Install cleanup waits up to 60 seconds for every process under the temporary
install root, including `Update.exe`. A failed app kill never skips uninstall.
After a wait timeout, cleanup force-stops all remaining root-matched processes,
records their IDs, and waits another 10 seconds before removing the folder with
at most five attempts two seconds apart, rechecking existence on every attempt.
`install-test.json` is written on success and failure,
with cleanup outcomes and errors. A verification error remains the first error
when cleanup also fails; neither is hidden. The local suite uses a fake updater
that keeps its executable open for three seconds, plus failure-path fixtures.

## Integration gates owned by other tracks

- `build/ffmpeg.json` must use `voxclip-ffmpeg/2`, with the local ZIP name,
  size and SHA-256 for both RIDs, `buildInputsSha256`, two matching clean-build
  reports, six ABI DLL majors, generated licence/notice evidence and the pinned
  source/build-tool archives. `testTools` is test-only and never transferred to
  release packaging. The release driver stages these inputs before VM locking;
  the VM checks the transfer receipt and local ZIP rather than downloading one.
  The corresponding-source archive contains the release commit's recipe, pin,
  build notes, original source/build-tool archives and selected AMF subset.
  See `doc/release.md` section 3.3 for the staging and archive contract.
- `src/VoxClip.App/Assets/VoxClip.ico` must exist for production packaging.
- The skeleton has no `.config/dotnet-tools.json` or `CHANGELOG.md`. Production
  requires a changelog section for the current version, which is passed to
  Velopack as release notes. A repository local-tool manifest remains an
  integration follow-up; implementation changes stay in this track's release
  tooling in `build/`. The lead separately accepts `doc/release.md` wording
  changes in the asset table and sections 3.2/3.6 as a scoped exception.
- The root `THIRD_PARTY_NOTICES.md` now contains the audited Windows package
  texts and pinned Velopack Setup/Update/stub source notices. The release flow
  checks its bytes in each full package and installed app; the older local
  signed installer predates those notices and does not verify this payload.

Local checks (wrap each command in `timeout`):

```sh
bash -n apps/windows/build/release-windows.sh
bash -n apps/windows/build/release-driver-common.sh
shellcheck apps/windows/build/release-windows.sh apps/windows/build/release-driver-common.sh
python3 apps/windows/build/test-release-assets.py
python3 apps/windows/build/test-release-driver.py
pwsh -NoProfile -File apps/windows/build/test-release-tools.ps1
```

## Lead reconciliation

Remaining deliberate differences from `doc/release.md`, sections 3.1-3.5 and
section 4 step 6:

1. The signer is `Sign-Artifacts.ps1` with `-Paths`, `-VerifyOnly` and optional
   evidence output, rather than `sign-if-needed.ps1`. All callers use this one
   implementation; no duplicate wrapper is kept.
2. Velopack 1.2.161 requires the single-file `{{file}}` template here, not the
   spec's `{{file...}}`; the latter failed installer signing in prior VM testing.
3. The legal certificate publisher contains an Estonian umlaut. Exact certificate
   subjects remain in evidence; comparisons normalize to `Haugas Development OU`.
4. The missing repository tool manifest prevents `dotnet tool restore` today.
   The driver installs `vpk` in the track-local tools directory using the version
   already pinned in `Directory.Packages.props`, never a global/latest tool.
   Switch to manifest restore once the owning track supplies it.
5. Configuration goes through a credential-free JSON file and `-Config`, not the
   reference script's individual arguments. VM source/output/metadata live under
   `VOXCLIP_WIN_BUILD_DIR\win-release\runs\<id>`; Mac outputs live under
   `build/.release/<id>` rather than `apps/windows/dist`. This isolates attempts,
   supports evidence and skeleton retries, and keeps the shared lock at the parent.
6. Additional test/override flags, optional `--upload-only DIR`, the `latest`
   symlink, `VOXCLIP_TIMEOUT`, `VOXCLIP_BUILD_TIMEOUT`, `VOXCLIP_VM_DOTNET` and
   `VOXCLIP_VM_SIGNING_DOTNET_ROOT` support bounded testing and the VM's separate
   x64 signing runtime. Defaults still upload to a draft, never publish.
7. `configure` accepts an exact per-RID object in addition to a string. Source
   assets require data-driven `component` identifiers; both configure lines are
   written to `BUILD.txt`. Transitive source coverage still needs pin-owner review.
8. The schema-2 consumer replaces the old BtbN shipping assumptions:
   `release-assets.py` stages verified local ZIPs and corresponding source;
   `vm-release.ps1` requires that stage. The separately pinned BtbN `testTools`
   archive remains solely for tests and is never a release input. Historical
   notes below describe earlier rounds and are not release instructions.
9. Section 3.3's file-only signing metadata preflight is superseded: account,
   profile and endpoint fall back to the Mac process environment only when
   absent from the file. File values win; all three must match the exact
   patterns in Prerequisites and overrides before locking and again on the VM.
   Section 3.2 records the restored endpoint default on the Mac only: file, then environment,
   then `https://neu.codesigning.azure.net`. Always send the validated endpoint
   explicitly to the VM, which still requires it. Only `<account>` and `<profile>`
   placeholders belong in examples; real names stay out of the repository.
   These values share the credential stdin payload, never SSH argv, and
   diagnostics identify only an invalid variable name.
10. Section 3.3's `tools/release/check-version.sh` is absent in this checkout.
    `release-assets.py version` reads/validates the Windows version, and an
    inline `plistlib` check compares the macOS version for production builds.
    The lead must reconcile that listing rather than add a duplicate helper.
11. The string-prefix containment in 3.3 is replaced by resolved-path
    device/inode ancestor comparisons and rejection of `st_nlink > 1` files.
    Production still archives the release tag. Dirty/skeleton archives instead
    pipe `git ls-files -z --cached --others --exclude-standard -- <staged paths>`
    through an isolated secret-name validator before non-recursive `tar --null -T`.
    Section 3.2 describes both secret-name layers: ignores alone are not a
    credential boundary. Reject secret-like names case-insensitively before
    creating an archive, and keep matching tar exclusions as defense in depth.
    Omit unstaged working-tree deletions from the validated list before tar.
    Staged roots are Windows, shared, license/notices and an existing changelog;
    ignored files and contents outside those roots are not recursively included.
12. The `grep -Eq` secret-only preflight and `grep|tr|ssh` transport in 3.3 are
    replaced by one byte-oriented, buffered Python allowlist parser. It handles
    BOM/CRLF, quotes and malformed UTF-8 without partial output or value leaks.
    Preflight validates each effective tenant/client/secret pair: a non-empty
    unquoted canonical value wins; only an empty one uses KVT/KVI/KVS. Blank
    effective values fail before locking, even with another valid alias.
    All Python invocations use `-I`, including asset helpers, and children no
    longer inherit `VOXCLIP_SIGNING_ENV`; grep environment options are discarded.
    Non-secret metadata follows item 9, not the listing's file-only checks.
13. The `ssh -o ConnectTimeout=5 ... echo connected` probe in 3.3 is omitted.
    Acquire is the first remote operation. SSH is batch-only with connect and
    keepalive limits; PowerShell uses UTF-16LE `-EncodedCommand` for non-secret
    commands, while credentials and signing metadata use stdin only. Active
    SSH/SCP/build steps and retry sleeps have explicit timeout/kill limits and
    interruptible waits rather than the listing's unbounded foreground calls.
14. Section 3.3 omits the shared atomic lock protocol, owner token, heartbeat
    and early release. Every invocation, including resume, has a fresh owner.
    Acquire 73 means contention and 124/255 means uncertain acquisition; owner
    checks retry within 35 minutes, never take over, and Describe on expiry.
    The heartbeat retries transport failures three times but aborts immediately
    on ownership loss. INT/TERM/HUP stop/reap work before owner-checked cleanup.
    After copy-back hashes, stop the heartbeat, clean the remote process/private
    metadata, and release before all Mac source/manifest/upload work. Cleanup
    and Release retry 124/255 three times with 20/40-second backoff, including
    exit cleanup after uncertain Acquire. Early-exit 0/74 is silent; exhausted
    uncertain cleanup warns. A later Release 74 after 124/255 describes current
    ownership and reports a lost reply, never a retained lock. A first-attempt
    normal Release 74 or exhausted normal cleanup keeps the CRITICAL path.
    Failed normal cleanup is not repeated at exit; Mac work finishes and exit
    75 identifies the lock needing human inspection. No VM is needed thereafter.
15. Section 3.3's `gh release upload "$DIST"/*` is not used. `upload-list` gates
    the constant Setup/feed/source/checksum names and feed-listed versioned
    full/delta packages against the manifest, version, commit and checksums.
    Evidence, local assets metadata, legacy feeds and portable ZIPs never upload.
    Missing drafts are created (pre-release where appropriate), draft status is
    checked before every bounded per-asset retry, and published releases refuse
    replacement. Upload-only rechecks hashes/signatures and requires production
    evidence; dirty/skeleton builds never become uploadable.
16. The corresponding-source listing in 3.3 is replaced by bounded helper
    downloads with complete source-pin validation, SHA-256 checks and manifest
    construction. Production pin/icon failures stop before locking. Copy-back
    includes evidence, and final hashes plus optional bounded `osslsigncode`
    verification precede upload and promotion of `.release/latest`; failures
    preserve the previous verified pointer. Skeleton exemptions are explicit
    non-uploadable tests, not production bypasses. Run/config layout, stale-run
    deletion, track-local tools and resume behavior are covered by items 4-6.

17. Reconcile the install-test cleanup contract: wait up to 60 seconds for all
    processes under the install root after uninstall, including `Update.exe`,
    then retry removal five times two seconds apart. Always retain install and
    cleanup evidence, and preserve the original error when cleanup also fails.
18. Section 3.3's hard-coded Windows SDK signtool path is superseded. Keep
    `VOXCLIP_VM_SIGNTOOL` as the override, otherwise discover the newest Windows
    Kits `10.0.26100.0` or later x64 tool, then the AzureTrustedSignTool `1.3.13`
    user-profile bundle. The bundle with the matching x64 dlib is an accepted VM
    prerequisite without a Windows SDK. Record its path and file version in evidence.

The lead owns updating the section 3.3 listing at merge. This track deliberately
leaves that listing unchanged; sections 3.2/3.6 describe the current safeguards.

Credentials, required host/file/account/profile inputs, build-root override,
default upload/draft creation, temporary smoke installs and delta download now
conform to the lead's requested contract. No disk credential transport remains.
For 0.1.0 the Claude Code/Codex connectors ship enabled (ADR-R20); confirming the
current lead decision is a release check, not a disable gate. Vendored reference
files and the clip-finder prompt are MIT per the lead's current decision.

## Round 8 local verification: 2026-10-25

Main `1db3af2` merged without conflicts, retaining the shared contracts. All
three suites passed twice against the completed release-tool changes:

- Asset suite: 20 tests per pass.
- Driver suite: 69 tests per pass, including evidence-only failure copy,
  interrupt cleanup, pre-lock local failures and independent tar exclusions.
- PowerShell suite: 41 tests per pass on the local PowerShell 7.5.4 runtime,
  including explicit outer error messages, install markers, kill and wait
  failures, an updater that Test-Install really waits for, bounded CLI calls,
  removal races, and fixture PE architectures for signtool and the dlib.
- Total: 130 tests per pass, 260 successful tests across both full passes.
- Bash syntax and ShellCheck pass for both shell scripts. Skeleton/no-upload,
  upload and upload-only dry runs pass without VM or signing access.

Only this track's existing section 3.2/3.6 lines in `doc/release.md` were edited.
No Windows PowerShell 5.1 or native installer run was performed in this round;
the lead owns the next skeleton run. Real signing env files were not accessed,
and no signing, uploads, pushes or history rewriting were performed. The old
history-only signing-name findings remain the lead's squash-only action.

## Round 6 pre-production verification: 2026-10-25

All eight binding lead decisions are implemented in separate fix commits:

1. Uncertain Acquire cleanup retries transport failures three times. The
   Acquire 255 / Check 255 / Release 255,0 fixture removes the lock after two
   Release events; exhausted retries warn only after three attempts.
2. A lost 124/255 Release reply followed by 74 describes current ownership,
   finishes with exit 0 and never reports a retained lock. First-attempt normal
   Release 74 still takes the CRITICAL path.
3. Canonical tenant/client/secret precedence agrees on Mac and VM. Whitespace
   canonical values with valid aliases fail all three pair regressions; empty
   canonical values still use aliases. VM validation repeats `.Trim()` checks.
4. Multiply-linked signing files fail before locking/staging. Dirty and skeleton
   archives use Git's NUL-delimited list, with tests for ignored arbitrary names,
   ignored hard links, outside-root files and space/newline filenames.
5. Lead reconciliation records the complete driver/listing differences.
   Section 3.3 is byte-for-byte unchanged from the round-5 baseline `8c0de28`.
6. The resumed-lock SIGINT test waits for a subprocess event marker and cleans
   its isolated process group. Ten extra repetitions cover 30 acquisition cases.
7. Every driver Python invocation uses `-I`, including asset helpers. Static
   checks and planted-module tests with `PYTHONPATH=:`, `.` and `:/nonexistent`
   pass; child SSH processes do not inherit the signing-file path.
8. Non-secret signing metadata falls back to Mac process values only when
   absent from the file. File precedence, exact validation boundaries, name-only
   failures, alias-only credential files and stdin-only fake SSH capture pass;
   the VM independently validates account, profile and endpoint again.

Two consecutive final verification passes each report **20 asset tests +
57 driver tests + 16 PowerShell tests = 93 passing tests, no skips**: **186**
passing test executions total. Both shell files pass `bash -n` and ShellCheck
in each pass. Skeleton, upload and upload-only dry runs all pass in both passes
with signing-file and VM-host variables unset, without remote side effects.

PowerShell coverage uses the SHA-256-verified PowerShell 7.5.4 macOS ARM64
runtime, not Windows PowerShell 5.1 or native installer evidence. The temporary
runtime/archive and all synthetic credential/test directories are removed.
No VM access, real credential-file access, real signing/packaging/upload,
GitHub CLI operations, pushes or merges were performed.

## Round 5 security verification: 2026-10-25

The lead's round-5 decisions are implemented and covered locally:

- Fresh invocation owners protect resumed run directories. Old run-ID locks
  survive acquisition exits 73/255/124 and SIGINT during each wait; a lost
  Acquire reply and failed first Check recover after a later 73/Check.
- Remote cleanup and Release retry 124/255 with bounded 20/40-second backoff.
  Exhaustion retains the lock without an exit-trap retry, finishes Mac source,
  manifest and requested upload work, then returns 75 with a human-inspection
  summary. Definite ownership loss is not retried.
- Filesystem device/inode containment rejects symlinked and case-variant paths
  before staging or SSH. The case-insensitive filesystem regression ran here.
- The byte-oriented credential filter ignores unrelated Latin-1, handles a
  leading BOM, reports invalid allowed UTF-8 by name, and emits nothing on a
  forced mid-filter exception. UTF-8 encoding and I/O failures never disclose
  exception text, offsets or values; output is buffered before one write.
- Every non-allowlisted FFmpeg enable flag requires corresponding source.
  Missing vaapi/libva, Vulkan and pthreads source fails before download; a
  separate read-only probe of win-ffmpeg-pin's current BtbN configure lines
  confirms rejection for both RIDs when those components are missing.
- Empty-quoted signing identities and secrets fail Mac preflight, with either
  canonical names or the existing aliases accepted when non-empty.
- All driver Python heredocs run isolated. Planted re/json/plistlib modules in
  the launch directory never execute in the filter or the three driver modes.
- Final hash or optional signature failure never promotes `.release/latest`
  and preserves any previous verified pointer.
- The asset table and sections 3.2/3.6 of `doc/release.md` match these changes
  under the lead's accepted scope exception. No other `doc/` files changed.

Final bounded verification: **20 asset tests + 47 driver tests + 12 PowerShell
tests = 79 passing tests, no skips**. Both shell files pass separate `bash -n`
checks and ShellCheck. Skeleton, upload and upload-only dry runs all pass
without VM or upload access; the read-only BtbN configure probe also passes.

PowerShell tests use a SHA-256-verified PowerShell 7.5.4 archive and an extracted
92 MiB subset with the installed .NET 10.0.2 runtime. This is local compatibility
coverage, not Windows PowerShell 5.1 or native installer evidence. The archive,
subset, runtime links and diagnostic scratch were deleted after verification;
all synthetic test-fixture directories are also removed by their suites.
No VM access, real credential-file access, real signing/packaging/upload or
GitHub CLI operations were performed this round.

## Round 4 verification: 2026-10-25

All 17 review minors are covered by eight fixes: credential filtering (3, 7,
12, 14), physical containment (4), early VM release (0, 6, 10), repeated-signal
cleanup (1, 16), ambiguous acquisition (2, 5, 11, 15), hardware source coverage
(8), optional Mac signature verification (9), and this README/cache correction
(13). Each logical fix has its own commit.

Bounded local verification passed:

- Asset suite: **17 tests**, including missing hardware source rejected before
  downloads and complete nv-codec-headers/AMF/libvpl archive coverage.
- Driver suite: **28 tests**, with fake signing fixtures, SSH/SCP, GitHub and
  signature tools. Coverage includes hostile grep options, lone CR, malformed
  values, symlink containment, early release, post-copy-back VM failure,
  double SIGINT, uncertain acquisition, deadlines and untouched foreign locks.
- PowerShell suite: **12 tests**, using cached PowerShell **7.5.4** with the
  installed **.NET 10.0.2** shared runtime. Only a **29 MiB** runtime subset was
  extracted, without downloading a runtime. This is a local compatibility
  check, not native Windows PowerShell 5.1 or real signing/installer evidence.
- Separate `bash -n` invocations: **2 files**; ShellCheck: **2 files**.
- Skeleton/no-upload and upload dry runs passed, plus upload-only dry run;
  the driver suite also proves all three avoid credentials and remote tools.

Total: **57 local tests passed**. The old approximately 71 MB compressed test
runtime, its checksum list, empty runtime folder and minimal reused runtime
were removed from `.release/tools`. No VM SSH, real credential access, signing,
packaging, uploads or GitHub commands ran. Existing incomplete production pin
and missing release-icon findings remain other-track integration gates.

## Round 3 verification: 2026-10-25

Local verification passes, with each command bounded by `timeout`:

- Bash syntax and ShellCheck: both driver shell files.
- `test-release-assets.py`: 15 tests, including complete/incomplete source pins,
  direct external components per RID, hashes, atomic archives and upload gates.
- `test-release-driver.py`: 8 tests, including synthetic SSH stdin filtering,
  no env-file SCP or credential argv, TERM/INT cleanup timing, ownership retries,
  required inputs, draft creation safety and temporary-install wiring.
- `test-release-tools.ps1`: 12 tests on a temporary PowerShell 7.5.4 Mac runtime,
  including delta outcomes, RFC 3161 parsing/signing/evidence, untouched publisher
  signatures, exact CLI architecture, atomic locks and ASCII/parser checks.
- Skeleton and upload dry runs: pass without SSH or GitHub mutations. The real
  incomplete FFmpeg pin still fails the production source gate.

Total: 35 local tests passed. This is not Windows PowerShell 5.1 or native
installer verification. A cached test-runtime archive, checksum list and empty
runtime directory remained in `.release/tools` after round 3. Round 4 reused
only a minimal runtime subset, then removed that subset and the leftover cache.
No publish tree, installer output or worktree was duplicated for round 3.
No ENOSPC failure occurred.

The VM remained unreachable throughout bounded probes from 07:30 to 08:31 UTC,
at least five minutes apart. Every SSH probe timed out. No skeleton run could
start, no VM lock was acquired, and no real signing credentials were read or
transported in this attempt. The post-run name-only credential-file listing was
**not obtained**; an empty listing cannot be claimed.

Pending once the VM is started:

1. Run exactly one `release-windows.sh --skeleton-test --no-upload`, with required
   `VOXCLIP_WIN_HOST` and external `VOXCLIP_SIGNING_ENV` set and an outer timeout.
   This must prove real stdin transport, dual-RID signing/timestamp checks,
   packaging, isolated install/uninstall and copy-back hashes. The driver waits
   up to 35 minutes for its atomic lock; never remove another worker's lock,
   even if it predates the VM's boot. The lead must resolve that condition.
2. Obtain a complete, name-only listing under `C:\voxclip-build` for `*signing*`,
   `*.env`, `.env*`, `*credential*` and `*secret*` files, never their contents.
3. Confirm the driver's cleanup released only its own lock. Native PowerShell
   5.1 parsing and actual signtool/Velopack behavior remain unverified here.

Mac notarization remains pending under the locked-screen instruction; no retry,
GUI launch or workaround was attempted. No uploads, pushes, merges or GitHub
mutations occurred. Older commit messages were not rewritten, as instructed;
new fix commits have spec/ADR bodies and no attribution trailers.

## Verified skeleton run: 2026-10-25

Run ID: `20261025T015300Z-37984`. All four Release/self-contained publishes
completed on the ARM64 Windows 11 VM: App and CLI for each RID. Published source
commit: `9262fb610cbc70ea0cad5490d5a3c4dbaac084b2`; later release-tool fixes were
applied with the non-uploadable resume path, without changing App/CLI source.
SDK: `10.0.402`. Velopack: `1.2.161`. No GitHub release was created or uploaded.

Both installers were silently installed into
`C:\Users\siim\AppData\Local\VoxClip`, checked, then silently uninstalled.
Installed CLI output was `VoxClip 0.1.0 (windows-x64)` and
`VoxClip 0.1.0 (windows-arm64)` respectively. Both install receipts record
`uninstalled: true` and `signingCredentialsAbsent: true`; pre-existing user data
under `C:\Users\siim\AppData\Local\VoxConvo\VoxClip` was unchanged.

Every PE in each category passed Authenticode and `signtool verify /pa /all`:

| RID | Payload PEs | Setup PEs | Full-package PEs | Installed PEs |
| --- | ---: | ---: | ---: | ---: |
| win-x64 | 563 | 1 | 564 | 564 |
| win-arm64 | 562 | 1 | 563 | 563 |

There are 37 owner-signed PEs in each payload and 39 owner-signed PEs in each
full package/installed tree. Valid third-party signatures were preserved.
Owner-signed payload files comprise the six FFmpeg DLLs; `FFmpeg.AutoGen.dll`,
`NAudio.Core.dll`, `NAudio.Wasapi.dll`, `Velopack.dll`, `Whisper.net.dll`;
`voxclip-cli.dll`, `voxclip-cli.exe`, `VoxClip.Core.dll`, `VoxClip.dll`,
`VoxClip.exe`, `VoxClip.Media.dll`; and 20 Whisper native PEs under the runtime
folders. The PE detector also signs the native PE named `whisper.ggml`, despite
its extension. Velopack's `Squirrel.exe`/installed `Update.exe`, execution stub,
and both Setup.exe files were signed and verified too. Complete per-file
subjects, thumbprints and hashes are in the signature JSON reports.

Both Setup signatures have this exact subject:

```text
CN=HAUGAS DEVELOPMENT OÜ, O=HAUGAS DEVELOPMENT OÜ, STREET=Kukesaba tn 2-1, L=Tallinn, C=EE, PostalCode=13516
```

Certificate thumbprint: `B0B3B4E5514CF5CF676420D90F219EF127E57284`.
Both have a Microsoft RSA timestamp. Both actual FFmpeg gates returned
`LGPL version 3 or later`, with `--enable-shared` and without `--enable-gpl` or
`--enable-nonfree`; the LGPLv3/GPLv3 texts and build notes were installed.

Local artifacts and evidence are under
`apps/windows/build/.release/20261025T015300Z-37984/`. VM results remain under
`C:\voxclip-build\win-release\runs\20261025T015300Z-37984\out` until another
release run cleans them. Every copied-back checksum passed twice.

| File in `upload/` | Bytes | SHA-256 |
| --- | ---: | --- |
| `VoxClip-win-x64-Setup.exe` | 191435560 | `6569a4f52e00dcdb6590e65da14e3ccb70bb9f0ebd5be86589ea910780263fbf` |
| `VoxClip-win-arm64-Setup.exe` | 165859616 | `5e2260f5c96d81741513912fdc940366965babe0e12d1a68db2d1de33b817dd0` |
| `VoxClip-0.1.0-win-x64-full.nupkg` | 183795914 | `99ab68ae7a1d3c90551e3b8009fc35ca40dd0880d2ccd3c5c7cc491606782f2f` |
| `VoxClip-0.1.0-win-arm64-full.nupkg` | 159826113 | `68e822f055cfa39becfb265479ccc6f619150948dd5e9d81b8ddce8eae53d63b` |
| `releases.win-x64.json` | 257 | `efb319d19e29fe16902b6e036059feb76010ae6f2978e40d0150d239e8b1c8fc` |
| `releases.win-arm64.json` | 259 | `4838dd3255d1a61d931259a8b6ae32bd9d6dbac08713532591568a399c127481` |
| `SHA256SUMS-windows.txt` | 564 | `d08ffe72e945cee267b3de324f60967a4b8ebaf3afad72affff9c462037d6fee` |

Additional verification: ten Python helper tests; Bash syntax and ShellCheck;
PowerShell parser checks; ASCII-only PowerShell scripts; actual native exit-code
preservation and timeout/process-tree cleanup tests. Missing credentials and
incomplete source pins fail closed. `evidence/upload-dry-run.txt` records the
draft-only upload plan; it made no network or signing calls.

The old 6.6 GiB of stale publish output was removed before this run, recovering
15.25 GiB free. Exit/failure cleanup paths were exercised during timestamp and
packaging failures. The final private folder is absent, both installations are
removed, and this run relinquished its VM lock. A newer lock directory observed
afterward was preserved rather than deleting another worker's claim; see
`evidence/cleanup.json`.

**These are not release candidates.** No
`VoxClip-win-ffmpeg-source.tar.xz` was fabricated: the existing unowned pin still
lacks `btbnCommit`, exact configure/licence metadata, and the complete
hash-pinned corresponding-source inventory. Source-archive generation itself
is tested with pinned synthetic downloads, including a linked dependency and
failure/atomic-replacement cases. The production gate rejects the real
incomplete pin before building. The missing release ICO, changelog, local tool
manifest and complete third-party notices are listed in the integration section.
This earlier run predates the round-3 transport/lock/smoke fixes. Its on-disk
credential transport is superseded by ADR-R7 stdin-only transport; it must not be
used as the implementation contract. Current implementation changes stay in
this track's release tooling; the lead has accepted the round-4/5
`doc/release.md` asset-table and sections 3.2/3.6 wording as an exception,
subject to review at merge. No other `doc/` files are changed this round.

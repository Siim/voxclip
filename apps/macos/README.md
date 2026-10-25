# VoxClip for macOS

SwiftPM skeleton for the native macOS app and headless CLI. Requires Apple silicon, macOS 26+, and Xcode with Swift 6.2+ and the macOS 26 SDK or newer. All targets use Swift 6 language mode.

## Build, run and test

From the repository root:

```sh
cd apps/macos
swift package resolve
swift build
swift build --product VoxClip
swift run VoxClip
swift test
swift run voxclip-cli --help
swift run voxclip-cli export --help
swift run voxclip-cli models --help
swift run voxclip-cli version
```

The first resolve downloads the pinned argument parser and official whisper xcframework; no transcription model is downloaded. Package.resolved is part of this package. No Xcode project or SwiftPM resource bundle is needed.

The app has a Welcome window, document-based .voxclip editor windows, Settings and labelled empty transcript/preview/inspector/timeline regions. Opening/saving JSON documents works; importing media, editing algorithms, transcription, captions, clips and export await their owning implementation tracks. An untitled document has no imported media (an empty source reference); it does not read the root directory.

The CLI declares the complete architecture §9 command tree. Help/version are usable. The primary `--open ... --export ...` form routes to the default `export` command; the explicit `export` alias has the same options. Other commands fail safely with a redacted notImplemented error and exit 1 until their services are filled in. --json writes exactly one final object on stdout; diagnostics go to stderr. Bad argument values exit 2. No skeleton command starts a paid provider, downloads a model, launches a subscription CLI or writes export output.

## Shared resources and isolated data

SharedResources resolves VOXCLIP_SHARED_DIR, then Contents/Resources/shared, then a repository walk from the executable. It never uses Bundle.module and never copies shared assets here. Tests independently walk from #filePath and support the same environment override.

```sh
VOXCLIP_SHARED_DIR="$PWD/../../shared" swift test
VOXCLIP_DATA_DIR=/tmp/voxclip-dev swift run voxclip-cli models list --json
```

Without VOXCLIP_DATA_DIR, locations follow architecture §2.5 (Application Support/VoxClip, Library/Logs/VoxClip, Movies/VoxClip). Location resolution alone creates no files. CLI keys, when real connectors are implemented, come only from the documented API-key environment variables, never Keychain. Never put a key in a command argument or project.

## Parallel implementation

Read [CONTRACTS.md](CONTRACTS.md) for the complete public type/protocol index, ownership and dated conflicts. Replace your existing stubs in place and work only in your track's folders. The shared value contracts are frozen; propose changes in CONTRACTS.md before modifying them. Tests include fixture-backed schema round-trips, caption schema/default decoding, redaction, versions and non-destructive stub checks; six track placeholders are explicitly disabled.

The package has no signing, packaging or release script yet. The release/packaging owner must supply bundle.sh following doc/release.md, copy shared assets (excluding fixtures) and THIRD_PARTY_NOTICES.md into Contents/Resources, and use the existing Info.plist and camera/audio-input-only entitlements. No sandbox, signing credential or extra entitlement is introduced here.

## Licences

VoxClip is MIT. Dependencies and full applicable licence texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the About settings pane identifies both native dependencies. The whisper b5454 archive checksum is e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b. See CONTRACTS.md for the release selection and verification command.

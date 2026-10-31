# VoxClip

A free, fast clipper for talking-head video on macOS and Windows. You can bring your own keys or run local models.

VoxClip transcribes a take with word timestamps, so you cut by editing text. Filler words and long pauses come out in a click. It can find clips with your own LLM, burn captions in a range of styles and export for VoxConvo, X or LinkedIn.

> Status: early development. The first signed builds are being prepared.

| Folder | Purpose |
| --- | --- |
| `apps/macos/` | Native Swift/SwiftUI app |
| `apps/windows/` | Native .NET app for Windows |
| `shared/` | Caption styles, prompts, fonts and golden test fixtures used by both apps |
| `doc/` | Architecture and release documentation |

VoxClip is a side project of [VoxConvo](https://voxconvo.com).

## License

MIT. Bundled fonts and libraries keep their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Models are not bundled: they download when you ask, and the in-app model list shows each one's license. Windows builds use the LGPL FFmpeg libraries, and each release attaches their source.

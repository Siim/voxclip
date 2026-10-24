# VoxClip

A free, fast clipper for talking-head video on macOS and Windows. You can bring your own keys or run local models.

VoxClip transcribes a take with word timestamps, so you cut by editing text. Filler words, long pauses and retakes come out in a click. It can find clips with your own LLM, burn captions in a range of styles and export for VoxConvo, X or LinkedIn.

> Status: early development. The first signed builds are being prepared.

| Folder | Purpose |
| --- | --- |
| `apps/macos/` | Native Swift/SwiftUI app |
| `apps/windows/` | Native .NET app for Windows |
| `shared/` | Caption styles, prompts, fonts and golden test fixtures used by both apps |
| `doc/` | Architecture and release documentation |

VoxClip is a side project of [VoxConvo](https://voxconvo.com).

## License

MIT. Bundled fonts and models keep their own licenses; see `shared/fonts` and the in-app model list.

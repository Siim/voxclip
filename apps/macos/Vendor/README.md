# Vendored packages

## onnxruntime-swift-package-manager

This is Microsoft's ONNX Runtime Swift package, tag `v1.19.2`, commit `bbc428e168a0374eb7d0503cdb7c73fdc1d99751`, MIT licensed (see its `LICENSE`).

**Why it's here.** Since about 2026-11-17, GitHub answers "Repository not found" for `microsoft/onnxruntime-swift-package-manager`, as it does for `microsoft/onnxruntime` and several sibling repositories. Microsoft hasn't given a reason or named a replacement. SwiftPM can't clone a package that's gone, so on a runner with no cache, `swift package resolve` fails.

**How it was copied.**
- Taken from a SwiftPM repository cache that was cloned before the takedown: `git archive bbc428e1…` of that clone, unchanged.
- No file was added, removed or edited.

**How to check it.**
- In a commit that contains this folder, `git rev-parse <commit>:apps/macos/Vendor/onnxruntime-swift-package-manager` should print `253e76aa37eeb75382e3313852d5d6405658437f`. That is the tree of upstream commit `bbc428e1`.
- The package's `Package.swift` still downloads the runtime binary from `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.19.2.zip`. SwiftPM checks it against SHA-256 `28787ee2f966a2c47eb293322c733c5dc4b5e3327cec321c1fe31a7c698edf68`, so the bytes that are linked are the same as before.

**When Microsoft's repository is back.** Go back to `.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.19.2")` in `apps/macos/Package.swift` and delete this folder.

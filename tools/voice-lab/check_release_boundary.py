import argparse
import pathlib
import platform
import subprocess
import tempfile


def check(bin_path, build_path):
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    flags = [compiler, "-typecheck", "-swift-version", "6", "-package-name", "macos", "-sdk", sdk,
             "-target", platform.machine() + "-apple-macosx26.0", "-I", str(bin_path),
             "-I", str(bin_path / "Modules"), "-F", str(bin_path), "-F", str(bin_path / "PackageFrameworks")]
    maps = sorted(build_path.rglob("*OnnxRuntimeBindings*.modulemap"))
    maps += sorted(build_path.glob("**/OnnxRuntimeBindings.build/module.modulemap"))
    if maps:
        selected = next((item for item in maps if "GeneratedModuleMaps" in item.parts), maps[0])
        flags += ["-Xcc", "-fmodule-map-file=" + str(selected)]
    header = """import Foundation
import VoxClipCore
@_spi(Testing) import VoxClipMedia
#if DEBUG
#error("Release boundary probes must not enable DEBUG")
#endif
struct Fake: SpeakerEmbedder {
    let modelID = "forged"
    let dimension = 2
    func embed(_ pcm16k: [Float]) async throws -> [Float] { [1, 0] }
}
"""
    probes = {
        "debug-injection": "let check = VoiceSpeakerCheck(embedder: Fake(), calibratedThreshold: 0)",
        "package-injection": 'let check = VoiceSpeakerCheck(verifiedEmbedder: Fake(), calibratedThreshold: 0, language: "en")',
        "arbitrary-threshold": 'func bypass(_ model: ONNXSpeakerEmbedder) { _ = VoiceSpeakerCheck(verifiedEmbedder: model, calibratedThreshold: 0, language: "en") }',
        "capability-construction": "func bypass(_ quote: VoiceLabQuote) { _ = VoiceOperationCapability(quote: quote, validate: {}) }",
        "policy-capability": "func bypass(_ policy: OwnVoicePolicy, _ quote: VoiceLabQuote) { _ = policy.authorized(for: quote, validate: {}) }",
    }
    with tempfile.TemporaryDirectory(prefix="voxclip-release-boundary-") as directory:
        source = pathlib.Path(directory) / "Probe.swift"
        source.write_text(header + "let check = VoiceSpeakerCheck()\nlet hash = VoiceLabFingerprint.bytes(Data())\n")
        positive = subprocess.run(flags + [str(source)], capture_output=True, text=True)
        if positive.returncode:
            raise RuntimeError("Release control probe failed; this is not boundary evidence:\n" + positive.stderr)
        for name, probe in probes.items():
            source.write_text(header + probe + "\n")
            result = subprocess.run(flags + [str(source)], capture_output=True, text=True)
            if not result.returncode or "error:" not in result.stderr:
                raise RuntimeError("Release boundary unexpectedly accepted " + name)
            if any(message in result.stderr for message in ["no such module", "missing required module", "could not build module"]):
                raise RuntimeError("Release probe failed for an import, not access control: " + name)
            print("Rejected Release bypass: " + name)
    print("Release control and five same-package access-boundary probes passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Check the built Release speaker/capability boundary without linking, audio or HTTP.")
    parser.add_argument("--bin-path", type=pathlib.Path, required=True)
    parser.add_argument("--build-path", type=pathlib.Path, default=pathlib.Path("apps/macos/.build"))
    args = parser.parse_args()
    check(args.bin_path.resolve(), args.build_path.resolve())

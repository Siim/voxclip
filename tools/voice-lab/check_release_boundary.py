import argparse
import pathlib
import platform
import subprocess
import tempfile
from release_source import scan


def same_module_source():
    source = pathlib.Path(__file__).resolve().parents[2] / "apps/macos/Sources/VoxClipMedia/VoiceLab/VoiceSpeakerCheck.swift"
    declaration = source.read_text().split("public actor VoiceUseGuard", 1)[0]
    if "public final class VoiceSpeakerCheck" not in declaration:
        raise RuntimeError("Cannot locate production speaker-check declaration")
    return declaration + """
public actor ONNXSpeakerEmbedder: SpeakerEmbedder {
    public nonisolated let modelID = "verified-model-control"
    public nonisolated let dimension = 256
    public func embed(_ samples: [Float]) async throws -> [Float] { [] }
    func validateIdentity(trustedEntry: SpeakerModel) throws {}
}
"""


def check(bin_path, build_path):
    scan(pathlib.Path(__file__).resolve().parents[2])
    with tempfile.TemporaryDirectory(prefix="voxclip-release-source-control-") as directory:
        fixture = pathlib.Path(directory) / "AnotherModule.swift"
        fixture.write_text("final class VoiceSpeakerCheck {\nprivate init() {}\npackage init(control: Int) {}\n}\n")
        try:
            scan(pathlib.Path(directory))
        except RuntimeError:
            print("Source scan rejected the non-private initializer positive control.")
        else:
            raise RuntimeError("Release source scan accepted its positive control")
    print("All-module Release initializer source scan passed.")
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
        source.write_text(header + "let check = VoiceSpeakerCheck.unavailable\nlet hash = VoiceLabFingerprint.bytes(Data())\n")
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
        same_module = same_module_source()
        source.write_text(same_module + "let check = VoiceSpeakerCheck.unavailable\n")
        control = subprocess.run(flags + [str(source)], capture_output=True, text=True)
        if control.returncode:
            raise RuntimeError("Same-module Release control failed:\n" + control.stderr)
        for name, probe in {
            "same-module-raw-threshold": probes["arbitrary-threshold"],
            "same-module-private-construction": 'func bypass(_ model: ONNXSpeakerEmbedder, _ entry: SpeakerModel) { _ = VoiceSpeakerCheck(verifiedModel: model, trustedEntry: entry, language: "en") }',
            "same-module-debug-injection": probes["debug-injection"].replace("Fake()", "nil"),
        }.items():
            source.write_text(same_module + probe + "\n")
            result = subprocess.run(flags + [str(source)], capture_output=True, text=True)
            if not result.returncode or "error:" not in result.stderr:
                raise RuntimeError("Same-module Release boundary accepted " + name)
            print("Rejected Release bypass: " + name)
    print("Release controls, five same-package and three same-module probes passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Check the built Release speaker/capability boundary without linking, audio or HTTP.")
    parser.add_argument("--bin-path", type=pathlib.Path, required=True)
    parser.add_argument("--build-path", type=pathlib.Path, default=pathlib.Path("apps/macos/.build"))
    args = parser.parse_args()
    check(args.bin_path.resolve(), args.build_path.resolve())

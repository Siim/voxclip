import argparse
import pathlib
import platform
import subprocess
import tempfile
from release_source import scan, release_source, without_literals
import re


def check_staged_actions(root):
    pattern = re.compile(r'\b(?:publishForTests|prepareForTests|executeForTests|finishGenerationForTests|finishQuotePreparationForTests|voiceRecoveryForTests|DebugRewrite|DebugRewriteGeneration|showFixture|DebugVoiceLab)\b')
    for source in sorted(root.rglob('*.swift')):
        if '.build' in source.parts:
            continue
        if pattern.search(without_literals(release_source(source.read_text()))):
            raise RuntimeError('Release exposes a DEBUG Voice Lab hook: ' + str(source))


def same_module_source():
    source = pathlib.Path(__file__).resolve().parents[2] / "apps/macos/Sources/VoxClipMedia/VoiceLab/VoiceSpeakerCheck.swift"
    declaration = source.read_text().split("public actor VoiceUseGuard", 1)[0]
    if "public final class VoiceSpeakerCheck" not in declaration:
        raise RuntimeError("Cannot locate production speaker-check declaration")
    capability = source.with_name('VoiceOperationCapability.swift').read_text()
    policy = source.with_name('OwnVoicePolicy.swift').read_text()
    return capability + declaration + policy + """
public actor ONNXSpeakerEmbedder: SpeakerEmbedder {
    public nonisolated let modelID = "verified-model-control"
    public nonisolated let dimension = 256
    public func embed(_ samples: [Float]) async throws -> [Float] { [] }
    func validateIdentity(trustedEntry: SpeakerModel) throws {}
}
"""


def require_access_rejection(name, result, protection, symbol=None):
    diagnostic = (symbol + ' is ' if symbol else '') + "inaccessible due to '" + protection + "' protection level"
    if not result.returncode or diagnostic not in result.stderr:
        raise RuntimeError('Release probe did not prove ' + protection + ' access: ' + name + '\n' + result.stderr)
    if any(message in result.stderr for message in ['no such module', 'missing required module', 'could not build module']):
        raise RuntimeError('Release probe failed for an import: ' + name + '\n' + result.stderr)


PROOF_CALL = '''func forge(_ store: VoiceConsentStore, _ record: VoiceConsentRecord?, _ embedder: any SpeakerEmbedder) {
    _ = VoiceSpeakerMatch(recordID: "forged", cloneVoiceID: nil, store: store, record: record, statementHash: "forged", embedder: embedder)
}'''
POLICY_CALL = '''func bypass(_ policy: OwnVoicePolicy, _ quote: VoiceLabQuote, _ store: VoiceConsentStore, _ record: VoiceConsentRecord?, _ embedder: any SpeakerEmbedder) throws {
    _ = try policy.authorized(for: quote, proof: .init(recordID: "forged", cloneVoiceID: nil, store: store, record: record, statementHash: "forged", embedder: embedder))
}'''
CAPABILITY_CALL = '''func forgeCapability(_ policy: OwnVoicePolicy, _ quote: VoiceLabQuote) {
    _ = type(of: policy.capability!).init(quote: quote, reserve: nil, validate: {})
}'''


def check(bin_path, build_path):
    root = pathlib.Path(__file__).resolve().parents[2]
    scan(root)
    check_staged_actions(root / 'apps/macos/Sources')
    gate_source = (root / 'apps/macos/Sources/VoxClipCore/Domain/VoiceLab/VoiceConsent.swift').read_text()
    gate = re.search(r'public static func rewriteEnabled\([^}]+}', gate_source).group()
    with tempfile.TemporaryDirectory(prefix='voxclip-release-beta-') as directory:
        source = pathlib.Path(directory) / 'Gate.swift'
        binary = pathlib.Path(directory) / 'gate'
        source.write_text('enum Gate {' + gate + '}\n' + '''
for enabled in [false, true] {
 for notice in [false, true] {
  for debug in [false, true] {
   precondition(Gate.rewriteEnabled(enabled: enabled, noticeAccepted: notice, internalBuild: debug) == (enabled && (notice || debug)))
  }
 }
}
''')
        subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('Production beta gate passed all eight enabled/notice/build combinations.')
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
        "package-injection": 'let check = VoiceSpeakerCheck(verifiedModel: nil, trustedEntry: nil, language: nil)',
        "arbitrary-threshold": 'func bypass(_ model: ONNXSpeakerEmbedder, _ entry: SpeakerModel) { _ = VoiceSpeakerCheck(verifiedModel: model, trustedEntry: entry, language: "en") }',
        "capability-construction": CAPABILITY_CALL,
        "policy-capability": POLICY_CALL,
        "speaker-proof": POLICY_CALL,
    }
    with tempfile.TemporaryDirectory(prefix="voxclip-release-boundary-") as directory:
        source = pathlib.Path(directory) / "Probe.swift"
        source.write_text(header + 'let check = VoiceSpeakerCheck.unavailable\nlet hash = VoiceLabFingerprint.bytes(Data())\nlet action = VoiceLabEditCommand.delete(segmentID: "test")\n')
        positive = subprocess.run(flags + [str(source)], capture_output=True, text=True)
        if positive.returncode:
            raise RuntimeError("Release control probe failed; this is not boundary evidence:\n" + positive.stderr)
        for name, probe in probes.items():
            source.write_text(header + probe + "\n")
            result = subprocess.run(flags + [str(source)], capture_output=True, text=True)
            protection, symbol = {
                'capability-construction': ('internal', "'VoiceOperationCapability' initializer"),
                'policy-capability': ('internal', "'authorized'"),
                'speaker-proof': ('fileprivate', "'VoiceSpeakerMatch' initializer"),
            }.get(name, ('private', "'VoiceSpeakerCheck' initializer"))
            require_access_rejection(name, result, protection, symbol)
            print("Rejected Release bypass: " + name)
        same_module = same_module_source()
        source.write_text('\n'.join([same_module, PROOF_CALL, POLICY_CALL, CAPABILITY_CALL]) + '''
private extension VoiceSpeakerCheck {
    static func allowed(_ model: ONNXSpeakerEmbedder?, _ entry: SpeakerModel?, _ language: String?) {
        _ = VoiceSpeakerCheck(verifiedModel: model, trustedEntry: entry, language: language)
    }
}
let check = VoiceSpeakerCheck.unavailable
''')
        control = subprocess.run(flags + [str(source)], capture_output=True, text=True)
        if control.returncode:
            raise RuntimeError("Same-module Release control failed:\n" + control.stderr)
        fake = 'struct Fake' + header.split('struct Fake', 1)[1]
        source.write_text(same_module + fake + probes['debug-injection'])
        debug_control = subprocess.run(flags + ['-DDEBUG', str(source)], capture_output=True, text=True)
        if debug_control.returncode:
            raise RuntimeError('DEBUG injection control failed:\n' + debug_control.stderr)
        for name, probe in {
            "same-module-raw-threshold": probes["arbitrary-threshold"],
            "same-module-private-construction": 'func bypass(_ model: ONNXSpeakerEmbedder, _ entry: SpeakerModel) { _ = VoiceSpeakerCheck(verifiedModel: model, trustedEntry: entry, language: "en") }',
            "same-module-debug-injection": probes["debug-injection"].replace("Fake()", "nil"),
        }.items():
            source.write_text(same_module + probe + "\n")
            result = subprocess.run(flags + [str(source)], capture_output=True, text=True)
            require_access_rejection(name, result, 'private', "'VoiceSpeakerCheck' initializer")
            print("Rejected Release bypass: " + name)
        declaration = pathlib.Path(directory) / 'Speaker.swift'
        declaration.write_text(same_module)
        source.write_text('import Foundation\nimport VoxClipCore\n' + PROOF_CALL)
        result = subprocess.run(flags + [str(declaration), str(source)], capture_output=True, text=True)
        require_access_rejection('same-module-speaker-proof', result, 'fileprivate', "'VoiceSpeakerMatch' initializer")
        print('Rejected Release bypass: same-module-speaker-proof')
    print("Release/DEBUG signature controls, six same-package and four same-module probes passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Check the built Release speaker/capability boundary without linking, audio or HTTP.")
    parser.add_argument("--bin-path", type=pathlib.Path, required=True)
    parser.add_argument("--build-path", type=pathlib.Path, default=pathlib.Path("apps/macos/.build"))
    args = parser.parse_args()
    check(args.bin_path.resolve(), args.build_path.resolve())

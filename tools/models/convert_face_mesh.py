#!/usr/bin/env python3
"""Reproduce and check the bundled Face Mesh V2 ONNX file (apps/windows/models/frames/face_mesh_v2.onnx, ADR-R48 Windows).

  python3 tools/models/convert_face_mesh.py --work /tmp/voxclip-face-mesh
      Fetch the pinned MediaPipe bundle, check its SHA-256 and the TFLite inside it, convert the TFLite to ONNX with
      tf2onnx 1.17.0 (opset 17, batch fixed at 1), then check the conversion against the bundled file: the same inputs and
      outputs, the same operators in order and the same weights, and both within 1e-3 of the TFLite original on random
      inputs. Exit 0 when every check passes.
  python3 tools/models/convert_face_mesh.py --work /tmp/voxclip-face-mesh --from-pack
      Fetch the pinned Hugging Face pack, check its SHA-256 and write its "mesh" entry, which is byte-identical to the
      catalogued file, to <work>/face_mesh_v2.onnx.

tf2onnx names the constants it folds from a process-wide counter that depends on the TensorFlow version, so a local
conversion is the same graph with different constant names (4,920,952 bytes here with TensorFlow 2.21, 4,921,003 from the
tf2onnx command line, instead of 4,921,008; checked with TensorFlow 2.20 and 2.21). The committed bytes are therefore the pack's entry, and this tool proves they are the conversion of the
pinned TFLite. Needs: tensorflow 2.21.0, tf2onnx 1.17.0, onnxruntime 1.19.2, numpy (in a throwaway venv, not the repo).
Only the pinned public files below are downloaded.
"""
import argparse
import hashlib
import json
import pathlib
import struct
import sys
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOGUE = ROOT / "shared" / "catalog" / "frame-models.json"
BUNDLED = ROOT / "apps" / "windows" / "models" / "frames" / "face_mesh_v2.onnx"
TFLITE_ENTRY = "face_landmarks_detector.tflite"
PACK_URL = ("https://huggingface.co/NardoCreations/mediapipe-face-onnx/resolve/"
            "253c4f079ea8ec964c914ba6de237b7c62762197/mediapipe-face.pack")
PACK_SHA256 = "69f881ea5961e8b8fecc5076ae5c5559e284f7bc22c1859ed19900b9069e3b98"
OPSET = 17
PARITY = 1e-3
USER_AGENT = "VoxClip-tools/1.0 (https://github.com/Siim/voxclip)"


def landmarks_entry():
    catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))
    return next(file for file in catalogue["models"][0]["files"] if file["role"] == "landmarks")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, expected, path):
    if path.exists() and sha256(path.read_bytes()) == expected:
        return path.read_bytes()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    data = urllib.request.urlopen(request, timeout=120).read()
    if sha256(data) != expected:
        raise SystemExit(f"{url}: SHA-256 {sha256(data)} is not the pinned {expected}")
    path.write_bytes(data)
    return data


def from_pack(work, entry):
    data = fetch(PACK_URL, PACK_SHA256, work / "mediapipe-face.pack")
    if data[:4] != b"NCMP":
        raise SystemExit("The pack is not an NCMP container.")
    _version, count = struct.unpack_from("<II", data, 4)
    offset = 12
    for _ in range(count):
        (length,) = struct.unpack_from("<I", data, offset)
        name = data[offset + 4:offset + 4 + length].decode("utf-8")
        offset += 4 + length
        (size,) = struct.unpack_from("<I", data, offset)
        blob = data[offset + 4:offset + 4 + size]
        offset += 4 + size
        if name == "mesh":
            if len(blob) != entry["bytes"] or sha256(blob) != entry["sha256"]:
                raise SystemExit("The pack's mesh entry is not the catalogued file.")
            out = work / "face_mesh_v2.onnx"
            out.write_bytes(blob)
            print(f"ok wrote {out} ({len(blob)} bytes, SHA-256 {entry['sha256']})")
            return 0
    raise SystemExit("The pack has no mesh entry.")


def tflite_bytes(work, entry):
    source = entry["source"]
    bundle = fetch(source["bundle"], source["bundleSha256"], work / "face_landmarker.task")
    with zipfile.ZipFile(work / "face_landmarker.task") as archive:
        tflite = archive.read(TFLITE_ENTRY)
    if sha256(tflite) != source["tfliteSha256"]:
        raise SystemExit(f"{TFLITE_ENTRY}: SHA-256 {sha256(tflite)} is not the pinned {source['tfliteSha256']}")
    path = work / TFLITE_ENTRY
    path.write_bytes(tflite)
    print(f"ok bundle {sha256(bundle)}; {TFLITE_ENTRY} {sha256(tflite)}")
    return path


def convert(tflite, out):
    import tf2onnx  # noqa: PLC0415 (only this mode needs TensorFlow)
    if tf2onnx.__version__ != "1.17.0":
        raise SystemExit(f"tf2onnx {tf2onnx.__version__} is not the pinned 1.17.0")
    model, _ = tf2onnx.convert.from_tflite(str(tflite), opset=OPSET)
    for value in list(model.graph.input) + list(model.graph.output):
        batch = value.type.tensor_type.shape.dim[0]
        batch.ClearField("dim_param")
        batch.dim_value = 1
    out.write_bytes(model.SerializeToString())
    return out


def same_graph(a_path, b_path):
    import onnx  # noqa: PLC0415
    from onnx import numpy_helper  # noqa: PLC0415
    a, b = onnx.load(str(a_path)), onnx.load(str(b_path))

    def shapes(values):
        return [(v.name, [d.dim_value or d.dim_param for d in v.type.tensor_type.shape.dim]) for v in values]

    def weights(model):
        return sorted((tuple(i.dims), i.data_type, numpy_helper.to_array(i).tobytes()) for i in model.graph.initializer)

    checks = {
        "inputs": shapes(a.graph.input) == shapes(b.graph.input),
        "outputs": shapes(a.graph.output) == shapes(b.graph.output),
        "opsets": [(o.domain, o.version) for o in a.opset_import] == [(o.domain, o.version) for o in b.opset_import],
        "operators": [n.op_type for n in a.graph.node] == [n.op_type for n in b.graph.node],
        "weights": weights(a) == weights(b),
    }
    for name, passed in checks.items():
        print(f"{'ok' if passed else 'FAIL'} same {name}")
    return all(checks.values())


def parity(tflite, models, samples=8):
    import numpy as np  # noqa: PLC0415
    import onnxruntime as ort  # noqa: PLC0415
    import tensorflow as tf  # noqa: PLC0415
    # TFLite's reference kernels (XNNPACK may compute in reduced precision), ORT's full optimisation as the app runs it.
    interpreter = tf.lite.Interpreter(model_path=str(tflite),
                                      experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
    interpreter.allocate_tensors()
    tensor = interpreter.get_input_details()[0]
    outputs = interpreter.get_output_details()
    rng = np.random.default_rng(20261109)
    inputs = [rng.random((1, 256, 256, 3), dtype=np.float32) for _ in range(samples)]
    references = []
    for x in inputs:
        interpreter.set_tensor(tensor["index"], x)
        interpreter.invoke()
        references.append({o["name"]: interpreter.get_tensor(o["index"]).copy() for o in outputs})
    passed = True
    for path in models:
        options = ort.SessionOptions()
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        options.intra_op_num_threads = 2
        session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
        names = [o.name for o in session.get_outputs()]
        worst = 0.0
        for x, reference in zip(inputs, references):
            for name, value in zip(names, session.run(None, {session.get_inputs()[0].name: x})):
                worst = max(worst, float(np.abs(value.reshape(-1) - reference[name].reshape(-1)).max()))
        ok = worst <= PARITY
        passed &= ok
        print(f"{'ok' if ok else 'FAIL'} {path.name}: max |onnx - tflite| {worst:.2e} (onnxruntime {ort.__version__})")
    return passed


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", required=True, type=pathlib.Path, help="a scratch folder for downloads and outputs")
    parser.add_argument("--from-pack", action="store_true", help="write the pinned pack's byte-identical mesh entry")
    parser.add_argument("--bundled", type=pathlib.Path, default=BUNDLED, help="the file to check the conversion against")
    arguments = parser.parse_args(argv)
    arguments.work.mkdir(parents=True, exist_ok=True)
    entry = landmarks_entry()
    if arguments.from_pack:
        return from_pack(arguments.work, entry)
    bundled = arguments.bundled.read_bytes()
    if len(bundled) != entry["bytes"] or sha256(bundled) != entry["sha256"]:
        raise SystemExit(f"{arguments.bundled} is not the catalogued file.")
    print(f"ok bundled {arguments.bundled.name} matches the catalogue ({entry['sha256']})")
    tflite = tflite_bytes(arguments.work, entry)
    converted = convert(tflite, arguments.work / "face_mesh_v2.converted.onnx")
    data = converted.read_bytes()
    print(f"{'ok byte-identical' if sha256(data) == entry['sha256'] else 'note: not byte-identical'}: "
          f"conversion {len(data)} bytes, SHA-256 {sha256(data)}")
    graph = same_graph(arguments.bundled, converted)
    close = parity(tflite, [arguments.bundled, converted])
    return 0 if graph and close else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

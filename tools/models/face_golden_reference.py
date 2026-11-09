#!/usr/bin/env python3
"""The reference for the Windows face goldens (shared/fixtures/frame-faces, OnnxFrameFacesTests): the W3 face path built
independently of the C# code, from numpy, onnxruntime and the pure maths of tools/fixtures/clip-frames/generate_face_fields.py.

  python3 tools/models/face_golden_reference.py shared/fixtures/frame-faces/*.png

prints, per image, the face count and the largest real face's fields (rect, eye ratios, yaw, pitch, capture quality and its
parts) with the catalogue's calibration. Re-pin OnnxFrameFacesTests' Goldens from it whenever the calibration changes (W7).
Steps, as OnnxFrameFaces: the image scaled bilinearly at pixel centres (edges repeated) to YuNet's input (640 px long side,
padded black to multiples of 32), BGR 0-255 NCHW; YuNet decoded; largest box first (a box the mesh rejects is not counted);
the roll-aligned 256 px crop sampled from the image itself; Face Mesh V2; the fields. Needs numpy, pillow and onnxruntime
1.19.2 in a throwaway venv.
"""
import importlib.util
import json
import pathlib
import sys

import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODELS = ROOT / "apps" / "windows" / "models" / "frames"
GENERATOR = ROOT / "tools" / "fixtures" / "clip-frames" / "generate_face_fields.py"
CALIBRATION = json.loads((ROOT / "shared" / "catalog" / "frame-models.json").read_text(encoding="utf-8"))["models"][0]["calibration"]
ANALYSIS_EDGE = 1280

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("generate_face_fields", GENERATOR)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


def session(name):
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    return ort.InferenceSession(str(MODELS / name), options, providers=["CPUExecutionProvider"])


DETECTOR = session("face_detection_yunet_2026may.onnx")
MESH = session("face_mesh_v2.onnx")


def taps(source, target):
    position = np.maximum(0.0, (np.arange(target) + 0.5) * (source / target) - 0.5)
    low = np.minimum(np.floor(position).astype(int), source - 1)
    high = np.minimum(low + 1, source - 1)
    return low, high, position - low


def faces(path):
    image = Image.open(path).convert("RGB")
    rgb = np.asarray(image).astype(np.float64)
    height, width, _ = rgb.shape
    size = gen.yunet_input(width, height)
    columns, rows = taps(width, size["contentWidth"]), taps(height, size["contentHeight"])
    top = rgb[rows[0]][:, columns[0]] + (rgb[rows[0]][:, columns[1]] - rgb[rows[0]][:, columns[0]]) * columns[2][None, :, None]
    bottom = rgb[rows[1]][:, columns[0]] + (rgb[rows[1]][:, columns[1]] - rgb[rows[1]][:, columns[0]]) * columns[2][None, :, None]
    scaled = top + (bottom - top) * rows[2][:, None, None]
    tensor = np.zeros((1, 3, size["height"], size["width"]), np.float32)
    tensor[0, :, :size["contentHeight"], :size["contentWidth"]] = scaled[:, :, ::-1].transpose(2, 0, 1)
    names = [output.name for output in DETECTOR.get_outputs()]
    outputs = {name: value.reshape(-1).tolist() for name, value in zip(names, DETECTOR.run(None, {"input": tensor}))}
    found = gen.decode(outputs, size["width"], size["height"])
    flat = np.asarray(image).reshape(-1).tolist()
    rejected = 0
    for face in sorted(found, key=lambda item: -gen.area(item)):  # stable: best score first among equals
        crop = gen.crop_from_face(face, 1 / size["scale"])
        if crop is None:
            rejected += 1
            continue
        sample = gen.sample(crop, flat, width, height, width * 3)
        landmarks, presence = MESH.run(["Identity", "Identity_1"], {"input_12": np.asarray(sample, np.float32).reshape(1, 256, 256, 3)})
        logit = float(presence.reshape(-1)[0])
        if logit < 0:
            rejected += 1
            continue
        points = landmarks.reshape(478, 3).astype(np.float64).tolist()
        case = {"count": 478, "fill": [0.0, 0.0, 0.0], "points": {str(index): point for index, point in enumerate(points)},
                "faceWidthPixels": face["width"] * (ANALYSIS_EDGE / gen.LONG_SIDE),
                "crop": gen.crop_stats(sample, gen.CROP_SIZE, CALIBRATION["quality"]["gates"]),
                "rect": gen.picture_rect(face, size["contentWidth"], size["contentHeight"])}
        fields = gen.mesh_fields(case, CALIBRATION)
        return {"faceCount": len(found) - rejected, "detectorScore": face["score"], "presenceLogit": logit, "roll": crop["roll"],
                "face": fields["face"], "quality": fields["quality"], "meshYaw": fields["meshYaw"], "meshPitch": fields["meshPitch"]}
    return {"faceCount": 0, "boxes": len(found)}


def main(paths):
    for path in paths:
        print(pathlib.Path(path).name, json.dumps(faces(path), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

import argparse
import hashlib
import json
import math
import pathlib
import subprocess
import sys
import wave

import numpy as np
import onnxruntime as ort
from calibration import choose_threshold

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "shared/catalog/voice-lab-models.json"
FIXTURES = ROOT / "shared/fixtures/voice-lab/speaker"
VERSION = "silero-6.2.0-strict-kaldi80-v1"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_wav(path):
    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError("Expected mono PCM16 WAV at 16000 Hz")
        return np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768


def windows(pcm):
    if len(pcm) < 48000 or not np.isfinite(pcm).all():
        raise ValueError("At least three seconds of finite voiced samples are required")
    return [pcm[start:start + 48000] for start in range(0, len(pcm) - 48000 + 1, 24000)]


def normalized(vector):
    vector = np.asarray(vector, dtype=np.float64)
    norm = np.linalg.norm(vector)
    if not math.isfinite(norm) or norm <= 0:
        raise ValueError("Invalid embedding")
    return (vector / norm).astype(np.float32)


def features(pcm):
    if len(pcm) != 48000:
        raise ValueError("Expected one three-second window")
    frames = np.stack([pcm[start:start + 400] for start in range(0, 47601, 160)]).astype(np.float64) * 32768
    frames -= frames.mean(axis=1, keepdims=True)
    frames[:, 1:] -= 0.97 * frames[:, :-1].copy()
    frames[:, 0] *= 0.03
    frames *= 0.54 - 0.46 * np.cos(2 * np.pi * np.arange(400) / 399)
    power = np.abs(np.fft.rfft(frames, n=512)) ** 2
    mel = 1127 * np.log1p(np.arange(257) * (16000 / 512) / 700)
    low = 1127 * math.log1p(20 / 700)
    high = 1127 * math.log1p(8000 / 700)
    step = (high - low) / 81
    bank = []
    for band in range(80):
        left = low + band * step
        weights = np.maximum(0, np.minimum((mel - left) / step, (left + 2 * step - mel) / step))
        weights[-1] = 0
        bank.append(weights)
    result = np.log(np.maximum(np.finfo(np.float32).eps, power @ np.asarray(bank).T))
    result -= result.mean(axis=0, keepdims=True)
    return result.astype(np.float32)


def session(model):
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    return ort.InferenceSession(str(model), sess_options=options, providers=["CPUExecutionProvider"])


def embed(runtime, matrices):
    vectors = [normalized(runtime.run(["embs"], {"feats": np.asarray(matrix, dtype=np.float32).reshape(1, 298, 80)})[0].reshape(-1)) for matrix in matrices]
    return normalized(np.sum(vectors, axis=0, dtype=np.float32))


def preprocess(cli, vad, items, output):
    output.mkdir(parents=True, exist_ok=True)
    manifest = output / "inputs.json"
    manifest.write_text(json.dumps(items), encoding="utf-8")
    subprocess.run([str(cli), "speaker-diagnostic", "--input", str(manifest), "--vad", str(vad), "--output", str(output)], check=True)
    return {item["id"]: json.loads((output / (item["id"] + ".json")).read_text()) for item in items}


def verify_assets(model, vad):
    entry = json.loads(CATALOG.read_text())["models"][0]
    for role, path in [("speaker", model), ("vad", vad)]:
        record = next(record for record in entry["files"] if record["role"] == role)
        if path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
            raise ValueError("Asset does not match the pinned catalogue: " + role)
    return entry


def calibrate(args):
    entry = verify_assets(args.model, args.vad)
    clips = args.work / "clips"
    clips.mkdir(parents=True, exist_ok=True)
    items = []
    for speaker in sorted(args.corpus.iterdir()):
        if not speaker.is_dir():
            continue
        count = 0
        for source in sorted(speaker.rglob("*.flac")):
            target = clips / (source.stem + ".wav")
            subprocess.run([args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(source), "-t", "6", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(target)], check=True)
            if len(read_wav(target)) < 96000:
                continue
            items.append({"id": source.stem, "wav": str(target)})
            count += 1
            if count == 4:
                break
    prepared = preprocess(args.cli, args.vad, items, args.work / "preprocessed")
    runtime = session(args.model)
    selected = []
    speakers = {}
    for item in items:
        speaker = item["id"].split("-")[0]
        result = prepared[item["id"]]
        if not result["features"] or speakers.get(speaker, 0) >= 3:
            continue
        pcm = read_wav(pathlib.Path(item["wav"]))
        speech = np.concatenate([pcm[start:end] for start, end in result["ranges"]])
        independent = [features(window) for window in windows(speech)]
        maximum = max(float(np.max(np.abs(matrix - np.asarray(other).reshape(298, 80)))) for matrix, other in zip(independent, result["features"]))
        if maximum > 2e-4 or len(independent) != len(result["features"]):
            raise ValueError(f"Swift/Python preprocessing drift: {maximum}")
        selected.append({"id": item["id"], "speaker": speaker, "embedding": embed(runtime, result["features"]), "wavSha256": digest(pathlib.Path(item["wav"]))})
        speakers[speaker] = speakers.get(speaker, 0) + 1
    impostor, own, pairs = [], [], []
    for index, left in enumerate(selected):
        for right in selected[index + 1:]:
            score = float(np.dot(normalized(left["embedding"]).astype(np.float64), normalized(right["embedding"]).astype(np.float64)))
            same = left["speaker"] == right["speaker"]
            (own if same else impostor).append(score)
            pairs.append([left["id"], right["id"], same, score])
    chosen, curve = choose_threshold(impostor, own)
    report = {
        "schema": "voxclip-speaker-calibration/1", "date": args.date, "model": entry["id"],
        "modelSha256": digest(args.model), "vadSha256": digest(args.vad), "preprocessing": VERSION,
        "runtime": "onnxruntime " + ort.__version__ + " CPUExecutionProvider", "language": "en",
        "corpus": "LibriSpeech test-clean (OpenSLR 12, CC BY 4.0)", "clipSeconds": 6,
        "selection": "Sorted speaker/chapter/utterance; first four utterances at least 6 s; first three with at least 3 s Silero speech. Different utterances for same-speaker pairs; no augmentation.",
        "speakers": len(speakers), "clips": [{key: value for key, value in item.items() if key != "embedding"} for item in selected],
        "impostorPairs": len(impostor), "sameSpeakerPairs": len(own),
        "threshold": chosen[0] if chosen else None, "falseAcceptRate": chosen[1] if chosen else None, "sameSpeakerPassRate": chosen[2] if chosen else None,
        "curveColumns": ["threshold", "falseAcceptRate", "sameSpeakerPassRate"], "curve": curve,
        "limitations": ["Calibration, not a held-out accuracy claim or a microphone check.", "No account-free Estonian speaker-labelled subset was obtained in this run; calibration owed.", "User own-voice check on this Mac microphone is owed."]
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    (args.report.parent / "calibration-pairs.json").write_text(json.dumps(pairs, separators=(",", ":")) + "\n")
    if not chosen:
        if args.update_catalog:
            catalog = json.loads(CATALOG.read_text())
            catalog["models"][0]["threshold"] = None
            catalog["models"][0]["calibration"] = None
            CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
        print("No threshold meets both targets. No threshold was published.", file=sys.stderr)
        return 2
    if args.update_catalog:
        catalog = json.loads(CATALOG.read_text())
        catalog["models"][0]["threshold"] = chosen[0]
        catalog["models"][0]["calibration"] = {"date": args.date, "preprocessing": VERSION, "modelSha256": digest(args.model), "vadSha256": digest(args.vad), "languages": [{"language": "en", "corpus": report["corpus"], "impostorPairs": len(impostor), "sameSpeakerPairs": len(own), "falseAcceptRate": chosen[1], "sameSpeakerPassRate": chosen[2]}]}
        CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: report[key] for key in ["speakers", "impostorPairs", "sameSpeakerPairs", "threshold", "falseAcceptRate", "sameSpeakerPassRate"]}))
    return 0


def parity(args):
    entry = verify_assets(args.model, args.vad)
    if args.check:
        expected = json.loads((FIXTURES / "vectors.json").read_text())
        items = [{"id": item["id"], "wav": str(FIXTURES / (item["id"] + ".wav"))} for item in expected["clips"]]
    else:
        report = json.loads(args.report.read_text())
        selected_speakers = sorted({item["id"].split("-")[0] for item in report["clips"]})[:2]
        chosen = [item for speaker in selected_speakers for item in [clip for clip in report["clips"] if clip["id"].split("-")[0] == speaker][:2]]
        FIXTURES.mkdir(parents=True, exist_ok=True)
        for item in chosen:
            (FIXTURES / (item["id"] + ".wav")).write_bytes((args.work / "clips" / (item["id"] + ".wav")).read_bytes())
        items = [{"id": item["id"], "wav": str(FIXTURES / (item["id"] + ".wav"))} for item in chosen]
    prepared = preprocess(args.cli, args.vad, items, args.work / "parity")
    runtime = session(args.model)
    vectors = []
    for item in items:
        result = prepared[item["id"]]
        pcm = read_wav(pathlib.Path(item["wav"]))
        speech = np.concatenate([pcm[start:end] for start, end in result["ranges"]])
        embedding = embed(runtime, [features(window).reshape(-1).tolist() for window in windows(speech)])
        vectors.append({"id": item["id"], "sha256": digest(pathlib.Path(item["wav"])), "ranges": result["ranges"], "embedding": embedding.tolist()})
    scores = [[left["id"], right["id"], float(np.dot(left["embedding"], right["embedding"]))] for index, left in enumerate(vectors) for right in vectors[index + 1:]]
    result = {"schema": "voxclip-speaker-vectors/1", "model": entry["id"], "modelSha256": digest(args.model), "vadSha256": digest(args.vad), "preprocessing": VERSION, "runtime": "onnxruntime " + ort.__version__ + " CPU", "embeddingAbsoluteTolerance": 0.0002, "scoreAbsoluteTolerance": 0.0002, "clips": vectors, "scores": scores}
    numerical_pcm = np.asarray([np.float32(math.sin(index * 0.071) * 0.2) for index in range(48000)], dtype=np.float32)
    numerical = features(numerical_pcm)
    feature_vector = {"preprocessing": "kaldi80-v1", "formula": "Float(sin(Double(index) * 0.071) * 0.2), 48000 samples", "first": numerical[0].tolist(), "last": numerical[-1].tolist()}
    if args.check:
        if len(result["clips"]) != len(expected["clips"]) or len(scores) != len(expected["scores"]):
            raise ValueError("Parity fixture count drift")
        reference = json.loads((FIXTURES / "features.json").read_text())
        for key in ["first", "last"]:
            if not np.allclose(feature_vector[key], reference[key], rtol=0, atol=0.0002):
                raise ValueError("Numerical feature drift")
        for actual, reference in zip(result["clips"], expected["clips"]):
            if actual["id"] != reference["id"] or actual["sha256"] != reference["sha256"] or actual["ranges"] != reference["ranges"] or not np.allclose(actual["embedding"], reference["embedding"], rtol=0, atol=expected["embeddingAbsoluteTolerance"]):
                raise ValueError("Parity drift: " + actual["id"])
        for actual, reference in zip(scores, expected["scores"]):
            if actual[:2] != reference[:2] or abs(actual[2] - reference[2]) > expected["scoreAbsoluteTolerance"]:
                raise ValueError("Score drift")
        print("Speaker parity fixtures match real CPU ONNX inference.")
    else:
        (FIXTURES / "vectors.json").write_text(json.dumps(result, indent=2) + "\n")
        (FIXTURES / "features.json").write_text(json.dumps(feature_vector, indent=2) + "\n")
        print("Wrote " + str(len(vectors)) + " attributed speaker clips and vectors.")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Offline S6 calibration and parity; never downloads or calls providers.")
    parser.add_argument("mode", choices=["calibrate", "parity"])
    parser.add_argument("--model", type=pathlib.Path, required=True)
    parser.add_argument("--vad", type=pathlib.Path, required=True)
    parser.add_argument("--cli", type=pathlib.Path, required=True)
    parser.add_argument("--work", type=pathlib.Path, required=True)
    parser.add_argument("--corpus", type=pathlib.Path)
    parser.add_argument("--report", type=pathlib.Path, default=FIXTURES / "calibration-en.json")
    parser.add_argument("--date", default="2026-10-29")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--update-catalog", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.mode == "calibrate" and args.corpus is None:
        parser.error("Calibration requires an already downloaded LibriSpeech test-clean directory")
    return calibrate(args) if args.mode == "calibrate" else parity(args)


if __name__ == "__main__":
    sys.exit(main())

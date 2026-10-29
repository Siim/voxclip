import hashlib
import json
import math
import pathlib
import wave

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "shared/fixtures/voice-lab/speaker"


def check():
    vectors = json.loads((FIXTURES / "vectors.json").read_text())
    report = json.loads((FIXTURES / "calibration-en.json").read_text())
    catalog = json.loads((ROOT / "shared/catalog/voice-lab-models.json").read_text())["models"][0]
    files = {file["role"]: file for file in catalog["files"]}
    for document in [vectors, report]:
        assert document["model"] == catalog["id"]
        assert document["modelSha256"] == files["speaker"]["sha256"]
        assert document["vadSha256"] == files["vad"]["sha256"]
        assert document["preprocessing"] == catalog["preprocessing"]
    assert report["threshold"] == catalog["threshold"]
    for clip in vectors["clips"]:
        path = FIXTURES / (clip["id"] + ".wav")
        assert hashlib.sha256(path.read_bytes()).hexdigest() == clip["sha256"]
        with wave.open(str(path), "rb") as audio:
            assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
            assert 48000 <= audio.getnframes() <= 96000
        assert len(clip["embedding"]) == catalog["dimension"]
        assert abs(sum(value * value for value in clip["embedding"]) - 1) < 1e-5
        previous = 0
        for start, end in clip["ranges"]:
            assert previous <= start < end <= 96000
            previous = end
    by_id = {clip["id"]: clip for clip in vectors["clips"]}
    for left, right, score in vectors["scores"]:
        actual = sum(first * second for first, second in zip(by_id[left]["embedding"], by_id[right]["embedding"]))
        assert math.isfinite(score) and abs(actual - score) < 1e-6
    pairs = json.loads((FIXTURES / "calibration-pairs.json").read_text())
    assert len({tuple(sorted([left, right])) for left, right, _, _ in pairs}) == len(pairs)
    own = [score for left, right, same, score in pairs if same]
    impostor = [score for left, right, same, score in pairs if not same]
    for left, right, same, score in pairs:
        assert same == (left.split("-")[0] == right.split("-")[0])
        assert left != right and math.isfinite(score)
    assert len(own) == report["sameSpeakerPairs"] >= 50
    assert len(impostor) == report["impostorPairs"] >= 200
    threshold = report["threshold"]
    far = sum(score >= threshold for score in impostor) / len(impostor)
    rate = sum(score >= threshold for score in own) / len(own)
    assert far == report["falseAcceptRate"] <= 0.01
    assert rate == report["sameSpeakerPassRate"] >= 0.95
    language = catalog["calibration"]["languages"][0]
    assert language["impostorPairs"] == len(impostor) and language["sameSpeakerPairs"] == len(own)
    assert language["falseAcceptRate"] == far and language["sameSpeakerPassRate"] == rate
    print("Speaker asset hashes, attribution fixture formats, scores and calibration metadata match.")


if __name__ == "__main__":
    check()

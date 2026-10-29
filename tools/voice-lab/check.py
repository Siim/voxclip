import hashlib
import json
import math
import pathlib
import wave
from calibration import choose_threshold, conditions_pass, rates, MARGIN_FLOOR

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
            assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, clip["sampleRate"])
            assert audio.getframerate() in [16000, 44100, 48000]
            assert audio.getnframes() == audio.getframerate() * 6
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
    assert {clip["sampleRate"] for clip in vectors["clips"]} == {16000, 44100, 48000}
    pairs = json.loads((FIXTURES / "calibration-pairs.json").read_text())
    assert len({tuple(sorted([left, right])) for left, right, _, _, _ in pairs}) == len(pairs)
    clips = {clip["id"]: clip for clip in report["clips"]}
    assert len(clips) == report["audioRenders"]
    assert len({clip["speaker"] for clip in clips.values()}) == report["speakers"]
    assert len({clip["source"] for clip in clips.values()}) == report["independentClips"]
    assert len(clips) == report["independentClips"] * 2
    corpus_speakers = {}
    for clip in clips.values():
        corpus_speakers.setdefault(clip["corpus"], set()).add(clip["speaker"])
    corpora = list(corpus_speakers)
    for index, corpus in enumerate(corpora):
        for other in corpora[index + 1:]:
            assert not corpus_speakers[corpus] & corpus_speakers[other]
    assert sum(len(speakers) for corpus, speakers in corpus_speakers.items() if "clean" in corpus) == report["calibrationSpeakers"] == 80
    own = [score for _, _, same, score, _ in pairs if same]
    impostor = [score for _, _, same, score, _ in pairs if not same]
    for left, right, same, score, group in pairs:
        first, second = clips[left], clips[right]
        assert first["source"] != second["source"]
        assert same == (first["speaker"] == second["speaker"])
        assert first["corpus"] == second["corpus"] and first["sampleRate"] == second["sampleRate"]
        assert group == f'{first["corpus"]}-{first["sampleRate"]}'
        assert math.isfinite(score) and -1 <= score <= 1
    assert len(own) == report["sameSpeakerPairs"] >= 50
    assert len(impostor) == report["impostorPairs"] >= 200
    margin = report["margin"]
    threshold = margin["candidateThreshold"]
    fitting = [pair for pair in pairs if "clean" in pair[4]]
    different = [pair[3] for pair in fitting if not pair[2]]
    same = [pair[3] for pair in fitting if pair[2]]
    chosen, curve = choose_threshold(different, same, margin["crossRuntimeDrift"])
    assert margin["maximumCalibrationImpostorScore"] == max(different)
    assert margin["absoluteFloor"] == MARGIN_FLOOR
    assert threshold == max(0, max(different) + max(MARGIN_FLOOR, margin["crossRuntimeDrift"]))
    assert report["curve"] == curve
    assert report["validationCurve"] == [[point[0], *rates(impostor, own, point[0])] for point in curve]
    far, rate = rates(impostor, own, threshold)
    assert far == report["falseAcceptRate"] and rate == report["sameSpeakerPassRate"]
    for condition in report["conditions"]:
        group = f'{condition["corpus"]}-{condition["sampleRate"]}'
        group_clips = [clip for clip in clips.values() if f'{clip["corpus"]}-{clip["sampleRate"]}' == group]
        group_pairs = [pair for pair in pairs if pair[4] == group]
        assert len(group_pairs) == len(group_clips) * (len(group_clips) - 1) // 2
        assert len(group_clips) == condition["independentClips"] == condition["speakers"] * 3
        different = [pair[3] for pair in group_pairs if not pair[2]]
        same = [pair[3] for pair in group_pairs if pair[2]]
        assert len(different) == condition["impostorPairs"] >= 200
        assert len(same) == condition["sameSpeakerPairs"] >= 50
        assert rates(different, same, threshold) == [condition["falseAcceptRate"], condition["sameSpeakerPassRate"]]
        assert condition["falseAccepts"] == sum(score >= threshold for score in different)
        assert condition["sameSpeakerPasses"] == sum(score >= threshold for score in same)
        assert condition["maximumImpostorScore"] == max(different)
    passed = chosen is not None and conditions_pass(report["conditions"])
    assert report["threshold"] == (threshold if passed else None)
    assert catalog["calibration"]["outcome"] == ("passed" if passed else "withheld")
    assert catalog["calibration"]["margin"] == margin
    language = catalog["calibration"]["languages"][0]
    for key in ["speakers", "calibrationSpeakers", "independentClips", "audioRenders", "conditions", "corpus"]:
        assert language[key] == report[key]
    assert language["impostorPairs"] == len(impostor) and language["sameSpeakerPairs"] == len(own)
    assert language["falseAcceptRate"] == far and language["sameSpeakerPassRate"] == rate
    print("Speaker asset hashes, attribution fixture formats, scores and calibration metadata match.")


if __name__ == "__main__":
    check()

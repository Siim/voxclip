import hashlib
import json
import math
import pathlib
import re
import wave
import riigikogu
from calibration import choose_threshold, candidate_threshold, calibration_percentile, conditions_pass, rates, MARGIN_FLOOR, PERCENTILE, PERCENTILE_METHOD, ROUNDING_INCREMENT, MARGIN_POLICY

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
    assert catalog["calibration"]["date"] == report["date"]
    assert catalog["calibration"]["preprocessing"] == report["preprocessing"]
    assert [item["language"] for item in catalog["calibration"]["languages"]] == ["en"]
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
    roles = {condition["corpus"]: condition["role"] for condition in report["conditions"]}
    assert roles == {"dev-clean": "calibration", "test-clean": "calibration", "dev-other": "speaker-disjoint validation", "test-other": "speaker-disjoint validation"}
    assert sum(len(speakers) for corpus, speakers in corpus_speakers.items() if roles[corpus] == "calibration") == report["calibrationSpeakers"] == 80
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
    fitting = [pair for pair in pairs if roles[clips[pair[0]]["corpus"]] == "calibration"]
    different = [pair[3] for pair in fitting if not pair[2]]
    same = [pair[3] for pair in fitting if pair[2]]
    chosen, curve = choose_threshold(different, same, margin["crossRuntimeDrift"])
    assert margin["maximumCalibrationImpostorScore"] == max(different)
    assert margin["policy"] == MARGIN_POLICY
    assert margin["percentileProbability"] == PERCENTILE
    assert margin["percentileMethod"] == PERCENTILE_METHOD
    assert margin["percentileCalibrationImpostorScore"] == calibration_percentile(different)
    assert margin["roundingIncrement"] == ROUNDING_INCREMENT
    assert margin["absoluteFloor"] == MARGIN_FLOOR
    assert threshold == candidate_threshold(different, margin["crossRuntimeDrift"])
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


def check_et():
    """Estonian et-v1 evidence, frozen or validated. The catalogue stays English-only until a separate change adopts it."""
    path = FIXTURES / "calibration-et.json"
    if not path.exists():
        return
    report = json.loads(path.read_text())
    pairs = json.loads((FIXTURES / "calibration-pairs-et.json").read_text())
    catalog = json.loads((ROOT / "shared/catalog/voice-lab-models.json").read_text())["models"][0]
    files = {file["role"]: file for file in catalog["files"]}
    assert (report["language"], report["calibration"], report["selectionPolicy"]) == ("et", "et-v1", riigikogu.POLICY)
    assert report["model"] == catalog["id"] and report["preprocessing"] == catalog["preprocessing"]
    assert report["modelSha256"] == files["speaker"]["sha256"] and report["vadSha256"] == files["vad"]["sha256"]
    assert [item["language"] for item in catalog["calibration"]["languages"]] == ["en"]
    sources = report["sources"]
    assert (sources["dataset"], sources["revision"], sources["licence"], sources["attribution"]) == (riigikogu.DATASET, riigikogu.REVISION, riigikogu.LICENCE, riigikogu.ATTRIBUTION)
    assert len(sources["transcripts"]) == len({row[0] for row in sources["transcripts"]}) == 1001
    assert all(re.fullmatch(r"[0-9a-f]{64}", row[2]) and re.fullmatch(r"[0-9a-f]{40}", row[3]) for row in sources["transcripts"])
    audio = {record["path"]: record for record in sources["audio"]}
    assert all(re.fullmatch(r"[0-9a-f]{64}", record["lfsSha256"]) for record in audio.values())
    pool = report["pool"]
    assert pool == sorted(pool) and len(pool) <= riigikogu.POOL_SESSIONS and len({session[:8] for session in pool}) == len(pool)
    assert report["predeclared"] == {"targetSpeakersPerGroup": 40, "minimumSpeakersPerGroup": 17, "minimumPairsPerCell": [1224, 51], "targetPairsPerCell": [7020, 120]}
    clips = {clip["id"]: clip for clip in report["clips"]}
    assert len(clips) == len(report["clips"]) == report["audioRenders"] == report["independentClips"] * 2
    sessions = {}
    for clip in clips.values():
        key = re.fullmatch(r"rk([0-9]{3})", clip["speaker"])
        assert key and clip["corpus"] == riigikogu.GROUPS[(int(key.group(1)) - 1) % 4]
        source = re.fullmatch(r"([0-9]{12})@([0-9]+)\.([0-9]{3})-([0-9]+)\.([0-9]{3})", clip["source"])
        assert source and source.group(1) in pool and f"audio/{source.group(1)}.flac" in audio
        start, end = int(source.group(2)) * 1000 + int(source.group(3)), int(source.group(4)) * 1000 + int(source.group(5))
        assert end - start == riigikogu.EXCERPT_MS and clip["id"] == f'{source.group(1)}-{start}-{clip["sampleRate"]}'
        assert clip["sampleRate"] in [48000, 44100] and re.fullmatch(r"[0-9a-f]{64}", clip["wavSha256"]) and re.fullmatch(r"[0-9a-f]{64}", clip["excerptSha256"])
        sessions.setdefault(clip["speaker"], set()).add(source.group(1))
    assert len(sessions) == report["speakers"] and all(len(value) == 3 for value in sessions.values())
    assert len({clip["source"] for clip in clips.values()}) == report["independentClips"]
    assert len({(clip["source"], clip["sampleRate"]) for clip in clips.values()}) == len(clips)
    assert len({tuple(sorted([left, right])) for left, right, _, _, _ in pairs}) == len(pairs)
    for left, right, same, score, group in pairs:
        first, second = clips[left], clips[right]
        assert first["source"] != second["source"] and same == (first["speaker"] == second["speaker"])
        assert first["corpus"] == second["corpus"] and first["sampleRate"] == second["sampleRate"] and group == f'{first["corpus"]}-{first["sampleRate"]}'
        assert math.isfinite(score) and -1 <= score <= 1
    roles = {condition["corpus"]: condition["role"] for condition in report["conditions"]}
    assert all(riigikogu.ROLES[group] == role for group, role in roles.items())
    fitting = [pair for pair in pairs if riigikogu.ROLES[clips[pair[0]]["corpus"]] == "calibration"]
    different = [pair[3] for pair in fitting if not pair[2]]
    same = [pair[3] for pair in fitting if pair[2]]
    point, curve = choose_threshold(different, same, report["margin"]["crossRuntimeDrift"])
    margin = report["margin"]
    threshold = margin["candidateThreshold"]
    assert (margin["policy"], margin["percentileProbability"], margin["percentileMethod"], margin["roundingIncrement"], margin["absoluteFloor"], margin["crossRuntimeDrift"]) == (MARGIN_POLICY, PERCENTILE, PERCENTILE_METHOD, ROUNDING_INCREMENT, MARGIN_FLOOR, 0.0)
    assert margin["percentileCalibrationImpostorScore"] == calibration_percentile(different) and margin["maximumCalibrationImpostorScore"] == max(different)
    assert threshold == candidate_threshold(different) and report["calibrationPoint"] == point and report["curve"] == curve
    expected = [group for group in riigikogu.GROUPS if report["status"] == "validated" or riigikogu.ROLES[group] == "calibration"]
    assert report["status"] in ["frozen-before-validation", "validated"]
    assert [(condition["corpus"], condition["sampleRate"]) for condition in report["conditions"]] == [(group, rate) for group in sorted(expected, key=lambda group: (riigikogu.ROLES[group] != "calibration", group)) for rate in [48000, 44100]]
    assert report["calibrationSpeakers"] == len({clip["speaker"] for clip in clips.values() if riigikogu.ROLES[clip["corpus"]] == "calibration"})
    for condition in report["conditions"]:
        group = f'{condition["corpus"]}-{condition["sampleRate"]}'
        group_clips = [clip for clip in clips.values() if f'{clip["corpus"]}-{clip["sampleRate"]}' == group]
        group_pairs = [pair for pair in pairs if pair[4] == group]
        assert len(group_pairs) == len(group_clips) * (len(group_clips) - 1) // 2
        assert len(group_clips) == condition["independentClips"] == condition["speakers"] * 3 == 3 * len({clip["speaker"] for clip in group_clips})
        impostor = [pair[3] for pair in group_pairs if not pair[2]]
        own = [pair[3] for pair in group_pairs if pair[2]]
        assert (len(impostor), len(own)) == (condition["impostorPairs"], condition["sameSpeakerPairs"]) == tuple(riigikogu.minimum_pairs(condition["speakers"]))
        assert rates(impostor, own, threshold) == [condition["falseAcceptRate"], condition["sameSpeakerPassRate"]]
        assert condition["falseAccepts"] == sum(score >= threshold for score in impostor) and condition["sameSpeakerPasses"] == sum(score >= threshold for score in own)
        assert condition["maximumImpostorScore"] == max(impostor)
    all_impostor = [pair[3] for pair in pairs if not pair[2]]
    all_own = [pair[3] for pair in pairs if pair[2]]
    assert (len(all_impostor), len(all_own)) == (report["impostorPairs"], report["sameSpeakerPairs"])
    assert rates(all_impostor, all_own, threshold) == [report["falseAcceptRate"], report["sameSpeakerPassRate"]]
    assert report["validationCurve"] == [[point[0], *rates(all_impostor, all_own, point[0])] for point in curve]
    passed = (report["status"] == "validated" and point is not None and conditions_pass(report["conditions"])
              and all(condition["speakers"] >= riigikogu.MINIMUM_SPEAKERS for condition in report["conditions"]))
    assert report["threshold"] == (threshold if passed else None)
    print("Estonian et-v1 speaker evidence is internally consistent (" + report["status"] + ", threshold " + str(report["threshold"]) + ").")


if __name__ == "__main__":
    check()
    check_et()

import argparse
import hashlib
import json
import math
import pathlib
import subprocess
import sys
import wave

import numpy as np
from calibration import choose_threshold, candidate_threshold, calibration_percentile, rates, conditions_pass, FAR_LIMIT, OWN_LIMIT, MARGIN_FLOOR, PERCENTILE, PERCENTILE_METHOD, ROUNDING_INCREMENT, MARGIN_POLICY
import riigikogu

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "shared/catalog/voice-lab-models.json"
FIXTURES = ROOT / "shared/fixtures/voice-lab/speaker"
VERSION = "sinc32-blackman94-silero-6.2.0-kaldi80-v2"
RATES = [48_000, 44_100]
ROLES = {"dev-clean": "calibration", "test-clean": "calibration", "dev-other": "speaker-disjoint validation", "test-other": "speaker-disjoint validation"}
ARCHIVES = {
    "dev-clean": "76f87d090650617fca0cac8f88b9416e0ebf80350acb97b343a85fa903728ab3",
    "test-clean": "39fde525e59672dc6d1551919b1478f724438a95aa55f874b576be21967e6c23",
    "dev-other": "12661c48e8c3fe1de2c1caa4c3e135193bfb1811584f11f569dd12645aa84365",
    "test-other": "d09c181bba5cf717b3dee7d4d592af11a3ee3a09e08ae025c5506f6ebe961c29",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


def preprocess(cli, vad, items, output, include_features=False):
    output.mkdir(parents=True, exist_ok=True)
    manifest = output / "inputs.json"
    manifest.write_text(json.dumps(items), encoding="utf-8")
    command = [str(cli), "speaker-diagnostic", "--input", str(manifest), "--model-directory", str(vad.parent), "--output", str(output)]
    if include_features:
        command.append("--include-features")
    subprocess.run(command, check=True)
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
    if args.update_catalog:
        catalog = json.loads(CATALOG.read_text())
        catalog["models"][0].update(preprocessing=VERSION, threshold=None, calibration=None)
        CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    clips = args.work / "clips"
    clips.mkdir(parents=True, exist_ok=True)
    items = []
    corpus_speakers = {}
    corpora = ["dev-clean", "test-clean"] + (["dev-other", "test-other"] if args.harder else [])
    for corpus in corpora:
        archive = args.corpus.parent / (corpus + ".tar.gz")
        if archive.exists() and digest(archive) != ARCHIVES[corpus]:
            raise ValueError("Corpus archive checksum mismatch: " + corpus)
        root = args.corpus / corpus
        speakers = sorted(directory for directory in root.iterdir() if directory.is_dir())
        identities = {speaker.name for speaker in speakers}
        if any(identities & previous for previous in corpus_speakers.values()):
            raise ValueError("Corpus speakers must be disjoint")
        corpus_speakers[corpus] = identities
        for speaker in speakers:
            count = 0
            for source in sorted(speaker.rglob("*.flac")):
                decoded = []
                for rate in [48_000, 44_100]:
                    identity = f"{source.stem}-{rate}"
                    target = clips / (identity + ".wav")
                    subprocess.run([args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(source), "-t", "6", "-ac", "1", "-ar", str(rate), "-c:a", "pcm_s16le", str(target)], check=True)
                    with wave.open(str(target), "rb") as audio:
                        if audio.getnframes() < rate * 6:
                            break
                    decoded.append({"id": identity, "source": source.stem, "speaker": speaker.name, "corpus": corpus, "sampleRate": rate, "group": f"{corpus}-{rate}", "wav": str(target)})
                if len(decoded) != 2:
                    continue
                items.extend(decoded)
                count += 1
                if count == 4:
                    break
    prepared = preprocess(args.cli, args.vad, items, args.work / "preprocessed")
    selected, counts = [], {}
    for item in items:
        key = (item["corpus"], item["speaker"])
        if item["sampleRate"] != 48_000 or counts.get(key, 0) >= 3:
            continue
        versions = [candidate for candidate in items if candidate["source"] == item["source"]]
        if len(versions) != 2 or any(not prepared[version["id"]].get("embedding") for version in versions):
            continue
        selected.extend(versions)
        counts[key] = counts.get(key, 0) + 1
    for corpus, speakers in corpus_speakers.items():
        if any(counts.get((corpus, speaker), 0) != 3 for speaker in speakers):
            raise ValueError("Every speaker needs three distinct utterances with enough voiced audio at both rates")
    selected_by_id = {item["id"]: item for item in selected}
    pairs = []
    for score in json.loads((args.work / "preprocessed/scores.json").read_text()):
        left, right = selected_by_id.get(score["left"]), selected_by_id.get(score["right"])
        if left is None or right is None:
            continue
        if left["source"] == right["source"]:
            raise ValueError("A pair must use distinct source utterances")
        pairs.append([left["id"], right["id"], left["speaker"] == right["speaker"], score["value"], left["group"]])
    fitting = [pair for pair in pairs if ROLES[selected_by_id[pair[0]]["corpus"]] == "calibration"]
    impostor = [pair[3] for pair in fitting if not pair[2]]
    own = [pair[3] for pair in fitting if pair[2]]
    chosen, curve = choose_threshold(impostor, own)
    candidate = candidate_threshold(impostor)
    conditions = []
    for corpus in corpora:
        for rate in [48_000, 44_100]:
            group = f"{corpus}-{rate}"
            group_pairs = [pair for pair in pairs if pair[4] == group]
            different = [pair[3] for pair in group_pairs if not pair[2]]
            same = [pair[3] for pair in group_pairs if pair[2]]
            far, passed = rates(different, same, candidate)
            conditions.append({"corpus": corpus, "sampleRate": rate, "role": ROLES[corpus], "speakers": len(corpus_speakers[corpus]), "independentClips": len(corpus_speakers[corpus]) * 3, "impostorPairs": len(different), "sameSpeakerPairs": len(same), "falseAccepts": sum(score >= candidate for score in different), "sameSpeakerPasses": sum(score >= candidate for score in same), "falseAcceptRate": far, "sameSpeakerPassRate": passed, "maximumImpostorScore": max(different)})
    if not conditions_pass(conditions):
        chosen = None
    all_impostor = [pair[3] for pair in pairs if not pair[2]]
    all_own = [pair[3] for pair in pairs if pair[2]]
    all_far, all_passed = rates(all_impostor, all_own, candidate)
    margin = {"policy": MARGIN_POLICY, "rule": "99.9th percentile of pooled dev-clean and test-clean impostor scores at both rates (linear interpolation at (n-1)*0.999) + max(0.002, measured cross-runtime drift), rounded up to 0.01 using decimal ceiling. Freeze before disjoint validation. Publish only if every corpus/rate has FAR <= 0.005 and same-speaker pass >= 0.95.", "percentileProbability": PERCENTILE, "percentileMethod": PERCENTILE_METHOD, "percentileCalibrationImpostorScore": calibration_percentile(impostor), "roundingIncrement": ROUNDING_INCREMENT, "absoluteFloor": MARGIN_FLOOR, "crossRuntimeDrift": 0.0, "driftBasis": "Not applicable: all embeddings and cosine scores use the production Swift helper and official ONNX Runtime 1.19.2 CPU; no Python scoring path. The 0.002 floor remains in force.", "maximumCalibrationImpostorScore": max(impostor), "candidateThreshold": candidate, "farLimit": FAR_LIMIT, "sameSpeakerMinimum": OWN_LIMIT}
    report = {
        "schema": "voxclip-speaker-calibration/2", "date": args.date, "model": entry["id"],
        "modelSha256": digest(args.model), "vadSha256": digest(args.vad), "preprocessing": VERSION,
        "runtime": "production Swift / ONNX Runtime 1.19.2 CPU", "language": "en",
        "cliSha256": digest(args.cli),
        "decoder": subprocess.check_output([args.ffmpeg, "-version"], text=True).splitlines()[0],
        "corpusArchives": [{"corpus": corpus, "url": f"https://www.openslr.org/resources/12/{corpus}.tar.gz", "sha256": ARCHIVES[corpus]} for corpus in corpora],
        "corpus": "LibriSpeech dev-clean + test-clean; dev-other + test-other speaker-disjoint validation (OpenSLR 12, CC BY 4.0)" if args.harder else "LibriSpeech dev-clean + test-clean (OpenSLR 12, CC BY 4.0)", "clipSeconds": 6,
        "selection": "Sorted speaker/chapter/utterance; first four utterances at least 6 s; first three with at least 3 s Silero speech at both 48000 and 44100 Hz. Each pair uses different utterances. Rate renders and pairs are correlated, not independent trials.",
        "speakers": sum(len(value) for value in corpus_speakers.values()), "calibrationSpeakers": sum(len(value) for key, value in corpus_speakers.items() if ROLES[key] == "calibration"),
        "independentClips": len({item["source"] for item in selected}), "audioRenders": len(selected),
        "clips": [{key: value for key, value in item.items() if key not in ["wav", "group"]} | {"wavSha256": digest(pathlib.Path(item["wav"]))} for item in selected],
        "impostorPairs": len(all_impostor), "sameSpeakerPairs": len(all_own), "conditions": conditions, "margin": margin,
        "threshold": candidate if chosen else None, "falseAcceptRate": all_far, "sameSpeakerPassRate": all_passed,
        "curveColumns": ["threshold", "falseAcceptRate", "sameSpeakerPassRate"], "curve": curve,
        "validationCurve": [[point[0], *rates(all_impostor, all_own, point[0])] for point in curve],
        "limitations": ["Calibration pairs share speakers and clips; rate renders are not independent recordings. Counts are not independent statistical trials.", "Clean calibration and disjoint harder read-speech validation are not microphone acceptance, spoof resistance or a held-out field-accuracy claim.", "Estonian calibration remains owed.", "User own-voice check on this Mac microphone is owed."]
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    (args.report.parent / "calibration-pairs.json").write_text(json.dumps(pairs, separators=(",", ":")) + "\n")
    if args.update_catalog:
        catalog = json.loads(CATALOG.read_text())
        model = catalog["models"][0]
        model["preprocessing"] = VERSION
        model["threshold"] = candidate if chosen else None
        model["calibration"] = {"date": args.date, "preprocessing": VERSION, "modelSha256": digest(args.model), "vadSha256": digest(args.vad), "outcome": "passed" if chosen else "withheld", "margin": margin, "languages": [{"language": "en", "corpus": report["corpus"], "speakers": report["speakers"], "calibrationSpeakers": report["calibrationSpeakers"], "independentClips": report["independentClips"], "audioRenders": len(selected), "impostorPairs": len(all_impostor), "sameSpeakerPairs": len(all_own), "falseAcceptRate": all_far, "sameSpeakerPassRate": all_passed, "conditions": conditions}]}
        CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: report[key] for key in ["speakers", "independentClips", "impostorPairs", "sameSpeakerPairs", "threshold", "falseAcceptRate", "sameSpeakerPassRate"]}), flush=True)
    if not chosen:
        print("No threshold satisfies the conservative margin and every calibration/validation condition. Cloning remains unavailable.", file=sys.stderr)
        return 2
    return 0


def render(ffmpeg, source, target, rate):
    subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(source), "-t", "6", "-ac", "1", "-ar", str(rate), "-c:a", "pcm_s16le", str(target)], check=True)
    with wave.open(str(target), "rb") as audio:
        if audio.getnframes() < rate * 6:
            raise ValueError("Excerpt render is shorter than six seconds: " + str(target))


def et_condition(group, rate, group_pairs, speakers, threshold):
    different = [pair[3] for pair in group_pairs if not pair[2]]
    same = [pair[3] for pair in group_pairs if pair[2]]
    far, passed = rates(different, same, threshold)
    return {"corpus": group, "sampleRate": rate, "role": riigikogu.ROLES[group], "speakers": speakers, "independentClips": speakers * 3, "impostorPairs": len(different), "sameSpeakerPairs": len(same), "falseAccepts": sum(score >= threshold for score in different), "sameSpeakerPasses": sum(score >= threshold for score in same), "falseAcceptRate": far, "sameSpeakerPassRate": passed, "maximumImpostorScore": max(different)}


def calibrate_et(args):
    """Estonian et-v1: `--phase fit` scores only rk-cal-a/b and freezes tau; `--phase validate` reads the committed frozen report and never refits."""
    entry = verify_assets(args.model, args.vad)
    manifest = json.loads(args.excerpts.read_text())
    if (manifest["policy"], manifest["revision"]) != (riigikogu.POLICY, riigikogu.REVISION):
        raise ValueError("Excerpts are for another policy or revision")
    pairs_path = args.report.parent / "calibration-pairs-et.json"
    fit = args.phase == "fit"
    groups = [group for group in riigikogu.GROUPS if (riigikogu.ROLES[group] == "calibration") == fit]
    hashes = {"modelSha256": digest(args.model), "vadSha256": digest(args.vad), "cliSha256": digest(args.cli), "preprocessing": VERSION,
              "decoder": subprocess.check_output([args.ffmpeg, "-version"], text=True).splitlines()[0]}
    if not fit:
        frozen = json.loads(args.report.read_text())
        frozen_pairs = json.loads(pairs_path.read_text())
        if frozen.get("status") != "frozen-before-validation" or any(frozen[key] != value for key, value in hashes.items()):
            raise ValueError("Validation needs the committed frozen calibration from the same model, VAD, CLI and decoder")
        if any(riigikogu.ROLES[pair[4].rsplit("-", 1)[0]] != "calibration" for pair in frozen_pairs):
            raise ValueError("The frozen calibration must contain calibration pairs only")
        if frozen["margin"]["candidateThreshold"] != candidate_threshold([pair[3] for pair in frozen_pairs if not pair[2]]):
            raise ValueError("The frozen candidate does not match its calibration pairs")
    speakers = [speaker for speaker in manifest["speakers"] if speaker["group"] in groups]
    renders = args.work / "renders"
    renders.mkdir(parents=True, exist_ok=True)
    items = []
    for speaker in speakers:
        for candidate in speaker["candidates"]:
            source = pathlib.Path(candidate["wav"])
            if digest(source) != candidate["sha256"]:
                raise ValueError("Excerpt changed: " + candidate["id"])
            for rate in RATES:
                identity = f'{candidate["id"]}-{rate}'
                target = renders / (identity + ".wav")
                render(args.ffmpeg, source, target, rate)
                items.append({"id": identity, "candidate": candidate["id"], "source": candidate["source"], "speaker": speaker["key"], "corpus": speaker["group"], "sampleRate": rate, "group": f'{speaker["group"]}-{rate}', "wav": str(target), "excerptSha256": candidate["sha256"]})
    output = args.work / ("preprocessed-" + args.phase)
    prepared = preprocess(args.cli, args.vad, items, output)
    voiced = {}
    for item in items:
        voiced.setdefault(item["candidate"], []).append(bool(prepared[item["id"]].get("embedding")))
    chosen, rejected = riigikogu.assemble(speakers, lambda identity: voiced[identity] == [True, True], groups)
    kept = {candidate["id"] for members in chosen.values() for member in members for candidate in member["candidates"]}
    selected = [item for item in items if item["candidate"] in kept]
    by_id = {item["id"]: item for item in selected}
    pairs = []
    for score in json.loads((output / "scores.json").read_text()):
        left, right = by_id.get(score["left"]), by_id.get(score["right"])
        if left is None or right is None:
            continue
        if left["source"] == right["source"] or left["group"] != right["group"]:
            raise ValueError("A pair must use distinct source utterances within one condition")
        pairs.append([left["id"], right["id"], left["speaker"] == right["speaker"], score["value"], left["group"]])
    clips = [{key: item[key] for key in ["id", "source", "speaker", "corpus", "sampleRate"]} | {"wavSha256": digest(pathlib.Path(item["wav"])), "excerptSha256": item["excerptSha256"]} for item in selected]
    log = [{"group": group, "qualifyingSpeakers": sum(speaker["group"] == group for speaker in manifest["speakers"]), "selectedSpeakers": len(chosen[group])} for group in groups]
    if fit:
        impostor = [pair[3] for pair in pairs if not pair[2]]
        own = [pair[3] for pair in pairs if pair[2]]
        point, curve = choose_threshold(impostor, own)
        candidate = candidate_threshold(impostor)
        conditions = [et_condition(group, rate, [pair for pair in pairs if pair[4] == f"{group}-{rate}"], len(chosen[group]), candidate) for group in groups for rate in RATES]
        margin = {"policy": MARGIN_POLICY, "rule": "99.9th percentile of pooled rk-cal-a and rk-cal-b impostor scores at both rates (linear interpolation at (n-1)*0.999) + max(0.002, measured cross-runtime drift), rounded up to 0.01 using decimal ceiling. Frozen and committed before rk-val-a and rk-val-b are scored. Publish only if every group/rate has FAR <= 0.005 and same-speaker pass >= 0.95 with at least 17 speakers (200 impostor / 50 same-speaker pairs).", "percentileProbability": PERCENTILE, "percentileMethod": PERCENTILE_METHOD, "percentileCalibrationImpostorScore": calibration_percentile(impostor), "roundingIncrement": ROUNDING_INCREMENT, "absoluteFloor": MARGIN_FLOOR, "crossRuntimeDrift": 0.0, "driftBasis": "Not applicable: all embeddings and cosine scores use the production Swift helper and official ONNX Runtime 1.19.2 CPU; no Python scoring path. The 0.002 floor remains in force.", "maximumCalibrationImpostorScore": max(impostor), "candidateThreshold": candidate, "farLimit": FAR_LIMIT, "sameSpeakerMinimum": OWN_LIMIT}
        report = {
            "schema": "voxclip-speaker-calibration/2", "date": args.date, "calibration": "et-v1", "status": "frozen-before-validation",
            "model": entry["id"], **hashes, "runtime": "production Swift / ONNX Runtime 1.19.2 CPU", "language": "et",
            "sources": {"dataset": riigikogu.DATASET, "url": "https://huggingface.co/datasets/" + riigikogu.DATASET, "revision": riigikogu.REVISION, "licence": riigikogu.LICENCE, "attribution": riigikogu.ATTRIBUTION,
                        "audio": manifest["audio"], "transcripts": [[record["path"], record["bytes"], record["sha256"], record["gitBlobSha1"]] for record in manifest["transcripts"]], "transcriptColumns": ["path", "bytes", "sha256", "gitBlobSha1"]},
            "corpus": "Riigikogu plenary sessions, Dec 2017 to May 2025 (TalTechNLP/riigikogu-audio-stenograms-2018-2025, CC BY-SA 3.0): rk-cal-a + rk-cal-b calibration; rk-val-a + rk-val-b speaker-disjoint validation", "clipSeconds": 6,
            "selectionPolicy": riigikogu.POLICY, "policyDocument": "shared/fixtures/voice-lab/speaker/policy-et-v1.md",
            "selection": "Transcript-only: role-prefix-stripped names (typo/hyphen variants merged); qualifying turn >= 10 s; excerpt [turnStart + 2 s, turnStart + 8 s] of the 16 kHz FLAC; greedy 30-session pool, one per date; speakers with qualifying turns in >= 3 pool sessions, numbered rkNNN in SHA-256 order of the normalised name and dealt to rk-cal-a, rk-val-a, rk-cal-b, rk-val-b. Candidates are the first qualifying turn in each of the first four pool sessions by date; keep the first three with at least 3 s Silero speech at both 48000 and 44100 Hz; first 40 complete speakers per group in key order. Same-speaker pairs are cross-session. Rate renders and pairs are correlated, not independent trials.",
            "predeclared": {"targetSpeakersPerGroup": riigikogu.TARGET_SPEAKERS, "minimumSpeakersPerGroup": riigikogu.MINIMUM_SPEAKERS, "minimumPairsPerCell": riigikogu.minimum_pairs(riigikogu.MINIMUM_SPEAKERS), "targetPairsPerCell": riigikogu.minimum_pairs(riigikogu.TARGET_SPEAKERS)},
            "pool": manifest["pool"], "selectionLog": log, "rejectedCandidates": rejected,
            "conditions": conditions, "margin": margin, "calibrationPoint": point, "threshold": None,
            "curveColumns": ["threshold", "falseAcceptRate", "sameSpeakerPassRate"], "curve": curve,
            "clips": clips,
        }
        all_pairs = pairs
    else:
        report = frozen
        candidate = frozen["margin"]["candidateThreshold"]
        conditions = frozen["conditions"] + [et_condition(group, rate, [pair for pair in pairs if pair[4] == f"{group}-{rate}"], len(chosen[group]), candidate) for group in groups for rate in RATES]
        all_pairs = frozen_pairs + pairs
        passed = frozen["calibrationPoint"] is not None and conditions_pass(conditions) and all(condition["speakers"] >= riigikogu.MINIMUM_SPEAKERS for condition in conditions)
        report.update(status="validated", conditions=conditions, threshold=candidate if passed else None, clips=frozen["clips"] + clips,
                      selectionLog=frozen["selectionLog"] + log, rejectedCandidates=frozen["rejectedCandidates"] + rejected)
    all_impostor = [pair[3] for pair in all_pairs if not pair[2]]
    all_own = [pair[3] for pair in all_pairs if pair[2]]
    speaker_keys = {clip["speaker"] for clip in report["clips"]}
    report.update(speakers=len(speaker_keys), calibrationSpeakers=len({clip["speaker"] for clip in report["clips"] if riigikogu.ROLES[clip["corpus"]] == "calibration"}),
                  independentClips=len({clip["source"] for clip in report["clips"]}), audioRenders=len(report["clips"]), impostorPairs=len(all_impostor), sameSpeakerPairs=len(all_own))
    report["falseAcceptRate"], report["sameSpeakerPassRate"] = rates(all_impostor, all_own, report["margin"]["candidateThreshold"])
    report["validationCurve"] = [[point[0], *rates(all_impostor, all_own, point[0])] for point in report["curve"]]
    report["limitations"] = [
        "Calibration pairs share speakers and clips; rate renders are not independent recordings. Counts are not independent statistical trials.",
        "One parliament hall and microphone chain: same-channel impostors and cross-session same-speaker pairs, not consumer microphones, home rooms, field accuracy or spoof resistance.",
        "Labels come from official stenograms with forced-alignment times (within 1 s for over 99% of sentences per the dataset card); interjections or misaligned turns can mislabel an excerpt. No manual curation was applied.",
        "Session keys (session@start-end) are traceable to public speaker names through the public stenograms; no names, name map, transcripts or audio are committed.",
        "Identical names of two different people cannot be separated, and the typo/hyphen merge rule can join two different people with near-identical names.",
        "et-v2 adding Mozilla Common Voice et (consumer microphones), if the product owner provides it, supersedes et-v1 whatever its outcome.",
        "User own-voice check on this Mac microphone is owed; Windows runtime parity is owed.",
    ]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    pairs_path.write_text(json.dumps(all_pairs, separators=(",", ":")) + "\n")
    print(json.dumps({key: report[key] for key in ["status", "speakers", "independentClips", "impostorPairs", "sameSpeakerPairs", "threshold", "falseAcceptRate", "sameSpeakerPassRate"]} | {"candidate": report["margin"]["candidateThreshold"], "selectionLog": report["selectionLog"]}), flush=True)
    for condition in report["conditions"]:
        print(json.dumps({key: condition[key] for key in ["corpus", "sampleRate", "speakers", "falseAccepts", "impostorPairs", "sameSpeakerPasses", "sameSpeakerPairs"]}), flush=True)
    if fit:
        print("Frozen candidate " + str(report["margin"]["candidateThreshold"]) + ". Commit it before running --phase validate.", flush=True)
        return 0
    if report["threshold"] is None:
        print("A condition failed the predeclared gates. Estonian remains unavailable.", file=sys.stderr)
        return 2
    return 0


def parity(args):
    entry = verify_assets(args.model, args.vad)
    if args.check:
        expected = json.loads((FIXTURES / "vectors.json").read_text())
        items = [{"id": item["id"], "wav": str(FIXTURES / (item["id"] + ".wav"))} for item in expected["clips"]]
    else:
        base_ids = ["1089-134686-0000", "1089-134686-0002", "1188-133604-0000", "1188-133604-0001"]
        ids = list(base_ids)
        for source in [base_ids[0], base_ids[2]]:
            for rate in [48_000, 44_100]:
                identity = f"{source}-{rate}"
                subprocess.run([args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(FIXTURES / (source + ".wav")), "-ar", str(rate), "-c:a", "pcm_s16le", str(FIXTURES / (identity + ".wav"))], check=True)
                ids.append(identity)
        items = [{"id": identity, "wav": str(FIXTURES / (identity + ".wav"))} for identity in ids]
    prepared = preprocess(args.cli, args.vad, items, args.work / "parity")
    vectors = []
    for item in items:
        result = prepared[item["id"]]
        with wave.open(item["wav"], "rb") as audio:
            rate = audio.getframerate()
        vectors.append({"id": item["id"], "sha256": digest(pathlib.Path(item["wav"])), "sampleRate": rate, "ranges": result["ranges"], "embedding": result["embedding"]})
    scores = [[item["left"], item["right"], item["value"]] for item in json.loads((args.work / "parity/scores.json").read_text())]
    result = {"schema": "voxclip-speaker-vectors/1", "model": entry["id"], "modelSha256": digest(args.model), "vadSha256": digest(args.vad), "preprocessing": VERSION, "runtime": "production Swift / ONNX Runtime 1.19.2 CPU", "embeddingAbsoluteTolerance": 0.0002, "scoreAbsoluteTolerance": 0.0002, "clips": vectors, "scores": scores}
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
    parser.add_argument("--report", type=pathlib.Path)
    parser.add_argument("--language", choices=["en", "et"], default="en")
    parser.add_argument("--excerpts", type=pathlib.Path, help="Estonian: excerpts.json written by riigikogu.py excerpt")
    parser.add_argument("--phase", choices=["fit", "validate"], help="Estonian: fit and freeze on calibration groups, or validate against the committed frozen candidate")
    parser.add_argument("--date", default="2026-10-29")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--update-catalog", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--harder", action="store_true", help="Evaluate disjoint dev-other and test-other speakers without refitting the clean threshold")
    args = parser.parse_args()
    if args.report is None:
        args.report = FIXTURES / ("calibration-et.json" if args.language == "et" else "calibration-en.json")
    if args.mode == "calibrate" and args.language == "et":
        if args.excerpts is None or args.phase is None or args.update_catalog or args.harder:
            parser.error("Estonian calibration requires --excerpts and --phase, and never updates the catalogue")
        return calibrate_et(args)
    if args.mode == "calibrate" and args.corpus is None:
        parser.error("Calibration requires an already downloaded LibriSpeech root with dev-clean and test-clean")
    return calibrate(args) if args.mode == "calibrate" else parity(args)


if __name__ == "__main__":
    sys.exit(main())

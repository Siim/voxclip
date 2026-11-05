"""Text-to-voice length estimator vectors (ADR-R41): the calibrated prior, its pause rule, the calibration's robust
median and spread, and the p80 word budget. Synthetic texts only. The `real` cases' observed lengths are bin medians
of 78 measured Eleven v4 takes (tools/voice-lab/measure_tts_takes.py, 5 November 2026), never a single take."""
import argparse
import json
import math
import pathlib
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "shared/fixtures/voice-lab/tts-estimator-cases.json"
K, ONSET, SENTENCE, CLAUSE = 1.2, 0.4, 0.5, 0.1
LEAD, TAIL = 0.03, 0.06
SPREAD = 1.15
BOUNDS = (0.25, 4.0)
SPREAD_BOUNDS = (1.05, 1.6)
VOICE_LIMIT, PROJECT_LIMIT, VOICE_WEIGHT = 30, 10, 3
SENTENCE_MARKS, CLAUSE_MARKS = ".!?…。！？", ",;:—–，；："


def length(text):
    return sum(1 for c in unicodedata.normalize("NFC", text) if unicodedata.category(c) in ("Lu", "Ll", "Lt", "Lm", "Lo", "Nd"))


def pause_seconds(text):
    chars = list(unicodedata.normalize("NFC", text))
    total = pending = 0.0
    for index, ch in enumerate(chars):
        if ch in SENTENCE_MARKS:
            pending = max(pending, SENTENCE)
        elif ch in CLAUSE_MARKS:
            pending = max(pending, CLAUSE)
        elif ch == "-":
            joined = 0 < index < len(chars) - 1 and length(chars[index - 1]) > 0 and length(chars[index + 1]) > 0
            if not joined:
                pending = max(pending, CLAUSE)
        elif length(ch) > 0:
            total += pending
            pending = 0.0
    return total


def estimate(text, rate):
    speech = length(text) / (rate * K)
    fixed = LEAD + TAIL + ONSET
    return speech + fixed + pause_seconds(text)


def old_estimate(text, rate):
    punctuation = group = 0.0
    for ch in text:
        pause = 0.22 if ch in SENTENCE_MARKS else 0.12 if ch in CLAUSE_MARKS + "-" else 0.0
        if pause:
            group = max(group, pause)
        else:
            punctuation += group
            group = 0.0
    punctuation += group
    return length(text) / (rate * 1.8) + LEAD + TAIL + punctuation


def quantile(values, p):
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * p
    lower, upper = math.floor(position), math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def robust(ratios, limit):
    kept = [r for r in ratios if math.isfinite(r) and BOUNDS[0] <= r <= BOUNDS[1]][-limit:] if limit > 0 else []
    if len(kept) < 5:
        return kept
    center = quantile(kept, 0.5)
    deviation = quantile([abs(r - center) for r in kept], 0.5) * 1.4826
    if deviation <= 0:
        return kept
    return [r for r in kept if abs(r - center) <= 3 * deviation]


def multiplier(ratios, limit):
    kept = robust(ratios, limit)
    return quantile(kept, 0.5) if len(kept) >= 2 else 1.0


def spread(ratios, limit):
    kept = robust(ratios, limit)
    if len(kept) < 5:
        return SPREAD
    center = quantile(kept, 0.5)
    return min(SPREAD_BOUNDS[1], max(SPREAD_BOUNDS[0], quantile(kept, 0.8) / center))


def merged(project, voice):
    kept = robust(voice, VOICE_LIMIT)
    if len(kept) < 2:
        return list(project)
    return [quantile(kept, 0.5)] * VOICE_WEIGHT + list(project)


def word_target(wps, mult, minimum, maximum, overhead, bridge, spread_value):
    rate = wps * K / mult
    lower = max(0, minimum - overhead) * rate - bridge
    upper = max(0, maximum / spread_value - overhead) * rate - bridge
    low = max(1, int(max(0, min(2000, math.ceil(lower)))))
    return {"minimum": low, "maximum": max(low, min(2000, int(max(0, min(2000, math.floor(upper))))))}


ESTIMATE_ROWS = [
    ("final-mark-is-free", "Hello there.", 11.69),
    ("internal-sentence", "Hello there. We ride", 11.69),
    ("clause-groups", "One, two; three", 11.69),
    ("one-group-largest-pause", "Wait... what?! Yes", 11.69),
    ("joined-hyphen", "A-10 Canary", 9.988221436984691),
    ("spaced-hyphen", "yes - no", 10.0),
    ("em-dash", "Well — fine.", 10.0),
    ("quote-after-mark", "“Quoted.” Next", 12.0),
    ("no-letters", "...", 10.0),
    ("digits", "In 2026 we rode 120 km.", 11.38),
    ("estonian", "Tere, õhtust! Sõidame", 11.0),
    ("cjk", "你好。世界", 6.0),
]
# Bin medians of measured Eleven v4 takes (letters, internal clause marks, speaker letters/s, observed seconds).
REAL_ROWS = [
    ("v4-6-15-letters", "Turn it on now", 11.69, 1.28),
    ("v4-16-25-letters", "Then we ride on the coast", 11.69, 1.84),
    ("v4-26-40-letters", "After this bridge, the road climbs fast", 11.69, 2.60),
    ("v4-41-70-letters", "We left the town early, and the light was still too soft", 11.69, 3.92),
]
REAL_LETTERS = [11, 20, 32, 44]
CALIBRATION_ROWS = [
    ("empty", [], []),
    ("one-sample-is-uncalibrated", [1.2], []),
    ("two-samples-median", [1.2, 1.4], []),
    ("out-of-bounds-dropped", [0.1, 5.0, 1.0, 1.1], []),
    ("outlier-trimmed", [1.0, 1.02, 0.98, 1.05, 0.97, 3.0], []),
    ("project-keeps-last-ten", [2.0, 2.0, 2.0, 1.0, 1.1, 0.9, 1.05, 0.95, 1.0, 1.2, 0.8, 1.0], []),
    ("wide-spread-clamped", [0.5, 0.6, 0.7, 1.0, 1.9, 2.0, 2.1], []),
    ("voice-starts-a-new-project", [], [0.9, 0.95, 1.0, 1.05, 1.1, 0.92]),
    ("two-project-takes-keep-the-voice", [1.3, 1.35], [0.9, 0.95, 1.0, 1.05, 1.1, 0.92]),
    ("project-outweighs-the-voice", [1.3, 1.35, 1.32, 1.28], [0.9, 0.95, 1.0, 1.05, 1.1, 0.92]),
    ("voice-with-one-sample-ignored", [1.3, 1.35], [0.9]),
]
WORD_TARGET_ROWS = [
    ("prior-spread", 2.5, 1.0, 2.0, 3.0, 0.49, 0, SPREAD),
    ("calibrated-and-bridged", 2.4, 1.1, 1.5, 2.5, 0.6, 2, SPREAD),
    ("median-budget", 2.5, 1.0, 2.0, 3.0, 0.49, 0, 1.0),
    ("tight-slot-keeps-one-word", 2.0, 1.0, 0.5, 0.6, 0.49, 0, 1.3),
]


def document():
    estimates = [{"id": i, "text": t, "rate": r, "letters": length(t), "pauseSeconds": pause_seconds(t), "expectedSeconds": estimate(t, r)}
                 for i, t, r in ESTIMATE_ROWS]
    real = []
    for (i, t, r, observed), letters in zip(REAL_ROWS, REAL_LETTERS):
        assert length(t) == letters, (i, length(t))
        real.append({"id": i, "text": t, "rate": r, "observedSeconds": observed, "oldEstimateSeconds": old_estimate(t, r),
                     "expectedSeconds": estimate(t, r)})
    calibration = []
    for i, project, voice in CALIBRATION_ROWS:
        samples = merged(project, voice)
        calibration.append({"id": i, "project": project, "voice": voice, "robustProject": robust(project, PROJECT_LIMIT),
                            "merged": samples, "multiplier": multiplier(samples, PROJECT_LIMIT),
                            "spread": spread(project, PROJECT_LIMIT) if len(robust(project, PROJECT_LIMIT)) >= 5 else spread(voice, VOICE_LIMIT)})
    targets = [{"id": i, "wordsPerSecond": w, "multiplier": m, "minimumSeconds": lo, "maximumSeconds": hi, "overheadSeconds": o,
                "bridgeWords": b, "spread": s, "expected": word_target(w, m, lo, hi, o, b, s)} for i, w, m, lo, hi, o, b, s in WORD_TARGET_ROWS]
    return {"schema": "voxclip-tts-estimator/1", "caseCount": len(estimates) + len(real) + len(calibration) + len(targets),
            "prior": {"version": 2, "providerSpeechRateMultiplier": K, "onsetSeconds": ONSET, "sentencePauseSeconds": SENTENCE,
                      "clausePauseSeconds": CLAUSE, "trimLeadSeconds": LEAD, "trimTailSeconds": TAIL, "priorSpread": SPREAD,
                      "ratioBounds": list(BOUNDS), "spreadBounds": list(SPREAD_BOUNDS), "voiceSampleLimit": VOICE_LIMIT,
                      "projectSampleLimit": PROJECT_LIMIT, "voiceWeight": VOICE_WEIGHT},
            "observed": {"date": "2026-11-05", "takes": 78, "model": "eleven_v4", "note": "bin medians of measured takes; texts are synthetic"},
            "estimates": estimates, "real": real, "calibration": calibration, "wordTargets": targets}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = json.dumps(document(), ensure_ascii=False, indent=2) + "\n"
    if arguments.check:
        if OUTPUT.read_text() != rendered:
            raise SystemExit("tts estimator fixtures drift; run tools/fixtures/voice-lab/generate_tts_estimator.py")
        print("TTS estimator fixture: zero drift")
    else:
        OUTPUT.write_text(rendered)
        print(OUTPUT.relative_to(ROOT))

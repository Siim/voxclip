"""Rewrite slot vectors (ai.md §12.9, ADR-R42): the speaker's words per second, the spans a selection's words make (closed
after a word ending in punctuation or before a 0.3 s pause), each span's seconds and its word budget at the calibrated
prior's p80 (ADR-R43, generate_tts_estimator.py), never more than the span's own words; and the request lines the shared
voice-rewrite prompt renders for them. Synthetic words only."""
import argparse
import hashlib
import json
import pathlib
from decimal import Decimal, ROUND_HALF_UP

import generate_tts_estimator as tts

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "shared/fixtures/voice-lab/rewrite-slot-cases.json"
PROMPT = "shared/prompts/voice-rewrite.json"
PAUSE, MAXIMUM_SLOTS = 0.3, 60
CLOSING = ".,;:!?…—"


def speaking_rate(words):
    seconds = previous_end = 0.0
    letters = 0
    for word in words:
        letters += tts.length(word["text"])
        seconds += max(0.0, word["end"] - max(word["start"], previous_end))
        previous_end = max(previous_end, word["end"])
    return letters / seconds


def words_per_second(words):
    characters = sum(tts.length(word["text"]) for word in words)
    return speaking_rate(words) * len(words) / characters


def slots(words, wps, multiplier, spread):
    spans, current = [], []
    for word in words:
        if current and word["start"] - current[-1]["end"] >= PAUSE:
            spans.append(current)
            current = []
        current.append(word)
        if word["text"] and word["text"][-1] in CLOSING:
            spans.append(current)
            current = []
    if current:
        spans.append(current)
    if not spans or len(spans) > MAXIMUM_SLOTS:
        return None
    result = []
    for span in spans:
        seconds = span[-1]["end"] - span[0]["start"]
        if seconds <= 0:
            continue
        target = tts.word_target(wps, multiplier, 0, seconds, min(tts.ONSET, seconds), 0, spread)
        result.append({"text": " ".join(word["text"] for word in span), "seconds": seconds,
                       "maxWords": max(1, min(target["maximum"], len(span)))})
    return result


def fixed1(value):
    """JavaScript toFixed(1) of the double's exact decimal value, as both apps format seconds."""
    return str(Decimal(value).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))


def timed(texts, length=0.32, gap=0.08, pauses=None):
    pauses = pauses or {}
    words, cursor = [], 1.0
    for index, text in enumerate(texts):
        cursor += pauses.get(index, 0.0)
        words.append({"id": f"w{index}", "text": text, "start": round(cursor, 6), "end": round(cursor + length, 6)})
        cursor += length + gap
    return words


SENTENCE = "So this is the part where we ride along the coast, and honestly the light was perfect. Then the road climbs".split()
SOFT = "we left early and the light was soft".split()
CASES = [
    ("punctuation-closes-spans", timed(SENTENCE), 1.0, tts.SPREAD),
    ("calibrated-voice-tightens", timed(SENTENCE), 1.5, tts.SPREAD),
    ("median-budget", timed(SENTENCE), 1.0, 1.0),
    ("pause-closes-a-span", timed(SOFT, pauses={4: 0.3}), 1.0, tts.SPREAD),
    ("pause-under-the-threshold", timed(SOFT, pauses={4: 0.21}), 1.0, tts.SPREAD),
    ("one-word-span-keeps-one", timed(["Wait.", "then", "go"], length=0.2, gap=0.5), 1.0, tts.SPREAD),
    ("slow-speaker-capped-at-its-words", timed("this is said very slowly".split(), length=0.9, gap=0.1), 1.0, tts.SPREAD),
    ("too-many-spans-sends-none", timed([f"w{index}." for index in range(61)]), 1.0, tts.SPREAD),
]


def document():
    prompt_bytes = (ROOT / PROMPT).read_bytes().replace(b"\r\n", b"\n")
    templates = json.loads(prompt_bytes)["request"]
    cases = []
    for identity, words, multiplier, spread in CASES:
        wps = words_per_second(words)
        expected = slots(words, wps, multiplier, spread)
        block = None
        if expected is not None:
            lines = [templates["slotLine"].replace("{index}", str(index + 1)).replace("{seconds}", fixed1(slot["seconds"]))
                     .replace("{maxWords}", str(slot["maxWords"])).replace("{text}", slot["text"]) for index, slot in enumerate(expected)]
            block = templates["slotsBlock"].replace("{slots}", "\n".join(lines))
        cases.append({"id": identity, "words": words, "multiplier": multiplier, "spread": spread, "wordsPerSecond": wps,
                      "slots": expected, "slotsBlock": block})
    return {"schema": "voxclip-rewrite-slots/1", "caseCount": len(cases),
            "sources": {PROMPT: hashlib.sha256(prompt_bytes).hexdigest()},
            "constants": {"pauseSeconds": PAUSE, "maximumSlots": MAXIMUM_SLOTS, "closing": CLOSING, "onsetSeconds": tts.ONSET,
                          "providerSpeechRateMultiplier": tts.K, "priorSpread": tts.SPREAD},
            "cases": cases}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = json.dumps(document(), ensure_ascii=False, indent=2) + "\n"
    if arguments.check:
        if OUTPUT.read_text() != rendered:
            raise SystemExit("rewrite slot fixtures drift; run tools/fixtures/voice-lab/generate_rewrite_slots.py")
        print("Rewrite slot fixture: zero drift")
    else:
        OUTPUT.write_text(rendered)
        print(OUTPUT.relative_to(ROOT))

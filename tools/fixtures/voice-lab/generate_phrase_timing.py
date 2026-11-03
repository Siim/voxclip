"""Offline phrase-timing reference; recorded VAD measurements, never provider calls."""
import argparse
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "shared/fixtures/voice-lab/phrase-timing-cases.json"


def estimate(text, rate):
    punctuation = 0.0
    group = 0.0
    for character in text:
        pause = 0.22 if character in ".!?…。！？" else 0.12 if character in ",;:—–-，；：" else 0.0
        if pause:
            group = max(group, pause)
        else:
            punctuation += group
            group = 0.0
    punctuation += group
    speech = sum(character.isalnum() for character in text) / (rate * 1.8)
    lead = speech + 0.03
    trimmed = lead + 0.06
    return trimmed + punctuation


def document():
    rate = 9.988221436984691
    rows = [
        ("phrase-1", "And yeah, I'm still going, and I'm not running out of ideas anytime soon. The next idea is adding multiplayer missions to A-10 Canary. The missions are pretty similar to the ones in the original", [11.02, 12.2148125]),
        ("phrase-2", "players can actually work together, choose their team,", [2.6799375]),
        ("phrase-3", "then, well, let's get going.", [1.63]),
    ]
    cases = [{"id": identity, "text": text, "rate": rate, "measuredVoicedSeconds": measured,
              "expectedSeconds": estimate(text, rate)} for identity, text, measured in rows]
    return {"schema": "voxclip-phrase-timing/1", "caseCount": len(cases),
            "calibration": {"date": "2026-11-03", "vad": "SpeakerVAD / Silero 6.2.0 CPU",
                            "vadSha256": "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
                            "providerSpeechRateMultiplier": 1.8, "minorPauseSeconds": 0.12,
                            "sentencePauseSeconds": 0.22, "trimLeadSeconds": 0.03, "trimTailSeconds": 0.06},
            "cases": cases}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = json.dumps(document(), ensure_ascii=False, indent=2) + "\n"
    if arguments.check:
        if OUTPUT.read_text() != rendered:
            raise SystemExit("phrase timing fixtures drift; run tools/fixtures/voice-lab/generate_phrase_timing.py")
        print("Phrase timing fixture: zero drift")
    else:
        OUTPUT.write_text(rendered)
        print(OUTPUT.relative_to(ROOT))

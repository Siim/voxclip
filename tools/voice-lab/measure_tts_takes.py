#!/usr/bin/env python3
"""Measure how real Voice Lab takes run against the text-to-voice length estimator (ADR-R41). Local and read only.

For every paid take under a Voice Lab folder it gets the take's words on device (`voxclip-cli transcribe --engine
whisper` with an isolated data folder that links the installed whisper model), the take's voiced length (first to last
voiced 10 ms frame, widened by the trim lead and tail, as a Rewrite measures a take without alignment) and the
speaker's letters per voiced second from the take's project, when one is given. It prints aggregates only: medians,
IQRs, error tables. It never writes to the Voice Lab folder or the projects, never makes a network call, and deletes
its transcripts when it finishes unless --keep is given. Nothing it prints is per take.

    python3 -I tools/voice-lab/measure_tts_takes.py --cli <voxclip-cli> --shared shared \
        --project <project-id>=<path.voxclip> [--project ...] [--v4-from 2026-11-03T11:00]
"""
import argparse
import datetime
import json
import math
import os
import re
import shutil
import statistics
import struct
import subprocess
import unicodedata

LEAD, TAIL, VOICED = 0.03, 0.06, 0.005623413251903491
SENT, CLAUSE = ".!?…。！？", ",;:—–，；："
# The current prior (VoiceLabPhraseTiming): k, onset, internal sentence pause, internal clause pause.
PRIOR = (1.2, 0.4, 0.5, 0.1)


def length(text):
    return sum(1 for c in unicodedata.normalize("NFC", text) if unicodedata.category(c) in ("Lu", "Ll", "Lt", "Lm", "Lo", "Nd"))


def syllables(word):
    w = re.sub(r"[^a-z]", "", word.lower())
    if not w:
        return 1 if any(ch.isdigit() for ch in word) else 0
    n = len(re.findall(r"[aeiouy]+", w))
    if w.endswith("e") and not w.endswith(("le", "ee")) and n > 1:
        n -= 1
    return max(1, n)


def marks(text):
    """Internal sentence and clause groups (followed by more speech), as the estimator counts them."""
    sentences = clauses = pending = 0
    chars = list(unicodedata.normalize("NFC", text))
    for i, ch in enumerate(chars):
        if ch in SENT:
            pending = max(pending, 2)
        elif ch in CLAUSE or (ch == "-" and not (0 < i < len(chars) - 1 and length(chars[i - 1]) and length(chars[i + 1]))):
            pending = max(pending, 1)
        elif length(ch):
            sentences += pending == 2
            clauses += pending == 1
            pending = 0
    return sentences, clauses


def old_pauses(text):
    total = group = 0.0
    for ch in text:
        p = 0.22 if ch in SENT else 0.12 if ch in CLAUSE + "-" else 0
        if p:
            group = max(group, p)
        else:
            total += group
            group = 0
    return total + group


def read_wav(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a WAV")
    pos, fmt = 12, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            fmt = (tag, ch, rate, bits)
        elif cid == b"data" and fmt:
            tag, ch, rate, bits = fmt
            if tag == 3 or (tag == 0xFFFE and bits == 32):
                values = struct.unpack(f"<{len(body) // 4}f", body[:len(body) // 4 * 4])
            elif bits == 16:
                values = [v / 32768 for v in struct.unpack(f"<{len(body) // 2}h", body[:len(body) // 2 * 2])]
            else:
                raise ValueError("unsupported WAV")
            return rate, values[::ch]
        pos += 8 + size + (size & 1)
    raise ValueError("no audio")


def voiced_seconds(rate, samples):
    frame = max(1, round(rate * 0.01))
    levels = [math.sqrt(sum(x * x for x in samples[s:s + frame]) / frame) for s in range(0, len(samples) - frame + 1, frame)]
    voiced = [i for i, level in enumerate(levels) if level > VOICED]
    if not voiced:
        return None
    start = max(0, voiced[0] * frame / rate - LEAD)
    end = min(len(samples) / rate, (voiced[-1] + 1) * frame / rate + TAIL)
    return end - start


def speaker_rates(words):
    seconds = letters = syll = 0
    previous = 0.0
    for word in words:
        if word.get("kind") != "word":
            continue
        letters += length(word["text"])
        syll += syllables(word["text"])
        seconds += max(0, word["end"] - max(word["start"], previous))
        previous = max(previous, word["end"])
    return letters / seconds, syll / seconds


def quantile(values, p):
    v = sorted(values)
    k = (len(v) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def summary(values):
    return (f"n={len(values)} median={statistics.median(values):.3f} IQR=[{quantile(values, .25):.3f}, {quantile(values, .75):.3f}] "
            f"p10={quantile(values, .1):.3f} p90={quantile(values, .9):.3f}")


def score(name, predicted, rows):
    errors = [p - r["measured"] for p, r in zip(predicted, rows)]
    pct = [abs(e) / r["measured"] for e, r in zip(errors, rows)]
    bias = statistics.median(e / r["measured"] for e, r in zip(errors, rows))
    print(f"  {name:34s} MAE {statistics.mean(abs(e) for e in errors):.2f} s  MAPE {100 * statistics.mean(pct):.0f}%  "
          f"within ±15% {100 * sum(p <= .15 for p in pct) / len(pct):.0f}%  median bias {100 * bias:+.0f}%")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cli", required=True)
    parser.add_argument("--shared", required=True)
    parser.add_argument("--voice-lab", default=os.path.expanduser("~/Library/Application Support/VoxClip/VoiceLab"))
    parser.add_argument("--models", default=os.path.expanduser("~/Library/Application Support/VoxClip/Models"))
    parser.add_argument("--project", action="append", default=[], help="<project-id>=<path.voxclip>, read only")
    parser.add_argument("--v4-from", default="2026-11-03T11:00", help="takes written from this local time on are Eleven v4")
    parser.add_argument("--scratch", default="/tmp/voxclip-measure-tts-takes")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    v4_from = datetime.datetime.fromisoformat(args.v4_from).timestamp()
    data = os.path.join(args.scratch, "data")
    out = os.path.join(args.scratch, "out")
    os.makedirs(os.path.join(data, "Models"), exist_ok=True)
    os.makedirs(out, exist_ok=True)
    link = os.path.join(data, "Models", "whispercpp")
    if not os.path.islink(link):
        os.symlink(os.path.join(args.models, "whispercpp"), link)
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "VOXCLIP_NO_KEYCHAIN": "1",
           "VOXCLIP_DATA_DIR": os.path.abspath(data), "VOXCLIP_SHARED_DIR": os.path.abspath(args.shared)}
    rates = {}
    for item in args.project:
        pid, path = item.split("=", 1)
        with open(path) as handle:
            rates[pid] = speaker_rates(json.load(handle)["transcript"]["words"])
    pooled = (statistics.median(r[0] for r in rates.values()), statistics.median(r[1] for r in rates.values())) if rates else None
    print("speaker letters/s per project:", [round(r[0], 2) for r in rates.values()])
    rows, skipped = [], 0
    for folder in sorted(os.listdir(args.voice_lab)):
        path = os.path.join(args.voice_lab, folder)
        if not os.path.isdir(path) or not re.fullmatch(r"[0-9a-f-]{36}", folder):
            continue
        speaker = rates.get(folder, pooled)
        if speaker is None:
            continue
        for name in sorted(os.listdir(path)):
            if not name.endswith(".wav") or name.startswith("."):
                continue
            wav = os.path.join(path, name)
            transcript = os.path.join(out, f"{folder}__{name[:-4]}.voxclip")
            if not os.path.exists(transcript):
                done = subprocess.run(["nice", "-n", "10", args.cli, "transcribe", "--open", wav, "--engine", "whisper", "--language", "en",
                                       "--out", transcript, "--json", "--quiet"], env=env, capture_output=True, text=True)
                if done.returncode:
                    skipped += 1
                    continue
            with open(transcript) as handle:
                words = [w for w in json.load(handle)["transcript"]["words"] if w.get("kind") == "word"]
            rate, samples = read_wav(wav)
            seconds = voiced_seconds(rate, samples)
            text = " ".join(w["text"] for w in words)
            letters = length(text)
            confidence = statistics.mean((w.get("conf") or 0) for w in words) if words else 0
            # A whisper miss or a cut-off take is not a pace: too few words, low confidence or an impossible rate.
            if len(words) < 2 or not seconds or letters < 6 or confidence < .6 or not 4 <= letters / max(.05, seconds - LEAD - TAIL) <= 30:
                skipped += 1
                continue
            s, c = marks(text)
            rows.append({"model": "v4" if os.path.getmtime(wav) >= v4_from else "pre-v4", "measured": seconds, "letters": letters,
                         "syll": sum(syllables(w["text"]) for w in words), "speaker": speaker[0], "sspk": speaker[1], "s": s, "c": c,
                         "old": letters / (speaker[0] * 1.8) + LEAD + TAIL + old_pauses(text)})
    print(f"takes measured {len(rows)}, skipped {skipped}")
    k, onset, sentence, clause = PRIOR
    for model in ("v4", "pre-v4", "all"):
        sel = [r for r in rows if model == "all" or r["model"] == model]
        if len(sel) < 5:
            continue
        plain = [r for r in sel if r["s"] == 0 and r["c"] == 0]
        print(f"[{model}] n={len(sel)}")
        print("  measured ÷ old estimate:", summary([r["measured"] / r["old"] for r in sel]))
        if plain:
            print("  provider ÷ speaker letters/s (no internal marks):",
                  summary([r["letters"] / (r["measured"] - LEAD - TAIL) / r["speaker"] for r in plain]))
        new = [r["letters"] / (r["speaker"] * k) + LEAD + TAIL + onset + sentence * r["s"] + clause * r["c"] for r in sel]
        print("  measured ÷ new estimate:", summary([r["measured"] / n for r, n in zip(sel, new)]),
              f"p80/p50={quantile([r['measured'] / n for r, n in zip(sel, new)], .8) / statistics.median(r['measured'] / n for r, n in zip(sel, new)):.3f}")
        score("old prior (1.8, .22/.12)", [r["old"] for r in sel], sel)
        score("new prior", new, sel)
        syl_k = statistics.median(r["syll"] / (r["measured"] - LEAD - TAIL - onset) / r["sspk"] for r in sel if r["measured"] - LEAD - TAIL - onset > .2)
        score("syllables, same onset and pauses", [r["syll"] / (r["sspk"] * syl_k) + LEAD + TAIL + onset + sentence * r["s"] + clause * r["c"] for r in sel], sel)
    if not args.keep:
        shutil.rmtree(os.path.join(args.scratch, "out"), ignore_errors=True)


if __name__ == "__main__":
    main()

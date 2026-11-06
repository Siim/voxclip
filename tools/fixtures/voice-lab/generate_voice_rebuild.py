"""Rebuild-from-my-videos vectors (voice-lab.md §6.12, ADR-R44; the per-video floor of §6.13, ADR-R45): which owner-verified stretches a
rebuilt clone is made from, in the order they are sent, and the line shown before any click.

`pick` keeps a candidate only when its score passes τ against the voice's own embedding (one hop), its SNR reaches the floor and it lasts
5–30 s. Round 1 takes each video's cleanest piece (SNR, then score, then video, then start), the videos ordered by that piece's score;
round 2 repeatedly takes the remaining piece whose highest cosine to the chosen ones is lowest (ties: the cleaner one, in candidate
order). A piece that would pass 24 files or 120 s is skipped; the kept consent clip counts toward both.

Pure binary64 arithmetic in a fixed order, as both Cores compute it: a vector is normalized by the square root of its sum of squares
(each term in binary64, summed in order) and each element rounded to binary32; a cosine is the binary64 sum, in order, of the products
of two normalized vectors, clamped to [-1, 1]. Embeddings are small four-element vectors normalized that way, stored as consent records
store them (little-endian binary32, base64). Synthetic only."""
import argparse
import base64
import json
import math
import pathlib
import struct

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "shared/fixtures/voice-lab/voice-rebuild-cases.json"
THRESHOLD = 0.45
MAXIMUM_FILES, MINIMUM_TOTAL_MS, MAXIMUM_TOTAL_MS = 24, 30_000, 120_000
MINIMUM_PIECE_MS, MAXIMUM_PIECE_MS, MINIMUM_SNR_DB, PER_VIDEO_SNR_DB = 5_000, 30_000, 20.0, 8.0
CANDIDATES_PER_VIDEO = 6


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def normalized(vector):
    norm = 0.0
    for value in vector:
        norm += float(value) * float(value)
    norm = math.sqrt(norm)
    return [f32(float(value) / norm) for value in vector]


def cosine(left, right):
    left, right = normalized(left), normalized(right)
    score = 0.0
    for a, b in zip(left, right):
        score += a * b
    return min(1.0, max(-1.0, score))


def encode(vector):
    return base64.b64encode(b"".join(struct.pack("<f", value) for value in vector)).decode("ascii")


def unit(*values):
    return normalized([float(value) for value in values])


def candidate(video, start, end, snr, score, *direction):
    return {"video": video, "startMs": start, "endMs": end, "snrDb": snr, "score": score, "embedding": encode(unit(*direction))}


def decode(text):
    data = base64.b64decode(text)
    return [struct.unpack("<f", data[index:index + 4])[0] for index in range(0, len(data), 4)]


def cleaner_key(item):
    return (-item["snrDb"], -item["score"], item["video"], item["startMs"])


def same(a, b):
    return all(a[key] == b[key] for key in ("video", "startMs", "endMs", "snrDb", "score", "embedding"))


def pick(candidates, threshold, kept_ms=None, floor=MINIMUM_SNR_DB):
    rejected, pool = {}, []
    for item in candidates:
        duration = item["endMs"] - item["startMs"]
        if not item["score"] >= threshold:
            reason = "notTheOwner"
        elif not item["snrDb"] >= floor:
            reason = "noisy"
        elif not MINIMUM_PIECE_MS <= duration <= MAXIMUM_PIECE_MS:
            reason = "length"
        else:
            reason = None
        if reason:
            rejected[reason] = rejected.get(reason, 0) + 1
        else:
            pool.append(item)
    chosen, total, files = [], kept_ms or 0, 0 if kept_ms is None else 1

    def fits(item):
        return files < MAXIMUM_FILES and total + item["endMs"] - item["startMs"] <= MAXIMUM_TOTAL_MS

    videos = {}
    for item in pool:
        videos.setdefault(item["video"], []).append(item)
    firsts = sorted((sorted(group, key=cleaner_key)[0] for group in videos.values()), key=lambda item: (-item["score"],) + cleaner_key(item))
    for item in firsts:
        if fits(item):
            chosen.append(item)
            total += item["endMs"] - item["startMs"]
            files += 1
    remaining = [item for item in pool if not any(same(item, other) for other in chosen)]
    while remaining:
        best = None
        for index, item in enumerate(remaining):
            if not fits(item):
                continue
            closeness = max((cosine(decode(other["embedding"]), decode(item["embedding"])) for other in chosen), default=-1)
            if best is None or closeness < best[1] or closeness == best[1] and cleaner_key(item) < cleaner_key(remaining[best[0]]):
                best = (index, closeness)
        if best is None:
            break
        item = remaining.pop(best[0])
        chosen.append(item)
        total += item["endMs"] - item["startMs"]
        files += 1
    if remaining:
        rejected["full"] = rejected.get("full", 0) + len(remaining)
    total_ms = (kept_ms or 0) + sum(item["endMs"] - item["startMs"] for item in chosen)
    return {"pieces": [[item["video"], item["startMs"]] for item in chosen], "keptMs": kept_ms, "rejected": dict(sorted(rejected.items())),
            "totalMs": total_ms, "videoCount": len({item["video"] for item in chosen}), "fileCount": len(chosen) + (0 if kept_ms is None else 1),
            "enough": total_ms >= MINIMUM_TOTAL_MS, "summary": summary(total_ms, len({item["video"] for item in chosen}), kept_ms is not None)}


def amount(milliseconds):
    seconds = max(0, milliseconds) // 1000
    minutes, rest = seconds // 60, seconds % 60
    if minutes == 0:
        return f"{rest} s"
    return f"{minutes} min" if rest == 0 else f"{minutes} min {rest} s"


def summary(total_ms, videos, kept):
    return f"{amount(total_ms)} from {'1 video' if videos == 1 else f'{videos} videos'}{' and your consent clip' if kept else ''}"


def document():
    cases = []

    def add(name, candidates, kept_ms=None, floor=MINIMUM_SNR_DB):
        cases.append({"kind": "pick", "name": name, "threshold": THRESHOLD, "keptMs": kept_ms, "minimumSnrDb": floor,
                      "candidates": candidates, "expected": pick(candidates, THRESHOLD, kept_ms, floor)})

    add("only-the-owners-clean-speech-of-the-right-length", [
        candidate("video-a", 0, 12_000, 24.0, 0.80, 1, 0, 0, 0),
        candidate("video-a", 20_000, 32_000, 26.0, 0.30, 1, 1, 0, 0),
        candidate("video-a", 40_000, 52_000, 12.0, 0.90, 1, 0, 1, 0),
        candidate("video-a", 60_000, 64_000, 30.0, 0.90, 1, 0, 0, 1),
        candidate("video-a", 70_000, 101_000, 30.0, 0.90, 2, 1, 0, 0),
        candidate("video-a", 110_000, 140_000, 22.0, 0.60, 1, 2, 0, 0),
    ], kept_ms=27_720)
    add("every-video-once-before-any-repeats-then-the-most-different", [
        candidate("video-a", 0, 20_000, 30.0, 0.70, 1, 0, 0, 0),
        candidate("video-a", 30_000, 50_000, 28.0, 0.75, 1, 0.1, 0, 0),
        candidate("video-a", 60_000, 80_000, 22.0, 0.60, 0, 0, 1, 0),
        candidate("video-b", 0, 20_000, 25.0, 0.90, 0, 1, 0, 0),
        candidate("video-b", 30_000, 50_000, 24.0, 0.85, 0.2, 1, 0, 0),
        candidate("video-c", 5_000, 25_000, 21.0, 0.50, 0, 0, 0, 1),
    ])
    add("ties-go-to-snr-score-video-then-start", [
        candidate("video-b", 10_000, 20_000, 25.0, 0.70, 1, 0, 0, 0),
        candidate("video-a", 30_000, 40_000, 25.0, 0.70, 1, 0, 0, 0),
        candidate("video-a", 10_000, 20_000, 25.0, 0.70, 1, 0, 0, 0),
        candidate("video-b", 30_000, 40_000, 25.0, 0.70, 1, 0, 0, 0),
    ])
    add("a-piece-past-120-s-is-skipped-and-a-shorter-one-still-fits", [
        candidate("video-a", 0, 30_000, 30.0, 0.80, 1, 0, 0, 0),
        candidate("video-b", 0, 30_000, 29.0, 0.80, 0, 1, 0, 0),
        candidate("video-c", 0, 30_000, 28.0, 0.80, 0, 0, 1, 0),
        candidate("video-a", 40_000, 70_000, 27.0, 0.80, 0, 0, 0, 1),
        candidate("video-b", 40_000, 55_000, 26.0, 0.80, 1, 1, 0, 0),
        candidate("video-c", 40_000, 45_000, 25.0, 0.80, 1, 0, 1, 0),
    ], kept_ms=10_000)
    add("at-most-24-files-with-the-consent-clip", [
        candidate(f"video-{index:02d}", 0, 5_000, 30.0 - index * 0.25, 0.80, 1, index % 3, index % 5, index % 7) for index in range(26)
    ], kept_ms=5_000)
    add("too-little-clean-speech-is-not-enough", [
        candidate("video-a", 0, 9_000, 25.0, 0.80, 1, 0, 0, 0),
        candidate("video-a", 20_000, 32_000, 15.0, 0.80, 0, 1, 0, 0),
    ], kept_ms=None)
    add("the-per-video-floor-admits-cleaner-noisy-speech-never-another-voice", [
        candidate("video-a", 72_400, 82_000, 8.83, 0.47, 1, 0, 0, 0),
        candidate("video-a", 83_400, 100_200, 8.84, 0.48, 1, 1, 0, 0),
        candidate("video-a", 101_400, 116_000, 11.31, 0.49, 1, 0, 1, 0),
        candidate("video-a", 117_000, 137_000, 15.4, 0.40, 0, 0, 0, 1),
        candidate("video-a", 172_300, 184_500, 6.70, 0.45, 1, 0, 0, 1),
    ], kept_ms=27_720, floor=PER_VIDEO_SNR_DB)
    amounts = [0, 999, 27_720, 59_999, 60_000, 68_000, 120_000, 190_500, -5]
    cases.append({"kind": "amount", "name": "whole-seconds-as-minutes-and-seconds", "milliseconds": amounts,
                  "expected": [amount(value) for value in amounts]})
    return {"schema": "voxclip-voice-rebuild/1",
            "description": "Rebuild from my videos (doc/spec/voice-lab.md section 6.12, ADR-R44; the per-video floor of section 6.13, ADR-R45): the "
                           "pieces a rebuilt voice is made from and the line shown first. Generated by tools/fixtures/voice-lab/generate_voice_rebuild.py.",
            "constants": {"threshold": THRESHOLD, "maximumFiles": MAXIMUM_FILES, "minimumTotalMs": MINIMUM_TOTAL_MS, "maximumTotalMs": MAXIMUM_TOTAL_MS,
                          "minimumPieceMs": MINIMUM_PIECE_MS, "maximumPieceMs": MAXIMUM_PIECE_MS, "minimumSnrDb": MINIMUM_SNR_DB,
                          "perVideoMinimumSnrDb": PER_VIDEO_SNR_DB, "candidatesPerVideo": CANDIDATES_PER_VIDEO},
            "caseCount": len(cases), "cases": cases}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = json.dumps(document(), ensure_ascii=False, indent=2) + "\n"
    if arguments.check:
        if OUTPUT.read_text() != rendered:
            raise SystemExit("voice rebuild fixtures drift; run tools/fixtures/voice-lab/generate_voice_rebuild.py")
        print("Voice rebuild fixture: zero drift")
    else:
        OUTPUT.write_text(rendered)
        print(OUTPUT.relative_to(ROOT))

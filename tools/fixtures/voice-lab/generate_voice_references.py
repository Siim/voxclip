"""Voice reference vectors (voice-lab.md §6.9, ADR-R41 "Let a video teach your voice"): which learned references the use-time guard
may use, how a phrase's speech matches the owner through them, and how learning one changes the speaker block. Every reference passed
against the record's own embedding when it was learned and still does: one hop, never a chain; τ never changes.

Pure binary64 arithmetic in a fixed order, as both Cores compute it: a vector is normalized by the square root of its sum of squares
(each term in binary64, summed in order) and each element rounded to binary32; a cosine is the binary64 sum, in order, of the products
of two normalized vectors, clamped to [-1, 1]. Embeddings are four-element integer vectors normalized that way, stored as the consent
record stores them (little-endian binary32, base64). Synthetic only."""
import argparse
import base64
import json
import math
import pathlib
import struct

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "shared/fixtures/voice-lab/voice-references-cases.json"
BOUND, THRESHOLD, MODEL = 16, 0.45, "wespeaker-resnet34"
LEARNED_AT = "2026-11-05T12:00:00Z"


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


OWNER = unit(1, 0, 0, 0)


def reference(vector, key, score=None, model=MODEL, added=LEARNED_AT):
    return {"embedding": encode(vector), "contentKey": key, "addedAt": added,
            "statementScore": cosine(OWNER, vector) if score is None else score, "model": model}


def speaker(references=None, owner=OWNER):
    block = {"model": MODEL, "threshold": THRESHOLD, "embedding": encode(owner)}
    if references:
        block["references"] = references
    return block


def decode(text):
    data = base64.b64decode(text)
    return [struct.unpack("<f", data[index:index + 4])[0] for index in range(0, len(data), 4)]


def usable(block):
    owner = decode(block["embedding"])
    keys = []
    for item in block.get("references", []):
        vector = decode(item["embedding"])
        if item["model"] != block["model"] or item["statementScore"] < block["threshold"] or len(vector) != len(owner):
            continue
        if cosine(owner, vector) >= block["threshold"]:
            keys.append(item["contentKey"])
    return keys


def match(block, candidate):
    statement = cosine(decode(block["embedding"]), candidate)
    if statement >= block["threshold"]:
        return {"kind": "statement", "score": statement, "contentKey": None}
    best = None
    keys = usable(block)
    for item in block.get("references", []):
        if item["contentKey"] not in keys:
            continue
        score = cosine(decode(item["embedding"]), candidate)
        if score >= block["threshold"] and score > (best["score"] if best else -1):
            best = {"kind": "reference", "score": score, "contentKey": item["contentKey"]}
    return best


def most_redundant(references):
    vectors = [decode(item["embedding"]) for item in references]
    worst, worst_key = 0, (-math.inf, math.inf, "")
    for index, vector in enumerate(vectors):
        closest = -math.inf
        for other, other_vector in enumerate(vectors):
            if other != index:
                closest = max(closest, cosine(vector, other_vector))
        key = (closest, references[index]["statementScore"], references[index]["addedAt"])
        if key[0] != worst_key[0]:
            worse = key[0] > worst_key[0]
        elif key[1] != worst_key[1]:
            worse = key[1] < worst_key[1]
        else:
            worse = key[2] < worst_key[2]
        if worse:
            worst, worst_key = index, key
    return worst


def learning(block, vector, key, model, at):
    if model != block["model"]:
        return {"refusal": "otherModel"}
    learned = normalized(vector)
    score = cosine(decode(block["embedding"]), learned)
    if score < block["threshold"]:
        return {"refusal": "notTheOwner"}
    kept = [item for item in block.get("references", []) if item["model"] == block["model"]]
    existing = next((item for item in kept if item["contentKey"] == key), None)
    if existing is not None:
        if not score > existing["statementScore"]:
            return {"refusal": "notBetter"}
        kept = [item for item in kept if item["contentKey"] != key]
    kept.append({"embedding": encode(learned), "contentKey": key, "addedAt": at, "statementScore": score, "model": model})
    while len(kept) > BOUND:
        kept.pop(most_redundant(kept))
    return {"contentKeys": [item["contentKey"] for item in kept], "statementScores": [item["statementScore"] for item in kept],
            "learnedScore": score}


def document():
    near = unit(3, 4, 0, 0)        # 0.6 against the owner: learnable
    far = unit(1, 3, 0, 0)         # ~0.316: not the owner
    guest = unit(0, 0, 1, 0)       # 0 against the owner
    beside = unit(1, 4, 1, 0)      # below τ on its own; close to `near`
    learned = speaker([reference(near, "project-a")])
    cases = []
    mixed = speaker([
        reference(near, "project-a"),
        reference(near, "project-b", model="other-model"),
        reference(near, "project-c", score=0.3),
        reference(far, "project-d", score=0.9),
    ])
    cases.append({"kind": "usable", "name": "usable-filters-model-score-and-hop", "speaker": mixed,
                  "expected": {"contentKeys": usable(mixed), "learnedCount": len(usable(mixed))}})
    for name, block, candidate in [
        ("match-statement-first", learned, unit(9, 4, 0, 0)),
        ("match-through-a-reference", learned, beside),
        ("match-a-guest-never", learned, guest),
        ("match-no-references", speaker(), beside),
        ("match-a-reference-that-fails-its-hop-is-never-used", speaker([reference(far, "project-d", score=0.9)]), unit(1, 3, 0, 0)),
        ("match-the-best-reference", speaker([reference(unit(4, 4, 1, 0), "project-e"), reference(near, "project-a"),
                                               reference(unit(5, 1, 2, 0), "project-f")]), beside),
    ]:
        stored = encode(normalized(candidate))
        cases.append({"kind": "match", "name": name, "speaker": block, "candidate": stored, "expected": match(block, decode(stored))})
    later = "2026-11-06T09:30:00Z"
    for name, block, vector, key, model in [
        ("learning-the-first-reference", speaker(), near, "project-a", MODEL),
        ("learning-refuses-another-speaker", speaker(), far, "project-a", MODEL),
        ("learning-refuses-another-model", speaker(), near, "project-a", "other-model"),
        ("learning-keeps-the-better-of-one-project", learned, unit(3, 3, 0, 0), "project-a", MODEL),
        ("learning-refuses-a-worse-one-for-the-same-project", learned, unit(2, 3, 0, 0), "project-a", MODEL),
        ("learning-drops-other-model-references", speaker([reference(near, "project-a", model="old-model")]), near, "project-b", MODEL),
    ]:
        stored = encode(normalized(vector))
        cases.append({"kind": "learning", "name": name, "speaker": block, "embedding": stored,
                      "contentKey": key, "model": model, "at": later, "expected": learning(block, decode(stored), key, model, later)})
    # Sixteen references spread around the owner, two of them almost the same: learning a seventeenth drops the more redundant of those.
    spread = [reference(unit(6, a, b, 0), f"project-{index:02d}", added=f"2026-11-0{1 + index % 5}T10:00:00Z")
              for index, (a, b) in enumerate([(1, 0), (0, 1), (2, 1), (1, 2), (3, 0), (0, 3), (3, 2), (2, 3), (4, 1), (1, 4),
                                              (4, 3), (3, 4), (5, 0), (0, 5), (2, 5), (2, 5)])]
    full = speaker(spread)
    stored = encode(unit(6, 5, 2, 0))
    cases.append({"kind": "learning", "name": "learning-over-the-bound-drops-the-most-redundant", "speaker": full,
                  "embedding": stored, "contentKey": "project-new", "model": MODEL, "at": later,
                  "expected": learning(full, decode(stored), "project-new", MODEL, later)})
    return {"schema": "voxclip-voice-references/1",
            "description": "Learned voice references (doc/spec/voice-lab.md section 6.9, ADR-R41): which the guard may use, how speech matches "
                           "through them, and learning one. Generated by tools/fixtures/voice-lab/generate_voice_references.py.",
            "constants": {"bound": BOUND, "threshold": THRESHOLD, "model": MODEL},
            "caseCount": len(cases), "cases": cases}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = json.dumps(document(), ensure_ascii=False, indent=2) + "\n"
    if arguments.check:
        if OUTPUT.read_text() != rendered:
            raise SystemExit("voice reference fixtures drift; run tools/fixtures/voice-lab/generate_voice_references.py")
        print("Voice reference fixture: zero drift")
    else:
        OUTPUT.write_text(rendered)
        print(OUTPUT.relative_to(ROOT))

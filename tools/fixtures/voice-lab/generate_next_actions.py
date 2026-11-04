#!/usr/bin/env python3
"""Independent Rewrite next-step vectors (voice-lab.md §8.2.1): reply `nextActions` parsing, the scoped and open
feedback rendered from shared/prompts/rewrite-next-actions.json, and how a scoped reply lands on the asked phrases."""
import hashlib
import json
import re
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
JS_SPACE = set("\t\n\v\f\r       　﻿") | {chr(c) for c in range(0x2000, 0x200B)}


def js_trim(text):
    start, end = 0, len(text)
    while start < end and text[start] in JS_SPACE:
        start += 1
    while end > start and text[end - 1] in JS_SPACE:
        end -= 1
    return text[start:end]


def words(text):
    return [part for part in re.split("[" + re.escape("".join(sorted(JS_SPACE))) + "]+", text) if part]


def control(text, line_breaks):
    return any(unicodedata.category(ch) == "Cc" and not (line_breaks and ch == "\n") for ch in text)


def link(text):
    return re.search(r"https?://", text, re.IGNORECASE) is not None


def whole(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not value.is_integer():
        return None
    return int(value)


def parse_one(item):
    if not isinstance(item, dict) or not isinstance(item.get("label"), str) or not isinstance(item.get("instruction"), str):
        return None
    label, instruction = js_trim(item["label"]), js_trim(item["instruction"])
    if not label or len(label.encode()) > 80 or len(words(label)) > 6 or control(label, False) or link(label):
        return None
    if not instruction or len(instruction.encode()) > 1000 or control(instruction, True) or link(instruction):
        return None
    ordinals = []
    raw = item.get("ordinals")
    if raw is not None:
        if not isinstance(raw, list) or len(raw) > 60:
            return None
        for value in raw:
            number = whole(value)
            if number is None or not 1 <= number <= 999:
                return None
            if number not in ordinals:
                ordinals.append(number)
    return dict(label=label, instruction=instruction, ordinals=sorted(ordinals))


def parse(value):
    result, labels = [], set()
    for item in value if isinstance(value, list) else []:
        if len(result) >= 4:
            break
        action = parse_one(item)
        if action is None or action["label"].lower() in labels:
            continue
        labels.add(action["label"].lower())
        result.append(action)
    return result


def fixed1(value):
    return f"{value:.1f}"


def fill(template, values):
    return re.sub(r"\{([A-Za-z]+)\}", lambda match: values.get(match[1], match[0]), template)


def scoped(templates, instruction, phrases, budget):
    lines = []
    for phrase in phrases:
        values = {}
        if phrase["reason"] == "fit":
            values = dict(estimateSeconds=fixed1(phrase["estimateSeconds"]), slotSeconds=fixed1(phrase["slotSeconds"]))
        elif phrase["reason"] == "budget":
            values = dict(voiceWords=str(budget["voiceWords"]), scopeWords=str(budget["scopeWords"]))
        reason = fill(templates["reasons"][phrase["reason"]], values)
        lines.append(fill(templates["scopedPhraseLine"], dict(ordinal=str(phrase["ordinal"]), reason=reason,
                                                               original=phrase["original"], proposed=phrase["proposed"])))
    return fill(templates["scopedFeedbackBlock"], dict(instruction=js_trim(instruction), phrases="\n\n".join(lines)))


def touches(a, b):
    a, b = (a[0], max(a)), (b[0], max(b))
    if a[0] == a[1] or b[0] == b[1]:
        return a[0] <= b[1] and b[0] <= a[1]
    return a[0] < b[1] and b[0] < a[1]


def assign(current, asked, reply):
    candidates = {index: [found for found, span in enumerate(reply) if touches(current[index], span)] for index in asked}
    result = {}
    for index in sorted(asked):
        if str(index) in result:
            continue
        if not candidates[index]:
            result[str(index)] = "keepOriginal"
            continue
        found = candidates[index][0]
        group = [other for other in range(len(current)) if touches(current[other], reply[found])]
        lands = len(candidates[index]) == 1 and all(other in asked and candidates[other] == [found] for other in group)
        for member in group:
            if member in asked:
                result[str(member)] = "conflict" if not lands else f"replace:{found}" if member == group[0] else f"absorbed:{group[0]}"
        result.setdefault(str(index), "conflict")
    return result


def main():
    paths = ["shared/prompts/rewrite-next-actions.json", "shared/prompts/voice-rewrite.json", "shared/prompts/patch-rewrite.json"]
    raw = {path: (ROOT / path).read_bytes().replace(b"\r\n", b"\n") for path in paths}
    templates = json.loads(raw[paths[0]])["request"]
    good = dict(label="Say it in 6 words", instruction="Say phrase 2 in at most six words.", ordinals=[2])
    parse_cases = [
        ("valid", [good]),
        ("absent-ordinals", [dict(label="Drop 'actually'", instruction="Drop the word actually.")]),
        ("null-ordinals", [dict(label="Drop 'actually'", instruction="Drop the word actually.", ordinals=None)]),
        ("trimmed-sorted-deduplicated", [dict(label="  Merge with the next sentence ", instruction="　Merge phrase 3 with the next sentence.﻿",
                                              ordinals=[4, 3, 4.0])]),
        ("cap-four", [dict(label=f"Fix {n}", instruction=f"Fix phrase {n}.", ordinals=[n]) for n in range(1, 7)]),
        ("bad-entries-dropped", [
            dict(label="", instruction="Empty label."),
            dict(label="One two three four five six seven", instruction="Seven words."),
            dict(label="Long " + "x" * 80, instruction="Too many bytes."),
            dict(label="Tab\there", instruction="Control in label."),
            dict(label="See https://example.com", instruction="Link in label."),
            dict(label="No instruction", instruction="   "),
            dict(label="Link instruction", instruction="Read http://example.com first."),
            dict(label="Control instruction", instruction="Bell\u0007"),
            dict(label="Fraction", instruction="Half an ordinal.", ordinals=[1.5]),
            dict(label="Zero", instruction="Ordinal zero.", ordinals=[0]),
            dict(label="Too big", instruction="Ordinal 1000.", ordinals=[1000]),
            dict(label="Bool", instruction="A boolean ordinal.", ordinals=[True]),
            dict(label="Text ordinals", instruction="A string list.", ordinals="2"),
            dict(label=7, instruction="A numeric label."),
            "not an object",
            good,
        ]),
        ("line-break-instruction", [dict(label="Two steps", instruction="Shorten phrase 1.\nKeep the name.", ordinals=[1])]),
        ("repeated-label", [good, dict(label="SAY IT IN 6 WORDS", instruction="Again.", ordinals=[1]),
                            dict(label="Keep it plain", instruction="Plain words.", ordinals=[])]),
        ("not-an-array", {"label": "x"}),
    ]
    parsing = [dict(id=name, input=value, expected=parse(value)) for name, value in parse_cases]
    phrases = [
        dict(ordinal=2, reason="fit", original="We made the right call", proposed="We absolutely made the very best possible decision",
             estimateSeconds=3.04, slotSeconds=1.96),
        dict(ordinal=4, reason="budget", original="last week", proposed="seven days ago"),
        dict(ordinal=5, reason="take", original="it is faster", proposed="it runs faster"),
        dict(ordinal=6, reason="context", original="ok", proposed="all right"),
        dict(ordinal=7, reason="asked", original="{instruction}", proposed="{phrases} stays literal"),
        dict(ordinal=8, reason="collision", original="and then", proposed="and right after that"),
    ]
    budget = dict(voiceWords=72, scopeWords=118)
    feedback = [
        dict(id="scoped-every-reason", instruction="  Say it in 6 words.  ", phrases=phrases, budget=budget,
             expected=scoped(templates, "  Say it in 6 words.  ", phrases, budget)),
        dict(id="scoped-one-fit", instruction="Drop 'actually'", phrases=phrases[:1], budget=budget,
             expected=scoped(templates, "Drop 'actually'", phrases[:1], budget)),
        dict(id="open", instruction="Keep the names, make it shorter.", phrases=[], budget=None,
             expected=fill(templates["openFeedbackBlock"], dict(instruction="Keep the names, make it shorter."))),
        dict(id="fewer-words", instruction="", phrases=[], budget=None, limit=17,
             expected=fill(templates["fewerWordsInstruction"], dict(limit="17"))),
        dict(id="merge", instruction="", phrases=[], budget=None, merge=[3, 4],
             expected=fill(templates["mergeInstruction"], dict(first="3", second="4"))),
    ]
    landing_cases = [
        ("reworded-in-place", [[0, 2], [5, 7], [9, 10]], [1], [[0, 2], [5, 7], [9, 10]]),
        ("grown-into-unchanged-words", [[0, 2], [5, 7]], [1], [[0, 2], [5, 9]]),
        ("left-as-recorded", [[0, 2], [5, 7]], [1], [[0, 2]]),
        ("reaches-a-frozen-change", [[0, 2], [3, 5]], [0], [[0, 4]]),
        ("split-in-two", [[0, 6]], [0], [[0, 2], [4, 6]]),
        ("insertion-at-edge", [[3, 3], [6, 8]], [0], [[2, 3]]),
        ("adjacent-not-touching", [[0, 2], [2, 4]], [1], [[2, 4]]),
        ("two-asked-one-merged-reply", [[0, 2], [3, 5]], [0, 1], [[0, 5]]),
        ("merge-reaching-a-frozen-change", [[0, 2], [3, 5], [6, 8]], [0, 1], [[0, 7]]),
        ("merge-with-a-split-partner", [[0, 2], [3, 6]], [0, 1], [[0, 4], [5, 6]]),
        ("other-phrases-ignored", [[0, 2], [5, 7], [9, 10]], [0], [[0, 1], [5, 6], [9, 10], [12, 13]]),
    ]
    landing = [dict(id=name, current=current, asked=asked, reply=reply, expected=assign(current, set(asked), reply))
               for name, current, asked, reply in landing_cases]
    payload = dict(schema="voxclip-voice-lab-next-actions-cases/1",
                   sources={path: hashlib.sha256(data).hexdigest() for path, data in raw.items()},
                   parsing=parsing, feedback=feedback, landing=landing,
                   caseCount=len(parsing) + len(feedback) + len(landing))
    output = ROOT / "shared/fixtures/voice-lab/rewrite-next-actions-cases.json"
    output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(output.relative_to(ROOT))


if __name__ == "__main__":
    main()

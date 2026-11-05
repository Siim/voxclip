#!/usr/bin/env python3
"""Write shared/fixtures/caption-translations/caption-translation-cases.json (voxclip-caption-translation-cases/1): Ask
Claude's translated captions (doc/spec/ai.md section 18.2), produced independently of both apps. Standard library only;
deterministic.

Every case patches `captionTranslations` (and, for `version`, `schemaVersion`) onto the project in `baseProject`.

- `wire.valid` / `wire.invalid`: lists a project may store or must refuse; `runtimeOnly` cases pass the JSON schema and
  are refused by the readers (unknown or out-of-order words, an unknown clip, overlaps in one scope, untrimmed text,
  duplicate ids).
- `spread`: caption words in (edited-timeline seconds, transcript ids), the translations and the rendered clip, and the
  words out. A clip's own translations apply first, then the Full Take's (clipId null) where their words are still free.
  The translation's words are spread over the shown words of its range in order: with as many or more translated words,
  shown word i carries words [i*m/n, (i+1)*m/n) (integer division) and shares its time evenly among them, the last
  ending on the word's end; with fewer, translated word k spans shown words [k*n/m, (k+1)*n/m - 1]. A slot's first word
  keeps its id, the others add "#j". Words over a bleeped id are masked (x per letter or digit, punctuation kept).

Mac Core (CaptionTranslationTests) replays every case; Windows Core (CaptionTranslationVectorTests) replays `wire`.

    python3 -I tools/fixtures/caption-translations/generate_caption_translations.py
"""
import json
import os
import sys

sys.dont_write_bytecode = True
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
OUT = os.path.join(REPO, "shared", "fixtures", "caption-translations", "caption-translation-cases.json")
BASE = "fixtures/clip-controls/clip-controls-project.voxclip"
MASK = "×"


def entry(identifier, clip, start, end, language, text):
    return {"id": identifier, "clipId": clip, "startWordId": start, "endWordId": end, "language": language, "text": text}


def masked(text):
    return "".join(MASK if character.isalnum() else character for character in text)


def word(identifier, text, start, end):
    return {"id": identifier, "text": text, "start": start, "end": end}


def spread(tokens, slots, bleeped):
    count, shown = len(tokens), len(slots)
    words = []
    if count >= shown:
        for index, slot in enumerate(slots):
            first, last = index * count // shown, (index + 1) * count // shown
            share = (slot["end"] - slot["start"]) / float(last - first)
            for token in range(first, last):
                offset = float(token - first)
                text = masked(tokens[token]) if slot["id"] in bleeped else tokens[token]
                end = slot["end"] if token == last - 1 else slot["start"] + (offset + 1) * share
                words.append(word(slot["id"] if token == first else f"{slot['id']}#{token - first}", text, slot["start"] + offset * share, end))
    else:
        for token, text in enumerate(tokens):
            first, last = token * shown // count, (token + 1) * shown // count - 1
            covered = slots[first:last + 1]
            text = masked(text) if any(slot["id"] in bleeped for slot in covered) else text
            words.append(word(slots[first]["id"], text, slots[first]["start"], slots[last]["end"]))
    return words


def order_of(identifier):
    return int(identifier[1:].split("#")[0]) - 1


def applying(words, translations, clip, bleeped):
    rendered = [t for t in translations if clip is not None and t["clipId"] == clip] + [t for t in translations if t["clipId"] is None]
    result = list(words)
    consumed = set()
    for translation in rendered:
        lower, upper = order_of(translation["startWordId"]), order_of(translation["endWordId"])
        positions = [i for i, item in enumerate(result) if lower <= order_of(item["id"]) <= upper]
        if not positions or any(result[i]["id"] in consumed for i in positions):
            continue
        slots = [result[i] for i in positions]
        out = spread(translation["text"].split(), slots, bleeped)
        if not out:
            continue
        consumed.update(slot["id"] for slot in slots)
        for i in reversed(positions):
            del result[i]
        result[positions[0]:positions[0]] = out
    return result


def generated():
    # The edited timeline of the base project's words w1-w9, with w4 cut (not shown).
    shown = [word("w1", "So", 0.0, 0.25), word("w2", "it", 0.25, 0.5), word("w3", "costs", 0.5, 1.0), word("w5", "four", 1.0, 1.25),
             word("w6", "thousand", 1.25, 1.75), word("w7", "two", 1.75, 2.0), word("w8", "hundred,", 2.0, 2.5), word("w9", "OK.", 2.5, 3.0)]
    spread_cases = []

    def case(identifier, translations, clip=None, bleeped=(), words=shown):
        spread_cases.append({"id": identifier, "clipId": clip, "bleeped": list(bleeped), "translations": translations, "words": words,
                             "expected": applying(words, translations, clip, set(bleeped))})

    case("more-translated-words-than-shown", [entry("tr-1", None, "w2", "w5", "es", "eso cuesta unos cuatro mil")])
    case("fewer-translated-words-than-shown", [entry("tr-1", None, "w1", "w6", "es", "hola mundo")])
    case("as-many-words", [entry("tr-1", None, "w7", "w9", "de", "zwei hundert, OK.")])
    case("a-bleeped-word-stays-masked", [entry("tr-1", None, "w2", "w3", "es", "cuesta 42 dólares,")], bleeped=["w3"])
    clip_and_full = [entry("tr-1", "clip-main", "w2", "w3", "fr", "il coûte"), entry("tr-2", None, "w1", "w5", "es", "a b c d e f")]
    case("the-clips-own-wins", clip_and_full, clip="clip-main")
    case("the-full-take-shows-its-own", clip_and_full, clip=None)
    case("another-clip-shows-the-full-takes", clip_and_full, clip="clip-other")
    case("every-word-cut", [entry("tr-1", None, "w4", "w4", "es", "mil")])
    case("one-language-without-spaces", [entry("tr-1", None, "w5", "w8", "ja", "四千二百")])

    valid = [
        {"id": "one-full-take", "captionTranslations": [entry("tr-1", None, "w2", "w5", "es", "cuatro mil")]},
        {"id": "clip-and-full-over-the-same-words", "captionTranslations": clip_and_full},
        {"id": "region-tag", "captionTranslations": [entry("tr-7", "clip-main", "w1", "w1", "pt-br", "Então")]},
        {"id": "one-word", "captionTranslations": [entry("tr-1", None, "w9", "w9", "de", "OK.")]},
    ]
    invalid = [
        {"id": "language-upper-case", "captionTranslations": [entry("tr-1", None, "w2", "w5", "ES", "cuatro")]},
        {"id": "language-name", "captionTranslations": [entry("tr-1", None, "w2", "w5", "spanish", "cuatro")]},
        {"id": "empty-text", "captionTranslations": [entry("tr-1", None, "w2", "w5", "es", "")]},
        {"id": "bad-id", "captionTranslations": [entry("t1", None, "w2", "w5", "es", "cuatro")]},
        {"id": "extra-key", "captionTranslations": [dict(entry("tr-1", None, "w2", "w5", "es", "cuatro"), start=1.0)]},
        {"id": "missing-clip-id", "captionTranslations": [{k: v for k, v in entry("tr-1", None, "w2", "w5", "es", "cuatro").items() if k != "clipId"}]},
        {"id": "empty-list", "captionTranslations": []},
        {"id": "version-3", "version": 3, "captionTranslations": [entry("tr-1", None, "w2", "w5", "es", "cuatro")]},
        {"id": "unknown-word", "runtimeOnly": True, "captionTranslations": [entry("tr-1", None, "w2", "w99", "es", "cuatro")]},
        {"id": "words-out-of-order", "runtimeOnly": True, "captionTranslations": [entry("tr-1", None, "w5", "w2", "es", "cuatro")]},
        {"id": "unknown-clip", "runtimeOnly": True, "captionTranslations": [entry("tr-1", "clip-gone", "w2", "w5", "es", "cuatro")]},
        {"id": "overlap-in-one-scope", "runtimeOnly": True,
         "captionTranslations": [entry("tr-1", None, "w2", "w5", "es", "cuatro"), entry("tr-2", None, "w5", "w6", "es", "mil")]},
        {"id": "untrimmed-text", "runtimeOnly": True, "captionTranslations": [entry("tr-1", None, "w2", "w5", "es", " cuatro")]},
        {"id": "duplicate-id", "runtimeOnly": True,
         "captionTranslations": [entry("tr-1", None, "w1", "w1", "es", "Así"), entry("tr-1", None, "w2", "w5", "es", "cuatro")]},
    ]
    return {
        "schema": "voxclip-caption-translation-cases/1",
        "description": "Ask Claude's translated captions (doc/spec/ai.md section 18.2): what a project stores and how the "
                       "translation's words spread over the shown words. Generated by "
                       "tools/fixtures/caption-translations/generate_caption_translations.py; do not hand-edit.",
        "baseProject": BASE,
        "wire": {"valid": valid, "invalid": invalid},
        "spread": spread_cases,
    }


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(json.dumps(generated(), indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()

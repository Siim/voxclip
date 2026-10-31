import hashlib
import unicodedata
import unittest
import riigikogu
from riigikogu import (assemble, canonical_names, choose_pool, collect, minimum_pairs, milliseconds, normalise_name, parse_trs,
                       qualifying_turns, same_person, select, speaker_hash, streaminfo)
from check import check_et

# Synthetic names only: committed evidence and tests never carry real speaker names.
TRS = b'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Trans SYSTEM "trans-14.dtd">
<Trans audio_filename="202001011000">
  <Speakers>
    <Speaker id="spk1" name="Aseesimees Mari Tamm" type="male"/>
    <Speaker id="spk2" name="Riigikohtu liikme kandidaat Jaan Kask" type="male"/>
    <Speaker id="spk3" name="Unknown Speaker (S:0,T:0)" type="male"/>
  </Speakers>
  <Episode><Section startTime="0.460" endTime="40.000">
    <Turn speaker="spk1" startTime="0.460" endTime="10.460"><Sync time="0.460"/>Tekst.</Turn>
    <Turn speaker="spk2" startTime="11.000" endTime="20.999"><Sync time="11.000"/>Tekst.</Turn>
    <Turn speaker="spk1 spk2" startTime="21.000" endTime="35.000"><Sync time="21.000"/>Tekst.</Turn>
    <Turn speaker="spk3" startTime="35.000" endTime="50.000"><Sync time="35.000"/>Tekst.</Turn>
  </Section></Episode>
</Trans>'''


def sessions_with(name_sessions):
    """{session: [names]} -> qualifying {session: {name: [start]}} with one 12 s turn per name at 100 s."""
    return {session: {name: [100_000] for name in names} for session, names in name_sessions.items()}


class RiigikoguNameTests(unittest.TestCase):
    def test_role_prefixes_are_stripped(self):
        for raw, expected in [("Aseesimees Mari Tamm", "Mari Tamm"), ("Esimees Mari Tamm", "Mari Tamm"),
                              ("Riigikohtu liikme kandidaat Jaan Kask", "Jaan Kask"), ("Peaminister Mari Tamm", "Mari Tamm"),
                              ("Haridus- ja teadusminister Mari Tamm", "Mari Tamm"), ("Peaministrikandidaat Mari Tamm", "Mari Tamm"),
                              ("Eesti Panga president Jaan Kask", "Jaan Kask"), ("Tartu Ülikooli professor Jaan Kask", "Jaan Kask"),
                              ("Professor Jaan Kask", "Jaan Kask"), ("Õiguskantsler Mari Tamm", "Mari Tamm"),
                              ("Mari  Tamm ", "Mari Tamm"), ("Jaan Peeter Kask", "Jaan Peeter Kask"), ("Mari-Liis Tamm-Kask", "Mari-Liis Tamm-Kask")]:
            self.assertEqual(normalise_name(raw), expected, raw)

    def test_labels_without_one_named_person_are_dropped(self):
        for raw in ["Unknown Speaker (S:0,T:0)", "Unknown Speaker", "Riigikogu koor", "Keskerakonna fraktsioon", "Jõuluvana", "Professor Kask", ""]:
            self.assertIsNone(normalise_name(raw), raw)

    def test_names_are_nfc(self):
        decomposed = unicodedata.normalize("NFD", "Jüri Mänd")
        self.assertEqual(normalise_name(decomposed), unicodedata.normalize("NFC", "Jüri Mänd"))
        self.assertEqual(speaker_hash(normalise_name(decomposed)), hashlib.sha256("Jüri Mänd".encode()).hexdigest())

    def test_relatives_stay_distinct_hard_impostors(self):
        names = {"201801011000": ["Mari Tamm", "Jaan Tamm", "Mari-Liis Tamm", "Mart Tamm", "Martin Tamm"]}
        canonical = canonical_names(names)
        self.assertEqual(canonical, {name: name for name in names["201801011000"]})
        self.assertFalse(same_person("Mart Tamm", "Martin Tamm"))
        self.assertFalse(same_person("Jaan Kask", "Jaan Kuusk"))

    def test_typo_and_hyphen_variants_merge_to_the_most_frequent_spelling(self):
        names = {"201801011000": ["Jaan Kask", "Mari Tamm"], "201801021000": ["Jaan Kask", "Mari Tamm-Kuusk"],
                 "201801031000": ["Jaan Kaskk", "Mari Tamm-Kuusk"], "201801041000": ["Mari Tamm-Kuusk"]}
        canonical = canonical_names(names)
        self.assertEqual(canonical["Jaan Kaskk"], "Jaan Kask")
        self.assertEqual(canonical["Mari Tamm"], "Mari Tamm-Kuusk")
        self.assertTrue(same_person("Mari Tamm", "Mari Tamm-Kuusk"))

    def test_trs_turns_and_qualification(self):
        turns = parse_trs(TRS)
        self.assertEqual(turns, [("Aseesimees Mari Tamm", 460, 10460), ("Riigikohtu liikme kandidaat Jaan Kask", 11000, 20999),
                                 ("Unknown Speaker (S:0,T:0)", 35000, 50000)])
        self.assertEqual(qualifying_turns({"202001011000": turns}), {"202001011000": {"Mari Tamm": [460]}})
        with self.assertRaises(ValueError):
            milliseconds("1.0005")
        with self.assertRaises(ValueError):
            qualifying_turns({"2020-01-01": turns})


class RiigikoguSelectionTests(unittest.TestCase):
    def test_pool_is_greedy_one_per_date_and_deterministic(self):
        qualifying = sessions_with({"201801011000": ["A A", "B B"], "201801011400": ["A A", "B B", "C C"],
                                    "201801021000": ["A A", "B B", "C C"], "201801031000": ["A A"], "201801041000": ["C C", "D D"]})
        # 201801011400 and 201801021000 tie on gain 3; the earlier wins and blocks its date for 201801011000.
        self.assertEqual(choose_pool(qualifying), ["201801011400", "201801021000", "201801031000", "201801041000"])

    def test_pool_stops_at_thirty_sessions(self):
        qualifying = sessions_with({f"2019{month:02d}{day:02d}1000": [f"S{day:02d}{month:02d} X"] for month in range(1, 4) for day in range(1, 21)})
        self.assertEqual(len(choose_pool(qualifying)), riigikogu.POOL_SESSIONS)

    def test_speakers_groups_and_candidates(self):
        names = [f"Nimi{index:02d} Perenimi" for index in range(9)]
        qualifying = {f"2018010{day}1000": {name: [day * 60_000 + index * 1000, day * 60_000 + 30_000] for index, name in enumerate(names[:8 if day < 4 else 4])} for day in range(1, 5)}
        for day in range(4, 7):
            qualifying.setdefault(f"2018010{day}1000", {})[names[8]] = [5_000]
        selection = select(qualifying)
        # Days 1-3 cover the first eight speakers; days 4-6 gain only the ninth, so four speakers also get day 4.
        self.assertEqual(selection["pool"], [f"2018010{day}1000" for day in range(1, 7)])
        ordered = sorted(names, key=speaker_hash)
        self.assertEqual([speaker["name"] for speaker in selection["speakers"]], ordered)
        self.assertEqual([speaker["key"] for speaker in selection["speakers"]], [f"rk{index:03d}" for index in range(1, 10)])
        self.assertEqual([speaker["group"] for speaker in selection["speakers"]], (riigikogu.GROUPS * 3)[:9])
        first = next(speaker for speaker in selection["speakers"] if speaker["name"] in names[:4])
        self.assertTrue(all(len(speaker["candidates"]) == 3 for speaker in selection["speakers"] if speaker["name"] not in names[:4]))
        index = names.index(first["name"])
        self.assertEqual([candidate["session"] for candidate in first["candidates"]], [f"2018010{day}1000" for day in range(1, 5)])
        start = 122_000 + index * 1000
        self.assertEqual(first["candidates"][1], {"id": f"201801021000-{start}", "source": f"201801021000@{start // 1000}.000-{start // 1000 + 6}.000", "session": "201801021000", "startMs": start, "endMs": start + 6000})
        ninth = next(speaker for speaker in selection["speakers"] if speaker["name"] == names[8])
        self.assertEqual([candidate["source"] for candidate in ninth["candidates"]], [f"2018010{day}1000@7.000-13.000" for day in range(4, 7)])

    def test_speakers_need_three_pool_sessions(self):
        qualifying = sessions_with({"201801011000": ["A A", "B B"], "201801021000": ["A A", "B B"], "201801031000": ["A A"]})
        self.assertEqual([speaker["name"] for speaker in select(qualifying)["speakers"]], ["A A"])
        self.assertEqual(len(select(qualifying)["speakers"][0]["candidates"]), 3)

    def test_replacement_uses_the_fourth_session_then_skips_the_speaker(self):
        def speaker(key, group, count):
            return {"key": key, "group": group, "candidates": [{"id": f"{key}-{index}", "source": f"{key}@{index}"} for index in range(count)]}
        speakers = [speaker("rk001", "rk-cal-a", 4), speaker("rk002", "rk-val-a", 4), speaker("rk005", "rk-cal-a", 3), speaker("rk009", "rk-cal-a", 4)]
        failed = {"rk001-1", "rk005-0"}
        chosen, rejected = assemble(speakers, lambda identity: identity not in failed, ["rk-cal-a"])
        self.assertEqual([[candidate["id"] for candidate in member["candidates"]] for member in chosen["rk-cal-a"]],
                         [["rk001-0", "rk001-2", "rk001-3"], ["rk009-0", "rk009-1", "rk009-2"]])
        self.assertEqual([item["speaker"] for item in rejected], ["rk001", "rk005", "rk005"])
        self.assertNotIn("rk-val-a", chosen)

    def test_groups_stop_at_the_target(self):
        speakers = [{"key": f"rk{index:03d}", "group": "rk-cal-b", "candidates": [{"id": f"{index}-{part}", "source": f"{index}@{part}"} for part in range(3)]} for index in range(45)]
        chosen, _ = assemble(speakers, lambda identity: True)
        self.assertEqual(len(chosen["rk-cal-b"]), riigikogu.TARGET_SPEAKERS)
        self.assertEqual(chosen["rk-cal-a"], [])

    def test_predeclared_minimum_is_the_smallest_group_meeting_both_pair_floors(self):
        self.assertEqual(minimum_pairs(riigikogu.MINIMUM_SPEAKERS), (1224, 51))
        self.assertEqual(minimum_pairs(riigikogu.TARGET_SPEAKERS), (7020, 120))
        self.assertLess(minimum_pairs(riigikogu.MINIMUM_SPEAKERS - 1)[1], 50)
        self.assertEqual(riigikogu.ROLES, {"rk-cal-a": "calibration", "rk-val-a": "speaker-disjoint validation", "rk-cal-b": "calibration", "rk-val-b": "speaker-disjoint validation"})


class RiigikoguStreamTests(unittest.TestCase):
    def test_windows_are_cut_across_odd_block_boundaries(self):
        data = bytes(index % 251 for index in range(2 * (riigikogu.EXCERPT_SAMPLES + 50_000)))
        blocks = [data[start:start + 7_777] for start in range(0, len(data), 7_777)]
        parts, length, digest = collect(blocks, {"a": 0, "b": 12_345, "c": 50_000})
        self.assertEqual(length, len(data))
        self.assertEqual(digest, hashlib.md5(data).hexdigest())
        for identity, start in [("a", 0), ("b", 12_345), ("c", 50_000)]:
            self.assertEqual(bytes(parts[identity]), data[start * 2:(start + riigikogu.EXCERPT_SAMPLES) * 2])

    def test_streaminfo_is_parsed(self):
        block = bytearray(34)
        rate, channels, bits, samples = 16000, 1, 16, 54_291_784
        block[10], block[11] = rate >> 12, (rate >> 4) & 0xFF
        block[12] = (rate & 0xF) << 4 | (channels - 1) << 1 | (bits - 1) >> 4
        block[13] = ((bits - 1) & 0xF) << 4 | samples >> 32
        block[14:18] = (samples & 0xFFFFFFFF).to_bytes(4, "big")
        block[18:34] = bytes(range(16))
        head = b"fLaC" + bytes([0, 0, 0, 34]) + bytes(block)
        self.assertEqual(streaminfo(head), (16000, 1, 16, samples, bytes(range(16)).hex()))
        with self.assertRaises(ValueError):
            streaminfo(b"RIFF" + head[4:])

    def test_committed_estonian_evidence(self):
        check_et()


if __name__ == "__main__":
    unittest.main()

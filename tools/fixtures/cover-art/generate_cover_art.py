#!/usr/bin/env python3
"""Generate the shared MP4 cover-art vectors (ADR-R48, doc/publishing.md section 7).

Writes shared/fixtures/cover-art/: small synthetic MP4 inputs, the two cover images and cover-art-cases.json
(schema voxclip-cover-art-cases/1). Swift `MP4CoverArtReplayTests` (Core), the Media `MP4CoverEmbedTests` and C#
`Mp4CoverArtReplayTests` replay every case: each writer's output must have the expected size and SHA-256, or the case's
refusal.

Everything is built here, byte by byte, from constants: a 64 x 64 black H.264 picture (three frames at 10 fps, encoded
once with OpenH264) and 16 frames of silent 48 kHz AAC, interleaved into an `mdat`, with `moov` before or after it. No
user media and no encoder runs here, so the bytes are the same on every machine. The expected output of each case is
built the same way from scratch, with the cover's `moov/udta/meta/ilst/covr` in place: the writers edit the input, this
script lays the answer out again, so the two are independent. Only the `stco` overflow case shifts synthetic offsets the
way the writers do, since its offsets point past the file by design. Deterministic; run from anywhere.
"""
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/cover-art'
U32 = 0xFFFFFFFF

# One 16 x 16 JPEG (ffmpeg mjpeg, bitexact), the cover the writers embed.
COVER_JPEG = bytes.fromhex(
    'ffd8ffe000104a46494600010200000100010000ffdb0043000810101310131616161616161a181a1b1b1b1a1a1a1a1b1b1b1d1d1d2222221d'
    '1d1d1b1b1d1d2020222225262523232223262628282830302e2e38383a454553ffc4004b000101000000000000000000000000000000070101'
    '00000000000000000000000000000003100100000000000000000000000000000000110100000000000000000000000000000000ffc0001108'
    '0010001003012200021100031100ffda000c03010002110311003f009280613fffd9')

# The H.264 and AAC sample entries (`stsd` payloads) and samples, as OpenH264 and ffmpeg's AAC encoder wrote them.
VIDEO_STSD = bytes.fromhex(
    '00000000000000010000009f61766331000000000000000100000000000000000000000000000000004000400048000000480000000000000001'
    '104c617663206c69626f70656e683236340000000000000000000000000000000018ffff00000025617663430142c014ffe1000e6742c0148c8d'
    '421260203c2211a801000468ce3c8000000010706173700000000100000001000000146274727400000000000005d5000005d5')
AUDIO_STSD = bytes.fromhex(
    '00000000000000010000006e6d703461000000000000000100000000000000000001001000000000bb800000000000366573647300000000038080'
    '80250002000480808017401500000000005dc0000006390580808005118856e50006808080010200000014627472740000000000005dc000000639')
VIDEO_SAMPLES = [bytes.fromhex('0000001a65b80004000009e4c5000119f939393aebaebaebaeba92baebc0'),
                 bytes.fromhex('0000000961e00040009c813c23'),
                 bytes.fromhex('0000000961e00080011c81fc23')]
AUDIO_SAMPLES = [bytes.fromhex('01182007')] * 16
# mdat order: a video sample, then a run of audio samples (stsc below), as chunks.
CHUNKS = [('video', [0]), ('audio', [0, 1, 2, 3, 4]), ('video', [1]), ('audio', [5, 6, 7, 8, 9]),
          ('video', [2]), ('audio', [10, 11, 12, 13, 14, 15])]


def box(kind, payload=b'', header='normal'):
    """A box with a 32-bit size, a 64-bit largesize (`large`) or size 0, to the end of the file (`to-end`)."""
    if header == 'large':
        return struct.pack('>I4sQ', 1, kind, 16 + len(payload)) + payload
    if header == 'to-end':
        return struct.pack('>I4s', 0, kind) + payload
    assert 8 + len(payload) <= U32
    return struct.pack('>I4s', 8 + len(payload), kind) + payload


def full(kind, flags, payload):
    return box(kind, struct.pack('>I', flags) + payload)


def u32s(*values):
    return b''.join(struct.pack('>I', value) for value in values)


MATRIX = u32s(0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)


def hdlr(handler, name, manufacturer=b'\0\0\0\0'):
    return full(b'hdlr', 0, u32s(0) + handler + manufacturer + u32s(0, 0) + name + b'\0')


# The iTunes metadata handler the writers add: `mdir`, manufacturer `appl`, an empty name (as AtomicParsley writes it).
META_HDLR = hdlr(b'mdir', b'', b'appl')


def data_item(kind, type_code, payload):
    """An `ilst` item: `kind` holding one `data` atom (well-known type, locale 0)."""
    return box(kind, box(b'data', u32s(type_code, 0) + payload))


def cover_item(image):
    return data_item(b'covr', 14 if image.startswith(b'\x89PNG') else 13, image)


def png(width, height, rgb):
    """An RGB PNG with stored (uncompressed) deflate blocks, so no zlib version changes its bytes."""
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', crc32(kind + payload))
    raw = b''.join(b'\0' + bytes(rgb) * width for _ in range(height))
    stored = b'\x78\x01' + b''.join(
        bytes([1 if start + 65535 >= len(raw) else 0]) + struct.pack('<HH', len(block), len(block) ^ 0xFFFF) + block
        for start in range(0, len(raw), 65535) for block in [raw[start:start + 65535]]) + struct.pack('>I', adler32(raw))
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', stored) + chunk(b'IEND', b'')


def crc32(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def adler32(data):
    a, b = 1, 0
    for byte in data:
        a = (a + byte) % 65521
        b = (b + a) % 65521
    return b << 16 | a


COVER_PNG = png(24, 24, (0xFF, 0x80, 0x20))


def track(kind, offsets, offset_box):
    """One `trak`; `offsets` are its chunk offsets in an `stco` or `co64`."""
    video = kind == 'video'
    track_id = 1 if video else 2
    timescale = 10240 if video else 48000
    duration = 3 * 1024 if video else 15 * 1024 + 64
    tkhd = full(b'tkhd', 3, u32s(0, 0, track_id, 0, 300, 0, 0) + struct.pack('>hhhh', 0, 0 if video else 1, 0 if video else 0x100, 0)
                + MATRIX + u32s(64 << 16 if video else 0, 64 << 16 if video else 0))
    mdhd = full(b'mdhd', 0, u32s(0, 0, timescale, duration) + struct.pack('>HH', 0x55C4, 0))
    media_header = full(b'vmhd', 1, struct.pack('>HHHH', 0, 0, 0, 0)) if video else full(b'smhd', 0, struct.pack('>hH', 0, 0))
    dinf = box(b'dinf', full(b'dref', 0, u32s(1) + full(b'url ', 1, b'')))
    if video:
        tables = [box(b'stsd', VIDEO_STSD), full(b'stts', 0, u32s(1, 3, 1024)), full(b'stss', 0, u32s(1, 1)),
                  full(b'stsc', 0, u32s(1, 1, 1, 1)), full(b'stsz', 0, u32s(0, 3, *map(len, VIDEO_SAMPLES)))]
    else:
        tables = [box(b'stsd', AUDIO_STSD), full(b'stts', 0, u32s(2, 15, 1024, 1, 64)),
                  full(b'stsc', 0, u32s(2, 1, 5, 1, 3, 6, 1)), full(b'stsz', 0, u32s(4, 16))]
    if offset_box == 'co64':
        tables.append(full(b'co64', 0, u32s(len(offsets)) + b''.join(struct.pack('>Q', value) for value in offsets)))
    else:
        tables.append(full(b'stco', 0, u32s(len(offsets), *offsets)))
    minf = box(b'minf', media_header + dinf + box(b'stbl', b''.join(tables)))
    mdia = box(b'mdia', mdhd + hdlr(b'vide' if video else b'soun', b'VideoHandler' if video else b'SoundHandler') + minf)
    return box(b'trak', tkhd + mdia)


def udta(entries):
    """`udta` from entries: ('raw', box bytes) or ('meta', [ilst item boxes])."""
    def entry(item):
        return item[1] if item[0] == 'raw' else full(b'meta', 0, META_HDLR + box(b'ilst', b''.join(item[1])))
    return box(b'udta', b''.join(map(entry, entries)))


def with_cover(entries, image):
    """The writers' rule: replace the first `covr` in place (dropping any later one), else append it to the `ilst`; add a
    `meta` at the end of `udta` when there is none, and a `udta` at the end of `moov` when there is none."""
    entries = list(entries or [])
    cover = cover_item(image)
    for index, (kind, value) in enumerate(entries):
        if kind != 'meta':
            continue
        items = [item for item in value]
        covers = [position for position, item in enumerate(items) if item[4:8] == b'covr']
        if covers:
            items[covers[0]] = cover
            items = [item for position, item in enumerate(items) if position not in covers[1:]]
        else:
            items.append(cover)
        entries[index] = ('meta', items)
        return entries
    return entries + [('meta', [cover])]


def movie(spec, offsets_for, offset_boxes, udta_entries):
    children = [full(b'mvhd', 0, u32s(0, 0, 1000, 300, 0x10000) + struct.pack('>H', 0x100) + bytes(10) + MATRIX + bytes(24) + u32s(3))]
    children += [track(kind, offsets_for(kind), offset_boxes[kind]) for kind in ('video', 'audio')]
    if spec.get('mvex'):
        children.append(box(b'mvex', full(b'trex', 0, u32s(1, 1, 0, 0, 0))))
    if udta_entries is not None:
        children.append(udta(udta_entries))
    return box(b'moov', b''.join(children), spec.get('moov_header', 'normal'))


def layout(spec, udta_entries, offset_boxes=None, shift=None):
    """The file's bytes: ftyp, then moov and mdat in the spec's order. Chunk offsets are where each chunk lands, or the
    spec's synthetic offsets plus `shift`."""
    offset_boxes = offset_boxes or spec.get('offset_boxes', {'video': 'stco', 'audio': 'stco'})
    ftyp = box(b'ftyp', b'isom' + u32s(0x200) + b'isomiso2avc1mp41')
    payload = {'video': VIDEO_SAMPLES, 'audio': AUDIO_SAMPLES}
    chunk_bytes = [b''.join(payload[kind][index] for index in indices) for kind, indices in CHUNKS]
    mdat_header = {'normal': 8, 'large': 16, 'to-end': 8}[spec.get('mdat_header', 'normal')]
    gap = box(b'free') if spec.get('free') else b''

    def offsets(mdat_start):
        found = {'video': [], 'audio': []}
        cursor = mdat_start + mdat_header
        for (kind, _), data in zip(CHUNKS, chunk_bytes):
            found[kind].append(cursor)
            cursor += len(data)
        return found

    def offsets_for(start):
        real = offsets(start)
        fake = spec.get('fake_offsets', {})
        return lambda kind: [value + (shift or 0) for value in fake[kind]] if kind in fake else real[kind]

    mdat = box(b'mdat', b''.join(chunk_bytes), spec.get('mdat_header', 'normal'))
    if spec['order'] == 'moov-first':
        moov_size = len(movie(spec, lambda kind: [0] * len(offsets(0)[kind]), offset_boxes, udta_entries))
        start = len(ftyp) + moov_size + len(gap)
        moov = movie(spec, offsets_for(start), offset_boxes, udta_entries)
        parts = [ftyp, moov, gap, mdat]
    else:
        start = len(ftyp) + len(gap)
        moov = movie(spec, offsets_for(start), offset_boxes, udta_entries)
        parts = [ftyp, gap, mdat, moov]
    parts += spec.get('trailing', [])
    data = b''.join(parts)
    return data, moov


def expected(spec, image):
    """The case's output built from scratch with the cover in place; for synthetic offsets, the writers' shift and the
    promotion of an overflowing `stco` to `co64`. A `moov` that ran to the end of the file gets its size written out."""
    entries = with_cover(spec.get('udta'), image)
    boxes = dict(spec.get('offset_boxes', {'video': 'stco', 'audio': 'stco'}))
    _, before = layout(spec, spec.get('udta'))
    spec = {**spec, 'moov_header': 'normal'}
    if 'fake_offsets' not in spec:
        return layout(spec, entries, boxes)[0]
    moved = spec['order'] == 'moov-first'
    while True:
        growth = len(layout(spec, entries, boxes)[1]) - len(before)
        shift = growth if moved else 0
        overflowing = [kind for kind, values in spec['fake_offsets'].items()
                       if boxes[kind] == 'stco' and any(value + shift > U32 for value in values)]
        if not overflowing:
            return layout(spec, entries, boxes, shift)[0]
        for kind in overflowing:
            boxes[kind] = 'co64'


def tree(data):
    """The boxes a reader of the cover cares about, as `path offset size`, and each track's chunk-offset table."""
    lines, tables = [], []

    def walk(start, end, path):
        cursor = start
        while cursor < end:
            size, kind = struct.unpack('>I4s', data[cursor:cursor + 8])
            header = 8
            if size == 1:
                size, header = struct.unpack('>Q', data[cursor + 8:cursor + 16])[0], 16
            elif size == 0:
                size = end - cursor
            name = kind.decode('latin-1')
            here = f'{path}/{name}' if path else name
            lines.append(f'{here} {cursor} {size}')
            body = cursor + header
            if name in ('moov', 'trak', 'mdia', 'minf', 'stbl', 'udta', 'ilst'):
                walk(body, cursor + size, here)
            elif name == 'meta':
                walk(body + 4, cursor + size, here)
            elif name in ('stco', 'co64'):
                count = struct.unpack('>I', data[body + 4:body + 8])[0]
                width = 4 if name == 'stco' else 8
                entries = [int.from_bytes(data[body + 8 + width * index:body + 8 + width * (index + 1)], 'big') for index in range(count)]
                tables.append({'box': name, 'entries': entries})
            cursor += size
    walk(0, len(data), '')
    return lines, tables


def name_box(text):
    return box(b'\xa9xyz', struct.pack('>HH', len(text), 0x15C7) + text)


EXISTING_META = ('meta', [data_item(b'\xa9nam', 1, b'Ship day'), cover_item(COVER_PNG), data_item(b'\xa9too', 1, b'Lavf61.7.100')])
# Synthetic chunk offsets just under 2^32: valid in an `stco` until the cover's growth pushes them over.
NEAR_LIMIT = [U32 - 200, U32 - 150, U32 - 100]

CASES = [
    # (id, input file, spec, image, refusal)
    ('moov-first', 'moov-first.mp4', {'order': 'moov-first', 'free': True}, 'cover.jpg', None),
    ('moov-first-png', 'moov-first.mp4', {'order': 'moov-first', 'free': True}, 'cover.png', None),
    ('moov-last', 'moov-last.mp4', {'order': 'moov-last'}, 'cover.jpg', None),
    ('existing-covr', 'existing-covr.mp4',
     {'order': 'moov-first', 'udta': [('raw', name_box(b'+59.4370+024.7536/')), EXISTING_META]}, 'cover.jpg', None),
    ('udta-without-meta', 'udta-without-meta.mp4', {'order': 'moov-last', 'udta': [('raw', name_box(b'+59.4370+024.7536/'))]},
     'cover.jpg', None),
    ('co64', 'co64.mp4', {'order': 'moov-first', 'offset_boxes': {'video': 'co64', 'audio': 'stco'}}, 'cover.jpg', None),
    ('stco-overflow', 'stco-overflow.mp4', {'order': 'moov-first', 'fake_offsets': {'video': NEAR_LIMIT}}, 'cover.jpg', None),
    ('mdat-largesize', 'mdat-largesize.mp4', {'order': 'moov-first', 'mdat_header': 'large'}, 'cover.jpg', None),
    ('mdat-to-end', 'mdat-to-end.mp4', {'order': 'moov-first', 'mdat_header': 'to-end'}, 'cover.jpg', None),
    ('moov-to-end', 'moov-to-end.mp4', {'order': 'moov-last', 'moov_header': 'to-end'}, 'cover.jpg', None),
    ('fragmented-mvex', 'fragmented-mvex.mp4', {'order': 'moov-first', 'mvex': True}, 'cover.jpg', 'fragmented'),
    ('fragmented-moof', 'fragmented-moof.mp4',
     {'order': 'moov-first', 'trailing': [box(b'moof', full(b'mfhd', 0, u32s(1)))]}, 'cover.jpg', 'fragmented'),
    ('truncated', 'truncated.mp4', {'order': 'moov-first', 'cut': 10}, 'cover.jpg', 'truncated'),
    ('truncated-header', 'truncated-header.mp4', {'order': 'moov-first', 'trailing': [b'\0\0\0\x10mo']}, 'cover.jpg', 'truncated'),
    ('truncated-child', 'truncated-child.mp4', {'order': 'moov-first', 'grow_first_trak': 4096}, 'cover.jpg', 'truncated'),
    ('bad-largesize', 'bad-largesize.mp4', {'order': 'moov-first', 'trailing': [struct.pack('>I4sQ', 1, b'free', 12)]},
     'cover.jpg', 'unfollowableSize'),
    ('no-moov', 'no-moov.mp4', {'order': 'moov-first', 'drop_moov': True}, 'cover.jpg', 'noMovie'),
]


def input_bytes(spec):
    data, moov = layout(spec, spec.get('udta'))
    if spec.get('cut'):
        data = data[:-spec['cut']]
    if spec.get('grow_first_trak'):
        trak = data.index(b'trak') - 4
        size = struct.unpack('>I', data[trak:trak + 4])[0]
        data = data[:trak] + struct.pack('>I', size + spec['grow_first_trak']) + data[trak + 4:]
    if spec.get('drop_moov'):
        start = data.index(moov)
        data = data[:start] + data[start + len(moov):]
    return data


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    images = {'cover.jpg': COVER_JPEG, 'cover.png': COVER_PNG}
    files = dict(images)
    cases = []
    for case_id, name, spec, image, refusal in CASES:
        source = input_bytes(spec)
        assert files.setdefault(name, source) == source, name
        item = {'id': case_id, 'input': name, 'inputSize': len(source), 'inputSha256': sha(source), 'image': image}
        if refusal:
            item['refusal'] = refusal
        else:
            output = expected(spec, images[image])
            boxes, tables = tree(output)
            _, before = tree(source)
            moov_before = next(int(line.split()[2]) for line in tree(source)[0] if line.startswith('moov '))
            moov_after = next(int(line.split()[2]) for line in boxes if line.startswith('moov '))
            item.update({
                'decodes': 'fake_offsets' not in spec,
                'growth': moov_after - moov_before,
                'outputSize': len(output),
                'outputSha256': sha(output),
                'inputChunkOffsets': before,
                'chunkOffsets': tables,
                'boxes': boxes,
            })
        cases.append(item)
    document = {
        'schema': 'voxclip-cover-art-cases/1',
        'description': 'The MP4 cover-art writer (ADR-R48): each input with the image embedded as moov/udta/meta/ilst/covr, '
                       'or the refusal that leaves the file untouched. Generated by tools/fixtures/cover-art/generate_cover_art.py.',
        'coverTypes': {'jpeg': 13, 'png': 14},
        'caseCount': len(cases),
        'cases': cases,
    }
    for name, data in sorted(files.items()):
        (DESTINATION / name).write_bytes(data)
    (DESTINATION / 'cover-art-cases.json').write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()

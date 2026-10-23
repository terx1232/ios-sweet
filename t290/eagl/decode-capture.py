#!/usr/bin/env python3
"""Decode the opt-in CA capture bundle; preserve complete records after a panic."""
import argparse
import base64
import json
import math
import re
from pathlib import Path
import struct
import zlib

from PIL import Image

HEADER = struct.Struct('<32I')
FIELDS = ('magic header_size kind sequence draw api fbo texture surface width height stride '
          'format type level x y flags program unit0 unit1 error context_lo context_hi '
          'viewport_x viewport_y viewport_w viewport_h size reserved0 reserved1 reserved2').split()
UNIFORMS = ('vertex_matrix texmat0 texmat1 texmatD texmatW coord_arg function_arg '
            'color_matrix[0] color_matrix[1] color_matrix[2] color_matrix[3] texture0').split()
STATE = ('blend src_rgb dst_rgb src_alpha dst_alpha equation_rgb equation_alpha scissor '
         'scissor_x scissor_y scissor_w scissor_h viewport_x viewport_y viewport_w viewport_h').split()
KINDS = {1: 'upload', 2: 'draw', 3: 'surface-input', 4: 'present-surface1', 5: 'state'}


def extract_logs(logdir, destination):
    beginnings, chunks = {}, {}
    for path in sorted(logdir.glob('*.txt')):
        for line in path.read_text(errors='replace').splitlines():
            m = re.search(r'\bCAPBEGIN (\d+) (\d+) (\d+) (\d+) ([0-9a-f]{8})', line)
            if m:
                seq, count, packed, raw = map(int, m.groups()[:4])
                beginnings[seq] = (count, packed, raw, int(m[5], 16))
            m = re.search(r'\bCAPDATA (\d+) (\d+) ([A-Za-z0-9+/=]+)', line)
            if m:
                chunks.setdefault(int(m[1]), {})[int(m[2])] = m[3]
    complete, skipped = [], {}
    for seq, (count, packed_size, raw_size, expected_hash) in sorted(beginnings.items()):
        try:
            if not 1 <= count <= 40000 or not 128 <= raw_size <= 15 * 1024 * 1024 + 128:
                raise ValueError('invalid stream limits')
            parts = chunks.get(seq, {})
            packed = base64.b64decode(''.join(parts[i] for i in range(count)), validate=True)
            if len(packed) != packed_size:
                raise ValueError('compressed size mismatch')
            raw = None
            for window in (15, -15, 31):
                try:
                    decoder = zlib.decompressobj(window)
                    candidate = decoder.decompress(packed, raw_size + 1)
                    if decoder.eof and len(candidate) == raw_size:
                        raw = candidate
                        break
                except zlib.error:
                    pass
            if raw is None:
                raise ValueError('incomplete or invalid compressed record')
            hash_value = 2166136261
            for byte in raw:
                hash_value = ((hash_value ^ byte) * 16777619) & 0xffffffff
            if hash_value != expected_hash:
                raise ValueError('record checksum mismatch')
            header = HEADER.unpack_from(raw)
            if header[0] != 0x31504354 or header[1] != 128 or header[3] != seq or header[28] != len(raw)-128:
                raise ValueError('record header mismatch')
            complete.append(raw)
        except (KeyError, ValueError) as exc:
            skipped[str(seq)] = str(exc)
    destination.write_bytes(b'T290CAP1' + struct.pack('<2I', 1, 128) + b''.join(complete))
    return {'complete': len(complete), 'skipped': skipped,
            'chunks_without_begin': sorted(set(chunks) - set(beginnings))}


def records(data):
    if len(data) < 16 or data[:8] != b'T290CAP1' or struct.unpack_from('<2I', data, 8) != (1, 128):
        raise ValueError('not a version-1 T290 compositor capture')
    offset = 16
    while offset < len(data):
        if len(data) - offset < HEADER.size:
            raise EOFError(f'truncated record header at {offset}')
        header = dict(zip(FIELDS, HEADER.unpack_from(data, offset)))
        if header['magic'] != 0x31504354 or header['header_size'] != 128:
            raise ValueError(f'bad record header at {offset}')
        for key in ('level', 'x', 'y', 'viewport_x', 'viewport_y'):
            if header[key] >= 0x80000000:
                header[key] -= 0x100000000
        size = header['size']
        if size > 15 * 1024 * 1024:
            raise ValueError(f'oversized record at {offset}')
        offset += HEADER.size
        if len(data) - offset < size:
            raise EOFError(f'truncated record {header["sequence"]}: {len(data)-offset}/{size} payload bytes')
        yield header, memoryview(data)[offset:offset+size]
        offset += size


def image_from_record(h, payload):
    w, height, stride = h['width'], h['height'], h['stride']
    if h['error'] or not w or not height or w > 4096 or height > 4096:
        return None
    fmt, typ = h['format'], h['type']
    if h['flags'] & 1:
        fmt = {0x52474241: 0x1908, 0x42475241: 0x80e1, 0x41303038: 0x1906,
               0x4c303038: 0x1909, 0x4c413038: 0x190a, 0x52303038: 0x1903,
               0x52473838: 0x8227}.get(fmt)
    channels = {0x1908: 4, 0x80e1: 4, 0x1906: 1, 0x1909: 1,
                0x190a: 2, 0x1903: 1, 0x8227: 2}.get(fmt)
    width_bytes = {0x1401: 1, 0x140b: 2, 0x8d61: 2}.get(typ)
    if not channels or not width_bytes:
        return None
    cpp = channels * width_bytes
    if stride < w * cpp or len(payload) < stride * height:
        raise ValueError(f'invalid image layout in record {h["sequence"]}')
    rgba = bytearray(w * height * 4)
    for y in range(height):
        row = payload[y * stride:y * stride + w * cpp]
        for x in range(w):
            src = row[x * cpp:(x+1) * cpp]
            if width_bytes == 1:
                v = list(src)
            else:
                v = [round(max(0, min(1, t)) * 255) if math.isfinite(t) else 0
                     for t in struct.unpack('<' + 'e' * channels, src)]
            if fmt == 0x1908: color = v
            elif fmt == 0x80e1: color = [v[2], v[1], v[0], v[3]]
            elif fmt == 0x1906: color = [0, 0, 0, v[0]]
            elif fmt == 0x1909: color = [v[0], v[0], v[0], 255]
            elif fmt == 0x190a: color = [v[0], v[0], v[0], v[1]]
            elif fmt == 0x1903: color = [v[0], 0, 0, 255]
            else: color = [v[0], v[1], 0, 255]
            offset = (y * w + x) * 4
            rgba[offset:offset+4] = bytes(color)
    # Keep memory/GL row order: orientation is explicit, not guessed per record.
    return Image.frombytes('RGBA', (w, height), bytes(rgba))


def decode(source, output):
    output.mkdir(parents=True, exist_ok=True)
    manifest = {'source': str(source), 'row_order': 'raw memory / GL bottom row first', 'records': []}
    try:
        for h, payload in records(source.read_bytes()):
            item = dict(h)
            item['kind_name'] = KINDS.get(h['kind'], 'unknown')
            item['operation'] = ({0: 'primitives', 1: 'clear', 2: 'blit'}.get(h['reserved0'], 'unknown')
                                 if h['reserved1'] == 1 else 'unknown')
            name = f'{h["sequence"]:03}-{item["kind_name"]}-draw{h["draw"]}-fbo{h["fbo"]}-tex{h["texture"]}'
            (output / (name + '.bin')).write_bytes(payload)
            if h['kind'] == 5:
                if len(payload) != 16 * 4 + 12 * 16 * 4:
                    raise ValueError('invalid GL state payload')
                item['state'] = dict(zip(STATE, struct.unpack_from('<16i', payload)))
                item['uniforms'] = {}
                for i, key in enumerate(UNIFORMS):
                    if h['flags'] & (1 << i):
                        values = struct.unpack_from('<16f', payload, 64 + i * 64)
                        item['uniforms'][key] = [v if math.isfinite(v) else str(v) for v in values]
            else:
                img = image_from_record(h, payload)
                if img is not None:
                    img.save(output / (name + '.png'))
                    alpha = img.getchannel('A')
                    item['alpha_extrema'] = alpha.getextrema()
                    item['nonzero_alpha_pixels'] = sum(alpha.histogram()[1:])
                    item['rgba_extrema'] = img.getextrema()
                    # A8 needs its own visible mask to distinguish an empty input.
                    alpha.save(output / (name + '-alpha.png'))
            manifest['records'].append(item)
    except EOFError as exc:
        manifest['incomplete_tail'] = str(exc)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2, allow_nan=False) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--logs', action='store_true', help='extract checksummed records from USB .txt logs')
    args = parser.parse_args()
    if args.logs:
        args.output.mkdir(parents=True, exist_ok=True)
        bundle = args.output / 'capture.bin'
        extraction = extract_logs(args.source, bundle)
        (args.output / 'stream-status.json').write_text(json.dumps(extraction, indent=2) + '\n')
        print(f'USB stream: {extraction}')
    else:
        bundle = args.source
    result = decode(bundle, args.output)
    print(f'Decoded {len(result["records"])} complete records')
    if 'incomplete_tail' in result:
        print(result['incomplete_tail'])

"""Prepare split Pronto MDT firmware offline; never accesses a device.

The output is a memory image and ORIGINAL authentication metadata, not a
bootable/patched ELF. PAS authentication, clocks and reset are still required.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

BASE = 0x8CE00000
CAPACITY = 0x700000
TYPE_MASK = 7 << 24
HASH = 2 << 24
RELOCATABLE = 1 << 27


def prepare(mdt, read_segment):
    """Validate first, then return (memory, original metadata, load manifest)."""
    if len(mdt) < 52 or mdt[:7] != b"\x7fELF\x01\x01\x01":
        raise ValueError("expected little-endian ELF32 MDT")
    hdr = struct.unpack_from("<16sHHIIIIIHHHHHH", mdt)
    _, kind, machine, version, entry, phoff, _, _, ehsize, phsize, count, *_ = hdr
    if (kind, machine, version, ehsize, phsize) != (2, 40, 1, 52, 32):
        raise ValueError("unsupported ARM ELF header")
    if not 2 <= count <= 100 or phoff < 52 or phoff + count * 32 > len(mdt):
        raise ValueError("invalid program header bounds")
    ph = [struct.unpack_from("<8I", mdt, phoff + i * 32) for i in range(count)]
    hashes = [p for p in ph if p[6] & TYPE_MASK == HASH]
    if ph[0][0] == 1 or len(hashes) != 1:
        raise ValueError("expected one authentication hash segment")
    header_size, hash_size = ph[0][4], hashes[0][4]
    # Restrict this tool to the observed split MDT format. Never rewrite ELF
    # addresses: the secure loader authenticates the original metadata.
    if not hash_size or header_size < phoff + count * 32 or header_size + hash_size != len(mdt):
        raise ValueError("split MDT authentication metadata is truncated/ambiguous")
    if any(p[0] == 1 and p[6] & TYPE_MASK != HASH and p[4] > p[5] for p in ph):
        raise ValueError("load segment file size exceeds memory size")
    loads = [(i, p) for i, p in enumerate(ph)
             if p[0] == 1 and p[6] & TYPE_MASK != HASH and p[5]]
    if not loads or any(not p[6] & RELOCATABLE for _, p in loads):
        raise ValueError("expected relocatable Pronto load segments")
    minimum = min(p[3] for _, p in loads)
    ranges = []
    prepared = []
    for index, p in loads:
        _, _, _, address, filesz, memsz, flags, alignment = p
        end = address + memsz
        if filesz > memsz or end > 1 << 32:
            raise ValueError("segment size/physical address overflow")
        offset = address - minimum
        if offset + memsz > CAPACITY:
            raise ValueError("segment exceeds SM-T290 WCNSS reservation")
        if alignment and alignment & (alignment - 1):
            raise ValueError("invalid segment alignment")
        if alignment > 1 and (BASE - minimum) % alignment:
            raise ValueError("relocation violates segment alignment")
        if any(address < hi and end > lo for lo, hi in ranges):
            raise ValueError("overlapping firmware segments")
        ranges.append((address, end))
        data = read_segment(index) if filesz else b""
        if len(data) != filesz:
            raise ValueError(f"segment {index} missing or truncated")
        prepared.append((offset, data, memsz))
    extent = (max(hi for _, hi in ranges) - minimum + 4095) & ~4095
    if extent > CAPACITY or not any(lo <= entry < hi for lo, hi in ranges):
        raise ValueError("invalid load extent or entry address")
    if not any(p[6] & 1 and p[3] <= entry < p[3] + p[4] for _, p in loads):
        raise ValueError("entry is not inside executable file data")
    memory = bytearray(extent)
    for offset, data, _ in prepared:
        memory[offset:offset + len(data)] = data
    manifest = {
        "format": "t290-pronto-offline-v1", "pas_id": 6,
        "physical_base": BASE, "reserved_size": CAPACITY,
        "original_base": minimum, "relocated_entry": BASE + entry - minimum,
        "load_size": extent, "segments": len(loads),
        "memory_sha256": hashlib.sha256(memory).hexdigest(),
        "metadata_sha256": hashlib.sha256(mdt).hexdigest(),
        "authenticated": False, "hardware_loaded": False,
    }
    return bytes(memory), mdt, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("firmware", type=Path, help="folder containing wcnss.mdt/bXX")
    parser.add_argument("output", type=Path, help="new output folder outside the repository")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    if args.output.resolve().is_relative_to(repo):
        parser.error("private firmware output must be outside the repository")
    memory, metadata, manifest = prepare(
        (args.firmware / "wcnss.mdt").read_bytes(),
        lambda i: (args.firmware / f"wcnss.b{i:02d}").read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "wcnss-memory.bin").write_bytes(memory)
    (args.output / "wcnss-auth-metadata.bin").write_bytes(metadata)
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

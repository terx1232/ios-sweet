"""Synthetic fixtures only; no proprietary firmware required."""
import struct
import unittest
from prepare_firmware import BASE, CAPACITY, HASH, RELOCATABLE, prepare


def fixture():
    data = bytearray(52 + 4 * 32 + 16)
    struct.pack_into("<16sHHIIIIIHHHHHH", data, 0,
                     b"\x7fELF\x01\x01\x01" + bytes(9), 2, 40, 1,
                     0x8D600002, 52, 0, 0, 52, 32, 4, 0, 0, 0)
    headers = [
        (0, 0, 0, 0, 180, 0, 0, 0),
        (0, 0, 0, 0, 16, 16, HASH, 4),
        (1, 0x1000, 0, 0x8D600000, 4, 8, RELOCATABLE | 5, 0x1000),
        (1, 0x2000, 0, 0x8D602000, 0, 16, RELOCATABLE | 6, 4),
    ]
    for i, header in enumerate(headers):
        struct.pack_into("<8I", data, 52 + i * 32, *header)
    data[-16:] = bytes(range(16))
    return data


class FirmwareTests(unittest.TestCase):
    def test_relocation_and_bss(self):
        mdt = fixture()
        memory, metadata, manifest = prepare(mdt, lambda i: b"ABCD")
        self.assertEqual(metadata, mdt)
        self.assertEqual(memory[:8], b"ABCD\0\0\0\0")
        self.assertEqual(memory[8:], bytes(len(memory) - 8))
        self.assertEqual(manifest["relocated_entry"], BASE + 2)
        self.assertEqual(manifest["load_size"], 0x3000)
        self.assertFalse(manifest["authenticated"])
        self.assertFalse(manifest["hardware_loaded"])

    def test_bad_headers(self):
        for offset, value in [(0, 0), (4, 2), (5, 2), (18, 183), (44, 255)]:
            mdt = fixture()
            mdt[offset] = value
            with self.assertRaises(ValueError):
                prepare(mdt, lambda i: b"ABCD")

    def test_all_truncations(self):
        mdt = fixture()
        for n in range(len(mdt)):
            with self.assertRaises(ValueError):
                prepare(mdt[:n], lambda i: b"ABCD")

    def test_wrong_split_file(self):
        for data in [b"", b"ABC", b"ABCDE"]:
            with self.assertRaises(ValueError):
                prepare(fixture(), lambda i: data)

    def test_nonempty_zero_memory_segment(self):
        mdt = fixture()
        struct.pack_into("<I", mdt, 52 + 3 * 32 + 4 * 4, 1)
        struct.pack_into("<I", mdt, 52 + 3 * 32 + 5 * 4, 0)
        with self.assertRaises(ValueError):
            prepare(mdt, lambda i: b"ABCD")

    def test_reject_segment_ranges(self):
        # Program header3 fields: address, memory length, flags, alignment.
        for field, value in [(3, 0x8D600004), (5, CAPACITY),
                             (3, 0xFFFFFFFC), (6, 6), (7, 3), (7, 1 << 26)]:
            mdt = fixture()
            struct.pack_into("<I", mdt, 52 + 3 * 32 + field * 4, value)
            with self.assertRaises(ValueError):
                prepare(mdt, lambda i: b"ABCD")

    def test_entry_must_be_executable_file_data(self):
        for entry in [0, 0x8D600006, 0x8D602000]:
            mdt = fixture()
            struct.pack_into("<I", mdt, 24, entry)
            with self.assertRaises(ValueError):
                prepare(mdt, lambda i: b"ABCD")


if __name__ == "__main__":
    unittest.main()

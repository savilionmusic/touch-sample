#!/usr/bin/env python3
"""Exercise real FAT32 images, names/data, and failure preservation; no VM/hardware."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lab-ext"))
sys.path.insert(0, str(ROOT / "out/sample-tools"))
import sample_card
from pyfatfs.PyFatFS import PyFatFS


class CardTests(unittest.TestCase):
    def test_partition_and_unicode_roundtrip(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "out") as temp:
            base = Path(temp)
            source = base / "samples"
            nested = source / "MPC-Sample/Samples/Sav Kit/Café drums"
            nested.mkdir(parents=True)
            audio = bytes(range(256)) * 30
            (nested / "Kick é 01.wav").write_bytes(audio)
            image = base / "card.img"
            with patch.object(sample_card, "CARD_SIZE", 512 << 20):
                sample_card.build(source, image)
            self.assertEqual(image.stat().st_size, 512 << 20)
            with image.open("rb") as stream:
                mbr = stream.read(512)
                self.assertEqual(mbr[510:], b"\x55\xaa")
                self.assertEqual(mbr[450], 0x0C)
                self.assertEqual(struct.unpack_from("<I", mbr, 454)[0], 2048)
                stream.seek(sample_card.OFFSET)
                boot = stream.read(512)
                reserved = struct.unpack_from("<H", boot, 14)[0]
                fat_sectors = struct.unpack_from("<I", boot, 36)[0]
                root_cluster = struct.unpack_from("<I", boot, 44)[0]
                sector = reserved + boot[16] * fat_sectors + (root_cluster - 2) * boot[13]
                stream.seek(sample_card.OFFSET + sector * 512)
                self.assertEqual(stream.read(11), b"MPC SAMPLE ")
                stream.seek(sample_card.OFFSET + 512 + 488)
                free, next_free = struct.unpack("<II", stream.read(8))
                self.assertGreater(free, 0)
                self.assertLess(free, (512 << 20) // 4096)
                self.assertGreaterEqual(next_free, 2)
            with PyFatFS(str(image), offset=sample_card.OFFSET, read_only=True) as fs:
                self.assertEqual(fs.readbytes("MPC-Sample/Samples/Sav Kit/Café drums/Kick é 01.wav"), audio)

    def test_failed_copy_preserves_previous_image(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "out") as temp:
            base = Path(temp)
            source = base / "samples"
            source.mkdir()
            (source / "kick.wav").write_bytes(b"test")
            image = base / "card.img"
            image.write_bytes(b"existing guest saves")
            with patch.object(sample_card, "CARD_SIZE", 512 << 20), \
                    patch.object(PyFatFS, "upload", side_effect=OSError("copy failed")):
                with self.assertRaises(OSError):
                    sample_card.build(source, image)
            self.assertEqual(image.read_bytes(), b"existing guest saves")


if __name__ == "__main__":
    unittest.main()

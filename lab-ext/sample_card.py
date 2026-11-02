"""Build a partitioned FAT32 SD image without mounting it on the Mac.

Local extension only: the pinned vendor lab stays unchanged. Used at boot and by
the panel's SD insert action. Dependencies are isolated in ignored out/sample-tools.
"""
from pathlib import Path
import os
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CARD_SIZE = 4 << 30
OFFSET = 1 << 20


def build(folder, destination):
    sys.path.insert(0, str(ROOT / "out/sample-tools"))
    try:
        from pyfatfs.PyFat import PyFat
        from pyfatfs.PyFatFS import PyFatFS
    except ImportError as error:
        raise RuntimeError("Install sample-card dependencies: python3 -m pip install "
                           "--target out/sample-tools -r lab-ext/sample-card-requirements.txt") from error
    folder, destination = Path(folder), Path(destination)
    files = sorted(p for p in folder.rglob("*") if p.is_file())
    for p in folder.rglob("*"):
        if p.is_symlink():
            raise RuntimeError(f"SD folder must not contain symlinks: {p}")
    # Allow for 4 KiB clusters, directories, FAT tables and room for guest saves.
    required = sum(((p.stat().st_size + 4095) // 4096) * 4096 for p in files)
    if required > CARD_SIZE - (256 << 20):
        raise RuntimeError("Samples exceed the 4 GiB card's safe capacity (leave 256 MiB free)")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fat32-", dir=destination.parent) as temp:
        image = Path(temp) / "sdcard.img"
        image.touch()
        fat = PyFat(offset=OFFSET)
        try:
            fat.mkfs(str(image), fat_type=32, size=CARD_SIZE - OFFSET, label="MPC SAMPLE")
        finally:
            fat.close()
        # Primary + backup BPBs need the partition's hidden-sector count.
        with image.open("r+b") as output:
            for sector in (0, 6):
                output.seek(OFFSET + sector * 512 + 28)
                output.write(struct.pack("<I", OFFSET // 512))
            # One MBR FAT32-LBA partition; guest expects /dev/mmcblk1p1.
            mbr = bytearray(512)
            mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\xfe\xff\xff", 0x0C,
                                       b"\xfe\xff\xff", OFFSET // 512,
                                       (CARD_SIZE - OFFSET) // 512)
            mbr[510:512] = b"\x55\xaa"
            output.seek(0)
            output.write(mbr)
        with PyFatFS(str(image), offset=OFFSET) as filesystem:
            for i, source in enumerate(files, 1):
                relative = source.relative_to(folder).as_posix()
                parent = str(Path(relative).parent)
                if parent != ".":
                    filesystem.makedirs(parent, recreate=True)
                with source.open("rb") as stream:
                    filesystem.upload(relative, stream, chunk_size=1024 * 1024)
                if i % 500 == 0:
                    print(f"SD card: {i}/{len(files)} files", flush=True)
        # pyfatfs does not update FAT32 FSInfo after copying. Recompute its hints.
        with image.open("r+b") as output:
            # mkfs converts the root volume-label entry to an 8.3 filename,
            # dropping its space. Linux prefers this entry over the BPB label.
            output.seek(OFFSET)
            boot = output.read(512)
            reserved = struct.unpack_from("<H", boot, 14)[0]
            fat_sectors = struct.unpack_from("<I", boot, 36)[0]
            root_cluster = struct.unpack_from("<I", boot, 44)[0]
            sector = reserved + boot[16] * fat_sectors + (root_cluster - 2) * boot[13]
            output.seek(OFFSET + sector * 512)
            entry = output.read(32)
            if entry[11] != 0x08:
                raise RuntimeError("Expected the root volume label as the first FAT32 entry")
            output.seek(OFFSET + sector * 512)
            output.write(b"MPC SAMPLE ")
            total_sectors = struct.unpack_from("<I", boot, 32)[0]
            cluster_count = (total_sectors - reserved - boot[16] * fat_sectors) // boot[13]
            output.seek(OFFSET + reserved * 512)
            table = output.read((cluster_count + 2) * 4)
            free = [i for i, (value,) in enumerate(struct.iter_unpack("<I", table))
                    if i >= 2 and value & 0x0FFFFFFF == 0]
            for sector in (1, 7):
                output.seek(OFFSET + sector * 512 + 488)
                output.write(struct.pack("<II", len(free), free[0] if free else 0xFFFFFFFF))
        # Publish only a complete, closed image; failures preserve the old card.
        os.replace(image, destination)
    return str(destination)


def install(lab):
    """Override the host image builder in this Python process, never the firmware."""
    def image(qimg=None):
        try:
            return build(lab.SDCARD, lab.SD_IMG)
        except (RuntimeError, OSError):
            raise
        except Exception as error:
            # The stock panel displays RuntimeError/OSError as a failed insert.
            raise RuntimeError(f"FAT32 card build failed: {error}") from error

    lab.SD_SIZE = CARD_SIZE
    lab.sdcard_image = image

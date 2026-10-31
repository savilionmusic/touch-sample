#!/usr/bin/env python3
"""Phase 0: turn Akai's "MPC Sample 1.3.0 Updater.app.zip" into the emulator's firmware inputs.

    python3 scripts/extract-firmware.py [UPDATER.zip | Updater.app | update.img]

Default input: the first *.zip in firmware/. Everything stays in git-ignored folders (hard rule 1):
  firmware/updater/          the unzipped updater app
  firmware/az0x/             az0x.py's raw output (records, .xz compressed)
  vendor/virtual-mpc-sample/firmware/extracted/{part1,part2,parr}
  vendor/virtual-mpc-sample/firmware/Firmware/MPCSAMPLE-1.3.0.12-update.img (hard link or copy)

The AZ0x container is parsed by mpc-sample-lab's tools/az0x.py, run as a separate process
(that repository has no licence, so its code is not copied here). Partitions are recognised by
their SHA-256 against the emulator's inputs.sha256, so the record names don't matter.
Read-only on the input; never runs the updater.
"""
import hashlib
import lzma
import os
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAB = os.path.join(ROOT, "vendor", "virtual-mpc-sample")
AZ0X = os.path.join(ROOT, "vendor", "mpc-sample-lab", "tools", "az0x.py")
FW = os.path.join(ROOT, "firmware")
FW_LAB = os.path.join(LAB, "firmware")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def expected():
    """inputs.sha256: digest -> relative path (extracted/part1, ..., Firmware/...img)."""
    out = {}
    with open(os.path.join(LAB, "inputs.sha256")) as f:
        for line in f:
            digest, rel = line.split(None, 1)
            out[digest] = rel.strip()
    return out


def find_image(arg):
    if arg is None:
        zips = sorted(n for n in os.listdir(FW) if n.lower().endswith(".zip")) if os.path.isdir(FW) else []
        if not zips:
            sys.exit(f"no updater zip in {FW}: download 'MPC Sample 1.3.0 Updater.app.zip' there (PLAN.md Phase 0)")
        arg = os.path.join(FW, zips[0])
    arg = os.path.abspath(arg)
    if arg.lower().endswith(".img"):
        return arg
    root = arg
    if arg.lower().endswith(".zip"):
        root = os.path.join(FW, "updater")
        if not os.path.isdir(root):
            print(f"unzipping {os.path.basename(arg)} -> firmware/updater/")
            # ditto keeps the app bundle intact (symlinks, resource forks); zipfile is the fallback
            if shutil.which("ditto"):
                subprocess.run(["ditto", "-x", "-k", arg, root], check=True)
            else:
                with zipfile.ZipFile(arg) as z:
                    z.extractall(root)
    imgs = []
    for d, _, files in os.walk(root):
        imgs += [os.path.join(d, n) for n in files if n.lower().endswith(".img")]
    if not imgs:
        sys.exit(f"no *.img inside {root}")
    imgs.sort(key=os.path.getsize, reverse=True)
    return imgs[0]


def main():
    want = expected()
    img_digest = next(d for d, rel in want.items() if rel.endswith(".img"))
    img = find_image(sys.argv[1] if len(sys.argv) > 1 else None)
    print(f"update image: {img}")
    d = sha256(img)
    if d != img_digest:
        sys.exit(f"SHA-256 {d}\nis not firmware 1.3.0.12 ({img_digest}).\n"
                 "Stop here: the emulator supports only 1.3.0.12 (PLAN.md Phase 0).")
    print("update image is 1.3.0.12: OK")

    out = os.path.join(FW, "az0x")
    os.makedirs(out, exist_ok=True)
    subprocess.run([sys.executable, "-I", AZ0X, img, "--extract", out], check=True)

    found = {}
    for name in sorted(os.listdir(out)):
        path = os.path.join(out, name)
        if name.endswith(".xz"):
            raw = path[:-3]
            if not os.path.exists(raw):
                print(f"decompressing {name}")
                with lzma.open(path) as src, open(raw + ".tmp", "wb") as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)
                os.replace(raw + ".tmp", raw)
            path = raw
        elif name.endswith((".tmp", "header_signed.bin", "signature.bin")):
            continue
        dg = sha256(path)
        if dg in want:
            found[want[dg]] = path
            print(f"{os.path.basename(path)} = {want[dg]}")

    missing = [rel for rel in want.values() if rel.startswith("extracted/") and rel not in found]
    if missing:
        sys.exit(f"not found among the records: {missing}. See vendor/virtual-mpc-sample/docs/CUSTOM_FIRMWARE.md")

    os.makedirs(os.path.join(FW_LAB, "extracted"), exist_ok=True)
    os.makedirs(os.path.join(FW_LAB, "Firmware"), exist_ok=True)
    for rel, src in list(found.items()) + [(want[img_digest], img)]:
        dst = os.path.join(FW_LAB, rel)
        if os.path.exists(dst) and sha256(dst) == sha256(src):
            continue
        if os.path.exists(dst):
            os.remove(dst)
        try:
            os.link(src, dst)
        except OSError:
            shutil.copyfile(src, dst)
        print(f"-> vendor/virtual-mpc-sample/firmware/{rel}")
    print("firmware ready. Next: cd vendor/virtual-mpc-sample && python3 lab.py build")


if __name__ == "__main__":
    main()

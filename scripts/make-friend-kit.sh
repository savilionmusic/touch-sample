#!/usr/bin/env bash
# Build dist/"Touch Sample Kit"/ and dist/"Touch Sample Kit.zip" for a friend's Mac.
# Contains only: the repo (git archive HEAD), the open-source kernel + audio bridge, Setup.command,
# and a read-me. A leak check refuses to build if anything Akai-derived slipped in.
# Run from anywhere on macOS or Linux:  scripts/make-friend-kit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/vendor/virtual-mpc-sample"
DIST="$ROOT/dist"
NAME="Touch Sample Kit"
KIT="$DIST/$NAME"

die() { echo "make-friend-kit: $*" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "need sha256sum or shasum"; fi

KERNEL="$LAB/out/kernel/Image"
BRIDGE="$LAB/out/bridge/mpclab-audio-bridge"
[ -f "$KERNEL" ] || die "missing $KERNEL (run: cd vendor/virtual-mpc-sample && python3 lab.py build kernel)"
[ -f "$BRIDGE" ] || die "missing $BRIDGE (run: python3 lab.py build bridge)"
[ -f "$LAB/inputs.sha256" ] || die "missing $LAB/inputs.sha256"
git -C "$ROOT" diff --quiet HEAD -- || echo "note: uncommitted changes are NOT in the kit (git archive HEAD)."

rm -rf "$KIT" "$DIST/$NAME.zip"
mkdir -p "$KIT/prebuilt/kernel" "$KIT/prebuilt/bridge"
cp "$ROOT/scripts/friend-kit/Setup.command" "$KIT/Setup.command"
cp "$ROOT/scripts/friend-kit/READ ME FIRST.txt" "$KIT/READ ME FIRST.txt"
chmod +x "$KIT/Setup.command"
cp "$KERNEL" "$KIT/prebuilt/kernel/Image"
cp "$BRIDGE" "$KIT/prebuilt/bridge/mpclab-audio-bridge"
chmod +x "$KIT/prebuilt/bridge/mpclab-audio-bridge"
git -C "$ROOT" archive --format=tar.gz --prefix= -o "$KIT/TouchSample.tar.gz" HEAD

# ---- leak check ------------------------------------------------------------------------------
BAD_RE='(\.(img|qcow2|ext4|ext2|fit|raw)$|(^|/)(part1|part2|parr)$|(^|/)initramfs[^/]*|(^|/)keys(/|$)|(^|/)id_ed25519|firmware/extracted|(^|/)sdcard(/|$))'
leaks=0
check_list() { # label, stdin = paths
  local hits
  hits="$(grep -E "$BAD_RE" || true)"
  if [ -n "$hits" ]; then echo "LEAK in $1:" >&2; echo "$hits" >&2; leaks=1; fi
}
( cd "$KIT" && find . -type f | sed 's|^\./||' ) | check_list "kit files"
tar -tzf "$KIT/TouchSample.tar.gz" | check_list "TouchSample.tar.gz"

hashes="$(cut -d' ' -f1 "$LAB/inputs.sha256")"
while IFS= read -r f; do
  h="$(sha "$KIT/$f")"
  if printf '%s\n' "$hashes" | grep -qx "$h"; then echo "LEAK: $f matches a firmware hash" >&2; leaks=1; fi
done < <(cd "$KIT" && find . -type f | sed 's|^\./||')
# files inside the tarball, hashed too
TMPX="$(mktemp -d)"; trap 'rm -rf "$TMPX"' EXIT
tar -xzf "$KIT/TouchSample.tar.gz" -C "$TMPX"
while IFS= read -r f; do
  h="$(sha "$TMPX/$f")"
  if printf '%s\n' "$hashes" | grep -qx "$h"; then echo "LEAK: tarball file $f matches a firmware hash" >&2; leaks=1; fi
done < <(cd "$TMPX" && find . -type f | sed 's|^\./||')
[ "$leaks" = 0 ] || { rm -rf "$KIT"; die "leak check FAILED; kit removed."; }
echo "leak check passed."

# ---- zip (must keep Setup.command's exec bit) -----------------------------------------------
if command -v ditto >/dev/null 2>&1; then
  ( cd "$DIST" && ditto -c -k --keepParent "$NAME" "$NAME.zip" )
elif command -v zip >/dev/null 2>&1; then
  ( cd "$DIST" && zip -qr -X "$NAME.zip" "$NAME" )
else
  die "need ditto (macOS) or zip"
fi
echo "built: $DIST/$NAME.zip ($(du -h "$DIST/$NAME.zip" | cut -f1))"

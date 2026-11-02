#!/bin/bash
# Touch Sample friend kit: one-time setup on an Apple Silicon Mac. Double-click to run.
# Safe to run again: each step is skipped when already done.
#
# Hard rule: no Akai firmware is in this kit. The emulator's disk images are built here, on
# this Mac, from YOUR copy of the "MPC Sample 1.3.0 Updater".
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/Documents/Codex/TouchSample"
LAB_URL="https://github.com/orrpunk-art/virtual-mpc-sample"
LAB_COMMIT="78d28cea1efe7e16b8a15a86465a64f432945a41"
SLAB_URL="https://github.com/gospodindilly-ops/mpc-sample-lab"
SLAB_COMMIT="3d482b94c918b96d174f31c411686f2b18b74ce6"
COLIMA_STARTED=0

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
on_exit() {
  rc=$?
  if [ "$COLIMA_STARTED" = 1 ]; then colima stop >/dev/null 2>&1 || true; fi
  if [ "$rc" -ne 0 ]; then
    printf '\nSomething went wrong (see the message above). Fix it, then double-click Setup again;\nit carries on where it stopped.\n'
  fi
  if [ -t 0 ]; then read -r -p "Press Return to close this window. " _ || true; fi
}
trap on_exit EXIT
trap 'echo "Stopped at line $LINENO." >&2' ERR

# Look for the Akai updater: argument, else Desktop/Downloads (two levels deep).
find_updater() {
  if [ -n "${1:-}" ]; then
    [ -e "$1" ] || return 1
    printf '%s\n' "$1"; return 0
  fi
  local d found
  for d in "$HOME/Desktop" "$HOME/Downloads"; do
    [ -d "$d" ] || continue
    found="$(find "$d" -maxdepth 2 \( -iname '*MPC*Sample*Updater*.app' -o -iname '*MPC*Sample*Updater*.zip' -o -name 'MPCSAMPLE-1.3.0.12-update.img' \) 2>/dev/null | head -n 1)"
    if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  done
  return 1
}

# Allows `source Setup.command --functions-only` for testing find_updater.
if [ "${1:-}" = "--functions-only" ]; then trap - EXIT ERR; return 0 2>/dev/null || exit 0; fi

echo "Touch Sample setup. This installs a few tools and builds the emulated MPC Sample"
echo "on this Mac. It can take 30-60 minutes the first time. Leave this window open."

# a. Mac check
say "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || fail "This only works on a Mac."
[ "$(uname -m)" = "arm64" ] || fail "This needs an Apple Silicon Mac (M1 or newer). This one is $(uname -m)."
echo "OK: Apple Silicon Mac."

# b. Homebrew
say "Checking Homebrew (the Mac tool installer)"
if [ ! -x /opt/homebrew/bin/brew ]; then
  echo "Homebrew is not installed. Installing it now. You will be asked for your Mac password"
  echo "(typing shows nothing; that is normal). Press Return when it asks."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[ -x /opt/homebrew/bin/brew ] || fail "Homebrew did not install. Check your internet connection and try again."
eval "$(/opt/homebrew/bin/brew shellenv)"
echo "OK: Homebrew ready."

# c. Tools
say "Installing tools (qemu, colima, docker, git, python)"
for pkg in qemu colima docker git python@3.12; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then echo "have $pkg"; else echo "installing $pkg ..."; brew install "$pkg"; fi
done
export PATH="$(brew --prefix python@3.12)/libexec/bin:$PATH"
command -v python3 >/dev/null || fail "python3 not found after install."

# d. Project folder
say "Setting up the project folder $TARGET"
if [ -e "$TARGET" ] && [ ! -f "$TARGET/vendor/virtual-mpc-sample/lab.py" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  if [ ! -f "$TARGET/scripts/run-lab.command" ]; then
    fail "$TARGET already exists and is not a Touch Sample folder. Move or rename it, then run Setup again."
  fi
fi
OUT="$TARGET/vendor/virtual-mpc-sample/out"
if [ -f "$TARGET/vendor/virtual-mpc-sample/lab.py" ] && [ -f "$OUT/emmc.base.qcow2" ] && [ -f "$OUT/initramfs.cpio.gz" ] \
   && [ -f "$OUT/lab-layer.ext4" ] && [ -f "$OUT/fw/cmdline.txt" ] && [ -f "$OUT/kernel/Image" ]; then
  echo "Already built. Nothing to do except the shortcut."
  ALREADY=1
else
  ALREADY=0
  mkdir -p "$TARGET"
  if [ ! -f "$TARGET/scripts/run-lab.command" ]; then
    [ -f "$KIT/TouchSample.tar.gz" ] || fail "TouchSample.tar.gz is missing next to Setup.command. Re-unzip the kit."
    tar -xzf "$KIT/TouchSample.tar.gz" -C "$TARGET"
    echo "Project files unpacked."
  fi

  # e. Vendor repos at pinned versions
  say "Downloading the two emulator projects"
  clone_at() { # url dir commit
    if [ ! -d "$2/.git" ]; then
      if [ -d "$2" ] && [ -n "$(ls -A "$2")" ]; then fail "$2 exists and is not empty; remove it and run again."; fi
      mkdir -p "$(dirname "$2")"
      git clone -q "$1" "$2"
    fi
    git -C "$2" checkout -q "$3" 2>/dev/null || { git -C "$2" fetch -q origin && git -C "$2" checkout -q "$3"; }
    echo "OK: $(basename "$2") at ${3:0:8}"
  }
  clone_at "$LAB_URL" "$TARGET/vendor/virtual-mpc-sample" "$LAB_COMMIT"
  clone_at "$SLAB_URL" "$TARGET/vendor/mpc-sample-lab" "$SLAB_COMMIT"
  mkdir -p "$TARGET/vendor/virtual-mpc-sample/overlay/lab-layer/root/.ssh"

  # f. Prebuilt open-source pieces
  say "Copying the prebuilt kernel and audio bridge (open source, no Akai content)"
  mkdir -p "$OUT/kernel" "$OUT/bridge"
  [ -f "$KIT/prebuilt/kernel/Image" ] || fail "prebuilt/kernel/Image is missing from the kit."
  [ -f "$KIT/prebuilt/bridge/mpclab-audio-bridge" ] || fail "prebuilt/bridge/mpclab-audio-bridge is missing from the kit."
  cp "$KIT/prebuilt/kernel/Image" "$OUT/kernel/Image"
  cp "$KIT/prebuilt/bridge/mpclab-audio-bridge" "$OUT/bridge/mpclab-audio-bridge"
  chmod +x "$OUT/bridge/mpclab-audio-bridge"

  # g. Firmware from the friend's own updater
  say "Looking for your MPC Sample 1.3.0 Updater"
  if ! UPDATER="$(find_updater "${1:-}")"; then
    echo "I could not find the updater. Please:"
    echo "  1. Download 'MPC Sample 1.3.0 Updater' from Akai's website."
    echo "  2. Put it on your Desktop (the .zip or the .app, either is fine)."
    echo "  3. Double-click Setup again."
    exit 1
  fi
  echo "Found: $UPDATER"
  say "Reading the firmware out of your updater (stays on this Mac)"
  python3 "$TARGET/scripts/extract-firmware.py" "$UPDATER"

  # h. Build disk images
  say "Building the emulator's disk images"
  if ! docker info >/dev/null 2>&1; then
    echo "Starting the Linux helper (colima). The first start downloads a Linux VM: several minutes."
    colima start --cpu 4 --memory 4
    COLIMA_STARTED=1
  fi
  ( cd "$TARGET/vendor/virtual-mpc-sample" && python3 lab.py build images )
  if [ "$COLIMA_STARTED" = 1 ]; then colima stop; COLIMA_STARTED=0; fi
fi

# The project launcher uses the FAT32 card builder, including when the card is empty.
say "Installing the local SD-card tools"
python3 -m pip install --target "$TARGET/out/sample-tools" -r "$TARGET/lab-ext/sample-card-requirements.txt"

# Build the native controller app locally, using this Mac's project path.
say "Building Touch Sample for the MPC Touch"
"$TARGET/scripts/build-app.sh"
echo "The app is at $TARGET/dist/Touch Sample.app"

# i. Desktop shortcut
say "Creating the Desktop shortcut"
SHORTCUT="$HOME/Desktop/Start MPC Sample.command"
mkdir -p "$HOME/Desktop"
cat > "$SHORTCUT" <<'SH'
#!/bin/bash
# Starts the emulated MPC Sample and opens its screen in your browser.
ROOT="$HOME/Documents/Codex/TouchSample"
export PATH="/opt/homebrew/bin:$PATH"
( for _ in $(seq 120); do nc -z 127.0.0.1 8765 2>/dev/null && { open "http://127.0.0.1:8765/"; exit 0; }; sleep 1; done ) &
"$ROOT/scripts/run-lab.command"
SH
chmod +x "$SHORTCUT"
xattr -d com.apple.quarantine "$SHORTCUT" 2>/dev/null || true
chmod +x "$TARGET/scripts/run-lab.command" "$TARGET"/lab-ext/qemu-tune/* 2>/dev/null || true

say "All done!"
echo "Start it: double-click 'Start MPC Sample' on your Desktop. Your browser opens the MPC screen."
echo "Stop it: click that Terminal window and press Control-C. It saves and shuts down."
echo "Samples: put WAV files in $TARGET/vendor/virtual-mpc-sample/sdcard/ (make the folder if needed)."
echo "MPC Touch: open $TARGET/dist/Touch Sample.app after installing your existing touch driver and DisplayLink."
if [ -d "/Applications/Touch Sample.app" ]; then
  echo "Note: 'Touch Sample.app' is not needed without an MPC Touch screen. Use the Desktop shortcut instead."
fi
exit 0

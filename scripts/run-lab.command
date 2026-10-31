#!/bin/bash
# Touch Sample: start the emulated MPC Sample. Open this in Terminal.app (double-click, or
# `open -a Terminal scripts/run-lab.command`), not in an IDE's or the Claude app's terminal pane:
# QEMU gets throttled there and the sound clicks (vendor docs/PANEL.md "Clicks").
#
# Order matters: our panel server (the stock one plus /touch and /bridge) takes port 8765
# first, so `lab.py run` starts no panel of its own; the panel must be up before the app
# boots (it answers the app's start request with MAIN VOLUME).
# Ctrl-C here = the power key + "Yes": the MPC Sample saves and shuts down.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$ROOT/vendor/virtual-mpc-sample"
cd "$LAB" || exit 1

if nc -z 127.0.0.1 5554 2>/dev/null; then
  if ! nc -z 127.0.0.1 8765 2>/dev/null; then
    echo "The MPC Sample is running; restoring the Touch panel server."
    exec python3 "$ROOT/panel-ext/touch_server.py"
  fi
  echo "The MPC Sample and Touch panel are already running."
  exit 0
fi

SERVER_PID=""
if ! nc -z 127.0.0.1 8765 2>/dev/null; then
  python3 "$ROOT/panel-ext/touch_server.py" &
  SERVER_PID=$!
  for _ in $(seq 50); do nc -z 127.0.0.1 8765 2>/dev/null && break; sleep 0.1; done
fi
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null' EXIT

echo "Touch screen page: http://127.0.0.1:8765/touch   stock panel: http://127.0.0.1:8765/"
python3 lab.py run "$@"

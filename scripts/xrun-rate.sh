#!/bin/bash
# Read-only: guest playback xruns over N seconds (default 10), plus CPUs online and queued frames.
set -euo pipefail
cd "$(dirname "$0")/../vendor/virtual-mpc-sample"
n="${1:-10}"
python3 lab.py ssh "cat /sys/devices/system/cpu/online; a=\$(grep xrun_counter /proc/asound/Loopback/pcm0p/sub0/status); sleep $n; b=\$(grep xrun_counter /proc/asound/Loopback/pcm0p/sub0/status); echo \"\$a -> \$b in ${n}s\"; grep -E 'delay|hw_ptr' /proc/asound/Loopback/pcm0p/sub0/status"

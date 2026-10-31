# Claude handoff: Touch Sample audio

Date: 2026-10-31. Work only in `/Users/savmacbook/Documents/Codex/TouchSample`.

## Task and user expectations

Sav asked Codex to hand this work to Claude. Continue investigating and fixing the persistent clicks/pops and shaky audio. **Audio is audible, but this problem is unresolved.** Sav says it sounds as if the engine is struggling for headroom/CPU. That is a listening observation, not a proven CPU-capacity diagnosis.

Sav uses Universal Audio Apollo speakers/headphones at **44.1 kHz**. Keep the native, integrated Touch instrument experience: no visible browser and no dragging a Chrome window to the Touch. Q-LINK selects banks, rather than sending KNOB FX. Sav wants playable latency; a larger host buffer was tested and rejected because clicks remained and delay increased. Physical sample start/end editing and some remaining button mappings are secondary unfinished work; do not silently treat them as fixed.

## Read first and preserve

Read `claude-project/PROJECT_INSTRUCTIONS.md`, `PLAN.md`, `CONTROL_MAP.md`, then `docs/DESIGN.md`. `docs/MANUAL.md` describes the current user workflow. The original `docs/HANDOFF.md` is historical; Phase 5 is already implemented and hardware tests have happened.

- Never commit Akai firmware, extracted partitions, factory content, keys, or personal samples.
- Preserve PaperCut/Koala, `com.savilion.mpc-touchd`, AkaiTouchPanel.kext, DisplayLink, and hardware firmware. Never run another raw touch reader.
- Never send SysEx `0x5A`; no SysEx/bursts to the Private port. Use the existing allow-listed bridge only. One app owns the Touch; refuse competing owners.
- Launch the emulator through `scripts/run-lab.command` in **Terminal.app**, never the coding assistant's shell. Its scheduling context matters. Do not start another VM while port 5554 is occupied.
- Prefer read-only diagnostics and `--self-test`. Sav does physical playing/listening. During this session Sav explicitly authorized opening/restarting the integrated app for tests, accepted Terminal prompts, and reported results. Preserve that scope; no arbitrary hardware commands or captures.
- Use Stop/Quit in Touch Sample to save before shutting down. Do not kill a healthy VM and discard work. The force-QMP quit used in one failed test was solely for the crashed experimental guest.
- Small local commits, no force-push or history rewrite, **nothing pushed without Sav's OK**. Nothing from this session was pushed.

The shared-profile Hindsight recall was available and consulted. Repository files remain authoritative. Do not put this handoff/transcript into the personal profile bank.

## Git and current live state

Current branch: **`codex/guest-audio-buffer-test`**, based on `33166b5`. Documentation may be committed after this file is written; inspect `git log` and `git status` before changing anything.

Experimental worktree changes intentionally left for continuity:

- Modified `scripts/run-lab.command`: prepends `lab-ext/qemu-single-cpu` to PATH.
- Untracked `lab-ext/qemu-single-cpu/qemu-system-aarch64`: shell wrapper replaces every `-smp` value with `1`, including DTB generation, then execs `/opt/homebrew/bin/qemu-system-aarch64`.
- Documentation changes: this file, `docs/AUDIO_DIAGNOSIS.md`, and the pointer in `docs/HANDOFF.md`.

The single-vCPU experiment is **not a working fix and should not become the default without evidence**. Last read-only snapshot: the app and VM were still running, guest CPUs online was `0` (one CPU), and `ac50` plus `mpclab-audio` services were active. Host listener PIDs were QEMU **28638** on 5554/5557, panel Python **26615** on 8765, and app PID **28713**. PIDs are a snapshot, not stable identifiers; recheck. No VM/app was stopped merely to write this handoff.

The panel Python is an existing persistent diagnostic process. Its loaded code includes a temporary screen-burst toggle experiment, with normal bursts restored/enabled. `panel-ext/touch_server.py` on disk was restored to committed source. After a clean session stop, restart the panel normally through Terminal; do not assume its current in-memory code is identical to disk. Do not launch a second panel on 8765.

**The original lab kernel is restored.** SHA-256 of both `vendor/virtual-mpc-sample/out/kernel/Image` and the preserved `out/kernel-period-test/original-Image` was verified as:

```text
7eb5c5b3f6df3681ded6a03e12390cc764c099db651c6c91a9ae4e0ac69215bc
```

The failed kernel-test patch/build/install scripts were removed from the worktree. Ignored trial build artifacts remain under `out/kernel-period-test/`; do not install them. Vendor Git worktree was clean. No original Akai firmware or protected macOS driver was modified.

To roll back only the CPU-count experiment: inspect/save the launcher diff, restore `scripts/run-lab.command` to HEAD (`git restore -- scripts/run-lab.command`), then use the app's normal save/quit and reopen from the native app/Terminal workflow. The wrapper becomes unused; it can be removed once no longer needed. Do not restart from the assistant shell. Verify `/sys/devices/system/cpu/online` reports `0-3` after rollback. Restoring the launcher alone does not alter the already-running VM.

## Implemented and user-tested behavior

- `app/Sources/TouchSampleApp/main.swift`: AppKit app, auto-start, owner checks, native borderless WKWebView on the Touch, startup/reconnect screen. Checks both panel 8765 and QMP 5554 before deciding a session exists; opens the launcher in Terminal when needed. Stop/Quit stops the bridge/audio and calls `python3 lab.py stop` to save.
- `app/Sources/TouchSampleApp/DirectTouch.swift`: receives the installed driver's CFMessagePort `com.savilion.papercut.touch`. Packet: Int32 type, Int32 clicks, Double global x, Double global y (24 bytes). Converts to DOM coordinates and forwards events without a second USB reader or moving the cursor. Driver protocol was verified against the newer local PaperCut source under `PaperCut-bf2`, not assumed from older main.
- `panel-ext/touch.html`: direct-touch dispatch keeps the original target during drag/release. Sav confirmed the touchscreen controls work. The embedded stock firmware LCD is not itself touch-enabled by upstream; do not confuse that image with our surrounding touch controls. Touching sample start/end remains a user-reported gap.
- Q-Link bank behavior is in `BridgeCore` and `mappings/default.json`: Q1–3 map K1–K3, Q4 switches FADER / MAIN VOLUME with bank (Shift selects the opposite); KNOB FX remains an on-screen action.
- `scripts/build-app.sh`: release build, `dist/Touch Sample.app`, bundle ID `com.savilion.touchsample`, ad-hoc signs our bundle only. `dist/` is ignored.

### Current audio path

```text
Stock Sample app: 44.1 kHz, 4ch S32_LE, 128-frame processing
  -> guest snd-aloop
  -> upstream mpclab-audio-bridge selects stereo and converts to S16_LE
  -> QEMU virtio-serial WebSocket ws://127.0.0.1:5557
  -> NativeAudio.swift / AVAudioPlayerNode / AVAudioEngine
  -> macOS default output: Apollo at 44.1 kHz
```

`NativeAudio.swift` uses a serial user-initiated queue, preserves partial PCM frames, decodes signed little-endian stereo to Float32, schedules buffers, starts at 2048 queued frames (~46 ms), and bounds stale queued audio at 16384 frames. Current code does not adapt the startup target. Native WKWebView loads `/touch?audio=native`; the page does not open a competing audio socket. Chrome fallback keeps browser audio but is not Sav's desired workflow.

Logs: `out/app.log` (ignored), including received frames, queued frames, peak, target, and `underruns`. The native underrun counter counts zero scheduled frames after `.dataConsumed` callbacks; it is bookkeeping, not a direct hardware xrun report. The latest tail showed target=2048, cumulative underruns=107, and zero peaks in those recent lines. Do not infer permanent silence or a universal healthy host queue from earlier intervals.

## Measurements and trials already done

Full narrative is in `docs/AUDIO_DIAGNOSIS.md`. Important results:

1. **Apollo route works for ordinary host sound.** Sav heard the quiet Mac test chime and a clear short AVAudioEngine tone. Later Sav confirmed actual Sample sounds became audible with native playback. These listening results do not establish clean continuous playback.
2. **Not an established 48/44.1 mismatch.** CoreAudio and live WebKit context were confirmed at 44100 Hz. A separate worklet bug at 48000 Hz was fixed by scaling read ratio by `44100 / sampleRate`; synthetic sine tests went from 17 underruns/5 seconds to zero. This was a real fallback bug, but live 44.1 kHz clicks persisted.
3. **Larger host buffer was rejected.** 4096-frame/adaptive buffering still clicked and Sav reported excessive delay. Restored 2048. In a measured ten-second larger-buffer interval, host queue stayed fed while guest playback xruns rose 160 -> 190. This establishes guest dropouts in that interval, not that host problems can never occur.
4. **Guest scheduling latency exists.** A separately compiled upstream `tools/wakelat.c` run recorded 8626 wakeups in 10 seconds, 24 >6 ms late, worst 17.8 ms; guest xruns rose 180 -> 212. The helper itself ran a 1 ms realtime thread and can perturb load. It was removed from guest `/tmp` afterward. This supports investigating timing; it does not prove every click has one cause.
5. **More guest buffer capacity did not ensure more queued audio.** `snd_aloop.min_buffer=2048` was accepted, yet observed playback delay stayed around 360 frames (~8 ms), with 17 xruns/10 seconds. Default min_buffer=1024 restored. Distinguish capacity, current fill, period size, and host buffering.
6. **512-frame guest period failed.** A temporary lab-Linux-kernel `min_period` constraint was built in the existing Docker cache and tested. The Sample printed 512-sample buffer then SIGSEGV/restart-looped. Rolled back to the original lab kernel and verified 128-frame periods / 1024 buffer. Do not repeat this as a proposed ready fix or change the stock app's processing block size casually.
7. **No demonstrated gain from a transient per-QEMU power assertion, high latency/throughput tier request, or disabling extra QMP screen bursts.** Bursts-off still gave 30 guest xruns/10 seconds. All those transient settings were restored/expired; normal panel behavior is active. Disabling bursts was not the same as eliminating all VNC/display work.
8. **One vCPU is not a solution.** Four-vCPU baseline immediately before the trial: 21 guest xruns/10 seconds, native counter stable in that interval. One-vCPU first interval: 50 -> 59 guest xruns/10 seconds. Later guest playback counter reached 837 and native queue counter 107. Those later totals cover different time spans, so do not compare them as rates. No clean audible result was established.
9. **Do not confuse average CPU with deadline misses.** A prior snapshot showed QEMU ~30–38% of one core, alongside WindowServer, DisplayLink, SoundFlow, Pro Tools, etc. Total CPU saturation was not proven. Guest audio app threads were SCHED_RR priority 20; bridge reader/feeder FIFO 15, correctly below the app. Kernel was PREEMPT, HZ=1000, not PREEMPT_RT. Do not kill other user apps or alter drivers without a task-specific reason/authorization.

Last guest snapshot (one CPU; counters cumulative):

| Endpoint | Owner/direction | Buffer | Delay | Xruns |
| --- | --- | ---: | ---: | ---: |
| pcm0p | Sample playback | 1024 | 329 | 837 |
| pcm0c | Sample capture | 1024 | 99 | 34 |
| pcm1c | Bridge reads app output | 2048 | 11 | 11 |
| pcm1p | Bridge feeds app input | 1024 | 891 | 34 |

All four endpoints reported RUNNING, S32_LE, 4 channels, 44100 Hz, period 128. The app's capture/playback are linked and its watchdog can restart both; inspect both directions rather than assuming every reset began in output.

## Upstream and continuation

Pinned upstream is `orrpunk-art/virtual-mpc-sample`, commit `78d28cea1efe7e16b8a15a86465a64f432945a41`. A live remote/issue check earlier in this investigation found no newer main commit or audio-fix issue. Recheck if relevant; these are time-sensitive facts. Its `docs/PANEL.md` explains the audio architecture, known vCPU stalls, and experiments that did not help upstream (including user-interactive vCPU QoS). Upstream did not establish audible Mac playback merely by measuring bridge signal levels.

Recommended next steps, not implemented fixes:

1. Restore a known four-vCPU baseline and measure comparable short intervals while Sav plays the same material. Preserve project state when restarting.
2. Correlate guest playback/capture xruns, bridge drops/under counters, and native queue statistics with the audible fault. Recording/analyzing the PCM already available in software could distinguish corrupted/discontinuous source from host playback starvation; do not open a competing port-5557 client while native audio owns it. No such continuous correlated recording was completed here.
3. Investigate why the app leaves only ~320–360 playback frames queued despite the larger allowed buffer. A runtime-only ALSA tracing/preload idea was considered, but **no shim was written, loaded, or tested**, and no guest service override was installed. Check actual ALSA start/link/write behavior before proposing buffer prefill. Extra capacity alone was already tried; period 512 already crashed. Respect the firmware-preservation rule.
4. Validate improvements with both measured underrun rates and Sav's listening/latency report. Do not claim success from meters, a passing build, or a short clear tone.

Read-only guest inspection:

```sh
cd /Users/savmacbook/Documents/Codex/TouchSample/vendor/virtual-mpc-sample
python3 lab.py ssh 'cat /sys/devices/system/cpu/online; cat /proc/asound/Loopback/pcm0p/sub0/hw_params; cat /proc/asound/Loopback/pcm0p/sub0/status'
```

Sample service is **`ac50.service`**, not `mpclab-app.service`; bridge is `mpclab-audio.service`. `systemctl cat ac50` shows stock `/usr/bin/launch-ac50`. No environment/preload overrides were installed. `/lab` was absent when last checked even though upstream defines an optional 9p mount; do not assume the host share is mounted. Guest utilities are BusyBox; GNU `ps -eLo` and shorthand `head -30` did not work.

Docker is Colima with cached `mpclab-tools`. No duplicate kernel build should be started. The cached Linux source was restored after the temporary patch build; a future build should verify source/artifacts rather than trust stale cached objects. Host/guest ports: panel 8765, QMP 5554, audio levels/control 5556, PCM 5557, SSH 2022, VNC 5910.

## Checks actually run in the preceding implementation work

- Release Swift build and `scripts/build-app.sh`; plist validation and ad-hoc bundle signature verification.
- `app/.build/release/touch-bridge --self-test`: **128 passed**, no hardware/network.
- `app/.build/release/TouchSampleApp --self-test`: PCM signed amplitude, stereo, little-endian, malformed-frame checks, plus direct-touch packet/coordinate checks without opening the audio device/touch port.
- `node scripts/test-direct-touch.cjs`: page hold/drag/release behavior.
- `node scripts/test-audio-worklet.cjs`: synthetic sine playback at 44.1 and 48 kHz.
- Shell syntax checks for the launcher and single-CPU wrapper; documentation diff checks.
- Manual results are the Sav listening/touch reports above. These tests were run during the preceding work, **not rerun merely to write this handoff**. They do not certify physical audio quality.

## Relevant local commits

| Commit | Change |
| --- | --- |
| `33166b5` | Record guest underrun/scheduling measurements |
| `86372a3` | Restore shorter host buffer after latency test |
| `b4996b3` | Native audio and diagnostics; its adaptive policy was subsequently reverted |
| `7985825` | Direct-touch/Q-Link documentation |
| `ec27933` | Mouseless direct touch and automatic panel audio |
| `f5594c7` | Q-LINK bank selection |
| `05fbe2b` | Native startup, display, missing-session recovery |
| `3c50452` | App bundle/display alignment |

They are local history; no push was made. Keep the working native controller experience intact while fixing audio.

# Audio investigation — 2026-10-31

Upstream is `orrpunk-art/virtual-mpc-sample`, pinned at `78d28cea1efe7e16b8a15a86465a64f432945a41`. A live `git ls-remote` check found the same main revision. The public issue list had one SD/autoboot setup issue, no audio fix. Upstream `docs/PANEL.md` explicitly distinguishes measured bridge signal levels from audible Mac playback, which it did not verify.

Sav heard only clicks/pops from the WebKit player, while an `afplay` Mac test chime was audible on Universal Audio. CoreAudio initially reported 48 kHz and later confirmed Sav's intended 44.1 kHz setting; preferred output channels are 1–2. No global device setting was changed by this investigation.

Measured during emulator playback:

- Guest stereo peaks reached about 0.10, phones about 0.26. Host drops were zero and the guest underrun counter did not change during the first short test.
- WebKit's context and worklet both reported 44100 Hz, running state, and input/output peaks around 0.10. Thus a 48 kHz context mismatch does not explain the live failure.
- PCM traffic reached the worker at about 176400 bytes/s. Worker delivery gaps reached 60–69 ms, and the worklet's underrun counter increased. These explain some clicks, but do not establish the cause of the near-silence Sav heard.
- Separately, a synthetic steady PCM test exposed a sample-rate conversion bug in the copied worklet at 48000 Hz: 17 underruns in five seconds. Scaling its read ratio by 44100/outputRate preserves the sine amplitude and eliminates those simulated underruns at both 44100 and 48000 Hz.

The app now offers the same native display and direct-touch integration while AVAudioEngine/AVAudioPlayerNode plays the unchanged upstream S16_LE stereo 44100 Hz WebSocket stream. The page receives `audio=native` and does not open a second PCM client. Native playback prebuffers 2048 source frames (about 46 ms at 44.1 kHz) and bounds queued latency; logs record hardware format, received frames, queued frames, peaks and underruns. Reconnect and Stop close/release the socket and engine. Chrome fallback retains the browser player.

Automated checks: native PCM signed/stereo/little-endian conversion and malformed-frame handling; synthetic five-second sine playback at both output rates; existing direct-touch packet/coordinate and page hold/drag/release checks. These are software checks. Audible native playback requires Sav's test and is not established by nonzero meters.

Sav confirmed the native audio path is audible on the Apollo, with some clicks and pops remaining. A trial with a 4096-frame adaptive host buffer still produced clicks and Sav reported too much delay, so 2048 frames was restored. With the larger buffer, the host queue remained fed while the guest ALSA xrun counter increased from 160 to 190 in ten seconds. Guest-side dropouts are established; host scheduling and screen-refresh workload are possible causes, not yet proven. A CPU snapshot showed QEMU about 38% of one core, which does not reveal brief scheduler stalls. No change was made to the guest firmware, driver, or DisplayLink.

The 4096-frame host-buffer trial was audible but Sav reported too much delay and continuing clicks. After restoring 2048 frames, guest ALSA `/proc/asound/Loopback/pcm0p/sub0/hw_params` reported S32_LE, 44100 Hz, 4 channels, 128-frame period and 1024-frame buffer. The guest `xrun_counter` rose from 160 to 190 over 10 seconds with the larger host buffer; the host queue stayed fed in that interval. A CPU snapshot showed QEMU ~38% of one core, which does not establish whether brief stalls occurred.

The upstream `tools/wakelat.c` helper was compiled separately using the already-built `mpclab-tools` image, copied to guest `/tmp`, and removed after a 10-second run. It recorded 8626 wakeups, 24 over 6 ms late, worst 17.8 ms; the guest playback xrun counter increased from 180 to 212 in that run. The diagnostic itself runs a 1 ms realtime thread and can perturb scheduling, so this is evidence of latency under diagnostic load, not proof that every click has the same cause. The prior 30-xrun measurement did not run this helper. Guest scheduling is a likely contributor; no tested fix for those guest underruns has yet been established.

# Audio investigation — 2026-10-31

Upstream is `orrpunk-art/virtual-mpc-sample`, pinned at `78d28cea1efe7e16b8a15a86465a64f432945a41`. A live `git ls-remote` check found the same main revision. The public issue list had one SD/autoboot setup issue, no audio fix. Upstream `docs/PANEL.md` explicitly distinguishes measured bridge signal levels from audible Mac playback, which it did not verify.

Sav heard only clicks/pops from the WebKit player, while an `afplay` Mac test chime was audible on Universal Audio. CoreAudio initially reported 48 kHz and later confirmed Sav's intended 44.1 kHz setting; preferred output channels are 1–2. No global device setting was changed by this investigation.

Measured during emulator playback:

- Guest stereo peaks reached about 0.10, phones about 0.26. Host drops were zero and the guest underrun counter did not change during the first short test.
- WebKit's context and worklet both reported 44100 Hz, running state, and input/output peaks around 0.10. Thus a 48 kHz context mismatch does not explain the live failure.
- PCM traffic reached the worker at about 176400 bytes/s. Worker delivery gaps reached 60–69 ms, and the worklet's underrun counter increased. These explain some clicks, but do not establish the cause of the near-silence Sav heard.
- Separately, a synthetic steady PCM test exposed a sample-rate conversion bug in the copied worklet at 48000 Hz: 17 underruns in five seconds. Scaling its read ratio by 44100/outputRate preserves the sine amplitude and eliminates those simulated underruns at both 44100 and 48000 Hz.

The app now offers the same native display and direct-touch integration while AVAudioEngine/AVAudioPlayerNode plays the unchanged upstream S16_LE stereo 44100 Hz WebSocket stream. The page receives `audio=native` and does not open a second PCM client. Native playback prebuffers 4096 source frames (about 93 ms at 44.1 kHz), increases the target after an underrun and bounds queued latency; logs record hardware format, received frames, queued frames, peaks and underruns. Reconnect and Stop close/release the socket and engine. Chrome fallback retains the browser player.

Automated checks: native PCM signed/stereo/little-endian conversion and malformed-frame handling; synthetic five-second sine playback at both output rates; existing direct-touch packet/coordinate and page hold/drag/release checks. These are software checks. Audible native playback requires Sav's test and is not established by nonzero meters.

Sav confirmed the native audio path is audible on the Apollo, with some clicks and pops remaining. The native queue had emptied during the session, so the starting cushion was increased from 2048 to 4096 frames; after an empty queue it pauses and re-primes with an incrementally larger target (maximum 8192 frames). This trades playing latency for resilience. Upstream also reports guest-side audio restarts that this host buffer cannot eliminate. The revised buffer needs Sav's audible and playing-latency test.

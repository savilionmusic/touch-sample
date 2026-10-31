# Touch Sample manual

Touch Sample runs the MPC Sample firmware in an emulator. Keep this project folder in place: the app uses the scripts, settings, and emulator alongside it. Your own samples belong in `vendor/virtual-mpc-sample/sdcard/`; there is no factory library.

## Start and play

1. Connect the MPC Touch and quit PaperCut, Koala Link, Koala and Akai MPC. Only one app can own the Touch.
2. Build the app with `scripts/build-app.sh` in Terminal, then open `dist/Touch Sample.app`. Choose the Mac's output or the Touch audio interface in Sound Settings. The app uses the system default output.
3. The app starts automatically when no conflicting controller app is running. Use Start to retry after a stop or a conflict. If needed, the app opens `scripts/run-lab.command` in Terminal and waits for the panel. Leave that Terminal session open. When the Touch screen appears, tap it if the page asks for sound. Close other panel pages, since only one page can play the emulator's audio.
4. Play the Touch pads and controls. The on-screen controls include functions missing from the hardware. If the display is not detected, check its connection and macOS display settings. The status line reports the bridge and MIDI connection.

For an audio comparison, stop first, select **Use Chrome for the Touch screen**, and start again. Google Chrome must be installed. Compare its sound and latency with the default WebKit view. The Chrome window uses a separate temporary profile.

## Stop and save

Click Stop or quit the app. The bridge releases held controls and the emulator receives `lab.py stop` to save before shutting down. Wait for the stop to finish before disconnecting. If the app reports a stop failure, check Terminal; from `vendor/virtual-mpc-sample`, run `python3 lab.py stop` and check its output.

## Change a mapping

Stop the app first. Make a backup of `mappings/default.json`, then edit it with a plain-text editor. Entries connect Touch control names to Sample actions; Shift entries describe the alternate actions. Use existing entries and `CONTROL_MAP.md` as examples, preserve valid JSON, and restart to load changes. Keep the hardware profile and safety rules intact. If the bridge reports a configuration error, restore the backup.

## Locked Touch

If USB remains present but MIDI is silent, stop the app and run this in Terminal:

```sh
"$HOME/Library/Application Support/MPC Touch Driver/mpc_replug"
```

Reconnect as prompted, then start again. Do not change or rebuild the touch driver, AkaiTouchPanel.kext, or DisplayLink.

The built-in Touch window appears during startup and follows the display if macOS re-enumerates it. **Show Touch** brings it forward. The app checks both the panel server and emulator before starting; an old panel page alone does not mean the Sample is running. Display placement, page-load failures and bridge output errors are recorded in `out/app.log` for troubleshooting. MIDI connected means the ports were found; it does not certify the physical screen, lights, touch alignment or every control.

The Touch uses the installed driver's existing direct-touch connection, so taps and drags operate the panel without moving the Mac pointer. The app claims that connection only after the controller owner check; it releases it on Stop. Audio starts with the panel; a visible sound badge provides a retry if playback fails. Q-LINK cycles banks A/B: Q1–Q3 remain K1–K3, and Q4 switches between FADER and MAIN VOLUME. Shift temporarily selects the opposite Q4 assignment. KNOB FX stays available on screen.

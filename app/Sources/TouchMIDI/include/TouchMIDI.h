// TouchMIDI: CoreMIDI find/connect/send for the Akai MPC Touch.
//
// Adapted from PaperCut (read-only reference, ~/Documents/Codex/PaperCut):
//   - app/Sources/MPCRealtime/ControllerSetup.c       (output, startup SysEx, device/entity match)
//   - outputs/mpc-touch-research/midi_capture.c        (read-only input capture)
//   - app/Sources/MPCApp/Instrument.swift, MIDIInput    (endpoint discovery: global source list AND entity
//                                                        traversal, Public/Private roles)
//
// Hard rules enforced HERE, in the only function that writes to the device (touch_send):
//   - no SysEx with byte 4 == 0x5A (F0 47 xx 37 5A ...) is ever sent;
//   - no SysEx at all goes to the Private port;
//   - the Private port only receives B0 23..26 and B0 5A..5D;
//   - the Public port only receives well-formed single messages (channel messages or one complete SysEx <= 64 bytes).
// touch_startup() sends exactly the three Public SysEx from CONTROL_MAP.md "Touch startup", nothing else.
#ifndef TOUCH_MIDI_H
#define TOUCH_MIDI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TOUCH_PORT_PUBLIC  0
#define TOUCH_PORT_PRIVATE 1

typedef struct {
    int  role;            // TOUCH_PORT_PUBLIC / TOUCH_PORT_PRIVATE
    int  is_source;       // 1 if this endpoint is a MIDI source (Touch -> Mac)
    int  is_destination;  // 1 if this endpoint is a MIDI destination (Mac -> Touch)
    char device[64];
    char entity[64];
    char endpoint[96];
} touch_endpoint_info;

// Lists the MPC Touch endpoints that would be used. CoreMIDI queries only; opens nothing, sends nothing.
int touch_list_endpoints(touch_endpoint_info *out, int max);

// Input callback. `bytes` are raw packet bytes (may hold several messages, running status, or SysEx pieces).
typedef void (*touch_input_fn)(int role, const uint8_t *bytes, int len, uint64_t host_ns, void *ctx);
// Called (on the thread that created the client; needs a running run loop) when the MIDI setup changed.
typedef void (*touch_setup_fn)(void *ctx);

// Creates the client + input port, connects every Public/Private source of the MPC Touch. When want_output is 0
// no output port is created at all (read-only). Returns the number of connected input sources (>= 0, zero when
// the Touch is absent: the client stays open so a later touch_rescan can pick it up), or a negative error.
int touch_open(touch_input_fn input, void *input_ctx, touch_setup_fn setup, void *setup_ctx, int want_output);
// Re-scans endpoints (after a setup change). Returns the number of connected inputs; *changed is set to 1 if
// the set of input endpoints or the availability of the Public/Private destinations differs from before.
int touch_rescan(int *changed);
int touch_input_count(void);
// Bit 0 set: Public destination present; bit 1 set: Private destination present.
int touch_output_mask(void);
void touch_close(void);

// Return codes of touch_validate / touch_send.
#define TOUCH_OK               0
#define TOUCH_ERR_ARGS        -1
#define TOUCH_ERR_SYSEX_5A    -2   // SysEx whose byte 4 is 0x5A: never sent
#define TOUCH_ERR_PRIVATE_SYSEX -3 // any SysEx to Private
#define TOUCH_ERR_PRIVATE_MSG -4   // Private only takes B0 23..26 / B0 5A..5D
#define TOUCH_ERR_MALFORMED   -5
#define TOUCH_ERR_NOT_OPEN    -6   // not open for output, or destination absent
#define TOUCH_ERR_COREMIDI    -7

// Pure check with no I/O: would touch_send accept this message?
int touch_validate(int role, const uint8_t *bytes, int len);
// Sends exactly one MIDI message (or one complete SysEx) after touch_validate. Does no pacing: the caller owns that.
int touch_send(int role, const uint8_t *bytes, int len);

// The three Public SysEx of the accepted startup, in order: unlock, gate, backlight/display on.
int touch_startup_count(void);
int touch_startup_message(int index, uint8_t *out, int cap); // returns length, or <0
// Sends them in order on Public, with 20 ms between (blocking ~40 ms). Returns 0 or the first error.
int touch_startup(void);

// Monotonic nanoseconds (mach absolute time converted), same clock as the host_ns passed to input callbacks.
uint64_t touch_now_ns(void);
const char *touch_error_string(int code);

#ifdef __cplusplus
}
#endif
#endif

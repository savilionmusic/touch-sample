// TouchMIDI implementation. See include/TouchMIDI.h for the PaperCut files this is adapted from and the
// hard rules enforced here.
//
// CoreMIDI's plain MIDIInputPortCreate / MIDISend are used (as PaperCut does) because they take byte packets,
// which is what the Touch's classic MIDI 1.0 endpoints speak. They are marked deprecated in newer SDKs, so the
// deprecation warning is silenced for this file only.
#include "TouchMIDI.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define MAX_ENDPOINTS 32
#define MAX_SOURCES 16
#define MAX_SYSEX 64

typedef struct {
    int role;
    int active;
    MIDIEndpointRef ep;
} src_ctx;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static MIDIClientRef g_client;
static MIDIPortRef g_in, g_out;
static int g_open;
static int g_want_output;
static touch_input_fn g_input_fn;
static void *g_input_ctx;
static touch_setup_fn g_setup_fn;
static void *g_setup_ctx;
static src_ctx g_src[MAX_SOURCES];
static MIDIEndpointRef g_dest[2];
static int g_input_count;

// ---------------------------------------------------------------- time

uint64_t touch_now_ns(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

static uint64_t host_to_ns(MIDITimeStamp t) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    if (t == 0) return touch_now_ns();
    return t * tb.numer / tb.denom;
}

// ---------------------------------------------------------------- property helpers (PaperCut: get_name)

static void get_string(MIDIObjectRef obj, CFStringRef key, char *buf, size_t n) {
    CFStringRef value = NULL;
    buf[0] = '\0';
    if (MIDIObjectGetStringProperty(obj, key, &value) == noErr && value) {
        CFStringGetCString(value, buf, (CFIndex)n, kCFStringEncodingUTF8);
        CFRelease(value);
    }
}

static int get_int(MIDIObjectRef obj, CFStringRef key) {
    SInt32 v = 0;
    MIDIObjectGetIntegerProperty(obj, key, &v);
    return (int)v;
}

static int contains_ci(const char *hay, const char *needle) {
    return hay && needle && strcasestr(hay, needle) != NULL;
}

// ---------------------------------------------------------------- endpoint discovery

typedef struct {
    touch_endpoint_info info;
    MIDIEndpointRef ep;
} cand;

static cand *find_cand(cand *c, int n, MIDIEndpointRef ep, int is_source) {
    for (int i = 0; i < n; ++i)
        if (c[i].ep == ep && c[i].info.is_source == is_source) return &c[i];
    return NULL;
}

static int add_cand(cand *c, int n, int max, MIDIEndpointRef ep, int is_source, int role,
                    const char *device, const char *entity) {
    if (n >= max || find_cand(c, n, ep, is_source)) return n;
    cand *x = &c[n];
    memset(x, 0, sizeof(*x));
    x->ep = ep;
    x->info.role = role;
    x->info.is_source = is_source;
    x->info.is_destination = !is_source;
    snprintf(x->info.device, sizeof(x->info.device), "%s", device);
    snprintf(x->info.entity, sizeof(x->info.entity), "%s", entity);
    get_string(ep, kMIDIPropertyName, x->info.endpoint, sizeof(x->info.endpoint));
    return n + 1;
}

// Role of an entity/endpoint pair: -1 = not ours. Mirrors PaperCut's connectTouchControls: Private when the
// Private property is set or the name says Private; Public when the name says Public. The "MIDI Port" entity
// (the Touch's DIN jacks) is never used.
static int classify(MIDIObjectRef entity, MIDIObjectRef endpoint, const char *entity_name) {
    char ep_name[96];
    ep_name[0] = 0;
    if (endpoint) get_string(endpoint, kMIDIPropertyName, ep_name, sizeof(ep_name));
    if (contains_ci(entity_name, "MIDI Port")) return -1;
    int priv = (entity && get_int(entity, kMIDIPropertyPrivate) == 1) ||
               (endpoint && get_int(endpoint, kMIDIPropertyPrivate) == 1) ||
               contains_ci(entity_name, "Private");
    int pub = contains_ci(entity_name, "Public") || contains_ci(ep_name, "Public");
    if (priv) return TOUCH_PORT_PRIVATE;
    if (pub) return TOUCH_PORT_PUBLIC;
    return -1;
}

static int collect(cand *c, int max) {
    int n = 0;
    // 1) global source list
    ItemCount ns = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < ns; ++i) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        MIDIEntityRef entity = 0;
        MIDIDeviceRef device = 0;
        if (MIDIEndpointGetEntity(ep, &entity) != noErr || !entity) continue;
        if (MIDIEntityGetDevice(entity, &device) != noErr || !device) continue;
        char dname[64], ename[64];
        get_string(device, kMIDIPropertyName, dname, sizeof(dname));
        if (!contains_ci(dname, "MPC Touch") || get_int(device, kMIDIPropertyOffline)) continue;
        get_string(entity, kMIDIPropertyName, ename, sizeof(ename));
        int role = classify(entity, ep, ename);
        if (role < 0) continue;
        n = add_cand(c, n, max, ep, 1, role, dname, ename);
    }
    // 2) entity traversal (some CoreMIDI versions omit the hidden Private endpoint from the global list)
    ItemCount nd = MIDIGetNumberOfDevices();
    for (ItemCount d = 0; d < nd; ++d) {
        MIDIDeviceRef device = MIDIGetDevice(d);
        char dname[64];
        get_string(device, kMIDIPropertyName, dname, sizeof(dname));
        if (!contains_ci(dname, "MPC Touch") || get_int(device, kMIDIPropertyOffline)) continue;
        ItemCount ne = MIDIDeviceGetNumberOfEntities(device);
        for (ItemCount e = 0; e < ne; ++e) {
            MIDIEntityRef entity = MIDIDeviceGetEntity(device, e);
            char ename[64];
            get_string(entity, kMIDIPropertyName, ename, sizeof(ename));
            int role = classify(entity, 0, ename);
            if (role < 0) continue;
            ItemCount nsrc = MIDIEntityGetNumberOfSources(entity);
            for (ItemCount k = 0; k < nsrc; ++k)
                n = add_cand(c, n, max, MIDIEntityGetSource(entity, k), 1, role, dname, ename);
            ItemCount ndst = MIDIEntityGetNumberOfDestinations(entity);
            for (ItemCount k = 0; k < ndst; ++k)
                n = add_cand(c, n, max, MIDIEntityGetDestination(entity, k), 0, role, dname, ename);
        }
    }
    return n;
}

int touch_list_endpoints(touch_endpoint_info *out, int max) {
    cand c[MAX_ENDPOINTS];
    int n = collect(c, MAX_ENDPOINTS);
    int m = 0;
    for (int i = 0; i < n && m < max; ++i) out[m++] = c[i].info;
    return m;
}

// ---------------------------------------------------------------- input

static void read_proc(const MIDIPacketList *list, void *read_ctx, void *src_ctx_ptr) {
    (void)read_ctx;
    src_ctx *s = (src_ctx *)src_ctx_ptr;
    touch_input_fn fn = g_input_fn;
    if (!fn || !s || !s->active) return;
    const MIDIPacket *p = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; ++i) {
        fn(s->role, p->data, (int)p->length, host_to_ns(p->timeStamp), g_input_ctx);
        p = MIDIPacketNext(p);
    }
}

static void notify_proc(const MIDINotification *n, void *ctx) {
    (void)ctx;
    if (n->messageID == kMIDIMsgSetupChanged || n->messageID == kMIDIMsgPropertyChanged) {
        touch_setup_fn fn = g_setup_fn;
        if (fn) fn(g_setup_ctx);
    }
}

static int output_mask_locked(void) {
    return (g_dest[0] ? 1 : 0) | (g_dest[1] ? 2 : 0);
}

// Caller holds g_lock.
static int rescan_locked(int *changed) {
    cand c[MAX_ENDPOINTS];
    int n = collect(c, MAX_ENDPOINTS);

    MIDIEndpointRef want[MAX_SOURCES];
    int wrole[MAX_SOURCES];
    int nw = 0;
    MIDIEndpointRef dest[2] = {0, 0};
    for (int i = 0; i < n; ++i) {
        if (c[i].info.is_source && nw < MAX_SOURCES) {
            want[nw] = c[i].ep;
            wrole[nw++] = c[i].info.role;
        }
        if (c[i].info.is_destination && !dest[c[i].info.role]) dest[c[i].info.role] = c[i].ep;
    }

    int diff = 0;
    int have = 0;
    for (int i = 0; i < MAX_SOURCES; ++i) if (g_src[i].active) ++have;
    if (have != nw) diff = 1;
    for (int j = 0; j < nw && !diff; ++j) {
        int found = 0;
        for (int i = 0; i < MAX_SOURCES; ++i)
            if (g_src[i].active && g_src[i].ep == want[j] && g_src[i].role == wrole[j]) found = 1;
        if (!found) diff = 1;
    }
    if (dest[0] != g_dest[0] || dest[1] != g_dest[1]) diff = 1;
    if (changed) *changed = diff;
    if (!diff) return g_input_count;

    for (int i = 0; i < MAX_SOURCES; ++i) {
        if (g_src[i].active) {
            g_src[i].active = 0;
            MIDIPortDisconnectSource(g_in, g_src[i].ep);  // fails harmlessly if the endpoint is gone
        }
    }
    int cnt = 0;
    for (int j = 0; j < nw; ++j) {
        src_ctx *s = &g_src[j];
        s->role = wrole[j];
        s->ep = want[j];
        s->active = 1;
        if (MIDIPortConnectSource(g_in, want[j], s) == noErr) ++cnt;
        else s->active = 0;
    }
    g_dest[0] = dest[0];
    g_dest[1] = dest[1];
    g_input_count = cnt;
    return cnt;
}

int touch_open(touch_input_fn input, void *input_ctx, touch_setup_fn setup, void *setup_ctx, int want_output) {
    pthread_mutex_lock(&g_lock);
    if (g_open) { pthread_mutex_unlock(&g_lock); return TOUCH_ERR_ARGS; }
    g_input_fn = input;
    g_input_ctx = input_ctx;
    g_setup_fn = setup;
    g_setup_ctx = setup_ctx;
    g_want_output = want_output ? 1 : 0;
    memset(g_src, 0, sizeof(g_src));
    g_dest[0] = g_dest[1] = 0;
    g_input_count = 0;

    OSStatus st = MIDIClientCreate(CFSTR("Touch Sample"), notify_proc, NULL, &g_client);
    if (st != noErr) { g_client = 0; pthread_mutex_unlock(&g_lock); return TOUCH_ERR_COREMIDI; }
    st = MIDIInputPortCreate(g_client, CFSTR("Touch Sample input"), read_proc, NULL, &g_in);
    if (st != noErr) {
        MIDIClientDispose(g_client); g_client = 0; g_in = 0;
        pthread_mutex_unlock(&g_lock);
        return TOUCH_ERR_COREMIDI;
    }
    if (g_want_output) {
        st = MIDIOutputPortCreate(g_client, CFSTR("Touch Sample output"), &g_out);
        if (st != noErr) {
            MIDIPortDispose(g_in); MIDIClientDispose(g_client); g_client = g_in = g_out = 0;
            pthread_mutex_unlock(&g_lock);
            return TOUCH_ERR_COREMIDI;
        }
    }
    g_open = 1;
    int changed = 0;
    int n = rescan_locked(&changed);
    pthread_mutex_unlock(&g_lock);
    return n;
}

int touch_rescan(int *changed) {
    pthread_mutex_lock(&g_lock);
    int n = g_open ? rescan_locked(changed) : 0;
    pthread_mutex_unlock(&g_lock);
    return n;
}

int touch_input_count(void) {
    pthread_mutex_lock(&g_lock);
    int n = g_input_count;
    pthread_mutex_unlock(&g_lock);
    return n;
}

int touch_output_mask(void) {
    pthread_mutex_lock(&g_lock);
    int m = g_open && g_want_output ? output_mask_locked() : 0;
    pthread_mutex_unlock(&g_lock);
    return m;
}

void touch_close(void) {
    pthread_mutex_lock(&g_lock);
    if (g_open) {
        for (int i = 0; i < MAX_SOURCES; ++i) {
            if (g_src[i].active) { g_src[i].active = 0; MIDIPortDisconnectSource(g_in, g_src[i].ep); }
        }
        g_input_fn = NULL;
        g_setup_fn = NULL;
        if (g_in) MIDIPortDispose(g_in);
        if (g_out) MIDIPortDispose(g_out);
        if (g_client) MIDIClientDispose(g_client);
        g_in = g_out = 0;
        g_client = 0;
        g_open = 0;
        g_dest[0] = g_dest[1] = 0;
        g_input_count = 0;
    }
    pthread_mutex_unlock(&g_lock);
}

// ---------------------------------------------------------------- output (the only place that writes)

const char *touch_error_string(int code) {
    switch (code) {
        case TOUCH_OK: return "ok";
        case TOUCH_ERR_ARGS: return "bad arguments";
        case TOUCH_ERR_SYSEX_5A: return "refused: SysEx 0x5A is never sent";
        case TOUCH_ERR_PRIVATE_SYSEX: return "refused: no SysEx to the Private port";
        case TOUCH_ERR_PRIVATE_MSG: return "refused: Private only takes B0 23..26 / B0 5A..5D";
        case TOUCH_ERR_MALFORMED: return "malformed MIDI message";
        case TOUCH_ERR_NOT_OPEN: return "output not open or destination absent";
        case TOUCH_ERR_COREMIDI: return "CoreMIDI error";
        default: return "unknown error";
    }
}

int touch_validate(int role, const uint8_t *b, int len) {
    if (!b || len < 1 || (role != TOUCH_PORT_PUBLIC && role != TOUCH_PORT_PRIVATE)) return TOUCH_ERR_ARGS;
    if (b[0] == 0xF0) {
        // Order matters: the 0x5A rule is reported first so it can never be masked by another rule.
        if (len > 4 && b[4] == 0x5A) return TOUCH_ERR_SYSEX_5A;
        if (role == TOUCH_PORT_PRIVATE) return TOUCH_ERR_PRIVATE_SYSEX;
        if (len < 3 || len > MAX_SYSEX || b[len - 1] != 0xF7) return TOUCH_ERR_MALFORMED;
        for (int i = 1; i < len - 1; ++i)
            if (b[i] & 0x80) return TOUCH_ERR_MALFORMED;
        return TOUCH_OK;
    }
    if (b[0] < 0x80 || b[0] >= 0xF0) return TOUCH_ERR_MALFORMED;  // data byte, system common, realtime
    int need = ((b[0] & 0xF0) == 0xC0 || (b[0] & 0xF0) == 0xD0) ? 2 : 3;
    if (len != need) return TOUCH_ERR_MALFORMED;
    for (int i = 1; i < len; ++i)
        if (b[i] & 0x80) return TOUCH_ERR_MALFORMED;
    if (role == TOUCH_PORT_PRIVATE) {
        if (b[0] != 0xB0) return TOUCH_ERR_PRIVATE_MSG;
        if (!((b[1] >= 0x23 && b[1] <= 0x26) || (b[1] >= 0x5A && b[1] <= 0x5D))) return TOUCH_ERR_PRIVATE_MSG;
    }
    return TOUCH_OK;
}

int touch_send(int role, const uint8_t *bytes, int len) {
    int v = touch_validate(role, bytes, len);
    if (v != TOUCH_OK) return v;
    pthread_mutex_lock(&g_lock);
    int rc = TOUCH_OK;
    MIDIEndpointRef dest = (role == TOUCH_PORT_PUBLIC) ? g_dest[0] : g_dest[1];
    if (!g_open || !g_want_output || !g_out || !dest) {
        rc = TOUCH_ERR_NOT_OPEN;
    } else {
        union { MIDIPacketList list; Byte raw[256]; } buf;
        MIDIPacket *pk = MIDIPacketListInit(&buf.list);
        pk = MIDIPacketListAdd(&buf.list, sizeof(buf), pk, 0, (ByteCount)len, bytes);
        if (!pk) rc = TOUCH_ERR_ARGS;
        else if (MIDISend(g_out, dest, &buf.list) != noErr) rc = TOUCH_ERR_COREMIDI;
    }
    pthread_mutex_unlock(&g_lock);
    return rc;
}

// Copied from PaperCut ControllerSetup.c (controller_send): the accepted unlock / gate / backlight SysEx.
static const uint8_t k_unlock[]    = {0xF0, 0x47, 0x7F, 0x37, 0x62, 0x00, 0x01, 0x65, 0xF7};
static const uint8_t k_gate[]      = {0xF0, 0x47, 0x00, 0x37, 0x64, 0x00, 0x01, 0x01, 0xF7};
static const uint8_t k_backlight[] = {0xF0, 0x47, 0x00, 0x37, 0x64, 0x00, 0x03, 0x00, 0x01, 0x01, 0xF7};

int touch_startup_count(void) { return 3; }

int touch_startup_message(int index, uint8_t *out, int cap) {
    const uint8_t *src = NULL;
    int n = 0;
    switch (index) {
        case 0: src = k_unlock;    n = (int)sizeof(k_unlock); break;
        case 1: src = k_gate;      n = (int)sizeof(k_gate); break;
        case 2: src = k_backlight; n = (int)sizeof(k_backlight); break;
        default: return TOUCH_ERR_ARGS;
    }
    if (!out || cap < n) return TOUCH_ERR_ARGS;
    memcpy(out, src, (size_t)n);
    return n;
}

int touch_startup(void) {
    for (int i = 0; i < 3; ++i) {
        uint8_t m[16];
        int n = touch_startup_message(i, m, sizeof(m));
        int rc = touch_send(TOUCH_PORT_PUBLIC, m, n);
        if (rc != TOUCH_OK) return rc;
        usleep(20000);
    }
    return TOUCH_OK;
}

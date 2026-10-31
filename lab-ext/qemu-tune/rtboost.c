// Loaded into QEMU with DYLD_INSERT_LIBRARIES by lab-ext/qemu-tune/qemu-system-aarch64.
// Gives QEMU's vCPU threads ("CPU n/HVF", named because the wrapper adds debug-threads=on)
// the macOS real-time (time-constraint) policy, the same class CoreAudio uses, so the guest's
// 1 ms timer ticks and the Sample's 128-frame audio periods are not woken late. Nothing in
// QEMU or the guest is modified. TS_RT_COMPUTATION_US overrides the per-1 ms budget (default 500).
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint32_t ns_to_abs(uint64_t ns) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    return (uint32_t)(ns * tb.denom / tb.numer);
}

static int boost(thread_act_t t) {
    const char *env = getenv("TS_RT_COMPUTATION_US");
    uint64_t comp_us = env ? strtoull(env, NULL, 10) : 500;
    if (comp_us < 50 || comp_us > 1000) comp_us = 500;
    thread_time_constraint_policy_data_t p = {
        .period = ns_to_abs(1000000), .computation = ns_to_abs(comp_us * 1000),
        .constraint = ns_to_abs(1000000), .preemptible = 1 };
    return thread_policy_set(t, THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p,
                             THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static void *watch(void *arg) {
    (void)arg;
    pthread_setname_np("rtboost");
    thread_act_t done[64]; int ndone = 0;
    for (int pass = 0; ; pass++) {
        thread_act_array_t list; mach_msg_type_number_t n;
        if (task_threads(mach_task_self(), &list, &n) == KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < n; i++) {
                int seen = 0;
                for (int j = 0; j < ndone; j++) if (done[j] == list[i]) seen = 1;
                thread_extended_info_data_t info; mach_msg_type_number_t c = THREAD_EXTENDED_INFO_COUNT;
                if (!seen && ndone < 64 &&
                    thread_info(list[i], THREAD_EXTENDED_INFO, (thread_info_t)&info, &c) == KERN_SUCCESS &&
                    strncmp(info.pth_name, "CPU ", 4) == 0) {
                    int r = boost(list[i]);
                    fprintf(stderr, "rtboost: %s -> %s\n", info.pth_name, r == KERN_SUCCESS ? "real-time" : "FAILED");
                    done[ndone++] = list[i];
                    continue;  // keep the port reference for the comparison above
                }
                mach_port_deallocate(mach_task_self(), list[i]);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof(thread_act_t));
        }
        sleep(pass < 60 ? 1 : 10);  // vCPU threads appear during startup; keep a slow check after
    }
    return NULL;
}

__attribute__((constructor)) static void start(void) {
    pthread_t t;
    if (pthread_create(&t, NULL, watch, NULL) == 0) pthread_detach(t);
}

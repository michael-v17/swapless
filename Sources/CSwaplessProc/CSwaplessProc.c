#include "CSwaplessProc.h"

#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>

typedef int (*sw_cir_fn)(uint64_t cid, void *buf, size_t size);
typedef pid_t (*sw_resp_fn)(pid_t pid);

static pthread_once_t sw_once = PTHREAD_ONCE_INIT;
static sw_cir_fn sw_cir = NULL;
static sw_resp_fn sw_resp = NULL;

static void sw_resolve(void) {
    sw_cir = (sw_cir_fn)dlsym(RTLD_DEFAULT, "coalition_info_resource_usage");
    sw_resp = (sw_resp_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
}

int sw_symbols_available(void) {
    pthread_once(&sw_once, sw_resolve);
    int bits = 0;
    if (sw_cir) bits |= SW_SYM_COALITION_USAGE;
    if (sw_resp) bits |= SW_SYM_RESPONSIBLE_PID;
    return bits;
}

// PROC_PIDCOALITIONINFO's struct: two coalition ids, then three reserved words.
struct sw_pidcoal {
    uint64_t coalition_id[2];
    uint64_t reserved[3];
};

int sw_coalition_ids(pid_t pid, uint64_t *resource, uint64_t *jetsam) {
    struct sw_pidcoal c;
    memset(&c, 0, sizeof c);
    errno = 0;
    int n = proc_pidinfo(pid, 20 /* PROC_PIDCOALITIONINFO */, 0, &c, (int)sizeof c);
    if (n <= 0) {
        int e = errno ? errno : ESRCH;
        return -e;
    }
    if (resource) *resource = c.coalition_id[0];
    if (jetsam) *jetsam = c.coalition_id[1];
    return 0;
}

int sw_decode_usage(const void *buf, size_t len, uint64_t *footprint, uint64_t *started,
                    uint64_t *exited) {
    const size_t need = (SW_USAGE_IDX_PHYS_FOOTPRINT + 1) * sizeof(uint64_t);
    if (buf == NULL || len < need) return SW_ERR_LAYOUT_DRIFT;
    uint64_t w[SW_USAGE_IDX_PHYS_FOOTPRINT + 1];
    memcpy(w, buf, need);  // unaligned-safe
    if (w[SW_USAGE_IDX_EQOS_LEN] != SW_USAGE_EXPECTED_EQOS_LEN) return SW_ERR_LAYOUT_DRIFT;
    if (footprint) *footprint = w[SW_USAGE_IDX_PHYS_FOOTPRINT];
    if (started) *started = w[SW_USAGE_IDX_TASKS_STARTED];
    if (exited) *exited = w[SW_USAGE_IDX_TASKS_EXITED];
    return 0;
}

int sw_coalition_usage(uint64_t cid, uint64_t *footprint, uint64_t *started, uint64_t *exited) {
    pthread_once(&sw_once, sw_resolve);
    if (!sw_cir) return SW_ERR_SYMBOL_MISSING;
    unsigned char buf[SW_USAGE_BUFFER_BYTES];
    memset(buf, 0, sizeof buf);
    errno = 0;
    int rc = sw_cir(cid, buf, sizeof buf);
    if (rc != 0) {
        int e = errno ? errno : EIO;
        return -e;
    }
    return sw_decode_usage(buf, sizeof buf, footprint, started, exited);
}

pid_t sw_responsible_pid(pid_t pid) {
    pthread_once(&sw_once, sw_resolve);
    if (!sw_resp) return SW_ERR_SYMBOL_MISSING;
    return sw_resp(pid);
}

int sw_pid_rusage(pid_t pid, sw_rusage_t *out) {
    struct rusage_info_v4 ri;
    memset(&ri, 0, sizeof ri);
    errno = 0;
    int rc = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri);
    if (rc != 0) {
        int e = errno ? errno : EIO;
        return -e;
    }
    if (out) {
        out->phys_footprint = ri.ri_phys_footprint;
        out->lifetime_max_phys_footprint = ri.ri_lifetime_max_phys_footprint;
        out->user_time = ri.ri_user_time;
        out->system_time = ri.ri_system_time;
        out->child_user_time = ri.ri_child_user_time;
        out->child_system_time = ri.ri_child_system_time;
        out->proc_start_abstime = ri.ri_proc_start_abstime;
    }
    return 0;
}

void sw_timebase(uint32_t *numer, uint32_t *denom) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    if (numer) *numer = tb.numer;
    if (denom) *denom = tb.denom;
}

int sw_task_compressed(pid_t pid, uint64_t *compressed) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_name_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kr = task_info(task, TASK_VM_INFO, (task_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), task);
    if (kr != KERN_SUCCESS) return -1;
    if (compressed) *compressed = info.compressed;
    return 0;
}

int sw_host_vm(uint64_t *compressor_pages, uint64_t *swapins, uint64_t *page_size) {
    vm_statistics64_data_t vs;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t kr = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vs, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (kr != KERN_SUCCESS) return -1;
    if (compressor_pages) *compressor_pages = vs.compressor_page_count;
    if (swapins) *swapins = vs.swapins;
    if (page_size) *page_size = vm_page_size ? (uint64_t)vm_page_size : 16384;
    return 0;
}

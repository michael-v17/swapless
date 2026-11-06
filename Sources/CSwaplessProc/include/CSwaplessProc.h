// CSwaplessProc: the only place Swapless touches private symbols (spec § A).
//
// Private symbols, resolved with dlsym under pthread_once:
//   coalition_info_resource_usage(uint64_t cid, void *buf, size_t size)
//   responsibility_get_pid_responsible_for_pid(pid_t)  -> pid_t
//
// Return codes for every sw_* call that returns int:
//   0                    ok
//   -ESRCH               the coalition / process is gone (callers skip it)
//   SW_ERR_SYMBOL_MISSING the private symbol could not be resolved
//   SW_ERR_LAYOUT_DRIFT   the kernel struct no longer looks like the 27.2 layout
//   any other -errno
#ifndef CSWAPLESSPROC_H
#define CSWAPLESSPROC_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#define SW_ERR_SYMBOL_MISSING (-1000)
#define SW_ERR_LAYOUT_DRIFT   (-1001)

/// Bits of sw_symbols_available().
#define SW_SYM_COALITION_USAGE   (1 << 0)
#define SW_SYM_RESPONSIBLE_PID   (1 << 1)

/// The usage buffer handed to the kernel. The 27.2 struct is 400 bytes; a short buffer is
/// silently truncated with rc=0, so we always pass a zero-filled 1 KiB one.
#define SW_USAGE_BUFFER_BYTES 1024

/// Word indexes inside the coalition usage struct (uint64 words).
#define SW_USAGE_IDX_TASKS_STARTED   0
#define SW_USAGE_IDX_TASKS_EXITED    1
#define SW_USAGE_IDX_EQOS_LEN       23
#define SW_USAGE_IDX_PHYS_FOOTPRINT 40
#define SW_USAGE_EXPECTED_EQOS_LEN   7

/// Bitmask of the private symbols that resolved (SW_SYM_*).
int sw_symbols_available(void);

/// PROC_PIDCOALITIONINFO (flavor 20): resource coalition [0] and jetsam coalition [1].
int sw_coalition_ids(pid_t pid, uint64_t *resource, uint64_t *jetsam);

/// coalition_info_resource_usage on a zero-filled 1 KiB buffer, then sw_decode_usage.
int sw_coalition_usage(uint64_t cid, uint64_t *footprint, uint64_t *started, uint64_t *exited);

/// Pure decoder: phys_footprint at byte offset 320 (word 40), tasks_started word 0,
/// tasks_exited word 1. SW_ERR_LAYOUT_DRIFT when word 23 (cpu_time_eqos_len) != 7 or the
/// buffer is too short to hold word 40.
int sw_decode_usage(const void *buf, size_t len, uint64_t *footprint, uint64_t *started,
                    uint64_t *exited);

/// responsibility_get_pid_responsible_for_pid(pid). -1 for unknown / other-uid pids, and
/// SW_ERR_SYMBOL_MISSING when the symbol is gone. Used for labels only.
pid_t sw_responsible_pid(pid_t pid);

/// Public proc_pid_rusage(RUSAGE_INFO_V4), flattened. Times are raw mach ticks.
typedef struct {
    uint64_t phys_footprint;
    uint64_t lifetime_max_phys_footprint;
    uint64_t user_time;
    uint64_t system_time;
    uint64_t child_user_time;
    uint64_t child_system_time;
    uint64_t proc_start_abstime;
} sw_rusage_t;

/// 0 or -errno.
int sw_pid_rusage(pid_t pid, sw_rusage_t *out);

/// mach_timebase_info numer / denom (125 / 3 on this Mac).
void sw_timebase(uint32_t *numer, uint32_t *denom);

/// TASK_VM_INFO.compressed for a same-user pid (task_name_for_pid). 0 or -errno / -1.
int sw_task_compressed(pid_t pid, uint64_t *compressed);

/// HOST_VM_INFO64: compressor_page_count and swapins, plus the page size. 0 or -1.
int sw_host_vm(uint64_t *compressor_pages, uint64_t *swapins, uint64_t *page_size);

#endif

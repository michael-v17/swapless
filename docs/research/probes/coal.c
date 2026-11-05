#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/resource.h>
struct cru { uint64_t tasks_started, tasks_exited, time_nonempty, cpu_time, interrupt_wakeups, platform_idle_wakeups, bytesread, byteswritten, gpu_time, cpu_time_billed_to_me, cpu_time_billed_to_others, energy, liw, ldw, linw, lmw, liwe, ldwe, linwe, lmwe, energy_billed_to_me, energy_billed_to_others, cpu_ptime, cpu_time_eqos_len, cpu_time_eqos[7], cpu_instructions, cpu_cycles, fs_metadata_writes, pm_writes, cpu_pinstructions, cpu_pcycles, conclave_mem, ane_mach_time, ane_energy_nj, phys_footprint, gpu_energy_nj, gpu_e_me, gpu_e_others, swapins; uint64_t pad[32]; };
struct pcoal { uint64_t coalition_id[2]; uint64_t r1, r2, r3; };
int main(int argc, char **argv) {
  int (*cir)(uint64_t, struct cru*, size_t) = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage");
  printf("sym=%p offsetof(phys_footprint)=%zu\n", (void*)cir, offsetof(struct cru, phys_footprint));
  for (int i = 1; i < argc; i++) {
    pid_t pid = atoi(argv[i]); struct pcoal c = {0}; proc_pidinfo(pid, 20, 0, &c, sizeof c);
    struct cru u; memset(&u, 0, sizeof u); int r = cir(c.coalition_id[0], &u, sizeof u); int e = errno;
    struct rusage_info_v4 ri = {0}; int rr = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t*)&ri);
    printf("pid %d coal=%llu rc=%d errno=%d tasks_started=%llu exited=%llu coal_footprint=%.1fMB swapins=%llu | own rusage rc=%d fp=%.1fMB\n", pid, c.coalition_id[0], r, r?e:0, u.tasks_started, u.tasks_exited, u.phys_footprint/1048576.0, u.swapins, rr, ri.ri_phys_footprint/1048576.0);
  }
}

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <mach/mach.h>
struct pcoal { uint64_t coalition_id[2]; uint64_t r1, r2, r3; };
int main(int argc, char **argv) {
  int (*resp)(pid_t, pid_t*, uint64_t*, uint64_t*) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
  printf("resp sym=%p\n", (void*)resp);
  for (int i = 1; i < argc; i++) {
    pid_t pid = atoi(argv[i]);
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int pl = proc_pidpath(pid, path, sizeof path);
    struct rusage_info_v6 ri; memset(&ri,0,sizeof ri);
    int r = proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t*)&ri);
    int e1 = errno;
    struct proc_taskinfo ti; int t = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti); int e2 = errno;
    struct proc_bsdinfo bi; int b = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi);
    struct proc_bsdshortinfo si; int s = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si);
    struct pcoal c; memset(&c,0,sizeof c); int cr = proc_pidinfo(pid, 20, 0, &c, sizeof c); int e3 = errno;
    mach_port_t task = MACH_PORT_NULL; kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    mach_port_t ntask = MACH_PORT_NULL; kern_return_t kr2 = task_name_for_pid(mach_task_self(), pid, &ntask);
    task_vm_info_data_t vi; mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT; kern_return_t kr3 = -1;
    if (kr2 == KERN_SUCCESS) kr3 = task_info(ntask, TASK_VM_INFO, (task_info_t)&vi, &cnt);
    pid_t rp = -1; uint64_t a=0,bb=0; int rr = resp ? resp(pid, &rp, &a, &bb) : -9;
    printf("pid %d path=%s (pl=%d)\n", pid, pl>0?path:"?", pl);
    printf("  rusage rc=%d errno=%d footprint=%.1fMB resident=%.1fMB lifemax=%.1fMB neural=%.1fMB\n", r, r?e1:0, ri.ri_phys_footprint/1048576.0, ri.ri_resident_size/1048576.0, ri.ri_lifetime_max_phys_footprint/1048576.0, ri.ri_neural_footprint/1048576.0);
    printf("  taskinfo rc=%d errno=%d rss=%.1fMB\n", t, t<=0?e2:0, t>0?ti.pti_resident_size/1048576.0:-1);
    printf("  bsdinfo rc=%d ppid=%d uid=%d | short rc=%d\n", b, b>0?bi.pbi_ppid:-1, b>0?bi.pbi_uid:-1, s);
    printf("  coalition rc=%d errno=%d ids=%llu,%llu\n", cr, cr<=0?e3:0, c.coalition_id[0], c.coalition_id[1]);
    printf("  task_for_pid kr=%d task_name_for_pid kr=%d TASK_VM_INFO(name port) kr=%d fp=%.1fMB\n", kr, kr2, kr3, kr3==0?vi.phys_footprint/1048576.0:-1);
    printf("  responsible rc=%d rpid=%d\n", rr, rp);
  }
  return 0;
}
